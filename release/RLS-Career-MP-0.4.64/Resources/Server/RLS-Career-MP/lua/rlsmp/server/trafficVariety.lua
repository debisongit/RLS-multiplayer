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
local trafficCfg = {}   -- config.traffic (minAmount)
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

-- Police variety settings; the client sanitizes them again.
function M.police()
  local p = type(cfg.police) == "table" and cfg.police or {}
  local words = {}
  if type(p.undercoverWords) == "table" then
    for _, w in ipairs(p.undercoverWords) do
      if type(w) == "string" and w ~= "" and #w <= 32 and #words < 8 then words[#words + 1] = w end
    end
  end
  return {
    enabled = p.enabled ~= false,
    models = weights(p.models),
    undercoverShare = tonumber(p.undercoverShare),
    maxShare = tonumber(p.maxShare),
    undercoverWords = words,
  }
end

-- Premade pool, respawn re-roll and parked amount settings; the client sanitizes them again.
function M.pool()
  local p = type(cfg.pool) == "table" and cfg.pool or {}
  return {enabled = p.enabled ~= false, avoidLast = tonumber(p.avoidLast), brandWindow = tonumber(p.brandWindow), brandMax = tonumber(p.brandMax),
    streetMax = tonumber(p.streetMax), configsPerModel = tonumber(p.configsPerModel), popPower = tonumber(p.popPower), ageMax = tonumber(p.ageMax)}
end

function M.respawn()
  local r = type(cfg.respawn) == "table" and cfg.respawn or {}
  return {enabled = r.enabled ~= false, mode = r.mode, perMinute = tonumber(r.perMinute), chance = tonumber(r.chance), repaintChance = tonumber(r.repaintChance),
    waitSeconds = tonumber(r.waitSeconds), checkSeconds = tonumber(r.checkSeconds)}
end

function M.parked()
  local k = type(cfg.parked) == "table" and cfg.parked or {}
  return {amount = tonumber(k.amount), nightAmount = tonumber(k.nightAmount), fullPool = k.fullPool ~= false, simplifiedShare = tonumber(k.simplifiedShare),
    nearCount = tonumber(k.nearCount), nearNightCount = tonumber(k.nearNightCount), nearRadius = tonumber(k.nearRadius), farRadius = tonumber(k.farRadius),
    moveEverySeconds = tonumber(k.moveEverySeconds)}
end

local function wordList(src)
  local out = {}
  if type(src) ~= "table" then return nil end
  for _, w in ipairs(src) do
    if type(w) == "string" and w ~= "" and #w <= 32 and #out < 24 then out[#out + 1] = w end
  end
  return out
end

function M.rarity()
  local r = type(cfg.rarity) == "table" and cfg.rarity or {}
  return {enabled = r.enabled ~= false, common = tonumber(r.common), uncommon = tonumber(r.uncommon), rare = tonumber(r.rare),
    rareWords = wordList(r.rareWords), uncommonWords = wordList(r.uncommonWords), rareModels = wordList(r.rareModels),
    uncommonValue = tonumber(r.uncommonValue), rareValue = tonumber(r.rareValue)}
end

function M.preload()
  local p = type(cfg.preload) == "table" and cfg.preload or {}
  return {enabled = p.enabled ~= false, minGapSeconds = tonumber(p.minGapSeconds),
    slowFrameMs = tonumber(p.slowFrameMs), calmFrames = tonumber(p.calmFrames), settleSeconds = tonumber(p.settleSeconds), warmShare = tonumber(p.warmShare)}
end

function M.focus()
  local f = type(cfg.focus) == "table" and cfg.focus or {}
  return {enabled = f.enabled ~= false, configs = tonumber(f.configs), minutes = tonumber(f.minutes)}
end

function M.simplified()
  local k = type(cfg.simplified) == "table" and cfg.simplified or {}
  return {enabled = k.enabled == true, parked = k.parked ~= false, traffic = k.traffic == true, nearRadius = tonumber(k.nearRadius),
    perMinute = tonumber(k.perMinute), checkSeconds = tonumber(k.checkSeconds)}
end

-- BeamMP's per-player car limit (MaxCars), or 0 when this server cannot say. The client stops adding traffic cars a few below it.
local function maxCars()
  local ok, n = pcall(function() return MP.Get(MP.Settings.MaxCars) end)
  n = ok and tonumber(n) or 0
  return n and n >= 1 and math.floor(n) or 0
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
    models = weights(cfg.models),
    mods = weights(cfg.mods),
    zones = zones,
    day = weights(cfg.day),
    night = weights(cfg.night),
    oversample = tonumber(cfg.oversample),
    maxShare = tonumber(cfg.maxShare),
    maxCandidates = tonumber(cfg.maxCandidates),
    minAmount = math.max(0, math.floor(tonumber(trafficCfg.minAmount) or 0)),   -- traffic.minAmount, so the client builds the first traffic group big enough
    maxCars = maxCars(),
    excludeWords = type(cfg.excludeWords) == "table" and wordList(cfg.excludeWords) or nil,
    applyToTraffic = cfg.applyToTraffic ~= false,
    applyToParked = cfg.applyToParked ~= false,
    zoneSpeedLimits = {city = tonumber(limits.city), main = tonumber(limits.main)},
    swap = M.swap(),
    police = M.police(),
    pool = M.pool(),
    respawn = M.respawn(),
    parked = M.parked(),
    rarity = M.rarity(),
    preload = M.preload(),
    focus = M.focus(),
    simplified = M.simplified(),
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

-- Settings changed (by the traffic menu): send everybody the new ones.
function M.resend() told = {} end

function M.init(config)
  cfg = config.trafficVariety
  trafficCfg = type(config.traffic) == "table" and config.traffic or {}
  told = {}
  net.on("rlsmpTrafficVarietyTick", function() M.push() end)
  MP.CreateEventTimer("rlsmpTrafficVarietyTick", 1000)
  util.info("Traffic variety: enabled=" .. tostring(cfg.enabled))
end

return M
