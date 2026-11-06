-- Client anti-teleport police test (LuaJIT). Run: luajit tests/police_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end

local mp, career = true, true
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}

local positions = {[1] = {0, 0, 0}, [10] = {100, 0, 0}, [11] = {900, 0, 0}, [12] = {50, 0, 0}}
be = {
  getPlayerVehicleID = function() return 1 end,
  getObjectPositionXYZ = function(_, id) local p = positions[id] return p[1], p[2], p[3] end,
}
local function cop(id) return {id = id, role = {name = "police"}, enableRespawn = true} end
local traffic = {[1] = {role = {name = "none"}}, [10] = cop(10), [11] = cop(11), [12] = {role = {name = "civilian"}, enableRespawn = true}}
local teleports, roadblocks = 0, 0
gameplay_traffic = {
  getTrafficData = function() return traffic end,
  forceTeleport = function() teleports = teleports + 1 return true end,
}
overhaul_integration_services_police = {setupRoadblock = function() roadblocks = roadblocks + 1 return {vehIds = {}} end}

-- Fake net so we can reach the config handler
local police = require("rlsmp/police")
police.onExtensionLoaded()

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end

-- 1. Outside a pursuit nothing is touched
police.onUpdate(5)
check(traffic[10].enableRespawn == true, "no pursuit -> respawn untouched")

-- 2. Pursuit for another vehicle is ignored
police.onPursuitModeUpdate(99, {mode = 2})
check(not police.isPursuit(), "other vehicle's pursuit ignored")

-- 3. Player chased: near cop frozen, far cop and civilian untouched
police.onPursuitModeUpdate(1, {mode = 2})
check(police.isPursuit(), "pursuit on")
check(traffic[10].enableRespawn == false, "nearby cop cannot respawn")
check(traffic[11].enableRespawn == true, "far cop may despawn")
check(traffic[12].enableRespawn == true, "civilians untouched")

-- 4. Roadblocks and teleports of police are refused, others pass
check(overhaul_integration_services_police.setupRoadblock() == nil and roadblocks == 0, "roadblock refused")
check(gameplay_traffic.forceTeleport(10) == false and teleports == 0, "cop teleport refused")
check(gameplay_traffic.forceTeleport(12) == true and teleports == 1, "civilian teleport allowed")

-- 5. A cop that falls behind the leash is released, one that catches up is frozen
positions[10] = {500, 0, 0}
positions[11] = {100, 0, 0}
police.onUpdate(0.6)
check(traffic[10].enableRespawn == true, "trailing cop released")
check(traffic[11].enableRespawn == false, "cop that caught up is frozen")

-- 6. Pursuit ends: everything restored, wrappers pass through
police.onPursuitModeUpdate(1, {mode = 0})
check(traffic[11].enableRespawn == true and not police.isPursuit(), "respawn restored")
check(overhaul_integration_services_police.setupRoadblock() ~= nil and roadblocks == 1, "roadblocks work again")
check(gameplay_traffic.forceTeleport(10) == true, "cop teleport allowed again")

-- 7. A cop that already had respawn off keeps it off afterwards
traffic[10].enableRespawn = false
positions[10] = {10, 0, 0}
police.onPursuitModeUpdate(1, {mode = 1})
police.onPursuitModeUpdate(1, {mode = 0})
check(traffic[10].enableRespawn == false, "previous setting preserved")
traffic[10].enableRespawn = true

-- 8. Server config switches things off
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = false}))
police.onPursuitModeUpdate(1, {mode = 2})
check(traffic[10].enableRespawn == true, "antiTeleport=false -> nothing frozen")
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "antiTeleport=false -> roadblocks allowed")
police.onPursuitModeUpdate(1, {mode = 0})
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, blockRoadblocks = false, leashMeters = 60}))
check(police.getSettings().leashMeters == 60, "leash from server")
positions[12] = {50, 0, 0}
traffic[12].role.name = "police"
police.onPursuitModeUpdate(1, {mode = 2})
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "blockRoadblocks=false allows roadblocks")
check(traffic[12].enableRespawn == false and traffic[10].enableRespawn == false, "units inside 60 m frozen")
positions[10] = {70, 0, 0}
police.onUpdate(1)
check(traffic[10].enableRespawn == true, "unit outside new leash released")

-- 9. Leaving the server / career restores everything; MP off does nothing
police.onServerLeave()
check(traffic[12].enableRespawn == true and not police.isPursuit(), "leave restores")
mp = false
police.onPursuitModeUpdate(1, {mode = 2})
check(not police.isPursuit(), "not in multiplayer -> ignored")

print(string.format("police_client_test: %d checks passed", passed))
