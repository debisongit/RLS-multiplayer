-- Black market drop marker, client (LuaJIT). Run: luajit tests/market_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local handlers, toasts, drawn, reports = {}, {}, 0, 0
local scoutAsked
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
local dialogs = {}
guihooks = {trigger = function(name, t) if name == "showConfirmationDialog" then dialogs[#dialogs + 1] = t else toasts[#toasts + 1] = t.msg end end}
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
check(lastToast():find("Collecting") and reports == 1, "inside 15 m: collecting toast and a fresh position report")
run(5)
check(#toasts == n + 1 and reports == 1, "toast once while staying")
at = {x = 100, y = 120, z = 5}
run(1.1)
at = {x = 12, y = 20, z = 5}
run(1.1)
check(#toasts == n + 2 and reports == 2, "toast again after leaving and coming back")

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

-- Phone app bridge ---------------------------------------------------------------------------------------------
local sentApp, fakeClock = {}, 100
TriggerServerEvent = function(name, data) sentApp[#sentApp + 1] = {name = name, data = json.decode(data)} end
local realTime = os.time
os.time = function() return fakeClock end
local function sentCount(name) local n = 0 for _, e in ipairs(sentApp) do if e.name == name then n = n + 1 end end return n end
market.enable(false)
check(market.uiGet().enabled == false and market.uiAct("buy", "screwdriver") == false and #sentApp == 0, "app: disabled, nothing sent")
market.enable(true)
local got = market.uiGet()
check(got.enabled and got.state == nil and sentCount("rlsmpMarketGet") == 1, "app: first poll asks the server")
market.uiGet()
check(sentCount("rlsmpMarketGet") == 1, "app: polling again in the same second does not flood the server")
fakeClock = fakeClock + 1
market.uiGet()
check(sentCount("rlsmpMarketGet") == 2, "app: asks again after a second")
server("rlsmpMarketState", {ready = true, member = true, rep = 12})
check(market.uiGet().state.rep == 12, "app: the last state is handed over")
server("rlsmpMarketResult", {text = "Paid $400."})
local r1 = market.uiGet().result
check(r1.text == "Paid $400." and r1.seq == 1, "app: the result text with a sequence number")
server("rlsmpMarketResult", {text = "Paid $400."})
check(market.uiGet().result.seq == 2, "app: the same text again is a new result (the app shows it again)")
check(market.uiAct("buy", "screwdriver", 2) == true, "app: buy sent")
local act = sentApp[#sentApp]
check(act.name == "rlsmpMarketAct" and act.data.a == "buy" and act.data.item == "screwdriver" and act.data.n == 2, "app: buy carries item and count")
local asks = sentCount("rlsmpMarketGet")
market.uiGet()
check(sentCount("rlsmpMarketGet") == asks + 1, "app: after an action the next poll refreshes at once")
market.uiAct("invite", "fay")
check(sentApp[#sentApp].data.a == "invite" and sentApp[#sentApp].data.who == "fay", "app: invite carries the name")
local reportsBefore = reports
market.uiAct("pickup")
check(sentApp[#sentApp].data.a == "pickup" and reports == reportsBefore + 1, "app: pickup asks for a fresh position report")
market.uiAct("accept")
check(sentApp[#sentApp].data.a == "accept", "app: accept")

-- Automatic pickup: the answer to it opens a popup (not a chat line); the phone app's own pickup does not
local nd = #dialogs
server("rlsmpMarketResult", {text = "Picked up: Screwdriver."})
check(#dialogs == nd, "app pickup answer: no popup")
server("rlsmpMarketDrop", {id = "o9", label = "Plate", spot = "Yard", x = 5000, y = 5000, z = 0, readyIn = 0})
at = {x = 5000, y = 5000, z = 0}
market.onUpdate(0.1) market.onUpdate(1.1)
check(sentApp[#sentApp].data.a == "pickup", "inside the circle: pickup sent by itself")
server("rlsmpMarketResult", {text = "Picked up: Fake plate."})
check(#dialogs == nd + 1 and dialogs[#dialogs].text:find("Picked up"), "automatic pickup answer: a small popup")
check(#dialogs[#dialogs].buttons == 1 and dialogs[#dialogs].buttons[1].label == "OK", "popup has one OK button")
server("rlsmpMarketClear", {id = "o9"})

-- Buttons done by other extensions
local fenced, meetupAct
rlsmp_theft = {fence = function(m) fenced = m end}
rlsmp_meetup = {startBlack = function() meetupAct = "black" end, cancel = function() meetupAct = "cancel" end}
local nsent = #sentApp
market.uiAct("fence", "resell")
market.uiAct("meetup")
check(fenced == "resell" and meetupAct == "black" and #sentApp == nsent, "app: fence and meetup go to the other extensions, nothing to the server")
market.uiAct("meetupCancel")
check(meetupAct == "cancel", "app: meetup can be dropped")
check(market.uiAct(42) == false and market.uiAct(nil) == false, "app: a non-text action is refused here")
server("rlsmpMarketState", "garbage")
check(market.uiGet().state.rep == 12, "app: a bad state message changes nothing")
-- scout tip: the game sends the stealable parked cars it sees; the marks are small spheres until the time is up
server("rlsmpMarketState", {ready = true, member = true, rep = 12, scout = {radius = 900}})
rlsmp_theft = {stealableNear = function(r, max) scoutAsked = {r, max} return {{x = 1, y = 2, z = 3}} end}
market.uiAct("scout")
local sa = sentApp[#sentApp]
check(sa.data.a == "scout" and #sa.data.cars == 1 and sa.data.cars[1].x == 1 and scoutAsked[1] == 900 and scoutAsked[2] == 8, "scout: sends the cars with the app's radius")
local before = #toasts
server("rlsmpMarketScout", {marks = {{x = 10, y = 20, z = 5}, {x = 30, y = 40, z = 5}, {x = "a", y = 0, z = 0}}, seconds = 600})
check(#market._marks() == 2 and #toasts == before + 1 and lastToast():find("2 car"), "scout: two marks, one toast")
debugDrawer = {drawSphere = function() drawn = drawn + 1 end}
drawn = 0
run(1)
check(drawn >= 20, "scout: a small sphere per mark and frame")
run(601)
check(#market._marks() == 0, "scout: marks end with the time")
drawn = 0
run(1)
check(drawn == 0, "scout: nothing drawn after that")
server("rlsmpMarketScout", {marks = {{x = 10, y = 20, z = 5}}, seconds = 600})
market.onServerLeave()
check(#market._marks() == 0, "scout: leaving the server drops the marks")
market.enable(true)
market.onServerLeave()
check(market.uiGet().state == nil and market.uiGet().result == nil, "app: leaving the server forgets the state")
-- stolen cars through the phone: handed to the garage extension with the plate and the way; the garage answer can note a message
local garageCalls = {}
rlsmp_garage = {doStolen = function(plate, action) garageCalls[#garageCalls + 1] = {plate, action} return action ~= "gamble" end}
check(market.uiAct("stolenDo", "PH 1", "sell") == true and garageCalls[1][1] == "PH 1" and garageCalls[1][2] == "sell", "app: stolenDo goes to the garage extension")
check(market.uiAct("stolenDo", "PH 1", "gamble") == false, "app: the garage extension's refusal is passed on")
market.note("Sold (sell): $4000.")
check(market.uiGet().result.text == "Sold (sell): $4000.", "app: a note from the garage extension shows in the message box")
rlsmp_garage = nil
check(market.uiAct("stolenDo", "PH 1", "sell") == false, "app: without the garage extension nothing happens")
os.time = realTime
print("market_client_test: " .. passed .. " checks passed")
