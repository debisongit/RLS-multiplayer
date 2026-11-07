-- RLS-Career-MP client extension "rlsmp_claims": reports crashes with other players to the server.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Watches the car the player drives. When it touches another PLAYER's car (not AI traffic, not a walking player) we keep
-- a snapshot of both cars from just before the contact, wait until the contact is over, measure the damage our car took
-- with RLS's own repair price (broken parts), and send it all to the server (see server/claims.lua, which decides fault).
-- Also: answers "which car am I in" for /dashcam, and files an RLS insurance claim when the server says we were at fault.

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")

local enabled = false
local clock = 0               -- game time we advance ourselves (testable)
local sinceCheck = 0
local CHECK_EVERY = 0.1       -- seconds
local CONTACT_OVER = 1.5      -- seconds without contact ends an incident
local NEARBY_RADIUS = 40      -- meters: "other cars around" that could have seen it

local previous               -- snapshot of the previous check: {mine = snap, others = {[id] = snap}}
local contacts = {}          -- other car id -> incident in progress
local lastHitInventory

function M.enable(on)
  enabled = on == true
  if not enabled then previous, contacts = nil, {} end
end

local function arr(v) return {v.x, v.y, v.z} end
local function snap(pos, vel, dir) return {p = arr(pos), v = arr(vel), d = arr(dir)} end

local function distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Repair price of the car right now (RLS prices every broken part). cb(price) gets nil when we cannot tell.
local function repairPrice(veh, cb)
  local vc = overhaul_career_market_valueCalculator
  if not (vc and vc.getSpawnedVehicleRepairPrice and core_vehicleBridge and core_vehicleBridge.requestValue) then return cb(nil) end
  local ok = pcall(core_vehicleBridge.requestValue, veh, function(res)
    local fine, price = pcall(vc.getSpawnedVehicleRepairPrice, veh:getID(), res and res.result)
    cb(fine and tonumber(price) or nil)
  end, "getPartConditions")
  if not ok then cb(nil) end
end

-- Another PLAYER's car (not traffic: those have their name tag hidden by trafficLabels, not a walking character).
local function isPlayerCar(id, remote)
  if not remote[id] then return false end
  local o = be:getObjectByID(id)
  if o and (o.jbeam or o.JBeam) == "unicycle" then return false end
  local _, v = mp.serverIdOf(id)
  return v ~= nil and v.hideNametag ~= true
end

local function nearbyCount(myPos, ignoreIds)
  local n = 0
  for id, o in pairs(map.objects) do
    if not ignoreIds[id] and o.pos and distance(o.pos, myPos) <= NEARBY_RADIUS then n = n + 1 end
  end
  return n
end

local function finish(id, c, veh)
  contacts[id] = nil
  local mineId = mp.serverIdOf(veh:getID())
  local otherId = mp.serverIdOf(id)
  if not (mineId and otherId) then
    log("W", "RLSMP-CLAIMS", string.format("contact with car %s ended but BeamMP ids are unknown (mine %s, other %s): no report", tostring(id), tostring(mineId), tostring(otherId)))
    return
  end
  local inv = overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(veh:getID())
  lastHitInventory = inv
  repairPrice(veh, function(after)
    local damage = (after and c.baseline) and math.max(0, after - c.baseline) or nil
    log("I", "RLSMP-CLAIMS", string.format("sending crash report: %s hit %s, damage %s, nearby %s", tostring(mineId), tostring(otherId), tostring(damage), tostring(c.nearby)))
    net.send("rlsmpHit", {me = mineId, with = otherId, inv = inv, model = veh.jbeam or veh.JBeam,
      mine = c.mine, other = c.other, damage = damage, nearby = c.nearby})
  end)
end

function M.onUpdate(dtReal)
  if not enabled then return end
  clock = clock + (dtReal or 0)
  sinceCheck = sinceCheck + (dtReal or 0)
  if sinceCheck < CHECK_EVERY then return end
  sinceCheck = 0

  local veh = getPlayerVehicle(0)
  if not veh or (veh.jbeam or veh.JBeam) == "unicycle" then previous, contacts = nil, {} return end
  local myId = veh:getID()
  local remote = mp.remoteSet()
  local myPos = veh:getPosition()
  local mine = snap(myPos, veh:getVelocity(), veh:getDirectionVector())

  local others = {}
  for id, o in pairs(map.objects) do
    if id ~= myId and o.pos and remote[id] and distance(o.pos, myPos) <= 60 then
      others[id] = snap(o.pos, o.vel or {x = 0, y = 0, z = 0}, o.dirVec or {x = 0, y = 1, z = 0})
      -- Contact is booked on each car's own map data; trust either side (a remote car may not carry its own collision flags).
      local mineObj = map.objects[myId]
      local touching = (o.objectCollisions and o.objectCollisions[myId] == 1)
        or (mineObj and mineObj.objectCollisions and mineObj.objectCollisions[id] == 1)
      if touching and isPlayerCar(id, remote) then
        local c = contacts[id]
        if not c then
          -- first contact: use the snapshot from one check earlier, before the impact changed the speeds
          c = {mine = previous and previous.mine or mine, other = previous and previous.others[id] or others[id],
               nearby = nearbyCount(myPos, {[myId] = true, [id] = true})}
          contacts[id] = c
          log("I", "RLSMP-CLAIMS", "contact started with player car " .. tostring(id))
          repairPrice(veh, function(price) c.baseline = price end)
        end
        c.last = clock
      end
    end
  end
  previous = {mine = mine, others = others}

  for id, c in pairs(contacts) do
    if clock - (c.last or clock) >= CONTACT_OVER then finish(id, c, veh) end
  end
end

-- Server: "which car are you in?" (for /dashcam)
local function onWhatCar()
  local inventory = overhaul_career_garage_inventory
  local id = inventory and inventory.getCurrentVehicle and inventory.getCurrentVehicle()
  local rec = id and inventory.getVehicle(id)
  net.send("rlsmpMyCar", {inv = id, model = rec and rec.model, name = rec and (rec.niceName or rec.model)})
end

-- Server: you were at fault. File an RLS insurance claim for that damage so the driver score drops.
local function onPenalty(msg)
  local insurance = overhaul_career_repair_insurance
  local damage = tonumber(msg.damage)
  if not (insurance and insurance.makeRepairClaim and damage and damage > 0) then return end
  local inv = lastHitInventory or (overhaul_career_garage_inventory and overhaul_career_garage_inventory.getCurrentVehicle())
  if not inv then return end
  -- zero out-of-pocket cost here: the money was already taken by the server; this only records the claim and the score hit
  pcall(insurance.makeRepairClaim, inv, {0}, nil, damage)
end

function M.onExtensionLoaded()
  net.on("rlsmpWhatCar", onWhatCar)
  net.on("rlsmpClaimPenalty", onPenalty)
end

M._onPenalty, M._onWhatCar = onPenalty, onWhatCar
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
