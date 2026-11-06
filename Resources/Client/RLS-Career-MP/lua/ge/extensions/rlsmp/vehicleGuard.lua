-- RLS-Career-MP client extension "rlsmp_vehicleGuard".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Players may only enter their own cars. Blocked: other players' vehicles (incl. their traffic) and
-- AI traffic / parked cars of the game itself (you can enter them, but can't control them).
-- Entering is refused BEFORE it happens (RLS and the game ask gameplay_walk.isVehicleBlacklisted / getInVehicle first),
-- because once a walking player is inside a car BeamMP deletes their walking character, and there is nothing to return to.
-- If a switch still slips through (e.g. the vehicle menu), we put the player back in their old car, or on foot beside it.
-- A future "steal a car" feature would add its exception in isBlocked().

local M = {}

local mp = require("rlsmp/lib/mp")

local enabled = false
local reverting = false

function M.enable(on) enabled = on == true end

local function listHas(list, id)
  for _, v in ipairs(list or {}) do if v == id then return true end end
  return false
end

-- true = the player must not sit in this vehicle.
function M.isBlocked(id)
  if not id or id < 0 then return false end
  -- Only vehicles BeamMP knows as another player's. A car RLS just spawned is not registered yet and stays allowed.
  if mp.isRemote(id) then return true end
  if gameplay_traffic and gameplay_traffic.getTrafficData then
    local td = gameplay_traffic.getTrafficData()[id]
    if td and td.isAi == true then return true end
  end
  if gameplay_parking and gameplay_parking.getParkedCarsList then
    if listHas(gameplay_parking.getParkedCarsList(true), id) then return true end
  end
  return false
end

local function toast()
  guihooks.trigger("toastrMsg", {type = "warning", title = "RLS Career MP", msg = "You can't drive that vehicle.", config = {timeOut = 3000}})
end

local function idOf(vehicle)
  if type(vehicle) == "number" then return vehicle end
  return vehicle and vehicle.getID and vehicle:getID() or vehicle and vehicle.getId and vehicle:getId() or nil
end

-- Wrap the walking module once per module table (it can be reloaded; this runs every frame).
local wrapped = setmetatable({}, {__mode = "k"})
function M.install()
  local walk = gameplay_walk
  if not walk or wrapped[walk] then return walk ~= nil end
  wrapped[walk] = true
  local originalBlacklisted, originalGetIn = walk.isVehicleBlacklisted, walk.getInVehicle
  walk.isVehicleBlacklisted = function(vehId, ...)
    if enabled and M.isBlocked(vehId) then return true end
    if originalBlacklisted then return originalBlacklisted(vehId, ...) end
    return false
  end
  if originalGetIn then
    walk.getInVehicle = function(vehicle, ...)
      if enabled and M.isBlocked(idOf(vehicle)) then toast() return end
      return originalGetIn(vehicle, ...)
    end
  end
  return true
end

function M.onVehicleSwitched(oldId, newId)
  if not enabled or reverting or not M.isBlocked(newId) then return end
  reverting = true
  local old = oldId and oldId >= 0 and be:getObjectByID(oldId)
  if old and (old.jbeam or old.JBeam) ~= "unicycle" and not M.isBlocked(oldId) then
    be:enterVehicle(0, old)
  else
    -- The walking character is gone by now: stand next to the car we were refused instead of a default spawn.
    local refused = be:getObjectByID(newId)
    local pos = refused and refused:getPosition()
    gameplay_walk.setWalkingMode(true, pos and (pos + vec3(0, 0, 0.5)) or nil)
  end
  reverting = false
  toast()
end

function M.onUpdate()
  M.install()
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
