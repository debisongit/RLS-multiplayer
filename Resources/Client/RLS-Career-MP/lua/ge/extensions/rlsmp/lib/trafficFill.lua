-- RLS-Career-MP client: pure logic for filling the traffic up to the server's minimum (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- gameplay_traffic.setActiveAmount only says how many cars may be ACTIVE; it never creates a car. The game builds its traffic cars once, at
-- traffic setup (a real log: activeAmount 4, 5 cars in traffic). So when the server's minimum is higher than the cars that exist, the missing
-- cars are built one at a time (rlsmp/trafficFill.lua, through the async one-car group spawn of rlsmp/trafficSwap.lua).

local M = {}

M.EVERY = 4            -- seconds between two spawns
M.MARGIN = 3           -- stay this many cars below BeamMP's per-player limit
M.UNKNOWN_MAX = 60     -- per-player limit assumed when the server did not say
M.MAX_FAILURES = 3     -- failed spawns, then no more spawning
M.GRACE = 120          -- seconds a car we added is left alone by our own recycling / re-roll / swap

-- The number of cars wanted: the quota is a ceiling, the minimum is the wish. 0 = nothing to do.
function M.want(quota, minAmount)
  quota, minAmount = tonumber(quota), tonumber(minAmount)
  if not quota or not minAmount or quota < 1 or minAmount < 1 then return 0 end
  return math.floor(math.min(quota, minAmount))
end

-- Size of the traffic group the game asks for: lifted to the wish only when no traffic car exists yet and the group is not tiny (the setup group,
-- not a refill or a single job car).
function M.groupSize(asked, wish, existing)
  asked = tonumber(asked) or 0
  if (existing or 0) > 0 or asked < 2 or (tonumber(wish) or 0) <= asked then return asked end
  return math.floor(wish)
end

-- s = {have, want, pending, own, maxCars, now, last, failures}. Returns "spawn", or "wait" and a reason:
-- done, pending, failures (stopped), gap (too soon), maxCars (refused: near BeamMP's per-player limit).
function M.decide(s)
  if (s.failures or 0) >= M.MAX_FAILURES then return "wait", "failures" end
  if s.have + (s.pending or 0) >= s.want then return "wait", "done" end
  if (s.pending or 0) > 0 then return "wait", "pending" end
  if s.now - (s.last or -1e9) < M.EVERY then return "wait", "gap" end
  local limit = tonumber(s.maxCars) or 0
  if limit < 1 then limit = M.UNKNOWN_MAX end
  if (s.own or 0) >= limit - M.MARGIN then return "wait", "maxCars" end
  return "spawn"
end

-- born = {id = time added}. True while the car is younger than GRACE.
function M.isNew(born, id, now)
  local at = born[id]
  return at ~= nil and now - at < M.GRACE
end

return M
