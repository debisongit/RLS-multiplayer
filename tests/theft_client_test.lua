-- Car theft: client (LuaJIT) test with fake game globals. Run: luajit tests/theft_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logs = {}
function log(level, tag, msg) logs[#logs + 1] = tostring(msg) end
function setExtensionUnloadMode() end
local sent, handlers, toasts = {}, {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
local dialogs = {}
guihooks = {trigger = function(name, t) if name == "showConfirmationDialog" then dialogs[#dialogs + 1] = t else toasts[#toasts + 1] = t.msg end end}
vec3 = function(x, y, z) if type(x) == "table" then return x end return {x = x, y = y, z = z} end
quatFromDir = function() return {x = 0, y = 0, z = 0, w = 1} end
createVehiclePaint = function(c) return {baseColor = c} end

local order = {}   -- what happened, in order
local objects = {}
local nextId = 100
local function mkObj(id, jbeam, x, y, extra)
  local o = {id = id, jbeam = jbeam, pos = {x = x, y = y, z = 0}, dyn = {}}
  function o:getID() return self.id end
  function o:getPosition() return self.pos end
  function o:getDirectionVector() return {x = 0, y = 1, z = 0} end
  function o:getDirectionVectorUp() return {x = 0, y = 0, z = 1} end
  function o:getMetallicPaintData() return {} end
  function o:getDynDataFieldbyName(k) return self.dyn[k] end
  function o:setDynDataFieldbyName(k, _, v) self.dyn[k] = v order[#order + 1] = "dyn " .. k .. "=" .. v end
  function o:delete() order[#order + 1] = "delete " .. self.id objects[self.id] = nil end
  for k, v in pairs(extra or {}) do o[k] = v end
  objects[id] = o
  return o
end

local playerId = 1
local walkerObj = mkObj(1, "unicycle", 0, 0)
be = {getObjectByID = function(_, id) return objects[id] end, getPlayerVehicleID = function() return playerId end,
  enterVehicle = function(_, _, o) order[#order + 1] = "be.enter " .. o.id end}

local parked = {}
gameplay_parking = {getParkedCarsList = function() return parked end}
local trafficData = {}
gameplay_traffic = {getTrafficData = function() return trafficData end}
local blacklist = {}
gameplay_walk = {
  removeVehicleFromBlacklist = function(id) blacklist[id] = nil order[#order + 1] = "unblacklist " .. id end,
  isVehicleBlacklisted = function(id) return blacklist[id] == true end,
  getInVehicle = function(v) order[#order + 1] = "enter " .. v.id end,
  setWalkingMode = function() end,
}
local mpVehicles = {}
MPVehicleGE = {getVehicles = function() return mpVehicles end}
local configs = {
  ["covet|base"] = {Value = 6000, Years = {min = 1988, max = 1994}},
  ["etk800|854t"] = {Value = 40000, Years = {min = 2014, max = 2020}},
}
local spawned, valuationOpts
core_vehicles = {
  getConfig = function(model, key) return configs[model .. "|" .. tostring(key)] end,
  spawnNewVehicle = function(model, opts)
    nextId = nextId + 1
    order[#order + 1] = "spawn " .. model
    spawned = {model = model, opts = opts}
    return mkObj(nextId, model, opts.pos.x, opts.pos.y)
  end,
}

local T = require("rlsmp/lib/theft")
local net = require("rlsmp/lib/net")
net.init()
local theft = require("rlsmp/theft")
theft.onExtensionLoaded()
local guard = require("rlsmp/vehicleGuard")
guard.onExtensionLoaded()
guard.enable(true)

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, t) handlers[name](json.encode(t)) end
local function last(name) for i = #sent, 1, -1 do if sent[i].name == name then return sent[i].data end end end
local function count(name) local n = 0 for _, s in ipairs(sent) do if s.name == name then n = n + 1 end end return n end
local function step(n, dt) for _ = 1, n do theft.onUpdate(dt or 0.5) end end

-- 1. Consistent pick: pure, same answer for the same spot, about perMille of spots
local yes, total, same = 0, 4000, true
for i = 1, total do
  local pos = {x = (i % 97) * 9.3, y = math.floor(i / 97) * 7.1}
  local a = T.stealable(4242, 7, 150, pos)
  if a ~= T.stealable(4242, 7, 150, {x = pos.x + 0.3, y = pos.y + 0.2, z = 99}) and math.floor(pos.x / 4) == math.floor((pos.x + 0.3) / 4)
    and math.floor(pos.y / 4) == math.floor((pos.y + 0.2) / 4) then same = false end
  if a then yes = yes + 1 end
end
check(same, "same spot (small offsets inside the cell, any z), same answer")
check(yes > total * 0.11 and yes < total * 0.19, "about 15% of spots are stealable (" .. yes .. ")")
local diff = 0
for i = 1, 500 do if T.stealable(4242, 7, 150, {x = i * 8, y = 3}) ~= T.stealable(4242, 8, 150, {x = i * 8, y = 3}) then diff = diff + 1 end end
check(diff > 20, "another period picks other cars")
check(T.stealable(1, 1, 0, {x = 0, y = 0}) == false and T.stealable(1, 1, 1000, {x = 0, y = 0}) == true, "0 and 1000 per mille")
check(T.hash("a") == 0xE40C292C, "FNV-1a matches the reference value")
local r, c, k = T.realModel("simple_traffic", "vehicles/simple_traffic/etk800_854t.pc")
check(r == "etk800" and c == nil and k == "854t", "simplified car maps to the real model")
check(T.realModel("covet", "vehicles/covet/base.pc") == "covet", "a normal car keeps its model")
check(T.colorName(0.9, 0.05, 0.05) == "red" and T.colorName(1, 1, 1) == "white" and T.colorName(0.05, 0.1, 0.8) == "blue" and T.colorName(0.7, 0.7, 0.7) == "silver", "colour names (plateRead buckets)")
check(T.cleanPlate("  ab  12 ") == "AB 12" and T.cleanPlate("") == nil and T.cleanPlate("a|b") == nil, "plates cleaned like the server")

-- find a seed that makes car 10's spot stealable and car 11's not
local spotA, spotB = {x = 1.5, y = 1.0}, {x = 2.0, y = -1.5}
local seed
for s = 1, 100000 do
  if T.stealable(s, 3, 150, spotA) and not T.stealable(s, 3, 150, spotB) then seed = s break end
end
check(seed ~= nil, "found a seed for the test")
mkObj(10, "covet", spotA.x, spotA.y, {partConfig = "vehicles/covet/base.pc", color = {x = 0.9, y = 0.05, z = 0.05}, colorPalette0 = {x = 0, y = 0, z = 0}})
objects[10].dyn.licenseText = "CVT 42"
objects[10].dyn.isParked = "true"
mkObj(11, "etk800", spotB.x, spotB.y, {partConfig = "vehicles/etk800/854t.pc"})
parked = {10, 11}
blacklist[10], blacklist[11] = true, true

-- 2. Prompt only near a stealable car, only with items
theft.enable(true)
step(4)
check(count("rlsmpTheftCheck") == 0, "no config yet: nothing")
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
walkerObj.pos = {x = 50, y = 50, z = 0}
step(4)
check(count("rlsmpTheftCheck") == 0, "far away: no check")
walkerObj.pos = {x = 2.5, y = -1.5, z = 0}   -- next to car 11 (not stealable), 2.6 m from car 10 too
step(2)
local chk = last("rlsmpTheftCheck")
check(chk and chk.id == 10 and chk.value == 6000 and chk.year == 1988, "check asks about the stealable car only, with value and year")
check(theft.isStealable(11) == false, "car 11 is not stealable")
local nt = #toasts
server("rlsmpTheftCan", {ok = false, id = 10, err = "You need: Screwdriver"})
check(#toasts == nt, "no tools: no prompt")
step(2)
check(count("rlsmpTheftCheck") == 1, "asked once per car")
theft.onServerLeave()
theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
walkerObj.pos = {x = 1.5, y = 0, z = 0}
step(2)
server("rlsmpTheftCan", {ok = true, id = 10, method = "window_screwdriver", label = "Smash", seconds = 3})
check(toasts[#toasts]:find("Press %[Y%]") and not toasts[#toasts]:find("/"), "tools owned: key toast shown (no chat command)")
playerId = 10   -- (in a car: no prompt or check)
local before = count("rlsmpTheftCheck")
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
step(3)
check(count("rlsmpTheftCheck") == before, "not on foot: no check")
playerId = 1
step(2)
server("rlsmpTheftCan", {ok = true, id = 10, method = "window_screwdriver", label = "Smash", seconds = 3})

-- 3. The guard refuses the parked car before conversion
check(guard.isBlocked(10) == true, "parked car still blocked")

-- 4. the key opens a popup, a steal button starts it, progress, walk away cancels
server("rlsmpTheftCan", {ok = true, id = 10, method = "window_screwdriver", label = "Smash", seconds = 3,
  methods = {{method = "window_screwdriver", label = "Smash", seconds = 3}, {method = "other_way", label = "Quiet way", seconds = 9}}})
local nd = #dialogs
theft.interact()
local dlg = dialogs[#dialogs]
check(#dialogs == nd + 1 and #dlg.buttons == 3 and dlg.buttons[3].label == "Cancel",
  "interact: popup with one button per method and Cancel (inspect is off in this config)")
check(dlg.buttons[1].label:find("Smash") and dlg.buttons[1].label:find("3 s") and dlg.buttons[2].label:find("Quiet"), "interact: steal buttons name method and time")
check(dlg.buttons[1].luaCallback == 'rlsmp_theft.choose("steal:window_screwdriver")' and dlg.buttons[3].luaCallback == "", "interact: callbacks are our fixed words, Cancel does nothing")
theft.choose("steal:bad name;os.exit()")
check(count("rlsmpTheftStart") == 0, "choose: a bad word is ignored")
theft.choose("steal:window_screwdriver")
local st = last("rlsmpTheftStart")
check(st and st.method == "window_screwdriver" and st.value == 6000 and st.year == 1988, "start asked")
server("rlsmpTheftGo", {ok = true, method = "window_screwdriver", label = "Smash", seconds = 3, noise = 0.9})
step(2, 0.6)
check(theft.noise() == 0.9, "noise flag raised")
check(toasts[#toasts]:find("1 / 3"), "progress toast")
walkerObj.pos = {x = 6, y = 0, z = 0}
step(1)
check(last("rlsmpTheftCancel") and theft._action() == nil, "walked away: cancelled")
walkerObj.pos = {x = 1.5, y = 0, z = 0}
server("rlsmpTheftSteal", {})   -- the server's hidden developer fallback still works
server("rlsmpTheftGo", {ok = true, method = "window_screwdriver", label = "Smash", seconds = 3, noise = 0.9})
step(5, 0.5)
check(count("rlsmpTheftFinish") == 0, "not done before the time")
step(2, 0.5)
check(count("rlsmpTheftFinish") == 1, "finish asked when the time is up")
step(3, 0.5)
check(count("rlsmpTheftFinish") == 1, "asked once")

-- 5. Success: conversion order
order = {}
mpVehicles["1-3"] = {gameVehicleID = 300, isLocal = false}
mkObj(300, "pickup", 10, 10)   -- another player's car nearby: a witness
trafficData = {[400] = {isAi = true}}
mkObj(400, "covet", 30, 0)
server("rlsmpTheftResult", {ok = true})
local newId = nextId
check(order[1] == "delete 10" and order[2] == "spawn covet", "parked car deleted, then the full car spawned")
check(order[3] == "dyn isParked=false" and order[4] == "unblacklist " .. newId, "never parked, off the blacklist")
check(objects[newId].ignoreParking == true and objects[newId].playerUsable == true, "ignoreParking set")
check(spawned.opts.licenseText == "CVT 42" and spawned.opts.config == "vehicles/covet/base.pc" and spawned.opts.autoEnterVehicle == false
  and spawned.opts.paint.baseColor.x == 0.9 and spawned.opts.pos.x == spotA.x, "spawned with plate, config, paint, position")
local done = last("rlsmpTheftDone")
check(done and done.plate == "CVT 42" and done.model == "covet" and done.color == "red" and done.value == 6000 and done.year == 1988
  and done.x == spotA.x and done.witnesses == 2, "server told: plate, model, colour, value, year, position, witnesses")
check(#order == 4, "not entered yet")
theft.onUpdate(0.6)
check(order[5] == "enter " .. newId, "then the player gets in")

-- 6. Guard exception exactly for converted ids
check(guard.isBlocked(newId) == false, "the stolen car may be entered")
check(guard.isBlocked(11) == true, "other parked cars stay blocked")
check(guard.install() == true, "guard wraps the walking module")
check(gameplay_walk.isVehicleBlacklisted(newId) == false, "walk blacklist lets us in")
local cars = theft.stolenCars()
check(#cars == 1 and cars[1].vehId == newId and cars[1].plate == "CVT 42", "stolenCars lists it")
server("rlsmpTheftReported", {plate = "CVT 42"})
check(theft.stolenCars()[1].reported == true, "reported marked")
-- 6a. The phone's old "fence" button no longer knows gambling
local askedBefore = count("rlsmpFenceSell")
theft.fence("gamble")
check(count("rlsmpFenceSell") == askedBefore, "no gamble: a gamble request from the phone sends nothing")

-- 6b. The fence: /fence asks, the client names the stolen car next to the player, deletes it only when the server says so
local sentBefore = count("rlsmpFenceSell")
walkerObj.pos = {x = spotA.x + 100, y = spotA.y, z = 0}
server("rlsmpFenceAsk", {mode = "strip"})
check(count("rlsmpFenceSell") == sentBefore and toasts[#toasts]:find("Stand next to the stolen car"), "fence: nobody near a stolen car, nothing sent")
local reported = 0
rlsmp_positions = {reportNow = function() reported = reported + 1 end}
walkerObj.pos = {x = spotA.x + 3, y = spotA.y, z = 0}
playerId = newId
server("rlsmpFenceAsk", {mode = "strip"})
check(count("rlsmpFenceSell") == sentBefore and toasts[#toasts]:find("Get out"), "fence: must be on foot")
playerId = 1
server("rlsmpFenceAsk", {mode = "resell"})
local fs = last("rlsmpFenceSell")
check(count("rlsmpFenceSell") == sentBefore + 1 and fs.plate == "CVT 42" and fs.mode == "resell", "fence: the plate and mode are sent")
check(reported == 1, "fence: a fresh position report is asked for before the sale")
server("rlsmpFenceResult", {ok = false, mode = "resell", err = "The fence works at Joe's Junkyard right now. Bring the car there."})
check(objects[newId] ~= nil and #theft.stolenCars() == 1 and toasts[#toasts]:find("Bring the car"), "fence refused: the car stays, the reason is shown")
order = {}
server("rlsmpFenceAsk", {mode = "strip"})
server("rlsmpFenceResult", {ok = true, mode = "strip", pay = 1800, takeCar = true})
check(order[1] == "delete " .. newId and objects[newId] == nil and #theft.stolenCars() == 0 and toasts[#toasts]:find("1800"), "fence sold: the car is deleted and forgotten")
check(not T.isConverted(newId), "fence sold: no longer enterable")
server("rlsmpFenceResult", {ok = true, mode = "strip", pay = 5, takeCar = true})
check(true, "a stray result without a pending car does nothing")

theft.onVehicleDestroyed(newId)
check(not T.isConverted(newId) and #theft.stolenCars() == 0, "destroyed: forgotten")
-- a later parked car that reuses the id is blocked again
parked = {newId}
mkObj(newId, "covet", 0, 0)
check(guard.isBlocked(newId) == true, "reused id is blocked again")
-- another player's car is never let through, even if its id was in the set
T.markConverted(300)
check(guard.isBlocked(300) == true, "remote car stays blocked")
T.clearConverted()

-- 7. Failure result: no conversion
parked = {10}
mkObj(10, "covet", spotA.x, spotA.y, {partConfig = "vehicles/covet/base.pc"})
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
step(2)
server("rlsmpTheftCan", {ok = true, id = 10, method = "window_screwdriver", label = "Smash", seconds = 1})
server("rlsmpTheftSteal", {})
server("rlsmpTheftGo", {ok = true, method = "window_screwdriver", seconds = 1, noise = 0})
step(3)
order = {}
server("rlsmpTheftResult", {ok = false, err = "It did not work."})
check(#order == 0 and objects[10] ~= nil and toasts[#toasts]:find("did not work"), "failure: the parked car stays")

-- 7b. switched off while a steal is running: the action stops and the server is told
parked = {10}
mkObj(10, "covet", spotA.x, spotA.y, {partConfig = "vehicles/covet/base.pc"})
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
step(2)
server("rlsmpTheftCan", {ok = true, id = 10, method = "window_screwdriver", label = "Smash", seconds = 30})
server("rlsmpTheftSteal", {})
server("rlsmpTheftGo", {ok = true, method = "window_screwdriver", seconds = 30, noise = 0})
step(2)
check(theft._action() ~= nil, "a steal is running")
local cancels = count("rlsmpTheftCancel")
server("rlsmpTheftConfig", {enabled = false, seed = seed, period = 3, perMille = 150})
check(theft._action() == nil and theft._target() == nil and count("rlsmpTheftCancel") == cancels + 1 and toasts[#toasts]:find("switched off"), "switched off mid-steal: stopped, server told, player told")

-- 8. Off when the server says so
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = false, seed = seed, period = 3, perMille = 150})
local n0 = count("rlsmpTheftCheck")
step(4)
check(count("rlsmpTheftCheck") == n0, "disabled by the server: nothing")
-- 9. Inspect hint: ask the server (it answers members only), one small toast, /inspect works on the nearest parked car of any kind
playerId = 1
theft.onServerLeave() theft.enable(true)
mkObj(20, "covet", spotA.x, spotA.y, {partConfig = "vehicles/covet/base.pc"})
parked = {20, 11}
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3, inspect = {enabled = true, range = 15}})
walkerObj.pos = {x = 10, y = 5, z = 0}
local checks9 = count("rlsmpTheftCheck")
step(2)
local hq = last("rlsmpTheftHint")
check(count("rlsmpTheftHint") == 1 and hq.id == 20 and hq.x == spotA.x, "hint: asked once for the stealable car in range (not for the boring one, not the 3 m prompt)")
check(count("rlsmpTheftCheck") == checks9, "hint: far from the car there is no steal prompt")
step(6)
check(count("rlsmpTheftHint") == 1, "hint: not asked again within 15 s")
local nt9 = #toasts
check(nt9 == #toasts, "hint: silence until the server answers")
server("rlsmpTheftHint", {ok = true, id = 20})
check(toasts[#toasts]:find("Press %[Y%]") and not toasts[#toasts]:find("/") and #toasts == nt9 + 1, "hint: the server said yes, one small toast")
server("rlsmpTheftHint", {ok = true, id = 20})
check(#toasts == nt9 + 1, "hint: shown once per car")
theft.interact()
dlg = dialogs[#dialogs]
check(#dlg.buttons == 2 and dlg.buttons[1].label == "Inspect" and dlg.buttons[2].label == "Cancel", "interact near a boring-for-us parked car: Inspect and Cancel only")
theft.choose("inspect")
local iq = last("rlsmpTheftInspect")
check(count("rlsmpTheftInspect") == 1 and iq.id == 20 and iq.value == 6000 and iq.year == 1988 and iq.x == spotA.x, "inspect: asks about the nearest parked car with value and year")
step(8, 0.5)
check(count("rlsmpTheftInspectFinish") == 0, "inspect: waits for the server's go")
server("rlsmpTheftInspectGo", {ok = true, seconds = 3})
step(5, 0.5)
check(toasts[#toasts]:find("2 / 3") and count("rlsmpTheftInspectFinish") == 0, "inspect: progress toast")
step(3, 0.5)
check(count("rlsmpTheftInspectFinish") == 1, "inspect: finish asked when the time is up")
server("rlsmpTheftInspected", {id = 20, found = true, text = "Easy mark, old car."})
check(toasts[#toasts] == "Easy mark, old car." and theft._inspect() == nil, "inspect: the answer is shown")
server("rlsmpTheftInspectAsk", {})
server("rlsmpTheftInspectGo", {ok = true, seconds = 3})
walkerObj.pos = {x = 30, y = 5, z = 0}
step(2, 0.5)
check(theft._inspect() == nil and count("rlsmpTheftInspectFinish") == 1, "inspect: walking away cancels")
walkerObj.pos = {x = 100, y = 5, z = 0}
local ic = count("rlsmpTheftInspect")
server("rlsmpTheftInspectAsk", {})
check(count("rlsmpTheftInspect") == ic and toasts[#toasts]:find("No parked car"), "inspect: nothing in range, nothing sent")
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3, inspect = {enabled = false, range = 15}})
walkerObj.pos = {x = 10, y = 5, z = 0}
local hc = count("rlsmpTheftHint")
step(3)
server("rlsmpTheftInspectAsk", {})
check(count("rlsmpTheftHint") == hc and count("rlsmpTheftInspect") == ic, "inspect: switched off, nothing asked")
-- The fence from the phone app: only our fixed words
theft.onServerLeave() theft.enable(true)
server("rlsmpTheftConfig", {enabled = true, seed = seed, period = 3, perMille = 150, periodSeconds = 3600, radius = 3})
local fq = count("rlsmpFenceSell")
theft.fence("rm -rf")
check(count("rlsmpFenceSell") == fq, "fence: unknown mode ignored")
-- Stand-in parked cars (simple_traffic, config `sedan_pre_s_parked`): the value comes from the real config, not 0
local bastionList = {
  {model_key = "bastion", key = "sedan_pre_s", Value = 30000, Years = {min = 2005, max = 2010}},
  {model_key = "bastion", key = "sedan_pre_h", Value = 50000, Years = {min = 2005, max = 2010}},
  {model_key = "bastion", key = "police", Value = 90000, ["Config Type"] = "Police", Years = {min = 2005, max = 2010}},
}
core_vehicles.getConfigList = function() return {configs = bastionList} end
overhaul_career_market_valueCalculator = {getVehicleValuation = function(o) valuationOpts = o return {bookValue = o.catalogBaseValue * 0.7} end}
local stand = mkObj(300, "simple_traffic", 1, 1, {partConfig = "vehicles/simple_traffic/bastion_sedan_pre_s_parked.pc"})
local ci = theft.carInfo(stand)
check(ci.model == "bastion" and ci.configKey == "sedan_pre_s" and ci.config == "vehicles/bastion/sedan_pre_s.pc", "stand-in: real config found")
check(ci.value == 21000 and ci.year == 2005, "stand-in: used value from RLS valuation, not 0")
check(valuationOpts.logContext == "rlsmpStolen" and valuationOpts.age > 0 and valuationOpts.mileageMeters > 0, "valuation asked with age and mileage")
local unknown = mkObj(301, "simple_traffic", 2, 2, {partConfig = "vehicles/simple_traffic/bastion_weird_parked.pc"})
ci = theft.carInfo(unknown)
check(ci.value == 21000 and ci.config == nil, "unknown config: typical one of the model, spawn left to the game")
-- Repricing: the server asks, we answer with today's market (also for a car we no longer have)
overhaul_career_economy_globalEconomy = {getVehicleMarketIndex = function() return 1.1 end}
overhaul_career_market_valueCalculator = {getVehicleValuation = function(o) valuationOpts = o return {bookValue = o.catalogBaseValue * 0.7 * (o.applyVehicleBuyMarket and overhaul_career_economy_globalEconomy.getVehicleMarketIndex() or 1)} end}
local rc = count("rlsmpTheftValue")
server("rlsmpTheftReprice", {cars = {{plate = "OLD 1", model = "bastion", config = "vehicles/bastion/sedan_pre_s.pc"}, {plate = "X", model = "nomodel"}}})
local rv = last("rlsmpTheftValue")
check(count("rlsmpTheftValue") == rc + 1 and rv.plate == "OLD 1" and rv.value == 23100 and rv.source == "rls valuation", "reprice: value with the market index, sent for the car it could price")
check(valuationOpts.applyVehicleBuyMarket == true, "reprice: market flag on the valuation")
overhaul_career_economy_globalEconomy = {getVehicleMarketIndex = function() return 0.9 end}
server("rlsmpTheftReprice", {cars = {{plate = "OLD 1", model = "bastion", config = "vehicles/bastion/sedan_pre_s.pc"}}})
check(last("rlsmpTheftValue").value == 18900, "reprice: a changed market gives a new value (cache keyed by market)")
print("theft_client_test: " .. passed .. " checks passed")
