-- RLS-Career-MP client: tiny BeamMP helpers (plain module).
-- SPDX-License-Identifier: AGPL-3.0-only
local M = {}

-- Game vehicle ids that BeamMP knows and that belong to OTHER players.
-- A vehicle BeamMP does not know yet (e.g. a car we just spawned) is never "remote".
function M.remoteSet()
  local set = {}
  if not (MPVehicleGE and MPVehicleGE.getVehicles) then return set end
  for _, v in pairs(MPVehicleGE.getVehicles()) do
    if v.isLocal ~= true and v.gameVehicleID and v.gameVehicleID ~= -1 then set[v.gameVehicleID] = true end
  end
  return set
end

-- How many cars BeamMP counts as MINE (they count against the server's per-player limit MaxCars).
function M.ownCount()
  local n = 0
  if MPVehicleGE and MPVehicleGE.getVehicles then
    for _, v in pairs(MPVehicleGE.getVehicles()) do if v.isLocal == true then n = n + 1 end end
  end
  return n
end

function M.isRemote(id)
  return M.remoteSet()[id] == true
end

-- BeamMP's server id ("0-7") of one of MY cars, or nil. (getServerVehicleID logs errors for cars it does not know.)
function M.serverIdOf(gameVehicleId)
  if not (MPVehicleGE and MPVehicleGE.getVehicles) then return nil end
  for serverId, v in pairs(MPVehicleGE.getVehicles()) do
    if v.gameVehicleID == gameVehicleId then return serverId, v end
  end
  return nil
end

function M.isMPSession()
  return MPCoreNetwork ~= nil and ((MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession())
    or (MPCoreNetwork.isGoingMPSession and MPCoreNetwork.isGoingMPSession())) or false
end

return M
