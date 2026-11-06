-- Client unstuck test (LuaJIT). Run: luajit tests/unstuck_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
AddEventHandler = function(name, fn) _G.__handlers = _G.__handlers or {} _G.__handlers[name] = fn end
TriggerServerEvent = function() end

-- tiny vec3
local V = {}
V.__index = V
local function vec3(x, y, z) if type(x) == "table" then return setmetatable({x = x.x, y = x.y, z = x.z}, V) end return setmetatable({x = x, y = y or 0, z = z or 0}, V) end
V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, k) return vec3(a.x * k, a.y * k, a.z * k) end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
_G.vec3 = vec3
function quatFromDir() return "rot" end

local toasts, teleports = {}, {}
guihooks = {trigger = function(_, d) toasts[#toasts + 1] = d.msg end}
local player = {jbeam = "etk800", pos = vec3(10, 0, 0), speed = 0}
function player:getPosition() return self.pos end
function player:getVelocity() return vec3(self.speed, 0, 0) end
function player:getDirectionVector() return vec3(1, 0, 0) end
getPlayerVehicle = function() return player end
map = {
  findClosestRoad = function() return "road1", 5 end,
  getMap = function() return {nodes = {[5] = {pos = {x = 0, y = 0, z = 0}}}} end,
}
spawn = {safeTeleport = function(veh, pos, rot, a4, a5, a6, a7, reset) teleports[#teleports + 1] = {pos = pos, rot = rot, reset = reset} return true end}

local u = require("rlsmp/unstuck")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

u._onUnstuck()
check(#teleports == 0, "disabled does nothing")
u.enable(true)

u._onUnstuck()
check(teleports[1].pos.x == 0 and teleports[1].pos.y == 0, "car goes onto the road node")
check(teleports[1].reset == false, "the car is NOT reset, so damage stays")

player.jbeam, player.pos = "unicycle", vec3(10, 0, 0)
u._onUnstuck()
check(math.abs(teleports[2].pos.x - 3) < 1e-6, "walker lands 3 m from the road toward where they were")
player.pos = vec3(1, 0, 0)
u._onUnstuck()
check(math.abs(teleports[3].pos.x - 1) < 1e-6, "walker already close stays put (no overshoot)")

player.speed = 20
local before = #teleports
u._onUnstuck()
check(#teleports == before and toasts[#toasts]:find("Slow down"), "refused while moving fast")
player.speed = 0

overhaul_career_police_playerDriving = {playerPursuitActive = function() return true end}
u._onUnstuck()
check(#teleports == before and toasts[#toasts]:find("police"), "refused during a pursuit")
overhaul_career_police_playerDriving = nil

map.findClosestRoad = function() return nil end
u._onUnstuck()
check(#teleports == before and toasts[#toasts]:find("No road"), "no road found")

getPlayerVehicle = function() return nil end
u._onUnstuck()
check(toasts[#toasts]:find("Nothing"), "no vehicle")
print(string.format("unstuck_test: %d checks passed", passed))
