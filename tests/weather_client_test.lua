-- Shared weather extension test (LuaJIT). Run: luajit tests/weather_client_test.lua
-- Fakes RLS's overhaul_world_weather with the behaviour read from its source (forceCondition("clear") moves RLS's clock to 12:00).
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
local function count(fragment) local k = 0 for _, l in ipairs(logged) do if l:find(fragment, 1, true) then k = k + 1 end end return k end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
function setExtensionUnloadMode() end

local VALID = {clear = true, partlyCloudy = true, overcast = true, drizzle = true, rain = true, storm = true}
local rls = {condition = "clear", minute = 300, ready = true, override = false, refuse = false, effective = {}, forced = {}, minuteSets = {}}
overhaul_world_weather = {
  getUiState = function() if not rls.ready then return {ready = false} end return {ready = true, condition = rls.condition} end,
  forceCondition = function(c)
    rls.forced[#rls.forced + 1] = c
    if rls.override or rls.refuse or not VALID[c] then return false end
    rls.condition = rls.effective[c] or c          -- RLS may show something else (for example drizzle not allowed)
    if c == "clear" then rls.minute = 720 end      -- RLS's own behaviour: clear moves its clock to noon
    return true
  end,
  setMinuteOfDay = function(m, freeze) rls.minuteSets[#rls.minuteSets + 1] = m rls.minute = m return true end,
  isExternalOverrideActive = function() return rls.override end,
}
package.loaded["rlsmp/clock"] = {minuteNow = function() return 1000 end}
local mp, career = true, true
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}

local T = require("rlsmp/weather")
T.onExtensionLoaded()

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(tbl) handlers["rlsmpWeather"](json.encode(tbl)) end
local function run(seconds) for _ = 1, seconds do T.onUpdate(1) end end

-- 1. nothing before the server speaks ----------------------------------------------------------------------------------------
run(10)
check(#rls.forced == 0, "no message yet: RLS is left alone")

-- 2. the server's weather is forced once ---------------------------------------------------------------------------------------
server({c = "rain", p = 12, n = 600})
check(saw("weather from the server: rain (period 12, 600 s left)"), "message logged")
run(3)
check(#rls.forced == 1 and rls.forced[1] == "rain" and rls.condition == "rain", "forced rain")
check(saw("weather: forced rain (RLS showed clear, now shows rain)"), "decision logged")
run(60)
check(#rls.forced == 1, "RLS still shows rain: not forced again, however often we check")
server({c = "rain", p = 12, n = 540})
run(20)
check(#rls.forced == 1, "the same message again changes nothing")

-- 3. RLS moves on by itself (next forecast segment): corrected -------------------------------------------------------------------
rls.condition = "overcast"
run(3)
check(#rls.forced == 2 and rls.condition == "rain", "RLS changed its mind: forced rain again")
run(30)
check(#rls.forced == 2, "...and then stable")

-- 4. a new condition from the server; clear must not leave RLS's clock at noon ------------------------------------------------------
server({c = "clear", p = 13, n = 900})
run(6)
check(rls.forced[#rls.forced] == "clear" and rls.condition == "clear", "server says clear: forced")
check(#rls.minuteSets == 1 and rls.minuteSets[1] == 1000 and rls.minute == 1000, "RLS's clock jumped to noon; it was put back to the server's minute 1000")
server({c = "storm", p = 14, n = 900})
run(6)
check(rls.forced[#rls.forced] == "storm" and #rls.minuteSets == 1, "other conditions do not touch the clock")

-- 5. RLS shows something else than asked (drizzle not allowed): no endless forcing ---------------------------------------------------------
rls.effective = {drizzle = "overcast"}
server({c = "drizzle", p = 15, n = 900})
run(6)
local forcedBefore = #rls.forced
check(rls.forced[forcedBefore] == "drizzle" and rls.condition == "overcast", "drizzle forced, RLS shows overcast")
run(120)
check(#rls.forced == forcedBefore, "what RLS shows after our force is accepted: no loop")
rls.effective = {}

-- 6. bad messages are ignored ------------------------------------------------------------------------------------------------------------
local n = #rls.forced
for _, bad in ipairs({{c = "hail"}, {c = 7}, {}, {c = "Rain"}}) do server(bad) end
handlers["rlsmpWeather"]("[1,2]")
run(10)
check(#rls.forced == n and T.getTarget() == "drizzle", "unknown or malformed conditions are ignored, the last good one stays")

-- 7. RLS not ready yet -----------------------------------------------------------------------------------------------------------------------
T.onServerLeave()
rls.condition, rls.forced, rls.ready = "clear", {}, false
server({c = "rain"})
run(10)
check(#rls.forced == 0, "RLS weather not ready: waiting")
rls.ready = true
run(3)
check(#rls.forced == 1 and rls.condition == "rain", "ready: forced")

-- 8. another weather mod has priority ------------------------------------------------------------------------------------------------------------
T.onServerLeave() rls.forced, rls.condition = {}, "clear"
rls.override = true
server({c = "storm"})
run(20)
check(#rls.forced == 0 and saw("another weather mod has priority"), "external override: nothing, said once")
check(count("another weather mod has priority") == 1, "...only once")
rls.override = false

-- 9. RLS refuses: back off, then try again ----------------------------------------------------------------------------------------------------------
T.onServerLeave() rls.forced, rls.condition, rls.refuse = {}, "clear", true
logged = {}
server({c = "storm"})
run(3)
check(#rls.forced == 1 and saw("weather: forceCondition(storm) failed"), "refused: logged")
run(20)
check(#rls.forced == 1, "backing off for 30 s")
rls.refuse = false
run(15)
check(#rls.forced == 2 and rls.condition == "storm", "after the back-off it works")

-- 10. not in multiplayer / no career / no RLS weather -------------------------------------------------------------------------------------------------
T.onServerLeave() rls.forced, rls.condition = {}, "clear"
server({c = "rain"})
mp = false
run(10)
check(#rls.forced == 0, "single player: nothing")
mp, career = true, false
run(10)
check(#rls.forced == 0, "career not active: nothing")
career = true
local saved = overhaul_world_weather
overhaul_world_weather = nil
run(10)
check(#rls.forced == 0 and saw("RLS's weather module is not available"), "no RLS weather module: said, nothing forced")
overhaul_world_weather = saved
run(10)
check(#rls.forced == 1, "and it works as soon as RLS weather exists")

-- 11. clear without the clock extension: no error, no minute change -----------------------------------------------------------------------------------
T.onServerLeave() rls.forced, rls.minuteSets, rls.condition = {}, {}, "rain"
package.loaded["rlsmp/clock"] = nil
server({c = "clear"})
run(6)
check(rls.condition == "clear" and #rls.minuteSets == 0, "no clock extension: clear is forced, the clock is left alone")
package.loaded["rlsmp/clock"] = {minuteNow = function() return 1000 end}

-- 12. leaving the server forgets everything ---------------------------------------------------------------------------------------------------------------
T.onServerLeave()
check(T.getTarget() == nil, "settings forgotten on leaving")
rls.forced, rls.condition = {}, "rain"
run(20)
check(#rls.forced == 0, "after leaving: RLS is left alone")

print(string.format("weather_client_test: %d checks passed", passed))
