-- RLS-Career-MP client: pure logic for live traffic swapping (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A traffic car keeps its model once it exists. Swapping replaces a car that NOBODY can see by a different model that suits the
-- current road class and time of day better. This file only decides; the extension rlsmp/trafficSwap.lua does the game calls.
--   * a car must have been out of everybody's sight for `hiddenSeconds` in a row,
--   * at most `perMinute` swaps per minute (BeamMP sends every swap to every player),
--   * the replacement must be a different model and weigh at least `minRatio` times what the car weighs now
--     (with default weights everything weighs 1, so nothing is swapped: swapping only follows real weights).

local V = require("rlsmp/lib/trafficVariety")

local M = {}

M.COOLDOWN = 600   -- seconds before the same car may be looked at again (a car swapped or judged once is left alone for a while)

function M.newTracker() return {hidden = {}, stamps = {}, decided = {}, failures = 0} end

-- One decision per car per COOLDOWN, so watch-only logs show different cars and a swapped car is not swapped again at once.
function M.recentlyDecided(tr, id, now)
  local at = tr.decided[id]
  return at ~= nil and now - at < M.COOLDOWN
end
function M.markDecided(tr, id, now) tr.decided[id] = now end

-- Records whether a car is hidden right now; returns for how many seconds it has been hidden without a break.
function M.seeHidden(tr, id, hidden, now)
  if not hidden then tr.hidden[id] = nil return 0 end
  tr.hidden[id] = tr.hidden[id] or now
  return now - tr.hidden[id]
end

-- Forgets cars that no longer exist. `alive` = set of ids.
function M.forget(tr, alive)
  for id in pairs(tr.hidden) do if not alive[id] then tr.hidden[id] = nil end end
  for id in pairs(tr.decided) do if not alive[id] then tr.decided[id] = nil end end
end

-- Rate limit: swaps in the last 60 seconds against `perMinute`.
function M.allowed(tr, now, swap)
  local kept, n = {}, 0
  for _, t in ipairs(tr.stamps) do
    if now - t < 60 then kept[#kept + 1] = t n = n + 1 end
  end
  tr.stamps = kept
  return n < swap.perMinute
end

function M.record(tr, now) tr.stamps[#tr.stamps + 1] = now end

-- current = {model, config}; candidates = entries the game offered recently. Returns the replacement entry, the old weight and the
-- new weight; nil when the car should stay.
function M.decide(current, candidates, ctx, cfg, infoOf, rnd)
  local wc = V.weight(current, infoOf(current), ctx, cfg)
  local others = {}
  for _, e in ipairs(candidates or {}) do
    if e.model and e.model ~= current.model then others[#others + 1] = e end
  end
  if #others == 0 then return nil, wc, nil end
  local picked = V.select(others, 1, infoOf, ctx, cfg, rnd)
  local r = picked[1]
  if not r then return nil, wc, nil end
  local wr = V.weight(r, infoOf(r), ctx, cfg)
  if wr <= 0 then return nil, wc, wr end
  if wc <= 0 then return r, wc, wr end                    -- the car is not wanted here at all
  if wr >= wc * cfg.swap.minRatio and wr > wc then return r, wc, wr end
  return nil, wc, wr
end

return M
