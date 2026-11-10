-- RLS-Career-MP server: "smart traffic" driver personalities (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The AI itself runs inside each player's game (client rlsmp_personalities). The server only owns the
-- settings and sends them (`rlsmpSmartTraffic {enabled, mix, policeReact}`) once to each player when they
-- finish loading (same diff-on-a-timer approach as trafficPolice.lua). It is sent even when the feature is
-- off, so a game never guesses: the client does nothing until it has heard from the server.

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

M.NAMES = {"normal", "slow", "aggressive", "racer", "drunk"}

local cfg
local told = {}   -- pid -> true once they have the settings

-- Weights from config.json: numbers >= 0 only (anything else counts as 0).
function M.mix()
  local src = type(cfg.mix) == "table" and cfg.mix or {}
  local out = {}
  for _, name in ipairs(M.NAMES) do
    local w = tonumber(src[name])
    out[name] = (w and w == w and w > 0 and w < math.huge) and w or 0
  end
  return out
end

-- Night multipliers: numbers >= 0 only; anything else counts as 1 (unchanged).
function M.nightMult()
  local src = type(cfg.nightMult) == "table" and cfg.nightMult or {}
  local out = {}
  for _, name in ipairs(M.NAMES) do
    local m = tonumber(src[name])
    out[name] = (m and m == m and m >= 0 and m < math.huge) and m or 1
  end
  return out
end

function M.payload()
  return {
    enabled = cfg.enabled == true,
    mix = M.mix(),
    nightMult = M.nightMult(),
    policeReact = cfg.policeReact == true,
  }
end

function M.push()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      if not told[pid] then
        told[pid] = true
        local p = M.payload()
        net.send(pid, "rlsmpSmartTraffic", p)
        util.info(string.format("RLSMP-P3 smart traffic sent to pid=%s enabled=%s policeReact=%s mix=%s/%s/%s/%s/%s",
          tostring(pid), tostring(p.enabled), tostring(p.policeReact),
          p.mix.normal, p.mix.slow, p.mix.aggressive, p.mix.racer, p.mix.drunk))
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
  cfg = config.smartTraffic
  told = {}
  net.on("rlsmpSmartTrafficTick", function() M.push() end)
  MP.CreateEventTimer("rlsmpSmartTrafficTick", 1000)
  util.info("Smart traffic: enabled=" .. tostring(cfg.enabled) .. " policeReact=" .. tostring(cfg.policeReact))
end

return M
