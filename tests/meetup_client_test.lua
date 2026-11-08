-- Meetup selling, client (LuaJIT). Run: luajit tests/meetup_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local handlers, toasts, sentEv = {}, {}, {}
TriggerServerEvent = function(name, data) sentEv[#sentEv + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
guihooks = {trigger = function(_, t) toasts[#toasts + 1] = t.msg end}
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure logic
local L = require("rlsmp/lib/meetup")
check(L.fromMarketplace({"@x/career/market/marketplace.lua"}) and L.fromMarketplace({"@a/marketplace/negotiation.lua"}), "marketplace caller found")
check(not L.fromMarketplace({"@x/career/carmeets/carmeets.lua", "@x/career/market/auction/registration.lua"}), "car meets and auction are not the marketplace")
local h = L.newHold()
check(not L.step(h, 1, 5, 0, 15) and not L.step(h, 1, 5, 10, 15) and h.t == 0, "moving resets the timer")
check(not L.step(h, 1, 5, 0, 15) and not L.step(h, 1, 40, 0, 15) and h.t == 0, "outside resets the timer")
L.step(h, 1, 5, 0, 15) L.step(h, 1, 5, 0, 15)
check(L.step(h, 1, 5, 0, 15), "stopped inside for 3 s: arrived")
local ids = L.nearestCops({[7] = {x = 100, y = 0}, [8] = {x = 10, y = 0}, [9] = {x = 50, y = 0}}, {x = 0, y = 0}, 2)
check(#ids == 2 and ids[1] == 8 and ids[2] == 9, "two nearest police")
check(#L.nearestCops({}, {x = 0, y = 0}, 2) == 0, "no police")

-- the extension with a fake RLS
local pos, speed = {x = 0, y = 0, z = 0}, 0
local car = {getPosition = function() return pos end, getVelocity = function() return {length = function() return speed end} end}
getPlayerVehicle = function() return car end
be = {getPlayerVehicleID = function() return 50 end, getObjectByID = function() return nil end}
local realSold, pubCalls, bypassSeen = {}, 0, nil
local inventory = {
  getVehicles = function() return {[3] = {model = "etk800", config = {licenseName = "ABC 123"}}} end,
  sellVehicle = function(id, price) realSold[#realSold + 1] = {id, price} return true end,
  publishVehicleSale = function() pubCalls = pubCalls + 1 end,
  getInventoryIdFromVehicleId = function() return 3 end,
}
overhaul_career_garage_inventory = inventory
local pathSet = 0
core_groundMarkers = {setPath = function() pathSet = pathSet + 1 return 1 end, clearOwnedPath = function() end}
local chased
overhaul_integration_services_police = {
  getPoliceVehicles = function() return {[11] = true, [12] = true, [13] = true} end,
  setPursuitMode = function(mode, target, ids) chased = {mode, target, #ids} end,
}
local pol = {[11] = {x = 500, y = 0}, [12] = {x = 5, y = 0}, [13] = {x = 50, y = 0}}
be.getObjectByID = function(_, id) return pol[id] and {getPosition = function() return pol[id] end} or nil end
local net = require("rlsmp/lib/net")
net.init()
local mt = require("rlsmp/meetup")
mt.onExtensionLoaded()
local function server(name, t) handlers[name](json.encode(t)) end
local function run(sec) for _ = 1, math.floor(sec * 10 + 0.5) do mt.onUpdate(0.1) end end

mt.enable(true)
mt.onUpdate(0.1)
check(inventory.sellVehicle ~= nil and inventory.sellVehicle ~= (function() return nil end), "installed")
local wrapped = inventory.sellVehicle
mt.onUpdate(0.1)
check(inventory.sellVehicle == wrapped, "wrapped once, not stacked")

-- a caller that is not the marketplace (this test file) goes straight through
check(inventory.sellVehicle(3, 100) == true and #realSold == 1, "other callers sell at once")

-- the marketplace path: simulate by calling from a function whose source contains "marketplace" (stack check)
local function fakeMarketplaceCall() return inventory.sellVehicle(3, 5000) end
local info = debug.getinfo(fakeMarketplaceCall, "S")
-- our test file is not named marketplace, so force it with a load()ed chunk named like RLS's file
local chunk = load("local inv = ... return function() local r = inv.sellVehicle(3, 5000) return r end", "@career/market/marketplace.lua")
local viaMarketplace = chunk(inventory)
check(viaMarketplace() == false and #realSold == 1, "marketplace sale is held back")
local req = sentEv[#sentEv]
check(req.name == "rlsmpMeetupRequest" and req.data.inv == 3 and req.data.plate == "ABC 123" and req.data.price == 5000, "server asked for a meetup")
check(viaMarketplace() == false and #sentEv == 1, "second sale while one is held: refused, no new request")

server("rlsmpMeetupSet", {id = "m1", kind = "market", spot = "Dock", x = 100, y = 0, z = 0, radius = 15, expiresIn = 600})
check(mt._meetup() and pathSet == 1, "route set")
run(5)
check(#sentEv == 1, "far away: nothing sent")
pos = {x = 100, y = 5, z = 0}
run(1)
check(#sentEv == 1, "not held long enough")
speed = 10
run(3)
check(#sentEv == 1, "driving through does not count")
speed = 0
run(3)
local arrived = sentEv[#sentEv]
check(arrived.name == "rlsmpMeetupArrive" and arrived.data.id == "m1", "arrival sent")
server("rlsmpMeetupResult", {id = "m1", ok = true, kind = "market"})
check(#realSold == 2 and realSold[2][1] == 3 and realSold[2][2] == 5000 and pubCalls == 1, "held sale finished with the real sellVehicle")
check(mt._meetup() == nil and mt._held() == nil, "state cleared")

-- setup: 1 or 2 nearest police, no sale
viaMarketplace()
server("rlsmpMeetupSet", {id = "m2", kind = "market", spot = "Dock", x = 100, y = 0, z = 0, radius = 15, expiresIn = 600})
run(4)
server("rlsmpMeetupResult", {id = "m2", ok = false, setup = true, cops = 2})
check(chased and chased[1] == 1 and chased[2] == 50 and chased[3] == 2 and #realSold == 2, "setup: chase of 2 police, sale not done")
chased = nil
viaMarketplace()
server("rlsmpMeetupSet", {id = "m3", kind = "market", spot = "Dock", x = 100, y = 0, z = 0, radius = 15, expiresIn = 600})
run(4)
server("rlsmpMeetupResult", {id = "m3", ok = false, setup = true, cops = 1})
check(chased and chased[3] == 1, "setup with 1 cop")

-- denied
viaMarketplace()
server("rlsmpMeetupDenied", {err = "wait"})
check(mt._held() == nil, "denied clears the held sale")

-- disabled: nothing is held
mt.enable(false)
check(viaMarketplace() == true and #realSold == 3, "disabled: the normal sale runs")

print(string.format("meetup_client_test: %d checks passed", passed))
