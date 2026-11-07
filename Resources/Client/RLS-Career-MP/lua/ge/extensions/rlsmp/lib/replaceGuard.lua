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

-- How the replacement is done.
-- Never call BeamMP's replaceRequest from here: BeamMP saved whatever replaceVehicle was in place when the session started as its
-- "original" and calls it from replaceRequest. If that is OUR wrapper, calling replaceRequest from the wrapper loops forever
-- (a reviewer reproduced this on a copy of BeamMP's logic; it freezes the game). So in a session we do BeamMP's job ourselves:
--   * a car that BeamMP knows as local: mark it as edited ("-" = BeamMP's marker, so it syncs the change) and replace it with the game's own function
--   * anything else: spawn a new car through core_vehicles.spawnNewVehicle (BeamMP's own wrapper for that), as BeamMP does
-- Outside a session the game's own function is used untouched.
local busy = false

local function replace(model, config, target, ...)
  if not vanilla then return inner(model, config, target, ...) end   -- the game's own function was never captured: stay out of the way
  if busy then return vanilla(model, config, target, ...) end        -- backstop against any call loop
  if not mp.isMPSession() then return vanilla(model, config, target, ...) end
  busy = true
  local ok, a, b, c = pcall(function(...)
    local targetId = target ~= nil and idOf(target) or nil
    if targetId and mp.isRemote(targetId) then
      log("W", TAG, string.format("replace %s refused: target %s is another player's car", tostring(model), describe(targetId)))
      return nil
    end
    local cur = getPlayerVehicle and getPlayerVehicle(0)
    local victim = targetId and target or cur
    local victimId = targetId or (cur and cur:getID())
    local serverId, entry = nil, nil
    if victimId then serverId, entry = mp.serverIdOf(victimId) end
    if victimId and serverId ~= nil and entry.isLocal == true then
      if targetId and targetId ~= (cur and cur:getID()) then
        log("I", TAG, string.format("replace %s target=%s but player is in %s: replacing the target itself", tostring(model), describe(targetId), describe(cur and cur:getID())))
      end
      entry.jbeam = "-"
      return vanilla(model, config or {}, victim, ...)
    end
    log("I", TAG, string.format("replace %s: car %s is not a known local car, spawning a new one as BeamMP does", tostring(model), describe(victimId)))
    return core_vehicles.spawnNewVehicle(model, config or {})
  end, ...)
  busy = false
  if not ok then
    log("E", TAG, "replace failed: " .. tostring(a))
    return nil
  end
  return a, b, c
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
-- The game's own replaceVehicle (captured before BeamMP swapped it), for code that must replace one specific car (live traffic swapping).
function M.getVanilla() return vanilla end

return M
