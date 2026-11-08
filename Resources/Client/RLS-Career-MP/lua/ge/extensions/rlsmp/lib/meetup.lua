-- RLS-Career-MP client: meetup selling, pure logic (no game calls; the extension is rlsmp/meetup.lua).
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.HOLD = 2.5          -- seconds a player must stay stopped inside the circle
M.STOP_SPEED = 2.0    -- m/s counts as stopped

-- True when one of the call-stack sources is RLS's Marketplace (career/market/marketplace.lua or marketplace/negotiation.lua).
-- Car meets and the auction also call inventory.sellVehicle; their files do not contain "marketplace", so they are left alone.
function M.fromMarketplace(sources)
  for _, src in ipairs(sources or {}) do
    if type(src) == "string" and src:lower():find("marketplace", 1, true) then return true end
  end
  return false
end

function M.dist2d(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return math.huge end
  local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

-- Drop-off timer: newHold() then step(h, dt, distance, speed, radius) -> true once the player stayed stopped inside the circle for HOLD seconds.
function M.newHold() return {t = 0} end
function M.step(h, dt, distance, speed, radius)
  if distance <= radius and speed <= M.STOP_SPEED then
    h.t = h.t + dt
    return h.t >= M.HOLD
  end
  h.t = 0
  return false
end

-- The n nearest police ids. units: id -> {x, y}; at: {x, y}. Returns a list (may be shorter than n).
function M.nearestCops(units, at, n)
  local list = {}
  for id, p in pairs(units or {}) do list[#list + 1] = {id = id, d = M.dist2d(p, at)} end
  table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  local out = {}
  for i = 1, math.min(math.max(0, math.floor(tonumber(n) or 0)), #list) do out[i] = list[i].id end
  return out
end

return M
