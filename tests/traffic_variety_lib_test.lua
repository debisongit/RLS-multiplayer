-- Traffic variety pure logic test (LuaJIT). Run: luajit tests/traffic_variety_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local V = require("rlsmp/lib/trafficVariety")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- a deterministic random source: a simple LCG in [0,1)
local function lcg(seed)
  local s = seed
  return function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end
end

local function cfgWith(over)
  local c = V.sanitize(over or {})
  return c
end

-- sanitize -----------------------------------------------------------------------------------------------
local c = V.sanitize(nil)
check(c.enabled == true and c.oversample == 2 and c.maxShare == 0.25 and c.maxCandidates == 80, "defaults for a missing table")
check(next(c.typeWeights) == nil and next(c.mods) == nil, "no weights by default")
c = V.sanitize({typeWeights = {Truck = 0.5, Bad = -3, Nan = 0 / 0, Str = "x", Inf = math.huge, [1] = 2, [string.rep("n", 80)] = 1},
  mods = {mycar = 3}, oversample = 99, maxShare = 0, maxCandidates = 5, enabled = false})
check(c.typeWeights.Truck == 0.5, "good weight kept")
check(c.typeWeights.Bad == 0, "negative weight becomes 0 (never)")
check(c.typeWeights.Nan == nil and c.typeWeights.Str == nil and c.typeWeights.Inf == nil, "NaN, text and infinity dropped")
check(c.typeWeights[1] == nil and c.typeWeights[string.rep("n", 80)] == nil, "non-string and too long names dropped")
check(c.oversample == 4 and c.maxShare == 0.05 and c.maxCandidates == 10 and c.enabled == false, "numbers are clamped")
local big = {}
for i = 1, 200 do big["t" .. i] = 1 end
local n = 0
for _ in pairs(V.sanitize({typeWeights = big}).typeWeights) do n = n + 1 end
check(n == 64, "at most 64 entries per table")
c = V.sanitize({zoneSpeedLimits = {city = 20, main = 10}})
check(c.zoneSpeedLimits.city == 20 and c.zoneSpeedLimits.main == 20, "main limit cannot be below city")

-- zones -----------------------------------------------------------------------------------------------------
local cfg = cfgWith({})
check(V.zoneFromSpeed(10, cfg) == "city" and V.zoneFromSpeed(20, cfg) == "main" and V.zoneFromSpeed(35, cfg) == "highway", "road classes by speed limit")
check(V.zoneFromSpeed(nil, cfg) == nil and V.zoneFromSpeed(0, cfg) == nil and V.zoneFromSpeed("x", cfg) == nil, "no speed limit -> no zone")

-- weights ---------------------------------------------------------------------------------------------------
cfg = cfgWith({typeWeights = {Truck = 0.5}, zones = {highway = {Truck = 4}}, night = {Truck = 0.5}, day = {Truck = 2}, mods = {modcar = 3}})
local truck, car = {model = "pickup", config = "a"}, {model = "etk800", config = "a"}
check(V.weight(car, {type = "Car"}, {}, cfg) == 1, "unlisted Type counts as 1")
check(V.weight(truck, {type = "Truck"}, {}, cfg) == 0.5 * 2, "type weight x day multiplier")
check(V.weight(truck, {type = "Truck"}, {night = true}, cfg) == 0.5 * 0.5, "type weight x night multiplier")
check(V.weight(truck, {type = "Truck"}, {zone = "highway", night = true}, cfg) == 0.5 * 4 * 0.5, "type x zone x night")
check(V.weight(truck, {type = "Truck"}, {zone = "city"}, cfg) == 0.5 * 2, "a zone without an entry changes nothing")
check(V.weight({model = "modcar", config = "x"}, {type = "Car", mod = true}, {}, cfg) == 3, "mod weight")
check(V.weight(car, {}, {zone = "highway"}, cfg) == 1, "unknown Type: only the mod weight can apply")

-- select ----------------------------------------------------------------------------------------------------
local function pool(model, count, startAt)
  local out = {}
  for i = 1, count do out[#out + 1] = {model = model, config = "c" .. (startAt or 0) + i} end
  return out
end
local function concat(...)
  local out = {}
  for _, list in ipairs({...}) do for _, e in ipairs(list) do out[#out + 1] = e end end
  return out
end
local types = {sedan = "Car", hatch = "Car", pickup = "Truck", van = "Truck", bus = "Truck"}
local function infoOf(e) return {type = types[e.model]} end
local function count(group, model) local k = 0 for _, e in ipairs(group) do if e.model == model then k = k + 1 end end return k end

cfg = cfgWith({})
local candidates = concat(pool("sedan", 12), pool("hatch", 4), pool("pickup", 4), pool("van", 2))
local group = V.select(candidates, 10, infoOf, {}, cfg, lcg(1))
check(#group == 10, "group has the wanted size")
check(count(group, "sedan") <= 3, "no model fills more than 25% of the group (cap 3 of 10)")
local seen, unique = {}, true
for _, e in ipairs(group) do local k = e.model .. "/" .. e.config if seen[k] then unique = false end seen[k] = true end
check(unique, "entries are unique while the pool is big enough")
check(V.distinctModels(group) >= 4, "four models offered, all four appear")

-- weight 0 means never
cfg = cfgWith({typeWeights = {Truck = 0}})
for seed = 1, 20 do
  local g = V.select(candidates, 10, infoOf, {}, cfg, lcg(seed))
  check(count(g, "pickup") == 0 and count(g, "van") == 0 and #g == 10, "Truck weight 0: no trucks, group still full (seed " .. seed .. ")")
end

-- weights steer the mix (statistics with a fixed random source)
cfg = cfgWith({typeWeights = {Truck = 4}, maxShare = 1})
local trucks, total = 0, 0
local rnd = lcg(7)
for _ = 1, 400 do
  local g = V.select({{model = "sedan", config = "a"}, {model = "pickup", config = "a"}}, 1, infoOf, {}, cfg, rnd)
  total = total + 1
  if g[1].model == "pickup" then trucks = trucks + 1 end
end
check(trucks / total > 0.74 and trucks / total < 0.86, "weight 4 against 1 gives about 80% (got " .. trucks / total .. ")")

-- night and zone change the mix
cfg = cfgWith({night = {Truck = 0}, maxShare = 1})
local g = V.select(candidates, 10, infoOf, {night = true}, cfg, lcg(3))
check(count(g, "pickup") + count(g, "van") == 0, "night multiplier 0: no trucks at night")
g = V.select(candidates, 10, infoOf, {night = false}, cfg, lcg(3))
check(count(g, "pickup") + count(g, "van") > 0, "same settings by day: trucks allowed")

-- small pools still give a full group (cap relaxed, then repeats)
cfg = cfgWith({})
local small = pool("sedan", 3)
local sg, relaxed = V.select(small, 6, infoOf, {}, cfg, lcg(5))
check(#sg == 6 and relaxed > 0, "a pool smaller than the group: repeats fill it up")
local one, rel1 = V.select(pool("sedan", 8), 8, infoOf, {}, cfg, lcg(9))
check(#one == 8 and rel1 > 0, "one model only: the cap is relaxed instead of returning a short group")

-- nothing usable
check(#V.select({}, 5, infoOf, {}, cfg, lcg(1)) == 0, "no candidates, empty group")
check(#V.select(candidates, 0, infoOf, {}, cfg, lcg(1)) == 0, "amount 0, empty group")
check(#V.select({{model = "pickup", config = "a"}}, 3, infoOf, {}, cfgWith({typeWeights = {Truck = 0}}), lcg(1)) == 0, "everything weighted 0: empty, the caller falls back to the game's group")

-- mods get their weight
cfg = cfgWith({mods = {modcar = 100}, maxShare = 1})
local modInfo = function(e) return {type = "Car", mod = e.model == "modcar"} end
local mixed = concat(pool("sedan", 6), {{model = "modcar", config = "m1"}})
local modPicked = 0
rnd = lcg(11)
for _ = 1, 400 do
  local mg = V.select(mixed, 1, modInfo, {}, cfg, rnd)
  if mg[1].model == "modcar" then modPicked = modPicked + 1 end
end
check(modPicked / 400 > 0.88 and modPicked / 400 < 0.99, "a mod weighted 100 against 6 cars is picked about 94% of the time (" .. modPicked .. "/400)")

print(string.format("traffic_variety_lib_test: %d checks passed", passed))
