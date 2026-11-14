-- RLS-Career-MP client extension "rlsmp_spawnSpot": finds a road spot for a police or traffic car with the game's map (the rules are in lib/spawnSpot.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- How: it takes random nodes of the game's road graph (`map.getMap().nodes`, the same table RLS reads in its taxi and police code), keeps those in the
-- distance ring around the local player that the rules accept, asks `map.findClosestRoad` for the road name of a few of them (the player's own road is
-- refused), and lays the best one into its lane with `gameplay_traffic_trafficUtils.finalizeSpawnPoint` (RLS's taxi call does the same).
-- Anything missing or failing gives nil: the caller then leaves the car where the game put it. UNVERIFIED IN GAME: `node.links`, `node.drivability`, and
-- the return values of findClosestRoad (RLS uses the first as a road name, e.g. jobs/beamEats.lua:469); every call is in a pcall.
-- Log lines start with "spawn:".

local M = {}

local S = require("rlsmp/lib/spawnSpot")
local p3 = require("rlsmp/lib/p3")

local TRIES, MAX_ROAD_CHECKS = 160, 3   -- (was 8: the owner's perf line showed a 75 ms hitch in policeRespawn; each findClosestRoad is a map search)
local playerRoad = {pos = nil, name = nil, at = -math.huge}   -- the player's own road name, reused while they stand within 40 m of where it was asked
local keys, keysFor = nil, nil       -- the node names as a list (rebuilt when the game's node table changes)

local function xyz(p) return p and p.x and {x = p.x, y = p.y, z = p.z} or nil end

local function nodes()
  local ok, m = pcall(function() return map and map.getMap and map.getMap() end)
  return ok and m and m.nodes or nil
end

-- The local player: position and heading (car, or the walking character), the camera, the other players.
local function context()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return nil end
  local okd, dir = pcall(veh.getDirectionVector, veh)
  local pos = xyz(veh:getPosition())
  if not (pos and okd and dir) then return nil end
  local ctx = {player = pos, dir = {x = dir.x, y = dir.y}, others = {}}
  if core_camera and core_camera.getPosition and core_camera.getForward then
    local ok1, c = pcall(core_camera.getPosition)
    local ok2, f = pcall(core_camera.getForward)
    ctx.cam, ctx.fwd = ok1 and xyz(c) or nil, ok2 and xyz(f) or nil
  end
  local b = rawget(_G, "rlsmp_bubble") or package.loaded["rlsmp/bubble"]
  if b and b.otherPlayers then
    local okp, list = pcall(b.otherPlayers)
    if okp and type(list) == "table" then for _, q in ipairs(list) do ctx.others[#ctx.others + 1] = xyz(q) end end
  end
  return ctx
end
M._context = context

local function roadOf(pos)
  if not (map and map.findClosestRoad and vec3) then return nil end
  local ok, name = pcall(map.findClosestRoad, vec3(pos.x, pos.y, pos.z))
  return ok and name or nil
end

-- Candidates: random drivable nodes whose straight distance to the player is inside [minDist, maxDist].
local function candidates(ns, ctx, o)
  if keysFor ~= ns then
    keys, keysFor = {}, ns
    for k in pairs(ns) do keys[#keys + 1] = k end
  end
  local list, n = {}, #keys
  if n == 0 then return list end
  for _ = 1, TRIES do
    local k = keys[math.random(n)]
    local node = ns[k]
    local p = node and node.pos
    if p and (node.drivability == nil or node.drivability >= 0.5) then
      local d = math.sqrt((p.x - ctx.player.x) ^ 2 + (p.y - ctx.player.y) ^ 2)
      if d >= o.minDist and d <= o.maxDist and type(node.links) == "table" then
        local n2 = next(node.links)
        if n2 and ns[n2] then list[#list + 1] = {x = p.x, y = p.y, z = p.z, n1 = k, n2 = n2} end
      end
    end
  end
  return list
end

-- A spot with the lane laid in: {x, y, z, q = {x,y,z,w}, dist, side, road} or nil. o = {minDist, maxDist, preferRight, corridor, noRoad (skip the same-road rule), why (log text)}.
function M.find(o)
  local ns, ctx = nodes(), context()
  if not (ns and ctx) then p3.logOnChange("spawn-nomap", "x", "W", "spawn: no road map or no player car yet; nothing placed") return nil end
  ctx.minDist, ctx.corridor = o.minDist, o.corridor or 0
  local rough = candidates(ns, ctx, o)
  -- the cheap rules first (distance, view, line); only the survivors get a road name
  local ok, kept = {}, {}
  for _, c in ipairs(rough) do
    if not S.reject(c, ctx) then ok[#ok + 1] = c end
  end
  if o.preferRight then
    -- only a few survivors get a road name (each one is a map search): take the ones on the player's right first, so "right side preferred"
    -- still holds with the short list (with the first three in random order the pick landed on the left about one time in ten)
    local right, left = {}, {}
    for _, c in ipairs(ok) do
      local _, _, side = S.rel(ctx.player, ctx.dir or {x = 0, y = 0}, c)
      if side < 0 then right[#right + 1] = c else left[#left + 1] = c end
    end
    for _, c in ipairs(left) do right[#right + 1] = c end
    ok = right
  end
  for i = 1, math.min(#ok, MAX_ROAD_CHECKS) do kept[i] = ok[i] end
  if not o.noRoad then
    local now = os.clock()
    if playerRoad.pos and now - playerRoad.at < 10 and (playerRoad.pos.x - ctx.player.x) ^ 2 + (playerRoad.pos.y - ctx.player.y) ^ 2 < 1600 then
      ctx.road = playerRoad.name
    else
      ctx.road = roadOf(ctx.player)
      playerRoad.pos, playerRoad.name, playerRoad.at = {x = ctx.player.x, y = ctx.player.y}, ctx.road, now
    end
    for _, c in ipairs(kept) do c.road = roadOf(c) end
  end
  local best, why = S.pick(kept, ctx, o.preferRight)
  if not best then
    p3.log("I", string.format("spawn: %s: no spot (%d nodes in the ring of %d..%d m, %d allowed by distance/view, rejected %s)", tostring(o.why), #rough,
      math.floor(o.minDist), math.floor(o.maxDist), #ok, (function() local t = {} for r, k in pairs(why) do t[#t + 1] = r .. "=" .. k end return table.concat(t, ",") end)()))
    return nil
  end
  local ns1, ns2 = ns[best.n1], ns[best.n2]
  local spot = {x = best.x, y = best.y, z = best.z, dist = best.dist, side = best.side, road = best.road}
  local tu = rawget(_G, "gameplay_traffic_trafficUtils")
  local made, err = pcall(function()
    local dir = (ns2.pos - ns1.pos):normalized()
    local pos = vec3(best.x, best.y, best.z)
    local dir2
    if tu and tu.finalizeSpawnPoint then pos, dir2 = tu.finalizeSpawnPoint(pos, dir, best.n1, best.n2, {legalDirection = true}) end
    dir = dir2 or dir
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
    spot.x, spot.y, spot.z = pos.x, pos.y, pos.z
    spot.q = {x = rot.x, y = rot.y, z = rot.z, w = rot.w}
  end)
  if not made then p3.log("W", "spawn: " .. tostring(o.why) .. ": laying the car into its lane failed: " .. tostring(err)) return nil end
  p3.log("I", string.format("spawn: %s: spot %.0f m from you, %s of you, road %s, ring %d..%d m", tostring(o.why), best.dist,
    best.side < 0 and "RIGHT" or "left", tostring(best.road), math.floor(o.minDist), math.floor(o.maxDist)))
  return spot
end

-- Pure judgement of a position the game already chose (a re-placed cop): nil = fine, else the reason (lib/spawnSpot.lua `reject`).
function M.judge(pos, minDist, corridor, noRoad)
  local ctx = context()
  if not (ctx and pos) then return "noPlayer" end
  ctx.minDist, ctx.corridor = minDist, corridor or 0
  local c = {x = pos.x, y = pos.y, z = pos.z}
  if not noRoad then ctx.road, c.road = roadOf(ctx.player), roadOf(c) end
  local why = S.reject(c, ctx)
  if why then return why, (S.rel(ctx.player, ctx.dir, c)) end
  return nil, (S.rel(ctx.player, ctx.dir, c))
end

function M.onExtensionLoaded() p3.log("I", "rlsmp_spawnSpot loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
