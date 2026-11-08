-- RLS-Career-MP client: pure rules for WHERE a police car or a traffic car may appear (no game calls, unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Owner: "cop cars that respawn must NOT spawn literally in front of or behind the player; better about a block away in a DIFFERENT street, or a street
-- on the player's right side, at least about 1 km away" and "traffic should spawn and despawn in a 4 km radius".
-- Distances are STRAIGHT-LINE (horizontal) metres, not path lengths: a path search per candidate is too slow, and a path is never shorter than the line.
-- rlsmp/spawnSpot.lua finds candidate road points with the game's map; this file only judges them.

local G = require("rlsmp/lib/viewGate")

local M = {}

M.CORRIDOR = 40   -- police: a spot closer than this to the line of the player's heading (ahead OR behind) is "literally in front or behind"

local function len2(x, y) return math.sqrt(x * x + y * y) end

-- Where is p seen from the player at pp looking along dir? Returns dist (m, horizontal), along (m, + = ahead), side (m, + = left, - = RIGHT).
-- A player looking along +y sees +x on the right: side = dir.x * dy - dir.y * dx = -dx < 0.
function M.rel(pp, dir, p)
  local dx, dy = p.x - pp.x, p.y - pp.y
  local n = len2(dir.x, dir.y)
  if n < 1e-6 then return len2(dx, dy), 0, 0 end
  local ux, uy = dir.x / n, dir.y / n
  return len2(dx, dy), dx * ux + dy * uy, ux * dy - uy * dx
end

-- c = {x, y, z, road}; ctx = {player = {x,y,z}, dir = {x,y}, cam, fwd (camera), others = {{x,y,z}...}, minDist, corridor, road (the player's road name)}.
-- Returns nil when the spot is fine, else the reason: "noPlayer", "near" (closer than minDist to a player), "view" (in the camera cone / within 120 m),
-- "line" (straight ahead or behind the player), "sameRoad" (the player's own road).
function M.reject(c, ctx)
  local pp = ctx.player
  if not (c and pp) then return "noPlayer" end
  local min = tonumber(ctx.minDist) or 0
  if len2(c.x - pp.x, c.y - pp.y) < min then return "near" end
  for _, o in ipairs(ctx.others or {}) do
    if len2(c.x - o.x, c.y - o.y) < min then return "near" end
  end
  if G.reason({x = c.x, y = c.y, z = c.z or pp.z or 0}, pp, ctx.cam, ctx.fwd, ctx.others) then return "view" end
  if (ctx.corridor or 0) > 0 and ctx.dir then
    local _, _, side = M.rel(pp, ctx.dir, c)
    if math.abs(side) < ctx.corridor then return "line" end
  end
  if ctx.road and c.road and c.road == ctx.road then return "sameRoad" end
  return nil
end

-- The best of the allowed candidates. A spot on the player's RIGHT is preferred (`preferRight`), then the nearer one (it arrives sooner).
-- Returns the candidate (with .dist and .side added) or nil, and a table reason -> count for the log.
function M.pick(cands, ctx, preferRight)
  local best, bestKey, why = nil, nil, {}
  for _, c in ipairs(cands) do
    local r = M.reject(c, ctx)
    if r then why[r] = (why[r] or 0) + 1
    else
      local dist, _, side = M.rel(ctx.player, ctx.dir or {x = 0, y = 0}, c)
      local key = dist - ((preferRight and side < 0) and 1e6 or 0)
      if not bestKey or key < bestKey then best, bestKey = c, key end
      c.dist, c.side = dist, side
    end
  end
  return best, why
end

-- A distance for a traffic car in the ring [min, max] (u = a random number 0..1): evenly spread over the DISTANCE (not the area), so the
-- cars are not all at the edge of a 4 km disc. min >= max gives min.
function M.ringDistance(min, max, u)
  min, max = tonumber(min) or 0, tonumber(max) or 0
  if max <= min then return min end
  return min + (max - min) * math.max(0, math.min(1, u or 0))
end

-- Settings from the server (traffic.spawnMinDistance / spawnMaxDistance): 0 max = the game's own placement. min is never below 120 m (the view gate).
function M.ring(minD, maxD)
  minD, maxD = tonumber(minD) or 250, tonumber(maxD) or 4000
  if maxD <= 0 then return 0, 0 end
  minD = math.max(G.NEAR, math.min(minD, 3000))
  maxD = math.max(minD + 100, math.min(maxD, 6000))
  return minD, maxD
end

return M
