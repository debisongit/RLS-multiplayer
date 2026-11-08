-- RLS-Career-MP: finds traffic cars that are stuck (not moving for a long time) and picks ONE at a time to recycle.
-- Plain module (no game calls) so it can be unit tested. SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.STUCK_SECONDS = 120   -- standing still this long counts as stuck (red lights are shorter); the server setting traffic.unjam.seconds changes it
M.MIN_DISTANCE = 400    -- and only a car this far (m) from EVERY player; traffic.unjam.distance
M.CRASHED = true          -- also remove crashed cars near players (traffic.unjam.crashed)
M.CRASHED_SECONDS = 60    -- crashed this long and out of sight: remove (traffic.unjam.crashedSeconds)
M.IN_VIEW_SECONDS = 120   -- crashed this long, still in sight: fade it out anyway (traffic.unjam.inViewSeconds)
M.CRASH_STILL = 10        -- and it must have been standing still this long (a car still driving on stays)
M.FOOT_NEAR = 40          -- never in sight of a player closer than this (m)
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

-- A crashed car (age = seconds since RLS flagged it, still = seconds it has not moved, hidden = nobody sees it, dist = metres to the nearest player or nil).
-- Returns "hidden" or "inView" when it should be removed now, else nil.
function M.crashDue(age, still, hidden, dist)
  if not M.CRASHED or still < M.CRASH_STILL then return nil end
  if hidden then return age >= M.CRASHED_SECONDS and "hidden" or nil end
  if age >= M.IN_VIEW_SECONDS and dist and dist >= M.FOOT_NEAR then return "inView" end
  return nil
end

-- candidates: list of {id, stuck, hidden, due} where hidden = nobody can see it and no player is near it.
-- Returns the id to recycle now, or nil. The longest stuck hidden car goes first.
function M.pick(t, candidates, now)
  if now - t.lastRecycle < M.GAP_SECONDS then return nil end
  local best
  for _, c in ipairs(candidates) do
    if (c.due or (c.hidden and c.stuck >= M.STUCK_SECONDS)) and (not best or c.stuck > best.stuck) then best = c end
  end
  if best then
    t.lastRecycle = now
    t.cars[best.id] = nil   -- a fresh start if it comes back in the same slot
    return best.id
  end
end

return M
