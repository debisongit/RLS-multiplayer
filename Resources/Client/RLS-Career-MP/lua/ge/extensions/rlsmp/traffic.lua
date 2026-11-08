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
local wantMin = 0         -- the server's wished lowest traffic amount (traffic.minAmount), 0 = leave the player's own
local original, setByUs   -- the player's own traffic amount before we lowered it, and the value we set (to tell our change from RLS's)
local timer = 0
local HOLD_EVERY = 10   -- seconds between re-applications of the minimum amount
local clock, lastHold = 0, -HOLD_EVERY

local function isMP()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
end

local function careerActive()
  return overhaul_career_career ~= nil and overhaul_career_career.isActive()
end

local function chased()
  return rlsmp_police ~= nil and rlsmp_police.isPursuit ~= nil and rlsmp_police.isPursuit() == true
end

-- Keep traffic within the quota. Lowers it when above; raises it back (never above the player's own amount)
-- when the quota grew again, but only if the amount is still the one we set (RLS did not change it meanwhile).
-- Returns true if we changed it.
local function enforce()
  if not quota or not isMP() or not careerActive() then return false end
  if not gameplay_traffic or not gameplay_traffic.setActiveAmount or not gameplay_traffic.getTrafficVars then return false end
  local vars = gameplay_traffic.getTrafficVars()
  local current = vars and tonumber(vars.activeAmount)
  if not current then return false end
  if current > quota then
    if chased() then return false end   -- cutting traffic in the middle of a chase could deactivate the cops
    original = math.max(original or 0, current)
    gameplay_traffic.setActiveAmount(quota)
    setByUs = quota
    p3.count("traffic ceiling applied")
    p3.log("I", string.format("TRAFFIC ceiling lowered %s -> %s", tostring(current), tostring(quota)))
    return true
  end
  if setByUs and current == setByUs and original and quota > current and original > current then
    local raised = math.min(quota, original)
    gameplay_traffic.setActiveAmount(raised)
    setByUs = raised
    p3.log("I", string.format("TRAFFIC ceiling raised %s -> %s", tostring(current), tostring(raised)))
    return true
  end
  p3.count("traffic checks (already within quota)")
  return false
end

-- A game that starts with a tiny traffic amount (a log showed 4) shows the same few cars again and again. Lift it once to the server's
-- minimum (never above the quota, never while traffic is off or in a chase). Done when the quota arrives, not every frame, so RLS can still lower it.
function M.raiseToMin()
  if not quota or wantMin <= 0 or not isMP() or not careerActive() or chased() then return false end
  if not gameplay_traffic or not gameplay_traffic.setActiveAmount or not gameplay_traffic.getTrafficVars then return false end
  local vars = gameplay_traffic.getTrafficVars()
  local current = vars and tonumber(vars.activeAmount)
  local target = math.min(quota, wantMin)
  if not current or current < 1 or current >= target then return false end
  original = original or current
  lastHold = clock
  gameplay_traffic.setActiveAmount(target)
  setByUs = target
  local after = gameplay_traffic.getTrafficVars()
  p3.log("I", string.format("TRAFFIC amount raised %s -> %s (server minimum), read back %s", tostring(current), tostring(target), tostring(after and after.activeAmount)))
  return true
end

-- RLS resets the active amount to the player's own game setting whenever it recomputes it (settings change, our parked-cars top-up calls
-- onSettingsChanged, traffic restarts). The log showed 4 again 5 s after we raised it to 10. So every few seconds: if the amount is back at that
-- RLS value (not lowered by an event, which sets 0 or other numbers) and below our target, set it again and log the value READ BACK.
local function carCount()
  local n = 0
  for _ in pairs(gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}) do n = n + 1 end
  return n
end
function M.holdMin()
  if not quota or wantMin <= 0 or not isMP() or not careerActive() or chased() then return false end
  if not gameplay_traffic or not gameplay_traffic.setActiveAmount or not gameplay_traffic.getTrafficVars then return false end
  local target = math.min(quota, wantMin)
  local vars = gameplay_traffic.getTrafficVars()
  local current = vars and tonumber(vars.activeAmount)
  if not current or current < 1 or current >= target or clock - lastHold < HOLD_EVERY then return false end
  local own = settings and settings.getValue and tonumber(settings.getValue("trafficAmount"))
  if not own or own < 1 or (current ~= own and current ~= own - 1) then return false end   -- not RLS's own default: an event lowered it, leave it
  lastHold = clock
  original = original or current
  gameplay_traffic.setActiveAmount(target)
  setByUs = target
  local after = gameplay_traffic.getTrafficVars()
  local cars = carCount()
  p3.count("traffic amount held")
  p3.log("I", string.format("TRAFFIC amount was reset by the game to %s, set to %s again, read back %s, cars in traffic %d%s", tostring(current), tostring(target),
    tostring(after and after.activeAmount), cars, cars < target and " (the game made only that many cars at start: more cars need a traffic restart)" or ""))
  return true
end

local function onQuota(data)
  local n = tonumber(data.active)
  if not n or n < 0 then return end
  quota = math.floor(n)
  wantMin = math.max(0, math.floor(tonumber(data.min) or 0))
  p3.count("quota messages")
  p3.log("I", string.format("quota received active=%s min=%s players=%s rev=%s", tostring(quota), tostring(wantMin), tostring(data.players), tostring(data.rev)))
  if not enforce() then M.raiseToMin() end
end

function M.getQuota() return quota end
-- The number of cars the server wants to exist: min(quota, minAmount), 0 = no wish (rlsmp/trafficFill.lua builds the missing ones).
function M.getWant() return quota and wantMin > 0 and math.min(quota, wantMin) or 0 end

function M.onUpdate(dtReal)
  if not quota then return end
  timer = timer + (dtReal or 0)
  clock = clock + (dtReal or 0)
  if timer >= CHECK_EVERY then
    timer = 0
    if not enforce() then M.holdMin() end
  end
end

function M.onServerLeave()
  -- Give the player their own traffic amount back (only if nothing else changed it since).
  if original and setByUs and gameplay_traffic and gameplay_traffic.getTrafficVars and gameplay_traffic.setActiveAmount then
    local vars = gameplay_traffic.getTrafficVars()
    if vars and tonumber(vars.activeAmount) == setByUs then gameplay_traffic.setActiveAmount(original) end
  end
  quota, timer, original, setByUs = nil, 0, nil, nil
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
M._resetClock = function() clock, lastHold = 0, -HOLD_EVERY end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("traffic", M)
return M
