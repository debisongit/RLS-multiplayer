-- RLS-Career-MP server: police settings (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Pursuits themselves run inside each player's game (RLS AI). The server's job is to tell every
-- player who is in career how police should behave (`rlsmpPoliceConfig`): no teleporting police
-- cars in front of a chased player, and whether roadblocks are allowed.
-- Sent once to each player when they finish loading (same diff-on-a-timer approach as traffic.lua).

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

local cfg, tcfg
local told = {}   -- pid -> true once they have the settings

-- Traffic respawn range and delay, and the stuck-car recycling (config.traffic, edited in the [ menu); the client sanitizes them again.
function M.range()
  local t = type(tcfg) == "table" and tcfg or {}
  local u = type(t.unjam) == "table" and t.unjam or {}
  return {respawnRange = tonumber(t.respawnRange), respawnDistance = tonumber(t.respawnDistance), respawnDelay = tonumber(t.respawnDelay),
    unjam = {enabled = u.enabled ~= false, seconds = tonumber(u.seconds), distance = tonumber(u.distance),
      crashed = u.crashed ~= false, crashedSeconds = tonumber(u.crashedSeconds), inViewSeconds = tonumber(u.inViewSeconds)}}
end

function M.payload()
  return {
    antiTeleport = cfg.antiTeleport == true,
    blockRoadblocks = cfg.blockRoadblocks == true,
    noFineInStolenCar = cfg.noFineInStolenCar ~= false,
    respawnBehind = cfg.respawnBehind ~= false,
    respawnPerMinute = tonumber(cfg.respawnPerMinute),
    respawnGap = tonumber(cfg.respawnGap),
    respawnRebuildSeconds = tonumber(cfg.respawnRebuildSeconds),
    copRespawnDistance = tonumber(cfg.copRespawnDistance),
    copCount = tonumber(cfg.copCount),
    copTopUpSeconds = tonumber(cfg.copTopUpSeconds),
    bubbleMode = cfg.bubbleMode,
    holdNearBeforeChase = cfg.holdNearBeforeChase == true,
    range = M.range(),
  }
end

function M.push()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      if not told[pid] then
        told[pid] = true
        net.send(pid, "rlsmpPoliceConfig", M.payload())
        util.info(string.format("RLSMP-P3 police config sent to pid=%s antiTeleport=%s blockRoadblocks=%s",
          tostring(pid), tostring(cfg.antiTeleport), tostring(cfg.blockRoadblocks)))
      end
    end
  end
  for pid in pairs(told) do
    if not live[pid] then told[pid] = nil end
  end
end

-- Settings changed (by the traffic menu): send everybody the new ones.
function M.resend() told = {} end

function M.init(config)
  cfg = config.police
  tcfg = config.traffic
  told = {}
  net.on("rlsmpPoliceTick", function() if cfg.enabled then M.push() end end)
  MP.CreateEventTimer("rlsmpPoliceTick", 1000)
  util.info("Police rules on: antiTeleport=" .. tostring(cfg.antiTeleport))
end

return M
