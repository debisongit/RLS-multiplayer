-- RLS-Career-MP server: shared time of day.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The game minute is computed from the server's wall clock (no state to save, survives restarts):
-- one full day = time.dayMinutes real minutes, shaped like RLS's own day (quick dawn and dusk). Every few seconds each loaded player gets the current game minute.
-- Clients move their own sky smoothly in between (client clock.lua).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local cfg

-- RLS's own day shape: (game minutes in the part, share of the real day). Dawn and dusk are quick, the daytime long.
local PARTS = {{240, 4}, {180, 10}, {600, 28}, {180, 12}, {240, 6}}   -- the shares add up to 60

-- Game minute of the day (0 to 1440, 0 = midnight) and game minutes per real second, for a given epoch second.
-- Same curve as RLS uses for its day length setting (dayMinutes real minutes per full day).
function M.minuteAt(epoch, dayMinutes)
  local period = dayMinutes * 60
  local left = epoch % period
  local minute = 0
  for _, part in ipairs(PARTS) do
    local seconds = part[2] * dayMinutes     -- real seconds this part lasts
    if left < seconds then return minute + left / seconds * part[1], part[1] / seconds end
    left, minute = left - seconds, minute + part[1]
  end
  return 0, PARTS[1][1] / (PARTS[1][2] * dayMinutes)
end

function M.tick()
  local m, r = M.minuteAt(util.now(), cfg.time.dayMinutes)
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" then net.send(pid, "rlsmpTime", {m = m, r = r, dm = cfg.time.dayMinutes}) end
  end
end

function M.init(config)
  cfg = config
  local t = cfg.time
  if not t.enabled then return end
  if type(t.dayMinutes) ~= "number" or t.dayMinutes < 1 then t.dayMinutes = 45 end
  net.on("rlsmpTimeTick", M.tick)
  MP.CreateEventTimer("rlsmpTimeTick", math.max(1000, math.floor((tonumber(t.syncSeconds) or 5) * 1000)))
end

return M
