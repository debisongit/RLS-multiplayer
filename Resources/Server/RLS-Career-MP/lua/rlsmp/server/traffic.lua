-- RLS-Career-MP server: traffic director (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every player's game simulates its own AI traffic. If 10 players each run 30 cars the server
-- area is flooded, so the director hands out a shared budget: each career player gets a
-- ceiling for how many traffic cars their game may keep active (`rlsmpTrafficQuota`).
--
--   quota = clamp(floor(totalBudget / playersInCareer), minPerPlayer, maxPerPlayer)
--
-- It owns its own timer and only watches `sessions`; it never registers the join/leave events
-- that sessions.lua already uses (the net layer allows one handler per event name).

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

local cfg            -- the `traffic` section of the config
local known = {}     -- pid -> quota we last sent
local revision = 0

-- Pure: how many cars each player may have, given how many players are in career.
function M.quotaFor(count, c)
  c = c or cfg
  if count < 1 then return c.maxPerPlayer end
  local share = math.floor(c.totalBudget / count)
  return math.max(c.minPerPlayer, math.min(c.maxPerPlayer, share))
end

local function loadedPlayers()
  local list = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then list[#list + 1] = pid end
  end
  table.sort(list)
  return list
end

-- Recompute and send quotas to everyone whose number changed (and to new arrivals).
function M.rebalance()
  local list = loadedPlayers()
  local quota = M.quotaFor(#list)
  local live, bumped = {}, false
  for _, pid in ipairs(list) do
    live[pid] = true
    if known[pid] ~= quota then
      if not bumped then revision, bumped = revision + 1, true end
      known[pid] = quota
      net.send(pid, "rlsmpTrafficQuota", {active = quota, players = #list, rev = revision})
      util.info(string.format("RLSMP-P3 traffic quota sent to pid=%s active=%d players=%d rev=%d", tostring(pid), quota, #list, revision))
    end
  end
  for pid in pairs(known) do
    if not live[pid] then known[pid] = nil end
  end
end

function M.current(pid) return known[pid] end

local function tick()
  if not cfg.enabled then return end
  M.rebalance()
end

function M.init(config)
  cfg = config.traffic
  known, revision = {}, 0
  net.on("rlsmpTrafficTick", tick)
  MP.CreateEventTimer("rlsmpTrafficTick", math.max(250, math.floor((cfg.checkSeconds or 1) * 1000)))
  util.info("Traffic director on: budget " .. cfg.totalBudget .. ", " .. cfg.minPerPlayer .. "-" .. cfg.maxPerPlayer .. " per player")
end

return M
