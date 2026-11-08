-- RLS-Career-MP client extension "rlsmp_policeRespawn": where a police car that RLS re-places comes back (and the optional extra cops).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Owner: "cop cars that respawn must NOT spawn literally in front of or behind the player; better about a block away in a DIFFERENT street, or a street
-- on the player's right side, at least about 1 km away." and "I never asked for more cops".
--  1. A police unit's `respawnCount` goes up: RLS has just re-placed it (we only look at the counter, we never touch RLS's own recycling).
--  2. We judge where the game put it (rlsmp_spawnSpot.judge, rules in lib/spawnSpot.lua): at least `spawnMinDistance` (1000 m; `chaseSpawnMinDistance`,
--     600 m, during a chase) straight-line from EVERY player, not in the camera cone or within 120 m, not on the player's own road, not on the line
--     straight ahead of / behind the player (40 m corridor). A cop that passes is left alone.
--  3. Otherwise rlsmp_spawnSpot.find looks for a better road spot in the ring [min, 2.5 x min] (right-hand side preferred). With one: when the rebuild
--     interval has passed we BUILD one new police car of a DIFFERENT model there (`core_multiSpawn.spawnGroup` with `customTransforms`, the way RLS's
--     parking does it, then `insertTraffic(id, false, true)` + `setRole('police')` like RLS's police service) and remove the old unit; in between
--     (building freezes the game for a moment) the same car is moved there with `spawn.safeTeleport`. No spot found: the cop stays as the game put it.
--  The old "150 m behind the player on the player's own trail" behaviour is gone.
-- Never: more than `perMinute` builds a minute (BeamMP sends every spawn and delete to everybody), a second build at the same time, a car that ends
-- inside the minimum distance (it is deleted again and counted as a failure; three failures switch this off for the session).
-- Switch: server config police.respawnBehind (the name is old; it now means "we place re-placed cops").
-- UNVERIFIED IN GAME: that finalizeSpawnPoint / customTransforms lay the car where we ask, that a moved cop keeps chasing (see docs/RESEARCH_POLICE_SPAWN.md).
--
-- OPTIONAL TOP-UP (default OFF, police.copCount = 0 = leave the game's number, the owner never asked for more cops): when it is above 0 and fewer AI
-- police units exist, one more is built the same way at a spot from step 3, at most one per `topUpSeconds` (30).
-- Failures are counted separately for the two jobs (3 each). Pure helpers are exported for tests/police_respawn_client_test.lua.
-- HOW MANY cops and in which AREA (rlsmp/lib/copBudget.lua): the optional top-up asks it before every build. The number follows the area type (city, main road,
-- highway, other) and the time of day (night asks for more), never above police.maxCops (3), and at most ONE cop per area cell (police.areaSize, 1500 m).
-- The exact spawn spot is the placement code's job; until it hands its spot to budgetAllows, the player's position stands in for the cell.

local M = {}

local p3 = require("rlsmp/lib/p3")
local B = require("rlsmp/lib/copBudget")

local CHECK_EVERY = 0.5
local BUILD_TIMEOUT = 25          -- seconds to wait for onVehicleGroupSpawned
local NAME = "rlsmpCop"

local CORRIDOR = 40            -- m: "straight ahead of / behind the player" (lib/spawnSpot.lua)
local RING = 2.5                  -- the ring for a new spot is [min, RING x min]
local SLACK = 50                  -- a built car may come out this much closer than asked (lane laying moves it a little)
local settings = {budget = B.clean(nil), respawnBehind = true, perMinute = 4, maxFailures = 3, copCount = 0, topUpSeconds = 30, rebuildSeconds = 90, respawnDistance = 450,
  spawnMinDistance = 1000, chaseSpawnMinDistance = 600, preferRight = true}
local seen = {}                   -- police unit id -> respawnCount last time we looked
local mine = {}                   -- ids of the cops we built (for the log and the tests)
local grace = {}                  -- cop id we just built -> clock before which a respawn counter change is not acted on
local job                         -- the build in flight: {kind = "respawn" | "top", oldId?, entry, startedAt}
local recent = {}                 -- os.time() of our builds in the last minute
local failures = {respawn = 0, top = 0}
local off = {respawn = false, top = false}
local lastTop = -math.huge        -- clock of the last top-up build
local lastBudget = -math.huge     -- clock of the last time the cop budget was asked (it reads the road under the player)
local BUDGET_EVERY = 5
local clock, timer = 0, 0
local lastBuild = -math.huge      -- clock of the last replacement build (the freeze); between builds a bad cop is only moved
local moveFailures, moveOff = 0, false

local function isMP() return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession() end
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function live() return isMP() and careerActive() end
local function respawnOn() return settings.respawnBehind and not off.respawn and live() end
local function topOn() return settings.copCount > 0 and not off.top and live() end
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end

local function trafficData()
  return gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
end

local function objectOf(id)
  if getObjectByID then return getObjectByID(id) end
  return be and be.getObjectByID and be:getObjectByID(id) or nil
end

local function xyz(p) return p and {x = p.x, y = p.y, z = p.z} or nil end

-- The player's car position and the way it looks (the camera when walking is not needed: the player's own object is always there).
local function playerFrame()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return nil end
  local pos = xyz(veh:getPosition())
  local dirOk, dir = pcall(veh.getDirectionVector, veh)
  if not (pos and dirOk and dir) then return nil end
  return pos, {x = dir.x, y = dir.y, z = dir.z}
end

-- Is `pos` in front of the player (the side the car looks to)? Pure. Returns ahead (bool), distance (m, horizontal).
function M.relative(playerPos, playerDir, pos)
  local dx, dy = pos.x - playerPos.x, pos.y - playerPos.y
  local dist = math.sqrt(dx * dx + dy * dy)
  local len = math.sqrt(playerDir.x * playerDir.x + playerDir.y * playerDir.y)
  if len < 1e-6 then return false, dist end
  return (dx * playerDir.x + dy * playerDir.y) / len > 0, dist
end

-- The least distance to every player for a spot now (a chase may have a shorter one), and the ring's far end.
function M.limits(chase)
  local min = chase and settings.chaseSpawnMinDistance or settings.spawnMinDistance
  return min, math.min(6000, min * RING)
end

local function pursuit()
  local pol = ext("police")
  return pol and pol.isPursuit and pol.isPursuit() == true or false
end

-- A road spot for a new or moved cop, or nil.
local function findSpot(why)
  local sp = ext("spawnSpot")
  if not (sp and sp.find) then return nil end
  local min, max = M.limits(pursuit())
  return sp.find({minDist = min, maxDist = max, preferRight = settings.preferRight, corridor = CORRIDOR, why = why})
end

-- The spot whose area cell must be free of cops for a top-up. The car is built behind the player, so the player's position stands in for it;
-- the placement code that picks a far spot replaces this one function.
local function topUpSpot(ppos) return ppos end

-- May one more cop be built now, by area type, time of day and area cell? Asked at most every BUDGET_EVERY seconds (it reads the road under the player).
-- A "no" is not a failure of the build: nothing is counted against the top-up.
local function budgetAllows(copPos, ppos)
  if clock - lastBudget < BUDGET_EVERY then return false end
  lastBudget = clock
  local zone, night = false, false          -- false = no area information: only the caps apply
  local v = ext("trafficVariety")
  if v and v.contextNow then
    local ok, ctx = pcall(v.contextNow)
    if ok and type(ctx) == "table" then zone, night = ctx.zone, ctx.night == true end
  end
  local ok, why = B.canAdd(settings.budget, copPos, zone, night, topUpSpot(ppos), settings.copCount)
  p3.logOnChange("cop-budget", tostring(ok) .. tostring(why) .. tostring(zone) .. tostring(night), "I",
    string.format("police budget: %s (area %s, %s, %d cops out, at most %d)%s", ok and "one more cop" or "no new cop", tostring(zone or "other"),
      night and "night" or "day", #copPos, settings.budget.maxCops, ok and "" or ": " .. tostring(why)))
  return ok
end

local function isPoliceUnit(id, veh, playerId)
  return id ~= playerId and type(veh) == "table" and veh.isAi == true and type(veh.role) == "table" and veh.role.name == "police"
end

local function underRate()
  local now = os.time()
  local kept = {}
  for _, t in ipairs(recent) do if now - t < 60 then kept[#kept + 1] = t end end
  recent = kept
  return #recent < settings.perMinute
end

local function removeCar(id)
  if gameplay_traffic and gameplay_traffic.removeTraffic then pcall(gameplay_traffic.removeTraffic, id) end
  local o = objectOf(id)
  if o and o.delete then pcall(o.delete, o) end
end

local LABEL = {respawn = "respawn", top = "top-up"}      -- the word in the log lines

local function fail(why, kind)
  kind = kind or "respawn"
  failures[kind] = failures[kind] + 1
  p3.count("police " .. kind .. " failed")
  p3.log("W", "police " .. LABEL[kind] .. ": " .. why .. " (failure " .. failures[kind] .. " of " .. settings.maxFailures .. ")")
  if failures[kind] >= settings.maxFailures then
    off[kind] = true
    p3.log("W", "police " .. LABEL[kind] .. ": switched off for this session after " .. failures[kind] .. " failures; RLS places cops as before")
  end
end

-- Build one police car through the game's group spawn. kind = "respawn" (replaces `oldId`, a model other than its) or "top" (one more cop).
-- Returns true when a build was started.
local function build(kind, oldId, oldModel, have, removeFirst, spot)
  if job or not underRate() then return false end
  local v = ext("trafficVariety")
  if not (v and v.policePick) then return false end
  local entry = v.policePick(oldModel)
  if not entry then return false end
  if not (spot and spot.q and rawget(_G, "vec3") and rawget(_G, "quat")) then return false end
  local ms = rawget(_G, "core_multiSpawn")
  if not (ms and type(ms.spawnGroup) == "function") then
    p3.logOnChange("pr-nospawn", true, "W", "police respawn: core_multiSpawn.spawnGroup is not available")
    return false
  end
  -- mode + gap are only what RLS's parking passes next to customTransforms (parking.lua:1313); the transform decides where the car appears
  local params = {name = NAME, mode = "roadBehind", gap = 50, customTransforms = {{pos = vec3(spot.x, spot.y, spot.z), rot = quat(spot.q.x, spot.q.y, spot.q.z, spot.q.w)}}}
  local ok, err = pcall(ms.spawnGroup, {{model = entry.model, config = entry.config}}, 1, params)
  if not ok then fail("spawnGroup raised: " .. tostring(err), kind) return false end
  recent[#recent + 1] = os.time()
  job = {kind = kind, oldId = oldId, entry = entry, startedAt = clock}
  if removeFirst and oldId then
    -- the cop RLS put in FRONT of the player is an unseen car right ahead (a car's auto brake reacts to it): it goes now, not when the new one is ready
    removeCar(oldId)
    seen[oldId] = nil
    job.oldId = nil
  end
  p3.count("police " .. kind .. " started")
  if kind == "respawn" then
    p3.log("I", string.format("police respawn: cop %s (%s) was re-placed; building %s/%s at a spot %.0f m from the player", tostring(oldId), tostring(oldModel), entry.model, entry.config, spot.dist or 0))
  else
    p3.log("I", string.format("police top-up: only %s of %s cops on the map; building %s/%s at a spot %.0f m from the player", tostring(have or "?"), tostring(settings.copCount), entry.model, entry.config, spot.dist or 0))
  end
  return true
end

-- The game says the group exists. Give the car to traffic as police, check where it came out; a replacement then removes the old unit.
function M.onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName ~= NAME or not job then return end
  local j = job
  job = nil
  local kind = j.kind
  local id = type(vehList) == "table" and vehList[1] or nil
  if not id then return fail("the group came back empty", kind) end
  mine[id] = true
  if not (gameplay_traffic and gameplay_traffic.insertTraffic) then removeCar(id) return fail("no insertTraffic", kind) end
  local ok, err = pcall(gameplay_traffic.insertTraffic, id, false, true)
  if not ok then removeCar(id) return fail("insertTraffic failed: " .. tostring(err), kind) end
  local veh = trafficData()[id]
  if veh and veh.setRole then
    local okRole, errRole = pcall(veh.setRole, veh, "police")
    if not okRole then removeCar(id) return fail("setRole failed: " .. tostring(errRole), kind) end
  else
    removeCar(id)
    return fail("the new car is not in the traffic data", kind)
  end
  local o = objectOf(id)
  local at = o and xyz(o:getPosition())
  local sp = ext("spawnSpot")
  if at and sp and sp.judge then
    local min = M.limits(pursuit())
    local why, dist = sp.judge(at, min - SLACK, 0)
    p3.log("I", string.format("police %s: new cop %s came out %.0f m from the player%s", LABEL[kind], tostring(id), dist or -1, why and (" (" .. why .. ")") or ""))
    if why and why ~= "noPlayer" then
      removeCar(id)
      mine[id] = nil
      return fail(string.format("the new cop came out too near or in view (%s, %.0f m): not what we want", why, dist or -1), kind)
    end
  end
  failures[kind] = 0                -- a good one: the failure count starts again
  seen[id] = tonumber(veh.respawnCount) or 0
  grace[id] = clock + 10            -- its own start is not a re-placement
  if kind == "respawn" and j.oldId then
    removeCar(j.oldId)
    seen[j.oldId] = nil
  end
  p3.count("police " .. kind .. " done")
  p3.log("I", string.format("police %s: done, new cop %s (%s)%s", LABEL[kind], tostring(id), j.entry.model,
    kind == "respawn" and (", old cop " .. tostring(j.oldId or "(removed earlier)") .. " removed") or ""))
end

-- Put the same car on the road spot (no build, no freeze).
local function moveTo(id, spot)
  local o = objectOf(id)
  if not (spot and spot.q and o and rawget(_G, "vec3") and rawget(_G, "quat")) then return false end
  local pos, rot = vec3(spot.x, spot.y, spot.z + 0.3), quat(spot.q.x, spot.q.y, spot.q.z, spot.q.w)
  local sp = rawget(_G, "spawn") or package.loaded["spawn"]
  local ok, res
  if sp and type(sp.safeTeleport) == "function" then
    ok, res = pcall(sp.safeTeleport, o, pos, rot, nil, nil, nil, true)
  elseif o.setPositionRotation then
    ok, res = pcall(o.setPositionRotation, o, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  end
  if not ok or res == false then
    moveFailures = moveFailures + 1
    p3.log("W", "police respawn: moving cop " .. tostring(id) .. " failed (" .. tostring(res) .. ")")
    if moveFailures >= settings.maxFailures then moveOff = true p3.log("W", "police respawn: moving cops is switched off for this session") end
    return false
  end
  moveFailures = 0
  grace[id] = clock + 10
  p3.count("police respawn moved")
  p3.log("I", string.format("police respawn: cop %s moved to a spot %.0f m from the player, %s side (no build)", tostring(id), spot.dist or 0, (spot.side or 0) < 0 and "right" or "other"))
  return true
end

local function step()
  if not (respawnOn() or topOn()) then return end
  local traffic = trafficData()
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  if job and clock - job.startedAt > BUILD_TIMEOUT then
    local kind = job.kind
    job = nil
    fail("no group-spawned message within " .. BUILD_TIMEOUT .. " s", kind)
  end
  local ppos = playerFrame()
  for id in pairs(seen) do if traffic[id] == nil then seen[id] = nil end end
  for id in pairs(mine) do if traffic[id] == nil then mine[id] = nil end end
  for id in pairs(grace) do if traffic[id] == nil then grace[id] = nil end end
  local cops, copPos = 0, {}
  for id, veh in pairs(traffic) do
    if isPoliceUnit(id, veh, playerId) then
      cops = cops + 1
      if veh.pos then copPos[#copPos + 1] = {x = veh.pos.x, y = veh.pos.y} end
      local rc = tonumber(veh.respawnCount) or 0
      if seen[id] == nil then
        seen[id] = rc
      elseif rc > seen[id] then
        seen[id] = rc
        if respawnOn() and not (grace[id] and clock < grace[id]) and ppos and veh.pos then
          local sp = ext("spawnSpot")
          local min = M.limits(pursuit())
          local why, dist = nil, nil
          if sp and sp.judge then why, dist = sp.judge(veh.pos, min, CORRIDOR) end
          if why and why ~= "noPlayer" then
            p3.log("I", string.format("police respawn: cop %s re-placed %.0f m from the player: not allowed (%s, minimum %.0f m)", tostring(id), dist or -1, why, min))
            local spot = findSpot("cop " .. tostring(id))
            if spot then
              local model = veh.jbeam or (objectOf(id) and objectOf(id).jbeam)
              if clock - lastBuild >= settings.rebuildSeconds and build("respawn", id, model, nil, (dist or 1e9) < 300, spot) then
                lastBuild = clock
              elseif not moveOff then
                moveTo(id, spot)
              end
            end
          elseif sp then
            p3.log("I", string.format("police respawn: cop %s re-placed %.0f m from the player: fine, left alone", tostring(id), dist or -1))
          end
        end
      end
    end
  end
  -- more cops: one more when there are fewer than copCount, at most one per topUpSeconds, and not while another build is running
  if topOn() and not job and cops < settings.copCount and clock - lastTop >= settings.topUpSeconds and ppos and budgetAllows(copPos, ppos) then
    lastTop = clock
    local spot = findSpot("top-up")
    if spot then build("top", nil, nil, cops, false, spot) end
  end
end

function M.onUpdate(dtReal)
  clock = clock + (tonumber(dtReal) or 0)
  timer = timer + (tonumber(dtReal) or 0)
  if timer < CHECK_EVERY then return end
  timer = 0
  step()
end

local function onConfig(data)
  if type(data) ~= "table" then return end
  if type(data.respawnBehind) == "boolean" then settings.respawnBehind = data.respawnBehind end
  local per = tonumber(data.respawnPerMinute)
  if per and per >= 0 and per <= 30 then settings.perMinute = math.floor(per) end
  local cops = tonumber(data.copCount)
  if cops and cops >= 0 and cops <= 6 then settings.copCount = math.floor(cops) end
  local minD = tonumber(data.spawnMinDistance)
  if minD and minD >= 300 and minD <= 3000 then settings.spawnMinDistance = minD end
  local chaseD = tonumber(data.chaseSpawnMinDistance)
  if chaseD and chaseD >= 200 and chaseD <= 3000 then settings.chaseSpawnMinDistance = chaseD end
  if type(data.spawnPreferRight) == "boolean" then settings.preferRight = data.spawnPreferRight end
  local rebuild = tonumber(data.respawnRebuildSeconds)
  if rebuild and rebuild >= 10 and rebuild <= 1800 then settings.rebuildSeconds = rebuild end
  local rd = tonumber(data.copRespawnDistance)
  if rd and rd >= 0 and rd <= 4000 then settings.respawnDistance = rd end
  if data.maxCops ~= nil or data.areaSize ~= nil or data.copTargets ~= nil then settings.budget = B.clean(data) end
  local topUp = tonumber(data.copTopUpSeconds)
  if topUp and topUp >= 5 and topUp <= 600 then settings.topUpSeconds = topUp end
end
M._onConfig = onConfig

function M.onServerLeave()
  seen, mine, grace, job, recent = {}, {}, {}, nil, {}
  lastBuild, moveFailures, moveOff = -math.huge, 0, false
  failures, off, lastTop, lastBudget = {respawn = 0, top = 0}, {respawn = false, top = false}, -math.huge, -math.huge
end

-- The least radius (m) a police unit gets before RLS re-places it (rlsmp/bubble.lua reads this); 0 = the game's own.
function M.respawnDistance() return (live() and settings.respawnDistance) or 0 end

function M.getState() return {job = job, failures = failures, off = off, settings = settings, seen = seen, mine = mine} end

-- The settings arrive in rlsmpPoliceConfig; ONE event name has ONE handler, so rlsmp/police.lua owns it and passes the data on to M._onConfig.
function M.onExtensionLoaded()
  p3.log("I", "rlsmp_policeRespawn loaded")
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
