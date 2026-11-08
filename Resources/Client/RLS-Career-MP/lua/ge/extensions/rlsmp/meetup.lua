-- RLS-Career-MP client extension "rlsmp_meetup": a sale is finished at a meetup spot the server picks (rules: server/meetup.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- 1. Hook (UNVERIFIED IN-GAME): RLS's Marketplace pays through overhaul_career_garage_inventory.sellVehicle(inventoryId, price), looked
--    up through the global at call time. We wrap that one field (once; identity re-checked every frame). If the caller is the Marketplace
--    (call stack contains marketplace.lua, see lib/meetup.lua) the sale is held back (we return false), the server is asked for a meetup.
--    Garage sell, car meets and the auction are not touched.
-- 2. The server answers with a spot: we draw a marker and set a GPS route (core_groundMarkers, like RLS's own jobs do).
-- 3. Stop inside the circle for a few seconds: we tell the server (rlsmpMeetupArrive). Its answer is final:
--      ok (market)  -> we run the held sale with RLS's own sellVehicle (the money flows through RLS and the wallet as for any sale)
--      ok (black)   -> the server paid; we delete the stolen car
--      setup        -> 1 or 2 police chase us (RLS setPursuitMode on the nearest units); the sale does not happen
-- Entry points: the Marketplace app (the hook above) for garage cars, and the Black Market phone app button for a stolen car you drive or stand
-- next to (rlsmp_market.uiAct "meetup" -> M.startBlack, "meetupCancel" -> M.cancel). Hidden developer chat /meetup [black] does the same.

local M = {}

local net = require("rlsmp/lib/net")
local L = require("rlsmp/lib/meetup")

local enabled = false
local original, ours          -- the game's sellVehicle and our wrapper
local bypass = false           -- true while WE call the real sellVehicle
local held                     -- {inv, price, plate, model, soldVehicle, kind, carId} waiting for the server's spot
local meetup                   -- {id, kind, x, y, z, radius, expireAt, held, token}
local hold = L.newHold()
local clock, sentAt, retryAt = 0, nil, 0
local STEP = 0.25
local stepTimer = 0

local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Meetup", msg = msg, config = {timeOut = ms or 8000}}) end
end
local function say(level, msg) log(level, "RLSMP-MEETUP", msg) end
local function inventory() return overhaul_career_garage_inventory end

local function playerObj() return getPlayerVehicle and getPlayerVehicle(0) or nil end
local function playerPos()
  local o = playerObj()
  local p = o and o:getPosition()
  return p and {x = p.x, y = p.y, z = p.z} or nil
end

-- Route ---------------------------------------------------------------------------------------------------
local function setRoute(m)
  if not (core_groundMarkers and core_groundMarkers.setPath and vec3) then return end
  local ok, token = pcall(core_groundMarkers.setPath, vec3(m.x, m.y, m.z), {clearPathOnReachingTarget = false})
  if ok then m.token = token else say("W", "setPath failed: " .. tostring(token)) end
end

local function clearRoute(m)
  if not (m and m.token ~= nil and core_groundMarkers) then return end
  if core_groundMarkers.clearOwnedPath then pcall(core_groundMarkers.clearOwnedPath, m.token)
  elseif core_groundMarkers.setPath then pcall(core_groundMarkers.setPath, nil) end
end

local function endMeetup()
  clearRoute(meetup)
  meetup, held, sentAt = nil, nil, nil
  hold = L.newHold()
end

-- The hook --------------------------------------------------------------------------------------------------
local function stackSources()
  local out = {}
  if not (debug and debug.getinfo) then return out end
  for level = 3, 14 do
    local info = debug.getinfo(level, "S")
    if not info then break end
    out[#out + 1] = info.source or info.short_src
  end
  return out
end

local function carInfo(inv, id)
  local ok, v = pcall(function() return inv.getVehicles()[id] end)
  if not ok or type(v) ~= "table" then return nil end
  return v, v.config and v.config.licenseName, v.model
end

local function ask(body)
  if body.plate and rlsmp_theft and rlsmp_theft.damageOfPlate then body.damage = rlsmp_theft.damageOfPlate(body.plate) end   -- stolen cars only
  if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
  net.send("rlsmpMeetupRequest", body)
end

-- Hold a sale back and ask the server for a meetup. Returns false when the car is unknown.
local function holdSale(inventoryId, price)
  local inv = inventory()
  local v, plate, model = carInfo(inv, inventoryId)
  if not v then return false end
  local value = tonumber(price)
  if value == nil and overhaul_career_market_valueCalculator then
    local ok, q = pcall(overhaul_career_market_valueCalculator.getInventoryVehicleSellValue, inventoryId)
    value = ok and tonumber(q) or 0
  end
  held = {inv = inventoryId, price = value, plate = plate, model = model, soldVehicle = v, kind = "market"}
  say("I", string.format("held sale of car %s (%s) for %s", tostring(inventoryId), tostring(plate), tostring(value)))
  ask({kind = "market", inv = inventoryId, plate = plate, model = model, price = value})
  return true
end

local function wrapper(inventoryId, price, ...)
  if not enabled or bypass or not L.fromMarketplace(stackSources()) then return original(inventoryId, price, ...) end
  if meetup or held then
    toast("warning", "You already have a meetup open. Finish it or drop it in the Black Market app.")
    return false
  end
  if not holdSale(inventoryId, price) then return original(inventoryId, price, ...) end   -- unknown car: do not get in the way
  return false
end

-- Wrap once per table; called every frame so a reloaded RLS table is wrapped again.
function M.install()
  local inv = inventory()
  if type(inv) ~= "table" or type(inv.sellVehicle) ~= "function" then return false end
  if inv.sellVehicle == ours then return true end
  original = inv.sellVehicle
  ours = wrapper
  inv.sellVehicle = ours
  say("I", "wrapped overhaul_career_garage_inventory.sellVehicle")
  return true
end

-- Server answers -------------------------------------------------------------------------------------------
local function onSet(d)
  if not enabled then return end
  local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
  if not (x and y and z and d.id) then return end
  local old = meetup
  meetup = {id = tostring(d.id), kind = d.kind == "black" and "black" or "market", x = x, y = y, z = z,
    radius = tonumber(d.radius) or 15, expireAt = clock + (tonumber(d.expiresIn) or 600), spot = tostring(d.spot or "the meetup spot"),
    held = held}
  if old and old.id ~= meetup.id then clearRoute(old) end
  hold = L.newHold()
  setRoute(meetup)
  toast("info", "Meetup with the buyer at " .. meetup.spot .. ". Follow the GPS route, then stop at the marker.")
end

local function onDenied(d)
  held = nil
  toast("warning", tostring(d.err or "No buyer right now."))
end

local function onClear(d)
  if meetup and (d.id == nil or tostring(d.id) == meetup.id) then endMeetup() end
end

-- 1 or 2 police chase the player. UNVERIFIED IN-GAME: needs police units to exist already (RLS police traffic).
local function startSetup(cops)
  local svc = overhaul_integration_services_police
  local pid = be and be:getPlayerVehicleID(0)
  local at = playerPos()
  local units = {}
  if svc and svc.getPoliceVehicles and at then
    for id in pairs(svc.getPoliceVehicles() or {}) do
      local o = be:getObjectByID(id)
      local p = o and o:getPosition()
      if p then units[id] = {x = p.x, y = p.y} end
    end
  end
  local ids = L.nearestCops(units, at or {x = 0, y = 0}, cops)
  if svc and svc.setPursuitMode and pid and #ids > 0 then
    local ok, problem = pcall(svc.setPursuitMode, 1, pid, ids)
    say("I", string.format("setup: setPursuitMode(1) with %d police (%s)", #ids, ok and "ok" or tostring(problem)))
    if ok then return true end
  end
  if rlsmp_plates and rlsmp_plates.startChase and pid then   -- no unit known: let plate reading's chase start try
    say("I", "setup: no police unit found, trying the plate chase")
    return rlsmp_plates.startChase(pid, nil, "meetup")
  end
  say("W", "setup: could not start a chase")
  return false
end

local function deleteCar(id)
  local o = id and be and be:getObjectByID(id)
  if o then o:delete() end
end

local function onResult(d)
  local m = meetup
  if not m or tostring(d.id) ~= m.id then return end
  sentAt = nil
  if d.retry then retryAt = clock + 3 return end
  if d.setup then
    toast("warning", "Something is wrong. That was not a buyer!", 8000)
    endMeetup()
    startSetup(tonumber(d.cops) or 1)
    return
  end
  if not d.ok then
    toast("warning", tostring(d.err or "The buyer walked away."))
    endMeetup()
    return
  end
  if m.kind == "black" then
    deleteCar(m.held and m.held.carId)
    toast("success", string.format("Sold to the buyer for $%d.", math.floor(tonumber(d.pay) or 0)))
    endMeetup()
    return
  end
  local sale = m.held
  endMeetup()
  if not (sale and original) then return end
  bypass = true
  local ok, sold = pcall(original, sale.inv, sale.price)
  bypass = false
  if ok and sold then
    local inv = inventory()
    if inv.publishVehicleSale then pcall(inv.publishVehicleSale, sale.inv, sale.price, sale.price, sale.soldVehicle) end
    toast("success", "Sold. The buyer took the car.")
  else
    say("W", "held sale failed: " .. tostring(sold))
    toast("error", "The sale could not be completed. Try selling again.")
  end
end

-- Entry points without the hook --------------------------------------------------------------------------------
local function onAsk(d)
  if not enabled then return end
  if meetup or held then return toast("warning", "You already have a meetup open.") end
  if d.kind == "black" then
    local car
    local pid = be and be:getPlayerVehicleID(0)
    local at = playerPos()
    if rlsmp_theft and rlsmp_theft.stolenCars then
      for _, rec in ipairs(rlsmp_theft.stolenCars()) do
        if rec.vehId == pid then car = rec end
      end
      if not car and at and rlsmp_theft.nearestStolen then car = rlsmp_theft.nearestStolen(at, 8) end
    end
    if not car or not car.plate then return toast("warning", "Sit in (or stand next to) the stolen car you want to sell.") end
    held = {kind = "black", carId = car.vehId, plate = car.plate}
    return ask({kind = "black", plate = car.plate, model = car.model, price = car.value})
  end
  local inv = inventory()
  local pid = be and be:getPlayerVehicleID(0)
  local ok, id = pcall(inv.getInventoryIdFromVehicleId, pid)
  if not ok or id == nil then return toast("warning", "Sit in the garage car you want to sell.") end
  if not holdSale(id, nil) then toast("warning", "RLS does not know that car.") end
end

function M.startBlack() onAsk({kind = "black"}) end

function M.cancel() net.send("rlsmpMeetupCancel", {}) end

-- Frame ---------------------------------------------------------------------------------------------------------
local function draw(m)
  if not (debugDrawer and vec3) then return end
  pcall(function()
    debugDrawer:drawSphere(vec3(m.x, m.y, m.z + 1), m.radius, ColorF(0.2, 0.6, 1, 0.35))
  end)
end

function M.onUpdate(dtReal)
  if not enabled then return end
  dtReal = dtReal or 0
  clock = clock + dtReal
  M.install()
  local m = meetup
  if not m then return end
  if clock >= m.expireAt then toast("warning", "The buyer gave up waiting.") return endMeetup() end
  draw(m)
  stepTimer = stepTimer + dtReal
  if stepTimer < STEP then return end
  local dt = stepTimer
  stepTimer = 0
  local o = playerObj()
  local p = playerPos()
  if not (o and p) or sentAt or clock < retryAt then return end
  local vel = o.getVelocity and o:getVelocity()
  local speed = vel and vel:length() or 0
  if L.step(hold, dt, L.dist2d(p, m), speed, m.radius) then
    sentAt = clock
    if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
    local hp = m.held and m.held.plate
    net.send("rlsmpMeetupArrive", {id = m.id, damage = hp and rlsmp_theft and rlsmp_theft.damageOfPlate and rlsmp_theft.damageOfPlate(hp) or nil})
  end
end

function M.enable(on)
  enabled = on == true
  if not enabled then endMeetup() end
end

function M.onServerLeave() endMeetup() end

function M.onExtensionLoaded()
  net.on("rlsmpMeetupSet", onSet)
  net.on("rlsmpMeetupDenied", onDenied)
  net.on("rlsmpMeetupClear", onClear)
  net.on("rlsmpMeetupResult", onResult)
  net.on("rlsmpMeetupAsk", onAsk)
end

M._meetup = function() return meetup end
M._held = function() return held end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("meetup", M)
return M
