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
-- Pure logic: lib/trafficSwap.lua (tests: tests/traffic_swap_client_test.lua).

local M = {}

local S = require("rlsmp/lib/trafficSwap")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local tracker = S.newTracker()
local clock, timer = 0, 0
local pending                 -- a live swap waiting for its new car: {oldId, before = {id = true}, at, entry}
local liveOff = false         -- switched off after too many failures

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function variety() return package.loaded["rlsmp/trafficVariety"] end
local function personality() return package.loaded["rlsmp/lib/personality"] end
local function personalities() return package.loaded["rlsmp/personalities"] end
local function bubble() return package.loaded["rlsmp/bubble"] end

local function settings()
  local v = variety()
  local cfg = v and v.getConfig and v.getConfig()
  if cfg and cfg.enabled and cfg.swap and cfg.swap.enabled and mp.isMPSession() and careerActive() then return cfg end
  return nil
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

local function fail(cfg, why)
  tracker.failures = tracker.failures + 1
  p3.count("swap failed")
  p3.log("W", "swap failed: " .. tostring(why) .. " (" .. tracker.failures .. " of " .. cfg.swap.maxFailures .. ")")
  if tracker.failures >= cfg.swap.maxFailures and not liveOff then
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
local function resolvePending(cfg)
  if not pending then return end
  local fresh = {}
  for id in pairs(idSet()) do if not pending.before[id] and id ~= pending.oldId then fresh[#fresh + 1] = id end end
  local current = objectOf(pending.oldId)
  local inPlace = current ~= nil and jbeamOf(current) == pending.entry.model and pending.oldModel ~= pending.entry.model
  if #fresh > 0 or inPlace then
    local how, ids = "new id", table.concat(fresh, ",")
    if #fresh == 0 then how, ids = "replaced in place, same id", tostring(pending.oldId) end
    local results = {}
    if #fresh > 0 then for _, id in ipairs(fresh) do results[#results + 1] = toTraffic(id) end
    else results[1] = toTraffic(pending.oldId) end
    p3.count("swap done")
    p3.count(#fresh > 0 and "swap done (new id)" or "swap done (in place)")
    p3.log("I", string.format("swap done (%s): car %s is now car %s (%s/%s); traffic: %s", how, tostring(pending.oldId), ids,
      tostring(pending.entry.model), tostring(pending.entry.config), table.concat(results, ",")))
    pending = nil
  elseif clock - pending.at > 3 then
    pending = nil
    fail(cfg, "no new car appeared after the replace")
  end
end

local function performSwap(cfg, id, entry)
  local rg = package.loaded["rlsmp/lib/replaceGuard"]
  local vanilla = rg and rg.getVanilla and rg.getVanilla()
  local obj = objectOf(id)
  if not (vanilla and obj) then return fail(cfg, "the game's own replaceVehicle or the car is not available") end
  local before = idSet()
  local oldModel = jbeamOf(obj)
  local ok, err = pcall(vanilla, entry.model, {config = entry.config, autoEnterVehicle = false}, obj)
  if not ok then return fail(cfg, err) end
  pending = {oldId = id, before = before, at = clock, entry = entry, oldModel = oldModel}
  resolvePending(cfg)
end

-- One round. Returns the decision {id, from, to, live} or nil (for tests and logs).
function M.check()
  local cfg = settings()
  if not cfg then return nil end
  local v, P, ps = variety(), personality(), personalities()
  if not (v and P and ps and ps.context and gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  resolvePending(cfg)
  if pending then return nil end                                   -- one swap at a time
  local pctx = ps.context()
  local b = bubble()
  local alive, best, bestSecs = {}, nil, -1
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    alive[id] = true
    local hidden = false
    if veh.pos and P.skipReason(id, veh, pctx) == nil then
      hidden = b ~= nil and veh.camVisible ~= true and not (b.stayFor and b.stayFor(veh))
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
  if live then performSwap(cfg, best.id, entry) end
  return {id = best.id, from = current, to = entry, live = live}
end

function M.onUpdate(dtReal)
  local cfg = settings()
  if not cfg then return end
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= cfg.swap.checkSeconds then
    timer = 0
    M.check()
  end
end

function M.onServerLeave()
  tracker, pending, liveOff, clock, timer = S.newTracker(), nil, false, 0, 0
end

function M.report() return p3.report() end
function M.isLiveOff() return liveOff end

function M.onExtensionLoaded() p3.log("I", "rlsmp_trafficSwap loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
