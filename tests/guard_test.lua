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
  t["2-9"] = {gameVehicleID = 9, isLocal = false}      -- player 2's car (player 2 is driving: no walker of player 2)
  t["1-10"] = {gameVehicleID = 10, isLocal = false}   -- another player's walking character
  t["1-11"] = {gameVehicleID = 11, isLocal = false, hideNametag = true}   -- another player's AI traffic car (e.g. their taxi)
  t["1-12"] = {gameVehicleID = 12, isLocal = false}   -- player 1's car; player 1 is on foot (walker 10), so nobody drives it
  return t
end}
local traffic = {[2] = {isAi = true}, [3] = {isAi = false}, [60] = {isAi = true}, [61] = {isAi = true}, [62] = {isAi = true}}  -- 3 = player-driven traffic-system car (RLS job)
gameplay_traffic = {getTrafficData = function() return traffic end}
gameplay_parking = {getParkedCarsList = function() return {5} end}
own[5] = true
local objs = {[12] = {jbeam = "etk800"}, [10] = {jbeam = "unicycle"}, [1] = {name = "car1", jbeam = "etk800"}, [3] = {name = "car3", jbeam = "etk800"}, [50] = {jbeam = "unicycle"},
  [9] = {jbeam = "etk800", getPosition = function() return setmetatable({x = 5, y = 6, z = 7}, {__add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}) end}}
local playerVeh = 1
be = {getObjectByID = function(_, id) return objs[id] end, enterVehicle = function(_, _, o) entered = o end,
  getPlayerVehicleID = function() return playerVeh end}
local walkArgs, lastWalk
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
check(g.isBlocked(11, 50) == true and g.isBlocked(11) == true, "another player's traffic or parked car is never a passenger seat, even on foot")
check(saw("RLSMP-GUARD|BLOCKED id=11 jbeam=nil beammp=remote: another player's traffic or parked car"), "traffic block is logged")
check(g.isBlocked(9, 1) == true, "from inside a car you cannot hop into someone else's")
check(g.isBlocked(2) == true and g.isBlocked(5) == true, "AI traffic and parked cars stay blocked")
check(saw("RLSMP-GUARD|ALLOWED id=9 jbeam=etk800 beammp=remote: passenger seat in player 2's car"), "passenger decision is logged")
check(g.isBlocked(12) == true and saw("player 1 is on foot, nobody drives it"), "a car whose owner stands beside it on foot is not a seat")
g.onVehicleSwitched(50, 9)
check(walking == nil and entered == nil, "walking into a friend's car is not reverted")
check(g.isRiding() == 9 and saw("passenger ride started in car 9 of player 2"), "the ride is tracked and logged")
walking = nil
playerVeh = 1
g.onVehicleSwitched(1, 9)
check(entered == objs[1], "from a car it is still refused and you are put back")

-- the owner's traffic list must have arrived (otherwise a parked car without hideNametag yet could look like a player car)
local heard = false
rlsmp_trafficLabels = {heardFrom = function(pid) return heard end}
gameplay_walk = mkWalk()
playerVeh = 50
lastWalk = nil
check(g.isBlocked(9) == true and saw("traffic list of player 2 not received yet"), "owner's traffic list not received yet: refused")
heard = true
check(g.isBlocked(9) == false, "list received: passenger seat")

-- seat: RLS seats a walker through requestEnterBestSeat (driver seat). For another player's car only a passenger seat is given.
local seatCalls, libResult = {}, true
gameplay_seatOccupants = {requestEnterBestSeat = function(id) seatCalls[#seatCalls + 1] = "best " .. id return true end,
  getPlayerPresence = function() return _G.__presence end}
package.loaded["overhaul/lib/vehicles/passengerSeats"] = {enter = function(id) seatCalls[#seatCalls + 1] = "passenger " .. id return libResult, {seatId = "p1"} end}
g.install()
check(gameplay_seatOccupants.requestEnterBestSeat(9) == true and seatCalls[#seatCalls] == "passenger 9", "remote car: a passenger seat, never the driver seat")
check(gameplay_seatOccupants.requestEnterBestSeat(1) == true and seatCalls[#seatCalls] == "best 1", "own car: RLS's normal seating")
libResult = false
check(gameplay_seatOccupants.requestEnterBestSeat(9) == false and saw("no passenger seat could be given"), "no passenger seat: refused, stays on foot")
libResult = true
check(gameplay_seatOccupants.requestEnterBestSeat(11) == false and saw("seat refused id=11"), "another player's traffic car: no seat at all")
local seatFn = gameplay_seatOccupants.requestEnterBestSeat
g.install()
check(gameplay_seatOccupants.requestEnterBestSeat == seatFn, "seat wrapper is installed once")

-- watchdog: the passenger rides along; every way the ride can end puts them on foot beside the car
local function ride()
  g.stopRide("test")
  playerVeh = 9
  objs[9].getDirectionVector = function() return {x = 0, y = 1, z = 0} end
  g.onVehicleSwitched(50, 9)
  walking, walkArgs = nil, nil
end
local function ticks(n) for _ = 1, n do g.onUpdate(0.5) end end
objs[9].getPosition = function() return {x = 5, y = 6, z = 7} end
ride()
check(g.isRiding() == 9, "riding")
_G.__presence = {vehicleId = 9, permissionMode = "passenger"}
ticks(4)
check(g.isRiding() == 9 and walking == nil, "a normal passenger ride is left alone")
-- the driver gets out: a walking character of player 2 appears
local mpGet = MPVehicleGE.getVehicles
MPVehicleGE.getVehicles = function() local t = mpGet() t["2-77"] = {gameVehicleID = 77, isLocal = false} return t end
objs[77] = {jbeam = "unicycle"}
ticks(1)
check(g.isRiding() == 9 and walking == nil, "a moment of the driver on foot is tolerated")
ticks(4)
check(g.isRiding() == nil and walking == true and saw("the driver (player 2) got out"), "driver got out: the passenger is put on foot")
check(walkArgs and walkArgs.x ~= nil and walkArgs.z == 7.5, "...beside the car")
MPVehicleGE.getVehicles = mpGet
-- driver seat by mistake: no controls
ride()
_G.__presence = {vehicleId = 9, permissionMode = "driver"}
ticks(1)
check(g.isRiding() == nil and walking == true and saw("seat mode is driver"), "seat mode driver: put out, the passenger never gets the controls")
_G.__presence = {vehicleId = 9, permissionMode = "passenger"}
-- the car is deleted (driver left the server)
ride()
objs[9].getPosition = nil
g.onVehicleDestroyed(9)
check(g.isRiding() == nil and walking == true and saw("the car was deleted"), "car deleted: passenger put on foot at the last place")
check(walkArgs and walkArgs.x ~= nil, "...at the car's last known place")
objs[9].getPosition = function() return {x = 5, y = 6, z = 7} end
-- the passenger leaves by themselves
ride()
playerVeh = 50
ticks(1)
check(g.isRiding() == nil and walking == nil and saw("player vehicle is now 50"), "leaving the car yourself ends the ride, nothing forced")
-- passengers switched off while riding
ride()
handlers["rlsmpVehicleConfig"](json.encode({allowPassengers = false}))
ticks(1)
check(g.isRiding() == nil and walking == true, "passengers switched off: the rider is put out")
handlers["rlsmpVehicleConfig"](json.encode({allowPassengers = true}))
-- playerUsable
playerVeh = 50
objs[9].playerUsable = false
ticks(1)
check(objs[9].playerUsable == true and saw("made car 9 usable for passengers"), "a remote player car is made usable for passengers")
objs[11] = {jbeam = "etk800", playerUsable = false}
ticks(1)
check(objs[11].playerUsable == false, "AI traffic and parked cars are never made usable")
ride()
g.onServerLeave()
playerVeh = 50
check(g.getAllowPassengers() == false and g.isBlocked(9) == true and g.isRiding() == nil, "leaving the server turns passengers off and ends the ride")

print(string.format("guard_test: %d checks passed", passed))
