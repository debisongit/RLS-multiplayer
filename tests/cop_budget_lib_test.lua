-- Cop budget lib test (LuaJIT): how many cops by area type and time of day, one per area cell. Run: luajit tests/cop_budget_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local B = require("rlsmp/lib/copBudget")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local cfg = B.clean(nil)
check(cfg.maxCops == 3 and cfg.areaSize == 1500, "defaults: at most 3 cops, 1500 m areas")
check(B.target(cfg, "city", false) == 1 and B.target(cfg, "city", true) == 2, "city: 1 by day, 2 at night")
check(B.target(cfg, "highway", false) == 1 and B.target(cfg, "main", true) == 1, "highway and main road: 1")
check(B.target(cfg, nil, false) == 0 and B.target(cfg, nil, true) == 1 and B.target(cfg, "village", false) == 0, "rural / unknown: 0 by day, 1 at night")

-- cells
local cx, cy, key = B.cellOf({x = 1499, y = -1}, 1500)
check(cx == 0 and cy == -1 and key == "0:-1", "cell of a position")
check(select(3, B.cellOf({x = 1500, y = -1}, 1500)) == "1:-1", "the next cell starts at 1500 m")
check(B.cellOf({x = "a", y = 1}, 1500) == nil and B.cellOf(nil, 1500) == nil, "bad positions have no cell")
check(B.cellFree(cfg, {{x = 100, y = 100}}, {x = 1400, y = 1400}) == false, "a cop in the same cell: not free")
check(B.cellFree(cfg, {{x = 100, y = 100}}, {x = 1600, y = 100}) == true, "the next cell is free")

-- canAdd: the count follows area and time, the cell is the second rule
local ok, why = B.canAdd(cfg, {}, "city", false, {x = 0, y = 0}, 3)
check(ok == true, "city by day, no cop out: one")
ok, why = B.canAdd(cfg, {{x = 5000, y = 5000}}, "city", false, {x = 0, y = 0}, 3)
check(ok == false and why:find("1 cops out") and why:find("city by day"), "city by day wants only 1: refused, the reason names area and time (" .. tostring(why) .. ")")
ok = B.canAdd(cfg, {{x = 5000, y = 5000}}, "city", true, {x = 0, y = 0}, 3)
check(ok == true, "city at night wants 2: one more")
ok, why = B.canAdd(cfg, {{x = 5000, y = 5000}}, "city", true, {x = 5100, y = 5100}, 3)
check(ok == false and why:find("already in area 3:3"), "...but not in an area that has a cop (one per area)")
ok = B.canAdd(cfg, {{x = 5000, y = 5000}, {x = 0, y = 0}}, "city", true, {x = -3000, y = 0}, 3)
check(ok == false, "city at night: two out, two wanted: no third")
ok = B.canAdd(cfg, {}, nil, false, {x = 0, y = 0}, 3)
check(ok == false, "rural by day: none asked for")
ok = B.canAdd(cfg, {}, nil, true, {x = 0, y = 0}, 3)
check(ok == true, "rural at night: one")
-- the hard maximum
local big = B.clean({maxCops = 3, copTargets = {city = {day = 6, night = 6}}})
local three = {{x = 0, y = 0}, {x = 3000, y = 0}, {x = 6000, y = 0}}
check(B.canAdd(big, three, "city", true, {x = 9000, y = 0}, 6) == false, "never more than maxCops, whatever the table asks")
check(B.canAdd(big, {{x = 0, y = 0}, {x = 3000, y = 0}}, "city", true, {x = 9000, y = 0}, 6) == true, "...two out, three allowed: one more")
check(B.canAdd(big, {{x = 0, y = 0}}, "city", true, {x = 9000, y = 0}, 1) == false, "copCount (the top-up switch) is a cap as well")
check(B.limit(big, "city", true, nil) == 3, "limit without copCount")
-- no area information: only the caps
check(B.canAdd(cfg, {{x = 0, y = 0}}, false, false, {x = 9000, y = 0}, 3) == true, "no area information: the caps and the cell only")
check(B.canAdd(cfg, three, false, false, {x = 9000, y = 0}, 6) == false, "...and the hard maximum")
check(B.canAdd(cfg, {{x = 10, y = 10}}, false, false, {x = 20, y = 20}, 3) == false, "...and one per cell")
-- cleaning
local c2 = B.clean({maxCops = 99, areaSize = 5, copTargets = {city = {day = "x", night = -4}, highway = "junk"}})
check(c2.maxCops == 6 and c2.areaSize == 100 and c2.targets.city.day == 1 and c2.targets.city.night == 0 and c2.targets.highway.day == 1, "bad values are cleaned")

print(string.format("cop_budget_lib_test: %d checks passed", passed))
