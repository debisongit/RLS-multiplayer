-- Parked cars kept near the player (LuaJIT). Run: luajit tests/parked_near_test.lua
-- Fakes RLS's parking service (spots, occupancy, moveToParkingSpot) and the player.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local V = require("rlsmp/lib/trafficVariety")
local Pk = require("rlsmp/lib/parked")

-- lib ---------------------------------------------------------------------------------------------------------------------------------------
local me = {x = 0, y = 0}
local function car(id, x, busy) return {id = id, pos = {x = x, y = 0}, busy = busy} end
check(Pk.nearWanted({nearCount = 6, nearNightCount = 10}, false) == 6 and Pk.nearWanted({nearCount = 6, nearNightCount = 10}, true) == 10, "day 6, night 10")
check(Pk.nearWanted({nearCount = 0, nearNightCount = 10}, true) == 0, "nearCount 0 = off")
check(Pk.nearWanted({nearCount = 6, nearNightCount = 3}, true) == 6, "night never fewer than day")
local mv = Pk.pickMove({car(1, 100), car(2, 900), car(3, 5000)}, me, {}, 3, 350, 700)
check(mv and mv.id == 3 and mv.near == 1 and mv.far == 2, "the farthest far car is picked")
local _, why = Pk.pickMove({car(1, 100), car(2, 200), car(3, 300)}, me, {}, 3, 350, 700)
check(why == "enough", "enough near cars")
_, why = Pk.pickMove({car(1, 100), car(2, 500)}, me, {}, 3, 350, 700)
check(why == "none", "nothing farther than farRadius: nothing to move")
mv = Pk.pickMove({car(1, 900, true), car(2, 800)}, me, {}, 3, 350, 700)
check(mv and mv.id == 2, "a busy car (stolen, inspected) is never picked")
mv = Pk.pickMove({car(1, 5000), car(2, 800)}, me, {{x = 5000, y = 100}}, 3, 350, 700)
check(mv and mv.id == 2, "a car near ANOTHER player is left alone")
check(select(2, Pk.pickMove({car(1, 900)}, me, {}, 0, 350, 700)) == "disabled", "want 0 = disabled")
local s = Pk.sample({1, 2, 3, 4, 5}, 3, function() return 1 end)
check(#s == 3 and s[1] == 1 and s[2] == 2, "sample takes n entries")
check(Pk.spaced({x = 0, y = 0}, {{x = 100, y = 0}}, 40) and not Pk.spaced({x = 0, y = 0}, {{x = 10, y = 0}}, 40), "spots keep a gap to other parked cars")

-- config --------------------------------------------------------------------------------------------------------------------------------------
local c = V.sanitize({parked = {nearRadius = 5000, farRadius = 10, moveEverySeconds = 0}}).parked
check(c.nearRadius == 1500 and c.farRadius >= c.nearRadius + 50 and c.moveEverySeconds == 2, "nearRadius/farRadius/moveEverySeconds are limited")
c = V.sanitize({}).parked
check(c.nearCount == 6 and c.nearNightCount == 10 and c.nearRadius == 350 and c.farRadius == 700 and c.moveEverySeconds == 8, "defaults")

-- the game ----------------------------------------------------------------------------------------------------------------------------------
local objs, speed, moves, refuse = {}, 0, {}, false
local function mkObj(x, y) local o = {x = x, y = y} function o:getPosition() return {x = self.x, y = self.y, z = 0} end function o:isReady() return false end
  function o:getVelocity() local v = speed return {length = function() return v end} end return o end
function getObjectByID(id) return objs[id] end
be = {getPlayerVehicleID = function() return 100 end}
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
objs[100] = mkObj(0, 0)
local ids = {}
for i = 1, 9 do ids[i] = i objs[i] = mkObj(2000 + i * 100, 0) end   -- nine cars far away
local spotsList = {}
for i = 1, 30 do spotsList[i] = {ps = {pos = {x = 250 * math.cos(i * 0.209), y = 250 * math.sin(i * 0.209)}, id = i}} end
overhaul_integration_services_parking = {
  getParkedCarsList = function() return ids end,
  getParkedCarsData = function() return {} end,
  isSpawnPending = function() return false end,
  findParkingSpots = function(_, minR, maxR) check(minR == 120 and maxR == 350, "RLS is asked for spots 120..350 m") return spotsList end,
  filterParkingSpots = function(e, f) check(type(f) == "table" and f.avoidVisible and f.checkVehicles, "filters are a table (no day/night odds)") return e end,
  checkParkingSpot = function() return true end,
  moveToParkingSpot = function(id, ps) if refuse then return false end objs[id].x, objs[id].y = ps.pos.x, ps.pos.y moves[#moves + 1] = id return true end,
}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}
settings = {getValue = function(k) return k == "trafficParkedVehicles" and true or 10 end, setValue = function() end}
local night, config = false, nil
package.loaded["rlsmp/trafficVariety"] = {getConfig = function() return config end, contextNow = function() return {night = night} end}
local reported = 0
package.loaded["rlsmp/theft"] = {holdsCar = function(id) return id == 9 end, reportParked = function() reported = reported + 1 end}
package.loaded["rlsmp/trafficSwap"] = {isBusy = function() return false end, canBuild = function() return true end}
config = V.sanitize({parked = {nearCount = 3, nearNightCount = 5, moveEverySeconds = 8}})

local T = require("rlsmp/parked")
local function nearCount() local n = 0 for _, i in ipairs(ids) do local o = objs[i] if math.sqrt(o.x ^ 2 + o.y ^ 2) <= 350 then n = n + 1 end end return n end
local function tick(seconds) for _ = 1, seconds * 50 do T.onUpdate(0.02) end end

tick(60)
check(#moves == 3 and nearCount() == 3, "3 cars end up near the player (" .. #moves .. " moves)")
check(not saw("not moved"), "no failures")
check(saw("parked near: moved car") and saw("near 0 -> 1 of 3"), "the move is logged with counts")
check(reported >= 3, "the parked report is refreshed after a move")
tick(60)
check(#moves == 3, "enough near cars: no more moves")

-- the rate: one move per moveEverySeconds
for _, i in ipairs(ids) do objs[i].x = 3000 end   -- all far again
moves = {}
tick(7) T.onServerLeave() moves = {}
tick(1) tick(1)
check(#moves <= 1, "at most one move per call window")

-- a held car (being stolen) stays, a fast player gets nothing, a slow frame stops moves
T.onServerLeave() for _, i in ipairs(ids) do objs[i].x = 3000 end moves = {}
speed = 30 tick(40)
check(#moves == 0, "driving fast: no moves")
speed = 0
for _ = 1, 100 do T.onUpdate(0.1) end   -- 10 fps for 10 s
check(#moves == 0, "slow frames: no moves")
tick(30)
for _, id in ipairs(moves) do check(id ~= 9, "the car theft holds (9) is never moved") end

-- night wants more
T.onServerLeave() for _, i in ipairs(ids) do objs[i].x = 3000 end moves = {} night = true
tick(120)
check(nearCount() == 5, "night: 5 near cars")
night = false

-- RLS refuses: logged, survived
T.onServerLeave() for _, i in ipairs(ids) do objs[i].x = 3000 end moves = {} refuse = true logged = {}
tick(30)
check(#moves == 0 and saw("not moved"), "a refused move is logged, nothing breaks")
refuse = false

-- off by config, and with no spots
T.onServerLeave() for _, i in ipairs(ids) do objs[i].x = 3000 end moves = {}
config = V.sanitize({parked = {nearCount = 0}}) tick(60)
check(#moves == 0, "nearCount 0 = off")
config = V.sanitize({parked = {nearCount = 3}}) spotsList = {} T.onServerLeave() logged = {} tick(30)
check(#moves == 0 and saw("no free spot"), "no spots: logged")

print(string.format("parked_near_test: %d checks passed", passed))
