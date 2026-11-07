-- RLS-Career-MP: finds traffic cars that are stuck (not moving for a long time) and picks ONE at a time to recycle.
-- Plain module (no game calls) so it can be unit tested. SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.STUCK_SECONDS = 30    -- standing still this long counts as stuck (red lights are shorter)
M.GAP_SECONDS = 5       -- at most one recycled car per this many seconds ("one by one")
M.MOVE_METRES = 2       -- moving farther than this from the anchor spot resets the timer
M.SLOW = 0.5            -- m/s

function M.new() return {cars = {}, lastRecycle = -math.huge} end

-- Feed every active candidate car once per check. Returns how long it has been stuck (seconds).
function M.seen(t, id, x, y, speed, now)
  local c = t.cars[id]
  if not c then c = {x = x, y = y, since = now} t.cars[id] = c end
  local dx, dy = x - c.x, y - c.y
  if (speed or 0) > M.SLOW or dx * dx + dy * dy > M.MOVE_METRES * M.MOVE_METRES then
    c.x, c.y, c.since = x, y, now
  end
  c.seenAt = now
  return now - c.since
end

-- Forget cars that were not fed in this round.
function M.sweep(t, now)
  for id, c in pairs(t.cars) do if c.seenAt ~= now then t.cars[id] = nil end end
end

-- candidates: list of {id, stuck, hidden} where hidden = nobody can see it and no player is near it.
-- Returns the id to recycle now, or nil. The longest stuck hidden car goes first.
function M.pick(t, candidates, now)
  if now - t.lastRecycle < M.GAP_SECONDS then return nil end
  local best
  for _, c in ipairs(candidates) do
    if c.hidden and c.stuck >= M.STUCK_SECONDS and (not best or c.stuck > best.stuck) then best = c end
  end
  if best then
    t.lastRecycle = now
    t.cars[best.id] = nil   -- a fresh start if it comes back in the same slot
    return best.id
  end
end

return M
