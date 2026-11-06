-- Client anti-teleport police test (LuaJIT). Run: luajit tests/police_client_test.lua
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

local mp, career, playerId = true, true, 1
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
be = {getPlayerVehicleID = function() return playerId end}

local function cop(id) return {id = id, role = {name = "police"}, enableRespawn = true, respawnCount = 0} end
local traffic = {
  [1] = {role = {name = "none"}, pursuit = {mode = 0}},
  [2] = {role = {name = "none"}, pursuit = {mode = 0}}, -- a second car the player may switch to
  [10] = cop(10), [11] = cop(11), -- 11 will be far away: still frozen
  [12] = {role = {name = "civilian"}, enableRespawn = true, pursuit = {mode = 0}},
}
local teleports, roadblocks = 0, 0
gameplay_traffic = {
  getTrafficData = function() return traffic end,
  forceTeleport = function() teleports = teleports + 1 return true end,
}
overhaul_integration_services_police = {setupRoadblock = function() roadblocks = roadblocks + 1 return {vehIds = {}} end}

local police = require("rlsmp/police")
police.onExtensionLoaded()

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end
local function tick() police.onUpdate(1) end

check(saw("RLSMP-P3|probe: RLS police service present = true"), "boot probes use the RLSMP-P3 tag")
check(saw("RLSMP-P3|rlsmp_police loaded"), "loaded line")

-- 1. No pursuit: nothing touched
tick()
check(traffic[10].enableRespawn == true and not police.isPursuit(), "no pursuit -> respawn untouched")

-- 2. Player chased (found by polling, the hook is only a fast start)
traffic[1].pursuit.mode = 2
tick()
check(police.isPursuit(), "pursuit detected from traffic data")
check(traffic[10].enableRespawn == false and traffic[11].enableRespawn == false, "every police unit frozen, near or far")
check(traffic[12].enableRespawn == true, "civilians untouched")

check(saw("RLSMP-P3|probe: player vehicle in traffic data = true"), "probe: player in traffic data")
check(saw("RLSMP-P3|pursuit START mode=2 antiTeleport=true blockRoadblocks=true"), "pursuit START line")
check(saw("RLSMP-P3|patched setupRoadblock = true") and saw("RLSMP-P3|patched forceTeleport = true"), "patched lines")
check(saw("RLSMP-P3|FROZE police id=10 respawnCount=0 was enableRespawn=true"), "FROZE line")

-- 3. Roadblocks and police teleports refused, others pass
check(overhaul_integration_services_police.setupRoadblock() == nil and roadblocks == 0, "roadblock refused")
check(saw("RLSMP-P3|BLOCKED setupRoadblock from tests/police_client_test.lua:"), "BLOCKED line names the caller")
check(gameplay_traffic.forceTeleport(10) == false and teleports == 0, "cop teleport refused")
check(gameplay_traffic.forceTeleport(12) == true and teleports == 1, "civilian teleport allowed")

-- 4. A new police unit appearing mid-chase is frozen too
traffic[13] = cop(13)
tick()
check(traffic[13].enableRespawn == false, "late police unit frozen")

-- 5. Respawn watch notices a unit that was re-placed anyway
traffic[10].respawnCount = 1
tick()
check(police.getLeaks() == 1, "re-placed unit counted")
check(saw("RLSMP-P3|LEAK police id=10"), "LEAK line")
tick()
check(police.getLeaks() == 1, "counted once")

-- 6. RLS resets pursuit.mode directly and never calls the hook with 0 -> still released
traffic[1].pursuit.mode = 0
tick()
check(not police.isPursuit(), "pursuit end seen through traffic data")
check(saw("RLSMP-P3|pursuit END after"), "pursuit END line")
check(saw("RLSMP-P3|RELEASED police id=10"), "RELEASED line")
check(traffic[10].enableRespawn == true and traffic[11].enableRespawn == true and traffic[13].enableRespawn == true, "respawn restored")
check(overhaul_integration_services_police.setupRoadblock() ~= nil and roadblocks == 1, "roadblocks work again")
check(gameplay_traffic.forceTeleport(10) == true, "cop teleport allowed again")

-- 7. Player switches vehicle mid-chase: the new player vehicle is chased, state follows
traffic[1].pursuit.mode = 1
police.onPursuitModeUpdate(1, {mode = 1}) -- hook gives a fast start
check(police.isPursuit() and traffic[10].enableRespawn == false, "hook starts at once")
playerId = 2
traffic[1].pursuit.mode = 0
tick()
check(not police.isPursuit() and traffic[10].enableRespawn == true, "switching away from the chased car ends it")
traffic[2].pursuit.mode = 3
tick()
check(police.isPursuit() and traffic[10].enableRespawn == false, "new player vehicle chased -> frozen again")
traffic[2].pursuit.mode = 0
tick()
playerId = 1

-- 8. A unit that already had respawn off keeps it off afterwards
traffic[10].enableRespawn = false
traffic[1].pursuit.mode = 1
tick()
traffic[1].pursuit.mode = 0
tick()
check(traffic[10].enableRespawn == false, "previous setting preserved")
traffic[10].enableRespawn = true

-- 9. Server config
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = false}))
traffic[1].pursuit.mode = 2
tick()
check(traffic[10].enableRespawn == true, "antiTeleport=false -> nothing frozen")
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "antiTeleport=false -> roadblocks allowed")
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, blockRoadblocks = false}))
tick()
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "blockRoadblocks=false allows roadblocks")
check(traffic[10].enableRespawn == false, "police frozen again")

-- 10. Leaving the server restores everything; outside multiplayer nothing happens
police.onServerLeave()
check(traffic[10].enableRespawn == true and not police.isPursuit(), "leave restores")
mp = false
tick()
check(not police.isPursuit() and traffic[10].enableRespawn == true, "not in multiplayer -> ignored")
mp = true
career = false
police.onOverhaulActive(false)
tick()
check(not police.isPursuit(), "career inactive -> ignored")

-- 11. Census
local report = police.report()
check(report:find("census begin", 1, true) and report:find("setupRoadblock BLOCKED", 1, true), "census lists blocked roadblocks")
check(report:find("setupRoadblock BLOCKED callers", 1, true) and report:find("police_client_test.lua:", 1, true), "census lists callers")
check(report:find("pursuits started", 1, true) and report:find("units frozen", 1, true), "census lists pursuits and freezes")

-- 12. Player car missing from traffic data: the RLS hook is the fallback
mp, career = true, true
traffic[1] = nil
logged = {}
police.onPursuitModeUpdate(1, {mode = 2})
check(police.isPursuit() and traffic[10].enableRespawn == false, "hook fallback starts the pursuit")
check(saw("RLSMP-P3|probe: player vehicle in traffic data = false"), "probe says the player is not in traffic data")
tick()
check(police.isPursuit(), "fallback keeps the pursuit on")
police.onPursuitModeUpdate(1, {mode = 0})
check(not police.isPursuit() and traffic[10].enableRespawn == true, "hook ends it")

print(string.format("police_client_test: %d checks passed", passed))
