-- RLS-Career-MP client extension "rlsmp_duel": pink-slip duels (server rules in server/duel.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server runs the duel. This side only: answers "which car are you in and where", reports its position once a second,
-- tells the server when it reached the finish, removes a lost car when the server says so (the server builds the
-- winner's car from its own copy of the save; nothing is uploaded from here), and adds a won car to the garage.

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
  -- cur = the car we sit in right now; the server refuses the stake unless it is the staked car.
  net.send("rlsmpDuelCar", {id = msg.id, inv = ok and id or nil, cur = id, model = rec and rec.model, pos = myPos()})
end

local function onGo(msg)
  if not enabled then return end
  duelId, finish, radius, finished = msg.id, msg.finish, tonumber(msg.radius) or 30, false
  toast("info", "GO!")
end

local function onEnd()
  duelId, finish, finished = nil, nil, nil
end

-- We lost: the server already took its copy of the car, so remove it from the garage and save.
-- If this fails (job, listing, not loaded) the server drops it on the next join instead.
local function onAck(msg)
  if not enabled or not msg.ok or not msg.inv then return end
  local rec = inv().getVehicle(msg.inv)
  if not rec or (msg.model and rec.model ~= msg.model) then return end
  if not overhaul_career_logistics_general.canRemoveLogisticsVehicle(msg.inv) then
    return toast("warning", "You lost the duel. The car is in use right now; it leaves your garage when you next join.")
  end
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
  net.on("rlsmpDuelAck", onAck)
  net.onBig("duelVehicle", onVehicle)
end

M._onWho, M._onGo, M._onAck, M._onVehicle = onWho, onGo, onAck, onVehicle
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("duel", M)
return M
