-- Black market drop marker, client (LuaJIT). Run: luajit tests/market_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local handlers, toasts, drawn, reports = {}, {}, 0, 0
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
guihooks = {trigger = function(_, t) toasts[#toasts + 1] = t.msg end}
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
ColorF = function() return {} end
ColorI = function() return {} end
String = function(s) return s end
debugDrawer = {drawSphere = function() drawn = drawn + 1 end, drawTextAdvanced = function() end}
local at = {x = 1000, y = 1000, z = 0}
local hasCar = true
getPlayerVehicle = function() return hasCar and {getPosition = function() return at end} or nil end
rlsmp_positions = {reportNow = function() reports = reports + 1 end}
local net = require("rlsmp/lib/net")
net.init()
local market = require("rlsmp/market")
market.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, t) handlers[name](json.encode(t)) end
local function run(seconds) for _ = 1, math.floor(seconds * 10 + 0.5) do market.onUpdate(0.1) end end
local function count(d) local n = 0 for _ in pairs(d) do n = n + 1 end return n end
local lastToast = function() return toasts[#toasts] or "" end

server("rlsmpMarketDrop", {id = "o1", label = "Fake plate", spot = "Joe's Junkyard", x = 10, y = 20, z = 5, readyIn = 60})
check(count(market._drops()) == 0 and #toasts == 0, "ignored while disabled")
market.enable(true)
server("rlsmpMarketDrop", {id = "o1", label = "Fake plate", spot = "Joe's Junkyard", x = 10, y = 20, z = 5, readyIn = 60})
check(count(market._drops()) == 1 and lastToast():find("Joe's Junkyard") and lastToast():find("60 s"), "order toast with spot and time")
server("rlsmpMarketDrop", {id = "o1", label = "Fake plate", spot = "Joe's Junkyard", x = 10, y = 20, z = 5, readyIn = 60})
check(#toasts == 1 and count(market._drops()) == 1, "same drop again (re-sync): no second toast")
server("rlsmpMarketDrop", {id = "bad", x = "a", y = 0, z = 0})
server("rlsmpMarketDrop", {x = 1, y = 2, z = 3})
server("rlsmpMarketDrop", {id = "inf", x = 1e999, y = 0, z = 0})
check(count(market._drops()) == 1, "bad drops ignored")

run(30)
check(#toasts == 1 and drawn == 0, "nothing while not ready")
run(31)
check(lastToast():find("waiting at Joe's Junkyard"), "ready toast")
check(drawn == 0, "far away: no marker drawn")
local n = #toasts
run(5)
check(#toasts == n, "ready toast once")

at = {x = 100, y = 120, z = 5}
run(1)
check(drawn > 0 and #toasts == n and reports == 0, "near (under 300 m): marker drawn, no pickup hint yet")
at = {x = 20, y = 25, z = 9}
run(1.1)
check(lastToast():find("/market pickup") and reports == 1, "inside 15 m: pickup hint and a fresh position report")
run(5)
check(#toasts == n + 1 and reports == 1, "hint once while staying")
at = {x = 100, y = 120, z = 5}
run(1.1)
at = {x = 12, y = 20, z = 5}
run(1.1)
check(#toasts == n + 2 and reports == 2, "hint again after leaving and coming back")

hasCar = false
run(3)
check(true, "no vehicle: no error")
hasCar = true

server("rlsmpMarketClear", {id = "o1"})
check(count(market._drops()) == 0, "cleared after pickup")
drawn = 0
run(3)
check(drawn == 0, "nothing drawn after clear")

server("rlsmpMarketDrop", {id = "o2", label = "Screwdriver", spot = "Docks", x = 0, y = 0, z = 0, readyIn = 0})
check(lastToast():find("waiting at Docks"), "already ready on join: one toast")
n = #toasts
run(2)
check(#toasts == n, "no second ready toast")
debugDrawer = nil
at = {x = 1, y = 1, z = 0}
run(2)
check(true, "no debugDrawer: no error")
market.enable(false)
check(count(market._drops()) == 0, "disable forgets drops")
server("rlsmpMarketClear", {})
print("market_client_test: " .. passed .. " checks passed")
