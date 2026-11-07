-- World guard test (LuaJIT). Run: luajit tests/world_client_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local toasts = 0
guihooks = {trigger = function() toasts = toasts + 1 end}
local switched = 0
overhaul_career_garage_switchMap = {
  switchMap = function() switched = switched + 1 return true end,
  getTravelBlockers = function() return nil end,
}
local sentMsgs = {}
package.loaded["rlsmp/lib/net"] = {send = function(name, d) sentMsgs[#sentMsgs + 1] = {name, d} end}
local w = require("rlsmp/world")
local function check(c, m) if not c then error("FAIL: " .. m, 2) end end
w.install(); w.install()
local sm = overhaul_career_garage_switchMap
check(sm.switchMap("x") == true and switched == 1, "disabled: normal travel")
check(sm.getTravelBlockers() == nil, "disabled: no blockers")
w.enable(true)
local ok, msg = sm.switchMap("x")
check(ok == false and msg and switched == 1 and toasts == 1, "enabled: travel refused with toast")
check(type(sm.getTravelBlockers()) == "table", "enabled: blocker reported")
w.enable(false)
check(sm.switchMap("x") == true and switched == 2, "off again: travel works")
-- reloaded module gets wrapped again
overhaul_career_garage_switchMap = {switchMap = function() switched = switched + 10 return true end}
w.install(); w.enable(true)
check(overhaul_career_garage_switchMap.switchMap() == false, "reloaded module wrapped")
-- event results
local done = 0
overhaul_events_fre_race = {onFreeroamRaceCompleted = function() done = done + 1 return "r" end}
w.onUpdate(); w.onUpdate()
local fre = overhaul_events_fre_race
w.enable(false)
fre.onFreeroamRaceCompleted({raceName = "a", finishTime = 50})
check(#sentMsgs == 0 and done == 1, "disabled: nothing sent, original still runs")
w.enable(true)
check(fre.onFreeroamRaceCompleted({raceName = "a", finishTime = 50, resultMetrics = {placement = 2}}) == "r", "original result passed through")
check(#sentMsgs == 1 and sentMsgs[1][1] == "rlsmpEventDone" and sentMsgs[1][2].t == 50 and sentMsgs[1][2].place == 2, "result sent once")
fre.onFreeroamRaceCompleted({raceName = "a", finishTime = 50, invalidLap = true})
fre.onFreeroamRaceCompleted({finishTime = 50})
check(#sentMsgs == 1 and done == 4, "invalid or incomplete results are not sent")
print("world_client_test OK")
