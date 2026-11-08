-- RLS-Career-MP client extension "rlsmp_weather": the server's weather.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server sends one of RLS's six conditions (rlsmpWeather {c, p, n}); we make RLS show it with RLS's own overhaul_world_weather.forceCondition,
-- so RLS keeps doing all the work (rain drops, clouds, wet roads, tire grip) and what the player sees matches the gameplay.
-- RLS's forecast is local (made from the player's own save), so when RLS moves on by itself (next forecast segment) we force the server's
-- condition again. We only force when the server's condition changed or RLS changed what it shows after our last force, never in a loop.
--   * forceCondition("clear") moves RLS's clock to 12:00; we put it back to the server's game minute (rlsmp_clock) at once.
--   * if RLS's "external override" is on (another weather mod), we do nothing.
-- RLS fires phone notifications ("Rain approaching", "Storm approaching", "Fog forming") from the player's OWN local forecast, which no longer
-- matches what they see, so we switch RLS's forecastNotifications off once per session (it is saved in the career, which only exists on this server).
-- Known gaps: RLS's morning fog, temperature and thunder timing stay local; RLS's weather app shows the local forecast; changes snap instead of fading.
-- Active only in a multiplayer session while the RLS career is active, after the server's first message.

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local VALID = {clear = true, partlyCloudy = true, overcast = true, drizzle = true, rain = true, storm = true}
local CHECK_EVERY = 2         -- seconds between checks
local MIN_GAP = 5             -- seconds between two forces
local BACKOFF = 30            -- seconds to wait after a force failed

local target                  -- the server's condition; nil until it speaks
local forcedFor               -- the target we last forced
local shownAfter              -- what RLS showed right after our last force
local clock, timer = 0, 0
local lastForceAt, nextTryAt = -math.huge, 0
local failures = 0
local silenced = false       -- RLS's own forecast notifications switched off this session

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function active() return target ~= nil and mp.isMPSession() and careerActive() end
local function rls() return rawget(_G, "overhaul_world_weather") end

local function shown(W)
  local ok, ui = pcall(W.getUiState)
  if not ok or type(ui) ~= "table" or ui.ready == false or type(ui.condition) ~= "string" then return nil end
  return ui.condition
end

local function serverMinute()
  local c = rawget(_G, "rlsmp_clock") or package.loaded["rlsmp/clock"]
  return c and c.minuteNow and c.minuteNow() or nil
end

-- One round. Returns true when it forced the condition (for tests).
function M.check()
  if not active() then return false end
  local W = rls()
  if not (W and W.getUiState and W.forceCondition) then
    p3.logOnChange("weather-norls", true, "W", "RLS's weather module is not available: shared weather stays off")
    return false
  end
  if W.isExternalOverrideActive and W.isExternalOverrideActive() then
    p3.logOnChange("weather-override", true, "W", "another weather mod has priority (RLS external override): shared weather does nothing")
    return false
  end
  if clock < nextTryAt or clock - lastForceAt < MIN_GAP then return false end
  local current = shown(W)
  if not current then return false end                                  -- RLS weather not ready yet
  if not silenced and W.setSetting then
    silenced = true
    local ok = pcall(W.setSetting, "forecastNotifications", false)
    p3.log("I", "weather: RLS's own forecast notifications switched off (they describe the local forecast, not the server's)" .. (ok and "" or " - failed"))
  end
  if forcedFor == target and current == shownAfter then return false end  -- RLS still shows what we set
  local ok, result = pcall(W.forceCondition, target)
  if not ok or result == false then
    failures = failures + 1
    nextTryAt = clock + BACKOFF
    p3.count("weather force failed")
    p3.log("W", string.format("weather: forceCondition(%s) failed (%s); trying again in %d s", target, tostring(ok and "refused" or result), BACKOFF))
    return false
  end
  lastForceAt = clock
  if target == "clear" then                                              -- RLS jumped its clock to noon: back to the server's time
    local minute = serverMinute()
    if minute and W.setMinuteOfDay then pcall(W.setMinuteOfDay, minute, true) end
  end
  forcedFor = target
  shownAfter = shown(W) or target
  p3.count("weather forced")
  p3.log("I", string.format("weather: forced %s (RLS showed %s, now shows %s)", target, current, tostring(shownAfter)))
  return true
end

local function onWeather(msg)
  local c = type(msg) == "table" and msg.c
  if type(c) ~= "string" or not VALID[c] then return end
  if c ~= target then
    p3.log("I", string.format("weather from the server: %s (period %s, %s s left)", c, tostring(msg.p), tostring(msg.n)))
  end
  target = c
end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

function M.onServerLeave()
  target, forcedFor, shownAfter, failures, silenced = nil, nil, nil, 0, false
  lastForceAt, nextTryAt = -math.huge, 0
end

function M.getTarget() return target end
function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpWeather", onWeather)
  p3.log("I", "rlsmp_weather loaded")
end

M._onWeather = onWeather
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("weather", M)
return M
