-- RLS-Career-MP client extension "rlsmp_trafficVariety": more varied traffic and parked cars (models and configs).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS/the game builds a traffic (or parked) group with core_multiSpawn.createGroup(amount, params). We wrap it: ask for a
-- bigger pool of candidates, add models from server-shipped mods (names + weights from the server), and pick the group with the
-- weights of lib/trafficVariety.lua (per model Type, per road class, day or night, per mod). Police groups are never touched.
-- Anything unexpected (no result, an error, settings not received yet) gives the game its untouched group.
--
-- The wrapper is registered with RLS's own wrapperLifetime.registerForwarder, so RLS's patch refresh sees it as part of the chain
-- and does not stack another layer on top of it (and we never re-wrap while it is intact).
-- Active only in a multiplayer session, while the RLS career is active, after the server's settings arrived (`rlsmpTrafficVariety`).
-- A car keeps its model once it exists, so this changes cars built from now on (traffic start, refills, parked cars).

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local V = require("rlsmp/lib/trafficVariety")

local MOD_CONFIGS_PER_MODEL = 4   -- how many eligible configs of a modded model join the candidate pool

local config            -- sanitized settings from the server; nil until it speaks
local ours, installedOn -- our createGroup wrapper and the core_multiSpawn table it lives on
local typeCache = {}    -- model name -> Type string or false
local missingMods = {}  -- mod model name -> true once logged as not installed
local probed = false

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end

local function active()
  return config ~= nil and config.enabled and mp.isMPSession() and careerActive()
end

-- The model's own "Type" in the game's model list ("Car", "Truck", ...), cached.
local function typeOfModel(model)
  if typeCache[model] ~= nil then return typeCache[model] or nil end
  local found = false
  if core_vehicles and core_vehicles.getModelList then
    local ok, list = pcall(core_vehicles.getModelList)
    local models = ok and type(list) == "table" and list.models or nil
    local info = models and (models[model] or models[string.lower(tostring(model))]) or nil
    if type(info) == "table" then
      local t = info.Type or info.type
      if type(t) == "string" and t ~= "" then found = t end
    end
  end
  typeCache[model] = found
  return found or nil
end

-- Same readings as RLS's own filter (trafficConfigFilter.lua), so we treat the same groups as police / parked.
local function isPoliceIntent(params)
  local f = type(params) == "table" and params.filters and params.filters["Config Type"]
  if type(f) ~= "table" then return false end
  local weight = tonumber(f.police) or tonumber(f.Police) or 0
  if weight <= 0 then return false end
  return f.other == nil or tonumber(f.other) == 0
end

local function isParkedIntent(params)
  local f = type(params) == "table" and params.filters and params.filters.Type
  if type(f) ~= "table" then return false end
  local parked = 0
  for name, weight in pairs(f) do
    if string.lower(tostring(name)) == "propparked" then parked = tonumber(weight) or 0
    elseif (tonumber(weight) or 0) > 0 then return false end
  end
  return parked > 0
end

-- Day or night, and the class of the road the player is on (from the road's speed limit; nil when the game has none).
local function context()
  local ctx = {night = false}
  if core_environment and core_environment.getLightState then
    local ok, state = pcall(core_environment.getLightState)
    if ok and type(state) == "table" then ctx.night = state.isNight == true end
  end
  local source = "none"
  if map and map.findClosestRoad and map.getMap and getPlayerVehicle then
    local veh = getPlayerVehicle(0)
    if veh then
      local ok, n1 = pcall(map.findClosestRoad, veh:getPosition())
      local nodes = ok and n1 and map.getMap().nodes
      local node = nodes and nodes[n1]
      if node and tonumber(node.speedLimit) then
        ctx.zone = V.zoneFromSpeed(node.speedLimit, config)
        source = "speedLimit"
      end
    end
  end
  ctx.zoneSource = source
  return ctx
end

-- Eligible configs of the server's mod models that are installed on THIS game. Needs RLS's own config filter (same rules).
local function modCandidates(params)
  local out = {}
  if next(config.mods) == nil then return out end
  local filter = rawget(_G, "overhaul_integration_patches_trafficConfigFilter")
  if not (filter and filter.isConfigEligible) then
    p3.logOnChange("variety-nofilter", true, "W", "RLS's traffic config filter is not available: modded cars are skipped")
    return out
  end
  for name, weight in pairs(config.mods) do
    if weight > 0 then
      local ok, data = pcall(core_vehicles and core_vehicles.getModel or function() return nil end, name)
      if ok and type(data) == "table" and type(data.configs) == "table" then
        local names = {}
        for cfg in pairs(data.configs) do names[#names + 1] = cfg end
        table.sort(names)
        for i = #names, 2, -1 do local j = math.random(i) names[i], names[j] = names[j], names[i] end
        local taken = 0
        for _, cfg in ipairs(names) do
          if taken >= MOD_CONFIGS_PER_MODEL then break end
          local eligible = filter.isConfigEligible(name, cfg, params)
          if eligible then out[#out + 1] = {model = name, config = cfg} taken = taken + 1 end
        end
      elseif not missingMods[name] then
        missingMods[name] = true
        p3.log("W", string.format("mod model %s is not installed here (or has no configs): skipped", name))
      end
    end
  end
  return out
end

local function probe(params, pool, group)
  if probed then return end
  probed = true
  local keys = {}
  for k in pairs(type(params) == "table" and params.filters or {}) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local first = pool[1] or {}
  local fields = {}
  for k in pairs(first) do fields[#fields + 1] = tostring(k) end
  table.sort(fields)
  local types = {}
  for _, e in ipairs(pool) do local t = typeOfModel(e.model) or "?" types[t] = (types[t] or 0) + 1 end
  local census = {}
  for t, n in pairs(types) do census[#census + 1] = t .. "=" .. n end
  table.sort(census)
  p3.log("I", "probe: group filters = " .. table.concat(keys, ",") .. "; first entry fields = " .. table.concat(fields, ",")
    .. "; model Types in the pool = " .. table.concat(census, ","))
end

-- Builds the new group, or returns nil to let the game keep its own.
local function build(original, amount, params)
  local parked = isParkedIntent(params)
  if parked and not config.applyToParked then return nil end
  if not parked and not config.applyToTraffic then return nil end
  local want = math.floor(amount)
  local size = math.min(config.maxCandidates, math.max(want, math.ceil(want * config.oversample)))
  local pool = original(size, params)
  if type(pool) ~= "table" or #pool == 0 then return nil end
  local candidates = {}
  for _, e in ipairs(pool) do candidates[#candidates + 1] = e end
  local mods = modCandidates(params)
  for _, e in ipairs(mods) do candidates[#candidates + 1] = e end
  local ctx = context()
  local function infoOf(e) return {type = typeOfModel(e.model), mod = config.mods[e.model] ~= nil} end
  local group, relaxed = V.select(candidates, want, infoOf, ctx, config)
  if #group == 0 then return nil end
  probe(params, pool, group)
  p3.logOnChange("variety-zone", ctx.zoneSource, "I", "probe: road class source = " .. ctx.zoneSource)
  p3.count(parked and "variety groups (parked)" or "variety groups (traffic)")
  p3.log("I", string.format("variety %s group: want=%d pool=%d mods=%d picked=%d distinct models=%d relaxed=%d zone=%s night=%s",
    parked and "parked" or "traffic", want, #pool, #mods, #group, V.distinctModels(group), relaxed, tostring(ctx.zone), tostring(ctx.night)))
  return group
end

-- Wraps core_multiSpawn.createGroup once; safe to call every frame (no re-wrap while our wrapper is still part of the chain).
function M.install()
  if not (core_multiSpawn and type(core_multiSpawn.createGroup) == "function") then return false end
  local ok, wl = pcall(require, "overhaul/lib/shell/wrapperLifetime")
  if not (ok and type(wl) == "table" and wl.registerForwarder and wl.intact) then
    p3.logOnChange("variety-nowl", true, "W", "RLS's wrapperLifetime is not available: traffic variety stays inactive")
    return false
  end
  if ours and installedOn == core_multiSpawn
      and wl.intact({target = core_multiSpawn, key = "createGroup", replacement = ours}) then return true end
  local original = core_multiSpawn.createGroup
  local function wrapper(amount, params)
    if not active() or isPoliceIntent(params) or tonumber(amount) == nil or amount < 1 then
      return original(amount, params)
    end
    local ok2, result = pcall(build, original, amount, params)
    if ok2 and type(result) == "table" and #result > 0 then return result end
    if not ok2 then p3.log("W", "variety failed, the game's own group is used: " .. tostring(result)) end
    return original(amount, params)
  end
  wl.registerForwarder(wrapper, original)
  ours, installedOn = wrapper, core_multiSpawn
  core_multiSpawn.createGroup = wrapper
  p3.log("I", "wrapped core_multiSpawn.createGroup (variety)")
  return true
end

local function onConfig(data)
  config = V.sanitize(data)
  local mods = 0
  for _ in pairs(config.mods) do mods = mods + 1 end
  p3.log("I", string.format("traffic variety settings received: enabled=%s mods=%d maxShare=%.2f oversample=%.1f traffic=%s parked=%s",
    tostring(config.enabled), mods, config.maxShare, config.oversample, tostring(config.applyToTraffic), tostring(config.applyToParked)))
end

function M.onUpdate() M.install() end

function M.onServerLeave()
  config, typeCache, missingMods, probed = nil, {}, {}, false
end

function M.getConfig() return config end
function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpTrafficVariety", onConfig)
  M.install()
  p3.log("I", "rlsmp_trafficVariety loaded")
end

M._onConfig = onConfig
M._build = build
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
