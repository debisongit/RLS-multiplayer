-- RLS-Career-MP client extension "rlsmp_trafficFill": makes the NUMBER of traffic cars reach the server's minimum.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- gameplay_traffic.setActiveAmount only limits how many existing cars are active; it never builds a car. The game builds its traffic cars once, at
-- traffic setup, as many as the player's own setting says (a real log: 4 + 1 police = 5 cars, so the same few cars circled the player).
-- rlsmp_traffic raises the active amount to min(quota, traffic.minAmount) (getWant); when fewer cars exist than that, this extension builds the missing
-- ones (placed in the 4 km ring around the player, rlsmp_spawnSpot: traffic.spawnMinDistance/spawnMaxDistance) ONE AT A TIME, at most one every few seconds, through the async one-car group spawn of rlsmp_trafficSwap (no freeze) and gives each to RLS
-- traffic (insertTraffic). The model comes from the variety pool (excludeWords, rarity, area weights, round robin) like every other pick.
-- Never above the want. Not in a chase, not while an event/job/race has cut the traffic amount, not on slow frames, not near BeamMP's per-player car
-- limit (MaxCars). Cars added here are left alone by the stuck-car recycling, the re-roll and the swap for a while (isNew).
-- Pure logic: lib/trafficFill.lua (tests: tests/traffic_fill_client_test.lua). Log lines start with "fill:".

local M = {}

local F = require("rlsmp/lib/trafficFill")
local R = require("rlsmp/lib/trafficReroll")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local SS = require("rlsmp/lib/spawnSpot")

local CHECK_EVERY = 1
local SPAWN_MIN, SPAWN_MAX = 150, 400   -- the old fallback: metres from the player, behind the camera (out of sight)
local clock, timer, last = 0, 0, -1e9
local born = {}                          -- car id -> clock when we added it
local spawned, refused, episode = 0, 0, false

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end

-- Traffic cars that exist (the player's own, other players' and garage cars are not traffic here).
local function traffic()
  local out, n = {}, 0
  local remote = mp.remoteSet()
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local inv = overhaul_career_garage_inventory
  for id in pairs(gameplay_traffic.getTrafficData()) do
    local mine = id ~= playerId and not remote[id] and not (inv and inv.getInventoryIdFromVehicleId and inv.getInventoryIdFromVehicleId(id) ~= nil)
    if mine then out[#out + 1] = id n = n + 1 end
  end
  return n, out
end

-- The old place: behind the camera on a road, out of sight, like RLS's taxi call does it (used only when the ring is off or finds nothing).
local function spawnPlaceBehind()
  local tu = rawget(_G, "gameplay_traffic_trafficUtils")
  if not (tu and tu.findSafeSpawnPoint and tu.finalizeSpawnPoint and core_camera and core_camera.getPosition and map and map.surfaceNormal) then return nil end
  local ok, at = pcall(function()
    local camPos, camFwd = core_camera.getPosition(), core_camera.getForward()
    if not (camPos and camFwd) then return nil end
    local spawn = tu.findSafeSpawnPoint(camPos, -camFwd, SPAWN_MIN, SPAWN_MAX, SPAWN_MIN, {minDrivability = 0.5})
    if not spawn then return nil end
    local pos, dir = tu.finalizeSpawnPoint(spawn.pos, spawn.dir, spawn.n1, spawn.n2, {legalDirection = true})
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
    return {x = pos.x, y = pos.y, z = pos.z, q = {x = rot.x, y = rot.y, z = rot.z, w = rot.w}}
  end)
  return ok and at or nil
end

-- A place in the ring around the player (traffic.spawnMinDistance .. spawnMaxDistance, default 250 to 4000 m), anywhere on the roads, never within 120 m
-- of a player or in the camera cone (rlsmp_spawnSpot). Falls back to the old behind-the-camera place when the ring is off (max 0) or has no spot.
local function spawnPlace()
  local b, sp = ext("bubble"), ext("spawnSpot")
  local r = b and b.getRange and b.getRange() or {}
  local min, max = SS.ring(r.spawnMinDistance, r.spawnMaxDistance)
  if max > 0 and sp and sp.find then
    local d0 = SS.ringDistance(min, max, math.random())
    local at = sp.find({minDist = math.max(min, d0 - 300), maxDist = math.min(max, d0 + 300), preferRight = false, corridor = 0, noRoad = true, why = "fill"})
    if at then return at end
  end
  return spawnPlaceBehind()
end

-- The next model: the variety pool (round robin, rarity, area weights, excludeWords), else something the game offered lately.
local function pick(ids, v, ts)
  local census = R.census(ids, function(id)
    local m = ts.modelOf(id, gameplay_traffic.getTrafficData()[id] or {})
    return m and v.brandOf and v.brandOf(m) or nil
  end, nil)
  local entry = v.pickReplacement({}, census)
  if entry then return entry end
  local list = v.candidates()
  return list[1] and list[math.random(#list)] or nil
end

local function refuse(why, have, want, own, maxCars)
  refused = refused + 1
  p3.count("fill refused (" .. why .. ")")
  local lvl = (why == "maxCars" or why == "no place" or why == "no pick" or why == "failures") and "W" or "I"
  p3.logOnChange("fill-refuse", why, lvl, string.format("fill: refused (%s): have=%d want=%d own cars=%d maxCars=%s", why, have, want, own, tostring(maxCars)))
end

-- One round. Returns "spawn" when a car was started (for tests and logs).
function M.check()
  if not (mp.isMPSession() and careerActive() and gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficVars) then return nil end
  local t, v, ts = ext("traffic"), ext("trafficVariety"), ext("trafficSwap")
  local want = t and t.getWant and t.getWant() or 0
  if want < 1 or not (v and v.pickReplacement and ts and ts.spawnNew) then return nil end
  local have, ids = traffic()
  for id in pairs(born) do if not gameplay_traffic.getTrafficData()[id] then born[id] = nil end end
  local vars = gameplay_traffic.getTrafficVars()
  local police = ext("police")
  local why
  if gameplay_traffic.getState and gameplay_traffic.getState() ~= "on" then why = "traffic off"
  elseif not vars or (tonumber(vars.activeAmount) or 0) < want then why = "amount lowered"   -- an event or job cut it, or it is not raised yet: leave it
  elseif police and police.isPursuit and police.isPursuit() == true then why = "chase" end
  local cfg = v.getConfig and v.getConfig()
  local own = mp.ownCount()
  local maxCars = cfg and cfg.maxCars or 0
  local pending = ts.isFillBusy and ts.isFillBusy() and 1 or 0
  local act, reason = F.decide({have = have, want = want, pending = pending, own = own, maxCars = maxCars, now = clock, last = last,
    failures = ts.isLiveOff and ts.isLiveOff() and F.MAX_FAILURES or 0})
  if have >= want then
    if episode then
      episode = false
      p3.log("I", string.format("fill: done have=%d want=%d spawned=%d refused=%d", have, want, spawned, refused))
    end
    return nil
  end
  if not episode then
    episode = true
    p3.log("I", string.format("fill: have=%d want=%d, adding cars one at a time (the game made only %d; setActiveAmount cannot create cars)", have, want, have))
  end
  if why then p3.logOnChange("fill-wait", why, "I", string.format("fill: waiting (%s): have=%d want=%d", why, have, want)) return nil end
  if act ~= "spawn" then
    if reason == "maxCars" or reason == "failures" then refuse(reason, have, want, own, maxCars) end
    return nil
  end
  local okb, whyb = ts.canBuild()
  if not okb then p3.logOnChange("fill-wait", whyb, "I", string.format("fill: waiting (%s): have=%d want=%d", tostring(whyb), have, want)) return nil end
  local entry = pick(ids, v, ts)
  if not entry then refuse("no pick", have, want, own, maxCars) last = clock return nil end
  local at = spawnPlace()
  if not at then refuse("no place", have, want, own, maxCars) last = clock return nil end
  local started, whys = ts.spawnNew(entry, at, cfg and cfg.swap and cfg.swap.maxFailures, function(newId, result)
    born[newId] = clock
    spawned = spawned + 1
    if v.noteWarm then v.noteWarm(entry.model) end
    p3.count("fill cars added")
    p3.log("I", string.format("fill: car %s %s/%s added (%s); have=%d want=%d spawned=%d refused=%d", tostring(newId), tostring(entry.model), tostring(entry.config), tostring(result), (traffic()), want, spawned, refused))
  end)
  last = clock
  if not started then refuse(tostring(whys), have, want, own, maxCars) return nil end
  p3.logOnChange("fill-refuse", "ok", "I", "fill: spawning " .. tostring(entry.model) .. "/" .. tostring(entry.config) .. string.format(" have=%d want=%d", have, want))
  return "spawn"
end

-- Cars we added are left alone (stuck-car recycling, re-roll, swap) for F.GRACE seconds.
function M.isNew(id) return F.isNew(born, id, clock) end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

function M.onServerLeave() clock, timer, last, born, spawned, refused, episode = 0, 0, -1e9, {}, 0, 0, false end
function M.report() return p3.report() end
function M.onExtensionLoaded() p3.log("I", "rlsmp_trafficFill loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
