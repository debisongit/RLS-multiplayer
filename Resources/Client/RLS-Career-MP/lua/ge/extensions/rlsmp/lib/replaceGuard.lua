-- RLS-Career-MP client: make "replace THIS car" mean this car (RLS part shop, repairs, ...).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS rebuilds a car with core_vehicles.replaceVehicle(model, options, theCar). In a BeamMP session BeamMP swaps that function for
-- its own replaceRequest(model, config, colors), which DROPS the third argument and replaces whatever car the PLAYER is in
-- (or spawns a brand new car when that car is unknown to it). The RLS garage-computer part shop runs while the player is ON FOOT:
-- BeamMP then replaced the walking character instead of the car, a new car appeared and took over the player, and the shopped
-- car stayed behind, still frozen by the shop ("a fake car you can hop in but can't drive").
--
-- Fix: when RLS names a specific car and BeamMP's version would pick the wrong one, call the game's own replaceVehicle for that car.
-- Everything else goes to BeamMP exactly as before. We capture the game's own function before BeamMP swaps it (when it joins).
-- Safe to call install() every frame: it wraps once and again whenever something else puts a different function there.

local mp = require("rlsmp/lib/mp")

local M = {}

local TAG = "RLSMP-REPLACE"

local vanilla   -- the game's own replaceVehicle, captured before BeamMP swapped it
local inner     -- what we wrapped (BeamMP's replaceRequest during a session, the game's own function otherwise)
local ours      -- our wrapper

local function isBeamMPs(fn)
  return MPVehicleGE ~= nil and fn ~= nil and fn == MPVehicleGE.replaceRequest
end

local function idOf(v)
  if type(v) == "number" then return v end
  if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
  if v.getID then return v:getID() end
  if v.getId then return v:getId() end
  return nil
end

local function describe(id)
  local o = id and id >= 0 and be and be.getObjectByID and be:getObjectByID(id)
  local name = o and (o.jbeam or o.JBeam or (o.getJBeamFilename and o:getJBeamFilename())) or nil
  return tostring(id) .. "(" .. tostring(name) .. ")"
end

local function replace(model, config, target, ...)
  if target == nil or not vanilla or not mp.isMPSession() then return inner(model, config, target, ...) end
  local targetId = idOf(target)
  if not targetId then return inner(model, config, target, ...) end
  local cur = getPlayerVehicle and getPlayerVehicle(0)
  local curId = cur and cur:getID() or nil
  local serverId, entry = mp.serverIdOf(targetId)
  local registeredLocal = serverId ~= nil and entry.isLocal == true

  if mp.isRemote(targetId) then
    log("I", TAG, string.format("replace %s target=%s is another player's car: left to BeamMP", tostring(model), describe(targetId)))
    return inner(model, config, target, ...)
  end
  if targetId == curId and registeredLocal then
    log("I", TAG, string.format("replace %s target=%s is the player's own car: BeamMP's replace is right (passthrough)", tostring(model), describe(targetId)))
    return inner(model, config, target, ...)
  end
  -- BeamMP would replace the player's vehicle (e.g. the walking character), or spawn a new car, instead of the named car.
  log("I", TAG, string.format("replace %s target=%s but player is in %s (beammp knows target: %s): replacing the target itself",
    tostring(model), describe(targetId), describe(curId), tostring(registeredLocal)))
  if registeredLocal then entry.jbeam = "-" end   -- BeamMP's own marker, so it syncs the changed car to the others as an edit
  return vanilla(model, config, target, ...)
end

function M.install()
  if not (core_vehicles and core_vehicles.replaceVehicle) then return false end
  local current = core_vehicles.replaceVehicle
  if current == ours then return true end
  if not vanilla and not isBeamMPs(current) then
    vanilla = current
    log("I", TAG, "captured the game's own replaceVehicle")
  end
  inner = current
  ours = replace
  core_vehicles.replaceVehicle = ours
  log("I", TAG, string.format("wrapped core_vehicles.replaceVehicle (beammp's version: %s, game's own known: %s)", tostring(isBeamMPs(current)), tostring(vanilla ~= nil)))
  if isBeamMPs(current) and not vanilla then
    log("W", TAG, "the game's own replaceVehicle was not captured before BeamMP swapped it; part shop fix is inactive until the mod is loaded earlier")
  end
  return true
end

function M.hasVanilla() return vanilla ~= nil end

return M
