-- RLS-Career-MP server: small quality-of-life commands.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- /unstuck (alias /road): teleports you to the nearest road, in a car or on foot.
-- The server only checks that you are in your career and not spamming it; the client does the teleport.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local cfg

local function unstuck(pid)
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then
    return MP.SendChatMessage(pid, "[RLS] Your career is still loading.")
  end
  local wait = (s.lastUnstuck or -math.huge) + cfg.unstuck.cooldownSeconds - util.now()
  if wait > 0 then
    return MP.SendChatMessage(pid, string.format("[RLS] Unstuck is on cooldown (%ds).", math.ceil(wait)))
  end
  s.lastUnstuck = util.now()
  net.send(pid, "rlsmpUnstuck", {})
end

function M.init(config)
  cfg = config
  net.onChat("unstuck", unstuck)
  net.onChat("road", unstuck)
end

return M
