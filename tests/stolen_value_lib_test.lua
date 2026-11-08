-- Stolen car value (LuaJIT). Run: luajit tests/stolen_value_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local SV = require("rlsmp/lib/stolenValue")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(SV.strip("sedan_pre_s_parked") == "sedan_pre_s" and SV.strip("a_parked_parked") == "a" and SV.strip("_parked") == nil and SV.strip(5) == nil, "strip")

local list = {
  {key = "sedan_pre_s", Value = 30000, Years = {min = 2005, max = 2010}},
  {key = "sedan_pre_h", Value = 50000, Years = {min = 2005, max = 2010}},
  {key = "sedan_pre_h_awd", Value = 52000},
  {key = "police", Value = 90000, ["Config Type"] = "Police"},
  {key = "taxi", Value = 20000},
  {key = "bare", Value = 1000},
}
local e, how = SV.match(list, {"sedan_pre_s_parked"})
check(e.key == "sedan_pre_s" and how == "exact", "exact after stripping _parked")
e, how = SV.match(list, {"x", "sedan_pre_h_awd_xl_parked"})
check(e.key == "sedan_pre_h_awd" and how == "prefix", "longest prefix wins")
check(SV.match(list, {"zzz_parked"}) == nil and SV.match(list, {"bar"}) == nil, "short or unrelated names do not match")
check(SV.typical(list).key == "sedan_pre_s", "typical: median, police and taxi skipped (30000, 50000, 52000, 1000 -> second)")
check(SV.typical({}) == nil and SV.typical({{key = "a"}}) == nil, "typical: nothing")

local seen
local ctx = {year = 2026, valuation = function(o) seen = o return {bookValue = 21400} end}
local r = SV.resolve("bastion", {"sedan_pre_s_parked"}, list, ctx)
check(r.value == 21400 and r.source == "rls valuation" and r.matched == "exact" and r.year == 2005, "real config, RLS valuation")
check(seen.age == 19 and seen.mileageMeters == 228000 * 1000 and seen.modelName == "bastion" and seen.configKey == "sedan_pre_s", "age from Years midpoint, 12000 km a year")
r = SV.resolve("bastion", {"weird_parked"}, list, ctx)
check(r.matched == "typical" and r.value == 21400 and r.source:find("typical"), "unknown config: typical config")

-- fallbacks, in order
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {year = 2026, valuation = function() return nil end, quick = function(b) return b * 0.5 end})
check(r.value == 15000 and r.source == "rls quick value", "quick value when the valuation is missing")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {year = 2026, valuation = function() error("boom") end, quick = function() return 0 end,
  estimate = function() return 12345.6 end})
check(r.value == 12346 and r.source == "spec estimate", "errors and zeros fall through to the estimate")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {})
check(r.value == 30000 and r.source == "catalog value", "no calculator: catalog value")
r = SV.resolve("bastion", {"x_parked"}, {}, {valuation = function() return {bookValue = 5} end})
check(r.value == 0 and r.source == "none" and r.age == SV.DEFAULT_AGE, "nothing known: 0 (server uses minValue), default age")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {valuation = function() return {bookValue = 1e12} end})
check(r.value == SV.MAX_VALUE, "client sanity cap")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {valuation = function() return {bookValue = 0 / 0} end})
check(r.value == 30000 or r.value > 0, "nan valuation ignored")

-- RLS market index: asked of the valuation itself, applied by us on the other paths
local mo
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {year = 2026, market = 1.2, valuation = function(o) mo = o return {bookValue = 20000} end})
check(mo.applyVehicleBuyMarket == true and r.value == 20000 and r.market == 1.2, "valuation gets the market flag and applies it itself")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {year = 2026, market = 0.8, valuation = function() return nil end, quick = function(b) return b * 0.5 end})
check(r.value == 12000, "quick value is multiplied by the market index")
r = SV.resolve("bastion", {"sedan_pre_s"}, list, {year = 2026, valuation = function(o) mo = o return {bookValue = 20000} end})
check(mo.applyVehicleBuyMarket == false, "no market index: not applied")

-- spec for the estimator
local spec = SV.specOf({Power = 300, Weight = 1500, ["Top Speed"] = 60, Drivetrain = "RWD", Years = {min = 2010, max = 2014}, Name = "x", aggregates = {Type = {Car = true}}})
check(spec.hp == 300 and spec.weight == 1500 and spec.year == 2010 and spec.drivetrain == "RWD" and spec.words:find("Car"), "specOf")
print("stolen_value_lib_test: " .. passed .. " checks passed")
