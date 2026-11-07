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

-- 2. before the server speaks the game's group is untouched -------------------------------------------------------------
vanillaCalls = {}
local g = core_multiSpawn.createGroup(8, TRAFFIC)
check(#g == 8 and #vanillaCalls == 1 and vanillaCalls[1] == 8, "no settings yet: the game's own call, same size")

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
check(vanillaCalls[1] == 4, "after leaving: the game's own group")

print(string.format("traffic_variety_client_test: %d checks passed", passed))
