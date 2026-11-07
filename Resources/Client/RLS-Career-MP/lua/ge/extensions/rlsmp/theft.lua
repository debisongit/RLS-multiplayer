-- RLS-Career-MP client extension "rlsmp_theft": steal a parked car (off unless the server turns it on: rlsmpTheftConfig).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- 1. The server sends a seed per period. A parked car of THIS game is stealable when lib/theft.stealable(seed, period, perMille,
--    position) says so (the same in every game for the same spot).
-- 2. Walking up to a stealable car (within `radius` m) asks the server whether we own a method that works on it
--    (rlsmpTheftCheck {id, value, year}); only a yes shows the prompt ("type /steal").
-- 3. /steal (chat; the server sends rlsmpTheftSteal) asks to start (rlsmpTheftStart). rlsmpTheftGo gives the time and noise.
--    A toast shows progress every second; walking away cancels (rlsmpTheftCancel). Noise raises a local flag (M.noise()).
-- 4. When the time is up we ask for the result (rlsmpTheftFinish): the server rolls the failure chance and uses up papers.
-- 5. Success: the parked car is turned into a normal driveable car the way docs/RESEARCH_PLATES_THEFT.md describes (snapshot,
--    delete the parked object, core_vehicles.spawnNewVehicle with RLS's own parked-car spawn options, ignoreParking, never
--    isParked, simple_traffic mapped to the real model, off the walk blacklist), vehicleGuard is told this id is ours to enter,
--    the player gets in, and the server hears about it (rlsmpTheftDone) and decides when it is reported.
-- The car is NOT put in the garage inventory (selling and stripping come later): M.stolenCars() lists them for that step.
-- rlsmpTheftReported needs nothing here: the police find the car by its plate (plate reading).
-- Untested in-game. Log tag RLSMP-THEFT.

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local T = require("rlsmp/lib/theft")

local TAG = "RLSMP-THEFT"
local SCAN_EVERY = 0.5
local NOISE_SECONDS = 30
local CANCEL_MOVE = 2.0       -- metres the player may move away from where they started
local WITNESS_TRAFFIC = 50    -- metres: AI traffic that can see you
local WITNESS_PLAYERS = 80    -- metres: other players' cars and walkers

local enabled = false
local cfg                      -- last rlsmpTheftConfig
local clock, scanTimer = 0, 0
local spots = {}               -- vehicle id -> {key, stealable}
local target                   -- {id, key, info, can, method, label, seconds, asked}
local action                   -- {id, info, method, seconds, elapsed, startPos, noise, lastShown, finishing}
local pendingEnter             -- {id, at}
local stolen = {}              -- new vehicle id -> {vehId, plate, model, config, color, value, year, t, reported}
local noiseLevel, noiseUntil = 0, -1

local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Car theft", msg = msg, config = {timeOut = ms or 4000}}) end
end
local function say(level, msg) log(level, TAG, msg) end

function M.enable(on)
  enabled = on == true
  if not enabled then target, action, pendingEnter = nil, nil, nil end
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

local function parkedIds()
  if not (gameplay_parking and gameplay_parking.getParkedCarsList) then return {} end
  return gameplay_parking.getParkedCarsList(true) or {}
end

-- Is this parked car one of the stealable ones? Cached per spot (RLS moves pool cars to other spots).
function M.isStealable(id)
  if not active() then return false end
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

-- Model, config, value and year of a parked car (value = RLS's base price of the config, year = first year of the config).
function M.carInfo(o)
  local model, config, key = T.realModel(jbeamOf(o), o.partConfig)
  if not model then return nil end
  local value, year
  if core_vehicles and core_vehicles.getConfig and key then
    local ok, info = pcall(core_vehicles.getConfig, model, key)
    if ok and type(info) == "table" then
      value = tonumber(info.Value)
      local years = info.Years or (info.aggregates and info.aggregates.Years)
      year = type(years) == "table" and tonumber(years.min) or nil
      -- a simplified car whose name matched a real config: spawn that config
      if not config then config = "vehicles/" .. model .. "/" .. key .. ".pc" end
    end
  end
  return {model = model, config = config, configKey = key, value = value or 0, year = year}
end

local function plateOf(o)
  if o and o.getDynDataFieldbyName then
    local ok, text = pcall(o.getDynDataFieldbyName, o, "licenseText", 0)
    if ok and type(text) == "string" then return text end
  end
  return nil
end

local function colorOf(o)
  local c = o and o.color
  if c == nil then return nil end
  return T.colorName(c.x or c.r or c[1], c.y or c.g or c[2], c.z or c.b or c[3])
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

-- Turn a parked car into a normal car we can drive. Returns the new vehicle object and the snapshot, or nil + why.
-- Order matters: snapshot -> delete the parked car -> spawn -> ignoreParking / never isParked -> converted set -> off the
-- walk blacklist. Entering happens a moment later (M.onUpdate) so the new car is ready.
function M.convertParked(id)
  local o = objOf(id)
  if not o then return nil, "car gone" end
  local info = M.carInfo(o)
  if not info then return nil, "unknown model" end
  local metallic = o.getMetallicPaintData and o:getMetallicPaintData() or {}
  local function paint(c, m) if createVehiclePaint and c then return createVehiclePaint(c, m) end return nil end
  local p = o:getPosition()
  local snap = {
    model = info.model, config = info.config, value = info.value, year = info.year,
    pos = p, rot = quatFromDir and quatFromDir(vec3(o:getDirectionVector()), vec3(o:getDirectionVectorUp())) or nil,
    paint = paint(o.color, metallic[1]), paint2 = paint(o.colorPalette0, metallic[2]), paint3 = paint(o.colorPalette1, metallic[3]),
    licenseText = plateOf(o), color = colorOf(o), at = {x = p.x, y = p.y, z = p.z},
  }
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
  stolen[newId] = {vehId = newId, plate = snap.licenseText, model = snap.model, config = snap.config, color = snap.color,
    value = snap.value, year = snap.year, t = os.time(), reported = false}
  pendingEnter = {id = newId, at = clock + 0.5}
  return veh, snap
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
  noiseLevel, noiseUntil = math.max(noiseLevel, action.noise), clock + NOISE_SECONDS
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

function M.onUpdate(dtReal)
  local dt = dtReal or 0
  clock = clock + dt
  if pendingEnter and clock >= pendingEnter.at then enterNow() end
  if not active() then return end
  local _, pos = walker()
  if action then return runAction(dt, pos) end
  scanTimer = scanTimer + dt
  if scanTimer < SCAN_EVERY then return end
  scanTimer = 0
  if not pos then target = nil return end
  local id = M.nearestStealable(pos)
  if not id then target = nil return end
  if target and target.id == id then
    -- the server answers at most once a second: ask again when no answer came
    if target.can == nil and clock - target.asked > 3 then
      target.asked = clock
      net.send("rlsmpTheftCheck", {id = id, value = target.info.value, year = target.info.year})
    end
    return
  end
  local info = M.carInfo(objOf(id))
  if not info then return end
  target = {id = id, info = info, asked = clock}
  net.send("rlsmpTheftCheck", {id = id, value = info.value, year = info.year})
end

-- Messages from the server ---------------------------------------------------------------------------

local function onConfig(d)
  local was = cfg and cfg.period
  cfg = {enabled = d.enabled == true, seed = tonumber(d.seed) or 0, period = tonumber(d.period) or 0,
    perMille = tonumber(d.perMille) or 0, periodSeconds = tonumber(d.periodSeconds) or 3600, radius = tonumber(d.radius) or 3}
  if was ~= cfg.period then spots, target = {}, nil end
  say("I", string.format("config: enabled=%s period=%s perMille=%s", tostring(cfg.enabled), tostring(cfg.period), tostring(cfg.perMille)))
end

local function onCan(d)
  if not (target and d.id == target.id) then return end
  target.can = d.ok == true
  if not target.can then return end
  target.method, target.label, target.seconds = d.method, d.label, d.seconds
  toast("info", string.format("This car could be yours. Type /steal (%s, %s s).", tostring(d.label), tostring(d.seconds)), 6000)
end

local function onSteal(d)
  if not active() then return end
  if d.stop then
    if action then action = nil toast("info", "Stopped.") end
    return
  end
  if action then return toast("warning", "You are already at it.") end
  local _, pos = walker()
  if not pos then return toast("warning", "Get out of your car first.") end
  if not (target and target.can and objOf(target.id) and T.dist(pos, posOf(objOf(target.id))) <= radius() + 0.5) then
    return toast("warning", "There is no car you can steal right here.")
  end
  target.startPos = pos
  net.send("rlsmpTheftStart", {method = d.method or target.method, value = target.info.value, year = target.info.year})
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
  local veh, snap = M.convertParked(a.id)
  if not veh then return toast("error", "The car could not be taken (" .. tostring(snap) .. ").") end
  net.send("rlsmpTheftDone", {plate = snap.licenseText, model = snap.model, color = snap.color, value = snap.value, year = snap.year,
    x = snap.at.x, y = snap.at.y, z = snap.at.z, witnesses = M.witnesses(snap.at)})
end

local function onReported(d)
  for _, rec in pairs(stolen) do
    if rec.plate ~= nil and tostring(rec.plate):upper() == tostring(d.plate) then rec.reported = true end
  end
  say("I", "reported stolen: " .. tostring(d.plate))
end

function M.onVehicleDestroyed(id)
  T.forget(id)
  stolen[id] = nil
  spots[id] = nil
end

function M.onServerLeave()
  cfg, target, action, pendingEnter = nil, nil, nil, nil
  spots, stolen = {}, {}
  T.clearConverted()
end

function M.onExtensionLoaded()
  net.on("rlsmpTheftConfig", onConfig)
  net.on("rlsmpTheftCan", onCan)
  net.on("rlsmpTheftSteal", onSteal)
  net.on("rlsmpTheftGo", onGo)
  net.on("rlsmpTheftResult", onResult)
  net.on("rlsmpTheftReported", onReported)
end

M._target = function() return target end
M._action = function() return action end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
