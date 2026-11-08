-- RLS-Career-MP client extension "rlsmp_trafficReroll": a traffic car that RLS respawned out of sight comes back as a different model.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS respawns a traffic car by fading it out and moving it somewhere else; it keeps its model and config forever, so the same few cars
-- circle the map. Here: when a car's respawn count goes up and nobody can see it (not on this camera, not near or visible to another player,
-- same rules as live swapping and the recycling of stuck cars), it is replaced by an entry of the premade pool (rlsmp_trafficVariety.pickReplacement:
-- a different model, a different config, round robin with a per-brand cap) and sometimes repainted.
-- The replacing itself is rlsmp_trafficSwap.replace. Default `respawn.mode` "async": the new car is built through the game's group spawn queue (no
-- freeze), RLS traffic gets it, then the old car goes (and the view rules are checked again first). "inplace" = the game's replaceVehicle (a
-- freeze of 0.5 to 2 s per re-roll); "off" = no re-rolling. See docs/RESEARCH_ASYNC_SWAP.md.
-- Never police, taxis, pursuits, jobs, crashed, the player's or other players' cars (personality.skipReason).
-- At most `respawn.perMinute` per minute: BeamMP sends every swap (a delete and a spawn) to every player.
-- Anything unexpected leaves the car as it is. Switch: server config trafficVariety.respawn.enabled.
-- Pure logic: lib/trafficReroll.lua (tests: tests/traffic_reroll_client_test.lua).

local M = {}

local R = require("rlsmp/lib/trafficReroll")
local S = require("rlsmp/lib/trafficSwap")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local tracker = R.newTracker()
local clock, timer = 0, 0

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end
local function personality()
  local P = package.loaded["rlsmp/lib/personality"]
  if P then return P end
  local ok, mod = pcall(require, "rlsmp/lib/personality")
  return ok and mod or nil
end

-- The variety settings (server's), only while re-rolling is wanted.
local function settings()
  local v = ext("trafficVariety")
  local cfg = v and v.getConfig and v.getConfig()
  if cfg and cfg.enabled and cfg.pool.enabled and cfg.respawn.enabled and cfg.respawn.mode ~= "off" and cfg.respawn.perMinute > 0 and mp.isMPSession() and careerActive() then return cfg end
  return nil
end

local function repaint(newId)
  local paints, manager = rawget(_G, "core_vehiclePaints"), rawget(_G, "core_vehicle_manager")
  if not (paints and paints.getRandomPaintsByVehicle and manager and manager.setVehiclePaintsNames) then return end
  local ok, err = pcall(function() manager.setVehiclePaintsNames(newId, paints.getRandomPaintsByVehicle(newId)) end)
  if ok then p3.count("reroll repainted") else p3.log("W", "reroll: repaint failed: " .. tostring(err)) end
end

-- Nobody can see this car and the usual safety rules pass (also asked again when an async build finishes). Returns false, or true and the distance.
local function hiddenFrom(P, id, veh, pctx, b)
  if not (veh and veh.pos and b ~= nil and R.skipReason(P, id, veh, pctx) == nil) then return false end
  if veh.camVisible == true or (b.isEnabled and not b.isEnabled()) or (b.stayFor and b.stayFor(veh)) then return false end
  if b.viewReason then
    local seen, dist = b.viewReason(veh)    -- strict: near any player or in front of the camera = leave it
    if seen then return false, seen end
    return true, dist
  end
  return true
end

-- One round. Returns {id, from, to} when a swap was started (for tests and logs), else nil.
function M.check()
  local cfg = settings()
  if not cfg then return nil end
  local v, ts, P, ps = ext("trafficVariety"), ext("trafficSwap"), personality(), ext("personalities")
  if not (v and v.pickReplacement and ts and ts.replace and P and ps and ps.context and gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  if ts.isLiveOff() then return nil end
  if cfg.respawn.mode == "async" and not (ts.asyncReady and ts.asyncReady()) then
    p3.logOnChange("reroll-async", "none", "W", "reroll: the game's group spawn (core_multiSpawn.spawnGroup) is not available: no re-rolling until it is (set respawn.mode to inplace to accept the freeze)")
    return nil
  end
  local data = gameplay_traffic.getTrafficData()
  local alive, ids = {}, {}
  for id, veh in pairs(data) do
    alive[id] = true
    ids[#ids + 1] = id
    if R.observe(tracker, id, veh.respawnCount, clock) then
      p3.count("reroll respawns seen")
      if math.random() >= cfg.respawn.chance then tracker.due[id] = nil end
    end
  end
  R.forget(tracker, alive)
  if ts.isBusy() then return nil end
  local due = R.dueIds(tracker, clock, cfg.respawn.waitSeconds)
  if #due == 0 then return nil end
  local okb, whyb = ts.canBuild()
  if not okb then
    p3.count("reroll postponed (" .. tostring(whyb) .. ")")
    p3.logOnChange("preload-postpone", whyb, "I", "preload: build postponed: " .. tostring(whyb))
    return nil
  end
  p3.logOnChange("preload-postpone", "go", "I", "preload: builds allowed again")
  local pctx, b = ps.context(), ext("bubble")
  for _, id in ipairs(due) do
    local veh = data[id]
    local hidden, dist = hiddenFrom(P, id, veh, pctx, b)     -- dist = the distance, or the reason when seen
    if not hidden and dist then p3.count("reroll skipped (" .. tostring(dist) .. ")") end
    if hidden then
      tracker.due[id] = nil                                     -- looked at: once per respawn, swapped or not
      if not S.allowed(tracker, clock, cfg.respawn) then p3.count("reroll skipped (rate)") return nil end
      local model, name = ts.modelOf(id, veh), ts.configOf(id)
      if not model then goto continue end
      local simp = ext("simplified")
      if model == "simple_traffic" then
        -- a cheap stand-in: only handled when rlsmp_simplified manages traffic stand-ins (then its real model is the "current" one)
        model = simp and simp.trafficActive and simp.trafficActive() and simp.realOf and simp.realOf(name) or nil
        if not model then goto continue end
      end
      local current = {model = model, config = name}
      local census = R.census(ids, function(other)
        local m = ts.modelOf(other, data[other])
        if m and v.noteWarm then v.noteWarm(m) end            -- its meshes are loaded already
        return m and v.brandOf and v.brandOf(m) or nil
      end, id)
      local entry, stage = v.pickReplacement(current, census)
      if not entry then p3.count("reroll: nothing to pick") return nil end
      if simp and simp.adapt then entry = simp.adapt(veh, entry) end   -- far from every player: a cheap stand-in of the same model
      local started, why = ts.replace(id, entry, cfg.swap.maxFailures, function(newId)
        p3.count("reroll done")
        if v.noteWarm then v.noteWarm(entry.realModel or entry.model) end
        if math.random() < cfg.respawn.repaintChance then repaint(newId) end
      end, {mode = cfg.respawn.mode, stillOk = function(oldId)
        return hiddenFrom(P, oldId, gameplay_traffic.getTrafficData()[oldId], ps.context(), ext("bubble"))
      end})
      if not started then
        p3.count("reroll not started")
        p3.log("I", "reroll: car " .. tostring(id) .. " not replaced: " .. tostring(why))
        return nil
      end
      S.record(tracker, clock)
      p3.count("reroll started")
      p3.log("I", string.format("reroll: respawned car %s %s/%s -> %s/%s (pool stage %s, mode %s) dist=%s camVisible=%s", tostring(id), tostring(model), tostring(name),
        tostring(entry.model), tostring(entry.config), tostring(stage), cfg.respawn.mode, tonumber(dist) and string.format("%.0f", dist) or "?", tostring(veh.camVisible)))
      return {id = id, from = current, to = entry}
    end
    ::continue::
  end
  return nil
end

function M.onUpdate(dtReal)
  local cfg = settings()
  if not cfg then return end
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= cfg.respawn.checkSeconds then
    timer = 0
    M.check()
  end
end

function M.onServerLeave() tracker, clock, timer = R.newTracker(), 0, 0 end
function M.report() return p3.report() end
function M.onExtensionLoaded() p3.log("I", "rlsmp_trafficReroll loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
