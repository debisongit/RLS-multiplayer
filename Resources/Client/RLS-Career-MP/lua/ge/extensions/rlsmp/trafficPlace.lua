-- RLS-Career-MP client extension "rlsmp_trafficPlace": a traffic car that the game has just re-placed is put somewhere in the 4 km ring around the player.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS gives a traffic car no spawn distance fields (only spawnValue, spawnDirBias, spawnRandomization: docs/RESEARCH_POLICE_SPAWN.md); the vanilla
-- placement code that picks the new spot is not in the RLS source and in the owner's logs it put cars 100 to 140 m from the player. So we watch
-- `respawnCount` (the same signal the re-roll uses); when it goes up, the car is moved to a road spot between traffic.spawnMinDistance (250) and
-- traffic.spawnMaxDistance (4000) from the player (rlsmp_spawnSpot.find: never within 120 m / the camera cone / near another player), with the
-- game's own `spawn.safeTeleport`, then `veh:onRefresh()` (RLS's own "after a respawn" refresh: resets the AI and the respawn radius).
-- A car the game placed already inside the ring and out of view is left alone. No spot found: the car stays where the game put it.
-- Not during a chase, one car per second, never for police, our fill cars, held cars, other players' cars. 0 spawnMaxDistance = the game's placement.
-- UNVERIFIED IN GAME: that the moved car drives on. Log lines start with "spawn:".

local M = {}

local S = require("rlsmp/lib/spawnSpot")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local CHECK_EVERY, WINDOW = 0.25, 300     -- seconds between looks; the ring spot is searched in distance +- WINDOW metres
local clock, timer, lastMove = 0, 0, -1e9
local seen = {}                           -- car id -> respawnCount last time
local moved, kept, none = 0, 0, 0

local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end

local function ringSettings()
  local b = ext("bubble")
  local r = b and b.getRange and b.getRange() or {}
  return S.ring(r.spawnMinDistance, r.spawnMaxDistance)
end

local function skip(id, veh, playerId, remote)
  if id == playerId or remote[id] or type(veh) ~= "table" or veh.isAi ~= true or veh.rlsmpHold then return true end
  if type(veh.role) == "table" and veh.role.name == "police" then return true end
  local fill = ext("trafficFill")
  return fill and fill.isNew and fill.isNew(id) or false
end

-- Move one car into the ring. Returns true when it was moved.
local function place(id, veh, min, max)
  local sp = ext("spawnSpot")
  if not (sp and sp.find and sp.judge) then return false end
  local why, d = sp.judge(veh.pos, min, 0, true)
  if not why and d and d <= max then
    kept = kept + 1
    p3.count("spawn: traffic left (already in the ring)")
    return false
  end
  local d0 = S.ringDistance(min, max, math.random())
  local spot = sp.find({minDist = math.max(min, d0 - WINDOW), maxDist = math.min(max, d0 + WINDOW), preferRight = false, corridor = 0, noRoad = true, why = "traffic " .. tostring(id)})
  local o = getObjectByID and getObjectByID(id)
  local sf = rawget(_G, "spawn") or package.loaded["spawn"]
  if not (spot and spot.q and o and sf and sf.safeTeleport and rawget(_G, "vec3") and rawget(_G, "quat")) then none = none + 1 return false end
  local ok, res = pcall(sf.safeTeleport, o, vec3(spot.x, spot.y, spot.z + 0.3), quat(spot.q.x, spot.q.y, spot.q.z, spot.q.w), nil, nil, nil, true, false)
  if not ok or res == false then p3.log("W", "spawn: traffic car " .. tostring(id) .. " could not be moved: " .. tostring(res)) return false end
  if type(veh.onRefresh) == "function" then pcall(veh.onRefresh, veh) end
  moved = moved + 1
  p3.count("spawn: traffic moved")
  p3.log("I", string.format("spawn: traffic car %s re-placed by the game %s m from you, moved to %.0f m (ring %d..%d m); moved=%d kept=%d nospot=%d",
    tostring(id), d and string.format("%.0f", d) or "?", spot.dist or 0, min, max, moved, kept, none))
  return true
end

function M.check()
  if not (mp.isMPSession() and careerActive() and gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  local min, max = ringSettings()
  if max <= 0 then return nil end
  local pol = ext("police")
  local data = gameplay_traffic.getTrafficData()
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local remote = mp.remoteSet()
  local result
  for id, veh in pairs(data) do
    local rc = tonumber(veh.respawnCount) or 0
    local prev = seen[id]
    seen[id] = rc
    if prev ~= nil and rc > prev and veh.pos and not result and clock - lastMove >= 1 and not skip(id, veh, playerId, remote)
      and not (pol and pol.isPursuit and pol.isPursuit() == true) then
      lastMove = clock
      if place(id, veh, min, max) then result = id end
    end
  end
  for id in pairs(seen) do if data[id] == nil then seen[id] = nil end end
  return result
end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

function M.onServerLeave() clock, timer, lastMove, seen, moved, kept, none = 0, 0, -1e9, {}, 0, 0, 0 end
function M.onExtensionLoaded() p3.log("I", "rlsmp_trafficPlace loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
