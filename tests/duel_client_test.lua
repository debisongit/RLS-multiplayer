-- Client duel test (LuaJIT). Run: luajit tests/duel_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
function deepcopy(t) return jsonDecode(jsonEncode(t)) end
local sent, handlers = {}, {}
guihooks = {trigger = function() end}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
local vehicles = {[4] = {model = "etk800", config = {}}}
local current, removed = 4, {}
overhaul_career_garage_inventory = {
  getCurrentVehicle = function() return current end,
  getVehicle = function(id) return vehicles[id] end,
  removeVehicle = function(id) removed[#removed + 1] = id vehicles[id] = nil end,
  hasFreeSlot = function() return true end,
  addVehicle = function() vehicles[10] = {model = "x", config = {}} return 10 end,
  setVehicleDirty = function() end,
  getVehicles = function() return vehicles end,
}
local removable = true
overhaul_career_logistics_general = {canRemoveLogisticsVehicle = function() return removable end}
local vmt = {__add = function(a, b) return a end, __mul = function(a) return a end}
local function V(x, y, z) return setmetatable({x = x, y = y, z = z}, vmt) end
local at = V(0, 0, 0)
getPlayerVehicle = function() return {getPosition = function() return at end, getDirectionVector = function() return V(0, 0, 0) end} end
core_vehicles = {spawnNewVehicle = function() return {getID = function() return 77 end, delete = function() end} end}
rlsmp_saveBridge = {requestSave = function() end}
local net = require("rlsmp/lib/net")
net.init()
local fleet = require("rlsmp/fleet")
rlsmp_fleet = fleet
local duel = require("rlsmp/duel")
duel.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, t) handlers[name](json.encode(t)) end
local function last(name) for i = #sent, 1, -1 do if sent[i].name == name then return sent[i].data end end end

duel.enable(false)
server("rlsmpDuelWho", {id = 1})
check(last("rlsmpDuelCar") == nil, "disabled: no answer")
duel.enable(true)
server("rlsmpDuelWho", {id = 1})
local car = last("rlsmpDuelCar")
check(car and car.inv == 4 and car.cur == 4 and car.model == "etk800" and car.pos.x == 0, "answers with the car, the current car and position")

-- finish line
server("rlsmpDuelGo", {id = 1, finish = {x = 100, y = 0, z = 0}, radius = 20})
duel.onUpdate(0.3)
check(last("rlsmpDuelFinish") == nil, "not at the finish yet")
at = V(95, 5, 0)
duel.onUpdate(0.3)
check(last("rlsmpDuelFinish") and last("rlsmpDuelFinish").id == 1, "finish reported")
sent = {}
duel.onUpdate(0.3) duel.onUpdate(0.3)
check(last("rlsmpDuelFinish") == nil, "finish reported only once")
server("rlsmpDuelEnd", {id = 1})
sent = {}
duel.onUpdate(2)
check(last("rlsmpDuelPos") == nil, "no position pings after the duel")

-- loser: the server built the winner's car from its own copy; the client only removes the car, never uploads it
check(handlers["rlsmpDuelHand"] == nil, "no hand-over upload handler any more")
sent = {}
server("rlsmpDuelAck", {slip = "s1", ok = false, inv = 4})
check(#removed == 0, "refused ack keeps the car")
server("rlsmpDuelAck", {slip = "s1", ok = true, inv = 4, model = "pickup"})
check(#removed == 0, "ack naming another model does not remove the car")
removable = false
server("rlsmpDuelAck", {slip = "s1", ok = true, inv = 4, model = "etk800"})
check(#removed == 0, "car in use for a job is left for the join-time drop")
removable = true
server("rlsmpDuelAck", {slip = "s1", ok = true, inv = 4, model = "etk800"})
check(removed[1] == 4, "removed when the server says so")
for _ = 1, 50 do net.pump(10) end
check(last("rlsmpUpBegin") == nil, "nothing uploaded for the hand-over")

-- winner: car arrives and is tagged; a second delivery is only confirmed
sent = {}
handlers["rlsmpDuelWho"] = handlers["rlsmpDuelWho"]
duel._onVehicle(json.encode({slip = "s1", rec = {model = "etk800", config = {}}}), {slip = "s1"})
check(vehicles[10] and vehicles[10].slipId == "s1" and last("rlsmpDuelReceived"), "winner gets the car, tagged with the slip")
sent = {}
vehicles[10] = {model = "etk800", slipId = "s1"}
duel._onVehicle(json.encode({slip = "s1", rec = {model = "etk800", config = {}}}), {slip = "s1"})
local count = 0 for _ in pairs(vehicles) do count = count + 1 end
check(count == 1 and last("rlsmpDuelReceived"), "repeat delivery is not spawned twice")
print("duel_client_test: " .. passed .. " checks passed")
