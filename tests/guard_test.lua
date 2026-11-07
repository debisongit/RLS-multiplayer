-- Vehicle guard test (LuaJIT). Run: luajit tests/guard_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
function setExtensionUnloadMode() end
local own = {[1] = true, [2] = true, [3] = true}
local entered, walking, toasts
MPVehicleGE = {getVehicles = function()
  local t = {}
  for id in pairs(own) do t["0-" .. id] = {gameVehicleID = id, isLocal = true} end
  t["1-9"] = {gameVehicleID = 9, isLocal = false}
  t["1-10"] = {gameVehicleID = 10, isLocal = false}   -- another player's walking character
  return t
end}
local traffic = {[2] = {isAi = true}, [3] = {isAi = false}, [60] = {isAi = true}, [61] = {isAi = true}, [62] = {isAi = true}}  -- 3 = player-driven traffic-system car (RLS job)
gameplay_traffic = {getTrafficData = function() return traffic end}
gameplay_parking = {getParkedCarsList = function() return {5} end}
own[5] = true
local objs = {[10] = {jbeam = "unicycle"}, [1] = {name = "car1", jbeam = "etk800"}, [3] = {name = "car3", jbeam = "etk800"}, [50] = {jbeam = "unicycle"},
  [9] = {jbeam = "etk800", getPosition = function() return setmetatable({x = 5, y = 6, z = 7}, {__add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}) end}}
local playerVeh = 1
be = {getObjectByID = function(_, id) return objs[id] end, enterVehicle = function(_, _, o) entered = o end,
  getPlayerVehicleID = function() return playerVeh end}
local walkArgs
vec3 = function(x, y, z) return {x = x, y = y, z = z} end
local function mkWalk() return {setWalkingMode = function(_, pos) walking = true walkArgs = pos end,
  isVehicleBlacklisted = function(id) return id == 99 end, getInVehicle = function(v) _G.__entered = v end} end
gameplay_walk = mkWalk()
guihooks = {trigger = function() toasts = (toasts or 0) + 1 end}

-- RLS's taxi service: 60 = the cab hailed for the player, 61 = an ordinary taxi in traffic, 62 = a taxi on its way
local taxiStates = {[60] = "waitingForPickup", [61] = "available", [62] = "enRoute"}
overhaul_integration_services_taxi = {getTaxiState = function(id) return taxiStates[id] or "available" end}

local g = require("rlsmp/vehicleGuard")
g.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(g.isBlocked(9) == true, "other player's car blocked")
check(g.isBlocked(77) == false, "a car BeamMP does not know yet (just spawned) is allowed")
check(g.isBlocked(2) == true, "own AI traffic blocked")
check(g.isBlocked(5) == true, "parked car blocked")
check(g.isBlocked(1) == false, "own car allowed")
check(g.isBlocked(3) == false, "player-driven traffic-system car allowed (RLS jobs)")
check(g.isBlocked(-1) == false, "no vehicle is fine")

g.onVehicleSwitched(1, 9)
check(entered == nil, "disabled guard does nothing")
g.enable(true)
g.onVehicleSwitched(1, 9)
check(entered == objs[1] and toasts == 1, "put back in the previous car")
entered, walking = nil, nil
g.onVehicleSwitched(9, 2)
check(walking and entered == nil, "no valid previous car -> on foot")
entered = nil
g.onVehicleSwitched(1, 3)
check(entered == nil, "allowed switch untouched")
-- refused up front: RLS asks gameplay_walk before it lets a walking player in
local g2 = require("rlsmp/vehicleGuard")
g2.enable(true)
local walk = gameplay_walk
local origIn = walk.getInVehicle
check(g2.install() == true and walk.getInVehicle ~= origIn, "walking module is wrapped")
local wrappedFn = walk.getInVehicle
g2.install()
check(walk.getInVehicle == wrappedFn, "installing again does not stack wrappers")
check(walk.isVehicleBlacklisted(9) == true, "another player's car counts as blacklisted for entering")
check(walk.isVehicleBlacklisted(1) == false and walk.isVehicleBlacklisted(99) == true, "own cars pass, the game's own blacklist still applies")
_G.__entered = nil
local t0 = toasts
walk.getInVehicle({getID = function() return 9 end})
check(_G.__entered == nil and toasts == t0 + 1, "entering a remote car is refused with a message and nothing is switched")
walk.getInVehicle({getID = function() return 1 end})
check(_G.__entered ~= nil, "entering your own car works as before")
gameplay_walk = mkWalk()
check(g2.install() == true and gameplay_walk.getInVehicle ~= nil, "a reloaded walking module is wrapped again")

-- a switch that slips through while walking: no re-entering the (deleted) walking character
entered, walking, walkArgs = nil, nil, nil
g2.onVehicleSwitched(50, 9)
check(entered == nil and walking == true, "walker is put back on foot, not into the deleted character")
check(walkArgs and walkArgs.x == 5 and walkArgs.y == 6, "on foot beside the refused car, not at a default spawn")

-- RLS's hailed taxi may be entered, every other AI taxi may not -------------------------------------------------------------
gameplay_walk = mkWalk()
g2.install()
local atOrigin = function() return setmetatable({x = 0, y = 0, z = 0}, {__add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}) end
objs[60], objs[61], objs[62] = {jbeam = "taxi", getPosition = atOrigin}, {jbeam = "taxi", getPosition = atOrigin}, {jbeam = "taxi", getPosition = atOrigin}
check(g.isBlocked(60) == false, "the cab hailed for you is allowed")
check(g.isBlocked(61) == true and g.isBlocked(62) == true, "other AI taxis stay blocked")
for _, state in ipairs({"pullingOverForPickup", "waitingForPickup", "occupied", "pullingOverForDropoff", "waitingForDropoff"}) do
  taxiStates[60] = state
  check(g.isBlocked(60) == false, "taxi state " .. state .. " is boardable")
end
for _, state in ipairs({"available", "unavailable", "enRoute", "driverDistress"}) do
  taxiStates[60] = state
  check(g.isBlocked(60) == true, "taxi state " .. state .. " is not boardable")
end
taxiStates[60] = "waitingForPickup"
check(gameplay_walk.isVehicleBlacklisted(60) == false and gameplay_walk.isVehicleBlacklisted(61) == true, "walking: hailed cab enterable, other taxis not")
_G.__entered = nil
gameplay_walk.getInVehicle({getID = function() return 60 end})
check(_G.__entered ~= nil, "walking into the hailed cab goes through")
entered, walking = nil, nil
g.onVehicleSwitched(50, 60)
check(entered == nil and walking == nil, "RLS boarding the cab by a vehicle switch is not reverted")
check(saw("RLSMP-GUARD|switch 50(unicycle) -> 60(taxi): ok (hired cab)"), "switch is logged")
check(saw("RLSMP-GUARD|ALLOWED id=60 jbeam=taxi beammp=unregistered: taxi hailed for you (waitingForPickup)"), "allowed decision is logged with its reason")
g.onVehicleSwitched(50, 61)
check(walking == true, "an ordinary taxi is still refused")
check(saw("RLSMP-GUARD|BLOCKED id=61 jbeam=taxi beammp=unregistered: AI traffic (taxi state: available)"), "blocked decision names the taxi state")
local savedTaxi = overhaul_integration_services_taxi
overhaul_integration_services_taxi = nil
check(g.isBlocked(60) == true, "no taxi service loaded: AI cars stay blocked")
overhaul_integration_services_taxi = {getTaxiState = function() error("boom") end}
check(g.isBlocked(60) == true, "a failing taxi service never lets anything through")
overhaul_integration_services_taxi = savedTaxi

-- Riding along in another player's car (server switch, off by default) ---------------------------------------------------
walking, entered = nil, nil
playerVeh = 50   -- the player is on foot
check(g.getAllowPassengers() == false and g.isBlocked(9) == true, "passengers are off by default")
handlers["rlsmpVehicleConfig"](json.encode({allowPassengers = true}))
check(g.getAllowPassengers() == true and saw("RLSMP-GUARD|config received allowPassengers=true"), "server turns passengers on")
check(g.isBlocked(9) == false, "on foot: another player's car is a passenger seat")
check(g.isBlocked(9, 50) == false, "...also when the vehicle we come from is given")
check(g.isBlocked(10) == true, "another player's walking character is never enterable")
check(g.isBlocked(9, 1) == true, "from inside a car you cannot hop into someone else's")
check(g.isBlocked(2) == true and g.isBlocked(5) == true, "AI traffic and parked cars stay blocked")
check(saw("RLSMP-GUARD|ALLOWED id=9 jbeam=etk800 beammp=remote: passenger seat in another player's car"), "passenger decision is logged")
g.onVehicleSwitched(50, 9)
check(walking == nil and entered == nil, "walking into a friend's car is not reverted")
walking = nil
playerVeh = 1
g.onVehicleSwitched(1, 9)
check(entered == objs[1], "from a car it is still refused and you are put back")
g.onServerLeave()
playerVeh = 50
check(g.getAllowPassengers() == false and g.isBlocked(9) == true, "leaving the server turns passengers off again")

print(string.format("guard_test: %d checks passed", passed))
