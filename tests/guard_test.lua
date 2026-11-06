-- Vehicle guard test (LuaJIT). Run: luajit tests/guard_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local own = {[1] = true, [2] = true, [3] = true}
local entered, walking, toasts
MPVehicleGE = {isOwn = function(id) return own[id] == true end}
local traffic = {[2] = {isAi = true}, [3] = {isAi = false}}  -- 3 = player-driven traffic-system car (RLS job)
gameplay_traffic = {getTrafficData = function() return traffic end}
gameplay_parking = {getParkedCarsList = function() return {5} end}
own[5] = true
local objs = {[1] = "car1", [3] = "car3"}
be = {getObjectByID = function(_, id) return objs[id] end, enterVehicle = function(_, _, o) entered = o end}
gameplay_walk = {setWalkingMode = function() walking = true end}
guihooks = {trigger = function() toasts = (toasts or 0) + 1 end}

local g = require("rlsmp/vehicleGuard")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(g.isBlocked(9) == true, "other player's car blocked")
check(g.isBlocked(2) == true, "own AI traffic blocked")
check(g.isBlocked(5) == true, "parked car blocked")
check(g.isBlocked(1) == false, "own car allowed")
check(g.isBlocked(3) == false, "player-driven traffic-system car allowed (RLS jobs)")
check(g.isBlocked(-1) == false, "no vehicle is fine")

g.onVehicleSwitched(1, 9)
check(entered == nil, "disabled guard does nothing")
g.enable(true)
g.onVehicleSwitched(1, 9)
check(entered == "car1" and toasts == 1, "put back in the previous car")
entered, walking = nil, nil
g.onVehicleSwitched(9, 2)
check(walking and entered == nil, "no valid previous car -> on foot")
entered = nil
g.onVehicleSwitched(1, 3)
check(entered == nil, "allowed switch untouched")
print(string.format("guard_test: %d checks passed", passed))
