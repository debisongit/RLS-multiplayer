-- RLS-Career-MP client: how many AI cops the map should have and where (pure, no game calls; see rlsmp/policeRespawn.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Owner: "depending on the area and time of day the amount can go up to MAX 3, but not 3 in one area: 1 per area".
--   * target(cfg, zone, night): how many cops the area type and the time of day ask for. zone = the road class the traffic variety computes
--     ("city", "main", "highway"; nil = unknown / rural, the "other" row), night = true/false.
--   * the number never goes above cfg.maxCops (default 3, hard) or cfg.copCount (the top-up switch, 0 = the game's own number).
--   * area = a square cell of cfg.areaSize metres (default 1500). At most ONE cop per cell.
--   * canAdd(cfg, cops, zone, night, pos): may one more cop be built at `pos` now? cops = positions {x, y} of the AI police units out.
-- This only decides HOW MANY and in which CELL. Where exactly the car is placed (far from the player, other street) is decided by the placement code;
-- it passes its spot as `pos` (until then policeRespawn passes the player's position, because the car is built behind the player).

local M = {}

M.DEFAULTS = {
  maxCops = 3,
  areaSize = 1500,
  -- cops asked for by area type and time of day: city 1 by day and 2 at night, main road 1, highway 1, residential / rural 0 by day and 1 at night
  targets = {
    city = {day = 1, night = 2},
    main = {day = 1, night = 1},
    highway = {day = 1, night = 1},
    other = {day = 0, night = 1},
  },
}
M.ZONES = {"city", "main", "highway", "other"}

local function number(v, d, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v then return d end
  return math.max(lo, math.min(hi, v))
end

-- Settings from the server's table (missing or bad values fall back to the defaults).
function M.clean(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS
  local out = {maxCops = math.floor(number(src.maxCops, d.maxCops, 0, 6)), areaSize = number(src.areaSize, d.areaSize, 100, 20000), targets = {}}
  local t = type(src.copTargets) == "table" and src.copTargets or (type(src.targets) == "table" and src.targets or {})
  for _, zone in ipairs(M.ZONES) do
    local row, drow = type(t[zone]) == "table" and t[zone] or {}, d.targets[zone]
    out.targets[zone] = {day = math.floor(number(row.day, drow.day, 0, 6)), night = math.floor(number(row.night, drow.night, 0, 6))}
  end
  return out
end

function M.zoneKey(zone)
  if zone == "city" or zone == "main" or zone == "highway" then return zone end
  return "other"
end

-- Cops the area type and time ask for (before the caps).
function M.target(cfg, zone, night)
  cfg = cfg or M.DEFAULTS
  local row = (cfg.targets or M.DEFAULTS.targets)[M.zoneKey(zone)] or M.DEFAULTS.targets.other
  return (night and row.night or row.day) or 0
end

-- The cell a position is in: two integers, and a text key.
function M.cellOf(pos, size)
  if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then return nil end
  size = number(size, M.DEFAULTS.areaSize, 100, 20000)
  local cx, cy = math.floor(pos.x / size), math.floor(pos.y / size)
  return cx, cy, cx .. ":" .. cy
end

-- Is no cop in the cell of `pos` yet?
function M.cellFree(cfg, cops, pos)
  local size = cfg and cfg.areaSize or M.DEFAULTS.areaSize
  local _, _, key = M.cellOf(pos, size)
  if not key then return false end
  for _, c in ipairs(cops or {}) do
    local _, _, k = M.cellOf(c, size)
    if k == key then return false end
  end
  return true
end

-- The most cops allowed right now: the area/time target, never above maxCops or copCount (the top-up switch; copCount nil = no switch).
function M.limit(cfg, zone, night, copCount)
  cfg = cfg or M.DEFAULTS
  local n = math.min(M.target(cfg, zone, night), cfg.maxCops or M.DEFAULTS.maxCops)
  if copCount then n = math.min(n, copCount) end
  return n
end

-- May one more cop be built at `pos`? Returns true, or false and the reason. zone == false means "no area information at all": only the caps apply.
function M.canAdd(cfg, cops, zone, night, pos, copCount)
  cfg = cfg or M.DEFAULTS
  local limit
  if zone == false then
    limit = math.min(cfg.maxCops or M.DEFAULTS.maxCops, copCount or math.huge)
  else
    limit = M.limit(cfg, zone, night, copCount)
  end
  local have = #(cops or {})
  if have >= limit then
    return false, string.format("%d cops out, %s asks for %s", have, zone == false and "the cap" or (M.zoneKey(zone) .. (night and " at night" or " by day")), tostring(limit))
  end
  if not M.cellFree(cfg, cops, pos) then
    local _, _, key = M.cellOf(pos, cfg.areaSize)
    return false, "a cop is already in area " .. tostring(key)
  end
  return true
end

return M
