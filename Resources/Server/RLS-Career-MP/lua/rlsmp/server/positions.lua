-- RLS-Career-MP server: where every player is (Phase 3, groundwork for server-directed traffic).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Each game sends rlsmpPos {x, y, z, speed, chased} about every 2 s (less often while standing still).
-- We keep only the latest report per player. Reports are client-made, so use them to direct traffic, never for money.
--
-- Rules: only from players whose career is loaded; numbers must be finite and inside the map-ish bounds below;
-- at most one accepted report per second per player (util.now() counts whole seconds, which is fine for a 2 s cadence).
-- A stored entry remembers the session table it came from. BeamMP reuses player ids, so an entry only counts while
-- sessions.get(pid) is still that same table; after a leave (or a new player on the same id) it is forgotten.
--
-- Distances are horizontal (x/y only): traffic zones care about the map, not the height.
-- Chat: /where tells you your last stored position (to check that reports arrive).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local MAX_XY, MAX_Z, MAX_SPEED = 100000, 20000, 1000   -- meters, meters, m/s
local MIN_GAP = 1                                       -- seconds between accepted reports

local latest = {}   -- pid -> {x, y, z, speed, chased, t, s = session table}

local function finite(v, limit)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and math.abs(v) <= limit
end

-- Drop the entry if its player left (or someone else now has that id). Returns the entry when still valid.
local function valid(pid)
  local e = latest[pid]
  if not e then return nil end
  local s = sessions.get(pid)
  if s ~= e.s or not sessions.isLoaded(pid) then
    latest[pid] = nil
    return nil
  end
  return e
end

local function prune()
  for pid in pairs(latest) do valid(pid) end
end

-- Returns true when the report was stored.
local function onPos(pid, data)
  if type(data) ~= "table" or not sessions.isLoaded(pid) then return false end
  local x, y, z, speed = data.x, data.y, data.z, data.speed
  if not (finite(x, MAX_XY) and finite(y, MAX_XY) and finite(z, MAX_Z) and finite(speed, MAX_SPEED) and speed >= 0) then
    return false
  end
  local now = util.now()
  local old = valid(pid)
  if old and now - old.t < MIN_GAP then return false end
  latest[pid] = {x = x, y = y, z = z, speed = speed, chased = data.chased == true, t = now, s = sessions.get(pid)}
  return true
end

local function public(e)
  return e and {x = e.x, y = e.y, z = e.z, speed = e.speed, chased = e.chased, t = e.t} or nil
end

-- Latest report of one player, or nil. {x, y, z, speed, chased, t}
function M.get(pid) return public(valid(pid)) end

-- pid -> {x, y, z, speed, chased, t} for everyone with a valid report.
function M.all()
  prune()
  local out = {}
  for pid, e in pairs(latest) do out[pid] = public(e) end
  return out
end

-- Horizontal distance in meters between two players, or nil if either has no report.
function M.distance(a, b)
  local p, q = valid(a), valid(b)
  if not (p and q) then return nil end
  local dx, dy = p.x - q.x, p.y - q.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Player ids within `radius` meters of pid (not pid itself), closest first.
function M.near(pid, radius)
  local list, dist = {}, {}
  if not valid(pid) then return list end
  prune()
  for other in pairs(latest) do
    if other ~= pid then
      local d = M.distance(pid, other)
      if d and d <= radius then list[#list + 1], dist[other] = other, d end
    end
  end
  table.sort(list, function(a, b) return dist[a] < dist[b] end)
  return list
end

-- The closest other player: pid, distance. nil when nobody else has a report.
function M.nearest(pid)
  if not valid(pid) then return nil end
  prune()
  local best, bestD
  for other in pairs(latest) do
    if other ~= pid then
      local d = M.distance(pid, other)
      if d and (not bestD or d < bestD) then best, bestD = other, d end
    end
  end
  return best, bestD
end

-- True while the player's last report said a police pursuit is on.
function M.isChased(pid)
  local e = valid(pid)
  return e ~= nil and e.chased
end

local function onWhere(pid)
  local e = valid(pid)
  if not e then
    return MP.SendChatMessage(pid, "[RLS] No position from you yet (it is sent every few seconds while your career runs).")
  end
  MP.SendChatMessage(pid, string.format("[RLS] Last position: x %.0f, y %.0f, z %.0f, %.0f km/h%s, %ds ago.",
    e.x, e.y, e.z, e.speed * 3.6, e.chased and ", police chase" or "", util.now() - e.t))
end

function M.init()
  net.onClient("rlsmpPos", function(pid, data) onPos(pid, data) end)
  net.onChat("where", onWhere)
  net.on("rlsmpPosTick", prune)
  MP.CreateEventTimer("rlsmpPosTick", 5000)
end

M._onPos = onPos

return M
