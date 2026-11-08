-- Spawn spot finder + traffic re-placement (LuaJIT): rlsmp_spawnSpot, rlsmp_trafficPlace. Run: luajit tests/spawn_spot_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- a tiny vec3
local V = {}
V.__index = V
function vec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, V) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function V:normalized() local l = math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) if l == 0 then l = 1 end return vec3(self.x / l, self.y / l, self.z / l) end
function V:rotated() return self end
quatFromDir = function() return {x = 0, y = 0, z = 0, w = 1} end
quat = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end

-- a grid of roads: nodes every 250 m over 6 km x 6 km; the road name is the column (x band of 500 m)
local nodes = {}
for ix = -12, 12 do for iy = -12, 12 do
  local k = ix .. "_" .. iy
  nodes[k] = {pos = vec3(ix * 250, iy * 250, 0), drivability = 1, links = {}}
end end
for ix = -12, 11 do for iy = -12, 12 do nodes[ix .. "_" .. iy].links[(ix + 1) .. "_" .. iy] = 1 end end
map = {
  getMap = function() return {nodes = nodes} end,
  findClosestRoad = function(p) return "road" .. math.floor(p.x / 500) end,
  surfaceNormal = function() return vec3(0, 0, 1) end,
}
local P = vec3(0, 0, 0)
getPlayerVehicle = function() return {getPosition = function() return P end, getDirectionVector = function() return vec3(0, 1, 0) end} end
core_camera = {getPosition = function() return vec3(0, 0, 2) end, getForward = function() return vec3(0, 1, 0) end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}
be = {getPlayerVehicleID = function() return 1 end}
rlsmp_bubble = {otherPlayers = function() return {} end, getRange = function() return {spawnMinDistance = 250, spawnMaxDistance = 4000} end}

local SP = require("rlsmp/spawnSpot")
math.randomseed(7)

-- 1. a cop spot: 1000..2500 m, right side, not the player's road, not in the 40 m corridor, not in view
local spot
for _ = 1, 20 do
  spot = SP.find({minDist = 1000, maxDist = 2500, preferRight = true, corridor = 40, why = "test"})
  if spot then break end
end
check(spot and spot.dist >= 1000 and spot.dist <= 2500 + 1, "a cop spot between 1000 and 2500 m")
check(spot.side < 0, "...on the player's right (side < 0)")
check(math.abs(spot.x) >= 40 and spot.road ~= "road0" and spot.road ~= "road-1", "...not on the player's own road, not in the 40 m corridor")
check(spot.q and spot.q.w == 1, "...with a rotation")
check(saw("spawn: test: spot") and saw("RIGHT"), "the log line says how far and on which side")

-- 2. no spot: the ring is empty (nothing between 9000 and 9500 m)
check(SP.find({minDist = 9000, maxDist = 9500, why = "far"}) == nil and saw("spawn: far: no spot"), "an empty ring gives nil and a log line")

-- 3. missing map or player: nil, no error
local savedMap = map.getMap
map.getMap = function() return nil end
check(SP.find({minDist = 1000, maxDist = 2500, why = "nomap"}) == nil and saw("no road map"), "no map: nil")
map.getMap = savedMap

-- 4. judge
local why, d = SP.judge({x = 0, y = 300, z = 0}, 1000, 40)
check(why == "near" and d == 300, "judge: a spot 300 m ahead is too near")
why = SP.judge({x = 10, y = 1500, z = 0}, 1000, 40)
check(why == "line", "judge: 1500 m straight ahead is refused")
check(SP.judge({x = 1500, y = 300, z = 0}, 1000, 40) == nil, "judge: 1500 m on the right is fine")

-- 5. traffic re-placement: a car the game just re-placed 150 m away goes into the 250..4000 m ring
local moved = {}
spawn = {safeTeleport = function(o, pos, rot, a, b, c, keep, reset) moved[#moved + 1] = {pos = pos, reset = reset} return true end}
local objects = {}
getObjectByID = function(id) return objects[id] end
local refreshed = 0
local traffic = {}
local function car(id, x, y) objects[id] = {} traffic[id] = {isAi = true, role = {name = "standard"}, respawnCount = 0, pos = {x = x, y = y, z = 0}, onRefresh = function() refreshed = refreshed + 1 end} end
gameplay_traffic = {getTrafficData = function() return traffic end}
local TP = require("rlsmp/trafficPlace")
TP.onExtensionLoaded()
car(5, 150, 150); car(6, 900, 900)
TP.check()                                       -- first look
check(#moved == 0, "first look: nothing")
traffic[5].respawnCount = 1
TP.onUpdate(2)
check(#moved == 1 and refreshed == 1, "a re-placed car is moved and refreshed (RLS's own after-respawn refresh)")
local mx, my = moved[1].pos.x, moved[1].pos.y
local md = math.sqrt(mx * mx + my * my)
check(md >= 250 - 5 and md <= 4000 + 5 and moved[1].reset == false, "...to 250..4000 m from the player, without repairing it")
check(saw("spawn: traffic car 5 re-placed by the game 212 m from you"), "the log says where the game put it and where we moved it")
-- one that the game already placed inside the ring is left alone
traffic[6].respawnCount = 1
TP.onUpdate(2)
check(#moved == 1, "a car the game placed 1273 m away (in the ring, out of the cone) is left alone")
-- police, hold, chase, off, one per second
car(7, 100, 100); traffic[7].role = {name = "police"}
TP.onUpdate(2)
traffic[7].respawnCount = 1
TP.onUpdate(2)
check(#moved == 1, "police are never moved by the traffic code")
car(8, 100, 100)
TP.onUpdate(2)
traffic[8].respawnCount = 1
rlsmp_police = {isPursuit = function() return true end}
TP.onUpdate(2)
check(#moved == 1, "not during a chase")
rlsmp_police = nil
traffic[8].respawnCount = 2
rlsmp_bubble.getRange = function() return {spawnMinDistance = 250, spawnMaxDistance = 0} end
TP.onUpdate(2)
check(#moved == 1, "spawnMaxDistance 0: the game's own placement")
rlsmp_bubble.getRange = function() return {spawnMinDistance = 250, spawnMaxDistance = 4000} end
traffic[8].respawnCount = 3
TP.onUpdate(2)
check(#moved == 2, "...and with the ring on again it moves")
-- no spot: the car stays
local savedFind = SP.find
rlsmp_spawnSpot = {find = function() return nil end, judge = SP.judge}
car(9, 100, 100)
TP.onUpdate(2)
traffic[9].respawnCount = 1
TP.onUpdate(2)
check(#moved == 2, "no spot found: the car stays where the game put it")
rlsmp_spawnSpot = nil

print(string.format("spawn_spot_client_test: %d checks passed", passed))
