-- Parked car amount test (LuaJIT). Run: luajit tests/parked_client_test.lua
-- Fakes the game setting, RLS's parking service and RLS's playerDriving.onSettingsChanged.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end

local V = require("rlsmp/lib/trafficVariety")
local Pk = require("rlsmp/lib/parked")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- lib -----------------------------------------------------------------------------------------------------------------------------
local plan = Pk.plan
check(plan({wanted = 10, current = 2}) == "set", "too low: set")
check(plan({wanted = 10, current = 0}) == "set", "automatic (0): set")
check(plan({wanted = 10, current = 15}) == "idle", "the player already wants more: leave it")
check(plan({wanted = 0, current = 2}) == "idle", "0 = leave the game alone")
check(plan({wanted = 10, current = 2, noParked = true}) == "skip", "parked cars switched off: skip")
check(plan({wanted = 10, current = 10, applied = 10, have = 4}) == "sync", "set but too few cars: top up")
check(plan({wanted = 10, current = 10, applied = 10, have = 10}) == "done", "enough cars")
check(plan({wanted = 10, current = 10, applied = 10, have = 4, tries = 12}) == "giveup", "too many tries")
check(plan({wanted = 10, current = 3, applied = 10, have = 4}) == "forget", "somebody changed the setting: forget")
check(plan({wanted = 12, current = 10, applied = 10, have = 10}) == "set", "the server asks for more: set again")
check(plan({wanted = 0, current = 10, applied = 10}) == "restore", "server no longer wants it: restore")

-- the game ------------------------------------------------------------------------------------------------------------------------
local values, writes = {trafficParkingAmount = 2, trafficParkedVehicles = true}, {}
settings = {
  getValue = function(k) return values[k] end,
  setValue = function(k, v) writes[#writes + 1] = {k, v} values[k] = v end,
}
local parked, syncCalls, notifyCalls, pending = 2, 0, 0, false
overhaul_integration_services_parking = {
  getParkedCarsAmount = function() return parked end,
  syncParkedCount = function() syncCalls = syncCalls + 1 if pending then return false end parked = values.trafficParkingAmount return true end,
}
overhaul_career_police_playerDriving = {onSettingsChanged = function() notifyCalls = notifyCalls + 1 end}
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return true end}
local config
package.loaded["rlsmp/trafficVariety"] = {getConfig = function() return config end}

local T = require("rlsmp/parked")
local function setConfig(amount) config = V.sanitize({parked = {amount = amount}}) end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5) do T.onUpdate(0.5) end end
local function reset()
  values.trafficParkingAmount, values.trafficParkedVehicles = 2, true
  writes, parked, syncCalls, notifyCalls, pending, logged = {}, 2, 0, 0, false, {}
  T.onServerLeave()
end

-- 1. nothing until the server's settings are here ------------------------------------------------------------------------------------
config = nil
run(10)
check(#writes == 0, "no settings yet: nothing written")

-- 2. the normal case: 2 -> 10, RLS is told, the cars appear -----------------------------------------------------------------------------
reset() setConfig(10)
run(2)
check(#writes == 1 and writes[1][1] == "trafficParkingAmount" and writes[1][2] == 10, "the game setting is raised to 10")
check(notifyCalls >= 1 and syncCalls >= 1, "RLS's own onSettingsChanged and syncParkedCount were called")
check(saw("parked: setting trafficParkingAmount 2 -> 10"), "the change is logged with the old value")
run(10)
check(parked == 10 and saw("parked: 10 parked cars now (wanted 10)"), "the cars were topped up and it says so")
local syncAtDone = syncCalls
run(20)
check(syncCalls == syncAtDone and #writes == 1, "enough cars: nothing more is asked")

-- 3. a spawn is still running: the top-up is retried, spaced out, and gives up ---------------------------------------------------------------------
reset() setConfig(10) pending = true
run(2)
check(#writes == 1, "set once")
run(90)
check(parked == 2 and syncCalls <= 1 + Pk.MAX_TRIES + 1, "retries are bounded (" .. syncCalls .. " calls)")
check(saw("giving up"), "it gives up with a log line")
pending = false

-- 4. leaving the server puts the player's value back ---------------------------------------------------------------------------------------------
reset() setConfig(10)
run(2)
T.onServerLeave()
check(values.trafficParkingAmount == 2 and saw("left the server, trafficParkingAmount back to 2"), "the old value is restored when leaving")

-- 5. a higher value of the player is never lowered ---------------------------------------------------------------------------------------------------
reset() setConfig(10) values.trafficParkingAmount = 15
run(4)
check(#writes == 0 and saw("already 15"), "the player's own 15 stays")

-- 6. 0 = off ---------------------------------------------------------------------------------------------------------------------------------------------------
reset() setConfig(0)
run(4)
check(#writes == 0, "amount 0: the game's own amount is left alone")
-- the server turns it off after we applied it
reset() setConfig(10) run(2)
setConfig(0) run(2)
check(values.trafficParkingAmount == 2 and saw("back to 2"), "server sets 0 later: the old value comes back")

-- 7. player switched parked cars off ------------------------------------------------------------------------------------------------------------------------
reset() setConfig(10) values.trafficParkedVehicles = false
run(4)
check(#writes == 0 and saw("switched off in the game settings"), "parked cars off in the settings: nothing")
values.trafficParkedVehicles = true
overhaul_shell_settings = {getSetting = function(k) return k == "noParkedMode" end}
reset() setConfig(10)
run(4)
check(#writes == 0, "RLS's noParkedMode: nothing")
overhaul_shell_settings = nil

-- 8. somebody else changes the setting after us: not fought -------------------------------------------------------------------------------------------------
reset() setConfig(10) run(2)
values.trafficParkingAmount = 4
run(4)
check(#writes == 1 and saw("no longer managed"), "changed by someone else: left alone")
T.onServerLeave()
check(values.trafficParkingAmount == 4, "...and not overwritten when leaving")

-- 9. the server asks for more later ---------------------------------------------------------------------------------------------------------------------------------
reset() setConfig(10) run(6)
setConfig(14) run(2)
check(values.trafficParkingAmount == 14, "a new amount from the server is applied")
T.onServerLeave()
check(values.trafficParkingAmount == 2, "...and the ORIGINAL value (2) is what comes back, not 10")

-- 10. outside a session / career ---------------------------------------------------------------------------------------------------------------------------------------
reset() setConfig(10)
MPCoreNetwork = {isMPSession = function() return false end}
run(6)
check(#writes == 0, "single player: nothing")
MPCoreNetwork = {isMPSession = function() return true end}
overhaul_career_career = {isActive = function() return false end}
run(6)
check(#writes == 0, "no career yet: nothing")
overhaul_career_career = {isActive = function() return true end}

-- 11. the game gives errors: nothing breaks ------------------------------------------------------------------------------------------------------------------------------
reset() setConfig(10)
settings.setValue = function() error("no") end
run(6)
check(#writes == 0, "a failing setValue is survived")
settings.setValue = function(k, v) writes[#writes + 1] = {k, v} values[k] = v end
overhaul_career_police_playerDriving = {onSettingsChanged = function() error("boom") end}
overhaul_integration_services_parking.syncParkedCount = function() error("boom") end
reset() setConfig(10)
run(6)
check(values.trafficParkingAmount == 10 and saw("onSettingsChanged failed"), "RLS functions that fail are logged, not fatal")

print(string.format("parked_client_test: %d checks passed", passed))
