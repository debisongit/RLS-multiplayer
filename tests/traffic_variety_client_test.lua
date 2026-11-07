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

-- 9. RLS refreshes its own wrappers: no fighting, no growth ----------------------------------------------------------------
core_multiSpawn = {createGroup = vanilla}
-- like RLS's patch registry: every wrapper it installs is registered as a forwarder of what it wraps
local rlsWrap = function(orig)
  local wrapper = function(amount, params) return orig(amount, params) end
  wl.registerForwarder(wrapper, orig)
  return wrapper
end
local rlsReplacement = rlsWrap(vanilla)
core_multiSpawn.createGroup = rlsReplacement        -- RLS's filter, installed first
local rlsInstalls = 0
local function rlsRefresh()                          -- RLS's patch refresh: re-wrap only if its wrapper is not intact
  if not wl.intact({target = core_multiSpawn, key = "createGroup", replacement = rlsReplacement}) then
    rlsInstalls = rlsInstalls + 1
    rlsReplacement = rlsWrap(core_multiSpawn.createGroup)
    core_multiSpawn.createGroup = rlsReplacement
  end
end
T.install()                                          -- we wrap on top of RLS's filter
local mine = core_multiSpawn.createGroup
check(mine ~= rlsReplacement and forwarders[mine] == rlsReplacement, "wrapped on top of RLS's filter as its forwarder")
for _ = 1, 6 do rlsRefresh() T.install() end
check(rlsInstalls == 0, "RLS's refresh sees our wrapper as part of its chain and does not re-wrap")
check(core_multiSpawn.createGroup == mine, "our wrapper stays the outermost one")
-- RLS reinstalls its filter over everything (e.g. it was reloaded): we end up inside it and stay stable
core_multiSpawn.createGroup = rlsWrap(core_multiSpawn.createGroup)
local outer = core_multiSpawn.createGroup
for _ = 1, 6 do T.install() end
check(core_multiSpawn.createGroup == outer, "RLS's wrapper outside ours: we leave it alone (our wrapper is inside the chain)")
-- the game replaces the whole function (a reload): one new wrap, then stable
core_multiSpawn.createGroup = vanilla
T.install()
local fresh = core_multiSpawn.createGroup
check(fresh ~= vanilla and forwarders[fresh] == vanilla, "after the function was replaced, wrapped exactly once")
for _ = 1, 6 do T.install() end
check(core_multiSpawn.createGroup == fresh, "...and stable")
check(wl ~= nil, "stand-in registry in use")

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
