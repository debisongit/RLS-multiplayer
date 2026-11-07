-- replaceVehicle guard test (LuaJIT). Run: luajit tests/replace_guard_test.lua
-- Fakes BeamMP's replaceRequest(model, config, colors), which ignores its third argument like the real one.
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end

local calls = {}
local mpSession = true
local playerId = 50                       -- the player is on foot (walking character 50)
local objs = {
  [1] = {id = 1, jbeam = "etk800"}, [2] = {id = 2, jbeam = "pickup"}, [50] = {id = 50, jbeam = "unicycle"}, [9] = {id = 9, jbeam = "etk800"},
}
for id, o in pairs(objs) do o.getID = function() return id end end
be = {getObjectByID = function(_, id) return objs[id] end}
getPlayerVehicle = function() return objs[playerId] end
local beammp = {
  ["0-1"] = {gameVehicleID = 1, isLocal = true, jbeam = "etk800"},
  ["0-50"] = {gameVehicleID = 50, isLocal = true, jbeam = "unicycle"},
  ["1-9"] = {gameVehicleID = 9, isLocal = false, jbeam = "etk800"},
  -- car 2 is not registered with BeamMP (just spawned)
}
MPVehicleGE = {getVehicles = function() return beammp end}
MPCoreNetwork = {isMPSession = function() return mpSession end}

-- the game's own function, then BeamMP's replacement
local function gameReplace(model, config, target) calls[#calls + 1] = {who = "game", model = model, target = target and target:getID()} return "game-new-car" end
core_vehicles = {replaceVehicle = gameReplace}
local function beammpReplace(model, config, colors) calls[#calls + 1] = {who = "beammp", model = model, target = colors and colors:getID()} return "beammp-new-car" end
MPVehicleGE.replaceRequest = beammpReplace

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function last() return calls[#calls] end

local g = require("rlsmp/lib/replaceGuard")

-- 1. We load before BeamMP joins: the game's own function is captured
check(g.install() == true and g.hasVanilla() == true and core_vehicles.replaceVehicle ~= gameReplace, "wrapped, game's own function captured")
local ourFn = core_vehicles.replaceVehicle
g.install()
check(core_vehicles.replaceVehicle == ourFn, "installing again does not stack wrappers")
-- 2. BeamMP joins and swaps the function: we wrap its version, and never capture it as the game's own
core_vehicles.replaceVehicle = beammpReplace
check(g.install() == true and core_vehicles.replaceVehicle == ourFn, "re-wrapped after BeamMP replaced the function (BeamMP's version is now the one behind us)")
ourFn = core_vehicles.replaceVehicle
g.install()
check(core_vehicles.replaceVehicle == ourFn, "still no stacking")

-- 3. THE BUG: part shop, player on foot, RLS replaces the car (3rd argument)
calls = {}
local result = core_vehicles.replaceVehicle("etk800", {config = "x"}, objs[1])
check(last().who == "game" and last().target == 1 and result == "game-new-car", "on foot in the shop: the named car is replaced by the game itself")
check(beammp["0-1"].jbeam == "-", "BeamMP is told to sync it as an edit")
check(#calls == 1, "BeamMP's replace (which would replace the walker) is not called")
check(saw("RLSMP-REPLACE|replace etk800 target=1(etk800) but player is in 50(unicycle) (beammp knows target: true): replacing the target itself"), "decision is logged")

-- 4. The player's own car, registered: BeamMP's path is right
playerId = 1
calls = {}
core_vehicles.replaceVehicle("etk800", {}, objs[1])
check(last().who == "beammp", "replacing the car you sit in: passthrough to BeamMP")
check(saw("RLSMP-REPLACE|replace etk800 target=1(etk800) is the player's own car"), "passthrough is logged")

-- 5. No target: passthrough (that is the player's vehicle by definition)
calls = {}
core_vehicles.replaceVehicle("etk800", {})
check(last().who == "beammp" and #calls == 1, "no third argument: passthrough")

-- 6. Another player's car is never touched by us
playerId = 50
calls = {}
core_vehicles.replaceVehicle("etk800", {}, objs[9])
check(last().who == "beammp", "another player's car: left to BeamMP")

-- 7. The car is the player's but BeamMP does not know it yet (it would SPAWN A NEW CAR instead of replacing)
playerId = 2
calls = {}
core_vehicles.replaceVehicle("pickup", {}, objs[2])
check(last().who == "game" and last().target == 2, "own car unknown to BeamMP: replaced by the game, no stray new car")
check(beammp["0-2"] == nil, "nothing invented in BeamMP's list")

-- 8. Not in a multiplayer session: untouched
playerId = 50
mpSession = false
calls = {}
core_vehicles.replaceVehicle("etk800", {}, objs[1])
check(last().who == "beammp", "single player: passthrough")
mpSession = true

-- 9. Leaving the server: BeamMP puts the game's function back; we wrap that again without breaking anything
core_vehicles.replaceVehicle = gameReplace
g.install()
check(core_vehicles.replaceVehicle ~= gameReplace, "wrapped again after leaving the server")
mpSession = false
calls = {}
core_vehicles.replaceVehicle("etk800", {}, objs[1])
check(last().who == "game" and #calls == 1, "outside a session the game's own function runs once")

print(string.format("replace_guard_test: %d checks passed", passed))
