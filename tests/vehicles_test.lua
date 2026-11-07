-- Server vehicle rules test (lua5.3). Run: lua5.3 tests/vehicles_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, handlers = {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
}
Util = {}
require("rlsmp.server.util").setJsonCodec(json)
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}
local cfg = require("rlsmp.server.config").defaults
require("rlsmp.server.net").init(cfg)
require("rlsmp.server.vehicles").init(cfg, "")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function tick() _G[handlers["rlsmpVehicleTick"]]() end
local function take() local t = sent sent = {} return t end

check(cfg.vehicles.allowPassengers == false, "passengers are off by default")
stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded -> nothing")
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].name == "rlsmpVehicleConfig" and m[1].data.allowPassengers == false, "settings sent on load")
tick()
check(#take() == 0, "sent only once")
cfg.vehicles.allowPassengers = true
stages[1] = "loaded"
tick()
m = take()
check(#m == 1 and m[1].pid == 1 and m[1].data.allowPassengers == true, "a switched-on server tells new players")
stages[0] = nil
tick()
stages[0] = "loaded"
tick()
check(#take() == 1, "rejoin gets them again")
cfg.vehicles.enabled = false
stages[2] = "loaded"
tick()
check(#take() == 0, "disabled -> silent")

print(string.format("vehicles_test: %d checks passed", passed))
