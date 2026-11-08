-- Live swapping extension test (LuaJIT). Run: luajit tests/traffic_swap_client_test.lua
-- Fakes the traffic data, Claude A's visibility rules (bubble, personalities) and the game's own replaceVehicle.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end

local V = require("rlsmp/lib/trafficVariety")
local P = require("rlsmp/lib/personality")

-- the game ---------------------------------------------------------------------------------------------------------------
local objects, nextId = {}, 100
local function addObject(id, jbeam, partConfig)
  objects[id] = {jbeam = jbeam, partConfig = partConfig, getID = function() return id end}
  return objects[id]
end
be = {
  getObjectCount = function() local n = 0 for _ in pairs(objects) do n = n + 1 end return n end,
  getObject = function(_, i) local k = 0 for id, o in pairs(objects) do if k == i then return o end k = k + 1 end end,
  getObjectByID = function(_, id) return objects[id] end,
}
getObjectByID = function(id) return objects[id] end
local td, inserted = {}, {}
local function addCar(id, model, over)
  addObject(id, model, "vehicles/" .. model .. "/cfg.pc")
  td[id] = {isAi = true, role = {name = "standard"}, state = "active", pos = {x = 0, y = 0, z = 0}, camVisible = false,
    pursuit = {mode = 0}, model = model}
  for k, v in pairs(over or {}) do td[id][k] = v end
end
gameplay_traffic = {getTrafficData = function() return td end, insertTraffic = function(id) inserted[#inserted + 1] = id end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}

-- the game's own replaceVehicle: a different model means a new object and the old one is deleted
local replaceCalls, replaceMode = {}, "ok"
local function vanillaReplace(model, options, old)
  replaceCalls[#replaceCalls + 1] = {model = model, options = options, old = old}
  if replaceMode == "error" then error("replace blew up") end
  if replaceMode == "nothing" then return nil end
  if replaceMode == "inplace" then   -- the game respawns the SAME object with the new model (same id); the traffic data keeps its old name
    old.jbeam = model
    old.partConfig = "vehicles/" .. model .. "/" .. tostring(options.config) .. ".pc"
    return old
  end
  objects[old:getID()] = nil
  td[old:getID()] = nil          -- the game forgets a deleted traffic car
  nextId = nextId + 1
  addObject(nextId, model, "vehicles/" .. model .. "/" .. tostring(options.config) .. ".pc")
  return objects[nextId]
end
package.loaded["rlsmp/lib/replaceGuard"] = {getVanilla = function() return vanillaReplace end}

-- Claude A's rules and the variety extension ---------------------------------------------------------------------------------
package.loaded["rlsmp/lib/personality"] = P
package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 1} end}
package.loaded["rlsmp/bubble"] = {stayFor = function(veh) return veh.near == true end}
local types = {pickup = "Truck", van = "Truck", sedan = "Car", hatch = "Car"}
local config, night, zone = nil, true, "city"
local offered = {{model = "sedan", config = "s1"}, {model = "hatch", config = "h1"}, {model = "pickup", config = "p1"}}
package.loaded["rlsmp/trafficVariety"] = {
  getConfig = function() return config end,
  candidates = function() return offered end,
  contextNow = function() return {night = night, zone = zone} end,
  infoOf = function(e) return {type = types[e.model]} end,
}

local T = require("rlsmp/trafficSwap")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function setConfig(over)
  local c = {night = {Truck = 0}, swap = {enabled = true, hiddenSeconds = 2, checkSeconds = 0.5, perMinute = 2}}
  for k, v in pairs(over or {}) do if k == "swap" then for a, b in pairs(v) do c.swap[a] = b end else c[k] = v end end
  c.preload = c.preload or {slowFrameMs = 2000, minGapSeconds = 0, settleSeconds = 0}   -- the tests step 0.5 s per frame
  config = V.sanitize(c)
end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5) do T.onUpdate(0.5) end end
local function reset()
  objects, td, inserted, replaceCalls, replaceMode = {}, {}, {}, {}, "ok"
  logged = {}
  T.onServerLeave()
end

-- 1. nothing happens until switched on -----------------------------------------------------------------------------------------
addObject(1, "unicycle")
addCar(10, "pickup")
config = nil
run(10)
check(#replaceCalls == 0 and not saw("swap"), "no settings yet: nothing")
setConfig({swap = {enabled = false}})
run(10)
check(#replaceCalls == 0 and not saw("swap"), "swap.enabled false: nothing, not even a log line")

-- 2. watch only (the default way to try it): decisions are logged, the game is not touched --------------------------------------------------
setConfig()
run(1)
check(not saw("swap would happen"), "hidden for 1 s only: not yet (needs 2 s)")
run(2)
check(saw("swap would happen (watch only): car 10 pickup (Truck, weight 0.00) -> "), "after 2 s hidden a truck at night: the log says what would happen")
check(#replaceCalls == 0 and #inserted == 0 and objects[10] ~= nil, "watch only: the game is not touched")
check(saw("zone=city night=true"), "zone and night in the log line")

-- 3. a car anybody can see is never a candidate ----------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup", {camVisible = true}) setConfig()
run(10)
check(not saw("would happen"), "visible on this camera: never")
reset() addObject(1, "unicycle") addCar(10, "pickup", {near = true}) setConfig()
run(10)
check(not saw("would happen"), "near or visible to another player (bubble): never")
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig()
local hiddenNow = package.loaded["rlsmp/bubble"]
package.loaded["rlsmp/bubble"] = nil
run(10)
check(not saw("would happen"), "without the bubble rules nobody can say who sees the car: never")
package.loaded["rlsmp/bubble"] = hiddenNow
-- flicker: seen again resets the count
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {hiddenSeconds = 3}})
run(2) td[10].camVisible = true run(0.5) td[10].camVisible = false run(2)
check(not saw("would happen"), "seen again: the hidden time starts over")
run(2)
check(saw("would happen"), "hidden long enough in a row: now")

-- 4. cars RLS or the game owns are left alone ---------------------------------------------------------------------------------------------
for name, over in pairs({police = {role = {name = "police"}}, pursuit = {pursuit = {mode = 2}}, notAi = {isAi = false}, crashed = {activeData = {tCrash = 5}},
    inactive = {state = "fadeOut"}, player = {}}) do
  reset() addObject(1, "unicycle") addCar(10, "pickup", over) setConfig()
  if name == "player" then package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 10} end} end
  run(10)
  package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 1} end}
  check(not saw("would happen"), name .. " car: never swapped")
end

-- 5. weights decide ---------------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({night = {}})   -- no weights: everything weighs 1
run(10)
check(not saw("would happen"), "default weights: nothing to gain, nothing swapped")
reset() addObject(1, "unicycle") addCar(10, "sedan") setConfig({night = {Truck = 0}})
run(10)
check(not saw("would happen"), "a car at night when only trucks are unwanted: stays")

-- 6. rate limit ------------------------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") setConfig({swap = {perMinute = 2, hiddenSeconds = 1}})
for id = 10, 15 do addCar(id, "pickup") end
run(10)
local count = 0
for _, l in ipairs(logged) do if l:find("swap would happen", 1, true) then count = count + 1 end end
check(count == 2, "six hidden trucks, perMinute 2: two decisions in the first minute (" .. count .. ")")
run(60)
count = 0
for _, l in ipairs(logged) do if l:find("swap would happen", 1, true) then count = count + 1 end end
check(count == 4, "a minute later two more (" .. count .. ")")
local ids = {}
for _, l in ipairs(logged) do
  local id = l:match("swap would happen %(watch only%): car (%d+)")
  if id then ids[id] = (ids[id] or 0) + 1 end
end
local distinct = 0
for _, n in pairs(ids) do distinct = distinct + 1 check(n == 1, "a car is looked at once, not again and again") end
check(distinct == 4, "four decisions, four different cars (" .. distinct .. ")")

-- 7. LIVE (experimental): the car is replaced and the new one goes to RLS's traffic --------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {live = true}})
run(3)
check(#replaceCalls == 1 and replaceCalls[1].old ~= nil, "live: the game's own replaceVehicle is called once, for that car")
check(replaceCalls[1].model ~= "pickup" and types[replaceCalls[1].model] == "Car", "the replacement is a car (a truck is not wanted at night)")
check(replaceCalls[1].options.autoEnterVehicle == false and replaceCalls[1].options.config ~= nil, "named config, the player is not put into it")
check(objects[10] == nil, "the old car is gone")
check(#inserted == 1 and inserted[1] == nextId, "the new car was given to RLS's traffic (insertTraffic)")
check(saw("swap LIVE: car 10 pickup") and saw("swap done (new id): car 10 is now car " .. nextId), "attempt and result are logged, and it says a new id was made")
check(saw("traffic: inserted into traffic"), "the new car was not in RLS traffic yet, so it was inserted")
run(10)
check(#replaceCalls == 1, "no other car qualifies: no second swap")

-- 7b. LIVE, the game changes the car IN PLACE (same id): also a success, nothing is inserted twice, and the car is not swapped again
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {live = true}})
replaceMode = "inplace"
run(3)
check(#replaceCalls == 1 and objects[10].jbeam ~= "pickup" and types[objects[10].jbeam] == "Car", "in place: the same object now has a car model")
check(saw("swap done (replaced in place, same id): car 10 is now car 10") and saw("traffic: already in traffic"), "success, and the log says it was in place")
check(#inserted == 0, "the traffic system already knew the car: not inserted a second time")
check(td[10].model == "pickup", "(the traffic data still has the old model name)")
check(not T.isLiveOff(), "a successful in place swap is not a failure")
run(200)
check(#replaceCalls == 1, "the swapped car is not swapped again (current model read from the object, and a cooldown)")
check(T.isLiveOff() == false, "...and live stays on")
-- a car that was looked at once is left alone for 10 minutes, swapped or not
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {perMinute = 12}})
run(3)
local n1 = 0 for _, l in ipairs(logged) do if l:find("swap would happen", 1, true) then n1 = n1 + 1 end end
run(300)
local n2 = 0 for _, l in ipairs(logged) do if l:find("swap would happen", 1, true) then n2 = n2 + 1 end end
check(n1 == 1 and n2 == 1, "watch only: the same car is not logged again within 10 minutes (" .. n1 .. "," .. n2 .. ")")
run(400)
n2 = 0 for _, l in ipairs(logged) do if l:find("swap would happen", 1, true) then n2 = n2 + 1 end end
check(n2 == 2, "...after the cooldown it may be looked at again (" .. n2 .. ")")

-- 8. LIVE failures switch it off -------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") setConfig({swap = {live = true, perMinute = 12, hiddenSeconds = 1, maxFailures = 3}})
for id = 10, 19 do addCar(id, "pickup") end
replaceMode = "error"
run(20)
check(#replaceCalls == 3, "three failed replaces, then it stops trying (" .. #replaceCalls .. ")")
check(saw("swap failed: ") and saw("live swapping switched itself off after too many failures"), "failures are logged and live switches itself off")
check(T.isLiveOff(), "live is off")
local liveCallsAtOff = #replaceCalls
replaceMode = "ok"
run(30)
check(#replaceCalls == liveCallsAtOff and saw("would happen (watch only)"), "after that it only watches")
T.onServerLeave()
check(not T.isLiveOff(), "leaving the server resets the failure count")

-- 9. the replace returns but no new car ever appears ---------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {live = true, maxFailures = 5}})
replaceMode = "nothing"
run(2.5)
check(#replaceCalls == 1 and #inserted == 0, "a replace that creates nothing")
run(5)
check(saw("swap failed: no new car appeared after the replace"), "...is noticed after 3 s and counted as a failure")

-- 10. no vanilla replace available ---------------------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig({swap = {live = true}})
package.loaded["rlsmp/lib/replaceGuard"] = {getVanilla = function() return nil end}
run(5)
check(saw("swap failed: the game's own replaceVehicle or the car is not available") and objects[10] ~= nil, "no game replace function: a failure, the car stays")
package.loaded["rlsmp/lib/replaceGuard"] = {getVanilla = function() return vanillaReplace end}

-- 11. outside a session / career nothing runs --------------------------------------------------------------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig()
MPCoreNetwork = {isMPSession = function() return false end}
run(10)
check(not saw("would happen"), "single player: nothing")
MPCoreNetwork = {isMPSession = function() return true end}

-- 12. extensions are found by their global name too (how core.lua finds them), and a missing one is said once --------------------------------------------------
reset() addObject(1, "unicycle") addCar(10, "pickup") setConfig()
local varietyStub, bubbleStub, personalitiesStub = package.loaded["rlsmp/trafficVariety"], package.loaded["rlsmp/bubble"], package.loaded["rlsmp/personalities"]
package.loaded["rlsmp/trafficVariety"], package.loaded["rlsmp/bubble"], package.loaded["rlsmp/personalities"] = nil, nil, nil
_G.rlsmp_trafficVariety, _G.rlsmp_bubble, _G.rlsmp_personalities = varietyStub, bubbleStub, personalitiesStub
run(5)
check(saw("swap would happen"), "found through the global names (rlsmp_trafficVariety, rlsmp_bubble, rlsmp_personalities)")
_G.rlsmp_trafficVariety = nil
reset()
run(5)
check(saw("rlsmp_trafficVariety was not found: live swapping cannot work"), "a missing rlsmp_trafficVariety is said, not silently ignored")
_G.rlsmp_bubble, _G.rlsmp_personalities = nil, nil
package.loaded["rlsmp/trafficVariety"], package.loaded["rlsmp/bubble"], package.loaded["rlsmp/personalities"] = varietyStub, bubbleStub, personalitiesStub

print(string.format("traffic_swap_client_test: %d checks passed", passed))
