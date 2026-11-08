-- RLS-Career-MP client: what a stolen parked car is worth (pure functions, the game calls come in through `ctx`).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Parked cars are simple_traffic stand-ins whose config is named like `sedan_pre_s_parked`: the real config is not there, so
-- the old code read no price (0) and the fence paid its floor. Order tried here (the first number wins, `source` says which):
--   1. the real config (stand-in name without _parked, then fuzzy prefix) -> RLS valuation of a used car of that age and mileage
--   2. no config found -> the model's typical config (median catalog value), same valuation
--   3. RLS getQuickVehicleValue on the catalog value
--   4. our spec estimator (lib/modPrice.lua) when the game gave no price at all
--   5. the plain catalog value, else 0 (the server then uses fence.minValue)
-- ctx = {valuation = fn(opts) -> record|nil, quick = fn(base, year, mileage) -> n|nil, estimate = fn(info) -> n|nil, year = this year}

local M = {}

M.DEFAULT_AGE = 12          -- years, when the config has no Years
M.KM_PER_YEAR = 12000       -- typical use of a used car
M.MAX_KM = 300000
M.MAX_VALUE = 10000000      -- the client never sends more than this (the server caps lower, fence.maxValue)
local SKIP = {"police", "taxi", "junk", "wreck", "derby", "race", "drag", "crawler", "rally"}

local function num(v) v = tonumber(v) return (v and v == v and v > -math.huge and v < math.huge) and v or nil end

-- "sedan_pre_s_parked" -> "sedan_pre_s"
function M.strip(key)
  if type(key) ~= "string" then return nil end
  local prev
  repeat
    prev = key
    key = key:gsub("_parked$", ""):gsub("_traffic$", ""):gsub("_simple$", "")
  until key == prev
  return key ~= "" and key or nil
end

-- Years of a config entry as {min, max} or nil.
function M.years(info)
  if type(info) ~= "table" then return nil end
  local y = info.Years or (type(info.aggregates) == "table" and info.aggregates.Years)
  local lo, hi = type(y) == "table" and num(y.min), type(y) == "table" and num(y.max)
  if not lo then return nil end
  hi = hi or lo
  if lo > hi then lo, hi = hi, lo end
  return {min = lo, max = hi}
end

-- The entry of `list` (array of config infos with .key) for the stand-in names `names`. Returns entry, how or nil.
-- how = "exact" | "prefix". Prefix: one name starts with the other, the longest common one wins (ties: shorter key).
function M.match(list, names)
  local want = {}
  for _, n in ipairs(names or {}) do
    local s = M.strip(n)
    if s then want[#want + 1] = s end
  end
  local best, bestLen, bestKeyLen
  for _, e in ipairs(list or {}) do
    local k = type(e) == "table" and type(e.key) == "string" and e.key
    if k then
      for _, w in ipairs(want) do
        if k == w then return e, "exact" end
        local short = math.min(#k, #w)
        if short >= 4 and k:sub(1, short) == w:sub(1, short) and (not best or short > bestLen or (short == bestLen and #k < bestKeyLen)) then
          best, bestLen, bestKeyLen = e, short, #k
        end
      end
    end
  end
  if best then return best, "prefix" end
  return nil
end

-- The model's typical config: the median of the catalog values, skipping police, taxi, junk and race configs.
function M.typical(list)
  local pool = {}
  for _, e in ipairs(list or {}) do
    local v = type(e) == "table" and num(e.Value)
    if v and v > 0 then
      local text = (tostring(e.key) .. " " .. tostring(e["Config Type"] or "")):lower()
      local skip = false
      for _, w in ipairs(SKIP) do if text:find(w, 1, true) then skip = true break end end
      if not skip then pool[#pool + 1] = e end
    end
  end
  if #pool == 0 then return nil end
  table.sort(pool, function(a, b) if a.Value ~= b.Value then return a.Value < b.Value end return tostring(a.key) < tostring(b.key) end)
  return pool[math.floor((#pool + 1) / 2)]
end

function M.mileageMeters(age)
  return math.min(M.MAX_KM, math.max(20000, age * M.KM_PER_YEAR)) * 1000
end

-- model = real model name; names = stand-in config names to try; list = config infos of that model.
-- Returns {value, source, configKey, matched ("exact"|"prefix"|"typical"|nil), year (first year, for the theft tier), age, mileage}.
function M.resolve(model, names, list, ctx)
  ctx = ctx or {}
  local entry, how = M.match(list, names)
  if not entry then entry, how = M.typical(list), "typical" end
  local out = {model = model, configKey = entry and entry.key, matched = entry and how or nil, source = "none", value = 0}
  local yr = M.years(entry)
  local now = num(ctx.year) or 2026
  local midYear = yr and math.floor((yr.min + yr.max) / 2) or nil
  out.year = yr and yr.min or nil
  out.age = midYear and math.max(0, now - midYear) or M.DEFAULT_AGE
  out.mileage = M.mileageMeters(out.age)
  local base = entry and num(entry.Value)
  local function done(v, src)
    v = math.floor(v + 0.5)
    if v > 0 then out.value, out.source = math.min(v, M.MAX_VALUE), src end
    return out
  end
  if entry and ctx.valuation then
    local ok, rec = pcall(ctx.valuation, {modelName = model, configKey = entry.key, configInfo = entry, catalogBaseValue = base,
      age = out.age, mileageMeters = out.mileage, logContext = "rlsmpStolen", applyVehicleBuyMarket = false})
    local v = ok and type(rec) == "table" and num(rec.bookValue)
    if v and v > 0 then return done(v, how == "typical" and "rls valuation (typical config)" or "rls valuation") end
  end
  if base and base > 0 and ctx.quick then
    local ok, v = pcall(ctx.quick, base, midYear or (now - M.DEFAULT_AGE), out.mileage)
    v = ok and num(v)
    if v and v > 0 then return done(v, "rls quick value") end
  end
  if entry and ctx.estimate then
    local ok, v = pcall(ctx.estimate, entry)
    v = ok and num(v)
    if v and v > 0 then return done(v, "spec estimate") end
  end
  if base and base > 0 then return done(base, "catalog value") end
  return out
end

-- A spec for lib/modPrice.estimate from a config info (same fields RLS and rlsmp/modPrice.lua read).
function M.specOf(info)
  local function n(k)
    local v = num(info[k])
    if v then return v end
    local a = type(info.aggregates) == "table" and info.aggregates[k]
    return type(a) == "table" and (num(a.max) or num(a.min)) or num(a)
  end
  local function s(k)
    local v = info[k] or (type(info.aggregates) == "table" and info.aggregates[k])
    if type(v) == "table" then for key, on in pairs(v) do if on == true then return tostring(key) end end return nil end
    return type(v) == "string" and v or nil
  end
  local y = M.years(info)
  return {hp = n("Power"), weight = n("Weight"), topSpeed = n("Top Speed"), drivetrain = s("Drivetrain"), year = y and y.min or nil,
    words = table.concat({s("Type") or "", s("Body Style") or "", s("Config Type") or "", tostring(info.Name or "")}, " ")}
end

return M
