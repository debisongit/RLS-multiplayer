-- Simplified (stand-in) cars: pure logic (LuaJIT). Run: luajit tests/simplified_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local L = require("rlsmp/lib/simplified")
local V = require("rlsmp/lib/trafficVariety")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- settings ------------------------------------------------------------------------------------------------------------
local d = L.sanitize(nil)
check(d.enabled == false and d.traffic == false and d.parked == true and d.nearRadius == 250 and d.perMinute == 4, "defaults: off")
local s = L.sanitize({enabled = true, traffic = "yes", parked = 0, nearRadius = 5, perMinute = 99, checkSeconds = 0})
check(s.enabled == true and s.traffic == false and s.parked == true, "only a real true switches on; parked is on unless exactly false")
check(L.sanitize({parked = false}).parked == false, "parked can be switched off")
check(s.nearRadius == 120 and s.perMinute == 12 and s.checkSeconds == 1, "numbers are clamped (radius never under the 120 m view gate)")
check(L.sanitize({nearRadius = 99999}).nearRadius == 1000 and L.sanitize({nearRadius = "x"}).nearRadius == 250, "radius upper clamp, junk = default")
check(L.sanitize("junk").enabled == false, "junk settings: defaults")
check(V.sanitize({simplified = {enabled = true}}).simplified.enabled == true and V.sanitize({}).simplified.enabled == false, "part of the variety settings")

-- names ---------------------------------------------------------------------------------------------------------------
local real, kind = L.parseConfig("legran_sedan_pre_s_parked")
check(real == "legran" and kind == "parked", "parked config name")
real, kind = L.parseConfig("pickup_d25")
check(real == "pickup" and kind == "traffic", "traffic config name")
check(L.parseConfig("") == nil and L.parseConfig(nil) == nil and L.parseConfig("_x") == nil, "unreadable names")
check(L.realOf("vehicles/simple_traffic/etk800_x_parked.pc") == "etk800" and L.realOf("legran_a") == "legran" and L.realOf(5) == nil, "real model from a config path or name")
check(L.isSimple("simple_traffic") and not L.isSimple("pickup") and not L.isSimple(nil), "isSimple")

-- map -----------------------------------------------------------------------------------------------------------------
local names = {"legran_a", "legran_b_parked", "pickup_a_parked", "pickup_b", "pickup_c", "bad", "_x"}
local map, n = L.buildMap(names, function(name) return name ~= "pickup_c" end)
check(n.total == 6 and n.traffic == 3 and n.parked == 2, "counts (the filter rejected pickup_c; _x is ignored)")
check(#map.legran.traffic == 1 and #map.legran.parked == 1 and #map.pickup.traffic == 1 and #map.pickup.parked == 1, "map by real model")
check(L.pickSimple(map, "legran", "traffic") == "legran_a" and L.pickSimple(map, "pickup", "parked") == "pickup_a_parked", "pickSimple")
check(L.pickSimple(map, "van", "traffic") == nil and L.pickSimple(nil, "van", "traffic") == nil, "no stand-in for an unknown model")
check(L.hasTraffic(map) and not L.hasTraffic({}) and not L.hasTraffic(L.buildMap({"a_parked"})), "hasTraffic")
local m2 = L.buildMap(names)
check(#m2.pickup.traffic == 2 and m2.bad ~= nil, "no filter: all traffic configs count")

-- parked decisions ----------------------------------------------------------------------------------------------------
local on = L.sanitize({enabled = true, parked = true, traffic = true, nearRadius = 250})
check(L.parkedWant(on, {simple = true, stealable = true, dist = 200}) == "toFull", "a stand-in at a stealable spot with a player near: real car")
check(L.parkedWant(on, {simple = true, stealable = true, dist = 251}) == nil, "...not while everybody is farther than the radius")
check(L.parkedWant(on, {simple = true, stealable = false, dist = 10}) == nil, "a stand-in at a normal spot stays a stand-in")
check(L.parkedWant(on, {simple = false, stealable = true, dist = 10}) == nil, "a real car at a stealable spot stays")
check(L.parkedWant(on, {simple = false, stealable = false, dist = 400, converted = true}) == "toSimple", "an upgraded car no longer at a stealable spot, everybody far: back")
check(L.parkedWant(on, {simple = false, stealable = false, dist = 300, converted = true}) == nil, "...not before 1.5 x the radius")
check(L.parkedWant(on, {simple = false, stealable = false, dist = 900}) == nil, "...and never a car we did not upgrade")
check(L.parkedWant(L.sanitize({enabled = false}), {simple = true, stealable = true, dist = 1}) == nil, "off: nothing")
check(L.parkedWant(L.sanitize({enabled = true, parked = false}), {simple = true, stealable = true, dist = 1}) == nil, "parked off: nothing")
check(L.parkedWant(on, {simple = true, stealable = true}) == nil, "unknown distance: nothing")

-- traffic decisions ---------------------------------------------------------------------------------------------------
check(L.trafficWant(on, {simple = true, dist = 100}) == "toFull", "a stand-in that comes near is upgraded")
check(L.trafficWant(on, {simple = true, dist = 400}) == nil, "a far stand-in stays")
check(L.trafficWant(on, {simple = false, dist = 5}) == nil, "a real car is never made a stand-in while driving")
check(L.trafficWant(L.sanitize({enabled = true}), {simple = true, dist = 5}) == nil, "traffic off (default): nothing")
check(L.respawnKind(on, 300, true) == "simple" and L.respawnKind(on, 200, true) == "full", "respawn: stand-in only beyond the radius")
check(L.respawnKind(on, 300, false) == "full" and L.respawnKind(on, nil, true) == "full", "respawn: real car without stand-ins or distance")
check(L.respawnKind(L.sanitize({enabled = true}), 999, true) == "full", "respawn: traffic off = real car")

-- helpers -------------------------------------------------------------------------------------------------------------
check(L.nearest({x = 0, y = 0, z = 0}, {{x = 3, y = 4, z = 0}, {x = 100, y = 0, z = 0}}) == 5, "nearest player")
check(L.nearest({x = 0, y = 0, z = 0}, {}) == math.huge and L.nearest(nil, {}) == nil, "no players: infinite, no position: nil")
local list = {{model = "simple_traffic", config = "a"}, {model = "pickup", config = "b"}, {model = "simple_traffic", config = "c"}}
local only, cnt = L.preferSimple(list, 2)
check(#only == 2 and cnt == 2 and only[1].config == "a" and only[2].config == "c", "parked group: stand-ins only when there are enough")
only, cnt = L.preferSimple(list, 3)
check(only == list and cnt == 2, "...else the list as it is")
check(L.preferSimple({}, 1)[1] == nil, "empty list")
local a, b = L.census({"simple_traffic", "pickup", "simple_traffic", "van"})
check(a == 2 and b == 2, "census")

-- parked stand-in as the look of a full pick -------------------------------------------------------------------------------
local sm = L.buildMap({"legran_sedan_pre_s_parked", "legran_wagon_parked", "legran_sedan", "pickup_d25_parked"})
check(L.pickSimpleFor(sm, "legran", "sedan_pre_h", function() return 0 end) == "legran_sedan_pre_s_parked", "stand-in of the same body style (sedan)")
check(L.pickSimpleFor(sm, "legran", "wagon_lux", function() return 0 end) == "legran_wagon_parked", "stand-in of the same body style (wagon)")
check(L.pickSimpleFor(sm, "legran", "coupe_v8") == nil, "no shared word: no stand-in, the car stays a full car")
check(L.pickSimpleFor(sm, "bastion", "sedan") == nil, "no stand-in for the model: nil")
local grp = {{model = "legran", config = "sedan_k1"}, {model = "bastion", config = "x"}, {model = "simple_traffic", config = "a_parked"}}
local out, intended = V.proxyParked(grp, function(e) return L.pickSimpleFor(sm, e.model, e.config, function() return 0 end) end, 1, function() return 0 end)
check(#out == 3 and out[1].model == "simple_traffic" and out[2].model == "bastion" and out[3].config == "a_parked", "share 1: a pick with a stand-in is shown as the stand-in, others stay")
check(#intended == 1 and intended[1].model == "legran" and intended[1].config == "sedan_k1" and intended[1].stand == "legran_sedan_pre_s_parked", "the real pick is listed")
out, intended = V.proxyParked(grp, function() return "x_parked" end, 0, function() return 0 end)
check(out[1].model == "legran" and #intended == 0, "share 0: all full cars")
check(#V.dropBlocked({{model = "a", config = "taxi_x"}, {model = "a", config = "k", ctype = "Police"}, {model = "a", config = "ok"}}) == 1, "police and taxi stay out of parked groups")

print(string.format("simplified_lib_test: %d checks passed", passed))
