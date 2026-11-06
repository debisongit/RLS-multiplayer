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
local p3 = require("rlsmp/lib/p3")

local CHECK_EVERY = 0.5   -- seconds between pursuit checks

local settings = {antiTeleport = true, blockRoadblocks = true}
local pursuit = false
local timer = 0
local frozen = {}         -- police vehicle id -> its enableRespawn before we touched it
local seenRespawns = {}   -- police vehicle id -> respawnCount when the pursuit started
local leaks = 0           -- units re-placed during a pursuit despite the freeze
local hookMode = 0        -- last pursuit mode the RLS hook reported for the player (fallback)
local pursuitStart = 0    -- os.clock() when the current pursuit began
local patched = {}        -- name -> true once a wrapper is installed

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
    p3.count("units released")
    p3.log("I", string.format("RELEASED police id=%s enableRespawn back to %s", tostring(id), tostring(frozen[id])))
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
  local policeNow = 0
  for id, veh in pairs(traffic) do
    if id ~= playerId and isPolice(veh) then
      policeNow = policeNow + 1
      if frozen[id] == nil then
        frozen[id] = veh.enableRespawn ~= false
        seenRespawns[id] = veh.respawnCount
        p3.count("units frozen")
        p3.log("I", string.format("FROZE police id=%s respawnCount=%s was enableRespawn=%s",
          tostring(id), tostring(veh.respawnCount), tostring(frozen[id])))
      end
      veh.enableRespawn = false
      local count = veh.respawnCount
      if type(count) == "number" and type(seenRespawns[id]) == "number" and count > seenRespawns[id] then
        leaks = leaks + 1
        seenRespawns[id] = count
        p3.count("LEAKS (re-placed while frozen)")
        p3.log("W", string.format("LEAK police id=%s was re-placed during the pursuit (respawnCount %s)", tostring(id), tostring(count)))
      end
    end
  end
  local most = p3.get("most police at once")
  if policeNow > most then p3.count("most police at once", policeNow - most) end
end

-- Wrap table[name] once; `refuse(...)` returning true means "block this call".
local function wrap(tbl, name, label, refuse, refusedValue)
  if type(tbl) ~= "table" then return false end
  if type(tbl[name]) ~= "function" then return false end
  if tbl["__rlsmp_" .. name] then return true end
  local original = tbl[name]
  tbl[name] = function(...)
    if active() and refuse(...) then
      local site = p3.caller()
      p3.count(label .. " BLOCKED")
      p3.countCaller(label .. " BLOCKED", site)
      p3.log("I", "BLOCKED " .. label .. " from " .. site)
      return refusedValue
    end
    p3.count(label .. " allowed")
    p3.countCaller(label .. " allowed", p3.caller())
    return original(...)
  end
  tbl["__rlsmp_" .. name] = true
  return true
end

local function patch()
  local police = overhaul_integration_services_police
  local function note(key, ok)
    if ok and not patched[key] then
      patched[key] = true
      p3.log("I", "patched " .. key .. " = true")
    elseif not ok then
      p3.logOnChange("patchfail " .. key, true, "W", "patched " .. key .. " = false (not available yet, will retry)")
    end
  end
  note("setupRoadblock", wrap(police, "setupRoadblock", "setupRoadblock", function() return settings.blockRoadblocks end, nil))
  note("forceTeleport", wrap(gameplay_traffic, "forceTeleport", "forceTeleport(police)", function(id)
    local veh = gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[id]
    return isPolice(veh)
  end, false))
end

-- The player's real pursuit level. Falls back to what the RLS hook told us if the player's car
-- is not in the traffic data (then the probe line says so).
local function playerPursuitMode()
  local playerId, traffic = playerTraffic()
  local veh = traffic and traffic[playerId]
  local inTraffic = veh ~= nil and type(veh.pursuit) == "table"
  p3.logOnChange("playerInTraffic", inTraffic, "I", "probe: player vehicle in traffic data = " .. tostring(inTraffic))
  if inTraffic then return tonumber(veh.pursuit.mode) or 0 end
  return hookMode
end

local function setPursuit(on)
  if on == pursuit then return end
  pursuit = on
  timer = 0
  if on then
    pursuitStart = os.clock()
    p3.count("pursuits started")
    p3.log("I", string.format("pursuit START mode=%s antiTeleport=%s blockRoadblocks=%s",
      tostring(playerPursuitMode()), tostring(settings.antiTeleport), tostring(settings.blockRoadblocks)))
    patch()
    if active() then freezePolice() end
  else
    p3.count("pursuits ended")
    p3.log("I", string.format("pursuit END after %.0fs, units frozen at end=%d, leaks so far=%d",
      os.clock() - pursuitStart, (function() local n = 0 for _ in pairs(frozen) do n = n + 1 end return n end)(), leaks))
    releaseAll()
  end
end

-- Compare our state with the real one; this is the source of truth.
local function sync()
  if not isMP() or not be or not overhaul_career_career or not overhaul_career_career.isActive() then return end
  setPursuit(playerPursuitMode() >= 1)
  if pursuit then patch() end   -- retry wrappers until RLS's police service exists
  if pursuit and active() then freezePolice() end
end

-- RLS fires this through extensions.hook whenever a pursuit level changes: just a fast start.
function M.onPursuitModeUpdate(targetId, data)
  if be and targetId == be:getPlayerVehicleID(0) then
    hookMode = type(data) == "table" and tonumber(data.mode) or 0
    p3.log("I", "hook onPursuitModeUpdate mode=" .. tostring(hookMode))
  end
  sync()
end

function M.onUpdate(dtReal)
  timer = timer + (dtReal or 0)
  if timer < CHECK_EVERY then return end
  timer = 0
  sync()
end

local function reset()
  releaseAll()
  pursuit, timer, leaks, hookMode = false, 0, 0, 0
end
M.onServerLeave = reset
-- Career closed / switched: don't leave vehicles frozen.
function M.onOverhaulActive(isActive) if not isActive then reset() end end

local function onConfig(data)
  p3.log("I", string.format("config received antiTeleport=%s blockRoadblocks=%s", tostring(data.antiTeleport), tostring(data.blockRoadblocks)))
  if type(data.antiTeleport) == "boolean" then settings.antiTeleport = data.antiTeleport end
  if type(data.blockRoadblocks) == "boolean" then settings.blockRoadblocks = data.blockRoadblocks end
  if not settings.antiTeleport then releaseAll() end
end

function M.isPursuit() return pursuit end
function M.getSettings() return settings end
function M.getLeaks() return leaks end
function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpPoliceConfig", onConfig)
  p3.log("I", "rlsmp_police loaded")
  p3.probe("MPCoreNetwork present", MPCoreNetwork ~= nil)
  p3.probe("RLS career module present", overhaul_career_career ~= nil)
  p3.probe("RLS police service present", overhaul_integration_services_police ~= nil)
  p3.probe("gameplay_traffic present", gameplay_traffic ~= nil)
  p3.probe("gameplay_traffic.forceTeleport is a function", gameplay_traffic ~= nil and type(gameplay_traffic.forceTeleport) == "function")
  p3.probe("debug.getinfo available (caller sites)", debug ~= nil and debug.getinfo ~= nil)
end

M._onConfig = onConfig
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
