-- RLS-Career-MP client: pure census of traffic respawns and fade-outs for the "distance:" log (no game calls, unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.WINDOW = 60   -- seconds

function M.new() return {counts = {}, states = {}, events = {}} end

-- Feed one car each frame. Returns "respawn" when its respawnCount went up, "fadeout" when it just entered fadeOut, else nil.
-- `dist` = metres to the local player when seen (nil if unknown).
function M.observe(w, id, count, state, dist, now)
  count = tonumber(count) or 0
  local prevCount, prevState = w.counts[id], w.states[id]
  w.counts[id], w.states[id] = count, state
  if prevCount == nil then return nil end
  if count > prevCount then
    w.events[#w.events + 1] = {at = now, dist = dist}
    return "respawn"
  end
  if state == "fadeOut" and prevState ~= "fadeOut" then return "fadeout" end
  return nil
end

function M.forget(w, alive)
  for id in pairs(w.counts) do if not alive[id] then w.counts[id], w.states[id] = nil, nil end end
end

-- Respawns in the last WINDOW seconds and the smallest distance among them (nil if none known).
function M.summary(w, now)
  local keep, nearest = {}, nil
  for _, e in ipairs(w.events) do
    if now - e.at <= M.WINDOW then
      keep[#keep + 1] = e
      if e.dist and (not nearest or e.dist < nearest) then nearest = e.dist end
    end
  end
  w.events = keep
  return #keep, nearest
end

return M
