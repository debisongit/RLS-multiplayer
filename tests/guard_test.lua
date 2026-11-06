-- Vehicle guard test (LuaJIT). Run: luajit tests/guard_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local own = {[1] = true, [2] = true, [3] = true}
local entered, walking, toasts
MPVehicleGE = {getVehicles = function()
  local t = {}
  for id in pairs(own) do t["0-" .. id] = {gameVehicleID = id, isLocal = true} end
  t["1-9"] = {gameVehicleID = 9, isLocal = false}
  return t
end}
local traffic = {[2] = {isAi = true}, [3] = {isAi = false}}  -- 3 = player-driven traffic-system car (RLS job)
gameplay_traffic = {getTrafficData = function() return traffic end}
gameplay_parking = {getParkedCarsList = function() return {5} end}
own[5] = true
local objs = {[1] = {name = "car1", jbeam = "etk800"}, [3] = {name = "car3", jbeam = "etk800"}, [50] = {jbeam = "unicycle"},
  [9] = {jbeam = "etk800", getPosition = function() return setmetatable({x = 5, y = 6, z = 7}, {__add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}) end}}
be = {getObjectByID = function(_, id) return objs[id] end, enterVehicle = function(_, _, o) entered = o end}
local walkArgs
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
local function mkWalk() return {setWalkingMode = function(_, pos) walking = true walkArgs = pos end,
  isVehicleBlacklisted = function(id) return id == 99 end, getInVehicle = function(v) _G.__entered = v end} end
gameplay_walk = mkWalk()
guihooks = {trigger = function() toasts = (toasts or 0) + 1 end}

local g = require("rlsmp/vehicleGuard")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(g.isBlocked(9) == true, "other player's car blocked")
check(g.isBlocked(77) == false, "a car BeamMP does not know yet (just spawned) is allowed")
check(g.isBlocked(2) == true, "own AI traffic blocked")
check(g.isBlocked(5) == true, "parked car blocked")
check(g.isBlocked(1) == false, "own car allowed")
check(g.isBlocked(3) == false, "player-driven traffic-system car allowed (RLS jobs)")
check(g.isBlocked(-1) == false, "no vehicle is fine")

g.onVehicleSwitched(1, 9)
check(entered == nil, "disabled guard does nothing")
g.enable(true)
g.onVehicleSwitched(1, 9)
check(entered == objs[1] and toasts == 1, "put back in the previous car")
entered, walking = nil, nil
g.onVehicleSwitched(9, 2)
check(walking and entered == nil, "no valid previous car -> on foot")
entered = nil
g.onVehicleSwitched(1, 3)
check(entered == nil, "allowed switch untouched")
-- refused up front: RLS asks gameplay_walk before it lets a walking player in
local g2 = require("rlsmp/vehicleGuard")
g2.enable(true)
local walk = gameplay_walk
local origIn = walk.getInVehicle
check(g2.install() == true and walk.getInVehicle ~= origIn, "walking module is wrapped")
local wrappedFn = walk.getInVehicle
g2.install()
check(walk.getInVehicle == wrappedFn, "installing again does not stack wrappers")
check(walk.isVehicleBlacklisted(9) == true, "another player's car counts as blacklisted for entering")
check(walk.isVehicleBlacklisted(1) == false and walk.isVehicleBlacklisted(99) == true, "own cars pass, the game's own blacklist still applies")
_G.__entered = nil
local t0 = toasts
walk.getInVehicle({getID = function() return 9 end})
check(_G.__entered == nil and toasts == t0 + 1, "entering a remote car is refused with a message and nothing is switched")
walk.getInVehicle({getID = function() return 1 end})
check(_G.__entered ~= nil, "entering your own car works as before")
gameplay_walk = mkWalk()
check(g2.install() == true and gameplay_walk.getInVehicle ~= nil, "a reloaded walking module is wrapped again")

-- a switch that slips through while walking: no re-entering the (deleted) walking character
entered, walking, walkArgs = nil, nil, nil
g2.onVehicleSwitched(50, 9)
check(entered == nil and walking == true, "walker is put back on foot, not into the deleted character")
check(walkArgs and walkArgs.x == 5 and walkArgs.y == 6, "on foot beside the refused car, not at a default spawn")

print(string.format("guard_test: %d checks passed", passed))
