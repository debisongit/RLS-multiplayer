-- RLS-Career-MP client extension "rlsmp_traffic": obeys the server's traffic budget.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server (server/traffic.lua) sends `rlsmpTrafficQuota {active}` = the most traffic cars
-- this game may keep active. We treat it as a CEILING: RLS and its events may lower traffic
-- (e.g. to 0 during a race) and we leave that alone, but never let it rise above the quota.

local M = {}

local net = require("rlsmp/lib/net")
local p3 = require("rlsmp/lib/p3")

local CHECK_EVERY = 3     -- seconds between ceiling checks
local quota               -- nil until the server sends one
local timer = 0

local function isMP()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
end

local function careerActive()
  return overhaul_career_career ~= nil and overhaul_career_career.isActive()
end

-- Lower the active traffic amount to the quota if it is above it. Returns true if we changed it.
local function enforce()
  if not quota or not isMP() or not careerActive() then return false end
  if not gameplay_traffic or not gameplay_traffic.setActiveAmount or not gameplay_traffic.getTrafficVars then return false end
  local vars = gameplay_traffic.getTrafficVars()
  local current = vars and tonumber(vars.activeAmount)
  if current and current > quota then
    gameplay_traffic.setActiveAmount(quota)
    p3.count("traffic ceiling applied")
    p3.log("I", string.format("TRAFFIC ceiling lowered %s -> %s", tostring(current), tostring(quota)))
    return true
  end
  p3.count("traffic checks (already within quota)")
  return false
end

local function onQuota(data)
  local n = tonumber(data.active)
  if not n or n < 0 then return end
  quota = math.floor(n)
  p3.count("quota messages")
  p3.log("I", string.format("quota received active=%s players=%s rev=%s", tostring(quota), tostring(data.players), tostring(data.rev)))
  enforce()
end

function M.getQuota() return quota end

function M.onUpdate(dtReal)
  if not quota then return end
  timer = timer + (dtReal or 0)
  if timer >= CHECK_EVERY then
    timer = 0
    enforce()
  end
end

function M.onServerLeave()
  quota, timer = nil, 0
end

function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpTrafficQuota", onQuota)
  p3.log("I", "rlsmp_traffic loaded")
  p3.probe("gameplay_traffic.setActiveAmount is a function", gameplay_traffic ~= nil and type(gameplay_traffic.setActiveAmount) == "function")
  p3.probe("gameplay_traffic.getTrafficVars is a function", gameplay_traffic ~= nil and type(gameplay_traffic.getTrafficVars) == "function")
end

M._onQuota = onQuota
M._enforce = enforce
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
