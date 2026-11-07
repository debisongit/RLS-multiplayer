-- Server smart traffic settings test (lua5.3). Run: lua5.3 tests/smart_traffic_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, handlers, timers = {}, {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function(name, ms) timers[name] = ms end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
}
Util = {}
require("rlsmp.server.util").setJsonCodec(json)
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}
local config = require("rlsmp.server.config")
local cfg = config.defaults
local util = require("rlsmp.server.util")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end

-- defaults, and merging into an old config.json that has no smartTraffic key / a partial one
local d = cfg.smartTraffic
check(d.enabled == true and d.policeReact == true, "defaults on")
check(d.mix.normal == 80 and d.mix.slow == 10 and d.mix.aggressive == 6 and d.mix.racer == 3 and d.mix.drunk == 1, "default mix")
local merged = util.deepMerge(config.defaults, {traffic = {enabled = true}})
check(merged.smartTraffic and merged.smartTraffic.mix.drunk == 1, "old config gets the new key")
merged = util.deepMerge(config.defaults, {smartTraffic = {mix = {drunk = 0, racer = 10}, policeReact = false}})
check(merged.smartTraffic.mix.drunk == 0 and merged.smartTraffic.mix.racer == 10 and merged.smartTraffic.mix.normal == 80
  and merged.smartTraffic.policeReact == false and merged.smartTraffic.enabled == true, "admin values kept, missing ones filled")

require("rlsmp.server.net").init(cfg)
local smart = require("rlsmp.server.smartTraffic")
smart.init(cfg, "")
check(handlers["rlsmpSmartTrafficTick"] ~= nil and timers["rlsmpSmartTrafficTick"] == 1000, "own timer event")

local function tick() _G[handlers["rlsmpSmartTrafficTick"]]() end
local function take() local t = sent sent = {} return t end

stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded -> nothing")
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].name == "rlsmpSmartTraffic" and m[1].pid == 0, "sent on load, one event name")
check(m[1].data.enabled == true and m[1].data.policeReact == true and m[1].data.mix.normal == 80
  and m[1].data.mix.drunk == 1, "payload carries the config")
tick()
check(#take() == 0, "sent only once")
stages[0] = nil
tick()
stages[0] = "loaded"
tick()
check(#take() == 1, "rejoin gets it again")

-- bad weights from a hand-edited config.json are sent as 0
cfg.smartTraffic.mix.racer = "lots"
cfg.smartTraffic.mix.slow = -5
stages[1] = "loaded"
tick()
m = take()
check(#m == 1 and m[1].pid == 1 and m[1].data.mix.racer == 0 and m[1].data.mix.slow == 0 and m[1].data.mix.aggressive == 6, "bad weights -> 0")

-- turned off: still told (so the game knows it is off)
cfg.smartTraffic.enabled = false
stages[2] = "loaded"
tick()
m = take()
check(#m == 1 and m[1].pid == 2 and m[1].data.enabled == false, "disabled is sent too")

print(string.format("smart_traffic_test: %d checks passed", passed))
