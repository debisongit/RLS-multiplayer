-- RLS-Career-MP client extension "rlsmp_policeRespawn": a police car that RLS re-places comes back BEHIND the player, as a different model.
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
-- Pure helpers are exported for tests/police_respawn_client_test.lua.

local M = {}

local p3 = require("rlsmp/lib/p3")

local CHECK_EVERY = 0.5
local BUILD_TIMEOUT = 25          -- seconds to wait for onVehicleGroupSpawned
local NAME = "rlsmpCop"

local settings = {respawnBehind = true, perMinute = 4, gap = 150, minDistance = 80, maxFailures = 3}
local seen = {}                   -- police unit id -> respawnCount last time we looked
local mine = {}                   -- ids of the cops we built (never replaced again)
local job                         -- the build in flight: {oldId, entry, startedAt}
local recent = {}                 -- os.time() of our builds in the last minute
local failures, off = 0, false
local clock, timer = 0, 0

local function isMP() return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession() end
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function active() return settings.respawnBehind and not off and isMP() and careerActive() end
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

local function fail(why)
  failures = failures + 1
  p3.count("police respawn failed")
  p3.log("W", "police respawn: " .. why .. " (failure " .. failures .. " of " .. settings.maxFailures .. ")")
  if failures >= settings.maxFailures then
    off = true
    p3.log("W", "police respawn: switched off for this session after " .. failures .. " failures; RLS places cops as before")
  end
end

-- Start building the replacement for a re-placed unit. Returns true when a build was started.
local function start(oldId, oldVeh)
  if job or not underRate() then return false end
  local v = ext("trafficVariety")
  if not (v and v.policePick) then return false end
  local oldModel = oldVeh.jbeam or (objectOf(oldId) and objectOf(oldId).jbeam)
  local entry = v.policePick(oldModel)
  if not entry then return false end
  local ms = rawget(_G, "core_multiSpawn")
  if not (ms and type(ms.spawnGroup) == "function") then
    p3.logOnChange("pr-nospawn", true, "W", "police respawn: core_multiSpawn.spawnGroup is not available")
    return false
  end
  local ok, err = pcall(ms.spawnGroup, {{model = entry.model, config = entry.config}}, 1, {name = NAME, mode = "roadBehind", gap = settings.gap})
  if not ok then fail("spawnGroup raised: " .. tostring(err)) return false end
  recent[#recent + 1] = os.time()
  job = {oldId = oldId, entry = entry, startedAt = clock}
  p3.count("police respawn started")
  p3.log("I", string.format("police respawn: cop %s (%s) was re-placed; building %s/%s behind the player", tostring(oldId), tostring(oldModel), entry.model, entry.config))
  return true
end

-- The game says the group exists. Give the car to traffic as police, check where it came out, then remove the old unit.
function M.onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName ~= NAME or not job then return end
  local j = job
  job = nil
  local id = type(vehList) == "table" and vehList[1] or nil
  if not id then return fail("the group came back empty") end
  mine[id] = true
  if not (gameplay_traffic and gameplay_traffic.insertTraffic) then removeCar(id) return fail("no insertTraffic") end
  local ok, err = pcall(gameplay_traffic.insertTraffic, id, false, true)
  if not ok then removeCar(id) return fail("insertTraffic failed: " .. tostring(err)) end
  local veh = trafficData()[id]
  if veh and veh.setRole then
    local okRole, errRole = pcall(veh.setRole, veh, "police")
    if not okRole then removeCar(id) return fail("setRole failed: " .. tostring(errRole)) end
  else
    removeCar(id)
    return fail("the new car is not in the traffic data")
  end
  local o = objectOf(id)
  local ppos, pdir = playerFrame()
  local at = o and xyz(o:getPosition())
  if ppos and at then
    local ahead, dist = M.relative(ppos, pdir, at)
    p3.log("I", string.format("police respawn: new cop %s came out %.0f m %s the player", tostring(id), dist, ahead and "IN FRONT OF" or "behind"))
    if ahead or dist < settings.minDistance then
      removeCar(id)
      mine[id] = nil
      return fail(string.format("the new cop came out %s (%.0f m): not what we want", ahead and "in front" or "too close", dist))
    end
  end
  failures = 0                      -- a good one: the failure count starts again
  removeCar(j.oldId)
  seen[j.oldId] = nil
  p3.count("police respawn done")
  p3.log("I", string.format("police respawn: done, new cop %s (%s), old cop %s removed", tostring(id), j.entry.model, tostring(j.oldId)))
end

local function step()
  if not active() then return end
  local traffic = trafficData()
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  if job and clock - job.startedAt > BUILD_TIMEOUT then
    job = nil
    fail("no group-spawned message within " .. BUILD_TIMEOUT .. " s")
  end
  local ppos, pdir = playerFrame()
  for id in pairs(seen) do if traffic[id] == nil then seen[id] = nil end end
  for id in pairs(mine) do if traffic[id] == nil then mine[id] = nil end end
  for id, veh in pairs(traffic) do
    if isPoliceUnit(id, veh, playerId) and not mine[id] then
      local rc = tonumber(veh.respawnCount) or 0
      if seen[id] == nil then
        seen[id] = rc
      elseif rc > seen[id] then
        seen[id] = rc
        if ppos and veh.pos then
          local ahead, dist = M.relative(ppos, pdir, veh.pos)
          if dist >= settings.minDistance then
            p3.log("I", string.format("police respawn: cop %s re-placed %.0f m %s the player", tostring(id), dist, ahead and "in front of" or "behind"))
            start(id, veh)
          end
        end
      end
    end
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
end
M._onConfig = onConfig

function M.onServerLeave()
  seen, mine, job, recent, failures, off = {}, {}, nil, {}, 0, false
end

function M.getState() return {job = job, failures = failures, off = off, settings = settings, seen = seen, mine = mine} end

-- The settings arrive in rlsmpPoliceConfig; ONE event name has ONE handler, so rlsmp/police.lua owns it and passes the data on to M._onConfig.
function M.onExtensionLoaded()
  p3.log("I", "rlsmp_policeRespawn loaded")
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
