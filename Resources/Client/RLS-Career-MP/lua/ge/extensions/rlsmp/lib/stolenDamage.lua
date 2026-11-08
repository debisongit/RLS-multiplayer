-- RLS-Career-MP client: turns RLS's raw vehicle damage number into a 0..1 fraction (pure, no game calls).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- map.objects[id].damage is BeamNG's running damage total of a spawned car (RLS reads it for the racing team lock and for traffic wrecks).
-- RLS locks a racing team car at 1000 and calls a traffic car wrecked at 500, so 1000 counts as 100 percent here (docs/RESEARCH_STOLEN_DAMAGE.md).
local M = {}

M.SCALE = 1000       -- raw damage that counts as fully wrecked
M.REACH = 80         -- metres from the player to the car for a trusted check

-- raw (number or nil) -> 0..1 rounded to 2 decimals; nil when there is no number.
function M.fraction(raw, scale)
  raw = tonumber(raw)
  if raw == nil or raw ~= raw then return nil end
  scale = tonumber(scale) or M.SCALE
  if scale <= 0 then scale = M.SCALE end
  local f = math.max(0, math.min(1, raw / scale))
  return math.floor(f * 100 + 0.5) / 100
end

-- A restored car is a new, unbroken car: it keeps the damage its record had (the larger of live and recorded).
function M.combine(live, recorded)
  live, recorded = tonumber(live), tonumber(recorded)
  if live == nil then return nil end
  return math.max(live, recorded or 0)
end

return M
