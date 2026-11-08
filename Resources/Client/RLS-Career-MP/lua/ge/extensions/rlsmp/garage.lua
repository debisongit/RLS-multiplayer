-- RLS-Career-MP client extension "rlsmp_garage": a "Strip / illegal parts" button in RLS's own garage computer.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS asks every extension for computer buttons with the hook onOverhaulComputerAddFunctions(menuData, computerFunctions)
-- (see docs/RESEARCH_GARAGE_STRIP.md). We add, all with only a Lua callback (no screen of our own, like RLS's "Maintenance" button):
--   * per garage car:  vehicleSpecific[inventoryId].rlsmpStrip   "Strip / illegal parts"
--   * general:         rlsmpStolen  "Stolen car: PLATE" (only when one of our stolen cars stands near the player; stolen cars are not in the
--                      RLS inventory on purpose, RLS's own Sell button would pay full price and skip the fence)
--   * general:         rlsmpItems   "Black market items" (the server's item list; RLS has no item inventory we could safely write to)
-- A button asks the server (rlsmpGarageQuote), the answer (rlsmpGarageMenu) opens a dialog (vanilla guihook showConfirmationDialog, same
-- one RLS's own debug menu uses), a dialog button calls M.choose(action) -> rlsmpGarageDo -> rlsmpGarageResult.
-- All rules and money live in server/fence.lua. This side only removes the car after the server paid. Untested in game. Log tag RLSMP-GARAGE.

local M = {}

local net = require("rlsmp/lib/net")

local TAG = "RLSMP-GARAGE"
local STOLEN_REACH = 60      -- metres from the player to a stolen car to offer the button
local enabled = false
local target                 -- {kind, inventoryId?, plate, model, value, year}

local function say(level, msg) log(level, TAG, msg) end
local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Garage", msg = msg, config = {timeOut = ms or 6000}}) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then target = nil end
end

local function ownedTarget(inventoryId)
  local v = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not v then return nil end
  local value = 0
  if overhaul_career_market_valueCalculator and overhaul_career_market_valueCalculator.getInventoryVehicleValue then
    local ok, got = pcall(overhaul_career_market_valueCalculator.getInventoryVehicleValue, inventoryId)
    if ok then value = tonumber(got) or 0 end
  end
  return {kind = "owned", inventoryId = inventoryId, plate = v.config and v.config.licenseName, model = v.model or v.niceName,
          value = value, year = v.year}
end

-- Why the strip button is greyed out for this garage car (nil = fine). Uses RLS's own rules for selling so loans, rentals and auctions stay safe.
local function blockedReason(inventoryId)
  local v = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not v then return "Unknown car." end
  if v.owned == false then return "You do not own this car." end
  if v.timeToAccess or v.listedForAuction then return "This car is not available right now." end
  local p = overhaul_career_permissions
  if p and p.getStatusForTag then
    local ok, st = pcall(p.getStatusForTag, {"vehicleSelling"}, {inventoryId = inventoryId})
    if ok and st and st.allow == false then return "This car cannot be sold or stripped right now." end
  end
  local g = overhaul_career_logistics_general
  if g and g.canRemoveLogisticsVehicle and not g.canRemoveLogisticsVehicle(inventoryId) then return "This car is on a delivery job." end
  return nil
end

function M.openFor(t)
  if not enabled or not t then return end
  target = t
  net.send("rlsmpGarageQuote", {plate = t.plate, model = t.model, value = t.value, year = t.year})
end

local function openItems()
  if not enabled then return end
  target = nil
  net.send("rlsmpGarageQuote", {})
end

-- The RLS hook. Everything is pcall'd: a bug here must never break RLS's garage screen.
local function addButtons(menuData, computerFunctions)
  if not enabled then return end
  local facility = menuData and menuData.computerFacility
  if not (facility and facility.functions and facility.functions["vehicleInventory"]) then return end
  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    local slot = computerFunctions.vehicleSpecific[inventoryId]
    if slot then
      local entry = {id = "rlsmpStrip", label = "Strip / illegal parts", order = 40,
                     callback = function() M.openFor(ownedTarget(inventoryId)) end}
      local why = blockedReason(inventoryId)
      if why then entry.disabled, entry.reason = true, {type = "text", label = why} end
      slot.rlsmpStrip = entry
    end
  end
  local rec = rlsmp_theft and rlsmp_theft.nearestStolenToPlayer and rlsmp_theft.nearestStolenToPlayer(STOLEN_REACH)
  if rec and rec.plate then
    computerFunctions.general.rlsmpStolen = {id = "rlsmpStolen", label = "Stolen car: " .. tostring(rec.plate), order = 41,
      callback = function()
        M.openFor({kind = "stolen", plate = rec.plate, model = rec.model, value = rec.value, year = rec.year})
      end}
  end
  computerFunctions.general.rlsmpItems = {id = "rlsmpItems", label = "Black market items", order = 42, callback = openItems}
end

function M.onOverhaulComputerAddFunctions(menuData, computerFunctions)
  local ok, err = pcall(addButtons, menuData, computerFunctions)
  if not ok then say("E", "could not add garage buttons: " .. tostring(err)) end
end

-- Server answers -----------------------------------------------------------------------------------------------

local function itemLine(items)
  local parts = {}
  for _, it in ipairs(items or {}) do
    parts[#parts + 1] = tostring(it.label or it.name) .. ((tonumber(it.count) or 1) > 1 and (" x" .. tostring(it.count)) or "")
  end
  return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function button(label, action)
  -- `action` is one of our own fixed words (checked again in M.choose), so building Lua text from it is safe.
  return {label = label, luaCallback = string.format("rlsmp_garage.choose(%q)", action), enabled = true}
end

local function onMenu(d)
  if not enabled or type(d) ~= "table" then return end
  if d.ok ~= true then return toast("warning", tostring(d.err or "No."), 6000) end
  local text = "Your items: " .. itemLine(d.items)
  local buttons = {}
  if target and d.kind then
    text = string.format("%s %s (%s)\n%s", tostring(d.model or "Car"), tostring(d.plate or ""), tostring(d.kind), text)
    if d.kind == "stolen" and #(d.fitted or {}) > 0 then text = text .. "\nFitted: " .. table.concat(d.fitted, ", ") end
    buttons[#buttons + 1] = button(string.format("Strip for $%d (the car is removed)", math.floor(tonumber(d.strip) or 0)), "strip")
    for _, f in ipairs(d.fit or {}) do
      if type(f.name) == "string" and f.name:match("^[%a_]+$") then
        buttons[#buttons + 1] = button("Fit " .. tostring(f.label or f.name), "fit:" .. f.name)
      end
    end
  end
  buttons[#buttons + 1] = {label = "Close", luaCallback = "", enabled = true}
  if guihooks then guihooks.trigger("showConfirmationDialog", {text = text, buttons = buttons, class = "recoveryPrompt"}) end
  say("I", "menu shown: " .. tostring(d.kind) .. " " .. tostring(d.plate))
end

-- Called by a dialog button (raw Lua string, see button()).
function M.choose(action)
  local t = target
  if not (enabled and t and type(action) == "string") then return end
  if not (action == "strip" or action:match("^fit:[%a_]+$")) then return end
  if action == "strip" and t.kind == "owned" then
    local why = blockedReason(t.inventoryId)
    if why then return toast("warning", why) end
  end
  say("I", string.format("choose %s for %s %s", action, t.kind, tostring(t.plate)))
  net.send("rlsmpGarageDo", {action = action, plate = t.plate, model = t.model, value = t.value, year = t.year, inventoryId = t.inventoryId})
end

local function removeOwned(inventoryId)
  local inv = overhaul_career_garage_inventory
  local ok, res = pcall(inv.removeVehicle, inventoryId)      -- also deletes the car's parts (RLS onOverhaulVehicleRemoved)
  if not ok or res == false then
    say("E", "the server paid but RLS would not remove inventory car " .. tostring(inventoryId) .. ": " .. tostring(res))
    toast("error", "Paid, but the game kept the car. Tell the server owner.", 8000)
    return false
  end
  if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then pcall(overhaul_career_saveSystem.saveCurrent) end
  local c = overhaul_career_garage_computer
  if c and c.refreshMenu then pcall(c.refreshMenu) end
  return true
end

local function onResult(d)
  if not enabled or type(d) ~= "table" then return end
  local t = target
  if d.ok ~= true then return toast("warning", tostring(d.err or "No."), 6000) end
  if d.action == "strip" then
    local removedOk = true
    if d.takeCar and t then
      if t.kind == "stolen" then
        if rlsmp_theft and rlsmp_theft.removeStolenByPlate then rlsmp_theft.removeStolenByPlate(t.plate) end
      elseif t.inventoryId then
        removedOk = removeOwned(t.inventoryId)
      end
    end
    target = nil
    if removedOk then toast("success", string.format("Stripped: $%d.", math.floor(tonumber(d.pay) or 0))) end
  else
    toast("success", tostring(d.fitted or "Part") .. " fitted.")
    if t then M.openFor(t) end            -- show the dialog again with the new state
  end
  say("I", string.format("result: action=%s pay=%s", tostring(d.action), tostring(d.pay)))
end

function M.onServerLeave() target = nil end

function M.onExtensionLoaded()
  net.on("rlsmpGarageMenu", onMenu)
  net.on("rlsmpGarageResult", onResult)
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
