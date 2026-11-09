-- RLS-Career-MP client extension "rlsmp_fakePlate": a fake plate on your OWN car (garage computer button "Fake plate").
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The button (garage.lua calls M.tile) asks the server (rlsmpFakeAsk); the server answers rlsmpFakeState with 3 random plate texts. A popup (vanilla
-- guihook showConfirmationDialog, like garage.lua) offers "Fit <plate>", "Other plates", "Restore real plate" and Close. A fit goes to the server
-- (rlsmpFakeFit), which uses up one fake_plate item and keeps the record (which car wears which fake plate, what the real plate was); only when it
-- says ok the plate changes on the car: RLS's own record (config.licenseName, saved with the career) AND the live car (dyn field licenseText +
-- core_vehicles.setPlateText, the same pair RLS's vehicles/licensePlates.lua uses). Restore does the same with the real plate.
-- A check every few seconds puts the fake plate back if RLS or a respawn restored the real one, and forgets the record when the car is gone or the
-- plate was changed another way (rlsmpFakeDrop). M.isFake(vehId) is true while a car wears one of our fake plates (read by theft.hasFakePlate, which
-- police.lua uses: no radar and no police fines). Everything about RLS/BeamNG behaviour is UNVERIFIED in game. Log tag RLSMP-FAKEPLATE.
-- Server: server/fakePlates.lua. Pure rules: lib/fakePlate.lua. docs/RESEARCH_FAKE_PLATES.md.

local M = {}

local net = require("rlsmp/lib/net")
local L = require("rlsmp/lib/fakePlate")

local TAG = "RLSMP-FAKEPLATE"
local CHECK_EVERY = 3        -- seconds between two checks of the cars
local FIRST_CHECK = 20       -- seconds after the first server state (RLS has to load its garage first)
local MAX_REAPPLY = 5        -- tries per record before we give up and wait for the player to look
local MISSING_DROP = 3       -- checks in a row with no matching garage car before the record is forgotten

local enabled = false
local clock, checkTimer = 0, 0
local synced                 -- clock when the first server state arrived
local records = {}           -- fake plate text -> {fake, real, inv, model, tries, missing}
local have = 0               -- fake_plate items the player owns (from the server)
local serverOn = true
local target                 -- {inv, choices = {...}}
local wantOpen               -- inventory id waiting for the server's choices

local function say(level, msg) log(level, TAG, msg) end
local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Fake plate", msg = msg, config = {timeOut = ms or 6000}}) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then target, wantOpen = nil, nil end
end

local function inventory() return overhaul_career_garage_inventory end
local function vehicles()
  local inv = inventory()
  return inv and inv.getVehicles and inv.getVehicles() or {}
end

local function objOf(vehId) return vehId and getObjectByID and getObjectByID(vehId) or nil end
local function liveObject(inv)
  local api = inventory()
  local ok, vehId = pcall(function() return api.getVehicleIdFromInventoryId(inv) end)
  vehId = ok and vehId or nil
  return objOf(vehId), vehId
end

local function plateOfObject(obj)
  local text
  if core_vehicles and core_vehicles.getVehicleLicenseText then
    local ok, got = pcall(core_vehicles.getVehicleLicenseText, obj)
    if ok then text = got end
  end
  if (text == nil or text == "") and obj.getDynDataFieldbyName then
    local ok, got = pcall(obj.getDynDataFieldbyName, obj, "licenseText", 0)
    if ok then text = got end
  end
  return L.clean(text)
end

-- True while this car (vehicle id) wears one of our fake plates. The plate on the car is what counts, so a respawn or a changed plate ends it.
function M.isFake(vehId)
  if next(records) == nil then return false end
  local obj = objOf(vehId)
  local plate = obj and plateOfObject(obj)
  return plate ~= nil and records[plate] ~= nil
end

-- Change the plate text of a garage car: RLS's record and, when the car is spawned, the car itself. Returns true when it worked.
local function applyPlate(inv, text)
  local v = vehicles()[inv]
  if not (v and type(v.config) == "table") then return false end
  local obj, vehId = liveObject(inv)
  local viaRls = false
  if obj and inventory().setLicensePlateText then
    viaRls = pcall(inventory().setLicensePlateText, inv, text)    -- sets config.licenseName and core_vehicles.setPlateText (not for a car that is not spawned: RLS bug)
  end
  v.config.licenseName = text
  if obj then
    if obj.setDynDataFieldbyName then obj:setDynDataFieldbyName("licenseText", 0, text) end
    if not viaRls and core_vehicles and core_vehicles.setPlateText then pcall(core_vehicles.setPlateText, text, vehId) end
  end
  if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then pcall(overhaul_career_saveSystem.saveCurrent) end
  local c = overhaul_career_garage_computer
  if c and c.refreshMenu then pcall(c.refreshMenu) end
  say("I", string.format("plate of garage car %s is now %s (%s)", tostring(inv), text, obj and "live car changed" or "car not spawned"))
  return true
end

-- The plate a garage car has now: RLS's record (config.licenseName) or, when RLS never stored one (a car bought or loaded without a saved plate,
-- seen in a real game: the plate is on the car but the record is empty), the plate text of the live car.
local function plateOfCar(inv, v)
  local plate = v and v.config and L.clean(v.config.licenseName)
  if plate then return plate end
  local obj = liveObject(inv)
  return obj and plateOfObject(obj) or nil
end

local function recordFor(inv)
  local v = vehicles()[inv]
  local plate = plateOfCar(inv, v)
  return plate and records[plate] or nil
end

-- Why the button is greyed out (nil = fine).
function M.blockedReason(inv)
  local v = vehicles()[inv]
  if not v then return "Unknown car." end
  if not serverOn then return "Fake plates are off on this server." end
  if v.owned == false then return "You do not own this car." end
  if v.timeToAccess or v.listedForAuction then return "This car is not available right now." end
  if rlsmp_police and rlsmp_police.isPursuit and rlsmp_police.isPursuit() == true then return "Lose the police first." end
  local p = overhaul_career_permissions
  if p and p.getStatusForTag then
    local ok, st = pcall(p.getStatusForTag, {"vehicleLicensePlate", "vehicleModification"}, {inventoryId = inv})
    if ok and st and st.allow == false then return "The plate of this car cannot be changed right now." end
  end
  return nil
end

-- The garage computer tile for one car (garage.lua puts it into computerFunctions.vehicleSpecific[inv]).
function M.tile(inv)
  local entry = {id = "rlsmpFakePlate", label = recordFor(inv) and "Fake plate (fitted)" or "Fit fake plate", order = 44,
                 callback = function() M.openFor(inv) end}
  local why = M.blockedReason(inv)
  if why then entry.disabled, entry.reason = true, {type = "text", label = why} end
  return entry
end

function M.openFor(inv)
  if not enabled then return end
  local why = M.blockedReason(inv)
  if why then return toast("warning", why) end
  wantOpen = inv
  net.send("rlsmpFakeAsk", {})
end

local function button(label, action, index)
  -- action and index are our own fixed word and number (checked again in M.choose), so building Lua text from them is safe.
  return {label = label, luaCallback = string.format("rlsmp_fakePlate.choose(%q, %d)", action, index or 0), enabled = true}
end

local function showPopup()
  local inv = target.inv
  local v = vehicles()[inv]
  if not v then return end
  local worn = recordFor(inv)
  local text = string.format("%s, plate %s\nFake plates you own: %d", tostring(v.niceName or v.model or "Car"),
    tostring(v.config and v.config.licenseName or "?"), have)
  local buttons = {}
  if worn then
    text = text .. string.format("\nA fake plate is fitted. Your real plate is %s.", worn.real)
    buttons[#buttons + 1] = button("Restore real plate (" .. worn.real .. ")", "restore")
  elseif have > 0 then
    text = text .. "\nFitting uses up one fake plate. Cops read the fake plate, not your real one."
    for i, plate in ipairs(target.choices or {}) do buttons[#buttons + 1] = button("Fit " .. plate, "fit", i) end
    buttons[#buttons + 1] = button("Other plates", "more")
  else
    text = text .. "\nYou have no fake plate. Buy one in the Black Market app."
  end
  buttons[#buttons + 1] = {label = "Close", luaCallback = "", enabled = true}
  if guihooks then guihooks.trigger("showConfirmationDialog", {text = text, buttons = buttons, class = "recoveryPrompt"}) end
end

-- A dialog button (raw Lua string, see button()).
function M.choose(action, index)
  local t = target
  if not (enabled and t and type(action) == "string") then return end
  if action == "more" then return M.openFor(t.inv) end
  local why = M.blockedReason(t.inv)
  if why then return toast("warning", why) end
  local v = vehicles()[t.inv]
  if action == "fit" then
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index > #(t.choices or {}) then return end
    local real = plateOfCar(t.inv, v)
    if not real then return toast("warning", "This car has no plate text yet. Try again in a moment.") end
    say("I", string.format("fit request: car %s, choice %d", tostring(t.inv), index))
    net.send("rlsmpFakeFit", {inv = t.inv, idx = index, real = real, model = v.model})
  elseif action == "restore" then
    local worn = recordFor(t.inv)
    if worn then net.send("rlsmpFakeRestore", {fake = worn.fake}) end
  end
end

-- Server answers ---------------------------------------------------------------------------------------------

local function onState(d)
  if type(d) ~= "table" then return end
  records = {}
  for _, r in ipairs(type(d.list) == "table" and d.list or {}) do
    local fake, real = L.clean(r.fake), L.clean(r.real)
    if fake and real then
      local old = records[fake]
      records[fake] = {fake = fake, real = real, inv = tonumber(r.inv), model = r.model, tries = 0, missing = 0}
      if old then records[fake].tries, records[fake].missing = old.tries, old.missing end
    end
  end
  have = math.max(0, math.floor(tonumber(d.have) or 0))
  serverOn = d.enabled ~= false
  synced = synced or clock
  if enabled and wantOpen and type(d.choices) == "table" then
    target = {inv = wantOpen, choices = d.choices}
    wantOpen = nil
    showPopup()
  end
end

local function onResult(d)
  if not enabled or type(d) ~= "table" then return end
  if d.ok ~= true then return toast("warning", tostring(d.err or "No."), 8000) end
  local inv = tonumber(d.inv)
  if d.action == "fit" then
    if not (inv and applyPlate(inv, d.fake)) then
      net.send("rlsmpFakeRestore", {fake = d.fake, failed = true})      -- the game could not do it: the server forgets the record and gives the item back
      return toast("error", "Could not change the plate. Nothing was used up.")
    end
    toast("success", "Fake plate " .. tostring(d.fake) .. " fitted.")
  elseif d.action == "restore" and not d.failed then
    if inv and applyPlate(inv, d.real) then toast("success", "Real plate " .. tostring(d.real) .. " is back.")
    else toast("warning", "The server forgot the fake plate, but the car was not found. Check the plate in the garage.") end
  end
end

-- Keep the plates right ------------------------------------------------------------------------------------

-- The garage car that goes with a record: its remembered inventory id if that car still has the fake or the real plate, else any car with the fake plate,
-- else the remembered car with another plate.
local function findCar(rec)
  local list = vehicles()
  local function has(v, plate) return v and v.config and L.clean(v.config.licenseName) == plate end
  local v = rec.inv and list[rec.inv]
  if v and (has(v, rec.fake) or has(v, rec.real)) then return rec.inv, v end
  for id, other in pairs(list) do
    if has(other, rec.fake) and (rec.model == nil or other.model == rec.model) then return id, other end
  end
  if v and v.model == rec.model then return rec.inv, v end    -- same car, other plate: the player changed it (decide says drop)
  return nil
end

local function check()
  if next(vehicles()) == nil then return end
  for fake, rec in pairs(records) do
    local inv, v = findCar(rec)
    if not inv then
      rec.missing = rec.missing + 1
      if rec.missing >= MISSING_DROP then
        say("I", "fake plate " .. fake .. ": the car is gone, record dropped")
        records[fake] = nil
        net.send("rlsmpFakeDrop", {fake = fake})
      end
    else
      rec.missing, rec.inv = 0, inv
      local obj = liveObject(inv)
      local what = L.decide(rec, v.config.licenseName, obj and plateOfObject(obj) or nil)
      if what == "reapply" and rec.tries < MAX_REAPPLY then
        rec.tries = rec.tries + 1
        say("W", string.format("fake plate %s was replaced on car %s, putting it back (try %d)", fake, tostring(inv), rec.tries))
        applyPlate(inv, fake)
      elseif what == "drop" then
        say("I", "fake plate " .. fake .. ": plate was changed another way, record dropped")
        records[fake] = nil
        net.send("rlsmpFakeDrop", {fake = fake})
      elseif what == "ok" then
        rec.tries = 0
      end
    end
  end
end

function M.onUpdate(dtReal, dtSim)
  clock = clock + (tonumber(dtSim) or tonumber(dtReal) or 0)
  if not (enabled and synced) or clock - synced < FIRST_CHECK then return end
  checkTimer = checkTimer + (tonumber(dtSim) or tonumber(dtReal) or 0)
  if checkTimer < CHECK_EVERY then return end
  checkTimer = 0
  local ok, err = pcall(check)
  if not ok then say("E", "check failed: " .. tostring(err)) end
end

function M.onServerLeave()
  records, have, target, wantOpen, synced, serverOn = {}, 0, nil, nil, nil, true
  clock, checkTimer = 0, 0
end

function M.onExtensionLoaded()
  net.on("rlsmpFakeState", onState)
  net.on("rlsmpFakeResult", onResult)
end

M._records = function() return records end
M._check = check
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("fakePlate", M)
return M
