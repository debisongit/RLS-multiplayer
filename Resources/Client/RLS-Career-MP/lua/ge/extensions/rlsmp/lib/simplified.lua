-- RLS-Career-MP client: pure decisions for "simplified" cars (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- BeamNG's "simple_traffic" is a cheap stand-in model: the file name of its config holds the real model ("legran_sedan_pre_s_parked.pc"
-- stands for a legran; RLS reads it the same way, trafficVehicle.lua). We keep the cheap stand-ins where nobody looks and use real cars
-- where it matters. Settings (server, trafficVariety.simplified): enabled, parked, traffic, nearRadius, perMinute, checkSeconds.
--   * parked cars are stand-ins already; a stand-in at a STEALABLE spot (same pick as theft) becomes a real car once a player is within
--     nearRadius (and the view gate allows it); a car we upgraded goes back to a stand-in when its spot is no longer stealable and
--     every player is far away (1.5 x nearRadius),
--   * moving traffic: the respawn re-roll picks a stand-in when the car is farther than nearRadius from EVERY player, else a real car;
--     a stand-in that comes within nearRadius is upgraded (when the view gate allows it). Never the other way round while driving.

local M = {}

M.MODEL = "simple_traffic"
M.DEFAULTS = {enabled = false, parked = true, traffic = false, nearRadius = 250, perMinute = 4, checkSeconds = 2}
M.BACK_FACTOR = 1.5   -- a parked car goes back to a stand-in only beyond nearRadius x this

local function number(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- nearRadius is never below the view gate's 120 m (a car closer than that is never touched).
function M.sanitize(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS
  return {
    enabled = src.enabled == true,
    parked = src.parked ~= false,
    traffic = src.traffic == true,
    nearRadius = number(src.nearRadius, d.nearRadius, 120, 1000),
    perMinute = math.floor(number(src.perMinute, d.perMinute, 0, 12)),
    checkSeconds = number(src.checkSeconds, d.checkSeconds, 1, 30),
  }
end

function M.isSimple(model) return model == M.MODEL end

-- "legran_sedan_pre_s_parked" -> "legran", "parked"; "legran_sedan" -> "legran", "traffic". nil for a name without a model part.
function M.parseConfig(name)
  if type(name) ~= "string" then return nil end
  local real = name:match("^(%w+)")
  if not real or real == "" then return nil end
  return real, (name:match("_parked$") and "parked" or "traffic")
end

-- The real model behind a stand-in's config file ("vehicles/simple_traffic/legran_sedan.pc" or "legran_sedan"). nil when unreadable.
function M.realOf(partConfigOrName)
  if type(partConfigOrName) ~= "string" then return nil end
  local key = partConfigOrName:match("([^/\\]+)%.pc$") or partConfigOrName
  return (M.parseConfig(key))
end

-- names = list of config names of the simple_traffic model; ok(name) -> true when the config may be used for moving traffic (nil = all).
-- Returns map[real] = {traffic = {names}, parked = {names}} and the counts.
function M.buildMap(names, ok)
  local map, total, traffic, parked = {}, 0, 0, 0
  for _, name in ipairs(names or {}) do
    local real, kind = M.parseConfig(name)
    if real then
      total = total + 1
      local e = map[real]
      if not e then e = {traffic = {}, parked = {}} map[real] = e end
      if kind == "parked" then
        e.parked[#e.parked + 1] = name
        parked = parked + 1
      elseif ok == nil or ok(name) then
        e.traffic[#e.traffic + 1] = name
        traffic = traffic + 1
      end
    end
  end
  return map, {total = total, traffic = traffic, parked = parked}
end

-- A stand-in config of `real` of the given kind ("traffic" | "parked"), or nil when there is none.
function M.pickSimple(map, real, kind, rnd)
  local e = map and map[real]
  local list = e and e[kind]
  if not list or #list == 0 then return nil end
  return list[math.floor((rnd or math.random)() * #list) % #list + 1]
end

-- A parked stand-in of `real` whose name shares a word (3+ letters, e.g. "sedan", "wagon") with the real config key, so the stand-in is
-- at least the same body style. Best match wins, ties are random. nil when none fits (the car then stays a full car). A GUESS: the stand-in
-- names are not documented anywhere we could read.
local function words(s)
  local out = {}
  for w in tostring(s or ""):lower():gmatch("%a%a%a+") do out[w] = true end
  return out
end
function M.pickSimpleFor(map, real, key, rnd)
  local e = map and map[real]
  local list = e and e.parked
  if not list or #list == 0 then return nil end
  local want = words(key)
  local best, bestScore = {}, 0
  for _, name in ipairs(list) do
    local score = 0
    for w in pairs(words((name:gsub("^%w+_", ""):gsub("_parked$", "")))) do if want[w] then score = score + 1 end end
    if score > bestScore then best, bestScore = {name}, score
    elseif score == bestScore and score > 0 then best[#best + 1] = name end
  end
  if bestScore < 1 then return nil end
  return best[math.floor((rnd or math.random)() * #best) % #best + 1]
end

function M.hasTraffic(map)
  for _, e in pairs(map or {}) do if #e.traffic > 0 then return true end end
  return false
end

-- Parked car. s = {simple, stealable, dist (to the nearest player), converted (a stand-in we upgraded)}. "toFull" | "toSimple" | nil.
function M.parkedWant(cfg, s)
  if not (cfg and cfg.enabled and cfg.parked and s and s.dist) then return nil end
  if s.simple and s.stealable and s.dist <= cfg.nearRadius then return "toFull" end
  if not s.simple and s.converted and not s.stealable and s.dist > cfg.nearRadius * M.BACK_FACTOR then return "toSimple" end
  return nil
end

-- Moving traffic that already exists. s = {simple, dist}. Only upgrades; a real car is never made a stand-in while it drives.
function M.trafficWant(cfg, s)
  if not (cfg and cfg.enabled and cfg.traffic and s and s.dist) then return nil end
  if s.simple and s.dist <= cfg.nearRadius then return "toFull" end
  return nil
end

-- At a respawn re-roll: "simple" only when stand-ins exist for traffic and the car is beyond nearRadius from every player.
function M.respawnKind(cfg, dist, haveSimple)
  if cfg and cfg.enabled and cfg.traffic and haveSimple and dist and dist > cfg.nearRadius then return "simple" end
  return "full"
end

-- Distance to the nearest of `points` ({x,y,z} list); math.huge when there are none.
function M.nearest(pos, points)
  if not pos then return nil end
  local best = math.huge
  for _, p in ipairs(points or {}) do
    local dx, dy, dz = (pos.x or 0) - (p.x or 0), (pos.y or 0) - (p.y or 0), (pos.z or 0) - (p.z or 0)
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < best then best = d end
  end
  return best
end

-- Parked group offered by the game: only stand-ins when there are at least `want` of them, else the list as it is.
function M.preferSimple(entries, want)
  local only = {}
  for _, e in ipairs(entries or {}) do
    if type(e) == "table" and M.isSimple(e.model) then only[#only + 1] = e end
  end
  if #only >= (tonumber(want) or 1) and #only > 0 then return only, #only end
  return entries, #only
end

-- Counts of stand-ins and real cars in a list of model names.
function M.census(models)
  local simple, full = 0, 0
  for _, m in ipairs(models or {}) do
    if M.isSimple(m) then simple = simple + 1 else full = full + 1 end
  end
  return simple, full
end

return M
