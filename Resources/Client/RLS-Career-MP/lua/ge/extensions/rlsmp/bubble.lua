-- RLS-Career-MP client extension "rlsmp_bubble": traffic never vanishes in front of another player.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS only looks at the LOCAL player when it decides to fade a traffic car out and reuse it (tryRespawn).
-- In multiplayer a car next to your friend could vanish because it is far from you. This wraps tryRespawn:
-- a car may only be recycled when it is more than BUBBLE metres from EVERY other player and none of them has a clear line to it.
-- Other players' own traffic cars (hidden name tags) do not count, only the players themselves.

local M = {}

local mp = require("rlsmp/lib/mp")

local BUBBLE = 450
local enabled = false

function M.enable(on) enabled = on == true end

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
    if canSee and canSee(p, carPos) then return true end
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
    if enabled and mp.isMPSession() and self.pos then
      local players = playerPositions()
      if #players > 0 and M.mustStay(self.pos, players, self.checkRayCast and function(a, b) return self:checkRayCast(a, b) end or nil) then
        return
      end
    end
    return original(self, ...)
  end
  wrappers[class] = wrapper
  class.tryRespawn = wrapper
  return true
end

function M.onUpdate() M.install() end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
