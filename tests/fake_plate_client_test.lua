-- Fake plates on own cars, client (LuaJIT) with fake game globals. Run: luajit tests/fake_plate_client_test.lua
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
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure rules ---------------------------------------------------------------------------------------------
local L = require("rlsmp/lib/fakePlate")
local rec = {fake = "7KTB482", real = "ABC 123"}
check(L.clean(" abc  123 ") == "ABC 123" and L.clean("") == nil and L.clean(5) == nil, "clean")
check(L.decide(rec, "7KTB482", "7KTB482") == "ok" and L.decide(rec, "7KTB482", nil) == "ok" and L.decide(rec, "7KTB482", "") == "ok", "fake on record and car: fine")
check(L.decide(rec, "7KTB482", "ABC 123") == "reapply", "car shows the real plate again: put the fake one back")
check(L.decide(rec, "ABC 123", "ABC 123") == "reapply", "record went back to the real plate: reapply")
check(L.decide(rec, "NEW 1", "NEW 1") == "drop", "plate changed another way: drop")
check(L.decide(rec, nil, nil) == "drop", "car gone: drop")

-- fake RLS -----------------------------------------------------------------------------------------------
local vehicles = {[3] = {owned = true, model = "covet", config = {licenseName = "ABC 123"}},
                  [4] = {owned = false, model = "pickup", config = {licenseName = "LOAN 1"}}}
local objects = {}
local function mkObj(id, plate)
  local o = {id = id, dyn = {licenseText = plate}}
  function o:getDynDataFieldbyName(k) return self.dyn[k] end
  function o:setDynDataFieldbyName(k, _, v) self.dyn[k] = v end
  objects[id] = o
  return o
end
mkObj(30, "ABC 123")
getObjectByID = function(id) return objects[id] end
local plateCalls, saved, refreshed = {}, 0, 0
local rlsSets = true     -- RLS's own setLicensePlateText works
core_vehicles = {setPlateText = function(text, vehId) plateCalls[#plateCalls + 1] = {text, vehId} if objects[vehId] then objects[vehId].dyn.licenseText = text end end,
  getVehicleLicenseText = function(o) return o.dyn.licenseText end}
overhaul_career_garage_inventory = {
  getVehicles = function() return vehicles end,
  getVehicleIdFromInventoryId = function(inv) return inv == 3 and 30 or nil end,
  setLicensePlateText = function(inv, text)
    if not rlsSets then error("boom") end
    core_vehicles.setPlateText(text, inv == 3 and 30 or nil)
    vehicles[inv].config.licenseName = text
  end,
}
overhaul_career_saveSystem = {saveCurrent = function() saved = saved + 1 end}
overhaul_career_garage_computer = {refreshMenu = function() refreshed = refreshed + 1 end}
overhaul_career_permissions = {getStatusForTag = function() return {allow = true} end}

local net = require("rlsmp/lib/net")
net.init()
local fp = require("rlsmp/fakePlate")
fp.onExtensionLoaded()
rlsmp_fakePlate = fp
local function server(name, t) handlers[name](json.encode(t)) end
local function lastSent(name) for i = #sent, 1, -1 do if sent[i].name == name then return sent[i].data end end end

-- off: no popup
fp.openFor(3)
check(lastSent("rlsmpFakeAsk") == nil, "disabled: nothing is asked")
fp.enable(true)

-- the tile
local tile = fp.tile(3)
check(tile.id == "rlsmpFakePlate" and tile.label == "Fit fake plate" and not tile.disabled, "tile for an owned car")
check(fp.tile(4).disabled and fp.tile(4).reason.label:find("do not own"), "not owned: greyed out")

-- the garage computer shows the tile next to the strip button
local garage = require("rlsmp/garage")
garage.enable(true)
local f = {general = {}, vehicleSpecific = {[3] = {}, [4] = {}}}
garage.onOverhaulComputerAddFunctions({computerFacility = {functions = {vehicleInventory = true}}, vehiclesInGarage = {{inventoryId = 3}, {inventoryId = 4}}}, f)
check(f.vehicleSpecific[3].rlsmpFakePlate and f.vehicleSpecific[3].rlsmpFakePlate.id == "rlsmpFakePlate", "garage: each owned car gets the fake plate tile")

-- open, offers, fit ---------------------------------------------------------------------------------------
tile.callback()
check(lastSent("rlsmpFakeAsk") ~= nil, "tile asks the server")
server("rlsmpFakeState", {list = {}, have = 0, enabled = true, choices = {"1AAA111", "2BBB222", "3CCC333"}})
local dlg = dialogs[#dialogs]
check(dlg and dlg.text:find("no fake plate") and #dlg.buttons == 1, "no item: only a hint and Close")
tile.callback()
server("rlsmpFakeState", {list = {}, have = 2, enabled = true, choices = {"1AAA111", "2BBB222", "3CCC333"}})
dlg = dialogs[#dialogs]
check(#dlg.buttons == 5 and dlg.buttons[1].label == "Fit 1AAA111" and dlg.buttons[1].luaCallback == 'rlsmp_fakePlate.choose("fit", 1)', "popup: 3 plates, other plates, close")
fp.choose("evil(); os.exit()", 1)
fp.choose("fit", 7)
check(lastSent("rlsmpFakeFit") == nil, "bad action / index: nothing sent")
fp.choose("fit", 2)
local fit = lastSent("rlsmpFakeFit")
check(fit and fit.inv == 3 and fit.idx == 2 and fit.real == "ABC 123" and fit.model == "covet", "fit request: index, real plate, model (the server picks the text)")
-- nothing changes until the server says ok
check(vehicles[3].config.licenseName == "ABC 123", "plate unchanged before the server answered")
server("rlsmpFakeResult", {ok = true, action = "fit", fake = "2BBB222", real = "ABC 123", inv = 3, have = 1})
check(vehicles[3].config.licenseName == "2BBB222" and objects[30].dyn.licenseText == "2BBB222", "RLS record and live car carry the fake plate")
check(plateCalls[#plateCalls][1] == "2BBB222" and plateCalls[#plateCalls][2] == 30, "plate texture updated through core_vehicles.setPlateText")
check(saved >= 1 and refreshed >= 1, "career saved so the plate survives, garage screen refreshed")
server("rlsmpFakeState", {list = {{fake = "2BBB222", real = "ABC 123", inv = 3, model = "covet"}}, have = 1, enabled = true})
check(fp.isFake(30) == true and fp.isFake(99) == false, "isFake: the car wears a fake plate")
check(fp.tile(3).label == "Fake plate (fitted)", "tile label shows the state")

-- theft.hasFakePlate and the police rules read it
local theft = require("rlsmp/theft")
check(theft.hasFakePlate(30) == true and theft.hasFakePlate(31) == false, "theft.hasFakePlate is true for an own car with a fake plate")

-- popup while fitted: restore
tile = fp.tile(3)
tile.callback()
server("rlsmpFakeState", {list = {{fake = "2BBB222", real = "ABC 123", inv = 3, model = "covet"}}, have = 1, enabled = true, choices = {"x"}})
dlg = dialogs[#dialogs]
check(dlg.buttons[1].label:find("Restore real plate %(ABC 123%)") and dlg.buttons[1].luaCallback == 'rlsmp_fakePlate.choose("restore", 0)', "popup: restore button")
check(not dlg.text:find("Fit "), "popup: no fit buttons while one is fitted")
fp.choose("restore", 0)
check(lastSent("rlsmpFakeRestore").fake == "2BBB222", "restore request")

-- RLS puts the real plate back (respawn): the check fixes it
vehicles[3].config.licenseName = "ABC 123"
objects[30].dyn.licenseText = "ABC 123"
fp._check()
check(vehicles[3].config.licenseName == "2BBB222" and objects[30].dyn.licenseText == "2BBB222", "real plate came back: the fake one is written again")
-- the live car shows another plate while the record keeps the fake one
objects[30].dyn.licenseText = "ZZZ 9"
fp._check()
check(objects[30].dyn.licenseText == "2BBB222", "live car with a wrong plate: fixed")

-- restore result
server("rlsmpFakeResult", {ok = true, action = "restore", fake = "2BBB222", real = "ABC 123", inv = 3})
check(vehicles[3].config.licenseName == "ABC 123" and objects[30].dyn.licenseText == "ABC 123", "restore puts the real plate on the record and the car")
server("rlsmpFakeState", {list = {}, have = 1, enabled = true})
check(fp.isFake(30) == false and theft.hasFakePlate(30) == false, "restored: no fake plate marker")

-- the player changed the plate in RLS's plate shop: the record is dropped
server("rlsmpFakeState", {list = {{fake = "2BBB222", real = "ABC 123", inv = 3, model = "covet"}}, have = 1, enabled = true})
vehicles[3].config.licenseName = "MINE 1"
sent = {}
fp._check()
check(lastSent("rlsmpFakeDrop") and lastSent("rlsmpFakeDrop").fake == "2BBB222" and next(fp._records()) == nil, "plate changed another way: record dropped")

-- the car is sold: dropped after a few checks
vehicles[3].config.licenseName = "ABC 123"
server("rlsmpFakeState", {list = {{fake = "2BBB222", real = "ABC 123", inv = 3, model = "covet"}}, have = 1, enabled = true})
local keep = vehicles[3]
vehicles[3] = nil
sent = {}
fp._check() fp._check()
check(lastSent("rlsmpFakeDrop") == nil, "one or two checks without the car: wait")
fp._check()
check(lastSent("rlsmpFakeDrop") ~= nil, "car gone for good: record dropped")
vehicles[3] = keep

-- an unspawned car (RLS bug in setLicensePlateText): only the record changes, no setPlateText on another car
objects[30] = nil
local before = #plateCalls
vehicles[3].config.licenseName = "ABC 123"
server("rlsmpFakeResult", {ok = true, action = "fit", fake = "9XYZ999", real = "ABC 123", inv = 3})
check(vehicles[3].config.licenseName == "9XYZ999" and #plateCalls == before, "car not spawned: record only, no plate call")

-- applying fails: the server is told so it gives the item back
sent = {}
server("rlsmpFakeResult", {ok = true, action = "fit", fake = "8XYZ888", real = "NOPE", inv = 77})
local undo = lastSent("rlsmpFakeRestore")
check(undo and undo.failed == true and undo.fake == "8XYZ888", "fit could not be applied: refund asked")

-- a refusal is shown
server("rlsmpFakeResult", {ok = false, action = "fit", err = "Lose the police first."})
check(toasts[#toasts] == "Lose the police first.", "server refusal shown")

-- leaving clears everything
fp.onServerLeave()
check(next(fp._records()) == nil, "leave: records cleared")

print("fake_plate_client_test: " .. passed .. " checks passed")
