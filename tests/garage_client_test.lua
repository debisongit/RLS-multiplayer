-- RLS garage computer button, client (LuaJIT). Run: luajit tests/garage_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logs = {}
function log(level, tag, msg) logs[#logs + 1] = level .. " " .. tostring(msg) end
function setExtensionUnloadMode() end
local sent, handlers, toasts, dialogs = {}, {}, {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
guihooks = {trigger = function(name, t)
  if name == "showConfirmationDialog" then dialogs[#dialogs + 1] = t else toasts[#toasts + 1] = t.msg end
end}
-- fake RLS
local vehicles = {[3] = {owned = true, model = "covet", config = {licenseName = "ABC 123"}, year = 1990},
                  [4] = {owned = false, model = "pickup", config = {licenseName = "LOAN 1"}},
                  [5] = {owned = true, timeToAccess = 5, model = "etk800", config = {licenseName = "RENT 1"}}}
local removed, saved, refreshed, removeOk = {}, 0, 0, true
overhaul_career_garage_inventory = {getVehicles = function() return vehicles end,
  removeVehicle = function(id) removed[#removed + 1] = id return removeOk end}
overhaul_career_market_valueCalculator = {getInventoryVehicleValue = function() return 4200 end}
overhaul_career_saveSystem = {saveCurrent = function() saved = saved + 1 end}
overhaul_career_garage_computer = {refreshMenu = function() refreshed = refreshed + 1 end}
overhaul_career_permissions = {getStatusForTag = function(_, _) return {allow = true} end}
overhaul_career_logistics_general = {canRemoveLogisticsVehicle = function() return true end}
local stolenNear
local goneByPlate = {}
rlsmp_theft = {nearestStolenToPlayer = function() return stolenNear end, removeStolenByPlate = function(p) goneByPlate[#goneByPlate + 1] = p end}

local net = require("rlsmp/lib/net")
net.init()
local garage = require("rlsmp/garage")
garage.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, t) handlers[name](json.encode(t)) end
local function lastSent(name) for i = #sent, 1, -1 do if sent[i].name == name then return sent[i].data end end end
local function menu()
  return {computerFacility = {functions = {vehicleInventory = true}}, vehiclesInGarage = {{inventoryId = 3}, {inventoryId = 4}, {inventoryId = 5}}}
end
local function funcs() return {general = {}, vehicleSpecific = {[3] = {}, [4] = {}, [5] = {}}} end

-- off: nothing is added
local f = funcs()
garage.onOverhaulComputerAddFunctions(menu(), f)
check(next(f.vehicleSpecific[3]) == nil and next(f.general) == nil, "disabled: no buttons")

garage.enable(true)
f = funcs()
garage.onOverhaulComputerAddFunctions(menu(), f)
check(f.vehicleSpecific[3].rlsmpStrip and f.vehicleSpecific[3].rlsmpStrip.label:find("Strip") and not f.vehicleSpecific[3].rlsmpStrip.disabled, "owned car: strip button")
check(f.vehicleSpecific[4].rlsmpStrip.disabled and f.vehicleSpecific[4].rlsmpStrip.reason.label:find("do not own"), "not owned: greyed out with a reason")
check(f.vehicleSpecific[5].rlsmpStrip.disabled, "not accessible: greyed out")
check(f.general.rlsmpItems and not f.general.rlsmpStolen, "items button always, no stolen button without a stolen car near")
local fNoFacility = funcs()
garage.onOverhaulComputerAddFunctions({computerFacility = {functions = {}}, vehiclesInGarage = {}}, fNoFacility)
check(next(fNoFacility.general) == nil, "garage without vehicleInventory: nothing added")
garage.onOverhaulComputerAddFunctions(nil, funcs())
check(true, "garbage menu data does not throw")

-- tapping the button asks the server
f.vehicleSpecific[3].rlsmpStrip.callback()
local q = lastSent("rlsmpGarageQuote")
check(q and q.plate == "ABC 123" and q.value == 4200 and q.model == "covet", "quote carries plate, value, model")
server("rlsmpGarageMenu", {ok = true, kind = "owned", plate = "ABC 123", model = "covet", strip = 1260, items = {{name = "fake_plate", label = "Fake plate", count = 2}}, fit = {}, fitted = {}})
local dlg = dialogs[#dialogs]
check(dlg and dlg.text:find("Fake plate x2") and dlg.buttons[1].label:find("1260") and dlg.buttons[1].luaCallback == 'rlsmp_garage.choose("strip")', "dialog: price and strip button")
check(#dlg.buttons == 2, "owned car: strip and close only")

-- choosing strip
garage.choose("strip")
local d = lastSent("rlsmpGarageDo")
check(d.action == "strip" and d.plate == "ABC 123" and d.inventoryId == 3, "strip request")
local nDo = 0
for _, s in ipairs(sent) do if s.name == "rlsmpGarageDo" then nDo = nDo + 1 end end
garage.choose("evil(); os.exit()")
local nDo2 = 0
for _, s in ipairs(sent) do if s.name == "rlsmpGarageDo" then nDo2 = nDo2 + 1 end end
check(nDo == nDo2, "unknown action is not sent")
server("rlsmpGarageResult", {ok = true, action = "strip", pay = 1260, takeCar = true, inventoryId = 3})
check(removed[1] == 3 and saved == 1 and refreshed == 1 and toasts[#toasts]:find("1260"), "owned car removed from the RLS inventory after the server paid")
garage.choose("strip")
check(lastSent("rlsmpGarageDo") == d and #removed == 1, "target forgotten after the strip")

-- refused
f.vehicleSpecific[3].rlsmpStrip.callback()
server("rlsmpGarageMenu", {ok = false, err = "The garage strip is closed on this server."})
check(toasts[#toasts]:find("closed"), "server no: shown as a toast")
-- a refusal from RLS stops us before we ask the server for money
vehicles[3].timeToAccess = 9
f.vehicleSpecific[3].rlsmpStrip.callback()
server("rlsmpGarageMenu", {ok = true, kind = "owned", plate = "ABC 123", strip = 5, items = {}, fit = {}})
local sentBefore = #sent
garage.choose("strip")
check(#sent == sentBefore and toasts[#toasts]:find("not available"), "RLS says the car is not available: nothing sent")
vehicles[3].timeToAccess = nil

-- RLS refuses to remove after payment: told loudly
removeOk = false
f.vehicleSpecific[3].rlsmpStrip.callback()
garage.choose("strip")
server("rlsmpGarageResult", {ok = true, action = "strip", pay = 5, takeCar = true})
check(toasts[#toasts]:find("Tell the server owner"), "RLS kept the car after payment: a clear message")
removeOk = true

local removedBefore = #removed
-- stolen car button, fitting
stolenNear = {plate = "STL 1", model = "etk800", value = 20000, year = 2003}
f = funcs()
garage.onOverhaulComputerAddFunctions(menu(), f)
check(f.general.rlsmpStolen and f.general.rlsmpStolen.label:find("STL 1"), "stolen car near: general button")
f.general.rlsmpStolen.callback()
check(lastSent("rlsmpGarageQuote").plate == "STL 1", "stolen quote")
server("rlsmpGarageMenu", {ok = true, kind = "stolen", plate = "STL 1", model = "etk800", strip = 6000, items = {},
  fit = {{name = "fake_plate", label = "Fake plate"}, {name = "x; y", label = "bad"}}, fitted = {"VIN plate"}})
dlg = dialogs[#dialogs]
check(#dlg.buttons == 3 and dlg.buttons[2].luaCallback == 'rlsmp_garage.choose("fit:fake_plate")' and dlg.text:find("Fitted: VIN plate"), "stolen dialog: strip, fit, close; bad names dropped")
garage.choose("fit:fake_plate")
check(lastSent("rlsmpGarageDo").action == "fit:fake_plate", "fit request")
local nq = #sent
server("rlsmpGarageResult", {ok = true, action = "fit:fake_plate", fitted = "Fake plate"})
check(sent[nq + 1].name == "rlsmpGarageQuote", "after fitting the dialog is refreshed")
garage.choose("strip")
server("rlsmpGarageResult", {ok = true, action = "strip", pay = 6000, takeCar = true})
check(goneByPlate[1] == "STL 1" and #removed == removedBefore, "stolen car deleted through the theft module, not the RLS inventory")

-- items button
f.general.rlsmpItems.callback()
server("rlsmpGarageMenu", {ok = true, items = {}})
check(dialogs[#dialogs].text:find("none") and #dialogs[#dialogs].buttons == 1, "items-only dialog")

garage.enable(false)
server("rlsmpGarageMenu", {ok = true, items = {}})
check(true, "disabled: events ignored")
print(string.format("garage_client_test: %d checks passed", passed))
