-- Traffic menu pure logic test (LuaJIT). Run: luajit tests/traffic_menu_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local L = require("rlsmp/lib/trafficMenu")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local st = L.new()
local snap = {trafficVariety = {typeWeights = {Truck = 0.5}, models = {}}, smartTraffic = {mix = {normal = 70, slow = 30}}}
L.setSnapshot(st, snap)
check(L.get(st, {"trafficVariety", "typeWeights", "Truck"}, 1) == 0.5, "server value shown")
check(L.get(st, {"trafficVariety", "typeWeights", "Bus"}, 1) == 1, "default when not set")
check(L.isSet(st, {"trafficVariety", "typeWeights", "Truck"}) and not L.isSet(st, {"trafficVariety", "typeWeights", "Bus"}), "isSet")

-- edits ------------------------------------------------------------------------------------------------------------
L.set(st, {"trafficVariety", "typeWeights", "Truck"}, 2)
check(L.get(st, {"trafficVariety", "typeWeights", "Truck"}, 1) == 2 and L.dirty(st) == 1, "pending value shown, counted")
L.set(st, {"trafficVariety", "typeWeights", "Truck"}, 0.5)
check(L.dirty(st) == 0, "setting back to the server value drops the change")
L.set(st, {"trafficVariety", "models", "pickup"}, 3)
check(L.isSet(st, {"trafficVariety", "models", "pickup"}), "a pending new weight counts as set")
L.remove(st, {"trafficVariety", "models", "pickup"})
check(L.dirty(st) == 0 and not L.isSet(st, {"trafficVariety", "models", "pickup"}), "removing a never-saved weight leaves nothing to send")
L.remove(st, {"trafficVariety", "typeWeights", "Truck"})
check(L.dirty(st) == 1 and L.get(st, {"trafficVariety", "typeWeights", "Truck"}, 1) == 1 and not L.isSet(st, {"trafficVariety", "typeWeights", "Truck"}), "removal of a server weight shown as default")
L.set(st, {"trafficVariety", "typeWeights", "Truck"}, 0.5)
check(L.dirty(st) == 0, "setting after a removal cancels the removal")
L.remove(st, {"trafficVariety", "typeWeights", "Truck"})

-- patch ------------------------------------------------------------------------------------------------------------
L.set(st, {"smartTraffic", "mix", "slow"}, 10)
L.set(st, {"smartTraffic", "mix", "normal"}, 90)
local p = L.patch(st)
check(#p.set == 2 and #p.rm == 1, "patch has 2 sets and 1 removal")
check(table.concat(p.set[1].p, ".") == "smartTraffic.mix.normal" and p.set[1].v == 90, "sets in a steady order")
check(table.concat(p.rm[1], ".") == "trafficVariety.typeWeights.Truck", "removal path")
L.revert(st)
check(L.dirty(st) == 0, "revert clears everything")

-- apply result ----------------------------------------------------------------------------------------------------
L.set(st, {"smartTraffic", "mix", "slow"}, 10)
L.set(st, {"smartTraffic", "mix", "normal"}, 90)
local kept = L.applyResult(st, {applied = 1, rejected = {{p = {"smartTraffic", "mix", "slow"}, why = "too big"}}, saved = true})
check(kept == 1 and L.dirty(st) == 1 and st.statusBad and st.status:find("too big", 1, true), "applied leave, rejected stay and are reported")
L.revert(st)
L.set(st, {"smartTraffic", "mix", "slow"}, 10)
L.applyResult(st, {applied = 1, rejected = {}, saved = false})
check(st.statusBad and st.status:find("NOT saved", 1, true), "a failed save is reported")
L.set(st, {"smartTraffic", "mix", "slow"}, 11)
L.applyResult(st, {applied = 1, rejected = {}, saved = true})
check(not st.statusBad and st.status:find("1 setting applied", 1, true) and L.dirty(st) == 0, "success message")
L.applyResult(st, "garbage")
check(true, "garbage result does not crash")

-- a fresh snapshot drops changes it already contains
L.set(st, {"smartTraffic", "mix", "slow"}, 50)
L.setSnapshot(st, {smartTraffic = {mix = {slow = 50}}})
check(L.dirty(st) == 0, "pending equal to the new server value is dropped")

-- shares
st = L.new()
L.setSnapshot(st, snap)
local sh = L.shares(st)
check(math.abs(sh.normal - 70) < 1e-9 and math.abs(sh.slow - 30) < 1e-9 and sh.racer == 0, "shares in percent")
L.set(st, {"smartTraffic", "mix", "normal"}, 0)
L.set(st, {"smartTraffic", "mix", "slow"}, 0)
check(L.shares(st).normal == 0, "all zero: no division by zero")

-- the game's cars
local list = {models = {
  etk800 = {Type = "Car", Brand = "ETK", Name = "800 Series"},
  pickup = {Type = "Truck", Brand = "Gavril", Name = "D-Series"},
  roamer = {Type = "Truck", Brand = "Gavril", Name = "Roamer"},
  barrels = {Type = "Prop", Name = "Barrels"},
  boxutility_trailer = {Type = "Trailer", Name = "Trailer"},
  ["bad;name"] = {Type = "Car", Name = "x"},
  badtype = {Type = "Bad;Type", Name = "y"},
}}
local ty = L.types(list)
check(#ty == 2 and ty[1].type == "Car" and ty[1].count == 2 and ty[2].type == "Truck" and ty[2].count == 2, "types: props, trailers and bad Type names left out, counted, sorted")
local ms = L.models(list, "", 10)
local keys = {}
for _, m in ipairs(ms) do keys[#keys + 1] = m.key end
check(table.concat(keys, ",") == "etk800,badtype,pickup,roamer" or table.concat(keys, ",") == "etk800,pickup,roamer,badtype", "models: usable cars only (" .. table.concat(keys, ",") .. ")")
check(#L.models(list, "GAVRIL", 10) == 2, "filter on brand, not case sensitive")
check(#L.models(list, "pick", 10) == 1 and L.models(list, "pick", 10)[1].label == "Gavril D-Series", "filter on key, label has brand")
check(#L.models(list, "", 2) == 2, "limit")
check(#L.types(nil) == 0 and #L.models(nil, "", 5) == 0, "no list, no crash")
check(not L.goodName("a;b") and not L.goodName("") and not L.goodName(string.rep("n", 65)) and L.goodName("my car-1"), "goodName")

-- where map
st = L.new()
check(table.concat(L.whereMap(st), ".") == "trafficVariety.zones.city", "default: city roads")
st.zone = "highway"
check(table.concat(L.whereMap(st), ".") == "trafficVariety.zones.highway", "highway")
st.time = "night"
check(table.concat(L.whereMap(st), ".") == "trafficVariety.night", "night wins over the road class")
local base = {"a"}
local c = L.child(base, "b")
check(#base == 1 and #c == 2, "child copies the path")

-- names under a section (theft methods, market items)
st = L.new()
check(#L.names(st, "theft", "methods") == 0, "names: no snapshot, no names")
L.setSnapshot(st, {theft = {methods = {signal_cloner = {}, window_screwdriver = {}, key_programmer = {}}}, market = {tiers = "x"}})
local nm = L.names(st, "theft", "methods")
check(#nm == 3 and nm[1] == "key_programmer" and nm[3] == "window_screwdriver", "names: sorted")
check(#L.names(st, "market", "tiers") == 0 and #L.names(st, "fence", "rep") == 0, "names: not a table or missing section is empty")
local ids = {}
for _, sec in ipairs(L.SECTIONS) do ids[sec.id] = true end
check(ids.theft and ids.fence and ids.market and #L.SECTIONS == 10, "the menu has the theft, fence and market sections")

print(string.format("traffic_menu_lib_test: %d checks passed", passed))
