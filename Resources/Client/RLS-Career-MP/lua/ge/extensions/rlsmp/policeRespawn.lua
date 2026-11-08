-- RLS-Career-MP client extension "rlsmp_policeRespawn": more police cars, and a police car that RLS re-places comes back BEHIND the player as a different model.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The owner's report: a re-placed cop keeps its model and the game puts it in front of the player (its own `spawnDirBias` hint did not help, see
-- docs/RESEARCH_CHASE_RANGE.md). So we do the placing ourselves:
--  1. A police unit's `respawnCount` goes up: RLS has just re-placed it (we only look at the counter, we never touch RLS's own recycling).
--  2. We build ONE new police car of a DIFFERENT model (rlsmp_trafficVariety.policePick: police settings apply) through the game's own group spawn,
--     `core_multiSpawn.spawnGroup({entry}, 1, {name = "rlsmpCop", mode = "roadBehind", gap = ...})`: the multi spawn mode that puts a car on the road behind the player.
--     RLS itself uses spawnGroup with `mode = "roadBehind"` for parked cars (integration/services/parking.lua).
--  3. `onVehicleGroupSpawned(..., "rlsmpCop")` gives us the new car: it joins traffic (`gameplay_traffic.insertTraffic(id, false, true)`) with the
--     police role (`setRole('police')`, the same two calls RLS's police service makes). We measure where it came out (`behind=`, `dist=` in the log).
--     If it is in FRONT of the player or closer than `minDistance`, it is deleted again and counted as a failure (three failures switch this off for the session).
--  4. Only then the old unit is removed. If anything fails, the old unit stays as RLS placed it.
-- Never: units within `minDistance` of the player, our own new cars, a second build at the same time, more than `perMinute` a minute (BeamMP sends every
-- spawn and delete to everybody). Switch: server config police.respawnBehind (also on the Police page of the [ menu).
-- UNVERIFIED IN GAME: what `roadBehind` does with one car and `gap` (the log says where the car really came out), and that a cop made this way chases.
--
-- TOP-UP (owner: "add more cops to the map, at most 2 to 3"): the game only puts ONE police car on the map ("requested 1, allocated 1" in the log). When the
-- number of AI police units is below `copCount` (server config police.copCount, default 3, 0 = leave the game's number) we build one more the same way
-- (steps 2 and 3 above, a random police model), at most one per `topUpSeconds` (30). The new cops are police like the game's own: RLS's police service
-- sends them after you in a chase. They are not removed when the game re-places them: they are replaced by a cop of another model behind you like any other.
-- Failures are counted separately for the two jobs (3 each), so a top-up that does not work never switches the respawn off, and the other way round.
-- Pure helpers are exported for tests/police_respawn_client_test.lua.

local M = {}

local p3 = require("rlsmp/lib/p3")

local CHECK_EVERY = 0.5
local BUILD_TIMEOUT = 25          -- seconds to wait for onVehicleGroupSpawned
local NAME = "rlsmpCop"

local settings = {respawnBehind = true, perMinute = 4, gap = 150, minDistance = 80, maxFailures = 3, copCount = 3, topUpSeconds = 30, rebuildSeconds = 90, respawnDistance = 450}
local seen = {}                   -- police unit id -> respawnCount last time we looked
local mine = {}                   -- ids of the cops we built (for the log and the tests)
local grace = {}                  -- cop id we just built -> clock before which a respawn counter change is not acted on
local job                         -- the build in flight: {kind = "respawn" | "top", oldId?, entry, startedAt}
local recent = {}                 -- os.time() of our builds in the last minute
local failures = {respawn = 0, top = 0}
local off = {respawn = false, top = false}
local lastTop = -math.huge        -- clock of the last top-up build
local clock, timer = 0, 0
local lastBuild = -math.huge      -- clock of the last replacement build (the freeze); between builds a cop in front is only moved behind the player
local trail = {}                  -- where the player has been: crumbs {x, y, z}, one every CRUMB metres, newest last
local moveFailures, moveOff = 0, false
local CRUMB, MAX_CRUMBS = 8, 400

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

-- The point `back` metres back along the player's own trail, and the direction of travel there (toward the player). Pure. nil when the trail is shorter.
function M.trailPoint(t, back)
  local acc = 0
  for i = #t, 2, -1 do
    local a, b = t[i - 1], t[i]
    local seg = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    acc = acc + seg
    if acc >= back and seg > 1e-6 then
      return {x = a.x, y = a.y, z = a.z}, {x = (b.x - a.x) / seg, y = (b.y - a.y) / seg}
    end
  end
  return nil
end

-- Add the player's position to the trail (a jump over 150 m = a teleport: start again).
function M.recordTrail(t, pos)
  local last = t[#t]
  if last then
    local d = math.sqrt((pos.x - last.x) ^ 2 + (pos.y - last.y) ^ 2)
    if d > 150 then for k in pairs(t) do t[k] = nil end last = nil
    elseif d < CRUMB then return end
  end
  t[#t + 1] = {x = pos.x, y = pos.y, z = pos.z}
  if #t > MAX_CRUMBS then table.remove(t, 1) end
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
local function build(kind, oldId, oldModel, have, removeFirst)
  if job or not underRate() then return false end
  local v = ext("trafficVariety")
  if not (v and v.policePick) then return false end
  local entry = v.policePick(oldModel)
  if not entry then return false end
  local ms = rawget(_G, "core_multiSpawn")
  if not (ms and type(ms.spawnGroup) == "function") then
    p3.logOnChange("pr-nospawn", true, "W", "police respawn: core_multiSpawn.spawnGroup is not available")
    return false
  end
  local ok, err = pcall(ms.spawnGroup, {{model = entry.model, config = entry.config}}, 1, {name = NAME, mode = "roadBehind", gap = settings.gap})
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
    p3.log("I", string.format("police respawn: cop %s (%s) was re-placed; building %s/%s behind the player", tostring(oldId), tostring(oldModel), entry.model, entry.config))
  else
    p3.log("I", string.format("police top-up: only %s of %s cops on the map; building %s/%s behind the player", tostring(have or "?"), tostring(settings.copCount), entry.model, entry.config))
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
  local ppos, pdir = playerFrame()
  local at = o and xyz(o:getPosition())
  if ppos and at then
    local ahead, dist = M.relative(ppos, pdir, at)
    p3.log("I", string.format("police %s: new cop %s came out %.0f m %s the player", LABEL[kind], tostring(id), dist, ahead and "IN FRONT OF" or "behind"))
    if ahead or dist < settings.minDistance then
      removeCar(id)
      mine[id] = nil
      return fail(string.format("the new cop came out %s (%.0f m): not what we want", ahead and "in front" or "too close", dist), kind)
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

-- A cop in front of the player: put the same car on the road behind (a point of the player's own trail), facing the way the player drives. No build.
local function moveBehind(id)
  local p, d = M.trailPoint(trail, settings.gap)
  local o = objectOf(id)
  if not (p and d and o and rawget(_G, "vec3") and rawget(_G, "quatFromDir")) then return false end
  local okRot, rot = pcall(quatFromDir, vec3(d.x, d.y, 0), vec3(0, 0, 1))
  if not okRot or not rot then return false end
  local pos = vec3(p.x, p.y, p.z + 0.3)
  local sp = rawget(_G, "spawn") or package.loaded["spawn"]
  local ok, res
  if sp and type(sp.safeTeleport) == "function" then
    ok, res = pcall(sp.safeTeleport, o, pos, rot, nil, nil, nil, true)
  elseif o.setPositionRotation then
    ok, res = pcall(o.setPositionRotation, o, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  end
  if not ok or res == false then
    moveFailures = moveFailures + 1
    p3.log("W", "police respawn: moving cop " .. tostring(id) .. " behind the player failed (" .. tostring(res) .. ")")
    if moveFailures >= settings.maxFailures then moveOff = true p3.log("W", "police respawn: moving cops is switched off for this session") end
    return false
  end
  moveFailures = 0
  grace[id] = clock + 10
  p3.count("police respawn moved")
  p3.log("I", string.format("police respawn: cop %s was in front, moved %.0f m behind the player along the road you drove (no build)", tostring(id), settings.gap))
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
  local ppos, pdir = playerFrame()
  if ppos then M.recordTrail(trail, ppos) end
  for id in pairs(seen) do if traffic[id] == nil then seen[id] = nil end end
  for id in pairs(mine) do if traffic[id] == nil then mine[id] = nil end end
  for id in pairs(grace) do if traffic[id] == nil then grace[id] = nil end end
  local cops = 0
  for id, veh in pairs(traffic) do
    if isPoliceUnit(id, veh, playerId) then
      cops = cops + 1
      local rc = tonumber(veh.respawnCount) or 0
      if seen[id] == nil then
        seen[id] = rc
      elseif rc > seen[id] then
        seen[id] = rc
        if respawnOn() and not (grace[id] and clock < grace[id]) and ppos and veh.pos then
          local ahead, dist = M.relative(ppos, pdir, veh.pos)
          if dist >= settings.minDistance then
            p3.log("I", string.format("police respawn: cop %s re-placed %.0f m %s the player", tostring(id), dist, ahead and "in front of" or "behind"))
            local model = veh.jbeam or (objectOf(id) and objectOf(id).jbeam)
            if clock - lastBuild >= settings.rebuildSeconds and build("respawn", id, model, nil, ahead) then
              lastBuild = clock
            elseif ahead and not moveOff then
              moveBehind(id)
            end
          end
        end
      end
    end
  end
  -- more cops: one more when there are fewer than copCount, at most one per topUpSeconds, and not while another build is running
  if topOn() and not job and cops < settings.copCount and clock - lastTop >= settings.topUpSeconds and ppos then
    lastTop = clock
    build("top", nil, nil, cops)
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
  local gap = tonumber(data.respawnGap)
  if gap and gap >= 20 and gap <= 500 then settings.gap = gap end
  local cops = tonumber(data.copCount)
  if cops and cops >= 0 and cops <= 6 then settings.copCount = math.floor(cops) end
  local rebuild = tonumber(data.respawnRebuildSeconds)
  if rebuild and rebuild >= 10 and rebuild <= 1800 then settings.rebuildSeconds = rebuild end
  local rd = tonumber(data.copRespawnDistance)
  if rd and rd >= 0 and rd <= 4000 then settings.respawnDistance = rd end
  local topUp = tonumber(data.copTopUpSeconds)
  if topUp and topUp >= 5 and topUp <= 600 then settings.topUpSeconds = topUp end
end
M._onConfig = onConfig

function M.onServerLeave()
  seen, mine, grace, job, recent = {}, {}, {}, nil, {}
  trail, lastBuild, moveFailures, moveOff = {}, -math.huge, 0, false
  failures, off, lastTop = {respawn = 0, top = 0}, {respawn = false, top = false}, -math.huge
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
