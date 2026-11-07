-- Client traffic ceiling test (LuaJIT). Run: luajit tests/traffic_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
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

server({active = 12, players = 2, rev = 3})
check(traffic.getQuota() == 12 and active == 12, "quota lowers traffic above it")
check(saw("RLSMP-P3|quota received active=12 players=2 rev=3"), "quota received line")
check(saw("RLSMP-P3|TRAFFIC ceiling lowered 30 -> 12"), "ceiling line")

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

-- the quota grows again (a player left): traffic goes back up, never above the player's own amount
active = 8
server({active = 8})
server({active = 20})
check(active == 20, "quota rises, traffic follows")
server({active = 99})
check(active == 30, "never above the player's own original amount")
active = 4 server({active = 99}) traffic.onUpdate(5)
check(active == 4, "an amount RLS changed is left alone")
-- no cutting during a chase
active = 30 server({active = 99})
rlsmp_police = {isPursuit = function() return true end}
server({active = 10})
check(active == 30, "traffic is not lowered during a pursuit")
rlsmp_police = nil
traffic.onUpdate(5)
check(active == 10, "lowered once the chase is over")
-- leaving restores the player's setting
traffic.onServerLeave()
check(active == 30, "own amount restored on leave")

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
