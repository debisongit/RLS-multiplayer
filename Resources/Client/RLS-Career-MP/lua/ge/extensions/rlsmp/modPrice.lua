-- RLS-Career-MP client extension "rlsmp_modPrice": fair dealership prices for modded cars.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS prices a shop listing with overhaul_career_market_valueCalculator.getVehicleValuation(opts) (called with
-- opts.logContext == "updateVehicleList" only by vehicleShopping/stock.lua). Its catalog value is the sum of the car's part values,
-- or the jbeam "Value" when the car has fewer than 3 valued parts: mod authors often get both wrong.
-- We wrap that function, let RLS compute as usual, and for a modded model scale the result to the estimate of lib/modPrice.lua.
-- Selling a car later does not go through this wrapper (see docs/RESEARCH_MOD_PRICES.md). Anything unexpected = the game's own price.
-- The wrapper is registered with RLS's wrapperLifetime like the other wrappers and re-checked every frame.

local M = {}

local net = require("rlsmp/lib/net")
local p3 = require("rlsmp/lib/p3")
local MP = require("rlsmp/lib/modPrice")

local cfg                 -- sanitized settings from the server; nil until it speaks (then the game's prices stay)
local slot = {}           -- ours (wrapper), on (the table), layer (state of the newest wrapper)
local wl, tries = nil, 0
local modded = {}         -- model -> true | false
local logged, loggedCount = {}, 0
local MAX_LOG = 120

local function numOf(info, key)
  local v = tonumber(info[key])
  if v then return v end
  local a = type(info.aggregates) == "table" and info.aggregates[key]
  if type(a) == "table" then return tonumber(a.max) or tonumber(a.min) end
  return tonumber(a)
end

local function strOf(info, key)
  local v = info[key]
  if type(v) == "string" then return v end
  local a = type(info.aggregates) == "table" and info.aggregates[key]
  if type(a) == "string" then return a end
  if type(a) == "table" then for k, on in pairs(a) do if on == true then return tostring(k) end end end
  return nil
end

local function specOf(info, age)
  local year = tonumber(os.date("%Y"))
  return {
    hp = numOf(info, "Power"), weight = numOf(info, "Weight"), topSpeed = numOf(info, "Top Speed"),
    drivetrain = strOf(info, "Drivetrain"), year = year and age and (year - age) or nil,
    words = table.concat({strOf(info, "Type") or "", strOf(info, "Body Style") or "", strOf(info, "Config Type") or "", tostring(info.Name or "")}, " "),
  }
end

local function realPath(model)
  if not (FS and FS.getFileRealPath) then return nil end
  local ok, p = pcall(FS.getFileRealPath, FS, "/vehicles/" .. model .. "/info.json")
  return ok and type(p) == "string" and p or nil
end

local function isModded(model)
  if modded[model] == nil then
    local path = realPath(model)
    modded[model] = MP.isModded({listed = cfg.models[model] == true, path = path})
    if loggedCount < MAX_LOG then
      loggedCount = loggedCount + 1
      p3.log("I", string.format("modprice: model %s is %s (listed=%s path=%s)", model, modded[model] and "a mod car" or "left alone", tostring(cfg.models[model] == true), tostring(path)))
    end
  end
  return modded[model]
end

local function adjust(opts, valuation)
  local model, config = opts.modelName, opts.configKey
  if type(model) ~= "string" or type(config) ~= "string" then return end
  local info = type(opts.configInfo) == "table" and opts.configInfo or {}
  local hasOverride = cfg.overrides[model .. "/" .. config] or cfg.overrides[model]
  if not hasOverride and not isModded(model) then return end
  local gameValue = tonumber(valuation.catalogValue)
  local used, est, why = MP.decide(cfg, {model = model, config = config}, specOf(info, opts.age), gameValue)
  local key = model .. "/" .. config
  if used and gameValue and math.abs(used - gameValue) > 0.5 then MP.rescale(valuation, used, cfg.min) else why = used and "author" or "game" end
  if not logged[key] and loggedCount < MAX_LOG then
    logged[key] = true
    loggedCount = loggedCount + 1
    p3.log("I", string.format("modprice: %s author=%s source=%s estimate=%s used=%s (%s) hp=%s kg=%s",
      key, tostring(info.rawCatalogValue or info.Value), tostring(info.catalogValueSource), est and string.format("%.0f", est) or "-",
      used and string.format("%.0f", used) or "game", why, tostring(numOf(info, "Power")), tostring(numOf(info, "Weight"))))
  end
  p3.count("modprice " .. why)
end

local function make(mine, original)
  return function(opts, ...)
    local v = original(opts, ...)
    if not (mine.active and cfg and cfg.enabled and type(v) == "table" and type(opts) == "table" and opts.logContext == "updateVehicleList") then return v end
    local ok, err = pcall(adjust, opts, v)
    if not ok then p3.logOnChange("modprice-err", tostring(err), "W", "modprice: failed, the game's price is used: " .. tostring(err)) end
    return v
  end
end

-- RLS's wrapperLifetime, loaded once (a failed require is retried about once a second).
local function lifetime()
  if wl then return wl end
  tries = tries + 1
  if tries % 60 ~= 1 then return nil end
  local ok, mod = pcall(require, "overhaul/lib/shell/wrapperLifetime")
  if ok and type(mod) == "table" and mod.registerForwarder and mod.intact then wl = mod return wl end
  return nil
end

function M.install()
  local target = rawget(_G, "overhaul_career_market_valueCalculator")
  if type(target) ~= "table" or type(target.getVehicleValuation) ~= "function" then return false end
  local lib = lifetime()
  if not lib then return false end
  if slot.ours and slot.on == target and lib.intact({target = target, key = "getVehicleValuation", replacement = slot.ours}) then return true end
  local original = target.getVehicleValuation
  if slot.layer then
    slot.layer.active = false
    p3.log("W", "modprice: rewrapped getVehicleValuation (RLS or the game replaced it); the older layer is now a passthrough")
  end
  local mine = {active = true}
  slot.layer = mine
  local wrapper = make(mine, original)
  lib.registerForwarder(wrapper, original)
  slot.ours, slot.on = wrapper, target
  target.getVehicleValuation = wrapper
  p3.log("I", "modprice: wrapped valueCalculator.getVehicleValuation")
  return true
end

local function onConfig(data)
  cfg = MP.sanitize(data)
  modded, logged, loggedCount = {}, {}, 0
  local n, o = 0, 0
  for _ in pairs(cfg.models) do n = n + 1 end
  for _ in pairs(cfg.overrides) do o = o + 1 end
  p3.log("I", string.format("modprice: settings received: enabled=%s min=%.0f max=%.0f tolerance=%.2f listed models=%d overrides=%d",
    tostring(cfg.enabled), cfg.min, cfg.max, cfg.tolerance, n, o))
  M.install()
end

function M.onUpdate() M.install() end
function M.onServerLeave() cfg, modded, logged, loggedCount = nil, {}, {}, 0 end
function M.getConfig() return cfg end
function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpModPrice", onConfig)
  p3.log("I", "rlsmp_modPrice loaded")
end

M._onConfig = onConfig
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
