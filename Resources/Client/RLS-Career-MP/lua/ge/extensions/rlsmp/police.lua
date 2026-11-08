-- RLS-Career-MP client extension "rlsmp_police": no police cars popping up in front of you.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- While the player is being chased (their traffic-data pursuit.mode >= 1):
--  * police units tied to the chase have their respawn switched off (RLS's per-vehicle `enableRespawn`
--    flag), so they cannot be faded out and re-placed along the route ahead of you. "Tied" means: the
--    unit RLS sees as nearest (`pursuit.sight.policeId`), the unit of the current roadblock
--    (`pursuit.roadblockTargetId`), or any police car within FREEZE_RADIUS of the player's car. A unit is
--    released again once it is none of these and further than RELEASE_RADIUS (a little gap so a unit on
--    the edge does not flip every check). RLS sets `role.targetId` on EVERY unit when a pursuit starts
--    (setPursuitMode is always called without a police list), so we cannot use that to pick units.
--    If the player's position is unknown, every police unit is frozen (the old behaviour, safe side);
--  * roadblocks (RLS places police cars on the road ahead) are refused;
--  * `gameplay_traffic.forceTeleport` on a police unit is refused.
-- Everything is restored when the pursuit ends. Outside multiplayer RLS runs untouched.
--
-- Added after the owner's log (cop fading out 0.5 s after the chase started, then re-placed):
--  * police close to the player are held ALREADY BEFORE a chase (same radii), so a cop that sees the offence is not
--    recycled in the gap before the pursuit mode flips;
--  * a held cop that is already fading out is told to fade back in (every frame, the fade lasts only about 0.25 s);
--  * every police unit gets `respawn.spawnDirBias = -1` ("away from you", RLS comment) so a cop that is re-placed
--    anyway (a reinforcement) arrives from behind, not ahead. Restored when we stop watching;
--  * roadblocks and police `forceTeleport` are refused at any time, not only after the pursuit was noticed.
--
-- The pursuit state is read from the player's traffic data every check, not only from the RLS hook,
-- because RLS resets `pursuit.mode` directly in several places (evade, arrest, vehicle switch).
-- A respawn-count watch warns if a unit is re-placed anyway (a path we do not block).
-- The server sends the settings in `rlsmpPoliceConfig`; until then the defaults below apply.

local M = {}

local net = require("rlsmp/lib/net")
local p3 = require("rlsmp/lib/p3")
local theftLib = require("rlsmp/lib/theft")

local CHECK_EVERY = 0.5   -- seconds between pursuit checks
local FREEZE_RADIUS = 300 -- metres: police this close to the player's car are frozen
local RELEASE_RADIUS = 350 -- metres: frozen units further than this (and not in the pursuit data) are released

local settings = {antiTeleport = true, blockRoadblocks = true, noFineInStolenCar = true}
local pursuit = false
local timer = 0
local frozen = {}         -- police vehicle id -> its enableRespawn before we touched it (held near the player, chase or not)
local biased = {}         -- police vehicle id -> its spawnDirBias before we set it to -1
local seenRespawns = {}   -- police vehicle id -> respawnCount when the pursuit started
local leaks = 0           -- units re-placed during a pursuit despite the freeze
local hookMode = 0        -- last pursuit mode the RLS hook reported for the player (fallback)
local pursuitStart = 0    -- wall-clock time when the current pursuit began
local patched = {}        -- name -> true once a wrapper is installed (log once)

local function isMP()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
end

-- Watching police at all (also before a chase).
local function watching()
  return settings.antiTeleport and isMP()
    and overhaul_career_career ~= nil and overhaul_career_career.isActive()
end

local function active()
  return pursuit and watching()
end

local function isPolice(veh)
  return type(veh) == "table" and type(veh.role) == "table" and veh.role.name == "police"
end

local function release(id, veh)
  if frozen[id] ~= nil then
    if veh then veh.rlsmpHold = nil end   -- see rlsmp/bubble.lua: its tryRespawn wrapper honours this flag
    p3.count("units released")
    if pursuit then p3.log("I", string.format("RELEASED police id=%s enableRespawn back to %s", tostring(id), tostring(frozen[id]))) end
    frozen[id] = nil
  end
end

local function unbias(id, veh)
  if biased[id] ~= nil then
    if veh and type(veh.respawn) == "table" then veh.respawn.spawnDirBias = biased[id] or nil end
    biased[id] = nil
  end
end

local function releaseAll()
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
  for id in pairs(frozen) do release(id, traffic[id]) end
  for id in pairs(biased) do unbias(id, traffic[id]) end
  frozen, seenRespawns, biased = {}, {}, {}
end

local function playerTraffic()
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then return nil end
  local playerId = be:getPlayerVehicleID(0)
  return playerId, gameplay_traffic.getTrafficData()
end

-- Works for BeamNG vec3 and plain {x, y, z} tables alike.
local function hasXYZ(p)
  local t = type(p)
  return (t == "table" or t == "cdata" or t == "userdata") and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil
end

local function distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The player's car position: traffic data first, then map.objects (also works for cars RLS does not track).
local function playerPos(playerId, traffic)
  local veh = traffic and traffic[playerId]
  if veh and hasXYZ(veh.pos) then return veh.pos end
  local obj = map and map.objects and map.objects[playerId]
  if obj and hasXYZ(obj.pos) then return obj.pos end
  return nil
end

-- Units named in the player's pursuit data (RLS keeps no list of chasing units there).
local function pursuitIds(playerId, traffic)
  local ids = {}
  local veh = traffic and traffic[playerId]
  local pursuit = veh and type(veh.pursuit) == "table" and veh.pursuit
  if pursuit then
    if type(pursuit.sight) == "table" and pursuit.sight.policeId then ids[pursuit.sight.policeId] = true end
    if pursuit.roadblockTargetId and pursuit.roadblockTargetId ~= 0 then ids[pursuit.roadblockTargetId] = true end
  end
  return ids
end

-- Should this police unit be frozen right now? `wasFrozen` widens the radius (release gap).
local function tied(id, veh, named, pos, wasFrozen)
  if veh.role and veh.role.state == "disabled" and not named[id] then return false end   -- a wreck may leave
  if named[id] then return true end
  if not pos then return pursuit end         -- no position known: in a chase freeze all (safe side)
  if not hasXYZ(veh.pos) then return wasFrozen end
  return distance(veh.pos, pos) <= (wasFrozen and RELEASE_RADIUS or FREEZE_RADIUS)
end

-- Where is this unit compared with the player: "dist=120 ahead=yes". Only for the LEAK line.
local function whereIs(veh, pos, playerVeh)
  if not (pos and hasXYZ(veh.pos)) then return "position unknown" end
  local dir = playerVeh and playerVeh.dirVec
  local ahead = "?"
  if hasXYZ(dir) then
    ahead = ((veh.pos.x - pos.x) * dir.x + (veh.pos.y - pos.y) * dir.y) > 0 and "yes" or "no"
  end
  return string.format("dist=%.0f ahead=%s", distance(veh.pos, pos), ahead)
end

-- Hold police near the player (before and during a chase) and the ones tied to it, release the rest, watch for units re-placed anyway.
local function freezePolice()
  local playerId, traffic = playerTraffic()
  if not traffic then return end
  local named, pos = pursuitIds(playerId, traffic), playerPos(playerId, traffic)
  if not pursuit then named = {} end
  p3.logOnChange("playerPosKnown", pos ~= nil, "I", "probe: player position known = " .. tostring(pos ~= nil))
  -- Units that left the traffic data: forget them (nothing to restore).
  for id in pairs(frozen) do
    if traffic[id] == nil then
      p3.log("I", string.format("GONE police id=%s left the traffic data while held", tostring(id)))
      frozen[id], seenRespawns[id], biased[id] = nil, nil, nil
    end
  end
  for id in pairs(biased) do if traffic[id] == nil then biased[id] = nil end end
  local policeNow = 0
  for id, veh in pairs(traffic) do
    if id ~= playerId and isPolice(veh) then
      policeNow = policeNow + 1
      -- A unit that RLS re-places is put "away from you" (behind), not ahead.
      if type(veh.respawn) == "table" and veh.respawn.spawnDirBias ~= -1 then
        if biased[id] == nil then biased[id] = veh.respawn.spawnDirBias or false end
        veh.respawn.spawnDirBias = -1
      end
      local isTied = tied(id, veh, named, pos, frozen[id] ~= nil)
      if not isTied then
        if frozen[id] ~= nil then
          release(id, veh)
          seenRespawns[id] = nil
        end
      else
        if frozen[id] == nil then
          frozen[id] = veh.enableRespawn ~= false
          seenRespawns[id] = veh.respawnCount
          p3.count(pursuit and "units frozen" or "units held before a chase")
          if pursuit then
            p3.log("I", string.format("FROZE police id=%s respawnCount=%s was enableRespawn=%s state=%s alpha=%s",
              tostring(id), tostring(veh.respawnCount), tostring(frozen[id]), tostring(veh.state), tostring(veh.alpha)))
          end
        end
        -- NOT enableRespawn=false: RLS turns such a car into state 'locked', and then its pursuit logic (lane rules, wreck handling) stops running.
        -- Instead the tryRespawn wrapper in rlsmp/bubble.lua refuses to recycle a car with this flag.
        veh.rlsmpHold = true
        local count = veh.respawnCount
        if type(count) == "number" and type(seenRespawns[id]) == "number" and count > seenRespawns[id] then
          leaks = leaks + 1
          seenRespawns[id] = count
          p3.count("LEAKS (re-placed while held)")
          p3.log("W", string.format("LEAK police id=%s was re-placed while held, pursuit=%s (respawnCount %s, %s)",
            tostring(id), tostring(pursuit), tostring(count), whereIs(veh, pos, traffic[playerId])))
        end
      end
    end
  end
  local most = p3.get("most police at once")
  if policeNow > most then p3.count("most police at once", policeNow - most) end
end

-- Every frame: a held unit that is already fading out (RLS decided just before we held it) fades back in.
-- The fade takes about 0.25 s, so the 0.5 s check would miss it.
local function rescueFading()
  if next(frozen) == nil then return end
  local _, traffic = playerTraffic()
  if not traffic then return end
  for id in pairs(frozen) do
    local veh = traffic[id]
    if veh and veh.state == "fadeOut" and (tonumber(veh.alpha) or 0) > 0 then
      veh.state = "fadeIn"
      p3.count("fade-outs cancelled")
      p3.log("I", string.format("CANCELLED fade-out of held police id=%s alpha=%s", tostring(id), tostring(veh.alpha)))
    end
  end
end

-- Wrap table[name]; `refuse(...)` returning true means "block this call".
-- The wrapper itself is kept in tbl["__rlsmp_"..name]. If RLS or vanilla later puts a new function in
-- tbl[name], the identity check fails and we wrap the new one (it becomes the original we call).
local function wrap(tbl, name, label, refuse, refusedValue)
  if type(tbl) ~= "table" then return false end
  if type(tbl[name]) ~= "function" then return false end
  local mine = tbl["__rlsmp_" .. name]
  if mine ~= nil and tbl[name] == mine then return true end
  if mine ~= nil then
    p3.count("rewrapped " .. label)
    p3.log("W", "rewrapped " .. label .. " (the function was replaced after we wrapped it)")
  end
  local original = tbl[name]
  local wrapper = function(...)
    if watching() and refuse(...) then
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
  tbl[name] = wrapper
  tbl["__rlsmp_" .. name] = wrapper
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
  -- RLS can call this the moment the offence happens, before our 0.5 s check saw the pursuit: refuse it for the player (or an unknown target) at any time.
  note("setupRoadblock", wrap(police, "setupRoadblock", "setupRoadblock", function(targetId)
    return settings.blockRoadblocks and (pursuit or targetId == nil or targetId == be:getPlayerVehicleID(0))
  end, nil))
  note("forceTeleport", wrap(gameplay_traffic, "forceTeleport", "forceTeleport(police)", function(id)
    local veh = gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[id]
    return isPolice(veh)
  end, false))
end


-- No fine in a car that is not yours -------------------------------------------------------------------------------------------------------
-- RLS ends a chase with a citation or an arrest by charging a money fine: playerDriving.onPursuitAction -> overhaul_career_economy_payment.pay(...,
-- reason.label == "Police fine"), then shows "Citation fine: $X" / "Arrest fine: $X". A car we turned from a parked car into a stolen car is not
-- registered to the player (it is not in their RLS garage), so that one payment is skipped and the message says so. The chase itself, the arrest and
-- the plate flag are untouched. (The payment function is called by name each time, so replacing it works; a hook function would not be safe to replace.)
local fineSkipped = nil        -- os.time() of the last skipped fine (the message that follows within 2 s is rewritten); nil = none

local function inStolenCar()
  return settings.noFineInStolenCar and isMP() and overhaul_career_career ~= nil and overhaul_career_career.isActive()
    and be ~= nil and theftLib.isConverted(be:getPlayerVehicleID(0))
end

local function isPoliceFine(reason)
  return type(reason) == "table" and reason.label == "Police fine"
end

-- Wrap tbl[name] (once; re-wrapped if the function is replaced). `around(original, ...)` returns the results.
local function wrapAround(tbl, name, key, around)
  if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then return false end
  local mine = tbl["__rlsmp_" .. key]
  if mine ~= nil and tbl[name] == mine then return true end
  local original = tbl[name]
  local wrapper = function(...) return around(original, ...) end
  tbl[name] = wrapper
  tbl["__rlsmp_" .. key] = wrapper
  p3.log("I", "patched " .. key .. " = true")
  return true
end

local function patchFines()
  wrapAround(overhaul_career_economy_payment, "pay", "finePay", function(original, price, reason, ...)
    if isPoliceFine(reason) and inStolenCar() then
      fineSkipped = os.time()
      p3.count("police fine skipped (stolen car)")
      p3.log("I", "police fine NOT charged: the car is not registered to the player (stolen)")
      return true
    end
    return original(price, reason, ...)
  end)
  wrapAround(_G, "ui_message", "fineMessage", function(original, msg, ...)
    if type(msg) == "string" and fineSkipped ~= nil and os.time() - fineSkipped <= 2 and (msg:find("^Citation fine") or msg:find("^Arrest fine")) then
      fineSkipped = nil
      msg = (msg:find("^Citation") and "Citation" or "Arrest") .. ": no fine, this car is not registered to you."
    end
    return original(msg, ...)
  end)
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
    pursuitStart = os.time()
    p3.count("pursuits started")
    p3.log("I", string.format("pursuit START mode=%s antiTeleport=%s blockRoadblocks=%s",
      tostring(playerPursuitMode()), tostring(settings.antiTeleport), tostring(settings.blockRoadblocks)))
    patch()
    if active() then freezePolice() end
  else
    p3.count("pursuits ended")
    p3.log("I", string.format("pursuit END after %.0fs, units frozen at end=%d, leaks so far=%d",
      os.time() - pursuitStart, (function() local n = 0 for _ in pairs(frozen) do n = n + 1 end return n end)(), leaks))
    if watching() then freezePolice() end   -- units tied only to the chase are released, the ones near you stay held
  end
end

-- Compare our state with the real one; this is the source of truth.
local function sync()
  if not isMP() or not be or not overhaul_career_career or not overhaul_career_career.isActive() then return end
  setPursuit(playerPursuitMode() >= 1)
  patchFines()   -- independent of antiTeleport: the fine wrappers only act when the player is in a stolen car
  if not watching() then return end
  patch()   -- retry wrappers until RLS's police service exists (installed before a chase, not after)
  freezePolice()
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
  if watching() then rescueFading() end
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
  if type(data.noFineInStolenCar) == "boolean" then settings.noFineInStolenCar = data.noFineInStolenCar end
  if type(data.bubbleMode) == "string" then
    local b = rawget(_G, "rlsmp_bubble") or package.loaded["rlsmp/bubble"]
    if b and b.setMode then b.setMode(data.bubbleMode) end
    p3.log("I", "traffic bubble mode = " .. data.bubbleMode)
  end
  if type(data.range) == "table" then
    local b = rawget(_G, "rlsmp_bubble") or package.loaded["rlsmp/bubble"]
    if b and b.setRange then b.setRange(data.range) end
    local u = rawget(_G, "rlsmp_unjam") or package.loaded["rlsmp/unjam"]
    if u and u.configure then u.configure(b and b.getRange and b.getRange().unjam or data.range.unjam) end
  end
  local pr = rawget(_G, "rlsmp_policeRespawn") or package.loaded["rlsmp/policeRespawn"]
  if pr and pr._onConfig then pr._onConfig(data) end   -- cops that come back behind the player (rlsmp/policeRespawn.lua)
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
