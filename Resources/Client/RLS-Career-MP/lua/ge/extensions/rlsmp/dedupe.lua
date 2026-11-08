-- RLS-Career-MP client extension "rlsmp_dedupe": removes a leftover copy of one of YOUR cars.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Seen in a log: after changing parts on a car (RLS replaces the car), the old car object was never deleted, so two
-- identical cars stood in the garage. RLS keeps only the newest one bound to the inventory slot.
-- Rule: a local car that is NOT bound to any inventory slot, but has the same model and the same license plate as
-- that slot's record, is a stale copy. If it stays that way for 4 seconds in a row (RLS is not in the middle of
-- swapping), it is deleted. Never the car the player is in, never another player's car.

local M = {}

local mp = require("rlsmp/lib/mp")

local enabled = false
local timer, clock = 0, 0
local CHECK_EVERY = 2
local WAIT = 4
local firstSeen = {}   -- vehicle id -> clock when first seen as a duplicate

function M.enable(on)
  enabled = on == true
  if not enabled then firstSeen = {} end
end

local function plateOf(obj)
  if obj and obj.getDynDataFieldbyName then
    local ok, text = pcall(obj.getDynDataFieldbyName, obj, "licenseText", 0)
    if ok and type(text) == "string" and text ~= "" then return text end
  end
end

-- One round. Returns the ids deleted (for tests and logs).
function M.check()
  local inv = overhaul_career_garage_inventory
  if not (inv and inv.getVehicles and inv.getVehicleIdFromInventoryId and be and be.getObjectCount) then return {} end
  local bySlot = {}   -- plate -> {id = bound vehicle id, model = ...}
  for invId, rec in pairs(inv.getVehicles() or {}) do
    local plate = type(rec.config) == "table" and rec.config.licenseName
    local bound = inv.getVehicleIdFromInventoryId(invId)
    if plate and plate ~= "" and bound then bySlot[plate] = {id = bound, model = rec.model} end
  end
  local remote = mp.remoteSet()
  local playerId = be:getPlayerVehicleID(0)
  local stillDuplicate, deleted = {}, {}
  for i = be:getObjectCount() - 1, 0, -1 do
    local obj = be:getObject(i)
    local id = obj and obj:getID()
    if id and not remote[id] and id ~= playerId then
      local plate = plateOf(obj)
      local slot = plate and bySlot[plate]
      -- A car bound to ANY inventory slot is a real car (two owned cars can share a plate text), never a stale copy.
      local bound = inv.getInventoryIdFromVehicleId and inv.getInventoryIdFromVehicleId(id) ~= nil
      if slot and not bound and slot.id ~= id and (obj.jbeam or obj.JBeam) == slot.model and be:getObjectByID(slot.id) then
        stillDuplicate[id] = true
        firstSeen[id] = firstSeen[id] or clock
        if clock - firstSeen[id] >= WAIT then
          log("W", "RLS-Career-MP", string.format("dedupe: deleting stale copy %s of car %s (plate %s)", tostring(id), tostring(slot.id), plate))
          obj:delete()
          firstSeen[id] = nil
          deleted[#deleted + 1] = id
        end
      end
    end
  end
  for id in pairs(firstSeen) do if not stillDuplicate[id] then firstSeen[id] = nil end end
  return deleted
end

function M.onUpdate(dtReal)
  if not enabled then return end
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("dedupe", M)
return M
