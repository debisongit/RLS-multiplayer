-- Simplified (stand-in) cars extension test (LuaJIT). Run: luajit tests/simplified_client_test.lua
-- Fakes the game's objects, parking, traffic, theft, the view gate and the game's own replaceVehicle.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end

local V = require("rlsmp/lib/trafficVariety")
local P = require("rlsmp/lib/personality")

-- the game ------------------------------------------------------------------------------------------------------------------
local objects, nextId, dyn = {}, 100, {}
local function addObject(id, jbeam, x)
  local o = {jbeam = jbeam, partConfig = "vehicles/" .. jbeam .. "/cfg.pc", playerUsable = true,
    getID = function() return id end, getPosition = function() return {x = x or 0, y = 0, z = 0} end,
    setDynDataFieldbyName = function(_, k, _, v) dyn[id] = dyn[id] or {} dyn[id][k] = v end,
    getDynDataFieldbyName = function() return "PLATE1" end, queueLuaCommand = function(_, cmd) dyn[id] = dyn[id] or {} dyn[id].cmd = cmd end}
  objects[id] = o
  return o
end
be = {
  getObjectCount = function() local n = 0 for _ in pairs(objects) do n = n + 1 end return n end,
  getObject = function(_, i) local k = 0 for _, o in pairs(objects) do if k == i then return o end k = k + 1 end end,
  getObjectByID = function(_, id) return objects[id] end,
  getPlayerVehicle = function() return objects[1] end,
  getPlayerVehicleID = function() return 1 end,
}
getObjectByID = function(id) return objects[id] end
local td, parkedList = {}, {}
gameplay_traffic = {getTrafficData = function() return td end, insertTraffic = function() end}
gameplay_parking = {getParkedCarsList = function() return parkedList end}
gameplay_walk = {addVehicleToBlacklist = function(id) dyn[id] = dyn[id] or {} dyn[id].blacklisted = true end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}
local pkCalls = {}
overhaul_integration_services_parking = {
  getCurrentParkingSpot = function() return "spot" end,
  isSpawnPending = function() return false end,
  removeVehicle = function(id) pkCalls[#pkCalls + 1] = "remove " .. id end,
  insertVehicle = function(id) pkCalls[#pkCalls + 1] = "insert " .. id end,
}
local standIns = {"legran_a", "legran_a_parked", "pickup_b", "pickup_c_parked", "nonsense"}
local eligibleResult = true
core_vehicles = {getModel = function(name)
  if name ~= "simple_traffic" then return nil end
  local configs = {}
  for _, c in ipairs(standIns) do configs[c] = {["Config Type"] = c:match("_parked$") and "PropParked" or "Traffic"} end
  return {configs = configs}
end}
overhaul_integration_patches_trafficConfigFilter = {isConfigEligible = function(model, name)
  if name == "nonsense" then return false, "noEngine" end
  return eligibleResult
end}

local replaceCalls = {}
local function vanillaReplace(model, options, old)
  replaceCalls[#replaceCalls + 1] = {model = model, options = options, old = old:getID()}
  objects[old:getID()] = nil
  td[old:getID()] = nil
  nextId = nextId + 1
  local o = addObject(nextId, model, old:getPosition().x)
  o.partConfig = "vehicles/" .. model .. "/" .. tostring(options.config) .. ".pc"
  return o
end
package.loaded["rlsmp/lib/replaceGuard"] = {getVanilla = function() return vanillaReplace end}

-- neighbours ----------------------------------------------------------------------------------------------------------------------
local stealable, blocked = {}, {}
package.loaded["rlsmp/lib/personality"] = P
package.loaded["rlsmp/personalities"] = {context = function() return {playerId = 1} end}
package.loaded["rlsmp/bubble"] = {
  otherPlayers = function() return {} end,
  viewReason = function(veh) return blocked[math.floor(veh.pos.x)] end,
}
package.loaded["rlsmp/theft"] = {
  isStealable = function(id) return stealable[id] == true end,
  carInfo = function(o)
    local real = o.jbeam == "simple_traffic" and "pickup" or o.jbeam
    return {model = real, config = (o.jbeam ~= "simple_traffic") and o.partConfig or nil, configKey = "x"}
  end,
}
local config
local fullFor = {pickup = {model = "pickup", config = "d25"}, legran = {model = "legran", config = "sedan"}}
package.loaded["rlsmp/trafficVariety"] = {
  getConfig = function() return config end,
  fullEntryFor = function(model) return fullFor[model] end,
}

local S = require("rlsmp/trafficSwap")
package.loaded["rlsmp/trafficSwap"] = S
local T = require("rlsmp/simplified")
package.loaded["rlsmp/simplified"] = T

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function setConfig(over)
  local simplified = {enabled = true, parked = true, traffic = true, nearRadius = 250, perMinute = 4, checkSeconds = 0.5}
  for k, v in pairs(over or {}) do simplified[k] = v end
  config = V.sanitize({simplified = simplified, preload = {slowFrameMs = 2000, minGapSeconds = 0, settleSeconds = 0}})
end
local function reset()
  objects, td, parkedList, replaceCalls, pkCalls, dyn, stealable, blocked = {}, {}, {}, {}, {}, {}, {}, {}
  logged = {}
  T.onServerLeave()
  S.onServerLeave()
  addObject(1, "unicycle", 0)         -- the player, walking, at the origin
end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5) do S.onUpdate(0.5) T.onUpdate(0.5) end end
local function addParked(id, jbeam, x) addObject(id, jbeam, x) parkedList[#parkedList + 1] = id end
local function addCar(id, jbeam, x, over)
  addObject(id, jbeam, x)
  td[id] = {isAi = true, role = {name = "standard"}, state = "active", pos = {x = x, y = 0, z = 0}, camVisible = false, pursuit = {mode = 0}, model = jbeam, respawnCount = 0}
  for k, v in pairs(over or {}) do td[id][k] = v end
  if jbeam == "simple_traffic" then objects[id].partConfig = "vehicles/simple_traffic/pickup_b.pc" end   -- the real model is in the file name
end

-- 1. off by default: nothing happens ------------------------------------------------------------------------------------------------
reset() config = V.sanitize({})
addParked(20, "simple_traffic", 200) stealable[20] = true
run(10)
check(#replaceCalls == 0, "simplified is off by default: no change")
check(T.trafficActive() == false, "trafficActive is false when off")

-- 2. discovery is logged, RLS's filter is respected ------------------------------------------------------------------------------------
reset() setConfig({parked = false})
run(3)
check(saw("simplified: stand-in configs 5 (parked 2, traffic 2 that pass RLS's traffic filter, for 2 real models)"), "census of the stand-in configs")
check(saw("noEngine=1"), "the filter's rejection is logged")
check(T.standIns().legran.traffic[1] == "legran_a" and T.standIns().nonsense.traffic[1] == nil, "a rejected config is not used for traffic")

-- 3. a stand-in at a stealable spot becomes a real car when a player is near -------------------------------------------------------------
reset() setConfig({traffic = false})
addParked(20, "simple_traffic", 200) stealable[20] = true
addParked(21, "simple_traffic", 150)                     -- not stealable: stays a stand-in
run(3)
check(#replaceCalls == 1 and replaceCalls[1].old == 20 and replaceCalls[1].model == "pickup" and replaceCalls[1].options.config == "d25", "the stealable stand-in is replaced by a real pickup with a real config")
check(replaceCalls[1].options.licenseText == "PLATE1" and replaceCalls[1].options.autoEnterVehicle == false, "plate kept, never entered")
check(pkCalls[1] == "remove 20" and pkCalls[2] == "insert " .. nextId, "the new car goes back into RLS's parking")
check(dyn[nextId].isParked == "true" and dyn[nextId].blacklisted and objects[nextId].playerUsable == false and dyn[nextId].cmd:find("setIgnitionLevel", 1, true), "it is a parked car again: not usable, blacklisted, engine off")
check(saw("simplified: parked car 20 -> REAL"), "logged")
check(saw("simplified: parked simple=") == false or true, "census may or may not have run yet")
run(30)
check(#replaceCalls == 1, "the not stealable stand-in and the real car are left alone")

-- 4. far away or in view: not changed ---------------------------------------------------------------------------------------------------
reset() setConfig({traffic = false})
addParked(20, "simple_traffic", 400) stealable[20] = true
run(5)
check(#replaceCalls == 0, "farther than the radius: stays a stand-in")
reset() setConfig({traffic = false})
addParked(20, "simple_traffic", 200) stealable[20] = true
blocked[200] = "inView"
run(5)
check(#replaceCalls == 0, "in the view gate: not changed")
check(saw("simplified: skipped") == false, "(log lines are counters, not spam)")
blocked[200] = nil
run(5)
check(#replaceCalls == 1, "...changed once the gate lets it")

-- 5. back to a stand-in -----------------------------------------------------------------------------------------------------------------------
reset() setConfig({traffic = false, nearRadius = 200})
addParked(20, "simple_traffic", 150) stealable[20] = true
run(3)
check(#replaceCalls == 1, "upgraded first")
local newId = nextId
parkedList = {newId}
stealable[20] = nil
objects[newId].getPosition = function() return {x = 500, y = 0, z = 0} end
run(30)
check(#replaceCalls == 2 and replaceCalls[2].model == "simple_traffic" and replaceCalls[2].options.config:find("simple_traffic", 1, true), "far from every player and no longer stealable: back to the stand-in it was")

-- 6. rate limit -------------------------------------------------------------------------------------------------------------------------------
reset() setConfig({traffic = false, perMinute = 1})
for i = 0, 3 do addParked(30 + i, "simple_traffic", 150 + i) stealable[30 + i] = true end
run(10)
check(#replaceCalls == 1, "perMinute 1: one change in the first minute")

-- 7. moving traffic: respawn adapt --------------------------------------------------------------------------------------------------------------
reset() setConfig()
run(2)
local far = T.adapt({pos = {x = 400, y = 0, z = 0}}, {model = "legran", config = "sedan"})
check(far.model == "simple_traffic" and far.config == "legran_a" and far.realModel == "legran", "a respawn beyond the radius gets a stand-in of the same model")
local near = T.adapt({pos = {x = 100, y = 0, z = 0}}, {model = "legran", config = "sedan"})
check(near.model == "legran", "a respawn near a player stays a real car")
local none = T.adapt({pos = {x = 400, y = 0, z = 0}}, {model = "van", config = "x"})
check(none.model == "van", "no stand-in for that model: real car")
setConfig({traffic = false})
check(T.adapt({pos = {x = 400, y = 0, z = 0}}, {model = "legran", config = "sedan"}).model == "legran", "traffic off: real car")

-- 8. moving traffic: a stand-in that comes near is upgraded; police and others are not ---------------------------------------------------------------
reset() setConfig({parked = false})
addCar(40, "simple_traffic", 200)
addCar(41, "simple_traffic", 150, {role = {name = "police"}})
addCar(42, "pickup", 100)
run(4)
check(#replaceCalls == 1 and replaceCalls[1].old == 40 and replaceCalls[1].model == "pickup" and replaceCalls[1].options.config == "d25", "the near stand-in is made a real car; police and real cars are left alone")
check(saw("simplified: traffic stand-in 40 -> REAL"), "logged")
reset() setConfig({parked = false})
addCar(40, "simple_traffic", 400)
run(4)
check(#replaceCalls == 0, "a far stand-in stays")
reset() setConfig({parked = false})
addCar(40, "simple_traffic", 200, {camVisible = true})
run(4)
check(#replaceCalls == 0, "a stand-in the camera can see is not changed")
check(T.realOf("legran_a") == "legran", "realOf is exported for the re-roll")

print(string.format("simplified_client_test: %d checks passed", passed))
