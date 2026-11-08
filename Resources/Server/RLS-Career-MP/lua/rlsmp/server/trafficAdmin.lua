-- RLS-Career-MP server: the in-game settings menu (Phase 3): AI traffic, car theft, fence, black market, police, weather.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- EVERY player on the server can open the menu (client rlsmp_trafficMenu: the [ key, or /trafficmenu) and change settings: there is no admin list
-- any more (the owner's decision). What still protects the server is THIS FILE:
--   * what: only settings on the allowlist below, each with a type and a range (anything else, or a value out of range, is rejected);
--   * how often: at most 3 requests per second per player;
--   * how: a change is set INSIDE the existing section tables (the other modules keep references to them), the config.json is saved,
--     the modules are told to resend their settings to everybody, and everybody who has the menu open gets the fresh state;
--   * who: every change is logged with the player's name and account id (log tag RLSMP-ADMIN).
-- Events: rlsmpTrafficAdminGet (C>S), rlsmpTrafficAdminSet {set = {{p = path, v = value}}, rm = {path}} (C>S),
--         rlsmpTrafficAdminState / rlsmpTrafficAdminResult / rlsmpTrafficAdminOpen (S>C). Settings that are read only once at startup
--         (timer intervals, the weather period length) are NOT editable here, because changing them live would do nothing.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local storage = require("rlsmp.server.storage")

local M = {}

local MAX_CHANGES = 64            -- changes per message
local MAX_PER_SECOND = 3          -- messages per second per player
local MAX_KEY = 64

local ZONES = {city = true, main = true, highway = true}
local PERSONALITIES = {"normal", "slow", "aggressive", "racer", "drunk"}
local CONDITIONS = {"clear", "partlyCloudy", "overcast", "drizzle", "rain", "storm"}

-- Rules: static settings by their dotted path. {kind, min, max, int}
local STATIC = {
  ["traffic.enabled"] = {"bool"},
  ["traffic.totalBudget"] = {"number", 0, 500, true},
  ["traffic.baseBudget"] = {"number", 0, 500, true},
  ["traffic.perPlayerBudget"] = {"number", 0, 100, true},
  ["traffic.minPerPlayer"] = {"number", 0, 50, true},
  ["traffic.maxPerPlayer"] = {"number", 1, 100, true},
  ["traffic.respawnRange"] = {"number", 0.5, 3},
  ["traffic.respawnDistance"] = {"number", 0, 6000},
  ["traffic.spawnMinDistance"] = {"number", 120, 3000},
  ["traffic.spawnMaxDistance"] = {"number", 0, 6000},
  ["traffic.respawnDelay"] = {"number", 0, 600},
  ["traffic.unjam.enabled"] = {"bool"},
  ["traffic.unjam.seconds"] = {"number", 30, 1800, true},
  ["traffic.unjam.distance"] = {"number", 150, 5000, true},
  ["traffic.unjam.crashed"] = {"bool"},
  ["traffic.unjam.crashedSeconds"] = {"number", 15, 600, true},
  ["traffic.unjam.inViewSeconds"] = {"number", 30, 1200, true},
  ["smartTraffic.enabled"] = {"bool"},
  ["smartTraffic.policeReact"] = {"bool"},
  ["trafficVariety.enabled"] = {"bool"},
  ["trafficVariety.applyToTraffic"] = {"bool"},
  ["trafficVariety.applyToParked"] = {"bool"},
  ["trafficVariety.maxShare"] = {"number", 0.05, 1},
  ["trafficVariety.oversample"] = {"number", 1, 4},
  ["trafficVariety.maxCandidates"] = {"number", 10, 300, true},
  ["trafficVariety.zoneSpeedLimits.city"] = {"number", 1, 100},
  ["trafficVariety.zoneSpeedLimits.main"] = {"number", 1, 200},
  ["trafficVariety.police.enabled"] = {"bool"},
  ["trafficVariety.police.undercoverShare"] = {"number", 0, 1},
  ["trafficVariety.police.maxShare"] = {"number", 0.05, 1},
  ["trafficVariety.swap.enabled"] = {"bool"},
  ["trafficVariety.swap.live"] = {"bool"},
  ["trafficVariety.swap.perMinute"] = {"number", 0, 12, true},
  ["trafficVariety.swap.hiddenSeconds"] = {"number", 1, 120},
  ["trafficVariety.swap.minRatio"] = {"number", 1, 100},
  ["trafficVariety.swap.maxFailures"] = {"number", 1, 20, true},
  ["trafficVariety.pool.enabled"] = {"bool"},
  ["trafficVariety.pool.avoidLast"] = {"number", 0, 40, true},
  ["trafficVariety.pool.brandWindow"] = {"number", 1, 40, true},
  ["trafficVariety.pool.brandMax"] = {"number", 1, 40, true},
  ["trafficVariety.pool.streetMax"] = {"number", 1, 40, true},
  ["trafficVariety.pool.configsPerModel"] = {"number", 1, 12, true},
  ["trafficVariety.pool.popPower"] = {"number", 0, 1},
  ["trafficVariety.respawn.enabled"] = {"bool"},
  ["trafficVariety.respawn.mode"] = {"enum", values = {async = true, inplace = true, off = true}},
  ["trafficVariety.respawn.perMinute"] = {"number", 0, 12, true},
  ["trafficVariety.respawn.chance"] = {"number", 0, 1},
  ["trafficVariety.respawn.repaintChance"] = {"number", 0, 1},
  ["trafficVariety.respawn.waitSeconds"] = {"number", 0.5, 30},
  ["trafficVariety.parked.amount"] = {"number", 0, 30, true},
  ["trafficVariety.parked.fullPool"] = {"bool"},
  ["trafficVariety.parked.simplifiedShare"] = {"number", 0, 1},
  ["trafficVariety.rarity.enabled"] = {"bool"},
  ["trafficVariety.rarity.common"] = {"number", 0, 1},
  ["trafficVariety.rarity.uncommon"] = {"number", 0, 1},
  ["trafficVariety.rarity.rare"] = {"number", 0, 1},
  ["trafficVariety.rarity.uncommonValue"] = {"number", 0, 100000000, true},
  ["trafficVariety.rarity.rareValue"] = {"number", 0, 100000000, true},
  ["trafficVariety.focus.enabled"] = {"bool"},
  ["trafficVariety.focus.configs"] = {"number", 1, 6, true},
  ["trafficVariety.focus.minutes"] = {"number", 1, 600},
  ["trafficVariety.preload.enabled"] = {"bool"},
  ["trafficVariety.preload.minGapSeconds"] = {"number", 0, 120},
  ["trafficVariety.preload.slowFrameMs"] = {"number", 10, 2000},
  ["trafficVariety.preload.settleSeconds"] = {"number", 0, 60},
  ["trafficVariety.preload.warmShare"] = {"number", 0, 1},
  ["trafficVariety.simplified.enabled"] = {"bool"},
  ["trafficVariety.simplified.parked"] = {"bool"},
  ["trafficVariety.simplified.traffic"] = {"bool"},
  ["trafficVariety.simplified.nearRadius"] = {"number", 120, 1000, true},
  ["trafficVariety.simplified.perMinute"] = {"number", 0, 12, true},
  ["weather.enabled"] = {"bool"},
  ["weather.force"] = {"enum", values = {[""] = true, clear = true, partlyCloudy = true, overcast = true, drizzle = true, rain = true, storm = true}},
  ["police.antiTeleport"] = {"bool"},
  ["police.blockRoadblocks"] = {"bool"},
  ["police.noFineInStolenCar"] = {"bool"},
  ["police.noRadarFineIllegal"] = {"bool"},
  ["police.respawnBehind"] = {"bool"},
  ["police.respawnPerMinute"] = {"number", 0, 30, true},
  ["police.spawnMinDistance"] = {"number", 300, 3000, true},
  ["police.chaseSpawnMinDistance"] = {"number", 200, 3000, true},
  ["police.spawnPreferRight"] = {"bool"},
  ["police.respawnRebuildSeconds"] = {"number", 10, 1800, true},
  ["police.copRespawnDistance"] = {"number", 0, 4000, true},
  ["police.copCount"] = {"number", 0, 4, true},
  ["vehicles.allowPassengers"] = {"bool"},
  ["police.copTopUpSeconds"] = {"number", 5, 600, true},
  ["police.maxCops"] = {"number", 0, 3, true},
  ["police.areaSize"] = {"number", 300, 10000},
  ["police.copTargets.city.day"] = {"number", 0, 3, true},
  ["police.copTargets.city.night"] = {"number", 0, 3, true},
  ["police.copTargets.main.day"] = {"number", 0, 3, true},
  ["police.copTargets.main.night"] = {"number", 0, 3, true},
  ["police.copTargets.highway.day"] = {"number", 0, 3, true},
  ["police.copTargets.highway.night"] = {"number", 0, 3, true},
  ["police.copTargets.other.day"] = {"number", 0, 3, true},
  ["police.copTargets.other.night"] = {"number", 0, 3, true},
  ["police.bubbleMode"] = {"enum", values = {original = true, protect = true, off = true}},
  ["police.enabled"] = {"bool"},
  ["police.plateFlagSeconds"] = {"number", 60, 86400, true},
  ["police.descriptionSeconds"] = {"number", 60, 86400, true},
  ["police.plateReading.enabled"] = {"bool"},
  ["police.plateReading.rangeMeters"] = {"number", 3, 100},
  ["police.plateReading.maxSpeedKmh"] = {"number", 5, 200},
  ["police.plateReading.readChance"] = {"number", 0, 1},
  ["police.plateReading.afterEscapeChance"] = {"number", 0, 1},
  ["police.plateReading.skipChance"] = {"number", 0, 1},
}
STATIC["modPrice.enabled"] = {"bool"}
STATIC["modPrice.sell"] = {"bool"}
STATIC["modPrice.max"] = {"number", 1000, 100000000, true}
STATIC["modPrice.min"] = {"number", 100, 100000, true}
STATIC["modPrice.tolerance"] = {"number", 0, 2}
for _, name in ipairs(PERSONALITIES) do
  STATIC["smartTraffic.mix." .. name] = {"number", 0, 100}
  STATIC["smartTraffic.nightMult." .. name] = {"number", 0, 20}
end
for _, name in ipairs(CONDITIONS) do STATIC["weather.mix." .. name] = {"number", 0, 100} end

-- Car theft, the fence and the black market (all read live by their modules, except what is said in the comments).
local function rules(prefix, list)
  for field, rule in pairs(list) do STATIC[prefix .. field] = rule end
end
rules("theft.", {
  enabled = {"bool"}, perMille = {"number", 0, 1000, true}, periodSeconds = {"number", 60, 86400, true}, radius = {"number", 1, 10},
  retrySeconds = {"number", 0, 300, true}, repriceMinutes = {"number", 1, 1440, true}, maxRepriceStep = {"number", 1, 500, true}, jammerNoiseFactor = {"number", 0, 1},
  baseWitnessChance = {"number", 0, 1}, perWitness = {"number", 0, 1}, noiseWitness = {"number", 0, 1}, maxWitnessChance = {"number", 0, 1},
  witnessCap = {"number", 0, 20, true}, seenReportMin = {"number", 1, 3600, true}, seenReportMax = {"number", 1, 3600, true},
  unseenReportSeconds = {"number", 1, 86400, true}, trackerReportSeconds = {"number", 1, 3600, true}, keepHours = {"number", 1, 720, true},
  ["tiers.immobilizerYear"] = {"number", 1900, 2100, true}, ["tiers.keylessYear"] = {"number", 1900, 2100, true},
  ["tiers.newestYear"] = {"number", 1900, 2100, true}, ["tiers.luxuryValue"] = {"number", 0, 100000000, true},
  ["inspect.enabled"] = {"bool"}, ["inspect.range"] = {"number", 3, 100}, ["inspect.seconds"] = {"number", 1, 30, true},
  ["inspect.cooldown"] = {"number", 0, 60},
})
rules("fence.", {
  enabled = {"bool"}, maxValue = {"number", 0, 100000000, true}, minValue = {"number", 0, 1000000, true},
  stripRate = {"number", 0, 1}, resellRate = {"number", 0, 1}, phone = {"bool"},
  maxSellDamage = {"number", 0, 1}, damageStripPenalty = {"number", 0, 1}, damageFreshSeconds = {"number", 10, 3600, true},
  ["rep.strip"] = {"number", 0, 25, true}, ["rep.sell"] = {"number", 0, 25, true}, ["rep.resell"] = {"number", 0, 25, true},
})
rules("market.", {
  enabled = {"bool"}, bustRep = {"number", 0, 100, true}, bustTakesPapers = {"bool"}, bustTakesTools = {"bool"},
  minDelaySeconds = {"number", 0, 3600, true}, maxDelaySeconds = {"number", 0, 3600, true}, maxOpenOrders = {"number", 1, 10, true},
  pickupRadius = {"number", 5, 200}, rotateMinutes = {"number", 1, 1440, true}, baseInvites = {"number", 0, 20, true},
  repPerInvite = {"number", 1, 100, true}, maxInvites = {"number", 0, 50, true}, fenceCarRate = {"number", 0, 1}, fencePartRate = {"number", 0, 1},
  ["scout.enabled"] = {"bool"}, ["scout.price"] = {"number", 0, 10000000, true}, ["scout.minRep"] = {"number", 0, 100, true},
  ["scout.radius"] = {"number", 50, 2000}, ["scout.seconds"] = {"number", 30, 3600, true}, ["scout.cooldownSeconds"] = {"number", 0, 3600, true},
  ["scout.freeUsesPerHour"] = {"number", 0, 100, true}, ["scout.repCost"] = {"number", 0, 25, true},
})

-- Rules for maps with names chosen by the player (car Types and models): first segments -> rule, last segment is the name.
local DYNAMIC_WEIGHT = {"number", 0, 20}
local DYNAMIC = {
  ["trafficVariety.typeWeights"] = DYNAMIC_WEIGHT,
  ["trafficVariety.models"] = DYNAMIC_WEIGHT,
  ["trafficVariety.mods"] = DYNAMIC_WEIGHT,
  ["trafficVariety.day"] = DYNAMIC_WEIGHT,
  ["trafficVariety.night"] = DYNAMIC_WEIGHT,
  ["trafficVariety.police.models"] = DYNAMIC_WEIGHT,
}

local config, configPath
local seen = {}        -- pid -> {second, count}
local watchers = {}    -- pid -> true once the player asked for the settings (they get the fresh state after a change)

-- Names of Types, models and zones: short, plain characters.
local function goodKey(k)
  return type(k) == "string" and #k >= 1 and #k <= MAX_KEY and k:match("^[%w_%- ]+$") ~= nil
end

-- Returns the rule for a path (an array of strings), and whether the setting may be removed (dynamic entries only), or nil, reason.
local function ruleFor(path)
  if type(path) ~= "table" or #path < 2 or #path > 4 then return nil, "bad path" end
  for _, seg in ipairs(path) do if type(seg) ~= "string" then return nil, "bad path" end end
  local dotted = table.concat(path, ".")
  local rule = STATIC[dotted]
  if rule then return rule, false end
  local head = table.concat(path, ".", 1, #path - 1)
  if DYNAMIC[head] then
    if not goodKey(path[#path]) then return nil, "bad name" end
    return DYNAMIC[head], true
  end
  if #path == 4 and path[1] == "trafficVariety" and path[2] == "zones" and ZONES[path[3]] then
    if not goodKey(path[4]) then return nil, "bad name" end
    return DYNAMIC_WEIGHT, true
  end
  return nil, "not an editable setting"
end

local function checkValue(rule, v)
  local kind = rule[1]
  if kind == "bool" then
    if type(v) ~= "boolean" then return nil, "needs true or false" end
    return v
  elseif kind == "number" then
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil, "needs a number" end
    if v < rule[2] or v > rule[3] then return nil, string.format("out of range (%s to %s)", rule[2], rule[3]) end
    if rule[4] then v = math.floor(v + 0.5) end
    return v
  elseif kind == "enum" then
    if type(v) ~= "string" or not rule.values[v] then return nil, "not an allowed value" end
    return v
  end
  return nil, "bad rule"
end

-- The table that holds the last segment of `path`, creating only the small maps whose names the player chooses.
local function holder(path, create)
  local t = config
  for i = 1, #path - 1 do
    local seg = path[i]
    local nxt = t[seg]
    if type(nxt) ~= "table" then
      local isZoneMap = (i == 3 and path[2] == "zones")
      if create and isZoneMap then nxt = {} t[seg] = nxt else return nil end   -- never replace or invent a whole section
    end
    t = nxt
  end
  return t, path[#path]
end

local function describe(path, v) return table.concat(path, ".") .. (v ~= nil and ("=" .. tostring(v)) or " removed") end

-- Applies a patch {set = {{p = path, v = value}}, rm = {path}}. Returns applied count, list of {p, why}, list of descriptions.
function M.applyPatch(patch)
  local applied, rejected, done = 0, {}, {}
  local function reject(p, why) rejected[#rejected + 1] = {p = p, why = why} end
  local sets = type(patch.set) == "table" and patch.set or {}
  local rms = type(patch.rm) == "table" and patch.rm or {}
  if #sets + #rms > MAX_CHANGES then
    return 0, {{p = {}, why = "too many changes in one message (" .. MAX_CHANGES .. " at most)"}}, {}
  end
  for _, change in ipairs(sets) do
    local path = type(change) == "table" and change.p
    local rule, why = ruleFor(path)
    if not rule then reject(path, why)
    else
      local value, problem = checkValue(rule, change.v)
      if value == nil then reject(path, problem)
      else
        local t, key = holder(path, true)
        if not t then reject(path, "that section does not exist")
        else
          t[key] = value
          applied = applied + 1
          done[#done + 1] = describe(path, value)
        end
      end
    end
  end
  for _, path in ipairs(rms) do
    local rule, removable = ruleFor(path)
    if not rule then reject(path, removable)
    elseif not removable then reject(path, "this setting cannot be removed, only changed")
    else
      local t, key = holder(path, false)
      if t and t[key] ~= nil then
        t[key] = nil
        applied = applied + 1
        done[#done + 1] = describe(path, nil)
      end
    end
  end
  return applied, rejected, done
end

-- The editable parts of the config, for the menu.
local function copyMap(src)
  local out = {}
  if type(src) == "table" then for k, v in pairs(src) do out[k] = v end end
  return out
end
local function copyZones(src)
  local out = {}
  if type(src) == "table" then for zone, map in pairs(src) do out[zone] = copyMap(map) end end
  return out
end

-- Rules that depend on the config: a theft method's numbers, and a black market item's price and rep.
local function addDerivedRules()
  for name, m in pairs(type(config.theft) == "table" and type(config.theft.methods) == "table" and config.theft.methods or {}) do
    if goodKey(name) and type(m) == "table" then
      local base = "theft.methods." .. name .. "."
      STATIC[base .. "seconds"] = {"number", 1, 600, true}
      STATIC[base .. "noise"] = {"number", 0, 1}
      STATIC[base .. "failChance"] = {"number", 0, 1}
      STATIC[base .. "enabled"] = {"bool"}
    end
  end
  local itemsOk, items = pcall(require, "rlsmp.server.items")
  for name, t in pairs(type(config.market) == "table" and type(config.market.tiers) == "table" and config.market.tiers or {}) do
    if goodKey(name) and type(t) == "table" and itemsOk and items.known(name) then
      local base = "market.tiers." .. name .. "."
      STATIC[base .. "price"] = {"number", 1, 100000000, true}
      STATIC[base .. "minRep"] = {"number", 0, 100, true}
      STATIC[base .. "off"] = {"bool"}
    end
  end
end

-- The values of every rule under theft / fence / market that exists in the config, as nested tables.
local function copyRuled(prefixes)
  local out = {}
  for dotted in pairs(STATIC) do
    local segs = {}
    for seg in dotted:gmatch("[^.]+") do segs[#segs + 1] = seg end
    if prefixes[segs[1]] then
      local src, dst = config, out
      for i = 1, #segs - 1 do
        src = type(src) == "table" and src[segs[i]] or nil
        dst[segs[i]] = dst[segs[i]] or {}
        dst = dst[segs[i]]
      end
      if type(src) == "table" then dst[segs[#segs]] = src[segs[#segs]] end
    end
  end
  return out
end

function M.snapshot()
  local t, s, v, w, p = config.traffic or {}, config.smartTraffic or {}, config.trafficVariety or {}, config.weather or {}, config.police or {}
  local pr = type(p.plateReading) == "table" and p.plateReading or {}
  local swap = type(v.swap) == "table" and v.swap or {}
  local limits = type(v.zoneSpeedLimits) == "table" and v.zoneSpeedLimits or {}
  local vp = type(v.police) == "table" and v.police or {}
  local pool = type(v.pool) == "table" and v.pool or {}
  local rs = type(v.respawn) == "table" and v.respawn or {}
  local pk = type(v.parked) == "table" and v.parked or {}
  local ra = type(v.rarity) == "table" and v.rarity or {}
  local pl = type(v.preload) == "table" and v.preload or {}
  local fo = type(v.focus) == "table" and v.focus or {}
  local sm = type(v.simplified) == "table" and v.simplified or {}
  local mpr = type(config.modPrice) == "table" and config.modPrice or {}
  local extra = copyRuled({theft = true, fence = true, market = true})
  -- A method without an "enabled" key is ON (theft.lua: enabled ~= false); show it that way, or the menu would list every method as off.
  for name, m in pairs(type(extra.theft) == "table" and type(extra.theft.methods) == "table" and extra.theft.methods or {}) do
    local real = config.theft.methods[name]
    if type(m) == "table" and type(real) == "table" then m.enabled = real.enabled ~= false end
  end
  return {
    theft = extra.theft, fence = extra.fence, market = extra.market,
    modPrice = {enabled = mpr.enabled, sell = mpr.sell, max = mpr.max, min = mpr.min, tolerance = mpr.tolerance},
    traffic = {enabled = t.enabled, totalBudget = t.totalBudget, baseBudget = t.baseBudget, perPlayerBudget = t.perPlayerBudget,
      minPerPlayer = t.minPerPlayer, maxPerPlayer = t.maxPerPlayer,
      respawnRange = t.respawnRange, respawnDistance = t.respawnDistance, respawnDelay = t.respawnDelay,
      spawnMinDistance = t.spawnMinDistance, spawnMaxDistance = t.spawnMaxDistance, unjam = copyMap(t.unjam)},
    smartTraffic = {enabled = s.enabled, policeReact = s.policeReact, mix = copyMap(s.mix), nightMult = copyMap(s.nightMult)},
    trafficVariety = {enabled = v.enabled, applyToTraffic = v.applyToTraffic, applyToParked = v.applyToParked,
      maxShare = v.maxShare, oversample = v.oversample, maxCandidates = v.maxCandidates,
      typeWeights = copyMap(v.typeWeights), models = copyMap(v.models), mods = copyMap(v.mods),
      zones = copyZones(v.zones), day = copyMap(v.day), night = copyMap(v.night),
      zoneSpeedLimits = {city = limits.city, main = limits.main},
      police = {enabled = vp.enabled, undercoverShare = vp.undercoverShare, maxShare = vp.maxShare, models = copyMap(vp.models)},
      swap = {enabled = swap.enabled, live = swap.live, perMinute = swap.perMinute, hiddenSeconds = swap.hiddenSeconds,
        minRatio = swap.minRatio, maxFailures = swap.maxFailures},
      pool = {enabled = pool.enabled, avoidLast = pool.avoidLast, brandWindow = pool.brandWindow, brandMax = pool.brandMax, streetMax = pool.streetMax,
        configsPerModel = pool.configsPerModel, popPower = pool.popPower},
      respawn = {enabled = rs.enabled, mode = rs.mode, perMinute = rs.perMinute, chance = rs.chance, repaintChance = rs.repaintChance, waitSeconds = rs.waitSeconds},
      parked = {amount = pk.amount, fullPool = pk.fullPool, simplifiedShare = pk.simplifiedShare},
      rarity = {enabled = ra.enabled, common = ra.common, uncommon = ra.uncommon, rare = ra.rare, uncommonValue = ra.uncommonValue, rareValue = ra.rareValue},
      focus = {enabled = fo.enabled, configs = fo.configs, minutes = fo.minutes},
      preload = {enabled = pl.enabled, minGapSeconds = pl.minGapSeconds,
        slowFrameMs = pl.slowFrameMs, settleSeconds = pl.settleSeconds, warmShare = pl.warmShare},
      simplified = {enabled = sm.enabled, parked = sm.parked, traffic = sm.traffic, nearRadius = sm.nearRadius, perMinute = sm.perMinute}},
    weather = {enabled = w.enabled, force = w.force, mix = copyMap(w.mix), periodMinutes = w.periodMinutes},
    vehicles = {allowPassengers = type(config.vehicles) == "table" and config.vehicles.allowPassengers == true},
    police = {enabled = p.enabled, antiTeleport = p.antiTeleport, blockRoadblocks = p.blockRoadblocks, noFineInStolenCar = p.noFineInStolenCar ~= false, noRadarFineIllegal = p.noRadarFineIllegal ~= false, respawnBehind = p.respawnBehind ~= false, respawnPerMinute = p.respawnPerMinute, spawnMinDistance = p.spawnMinDistance, chaseSpawnMinDistance = p.chaseSpawnMinDistance, spawnPreferRight = p.spawnPreferRight ~= false, respawnRebuildSeconds = p.respawnRebuildSeconds, copRespawnDistance = p.copRespawnDistance, copCount = p.copCount, copTopUpSeconds = p.copTopUpSeconds, maxCops = p.maxCops, areaSize = p.areaSize, copTargets = p.copTargets, bubbleMode = p.bubbleMode,
      plateFlagSeconds = p.plateFlagSeconds, descriptionSeconds = p.descriptionSeconds,
      plateReading = {enabled = pr.enabled, rangeMeters = pr.rangeMeters, maxSpeedKmh = pr.maxSpeedKmh, readChance = pr.readChance,
        afterEscapeChance = pr.afterEscapeChance, skipChance = pr.skipChance}},
  }
end

-- Who ---------------------------------------------------------------------------------------------------------------------------------
-- Everybody who is on the server (has a session) may use the menu. Returns true plus the player's name and account id for logs.
function M.canUse(pid)
  local s = sessions.get(pid)
  if not s then return false end
  local name = tostring((MP.GetPlayerName and MP.GetPlayerName(pid)) or s.name or "")
  return true, name, s.accountId
end

local function say(pid, text) if MP.SendChatMessage then MP.SendChatMessage(pid, "[Traffic] " .. text) end end

local function tooFast(pid)
  local now = util.now()
  local e = seen[pid]
  if not e or e.second ~= now then e = {second = now, count = 0} seen[pid] = e end
  e.count = e.count + 1
  return e.count > MAX_PER_SECOND
end

local function modulesResend()
  for _, name in ipairs({"smartTraffic", "trafficVariety", "trafficPolice", "theft", "plateRecords", "modPrice", "vehicles"}) do
    local ok, mod = pcall(require, "rlsmp.server." .. name)
    if ok and type(mod) == "table" and mod.resend then mod.resend() end
  end
end

local function sendState(pid)
  net.send(pid, "rlsmpTrafficAdminState", {ok = true, cfg = M.snapshot()})
end

local function sendStateToWatchers()
  for pid in pairs(watchers) do
    if sessions.get(pid) then sendState(pid) else watchers[pid] = nil end
  end
end

local function onGet(pid)
  if tooFast(pid) then return end
  if not M.canUse(pid) then
    net.send(pid, "rlsmpTrafficAdminState", {ok = false})
    return
  end
  watchers[pid] = true
  sendState(pid)
end

local function onSet(pid, data)
  if tooFast(pid) then return end
  local ok, name, account = M.canUse(pid)
  if not ok then
    net.send(pid, "rlsmpTrafficAdminState", {ok = false})
    return
  end
  watchers[pid] = true       -- somebody who changes settings has the menu open
  local t0 = type(config.traffic) == "table" and config.traffic or {}
  local u0 = type(t0.unjam) == "table" and t0.unjam or {}
  local before = {["traffic.respawnRange"] = t0.respawnRange, ["traffic.respawnDistance"] = t0.respawnDistance, ["traffic.respawnDelay"] = t0.respawnDelay, ["traffic.spawnMinDistance"] = t0.spawnMinDistance, ["traffic.spawnMaxDistance"] = t0.spawnMaxDistance,
    ["traffic.unjam.enabled"] = u0.enabled, ["traffic.unjam.seconds"] = u0.seconds, ["traffic.unjam.distance"] = u0.distance}
  local applied, rejected, done = M.applyPatch(data)
  local saved = true
  if applied > 0 then
    saved = storage.writeJson(configPath, config, true) == true
    modulesResend()
    for _, d in ipairs(done) do
      if d:find("^traffic%.respawn") or d:find("^traffic%.spawn") or d:find("^traffic%.unjam") then util.info("RLSMP-P3 range: " .. d .. " (was " .. tostring(before[d:match("^[^=]+")]) .. ")") end
    end
    local shown = {}
    for i = 1, math.min(#done, 8) do shown[i] = done[i] end
    util.info(string.format("RLSMP-ADMIN %s (pid %s, account %s) changed %d settings%s: %s%s", tostring(name), tostring(pid), tostring(account), applied,
      saved and "" or " (NOT SAVED to config.json)", table.concat(shown, ", "), #done > 8 and ", ..." or ""))
  end
  if #rejected > 0 then
    local first = rejected[1]
    util.warn(string.format("RLSMP-ADMIN %s: %d changes rejected, first: %s (%s)", tostring(name), #rejected, type(first.p) == "table" and table.concat(first.p, ".") or "?", tostring(first.why)))
  end
  net.send(pid, "rlsmpTrafficAdminResult", {ok = true, applied = applied, rejected = rejected, saved = saved})
  if applied > 0 then sendStateToWatchers() end
end

local function onMenuCommand(pid)
  if M.canUse(pid) then net.send(pid, "rlsmpTrafficAdminOpen", {}) end
end

function M.init(cfg, pluginRoot)
  config = cfg
  configPath = (pluginRoot or "") .. "config/config.json"
  seen, watchers = {}, {}
  addDerivedRules()
  net.onClient("rlsmpTrafficAdminGet", onGet)
  net.onClient("rlsmpTrafficAdminSet", onSet)
  net.onChat("trafficmenu", onMenuCommand)
  util.info("Settings menu: open to every player (changes are range checked and logged as RLSMP-ADMIN)")
end

M._ruleFor = ruleFor
return M
