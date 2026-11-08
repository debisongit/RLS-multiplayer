-- RLS-Career-MP client extension "rlsmp_bubble": traffic never vanishes in front of another player.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS only looks at the LOCAL player when it decides to fade a traffic car out and reuse it (tryRespawn).
-- In multiplayer a car next to your friend could vanish because it is far from you. This wraps tryRespawn:
-- a car may only be recycled when it is more than BUBBLE metres from EVERY other player and none of them has a clear line to it.
-- Other players' own traffic cars (hidden name tags) do not count, only the players themselves.
--
-- Modes (server setting police.bubbleMode, default "original"):
--  * "original": RLS's own distances stay. A car is only kept while another player is closer than the car's OWN active radius
--    (what RLS would use for the local player) AND has a clear line to it. Nothing else changes where cars vanish or appear.
--  * "protect": the old strict rule: kept while within BUBBLE metres of another player, or a clear line up to SIGHT metres.
--  * "off": no protection (RLS decides alone).
-- Police units tied to a chase (rlsmpHold, set by rlsmp/police.lua) are never recycled in any mode.
-- M.stayFor (used by unjam and the model swap, our own recycling) always uses the strict rule.

local M = {}

local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local BUBBLE = 450
local SIGHT = 1000
local DEFAULT_RADIUS = 200   -- used when a car has no active radius (should not happen)
local MODES = {original = true, protect = true, off = true}
local enabled = false
local mode = "original"

function M.enable(on) enabled = on == true end
function M.isEnabled() return enabled end
function M.setMode(m)
  if MODES[m] then mode = m end
end
function M.getMode() return mode end

-- Positions of the other players' cars (and walking characters).
local function playerPositions()
  local list = {}
  if not (MPVehicleGE and MPVehicleGE.getVehicles and map and map.objects) then return list end
  for _, v in pairs(MPVehicleGE.getVehicles()) do
    local id = v.gameVehicleID
    if v.isLocal ~= true and id and id ~= -1 and v.hideNametag ~= true then
      local obj = map.objects[id]
      if obj and obj.pos then list[#list + 1] = obj.pos end
    end
  end
  return list
end

-- true = keep this car where it is. `canSee(a, b)` is true when nothing static is between the points.
function M.mustStay(carPos, players, canSee)
  local limit = BUBBLE * BUBBLE
  for _, p in ipairs(players) do
    if carPos:squaredDistance(p) < limit then return true end
    -- line of sight only matters up to about a kilometre (a ray cast per player is not free)
    if canSee and carPos:squaredDistance(p) < SIGHT * SIGHT and canSee(p, carPos) then return true end
  end
  return false
end

-- "original" mode: keep the car only if another player is inside its own active radius and has a clear line to it.
function M.mustStayOriginal(carPos, radius, players, canSee)
  local limit = (tonumber(radius) or DEFAULT_RADIUS) ^ 2
  for _, p in ipairs(players) do
    if carPos:squaredDistance(p) < limit and (not canSee or canSee(p, carPos)) then return true end
  end
  return false
end

-- For other modules: should this traffic car stay where it is because another player is near or can see it?
function M.stayFor(car)
  if not enabled or not mp.isMPSession() or not car or not car.pos then return false end
  local players = playerPositions()
  if #players == 0 then return false end
  return M.mustStay(car.pos, players, car.checkRayCast and function(a, b) return car:checkRayCast(a, b) end or nil)
end

local wrappers = setmetatable({}, {__mode = "k"})   -- class -> the wrapper we installed

local function anyTrafficClass()
  if not (gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  for _, veh in pairs(gameplay_traffic.getTrafficData()) do
    local class = getmetatable(veh)
    if type(class) == "table" then return class end
  end
end

-- Runs every frame: RLS may replace the method when its services restart, then we wrap the new one.
function M.install()
  local class = anyTrafficClass()
  if not class or type(class.tryRespawn) ~= "function" then return false end
  if wrappers[class] and class.tryRespawn == wrappers[class] then return true end
  local original = class.tryRespawn
  local wrapper
  wrapper = function(self, ...)
    if enabled and self.rlsmpHold then p3.count("bubble: police held") return end   -- a police unit tied to the player's chase (rlsmp/police.lua) must not be recycled
    -- RLS's own cheap gates first: nothing to decide unless RLS is about to recycle this car
    local aboutToGo = self.enableRespawn and type(self.respawn) == "table" and self.focusDist and (tonumber(self.respawn.finalRadius) or math.huge) < self.focusDist
    if enabled and aboutToGo and mode ~= "off" and mp.isMPSession() and self.pos then
      local players = playerPositions()
      if #players > 0 then
        local canSee = self.checkRayCast and function(a, b) return self:checkRayCast(a, b) end or nil
        local keep
        if mode == "protect" then keep = M.mustStay(self.pos, players, canSee)
        else keep = M.mustStayOriginal(self.pos, self.respawn.finalRadius, players, canSee) end
        if keep then p3.count("bubble: kept for another player") return end
      end
    end
    p3.count("bubble: passed to RLS")
    return original(self, ...)
  end
  wrappers[class] = wrapper
  class.tryRespawn = wrapper
  return true
end

function M.onUpdate() M.install() end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
