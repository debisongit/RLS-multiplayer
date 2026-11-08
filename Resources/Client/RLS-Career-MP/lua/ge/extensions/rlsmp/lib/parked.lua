-- RLS-Career-MP client: pure decision for the parked car amount (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS keeps as many parked cars as the game setting trafficParkingAmount says (0 = automatic, 4 to 20). The server asks for `wanted`
-- (config trafficVariety.parked.amount, 0 = leave the game alone). We raise the setting (never lower the player's own higher value),
-- remember what it was, and put it back when the player leaves. This only decides what to do next:
--   state = {wanted, current (the setting now), noParked, applied (what we set, or nil), released (the wanted value we stopped managing), have, tries}
--   "skip"    the player switched parked cars off (the setting or RLS's noParkedMode): do nothing
--   "idle"    nothing to do
--   "set"     write the setting (and tell RLS)
--   "sync"    the setting is right but there are too few cars: ask RLS to top up
--   "done"    enough cars
--   "restore" the server no longer wants it: give the old value back
--   "forget"  somebody else changed the setting after us: leave it alone and stop managing it
--   "giveup"  too many top-up attempts

local M = {}

M.MAX_TRIES = 12

function M.plan(s)
  local wanted = tonumber(s.wanted) or 0
  local current = tonumber(s.current) or 0
  if s.noParked then return "skip" end
  if wanted <= 0 then return s.applied and "restore" or "idle" end
  if s.applied == nil then
    if current >= wanted or s.released == wanted then return "idle" end
    return "set"
  end
  if current ~= s.applied then return "forget" end
  if wanted ~= s.applied then return "set" end
  if (tonumber(s.have) or 0) >= wanted then return "done" end
  if (tonumber(s.tries) or 0) >= M.MAX_TRIES then return "giveup" end
  return "sync"
end

-- Keeping parked cars NEAR the player (docs/RESEARCH_PARKED_NEAR.md) ------------------------------------------------------------------------------
-- RLS leaves its parked cars where they are once they are far and switched off. We count the near ones and move one far car near the player.
M.MIN_SPOT = 120      -- RLS refuses spots within 120 m of the camera (keepClearRadiusMeters), so nearer spots would only fail
M.SLOW_SPEED = 12     -- m/s: above this the player drives past; RLS places cars ahead by itself

local function dist2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
M.dist2 = dist2

-- How many parked cars are wanted near the player.
function M.nearWanted(cfg, night)
  local day, ni = tonumber(cfg.nearCount) or 0, tonumber(cfg.nearNightCount) or 0
  if day <= 0 then return 0 end
  return (night and ni > day) and ni or day
end

-- cars = list of {id, pos = {x, y}, busy}; me = the player {x, y}; others = positions of the other players.
-- Returns {id, from (m), near, far} when one car should move, else nil + a word (disabled | enough | none) + near + far.
function M.pickMove(cars, me, others, want, nearRadius, farRadius)
  if want <= 0 then return nil, "disabled" end
  local near, far, best, bestD = 0, 0, nil, -1
  for _, c in ipairs(cars) do
    local d = dist2(c.pos, me)
    if d <= nearRadius then near = near + 1 end
    local anyD = d
    for _, o in ipairs(others or {}) do anyD = math.min(anyD, dist2(c.pos, o)) end
    if anyD > farRadius then
      far = far + 1
      if not c.busy and d > bestD then best, bestD = c, d end
    end
  end
  if near >= want then return nil, "enough", near, far end
  if not best then return nil, "none", near, far end
  return {id = best.id, from = bestD, near = near, far = far}
end

-- Up to n random entries of a spot list (the entries stay as they are).
function M.sample(entries, n, rand)
  rand = rand or math.random
  local copy, out = {}, {}
  for i, e in ipairs(entries or {}) do copy[i] = e end
  for _ = 1, math.min(n, #copy) do
    local i = rand(#copy)
    out[#out + 1] = table.remove(copy, i)
  end
  return out
end

-- True when the spot is at least `gap` m from every position in `taken` (no two parked cars on one corner).
function M.spaced(pos, taken, gap)
  for _, t in ipairs(taken) do if dist2(pos, t) < gap then return false end end
  return true
end

return M
