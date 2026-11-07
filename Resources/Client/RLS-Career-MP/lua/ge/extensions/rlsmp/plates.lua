-- RLS-Career-MP client extension "rlsmp_plates": police read your plate, the server keeps the records.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every 0.5 s, while the career runs in a multiplayer session and the server said the feature is on:
--  * an AI police unit that RLS already tracks you with (role.validTargets[myCar] visible, within
--    rangeMeters) while you drive under maxSpeedKmh may read your plate. A unit decides once per
--    encounter whether it bothers (readChance, afterEscapeChance shortly after you escaped a chase).
--    A read takes minSeconds..maxSeconds (random per read) and shows "Police reading your plate: 7AB____".
--    Leaving its range or speeding up resets it.
--  * a finished read asks the server (rlsmpPlateLookup). A flagged plate, or a remembered car description
--    (model + colour), starts an RLS chase at once (offense "wantedPlate", RLS's own pursuit code),
--    unless the unit lets it go (skipChance) or we started one for that plate within retriggerSeconds.
--  * escaping a chase (RLS hook onPursuitAction "evade") reports the car (rlsmpPlateEscaped): the server flags it.
--  * a new plate text or paint colour on one of your garage cars is reported (rlsmpPlateChanged): it clears
--    the plate flag / the description at once.
-- Only the local player's car; never while you are chased, on foot, a passenger, or playing as a cop.
-- Pure rules: lib/plateRead.lua. Tests: tests/plate_read_lib_test.lua, tests/plates_client_test.lua.
-- UNVERIFIED IN-GAME: everything about RLS's police data shape and pursuit start comes from reading RLS source.

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local R = require("rlsmp/lib/plateRead")

local STEP = 0.5              -- seconds between checks
local LOOKUP_TIMEOUT = 10     -- seconds to wait for the server's answer
local FALLBACK_AFTER = 1.5    -- seconds after triggerOffense before we start the chase ourselves
local UI_CATEGORY = "rlsmpPlateRead"

local enabled = false         -- core.lua: career active on the server
local config                  -- nil until the server speaks (lib sanitizeConfig)
local now, timer = 0, 0
local reader = R.newReader()
local cooldowns = {}          -- plate key -> time before which no new chase starts for it
local pending                 -- {key, plate, model, color, copId, playerId, t}: lookup on the way
local fallback                -- {t, playerId, copId, stage}: make sure the chase really started
local escapedUntil = 0        -- reads are likelier until then
local seen = {}               -- garage inventory id -> {plate, model, color}
local readPlate               -- plate shown in the progress message
local rnd = math.random

local function isMP() return mp.isMPSession() end
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function active()
  return enabled and config ~= nil and config.enabled and isMP() and careerActive()
end

local function show(text, ttl)
  if type(ui_message) == "function" then pcall(ui_message, text, ttl or 2, UI_CATEGORY, "info") end
end

local function trafficData()
  return gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
end

local function playerIsCop()
  local pd = overhaul_career_police_playerDriving
  if not pd or type(pd.getPlayerIsCop) ~= "function" then return false end
  local ok, cop = pcall(pd.getPlayerIsCop)
  return ok and cop == true
end

local function objectActive(id)
  if be and be.getObjectActive then
    local ok, on = pcall(be.getObjectActive, be, id)
    if ok then return on ~= false end
  end
  return true
end

local function inventoryId(vehId)
  local inv = overhaul_career_garage_inventory
  if not inv or type(inv.getInventoryIdFromVehicleId) ~= "function" then return nil end
  local ok, id = pcall(inv.getInventoryIdFromVehicleId, vehId)
  return ok and id or nil
end

-- sRGB 0..1 of the car's main paint: spawn config first (career/police/policeTasklist.lua reads the same),
-- then the live object colour (linear, x/y/z). nil if neither is readable.
local function paintRGB(vehId, obj)
  local ok, rgb = pcall(function()
    local vm = core_vehicle_manager and core_vehicle_manager.getVehicleData and core_vehicle_manager.getVehicleData(vehId)
    local paints = vm and type(vm.config) == "table" and vm.config.paints
    local base = type(paints) == "table" and type(paints[1]) == "table" and paints[1].baseColor
    if type(base) == "table" and tonumber(base[1]) and tonumber(base[2]) and tonumber(base[3]) then
      return {base[1], base[2], base[3]}
    end
    local c = obj and obj.color
    if c and tonumber(c.x) and tonumber(c.y) and tonumber(c.z) then
      return {R.srgbFromLinear(c.x), R.srgbFromLinear(c.y), R.srgbFromLinear(c.z)}
    end
    return nil
  end)
  return ok and rgb or nil
end

-- {plate, model, color} of a car (color may be nil). nil when there is no object or no plate text.
local function carInfo(vehId)
  local obj = getObjectByID and getObjectByID(vehId)
  if not obj then return nil end
  local plate
  if core_vehicles and core_vehicles.getVehicleLicenseText then
    local ok, text = pcall(core_vehicles.getVehicleLicenseText, obj)
    if ok then plate = text end
  end
  if (plate == nil or plate == "") and obj.getDynDataFieldbyName then
    local ok, text = pcall(obj.getDynDataFieldbyName, obj, "licenseText", 0)
    if ok then plate = text end
  end
  plate = R.cleanPlate(plate)        -- "" while RLS refreshes the plate: no info
  local model = obj.jbeam or obj.JBeam
  if not plate or type(model) ~= "string" or model == "" then return nil end
  local rgb = paintRGB(vehId, obj)
  return {plate = plate, model = model, color = rgb and R.colorName(rgb[1], rgb[2], rgb[3]) or nil}
end

local function inPursuit(veh)
  if rlsmp_police and rlsmp_police.isPursuit and rlsmp_police.isPursuit() == true then return true end
  if type(veh.pursuit) == "table" and (tonumber(veh.pursuit.mode) or 0) ~= 0 then return true end
  return type(veh.queuedFuncs) == "table" and veh.queuedFuncs.pursuitStart ~= nil
end

local function cancelRead(why)
  if reader.cop then
    p3.log("I", "plates: read by police id=" .. tostring(reader.cop) .. " reset (" .. why .. ")")
    reader.cop, reader.got, reader.need = nil, 0, 0
    show("Plate read interrupted", 1.5)
  end
  readPlate = nil
end

-- RLS police: setPursuitMode(level, vehId, policeIds) (integration/services/police.lua), vanilla forwards to it.
local function setPursuitMode(level, targetId, copId)
  local svc = overhaul_integration_services_police
  local fn = svc and svc.setPursuitMode
  if type(fn) ~= "function" and gameplay_police and type(gameplay_police.setPursuitMode) == "function" then
    fn = gameplay_police.setPursuitMode
  end
  if type(fn) ~= "function" then return false end
  local ok, problem = pcall(fn, level, targetId, copId)
  if not ok then p3.log("W", "plates: setPursuitMode failed: " .. tostring(problem)) end
  return ok
end

-- UNVERIFIED IN-GAME. Start an RLS chase on the player's car: an offense with a high score (RLS scales it by
-- offenseScoreScale 0.75; the first pursuit level needs 150), RLS then queues pursuitStart with the nearest unit.
-- If that has not happened after FALLBACK_AFTER seconds we call setPursuitMode(1, car, unit) ourselves.
function M.startChase(playerId, copId, plate)
  local veh = trafficData()[playerId]
  if not veh then return false end
  local offense = false
  if type(veh.triggerOffense) == "function" then
    local ok, problem = pcall(veh.triggerOffense, veh, {key = R.OFFENSE_KEY, value = plate, score = config.offenseScore})
    offense = ok
    if not ok then p3.log("W", "plates: triggerOffense failed: " .. tostring(problem)) end
  end
  fallback = {t = now + FALLBACK_AFTER, playerId = playerId, copId = copId, stage = 1}
  p3.count(offense and "plates: chases via offense" or "plates: chases via setPursuitMode")
  return true
end

local function chaseStarted(veh)
  return veh and ((type(veh.pursuit) == "table" and (tonumber(veh.pursuit.mode) or 0) ~= 0)
    or (type(veh.queuedFuncs) == "table" and veh.queuedFuncs.pursuitStart ~= nil))
end

local function checkFallback(traffic)
  if not fallback or now < fallback.t then return end
  local veh = traffic[fallback.playerId]
  if chaseStarted(veh) then
    p3.log("I", "plates: chase running (stage " .. fallback.stage .. ")")
    fallback = nil
  elseif fallback.stage == 1 and veh then
    local called = setPursuitMode(1, fallback.playerId, fallback.copId)
    p3.log("I", "plates: offense did not start a chase, setPursuitMode(1) " .. (called and "called" or "NOT available"))
    fallback.stage, fallback.t = 2, now + FALLBACK_AFTER
  else
    p3.count("plates: chase did not start")
    p3.log("W", "plates: the chase did not start (RLS ignores this car for pursuits?)")
    fallback = nil
  end
end

-- Plate text or paint of a garage car changed (paint jobs respawn the car, so we key by inventory id).
local function watchCar(playerId)
  local inv = inventoryId(playerId)
  if inv == nil then return end
  local info = carInfo(playerId)
  if not info then return end
  local prev = seen[inv]
  seen[inv] = info
  if not prev or prev.model ~= info.model then return end
  local plateChanged = prev.plate ~= info.plate
  local colorChanged = prev.color ~= nil and info.color ~= nil and prev.color ~= info.color
  if not plateChanged and not colorChanged then return end
  net.send("rlsmpPlateChanged", {model = info.model, oldPlate = prev.plate, plate = info.plate,
    oldColor = prev.color, color = info.color})
  p3.log("I", string.format("plates: garage car %s changed plate %s->%s colour %s->%s", tostring(inv),
    prev.plate, info.plate, tostring(prev.color), tostring(info.color)))
  -- Our own chase cooldown belongs to the old plate; the new one starts clean.
  if plateChanged then cooldowns[R.key(prev.plate, info.model)] = nil end
end

local function step()
  if not active() then
    cancelRead("inactive")
    pending, fallback = nil, nil
    return
  end
  local playerId = be and be:getPlayerVehicleID(0)
  local traffic = trafficData()
  checkFallback(traffic)
  if pending and now - pending.t > LOOKUP_TIMEOUT then
    p3.log("W", "plates: no answer for plate lookup, dropped")
    pending = nil
  end
  if not playerId or playerId < 0 then return cancelRead("no car") end
  watchCar(playerId)
  local veh = traffic[playerId]
  if type(veh) ~= "table" then return cancelRead("car not in traffic data") end
  if veh.isAi == true then return cancelRead("passenger") end
  if pending or fallback then return end
  if playerIsCop() then return cancelRead("player is a cop") end
  if inPursuit(veh) then return cancelRead("pursuit") end
  R.prune(reader, now)

  local cand
  local speed = tonumber(veh.speed) or 0
  if speed <= config.maxSpeedKmh / 3.6 then
    local copId = R.nearestReader(traffic, playerId, config.rangeMeters * config.rangeMeters, objectActive)
    if copId then cand = {copId = copId, recentEscape = now < escapedUntil} end
  end
  local wasCop = reader.cop
  local status, x = R.update(reader, now, STEP, cand, config, rnd)
  if status == "reset" then
    p3.log("I", "plates: read by police id=" .. tostring(wasCop) .. " reset (" .. (speed > config.maxSpeedKmh / 3.6 and "too fast" or "out of range") .. ")")
    show("Plate read interrupted", 1.5)
    readPlate = nil
  elseif status == "reading" then
    if x == 0 then
      local info = carInfo(playerId)
      if not info then
        reader.cop, reader.need, reader.got = nil, 0, 0
        return
      end
      readPlate = info.plate
      p3.count("plates: reads started")
      p3.log("I", string.format("plates: police id=%s reading plate (%.1fs)", tostring(reader.cop), reader.need))
    end
    show("Police reading your plate: " .. R.mask(readPlate, x), 2)
  elseif status == "done" then
    local info = carInfo(playerId)
    readPlate = nil
    if not info then return end
    show("Police read your plate: " .. info.plate, 3)
    p3.count("plates: reads finished")
    pending = {key = R.key(info.plate, info.model), plate = info.plate, model = info.model, color = info.color,
      copId = x, playerId = playerId, t = now}
    net.send("rlsmpPlateLookup", {plate = info.plate, model = info.model, color = info.color})
  end
end

local function onResult(data)
  local p = pending
  if not p or R.cleanPlate(data.plate) ~= p.plate or data.model ~= p.model then return end
  pending = nil
  if not active() then return end
  local veh = trafficData()[p.playerId]
  if not veh or (be and be:getPlayerVehicleID(0) ~= p.playerId) or inPursuit(veh) then return end
  local go, why = R.decideChase(data.flagged == true, cooldowns, p.key, now, config, rnd)
  p3.log("I", string.format("plates: lookup %s flagged=%s matchedBy=%s reason=%s -> %s", p.plate, tostring(data.flagged),
    tostring(data.matchedBy), tostring(data.reason), go and "CHASE" or why))
  if go then
    p3.count("plates: chases started")
    M.startChase(p.playerId, p.copId, p.plate)
  elseif why == "skipped" then
    p3.count("plates: flagged but let go")
  end
end

-- RLS hook (extensions.hook from police.lua evadeVehicle / trafficVehicle onPursuitUpdate).
function M.onPursuitAction(vehId, action, data)
  if action ~= "evade" or not active() or not be then return end
  local playerId = be:getPlayerVehicleID(0)
  local svc = overhaul_integration_services_police
  local handoff = svc and type(svc.getWalkHandoffVehId) == "function" and svc.getWalkHandoffVehId() or nil
  if vehId ~= playerId and vehId ~= handoff then return end
  if playerIsCop() then return end
  if R.isStalemate(data) then
    p3.log("I", "plates: pursuit ended as a stalemate (not an escape), nothing reported")
    return
  end
  local info = carInfo(vehId)
  if not info then
    p3.log("W", "plates: escaped, but the car's plate could not be read")
    return
  end
  escapedUntil = now + config.afterEscapeSeconds
  cooldowns[R.key(info.plate, info.model)] = now + config.retriggerSeconds
  net.send("rlsmpPlateEscaped", {plate = info.plate, model = info.model, color = info.color})
  p3.count("plates: escapes reported")
  p3.log("I", string.format("plates: escaped in %s %s (%s), reported", info.model, info.plate, tostring(info.color)))
end

function M.onUpdate(dtReal, dtSim)
  local dt = tonumber(dtSim) or tonumber(dtReal) or 0
  now = now + dt
  timer = timer + dt
  if timer < STEP then return end
  timer = 0
  step()
end

-- core.lua: career active on the server (true) / closed or left (false).
function M.enable(on)
  enabled = on == true
  if not enabled then
    cancelRead("disabled")
    pending, fallback = nil, nil
  end
end

local function onConfig(data)
  config = R.sanitizeConfig(data)
  p3.log("I", string.format("plates: config received enabled=%s range=%sm speed<%skm/h read %s-%ss chance=%s skip=%s",
    tostring(config.enabled), config.rangeMeters, config.maxSpeedKmh, config.minSeconds, config.maxSeconds,
    config.readChance, config.skipChance))
  if not config.enabled then cancelRead("turned off") end
end

function M.onServerLeave()
  cancelRead("left")
  config, enabled, pending, fallback = nil, false, nil, nil
  now, timer, escapedUntil = 0, 0, 0
  reader, cooldowns, seen = R.newReader(), {}, {}
end

function M.getConfig() return config end
function M.getReader() return reader end

function M.onExtensionLoaded()
  net.on("rlsmpPlateConfig", onConfig)
  net.on("rlsmpPlateResult", onResult)
  p3.log("I", "rlsmp_plates loaded")
  p3.probe("plates: core_vehicles.getVehicleLicenseText is a function",
    core_vehicles ~= nil and type(core_vehicles.getVehicleLicenseText) == "function")
end

-- Test hooks.
M._onConfig = onConfig
M._onResult = onResult
M._step = step
M._setRandom = function(fn) rnd = fn or math.random end
M._now = function() return now end
M._pending = function() return pending end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
