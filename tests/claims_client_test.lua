-- Crash reporting client test (LuaJIT). Run: luajit tests/claims_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent, handlers = {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end

local function v(x, y, z) return {x = x, y = y, z = z} end
-- my car (id 11) drives +x at 20 m/s; bob's player car (id 21) is parked at x=10; bob's traffic car 22 also touches
local mine = {jbeam = "etk800", pos = v(0, 0, 0), vel = v(20, 0, 0)}
function mine:getID() return 11 end
function mine:getPosition() return self.pos end
function mine:getVelocity() return self.vel end
function mine:getDirectionVector() return v(1, 0, 0) end
getPlayerVehicle = function() return mine end
local objectsById = {[21] = {jbeam = "pickup"}, [22] = {jbeam = "simple_traffic"}}
be = {getObjectByID = function(_, id) return objectsById[id] end}
map = {objects = {
  [11] = {pos = v(0, 0, 0), vel = v(20, 0, 0)},
  [21] = {pos = v(10, 0, 0), vel = v(0, 0, 0), dirVec = v(1, 0, 0), objectCollisions = {}},
  [22] = {pos = v(12, 1, 0), vel = v(0, 0, 0), dirVec = v(1, 0, 0), objectCollisions = {}},
  [30] = {pos = v(5, 5, 0), vel = v(0, 0, 0)},                    -- a car nearby that could have seen it
  [31] = {pos = v(500, 0, 0), vel = v(0, 0, 0)},                  -- far away
}}
local vehicles = {
  ["0-1"] = {gameVehicleID = 11, isLocal = true},
  ["1-1"] = {gameVehicleID = 21, isLocal = false},
  ["1-2"] = {gameVehicleID = 22, isLocal = false, hideNametag = true},   -- traffic
}
MPVehicleGE = {getVehicles = function() return vehicles end}
local price = 0
overhaul_career_market_valueCalculator = {getSpawnedVehicleRepairPrice = function() return price end}
core_vehicleBridge = {requestValue = function(_, cb) cb({result = {}}) end}
overhaul_career_garage_inventory = {
  getInventoryIdFromVehicleId = function() return 3 end,
  getCurrentVehicle = function() return 3 end,
  getVehicle = function() return {model = "etk800", niceName = "ETK 800"} end,
}
local claimed
overhaul_career_repair_insurance = {makeRepairClaim = function(inv, costs, info, damage) claimed = {inv = inv, damage = damage} end}

local net = require("rlsmp/lib/net")
net.init()
local c = require("rlsmp/claims")
c.onExtensionLoaded()
local passed = 0
local function check(cond, m) if not cond then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function run(seconds) for _ = 1, math.floor(seconds / 0.1 + 0.5) do c.onUpdate(0.1) end end

c.onUpdate(1)
check(#sent == 0, "disabled: nothing happens")
c.enable(true)
run(0.5)
check(#sent == 0, "no contact, no report")

-- contact with bob's car AND his traffic car; the speed changes at impact
map.objects[21].objectCollisions[11] = 1
map.objects[22].objectCollisions[11] = 1
mine.vel = v(2, 0, 0)            -- already slowed by the impact on the check where we first see the contact
price = 0
run(0.1)
price = 2400                      -- the damage shows up
run(0.5)
map.objects[21].objectCollisions[11] = nil
map.objects[22].objectCollisions[11] = nil
run(2)
check(#sent == 1 and sent[1].name == "rlsmpHit", "one report, for bob's car only (not his traffic)")
local r = sent[1].data
check(r.me == "0-1" and r.with == "1-1" and r.inv == 3 and r.model == "etk800", "report names both cars and my inventory slot")
check(r.mine.v[1] == 20 and r.other.v[1] == 0, "the snapshot is from just BEFORE the impact (20 m/s), not after")
check(r.damage == 2400, "damage = repair price after minus before: " .. tostring(r.damage))
check(r.nearby == 2, "two other cars nearby, traffic counts as a witness, the far one does not")

-- no RLS price function: report without damage (the server estimates)
sent = {}
overhaul_career_market_valueCalculator = nil
map.objects[21].objectCollisions[11] = 1
run(0.3) map.objects[21].objectCollisions[11] = nil run(2)
check(#sent == 1 and sent[1].data.damage == nil, "damage unknown -> reported as unknown")

-- walking: no reports
sent = {}
mine.jbeam = "unicycle"
map.objects[21].objectCollisions[11] = 1
run(0.5) map.objects[21].objectCollisions[11] = nil run(2)
check(#sent == 0, "walking players are not part of car crash claims")
mine.jbeam = "etk800"

-- server replies
handlers["rlsmpWhatCar"]("{}")
check(sent[#sent].name == "rlsmpMyCar" and sent[#sent].data.inv == 3 and sent[#sent].data.model == "etk800", "answers which car I am in")
handlers["rlsmpClaimPenalty"](json.encode({damage = 1800}))
check(claimed and claimed.damage == 1800 and claimed.inv == 3, "an RLS insurance claim is filed for the penalty")
print(string.format("claims_client_test: %d checks passed", passed))
