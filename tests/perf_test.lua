-- Frame-time counters (LuaJIT). Run: luajit tests/perf_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local P = require("rlsmp/lib/perf")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local clock, wall = 0, 1000
P.setClocks(function() return clock end, function() return wall end)
local calls = 0
local A = {onUpdate = function(dt) clock = clock + 0.002 calls = calls + 1 return "r1", "r2" end}
local B = {onUpdate = function(dt) clock = clock + 0.0005 end}
check(P.wrap("parked", A) == true and P.wrap("trafficFill", B) == true, "wrapped")
check(P.wrap("parked", A) == false, "never wrapped twice")
local a, b = A.onUpdate(0.016)
check(a == "r1" and b == "r2" and calls == 1, "the wrapper passes arguments and results through")
check(P.wrap("none", {}) == false and P.wrap("x", nil) == false, "nothing to wrap: ignored")

for _ = 1, 99 do A.onUpdate(0.016) B.onUpdate(0.016) end
be = {getObjectCount = function() return 42 end}
local text = P.report()
check(text and text:find("ours 2.50 ms/frame over 100 frames", 1, true), "total per frame and frames: " .. tostring(text))
check(text:find("cars in the game 42", 1, true), "the car count is in the line")
check(text:find("parked 2.00 (max 2.0)", 1, true) and text:find("trafficFill 0.50", 1, true), "per module numbers, busiest first")
check(text:find("parked") < text:find("trafficFill"), "sorted by time used")
check(P.report() == nil, "the window is cleared")

-- once a minute on its own
A.onUpdate(0.016)                       -- starts the timer
local n0 = #logged
wall = wall + 59
A.onUpdate(0.016)
check(#logged == n0, "no line before a minute")
wall = wall + 1
A.onUpdate(0.016)
check(#logged == n0 + 1 and logged[#logged]:find("perf: ours", 1, true), "one line after a minute")

-- a game that reloads the module: the new function is wrapped, the old marker does not block it
local C = {onUpdate = function() end}
P.wrap("c", C)
local first = C.onUpdate
C.onUpdate = function() end
check(P.wrap("c", C) == true and C.onUpdate ~= first, "a replaced onUpdate is wrapped again")
print("perf_test: " .. passed .. " checks passed")
