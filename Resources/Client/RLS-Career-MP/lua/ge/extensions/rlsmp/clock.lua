-- RLS-Career-MP client extension "rlsmp_clock": the server's time of day.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server sends the game minute (rlsmpTime {m, dm}). We run the sky from it:
--   * 4 times a second: write the time to the game's environment (smooth, no RLS state touched)
--   * every 10 seconds: tell RLS's weather system the new minute (sleepTo moves its forecast forward, so weather days keep passing)
-- RLS's own day/night cycle is paused while connected (RLS would otherwise run its own, different speed) and resumed on leave.

local M = {}

local enabled = false
local anchorMinute, anchorAt, rate, clockNow = nil, 0, 0, 0   -- rate = game minutes per real second
local drawTimer, syncTimer = 0, 0
local paused = false

local function toEngine(minute) return ((minute / 1440) + 0.5) % 1 end
local function toMinute(engine) return (((tonumber(engine) or 0) + 0.5) % 1) * 1440 end

local function weather() return overhaul_world_weather end

local function setPlay(on)
  local w = weather()
  if w and w.toggleDayNightCycle then pcall(w.toggleDayNightCycle, on) end
end

function M.enable(on)
  enabled = on == true
  if not enabled and paused then setPlay(true) paused = false end
  if not enabled then anchorMinute = nil end
end

-- Current server game minute (0 to 1440), or nil before the first message.
function M.minuteNow()
  if not anchorMinute then return nil end
  return (anchorMinute + (clockNow - anchorAt) * rate) % 1440
end

local function onTime(msg)
  local m, dm = tonumber(msg.m), tonumber(msg.dm)
  if not m or not dm or dm < 1 or m < 0 or m >= 1441 then return end
  anchorMinute, anchorAt, rate = m, clockNow, 1440 / (dm * 60)
end

local function draw(minute)
  if core_environment and core_environment.setTimeOfDay then
    core_environment.setTimeOfDay({time = toEngine(minute), play = false})
  end
end

local function syncRls(minute)
  local w = weather()
  if not (w and w.getClockState and w.sleepTo) then return end
  local ok, state = pcall(w.getClockState)
  if not ok or type(state) ~= "table" then return end
  local delta = (minute - toMinute(state.time)) % 1440
  if delta > 720 or delta < 1 then
    if w.setMinuteOfDay and delta >= 1 then pcall(w.setMinuteOfDay, minute, true) end  -- we are behind the server's wrap: just set it
  else
    pcall(w.sleepTo, toEngine(minute))
  end
end

function M.onUpdate(dtReal)
  clockNow = clockNow + (dtReal or 0)
  if not enabled or not anchorMinute then return end
  if not paused then setPlay(false) paused = true end
  drawTimer = drawTimer + (dtReal or 0)
  syncTimer = syncTimer + (dtReal or 0)
  if drawTimer >= 0.25 then
    drawTimer = 0
    draw(M.minuteNow())
  end
  if syncTimer >= 10 then
    syncTimer = 0
    syncRls(M.minuteNow())
  end
end

function M.onExtensionLoaded()
  require("rlsmp/lib/net").on("rlsmpTime", onTime)
end

M._onTime = onTime
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
