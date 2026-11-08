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
  applyToTraffic = true,
  applyToParked = true,
  zoneSpeedLimits = {city = 17, main = 27},   -- m/s: slower than city = "city", slower than main = "main", else "highway"
  swap = {enabled = false, live = false, perMinute = 2, hiddenSeconds = 5, checkSeconds = 2, minRatio = 1.5, maxFailures = 3},
  -- Police groups: weight per model (Bastion low), at most `undercoverShare` of the cars undercover, at most `maxShare` of a group one model.
  police = {enabled = true, models = {bastion = 0.3}, undercoverShare = 0.1, maxShare = 0.4, undercoverWords = {"undercover", "unmarked"}},
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
    applyToTraffic = src.applyToTraffic ~= false,
    applyToParked = src.applyToParked ~= false,
    zoneSpeedLimits = {city = city, main = main},
    swap = swapSettings(src.swap),
    police = policeSettings(src.police),
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

local function keyOf(entry) return tostring(entry.model) .. "/" .. tostring(entry.config) end

-- Picks `amount` entries from `candidates` (a list of {model, config, ...}).
--   infoOf(entry) -> {type =, mod =}   rnd() -> [0,1)
-- Returns the group (a list) and how many entries came from relaxing the per-model cap or from repeats.
function M.select(candidates, amount, infoOf, ctx, cfg, rnd)
  rnd = rnd or math.random
  amount = math.floor(tonumber(amount) or 0)
  local out, relaxed = {}, 0
  if amount < 1 or type(candidates) ~= "table" or #candidates == 0 then return out, 0 end

  -- unique candidates with their weights
  local pool, seen = {}, {}
  for _, entry in ipairs(candidates) do
    if type(entry) == "table" and entry.model then
      local key = keyOf(entry)
      if not seen[key] then
        seen[key] = true
        pool[#pool + 1] = {entry = entry, w = M.weight(entry, infoOf and infoOf(entry), ctx, cfg)}
      end
    end
  end
  if #pool == 0 then return out, 0 end

  local cap = math.max(1, math.ceil(amount * cfg.maxShare))
  local perModel = {}

  local function pickFrom(list, useCap)
    local total = 0
    for _, p in ipairs(list) do
      if p.w > 0 and (not useCap or (perModel[p.entry.model] or 0) < cap) then total = total + p.w end
    end
    if total <= 0 then return nil end
    local r = rnd() * total
    for i, p in ipairs(list) do
      if p.w > 0 and (not useCap or (perModel[p.entry.model] or 0) < cap) then
        r = r - p.w
        if r <= 0 then return i end
      end
    end
    for i = #list, 1, -1 do   -- float rounding: fall back to the last eligible one
      local p = list[i]
      if p.w > 0 and (not useCap or (perModel[p.entry.model] or 0) < cap) then return i end
    end
    return nil
  end

  -- pass 1: unique entries under the cap
  local left = {}
  for i, p in ipairs(pool) do left[i] = p end
  while #out < amount do
    local i = pickFrom(left, true)
    if not i then break end
    local p = table.remove(left, i)
    out[#out + 1] = p.entry
    perModel[p.entry.model] = (perModel[p.entry.model] or 0) + 1
  end
  -- pass 2: still short -> ignore the cap (small pools), still unique and weighted
  while #out < amount do
    local i = pickFrom(left, false)
    if not i then break end
    local p = table.remove(left, i)
    out[#out + 1] = p.entry
    perModel[p.entry.model] = (perModel[p.entry.model] or 0) + 1
    relaxed = relaxed + 1
  end
  -- pass 3: pool exhausted -> repeat weighted picks (never leave the game with a group that is too short)
  local guard = 0
  while #out < amount and guard < amount * 4 do
    guard = guard + 1
    local i = pickFrom(pool, false)
    if not i then break end
    out[#out + 1] = pool[i].entry
    relaxed = relaxed + 1
  end
  return out, relaxed
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

return M
