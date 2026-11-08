-- RLS-Career-MP client: pure logic for "traffic variety" (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A group is a list of {model = ..., config = ...} entries that RLS/the game spawns as traffic or parked cars.
-- We take a bigger pool of candidates and pick the group from it with weights:
--   weight = (models[model], else typeWeights[Type]) x zones[zone][model, else Type] x (night or day)[model, else Type] x (mods[model] for a modded model)
-- `Type` is the model's own "Type" in the game's model list; a weight for the model itself always wins over the one for its Type.
-- Missing weights count as 1, 0 means "never".
-- No single model may fill more than `maxShare` of a group, so groups are varied even with all weights at 1.

local M = {}

M.DEFAULTS = {
  enabled = true,
  typeWeights = {},
  models = {},
  mods = {},
  zones = {},
  day = {},
  night = {},
  oversample = 2,
  maxShare = 0.25,
  maxCandidates = 80,
  -- Broken / junkyard / wreck cars are never traffic: a model or config name (or Config Type) containing one of these words is skipped everywhere we pick cars.
  excludeWords = {"junk", "wreck", "derby", "crash", "rolling", "shell", "undriveable", "parts"},
  applyToTraffic = true,
  applyToParked = true,
  zoneSpeedLimits = {city = 17, main = 27},   -- m/s: slower than city = "city", slower than main = "main", else "highway"
  swap = {enabled = false, live = false, perMinute = 2, hiddenSeconds = 5, checkSeconds = 2, minRatio = 1.5, maxFailures = 3},
  -- Police groups: weight per model (Bastion low), at most `undercoverShare` of the cars undercover, at most `maxShare` of a group one model.
  police = {enabled = true, models = {bastion = 0.3}, undercoverShare = 0.1, maxShare = 0.4, undercoverWords = {"undercover", "unmarked"}},
  -- Premade pool: every car the game could use, picked round-robin (least recently used first, no model twice in a row, per-brand cap).
  pool = {enabled = true, avoidLast = 6, brandWindow = 12, brandMax = 3, streetMax = 3, configsPerModel = 5, popPower = 0.5, ageMax = 30},
  -- Re-roll: a traffic car that RLS respawned out of everybody's sight becomes a different model with a different config.
  respawn = {enabled = true, mode = "async", perMinute = 2, chance = 0.25, repaintChance = 0.5, waitSeconds = 3, checkSeconds = 0.5},
  -- Parked cars: how many RLS keeps (its own game setting trafficParkingAmount). 0 = leave the game's own amount alone.
  parked = {amount = 10, fullPool = true, simplifiedShare = 0.5},
  -- Rarity: everyday cars are the clear majority. Tier shares (of the picks), and what puts a config into a higher tier (words in the model or config
  -- name, the config's Config Type and Value when the game tells them).
  rarity = {enabled = true, common = 0.88, uncommon = 0.10, rare = 0.02,
    rareWords = {"race", "racer", "racing", "drift", "hotrod", "junk", "drag", "crawler", "trophy", "buggy", "formula", "rocket"},
    uncommonWords = {"rally", "offroad", "tuner", "pro", "workpackage", "sport", "taxi", "police", "dune", "turbo"},
    rareModels = {"scintilla", "bolide"}, uncommonValue = 45000, rareValue = 120000},
  -- Preload: frame guard, bias to models that are already loaded (lib/trafficPreload.lua).
  preload = {enabled = true, minGapSeconds = 6, slowFrameMs = 45, calmFrames = 45, settleSeconds = 3, warmShare = 0.7},
  focus = {enabled = true, configs = 2, minutes = 20},
  -- Simplified (cheap stand-in) cars: lib/simplified.lua. Off by default.
  simplified = {enabled = false, parked = true, traffic = false, nearRadius = 250, perMinute = 4, checkSeconds = 2},
}

local MAX_ENTRIES = 64
local MAX_NAME = 64

local function number(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  if lo and v < lo then return lo end
  if hi and v > hi then return hi end
  return v
end

-- {name = weight}: names are short strings, weights finite numbers >= 0, at most MAX_ENTRIES.
local function weightMap(src)
  local out, n = {}, 0
  if type(src) ~= "table" then return out end
  for name, w in pairs(src) do
    if type(name) == "string" and name ~= "" and #name <= MAX_NAME and n < MAX_ENTRIES then
      local value = number(w, nil, 0)
      if value then out[name] = value n = n + 1 end
    end
  end
  return out
end

-- Live swapping settings. `enabled` only watches and logs what it would do; `live` really replaces cars (experimental).
local function swapSettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.swap
  return {
    enabled = src.enabled == true,
    live = src.live == true,
    perMinute = math.floor(number(src.perMinute, d.perMinute, 0, 12)),
    hiddenSeconds = number(src.hiddenSeconds, d.hiddenSeconds, 1, 120),
    checkSeconds = number(src.checkSeconds, d.checkSeconds, 0.5, 30),
    minRatio = number(src.minRatio, d.minRatio, 1, 100),
    maxFailures = math.floor(number(src.maxFailures, d.maxFailures, 1, 20)),
  }
end
M.sanitizeSwap = swapSettings

-- Police settings. A missing `models` means the default (Bastion low); a sent table (even empty) is used as it is.
local function policeSettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.police
  local words = {}
  if type(src.undercoverWords) == "table" then
    for _, w in ipairs(src.undercoverWords) do
      if type(w) == "string" and w ~= "" and #w <= 32 and #words < 8 then words[#words + 1] = string.lower(w) end
    end
  else
    for i, w in ipairs(d.undercoverWords) do words[i] = w end
  end
  return {
    enabled = src.enabled ~= false,
    models = type(src.models) == "table" and weightMap(src.models) or {bastion = d.models.bastion},
    undercoverShare = number(src.undercoverShare, d.undercoverShare, 0, 1),
    maxShare = number(src.maxShare, d.maxShare, 0.05, 1),
    undercoverWords = words,
  }
end
M.sanitizePolice = policeSettings

local function wordList(src, default, maxLen)
  local out = {}
  if type(src) == "table" then
    for _, w in ipairs(src) do
      if type(w) == "string" and w ~= "" and #w <= 32 and #out < maxLen then out[#out + 1] = string.lower(w) end
    end
  else
    for i, w in ipairs(default) do out[i] = w end
  end
  return out
end

local function raritySettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.rarity
  return {
    enabled = src.enabled ~= false,
    common = number(src.common, d.common, 0, 1),
    uncommon = number(src.uncommon, d.uncommon, 0, 1),
    rare = number(src.rare, d.rare, 0, 1),
    rareWords = wordList(src.rareWords, d.rareWords, 24),
    uncommonWords = wordList(src.uncommonWords, d.uncommonWords, 24),
    rareModels = wordList(src.rareModels, d.rareModels, 24),
    uncommonValue = number(src.uncommonValue, d.uncommonValue, 0, 100000000),
    rareValue = number(src.rareValue, d.rareValue, 0, 100000000),
  }
end
M.sanitizeRarity = raritySettings

local function poolSettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.pool
  return {
    enabled = src.enabled ~= false,
    avoidLast = math.floor(number(src.avoidLast, d.avoidLast, 0, 40)),
    brandWindow = math.floor(number(src.brandWindow, d.brandWindow, 1, 40)),
    brandMax = math.floor(number(src.brandMax, d.brandMax, 1, 40)),
    streetMax = math.floor(number(src.streetMax, d.streetMax, 1, 40)),
    configsPerModel = math.floor(number(src.configsPerModel, d.configsPerModel, 1, 12)),
    popPower = number(src.popPower, d.popPower, 0, 1),
    ageMax = number(src.ageMax, d.ageMax, 1, 200),
  }
end
M.sanitizePool = poolSettings

local function respawnSettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.respawn
  return {
    enabled = src.enabled ~= false,
    mode = (src.mode == "inplace" or src.mode == "off") and src.mode or "async",   -- async = the game's group spawn queue, inplace = replaceVehicle (hitches)
    perMinute = math.floor(number(src.perMinute, d.perMinute, 0, 12)),
    chance = number(src.chance, d.chance, 0, 1),
    repaintChance = number(src.repaintChance, d.repaintChance, 0, 1),
    waitSeconds = number(src.waitSeconds, d.waitSeconds, 0.5, 30),
    checkSeconds = number(src.checkSeconds, d.checkSeconds, 0.2, 10),
  }
end
M.sanitizeRespawn = respawnSettings

-- Parked cars: 0 leaves the game's own amount alone, otherwise 1..30.
local function parkedSettings(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS.parked
  return {amount = math.floor(number(src.amount, d.amount, 0, 30)), fullPool = src.fullPool ~= false,
    simplifiedShare = number(src.simplifiedShare, d.simplifiedShare, 0, 1)}
end
M.sanitizeParked = parkedSettings

-- Turns whatever the server sent (or a hand-edited config.json) into a safe settings table.
function M.sanitize(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS
  local zones = {}
  if type(src.zones) == "table" then
    for zone, map in pairs(src.zones) do
      if type(zone) == "string" and #zone <= MAX_NAME then zones[zone] = weightMap(map) end
    end
  end
  local limits = type(src.zoneSpeedLimits) == "table" and src.zoneSpeedLimits or {}
  local city = number(limits.city, d.zoneSpeedLimits.city, 1, 100)
  local main = number(limits.main, d.zoneSpeedLimits.main, city, 200)
  return {
    enabled = src.enabled ~= false,
    typeWeights = weightMap(src.typeWeights),
    models = weightMap(src.models),
    mods = weightMap(src.mods),
    zones = zones,
    day = weightMap(src.day),
    night = weightMap(src.night),
    oversample = number(src.oversample, d.oversample, 1, 4),
    maxShare = number(src.maxShare, d.maxShare, 0.05, 1),
    maxCandidates = math.floor(number(src.maxCandidates, d.maxCandidates, 10, 300)),
    excludeWords = wordList(src.excludeWords, d.excludeWords, 40),
    minAmount = math.floor(number(src.minAmount, 0, 0, 64)),   -- traffic.minAmount, known before the quota (0 = unknown)
    maxCars = math.floor(number(src.maxCars, 0, 0, 1000)),     -- BeamMP's MaxCars per player (0 = unknown)
    applyToTraffic = src.applyToTraffic ~= false,
    applyToParked = src.applyToParked ~= false,
    zoneSpeedLimits = {city = city, main = main},
    swap = swapSettings(src.swap),
    police = policeSettings(src.police),
    pool = poolSettings(src.pool),
    respawn = respawnSettings(src.respawn),
    parked = parkedSettings(src.parked),
    rarity = raritySettings(src.rarity),
    preload = require("rlsmp/lib/trafficPreload").sanitize(src.preload),
    focus = require("rlsmp/lib/trafficFocus").sanitize(src.focus),
    simplified = require("rlsmp/lib/simplified").sanitize(src.simplified),
  }
end

-- Road class from a speed limit in m/s. nil when the game has no speed limit for the road.
function M.zoneFromSpeed(limit, cfg)
  limit = tonumber(limit)
  if not limit or limit ~= limit or limit <= 0 then return nil end
  local limits = cfg and cfg.zoneSpeedLimits or M.DEFAULTS.zoneSpeedLimits
  if limit < limits.city then return "city" end
  if limit < limits.main then return "main" end
  return "highway"
end

-- A model's own entry wins over the one for its Type.
local function pick(map, model, t)
  if not map then return nil end
  local v = map[model]
  if v ~= nil then return v end
  if t then return map[t] end
  return nil
end

-- entry = {model, config}; info = {type = "Car" | nil, mod = bool}; ctx = {zone = "city" | nil, night = bool}.
function M.weight(entry, info, ctx, cfg)
  info = info or {}
  ctx = ctx or {}
  local t, model = info.type, entry.model
  local w = pick(cfg.models, model, nil)
  if w == nil then w = (t and cfg.typeWeights[t]) or 1 end
  local zone = ctx.zone and cfg.zones[ctx.zone]
  if zone then w = w * (pick(zone, model, t) or 1) end
  w = w * (pick(ctx.night and cfg.night or cfg.day, model, t) or 1)
  if info.mod then w = w * (cfg.mods[model] or 1) end
  if w ~= w or w < 0 then return 0 end
  return w
end

-- Rarity -------------------------------------------------------------------------------------------------------------------------------------------
-- "common", "uncommon" or "rare" for a config. entry = {model, config, ctype =, value =} (the last two only when the game told them).
function M.tierOf(entry, rc)
  local model = string.lower(tostring(entry.model))
  local name = model .. "_" .. string.lower(tostring(entry.config))
  local tokens = {}
  for t in name:gmatch("[%a%d]+") do tokens[t] = true end
  local function hit(words)
    for _, w in ipairs(words) do
      if tokens[w] or (#w >= 5 and name:find(w, 1, true)) then return true end
    end
    return false
  end
  local value = tonumber(entry.value)
  local ctype = type(entry.ctype) == "string" and string.lower(entry.ctype) or ""
  for _, m in ipairs(rc.rareModels) do if m == model then return "rare" end end
  if ctype == "race" or ctype == "drift" or (value and value >= rc.rareValue and rc.rareValue > 0) or hit(rc.rareWords) then return "rare" end
  if (value and value >= rc.uncommonValue and rc.uncommonValue > 0) or hit(rc.uncommonWords) then return "uncommon" end
  return "common"
end

-- A function entry -> multiplier that makes the tiers' share of the picks what the settings say (shares are renormalised over the tiers that
-- exist in this list). nil when rarity is off or there is nothing to scale.
function M.rarityPlan(entries, infoOf, ctx, cfg)
  local rc = cfg.rarity
  if not (rc and rc.enabled) then return nil end
  -- the selectors give every MODEL one share (split over its configs), so the tier sums count each entry as weight / configs of its model
  local sum, tier, perModel = {common = 0, uncommon = 0, rare = 0}, {}, {}
  for _, e in ipairs(entries) do perModel[e.model] = (perModel[e.model] or 0) + 1 end
  for _, e in ipairs(entries) do
    local t = M.tierOf(e, rc)
    tier[e] = t
    sum[t] = sum[t] + M.weight(e, infoOf and infoOf(e) or nil, ctx, cfg) / perModel[e.model]
  end
  local present = 0
  for t, w in pairs(sum) do if w > 0 and rc[t] > 0 then present = present + rc[t] end end
  if present <= 0 then return nil end
  local factor = {}
  for t, w in pairs(sum) do factor[t] = (w > 0 and rc[t] > 0) and (rc[t] / present / w) or 0 end
  return function(e)
    local t = tier[e] or M.tierOf(e, rc)
    return factor[t]
  end
end

local function keyOf(entry) return tostring(entry.model) .. "/" .. tostring(entry.config) end

-- Round-robin memory ("pool"): which models were picked lately, so the street keeps changing.
--   history = the last picks {model, brand}, newest last; last[model] = the pick number it was used at; lastConfig[model] = its last config.
function M.newPool() return {tick = 0, last = {}, lastConfig = {}, history = {}} end

local HISTORY_MAX = 60

-- Remember a pick (a group entry or a re-roll).
function M.poolNote(mem, entry, brand)
  mem.tick = mem.tick + 1
  mem.last[entry.model] = mem.tick
  mem.lastConfig[entry.model] = entry.config
  mem.history[#mem.history + 1] = {model = entry.model, brand = brand}
  if #mem.history > HISTORY_MAX then table.remove(mem.history, 1) end
end

-- 0 = not allowed now (the model was used among the last `avoidLast` picks, or its brand is at the cap). Otherwise a boost for models unused for long.
-- `distinct` = how many models there are to choose from (avoidLast shrinks so the rule can always be met); `skipBrand` ignores the brand caps.
function M.poolFactor(mem, model, brand, cfg, distinct, census, skipBrand)
  local pc = cfg.pool
  local h = mem.history
  local avoid = math.min(pc.avoidLast, math.max(0, (distinct or 0) - 1))
  for i = #h, math.max(1, #h - avoid + 1), -1 do
    if h[i].model == model then return 0 end
  end
  if brand and not skipBrand then
    local n = 0
    for i = #h, math.max(1, #h - pc.brandWindow + 1), -1 do
      if h[i].brand == brand then n = n + 1 end
    end
    if n >= pc.brandMax then return 0 end
    if census and (census[brand] or 0) >= pc.streetMax then return 0 end
  end
  local age = mem.last[model] and (mem.tick - mem.last[model]) or pc.ageMax
  return 1 + math.min(age, pc.ageMax) / 5
end

-- Popular configs (high Population) are more likely than rare ones; power 0 switches it off. Unknown Population counts as normal.
function M.popFactor(pop, power)
  pop = tonumber(pop)
  if not pop or pop <= 0 or not power or power <= 0 then return 1 end
  local f = (pop / 1000) ^ power
  if f < 0.3 then return 0.3 end
  if f > 3 then return 3 end
  return f
end

-- Is this entry a junk / wreck / non-drivable car? Any word in the model, the config or its Config Type; entry.drivable == false counts too.
function M.isExcluded(entry, words)
  if type(entry) ~= "table" then return false end
  if entry.drivable == false then return true end
  local name = string.lower(tostring(entry.model) .. "/" .. tostring(entry.config) .. "/" .. tostring(entry.ctype or ""))
  for _, w in ipairs(words or {}) do
    if w ~= "" and name:find(w, 1, true) then return true end
  end
  return false
end

-- The list without excluded entries (the same table when nothing was removed).
function M.dropExcluded(list, words)
  if type(list) ~= "table" or not words or #words == 0 then return list end
  local out = {}
  for _, e in ipairs(list) do if not M.isExcluded(e, words) then out[#out + 1] = e end end
  return #out == #list and list or out
end

-- Picks `amount` entries from `candidates` (a list of {model, config, ...}).
--   infoOf(entry) -> {type =, mod =}   rnd() -> [0,1)
-- Returns the group (a list) and how many entries came from relaxing the per-model cap or from repeats.
function M.select(candidates, amount, infoOf, ctx, cfg, rnd, mem)
  rnd = rnd or math.random
  amount = math.floor(tonumber(amount) or 0)
  local out, relaxed = {}, 0
  if amount < 1 or type(candidates) ~= "table" or #candidates == 0 then return out, 0 end
  candidates = M.dropExcluded(candidates, cfg and cfg.excludeWords)

  -- unique candidates with their weights
  local pool, seen = {}, {}
  for _, entry in ipairs(candidates) do
    if type(entry) == "table" and entry.model then
      local key = keyOf(entry)
      if not seen[key] then
        seen[key] = true
        local info = infoOf and infoOf(entry)
        pool[#pool + 1] = {entry = entry, w = M.weight(entry, info, ctx, cfg), brand = info and info.brand}
      end
    end
  end
  if #pool == 0 then return out, 0 end
  local plan = M.rarityPlan((function() local l = {} for i, p in ipairs(pool) do l[i] = p.entry end return l end)(), infoOf, ctx, cfg)
  if plan then for _, p in ipairs(pool) do p.w = p.w * plan(p.entry) * 1000 end end

  local cap = math.max(1, math.ceil(amount * cfg.maxShare))
  local perModel = {}

  -- With a memory: every MODEL is equally likely whatever its number of configs, times the round-robin factor (0 = not now).
  local nModel, distinct = {}, 0
  if mem then
    for _, p in ipairs(pool) do
      if not nModel[p.entry.model] then distinct = distinct + 1 end
      nModel[p.entry.model] = (nModel[p.entry.model] or 0) + 1
    end
  end
  local function eff(p, useCap)
    if p.w <= 0 or (useCap and (perModel[p.entry.model] or 0) >= cap) then return 0 end
    if not mem then return p.w end
    local w = p.w / nModel[p.entry.model] * M.popFactor(p.entry.pop, cfg.pool.popPower)
    if useCap then
      local f = M.poolFactor(mem, p.entry.model, p.brand, cfg, distinct)
      if plan and f > 1 and M.tierOf(p.entry, cfg.rarity) ~= "common" then f = 1 end   -- no "unused for long" boost for uncommon / rare cars
      w = w * f
    end
    return w
  end

  local function pickFrom(list, useCap)
    local total = 0
    for _, p in ipairs(list) do total = total + eff(p, useCap) end
    if total <= 0 then return nil end
    local r = rnd() * total
    for i, p in ipairs(list) do
      local w = eff(p, useCap)
      if w > 0 then
        r = r - w
        if r <= 0 then return i end
      end
    end
    for i = #list, 1, -1 do   -- float rounding: fall back to the last eligible one
      if eff(list[i], useCap) > 0 then return i end
    end
    return nil
  end

  local function take(p)
    out[#out + 1] = p.entry
    perModel[p.entry.model] = (perModel[p.entry.model] or 0) + 1
    if mem then M.poolNote(mem, p.entry, p.brand) end
  end

  -- pass 1: unique entries under the cap (and the round-robin rules when there is a memory)
  local left = {}
  for i, p in ipairs(pool) do left[i] = p end
  while #out < amount do
    local i = pickFrom(left, true)
    if not i then break end
    take(table.remove(left, i))
  end
  -- pass 2: still short -> ignore the cap (small pools), still unique and weighted
  while #out < amount do
    local i = pickFrom(left, false)
    if not i then break end
    take(table.remove(left, i))
    relaxed = relaxed + 1
  end
  -- pass 3: pool exhausted -> repeat weighted picks (never leave the game with a group that is too short)
  local guard = 0
  while #out < amount and guard < amount * 4 do
    guard = guard + 1
    local i = pickFrom(pool, false)
    if not i then break end
    take(pool[i])
    relaxed = relaxed + 1
  end
  return out, relaxed
end

-- ONE replacement for a car that is respawning. `current` = {model, config} (never picked again; never its model unless nothing else exists).
-- census = {brand = number of cars of that brand on the street now} (without this car). Stages, relaxing step by step:
--   1 all rules   2 no brand caps   3 no avoid-last window but not the model picked last   4 any other model   5 same model, other config.
-- Returns the entry and the stage, or nil (nothing usable: leave the car alone). The pick is remembered in the memory.
function M.pickOne(mem, candidates, infoOf, ctx, cfg, rnd, current, census)
  rnd = rnd or math.random
  current = current or {}
  candidates = M.dropExcluded(candidates, cfg and cfg.excludeWords)
  local plan = M.rarityPlan(type(candidates) == "table" and candidates or {}, infoOf, ctx, cfg)
  local function rf(e) return plan and plan(e) * 1000 or 1 end
  local groups, order = {}, {}
  for _, e in ipairs(type(candidates) == "table" and candidates or {}) do
    if type(e) == "table" and e.model and e.config and not (e.model == current.model and e.config == current.config) then
      local g = groups[e.model]
      if not g then
        local info = infoOf and infoOf(e) or {}
        g = {model = e.model, brand = info.brand, w = M.weight(e, info, ctx, cfg), entries = {}, pop = 0}
        groups[e.model] = g
        order[#order + 1] = g
      end
      g.entries[#g.entries + 1] = e
      g.pop = g.pop + M.popFactor(e.pop, cfg.pool.popPower) * rf(e)
      if plan and M.tierOf(e, cfg.rarity) == "common" then g.everyday = true end
    end
  end
  local usable, others = {}, 0
  for _, g in ipairs(order) do
    if g.w > 0 then
      usable[#usable + 1] = g
      if g.model ~= current.model then others = others + 1 end
    end
  end
  if #usable == 0 then return nil end
  local lastModel = mem.history[#mem.history] and mem.history[#mem.history].model
  local pc = cfg.pool

  local function choose(allowed)
    local total, w = 0, {}
    for i, g in ipairs(usable) do
      w[i] = allowed(g) * g.w * (g.pop / #g.entries)
      total = total + w[i]
    end
    if total <= 0 then return nil end
    local r = rnd() * total
    for i, g in ipairs(usable) do
      if w[i] > 0 then
        r = r - w[i]
        if r <= 0 then return g end
      end
    end
    for i = #usable, 1, -1 do if w[i] > 0 then return usable[i] end end
  end

  local function notCurrent(g) return g.model ~= current.model end
  local function pf(g, ...)   -- round-robin factor; models with no everyday config get no "unused for long" boost
    local f = M.poolFactor(mem, g.model, g.brand, cfg, others, ...)
    if plan and f > 1 and not g.everyday then f = 1 end
    return f
  end
  local stages = {
    function(g) return notCurrent(g) and pf(g, census) or 0 end,
    function(g) return notCurrent(g) and pf(g, nil, true) or 0 end,
    function(g) return (notCurrent(g) and g.model ~= lastModel) and 1 or 0 end,
    function(g) return notCurrent(g) and 1 or 0 end,
    function(g) return 1 end,
  }
  for stage, allowed in ipairs(stages) do
    local g = choose(allowed)
    if g then
      -- a config of that model other than the one it had last time (and than this car's own)
      local fresh = {}
      for _, e in ipairs(g.entries) do
        if e.config ~= mem.lastConfig[g.model] and e.config ~= current.config then fresh[#fresh + 1] = e end
      end
      local list = #fresh > 0 and fresh or g.entries
      local entry
      local total = 0
      if plan then for _, e in ipairs(list) do total = total + rf(e) end end
      if total > 0 then
        local r = rnd() * total
        for _, e in ipairs(list) do entry = e r = r - rf(e) if r <= 0 then break end end
      else
        entry = list[math.min(#list, math.floor(rnd() * #list) + 1)]
      end
      M.poolNote(mem, entry, g.brand)
      return entry, stage
    end
  end
  return nil
end

-- Is this config name an undercover / unmarked one (any of the words in its name)?
function M.isUndercover(configName, words)
  local name = string.lower(tostring(configName or ""))
  for _, w in ipairs(words or {}) do
    if name:find(w, 1, true) then return true end
  end
  return false
end

-- Picks `amount` police entries from `candidates` ({model, config}). pc = sanitized police settings. Police groups are tiny (1 to 3 cars),
-- so the undercover cap is rounded at random: amount x share = 0.2 cars means 1 undercover car in 20 % of the groups, 10 % of the cars on average.
-- Stages: unique + both caps, unique without the model cap, repeats, and only if there is no plain car at all, undercover cars without a cap.
-- A model with weight 0 is never used. Returns the group and how many cars came from a relaxed stage.
function M.selectPolice(candidates, amount, pc, rnd)
  rnd = rnd or math.random
  amount = math.floor(tonumber(amount) or 0)
  local out, relaxed = {}, 0
  if amount < 1 or type(candidates) ~= "table" then return out, 0 end
  local pool, seen = {}, {}
  for _, e in ipairs(candidates) do
    if type(e) == "table" and e.model and e.config and not seen[keyOf(e)] then
      seen[keyOf(e)] = true
      local w = pc.models[e.model]
      if w == nil then w = 1 end
      if w > 0 then pool[#pool + 1] = {entry = e, w = w, uc = M.isUndercover(e.config, pc.undercoverWords)} end
    end
  end
  if #pool == 0 then return out, 0 end
  local x = amount * pc.undercoverShare
  local ucCap = math.floor(x) + ((rnd() < x - math.floor(x)) and 1 or 0)
  local modelCap = math.max(1, math.ceil(amount * pc.maxShare))
  local perModel, ucCount = {}, 0
  local function stage(list, useModelCap, useUcCap, unique)
    while #out < amount do
      local total = 0
      for _, p in ipairs(list) do
        if not (useModelCap and (perModel[p.entry.model] or 0) >= modelCap) and not (useUcCap and p.uc and ucCount >= ucCap) then total = total + p.w end
      end
      if total <= 0 then return end
      local r, chosen = rnd() * total, nil
      for i, p in ipairs(list) do
        if not (useModelCap and (perModel[p.entry.model] or 0) >= modelCap) and not (useUcCap and p.uc and ucCount >= ucCap) then
          chosen = i
          r = r - p.w
          if r <= 0 then break end
        end
      end
      local p = unique and table.remove(list, chosen) or list[chosen]
      out[#out + 1] = p.entry
      perModel[p.entry.model] = (perModel[p.entry.model] or 0) + 1
      if p.uc then ucCount = ucCount + 1 end
      if not (useModelCap and useUcCap and unique) then relaxed = relaxed + 1 end
    end
  end
  local left = {}
  for i, p in ipairs(pool) do left[i] = p end
  stage(left, true, true, true)
  stage(left, false, true, true)
  stage(pool, false, true, false)
  stage(pool, false, false, false)
  return out, relaxed
end

function M.distinctModels(group)
  local seen, n = {}, 0
  for _, e in ipairs(group or {}) do
    if e.model and not seen[e.model] then seen[e.model] = true n = n + 1 end
  end
  return n
end

-- Parked cars (config trafficVariety.parked) ----------------------------------------------------------------------------------------------------
-- Words that keep a car out of a parked group even when RLS's parked filter lets it through (the filter only reserves police).
M.PARKED_BLOCK_WORDS = {"police", "taxi"}

function M.dropBlocked(list, words)
  local out = {}
  for _, e in ipairs(list or {}) do
    if not M.isExcluded({model = e.model, config = e.config, ctype = e.ctype}, words or M.PARKED_BLOCK_WORDS) then out[#out + 1] = e end
  end
  return out
end

-- Shows a share of the picked FULL cars as the cheap stand-in of the same model, when one fits (standFor(entry) -> stand-in config name or nil).
-- The car you get when you steal it is the picked config, so every proxy is listed in `intended` = {stand, model, config}.
-- Entries that are stand-ins already are left alone. Returns the new group and the intended list.
function M.proxyParked(group, standFor, share, rnd)
  rnd = rnd or math.random
  local out, intended = {}, {}
  share = tonumber(share) or 0
  for _, e in ipairs(group or {}) do
    local stand = share > 0 and e.model ~= "simple_traffic" and standFor and standFor(e) or nil
    if stand and rnd() < share then
      out[#out + 1] = {model = "simple_traffic", config = stand}
      intended[#intended + 1] = {stand = stand, model = e.model, config = e.config}
    else
      out[#out + 1] = e
    end
  end
  return out, intended
end

return M
