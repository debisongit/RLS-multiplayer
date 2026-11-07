-- Client position reports (LuaJIT). Run: luajit tests/positions_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent = {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function() end
local at, speed = {x = 0, y = 0, z = 0}, 0
local hasCar = true
getPlayerVehicle = function()
  if not hasCar then return nil end
  return {getPosition = function() return at end,
          getVelocity = function() return {length = function() return speed end} end}
end
local chase = false
rlsmp_police = {isPursuit = function() return chase end}
local net = require("rlsmp/lib/net")
net.init()
local positions = require("rlsmp/positions")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function count() local n = 0 for _, s in ipairs(sent) do if s.name == "rlsmpPos" then n = n + 1 end end return n end
local function last() for i = #sent, 1, -1 do if sent[i].name == "rlsmpPos" then return sent[i].data end end end
local function run(seconds) for _ = 1, math.floor(seconds * 10 + 0.5) do positions.onUpdate(0.1) end end

run(5)
check(count() == 0, "nothing while disabled")
positions.enable(true)
at, speed = {x = 1.234, y = 2, z = 3}, 7.77
run(2)
local p = last()
check(count() == 1 and p.x == 1.2 and p.y == 2 and p.z == 3 and p.speed == 7.8 and p.chased == false, "first report, rounded")
run(6)
check(count() == 1, "standing still: skipped")
at = {x = 20, y = 2, z = 3}
run(2)
check(count() == 2 and last().x == 20, "moved: sent")
run(10)
check(count() == 3, "standing still: still sent every 10 s")
run(2)
chase = true
positions.onUpdate(0.1)
check(count() == 4 and last().chased == true, "chase start goes out at once")
chase = false
positions.onUpdate(0.1)
check(count() == 4, "no second report within 1.5 s")
run(1.5)
check(count() == 5 and last().chased == false, "chase end goes out once allowed")
hasCar = false
at = {x = 500, y = 0, z = 0}
run(20)
check(count() == 5, "no vehicle: nothing sent")
hasCar = true
rlsmp_police = nil
run(2)
check(count() == 6 and last().chased == false, "works without the police extension")
positions.enable(false)
run(20)
check(count() == 6, "disabled again: quiet")
positions.enable(true)
run(2)
check(count() == 7, "re-enabled: sends right away even without moving")
run(1)
local before = count()
positions.reportNow()
positions.onUpdate(0.1)
check(count() == before + 1, "reportNow: sent on the next frame without moving")
positions.enable(false)
positions.reportNow()
run(3)
check(count() == before + 1, "reportNow does nothing while disabled")
print("positions_client_test: " .. passed .. " checks passed")
