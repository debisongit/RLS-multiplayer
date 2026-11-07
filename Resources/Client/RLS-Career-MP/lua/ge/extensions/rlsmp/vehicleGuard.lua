-- RLS-Career-MP client extension "rlsmp_vehicleGuard".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Players may only enter their own cars. Blocked: other players' vehicles (incl. their traffic) and
-- AI traffic / parked cars of the game itself (you can enter them, but can't control them).
-- Entering is refused BEFORE it happens (RLS and the game ask gameplay_walk.isVehicleBlacklisted / getInVehicle first),
-- because once a walking player is inside a car BeamMP deletes their walking character, and there is nothing to return to.
-- If a switch still slips through (e.g. the vehicle menu), we put the player back in their old car, or on foot beside it.
-- Two exceptions (see isBlocked): the taxi RLS hailed for YOU (RLS boards you through a normal vehicle switch), and, only when
-- the server allows it (`vehicles.allowPassengers`), another player's car for a player who is ON FOOT (BeamMP itself supports
-- riding along: it gives the passenger camera). Their AI traffic and parked cars (hideNametag, see trafficLabels) stay refused. Every decision is logged with the tag RLSMP-GUARD.
-- Car theft (rlsmp/theft.lua): a parked car we turned into a driveable car is in lib/theft's converted set and may be entered;
-- that set holds exactly the converted ids (removed when the car is destroyed), nothing else.

local M = {}

local mp = require("rlsmp/lib/mp")
local net = require("rlsmp/lib/net")
local replaceGuard = require("rlsmp/lib/replaceGuard")
local theftLib = require("rlsmp/lib/theft")

local TAG = "RLSMP-GUARD"
local enabled = false
local reverting = false
local allowPassengers = false   -- set by the server (rlsmpVehicleConfig)

-- RLS taxi states that only ever belong to the cab hailed for the player (or the ride in progress).
local HIRED_CAB_STATES = {pullingOverForPickup = true, waitingForPickup = true, occupied = true,
  pullingOverForDropoff = true, waitingForDropoff = true}

function M.enable(on) enabled = on == true end
function M.getAllowPassengers() return allowPassengers end

local function listHas(list, id)
  for _, v in ipairs(list or {}) do if v == id then return true end end
  return false
end

local function jbeamOf(id)
  local o = id and id >= 0 and be and be.getObjectByID and be:getObjectByID(id)
  if not o then return nil end
  return o.jbeam or o.JBeam or (o.getJBeamFilename and o:getJBeamFilename()) or nil
end

-- true when the player is walking (their vehicle is the walking character). fromId = the vehicle they leave, if known.
local function onFoot(fromId)
  if not fromId and be and be.getPlayerVehicleID then fromId = be:getPlayerVehicleID(0) end
  return jbeamOf(fromId) == "unicycle"
end

-- The taxi RLS hailed for this player? RLS's own taxi state answers; any other AI taxi stays blocked.
local function hiredCab(id)
  local taxi = overhaul_integration_services_taxi
  if not taxi or type(taxi.getTaxiState) ~= "function" then return false, "no taxi service" end
  local ok, state = pcall(taxi.getTaxiState, id)
  if not ok then return false, "taxi state error" end
  return HIRED_CAB_STATES[state] == true, state
end

-- Log a decision once per vehicle until it changes (this is asked every frame by the game's UI).
local lastNote = {}
local function note(id, blocked, why)
  local key = (blocked and "blocked " or "allowed ") .. why
  if lastNote[id] == key then return end
  lastNote[id] = key
  local serverId, v = mp.serverIdOf(id)
  local owner = serverId and (v.isLocal and "own" or "remote") or "unregistered"
  log("I", TAG, string.format("%s id=%s jbeam=%s beammp=%s: %s", blocked and "BLOCKED" or "ALLOWED", tostring(id), tostring(jbeamOf(id)), owner, why))
end

-- true = the player must not sit in this vehicle. Second value = why. fromId = the vehicle they are leaving, if known.
function M.isBlocked(id, fromId)
  if not id or id < 0 then return false end
  -- Only vehicles BeamMP knows as another player's. A car RLS just spawned is not registered yet and stays allowed.
  if mp.isRemote(id) then
    if jbeamOf(id) == "unicycle" then note(id, true, "another player's walking character") return true, "remote walker" end
    -- Another player's AI traffic and parked cars are synced to us too; trafficLabels marks them with hideNametag. Never a seat.
    local _, entry = mp.serverIdOf(id)
    if entry and entry.hideNametag == true then note(id, true, "another player's traffic or parked car") return true, "remote traffic" end
    if allowPassengers and onFoot(fromId) then note(id, false, "passenger seat in another player's car") return false, "passenger" end
    note(id, true, allowPassengers and "another player's car (you are not on foot)" or "another player's car (passengers off)")
    return true, "remote car"
  end
  -- A parked car we stole and turned into a real car (never another player's: those are handled above).
  if theftLib.isConverted(id) then note(id, false, "stolen car (converted by theft)") return false, "stolen" end
  if gameplay_traffic and gameplay_traffic.getTrafficData then
    local td = gameplay_traffic.getTrafficData()[id]
    if td and td.isAi == true then
      local cab, state = hiredCab(id)
      if cab then note(id, false, "taxi hailed for you (" .. tostring(state) .. ")") return false, "hired cab" end
      note(id, true, "AI traffic (taxi state: " .. tostring(state) .. ")")
      return true, "AI traffic"
    end
  end
  if gameplay_parking and gameplay_parking.getParkedCarsList then
    if listHas(gameplay_parking.getParkedCarsList(true), id) then note(id, true, "parked car") return true, "parked" end
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

local function walkerCount()
  local n = 0
  if getAllVehicles then
    for _, v in ipairs(getAllVehicles()) do
      if v.getJBeamFilename and v:getJBeamFilename() == "unicycle" and not mp.isRemote(v:getID()) then n = n + 1 end
    end
  end
  return n
end

function M.onVehicleSwitched(oldId, newId)
  if not enabled or reverting then return end
  local blocked, why = M.isBlocked(newId, oldId)
  log("I", TAG, string.format("switch %s(%s) -> %s(%s): %s%s, own walkers now: %d", tostring(oldId), tostring(jbeamOf(oldId)),
    tostring(newId), tostring(jbeamOf(newId)), blocked and "refused" or "ok", why and (" (" .. why .. ")") or "", walkerCount()))
  if not blocked then return end
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
  replaceGuard.install()   -- keep "replace this car" pointing at this car (RLS part shop; see lib/replaceGuard.lua)
end

-- Server settings (rlsmpVehicleConfig). Forgotten when we leave the server.
local function onConfig(data)
  allowPassengers = data.allowPassengers == true
  log("I", TAG, "config received allowPassengers=" .. tostring(allowPassengers))
end
function M.onServerLeave() allowPassengers = false lastNote = {} end

function M.onExtensionLoaded()
  net.on("rlsmpVehicleConfig", onConfig)
  replaceGuard.install()   -- as early as possible: it must see the game's own function before BeamMP swaps it
end
M._onConfig = onConfig

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
