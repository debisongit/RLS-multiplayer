-- Premade pool / round-robin picking, pure logic (LuaJIT). Run: luajit tests/traffic_pool_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local V = require("rlsmp/lib/trafficVariety")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function lcg(seed)
  local s = seed
  return function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end
end

-- 12 models of 5 brands, 4 configs each
local brands = {sedan = "Ibishu", hatch = "Ibishu", coupe = "Ibishu", pickup = "Gavril", van = "Gavril", truck = "Gavril",
  wagon = "Bruckell", bus = "Bruckell", roamer = "Hopper", suv = "Hopper", sport = "ETK", mini = "ETK"}
local entries, models = {}, {}
for model in pairs(brands) do models[#models + 1] = model end
table.sort(models)
for _, model in ipairs(models) do
  for i = 1, 4 do entries[#entries + 1] = {model = model, config = "c" .. i} end
end
local function infoOf(e) return {type = "Car", brand = brands[e.model]} end
local cfg = V.sanitize({rarity = {enabled = false}})   -- rarity has its own tests (traffic_rarity_lib_test.lua)
local ctx = {}

-- sanitize ------------------------------------------------------------------------------------------------
check(cfg.pool.avoidLast == 6 and cfg.pool.brandMax == 3 and cfg.respawn.enabled and cfg.respawn.perMinute == 3 and cfg.parked.amount == 10, "defaults")
local c2 = V.sanitize({pool = {avoidLast = 999, brandMax = 0, popPower = 9}, respawn = {perMinute = 99, chance = 5, enabled = false}, parked = {amount = 500}})
check(c2.pool.avoidLast == 40 and c2.pool.brandMax == 1 and c2.pool.popPower == 1, "pool numbers clamped")
check(c2.respawn.perMinute == 12 and c2.respawn.chance == 1 and c2.respawn.enabled == false, "respawn numbers clamped")
check(c2.parked.amount == 30, "parked amount clamped to 30")
check(V.sanitize({parked = {amount = -4}}).parked.amount == 0 and V.sanitize({parked = {amount = "x"}}).parked.amount == 10, "parked: negative = 0, junk = default")
check(V.sanitize({parked = "x", pool = 3, respawn = false}).pool.enabled == true, "junk blocks give defaults")

-- popFactor -----------------------------------------------------------------------------------------------
check(V.popFactor(nil, 0.5) == 1 and V.popFactor(1000, 0) == 1 and V.popFactor(1000, 0.5) == 1, "popFactor neutral cases")
check(V.popFactor(1, 0.5) == 0.3 and V.popFactor(1e9, 0.5) == 3 and V.popFactor(4000, 0.5) == 2, "popFactor clamps and scales")

-- pickOne: round robin over 200 respawns ---------------------------------------------------------------------
local mem, rnd = V.newPool(), lcg(7)
local current = {model = "sedan", config = "c1"}
local seen, prevModel, repeats = {}, nil, 0
local brandSeen = {}
for _ = 1, 200 do
  local e, stage = V.pickOne(mem, entries, infoOf, ctx, cfg, rnd, current)
  check(e ~= nil, "a pick always exists with a big pool")
  check(e.model ~= current.model, "never the model the car has now")
  check(stage == 1, "the big pool needs no relaxed stage (stage " .. tostring(stage) .. ")")
  if e.model == prevModel then repeats = repeats + 1 end
  prevModel = e.model
  seen[e.model] = (seen[e.model] or 0) + 1
  brandSeen[brands[e.model]] = true
  current = e
end
check(repeats == 0, "the same model is never picked twice in a row")
local n = 0
for _, m in ipairs(models) do if (seen[m] or 0) > 0 then n = n + 1 end end
check(n == #models, "every model shows up over 200 picks")
local lo, hi = 1e9, 0
for _, m in ipairs(models) do lo = math.min(lo, seen[m]) hi = math.max(hi, seen[m]) end
check(hi - lo <= 8, "round robin keeps the counts close (" .. lo .. " to " .. hi .. ")")
local nb = 0
for _ in pairs(brandSeen) do nb = nb + 1 end
check(nb == 5, "all 5 brands appear")

-- avoid-last window: no model among the last 6 picks
mem, rnd = V.newPool(), lcg(11)
local hist = {}
for _ = 1, 100 do
  local e = V.pickOne(mem, entries, infoOf, ctx, cfg, rnd, nil)
  for i = math.max(1, #hist - 5), #hist do check(hist[i] ~= e.model, "no model repeats within the last 6 picks") end
  hist[#hist + 1] = e.model
end

-- per-brand cap: at most brandMax of a brand among the last brandWindow picks
mem, rnd = V.newPool(), lcg(5)
local tight = V.sanitize({pool = {brandMax = 2, brandWindow = 8, avoidLast = 2}})
local picks = {}
for _ = 1, 150 do
  local e, stage = V.pickOne(mem, entries, infoOf, ctx, tight, rnd, nil)
  picks[#picks + 1] = brands[e.model]
  check(stage == 1, "caps can always be met with 5 brands")
  local count = 0
  for i = math.max(1, #picks - 7), #picks do if picks[i] == picks[#picks] then count = count + 1 end end
  check(count <= 2, "brand cap holds in the window")
end

-- street census: a brand already on the street 3 times is skipped
for _ = 1, 40 do
  mem = V.newPool()
  local e, stage = V.pickOne(mem, entries, infoOf, ctx, cfg, rnd, nil, {Ibishu = 3, Gavril = 3, Bruckell = 3, Hopper = 3})
  check(brands[e.model] == "ETK" and stage == 1, "only the brand not yet on the street is picked")
end

-- weights: weight 0 is never picked, server weights still count
local w0 = V.sanitize({models = {sedan = 0, hatch = 0}})
mem = V.newPool()
for _ = 1, 100 do
  local e = V.pickOne(mem, entries, infoOf, ctx, w0, rnd, nil)
  check(e.model ~= "sedan" and e.model ~= "hatch", "weight 0 is never picked")
end
local heavy = V.sanitize({models = {van = 8}, pool = {avoidLast = 0}})
mem = V.newPool()
local vans = 0
for _ = 1, 200 do if V.pickOne(mem, entries, infoOf, ctx, heavy, rnd, nil).model == "van" then vans = vans + 1 end end
check(vans > 25, "a heavier weight picks that model more often than the 17 of 200 a plain model gets (" .. vans .. "/200)")

-- a config choice that differs from the last one of that model
mem = V.newPool()
local two = {{model = "solo", config = "a"}, {model = "solo", config = "b"}, {model = "solo", config = "c"}}
local lastCfg = nil
for _ = 1, 30 do
  local e, stage = V.pickOne(mem, two, nil, ctx, cfg, rnd, {model = "solo", config = lastCfg or "a"})
  check(e.config ~= (lastCfg or "a"), "a single-model pool still changes the config")
  check(stage == 5, "single model: the last stage")
  lastCfg = e.config
end

-- empty and unusable pools
check(V.pickOne(V.newPool(), {}, nil, ctx, cfg, rnd, nil) == nil, "empty pool: nil")
check(V.pickOne(V.newPool(), nil, nil, ctx, cfg, rnd, nil) == nil, "no pool: nil")
check(V.pickOne(V.newPool(), {{model = "solo", config = "a"}}, nil, ctx, cfg, rnd, {model = "solo", config = "a"}) == nil, "only the car's own config exists: nil, the car stays")
check(V.pickOne(V.newPool(), entries, infoOf, ctx, V.sanitize({typeWeights = {Car = 0}}), rnd, nil) == nil, "everything weight 0: nil")

-- brand cap with a tiny pool is relaxed instead of leaving the car alone
mem = V.newPool()
local oneBrand = {{model = "a", config = "1"}, {model = "b", config = "1"}, {model = "c", config = "1"}}
local sameBrand = function() return {brand = "X"} end
for i = 1, 20 do
  local e = V.pickOne(mem, oneBrand, sameBrand, ctx, tight, rnd, nil)
  check(e ~= nil, "one brand only: the cap relaxes (round " .. i .. ")")
end

-- select() with a memory: groups follow the round robin across calls
mem = V.newPool()
local counts = {}
for _ = 1, 30 do
  local group = V.select(entries, 3, infoOf, ctx, cfg, rnd, mem)
  check(#group == 3, "group is full")
  local m = {}
  for _, e in ipairs(group) do
    check(not m[e.model], "no model twice in a group of 3")
    m[e.model] = true
    counts[e.model] = (counts[e.model] or 0) + 1
  end
end
local glo, ghi = 1e9, 0
for _, m in ipairs(models) do glo = math.min(glo, counts[m] or 0) ghi = math.max(ghi, counts[m] or 0) end
check(glo >= 5 and ghi <= 12, "groups spread over all models (" .. glo .. " to " .. ghi .. " of 90 cars)")
check(#V.select(entries, 5, infoOf, ctx, cfg, rnd) == 5, "no memory: as before")

print(string.format("traffic_pool_lib_test: %d checks passed", passed))
