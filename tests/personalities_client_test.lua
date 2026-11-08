-- Client smart traffic personalities test (LuaJIT). Run: luajit tests/personalities_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end

local P = require("rlsmp/lib/personality")

---------------------------------------------------------------------------------------------------
-- 1. Choosing a personality from the mix
local mix = P.DEFAULT_MIX
check(P.pick(mix, 0) == "normal", "r=0 -> first bucket")
check(P.pick(mix, 0.7999) == "normal", "just under 80% -> normal")
check(P.pick(mix, 0.80) == "slow", "80% -> slow")
check(P.pick(mix, 0.8999) == "slow", "just under 90% -> slow")
check(P.pick(mix, 0.90) == "aggressive", "90% -> aggressive")
check(P.pick(mix, 0.96) == "racer", "96% -> racer")
check(P.pick(mix, 0.99) == "drunk", "99% -> drunk")
check(P.pick(mix, 1.0) == "drunk", "bad random source (1.0) -> last weighted bucket")
check(P.pick(mix, -3) == "normal", "negative random clamps to 0")
local counts = {}
for i = 0, 9999 do local n = P.pick(mix, i / 10000) counts[n] = (counts[n] or 0) + 1 end
check(counts.normal == 8000 and counts.slow == 1000 and counts.aggressive == 600 and counts.racer == 300 and counts.drunk == 100,
  "uniform randoms give exactly the configured shares")
check(P.pick({normal = 0, slow = 0, aggressive = 0, racer = 0, drunk = 0}, 0.5) == "normal", "zero total -> normal")
check(P.pick({}, 0.5) == "normal", "empty mix -> normal")
check(P.pick({drunk = 5}, 0) == "drunk" and P.pick({drunk = 5}, 0.99) == "drunk", "only drunk -> always drunk")
check(P.pick({normal = -10, racer = "x", slow = 0 / 0, drunk = 1}, 0.2) == "drunk", "negative / NaN / text weights count as 0")
check(P.pick({normal = 1, slow = 1}, 0.5) == "slow", "weights need not add up to 100")
check(P.pick(nil, 0.97) == "racer", "no mix at all -> default mix")
check(P.pick({racer = math.huge, slow = 1}, 0.1) == "slow", "infinite weight ignored")

---------------------------------------------------------------------------------------------------
-- 2. Commands
check(P.command("normal", 20) == nil, "normal is left to RLS")
check(P.command("slow", 20) == 'ai.setAggression(0.200) ai.setSpeedMode("limit") ai.setSpeed(17.000) ai.driveInLane("on")', "slow = 85% of the limit")
check(P.command("slow", nil):find('ai.setSpeedMode("legal")', 1, true) ~= nil, "unknown limit -> legal speed")
check(P.command("slow", 0):find('"legal"', 1, true) ~= nil, "zero limit -> legal speed")
check(P.command("aggressive", 20):find("ai.setSpeed(23.000)", 1, true) and P.command("aggressive", 20):find("ai.setAggression(0.750)", 1, true), "aggressive = 115%")
check(P.command("racer", 20):find("ai.setSpeed(30.000)", 1, true) ~= nil, "racer = 150% on a fast road")
check(P.command("racer", 10):find("ai.setSpeed(18.000)", 1, true) ~= nil, "racer = limit + 8 m/s on a slow road")
check(P.command("racer", 20):find('driveInLane("on")', 1, true) ~= nil, "racer keeps its lane")
check(P.restoreCommand(0.4) == 'ai.setAggression(0.400) ai.setSpeedMode("legal") ai.driveInLane("on")', "restore = RLS traffic values")
check(P.restoreCommand(nil):find("0.300", 1, true) ~= nil, "restore without traffic vars uses 0.3")

---------------------------------------------------------------------------------------------------
-- 3. Skipping rules
local function car(over)
  local v = {isAi = true, role = {name = "standard"}, pursuit = {mode = 0}, state = "active", queuedFuncs = {}, respawnCount = 0,
    tracking = {speedLimit = 20}, pos = {x = 0, y = 0, z = 0}, speed = 15}
  for k, val in pairs(over or {}) do v[k] = val end
  return v
end
local ctx = {playerId = 1, remote = {[2] = true}, parked = {[3] = true}, owned = function(id) return id == 4 end,
  locked = function(id) return id == 5 end, objectActive = function(id) return id ~= 6 end}
check(P.skipReason(10, car(), ctx) == nil, "ordinary civilian traffic is ours")
check(P.skipReason(1, car(), ctx) == "player", "player car skipped")
check(P.skipReason(2, car(), ctx) == "remote", "other players' cars skipped")
check(P.skipReason(3, car(), ctx) == "parked", "parked cars skipped")
check(P.skipReason(4, car(), ctx) == "owned", "own garage cars skipped")
check(P.skipReason(5, car(), ctx) == "locked", "RLS job / locked cars skipped")
check(P.skipReason(6, car(), ctx) == "notActive", "inactive (pooled) objects skipped")
check(P.skipReason(10, car({isAi = false}), ctx) == "notAi", "player-driven traffic entry skipped")
check(P.skipReason(10, car({role = {name = "police"}}), ctx) == "role", "police skipped")
check(P.skipReason(10, car({role = {name = "suspect"}}), ctx) == "role", "suspects skipped")
check(P.skipReason(10, car({role = {name = "emt"}}), ctx) == "role", "job roles skipped")
check(P.skipReason(10, car({role = false}), ctx) == "role", "no role skipped")
check(P.skipReason(10, car({pursuit = {mode = 2}}), ctx) == "pursuit", "car in a pursuit skipped")
check(P.skipReason(10, car({pursuit = {mode = -1}}), ctx) == "pursuit", "car being arrested skipped")
check(P.skipReason(10, car({queuedFuncs = {pursuitStart = {}}}), ctx) == "pursuit", "car about to be chased skipped")
check(P.skipReason(10, car({state = "fadeIn"}), ctx) == "notActive", "fading car skipped")
check(P.skipReason(10, car({isPerson = true}), ctx) == "person", "walking people skipped")
check(P.skipReason(10, "junk", ctx) == "noData", "junk data skipped")
check(P.skipReason(10, car({activeData = {tCrash = 123}}), ctx) == "crashed", "crashed car left to RLS's crash reaction")
check(P.rlsTakesOver("crashed"), "no restore sent to a crashed car")
check(P.rlsTakesOver("pursuit") and P.rlsTakesOver("role") and not P.rlsTakesOver("locked"), "who resets the AI after a skip")

---------------------------------------------------------------------------------------------------
-- 4. Drunk sequence with an injected clock and random source
local queue = {}
local function rnd() if #queue > 0 then return table.remove(queue, 1) end return 0.5 end
local d = P.newDrunk(0, rnd)            -- nextWeave = 8 + 6 = 14, nextWobble = 4 + 2 = 6
check(d.nextWeave == 14 and d.nextWobble == 6 and not d.laneOff, "drunk starts sober, schedules the first weave and wobble")
check(#P.drunkStep(d, 5, rnd) == 0, "nothing before the first wobble")
local ev = P.drunkStep(d, 6, rnd)
check(#ev == 1 and ev[1] == "speed" and math.abs(d.factor - 0.925) < 1e-9 and d.nextWobble == 12, "speed wobble at 6 s")
check(P.command("drunk", 20, d):find("ai.setSpeed(18.500)", 1, true) ~= nil, "wobble changes the cap")
ev = P.drunkStep(d, 14, rnd)
check(#ev == 2 and ev[1] == "laneOff" and ev[2] == "speed", "weave starts at 14 s (and a wobble is due too)")
check(d.laneOff and d.weaveEnd == 15.75 and d.lastWeave == 14, "weave lasts 1.75 s")
check(P.command("drunk", 20, d):find('driveInLane("off")', 1, true) ~= nil, "lane keeping off while weaving")
check(#P.drunkStep(d, 15.5, rnd) == 0, "still weaving at 15.5 s")
ev = P.drunkStep(d, 15.75, rnd)
check(#ev == 1 and ev[1] == "laneOn" and not d.laneOff and d.nextWeave == 29.75, "lane keeping back on, next weave 14 s later")
check(P.command("drunk", 20, d):find('driveInLane("on")', 1, true) ~= nil, "back in lane")
queue = {0.1}                            -- the next wobble is a hard brake
ev = P.drunkStep(d, 20, rnd)
check(#ev == 1 and ev[1] == "brake" and d.braking and d.brakeEnd == 21.25, "hard brake for 1.25 s")
local cmd = P.command("drunk", 20, d)
check(cmd:find("ai.setSpeed(2.000)", 1, true) and cmd:find("ai.setAggression(1.000)", 1, true), "brake = low cap, hard braking")
check(#P.drunkStep(d, 21, rnd) == 0, "still braking")
ev = P.drunkStep(d, 21.25, rnd)
check(#ev == 1 and ev[1] == "brakeEnd" and not d.braking and d.factor == 1 and d.nextWobble == 27.25, "brake over, normal speed")
P.drunkSober(d)
check(not d.laneOff and not d.braking, "sober resets weave and brake")

---------------------------------------------------------------------------------------------------
-- 5. Police rate limit and nearest unit
local lim = P.newLimiter(60)
check(P.mayStart(lim, 0, {}) == true, "first reaction allowed")
P.noteStart(lim, 0)
local ok, why = P.mayStart(lim, 59.9, {})
check(not ok and why == "cooldown", "no second pursuit within 60 s")
check(P.mayStart(lim, 60, {}) == true, "allowed again after 60 s")
ok, why = P.mayStart(lim, 500, {playerChased = true})
check(not ok and why == "playerChased", "never while the player is chased")
ok, why = P.mayStart(lim, 500, {anyPursuit = true})
check(not ok and why == "pursuitRunning", "never while another pursuit runs")
local units = {{id = 7, pos = {x = 100, y = 0, z = 0}, usable = true}, {id = 8, pos = {x = 50, y = 0, z = 0}, usable = false},
  {id = 9, pos = {x = 70, y = 0, z = 0}, usable = true}}
local pid, dist = P.nearestPolice({x = 0, y = 0, z = 0}, units, 80)
check(pid == 9 and dist == 70, "nearest usable unit inside 80 m")
check(P.nearestPolice({x = 0, y = 0, z = 0}, {{id = 7, pos = {x = 81, y = 0, z = 0}, usable = true}}, 80) == nil, "nobody beyond 80 m")
local e = {name = "racer", hits = 0}
check(P.suspicious(e, 30, 20, 0) and not P.suspicious(e, 25, 20, 0), "racer fast = over 1.2 x limit + 2 m/s")
check(not P.suspicious(e, 16, 5, 0), "never fast below 16.7 m/s")
check(P.suspicious(e, 26, nil, 0) and not P.suspicious(e, 24, nil, 0), "unknown limit: 25 m/s")
check(not P.suspicious({name = "aggressive"}, 60, 20, 0), "only racers and drunks")
local de = {name = "drunk", drunk = P.newDrunk(0, rnd)}
check(not P.suspicious(de, 15, 20, 0), "sober-looking drunk is not suspicious")
de.drunk.laneOff = true
check(P.suspicious(de, 15, 20, 0), "weaving drunk is suspicious")
de.drunk.laneOff, de.drunk.lastWeave = false, 10
check(P.suspicious(de, 15, 20, 14) and not P.suspicious(de, 15, 20, 15), "weave remembered for 5 s")
check(not P.suspicious(de, 3, 20, 11), "a crawling drunk is not 'weaving' for the police")

---------------------------------------------------------------------------------------------------
-- 6. The extension, with fake game globals
local mpOn, career = true, true
MPCoreNetwork = {isMPSession = function() return mpOn end}
overhaul_career_career = {isActive = function() return career end}
local traffic = {}
local trafficVars = {baseAggression = 0.35}
gameplay_traffic = {getTrafficData = function() return traffic end, getTrafficVars = function() return trafficVars end}
local playerId = 1
local inactive = {}
be = {getPlayerVehicleID = function() return playerId end, getObjectActive = function(_, id) return not inactive[id] end}
local mpVehicles = {}
MPVehicleGE = {getVehicles = function() return mpVehicles end}
local parked = {}
gameplay_parking = {getParkedCarsList = function() return parked end}
local pursuits = {}
overhaul_integration_services_police = {setPursuitMode = function(mode, target, police)
  pursuits[#pursuits + 1] = {mode = mode, target = target, police = police}
  traffic[target].pursuit.mode = mode            -- what RLS does: the car becomes a fleeing suspect
  traffic[target].role = {name = "suspect"}
end}
local chased = false
rlsmp_police = {isPursuit = function() return chased end}

local smart = require("rlsmp/personalities")
smart.onExtensionLoaded()
local sentCmds = {}
smart._setSend(function(id, c) sentCmds[#sentCmds + 1] = {id = id, cmd = c} return true end)
local fixed = 0.5
smart._setRandom(function() return fixed end)
local function take() local t = sentCmds sentCmds = {} return t end
local function server(tbl) handlers["rlsmpSmartTraffic"](json.encode(tbl)) end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5 + 0.5) do smart.onUpdate(0.5, 0.5) end end

traffic[10] = car()
smart.enable(true)
run(2)
check(#take() == 0 and next(smart.getCars()) == nil, "nothing before the server's config")
server({enabled = true, mix = {slow = 1}, policeReact = true})
check(saw("smart: config received enabled=true"), "config line logged")
mpOn = false
run(1)
check(#take() == 0, "nothing outside multiplayer")
mpOn, career = true, false
run(1)
check(#take() == 0, "nothing while the career is not active")
career = true

-- assignment and re-apply timing (random 0.5 -> no jitter)
local t0 = smart._now()
run(0.5)
local s = take()
check(#s == 1 and s[1].id == 10 and s[1].cmd:find("ai.setSpeed(17.000)", 1, true), "slow car gets its settings at once")
check(smart.getCars()[10].name == "slow", "personality cached by vehicle id")
run(19.5)
check(#take() == 0, "no re-send before 20 s")
run(0.5)
check(#take() == 1, "re-sent after 20 s")
fixed = 0.99                                         -- would pick "drunk" if it re-rolled
run(20)
check(#take() == 1 and smart.getCars()[10].name == "slow", "personality chosen once, never re-rolled")
fixed = 0.5
traffic[10].tracking.speedLimit = 30
run(0.5)
s = take()
check(#s == 1 and s[1].cmd:find("ai.setSpeed(25.500)", 1, true), "new road limit -> new cap at once")
traffic[10].tracking.speedLimit = 30.3
run(0.5)
check(#take() == 0, "tiny limit changes are ignored")
traffic[10].respawnCount = 1
run(0.5)
check(#take() == 1, "re-applied right after RLS respawns the car")
smart.onTrafficAction(10, "changeRole")
run(0.5)
check(#take() == 1, "re-applied after a role change back to standard")

-- first seen while fading in: no personality until it is active
traffic[11] = car({state = "fadeIn"})
run(1)
check(smart.getCars()[11] == nil and #take() == 0, "a car is only assigned once it is active")
traffic[11].state = "active"
run(0.5)
check(smart.getCars()[11] ~= nil and #take() == 1, "assigned when first seen active")

-- cars that are not ours never get a command
traffic[12] = car({role = {name = "police"}})
traffic[13] = car({isAi = false})
traffic[playerId] = car()
traffic[14] = car() mpVehicles["0-3"] = {gameVehicleID = 14, isLocal = false}
traffic[15] = car() parked = {15}
run(1)
for _, c in ipairs(take()) do check(c.id ~= 12 and c.id ~= 13 and c.id ~= playerId and c.id ~= 14 and c.id ~= 15, "skipped car got no command") end
check(not smart.getCars()[12] and not smart.getCars()[playerId] and not smart.getCars()[14] and not smart.getCars()[15], "skipped cars get no personality")
traffic[12], traffic[13], traffic[playerId], traffic[14], traffic[15] = nil, nil, nil, nil, nil
mpVehicles, parked = {}, {}

-- RLS's vehicle policy loads after us: a car it locks (taxi in service) is still skipped
traffic[16] = car()
run(0.5)
take()
check(smart.getCars()[16] ~= nil, "car 16 is ours while nothing locks it")
package.loaded["overhaul/lib/vehicles/policy"] = {query = function(domain, id) return domain == "roleLocked" and id == 16 end}
run(0.5)
s = take()
check(#s == 1 and s[1].id == 16 and s[1].cmd == P.restoreCommand(0.35), "policy that appears later is honoured, car handed back")
run(25)
for _, c in ipairs(take()) do check(c.id ~= 16, "locked car gets nothing more") end
package.loaded["overhaul/lib/vehicles/policy"] = nil
traffic[16] = nil

-- a crash: RLS reacts, we stay quiet until it respawns
traffic[10].activeData = {tCrash = 1}
run(25)
for _, c in ipairs(take()) do check(c.id ~= 10, "crashed car gets no command") end
traffic[10].activeData = {}
traffic[10].respawnCount = 2
run(0.5)
s = take()
check(#s == 1 and s[1].id == 10, "respawned after the crash: settings back")

-- gone cars are dropped from the cache
traffic[11] = nil
run(0.5)
check(smart.getCars()[11] == nil, "cache entry dropped when the car is gone")

-- hand back: RLS takes over (pursuit) -> silent; other reasons -> RLS values restored
traffic[10].pursuit.mode = 1
run(0.5)
check(#take() == 0, "pursuit: we send nothing, RLS drives")
traffic[10].pursuit.mode = 0
run(0.5)
check(#take() == 1, "pursuit over: our settings come back at once")
inactive[10] = true
run(0.5)
s = take()
check(#s == 1 and s[1].cmd == P.restoreCommand(0.35), "deactivated car gets RLS's traffic values back")
inactive[10] = nil
run(0.5)
check(#take() == 1, "and ours again when it is back")

-- drunk car disabled in the middle of a weave
traffic = {[20] = car()}
smart.enable(false)
take()
smart.enable(true)
server({enabled = true, mix = {drunk = 1}, policeReact = false})
run(0.5)
check(smart.getCars()[20].name == "drunk" and #take() == 1, "drunk assigned")
run(14)                                            -- the first weave starts 14 s after assignment
local cars = smart.getCars()
check(cars[20].drunk.laneOff, "drunk is weaving")
local last = take()
check(last[#last].cmd:find('driveInLane("off")', 1, true) ~= nil, "weave command sent")
smart.enable(false)
s = take()
check(#s == 1 and s[1].id == 20 and s[1].cmd:find('driveInLane("on")', 1, true) and s[1].cmd:find("0.350", 1, true), "career closed mid-weave: lane keeping and RLS values restored")
check(next(smart.getCars()) == nil, "cache cleared")
smart.enable(true)
run(0.5)
take()
server({enabled = false, mix = {drunk = 1}})
s = take()
check(#s == 1 and s[1].cmd == P.restoreCommand(0.35), "server turns it off -> restored")
run(5)
check(#take() == 0, "nothing while off")

-- police reaction
traffic = {[30] = car({speed = 40}), [31] = car({role = {name = "police", state = "patrol"}, pos = {x = 50, y = 0, z = 0}}),
  [1] = car({isAi = false, role = {name = "police"}, pos = {x = 5, y = 0, z = 0}})}
server({enabled = true, mix = {racer = 1}, policeReact = true})
run(0.5)
check(#pursuits == 0, "one fast check is not enough")
run(0.5)
check(#pursuits == 1 and pursuits[1].target == 30 and pursuits[1].police == 31 and pursuits[1].mode == 1,
  "fast racer near AI police -> RLS pursuit with that one unit (not the player's police car)")
check(saw("smart: racer id=30 seen by police id=31"), "pursuit line logged")
take()
run(1)
check(#take() == 0, "car in pursuit is left to RLS")
-- the chase ends; the racer speeds again within the cooldown
traffic[30].pursuit.mode = 0 traffic[30].role = {name = "standard"}
run(30)
check(#pursuits == 1, "cooldown: no second pursuit within 60 s")
run(31)
check(#pursuits == 2, "allowed again after 60 s")
traffic[30].pursuit.mode = 0 traffic[30].role = {name = "standard"}
chased = true
local before = #pursuits
run(65)
check(#pursuits == before, "never while the player is chased")
chased = false
traffic[31].pos = {x = 200, y = 0, z = 0}
run(5)
check(#pursuits == before, "no police within 80 m -> nothing")
traffic[31].pos = {x = 50, y = 0, z = 0}
traffic[31].role.targetId = 99
run(5)
check(#pursuits == before, "busy police unit is not used")
traffic[31].role.targetId = nil
traffic[31].role.flags = {cooldown = 1}
run(5)
check(#pursuits == before, "police unit on cooldown is not used")
traffic[31].role.flags = {}
traffic[31].role.targetPursuitMode = 2
run(5)
check(#pursuits == before, "police unit still in a pursuit mode is not used")
traffic[31].role.targetPursuitMode = 0
traffic[32] = car({pursuit = {mode = 2}, role = {name = "suspect"}})
run(5)
check(#pursuits == before, "no new AI pursuit while another one runs")
traffic[32] = nil
run(1)
check(#pursuits == before + 1, "goes ahead once that ended")
server({enabled = true, mix = {racer = 1}, policeReact = false})
traffic[30].pursuit.mode = 0 traffic[30].role = {name = "standard"}
run(120)
check(#pursuits == before + 1, "policeReact off -> no pursuits")

-- leaving the server forgets the config
smart.onServerLeave()
check(smart.getConfig() == nil and next(smart.getCars()) == nil, "leave clears config and cache")
take()
smart.enable(true)
run(2)
check(#take() == 0, "nothing until the next server sends its config")


---------------------------------------------------------------------------------------------------
-- 7. Night: more racers, aggressive and drunk drivers
local nm = P.withMultipliers({normal = 80, slow = 10, aggressive = 6, racer = 3, drunk = 1}, {normal = 1, slow = 0.5, aggressive = 2.5, racer = 4, drunk = 6})
check(nm.normal == 80 and nm.slow == 5 and nm.aggressive == 15 and nm.racer == 12 and nm.drunk == 6, "night weights = day weights x multipliers")
local total = 0
for _, n in ipairs(P.ORDER) do total = total + nm[n] end
check(math.abs(nm.drunk / total - 6 / 118) < 1e-9 and nm.racer / total > 3 / 100 * 2, "with the default mix drunk goes from 1% to about 5%, racers from 3% to about 10%")
local un = P.withMultipliers({normal = 2, drunk = 1}, nil)
check(un.normal == 2 and un.drunk == 1 and un.slow == 0, "no multipliers: the mix unchanged")
local bad = P.withMultipliers({normal = 2, drunk = 1}, {normal = -3, drunk = "x", racer = 0 / 0})
check(bad.normal == 2 and bad.drunk == 1, "negative, text and NaN multipliers count as 1")
check(P.withMultipliers({drunk = 1}, {drunk = 1e9}).drunk == 100, "a multiplier is capped at 100")
check(P.withMultipliers({drunk = 1}, {drunk = 0}).drunk == 0, "0 switches a personality off at night")

for k in pairs(traffic) do traffic[k] = nil end
local nightNow = false
core_environment = {getLightState = function() return {isNight = nightNow} end}
server({enabled = true, mix = {normal = 2, drunk = 1}, nightMult = {drunk = 6}, policeReact = false})
smart.enable(true)
traffic[30] = car()
run(1)
check(smart.getCars()[30] and smart.getCars()[30].name == "normal", "by day the random 0.5 gives a normal driver")
nightNow = true
run(1)
check(smart.getCars()[30] and smart.getCars()[30].name == "drunk", "at night the same random gives a drunk driver (the car drew again when night fell)")
check(saw("smart: it is night now"), "the change is logged")
nightNow = false
run(1)
check(smart.getCars()[30].name == "normal" and saw("smart: it is day now"), "and back to normal when day comes")
-- a server that sends no night multipliers: nothing changes at night
server({enabled = true, mix = {normal = 2, drunk = 1}, policeReact = false})
for k in pairs(traffic) do traffic[k] = nil end
traffic[31] = car()
run(1)
nightNow = true
run(1)
check(smart.getCars()[31] and smart.getCars()[31].name == "normal", "no nightMult from the server: night changes nothing")
nightNow = false
core_environment = nil

print(string.format("personalities_client_test: %d checks passed", passed))
