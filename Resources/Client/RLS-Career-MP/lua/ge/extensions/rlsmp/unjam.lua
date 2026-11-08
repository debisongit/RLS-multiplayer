-- RLS-Career-MP client extension "rlsmp_unjam": stuck traffic cars (standing still for 120 s, 400 m or more from every player) are recycled one by one.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Uses RLS's own recycle: a car in state 'fadeOut' fades away and RLS puts it back somewhere else.
-- Never recycles a car a player can see (local camera) or that is near/visible to another player (rlsmp_bubble),
-- never police, job or pursuit cars (same skip rules as the personalities).

local M = {}

local U = require("rlsmp/lib/unjam")

local enabled = false
local tracker = U.new()
local clock, timer = 0, 0
local CHECK_EVERY = 1

-- Server settings (traffic.unjam: enabled, seconds, distance), pushed through rlsmp_police's config. Nothing recycles while `enabled` is false.
local allowed = true
function M.configure(c)
  if type(c) ~= "table" then return end
  allowed = c.enabled ~= false
  if tonumber(c.seconds) then U.STUCK_SECONDS = tonumber(c.seconds) end
  if tonumber(c.distance) then U.MIN_DISTANCE = tonumber(c.distance) end
  U.CRASHED = c.crashed ~= false
  if tonumber(c.crashedSeconds) then U.CRASHED_SECONDS = tonumber(c.crashedSeconds) end
  if tonumber(c.inViewSeconds) then U.IN_VIEW_SECONDS = tonumber(c.inViewSeconds) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then tracker = U.new() end
end

-- Extensions are found by their global name first (as core.lua does), then by module path.
local function personalities() return rawget(_G, "rlsmp_personalities") or package.loaded["rlsmp/personalities"] end
local function bubble() return rawget(_G, "rlsmp_bubble") or package.loaded["rlsmp/bubble"] end
local function personality() return package.loaded["rlsmp/lib/personality"] end

local function recycle(veh)
  if type(veh.queuedFuncs) == "table" then for k in pairs(veh.queuedFuncs) do veh.queuedFuncs[k] = nil end end
  local obj
  if getObjectByID then obj = getObjectByID(veh.id)
  elseif be and be.getObjectByID then obj = be:getObjectByID(veh.id) end
  if obj and obj.queueLuaCommand then obj:queueLuaCommand("electrics.horn(false)") end
  veh.state = "fadeOut"
end

local function hpNow() return (os.clockhp or os.clock)() end   -- RLS stamps activeData.tCrash with os.clockhp()

-- One round. Returns the id that was recycled, if any (for tests and logs).
function M.check()
  if not allowed or not (gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  local P, ps = personality(), personalities()
  if not (P and ps and ps.context) then return nil end
  local ctx = ps.context()
  local b = bubble()
  local candidates = {}
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    -- only cars RLS itself would recycle: respawn allowed (a car with respawn off would fade out and stay invisible)
    local respawnOk = veh.enableRespawn ~= false and (type(veh.respawn) ~= "table" or (tonumber(veh.respawn.spawnValue) or 1) > 0)
    local fill = rawget(_G, "rlsmp_trafficFill") or package.loaded["rlsmp/trafficFill"]
    local reason = P.skipReason(id, veh, ctx)
    local crashAge
    if reason == "crashed" then   -- RLS's crash flag alone is no reason to skip here: judge the rest with the flag hidden
      crashAge = hpNow() - veh.activeData.tCrash
      reason = P.skipReason(id, setmetatable({activeData = false}, {__index = veh}), ctx)
    end
    if veh.pos and respawnOk and not (fill and fill.isNew and fill.isNew(id)) and reason == nil then   -- cars the traffic fill just added are left alone
      local stuck = U.seen(tracker, id, veh.pos.x, veh.pos.y, tonumber(veh.speed) or 0, clock)
      if crashAge then
        -- a crashed car near a player: needs the bubble (we must know where everybody is) and nobody else relying on it
        if b and b.viewReason and not (b.isEnabled and not b.isEnabled()) and not (b.stayFor and b.stayFor(veh)) then
          local hidden = b.viewReason(veh) == nil and veh.camVisible ~= true
          local d = b.minPlayerDistance and b.minPlayerDistance(veh)
          if U.crashDue(crashAge, stuck, hidden, d) then
            candidates[#candidates + 1] = {id = id, stuck = crashAge, due = true, crash = {age = crashAge, dist = d, seen = not hidden}}
          end
        end
      elseif stuck >= U.STUCK_SECONDS then
        local bubbleOff = b and b.isEnabled and not b.isEnabled()   -- without the bubble we do not know where the other players are
        local hidden = veh.camVisible ~= true and not bubbleOff and not (b and b.stayFor and b.stayFor(veh))
        if hidden and b and b.viewReason and b.viewReason(veh) then hidden = false end   -- strict: near a player or in front of the camera
        -- far from EVERY player (own game and the others); unknown distance counts as near
        if hidden then
          local d = b and b.minPlayerDistance and b.minPlayerDistance(veh)
          if not d or d < U.MIN_DISTANCE then hidden = false end
        end
        candidates[#candidates + 1] = {id = id, stuck = stuck, hidden = hidden}
      end
    end
  end
  U.sweep(tracker, clock)
  local id = U.pick(tracker, candidates, clock)
  if id then
    recycle(gameplay_traffic.getTrafficData()[id])
    for _, c in ipairs(candidates) do
      if c.id == id and c.crash then
        log("I", "RLS-Career-MP", string.format("unjam: crashed car id=%s dist=%s seen=%s removed after %ds", tostring(id), c.crash.dist and string.format("%.0f", c.crash.dist) or "?", tostring(c.crash.seen), c.crash.age))
        return id
      end
    end
    log("I", "RLS-Career-MP", "unjam: recycled stuck traffic car " .. tostring(id) .. " after " .. tostring(U.STUCK_SECONDS) .. " s, nearest player >= " .. tostring(U.MIN_DISTANCE) .. " m")
  end
  return id
end

function M.onUpdate(dtReal)
  if not enabled then return end
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
