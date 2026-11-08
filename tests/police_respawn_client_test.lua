-- Police respawn client test (LuaJIT): a re-placed cop comes back behind the player as another model. Run: luajit tests/police_respawn_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
local function count(fragment) local n = 0 for _, l in ipairs(logged) do if l:find(fragment, 1, true) then n = n + 1 end end return n end
function setExtensionUnloadMode() end
TriggerServerEvent = function() end
AddEventHandler = function() end

local mp, career = true, true
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
local PLAYER = 1
be = {getPlayerVehicleID = function() return PLAYER end}
-- the player stands at 0,0 and looks along +y: "behind" is negative y
getPlayerVehicle = function() return {getPosition = function() return {x = 0, y = 0, z = 0} end, getDirectionVector = function() return {x = 0, y = 1, z = 0} end} end
local objects, traffic, removed, inserted, roles, groups = {}, {}, {}, {}, {}, {}
local function newObject(id, y, model) objects[id] = {id = id, jbeam = model, pos = {x = 0, y = y, z = 0}} return objects[id] end
getObjectByID = function(id)
  local o = objects[id]
  if not o then return nil end
  return {jbeam = o.jbeam, getPosition = function() return o.pos end, delete = function() removed[#removed + 1] = "obj:" .. id objects[id] = nil end}
end
local function cop(id, y, model, rc)
  newObject(id, y, model)
  traffic[id] = {isAi = true, role = {name = "police"}, respawnCount = rc or 0, pos = {x = 0, y = y, z = 0}, jbeam = model}
  return traffic[id]
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
local picks = {{model = "vivace", config = "police_a"}, {model = "bastion", config = "police_b"}}
local pickCalls = {}
rlsmp_trafficVariety = {policePick = function(avoid)
  pickCalls[#pickCalls + 1] = avoid
  for _, e in ipairs(picks) do if e.model ~= avoid then return {model = e.model, config = e.config} end end
  return nil
end}

local R = require("rlsmp/policeRespawn")
R.onExtensionLoaded()
R._onConfig({copCount = 0})        -- the respawn scenarios below run without the top-up (it has its own at the end)
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function tick(n) for _ = 1, n or 1 do R.onUpdate(0.5) end end
local function reset() removed, inserted, roles, groups = {}, {}, {}, {} end

-- pure helper
local a, d = R.relative({x = 0, y = 0}, {x = 0, y = 1}, {x = 0, y = 100})
check(a == true and math.abs(d - 100) < 1e-9, "relative: a point along the heading is in front")
a, d = R.relative({x = 0, y = 0}, {x = 0, y = 1}, {x = 30, y = -40})
check(a == false and math.abs(d - 50) < 1e-9, "relative: a point behind, 50 m away")
check(R.relative({x = 0, y = 0}, {x = 0, y = 0}, {x = 5, y = 5}) == false, "relative: no heading counts as not in front")

-- 1. first sight only remembers the counter
cop(10, -400, "bastion", 3)
tick()
check(#groups == 0 and R.getState().seen[10] == 3, "first look: nothing happens, the counter is remembered")
tick()
check(#groups == 0, "an unchanged counter does nothing")

-- 2. the game re-places the cop: a different model is built behind the player
traffic[10].respawnCount = 4
traffic[10].pos = {x = 0, y = 300, z = 0}      -- the game put it IN FRONT, 300 m away
objects[10].pos = traffic[10].pos
tick()
check(#groups == 1 and groups[1].amount == 1 and groups[1].params.name == "rlsmpCop" and groups[1].params.mode == "roadBehind" and groups[1].params.gap == 150,
  "re-placed cop: one car asked for through the group spawn, mode roadBehind, gap 150")
check(groups[1].group[1].model == "vivace" and pickCalls[#pickCalls] == "bastion", "...of a model other than the old one")
check(saw("cop 10 re-placed 300 m in front of the player"), "the log says it was in front")
tick()
check(#groups == 1, "only one build at a time")

-- 3. the game reports the new car, behind the player: it becomes police, the old cop is removed
newObject(50, -200, "vivace")
R.onVehicleGroupSpawned({50}, 7, "rlsmpCop")
check(inserted[1] and inserted[1].id == 50 and inserted[1].isPlayer == false and inserted[1].noPool == true, "the new car is given to traffic (not the player, no pooling)")
check(roles[1] and roles[1].id == 50 and roles[1].role == "police", "...with the police role")
check(saw("new cop 50 came out 200 m behind the player"), "its place is logged")
check(table.concat(removed, ",") == "traffic:10,obj:10", "only now the old cop is removed: " .. table.concat(removed, ","))
check(R.getState().job == nil and R.getState().mine[50] == true, "build finished, the new cop is ours")
reset()

-- 4. a cop we built is not replaced at once (its own start), but when RLS re-places it later it is replaced like any other
tick()
traffic[50].respawnCount = 1                    -- right after its start: inside the grace time
traffic[50].pos = {x = 0, y = -300, z = 0}
objects[50].pos = traffic[50].pos
tick(2)
check(#groups == 0, "a cop we built is left alone during its first seconds")
tick(25)                                        -- 10 s grace are over
traffic[50].respawnCount = 2
tick()
check(#groups == 1 and groups[1].group[1].model ~= "vivace", "...but replaced when RLS re-places it later (a model other than its own)")
R.onServerLeave()                               -- (a fresh session for the scenarios below)
reset()
traffic[50] = nil
objects[50] = nil

-- 5. a new car that came out IN FRONT is deleted again, the old cop stays, it counts as a failure
cop(11, -500, "vivace", 0)
tick()
traffic[11].respawnCount = 1
traffic[11].pos = {x = 0, y = -350, z = 0}
tick()
check(#groups == 1, "second build started")
newObject(51, 120, "bastion")
R.onVehicleGroupSpawned({51}, 8, "rlsmpCop")
check(saw("came out in front") and table.concat(removed, ","):find("obj:51", 1, true) and not table.concat(removed, ","):find("obj:11", 1, true), "in front: the new car is deleted, the old cop is kept")
check(R.getState().failures.respawn == 1 and R.getState().mine[51] == nil, "...and it counts as a failure")
reset()

-- 6. too close to the player counts the same
traffic[11].respawnCount = 2
tick()
newObject(52, -20, "bastion")
R.onVehicleGroupSpawned({52}, 9, "rlsmpCop")
check(saw("too close") and R.getState().failures.respawn == 2, "too close: deleted, second failure")
reset()
-- a good one starts the count again
traffic[11].respawnCount = 3
tick()
newObject(53, -250, "bastion")
R.onVehicleGroupSpawned({53}, 10, "rlsmpCop")
check(R.getState().failures.respawn == 0 and #roles == 1, "a good build resets the failure count")
reset()

-- 7. cops close to the player are left alone, other groups are ignored
cop(12, -30, "vivace", 0)
tick()
traffic[12].respawnCount = 1
traffic[12].pos = {x = 0, y = -30, z = 0}
tick(2)
check(#groups == 0, "a cop re-placed within 80 m is left alone")
R.onVehicleGroupSpawned({99}, 1, "autoParking")
check(#inserted == 0 and #removed == 0, "other group names are ignored")
reset()

-- 8. the switch, multiplayer and the career (the cop of step 6 was replaced and is gone: a new one)
cop(15, -500, "vivace", 0)
tick()
R._onConfig({respawnBehind = false})
traffic[15].respawnCount, traffic[15].pos = 1, {x = 0, y = -480, z = 0}
tick(2)
check(#groups == 0, "respawnBehind = false: nothing")
R._onConfig({respawnBehind = true})
mp = false
traffic[15].respawnCount = 2
tick(2)
check(#groups == 0, "outside multiplayer: nothing")
mp, career = true, false
traffic[15].respawnCount = 3
tick(2)
check(#groups == 0, "career not active: nothing")
career = true
tick(1)
traffic[15] = nil
tick()

-- 9. rate limit (a fresh session: the builds above are forgotten)
R.onServerLeave()
reset()
R._onConfig({respawnPerMinute = 1})
for _, t in ipairs({13, 14}) do cop(t, -450, "bastion", 0) end
tick()
traffic[13].respawnCount, traffic[13].pos = 1, {x = 0, y = -450, z = 0}
tick()
check(#groups == 1, "first re-placed cop: a build")
newObject(60, -200, "vivace")
R.onVehicleGroupSpawned({60}, 11, "rlsmpCop")
reset()
traffic[14].respawnCount, traffic[14].pos = 1, {x = 0, y = -450, z = 0}
tick()
check(#groups == 0, "perMinute = 1: the second one in the same minute waits")
R._onConfig({respawnPerMinute = 4})

-- 10. no answer: a timeout is a failure and the old cop stays
R.onServerLeave()
cop(20, -400, "bastion", 0)
tick()
traffic[20].respawnCount, traffic[20].pos = 1, {x = 0, y = -420, z = 0}
tick()
check(#groups == 1 and R.getState().job ~= nil, "a build is waiting")
tick(60)
check(R.getState().job == nil and R.getState().failures.respawn == 1 and saw("no group-spawned message"), "no answer in 25 s: failure, nothing removed")

-- 11. three failures switch it off for the session
reset()
for i = 1, 2 do
  traffic[20].respawnCount = traffic[20].respawnCount + 1
  tick()
  newObject(70 + i, 150, "vivace")
  R.onVehicleGroupSpawned({70 + i}, 20 + i, "rlsmpCop")
end
check(R.getState().off.respawn == true and saw("switched off for this session"), "three failures: switched off")
traffic[20].respawnCount = traffic[20].respawnCount + 1
local before = #groups
tick(2)
check(#groups == before, "...and nothing more is built")

-- 12. a pool with only that model: the pick function is asked and may fall back, nil leaves the cop alone
R.onServerLeave()
rlsmp_trafficVariety.policePick = function() return nil end
cop(30, -400, "bastion", 0)
tick()
traffic[30].respawnCount, traffic[30].pos = 1, {x = 0, y = -420, z = 0}
reset()
tick()
check(#groups == 0, "no police pick available: the cop is left as RLS placed it")


-- 13. TOP-UP: more cops (the game puts one; copCount 3 = two more, one at a time)
R.onServerLeave()
reset()
for id in pairs(traffic) do traffic[id] = nil end
for id in pairs(objects) do objects[id] = nil end
rlsmp_trafficVariety.policePick = function(avoid)
  pickCalls[#pickCalls + 1] = avoid
  for _, e in ipairs(picks) do if e.model ~= avoid then return {model = e.model, config = e.config} end end
  return nil
end
R._onConfig({copCount = 3, copTopUpSeconds = 30, respawnPerMinute = 30})
cop(90, -400, "bastion", 0)                       -- the game's own cop
tick()
check(#groups == 1 and groups[1].params.name == "rlsmpCop" and groups[1].params.mode == "roadBehind" and groups[1].amount == 1, "top-up: one cop on the map, three wanted: a build starts")
check(R.getState().job.kind == "top" and saw("police top-up: only 1 of 3 cops on the map"), "...as a top-up, the log says how many there are")
check(groups[1].group[1].model == "vivace", "...of a police pool entry (the stub's first pick)")
tick(4)
check(#groups == 1, "only one build at a time")
newObject(91, -220, "vivace")
R.onVehicleGroupSpawned({91}, 30, "rlsmpCop")
check(inserted[1].id == 91 and roles[1].role == "police" and #removed == 0, "top-up: the new car becomes police, nothing is removed")
check(saw("police top-up: done, new cop 91") and R.getState().job == nil, "...and it is logged")
reset()
tick(10)
check(#groups == 0, "top-up: the next one waits for topUpSeconds (30 s)")
tick(60)
check(#groups == 1, "...and comes after it (two cops now, three wanted)")
newObject(92, -240, "bastion")
R.onVehicleGroupSpawned({92}, 31, "rlsmpCop")
reset()
tick(80)
check(#groups == 0, "three cops: nothing more is built")
-- one of ours is removed (wrecked): it is filled up again
traffic[92] = nil
objects[92] = nil
tick(2)
check(#groups == 1, "a cop is gone: filled up again")
R.onServerLeave()
reset()

-- top-up that comes out in front is deleted again; failures of the two jobs are counted apart
for id in pairs(traffic) do traffic[id] = nil end
cop(95, -400, "bastion", 0)
R._onConfig({copCount = 2})
tick()
newObject(96, 150, "vivace")
R.onVehicleGroupSpawned({96}, 32, "rlsmpCop")
check(saw("police top-up: the new cop came out in front") and R.getState().failures.top == 1 and R.getState().failures.respawn == 0, "top-up in front: deleted, counted as a top-up failure only")
check(table.concat(removed, ","):find("obj:96", 1, true), "...the new car is deleted")
reset()
for i = 1, 2 do
  tick(70)
  newObject(96 + i, 150, "vivace")
  R.onVehicleGroupSpawned({96 + i}, 32 + i, "rlsmpCop")
end
check(R.getState().off.top == true and R.getState().off.respawn == false and saw("police top-up: switched off for this session"), "three top-up failures switch the top-up off, not the respawn")
reset()
traffic[95].respawnCount, traffic[95].pos = 1, {x = 0, y = -500, z = 0}
objects[95].pos = traffic[95].pos
tick()
check(#groups == 1 and R.getState().job.kind == "respawn", "...the respawn still works")
R.onServerLeave()
reset()

-- settings: 0 = leave the game's number; bad values ignored; not outside multiplayer
for id in pairs(traffic) do traffic[id] = nil end
cop(100, -400, "bastion", 0)
R._onConfig({copCount = 0})
tick(80)
check(#groups == 0, "copCount 0: no top-up")
R._onConfig({copCount = 99, copTopUpSeconds = 1})
check(R.getState().settings.copCount == 0 and R.getState().settings.topUpSeconds == 30, "copCount above 6 and topUpSeconds below 5 are ignored")
R._onConfig({copCount = 2})
mp = false
tick(80)
check(#groups == 0, "outside multiplayer: no top-up")
mp = true
rlsmp_trafficVariety.policePick = function() return nil end
tick(80)
check(#groups == 0, "no police pick available: no top-up")

print(string.format("police_respawn_client_test: %d checks passed", passed))
