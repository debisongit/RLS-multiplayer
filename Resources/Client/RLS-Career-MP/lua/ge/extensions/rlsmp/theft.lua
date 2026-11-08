-- RLS-Career-MP client extension "rlsmp_theft": steal a parked car (off unless the server turns it on: rlsmpTheftConfig).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- 1. The server sends a seed per period. A parked car of THIS game is stealable when lib/theft.stealable(seed, period, perMille,
--    position) says so (the same in every game for the same spot).
-- 2. Walking up to a stealable car (within `radius` m) asks the server which methods we have the tools for
--    (rlsmpTheftCheck {id, value, year} -> rlsmpTheftCan {methods}); a yes shows one small toast "Press [key] ...".
-- 3. The key is our input action rlsmpInteract (core/input/actions/rlsmp.json, M.interact). It opens a small popup (vanilla guihook
--    showConfirmationDialog, the same one rlsmp/garage.lua uses) with: Inspect, one button per steal method we have tools for, Cancel.
--    A button calls M.choose("inspect") or M.choose("steal:<method>"), which asks to start (rlsmpTheftStart). rlsmpTheftGo gives the
--    time and noise. A toast shows progress every second; walking away cancels (rlsmpTheftCancel). Noise raises a local flag (M.noise()).
--    Nothing needs chat. The server's chat /steal is only a hidden developer fallback (same code path).
-- 4. When the time is up we ask for the result (rlsmpTheftFinish): the server rolls the failure chance and uses up papers.
-- 5. Success: the parked car is turned into a normal driveable car the way docs/RESEARCH_PLATES_THEFT.md describes (snapshot,
--    delete the parked object, core_vehicles.spawnNewVehicle with RLS's own parked-car spawn options, ignoreParking, never
--    isParked, simple_traffic mapped to the real model, off the walk blacklist), vehicleGuard is told this id is ours to enter,
--    the player gets in, and the server hears about it (rlsmpTheftDone) and decides when it is reported.
-- The car is NOT put in the garage inventory: selling and stripping go through the fence (garage computer or Black Market app, server/fence.lua) using M.stolenCars().
-- rlsmpTheftReported needs nothing here: the police find the car by its plate (plate reading).
-- 6. Inspect hint (black market members only, decided by the SERVER): within cfg.inspect.range of a stealable parked car we ask
--    (rlsmpTheftHint); only a member in range gets an answer, then one small toast says "Press [key] to look closer". The popup's Inspect
--    works on the nearest parked car of ANY kind (the popup opens for any parked car in range, so it never tells who is a member), takes
--    a few seconds and the server answers with text; boring cars and non-members get the same wait and the plain "nothing stands out" text.
-- Untested in-game. Log tag RLSMP-THEFT.

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local T = require("rlsmp/lib/theft")
local SV = require("rlsmp/lib/stolenValue")
local MPrice = require("rlsmp/lib/modPrice")

local TAG = "RLSMP-THEFT"
local SCAN_EVERY = 0.5
local NOISE_SECONDS = 30
local CANCEL_MOVE = 2.0       -- metres the player may move away from where they started
local WITNESS_TRAFFIC = 50    -- metres: AI traffic that can see you
local WITNESS_PLAYERS = 80    -- metres: other players' cars and walkers

local enabled = false
local cfg                      -- last rlsmpTheftConfig
local clock, scanTimer = 0, 0
local lastCensus = -999
local spots = {}               -- vehicle id -> {key, stealable}
local target                   -- {id, key, info, can, method, label, seconds, asked}
local action                   -- {id, info, method, seconds, elapsed, startPos, noise, lastShown, finishing}
local inspectAct              -- {id, seconds, elapsed, startPos, lastShown, finishing}
local hintAsked, hinted = {}, {}   -- parked car id -> time we asked / spot key we got a hint for
local pendingEnter             -- {id, at}
local popupCar                 -- parked car id the open popup is about
local toldKey = {}             -- parked car id -> spot key we showed the key toast for
local stolen = {}              -- new vehicle id -> {vehId, plate, model, config, color, value, year, t, reported}
local noiseLevel, noiseUntil = 0, -1

local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Car theft", msg = msg, config = {timeOut = ms or 4000}}) end
end
local function say(level, msg) log(level, TAG, msg) end

-- Name of the key bound to our interact action, read the way RLS's guide.lua reads the phone key (core_input_bindings.bindings).
local ACTION = "rlsmpInteract"
local function keyName()
  local devices = core_input_bindings and core_input_bindings.bindings
  for _, device in ipairs(type(devices) == "table" and devices or {}) do
    local list = device.contents and device.contents.bindings
    for _, b in ipairs(type(list) == "table" and list or {}) do
      if b.action == ACTION and type(b.control) == "string" and b.control ~= "" then return b.control:upper() end
    end
  end
  return "Y"
end
M.keyName = keyName

function M.enable(on)
  enabled = on == true
  if not enabled then target, action, inspectAct, pendingEnter = nil, nil, nil, nil end
end

local function active() return enabled and cfg ~= nil and cfg.enabled == true end

local function objOf(id) return id and id >= 0 and be and be:getObjectByID(id) or nil end
local function jbeamOf(o) return o and (o.jbeam or o.JBeam or (o.getJBeamFilename and o:getJBeamFilename())) or nil end
local function posOf(o)
  if not o then return nil end
  local p = o:getPosition()
  return p and {x = p.x, y = p.y, z = p.z} or nil
end

-- The walking character and its position, or nil when the player is in a car.
local function walker()
  local id = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local o = objOf(id)
  if jbeamOf(o) ~= "unicycle" then return nil end
  return o, posOf(o)
end

-- Only cars THIS game spawned may be stolen, inspected, scouted or converted. BeamMP syncs every player's parked and AI cars to the others
-- as remote vehicles; those (and a car BeamMP has not registered yet) are refused here, once per car in the log.
local refusedLogged = {}
local function ownCar(id)
  local ok, why = mp.isOwn(id)
  if ok then return true end
  if not refusedLogged[id] then
    refusedLogged[id] = true
    say("I", string.format("refused: not our car id=%s (%s)", tostring(id), tostring(why)))
  end
  return false
end
M.ownCar = ownCar

local function parkedIds()
  if not (gameplay_parking and gameplay_parking.getParkedCarsList) then return {} end
  local out = {}
  for _, id in ipairs(gameplay_parking.getParkedCarsList(true) or {}) do
    if ownCar(id) then out[#out + 1] = id end
  end
  return out
end

-- Is this parked car one of the stealable ones? Cached per spot (RLS moves pool cars to other spots).
function M.isStealable(id)
  if not active() or not ownCar(id) then return false end
  local pos = posOf(objOf(id))
  local key = pos and T.spotKey(cfg.period, pos)
  if not key then return false end
  local c = spots[id]
  if c and c.key == key then return c.stealable end
  local yes = T.stealable(cfg.seed, cfg.period, cfg.perMille, pos)
  spots[id] = {key = key, stealable = yes}
  return yes
end

local function radius() return tonumber(cfg and cfg.radius) or 3 end

function M.nearestStealable(pos)
  local best, bestD
  for _, id in ipairs(parkedIds()) do
    local o = objOf(id)
    local d = o and T.dist(pos, posOf(o)) or math.huge
    if d <= radius() and (not bestD or d < bestD) and M.isStealable(id) then best, bestD = id, d end
  end
  return best, bestD
end

-- Parked cars (stealable or not) within `radius` of pos, nearest first: list of {id, pos, d}.
local function parkedNear(pos, radius)
  local out = {}
  for _, id in ipairs(parkedIds()) do
    local p = posOf(objOf(id))
    local d = p and T.dist(pos, p) or math.huge
    if d <= radius then out[#out + 1] = {id = id, pos = p, d = d} end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
end

-- Stealable parked cars within `radius` m of the player (on foot or in a car), nearest first, at most `max`: {x, y, z} list for the scout tip
-- (the server checks each one again, see server/market.lua cmds.scout).
function M.stealableNear(radius, max)
  local id = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local pos = posOf(objOf(id))
  local out = {}
  if not (pos and active()) then return out end
  for _, c in ipairs(parkedNear(pos, tonumber(radius) or 800)) do
    if M.isStealable(c.id) then out[#out + 1] = {x = c.pos.x, y = c.pos.y, z = c.pos.z} end
    if #out >= (tonumber(max) or 8) then break end
  end
  return out
end

-- Config infos of one model (cached). Falls back to the one config getConfig knows when the list is not there.
local listCache = {}
local function configsOf(model, key)
  if listCache[model] then return listCache[model] end
  local out = {}
  local ok, all = pcall(function() return core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList() end)
  local configs = ok and type(all) == "table" and (all.configs or all) or {}
  for _, info in pairs(configs) do
    if type(info) == "table" and info.model_key == model and info.key then out[#out + 1] = info end
  end
  if #out > 0 then listCache[model] = out end
  if #out == 0 and core_vehicles and core_vehicles.getConfig and key then
    local ok2, info = pcall(core_vehicles.getConfig, model, key)
    if ok2 and type(info) == "table" then out[1] = setmetatable({key = key}, {__index = info}) end
  end
  return out
end

local function marketIndex()
  local ge = overhaul_career_economy_globalEconomy
  if not (ge and ge.getVehicleMarketIndex) then return nil end
  local ok, v = pcall(ge.getVehicleMarketIndex)
  v = ok and tonumber(v) or nil
  return (v and v > 0 and v < 10) and v or nil
end

local function valueCtx()
  local vc = overhaul_career_market_valueCalculator
  return {
    year = tonumber(os.date("%Y")),
    valuation = vc and vc.getVehicleValuation,
    quick = vc and vc.getQuickVehicleValue,
    estimate = function(info) return MPrice.estimate(SV.specOf(info)) end,
    market = marketIndex(),     -- RLS's used-car market moves over time, so the price must be asked again later
  }
end

local valueCache = {}

-- Value of one model + config (names = config names to match). The cache key holds the market index, so a changed market asks again.
local function resolveValue(model, names, key)
  local ctx = valueCtx()
  local ck = model .. "|" .. tostring(names[2] or names[1]) .. "|" .. string.format("%.2f", ctx.market or 0)
  local r = valueCache[ck]
  if not r then
    local ok, res = pcall(SV.resolve, model, names, configsOf(model, key), ctx)
    r = ok and res or {value = 0, source = "error " .. tostring(res)}
    if ctx.valuation then valueCache[ck] = r end   -- RLS's calculator not loaded yet: ask again next time
    say("I", string.format("theft value: model %s config %s -> %s (%s), source %s, age %s, market %s, value %s", model, tostring(names[2] or names[1]),
      tostring(r.configKey), tostring(r.matched), tostring(r.source), tostring(r.age), tostring(r.market), tostring(r.value)))
  end
  return r
end

-- Model, config, value and year of a parked car. value = what a used car of this kind sells for (lib/stolenValue.lua: RLS's own
-- valuation of the real or typical config, else quick value, else our estimate). year = first year of the config.
function M.carInfo(o)
  local model, config, key = T.realModel(jbeamOf(o), o.partConfig)
  if not model then return nil end
  local full = T.configKey(o.partConfig)
  local r = resolveValue(model, {key, full}, key)
  -- a simplified car whose name matched a real config: spawn that config
  if not config and r.configKey and r.matched ~= "typical" then config = "vehicles/" .. model .. "/" .. r.configKey .. ".pc" end
  return {model = model, config = config, configKey = r.configKey or key, value = r.value or 0, year = r.year, source = r.source}
end

-- Value again for a stolen car (model + config path as the record stored them), with today's market. Returns value, source.
function M.valueFor(model, config)
  if type(model) ~= "string" or model == "" then return nil end
  local key = T.configKey(config)
  local r = resolveValue(model, {key, key}, key)
  if (r.value or 0) <= 0 then return nil end
  return r.value, r.source
end

local function plateOf(o)
  if o and o.getDynDataFieldbyName then
    local ok, text = pcall(o.getDynDataFieldbyName, o, "licenseText", 0)
    if ok and type(text) == "string" then return text end
  end
  return nil
end

local hasPlateRead, plateRead = pcall(require, "rlsmp/lib/plateRead")
local colorName = (hasPlateRead and type(plateRead) == "table" and type(plateRead.colorName) == "function") and plateRead.colorName or T.colorName

local function colorOf(o)
  local c = o and o.color
  if c == nil then return nil end
  return colorName(c.x or c.r or c[1], c.y or c.g or c[2], c.z or c.b or c[3])
end

-- Count of possible witnesses around a position: AI traffic and other players' cars or walkers.
function M.witnesses(pos)
  local n = 0
  local td = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
  for id, v in pairs(td) do
    if type(v) == "table" and v.isAi == true and T.dist(pos, posOf(objOf(id))) <= WITNESS_TRAFFIC then n = n + 1 end
  end
  for id in pairs(mp.remoteSet()) do
    if T.dist(pos, posOf(objOf(id))) <= WITNESS_PLAYERS then n = n + 1 end
  end
  return n
end

-- Rebuild data (for putting the car back after a rejoin, see rlsmp/recall.lua): paints and rotation as plain numbers.
local function paintTable(c, m)
  if type(c) ~= "table" and type(c) ~= "userdata" then return nil end
  local out = {x = c.x or c.r or 0, y = c.y or c.g or 0, z = c.z or c.b or 0, w = c.w or c.a or 1}
  if type(m) == "table" then
    out.m = {}
    for k, v in pairs(m) do if type(k) == "string" and type(v) == "number" then out.m[k] = v end end
  end
  return out
end
local function paintFrom(t)
  if type(t) ~= "table" or not createVehiclePaint then return nil end
  return createVehiclePaint({x = t.x, y = t.y, z = t.z, w = t.w}, t.m)
end
local function lookOf(o)
  local mt = o.getMetallicPaintData and o:getMetallicPaintData() or {}
  return {paintTable(o.color, mt[1]), paintTable(o.colorPalette0, mt[2]), paintTable(o.colorPalette1, mt[3])}
end
local function rotTable(q) return q and {x = q.x, y = q.y, z = q.z, w = q.w} or nil end

-- Turn a parked car into a normal car we can drive. Returns the new vehicle object and the snapshot, or nil + why.
-- Order matters: snapshot -> delete the parked car -> spawn -> ignoreParking / never isParked -> converted set -> off the
-- walk blacklist. Entering happens a moment later (M.onUpdate) so the new car is ready.
function M.convertParked(id)
  local o = objOf(id)
  if not o then return nil, "car gone" end
  if not ownCar(id) then return nil, "not our car" end
  local info = M.carInfo(o)
  if not info then return nil, "unknown model" end
  local metallic = o.getMetallicPaintData and o:getMetallicPaintData() or {}
  local function paint(c, m) if createVehiclePaint and c then return createVehiclePaint(c, m) end return nil end
  local p = o:getPosition()
  local snap = {
    model = info.model, config = info.config, value = info.value, year = info.year, source = info.source,
    pos = p, rot = quatFromDir and quatFromDir(vec3(o:getDirectionVector()), vec3(o:getDirectionVectorUp())) or nil,
    paint = paint(o.color, metallic[1]), paint2 = paint(o.colorPalette0, metallic[2]), paint3 = paint(o.colorPalette1, metallic[3]),
    licenseText = plateOf(o), color = colorOf(o), at = {x = p.x, y = p.y, z = p.z},
  }
  snap.look, snap.rotT = lookOf(o), rotTable(snap.rot)
  say("I", string.format("converting parked %s (%s, config %s) plate %s", tostring(id), tostring(info.model),
    tostring(info.configKey), tostring(snap.licenseText)))
  o:delete()
  spots[id] = nil
  local ok, veh = pcall(core_vehicles.spawnNewVehicle, snap.model, {
    config = snap.config, pos = snap.pos, rot = snap.rot, paint = snap.paint, paint2 = snap.paint2, paint3 = snap.paint3,
    licenseText = snap.licenseText, autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false, centeredPosition = true,
  })
  if not ok or not veh then
    say("E", "spawn of the stolen car failed: " .. tostring(veh))
    return nil, "spawn failed"
  end
  local newId = veh:getID()
  veh.ignoreParking = true
  if veh.setDynDataFieldbyName then veh:setDynDataFieldbyName("isParked", 0, "false") end
  veh.playerUsable = true
  T.markConverted(newId)
  if gameplay_walk and gameplay_walk.removeVehicleFromBlacklist then gameplay_walk.removeVehicleFromBlacklist(newId) end
  if not T.cleanPlate(snap.licenseText) then
    say("W", "the stolen car has no readable plate: the server cannot record it, so it will never be reported")
  end
  stolen[newId] = {vehId = newId, plate = T.cleanPlate(snap.licenseText) or snap.licenseText, model = snap.model, config = snap.config, color = snap.color,
    value = snap.value, year = snap.year, source = snap.source, t = os.time(), reported = false, look = snap.look}
  pendingEnter = {id = newId, at = clock + 0.5}
  return veh, snap
end

-- The server asks for a fresh price of the player's stolen cars (every theft.repriceMinutes, and for old records): we answer with today's value.
-- The car need not exist any more: model + config come from the server's record when we do not have it.
local function onReprice(d)
  if not active() or type(d) ~= "table" or type(d.cars) ~= "table" then return end
  for _, c in ipairs(d.cars) do
    if type(c) == "table" and type(c.plate) == "string" then
      local mine
      for _, rec in pairs(stolen) do if rec.plate == c.plate then mine = rec end end
      local value, source = M.valueFor(mine and mine.model or c.model, mine and mine.config or c.config)
      if value then
        if mine then mine.value, mine.source = value, source end
        net.send("rlsmpTheftValue", {plate = c.plate, value = value, source = source})
        say("I", string.format("theft value: repriced %s %s -> %s (%s)", tostring(c.model), c.plate, tostring(value), tostring(source)))
      end
    end
  end
end

-- The stolen cars that still exist in this game (for selling / stripping later).
function M.stolenCars()
  local out = {}
  for id, rec in pairs(stolen) do
    if objOf(id) then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b) return a.vehId < b.vehId end)
  return out
end

-- Fake plate fitted at the fence (garage.lua calls markFakePlate when the server says "fit:fake_plate" worked). Used by police.lua: no radar fine.
local fakePlates = {}
function M.markFakePlate(plate) local p = T.cleanPlate(plate) if p then fakePlates[p] = true end end
function M.hasFakePlate(vehId)
  local rec = stolen[vehId]
  return rec ~= nil and (rec.fakePlate == true or fakePlates[rec.plate] == true)
end

-- Put a stolen car back (rlsmp/recall.lua). spec = {plate, model, config, look, value, year, color}; pos {x,y,z}, rot {x,y,z,w} or nil.
-- Same safe spawn as the theft convert: never isParked, the guard lets the owner in, off the walk blacklist. Returns the vehicle or nil + why.
function M.spawnStolen(spec, pos, rot)
  if type(spec) ~= "table" or type(spec.model) ~= "string" or not pos then return nil, "bad record" end
  local look = type(spec.look) == "table" and spec.look or {}
  local ok, veh = pcall(core_vehicles.spawnNewVehicle, spec.model, {
    config = spec.config, pos = vec3(pos.x, pos.y, pos.z), rot = rot and quat and quat(rot.x, rot.y, rot.z, rot.w) or nil,
    paint = paintFrom(look[1]), paint2 = paintFrom(look[2]), paint3 = paintFrom(look[3]),
    licenseText = spec.plate, autoEnterVehicle = false, canSpawnAnotherVehicleCheck = false, centeredPosition = true,
  })
  if not ok or not veh then return nil, "spawn failed: " .. tostring(veh) end
  local id = veh:getID()
  veh.ignoreParking = true
  if veh.setDynDataFieldbyName then veh:setDynDataFieldbyName("isParked", 0, "false") end
  veh.playerUsable = true
  T.markConverted(id)
  if gameplay_walk and gameplay_walk.removeVehicleFromBlacklist then gameplay_walk.removeVehicleFromBlacklist(id) end
  stolen[id] = {vehId = id, plate = T.cleanPlate(spec.plate) or spec.plate, model = spec.model, config = spec.config, color = spec.color,
    value = spec.value, year = spec.year, t = os.time(), reported = false, look = spec.look}
  return veh
end

-- Does a car with this plate exist in this game (our stolen map, or any object whose plate text matches)? Returns its id.
function M.liveByPlate(plate)
  plate = T.cleanPlate(tostring(plate or ""))
  if not plate then return nil end
  for id, rec in pairs(stolen) do
    if rec.plate == plate and objOf(id) then return id end
  end
  for i = 0, (be and be.getObjectCount and be:getObjectCount() or 0) - 1 do
    local o = be:getObject(i)
    if o and not mp.isRemote(o:getID()) and T.cleanPlate(tostring(plateOf(o) or "")) == plate then return o:getID() end
  end
  return nil
end

-- Where our stolen cars stand now: list of {plate, x, y, z, rot} (recall.lua reports them to the server).
function M.stolenPlaces()
  local out = {}
  for _, rec in ipairs(M.stolenCars()) do
    local o = objOf(rec.vehId)
    local p = posOf(o)
    if p and rec.plate then
      local q = quatFromDir and quatFromDir(vec3(o:getDirectionVector()), vec3(o:getDirectionVectorUp())) or nil
      out[#out + 1] = {plate = rec.plate, x = p.x, y = p.y, z = p.z, rot = rotTable(q)}
    end
  end
  return out
end

-- Local "that was loud" flag, 0..1 (e.g. for police or witnesses later).
function M.noise() return clock < noiseUntil and noiseLevel or 0 end

local function cancel(why)
  if not action then return end
  net.send("rlsmpTheftCancel", {})
  say("I", "cancelled: " .. why)
  toast("warning", why)
  action = nil
end

local function enterNow()
  local veh = objOf(pendingEnter.id)
  pendingEnter = nil
  if not veh then return end
  if gameplay_walk and gameplay_walk.getInVehicle then
    gameplay_walk.getInVehicle(veh)
  elseif be and be.enterVehicle then
    be:enterVehicle(0, veh)
  end
end

local function runAction(dt, pos)
  action.elapsed = action.elapsed + dt
  local car = objOf(action.id)
  if not car then return cancel("The car is gone.") end
  if not pos then return cancel("You left the car.") end
  if T.dist(pos, action.startPos) > CANCEL_MOVE or T.dist(pos, posOf(car)) > radius() + 1.5 then
    return cancel("You walked away. Nothing happened.")
  end
  noiseLevel, noiseUntil = action.noise, clock + NOISE_SECONDS
  local shown = math.floor(action.elapsed)
  if shown > action.lastShown and not action.finishing then
    action.lastShown = shown
    toast("info", string.format("%s... %d / %d s", action.label or "Working", math.min(shown, action.seconds), action.seconds), 1100)
  end
  if action.elapsed >= action.seconds and not action.finishing then
    action.finishing = true
    net.send("rlsmpTheftFinish", {})
  end
end

-- Ask the server about stealable cars close by; it answers only a member who really stands in range (re-asked every 15 s until it does).
local function scanHints(pos)
  local I = cfg.inspect
  if not (I and I.enabled) then return end
  for _, c in ipairs(parkedNear(pos, I.range)) do
    if M.isStealable(c.id) and hinted[c.id] ~= spots[c.id].key and clock - (hintAsked[c.id] or -999) > 15 then
      hintAsked[c.id] = clock
      if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
      net.send("rlsmpTheftHint", {id = c.id, sid = mp.sidOf(c.id), x = c.pos.x, y = c.pos.y})
    end
  end
end

local function runInspect(dt, pos)
  local a = inspectAct
  a.elapsed = a.elapsed + dt
  if a.waiting then   -- the server's go has not come yet (it stays silent while its short cooldown runs)
    if a.elapsed > 5 then inspectAct = nil end
    return
  end
  local car = objOf(a.id)
  if not (car and pos) or T.dist(pos, a.startPos) > CANCEL_MOVE then
    inspectAct = nil
    return toast("warning", "You walked away.", 2500)
  end
  local shown = math.floor(a.elapsed)
  if shown > a.lastShown and not a.finishing then
    a.lastShown = shown
    toast("info", string.format("Looking the car over... %d / %d s", math.min(shown, a.seconds), a.seconds), 1100)
  end
  if a.elapsed >= a.seconds and not a.finishing then
    a.finishing = true
    net.send("rlsmpTheftInspectFinish", {})
  end
end

function M.onUpdate(dtReal)
  local dt = dtReal or 0
  clock = clock + dt
  if pendingEnter and clock >= pendingEnter.at then enterNow() end
  if not active() then return end
  local _, pos = walker()
  if action then return runAction(dt, pos) end
  if inspectAct then return runInspect(dt, pos) end
  scanTimer = scanTimer + dt
  if scanTimer < SCAN_EVERY then return end
  scanTimer = 0
  if not pos then target = nil return end
  -- Why can nobody find a car to steal? Log what exists around a walking player, at most every 30 s (parked cars are few in RLS).
  if clock - lastCensus >= 30 then
    lastCensus = clock
    local total, near, nearest = 0, 0, math.huge
    for _, pid in ipairs(parkedIds()) do
      local d = T.dist(pos, posOf(objOf(pid)))
      total = total + 1
      if d <= 60 then near = near + 1 end
      if d < nearest then nearest = d end
    end
    say("I", string.format("parked cars known: %d, within 60 m: %d, nearest: %s m, stealable share: %s/1000", total, near,
      nearest == math.huge and "none" or tostring(math.floor(nearest)), tostring(cfg.perMille)))
  end
  scanHints(pos)
  local id = M.nearestStealable(pos)
  if not id then target = nil return end
  if target and target.id == id then
    -- the server answers at most once a second: ask again when no answer came
    if target.can == nil and clock - target.asked > 3 then
      target.asked = clock
      net.send("rlsmpTheftCheck", {id = id, sid = mp.sidOf(id), value = target.info.value, year = target.info.year})
    end
    return
  end
  local info = M.carInfo(objOf(id))
  if not info then return end
  target = {id = id, info = info, asked = clock}
  say("I", string.format("stealable car %s nearby: model %s config %s value %s year %s plate %s", tostring(id), tostring(info.model),
    tostring(info.configKey), tostring(info.value), tostring(info.year), tostring(plateOf(objOf(id)))))
  net.send("rlsmpTheftCheck", {id = id, sid = mp.sidOf(id), value = info.value, year = info.year})
end

-- Messages from the server ---------------------------------------------------------------------------

local function onConfig(d)
  local was = cfg and cfg.period
  cfg = {enabled = d.enabled == true, seed = tonumber(d.seed) or 0, period = tonumber(d.period) or 0,
    perMille = tonumber(d.perMille) or 0, periodSeconds = tonumber(d.periodSeconds) or 3600, radius = tonumber(d.radius) or 3,
    inspect = type(d.inspect) == "table" and {enabled = d.inspect.enabled == true, range = tonumber(d.inspect.range) or 15} or nil}
  if was ~= cfg.period then spots, target, hintAsked, hinted, toldKey = {}, nil, {}, {}, {} end
  if not cfg.enabled then
    -- switched off from the menu: drop the prompt, and stop a steal that is running (the server refuses the finish anyway)
    if action then net.send("rlsmpTheftCancel", {}) toast("warning", "Car theft was switched off.") end
    target, action, inspectAct = nil, nil, nil
  end
  say("I", string.format("config: enabled=%s period=%s perMille=%s", tostring(cfg.enabled), tostring(cfg.period), tostring(cfg.perMille)))
end

local function onCan(d)
  if not (target and d.id == target.id) then return end
  target.can = d.ok == true
  if not target.can then return end
  target.method, target.label, target.seconds = d.method, d.label, d.seconds
  target.methods = type(d.methods) == "table" and d.methods or {{method = d.method, label = d.label, seconds = d.seconds}}
  local c = spots[target.id]
  if c and toldKey[target.id] == c.key then return end
  if c then toldKey[target.id] = c.key end
  toast("info", string.format("This car could be yours. Press [%s] to steal or look it over.", keyName()), 6000)
end

local function onHint(d)
  if not (active() and d.ok == true and d.id) then return end
  local c = spots[d.id]
  if not c or hinted[d.id] == c.key then return end
  hinted[d.id] = c.key
  toast("info", string.format("A parked car nearby may be an easy mark. Press [%s] to look closer.", keyName()), 5000)
end

-- Inspect: the parked car the popup was opened for (or the nearest one within range), whatever it is.
local function startInspect(carId)
  local I = active() and cfg.inspect
  if not (I and I.enabled) then return end
  if action or inspectAct then return toast("warning", "You are already busy.", 2500) end
  local o, pos = walker()
  if not pos then return toast("warning", "Get out of your car first.", 3000) end
  local c
  for _, k in ipairs(parkedNear(pos, I.range)) do
    if carId == nil or k.id == carId then c = k break end
  end
  if not c or not ownCar(c.id) then return toast("info", "No parked car close enough to look at.", 3000) end
  local info = M.carInfo(objOf(c.id)) or {}
  if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
  inspectAct = {id = c.id, seconds = 0, elapsed = 0, startPos = pos, lastShown = -1, finishing = false, waiting = true}
  net.send("rlsmpTheftInspect", {id = c.id, sid = mp.sidOf(c.id), x = c.pos.x, y = c.pos.y, z = c.pos.z, value = info.value or 0, year = info.year})
end

local function onInspectAsk() startInspect(nil) end   -- the server's developer chat fallback

local function onInspectGo(d)
  if not inspectAct then return end
  if not d.ok then inspectAct = nil return end
  inspectAct.seconds, inspectAct.waiting, inspectAct.elapsed = tonumber(d.seconds) or 3, nil, 0
end

local function onInspected(d)
  inspectAct = nil
  toast(d.found and "warning" or "info", tostring(d.text or ""):sub(1, 400), d.found and 14000 or 4000)
end

local function startSteal(method)
  if not active() then return end
  if action then return toast("warning", "You are already at it.") end
  if inspectAct then return toast("warning", "You are already busy.", 2500) end
  local _, pos = walker()
  if not pos then return toast("warning", "Get out of your car first.") end
  if not (target and target.can and objOf(target.id) and ownCar(target.id) and T.dist(pos, posOf(objOf(target.id))) <= radius() + 0.5) then
    return toast("warning", "There is no car you can steal right here.")
  end
  target.startPos = pos
  net.send("rlsmpTheftStart", {sid = mp.sidOf(target.id), method = method or target.method, value = target.info.value, year = target.info.year})
end

local function onSteal(d)   -- the server's developer chat fallback
  if d.stop then
    if action then action = nil toast("info", "Stopped.") end
    return
  end
  startSteal(d.method)
end

-- The interact key (input action rlsmpInteract) ----------------------------------------------------------
local function button(label, act)
  -- `act` is checked again in M.choose, so building Lua text from it is safe.
  return {label = label, luaCallback = string.format("rlsmp_theft.choose(%q)", act), enabled = true}
end

function M.interact()
  if not active() then return end
  if action or inspectAct then return toast("warning", "You are already busy.", 2500) end
  local _, pos = walker()
  if not pos then return toast("warning", "Get out of your car first.", 3000) end
  local I = cfg.inspect
  local c = parkedNear(pos, (I and I.range) or radius())[1]
  if not c then return toast("info", "No parked car close enough.", 3000) end
  local buttons = {}
  if I and I.enabled then buttons[#buttons + 1] = button("Inspect", "inspect") end
  local t = target
  if t and t.id == c.id and t.can and t.methods and T.dist(pos, c.pos) <= radius() + 0.5 then
    for _, m in ipairs(t.methods) do
      if type(m.method) == "string" and m.method:match("^[%a_]+$") then
        buttons[#buttons + 1] = button(string.format("Steal: %s (%s s)", tostring(m.label or m.method), tostring(m.seconds or "?")), "steal:" .. m.method)
      end
    end
  end
  if #buttons == 0 then return toast("info", "Nothing to do with this car.", 3000) end
  buttons[#buttons + 1] = {label = "Cancel", luaCallback = "", enabled = true}
  if not ownCar(c.id) then return toast("info", "No parked car close enough.", 3000) end
  popupCar = c.id
  local info = M.carInfo(objOf(c.id))
  if guihooks then
    guihooks.trigger("showConfirmationDialog", {text = "Parked car" .. (info and info.model and (": " .. tostring(info.model)) or ""), buttons = buttons, class = "recoveryPrompt"})
  end
  say("I", "popup for car " .. tostring(c.id) .. " with " .. #buttons .. " buttons")
end

-- Called by a popup button. Only our own fixed words are accepted.
function M.choose(act)
  if type(act) ~= "string" or not active() then return end
  if act == "inspect" then return startInspect(popupCar) end
  local method = act:match("^steal:([%a_]+)$")
  if method then return startSteal(method) end
end

local function onGo(d)
  if not d.ok then return toast("warning", tostring(d.err or "You can't do that.")) end
  if not target or not target.startPos then return net.send("rlsmpTheftCancel", {}) end
  action = {id = target.id, info = target.info, method = d.method, label = d.label, seconds = tonumber(d.seconds) or 10,
    noise = tonumber(d.noise) or 0, elapsed = 0, startPos = target.startPos, lastShown = -1, finishing = false}
  say("I", string.format("start %s on %s (%ss, noise %s)", tostring(d.method), tostring(target.id), tostring(d.seconds), tostring(d.noise)))
end

local function onResult(d)
  local a = action
  action = nil
  if not a then return end
  if not d.ok then return toast("warning", tostring(d.err or "It did not work.")) end
  target = nil
  if not ownCar(a.id) then return toast("warning", "That car is not yours to take.") end
  local veh, snap = M.convertParked(a.id)
  if not veh then return toast("error", "The car could not be taken (" .. tostring(snap) .. ").") end
  net.send("rlsmpTheftDone", {plate = snap.licenseText, model = snap.model, color = snap.color, value = snap.value, year = snap.year,
    valueSource = snap.source, config = snap.config, look = snap.look, rot = snap.rotT,
    x = snap.at.x, y = snap.at.y, z = snap.at.z, witnesses = M.witnesses(snap.at)})
end

local function onReported(d)
  for _, rec in pairs(stolen) do
    if rec.plate ~= nil and T.cleanPlate(tostring(rec.plate)) == d.plate then rec.reported = true end
  end
  say("I", "reported stolen: " .. tostring(d.plate))
end

-- The fence (server/fence.lua) ------------------------------------------------------------------------
-- The Black Market app (M.fence) or the server (developer chat) starts a sale: rlsmpFenceAsk. The player must be on foot next to one of the stolen cars; we name it by its plate.
-- The server checks everything (spot, papers, ownership, money). Only when its answer says takeCar do we delete the car.
local FENCE_REACH = 8       -- metres from the player to the car
local fenceCarId

function M.nearestStolen(pos, reach)
  local best, bestD
  for _, rec in ipairs(M.stolenCars()) do
    local d = T.dist(pos, posOf(objOf(rec.vehId)))
    if d <= reach and (not bestD or d < bestD) then best, bestD = rec, d end
  end
  return best
end

-- For the garage computer (rlsmp/garage.lua): the stolen car nearest to the player within `reach` metres (nil if none), and removal by plate.
function M.nearestStolenToPlayer(reach)
  local id = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local p = posOf(objOf(id))
  return p and M.nearestStolen(p, reach) or nil
end

function M.removeStolenByPlate(plate)
  for id, rec in pairs(stolen) do
    if rec.plate == plate then
      local o = objOf(id)
      stolen[id] = nil
      T.forget(id)
      if o then o:delete() end
      return true
    end
  end
  return false
end

local function onFenceAsk(d)
  if not active() then return end
  if type(d) ~= "table" or type(d.mode) ~= "string" then return end
  local _, pos = walker()
  if not pos then return toast("warning", "Get out of the car and stand next to it first.", 5000) end
  local rec = M.nearestStolen(pos, FENCE_REACH)
  if not rec or not rec.plate then return toast("warning", "Stand next to the stolen car you want to sell.", 5000) end
  fenceCarId = rec.vehId
  if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end   -- the server wants a fresh position for the drop spot check
  say("I", string.format("fence %s: car %s plate %s", tostring(d.mode), tostring(rec.vehId), tostring(rec.plate)))
  net.send("rlsmpFenceSell", {plate = rec.plate, mode = d.mode})
end

-- The Black Market phone app button (rlsmp_market.uiAct "fence"): same as the server's ask, started here. Mode is one of our fixed words.
function M.fence(mode)
  if mode == "strip" or mode == "sell" or mode == "resell" then onFenceAsk({mode = mode}) end
end

local function onFenceResult(d)
  local id = fenceCarId
  fenceCarId = nil
  if d.takeCar and id then
    local o = objOf(id)
    stolen[id] = nil
    T.forget(id)
    if o then o:delete() end
  end
  if d.ok then
    toast("success", string.format("Sold: $%d.", math.floor(tonumber(d.pay) or 0)), 6000)
  elseif d.busted then
    toast("error", tostring(d.err or "It was a trap."), 8000)
  else
    toast("warning", tostring(d.err or "The fence said no."), 6000)
  end
  say("I", string.format("fence result: ok=%s mode=%s pay=%s busted=%s", tostring(d.ok), tostring(d.mode), tostring(d.pay), tostring(d.busted)))
end

function M.onVehicleDestroyed(id)
  refusedLogged[id] = nil
  T.forget(id)
  stolen[id] = nil
  spots[id] = nil
end

function M.onServerLeave()
  cfg, target, action, inspectAct, pendingEnter = nil, nil, nil, nil, nil
  spots, stolen, hintAsked, hinted, toldKey, popupCar = {}, {}, {}, {}, {}, nil
  fakePlates = {}
  T.clearConverted()
end

function M.onExtensionLoaded()
  net.on("rlsmpTheftConfig", onConfig)
  net.on("rlsmpTheftCan", onCan)
  net.on("rlsmpTheftSteal", onSteal)
  net.on("rlsmpTheftHint", onHint)
  net.on("rlsmpTheftInspectAsk", onInspectAsk)
  net.on("rlsmpTheftInspectGo", onInspectGo)
  net.on("rlsmpTheftInspected", onInspected)
  net.on("rlsmpTheftGo", onGo)
  net.on("rlsmpTheftResult", onResult)
  net.on("rlsmpTheftReported", onReported)
  net.on("rlsmpTheftReprice", onReprice)
  net.on("rlsmpFenceAsk", onFenceAsk)
  net.on("rlsmpFenceResult", onFenceResult)
end

M._target = function() return target end
M._action = function() return action end
M._inspect = function() return inspectAct end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
