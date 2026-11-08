-- RLS-Career-MP client extension "rlsmp_simplified": cheap "simple_traffic" stand-in cars where nobody looks, real cars where it matters.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Server settings: trafficVariety.simplified {enabled (default off), parked, traffic (default off), nearRadius, perMinute, checkSeconds}.
-- What it does (decisions in lib/simplified.lua, research and the unverified list in docs/RESEARCH_SIMPLIFIED.md):
--   * discovers the stand-in configs of the model simple_traffic once (logged: `simplified: stand-in configs ...`),
--   * parked cars: RLS's parked cars are stand-ins already (the game's parked configs). A stand-in at a STEALABLE spot (rlsmp_theft.isStealable,
--     the same pick as the theft code) becomes a real car when a player is within nearRadius; a car we upgraded that is no longer at a stealable
--     spot goes back when every player is farther than 1.5 x nearRadius. The car is replaced in place (the game's replaceVehicle through
--     rlsmp_trafficSwap.replace) and handed back to RLS's parking pool;
--   * moving traffic: the respawn re-roll (rlsmp_trafficReroll) asks adapt() for a stand-in when the car is beyond nearRadius from every player;
--     a stand-in that comes within nearRadius is upgraded here.
-- Same safety rules as the other car changers: view gate (never within 120 m of a player or in front of the camera), frame guard and failure
-- switch-off inside trafficSwap.replace, perMinute budget (BeamMP sends every change to everybody), one change per round, never police, taxis,
-- jobs, pursuits, crashed cars, the player's or other players' cars (personality.skipReason). Log tag RLSMP-P3, lines start with `simplified:`.

local M = {}

local L = require("rlsmp/lib/simplified")
local S = require("rlsmp/lib/trafficSwap")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local DISCOVER_PER_TICK = 15      -- configs looked at per update while discovering
local CENSUS_EVERY = 30           -- seconds between census log lines
local RETRY_AFTER = 120           -- seconds before a car that could not be changed is looked at again
local MAX_TRIES = 3               -- parked candidates tried per round

local clock, timer, censusAt = 0, 0, 0
local tracker = S.newTracker()    -- rate stamps (perMinute)
local map, job                    -- real model -> {traffic = {}, parked = {}}; the discovery in progress
local back = {}                   -- parked car id -> {model, config} of the stand-in we upgraded (to go back to)
local decided = {}                -- car id -> time we could not / did not change it

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end
local function objectOf(id) return id and be and be.getObjectByID and be:getObjectByID(id) or nil end
local function jbeamOf(o) return o and (o.jbeam or o.JBeam or (o.getJBeamFilename and o:getJBeamFilename())) or nil end
local function parking() return rawget(_G, "overhaul_integration_services_parking") end
local function personality()
  local P = package.loaded["rlsmp/lib/personality"]
  if P then return P end
  local ok, mod = pcall(require, "rlsmp/lib/personality")
  return ok and mod or nil
end

local function settings()
  local v = ext("trafficVariety")
  local cfg = v and v.getConfig and v.getConfig()
  local s = cfg and cfg.enabled and cfg.simplified
  if s and s.enabled and mp.isMPSession() and careerActive() then return s, cfg end
  return nil
end

-- Discovery -------------------------------------------------------------------------------------------------------------------------------
local function startDiscovery()
  if map or job then return end
  local ok, data = pcall(core_vehicles and core_vehicles.getModel or function() return nil end, L.MODEL)
  if not ok or type(data) ~= "table" or type(data.configs) ~= "table" then
    map = {}
    p3.log("W", "simplified: the model simple_traffic has no configs here: nothing to manage")
    return
  end
  local names = {}
  for name in pairs(data.configs) do names[#names + 1] = name end
  table.sort(names)
  job = {names = names, i = 1, data = data, ok = {}, reasons = {}, types = {}}
end

local function stepDiscovery()
  local j = job
  if not j then return end
  local filter = rawget(_G, "overhaul_integration_patches_trafficConfigFilter")
  for _ = 1, DISCOVER_PER_TICK do
    local name = j.names[j.i]
    if not name then
      local m, n = L.buildMap(j.names, function(cn) return j.ok[cn] == true end)
      map, job = m, nil
      local models = 0
      for _, e in pairs(m) do if #e.traffic > 0 then models = models + 1 end end
      local types, reasons = {}, {}
      for t, c in pairs(j.types) do types[#types + 1] = t .. "=" .. c end
      for r, c in pairs(j.reasons) do reasons[#reasons + 1] = r .. "=" .. c end
      table.sort(types) table.sort(reasons)
      p3.log("I", string.format("simplified: stand-in configs %d (parked %d, traffic %d that pass RLS's traffic filter, for %d real models); config Types: %s; rejected by the filter: %s; first: %s",
        n.total, n.parked, n.traffic, models, #types > 0 and table.concat(types, ",") or "none known", #reasons > 0 and table.concat(reasons, ",") or "none",
        table.concat({j.names[1] or "-", j.names[2] or "-", j.names[3] or "-"}, " ")))
      return
    end
    j.i = j.i + 1
    local info = j.data.configs[name]
    local t = type(info) == "table" and (info["Config Type"] or info.Type) or nil
    t = type(t) == "string" and t or "?"
    j.types[t] = (j.types[t] or 0) + 1
    local real, kind = L.parseConfig(name)
    if real and kind == "traffic" then
      -- RLS's own rule (engine, wheels, power) decides which stand-ins may drive; we do not bypass it
      local good = true
      if filter and filter.isConfigEligible then
        local g, eligible, reason = pcall(filter.isConfigEligible, L.MODEL, name, {filters = {}})
        good = g and eligible ~= false
        if g and eligible == false then j.reasons[tostring(reason)] = (j.reasons[tostring(reason)] or 0) + 1 end
      end
      j.ok[name] = good
    end
  end
end

-- Distances and the view gate ---------------------------------------------------------------------------------------------------------------
local function xyz(v) return v and v.x and {x = v.x, y = v.y, z = v.z} or nil end

local function playerPoints()
  local list = {}
  local pv = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
  local p = pv and pv.getPosition and xyz(pv:getPosition())
  if p then list[#list + 1] = p end
  local b = ext("bubble")
  if b and b.otherPlayers then
    for _, q in ipairs(b.otherPlayers()) do list[#list + 1] = xyz(q) end
  end
  return list
end

-- Distance from a position to the nearest player (any game), math.huge when no player position is known.
local function minDist(pos) return L.nearest(xyz(pos), playerPoints()) end

-- nil = the car may be changed (far from every player and out of the camera's view); else the reason.
local function gateReason(veh)
  local b = ext("bubble")
  if not (b and b.viewReason) then return "noGate" end
  return b.viewReason(veh)
end

local function mayTry(id)
  local at = decided[id]
  return at == nil or clock - at > RETRY_AFTER
end

-- Parked cars ----------------------------------------------------------------------------------------------------------------------------------
local function parkedIds()
  if not (gameplay_parking and gameplay_parking.getParkedCarsList) then return {} end
  local out = {}
  for _, id in ipairs(gameplay_parking.getParkedCarsList(true) or {}) do
    if mp.isOwn(id) then out[#out + 1] = id end   -- never change another player's parked car (BeamMP shows it to us as a remote vehicle)
  end
  return out
end

-- Paint and plate of a car, to give the replacement the same look (the same snapshot the theft code takes).
local function look(o)
  local opts = {}
  pcall(function()
    local metallic = o.getMetallicPaintData and o:getMetallicPaintData() or {}
    local function paint(c, m) if createVehiclePaint and c then return createVehiclePaint(c, m) end return nil end
    opts.paint, opts.paint2, opts.paint3 = paint(o.color, metallic[1]), paint(o.colorPalette0, metallic[2]), paint(o.colorPalette1, metallic[3])
    if o.getDynDataFieldbyName then
      local text = o:getDynDataFieldbyName("licenseText", 0)
      if type(text) == "string" and text ~= "" then opts.licenseText = text end
    end
  end)
  return opts
end

-- After a parked car was replaced: it must be a parked car again for RLS (pool, fields, ignition).
local function fixParked(oldId, newId, how)
  local o = objectOf(newId)
  if not o then return end
  local pk = parking()
  if how == "new id" and pk then
    if pk.removeVehicle then pcall(pk.removeVehicle, oldId) end
    if pk.insertVehicle then
      local ok, err = pcall(pk.insertVehicle, newId)
      if not ok then p3.log("W", "simplified: giving the new parked car to RLS's parking failed: " .. tostring(err)) end
    end
  end
  o.playerUsable = false
  if o.setDynDataFieldbyName then
    o:setDynDataFieldbyName("isParked", 0, "true")
    o:setDynDataFieldbyName("ignoreTraffic", 0, "true")
  end
  if gameplay_walk and gameplay_walk.addVehicleToBlacklist then pcall(gameplay_walk.addVehicleToBlacklist, newId) end
  if o.queueLuaCommand then o:queueLuaCommand("electrics.setIgnitionLevel(0)") end
end

-- Starts the change of one parked car. Returns true when the game started it.
local function changeParked(id, o, want)
  local theft, v, ts = ext("theft"), ext("trafficVariety"), ext("trafficSwap")
  local entry
  if want == "toFull" then
    local info = theft and theft.carInfo and theft.carInfo(o)
    if not info or not info.model then return false, "unknown model" end
    local config = info.config
    if not config then
      local full = v and v.fullEntryFor and v.fullEntryFor(info.model)
      config = full and full.config
    end
    if not config then return false, "no real config for " .. tostring(info.model) end
    entry = {model = info.model, config = config, noTraffic = true, opts = look(o)}
  else
    local orig = back[id]
    if not orig then return false, "no stand-in remembered" end
    entry = {model = L.MODEL, config = orig.config, noTraffic = true, opts = look(o)}
  end
  local from = jbeamOf(o)
  local origModel, origConfig = from, o.partConfig
  local t0 = os.clock()
  local started, why = ts.replace(id, entry, 3, function(newId, how)
    fixParked(id, newId, how)
    back[id] = nil
    if want == "toFull" then back[newId] = {model = origModel, config = origConfig} end
    p3.count(want == "toFull" and "simplified: parked upgraded" or "simplified: parked back to stand-in")
    p3.log("I", string.format("simplified: parked car %s -> %s (%s/%s) %s; now car %s", tostring(id), want == "toFull" and "REAL" or "stand-in",
      tostring(entry.model), tostring(entry.config), how, tostring(newId)))
  end)
  if not started then return false, why end
  p3.log("I", string.format("simplified: parked car %s %s took %.0f ms in the call", tostring(id), want, (os.clock() - t0) * 1000))
  return true
end

local function checkParked(cfg)
  if not cfg.parked then return false end
  local theft, ts, pk = ext("theft"), ext("trafficSwap"), parking()
  if not (theft and theft.isStealable and ts and ts.replace) then return false end
  if pk and pk.isSpawnPending and pk.isSpawnPending() then return false end
  local want, simple, full = {}, 0, 0
  for _, id in ipairs(parkedIds()) do
    local o = objectOf(id)
    local pos = o and o.getPosition and xyz(o:getPosition())
    if pos then
      local isSimple = L.isSimple(jbeamOf(o))
      if isSimple then simple = simple + 1 else full = full + 1 end
      local w = L.parkedWant(cfg, {simple = isSimple, stealable = theft.isStealable(id), dist = minDist(pos), converted = back[id] ~= nil})
      if w and mayTry(id) then want[#want + 1] = {id = id, o = o, pos = pos, want = w, dist = minDist(pos)} end
    end
  end
  M.lastParked = {simple = simple, full = full}
  table.sort(want, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.id < b.id end)
  for i = 1, math.min(MAX_TRIES, #want) do
    local c = want[i]
    local spot = pk and pk.getCurrentParkingSpot and pk.getCurrentParkingSpot(c.id)
    local reason = gateReason({pos = c.o:getPosition()})
    if not spot then
      p3.count("simplified: skipped (not parked on a spot)")
    elseif reason then
      p3.count("simplified: skipped (" .. reason .. ")")
    else
      decided[c.id] = clock
      local ok, why = changeParked(c.id, c.o, c.want)
      if ok then S.record(tracker, clock) return true end
      p3.count("simplified: not started")
      p3.log("I", string.format("simplified: parked car %s %s not started: %s", tostring(c.id), c.want, tostring(why)))
    end
  end
  return false
end

-- True while we swapped this parked car (it is a different object than RLS first spawned; leave it alone).
function M.holdsCar(id) return back[id] ~= nil end

-- Moving traffic -------------------------------------------------------------------------------------------------------------------------------
function M.trafficActive()
  local cfg = settings()
  return cfg ~= nil and cfg.traffic == true
end
M.realOf = L.realOf

-- The respawn re-roll picked `entry` (a real car) for `veh`. Returns the stand-in of the same model when the car is beyond nearRadius from
-- every player and a traffic stand-in of that model exists, else the entry unchanged.
function M.adapt(veh, entry)
  local cfg = settings()
  if not (cfg and cfg.traffic and entry and veh and veh.pos) then return entry end
  startDiscovery()
  if not map then return entry end
  local dist = minDist(veh.pos)
  local kind = L.respawnKind(cfg, dist, L.hasTraffic(map))
  if kind ~= "simple" then
    p3.count("simplified: respawn real car")
    return entry
  end
  local name = L.pickSimple(map, entry.model, "traffic")
  if not name then
    p3.count("simplified: respawn real car (no stand-in for the model)")
    return entry
  end
  p3.count("simplified: respawn stand-in")
  p3.log("I", string.format("simplified: respawn car at %.0f m from every player: stand-in %s for %s", dist, name, tostring(entry.model)))
  return {model = L.MODEL, config = name, realModel = entry.model, fromReserve = entry.fromReserve}
end

local function checkTraffic(cfg)
  if not cfg.traffic then return false end
  local ts, v, ps, P = ext("trafficSwap"), ext("trafficVariety"), ext("personalities"), personality()
  if not (ts and ts.replace and v and v.fullEntryFor and ps and ps.context and P and gameplay_traffic and gameplay_traffic.getTrafficData) then return false end
  local pctx = ps.context()
  local want, simple, full = {}, 0, 0
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    local model = veh.pos and ts.modelOf(id, veh)
    if model and P.skipReason(id, veh, pctx) == nil then
      local isSimple = L.isSimple(model)
      if isSimple then simple = simple + 1 else full = full + 1 end
      if isSimple and mayTry(id) then
        local dist = minDist(veh.pos)
        if L.trafficWant(cfg, {simple = true, dist = dist}) then want[#want + 1] = {id = id, veh = veh, dist = dist} end
      end
    end
  end
  M.lastTraffic = {simple = simple, full = full}
  table.sort(want, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.id < b.id end)
  for i = 1, math.min(MAX_TRIES, #want) do
    local c = want[i]
    local reason = (c.veh.camVisible == true and "camVisible") or gateReason(c.veh)
    if reason then
      p3.count("simplified: skipped (" .. reason .. ")")
    else
      decided[c.id] = clock
      local real = L.realOf(ts.configOf(c.id))
      local full = real and v.fullEntryFor(real)
      if not full then
        p3.count("simplified: not started")
        p3.log("I", string.format("simplified: traffic stand-in %s (%s) cannot be upgraded: no real config of that model in the pool", tostring(c.id), tostring(real)))
      else
        local t0 = os.clock()
        local started, why = ts.replace(c.id, {model = full.model, config = full.config}, 3, function(newId, how)
          p3.count("simplified: traffic upgraded")
          p3.log("I", string.format("simplified: traffic stand-in %s -> REAL %s/%s (%s) at %.0f m; now car %s", tostring(c.id), tostring(full.model), tostring(full.config), how, c.dist, tostring(newId)))
        end)
        if started then
          p3.log("I", string.format("simplified: traffic upgrade took %.0f ms in the call", (os.clock() - t0) * 1000))
          S.record(tracker, clock)
          return true
        end
        p3.count("simplified: not started")
        p3.log("I", string.format("simplified: traffic stand-in %s not upgraded: %s", tostring(c.id), tostring(why)))
      end
    end
  end
  return false
end

-- One round ------------------------------------------------------------------------------------------------------------------------------------
local function census()
  local pk, tr = M.lastParked or {simple = 0, full = 0}, M.lastTraffic or {simple = 0, full = 0}
  local converted = 0
  for _ in pairs(back) do converted = converted + 1 end
  p3.log("I", string.format("simplified: parked simple=%d full=%d (upgraded by us %d) | traffic simple=%d full=%d | parked up=%d back=%d, traffic up=%d, respawn stand-in=%d real=%d, not started=%d",
    pk.simple, pk.full, converted, tr.simple, tr.full, p3.get("simplified: parked upgraded"), p3.get("simplified: parked back to stand-in"),
    p3.get("simplified: traffic upgraded"), p3.get("simplified: respawn stand-in"), p3.get("simplified: respawn real car"), p3.get("simplified: not started")))
end

-- Returns true when a change was started (for tests).
function M.check()
  local cfg = settings()
  if not cfg then return false end
  startDiscovery()
  local ts = ext("trafficSwap")
  if not (ts and ts.canBuild and ts.isBusy) then return false end
  if ts.isBusy() or not ts.canBuild() then return false end
  if not S.allowed(tracker, clock, cfg) then return false end
  local did = checkParked(cfg)
  if not did then did = checkTraffic(cfg) end
  return did
end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  local cfg = settings()
  if not cfg then return end
  stepDiscovery()
  if timer >= cfg.checkSeconds then
    timer = 0
    M.check()
  end
  if clock - censusAt >= CENSUS_EVERY then
    censusAt = clock
    census()
  end
  for id in pairs(back) do if not objectOf(id) then back[id] = nil end end
end

function M.onServerLeave()
  clock, timer, censusAt, tracker, map, job, back, decided = 0, 0, 0, S.newTracker(), nil, nil, {}, {}
  M.lastParked, M.lastTraffic = nil, nil
end

function M.standIns() return map end
function M.report() return p3.report() end
function M.onExtensionLoaded() p3.log("I", "rlsmp_simplified loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("simplified", M)
return M
