-- RLS-Career-MP client extension "rlsmp_police": no police cars popping up in front of you.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- While the player is being chased (their traffic-data pursuit.mode >= 1):
--  * EVERY police unit has its respawn switched off (RLS's per-vehicle `enableRespawn` flag), so it
--    cannot be faded out and re-placed along the route ahead of you;
--  * roadblocks (RLS places police cars on the road ahead) are refused;
--  * `gameplay_traffic.forceTeleport` on a police unit is refused.
-- Everything is restored when the pursuit ends. Outside multiplayer RLS runs untouched.
--
-- The pursuit state is read from the player's traffic data every check, not only from the RLS hook,
-- because RLS resets `pursuit.mode` directly in several places (evade, arrest, vehicle switch).
-- A respawn-count watch warns if a unit is re-placed anyway (a path we do not block).
-- The server sends the settings in `rlsmpPoliceConfig`; until then the defaults below apply.

local M = {}

local net = require("rlsmp/lib/net")

local CHECK_EVERY = 0.5   -- seconds between pursuit checks

local settings = {antiTeleport = true, blockRoadblocks = true}
local pursuit = false
local timer = 0
local frozen = {}         -- police vehicle id -> its enableRespawn before we touched it
local seenRespawns = {}   -- police vehicle id -> respawnCount when the pursuit started
local leaks = 0           -- units re-placed during a pursuit despite the freeze

local function isMP()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
end

local function active()
  return pursuit and settings.antiTeleport and isMP()
    and overhaul_career_career ~= nil and overhaul_career_career.isActive()
end

local function isPolice(veh)
  return type(veh) == "table" and type(veh.role) == "table" and veh.role.name == "police"
end

local function release(id, veh)
  if frozen[id] ~= nil then
    if veh then veh.enableRespawn = frozen[id] end
    frozen[id] = nil
  end
end

local function releaseAll()
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
  for id in pairs(frozen) do release(id, traffic[id]) end
  frozen, seenRespawns = {}, {}
end

local function playerTraffic()
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then return nil end
  local playerId = be:getPlayerVehicleID(0)
  return playerId, gameplay_traffic.getTrafficData()
end

-- Freeze respawn for every police unit and watch for units that get re-placed anyway.
local function freezePolice()
  local playerId, traffic = playerTraffic()
  if not traffic then return end
  for id, veh in pairs(traffic) do
    if id ~= playerId and isPolice(veh) then
      if frozen[id] == nil then
        frozen[id] = veh.enableRespawn ~= false
        seenRespawns[id] = veh.respawnCount
      end
      veh.enableRespawn = false
      local count = veh.respawnCount
      if type(count) == "number" and type(seenRespawns[id]) == "number" and count > seenRespawns[id] then
        leaks = leaks + 1
        seenRespawns[id] = count
        log("W", "RLS-Career-MP", "Police unit " .. tostring(id) .. " was re-placed during a pursuit")
      end
    end
  end
end

-- Wrap table[name] once; `refuse(...)` returning true means "block this call".
local function wrap(tbl, name, refuse, refusedValue)
  if type(tbl) ~= "table" or type(tbl[name]) ~= "function" or tbl["__rlsmp_" .. name] then return end
  local original = tbl[name]
  tbl[name] = function(...)
    if active() and refuse(...) then return refusedValue end
    return original(...)
  end
  tbl["__rlsmp_" .. name] = true
end

local function patch()
  local police = overhaul_integration_services_police
  wrap(police, "setupRoadblock", function() return settings.blockRoadblocks end, nil)
  wrap(gameplay_traffic, "forceTeleport", function(id)
    local veh = gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[id]
    return isPolice(veh)
  end, false)
end

local function playerPursuitMode()
  local playerId, traffic = playerTraffic()
  local veh = traffic and traffic[playerId]
  return veh and type(veh.pursuit) == "table" and tonumber(veh.pursuit.mode) or 0
end

local function setPursuit(on)
  if on == pursuit then return end
  pursuit = on
  timer = 0
  if on then
    patch()
    if active() then freezePolice() end
  else
    releaseAll()
  end
end

-- Compare our state with the real one; this is the source of truth.
local function sync()
  if not isMP() or not be or not overhaul_career_career or not overhaul_career_career.isActive() then return end
  setPursuit(playerPursuitMode() >= 1)
  if pursuit and active() then freezePolice() end
end

-- RLS fires this through extensions.hook whenever a pursuit level changes: just a fast start.
function M.onPursuitModeUpdate() sync() end

function M.onUpdate(dtReal)
  timer = timer + (dtReal or 0)
  if timer < CHECK_EVERY then return end
  timer = 0
  sync()
end

local function reset()
  releaseAll()
  pursuit, timer, leaks = false, 0, 0
end
M.onServerLeave = reset
-- Career closed / switched: don't leave vehicles frozen.
function M.onOverhaulActive(isActive) if not isActive then reset() end end

local function onConfig(data)
  if type(data.antiTeleport) == "boolean" then settings.antiTeleport = data.antiTeleport end
  if type(data.blockRoadblocks) == "boolean" then settings.blockRoadblocks = data.blockRoadblocks end
  if not settings.antiTeleport then releaseAll() end
end

function M.isPursuit() return pursuit end
function M.getSettings() return settings end
function M.getLeaks() return leaks end

function M.onExtensionLoaded()
  net.on("rlsmpPoliceConfig", onConfig)
end

M._onConfig = onConfig
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
