-- RLS-Career-MP: pure helpers for putting a stolen car back (rlsmp/recall.lua). No game calls here, so tests can run them.
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.FAR = 5000         -- metres: a stored spot farther than this from the player counts as invalid
M.SPOT_FREE = 3.5    -- metres: another car this close to a spot blocks it
M.SIDE = 5           -- metres beside the player for the "here" fallback

local function num(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

local function dist2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- {x, y, z} from any table, or nil.
function M.pos(t)
  if type(t) ~= "table" then return nil end
  local x, y, z = num(t.x), num(t.y), num(t.z)
  if not (x and y and z) or math.abs(x) > 1e5 or math.abs(y) > 1e5 or math.abs(z) > 1e4 then return nil end
  return {x = x, y = y, z = z}
end

-- {x, y, z, w} unit-ish quaternion, or nil.
function M.rot(t)
  if type(t) ~= "table" then return nil end
  local x, y, z, w = num(t.x), num(t.y), num(t.z), num(t.w)
  if not (x and y and z and w) then return nil end
  local len = math.sqrt(x * x + y * y + z * z + w * w)
  if len < 0.5 or len > 1.5 then return nil end
  return {x = x, y = y, z = z, w = w}
end

-- Nearest drop spot within FAR of `me`: {x, y, z, name} or nil.
function M.nearestSpot(spots, me)
  local best, bestD
  for _, sp in ipairs(type(spots) == "table" and spots or {}) do
    local p = M.pos(sp)
    local d = p and dist2(p, me)
    if d and d <= M.FAR and (not bestD or d < bestD) then best, bestD = {x = p.x, y = p.y, z = p.z, name = sp.name}, d end
  end
  return best
end

-- A free spot at or around `p` (rings of 4 candidates at 0, 4 and 8 m). `taken(x, y)` says if a car stands closer than SPOT_FREE.
local function freeNear(p, taken)
  for _, r in ipairs({0, 4, 8}) do
    for k = 0, (r == 0 and 0 or 3) do
      local a = k * math.pi / 2
      local x, y = p.x + r * math.cos(a), p.y + r * math.sin(a)
      if not taken(x, y) then return {x = x, y = y, z = p.z} end
    end
  end
  return nil
end

-- Where to put the car. rec = {x, y, z, rot}; me = player position; manual = true puts it beside the player.
-- Returns {x, y, z, rot, how} where how = "last position" | "drop spot" | "player side" | "player side (manual)".
function M.choose(rec, me, spots, taken, manual)
  taken = taken or function() return false end
  local function side(how)
    local p = freeNear({x = me.x + M.SIDE, y = me.y, z = me.z + 0.3}, taken) or {x = me.x + M.SIDE, y = me.y, z = me.z + 0.3}
    return {x = p.x, y = p.y, z = p.z, how = how}
  end
  if manual then return side("player side (manual)") end
  local last = M.pos(rec)
  if last and dist2(last, me) <= M.FAR then
    local p = freeNear(last, taken)
    if p then return {x = p.x, y = p.y, z = p.z, rot = M.rot(rec.rot), how = "last position"} end
  end
  local sp = M.nearestSpot(spots, me)
  if sp then
    local p = freeNear(sp, taken)
    if p then return {x = p.x, y = p.y, z = p.z, how = "drop spot"} end
  end
  return side("player side")
end

-- Should the car's place be reported to the server now? (every `every` seconds, only if it moved or `force` seconds passed)
function M.dueReport(last, pos, now, every, minMove, force)
  if not last then return true end
  local dt = now - last.t
  if dt < every then return false end
  return dist2(last, pos) >= minMove or dt >= force
end

return M
