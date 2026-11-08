-- RLS-Career-MP client: fair dealership prices for modded cars (pure functions, no game calls).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The price is a CATALOG value (what RLS then ages and mileage-adjusts), so there is almost no year term here: RLS already
-- depreciates by age. Anchors (hp -> new price) are tuned by hand: 100 hp about 5k, 300 hp about 38k, 600 hp about 160k, 1000 hp about 1M.
-- Units: Power in hp, Weight in kg, Top Speed in m/s (BeamNG's own config fields). Anything missing or odd -> nil = the game's own price.

local M = {}

M.DEFAULTS = {enabled = true, max = 2000000, min = 800, tolerance = 0.35, sell = true, overrides = {}, models = {}}

local ANCHORS = {{60, 2800}, {100, 5000}, {150, 10500}, {200, 19000}, {300, 38000}, {450, 85000},
  {600, 160000}, {800, 380000}, {1000, 1000000}, {1400, 3000000}}
local HEAVY_KG = 4500

local function num(v) v = tonumber(v) return (v and v == v and v > -math.huge and v < math.huge) and v or nil end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Settings from the server: every field checked again here.
function M.sanitize(data)
  local d, out = type(data) == "table" and data or {}, {overrides = {}, models = {}}
  out.enabled = d.enabled ~= false
  out.sell = d.sell ~= false
  out.min = clamp(num(d.min) or M.DEFAULTS.min, 100, 1000000)
  out.max = clamp(num(d.max) or M.DEFAULTS.max, out.min, 1000000000)
  out.tolerance = clamp(num(d.tolerance) or M.DEFAULTS.tolerance, 0, 5)
  local n = 0
  for k, v in pairs(type(d.overrides) == "table" and d.overrides or {}) do
    v = num(v)
    if type(k) == "string" and #k >= 1 and #k <= 128 and v and v >= out.min and v <= out.max and n < 200 then out.overrides[k] = v n = n + 1 end
  end
  n = 0
  for _, name in ipairs(type(d.models) == "table" and d.models or {}) do
    if type(name) == "string" and #name >= 1 and #name <= 64 and n < 200 then out.models[name] = true n = n + 1 end
  end
  return out
end

-- Log-log interpolation through the anchors (steeper than the last segment is not extrapolated: the cap handles hypercars).
local function priceFromPower(hp)
  local a = ANCHORS
  if hp <= a[1][1] then return a[1][2] * (hp / a[1][1]) end
  for i = 1, #a - 1 do
    local l, r = a[i], a[i + 1]
    if hp <= r[1] then
      local t = (math.log(hp) - math.log(l[1])) / (math.log(r[1]) - math.log(l[1]))
      return math.exp(math.log(l[2]) + t * (math.log(r[2]) - math.log(l[2])))
    end
  end
  local l, r = a[#a - 1], a[#a]
  return r[2] * (hp / r[1]) ^ (math.log(r[2] / l[2]) / math.log(r[1] / l[1]))
end

local function has(hay, ...)
  for _, w in ipairs({...}) do if hay:find(w, 1, true) then return true end end
  return false
end

-- spec = {hp, weight, topSpeed (m/s), drivetrain, year, words (lowercase text of Type, Body Style, Config Type, Name)}.
-- Returns a number, or nil when there is not enough to go on.
function M.estimate(spec)
  if type(spec) ~= "table" then return nil end
  local hp, kg = num(spec.hp), num(spec.weight)
  if not hp or hp < 10 or hp > 20000 then return nil end
  if kg and (kg < 100 or kg > 100000) then kg = nil end
  local words = type(spec.words) == "string" and spec.words:lower() or ""
  local price
  if kg and (kg >= HEAVY_KG or has(words, "semi", "tractor", "bus")) then
    price = 18000 + hp * 90 + kg * 4                       -- trucks and buses: weight matters more than power
  else
    price = priceFromPower(hp)
    if kg then price = price * clamp((clamp(1000 + 2 * hp, 1100, 1800) / kg) ^ 0.4, 0.75, 1.3) end   -- light for its power costs more
    if has(words, "pickup", "truck", "van", "utility") then price = price * 0.85 end
    if has(words, "race", "drag", "rally") then price = price * 0.9 end
  end
  local drive = type(spec.drivetrain) == "string" and spec.drivetrain:lower() or ""
  price = price * (drive == "awd" and 1.05 or drive == "rwd" and 1.02 or drive == "fwd" and 0.96 or 1)
  local top = num(spec.topSpeed)                           -- m/s -> km/h; compare with what this power usually reaches
  if top and top > 5 and top < 200 then
    local expected = 150 + 100 * math.log(hp / 100) / math.log(10)
    price = price * clamp(1 + 0.25 * (top * 3.6 - expected) / expected, 0.9, 1.1)
  end
  local year = num(spec.year)
  if year then price = price * clamp(0.85 + (year - 1950) * 0.003, 0.7, 1) end   -- mild: RLS ages the price itself
  return price
end

-- Decide one price. key = {model, config}; gameValue = the catalog value RLS would use (can be nil).
-- Returns used, estimate, why ("override" | "author" | "estimate" | "game"). used == nil means: leave the game's price alone.
function M.decide(cfg, key, spec, gameValue)
  cfg = cfg or M.DEFAULTS
  local model, config = key and key.model, key and key.config
  local fixed = cfg.overrides and ((model and config and cfg.overrides[model .. "/" .. config]) or (model and cfg.overrides[model]))
  if fixed then return clamp(fixed, cfg.min, cfg.max), nil, "override" end
  local est = M.estimate(spec)
  if not est then return nil, nil, "game" end
  est = clamp(est, cfg.min, cfg.max)
  local author = num(gameValue)
  if author and author > 0 and math.abs(author - est) <= cfg.tolerance * est then return clamp(author, cfg.min, cfg.max), est, "author" end
  return est, est, "estimate"
end

-- Is this model a mod? evidence = {listed = in the server's mod list, official = the game says it ships with BeamNG, path = real file path}.
-- Unknown = not modded (the game's price stays).
function M.isModded(ev)
  if type(ev) ~= "table" or ev.official == true then return false end
  if ev.listed == true then return true end
  local p = type(ev.path) == "string" and ev.path:lower():gsub("\\", "/") or ""
  return p:find("/multiplayer/", 1, true) ~= nil
end

-- Scale a valuation record the game computed from its catalog value to the value we want. Floors that RLS applies are
-- proportional to the catalog value, so a plain ratio keeps its age and mileage curve. Returns the same table.
function M.rescale(valuation, used, minPrice)
  local base = type(valuation) == "table" and num(valuation.catalogValue)
  if not base or base <= 0 or not num(used) or used <= 0 then return valuation end
  local r = used / base
  for _, field in ipairs({"bookValue", "preDamageValue", "partsValueFloor"}) do
    if num(valuation[field]) then valuation[field] = valuation[field] * r end
  end
  if num(valuation.bookValue) and minPrice then valuation.bookValue = math.max(valuation.bookValue, minPrice) end
  valuation.catalogValue = used
  valuation.catalogSource = "modPrice"
  return valuation
end

return M
