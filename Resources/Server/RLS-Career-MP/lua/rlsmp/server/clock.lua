-- RLS-Career-MP server: shared time of day.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The game minute is computed from the server's wall clock (no state to save, survives restarts):
-- one full day = time.dayMinutes real minutes. Every few seconds each loaded player gets the current game minute.
-- Clients move their own sky smoothly in between (client clock.lua).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local cfg

-- Game minute of the day (0 to 1440, 0 = midnight) for a given epoch second.
function M.minuteAt(epoch, dayMinutes)
  local period = dayMinutes * 60
  return (epoch % period) / period * 1440
end

function M.tick()
  local m = M.minuteAt(util.now(), cfg.time.dayMinutes)
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" then net.send(pid, "rlsmpTime", {m = m, dm = cfg.time.dayMinutes}) end
  end
end

function M.init(config)
  cfg = config
  local t = cfg.time
  if not t.enabled then return end
  if type(t.dayMinutes) ~= "number" or t.dayMinutes < 1 then t.dayMinutes = 20 end
  net.on("rlsmpTimeTick", M.tick)
  MP.CreateEventTimer("rlsmpTimeTick", math.max(1000, math.floor((tonumber(t.syncSeconds) or 5) * 1000)))
end

return M
