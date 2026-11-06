-- Traffic name-tag client test (LuaJIT). Run: luajit tests/traffic_labels_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent, handlers = {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end

local vehicles = {
  ["0-1"] = {gameVehicleID = 11, isLocal = true},    -- my car (player driven)
  ["0-2"] = {gameVehicleID = 12, isLocal = true},    -- my AI traffic
  ["0-3"] = {gameVehicleID = 13, isLocal = true},    -- my parked car
  ["1-4"] = {gameVehicleID = 21, isLocal = false},   -- a remote traffic car
  ["1-5"] = {gameVehicleID = 22, isLocal = false},   -- remote player's real car
}
MPVehicleGE = {getVehicles = function() return vehicles end}
gameplay_traffic = {getTrafficData = function() return {[11] = {isAi = false}, [12] = {isAi = true}} end}
gameplay_parking = {getParkedCarsList = function() return {13} end}

local net = require("rlsmp/lib/net")
net.init()
local tl = require("rlsmp/trafficLabels")
tl.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local own = tl.collectOwn()
check(#own == 2 and own[1] == "0-2" and own[2] == "0-3", "own traffic and parked cars, but not the car I drive")

tl.onUpdate(5)
check(#sent == 0, "disabled: nothing sent")
tl.enable(true)
tl.onUpdate(5)
check(sent[1].name == "rlsmpTrafficIds" and #sent[1].data.ids == 2, "list sent to the server")
tl.onUpdate(5)
check(#sent == 1, "unchanged list is not sent again")
gameplay_parking.getParkedCarsList = function() return {} end
tl.onUpdate(5)
check(#sent == 2 and #sent[2].data.ids == 1, "changed list is sent")

handlers["rlsmpTrafficIdsRx"](json.encode({from = 1, ids = {"1-4"}}))
check(vehicles["1-4"].hideNametag == true and not vehicles["1-5"].hideNametag, "remote traffic hidden, remote player's car keeps its tag")
vehicles["1-6"] = {gameVehicleID = 23, isLocal = false}
handlers["rlsmpTrafficIdsRx"](json.encode({from = 1, ids = {"1-4", "1-6"}}))
check(vehicles["1-6"].hideNametag == true, "traffic that arrives later is hidden too")
handlers["rlsmpTrafficIdsRx"](json.encode({from = 1, ids = {"1-6"}}))
check(vehicles["1-4"].hideNametag == false, "a car that is no longer traffic gets its tag back")
print(string.format("traffic_labels_client_test: %d checks passed", passed))
