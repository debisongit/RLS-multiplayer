-- Traffic bubble test (LuaJIT). Run: luajit tests/bubble_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local function V(x, y) local v = {x = x, y = y} v.squaredDistance = function(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 end return v end
MPCoreNetwork = {isMPSession = function() return true end}
local remote = {["1-3"] = {gameVehicleID = 30, isLocal = false}, ["1-4"] = {gameVehicleID = 31, isLocal = false, hideNametag = true}, ["0-1"] = {gameVehicleID = 5, isLocal = true}}
MPVehicleGE = {getVehicles = function() return remote end}
map = {objects = {[30] = {pos = V(1000, 0)}, [31] = {pos = V(0, 10)}, [5] = {pos = V(0, 0)}}}
local respawned = 0
local sees = false
local class = {tryRespawn = function() respawned = respawned + 1 end}
class.checkRayCast = function() return sees end
local car = setmetatable({pos = V(0, 0), id = 9}, {__index = class})
gameplay_traffic = {getTrafficData = function() return {[9] = setmetatable({}, class)} end}
-- the data table's metatable must be the class itself (as in RLS): use a table with class as metatable
local inst = setmetatable({pos = V(0, 0)}, class) class.__index = class
gameplay_traffic = {getTrafficData = function() return {[9] = inst} end}
local b = require("rlsmp/bubble")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(b.install(), "installs")
local w = class.tryRespawn
b.install()
check(class.tryRespawn == w, "wrapped only once")
inst:tryRespawn()
check(respawned == 1, "disabled: RLS decides")
b.enable(true)
inst.pos = V(0, 0)         -- 1000 m from the other player, no line of sight
inst:tryRespawn()
check(respawned == 2, "far from every player and out of sight: may be recycled")
inst.pos = V(700, 0)       -- 300 m from the other player
inst:tryRespawn()
check(respawned == 2, "within 450 m of another player: stays")
inst.pos = V(0, 0) sees = true
inst:tryRespawn()
check(respawned == 2, "far but in line of sight: stays")
sees = false
remote["1-3"] = nil
inst:tryRespawn()
check(respawned == 3, "only other players' traffic left: not a reason to stay")
-- RLS replaces the method: we wrap the new one
class.tryRespawn = function() respawned = respawned + 10 end
b.install()
inst:tryRespawn()
check(respawned == 13, "a replaced method is wrapped again")
print("bubble_test: " .. passed .. " checks passed")
