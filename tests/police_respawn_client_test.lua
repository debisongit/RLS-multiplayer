-- Police respawn client test (LuaJIT): a re-placed cop that is too near / in view / on the player's road / straight ahead is moved far away as another model.
-- Run: luajit tests/police_respawn_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
TriggerServerEvent = function() end
AddEventHandler = function() end

local S = require("rlsmp/lib/spawnSpot")
local mp, career = true, true
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
local PLAYER = 1
be = {getPlayerVehicleID = function() return PLAYER end}
-- the player stands at 0,0 and looks along +y; "right" is +x
local P, D = {x = 0, y = 0, z = 0}, {x = 0, y = 1}
getPlayerVehicle = function() return {getPosition = function() return P end, getDirectionVector = function() return {x = 0, y = 1, z = 0} end} end
local objects, traffic, removed, inserted, roles, groups = {}, {}, {}, {}, {}, {}
local function newObject(id, x, y, model) objects[id] = {id = id, jbeam = model, pos = {x = x, y = y, z = 0}} return objects[id] end
getObjectByID = function(id)
  local o = objects[id]
  if not o then return nil end
  return {jbeam = o.jbeam, getPosition = function() return o.pos end, delete = function() removed[#removed + 1] = "obj:" .. id objects[id] = nil end}
end
local function cop(id, x, y, model, rc)
  newObject(id, x, y, model)
  traffic[id] = {isAi = true, role = {name = "police"}, respawnCount = rc or 0, pos = {x = x, y = y, z = 0}, jbeam = model}
  return traffic[id]
end
local function replaced(id, x, y)       -- the game re-placed cop id at x, y
  traffic[id].respawnCount = traffic[id].respawnCount + 1
  traffic[id].pos = {x = x, y = y, z = 0}
  objects[id].pos = traffic[id].pos
end
gameplay_traffic = {
  getTrafficData = function() return traffic end,
  insertTraffic = function(id, isPlayer, noPool)
    inserted[#inserted + 1] = {id = id, isPlayer = isPlayer, noPool = noPool}
    traffic[id] = traffic[id] or {isAi = true, role = {name = "standard"}, respawnCount = 0, pos = objects[id] and objects[id].pos}
    traffic[id].setRole = function(self, role) roles[#roles + 1] = {id = id, role = role} self.role = {name = role} end
  end,
  removeTraffic = function(id) removed[#removed + 1] = "traffic:" .. id traffic[id] = nil end,
}
core_multiSpawn = {spawnGroup = function(group, amount, params) groups[#groups + 1] = {group = group, amount = amount, params = params} end}
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
quat = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end
local teleports = {}
spawn = {safeTeleport = function(o, pos, rot, a, b, c, keep) teleports[#teleports + 1] = {obj = o, pos = pos, keep = keep} return true end}
local picks = {{model = "vivace", config = "police_a"}, {model = "bastion", config = "police_b"}}
local pickCalls = {}
rlsmp_trafficVariety = {policePick = function(avoid)
  pickCalls[#pickCalls + 1] = avoid
  for _, e in ipairs(picks) do if e.model ~= avoid then return {model = e.model, config = e.config} end end
  return nil
end}
-- the game-side spot finder, stubbed: judge uses the real rules, find returns whatever the test sets
local findCalls, spotToReturn = {}, nil
rlsmp_spawnSpot = {
  judge = function(pos, min, corridor)
    local c = {x = pos.x, y = pos.y, z = pos.z}
    return S.reject(c, {player = P, dir = D, minDist = min, corridor = corridor or 0, others = {}}), (S.rel(P, D, c))
  end,
  find = function(o) findCalls[#findCalls + 1] = o return spotToReturn end,
}
local chase = false
rlsmp_police = {isPursuit = function() return chase end}
local function spotAt(x, y) return {x = x, y = y, z = 0, q = {x = 0, y = 0, z = 0, w = 1}, dist = math.sqrt(x * x + y * y), side = x > 0 and -1 or 1} end

local R = require("rlsmp/policeRespawn")
R.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function tick(n) for _ = 1, n or 1 do R.onUpdate(0.5) end end
local function reset() removed, inserted, roles, groups, teleports, findCalls = {}, {}, {}, {}, {}, {} end
local st = R.getState().settings
st.rebuildSeconds = 0

-- defaults: no extra cops, 1000 m, 600 m in a chase, right side preferred
check(st.copCount == 0 and st.spawnMinDistance == 1000 and st.chaseSpawnMinDistance == 600 and st.preferRight == true, "defaults: copCount 0, 1000 m, 600 m in a chase, prefer right")
check(st.gap == nil, "the gap-behind setting is gone")
local mn, mx = R.limits(false)
check(mn == 1000 and mx == 2500, "ring 1000 to 2500 m outside a chase")
mn, mx = R.limits(true)
check(mn == 600 and mx == 1500, "ring 600 to 1500 m in a chase")

-- pure helper still there
local a, d = R.relative({x = 0, y = 0}, {x = 0, y = 1}, {x = 0, y = 100})
check(a == true and math.abs(d - 100) < 1e-9, "relative: a point along the heading is in front")

-- 1. first sight only remembers the counter
cop(10, 0, -400, "bastion", 3)
tick()
check(#groups == 0 and R.getState().seen[10] == 3, "first look: nothing happens")

-- 2. the game re-places the cop 300 m ahead: not allowed; a spot 1400 m away on the right is found; a different model is built THERE
spotToReturn = spotAt(1200, 700)
replaced(10, 0, 300)
tick()
check(#findCalls == 1 and findCalls[1].minDist == 1000 and findCalls[1].maxDist == 2500 and findCalls[1].preferRight == true and findCalls[1].corridor == 40,
  "spot search: ring 1000..2500 m, right preferred, 40 m corridor")
check(#groups == 1 and groups[1].amount == 1 and groups[1].params.name == "rlsmpCop", "one car asked for through the group spawn")
local tr = groups[1].params.customTransforms
check(tr and tr[1].pos.x == 1200 and tr[1].pos.y == 700 and groups[1].params.gap ~= 150, "...at the found spot (customTransforms), not 150 m behind")
check(groups[1].group[1].model == "vivace" and pickCalls[#pickCalls] == "bastion", "...of a model other than the old one")
check(saw("cop 10 re-placed 300 m from the player: not allowed (near"), "the log says why")
check(#removed == 0, "300 m away is not 'close': the old cop stays until the new one is ready")
reset()

-- 3. the new car comes out where asked: becomes police, the old cop is removed
newObject(50, 1200, 700, "vivace")
R.onVehicleGroupSpawned({50}, 7, "rlsmpCop")
check(inserted[1] and inserted[1].id == 50 and inserted[1].isPlayer == false and inserted[1].noPool == true, "the new car is given to traffic")
check(roles[1] and roles[1].role == "police", "...with the police role")
check(table.concat(removed, ","):find("traffic:10", 1, true), "...and the old cop is removed")
check(saw("new cop 50 came out 1389 m from the player"), "its place is logged")
reset()

-- 4. a re-placed cop that is already fine (1500 m away on another road) is left alone
cop(11, 0, -700, "vivace", 0)
tick()
replaced(11, 1500, 300)
tick()
check(#findCalls == 0 and #groups == 0 and #teleports == 0 and saw("cop 11 re-placed 1530 m from the player: fine"), "a cop 1500 m away off the player's line: left alone")

-- 5. 1500 m STRAIGHT AHEAD (inside the 40 m corridor) and 1500 m straight BEHIND are refused
reset()
replaced(11, 10, 1500)
tick()
check(saw("not allowed (line") and #findCalls == 1, "straight ahead, even far away, is refused")
spotToReturn = nil
replaced(11, -5, -1500)
tick()
check(saw("not allowed (line") and #findCalls == 2 and #groups == 1, "straight behind is refused too; no spot found = the cop stays, nothing built beyond the first")
reset(); R.onServerLeave()

-- 6. a new car that comes out too close is deleted again; failures count
cop(12, 0, -700, "bastion", 0)
st.rebuildSeconds = 0
tick()
spotToReturn = spotAt(1200, 700)
replaced(12, 0, 400)
tick()
check(#groups == 1, "build started")
newObject(51, 100, 100, "vivace")
R.onVehicleGroupSpawned({51}, 8, "rlsmpCop")
check(saw("came out too near or in view (near") and table.concat(removed, ","):find("obj:51", 1, true) and not table.concat(removed, ","):find("traffic:12", 1, true), "too close: the new car is deleted, the old cop kept")
check(R.getState().failures.respawn == 1 and R.getState().mine[51] == nil, "...and it counts as a failure")
reset()

-- 7. between builds (rebuild interval) the bad cop is MOVED to the spot, no build
R.onServerLeave()
st.rebuildSeconds = 90
cop(13, 0, -900, "bastion", 0)
tick()
tick(200)                                       -- the interval since the start of the session has passed
replaced(13, 0, 200)
spotToReturn = spotAt(1300, 400)
tick()
check(#groups == 1, "first one after the interval: a build")
newObject(52, 1300, 400, "vivace")
R.onVehicleGroupSpawned({52}, 9, "rlsmpCop")
reset()
cop(14, 0, -900, "bastion", 0)
tick()
replaced(14, 0, 200)
tick()
check(#groups == 0 and #teleports == 1 and teleports[1].pos.x == 1300 and teleports[1].keep == true, "inside the rebuild interval: the cop is moved to the spot (no build)")
check(saw("cop 14 moved to a spot") and saw("right side"), "...and the log says so")
-- teleport failing three times switches moving off
spawn.safeTeleport = function() return false end
for i = 1, 4 do replaced(14, 0, 200) tick(25) tick() end
check(saw("moving cops is switched off"), "three failed moves switch moving off for the session")
spawn.safeTeleport = function(o, pos, rot, a2, b2, c2, keep) teleports[#teleports + 1] = {obj = o, pos = pos, keep = keep} return true end
reset()

-- 8. in a chase the minimum is 600 m (a shorter ring); reinforcements 700 m away on the right are fine
R.onServerLeave()
chase = true
cop(15, 0, -900, "bastion", 0)
tick()
replaced(15, 700, 100)
tick()
check(#findCalls == 0 and saw("cop 15 re-placed 707 m from the player: fine"), "in a chase 700 m away (right side) is allowed")
replaced(15, 0, 250)
tick()
check(#findCalls == 1 and findCalls[1].minDist == 600 and findCalls[1].maxDist == 1500, "in a chase a bad spot searches the ring 600..1500 m")
chase = false
reset()

-- 9. switch, multiplayer, career
R.onServerLeave()
cop(16, 0, -900, "bastion", 0)
tick()
R._onConfig({respawnBehind = false})
replaced(16, 0, 100)
tick(2)
check(#findCalls == 0 and #groups == 0, "respawnBehind = false: nothing")
R._onConfig({respawnBehind = true})
mp = false
replaced(16, 0, 100)
tick(2)
check(#findCalls == 0, "outside multiplayer: nothing")
mp, career = true, false
replaced(16, 0, 100)
tick(2)
check(#findCalls == 0, "career not active: nothing")
career = true
traffic[16] = nil

-- 10. rate limit
R.onServerLeave()
reset()
R._onConfig({respawnPerMinute = 1})
spotToReturn = spotAt(1200, 700)
for _, t in ipairs({17, 18}) do cop(t, 0, -900, "bastion", 0) end
tick()
replaced(17, 0, 400)
tick()
check(#groups == 1, "first re-placed cop: a build")
newObject(60, 1200, 700, "vivace")
R.onVehicleGroupSpawned({60}, 11, "rlsmpCop")
reset()
replaced(18, 0, 400)
tick()
check(#groups == 0 and #teleports == 1, "perMinute = 1: the second one in the same minute is moved instead of built")
R._onConfig({respawnPerMinute = 4})

-- 11. no answer: a timeout is a failure; three failures switch the respawn off
st.rebuildSeconds = 0
R.onServerLeave()
reset()
cop(20, 0, -900, "bastion", 0)
tick()
replaced(20, 0, 400)
tick()
check(R.getState().job ~= nil, "a build is waiting")
tick(60)
check(R.getState().job == nil and R.getState().failures.respawn == 1 and saw("no group-spawned message"), "no answer in 25 s: failure")
for i = 1, 2 do
  replaced(20, 0, 400)
  tick()
  newObject(70 + i, 50, 50, "vivace")
  R.onVehicleGroupSpawned({70 + i}, 20 + i, "rlsmpCop")
end
check(R.getState().off.respawn == true and saw("switched off for this session"), "three failures: switched off")

-- 12. TOP-UP is OFF by default (the owner never asked for more cops) and only builds when the option is on
R.onServerLeave()
reset()
for id in pairs(traffic) do traffic[id] = nil end
for id in pairs(objects) do objects[id] = nil end
cop(90, 0, -800, "bastion", 0)
tick(200)
check(#groups == 0 and #findCalls == 0, "copCount 0 (default): no top-up, ever")
R._onConfig({copCount = 3, copTopUpSeconds = 30, respawnPerMinute = 30})
tick()
check(#groups == 1 and R.getState().job.kind == "top" and saw("police top-up: only 1 of 3 cops on the map"), "copCount 3: a top-up build starts")
check(groups[1].params.customTransforms[1].pos.x == 1200, "...at a found spot")
tick(4)
check(#groups == 1, "only one build at a time")
newObject(91, 1200, 700, "vivace")
R.onVehicleGroupSpawned({91}, 30, "rlsmpCop")
check(inserted[1].id == 91 and roles[1].role == "police" and #removed == 0, "top-up: the new car becomes police, nothing is removed")
reset()
tick(10)
check(#groups == 0, "the next top-up waits for topUpSeconds")
spotToReturn = nil
tick(80)
check(#groups == 0, "...and no spot found: no build")
R._onConfig({copCount = 99, copTopUpSeconds = 1})
check(st.copCount == 3 and st.topUpSeconds == 30, "copCount above 6 and topUpSeconds below 5 are ignored")

-- settings from the server
R._onConfig({spawnMinDistance = 1500, chaseSpawnMinDistance = 800, spawnPreferRight = false})
check(st.spawnMinDistance == 1500 and st.chaseSpawnMinDistance == 800 and st.preferRight == false, "distances and the right-side switch are taken from the server")
R._onConfig({spawnMinDistance = 10, chaseSpawnMinDistance = 99999})
check(st.spawnMinDistance == 1500 and st.chaseSpawnMinDistance == 800, "...out-of-range values are ignored")
R._onConfig({respawnRebuildSeconds = 90, copRespawnDistance = 450})
check(R.respawnDistance() == 450, "bubble.lua gets the police floor")
mp = false
check(R.respawnDistance() == 0, "outside multiplayer the game's own radius is used")
mp = true

print(string.format("police_respawn_client_test: %d checks passed", passed))
