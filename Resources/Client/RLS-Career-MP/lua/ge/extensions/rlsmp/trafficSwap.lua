-- RLS-Career-MP client extension "rlsmp_trafficSwap": traffic cars that nobody can see are swapped for a model that suits the road and the time.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A traffic car keeps its model once it exists, so the mix from rlsmp_trafficVariety only reaches cars built later. This extension also
-- follows the player: a car that has been out of EVERYBODY's sight for a while (not on this camera, not near or visible to any other player,
-- same rules as the recycling of stuck cars) may be replaced by a model that weighs clearly more for the current road class and day or night.
--
-- Two switches in the server config (`trafficVariety.swap`), both off by default:
--   enabled : only WATCH. Logs "would swap A -> B" with the reasons, counts them, changes nothing in the game.
--   live    : really replace the car (EXPERIMENTAL, never tried in the game). It uses the game's own replaceVehicle for that one car, then puts
--             the new car into RLS's traffic with gameplay_traffic.insertTraffic. After `maxFailures` failures it switches itself off.
-- At most `perMinute` swaps per minute: BeamMP sends every swap (a delete and a spawn) to every player.
-- Never touches police, taxis, pursuits, jobs, the player's or other players' cars (Claude A's personality.skipReason decides that).
-- M.replace(id, entry, maxFailures, onDone) is also used by rlsmp/trafficReroll.lua (a respawned car becomes another model).
-- Pure logic: lib/trafficSwap.lua (tests: tests/traffic_swap_client_test.lua).

local M = {}

local S = require("rlsmp/lib/trafficSwap")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local PL = require("rlsmp/lib/trafficPreload")

local tracker = S.newTracker()
local clock, timer = 0, 0
local pending                 -- a live swap waiting for its new car: {oldId, before = {id = true}, at, entry}
local liveOff = false         -- switched off after too many failures
local guard = PL.newGuard()   -- frame guard: slow frames, time of the last build

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
-- Extensions are looked up by their global name first (how core.lua finds them), then by module path.
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end
local function variety() return ext("trafficVariety") end
local function personality()
  local P = package.loaded["rlsmp/lib/personality"]
  if P then return P end
  local ok, mod = pcall(require, "rlsmp/lib/personality")
  return ok and mod or nil
end
local function personalities() return ext("personalities") end
local function bubble() return ext("bubble") end

local function settings()
  local v = variety()
  local cfg = v and v.getConfig and v.getConfig()
  if cfg and cfg.enabled and cfg.swap and cfg.swap.enabled and mp.isMPSession() and careerActive() then return cfg end
  return nil
end

-- Preload settings (the server's), or the defaults before it spoke.
local function preloadCfg()
  local v = variety()
  local cfg = v and v.getConfig and v.getConfig()
  return cfg and cfg.preload or PL.sanitize({})
end

-- May a car be built now? Not while frames are slow, not within minGapSeconds of the last build, not in a chase, not with physics paused.
function M.canBuild()
  local pc = preloadCfg()
  if not pc.enabled then return true end
  if be and be.getEnabled and be:getEnabled() == false then return false, "paused" end
  local police = ext("police")
  if police and police.isPursuit and police.isPursuit() == true then return false, "chase" end
  return PL.canBuild(guard, clock, pc)
end

local function objectOf(id)
  if getObjectByID then return getObjectByID(id) end
  return be and be.getObjectByID and be:getObjectByID(id) or nil
end

local function idSet()
  local set = {}
  if be and be.getObjectCount and be.getObject then
    for i = be:getObjectCount() - 1, 0, -1 do
      local obj = be:getObject(i)
      if obj then set[obj:getID()] = true end
    end
  end
  return set
end

local function jbeamOf(obj)
  return obj and (obj.jbeam or obj.JBeam or (obj.getJBeamFilename and obj:getJBeamFilename())) or nil
end

-- The car's CURRENT model: the object first (traffic data may keep the old name after a swap in place), then the traffic data.
local function modelOf(id, veh)
  local fromObject = jbeamOf(objectOf(id))
  if fromObject then return fromObject end
  if type(veh.model) == "string" and veh.model ~= "" then return veh.model end
  return nil
end

local function configOf(id)
  local obj = objectOf(id)
  local path = obj and obj.partConfig
  return type(path) == "string" and path:match("([^/\\]+)%.pc$") or nil
end

local function fail(maxFailures, why)
  tracker.failures = tracker.failures + 1
  p3.count("swap failed")
  p3.log("W", "swap failed: " .. tostring(why) .. " (" .. tracker.failures .. " of " .. maxFailures .. ")")
  if tracker.failures >= maxFailures and not liveOff then
    liveOff = true
    p3.log("W", "live swapping switched itself off after too many failures; it only watches now")
  end
end

-- Gives a car to RLS's traffic unless the traffic system already knows it.
local function toTraffic(id)
  local known = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[id]
  if known then return "already in traffic" end
  if gameplay_traffic and gameplay_traffic.insertTraffic then
    local ok, err = pcall(gameplay_traffic.insertTraffic, id)
    if not ok then p3.log("W", "swap: insertTraffic failed for " .. tostring(id) .. ": " .. tostring(err)) return "insertTraffic failed" end
    return "inserted into traffic"
  end
  return "no insertTraffic"
end

-- A live swap was asked for. The game may have made a NEW car (a new id) or changed the car IN PLACE (same id, new model): both are a success,
-- and the log says which one it was (that is the most useful thing to learn from the first real swap).
local function resolvePending()
  if not pending then return end
  local fresh = {}
  local remote = mp.remoteSet()
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local inv = overhaul_career_garage_inventory
  for id in pairs(idSet()) do
    if not pending.before[id] and id ~= pending.oldId then
      -- only the car this swap created: right model, not another player's, not the player's own, not one of the player's garage cars
      local o = objectOf(id)
      local mine = o ~= nil and jbeamOf(o) == pending.entry.model and not remote[id] and id ~= playerId
        and not (inv and inv.getInventoryIdFromVehicleId and inv.getInventoryIdFromVehicleId(id) ~= nil)
      if mine then fresh[#fresh + 1] = id end
    end
  end
  local current = objectOf(pending.oldId)
  local inPlace = current ~= nil and jbeamOf(current) == pending.entry.model and pending.oldModel ~= pending.entry.model
  if #fresh > 0 or inPlace then
    local how, ids = "new id", table.concat(fresh, ",")
    if #fresh == 0 then how, ids = "replaced in place, same id", tostring(pending.oldId) end
    local results = {}
    if pending.entry.noTraffic then results[1] = "not traffic (parked car)"   -- rlsmp_simplified: the caller puts the car back where it belongs
    elseif #fresh > 0 then for _, id in ipairs(fresh) do results[#results + 1] = toTraffic(id) end
    else results[1] = toTraffic(pending.oldId) end
    p3.count("swap done")
    p3.count(#fresh > 0 and "swap done (new id)" or "swap done (in place)")
    p3.log("I", string.format("swap done (%s): car %s is now car %s (%s/%s); traffic: %s", how, tostring(pending.oldId), ids,
      tostring(pending.entry.model), tostring(pending.entry.config), table.concat(results, ",")))
    local done, newId = pending.onDone, (#fresh > 0 and fresh[1] or pending.oldId)
    -- the new car must stand where the old one stood (the game's replaceVehicle is expected to keep the place; checked, and fixed if not)
    local o, at = objectOf(newId), pending.at0
    if o and at and o.getPosition then
      local okp, np = pcall(o.getPosition, o)
      if okp and np and at.x and ((np.x - at.x) ^ 2 + (np.y - at.y) ^ 2 + (np.z - at.z) ^ 2) > 25 then
        p3.log("W", string.format("swap: the new car %s is %.0f m from where the old one stood; moving it back", tostring(newId), math.sqrt((np.x - at.x) ^ 2 + (np.y - at.y) ^ 2 + (np.z - at.z) ^ 2)))
        if o.setPositionRotation and at.q then pcall(o.setPositionRotation, o, at.x, at.y, at.z, at.q.x, at.q.y, at.q.z, at.q.w) end
      end
    end
    pending = nil
    if done then local okd, err = pcall(done, newId, how) if not okd then p3.log("W", "swap: after-swap step failed: " .. tostring(err)) end end
  elseif clock - pending.at > 3 then
    local maxF = pending.maxFailures
    pending = nil
    fail(maxF, "no new car appeared after the replace")
  end
end

-- Replaces ONE traffic car by `entry` ({model, config}) with the game's own replaceVehicle. The caller has already checked that nobody can see the car.
-- Returns true when started, or false and a reason. onDone(newId, how) runs after the swap succeeded. Failures count towards maxFailures; after that
-- live replacing switches itself off (shared by live swapping and the respawn re-roll).
function M.replace(id, entry, maxFailures, onDone)
  maxFailures = tonumber(maxFailures) or 3
  if liveOff then return false, "switched off after failures" end
  if pending then return false, "busy" end
  local can, why = M.canBuild()
  if not can then
    p3.count("build postponed (" .. tostring(why) .. ")")
    p3.logOnChange("preload-postpone", why, "I", "preload: build postponed: " .. tostring(why))
    return false, why
  end
  local rg = package.loaded["rlsmp/lib/replaceGuard"]
  local vanilla = rg and rg.getVanilla and rg.getVanilla()
  local obj = objectOf(id)
  if not (vanilla and obj) then fail(maxFailures, "the game's own replaceVehicle or the car is not available") return false, "unavailable" end
  local before = idSet()
  local oldModel = jbeamOf(obj)
  -- BeamMP only syncs a change to one of my cars when the car is marked as edited (the same marker lib/replaceGuard.lua uses)
  local serverId, mpEntry = mp.serverIdOf(id)
  if serverId ~= nil and type(mpEntry) == "table" and mpEntry.isLocal == true then mpEntry.jbeam = "-" end
  local at0
  if obj.getPosition then
    local okp, pos = pcall(obj.getPosition, obj)
    if okp and pos and pos.x then
      at0 = {x = pos.x, y = pos.y, z = pos.z}
      if obj.getRotation then
        local okr, q = pcall(obj.getRotation, obj)
        if okr and q and q.w then at0.q = {x = q.x, y = q.y, z = q.z, w = q.w} end
      end
    end
  end
  local t0 = os.clock()
  local options = {config = entry.config, autoEnterVehicle = false}
  for k, v in pairs(entry.opts or {}) do options[k] = v end   -- e.g. paint and plate of a parked car (rlsmp_simplified)
  local ok, err = pcall(vanilla, entry.model, options, obj)
  local ms = (os.clock() - t0) * 1000
  PL.built(guard, clock)
  if not ok then fail(maxFailures, err) return false, "error" end
  p3.log("I", string.format("preload: build %s/%s took %.0f ms in the call (%s)", tostring(entry.model), tostring(entry.config), ms,
    entry.fromReserve and "from the reserve" or "picked on the spot"))
  p3.count(entry.fromReserve and "builds (reserve)" or "builds (on the spot)")
  pending = {oldId = id, before = before, at = clock, entry = entry, oldModel = oldModel, onDone = onDone, maxFailures = maxFailures, at0 = at0}
  resolvePending()
  return true
end
function M.isBusy() return pending ~= nil end

-- One round. Returns the decision {id, from, to, live} or nil (for tests and logs).
function M.check()
  local cfg = settings()
  if not cfg then return nil end
  local v, P, ps = variety(), personality(), personalities()
  if not (v and P and ps and ps.context and gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  resolvePending()
  if pending then return nil end                                   -- one swap at a time
  local pctx = ps.context()
  local b = bubble()
  local alive, best, bestSecs = {}, nil, -1
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    alive[id] = true
    local hidden = false
    if veh.pos and P.skipReason(id, veh, pctx) == nil then
      hidden = b ~= nil and veh.camVisible ~= true and not (b.isEnabled and not b.isEnabled()) and not (b.stayFor and b.stayFor(veh))
      if hidden and b.viewReason and b.viewReason(veh) then hidden = false end   -- strict: near a player or in front of the camera
    end
    local secs = S.seeHidden(tracker, id, hidden, clock)
    if hidden and secs >= cfg.swap.hiddenSeconds and secs > bestSecs and not S.recentlyDecided(tracker, id, clock) then
      best, bestSecs = {id = id, veh = veh}, secs
    end
  end
  S.forget(tracker, alive)
  if not best then return nil end
  p3.count("swap candidates seen")
  if not S.allowed(tracker, clock, cfg.swap) then return nil end
  local model = modelOf(best.id, best.veh)
  if not model then return nil end
  local current = {model = model, config = configOf(best.id)}
  local entry, wc, wr = S.decide(current, v.candidates(), v.contextNow(), cfg, v.infoOf, math.random)
  S.markDecided(tracker, best.id, clock)                           -- looked at: not again for a while, swapped or not
  if not entry then return nil end
  S.record(tracker, clock)
  local live = cfg.swap.live and not liveOff
  local c = v.contextNow()
  p3.log("I", string.format("swap %s: car %s %s (%s, weight %.2f) -> %s/%s (%s, weight %.2f) zone=%s night=%s",
    live and "LIVE" or "would happen (watch only)", tostring(best.id), tostring(model), tostring((v.infoOf(current) or {}).type),
    wc, tostring(entry.model), tostring(entry.config), tostring((v.infoOf(entry) or {}).type), wr, tostring(c.zone), tostring(c.night)))
  p3.count(live and "swap attempts" or "swap would happen")
  if live then M.replace(best.id, entry, cfg.swap.maxFailures) end
  return {id = best.id, from = current, to = entry, live = live}
end

function M.onUpdate(dtReal)
  if mp.isMPSession() and careerActive() and not variety() then
    p3.logOnChange("swap-novariety", true, "W", "rlsmp_trafficVariety was not found: live swapping cannot work")
  end
  dtReal = dtReal or 0
  clock = clock + dtReal
  PL.feed(guard, dtReal, clock, preloadCfg())
  resolvePending()                                                 -- a swap started by the respawn re-roll finishes here even when watching is off
  local cfg = settings()
  if not cfg then return end
  timer = timer + dtReal
  if timer >= cfg.swap.checkSeconds then
    timer = 0
    M.check()
  end
end

function M.onServerLeave()
  tracker, pending, liveOff, clock, timer, guard = S.newTracker(), nil, false, 0, 0, PL.newGuard()
end

function M.report() return p3.report() end
function M.isLiveOff() return liveOff end
-- The car's current model and config name, for the respawn re-roll (rlsmp/trafficReroll.lua), which swaps through M.replace.
M.getClock = function() return clock end
M.modelOf = modelOf
M.configOf = configOf

function M.onExtensionLoaded() p3.log("I", "rlsmp_trafficSwap loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
