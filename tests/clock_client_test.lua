-- Client shared-clock test (LuaJIT). Run: luajit tests/clock_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
AddEventHandler = function() end
TriggerServerEvent = function() end
local written, slept, setMin, plays = {}, {}, {}, {}
core_environment = {setTimeOfDay = function(v) written[#written + 1] = v.time end}
local rlsEngine = 0.5   -- RLS clock reads midnight
overhaul_world_weather = {
  getClockState = function() return {play = false, time = rlsEngine} end,
  sleepTo = function(t) slept[#slept + 1] = t end,
  setMinuteOfDay = function(m, f) setMin[#setMin + 1] = m end,
  toggleDayNightCycle = function(on) plays[#plays + 1] = on end,
}
local clock = require("rlsmp/clock")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function near(a, b) return math.abs(a - b) < 1e-6 end

clock.onUpdate(1)
check(#written == 0, "nothing before the server speaks")
clock.enable(true)
clock._onTime({m = 720, r = 0.5, dm = 45})
check(near(clock.minuteNow(), 720), "starts at the server minute")
clock.onUpdate(0.25)
check(#written == 1 and math.abs(written[1]) < 1e-3, "noon is engine time 0 (written)")
check(plays[1] == false, "RLS own cycle paused")
for _ = 1, 4 do clock.onUpdate(0.25) end
check(near(clock.minuteNow(), 720 + 1.25 * 0.5), "moves at the rate the server sends")
-- a new server message resets the anchor (no drift)
clock._onTime({m = 800, dm = 45})
check(near(clock.minuteNow(), 800), "server message re-anchors")
-- wrap past midnight
clock._onTime({m = 1439, r = 2, dm = 45})
clock.onUpdate(1)
check(clock.minuteNow() < 5, "wraps over midnight")
-- RLS sync after 10 s: RLS is behind -> sleepTo
syncCount = #slept
for _ = 1, 40 do clock.onUpdate(0.25) end
check(#slept > 0, "RLS weather moved forward with sleepTo")
-- RLS ahead of the server -> setMinuteOfDay
clock._onTime({m = 100, dm = 45})
rlsEngine = (((300 / 1440) + 0.5) % 1)
local before = #setMin
for _ = 1, 41 do clock.onUpdate(0.25) end
check(#setMin > before, "RLS ahead of the server is set back")
-- bad data ignored
clock._onTime({m = "x", dm = 45}) clock._onTime({m = 5, dm = 0}) clock._onTime({m = -4, dm = 45})
check(clock.minuteNow() ~= nil, "bad messages ignored")
clock.enable(false)
check(plays[#plays] == true, "RLS cycle resumes on leave")
local n = #written
clock.onUpdate(1)
check(#written == n, "nothing written while disabled")
print("clock_client_test: " .. passed .. " checks passed")
