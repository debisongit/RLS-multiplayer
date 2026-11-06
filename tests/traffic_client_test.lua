-- Client traffic ceiling test (LuaJIT). Run: luajit tests/traffic_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end

local mp, career = true, true
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
local active = 30
local calls = 0
gameplay_traffic = {
  getTrafficVars = function() return {activeAmount = active} end,
  setActiveAmount = function(n) active = n calls = calls + 1 end,
}

local traffic = require("rlsmp/traffic")
traffic.onExtensionLoaded()

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end
local function server(tbl) handlers["rlsmpTrafficQuota"](json.encode(tbl)) end

check(traffic.getQuota() == nil, "no quota yet")
check(traffic._enforce() == false and calls == 0, "nothing to enforce before the server speaks")

server({active = 12})
check(traffic.getQuota() == 12 and active == 12, "quota lowers traffic above it")

active = 5 -- an RLS event cut traffic
traffic.onUpdate(10)
check(active == 5 and calls == 1, "never raises traffic")

active = 30 -- RLS restored its own amount after the event
traffic.onUpdate(1)
check(active == 30, "check is rate limited")
traffic.onUpdate(3)
check(active == 12, "ceiling re-applied on the next check")

server({active = 8})
check(active == 8, "new quota applies at once")
server({active = -4})
check(traffic.getQuota() == 8, "negative quota ignored")

mp = false
active = 30
traffic.onUpdate(5)
check(active == 30, "does nothing outside multiplayer")
mp, career = true, false
traffic.onUpdate(5)
check(active == 30, "does nothing when career is not active")

career = true
traffic.onServerLeave()
traffic.onUpdate(5)
check(active == 30 and traffic.getQuota() == nil, "quota forgotten after leaving the server")

print(string.format("traffic_client_test: %d checks passed", passed))
