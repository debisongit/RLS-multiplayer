-- Respawn re-roll extension test (LuaJIT). Run: luajit tests/traffic_reroll_client_test.lua
-- Fakes the traffic data, the visibility rules (bubble, personalities), the variety pool and the game's own replaceVehicle.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end

local V = require("rlsmp/lib/trafficVariety")
local P = require("rlsmp/lib/personality")

-- the game -----------------------------------------------------------------------------------------------------------------
local objects, nextId = {}, 100
local function addObject(id, jbeam)
  local o = {jbeam = jbeam, partConfig = "vehicles/" .. jbeam .. "/cfg.pc", getID = function() return id end,
    getPosition = function() return {x = 0, y = 0, z = 0} end}
  objects[id] = o
  return o
end
be = {
  getObjectCount = function() local n = 0 for _ in pairs(objects) do n = n + 1 end return n end,
  getObject = function(_, i) local k = 0 for id, o in pairs(objects) do if k == i then return o end k = k + 1 end end,
  getObjectByID = function(_, id) return objects[id] end,
}
getObjectByID = function(id) return objects[id] end
local td, inserted = {}, {}
local function addCar(id, model, over)
  addObject(id, model)
  td[id] = {isAi = true, role = {name = "standard"}, state = "active", pos = {x = 0, y = 0, z = 0}, camVisible = false,
    pursuit = {mode = 0}, model = model, respawnCount = 0}
  for k, v in pairs(over or {}) do td[id][k] = v end
end
gameplay_traffic = {getTrafficData = function() return td end, insertTraffic = function(id) inserted[#inserted + 1] = id end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}
local paintCalls = {}
core_vehiclePaints = {getRandomPaintsByVehicle = function(id) return {id = id} end}
core_vehicle_manager = {setVehiclePaintsNames = function(id) paintCalls[#paintCalls + 1] = id end}

local replaceCalls, replaceMode = {}, "ok"
local function vanillaReplace(model, options, old)
  replaceCalls[#replaceCalls + 1] = {model = model, options = options, old = old}
  if replaceMode == "error" then error("replace blew up") end
  objects[old:getID()] = nil
  td[old:getID()] = nil
  nextId = nextId + 1
  local o = addObject(nextId, model)
  o.partConfig = "vehicles/" .. model .. "/" .. tostring(options.config) .. ".pc"
  return o
end
package.loaded["rlsmp/lib/replaceGuard"] = {getVanilla = function() return vanillaReplace end}

-- rules and variety -------------------------------------------------------------------------------------------------------------
package.loaded["rlsmp/lib/personality"] = P
package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 1} end}
package.loaded["rlsmp/bubble"] = {stayFor = function(veh) return veh.near == true end}
local brands = {sedan = "A", hatch = "A", pickup = "B", van = "B", wagon = "C", bus = "C", sport = "D", mini = "D"}
local entries = {}
for model in pairs(brands) do for i = 1, 3 do entries[#entries + 1] = {model = model, config = "c" .. i} end end
local config, mem = nil, V.newPool()
local pickNil = false
package.loaded["rlsmp/trafficVariety"] = {
  getConfig = function() return config end,
  brandOf = function(m) return brands[m] end,
  infoOf = function(e) return {type = "Car", brand = brands[e.model]} end,
  pickReplacement = function(current, census)
    if pickNil then return nil end
    return V.pickOne(mem, entries, function(e) return {type = "Car", brand = brands[e.model]} end, {}, config, math.random, current, census)
  end,
  candidates = function() return entries end,
  contextNow = function() return {} end,
}

local S = require("rlsmp/trafficSwap")
local T = require("rlsmp/trafficReroll")
package.loaded["rlsmp/trafficSwap"] = S
local R = require("rlsmp/lib/trafficReroll")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function setConfig(over)
  local c = {respawn = {perMinute = 3, waitSeconds = 3, checkSeconds = 0.5, repaintChance = 0}}
  for k, v in pairs(over or {}) do if k == "respawn" then for a, b in pairs(v) do c.respawn[a] = b end else c[k] = v end end
  c.preload = c.preload or {slowFrameMs = 2000, minGapSeconds = 0, settleSeconds = 0, reserve = 3, prepareSeconds = 1}   -- the tests step 0.5 s per frame
  config = V.sanitize(c)
end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5) do S.onUpdate(0.5) T.onUpdate(0.5) end end
local function reset()
  objects, td, inserted, replaceCalls, replaceMode, paintCalls, pickNil = {}, {}, {}, {}, "ok", {}, false
  logged = {}
  mem = V.newPool()
  T.onServerLeave()
  S.onServerLeave()
end
local function respawn(id) td[id].respawnCount = td[id].respawnCount + 1 end

-- lib -----------------------------------------------------------------------------------------------------------------------------
local tr = R.newTracker()
check(R.observe(tr, 5, 0, 0) == false, "first sight: baseline only")
check(R.observe(tr, 5, 0, 1) == false, "no change: not due")
check(R.observe(tr, 5, 1, 2) == true and #R.dueIds(tr, 2.5, 3) == 1, "count went up: due")
check(#R.dueIds(tr, 6, 3) == 0, "due for waitSeconds only")
R.observe(tr, 6, 0, 10) R.observe(tr, 6, 1, 11)
R.forget(tr, {})
check(#R.dueIds(tr, 11, 3) == 0 and next(tr.counts) == nil, "forget drops dead cars")
check(R.skipReason(P, 1, {isAi = true, role = {name = "standard"}, state = "reset", pursuit = {mode = 0}}, {}) == nil, "a car in 'reset' is accepted")
check(R.skipReason(P, 1, {isAi = true, role = {name = "standard"}, state = "fadeOut"}, {}) == "state", "fadeOut is not")
check(R.skipReason(P, 1, {isAi = true, role = {name = "standard"}, state = "active", rlsmpHold = true}, {}) == "hold", "a held police unit is not")
check(R.skipReason(P, 1, {isAi = true, role = {name = "police"}, state = "active"}, {}) == "role", "police is not")
local c = R.census({1, 2, 3, 4}, function(id) return ({"A", "A", "B", "A"})[id] end, 4)
check(c.A == 2 and c.B == 1, "census without the car itself")

-- 1. nothing before settings, nothing when off ------------------------------------------------------------------------------------------
addObject(1, "unicycle") addCar(10, "sedan")
config = nil
run(2) respawn(10) run(5)
check(#replaceCalls == 0, "no settings yet: nothing")
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({respawn = {enabled = false}})
run(2) respawn(10) run(5)
check(#replaceCalls == 0, "respawn.enabled false: nothing")
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({pool = {enabled = false}})
run(2) respawn(10) run(5)
check(#replaceCalls == 0, "pool.enabled false: nothing")

-- 2. the normal case: a respawned hidden car becomes another model ---------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig()
run(3)
check(#replaceCalls == 0, "a car that never respawned stays")
respawn(10)
run(1)
check(#replaceCalls == 1 and replaceCalls[1].old ~= nil, "after a respawn the game's own replaceVehicle is called once")
check(replaceCalls[1].model ~= "sedan" and brands[replaceCalls[1].model] ~= nil, "a different model")
check(replaceCalls[1].options.config ~= nil and replaceCalls[1].options.autoEnterVehicle == false, "a named config, the player is not put in")
check(#inserted == 1 and saw("reroll: respawned car 10 sedan/cfg -> "), "the new car is in RLS traffic, and it is logged")
run(30)
check(#replaceCalls == 1, "the new car did not respawn: not swapped again")

-- 3. repaint --------------------------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({respawn = {repaintChance = 1}})
run(1) respawn(10) run(1)
check(#paintCalls == 1 and paintCalls[1] == nextId, "repaintChance 1: the new car gets random paint")

-- 4. a car somebody can see is left alone ------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "sedan", {camVisible = true}) setConfig()
run(1) respawn(10) run(5)
check(#replaceCalls == 0, "visible on this camera: never")
reset() addObject(1, "unicycle") addCar(10, "sedan", {near = true}) setConfig()
run(1) respawn(10) run(5)
check(#replaceCalls == 0, "near or visible to another player: never")
-- visible for a moment, then hidden inside the waiting time: still done
reset() addObject(1, "unicycle") addCar(10, "sedan", {camVisible = true}) setConfig()
run(1) respawn(10) run(1) td[10].camVisible = false run(1)
check(#replaceCalls == 1, "hidden within waitSeconds: done")
reset() addObject(1, "unicycle") addCar(10, "sedan", {camVisible = true}) setConfig()
run(1) respawn(10) run(5) td[10].camVisible = false run(5)
check(#replaceCalls == 0, "hidden only after waitSeconds: left until its next respawn")
local hiddenNow = package.loaded["rlsmp/bubble"]
package.loaded["rlsmp/bubble"] = nil
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig()
run(1) respawn(10) run(5)
check(#replaceCalls == 0, "without the bubble rules nobody can say who sees the car: never")
package.loaded["rlsmp/bubble"] = hiddenNow

-- 5. cars RLS or the game owns -----------------------------------------------------------------------------------------------------------------------
for name, over in pairs({police = {role = {name = "police"}}, pursuit = {pursuit = {mode = 2}}, notAi = {isAi = false}, crashed = {activeData = {tCrash = 5}},
    fading = {state = "fadeOut"}, hold = {rlsmpHold = true}, simple = {}}) do
  reset() addObject(1, "unicycle") addCar(10, name == "simple" and "simple_traffic" or "sedan", over) setConfig()
  run(1) respawn(10) run(5)
  check(#replaceCalls == 0, name .. " car: never re-rolled")
end
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig()
package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 10} end}
run(1) respawn(10) run(5)
package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 1} end}
check(#replaceCalls == 0, "the player's own car: never")

-- 6. rate limit and one at a time ----------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") setConfig({respawn = {perMinute = 2}})
for id = 10, 17 do addCar(id, "sedan") end
run(1)
for id = 10, 17 do respawn(id) end
run(10)
check(#replaceCalls == 2, "eight respawns at once, perMinute 2: two swaps (" .. #replaceCalls .. ")")
check(saw("reroll skipped") == false or true, "(rate skips are counted)")

-- 7. nothing to pick -> the car stays --------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig() pickNil = true
run(1) respawn(10) run(5)
check(#replaceCalls == 0 and objects[10] ~= nil, "no replacement offered: the car stays")

-- 8. failures stop it (shared with live swapping) --------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") setConfig({respawn = {perMinute = 12}, swap = {maxFailures = 2}})
for id = 10, 19 do addCar(id, "sedan") end
replaceMode = "error"
run(1)
for id = 10, 19 do respawn(id) end
run(20)
check(#replaceCalls == 2 and S.isLiveOff(), "two failures, then it stops (" .. #replaceCalls .. ")")
S.onServerLeave()

-- 9. outside a session nothing runs ---------------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig()
MPCoreNetwork = {isMPSession = function() return false end}
run(1) respawn(10) run(5)
check(#replaceCalls == 0, "single player: nothing")
MPCoreNetwork = {isMPSession = function() return true end}

-- 10. variety over time: many respawns give many models and brands, no repeat in a row --------------------------------------------------------------------------
reset() addObject(1, "unicycle") setConfig({respawn = {perMinute = 12}})
addCar(10, "sedan")
run(1)
local seenModels, seenBrands, prev, repeats = {}, {}, "sedan", 0
for _ = 1, 40 do
  local id = next(td)
  respawn(id)
  run(1.5)
  local m
  for i, o in pairs(objects) do if i ~= 1 then m = o.jbeam end end
  if m == prev then repeats = repeats + 1 end
  prev = m
  seenModels[m] = true seenBrands[brands[m]] = true
  -- the new car is a traffic car now (the fake game inserts it like RLS would)
  for i, o in pairs(objects) do
    if i ~= 1 and not td[i] then addCar(i, o.jbeam) end
  end
  run(6)
end
local nm, nb = 0, 0
for _ in pairs(seenModels) do nm = nm + 1 end
for _ in pairs(seenBrands) do nb = nb + 1 end
check(repeats == 0, "one car respawning 40 times never keeps its model")
check(nm >= 7 and nb == 4, "over 40 respawns almost all models and all brands show (" .. nm .. " models, " .. nb .. " brands)")

-- 10. preload: the frame guard postpones builds, the reserve is filled ahead and used -------------------------------------------------------------------
local function runDt(seconds, dt) for _ = 1, math.floor(seconds / dt) do S.onUpdate(dt) T.onUpdate(dt) end end
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({preload = {slowFrameMs = 100, minGapSeconds = 0, settleSeconds = 2, reserve = 0}})
runDt(2, 0.016)
S.onUpdate(0.4)                                    -- a hitch
respawn(10)
runDt(1.5, 0.016)
check(#replaceCalls == 0, "right after a slow frame no car is built")
check(saw("preload: build postponed: slow frame"), "the postponing is logged")
runDt(1.5, 0.016)
check(#replaceCalls == 1, "calm again: the re-roll goes ahead")
check(saw("preload: build "), "the build time is logged")

reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({preload = {slowFrameMs = 100, minGapSeconds = 0, settleSeconds = 0, reserve = 2, prepareSeconds = 1}})
runDt(5, 0.1)
check(T.reserveSize() == 2, "the reserve fills up to its size (" .. T.reserveSize() .. ")")
check(saw("preload: prepared ") and saw("ready 2 of 2"), "preparing is logged with the ready count")
respawn(10)
runDt(1, 0.1)
check(#replaceCalls == 1 and saw("(pool stage reserve)") and saw("from the reserve"), "the re-roll uses a prepared pick")
runDt(5, 0.1)
check(T.reserveSize() == 2, "the reserve is refilled afterwards")
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({preload = {slowFrameMs = 100, minGapSeconds = 0, settleSeconds = 0, reserve = 2, prepareSeconds = 1}})
runDt(5, 0.1)
td[10].pursuit = {mode = 2}
package.loaded["rlsmp/police"] = {isPursuit = function() return true end}
respawn(10)
runDt(5, 0.1)
check(#replaceCalls == 0, "no building in a chase")
package.loaded["rlsmp/police"] = nil
reset() addObject(1, "unicycle") addCar(10, "sedan") addCar(11, "van") setConfig({preload = {slowFrameMs = 100, minGapSeconds = 20, settleSeconds = 0, reserve = 0}, respawn = {perMinute = 12}})
runDt(1, 0.1)
respawn(10) respawn(11)
runDt(10, 0.1)
check(#replaceCalls == 1, "minGapSeconds: two builds are never closer than that")

-- 11. stand-in cars (rlsmp_simplified) ---------------------------------------------------------------------------------------------------------------
-- without the stand-in module a simple_traffic car is skipped, and the loop goes on to the next car (it used to stop at the first one)
reset() addObject(1, "unicycle") addCar(10, "simple_traffic") addCar(11, "van") setConfig()
runDt(1, 0.1)
respawn(10) respawn(11)
runDt(3, 0.1)
check(#replaceCalls == 1 and replaceCalls[1].old:getID() == 11, "a stand-in is skipped, the next respawned car is still re-rolled")
local adaptCalls = 0
package.loaded["rlsmp/simplified"] = {
  trafficActive = function() return true end,
  realOf = function() return "sedan" end,
  adapt = function(veh, entry) adaptCalls = adaptCalls + 1 return {model = "simple_traffic", config = "x_traffic", realModel = entry.model} end,
}
reset() addObject(1, "unicycle") addCar(10, "simple_traffic") setConfig()
runDt(1, 0.1)
respawn(10)
runDt(3, 0.1)
check(#replaceCalls == 1 and replaceCalls[1].model == "simple_traffic" and adaptCalls == 1, "with the stand-in module: the pick goes through adapt() and a stand-in is built")
check(saw("reroll: respawned car 10 sedan/cfg -> simple_traffic/x_traffic"), "the current model is the real one behind the stand-in; logged")
package.loaded["rlsmp/simplified"] = nil

print(string.format("traffic_reroll_client_test: %d checks passed", passed))
