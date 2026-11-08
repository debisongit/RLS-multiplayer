-- Stolen car restore, client (LuaJIT) with fake game globals. Run: luajit tests/recall_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logs = {}
function log(level, tag, msg) logs[#logs + 1] = level .. " " .. tostring(msg) end
function setExtensionUnloadMode() end
local sent, handlers, toasts = {}, {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
guihooks = {trigger = function(_, t) toasts[#toasts + 1] = t.msg end}
vec3 = function(x, y, z) if type(x) == "table" then return x end return {x = x, y = y, z = z} end
quat = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end
quatFromDir = function() return {x = 0, y = 0, z = 0, w = 1} end
createVehiclePaint = function(c, m) return {c = c, m = m} end

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure helpers --------------------------------------------------------------------------------
local R = require("rlsmp/lib/recall")
local me = {x = 0, y = 0, z = 10}
local free = function() return false end
local w = R.choose({x = 100, y = 50, z = 12, rot = {x = 0, y = 0, z = 1, w = 0}}, me, {}, free, false)
check(w.how == "last position" and w.x == 100 and w.rot.z == 1, "free last place is used")
w = R.choose({x = 100, y = 50, z = 12}, me, {}, function(x, y) return math.abs(x - 100) < 1 and math.abs(y - 50) < 1 end, false)
check(w.how == "last position" and (w.x ~= 100 or w.y ~= 50), "a taken place shifts to a free neighbour")
w = R.choose({x = 100, y = 50, z = 12}, me, {}, function() return true end, false)
check(w.how == "player side", "everything taken: beside the player")
w = R.choose({x = 9e6, y = 0, z = 0}, me, {{x = 800, y = 0, z = 5, name = "Yard"}, {x = 90000, y = 0, z = 5}}, free, false)
check(w.how == "drop spot" and w.x == 800, "far or invalid place: nearest drop spot")
w = R.choose({x = 9000, y = 0, z = 0}, me, {{x = 90000, y = 0, z = 5}}, free, false)
check(w.how == "player side", "far place and no near spot: beside the player")
w = R.choose({x = 0 / 0, y = 0, z = 0}, me, {}, free, false)
check(w.how == "player side", "nan place: beside the player")
w = R.choose({x = 100, y = 50, z = 12}, me, {}, free, true)
check(w.how == "player side (manual)" and math.abs(w.x - R.SIDE) < 1e-9, "button: beside the player")
check(R.dueReport(nil, me, 5, 30, 3, 120) and not R.dueReport({x = 0, y = 0, z = 10, t = 0}, me, 20, 30, 3, 120), "report: first now, not before the interval")
check(not R.dueReport({x = 0, y = 0, z = 10, t = 0}, me, 40, 30, 3, 120) and R.dueReport({x = 0, y = 0, z = 10, t = 0}, me, 130, 30, 3, 120)
  and R.dueReport({x = 20, y = 0, z = 10, t = 0}, me, 40, 30, 3, 120), "report: only when moved, or after the long wait")

-- fake world ---------------------------------------------------------------------------------
local objects, nextId, spawns = {}, 100, {}
local function mkObj(id, jbeam, x, y)
  local o = {id = id, jbeam = jbeam, pos = {x = x, y = y, z = 0}, dyn = {}}
  function o:getID() return self.id end
  function o:getPosition() return self.pos end
  function o:getDirectionVector() return {x = 0, y = 1, z = 0} end
  function o:getDirectionVectorUp() return {x = 0, y = 0, z = 1} end
  function o:getMetallicPaintData() return {} end
  function o:getDynDataFieldbyName(k) return self.dyn[k] end
  function o:setDynDataFieldbyName(k, _, v) self.dyn[k] = v end
  function o:delete() objects[self.id] = nil end
  objects[id] = o
  return o
end
mkObj(1, "unicycle", 0, 0)
local order = {}
be = {getObjectByID = function(_, id) return objects[id] end, getPlayerVehicleID = function() return 1 end,
  getObjectCount = function() order = {} for id in pairs(objects) do order[#order + 1] = id end table.sort(order) return #order end,
  getObject = function(_, i) return objects[order[i + 1]] end}
core_vehicles = {spawnNewVehicle = function(model, opts)
  nextId = nextId + 1
  spawns[#spawns + 1] = {model = model, opts = opts}
  local o = mkObj(nextId, model, opts.pos.x, opts.pos.y)
  o.dyn.licenseText = opts.licenseText
  return o
end}
gameplay_walk = {removeVehicleFromBlacklist = function() end}
local net = require("rlsmp/lib/net")
net.init()
local T = require("rlsmp/lib/theft")
local theft = require("rlsmp/theft")
theft.onExtensionLoaded()
rlsmp_theft = theft
local recall = require("rlsmp/recall")
recall.onExtensionLoaded()
local function server(name, t) handlers[name](json.encode(t)) end
local function step(secs) for _ = 1, secs do recall.onUpdate(1) end end
local function logged(text) for _, l in ipairs(logs) do if l:find(text, 1, true) then return true end end return false end

-- spawnStolen: the safe path (never parked, guard exception, plate and paints kept)
local look = {{x = 1, y = 0, z = 0, w = 1, m = {metallic = 0.4}}, {x = 0, y = 1, z = 0, w = 1}, {x = 0, y = 0, z = 1, w = 1}}
local spec = {plate = "AB 1", model = "covet", config = "vehicles/covet/base.pc", look = look, value = 5000, year = 1990, x = 100, y = 50, z = 3,
  rot = {x = 0, y = 0, z = 0, w = 1}}
local veh = theft.spawnStolen(spec, {x = 7, y = 8, z = 9}, {x = 0, y = 0, z = 0.7, w = 0.7})
local so = spawns[#spawns].opts
check(veh and so.licenseText == "AB 1" and so.config == "vehicles/covet/base.pc" and so.paint.m.metallic == 0.4 and so.paint3.c.z == 1 and so.rot.z == 0.7, "spawn gets plate, config, paints, rotation")
check(veh.dyn.isParked == "false" and veh.ignoreParking == true and T.isConverted(veh:getID()), "never parked, guard exception")
check(theft.liveByPlate("ab 1") == veh:getID(), "found by plate")
local places = theft.stolenPlaces()
check(#places == 1 and places[1].plate == "AB 1" and places[1].x == 7, "place list for the server")
veh:delete()
check(theft.liveByPlate("AB 1") == nil, "gone after delete")

-- rejoin: nothing before the career is enabled, then the car comes back once
spawns = {}
server("rlsmpStolenRestore", {auto = true, spots = {}, cars = {spec}})
step(30)
check(#spawns == 0, "not enabled yet: nothing is created")
recall.enable(true)
step(5)
check(#spawns == 0, "waits for the world to settle")
step(5)
check(#spawns == 1 and spawns[1].opts.pos.x == 100 and spawns[1].opts.pos.y == 50, "restored at the last place")
check(logged("stolen car restored: AB 1 covet"), "logged")
step(60)
check(#spawns == 1, "one car per record: no second spawn")
local places2 = theft.stolenPlaces()
check(#places2 == 1, "the restored car is a stolen car again")

-- the same message again while the car lives: nothing new
server("rlsmpStolenRestore", {auto = true, spots = {}, cars = {spec}})
step(20)
check(#spawns == 1, "already here: not duplicated")

-- a far place falls back to the drop spot; a failing spawn is tried a few times only
for id in pairs(objects) do if id > 100 then objects[id] = nil end end
spawns = {}
local fail = true
local real = core_vehicles.spawnNewVehicle
core_vehicles.spawnNewVehicle = function(...) if fail then error("boom") end return real(...) end
local far = {plate = "FAR 1", model = "covet", x = 900000, y = 0, z = 0}
server("rlsmpStolenRestore", {auto = true, spots = {{x = 200, y = 300, z = 4, name = "Yard"}}, cars = {far}})
step(10)
check(next(recall._queue()) ~= nil, "failed try is kept")
step(120)
check(next(recall._queue()) == nil and #spawns == 0 and logged("giving up"), "gives up after a few tries")
fail = false
server("rlsmpStolenRestore", {auto = true, spots = {{x = 200, y = 300, z = 4, name = "Yard"}}, cars = {far}})
step(9)
check(#spawns == 1 and spawns[1].opts.pos.x ~= nil and math.abs(spawns[1].opts.pos.x - 200) <= 8 and logged("drop spot"), "far place: at the nearest drop spot")

-- the button
sent = {}
check(recall.bringHere("far 1") == true, "button asks")
local ask = sent[#sent]
check(ask.name == "rlsmpStolenRecall" and ask.data.plate == "far 1", "ask carries the plate")
server("rlsmpStolenRecallResult", {ok = false, err = "Wait 30 s before calling a car again."})
check(toasts[#toasts]:find("Wait 30"), "refusal shown")
spawns = {}
server("rlsmpStolenRestore", {auto = false, cars = {far}})
step(1)
check(#spawns == 1 and math.abs(spawns[1].opts.pos.x - R.SIDE) < 1e-6, "button: beside the player")
check(#theft.stolenPlaces() == 1, "the old car was removed first: one live car")
step(31)
local posted = false
for _, s in ipairs(sent) do if s.name == "rlsmpStolenPos" then posted = true end end
check(posted, "place report sent")

-- leaving clears the queue
recall.enable(false)
check(next(recall._queue()) == nil, "disabled: queue cleared")
print("recall_client_test: " .. passed .. " checks passed")
