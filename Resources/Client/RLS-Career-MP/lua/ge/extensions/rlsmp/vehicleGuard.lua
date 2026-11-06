-- RLS-Career-MP client extension "rlsmp_vehicleGuard".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Players may only enter their own cars. Blocked: other players' vehicles (incl. their traffic) and
-- AI traffic / parked cars of the game itself (you can enter them, but can't control them).
-- When a switch is blocked we put the player back in the vehicle they came from (or on foot).
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

function M.onVehicleSwitched(oldId, newId)
  if not enabled or reverting or not M.isBlocked(newId) then return end
  reverting = true
  local old = oldId and oldId >= 0 and be:getObjectByID(oldId)
  if old and not M.isBlocked(oldId) then
    be:enterVehicle(0, old)
  else
    gameplay_walk.setWalkingMode(true)
  end
  reverting = false
  guihooks.trigger("toastrMsg", {type = "warning", title = "RLS Career MP", msg = "You can't drive that vehicle.", config = {timeOut = 3000}})
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
