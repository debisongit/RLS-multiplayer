-- Client fleet test (LuaJIT) with a fake RLS inventory. Run: luajit tests/fleet_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
function deepcopy(t) return jsonDecode(jsonEncode(t)) end
local toasts, sent, handlers = {}, {}, {}
guihooks = {trigger = function(_, d) toasts[#toasts + 1] = d.msg end}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end

-- Fake RLS inventory
local vehicles = {[4] = {model = "etk800", niceName = "ETK", config = {parts = {a = "b"}}}}
local current, free, removed, dirty = 4, true, {}, {}
overhaul_career_garage_inventory = {
  getCurrentVehicle = function() return current end,
  getVehicle = function(id) return vehicles[id] end,
  removeVehicle = function(id) removed[#removed + 1] = id vehicles[id] = nil end,
  hasFreeSlot = function() return free end,
  addVehicle = function(vehId) vehicles[10] = {model = "etk800", config = {}} return 10 end,
  setVehicleDirty = function(id) dirty[#dirty + 1] = id end,
  getVehicles = function() return vehicles end,
}
overhaul_career_logistics_general = {canRemoveLogisticsVehicle = function() return true end}
getPlayerVehicle = function() return nil end
local spawned
core_vehicles = {spawnNewVehicle = function(model, o) spawned = {model = model, config = o.config} return {getID = function() return 77 end, delete = function() end} end}
rlsmp_saveBridge = {requestSave = function() end}

local transfer = require("rlsmp/lib/transfer")
local net = require("rlsmp/lib/net")
net.init()
local fleet = require("rlsmp/fleet")
fleet.onExtensionLoaded()
fleet.enable(true)

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, t) handlers[name](json.encode(t)) end
local function uploaded()
  for _ = 1, 50 do net.pump(10) end
  local begin = sent[1].data
  local asm = transfer.newAssembler(begin)
  for i = 2, #sent do asm:add(sent[i].data.i, sent[i].data.d) end
  sent = {}
  return json.decode(assert(asm:finish()))
end

-- add: uploads, removes only after the server says ok
server("rlsmpFleetDo", {act = "add"})
local up = uploaded()
check(up.kind == "fleetAdd" and up.data.inv == 4 and up.data.rec.model == "etk800", "car uploaded")
check(#removed == 0, "not removed before the server confirms")
server("rlsmpFleetAck", {act = "add", ok = false, inv = 4})
check(#removed == 0, "failed ack keeps the car")
server("rlsmpFleetAck", {act = "add", ok = true, inv = 4})
check(removed[1] == 4, "removed after ok ack")

-- take: spawns and registers
local payload = json.encode({fid = "1", rec = {model = "etk800", niceName = "Shared ETK", config = {parts = {x = "y"}}}})
local header, chunks = transfer.describe(payload, 30)
header.id, header.kind, header.extra = 1, "fleetVehicle", {fid = "1"}
server("rlsmpChunkBegin", header)
for i, d in ipairs(chunks) do server("rlsmpChunk", {id = 1, i = i, d = d}) end
check(spawned and spawned.model == "etk800" and spawned.config.parts.x == "y", "car spawned from record")
check(vehicles[10].fleetId == "1" and vehicles[10].niceName == "Shared ETK" and dirty[1] == 10, "tagged in inventory")

-- take fails when the garage is full -> tells the server
free = false
sent = {}
server("rlsmpChunkBegin", header)
for i, d in ipairs(chunks) do server("rlsmpChunk", {id = 1, i = i, d = d}) end
check(sent[1].name == "rlsmpFleetRelease" and sent[1].data.fid == "1", "release sent when garage is full")
free = true
sent = {}

-- return needs the right car
current, vehicles[10].fleetId = 10, "1"
server("rlsmpFleetDo", {act = "return", fid = "2"})
check(#sent == 0, "wrong fleet car is not uploaded")
server("rlsmpFleetDo", {act = "return", fid = "1"})
up = uploaded()
check(up.kind == "fleetReturn" and up.data.fid == "1" and up.data.inv == 10, "return uploaded")

-- already-fleet car cannot be added again
server("rlsmpFleetDo", {act = "add"})
check(#sent == 0, "fleet car can't be added twice")

-- retire: the fleet tag is removed from the inventory record
vehicles[10].fleetId = "1"
dirty = {}
server("rlsmpFleetRetire", {fid = "1"})
check(vehicles[10].fleetId == nil and dirty[1] == 10, "retired car loses its fleet tag")
overhaul_career_garage_inventory.getVehicles = function() return vehicles end

print(string.format("fleet_client_test: %d checks passed", passed))
