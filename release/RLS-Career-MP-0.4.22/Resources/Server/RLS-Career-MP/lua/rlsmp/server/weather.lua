-- RLS-Career-MP server: shared weather.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every game runs its own RLS weather (a forecast made from the player's own save), so players saw different weather. Like the time of day,
-- the server picks the weather from its wall clock (no state to save, restarts stay consistent). Every `periodMinutes` real minutes
-- there is a random "severity" (0 = clear sky, 1 = storm) and the weather glides smoothly from one period's value to the next, so it passes
-- through the conditions in between one step at a time (clear > partlyCloudy > overcast > drizzle > rain > storm). The weights of `mix` decide how
-- much of the scale each condition takes. Every `syncSeconds` each loaded player gets the current condition (`rlsmpWeather`); the client makes RLS
-- show it (client weather.lua). `force` pins one condition for everybody (for testing).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

M.CONDITIONS = {"clear", "partlyCloudy", "overcast", "drizzle", "rain", "storm"}
local INDEX = {}
for i, name in ipairs(M.CONDITIONS) do INDEX[name] = i end

local STRETCH = 1.1
local DEFAULT_MIX = {clear = 35, partlyCloudy = 25, overcast = 20, drizzle = 8, rain = 9, storm = 3}

local cfg
local lastPeriod

-- Weights per condition: numbers >= 0 only; if nothing is left the default mix is used.
function M.mix(src)
  local out, total = {}, 0
  src = type(src) == "table" and src or {}
  for _, name in ipairs(M.CONDITIONS) do
    local w = tonumber(src[name])
    out[name] = (w and w == w and w > 0 and w < math.huge) and w or 0
    total = total + out[name]
  end
  if total <= 0 then return M.mix(DEFAULT_MIX) end
  return out
end

-- A well mixed 32-bit integer hash (Lua 5.3 integer and bit operators). A plain linear formula would give a steady ramp from one period to the next.
local function mix32(x)
  x = x & 0xFFFFFFFF
  x = (((x >> 16) ~ x) * 0x45d9f3b) & 0xFFFFFFFF
  x = (((x >> 16) ~ x) * 0x45d9f3b) & 0xFFFFFFFF
  return ((x >> 16) ~ x) & 0xFFFFFFFF
end

-- A repeatable number in [0, 1) for a period: the same on every run and every machine, unrelated from one period to the next.
local function uniform(period, seed)
  return mix32(mix32(period + seed * 0x9E3779B1) + 0x7F4A7C15) / 4294967296
end

local function seedOf(tag)
  local seed = 0
  for i = 1, #(tag or "") do seed = (seed * 31 + tag:byte(i)) % 1000003 end
  return seed
end

-- Condition for a position on the severity scale u (0 to 1), by the weights of the mix.
local function conditionOf(u, mix)
  local total = 0
  for _, name in ipairs(M.CONDITIONS) do total = total + mix[name] end
  local r, lastWithWeight = u * total, M.CONDITIONS[1]
  for _, name in ipairs(M.CONDITIONS) do
    if mix[name] > 0 then
      lastWithWeight = name
      r = r - mix[name]
      if r < 0 then return name end
    end
  end
  return lastWithWeight      -- u = 1 exactly: the last condition that has any weight
end

-- The weather at an epoch second: condition, period number, seconds until the next period.
-- Inside a period the severity glides (smoothstep) from this period's random value to the next one's.
function M.at(epoch, c)
  local len = math.max(1, (tonumber(c.periodMinutes) or 15)) * 60
  local period = math.floor(epoch / len)
  local left = len - epoch % len
  local forced = c.force
  if type(forced) == "string" and INDEX[forced] then return forced, period, left end
  local seed = seedOf(c.serverTag)
  local f = (epoch % len) / len
  local s = f * f * (3 - 2 * f)
  local u = uniform(period, seed) * (1 - s) + uniform(period + 1, seed) * s
  -- Gliding between two random values rarely reaches the ends of the scale (storms would almost never happen): stretch it a little.
  -- Measured over thousands of periods, 1.1 gives storms about as often as the mix says; the other conditions land within a few points of their weights.
  u = math.max(0, math.min(1, 0.5 + (u - 0.5) * STRETCH))
  return conditionOf(u, M.mix(c.mix)), period, left
end

function M.tick()
  local c = {periodMinutes = cfg.weather.periodMinutes, mix = cfg.weather.mix, force = cfg.weather.force, serverTag = cfg.serverTag}
  local condition, period, left = M.at(util.now(), c)
  if period ~= lastPeriod then
    lastPeriod = period
    util.info(string.format("RLSMP-P3 weather period %d: %s (%s)", period, condition, cfg.weather.force ~= "" and "forced" or "from the mix"))
  end
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then net.send(pid, "rlsmpWeather", {c = condition, p = period, n = math.floor(left)}) end
  end
end

function M.init(config)
  cfg = config
  local w = cfg.weather
  if not w.enabled then return end
  net.on("rlsmpWeatherTick", M.tick)
  MP.CreateEventTimer("rlsmpWeatherTick", math.max(1000, math.floor((tonumber(w.syncSeconds) or 10) * 1000)))
  util.info("Shared weather on: a new condition every " .. tostring(w.periodMinutes) .. " min" .. ((w.force or "") ~= "" and (", forced: " .. w.force) or ""))
end

return M
