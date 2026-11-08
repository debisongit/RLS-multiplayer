-- Mod price extension test (LuaJIT). Run: luajit tests/mod_price_client_test.lua
-- Fakes the game, BeamMP and RLS's valueCalculator.getVehicleValuation (price = catalog value x age factor, like RLS) and wrapperLifetime.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
local function count(fragment) local n = 0 for _, l in ipairs(logged) do if l:find(fragment, 1, true) then n = n + 1 end end return n end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end
function setExtensionUnloadMode() end

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
  intact = function(b) local c = b.target[b.key] return c == b.replacement or containsWrapper(c, b.replacement) end,
}

-- RLS stand-in: catalog value of the car (the "parts" value), 0.5 age factor, floor 500
local profileValue = {}
local function original(opts)
  if type(opts) ~= "table" then return nil end
  local cat = profileValue[opts.modelName .. "/" .. opts.configKey] or opts.catalogBaseValue
  local book = math.max(500, cat * 0.5)
  return {catalogValue = cat, bookValue = book, preDamageValue = book, partsValueFloor = cat * 0.3, catalogSource = "parts"}
end
-- selling: value = catalog x 0.4 (x 0.9 for the sell value), like RLS's chain from the parts sum
local invCars = {}
overhaul_career_garage_inventory = {getVehicles = function() return invCars end}
core_vehicles = {getConfig = function() return {Power = 300, Weight = 1500, ["Top Speed"] = 70, Drivetrain = "RWD", Type = "Car"} end}
local function catalogOf(m, c) return profileValue[m .. "/" .. c] end
local function invValue(id)
  local v = invCars[id]
  local c = v and v.config
  local key = c and (c.key or (c.partConfigFilename and c.partConfigFilename:match("([^/]+)%.pc$")))
  return key and catalogOf(v.model, key) * 0.4 or nil
end
overhaul_career_market_valueCalculator = {
  getVehicleValuation = original,
  getInventoryVehicleValue = invValue,
  getInventoryVehicleSellValue = function(id) local v = invValue(id) return v and v * 0.9 end,
  getVehicleCatalogProfile = function(m, c) return {catalogValue = catalogOf(m, c)} end,
}
local realPaths = {}
FS = {getFileRealPath = function(_, p) return realPaths[p] end}

local T = require("rlsmp/modPrice")
T.onExtensionLoaded()
T.onUpdate()

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(tbl) handlers["rlsmpModPrice"](json.encode(tbl)) end
local function list(model, config, cat, info)
  profileValue[model .. "/" .. config] = cat
  local i = {Power = 300, Weight = 1500, ["Top Speed"] = 70, Drivetrain = "RWD", Type = "Car", Name = "x", rawCatalogValue = cat, catalogValueSource = "parts"}
  for k, v in pairs(info or {}) do i[k] = v end
  return {modelName = model, configKey = config, configInfo = i, age = 5, catalogBaseValue = cat, logContext = "updateVehicleList"}
end

-- 1. wrapped, but silent until the server spoke
check(overhaul_career_market_valueCalculator.getVehicleValuation ~= original, "wrapped")
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "a", 9e6)).bookValue == 4.5e6, "no settings yet: the game's price")

-- 2. settings arrive; an absurd mod car gets the estimate
server({enabled = true, max = 2000000, min = 800, tolerance = 0.35, overrides = {}, models = {"modcar"}})
local v = overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "a", 9e6))
check(v.catalogValue < 100000 and v.catalogValue > 20000 and v.catalogSource == "modPrice", "absurd high value replaced")
check(math.abs(v.bookValue - v.catalogValue * 0.5) < 1, "RLS's age factor kept")
check(saw("modprice: modcar/a author=9000000") and saw("(estimate)"), "logged with author, estimate and used")
local cheap = overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "b", 50))
check(cheap.catalogValue > 20000, "absurd low value replaced")

-- 3. a fair author value stays
local fair = overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "c", 38000))
check(fair.catalogValue == 38000 and fair.catalogSource == "parts", "within tolerance: untouched")

-- 4. other contexts, other models, missing data
local other = list("modcar", "d", 9e6) other.logContext = "carMeetPurchase"
check(overhaul_career_market_valueCalculator.getVehicleValuation(other).catalogValue == 9e6, "only the car shop")
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("etk800", "e", 9e6)).catalogValue == 9e6, "vanilla model untouched")
check(saw("etk800 is left alone"), "vanilla decision logged")
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "f", 9e6, {Power = false})).catalogValue == 9e6, "no power: the game's price")
check(overhaul_career_market_valueCalculator.getVehicleValuation(nil) == nil, "nil passes through")

-- 5. model found by its file path (downloaded from the server)
realPaths["/vehicles/dlcar/info.json"] = "C:/x/mods/multiplayer/cars.zip"
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("dlcar", "a", 9e6)).catalogValue < 100000, "path under multiplayer = a mod")

-- 6. overrides win, even for a vanilla model
server({enabled = true, overrides = {["etk800/e"] = 33333}, models = {}})
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("etk800", "e", 9e6)).catalogValue == 33333, "override")

-- 7. off, and logging once per config
server({enabled = false, models = {"modcar"}})
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "a", 9e6)).catalogValue == 9e6, "disabled: the game's price")
server({enabled = true, models = {"modcar"}})
local before = count("modprice: modcar/g")
for _ = 1, 5 do overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "g", 9e6)) end
check(count("modprice: modcar/g") - before == 1, "one log line per model/config")

-- 8. somebody wraps over us, then replaces us: we wrap again
local mine = overhaul_career_market_valueCalculator.getVehicleValuation
local theirs = function(...) return mine(...) end
forwarders[theirs] = mine
overhaul_career_market_valueCalculator.getVehicleValuation = theirs
T.onUpdate()
check(overhaul_career_market_valueCalculator.getVehicleValuation == theirs, "intact chain: no second layer")
overhaul_career_market_valueCalculator.getVehicleValuation = original
T.onUpdate()
check(overhaul_career_market_valueCalculator.getVehicleValuation ~= original, "replaced: wrapped again")
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "h", 9e6)).catalogValue < 100000, "still works after re-wrapping")

-- 9. an error inside never breaks the shop
local bad = list("modcar", "i", 9e6)
bad.configInfo = setmetatable({}, {__index = function() error("boom") end})
check(overhaul_career_market_valueCalculator.getVehicleValuation(bad).catalogValue == 9e6, "error: the game's price")

-- 9b. selling: the same fair price, only for modded models
profileValue["modcar/s1"], profileValue["etk800/s2"], profileValue["modcar/s3"] = 9e6, 9e6, 38000
invCars[1] = {model = "modcar", year = 2020, config = {key = "s1"}}
invCars[2] = {model = "etk800", year = 2020, config = {key = "s2"}}
invCars[3] = {model = "modcar", year = 2020, config = {partConfigFilename = "vehicles/modcar/s3.pc"}}
invCars[4] = {model = "modcar", year = 2020}
local V = overhaul_career_market_valueCalculator
local shopPrice = V.getVehicleValuation(list("modcar", "s1", 9e6)).catalogValue
check(math.abs(V.getInventoryVehicleValue(1) - shopPrice * 0.4) < 1, "sold at the same fair price as bought")
check(math.abs(V.getInventoryVehicleSellValue(1) - shopPrice * 0.36) < 1, "sell value too")
check(V.getInventoryVehicleValue(2) == 9e6 * 0.4, "vanilla car: the game's value")
check(V.getInventoryVehicleValue(3) == 38000 * 0.4, "fair author value: untouched (file name config key)")
check(V.getInventoryVehicleValue(4) == nil, "no config key: the game's value (nil here)")
check(V.getInventoryVehicleValue(99) == nil, "unknown car: nil passes through")
check(saw("modprice: selling modcar/s1"), "sell price logged")
server({enabled = true, sell = false, models = {"modcar"}})
check(V.getInventoryVehicleValue(1) == 9e6 * 0.4, "sell = false: the game's value")
server({enabled = true, models = {"modcar"}})
local oldCore = core_vehicles
core_vehicles = {getConfig = function() error("boom") end}
check(V.getInventoryVehicleValue(1) == 9e6 * 0.4, "no config data: the game's value")
core_vehicles = oldCore
check(overhaul_career_market_valueCalculator.getInventoryVehicleValue ~= invValue, "sell function wrapped")

-- 10. leaving the server
T.onServerLeave()
check(overhaul_career_market_valueCalculator.getVehicleValuation(list("modcar", "a", 9e6)).catalogValue == 9e6, "left the server: the game's price")
check(overhaul_career_market_valueCalculator.getInventoryVehicleValue(1) == 9e6 * 0.4, "left the server: the game's sell value")

print("mod_price_client_test: " .. passed .. " checks passed")
