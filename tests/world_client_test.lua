-- World guard test (LuaJIT). Run: luajit tests/world_client_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local toasts = 0
guihooks = {trigger = function() toasts = toasts + 1 end}
local switched = 0
overhaul_career_garage_switchMap = {
  switchMap = function() switched = switched + 1 return true end,
  resolveTravelBlockers = function() switched = switched + 1 return true end,
}
local sentMsgs = {}
package.loaded["rlsmp/lib/net"] = {send = function(name, d) sentMsgs[#sentMsgs + 1] = {name, d} end}
local w = require("rlsmp/world")
local function check(c, m) if not c then error("FAIL: " .. m, 2) end end
w.install(); w.install()
local sm = overhaul_career_garage_switchMap
check(sm.switchMap("x") == true and switched == 1, "disabled: normal travel")
w.enable(true)
local ok, msg = sm.switchMap("x")
check(ok == false and msg and switched == 1 and toasts == 1, "enabled: travel refused with toast")
local ok2 = sm.resolveTravelBlockers("x")
check(ok2 == false and switched == 1, "enabled: travel with blockers path refused too")
w.enable(false)
check(sm.switchMap("x") == true and switched == 2, "off again: travel works")
-- reloaded module gets wrapped again
overhaul_career_garage_switchMap = {switchMap = function() switched = switched + 10 return true end}
w.install(); w.enable(true)
check(overhaul_career_garage_switchMap.switchMap() == false, "reloaded module wrapped")
-- RLS puts a new function into the SAME table: wrapped again on the next install
local sm2 = overhaul_career_garage_switchMap
local fresh = 0
sm2.switchMap = function() fresh = fresh + 1 return true end
sm2.resolveTravelBlockers = function() fresh = fresh + 1 return true end
w.install()
check(sm2.switchMap() == false and sm2.resolveTravelBlockers() == false and fresh == 0, "replaced functions in the same table are wrapped again")
for _ = 1, 5 do w.install() end
w.enable(false)
check(sm2.switchMap() == true and fresh == 1, "installing every frame does not stack wrappers (original called once)")
check(sm2.resolveTravelBlockers() == true and fresh == 2, "same for resolveTravelBlockers")
-- event results
w.enable(false)
w.onRlsFreeroamRaceResultFinalized({raceName = "a", finishTime = 50})
check(#sentMsgs == 0, "disabled: nothing sent")
w.enable(true)
w.onRlsFreeroamRaceResultFinalized({raceName = "a", finishTime = 50, resultMetrics = {placement = 2}})
check(#sentMsgs == 1 and sentMsgs[1][1] == "rlsmpEventDone" and sentMsgs[1][2].t == 50 and sentMsgs[1][2].place == 2, "timed race sent")
w.onRlsFreeroamRaceResultFinalized({raceName = "a", finishTime = 50, invalidLap = true})
w.onRlsFreeroamRaceResultFinalized({finishTime = 50})
w.onRlsFreeroamRaceResultFinalized({raceName = "d", finishTime = 90, disciplineIds = {"demo"}})
w.onRlsFreeroamRaceResultFinalized({raceName = "b", finishTime = 20, disciplineIds = {"burnout"}})
w.onRlsFreeroamRaceResultFinalized({raceName = "t", disciplineIds = {"tractorPull"}})
check(#sentMsgs == 1, "invalid, incomplete and score-based events are not sent")
print("world_client_test OK")
