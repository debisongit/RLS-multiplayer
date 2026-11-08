-- Traffic fill test (LuaJIT). Run: luajit tests/traffic_fill_client_test.lua
-- The real rlsmp_trafficFill and rlsmp_trafficSwap (async one-car spawn) with a fake game: cars are added one at a time up to min(quota, minAmount).
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = level .. "|" .. tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end

local V = require("rlsmp/lib/trafficVariety")
local F = require("rlsmp/lib/trafficFill")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure logic ---------------------------------------------------------------------------------------------------------------------------
check(F.want(15, 10) == 10 and F.want(6, 10) == 6 and F.want(nil, 10) == 0 and F.want(15, 0) == 0, "want = min(quota, minAmount); 0 when unknown")
check(F.groupSize(4, 10, 0) == 10 and F.groupSize(4, 10, 3) == 4 and F.groupSize(12, 10, 0) == 12 and F.groupSize(1, 10, 0) == 1, "group size")
check(select(2, F.decide({have = 10, want = 10, now = 100})) == "done", "enough cars: done")
check(select(2, F.decide({have = 9, want = 10, pending = 1, now = 100})) == "done", "one is on its way: done")
check(select(2, F.decide({have = 5, want = 10, pending = 1, now = 100})) == "pending", "one at a time")
check(select(2, F.decide({have = 5, want = 10, now = 100, last = 98})) == "gap", "not twice within a few seconds")
check(select(2, F.decide({have = 5, want = 10, now = 100, own = 97, maxCars = 100})) == "maxCars", "stops below BeamMP's limit")
check(F.decide({have = 5, want = 10, now = 100, own = 96, maxCars = 100}) == "spawn", "a margin of 3 is kept")
check(select(2, F.decide({have = 5, want = 10, now = 100, own = 57})) == "maxCars", "unknown limit: a safe default")
check(select(2, F.decide({have = 5, want = 10, now = 100, failures = 3})) == "failures", "stops after failures")

-- the fake game ------------------------------------------------------------------------------------------------------------------------------
local objects, nextId = {}, 100
local function addObject(id, jbeam) objects[id] = {jbeam = jbeam, getID = function() return id end} end
be = {
  getObjectCount = function() local n = 0 for _ in pairs(objects) do n = n + 1 end return n end,
  getObject = function(_, i) local k = 0 for _, o in pairs(objects) do if k == i then return o end k = k + 1 end end,
  getObjectByID = function(_, id) return objects[id] end,
  getPlayerVehicleID = function() return 1 end,
}
getObjectByID = function(id) return objects[id] end
local td, inserted, activeAmount, state = {}, {}, 10, "on"
local function addTraffic(id) addObject(id, "sedan") td[id] = {isAi = true, role = {name = "standard"}, state = "active"} end
gameplay_traffic = {
  getTrafficData = function() return td end,
  getTrafficVars = function() return {activeAmount = activeAmount} end,
  getState = function() return state end,
  insertTraffic = function(id) inserted[#inserted + 1] = id td[id] = {isAi = true, role = {name = "standard"}, state = "active"} end,
}
local groupCalls = {}
local mt = {__unm = function(a) return setmetatable({x = -a.x, y = -a.y, z = -a.z}, getmetatable(a)) end}
mt.__index = {rotated = function(a) return a end}
vec3 = function(x, y, z) return setmetatable({x = x, y = y, z = z}, mt) end
quat = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end
quatFromDir = function() return quat(0, 0, 0, 1) end
core_multiSpawn = {spawnGroup = function(group, amount, params) groupCalls[#groupCalls + 1] = {group = group, amount = amount, params = params} return true end}
core_camera = {getPosition = function() return vec3(0, 0, 0) end, getForward = function() return vec3(0, 1, 0) end}
map = {surfaceNormal = function() return vec3(0, 0, 1) end}
local place = true
gameplay_traffic_trafficUtils = {
  findSafeSpawnPoint = function() return place and {pos = vec3(0, -200, 0), dir = vec3(0, 1, 0), n1 = 1, n2 = 2} or nil end,
  finalizeSpawnPoint = function(pos, dir) return pos, dir end,
}
local own = 6
MPVehicleGE = {getVehicles = function() local t = {} for i = 1, own do t[i] = {isLocal = true, gameVehicleID = i} end return t end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}

local want, chase = 10, false
package.loaded["rlsmp/traffic"] = {getWant = function() return want end}
package.loaded["rlsmp/police"] = {isPursuit = function() return chase end}
local picks = 0
local cfg = V.sanitize({preload = {slowFrameMs = 2000, minGapSeconds = 0, settleSeconds = 0}, maxCars = 100})
package.loaded["rlsmp/trafficVariety"] = {
  getConfig = function() return cfg end,
  pickReplacement = function() picks = picks + 1 return {model = "hatch", config = "h" .. picks} end,
  candidates = function() return {} end,
  brandOf = function() return "B" end,
  noteWarm = function() end,
}
local TS = require("rlsmp/trafficSwap")
package.loaded["rlsmp/trafficSwap"] = TS
local T = require("rlsmp/trafficFill")

local function step(sec) for _ = 1, math.max(1, math.floor(sec / 0.5)) do T.onUpdate(0.5) TS.onUpdate(0.5) end end   -- half-second frames
-- one round: the check runs, and when it started a spawn the game's queue answers
local function round()
  step(5)
  if #groupCalls > 0 and TS.isFillBusy() then
    nextId = nextId + 1
    addObject(nextId, "hatch")
    TS.onVehicleGroupSpawned({nextId}, 1, "rlsmpFill")
  end
end
addObject(1, "unicycle")
for i = 11, 15 do addTraffic(i) end   -- the game made 5 cars

-- 1. cars are added one at a time up to the want ---------------------------------------------------------------------------------------------------
step(1)
check(#groupCalls == 1 and groupCalls[1].params.name == "rlsmpFill" and groupCalls[1].amount == 1, "first check: one car through the one-car group spawn")
check(groupCalls[1].params.customTransforms[1].pos.y == -200, "placed at the spawn point behind the camera")
check(saw("fill: have=5 want=10, adding cars one at a time"), "the fill start is logged")
step(5)
check(#groupCalls == 1, "a spawn is waiting for its car: no second one")
nextId = nextId + 1 addObject(nextId, "hatch") TS.onVehicleGroupSpawned({nextId}, 1, "rlsmpFill")
check(#inserted == 1 and inserted[1] == nextId and T.isNew(nextId), "the new car is given to RLS traffic and marked new")
check(saw("fill: car " .. nextId .. " hatch/h1 added"), "added car is logged")
for _ = 1, 10 do round() end
local n = 0 for _ in pairs(td) do n = n + 1 end
check(n == 10 and #groupCalls == 5 and #inserted == 5, "exactly the missing 5 cars were built, never more")
check(saw("fill: done have=10 want=10 spawned=5"), "done is logged")
check(not T.isNew(11), "the game's own cars are never marked new")
for _ = 1, 3 do round() end
check(#groupCalls == 5, "at the want: nothing more")

-- 2. the want is the lower of quota and minimum: a lower want adds fewer -------------------------------------------------------------------------
logged, groupCalls = {}, {}
td = {} for i = 11, 15 do addTraffic(i) end
T.onServerLeave()
want = 7
for _ = 1, 10 do round() end
n = 0 for _ in pairs(td) do n = n + 1 end
check(n == 7 and #groupCalls == 2, "want 7: two cars added")

-- 3. gates -----------------------------------------------------------------------------------------------------------------------------------------
logged, groupCalls = {}, {}
td = {} for i = 11, 15 do addTraffic(i) end
T.onServerLeave()
want = 10
chase = true step(5) step(5)
check(#groupCalls == 0 and saw("fill: waiting (chase)"), "no building in a chase")
chase = false activeAmount = 0 step(5)
check(#groupCalls == 0 and saw("fill: waiting (amount lowered)"), "an event cut the traffic amount: left alone")
activeAmount = 10 state = "off" step(5)
check(#groupCalls == 0 and saw("fill: waiting (traffic off)"), "traffic off: nothing")
state = "on"
own = 98 step(5)
check(#groupCalls == 0 and saw("W|RLSMP-P3|fill: refused (maxCars)"), "near BeamMP's car limit: refused with a warning")
own = 6 place = false step(5)
check(#groupCalls == 0 and saw("fill: refused (no place)"), "no spawn point: refused")
place = true
step(5)
check(#groupCalls == 1, "all gates open: spawns")

-- 4. a spawn that never answers is a failure and the fill switches itself off after three ------------------------------------------------------------
TS.onServerLeave() T.onServerLeave() logged, groupCalls = {}, {}
td = {} for i = 11, 15 do addTraffic(i) end
for _ = 1, 40 do step(10) end
check(#groupCalls == 3 and TS.isLiveOff() and saw("fill: refused (failures)"), "three timeouts: no more spawning")

-- 5. cars we added are left alone for a while only -----------------------------------------------------------------------------------------------------
TS.onServerLeave() T.onServerLeave() logged, groupCalls = {}, {}
td = {} for i = 11, 15 do addTraffic(i) end
step(1) nextId = nextId + 1 addObject(nextId, "hatch") TS.onVehicleGroupSpawned({nextId}, 1, "rlsmpFill")
check(T.isNew(nextId), "new right after")
step(130)
check(not T.isNew(nextId), "after the grace time the normal rules apply again")

print(string.format("traffic_fill_client_test: %d checks passed", passed))
