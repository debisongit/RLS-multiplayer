-- replaceVehicle guard test (LuaJIT). Run: luajit tests/replace_guard_test.lua
-- The fake BeamMP copies the real one: at join it saves core_vehicles.replaceVehicle as its "original" (even if that is our wrapper)
-- and its replaceRequest(model, config, colors) calls that original and ignores the third argument.
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end

local calls = {}
local mpSession = true
local playerId = 50
local objs = {[1] = {jbeam = "etk800"}, [2] = {jbeam = "pickup"}, [50] = {jbeam = "unicycle"}, [9] = {jbeam = "etk800"}}
for id, o in pairs(objs) do o.getID = function() return id end end
be = {getObjectByID = function(_, id) return objs[id] end}
getPlayerVehicle = function() return objs[playerId] end
local beammp = {
  ["0-1"] = {gameVehicleID = 1, isLocal = true, jbeam = "etk800"},
  ["0-50"] = {gameVehicleID = 50, isLocal = true, jbeam = "unicycle"},
  ["1-9"] = {gameVehicleID = 9, isLocal = false, jbeam = "etk800"},
}
MPVehicleGE = {getVehicles = function() return beammp end}
MPCoreNetwork = {isMPSession = function() return mpSession end}

local function gameReplace(model, config, target) calls[#calls + 1] = {who = "game", model = model, target = target and target:getID()} return "game-new-car" end
local function gameSpawn(model) calls[#calls + 1] = {who = "spawn", model = model} return "spawned" end
core_vehicles = {replaceVehicle = gameReplace, spawnNewVehicle = gameSpawn}

-- BeamMP, as in MPVehicleGE.lua: capture at join, replaceRequest calls the captured original
local originalReplace
local depth = 0
local function replaceRequest(model, config, colors)
  depth = depth + 1
  if depth > 20 then error("INFINITE LOOP: replaceRequest -> original -> replaceRequest") end
  local cur = getPlayerVehicle(0)
  local id = cur and cur:getID() or -1
  local v
  for _, e in pairs(beammp) do if e.gameVehicleID == id then v = e end end
  local r
  if cur and v and v.isLocal then v.jbeam = "-" r = originalReplace(model, config or {})
  else r = core_vehicles.spawnNewVehicle(model, config or {}) end
  depth = depth - 1
  return r
end
MPVehicleGE.replaceRequest = replaceRequest
local function beammpJoin() originalReplace = core_vehicles.replaceVehicle core_vehicles.replaceVehicle = MPVehicleGE.replaceRequest end
local function beammpLeave() core_vehicles.replaceVehicle = originalReplace end

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function last() return calls[#calls] end

local g = require("rlsmp/lib/replaceGuard")

-- 1. We load first: the game's own function is captured, BeamMP then saves OUR wrapper as its original (the real order)
check(g.install() == true and g.hasVanilla() == true, "wrapped, game's own function captured")
local ourFn = core_vehicles.replaceVehicle
g.install()
check(core_vehicles.replaceVehicle == ourFn, "installing again does not stack wrappers")
beammpJoin()
g.install()
check(core_vehicles.replaceVehicle ~= replaceRequest, "re-wrapped after BeamMP replaced the function")
local ours2 = core_vehicles.replaceVehicle
g.install()
check(core_vehicles.replaceVehicle == ours2, "still no stacking")

-- 2. THE FREEZE: no named car while the player sits in his own car must not loop
playerId = 1
calls = {}
local r = core_vehicles.replaceVehicle("pickup", {config = "x"})
check(r == "game-new-car" and #calls == 1 and last().who == "game" and last().target == 1, "replace without a target replaces the player's car (no loop)")
check(beammp["0-1"].jbeam == "-", "BeamMP marker set so the change syncs")
calls = {}
core_vehicles.replaceVehicle("pickup", {}, objs[1])
check(#calls == 1 and last().who == "game" and last().target == 1, "target = the player's own car: no loop")

-- 3. THE PART SHOP BUG: player on foot, RLS names the car
playerId = 50
beammp["0-1"].jbeam = "etk800"
calls = {}
r = core_vehicles.replaceVehicle("etk800", {}, objs[1])
check(r == "game-new-car" and #calls == 1 and last().who == "game" and last().target == 1, "on foot in the shop: the named car is replaced, not the walker")
check(beammp["0-1"].jbeam == "-", "marked as edited")

-- 4. another player's car is never replaced
calls = {}
r = core_vehicles.replaceVehicle("etk800", {}, objs[9])
check(r == nil and #calls == 0, "another player's car: refused")
check(saw("another player's car"), "and logged")

-- 5. a car BeamMP does not know yet: spawn a new one as BeamMP does
calls = {}
r = core_vehicles.replaceVehicle("pickup", {}, objs[2])
check(last().who == "spawn", "unknown car: spawned new")

-- 6. after leaving the server BeamMP puts back what it saved (our wrapper): single player must use the game's function
beammpLeave()
mpSession = false
playerId = 1
calls = {}
r = core_vehicles.replaceVehicle("pickup", {}, objs[1])
check(#calls == 1 and last().who == "game" and r == "game-new-car", "single player after leaving: the game's own function, no loop")
g.install()
calls = {}
core_vehicles.replaceVehicle("pickup", {})
check(#calls == 1 and last().who == "game", "single player without a target: game's own function")

-- 7. an error inside is contained
mpSession = true
core_vehicles.spawnNewVehicle = function() error("boom") end
calls = {}
r = core_vehicles.replaceVehicle("pickup", {}, objs[2])
check(r == nil and saw("replace failed"), "an error is logged and the guard stays usable")
core_vehicles.spawnNewVehicle = gameSpawn
calls = {}
core_vehicles.replaceVehicle("pickup", {}, objs[1])
check(last().who == "game", "works again afterwards")

-- 8. mod loaded AFTER BeamMP joined: the guard stays out of the way
package.loaded["rlsmp/lib/replaceGuard"] = nil
core_vehicles = {replaceVehicle = replaceRequest, spawnNewVehicle = gameSpawn}
originalReplace = gameReplace
local g2 = require("rlsmp/lib/replaceGuard")
g2.install()
check(g2.hasVanilla() == false, "BeamMP's function is never taken as the game's own")
calls = {}
playerId = 1
core_vehicles.replaceVehicle("pickup", {}, objs[1])
check(#calls == 1 and last().who == "game", "falls back to BeamMP's behaviour untouched (no loop)")
print("replace_guard_test: " .. passed .. " checks passed")
