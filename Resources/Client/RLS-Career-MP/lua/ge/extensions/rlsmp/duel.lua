-- RLS-Career-MP client extension "rlsmp_duel": pink-slip duels (server rules in server/duel.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server runs the duel. This side only: answers "which car are you in and where", reports its position once a second,
-- tells the server when it reached the finish, and moves a car between inventory and server (never deleting before the server confirms).

local M = {}

local net = require("rlsmp/lib/net")

local enabled = false
local duelId, finish, radius, finished
local pingTimer, finishTimer = 0, 0

function M.enable(on)
  enabled = on == true
  if not enabled then duelId, finish, finished = nil, nil, nil end
end

local function inv() return overhaul_career_garage_inventory end
local function toast(kind, msg)
  guihooks.trigger("toastrMsg", {type = kind, title = "Pink-slip duel", msg = msg, config = {timeOut = 6000}})
end

local function myPos()
  local veh = getPlayerVehicle(0)
  local p = veh and veh:getPosition()
  return p and {x = p.x, y = p.y, z = p.z} or nil
end

local function onWho(msg)
  if not enabled then return end
  duelId = msg.id
  local i = inv()
  local id = i.getCurrentVehicle()
  local rec = id and i.getVehicle(id)
  local ok = rec and overhaul_career_logistics_general.canRemoveLogisticsVehicle(id) and not rec.fleetId
  net.send("rlsmpDuelCar", {id = msg.id, inv = ok and id or nil, model = rec and rec.model, pos = myPos()})
end

local function onGo(msg)
  if not enabled then return end
  duelId, finish, radius, finished = msg.id, msg.finish, tonumber(msg.radius) or 30, false
  toast("info", "GO!")
end

local function onEnd()
  duelId, finish, finished = nil, nil, nil
end

local function onHand(msg)
  if not enabled then return end
  local rec = inv().getVehicle(msg.inv)
  if not rec or not overhaul_career_logistics_general.canRemoveLogisticsVehicle(msg.inv) then
    return toast("warning", "A car you lost in a duel is owed, but it can't be moved right now (job or listing?).")
  end
  rlsmp_fleet.upload("duelHand", {slip = msg.slip, inv = msg.inv, rec = rlsmp_fleet.cleanCopy(rec)})
end

local function onAck(msg)
  if not enabled or not msg.ok or not msg.inv then return end
  inv().removeVehicle(msg.inv)
  if rlsmp_saveBridge then rlsmp_saveBridge.requestSave("rlsmp_duel") end
  toast("info", "You lost the duel. Your car went to the winner.")
end

-- The winner's car arrived.
local function onVehicle(text, extra)
  local slip = extra and extra.slip
  local function release(why)
    net.send("rlsmpDuelRelease", {slip = slip, why = why})
    toast("warning", why)
  end
  if not enabled then return release("not ready") end
  -- Already in the garage from an earlier delivery whose confirmation got lost: just confirm again.
  for _, rec in pairs(inv().getVehicles and inv().getVehicles() or {}) do
    if rec.slipId == slip then return net.send("rlsmpDuelReceived", {slip = slip}) end
  end
  if not text then return release("download failed") end
  local newId, record = rlsmp_fleet.spawnIntoGarage((jsonDecode(text) or {}).rec)
  if not newId then return release(record) end
  if record then
    record.slipId = slip
    inv().setVehicleDirty(newId)
  end
  if rlsmp_saveBridge then rlsmp_saveBridge.requestSave("rlsmp_duel") end
  net.send("rlsmpDuelReceived", {slip = slip})
  toast("info", "You won a car!")
end

function M.onUpdate(dtReal)
  if not enabled or not duelId then return end
  pingTimer = pingTimer + (dtReal or 0)
  if pingTimer >= 1 then
    pingTimer = 0
    local p = myPos()
    if p then net.send("rlsmpDuelPos", {pos = p}) end
  end
  if finish and not finished then
    finishTimer = finishTimer + (dtReal or 0)
    if finishTimer >= 0.25 then
      finishTimer = 0
      local p = myPos()
      if p then
        local dx, dy = p.x - finish.x, p.y - finish.y
        if dx * dx + dy * dy <= radius * radius then
          finished = true
          net.send("rlsmpDuelFinish", {id = duelId})
        end
      end
    end
  end
end

function M.onExtensionLoaded()
  net.on("rlsmpDuelWho", onWho)
  net.on("rlsmpDuelGo", onGo)
  net.on("rlsmpDuelEnd", onEnd)
  net.on("rlsmpDuelHand", onHand)
  net.on("rlsmpDuelAck", onAck)
  net.onBig("duelVehicle", onVehicle)
end

M._onWho, M._onGo, M._onHand, M._onAck, M._onVehicle = onWho, onGo, onHand, onAck, onVehicle
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
