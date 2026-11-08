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

-- Is this game vehicle one that THIS game spawned and owns? Single player (no MPVehicleGE): yes. In a session only a car BeamMP lists as
-- local counts (isLocal, and the player number in its server id "pid-vid" is ours when BeamMP tells us ours). A car BeamMP does not know
-- yet counts as NOT ours. Second value: why not ("remote" | "unregistered" | "not ours").
function M.isOwn(gameVehicleId)
  if not (MPVehicleGE and MPVehicleGE.getVehicles) then return true end
  local serverId, v = M.serverIdOf(gameVehicleId)
  if not serverId then return false, "unregistered" end
  if v.isLocal ~= true then return false, "remote" end
  local mine = MPConfig and MPConfig.getPlayerServerID and MPConfig.getPlayerServerID()
  local pid = tonumber(tostring(serverId):match("^(%d+)%-"))
  if mine and pid and tonumber(mine) ~= pid then return false, "not ours" end
  return true
end

-- The game vehicle id of a BeamMP server id ("pid-vid"), or nil when that car is not in this game (yet).
function M.gameIdOf(sid)
  if not (MPVehicleGE and MPVehicleGE.getVehicles) or type(sid) ~= "string" then return nil end
  local v = MPVehicleGE.getVehicles()[sid]
  local id = v and v.gameVehicleID
  return (id and id ~= -1) and id or nil
end

-- The server id "pid-vid" of a game vehicle (nil when BeamMP does not list it).
function M.sidOf(gameVehicleId)
  local serverId = M.serverIdOf(gameVehicleId)
  return serverId and tostring(serverId) or nil
end

function M.isMPSession()
  return MPCoreNetwork ~= nil and ((MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession())
    or (MPCoreNetwork.isGoingMPSession and MPCoreNetwork.isGoingMPSession())) or false
end

return M
