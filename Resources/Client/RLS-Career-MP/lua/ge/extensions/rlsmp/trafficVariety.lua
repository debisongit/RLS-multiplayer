-- RLS-Career-MP client extension "rlsmp_trafficVariety": more varied traffic and parked cars (models and configs).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS/the game builds a traffic (or parked) group with core_multiSpawn.createGroup(amount, params). We wrap it: ask for a
-- bigger pool of candidates, add models from server-shipped mods (names + weights from the server), and pick the group with the
-- weights of lib/trafficVariety.lua (per model Type, per road class, day or night, per mod).
-- Police groups get their own re-pick (config `police`: Bastion weight low, undercover share cap, max share per model), see buildPolice.
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
local PL = require("rlsmp/lib/trafficPreload")
local SM = require("rlsmp/lib/simplified")
local T = require("rlsmp/lib/theft")
local F = require("rlsmp/lib/trafficFill")
local FO = require("rlsmp/lib/trafficFocus")

local MOD_CONFIGS_PER_MODEL = 4   -- how many eligible configs of a modded model join the candidate pool

local config            -- sanitized settings from the server; nil until it speaks
local hooks = {createGroup = {}, fitGroup = {}}   -- per wrapped function: ours (our wrapper), on (the table it lives on), layer (state of our newest wrapper;
                                                  -- older layers kept in the chain by RLS's wrappers become plain passthroughs)
local policeCache       -- police pool: list of {model, config}; policeKeys: "model/config" -> true
local policeKeys = {}
local building = 0      -- > 0 while a group is being built: any other layer of ours that is called meanwhile just passes through
local wl                -- RLS's wrapperLifetime once it could be loaded
local tries = 0         -- install() calls, so a failed require is only retried now and then
local typeCache = {}    -- model name -> Type string or false
local missingMods = {}  -- mod model name -> true once logged as not installed
local probed = false
local recent, recentSeen = {}, {}   -- cars the game offered for traffic groups recently (RLS-approved), for live swapping
local RECENT_MAX = 120
local mem = V.newPool()      -- round-robin memory: which models were used lately (groups and re-rolls share it)
local brandCache = {}       -- model name -> Brand string or false
local premadeList           -- the premade pool: list of {model, config, pop}; nil until built
local parkedList            -- the same for PARKED cars (RLS's parked filter, more configs per model); nil until built
local memParked = V.newPool()   -- round-robin memory of the parked groups
local standCache            -- simple_traffic stand-in map (lib/simplified buildMap), false when there is none
local premadeJob            -- the build in progress: {models, i, out, params, filter}
local clock = 0
local focus = FO.newState()   -- the few configs traffic uses for now (lib/trafficFocus.lua)
local warm = {}             -- models whose meshes are probably loaded (on the street now, or built this session)

local showParkedLook, parkedFull   -- defined below
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end

-- The server's settings can arrive AFTER RLS built its first traffic group (seen in a real log: settings at 57.5 s, group built just before).
-- Cars keep their model on respawn, so a missed first group means the same few cars for the whole session. Until the server speaks we use
-- the built-in defaults (same as the server's defaults); the server's real settings replace them as soon as they arrive.
local provisional = false
local function active()
  if not (mp.isMPSession() and careerActive()) then return false end
  if config == nil then
    config = V.sanitize({})
    provisional = true
    p3.log("I", "traffic variety: server settings not here yet, using the defaults for now")
  end
  return config.enabled
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

-- The model's Brand from the model list, cached (nil when unknown: the per-brand cap then ignores the model).
local function brandOfModel(model)
  if brandCache[model] ~= nil then return brandCache[model] or nil end
  local found = false
  if core_vehicles and core_vehicles.getModelList then
    local ok, list = pcall(core_vehicles.getModelList)
    local models = ok and type(list) == "table" and list.models or nil
    local info = models and (models[model] or models[string.lower(tostring(model))]) or nil
    local b = type(info) == "table" and (info.Brand or info.brand) or nil
    if type(b) == "string" and b ~= "" then found = b end
  end
  brandCache[model] = found
  return found or nil
end

-- Can this model be spawned at all? A model folder with no .jbeam files (a leftover of a deleted mod: seen in a real log as G30_Domestic) makes the
-- game's spawn fail ("missing stage 1 data") and BeamMP then throws a FATAL LUA ERROR. Checked once per model; when the game's file system cannot be
-- asked, every model counts as fine.
local spawnableCache = {}
local function spawnable(model)
  if type(model) ~= "string" then return false end
  local known = spawnableCache[model]
  if known ~= nil then return known end
  local fs = rawget(_G, "FS")
  local ok = true
  if fs and fs.findFiles then
    local good, list = pcall(fs.findFiles, fs, "/vehicles/" .. model .. "/", "*.jbeam", -1, false, false)
    if good and type(list) == "table" and #list == 0 then ok = false end
  end
  spawnableCache[model] = ok
  if not ok then p3.log("W", "variety: " .. model .. " has no .jbeam files in /vehicles/" .. model .. "/ (a broken or removed mod car): never put in a group") end
  return ok
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
  p3.logOnChange("variety-context", tostring(ctx.zone) .. "/" .. tostring(ctx.night), "I",
    string.format("variety context: zone=%s night=%s (road class from %s)", tostring(ctx.zone), tostring(ctx.night), source))
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

-- Remembers the (already RLS-filtered) entries of a traffic group, so live swapping can pick from cars the game really offers.
local function remember(list)
  for _, e in ipairs(list) do
    if type(e) == "table" and e.model then
      local key = tostring(e.model) .. "/" .. tostring(e.config)
      if not recentSeen[key] then
        recentSeen[key] = true
        recent[#recent + 1] = {model = e.model, config = e.config}
        if #recent > RECENT_MAX then
          local old = table.remove(recent, 1)
          recentSeen[tostring(old.model) .. "/" .. tostring(old.config)] = nil
        end
      end
    end
  end
end

-- How many traffic cars the server wants (traffic.minAmount, known from our settings even before the quota; the quota caps it once it is here), 0 = no wish.
local function wish()
  local m = config and config.minAmount or 0
  if m < 1 then return 0 end
  local t = rawget(_G, "rlsmp_traffic") or package.loaded["rlsmp/traffic"]
  local q = t and t.getQuota and t.getQuota()
  return q and F.want(q, m) or m
end

local function trafficCars()
  local n = 0
  for _ in pairs(gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}) do n = n + 1 end
  return n
end

-- The stand-in map of the model simple_traffic (lib/simplified buildMap), nil when the game has none.
local function standMap()
  if standCache ~= nil then return standCache or nil end
  standCache = false
  local ok, data = pcall(core_vehicles and core_vehicles.getModel or function() return nil end, SM.MODEL)
  if ok and type(data) == "table" and type(data.configs) == "table" then
    local names = {}
    for name in pairs(data.configs) do names[#names + 1] = name end
    table.sort(names)
    standCache = SM.buildMap(names, nil)
  end
  return standCache or nil
end

-- A share (parked.simplifiedShare) of the picked full cars is shown as the cheap stand-in of the same model and body style; the pick is remembered
-- (lib/theft noteIntended) so a stolen car is exactly the picked config. Returns the group to spawn.
showParkedLook = function(group)
  local sm = standMap()
  local grp, intended = V.proxyParked(group, function(e) return sm and SM.pickSimpleFor(sm, e.model, e.config) or nil end, config.parked.simplifiedShare)
  for _, it in ipairs(intended) do
    T.noteIntended(it.stand, it.model, it.config, os.time())
    p3.log("I", string.format("theft config: parked pick %s/%s is shown as stand-in %s (remembered, how=map)", it.model, tostring(it.config), it.stand))
  end
  p3.log("I", string.format("parked: %d of %d picks shown as stand-ins (simplifiedShare %.2f), the rest are full cars", #intended, #grp, config.parked.simplifiedShare))
  return grp
end

-- Builds the new group, or returns nil to let the game keep its own.
local function build(original, amount, params)
  local parked = isParkedIntent(params)
  if parked and not config.applyToParked then return nil end
  if not parked and not config.applyToTraffic then return nil end
  local want = math.floor(amount)
  if not parked then
    -- the game's setup group is as big as the player's own amount (a real log: 4), and setActiveAmount cannot add cars later: ask for the server's minimum now
    local bigger = F.groupSize(want, wish(), trafficCars())
    if bigger > want then
      p3.log("I", string.format("fill: the game asked for a traffic group of %d, the server wants %d cars: group size raised", want, bigger))
      want = bigger
    end
  end
  local size = math.min(config.maxCandidates, math.max(want, math.ceil(want * config.oversample)))
  local pool = original(size, params)
  if type(pool) ~= "table" or #pool == 0 then return nil end
  local candidates = {}
  for _, e in ipairs(pool) do
    if spawnable(e.model) then candidates[#candidates + 1] = e end
  end
  local mods = modCandidates(params)
  for _, e in ipairs(mods) do candidates[#candidates + 1] = e end
  -- Parked cars can be EVERY model and config (full cars), also those with no stand-in. The game's own parked offer is only stand-ins, and a stand-in cannot be
  -- traced to ONE real config, so with the full pool the stand-ins come back only as a look of a full pick (below), with that pick remembered.
  local usedFull = false
  if parked and config.parked.fullPool then
    local list = parkedFull()
    if list and #list > 0 then
      local keep = {}
      for _, e in ipairs(candidates) do if e.model ~= SM.MODEL then keep[#keep + 1] = e end end
      for _, e in ipairs(list) do keep[#keep + 1] = e end
      candidates, usedFull = keep, true
    else
      p3.log("W", "parked: the full parked pool is not ready (or empty): the game's own offer is used this time")
    end
  end
  if parked and not usedFull and config.simplified.enabled and config.simplified.parked then
    -- the cheap stand-ins only (when the game offered enough of them): real parked cars come later, one by one, where a player can steal them
    local only, n = SM.preferSimple(candidates, want)
    p3.log("I", string.format("simplified: parked group offered %d stand-ins of %d entries (%s)", n, #candidates, only ~= candidates and "stand-ins only" or "list kept"))
    candidates = only
  end
  local ctx = context()
  local function infoOf(e) return {type = typeOfModel(e.model), mod = config.mods[e.model] ~= nil, brand = brandOfModel(e.model)} end
  if not parked then remember(candidates) end
  local usePool = config.pool.enabled and not parked
  if usePool then
    -- the premade pool: one entry list of every model the game could use, so a group is not limited to what the game offered this time
    for _, e in ipairs(premadeList or {}) do candidates[#candidates + 1] = e end
  end
  local group, relaxed = V.select(candidates, want, infoOf, ctx, config, nil, usedFull and memParked or (usePool and mem or nil))
  if #group == 0 then return nil end
  if usedFull then group = showParkedLook(group) end
  if not parked and config.focus.enabled then
    -- the same few configs for a while: choose them (normal weights) when none are set or their time is over, then every car of the group is one of them
    if FO.due(focus, config.focus, clock) then
      local chosen = V.select(candidates, math.max(6, config.focus.configs * 3), infoOf, ctx, config, nil, usePool and mem or nil)
      if FO.set(focus, config.focus, chosen, clock) then
        local names = {}
        for _, e in ipairs(focus.entries) do names[#names + 1] = FO.key(e) end
        p3.log("I", string.format("focus: traffic uses %s for the next %.0f minutes (choice number %d)", table.concat(names, " and "), config.focus.minutes, focus.rotations))
      end
    end
    local entries = FO.current(focus, config.focus)
    if entries then group = FO.group(entries, #group, math.random) relaxed = 0 p3.count("focus groups") end
  end
  probe(params, pool, group)
  p3.logOnChange("variety-zone", ctx.zoneSource, "I", "probe: road class source = " .. ctx.zoneSource)
  p3.count(parked and "variety groups (parked)" or "variety groups (traffic)")
  local names = {}
  for _, e in ipairs(group) do names[#names + 1] = tostring(e.model) .. "/" .. tostring(e.config) warm[e.model] = true end
  p3.log("I", string.format("variety %s group: want=%d pool=%d mods=%d premade=%d picked=%d distinct models=%d relaxed=%d zone=%s night=%s cars=%s",
    parked and "parked" or "traffic", want, #pool, #mods, usePool and #(premadeList or {}) or 0, #group, V.distinctModels(group), relaxed,
    tostring(ctx.zone), tostring(ctx.night), table.concat(names, ",")))
  return group
end

-- Every police config the game knows (Config Type "Police"), that can be spawned and passes RLS's own filter. Built once (cached).
-- RLS's career police normally come from the level's police.vehGroup.json (autoLoadFromFile) and then core_multiSpawn.fitGroup, NOT from createGroup,
-- and that file lists only Bastions; so we build the pool from the game's model list.
local POLICE_PARAMS = {filters = {["Config Type"] = {police = 1, other = 0}}}
local function policePool()
  if policeCache then return policeCache end
  local out, keys, models = {}, {}, {}
  local filter = rawget(_G, "overhaul_integration_patches_trafficConfigFilter")
  local ok, list = pcall(core_vehicles.getModelList)
  for name in pairs(ok and type(list) == "table" and type(list.models) == "table" and list.models or {}) do models[#models + 1] = name end
  table.sort(models)
  for _, name in ipairs(models) do
    local good, data = pcall(core_vehicles.getModel, name)
    if good and type(data) == "table" and type(data.configs) == "table" then
      local names = {}
      for cfg, info in pairs(data.configs) do
        local t = type(info) == "table" and (info["Config Type"] or info.configType)
        if type(t) == "string" and string.lower(t) == "police" then names[#names + 1] = cfg end
      end
      table.sort(names)
      for _, cfg in ipairs(names) do
        local eligible = true
        if filter and filter.isConfigEligible then
          local g, e = pcall(filter.isConfigEligible, name, cfg, POLICE_PARAMS)
          eligible = not g or e ~= false
        end
        if eligible and spawnable(name) then out[#out + 1] = {model = name, config = cfg} keys[name .. "/" .. cfg] = true end
      end
    end
  end
  local census, per = {}, {}
  for _, e in ipairs(out) do
    per[e.model] = (per[e.model] or 0) + 1
    if V.isUndercover(e.config, config.police.undercoverWords) then per[e.model .. " (undercover)"] = (per[e.model .. " (undercover)"] or 0) + 1 end
  end
  for k, n in pairs(per) do census[#census + 1] = k .. "=" .. n end
  table.sort(census)
  p3.log("I", string.format("police pool: %d configs: %s", #out, table.concat(census, ", ")))
  policeCache, policeKeys = out, keys
  return out
end

-- Is every entry of this list a police config? (the file group RLS hands to fitGroup)
local function allPolice(group)
  if type(group) ~= "table" or #group == 0 then return false end
  policePool()
  for _, e in ipairs(group) do
    if type(e) ~= "table" or not policeKeys[tostring(e.model) .. "/" .. tostring(e.config)] then return false end
  end
  return true
end

-- A police group of `amount` cars picked with the police settings, or nil to let the game keep its own.
local function buildPolice(amount)
  local pool = policePool()
  if #pool == 0 then return nil end
  local want = math.floor(amount)
  local group, relaxed = V.selectPolice(pool, want, config.police)
  if #group == 0 then return nil end
  local picked, undercover = {}, 0
  for _, e in ipairs(group) do
    picked[#picked + 1] = e.model .. "/" .. e.config
    if V.isUndercover(e.config, config.police.undercoverWords) then undercover = undercover + 1 end
  end
  p3.count("variety groups (police)")
  p3.log("I", string.format("variety police group: want=%d pool=%d undercover=%d relaxed=%d cars=%s", want, #pool, undercover, relaxed, table.concat(picked, ",")))
  return group
end

-- One police car entry {model, config} of a model other than `avoidModel` (the police settings apply: Bastion weight, undercover cap), or nil.
-- Used by rlsmp_policeRespawn when a cop is re-placed and comes back behind the player.
function M.policePick(avoidModel)
  if not (config and config.enabled and config.police and config.police.enabled) then return nil end
  local pool = policePool()
  if #pool == 0 then return nil end
  local fallback
  for _ = 1, 6 do
    local group = V.selectPolice(pool, 1, config.police)
    local e = group and group[1]
    if e then
      fallback = fallback or e
      if e.model ~= avoidModel then return {model = e.model, config = e.config} end
    end
  end
  return fallback and {model = fallback.model, config = fallback.config} or nil   -- the pool has only that model: better the same than none
end

-- The premade pool: a few eligible configs of EVERY model the game could use as traffic, built once per session, a few models per frame.
-- Same rules as the game's own groups: model Types from gameplay_traffic_trafficUtils.getBaseGroupParams() (when it lists any), RLS's
-- trafficConfigFilter.isConfigEligible for every config. Gives groups and re-rolls more than the 5 to 15 cars the game offered last time.
local PREMADE_MODELS_PER_FRAME = 3
local BLOCKED_TYPES = {prop = true, propparked = true, proptraffic = true, trailer = true, unicycle = true}   -- used when the game lists no Types
local BLOCKED_MODELS = {simple_traffic = true, unicycle = true}
local PARKED_PARAMS = {filters = {Type = {propparked = 1}}}   -- the parked intent of RLS's trafficConfigFilter (its parked pool rules)

local function startPremade()
  if premadeList or premadeJob then return end
  if not (core_vehicles and core_vehicles.getModelList and core_vehicles.getModel) then return end
  local filter = rawget(_G, "overhaul_integration_patches_trafficConfigFilter")
  if not (filter and filter.isConfigEligible) then
    p3.logOnChange("variety-nofilter-pool", true, "W", "RLS's traffic config filter is not available yet: no premade pool for now")
    return
  end
  local utils = rawget(_G, "gameplay_traffic_trafficUtils")
  local params
  if utils and utils.getBaseGroupParams then
    local ok, p = pcall(utils.getBaseGroupParams)
    if ok and type(p) == "table" then params = p end
  end
  params = params or {filters = {}}
  local allowed, any, shown = {}, false, {}
  local typeFilter = type(params.filters) == "table" and params.filters.Type
  if type(typeFilter) == "table" then
    for name, w in pairs(typeFilter) do
      if (tonumber(w) or 0) > 0 then allowed[string.lower(tostring(name))] = true any = true shown[#shown + 1] = tostring(name) end
    end
  end
  table.sort(shown)
  local ok, list = pcall(core_vehicles.getModelList)
  local names = {}
  for name, info in pairs(ok and type(list) == "table" and type(list.models) == "table" and list.models or {}) do
    local t = type(info) == "table" and (info.Type or info.type) or nil
    local tl = type(t) == "string" and string.lower(t) or nil
    local good = tl ~= nil and (any and allowed[tl] or (not any and not BLOCKED_TYPES[tl]))
    if good and not BLOCKED_MODELS[name] then names[#names + 1] = name end
  end
  table.sort(names)
  premadeJob = {models = names, i = 1, out = {}, outP = {}, params = params, filter = filter}
  p3.log("I", string.format("premade pool: building from %d models (Types from the game: %s)", #names, any and table.concat(shown, ",") or "none, using the built-in block list"))
end

local function stepPremade()
  local j = premadeJob
  if not j then return end
  local perModel = (config or V.DEFAULTS).pool.configsPerModel
  local perModelP = math.min(20, perModel * 2)      -- parked: more configs of each model
  local words = (config or V.DEFAULTS).excludeWords
  for _ = 1, PREMADE_MODELS_PER_FRAME do
    local name = j.models[j.i]
    if not name then
      premadeList, parkedList, premadeJob = j.out, j.outP, nil
      p3.log("I", string.format("parked pool: %d configs (RLS's parked filter, no police or taxi, junk words excluded)", #j.outP))
      local models, brands, bn = {}, {}, 0
      for _, e in ipairs(j.out) do
        models[e.model] = true
        local b = brandOfModel(e.model) or e.model
        if not brands[b] then brands[b] = true bn = bn + 1 end
      end
      local mn = 0
      for _ in pairs(models) do mn = mn + 1 end
      p3.log(#j.out > 0 and "I" or "W", string.format("premade pool: %d configs of %d models, %d brands", #j.out, mn, bn))
      return
    end
    j.i = j.i + 1
    if spawnable(name) then
      local ok, data = pcall(core_vehicles.getModel, name)
      if ok and type(data) == "table" and type(data.configs) == "table" then
        local cfgs = {}
        for c in pairs(data.configs) do cfgs[#cfgs + 1] = c end
        table.sort(cfgs)
        for a = #cfgs, 2, -1 do local b = math.random(a) cfgs[a], cfgs[b] = cfgs[b], cfgs[a] end
        local taken, takenP = 0, 0
        for _, c in ipairs(cfgs) do
          if taken >= perModel and takenP >= perModelP then break end
          local info = data.configs[c]
          local known = type(info) == "table"
          local e = {model = name, config = c, pop = known and tonumber(info.Population) or nil,
            ctype = known and type(info["Config Type"]) == "string" and info["Config Type"] or nil, value = known and tonumber(info.Value) or nil}
          if known and (info.isDrivable == false or info.drivable == false) then e.drivable = false end
          if V.isExcluded(e, words) then
            p3.count("variety: junk config skipped")
          else
            if taken < perModel then
              local good, eligible = pcall(j.filter.isConfigEligible, name, c, j.params)
              if good and eligible then j.out[#j.out + 1] = e taken = taken + 1 end
            end
            if takenP < perModelP and #V.dropBlocked({e}) == 1 then
              local good, eligible = pcall(j.filter.isConfigEligible, name, c, PARKED_PARAMS)
              if good and eligible then j.outP[#j.outP + 1] = e takenP = takenP + 1 end
            end
          end
        end
      end
    end
  end
end

-- The parked pool, built to the end right now when it is not there yet (a one-time cost, the parked group needs it before the first car is spawned).
parkedFull = function()
  if parkedList then return parkedList end
  if not premadeJob then startPremade() end
  local guard = 0
  while premadeJob and guard < 3000 do stepPremade() guard = guard + 1 end
  return parkedList
end

-- RLS's wrapperLifetime, loaded once. A failed require is not cached by Lua, so it is only retried every 60th call (~1 s).
local function lifetime()
  if wl then return wl end
  tries = tries + 1
  if tries % 60 ~= 1 then return nil end
  local ok, mod = pcall(require, "overhaul/lib/shell/wrapperLifetime")
  if ok and type(mod) == "table" and mod.registerForwarder and mod.intact then wl = mod return wl end
  p3.logOnChange("variety-nowl", true, "W", "RLS's wrapperLifetime is not available: traffic variety stays inactive")
  return nil
end

-- Wraps core_multiSpawn.createGroup and fitGroup; safe to call every frame (nothing happens while our wrapper is still part of the chain).
-- RLS's own wrapper is not registered as a forwarder of what it wraps, so when RLS wraps OVER us we are no longer "intact" and wrap
-- again. The older layer then stays in the chain but is switched off (a plain passthrough), so only one layer ever builds a group.
local function hook(key, lib, make)
  local slot, target = hooks[key], core_multiSpawn
  if type(target[key]) ~= "function" then return end
  if slot.ours and slot.on == target and lib.intact({target = target, key = key, replacement = slot.ours}) then return end
  local original = target[key]
  if slot.layer then
    slot.layer.active = false
    p3.count("rewrapped " .. key)
    p3.log("W", "rewrapped " .. key .. " (RLS or the game replaced it after we wrapped); the older layer is now a passthrough")
  end
  local mine = {active = true}
  slot.layer = mine
  local wrapper = make(mine, original)
  lib.registerForwarder(wrapper, original)
  slot.ours, slot.on = wrapper, target
  target[key] = wrapper
  p3.log("I", "wrapped core_multiSpawn." .. key .. " (variety)")
end

-- The game's own group (used when ours failed or found nothing) may hold a junk car: swap each for a pool pick, or drop it.
local function cleanOwn(group)
  if type(group) ~= "table" or not config then return group end
  local words = config.excludeWords
  local out, changed = {}, 0
  for _, e in ipairs(group) do
    if V.isExcluded(e, words) or M.isBannedModel(e.model) then
      changed = changed + 1
      local ok, pick = pcall(M.pickReplacement, e, nil)
      if ok and pick and pick.model then out[#out + 1] = {model = pick.model, config = pick.config} end
    else
      out[#out + 1] = e
    end
  end
  if changed == 0 then return group end
  p3.count("variety: junk car replaced in the game's own group")
  p3.log("I", string.format("variety: %d junk car(s) in the game's own group re-picked (%d entries left)", changed, #out))
  return out
end

local function makeCreateGroup(mine, original)
  return function(amount, params)
    if not mine.active or building > 0 or not active() or tonumber(amount) == nil or amount < 1 then
      return original(amount, params)
    end
    local police = isPoliceIntent(params)
    if police and not config.police.enabled then return original(amount, params) end
    building = building + 1
    local ok2, result = pcall(function()
      if police then return buildPolice(amount) end
      return build(original, amount, params)
    end)
    building = building - 1
    if ok2 and type(result) == "table" and #result > 0 then return result end
    if not ok2 then p3.log("W", "variety failed, the game's own group is used: " .. tostring(result)) end
    local own = original(amount, params)
    if police then return own end
    return cleanOwn(own)
  end
end

-- The file group of the level's police (all Bastions on the west coast) goes through fitGroup(group, count): we replace it by a re-picked group.
local function makeFitGroup(mine, original)
  return function(group, count, ...)
    if mine.active and building == 0 and tonumber(count) ~= nil and count >= 1 and active() and config.police.enabled then
      building = building + 1
      local ok2, result = pcall(function() return allPolice(group) and buildPolice(count) or nil end)
      building = building - 1
      if ok2 and type(result) == "table" and #result > 0 then return result end
      if not ok2 then p3.log("W", "variety (police file group) failed, the game's own group is used: " .. tostring(result)) end
    end
    return original(group, count, ...)
  end
end

function M.install()
  if not (core_multiSpawn and type(core_multiSpawn.createGroup) == "function") then return false end
  local lib = lifetime()
  if not lib then return false end
  hook("createGroup", lib, makeCreateGroup)
  hook("fitGroup", lib, makeFitGroup)
  return true
end

local function onConfig(data)
  config = V.sanitize(data)
  provisional = false
  local mods = 0
  for _ in pairs(config.mods) do mods = mods + 1 end
  p3.log("I", string.format("traffic variety settings received: enabled=%s mods=%d maxShare=%.2f oversample=%.1f traffic=%s parked=%s",
    tostring(config.enabled), mods, config.maxShare, config.oversample, tostring(config.applyToTraffic), tostring(config.applyToParked)))
  p3.log("I", string.format("police variety: enabled=%s undercoverShare=%.2f maxShare=%.2f", tostring(config.police.enabled), config.police.undercoverShare, config.police.maxShare))
end

-- The focus time is over: choose the next configs from the premade pool (or what the game offered lately) with the normal weights.
local lastFocusTry = -math.huge
local function rotateFocus()
  if clock - lastFocusTry < 5 then return end
  lastFocusTry = clock
  local list = {}
  for _, e in ipairs(premadeList or {}) do list[#list + 1] = e end
  if #list == 0 then for _, e in ipairs(recent) do list[#list + 1] = e end end
  if #list == 0 then return end
  list = V.dropExcluded(list, config.excludeWords)
  local ok, chosen = pcall(V.select, list, math.max(6, config.focus.configs * 3), M.infoOf, context(), config, nil, mem)
  if not ok or type(chosen) ~= "table" then return end
  if FO.set(focus, config.focus, chosen, clock) then
    local names = {}
    for _, e in ipairs(focus.entries) do names[#names + 1] = FO.key(e) end
    p3.log("I", string.format("focus: traffic uses %s for the next %.0f minutes (choice number %d)", table.concat(names, " and "), config.focus.minutes, focus.rotations))
  end
end

function M.onUpdate(dtReal)
  M.install()
  clock = clock + (dtReal or 0)
  if config and config.enabled and config.focus and config.focus.enabled and focus.entries and FO.due(focus, config.focus, clock) and mp.isMPSession() and careerActive() then
    rotateFocus()
  end
  if not premadeList and mp.isMPSession() and careerActive() and (config == nil or config.pool.enabled or config.parked.fullPool) then
    startPremade()
    stepPremade()
  end
end

function M.onServerLeave()
  config, provisional, typeCache, missingMods, probed = nil, false, {}, {}, false
  policeCache, policeKeys = nil, {}
  recent, recentSeen = {}, {}
  mem, brandCache, premadeList, premadeJob, warm = V.newPool(), {}, nil, nil, {}
  parkedList, memParked, standCache = nil, V.newPool(), nil
  T.clearIntended()
  focus = FO.newState()
end

function M.getConfig() return config end
-- For live swapping (rlsmp_trafficSwap): the entries seen recently, the current day/night and road class, and a model's Type/mod info.
function M.candidates() local out = {} for i, e in ipairs(recent) do out[i] = e end return V.dropExcluded(out, config and config.excludeWords) end
function M.contextNow() return context() end
function M.infoOf(e) return {type = typeOfModel(e.model), mod = config ~= nil and config.mods[e.model] ~= nil, brand = brandOfModel(e.model)} end
function M.brandOf(model) return brandOfModel(model) end
function M.premadeCount() return premadeList and #premadeList or 0 end
function M.getMemory() return mem end
function M.noteWarm(model) if type(model) == "string" then warm[model] = true end end

-- A model the player set to weight 0 in the menu (see lib V.isBanned).
function M.isBannedModel(model)
  return config ~= nil and V.isBanned(model, typeOfModel(model), config)
end

-- One replacement for a traffic car that is being re-rolled: a different model (different config too) from the premade pool, round robin.
-- current = {model, config}; census = {brand = cars of that brand on the street now}. nil = leave the car alone.
function M.pickReplacement(current, census)
  if not (config and config.enabled and config.pool.enabled) then return nil end
  if config.focus and config.focus.enabled and not FO.due(focus, config.focus, clock) then
    -- a car for the focus configs; none when the old car is one of them already (a rebuild into the same config helps nobody)
    local entries = FO.current(focus, config.focus)
    if entries then
      local e = entries[math.random(#entries)]
      if type(current) == "table" and current.model == e.model and current.config == e.config then return nil end
      p3.count("pool picks (focus)")
      return e, "focus"
    end
  end
  local list = {}
  for _, e in ipairs(premadeList or {}) do list[#list + 1] = e end
  if #list == 0 then for _, e in ipairs(recent) do list[#list + 1] = e end end   -- no premade pool: only what the game offered lately
  local ok, entry, stage
  local pc = config.preload
  if pc and pc.enabled then
    -- warm bias: most picks come from models that are already loaded (cheaper to build); nothing is noted in the memory when it finds nothing
    local preferred = PL.preferWarm(list, warm, pc.warmShare, math.random)
    if preferred ~= list then
      ok, entry, stage = pcall(V.pickOne, mem, preferred, M.infoOf, context(), config, math.random, current, census)
      if ok and entry then p3.count("pool picks (warm model)") end
    end
  end
  if not (ok and entry) then ok, entry, stage = pcall(V.pickOne, mem, list, M.infoOf, context(), config, math.random, current, census) end
  if not ok then p3.log("W", "pickReplacement failed: " .. tostring(entry)) return nil end
  if entry then p3.count("pool picks (stage " .. tostring(stage) .. ")") end
  return entry, stage
end
-- A real (full) car entry of `model` from the premade pool, or nil (rlsmp_simplified upgrades a stand-in with it).
function M.fullEntryFor(model)
  local list = {}
  for _, e in ipairs(premadeList or {}) do if e.model == model and not V.isExcluded(e, config and config.excludeWords) then list[#list + 1] = e end end
  if #list == 0 then return nil end
  return list[math.random(#list)]
end
-- RLS's parking calls this for the group it spawns (vehicle ids, group id, group name "autoParking"): a stand-in that came from one of our picks is
-- bound to the real car we picked (carInfo in rlsmp/theft.lua asks lib/theft intendedFor).
function M.onVehicleGroupSpawned(vehIds, groupId, groupName)
  if type(vehIds) ~= "table" then return end
  for _, id in ipairs(vehIds) do
    local o = be and be.getObjectByID and be:getObjectByID(id)
    local jb = o and (o.jbeam or o.JBeam or (o.getJBeamFilename and o:getJBeamFilename()))
    if jb == SM.MODEL then
      local e = T.bindSpawned(id, T.configKey(o.partConfig), os.time())
      if e then p3.log("I", string.format("theft config: parked stand-in %s (%s) stands for %s/%s (how=map)", tostring(id), tostring(T.configKey(o.partConfig)), e.model, tostring(e.config))) end
    end
  end
end
function M.parkedPoolCount() return parkedList and #parkedList or 0 end
function M.report() return p3.report() end

function M.onExtensionLoaded()
  net.on("rlsmpTrafficVariety", onConfig)
  M.install()
  p3.log("I", "rlsmp_trafficVariety loaded")
end

M._onConfig = onConfig
M._build = build
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("trafficVariety", M)
return M
