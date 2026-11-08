-- RLS-Career-MP client: pure logic for the traffic respawn range and delay (no game calls, unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The game recycles a traffic car when its `respawn.finalRadius` is smaller than the car's distance to the player (RLS trafficVehicle.lua).
-- respawnRange multiplies that radius, respawnDistance is a floor for it (a car is recycled only farther than that), respawnDelay keeps a car at least that many seconds after the game placed it. 1 and 0 = the game's original.

local M = {}

M.DEFAULTS = {respawnRange = 1, respawnDistance = 4000, respawnDelay = 0, unjam = {enabled = true, seconds = 120, distance = 400}}

local function num(v, lo, hi, d)
  v = tonumber(v)
  if not v or v ~= v then return d end
  return math.max(lo, math.min(hi, v))
end

function M.sanitize(src)
  src = type(src) == "table" and src or {}
  local u = type(src.unjam) == "table" and src.unjam or {}
  local d = M.DEFAULTS
  return {
    respawnRange = num(src.respawnRange, 0.5, 3, d.respawnRange),
    respawnDistance = num(src.respawnDistance, 0, 6000, d.respawnDistance),
    respawnDelay = num(src.respawnDelay, 0, 600, d.respawnDelay),
    unjam = {enabled = u.enabled ~= false, seconds = num(u.seconds, 30, 1800, d.unjam.seconds), distance = num(u.distance, 150, 5000, d.unjam.distance)},
  }
end

-- The radius the game computed, times the range. 1e5 and more is the game's "not calculated yet" value (1e6): left alone.
function M.scale(radius, range)
  radius = tonumber(radius)
  if not radius or radius >= 1e5 or range == 1 then return radius end
  return radius * range
end

-- The radius we give the game: the scaled one, but never below `distance` meters (0 = no floor).
function M.effective(radius, range, distance)
  radius = tonumber(radius)
  if not radius or radius >= 1e5 then return radius end
  return math.max(M.scale(radius, range), tonumber(distance) or 0)
end

-- Is the car still inside its minimum stay? `placedAt` = clock when its respawn count last changed (nil = unknown: no hold).
function M.holdByDelay(placedAt, now, delay)
  return delay > 0 and placedAt ~= nil and now - placedAt < delay
end

-- A "range:" log text for a change, with the values before and after (nil when nothing changed).
function M.describe(old, new)
  local parts = {}
  local function diff(name, a, b) if a ~= b then parts[#parts + 1] = string.format("%s %s -> %s", name, tostring(a), tostring(b)) end end
  diff("respawnRange", old.respawnRange, new.respawnRange)
  diff("respawnDistance", old.respawnDistance, new.respawnDistance)
  diff("respawnDelay", old.respawnDelay, new.respawnDelay)
  diff("unjam.enabled", old.unjam.enabled, new.unjam.enabled)
  diff("unjam.seconds", old.unjam.seconds, new.unjam.seconds)
  diff("unjam.distance", old.unjam.distance, new.unjam.distance)
  return #parts > 0 and table.concat(parts, ", ") or nil
end

return M
