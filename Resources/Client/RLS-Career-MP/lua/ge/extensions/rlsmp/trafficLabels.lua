-- RLS-Career-MP client extension "rlsmp_trafficLabels": no player name tags on AI traffic.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Sends the server the BeamMP ids of this game's AI traffic and parked cars; receives the same from other players
-- and hides those cars' name tags (MPVehicleGE honours `hideNametag`).

local M = {}

local net = require("rlsmp/lib/net")

local enabled = false
local timer, lastSent = 0, nil
local hidden = {}        -- sender pid -> {serverVehicleId = true}
local EVERY = 2          -- seconds

function M.enable(on)
  enabled = on == true
  if not enabled then timer, lastSent, hidden = 0, nil, {} end
end

-- Server ids ("0-7") of my own cars that are AI traffic or parked cars (not the car a player drives).
function M.collectOwn()
  local gameIds = {}
  local td = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
  for id, veh in pairs(td) do
    if type(veh) == "table" and veh.isAi == true then gameIds[id] = true end
  end
  if gameplay_parking and gameplay_parking.getParkedCarsList then
    for _, id in ipairs(gameplay_parking.getParkedCarsList(true) or {}) do gameIds[id] = true end
  end
  local out = {}
  if MPVehicleGE and MPVehicleGE.getVehicles then
    for serverId, v in pairs(MPVehicleGE.getVehicles()) do
      if v.isLocal == true and gameIds[v.gameVehicleID] then out[#out + 1] = serverId end
    end
  end
  table.sort(out)
  return out
end

local function applyHidden()
  if not (MPVehicleGE and MPVehicleGE.getVehicles) then return end
  local vehicles = MPVehicleGE.getVehicles()
  for _, set in pairs(hidden) do
    for serverId in pairs(set) do
      local v = vehicles[serverId]
      if v and not v.hideNametag then v.hideNametag = true end
    end
  end
end

-- true once this player's list reached us (before that we cannot tell their AI and parked cars from their own car).
function M.heardFrom(pid) return hidden[tonumber(pid)] ~= nil end

local function onRx(msg)
  if not enabled or type(msg.ids) ~= "table" then return end
  msg.from = tonumber(msg.from) or msg.from
  local vehicles = MPVehicleGE and MPVehicleGE.getVehicles and MPVehicleGE.getVehicles() or {}
  local new = {}
  for _, id in ipairs(msg.ids) do new[id] = true end
  -- cars that stopped being traffic get their tag back
  for id in pairs(hidden[msg.from] or {}) do
    if not new[id] and vehicles[id] then vehicles[id].hideNametag = false end
  end
  hidden[msg.from] = new
  applyHidden()
end

function M.onUpdate(dtReal)
  if not enabled then return end
  timer = timer + (dtReal or 0)
  if timer < EVERY then return end
  timer = 0
  applyHidden()   -- traffic that arrived after the list did
  local ids = M.collectOwn()
  local key = table.concat(ids, ",")
  if key ~= lastSent then
    lastSent = key
    net.send("rlsmpTrafficIds", {ids = ids})
  end
end

function M.onExtensionLoaded()
  net.on("rlsmpTrafficIdsRx", onRx)
end

M._onRx = onRx
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
