-- Server police settings test (lua5.3). Run: lua5.3 tests/traffic_police_test.lua
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
require("rlsmp.server.trafficPolice").init(cfg, "")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function tick() _G[handlers["rlsmpPoliceTick"]]() end
local function take() local t = sent sent = {} return t end

stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded -> nothing")
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].name == "rlsmpPoliceConfig" and m[1].data.antiTeleport == true
  and m[1].data.blockRoadblocks == true and m[1].data.noFineInStolenCar == true and m[1].data.noRadarFineIllegal == true, "settings sent on load (no fine in a stolen car, no radar fine: on by default)")
check(m[1].data.respawnBehind == true and m[1].data.respawnPerMinute == 4 and m[1].data.respawnGap == nil, "re-placed cops are judged and moved: on by default, 4 builds a minute, no gap setting any more")
check(m[1].data.spawnMinDistance == 1000 and m[1].data.chaseSpawnMinDistance == 600 and m[1].data.spawnPreferRight == true, "cops appear at least 1000 m away (600 m in a chase), right side preferred")
check(m[1].data.copCount == 0 and m[1].data.copTopUpSeconds == 30, "no extra cops by default (copCount 0 = the game's own number)")
check(m[1].data.respawnRebuildSeconds == 90 and m[1].data.copRespawnDistance == 450, "a rebuild at most every 90 s, cops re-placed only beyond 450 m")
check(m[1].data.bubbleMode == "original", "the traffic bubble mode is sent and defaults to original (RLS's own distances)")
tick()
check(#take() == 0, "sent only once")
stages[0] = nil
tick()
stages[0] = "loaded"
tick()
check(#take() == 1, "rejoin gets them again")
cfg.police.antiTeleport = false
stages[1] = "loaded"
tick()
m = take()
check(#m == 1 and m[1].pid == 1 and m[1].data.antiTeleport == false, "config changes are respected")
cfg.police.enabled = false
stages[2] = "loaded"
tick()
check(#take() == 0, "disabled -> silent")

-- an old config.json (written before the cop spawn rules) still has the old copCount default 3: it is reset to 0 once; a chosen value stays
local storage = require("rlsmp.server.storage")
local path = os.tmpname()
storage.writeJson(path, {police = {copCount = 3}}, true)
check(require("rlsmp.server.config").load(path).police.copCount == 0, "old config.json with copCount 3 and no spawn rules: reset to 0 (the owner never asked for more cops)")
check(require("rlsmp.server.config").load(path).police.copCount == 0, "...and it stays 0 (the file now has the new keys)")
storage.writeJson(path, {police = {copCount = 2, spawnMinDistance = 1000}}, true)
check(require("rlsmp.server.config").load(path).police.copCount == 2, "a value chosen after the change is kept")
os.remove(path)

print(string.format("traffic_police_test: %d checks passed", passed))
