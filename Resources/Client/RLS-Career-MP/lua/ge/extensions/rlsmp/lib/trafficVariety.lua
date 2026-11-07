-- RLS-Career-MP client: pure logic for "traffic variety" (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A group is a list of {model = ..., config = ...} entries that RLS/the game spawns as traffic or parked cars.
-- We take a bigger pool of candidates and pick the group from it with weights:
--   weight = typeWeights[Type] x zones[zone][Type] x (night or day)[Type] x (mods[model] for a modded model)
-- `Type` is the model's own "Type" in the game's model list. Missing weights count as 1, 0 means "never".
-- No single model may fill more than `maxShare` of a group, so groups are varied even with all weights at 1.

local M = {}

M.DEFAULTS = {
  enabled = true,
  typeWeights = {},
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

-- entry = {model, config}; info = {type = "Car" | nil, mod = bool}; ctx = {zone = "city" | nil, night = bool}.
function M.weight(entry, info, ctx, cfg)
  info = info or {}
  ctx = ctx or {}
  local t = info.type
  local w = 1
  if t then
    w = w * (cfg.typeWeights[t] or 1)
    local zone = ctx.zone and cfg.zones[ctx.zone]
    if zone then w = w * (zone[t] or 1) end
    local phase = ctx.night and cfg.night or cfg.day
    w = w * (phase[t] or 1)
  end
  if info.mod then w = w * (cfg.mods[entry.model] or 1) end
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

function M.distinctModels(group)
  local seen, n = {}, 0
  for _, e in ipairs(group or {}) do
    if e.model and not seen[e.model] then seen[e.model] = true n = n + 1 end
  end
  return n
end

return M
