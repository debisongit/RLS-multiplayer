-- RLS-Career-MP client: pure logic for the preload system (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Building a car is expensive (jbeam, parts, meshes, vehicle thread) and cannot be done "hidden" without BeamMP syncing it, so we do not build
-- spare cars. We spread and prepare the work instead:
--   * frame guard: no build while the last frames were slow, and not for `settleSeconds` after a slow frame (a build is itself a slow frame,
--     so builds are spaced out automatically); never two builds within `minGapSeconds`,
--   * reserve: the next picks are chosen ahead and their data (model info, .pc file) read ahead, one per `prepareSeconds`, in calm moments,
--   * warm bias: `warmShare` of the picks come from models that are already on the map or were built this session (their meshes are loaded).

local M = {}

M.DEFAULTS = {enabled = true, reserve = 3, prepareSeconds = 4, minGapSeconds = 6, slowFrameMs = 45, calmFrames = 45, settleSeconds = 3,
  warmShare = 0.7, ageMax = 240}

local function number(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.sanitize(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS
  return {
    enabled = src.enabled ~= false,
    reserve = math.floor(number(src.reserve, d.reserve, 0, 8)),
    prepareSeconds = number(src.prepareSeconds, d.prepareSeconds, 1, 60),
    minGapSeconds = number(src.minGapSeconds, d.minGapSeconds, 0, 120),
    slowFrameMs = number(src.slowFrameMs, d.slowFrameMs, 10, 2000),
    calmFrames = math.floor(number(src.calmFrames, d.calmFrames, 5, 300)),
    settleSeconds = number(src.settleSeconds, d.settleSeconds, 0, 60),
    warmShare = number(src.warmShare, d.warmShare, 0, 1),
    ageMax = number(src.ageMax, d.ageMax, 10, 3600),
  }
end

-- Frame guard -----------------------------------------------------------------------------------------------------------------------------
function M.newGuard() return {ring = {}, slowAt = -1e9, lastBuild = -1e9} end

-- dt = real seconds of the last frame, now = our clock.
function M.feed(g, dt, now, pc)
  dt = tonumber(dt)
  if not dt or dt <= 0 then return end
  local ring = g.ring
  ring[#ring + 1] = dt
  while #ring > pc.calmFrames do table.remove(ring, 1) end
  if dt * 1000 > pc.slowFrameMs then g.slowAt = now end
end

-- true when a build may start now; else false and the reason.
function M.canBuild(g, now, pc)
  if now - g.lastBuild < pc.minGapSeconds then return false, "gap" end
  if now - g.slowAt < pc.settleSeconds then return false, "slow frame" end
  local sum = 0
  for _, dt in ipairs(g.ring) do sum = sum + dt end
  if #g.ring > 0 and sum / #g.ring * 1000 > pc.slowFrameMs then return false, "slow frames" end
  return true
end

function M.built(g, now) g.lastBuild = now end

-- Reserve (picks made ahead) -------------------------------------------------------------------------------------------------------------------
function M.newQueue() return {} end
function M.size(q) return #q end

-- tag = the context the pick was made for (road class and day or night): a pick is only used in the same context.
function M.push(q, entry, now, tag)
  for _, e in ipairs(q) do if e.entry.model == entry.model and e.entry.config == entry.config then return false end end
  q[#q + 1] = {entry = entry, at = now, tag = tag}
  return true
end

-- The oldest ready pick that is not the car's own model; stale picks are dropped. nil when none.
function M.take(q, currentModel, now, ageMax, tag)
  for i = #q, 1, -1 do if now - q[i].at > ageMax or (tag ~= nil and q[i].tag ~= tag) then table.remove(q, i) end end
  for i, e in ipairs(q) do
    if e.entry.model ~= currentModel then table.remove(q, i) return e.entry end
  end
  return nil
end

function M.clear(q) for i = #q, 1, -1 do q[i] = nil end end

-- Warm bias --------------------------------------------------------------------------------------------------------------------------------------
-- With chance `share` and at least `minModels` warm models in the list, only those are offered; else the whole list.
function M.preferWarm(list, warm, share, rnd, minModels)
  if not warm or (rnd or math.random)() >= share then return list end
  local out, seen, n = {}, {}, 0
  for _, e in ipairs(list) do
    if warm[e.model] then
      out[#out + 1] = e
      if not seen[e.model] then seen[e.model] = true n = n + 1 end
    end
  end
  if n < (minModels or 6) then return list end
  return out
end

return M
