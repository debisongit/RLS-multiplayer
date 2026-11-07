-- RLS-Career-MP client extension "rlsmp_fleet": business fleet cars.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server runs the rules (/biz fleet ...). This side only moves a car between the
-- player's RLS inventory and the server:
--   add    : upload the car you are sitting in, and once the server has it, remove it from your inventory
--   take   : spawn the car the server sent and put it in your inventory (tagged with its fleetId)
--   return : upload the car again (with your changes), then remove it from your inventory
-- A car is only removed locally AFTER the server confirms, so it can never vanish.

local M = {}

local net = require("rlsmp/lib/net")

local enabled = false
local seq = 0

local function inv() return overhaul_career_garage_inventory end

local function toast(kind, msg)
  guihooks.trigger("toastrMsg", {type = kind, title = "Business fleet", msg = msg, config = {timeOut = 6000}})
end

function M.enable(on) enabled = on == true end

-- The inventory record of the car the player is in, and its inventory id.
local function currentRecord()
  local i = inv()
  if not i then return nil end
  local id = i.getCurrentVehicle()
  local rec = id and i.getVehicle(id)
  if not rec then return nil end
  return id, rec
end

-- Only plain data goes to the server (no userdata, no live game objects).
local function cleanCopy(rec)
  local out = {}
  for k, v in pairs(rec) do
    local t = type(v)
    if t == "table" or t == "string" or t == "number" or t == "boolean" then out[k] = deepcopy and deepcopy(v) or v end
  end
  out.thumbnail, out.defaultThumbnail = nil, nil
  return out
end

local function upload(kind, data)
  seq = seq + 1
  net.sendBig("rlsmpUpBegin", "rlsmpUpChunk", "f" .. seq, jsonEncode({kind = kind, data = data}), 16000)
end

local function onDo(msg)
  if not enabled then return end
  local id, rec = currentRecord()
  if not id then return toast("warning", "Sit in the car you want to use first.") end
  if not overhaul_career_logistics_general.canRemoveLogisticsVehicle(id) then
    return toast("warning", "This car is in use for a job or listing and can't be moved.")
  end
  if msg.act == "add" then
    if rec.fleetId then return toast("warning", "This car is already a fleet car.") end
    upload("fleetAdd", {inv = id, rec = cleanCopy(rec)})
  elseif msg.act == "return" then
    if tostring(rec.fleetId) ~= tostring(msg.fid) then return toast("warning", "Sit in your fleet car to return it.") end
    upload("fleetReturn", {inv = id, fid = tostring(msg.fid), rec = cleanCopy(rec)})
  end
end

-- Server confirmed: the car is safe on the server, so it may leave the inventory now.
local function onAck(ack)
  if not ack.ok or not ack.inv then return end
  inv().removeVehicle(ack.inv)
  -- Write the new inventory to the server soon, so a crash can't bring the old copy back.
  if rlsmp_saveBridge then rlsmp_saveBridge.requestSave("rlsmp_fleet") end
  toast("info", ack.act == "add" and "Car added to the business fleet." or "Fleet car returned.")
end

-- A fleet car arrived: spawn it in front of the player and register it in the inventory.
local function onVehicle(text, extra, problem)
  local fid = extra and extra.fid
  local function release(why)
    net.send("rlsmpFleetRelease", {fid = fid, why = why})
    toast("warning", why)
  end
  if not text then return release("download failed") end
  local rec = (jsonDecode(text) or {}).rec
  if type(rec) ~= "table" or type(rec.model) ~= "string" then return release("bad vehicle data") end
  local i = inv()
  if not i.hasFreeSlot() then return release("no free garage space") end

  local player = getPlayerVehicle(0)
  local pos = player and (player:getPosition() + player:getDirectionVector() * 6) or nil
  local ok, veh = pcall(core_vehicles.spawnNewVehicle, rec.model, {config = rec.config, pos = pos, autoEnterVehicle = false})
  if not ok or not veh then return release("spawn failed") end
  local newId = i.addVehicle(veh:getID(), nil, {owned = true})
  if not newId then
    veh:delete()
    return release("could not add to your garage")
  end
  local record = i.getVehicle(newId)
  if record then
    record.fleetId = tostring(fid)
    record.niceName = rec.niceName or record.niceName
    i.setVehicleDirty(newId)
  end
  toast("info", "Fleet car ready. Return it with /biz fleet return.")
end

-- Crash recovery: the server says these inventory slots already left for a fleet, but the save still has them.
function M.dropStale(list)
  if not enabled or type(list) ~= "table" then return end
  local i, removed = inv(), 0
  for _, id in ipairs(list) do
    if i.getVehicle(id) and overhaul_career_logistics_general.canRemoveLogisticsVehicle(id) then
      i.removeVehicle(id)
      removed = removed + 1
    end
  end
  if removed > 0 then
    if rlsmp_saveBridge then rlsmp_saveBridge.requestSave("rlsmp_fleet") end
    toast("info", "A car that was already moved to the business fleet was cleared from your garage.")
  end
end

-- The owner retired this car from the fleet: it becomes a normal personal car (just drop the fleet tag).
local function onRetire(msg)
  local i = inv()
  if not (enabled and i and i.getVehicles) then return end
  for id, rec in pairs(i.getVehicles()) do
    if tostring(rec.fleetId) == tostring(msg.fid) then
      rec.fleetId = nil
      i.setVehicleDirty(id)
      toast("info", "This car is now yours.")
    end
  end
end

function M.onExtensionLoaded()
  net.on("rlsmpFleetRetire", onRetire)
  net.on("rlsmpFleetDo", onDo)
  net.on("rlsmpFleetAck", onAck)
  net.onBig("fleetVehicle", onVehicle)
end

M._onDo, M._onAck, M._onVehicle, M._onRetire = onDo, onAck, onVehicle, onRetire
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
