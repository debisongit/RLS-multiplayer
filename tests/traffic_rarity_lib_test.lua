-- Rarity tiers, zone / day-night weights through the pool selector, and the preload logic (LuaJIT). Run: luajit tests/traffic_rarity_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local V = require("rlsmp/lib/trafficVariety")
local PL = require("rlsmp/lib/trafficPreload")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function lcg(seed) local s = seed return function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end end

-- sanitize ------------------------------------------------------------------------------------------------------------------------
local d = V.sanitize({})
check(d.rarity.enabled and d.rarity.common == 0.88 and d.rarity.rare == 0.02 and #d.rarity.rareWords > 5, "rarity defaults")
local j = V.sanitize({rarity = {common = 5, rare = -1, rareWords = {"Drift", 3, string.rep("x", 40)}, rareValue = "x"}}).rarity
check(j.common == 1 and j.rare == 0 and #j.rareWords == 1 and j.rareWords[1] == "drift" and j.rareValue == 120000, "rarity clamped, words cleaned, junk = default")
check(V.sanitize({rarity = "x"}).rarity.enabled == true, "junk block gives defaults")

-- tierOf --------------------------------------------------------------------------------------------------------------------------
local rc = d.rarity
local function tier(model, config, extra)
  local e = {model = model, config = config}
  for k, v in pairs(extra or {}) do e[k] = v end
  return V.tierOf(e, rc)
end
check(tier("bx", "pro_drift_M") == "rare", "drift is rare")
check(tier("muscle", "race") == "rare", "race is rare")
check(tier("sunburst2", "joes_junk_career_sunburst_sedan") == "rare", "junk is rare")
check(tier("scintilla", "gt_spider") == "rare", "an exotic model is rare")
check(tier("beachbuggy", "tuner_m") == "rare", "a buggy is rare")
check(tier("etki", "offroada331972") == "uncommon", "offroad inside a name is uncommon")
check(tier("euvan", "cargo_300d_workpackage_M_rhd_thw") == "uncommon", "workpackage is uncommon")
check(tier("covet", "15le_A") == "common" and tier("legran", "se_i4_A") == "common" and tier("etk800", "844_250_A") == "common", "everyday cars are common")
check(tier("pickup", "d25", {ctype = "Race"}) == "rare" and tier("pickup", "d25", {value = 200000}) == "rare", "Config Type Race and a high Value are rare")
check(tier("pickup", "d25", {value = 50000}) == "uncommon" and tier("pickup", "d25", {value = 9000}) == "common", "Value thresholds")
check(tier("grace", "a") == "common" and tier("pickup", "pro") == "uncommon", "short words match whole words only")

-- shares through the pool selector ----------------------------------------------------------------------------------------------------
local brands, entries = {}, {}
local function add(model, brand, configs) brands[model] = brand for _, c in ipairs(configs) do entries[#entries + 1] = {model = model, config = c} end end
local names = {} for i = 1, 40 do names[i] = "m" .. i end
for i, m in ipairs(names) do add(m, "B" .. i, {"base", "lx", "ex", "plain"}) end
add("sunburst2", "S", {"joes_junk_career", "base"}) add("bx", "X", {"pro_drift_M", "base"}) add("scintilla", "Z", {"gt_spider", "gt"})
add("etki", "E", {"offroada331972", "base"}) add("tenor70", "T", {"1600RXi_M", "race"}) add("lux", "L", {"sport", "base"})
local function infoOf(e) return {type = "Car", brand = brands[e.model]} end
local cfg = V.sanitize({})
local mem, rnd = V.newPool(), lcg(5)
local counts = {common = 0, uncommon = 0, rare = 0}
local N = 3000
for _ = 1, N do
  local e = V.pickOne(mem, entries, infoOf, {}, cfg, rnd, nil)
  counts[V.tierOf(e, cfg.rarity)] = counts[V.tierOf(e, cfg.rarity)] + 1
end
check(counts.common / N >= 0.8, "pickOne: everyday cars are the clear majority (" .. counts.common / N .. ")")
check(counts.rare / N <= 0.04, "pickOne: rare cars stay rare (" .. counts.rare / N .. ")")
check(counts.uncommon > 0 and counts.rare > 0, "pickOne: the other tiers still show up")
local off = V.sanitize({rarity = {enabled = false}})
mem, rnd = V.newPool(), lcg(5)
local rareOff = 0
for _ = 1, 1500 do
  local e = V.pickOne(mem, entries, infoOf, {}, off, rnd, nil)
  if V.tierOf(e, cfg.rarity) == "rare" then rareOff = rareOff + 1 end
end
check(rareOff / 1500 > 0.05, "rarity off: rare configs are as likely as any (" .. rareOff / 1500 .. ")")
mem, rnd = V.newPool(), lcg(9)
local gc = {common = 0, uncommon = 0, rare = 0}
for _ = 1, 400 do
  for _, e in ipairs(V.select(entries, 6, infoOf, {}, cfg, rnd, mem)) do gc[V.tierOf(e, cfg.rarity)] = gc[V.tierOf(e, cfg.rarity)] + 1 end
end
check(gc.common / 2400 >= 0.8 and gc.rare / 2400 <= 0.04, "select: same shares in groups (" .. gc.common / 2400 .. " / " .. gc.rare / 2400 .. ")")
-- only rare cars exist: they are still used (renormalised)
local onlyRare = {{model = "scintilla", config = "gt"}, {model = "bx", config = "pro_drift_M"}}
check(V.pickOne(V.newPool(), onlyRare, infoOf, {}, cfg, lcg(1), nil) ~= nil and #V.select(onlyRare, 2, infoOf, {}, cfg, lcg(1)) == 2, "a list with only rare cars still gives picks")

-- zone and day/night weights reach the selector -------------------------------------------------------------------------------------------------
local tinfo = function(e) return {type = (e.model == "semi" or e.model == "pickup") and "Truck" or "Car", brand = brands[e.model] or e.model} end
local pool2 = {}
for _, m in ipairs({"sedan", "hatch", "coupe", "wagon", "mini", "compact"}) do pool2[#pool2 + 1] = {model = m, config = "base"} end
for _, m in ipairs({"semi", "pickup"}) do pool2[#pool2 + 1] = {model = m, config = "base"} end
local zcfg = V.sanitize({rarity = {enabled = false}, pool = {avoidLast = 0, brandMax = 40, streetMax = 40}, zones = {city = {Truck = 0.1}, highway = {Truck = 4}}, night = {Truck = 0.25}})
local function truckShare(ctx)
  local m, r, t = V.newPool(), lcg(3), 0
  for _ = 1, 1500 do
    local e = V.pickOne(m, pool2, tinfo, ctx, zcfg, r, nil)
    if tinfo(e).type == "Truck" then t = t + 1 end
  end
  return t / 1500
end
local city, hwy, hwyNight = truckShare({zone = "city"}), truckShare({zone = "highway"}), truckShare({zone = "highway", night = true})
check(hwy > city * 5, "trucks: far more on the highway than in the city (" .. hwy .. " vs " .. city .. ")")
check(hwyNight < hwy * 0.6, "trucks: fewer at night (" .. hwyNight .. " vs " .. hwy .. ")")
check(V.zoneFromSpeed(12, zcfg) == "city" and V.zoneFromSpeed(22, zcfg) == "main" and V.zoneFromSpeed(35, zcfg) == "highway" and V.zoneFromSpeed(nil, zcfg) == nil, "road class from the speed limit")

-- preload lib ---------------------------------------------------------------------------------------------------------------------------------------
local pd = PL.sanitize({reserve = 99, slowFrameMs = "x", warmShare = 2})
check(pd.reserve == nil and pd.slowFrameMs == 45 and pd.warmShare == 1, "preload sanitize")
local pc = PL.sanitize({})
local g = PL.newGuard()
check(PL.canBuild(g, 100, pc), "calm start: allowed")
for i = 1, 10 do PL.feed(g, 0.016, 100 + i * 0.016, pc) end
check(PL.canBuild(g, 101, pc), "smooth frames: allowed")
PL.feed(g, 0.2, 101, pc)
local ok, why = PL.canBuild(g, 102, pc)
check(not ok and why == "slow frame", "a hitch blocks builds")
check(PL.canBuild(g, 101 + pc.settleSeconds + 0.1, pc), "after settleSeconds of calm: allowed again")
PL.feed(g, 0.5, 105, pc)
check(not PL.canBuild(g, 106, pc), "another hitch: blocked again")
for i = 1, 50 do PL.feed(g, 0.016, 105 + i * 0.016, pc) end
check(PL.canBuild(g, 109, pc), "calm again: allowed")
PL.built(g, 109)
ok, why = PL.canBuild(g, 110, pc)
check(not ok and why == "gap", "two builds are never closer than minGapSeconds")
check(PL.canBuild(g, 109 + pc.minGapSeconds + 0.1, pc), "after the gap: allowed")

local warm = {a = true, b = true, c = true, d = true, e = true, f = true}
local list = {}
for _, m in ipairs({"a", "b", "c", "d", "e", "f", "x", "y"}) do list[#list + 1] = {model = m, config = "1"} end
check(#PL.preferWarm(list, warm, 0.7, function() return 0.1 end) == 6, "warm bias: only loaded models")
check(#PL.preferWarm(list, warm, 0.7, function() return 0.9 end) == 8, "warm bias: sometimes everything")
check(#PL.preferWarm(list, {a = true}, 1, function() return 0 end) == 8, "warm bias: too few warm models, no filter")

print("traffic_rarity_lib_test: " .. passed .. " checks passed")
