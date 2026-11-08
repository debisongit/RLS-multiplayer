-- RLS-Career-MP client: pure logic for the respawn re-roll (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS/the game respawns a traffic car by moving it somewhere out of sight; it keeps its model. The traffic car object counts its respawns
-- (`respawnCount`), so we notice a respawn when that number goes up. The car is then "due" for a short while: as soon as nobody can see it and
-- the usual safety rules pass, the extension swaps it for a different model with a different config (rlsmp/trafficReroll.lua).

local S = require("rlsmp/lib/trafficSwap")

local M = {}

-- Respawn states in which a car may be re-rolled. 'active' is the normal state; right after a respawn the game puts it into 'reset', then 'fadeIn'.
M.STATES = {active = true, reset = true, fadeIn = true}

function M.newTracker()
  local t = S.newTracker()      -- stamps (rate limit) and failures are reused
  t.counts, t.due = {}, {}
  return t
end

-- Feed the respawn count of a car. Returns true when it just went up (the car is due). The first sighting only sets the baseline.
function M.observe(tr, id, count, now)
  count = tonumber(count) or 0
  local before = tr.counts[id]
  tr.counts[id] = count
  if before == nil then return false end
  if count > before then
    tr.due[id] = now
    return true
  end
  return false
end

-- Cars that are still due (a car stays due for `waitSeconds`, then it is left alone until its next respawn). Oldest first.
function M.dueIds(tr, now, waitSeconds)
  local list = {}
  for id, at in pairs(tr.due) do
    if now - at > waitSeconds then tr.due[id] = nil else list[#list + 1] = {id = id, at = at} end
  end
  table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
  local ids = {}
  for i, x in ipairs(list) do ids[i] = x.id end
  return ids
end

function M.forget(tr, alive)
  for id in pairs(tr.counts) do if not alive[id] then tr.counts[id] = nil end end
  for id in pairs(tr.due) do if not alive[id] then tr.due[id] = nil end end
end

-- Why this car must not be re-rolled (a reason string) or nil. personality.skipReason wants state "active"; a car that was just respawned is in
-- 'reset' or 'fadeIn', so it is asked as if it were active (every other field is read from the real car).
function M.skipReason(P, id, veh, pctx)
  if type(veh) ~= "table" then return "noData" end
  if not M.STATES[veh.state] then return "state" end
  if veh.rlsmpHold then return "hold" end
  return P.skipReason(id, setmetatable({state = "active"}, {__index = veh}), pctx)
end

-- How many cars of each brand are on the street (traffic data ids -> brand), without the car `exceptId`.
function M.census(ids, brandOf, exceptId)
  local out = {}
  for _, id in ipairs(ids) do
    if id ~= exceptId then
      local b = brandOf(id)
      if b then out[b] = (out[b] or 0) + 1 end
    end
  end
  return out
end

return M
