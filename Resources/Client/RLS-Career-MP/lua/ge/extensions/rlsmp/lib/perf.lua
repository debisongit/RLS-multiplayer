-- RLS-Career-MP: how much game time our own extensions use (frame-time counters, one log line a minute).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Owner's lag report: ~9 fps and nobody could say how much of it is ours. Every extension file ends with
--   require("rlsmp/lib/perf").wrap("name", M)
-- which wraps its onUpdate ONCE (a marker field stops a second layer when the module is loaded again) and adds up the time it takes.
-- Once a minute (and on M.report()) one line goes to the log: `perf: ours 1.2 ms/frame over 3600 frames, top: parked 0.6 (max 14.0), ...`
-- and the number of cars in the game, so a log shows both. NOT covered: the time inside the wrappers we put around RLS functions
-- (bubble tryRespawn, police) and in event handlers; if "ours" is small, the lag is not in our per-frame code.
-- Tests: tests/perf_test.lua.

local M = {}

local p3 = require("rlsmp/lib/p3")

M.EVERY = 60          -- seconds between log lines
local stats = {}      -- name -> {sum, max, n}
local frames = 0      -- calls of the busiest module in this window (about the frames)
local lastReport = nil
local clockFn = os.clock
local timeFn = os.time

function M.setClocks(c, t) clockFn, timeFn = c, t end

local function cars()
  if be and be.getObjectCount then
    local ok, n = pcall(be.getObjectCount, be)
    if ok then return n end
  end
  return nil
end

-- The report text, or nil when nothing was measured. Clears the window.
function M.report()
  local list, total, maxCalls = {}, 0, 0
  for name, s in pairs(stats) do
    if s.n > 0 then
      list[#list + 1] = {name = name, avg = s.sum / s.n * 1000, max = s.max * 1000, sum = s.sum, n = s.n}
      total = total + s.sum
      if s.n > maxCalls then maxCalls = s.n end
    end
  end
  stats = {}
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.sum > b.sum end)
  local parts = {}
  for i = 1, math.min(6, #list) do
    parts[#parts + 1] = string.format("%s %.2f (max %.1f)", list[i].name, list[i].avg, list[i].max)
  end
  local perFrame = maxCalls > 0 and total / maxCalls * 1000 or 0
  local n = cars()
  local text = string.format("perf: ours %.2f ms/frame over %d frames, cars in the game %s; per module ms/call: %s",
    perFrame, maxCalls, n and tostring(n) or "?", table.concat(parts, ", "))
  p3.log("I", text)
  return text
end

local function tick()
  local now = timeFn()
  if not lastReport then lastReport = now return end
  if now - lastReport >= M.EVERY then
    lastReport = now
    M.report()
  end
end

-- Wrap mod.onUpdate once.
function M.wrap(name, mod)
  if type(mod) ~= "table" or type(mod.onUpdate) ~= "function" or rawget(mod, "rlsmpPerfWrapped") == mod.onUpdate then return false end
  local original = mod.onUpdate
  local function timed(...)
    local t0 = clockFn()
    local a, b = original(...)
    local d = clockFn() - t0
    local s = stats[name]
    if not s then s = {sum = 0, max = 0, n = 0} stats[name] = s end
    s.sum, s.n = s.sum + d, s.n + 1
    if d > s.max then s.max = d end
    tick()
    return a, b
  end
  mod.onUpdate = timed
  mod.rlsmpPerfWrapped = timed
  return true
end

function M.reset() stats, lastReport = {}, nil end

return M
