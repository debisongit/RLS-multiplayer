-- Traffic variety extension test (LuaJIT). Run: luajit tests/traffic_variety_client_test.lua
-- Fakes the game, BeamMP, RLS's traffic config filter and a stand-in for RLS's wrapperLifetime (same forwarder / intact rules).
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
function setExtensionUnloadMode() end
math.randomseed(42)

-- stand-in for RLS's overhaul/lib/shell/wrapperLifetime (registerForwarder + intact, same rules) -------------------------
local forwarders = setmetatable({}, {__mode = "k"})
local function containsWrapper(current, replacement)
  while current do
    if current == replacement then return true end
    current = forwarders[current]
  end
  return false
end
package.loaded["overhaul/lib/shell/wrapperLifetime"] = {
  registerForwarder = function(wrapper, original) forwarders[wrapper] = original return wrapper end,
  intact = function(binding)
    local current = binding.target[binding.key]
    return current == binding.replacement or containsWrapper(current, binding.replacement)
  end,
}
local wl = package.loaded["overhaul/lib/shell/wrapperLifetime"]

-- the game ----------------------------------------------------------------------------------------------------------
local catalogue = {}
local function add(model, count) for i = 1, count do catalogue[#catalogue + 1] = {model = model, config = "c" .. i} end end
add("etk800", 6) add("sunburst", 6) add("pickup", 6) add("van", 4)
local vanillaCalls = {}
local function vanilla(amount, params)
  vanillaCalls[#vanillaCalls + 1] = amount
  local out = {}
  for i = 1, amount do out[#out + 1] = catalogue[(i - 1) % #catalogue + 1] end
  return out
end
core_multiSpawn = {createGroup = vanilla}

local models = {etk800 = {Type = "Car"}, sunburst = {Type = "Car"}, pickup = {Type = "Truck"}, van = {Type = "Truck"}, modcar = {Type = "Car"}}
core_vehicles = {
  getModelList = function() return {models = models} end,
  getModel = function(name)
    if name == "modcar" then return {configs = {good1 = {}, good2 = {}, bad = {}}} end
    return nil
  end,
}
overhaul_integration_patches_trafficConfigFilter = {isConfigEligible = function(model, cfg) return cfg ~= "bad" end}

local night = false
core_environment = {getLightState = function() return {isNight = night} end}
local speedLimit = 30
map = {findClosestRoad = function() return "n1", "n2", 3 end, getMap = function() return {nodes = {n1 = {speedLimit = speedLimit}}} end}
getPlayerVehicle = function() return {getPosition = function() return {x = 0, y = 0, z = 0} end} end
MPCoreNetwork = {isMPSession = function() return true end}
local careerOn = true
overhaul_career_career = {isActive = function() return careerOn end}

local T = require("rlsmp/trafficVariety")
T.onExtensionLoaded()
local original = vanilla

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(tbl) handlers["rlsmpTrafficVariety"](json.encode(tbl)) end
local function countModel(group, model) local k = 0 for _, e in ipairs(group) do if e.model == model then k = k + 1 end end return k end
local TRAFFIC = {filters = {Type = {Car = 1}, ["Config Type"] = {other = 1}}}
local PARKED = {filters = {Type = {propparked = 1}, ["Config Type"] = {other = 1}}}
local POLICE = {filters = {["Config Type"] = {police = 1, other = 0}}}

-- 1. installed once, as a forwarder over the game's function -----------------------------------------------------------
check(saw("RLSMP-P3|wrapped core_multiSpawn.createGroup (variety)"), "wrapped when the extension loads")
local ours = core_multiSpawn.createGroup
check(ours ~= vanilla and forwarders[ours] == vanilla, "registered as a forwarder of the game's own function")
for _ = 1, 10 do T.install() end
check(core_multiSpawn.createGroup == ours, "installing every frame never stacks another layer")

-- 2. before the server speaks the built-in defaults are used (the first group must not be missed) -----------------------
vanillaCalls = {}
local g = core_multiSpawn.createGroup(8, TRAFFIC)
check(#g == 8 and #vanillaCalls == 1 and vanillaCalls[1] == 16, "no settings yet: defaults apply (pool 2x), group of the wanted size")
check(saw("server settings not here yet, using the defaults"), "the provisional start is logged")

-- 3. with settings: bigger pool in, group of the wanted size out ---------------------------------------------------------
server({enabled = true})
check(saw("RLSMP-P3|traffic variety settings received: enabled=true"), "settings logged")
vanillaCalls = {}
g = core_multiSpawn.createGroup(10, TRAFFIC)
check(#g == 10, "group has the wanted size")
check(vanillaCalls[1] == 20, "the pool asked from the game is 2x the group")
check(countModel(g, "etk800") <= 3 and countModel(g, "sunburst") <= 3 and countModel(g, "pickup") <= 3 and countModel(g, "van") <= 3, "no model above 25% of the group")
check(saw("variety traffic group: want=10 pool=20"), "group summary logged")
check(saw("probe: group filters = Config Type,Type"), "probe: filter keys")
check(saw("first entry fields = config,model"), "probe: entry fields")
check(saw("model Types in the pool = Car=") and saw("Truck="), "probe: Type census")
check(saw("probe: road class source = speedLimit"), "probe: road class source")
local seenBefore = #T.candidates()
check(seenBefore > 0 and T.candidates()[1].model and T.candidates()[1].config, "live swapping: the entries the game offered are remembered")
check(T.infoOf({model = "pickup"}).type == "Truck", "live swapping: model Type lookup is shared")
check(T.contextNow().night == false, "live swapping: current day/night is shared")
core_multiSpawn.createGroup(6, PARKED)
check(#T.candidates() == seenBefore, "parked groups are not remembered (only traffic groups feed swapping)")

-- 4. weights: Truck 0 means no trucks, in traffic and parked ------------------------------------------------------------
server({enabled = true, typeWeights = {Truck = 0}})
for _ = 1, 20 do
  g = core_multiSpawn.createGroup(8, TRAFFIC)
  check(#g == 8 and countModel(g, "pickup") == 0 and countModel(g, "van") == 0, "Truck weight 0: no trucks")
end
g = core_multiSpawn.createGroup(8, PARKED)
check(#g == 8 and countModel(g, "pickup") == 0, "parked cars follow the same weights")
check(saw("variety parked group"), "parked group is logged as parked")

-- 5. day and night, road class -----------------------------------------------------------------------------------------
server({enabled = true, night = {Truck = 0}, zones = {highway = {Car = 0}}})
night = true
speedLimit = 10   -- city
g = core_multiSpawn.createGroup(8, TRAFFIC)
check(countModel(g, "pickup") + countModel(g, "van") == 0 and #g == 8 and saw("zone=city night=true"), "night in the city: no trucks")
night = false
speedLimit = 35   -- highway: Car weight 0
g = core_multiSpawn.createGroup(8, TRAFFIC)
check(countModel(g, "etk800") + countModel(g, "sunburst") == 0 and #g == 8, "highway: no cars, only trucks")
speedLimit = 10   -- city: no change
g = core_multiSpawn.createGroup(8, TRAFFIC)
check(countModel(g, "etk800") + countModel(g, "sunburst") > 0, "city: cars allowed again")
check(saw("zone=highway night=false") and saw("zone=city night=false") and saw("night=true"), "zone and day/night are in the log line")

-- 6. never police, never when switched off -------------------------------------------------------------------------------
vanillaCalls = {}
g = core_multiSpawn.createGroup(5, POLICE)
check(#g == 5 and #vanillaCalls == 1 and vanillaCalls[1] == 5, "police groups are left alone")
server({enabled = false})
vanillaCalls = {}
g = core_multiSpawn.createGroup(6, TRAFFIC)
check(#vanillaCalls == 1 and vanillaCalls[1] == 6, "settings say off: the game's own group")
server({enabled = true, applyToParked = false})
vanillaCalls = {}
core_multiSpawn.createGroup(6, PARKED)
check(vanillaCalls[1] == 6, "parked switched off: the game's own group")
vanillaCalls = {}
core_multiSpawn.createGroup(6, TRAFFIC)
check(vanillaCalls[1] == 12, "traffic still varied")
careerOn = false
vanillaCalls = {}
core_multiSpawn.createGroup(6, TRAFFIC)
check(vanillaCalls[1] == 6, "career not active: the game's own group")
careerOn = true

-- 7. mods: installed ones join, missing ones are skipped, ineligible configs stay out -----------------------------------
server({enabled = true, mods = {modcar = 1000, missingmod = 1000}, maxShare = 1})
local modPicks, allGood = 0, true
for _ = 1, 20 do
  g = core_multiSpawn.createGroup(6, TRAFFIC)
  for _, e in ipairs(g) do
    if e.model == "modcar" then modPicks = modPicks + 1 if e.config == "bad" then allGood = false end end
    check(e.model ~= "missingmod", "a mod model that is not installed is never picked")
  end
end
check(modPicks == 40, "an installed mod with a big weight: both usable configs in every group (2 x 20), each once (" .. modPicks .. ")")
check(allGood, "configs RLS's own filter rejects are never used")
check(saw("mod model missingmod is not installed here"), "missing mod is logged once")
local before = #logged
core_multiSpawn.createGroup(6, TRAFFIC)
local again = 0
for i = before + 1, #logged do if logged[i]:find("missingmod is not installed", 1, true) then again = again + 1 end end
check(again == 0, "...and not again")
overhaul_integration_patches_trafficConfigFilter = nil
g = core_multiSpawn.createGroup(6, TRAFFIC)
check(countModel(g, "modcar") == 0 and saw("RLS's traffic config filter is not available"), "without RLS's filter, mods are skipped")
overhaul_integration_patches_trafficConfigFilter = {isConfigEligible = function(model, cfg) return cfg ~= "bad" end}

-- 8. anything unexpected: the game's own group ---------------------------------------------------------------------------
server({enabled = true})
core_multiSpawn.createGroup = (function(inner)
  local w = core_multiSpawn.createGroup
  return w
end)(nil)
-- the game returns nothing for the big request
local calls = 0
local function picky(amount, params)
  calls = calls + 1
  if amount > 6 then return nil end
  return vanilla(amount, params)
end
-- rebuild the chain over a different game function
core_multiSpawn = {createGroup = picky}
installedAfterReload = true
T.install()
g = core_multiSpawn.createGroup(6, TRAFFIC)
check(#g == 6, "the pool call returned nothing: the game's own group is used")
local function boom(amount, params) if amount > 6 then error("boom") end return vanilla(amount, params) end
core_multiSpawn = {createGroup = boom}
T.install()
g = core_multiSpawn.createGroup(6, TRAFFIC)
check(#g == 6 and saw("variety failed, the game's own group is used"), "an error inside: logged, the game's own group is used")

-- junk cars in the game's own group (ours failed): re-picked away, never kept
local function junky(amount, params)
  if amount > 6 then error("boom") end
  return {{model = "midsize", config = "joesjunk_career_midsize_2"}, {model = "etk800", config = "c1"}, {model = "lansdale", config = "wrecked_a"}}
end
core_multiSpawn = {createGroup = junky}
T.install()
g = core_multiSpawn.createGroup(4, TRAFFIC)
local junkLeft = 0
for _, e in ipairs(g) do if e.config:find("junk") or e.config:find("wreck") then junkLeft = junkLeft + 1 end end
check(#g >= 1 and junkLeft == 0 and saw("junk car(s) in the game's own group re-picked"), "the game's own group: junk cars replaced or dropped")

-- 9. RLS wraps over us, like it does in a real career start. Its wrapper is NOT registered as a forwarder of what it wraps
--    (trafficConfigFilter's makeWrapper does not register it), so we are no longer "intact" and wrap again: only ONE layer may be active.
local function rlsPlainWrap(orig) return function(amount, params) return orig(amount, params) end end
local function countLines(fragment) local k = 0 for _, l in ipairs(logged) do if l:find(fragment, 1, true) then k = k + 1 end end return k end
core_multiSpawn = {createGroup = vanilla}
T.install()                                           -- our extension loads first, at mod mount
local rewrapsBefore = 0
for _, l in ipairs(logged) do if l:find("rewrapped createGroup", 1, true) then rewrapsBefore = rewrapsBefore + 1 end end
for round = 1, 5 do
  core_multiSpawn.createGroup = rlsPlainWrap(core_multiSpawn.createGroup)   -- RLS (re)installs its filter over everything
  for _ = 1, 6 do T.install() end                    -- our every-frame check
end
local rewraps = 0
for _, l in ipairs(logged) do if l:find("rewrapped createGroup", 1, true) then rewraps = rewraps + 1 end end
check(rewraps - rewrapsBefore == 5, "one re-wrap per RLS reinstall, never more (5 reinstalls, 30 checks)")
check(forwarders[core_multiSpawn.createGroup] ~= nil, "the outermost function is our newest layer")
local layersBefore = 0
logged = {}
vanillaCalls = {}
g = core_multiSpawn.createGroup(10, TRAFFIC)
check(#g == 10, "the group is built")
check(countLines("variety traffic group:") == 1, "exactly one layer builds the group (one log line), although six of ours are in the chain")
check(#vanillaCalls == 1 and vanillaCalls[1] == 20, "the game is asked once, for a 2x pool (not a pool of a pool)")
-- RLS's patch refresh also keeps working: it sees our newest layer through the forwarder we registered
local rlsReplacement = core_multiSpawn.createGroup   -- stand-in: pretend this is RLS's current binding
check(wl.intact({target = core_multiSpawn, key = "createGroup", replacement = core_multiSpawn.createGroup}), "our newest layer is intact")
-- a police group still passes straight through every layer
vanillaCalls = {}
core_multiSpawn.createGroup(5, POLICE)
check(#vanillaCalls == 1 and vanillaCalls[1] == 5, "police groups pass through all layers untouched")

-- 9b. if RLS's wrapper IS a registered forwarder, we never re-wrap
core_multiSpawn = {createGroup = vanilla}
T.install()
local rlsRegistered = function(orig)
  local w = function(amount, params) return orig(amount, params) end
  wl.registerForwarder(w, orig)
  return w
end
logged = {}
for _ = 1, 4 do
  core_multiSpawn.createGroup = rlsRegistered(core_multiSpawn.createGroup)
  for _ = 1, 6 do T.install() end
end
check(countLines("rewrapped createGroup") == 0, "RLS wrapper registered as a forwarder: our layer stays intact, no re-wrap at all")
logged = {}
for _ = 1, 20 do T.install() end
check(countLines("rewrapped createGroup") == 0 and countLines("wrapped core_multiSpawn.createGroup") == 0, "nothing happens while our layer is intact")

-- 9c. the game replaces the whole function (a reload): one new wrap, then stable
core_multiSpawn.createGroup = vanilla
logged = {}
T.install()
local fresh = core_multiSpawn.createGroup
check(fresh ~= vanilla and forwarders[fresh] == vanilla, "after the function was replaced, wrapped again")
for _ = 1, 6 do T.install() end
check(core_multiSpawn.createGroup == fresh, "...and stable")

-- 9d. RLS's Lua is missing: a failed require is not retried every frame
package.loaded["rlsmp/trafficVariety"] = nil
package.loaded["overhaul/lib/shell/wrapperLifetime"] = nil
local loaderCalls = 0
local searchers = package.searchers or package.loaders
local counter = function(name)   -- counts how often the game's module search is asked for RLS's library (not found each time)
  if name == "overhaul/lib/shell/wrapperLifetime" then loaderCalls = loaderCalls + 1 end
  return "\n\tno such module (test)"
end
table.insert(searchers, counter)
local T2 = require("rlsmp/trafficVariety")
core_multiSpawn = {createGroup = vanilla}
for _ = 1, 120 do T2.install() end
check(loaderCalls == 2, "120 frames without RLS: the library was looked for twice, not 120 times (" .. loaderCalls .. ")")
check(core_multiSpawn.createGroup == vanilla, "without RLS's wrapperLifetime nothing is wrapped")
check(saw("RLS's wrapperLifetime is not available"), "and it says so")
for i = #searchers, 1, -1 do if searchers[i] == counter then table.remove(searchers, i) end end
package.loaded["overhaul/lib/shell/wrapperLifetime"] = wl
package.loaded["rlsmp/trafficVariety"] = T

-- 10. leaving the server forgets the settings -----------------------------------------------------------------------------------
server({enabled = true})
vanillaCalls = {}
local counting = core_multiSpawn.createGroup
core_multiSpawn = {createGroup = vanilla}
T.install()
core_multiSpawn.createGroup(4, TRAFFIC)
check(vanillaCalls[1] == 8, "settings active")
T.onServerLeave()
check(T.getConfig() == nil, "settings forgotten on leaving")
vanillaCalls = {}
core_multiSpawn.createGroup(4, TRAFFIC)
check(vanillaCalls[1] == 8, "after leaving (still flagged as a session): defaults again, never stuck without settings")

-- a model with no .jbeam files (a leftover of a deleted mod; a real log showed G30_Domestic crash the spawn) is never put in a group ------------------------
server({enabled = true})
FS = {findFiles = function(self, dir) if dir:find("brokencar", 1, true) then return {} end return {dir .. "body.jbeam"} end}
models.brokencar = {Type = "Car"}
for _ = 1, 6 do table.insert(catalogue, 1, {model = "brokencar", config = "c1"}) end
vanillaCalls = {}
g = core_multiSpawn.createGroup(10, TRAFFIC)
check(#g == 10 and countModel(g, "brokencar") == 0, "a model without jbeam files is left out of the group, the group is still full")
check(saw("variety: brokencar has no .jbeam files"), "...and it is logged once")
local warnings = 0
for _, l in ipairs(logged) do if l:find("brokencar has no .jbeam", 1, true) then warnings = warnings + 1 end end
core_multiSpawn.createGroup(10, TRAFFIC)
local warnings2 = 0
for _, l in ipairs(logged) do if l:find("brokencar has no .jbeam", 1, true) then warnings2 = warnings2 + 1 end end
check(warnings == 1 and warnings2 == 1, "the model is checked and logged only once")
-- every offered model broken: the game keeps its own group (nil from the extension)
local only = {}
catalogue = only
for _ = 1, 20 do only[#only + 1] = {model = "brokencar", config = "c1"} end
FS = {findFiles = function() return {} end}
g = core_multiSpawn.createGroup(5, TRAFFIC)
check(#g == 5 and g[1].model == "brokencar", "all offered models broken: the game's own group is used instead of an empty one")
-- if the file system cannot be asked, nothing is filtered (no regression): a model not asked about before passes
FS = nil
models.neverasked = {Type = "Car"}
catalogue = {}
for _ = 1, 20 do catalogue[#catalogue + 1] = {model = "neverasked", config = "c1"} end
g = core_multiSpawn.createGroup(5, TRAFFIC)
check(#g == 5 and g[1].model == "neverasked", "no file system to ask: models are not filtered")

-- 10. police groups: re-picked (file group through fitGroup, and createGroup), settings, safety -----------------------------------------------
do
  local bastionCfgs = {"police_v8_awd_A", "police_redtail", "police_unmarked_v8_awd_A_Red", "police_unmarked_v8_awd_A_Blue", "undercover_redtail"}
  local function polCfgs(list) local t = {} for _, c in ipairs(list) do t[c] = {["Config Type"] = "Police"} end return t end
  local police = {bastion = polCfgs(bastionCfgs), fullsize = polCfgs({"police"}), sunburst = polCfgs({"police"}), etk800 = {c1 = {["Config Type"] = "Factory"}}}
  local oldGetModel = core_vehicles.getModel
  core_vehicles.getModelList = function() return {models = {bastion = {}, fullsize = {}, sunburst = {}, etk800 = {}}} end
  core_vehicles.getModel = function(name) if police[name] then return {configs = police[name]} end return oldGetModel(name) end
  local fitCalls = 0
  local function fit(group, count) fitCalls = fitCalls + 1 local out = {} for i = 1, count do out[i] = group[(i - 1) % #group + 1] end return out end
  core_multiSpawn.fitGroup = fit
  T.onServerLeave()
  T.onExtensionLoaded()   -- installs the fitGroup wrapper too
  check(saw("wrapped core_multiSpawn.fitGroup (variety)"), "fitGroup is wrapped")
  local fileGroup = {}
  for _, c in ipairs(bastionCfgs) do fileGroup[#fileGroup + 1] = {model = "bastion", config = c} end
  server({enabled = true})
  local bastions, undercover, cars = 0, 0, 0
  logged = {}
  for _ = 1, 300 do
    local pg = core_multiSpawn.fitGroup(fileGroup, 2)
    check(#pg == 2, "police file group: the wanted size")
    for _, e in ipairs(pg) do
      cars = cars + 1
      if e.model == "bastion" then bastions = bastions + 1 end
      if e.config:find("unmarked") or e.config:find("undercover") then undercover = undercover + 1 end
    end
  end
  check(fitCalls == 0, "the file group is replaced, the game's fitGroup is not needed")
  check(bastions / cars < 0.4 and undercover / cars < 0.15, "police file group: fewer Bastions and few undercover (b=" .. bastions .. " u=" .. undercover .. " of " .. cars .. ")")
  check(saw("police pool: 7 configs: bastion (undercover)=3, bastion=5, fullsize=1, sunburst=1"), "the police pool is logged")
  check(saw("variety police group: want=2"), "police group is logged")
  -- createGroup with the police intent (no file) is re-picked too
  vanillaCalls = {}
  local cg = core_multiSpawn.createGroup(3, POLICE)
  check(#cg == 3 and #vanillaCalls == 0, "createGroup police intent: re-picked from the police pool")
  -- a non-police list is passed to the game's fitGroup untouched
  local other = {{model = "etk800", config = "c1"}, {model = "sunburst", config = "c2"}}
  local fg = core_multiSpawn.fitGroup(other, 4)
  check(#fg == 4 and fitCalls == 1, "a non-police group goes to the game's fitGroup")
  -- switched off: the game's own groups
  server({enabled = true, police = {enabled = false}})
  vanillaCalls, fitCalls = {}, 0
  core_multiSpawn.createGroup(5, POLICE)
  core_multiSpawn.fitGroup(fileGroup, 3)
  check(#vanillaCalls == 1 and vanillaCalls[1] == 5 and fitCalls == 1, "police.enabled = false: the game's own police groups")
  -- an error while picking gives the game's group
  server({enabled = true})
  local oldList = core_vehicles.getModelList
  T.onServerLeave()
  server({enabled = true})
  core_vehicles.getModelList = function() error("boom") end
  fitCalls = 0
  local safe = core_multiSpawn.fitGroup(fileGroup, 3)
  check(#safe == 3 and fitCalls == 1, "no police pool (model list fails): the game's fitGroup answers")
  core_vehicles.getModelList = oldList
  -- a Bastion weight of 0 and only Bastions known: nothing to pick, the game keeps its group
  T.onServerLeave()
  server({enabled = true, police = {models = {bastion = 0, fullsize = 0, sunburst = 0}}})
  fitCalls = 0
  core_multiSpawn.fitGroup(fileGroup, 3)
  check(fitCalls == 1, "all police weighted 0: the game's group")
end

-- 11. the premade pool and the re-roll pick ---------------------------------------------------------------------------------------
do
  T.onServerLeave()
  server({enabled = true})
  local oldGetModel, oldList = core_vehicles.getModel, core_vehicles.getModelList
  local brandOf = {etk800 = "ETK", sunburst = "Ibishu", pickup = "Gavril", van = "Gavril", modcar = "Mod", simple_traffic = "X", proppy = "Y"}
  core_vehicles.getModelList = function()
    local m = {}
    for name, b in pairs(brandOf) do m[name] = {Type = name == "simple_traffic" and "PropTraffic" or (name == "proppy" and "Prop" or ((name == "pickup" or name == "van") and "Truck" or "Car")), Brand = b} end
    return {models = m}
  end
  core_vehicles.getModel = function(name)
    local cfgs = {}
    for i = 1, 8 do cfgs["k" .. i] = {Population = 1000 * i} end
    cfgs.bad = {}
    return {configs = cfgs}
  end
  gameplay_traffic_trafficUtils = {getBaseGroupParams = function() return {filters = {Type = {Car = 1, Truck = 1}}} end}
  check(T.premadeCount() == 0, "pool: nothing before the first frames")
  for _ = 1, 10 do T.onUpdate(0.016) end
  check(T.premadeCount() > 0, "pool: built over a few frames")
  check(saw("premade pool: building from 5 models (Types from the game: Car,Truck)"), "pool: only the game's Types (no Prop, no simple_traffic), logged")
  check(saw("premade pool: 25 configs of 5 models, 4 brands"), "pool: 5 configs per model (the 'bad' one is refused by RLS's filter), brands counted")
  local sample = core_multiSpawn.createGroup(6, TRAFFIC)
  check(#sample == 6 and saw("premade=25"), "groups draw from the premade pool too")
  -- a re-roll pick: another model, round robin, brand census respected
  local cur = {model = "etk800", config = "k1"}
  local lastModel
  for _ = 1, 60 do
    local e, stage = T.pickReplacement(cur, nil)
    check(e and e.model ~= cur.model and e.model ~= lastModel and brandOf[e.model], "pick: another model, never the same twice in a row")
    lastModel, cur = e.model, e
  end
  local m = T.getMemory()
  m.history, m.last = {}, {}
  local e = T.pickReplacement({model = "pickup", config = "k1"}, {ETK = 3, Ibishu = 3, Mod = 3})
  check(e and e.model == "van", "pick: brands full on the street are avoided when another exists")
  -- switched off
  server({enabled = true, pool = {enabled = false}})
  check(T.pickReplacement({model = "etk800", config = "k1"}) == nil, "pool.enabled false: no pick (the car stays)")
  server({enabled = true})
  -- leaving the server clears the pool
  T.onServerLeave()
  check(T.premadeCount() == 0, "pool: cleared when leaving")
  core_vehicles.getModel, core_vehicles.getModelList = oldGetModel, oldList
  gameplay_traffic_trafficUtils = nil
end

-- The setup group is asked at the server's minimum (setActiveAmount cannot add cars later) ------------------------------------------------
do
  server({enabled = true, minAmount = 12, maxCars = 40})
  check(require("rlsmp/lib/trafficVariety").sanitize({minAmount = 9999, maxCars = -3}).minAmount == 64 and require("rlsmp/lib/trafficVariety").sanitize({maxCars = -3}).maxCars == 0, "minAmount / maxCars are clamped")
  gameplay_traffic = {getTrafficData = function() return {} end}
  vanillaCalls = {}
  local big = core_multiSpawn.createGroup(4, TRAFFIC)
  check(#big == 12 and saw("fill: the game asked for a traffic group of 4, the server wants 12"), "no traffic yet: the group is as big as the minimum")
  check(#core_multiSpawn.createGroup(4, POLICE) == 4, "police groups keep their size")
  check(#core_multiSpawn.createGroup(4, PARKED) == 4, "parked groups keep their size")
  check(#core_multiSpawn.createGroup(1, TRAFFIC) == 1, "a single car stays single")
  rlsmp_traffic = {getQuota = function() return 8 end}
  check(#core_multiSpawn.createGroup(4, TRAFFIC) == 8, "never above the quota")
  rlsmp_traffic = nil
  gameplay_traffic = {getTrafficData = function() return {[1] = {}} end}
  check(#core_multiSpawn.createGroup(4, TRAFFIC) == 4, "traffic already exists: a refill keeps its size")
  gameplay_traffic = nil
  server({enabled = true})
  check(#core_multiSpawn.createGroup(4, TRAFFIC) == 4, "no minimum known: the game's size")
end

print(string.format("traffic_variety_client_test: %d checks passed", passed))
