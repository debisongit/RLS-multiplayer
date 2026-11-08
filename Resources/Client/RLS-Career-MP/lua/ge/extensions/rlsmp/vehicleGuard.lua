-- RLS-Career-MP client extension "rlsmp_vehicleGuard".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Players may only enter their own cars. Blocked: other players' vehicles (incl. their traffic) and
-- AI traffic / parked cars of the game itself (you can enter them, but can't control them).
-- Entering is refused BEFORE it happens (RLS and the game ask gameplay_walk.isVehicleBlacklisted / getInVehicle first),
-- because once a walking player is inside a car BeamMP deletes their walking character, and there is nothing to return to.
-- If a switch still slips through (e.g. the vehicle menu), we put the player back in their old car, or on foot beside it.
-- Two exceptions (see isBlocked): the taxi RLS hailed for YOU (RLS boards you through a normal vehicle switch), and, when
-- the server allows it (`vehicles.allowPassengers`, on by default), another PLAYER's car for a player who is ON FOOT, as a PASSENGER only:
--   * never their AI traffic or parked cars (hideNametag, see trafficLabels; and we must have heard that owner's list first),
--   * only while the owner is driving (a remote walking character of the same player means they got out),
--   * RLS seats us through gameplay_seatOccupants.requestEnterBestSeat, which would pick the DRIVER seat of a car nobody sits in on our side:
--     for another player's car we wrap it and seat the player in a passenger seat only (RLS's own passengerSeats lib), so no controls;
--   * a watchdog puts the passenger on foot again when the owner gets out, leaves, or the car is gone.
-- docs/RESEARCH_PASSENGERS.md says what is verified and what is guessed. Every decision is logged with the tag RLSMP-GUARD.
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

local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end

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
    if not allowPassengers then note(id, true, "another player's car (passengers off)") return true, "remote car" end
    if not onFoot(fromId) then note(id, true, "another player's car (you are not on foot)") return true, "remote car" end
    local owner = M.ownerPid(id)
    if not owner then note(id, true, "another player's car (owner unknown)") return true, "remote car" end
    local labels = ext("trafficLabels")
    if labels and labels.heardFrom and not labels.heardFrom(owner) then
      note(id, true, "another player's car (traffic list of player " .. owner .. " not received yet, cannot tell a parked car from their car)")
      return true, "remote car"
    end
    if M.ownerOnFoot(owner) then note(id, true, "another player's car (player " .. owner .. " is on foot, nobody drives it)") return true, "remote car" end
    local o = id >= 0 and be and be.getObjectByID and be:getObjectByID(id)
    note(id, false, string.format("passenger seat in player %s's car (playerUsable=%s active=%s)", owner, tostring(o and o.playerUsable),
      tostring(o and o.getActive and o:getActive())))
    return false, "passenger"
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

-- BeamMP server ids are "<player number>-<vehicle number>".
function M.ownerPid(id)
  local serverId = mp.serverIdOf(id)
  return serverId and tonumber(tostring(serverId):match("^(%d+)%-")) or nil
end

-- Does this player's walking character exist in our game? BeamMP removes a player's character while they sit in a car, so a character
-- of the owner means the owner is NOT driving. (A character BeamMP has not synced yet looks like "driving": the watchdog catches that.)
function M.ownerOnFoot(pid)
  if not (MPVehicleGE and MPVehicleGE.getVehicles) then return false end
  for serverId, v in pairs(MPVehicleGE.getVehicles()) do
    if v.isLocal ~= true and v.gameVehicleID and tonumber(tostring(serverId):match("^(%d+)%-")) == pid and jbeamOf(v.gameVehicleID) == "unicycle" then return true end
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
-- RLS (and the game) seat a walking player through requestEnterBestSeat, which takes the driver seat when nobody sits there on OUR side.
-- Another player's car must only ever give a passenger seat: no passenger seat = refused, and the player stays on foot.
local function passengerSeats()
  local ok, lib = pcall(require, "overhaul/lib/vehicles/passengerSeats")
  return ok and type(lib) == "table" and lib or nil
end

local function installSeats()
  local api = gameplay_seatOccupants
  if not api or wrapped[api] or type(api.requestEnterBestSeat) ~= "function" then return end
  wrapped[api] = true
  local original = api.requestEnterBestSeat
  api.requestEnterBestSeat = function(vehicleId, ...)
    if not (enabled and vehicleId and mp.isRemote(vehicleId)) then return original(vehicleId, ...) end
    local blocked, why = M.isBlocked(vehicleId)
    if blocked then log("I", TAG, string.format("seat refused id=%s (%s)", tostring(vehicleId), tostring(why))) return false end
    local lib = passengerSeats()
    local ok, handled, seat = false, nil, nil
    if lib and lib.enter then ok, handled, seat = pcall(lib.enter, vehicleId) end
    log("I", TAG, string.format("passenger seat id=%s: lib=%s ok=%s handled=%s seat=%s", tostring(vehicleId), tostring(lib ~= nil), tostring(ok),
      tostring(handled), tostring(type(seat) == "table" and seat.seatId or seat)))
    if ok and handled then return true end
    log("W", TAG, "no passenger seat could be given in player's car id=" .. tostring(vehicleId) .. " (refused; never the driver seat)")
    return false
  end
end

function M.install()
  installSeats()
  local walk = gameplay_walk
  if not walk or wrapped[walk] then return walk ~= nil end
  wrapped[walk] = true
  local originalBlacklisted, originalGetIn = walk.isVehicleBlacklisted, walk.getInVehicle
  M._originalBlacklisted = originalBlacklisted
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
  if not blocked then
    if why == "passenger" then M.startRide(newId) else M.stopRide("switched to " .. tostring(newId)) end
    return
  end
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

-- Passenger ride -------------------------------------------------------------------------------------------------
-- riding = {id, owner, pos = {x, y, z, dx, dy} of the car when last seen, since, ownerFoot = seconds the owner has been on foot}
local riding
local clock, watch = 0, 0
local OWNER_FOOT_GRACE = 2     -- seconds the owner may be on foot before the passenger is put out
local WATCH_EVERY = 0.5

local function carState(id)
  local o = id and id >= 0 and be and be.getObjectByID and be:getObjectByID(id)
  local p = o and o.getPosition and o:getPosition()
  if not p then return nil end
  local d = o.getDirectionVector and o:getDirectionVector()
  return {x = p.x, y = p.y, z = p.z, dx = d and d.x or 0, dy = d and d.y or 1}
end

function M.isRiding() return riding ~= nil and riding.id or nil end

function M.startRide(id)
  riding = {id = id, owner = M.ownerPid(id), pos = carState(id), since = clock, ownerFoot = 0}
  local presence = gameplay_seatOccupants and gameplay_seatOccupants.getPlayerPresence and gameplay_seatOccupants.getPlayerPresence(0)
  log("I", TAG, string.format("passenger ride started in car %s of player %s (seat mode: %s)", tostring(id), tostring(riding.owner),
    tostring(type(presence) == "table" and presence.permissionMode or "unknown")))
end

function M.stopRide(why)
  if not riding then return end
  log("I", TAG, string.format("passenger ride ended in car %s: %s", tostring(riding.id), tostring(why)))
  riding = nil
end

-- Put the passenger on foot beside the car (or where it was last seen). Used when the owner got out, left, or the car is gone.
function M.putOut(why)
  local r = riding
  if not r then return end
  log("I", TAG, string.format("passenger put out of car %s: %s", tostring(r.id), tostring(why)))
  riding = nil
  local at = carState(r.id) or r.pos
  local pos
  if at then
    -- two metres to the side of the car, a little above the ground
    pos = vec3(at.x - at.dy * 2.5, at.y + at.dx * 2.5, at.z + 0.5)
  end
  reverting = true
  if gameplay_walk and gameplay_walk.setWalkingMode then gameplay_walk.setWalkingMode(true, pos) end
  reverting = false
end

local function watchRide()
  local r = riding
  if not r then return end
  local current = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if current ~= r.id then
    -- the player left the car themselves (or the game moved them): done, unless they are no longer on foot AND not in the car
    return M.stopRide("player vehicle is now " .. tostring(current))
  end
  local state = carState(r.id)
  if not state then return M.putOut("the car is gone") end
  r.pos = state
  local presence = gameplay_seatOccupants and gameplay_seatOccupants.getPlayerPresence and gameplay_seatOccupants.getPlayerPresence(0)
  if type(presence) == "table" and presence.vehicleId == r.id and presence.permissionMode and presence.permissionMode ~= "passenger" then
    return M.putOut("seat mode is " .. tostring(presence.permissionMode) .. ", not passenger: no controls for you")
  end
  if not allowPassengers then return M.putOut("passengers were switched off") end
  if r.owner and M.ownerOnFoot(r.owner) then
    r.ownerFoot = r.ownerFoot + WATCH_EVERY
    if r.ownerFoot >= OWNER_FOOT_GRACE then return M.putOut("the driver (player " .. r.owner .. ") got out") end
  else
    r.ownerFoot = 0
  end
  if r.owner and MPVehicleGE and MPVehicleGE.getVehicles then
    local alive = false
    for serverId, v in pairs(MPVehicleGE.getVehicles()) do
      if v.gameVehicleID == r.id then alive = true break end
    end
    if not alive then return M.putOut("BeamMP no longer lists the car (the driver left)") end
  end
end

-- Remote cars a walking player may board as a passenger must not be marked unusable (RLS only walks to cars with playerUsable ~= false).
-- We only ever switch ON for cars isBlocked() lets in; everything else is refused by the guard wrappers anyway.
local function prepareRemotes()
  if not (enabled and allowPassengers and MPVehicleGE and MPVehicleGE.getVehicles) or not onFoot() then return end
  for _, v in pairs(MPVehicleGE.getVehicles()) do
    local id = v.gameVehicleID
    if v.isLocal ~= true and id and id >= 0 and not v.hideNametag and not M.isBlocked(id) then
      local o = be and be.getObjectByID and be:getObjectByID(id)
      if o and o.playerUsable == false then
        o.playerUsable = true
        log("I", TAG, "made car " .. tostring(id) .. " usable for passengers (playerUsable was false)")
      end
      if gameplay_walk and gameplay_walk.isVehicleBlacklisted and gameplay_walk.removeVehicleFromBlacklist then
        local okB, black = pcall(function() return M._originalBlacklisted and M._originalBlacklisted(id) end)
        if okB and black then
          gameplay_walk.removeVehicleFromBlacklist(id)
          log("I", TAG, "took car " .. tostring(id) .. " off the walk blacklist for passengers")
        end
      end
    end
  end
end

function M.onVehicleDestroyed(id)
  lastNote[id] = nil
  if riding and riding.id == id then M.putOut("the car was deleted") end
end

function M.onUpdate(dtReal)
  M.install()
  replaceGuard.install()   -- keep "replace this car" pointing at this car (RLS part shop; see lib/replaceGuard.lua)
  clock = clock + (tonumber(dtReal) or 0)
  watch = watch + (tonumber(dtReal) or 0)
  if watch < WATCH_EVERY then return end
  watch = 0
  if not enabled then return end
  watchRide()
  prepareRemotes()
end

-- Server settings (rlsmpVehicleConfig). Forgotten when we leave the server.
local function onConfig(data)
  allowPassengers = data.allowPassengers == true
  log("I", TAG, "config received allowPassengers=" .. tostring(allowPassengers))
end
function M.onServerLeave() allowPassengers = false lastNote = {} riding = nil end

function M.onExtensionLoaded()
  net.on("rlsmpVehicleConfig", onConfig)
  replaceGuard.install()   -- as early as possible: it must see the game's own function before BeamMP swaps it
end
M._onConfig = onConfig

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
