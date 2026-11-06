-- RLS-Career-MP client extension "rlsmp_police": no police cars popping up in front of you.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- While the player is being chased (pursuit mode >= 1):
--  * every police unit within `leashMeters` of the player has its respawn switched off
--    (RLS's per-vehicle `enableRespawn` flag), so it cannot be faded out and re-placed ahead;
--    units that fall further behind than the leash get their old setting back and may despawn;
--  * roadblocks (RLS places police cars on the road ahead) are refused;
--  * `gameplay_traffic.forceTeleport` on a police unit is refused.
-- Everything is restored when the pursuit ends. Outside multiplayer RLS runs untouched.
-- The server sends the settings in `rlsmpPoliceConfig`; until then the defaults below apply.

local M = {}

local net = require("rlsmp/lib/net")

local CHECK_EVERY = 0.5   -- seconds between leash checks

local settings = {antiTeleport = true, blockRoadblocks = true, leashMeters = 350}
local pursuit = false
local timer = 0
local frozen = {}         -- police vehicle id -> its enableRespawn before we touched it

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
  frozen = {}
end

-- Freeze respawn for police near the player, release the ones that dropped far behind.
local function applyLeash()
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then return end
  local playerId = be:getPlayerVehicleID(0)
  if not playerId then return end
  local px, py, pz = be:getObjectPositionXYZ(playerId)
  if not px then return end
  local leash2 = settings.leashMeters * settings.leashMeters
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    if id ~= playerId and isPolice(veh) then
      local x, y, z = be:getObjectPositionXYZ(id)
      if x then
        local dx, dy, dz = x - px, y - py, z - pz
        if dx * dx + dy * dy + dz * dz <= leash2 then
          if frozen[id] == nil then frozen[id] = veh.enableRespawn ~= false end
          veh.enableRespawn = false
        else
          release(id, veh)
        end
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

local function setPursuit(on)
  if on == pursuit then return end
  pursuit = on
  timer = 0
  if on then
    patch()
    if active() then applyLeash() end
  else
    releaseAll()
  end
end

-- RLS fires this through extensions.hook whenever a pursuit level changes.
function M.onPursuitModeUpdate(targetId, data)
  if not isMP() or not be or targetId ~= be:getPlayerVehicleID(0) then return end
  setPursuit(type(data) == "table" and (tonumber(data.mode) or 0) >= 1)
end

function M.onUpdate(dtReal)
  if not pursuit then return end
  timer = timer + (dtReal or 0)
  if timer < CHECK_EVERY then return end
  timer = 0
  if active() then applyLeash() end
end

local function reset()
  releaseAll()
  pursuit, timer = false, 0
end
M.onServerLeave = reset
-- Career closed / switched: don't leave vehicles frozen.
function M.onOverhaulActive(isActive) if not isActive then reset() end end

local function onConfig(data)
  if type(data.antiTeleport) == "boolean" then settings.antiTeleport = data.antiTeleport end
  if type(data.blockRoadblocks) == "boolean" then settings.blockRoadblocks = data.blockRoadblocks end
  local leash = tonumber(data.leashMeters)
  if leash and leash > 0 then settings.leashMeters = leash end
  if not settings.antiTeleport then releaseAll() end
end

function M.isPursuit() return pursuit end
function M.getSettings() return settings end

function M.onExtensionLoaded()
  net.on("rlsmpPoliceConfig", onConfig)
end

M._onConfig = onConfig
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
