-- RLS-Career-MP server: "traffic variety" settings (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Which cars the AI traffic and parked cars use is decided inside each player's game (client rlsmp_trafficVariety).
-- The server only owns the settings and sends them (`rlsmpTrafficVariety`) once to each player when they finish loading
-- (same approach as smartTraffic.lua). It is sent even when the feature is off, so a game never guesses.
-- Modded car models: put the mod zip in the server's Resources/Client folder (BeamMP gives it to every player) and list
-- the model's name under `mods` with a weight. A game that does not have the model skips it.

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

local MAX_ENTRIES = 64
local MAX_NAME = 64

local cfg
local told = {}   -- pid -> true once they have the settings

-- {name = weight}: short string names, finite weights >= 0, at most MAX_ENTRIES (a bad config.json cannot flood the clients).
local function weights(src)
  local out, n = {}, 0
  if type(src) ~= "table" then return out end
  for name, w in pairs(src) do
    w = tonumber(w)
    if type(name) == "string" and name ~= "" and #name <= MAX_NAME and w and w == w and w >= 0 and w < math.huge and n < MAX_ENTRIES then
      out[name] = w
      n = n + 1
    end
  end
  return out
end

-- Live swapping switches and numbers; the client sanitizes them again.
function M.swap()
  local s = type(cfg.swap) == "table" and cfg.swap or {}
  return {
    enabled = s.enabled == true,
    live = s.live == true,
    perMinute = tonumber(s.perMinute),
    hiddenSeconds = tonumber(s.hiddenSeconds),
    checkSeconds = tonumber(s.checkSeconds),
    minRatio = tonumber(s.minRatio),
    maxFailures = tonumber(s.maxFailures),
  }
end

function M.payload()
  local zones = {}
  if type(cfg.zones) == "table" then
    for zone, map in pairs(cfg.zones) do
      if type(zone) == "string" and #zone <= MAX_NAME then zones[zone] = weights(map) end
    end
  end
  local limits = type(cfg.zoneSpeedLimits) == "table" and cfg.zoneSpeedLimits or {}
  return {
    enabled = cfg.enabled == true,
    typeWeights = weights(cfg.typeWeights),
    mods = weights(cfg.mods),
    zones = zones,
    day = weights(cfg.day),
    night = weights(cfg.night),
    oversample = tonumber(cfg.oversample),
    maxShare = tonumber(cfg.maxShare),
    maxCandidates = tonumber(cfg.maxCandidates),
    applyToTraffic = cfg.applyToTraffic ~= false,
    applyToParked = cfg.applyToParked ~= false,
    zoneSpeedLimits = {city = tonumber(limits.city), main = tonumber(limits.main)},
    swap = M.swap(),
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
        net.send(pid, "rlsmpTrafficVariety", p)
        local mods = 0
        for _ in pairs(p.mods) do mods = mods + 1 end
        util.info(string.format("RLSMP-P3 traffic variety sent to pid=%s enabled=%s mods=%d maxShare=%s swap=%s live=%s",
          tostring(pid), tostring(p.enabled), mods, tostring(p.maxShare), tostring(p.swap.enabled), tostring(p.swap.live)))
      end
    end
  end
  for pid in pairs(told) do
    if not live[pid] then told[pid] = nil end
  end
end

function M.init(config)
  cfg = config.trafficVariety
  told = {}
  net.on("rlsmpTrafficVarietyTick", function() M.push() end)
  MP.CreateEventTimer("rlsmpTrafficVarietyTick", 1000)
  util.info("Traffic variety: enabled=" .. tostring(cfg.enabled))
end

return M
