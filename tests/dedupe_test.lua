-- Stale car copy cleanup (LuaJIT). Run: luajit tests/dedupe_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local logged = {}
function log(_, _, m) logged[#logged + 1] = m end
local objs, deleted = {}, {}
local function obj(id, model, plate)
  local o = {jbeam = model}
  function o:getID() return id end
  function o:getDynDataFieldbyName() return plate end
  function o:delete() deleted[#deleted + 1] = id for i, x in ipairs(objs) do if x == self then table.remove(objs, i) break end end end
  objs[#objs + 1] = o
  return o
end
local player = 100
be = {getObjectCount = function() return #objs end, getObject = function(_, i) return objs[i + 1] end,
  getPlayerVehicleID = function() return player end,
  getObjectByID = function(_, id) for _, o in ipairs(objs) do if o:getID() == id then return o end end end}
MPVehicleGE = {getVehicles = function() return {["1-1"] = {gameVehicleID = 7, isLocal = false}} end}
local slots = {[1] = {model = "sunburst2", config = {licenseName = "8DHS272"}}, [2] = {model = "etk800", config = {licenseName = "ABC123"}}}
local boundTo = {[1] = 182628, [2] = 50}
overhaul_career_garage_inventory = {getVehicles = function() return slots end, getVehicleIdFromInventoryId = function(i) return boundTo[i] end,
  getInventoryIdFromVehicleId = function(id) for i, v in pairs(boundTo) do if v == id then return i end end end}
local d = require("rlsmp/dedupe")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

obj(182628, "sunburst2", "8DHS272")   -- the real, bound car
obj(170592, "sunburst2", "8DHS272")   -- stale copy
obj(50, "etk800", "ABC123")
obj(7, "sunburst2", "8DHS272")        -- another player's car with the same text: never touched
obj(100, "sunburst2", "8DHS272")      -- the car the player sits in: never touched
d.onUpdate(5)
check(#deleted == 0, "disabled: nothing happens")
d.enable(true)
d.onUpdate(2)
check(#deleted == 0, "first sighting: wait")
d.onUpdate(2) d.onUpdate(2)
check(#deleted == 1 and deleted[1] == 170592, "the stale copy is deleted after 4 s; the bound car, the player's own car and other players' cars stay")
-- RLS in the middle of swapping: the copy disappears on its own before the wait is over
obj(170600, "sunburst2", "8DHS272")
d.onUpdate(2)
for i, o in ipairs(objs) do if o:getID() == 170600 then table.remove(objs, i) break end end
d.onUpdate(2) d.onUpdate(2) d.onUpdate(2)
check(#deleted == 1, "a copy that vanished by itself is not touched")
-- same plate text but a different model: not a copy
obj(300, "pickup", "ABC123")
for _ = 1, 5 do d.onUpdate(2) end
check(#deleted == 1, "different model with the same plate text is left alone")
-- two owned cars with the same model and plate text: both are bound to a slot, neither is a copy
slots[3] = {model = "sunburst2", config = {licenseName = "8DHS272"}}
boundTo[3] = 400
obj(400, "sunburst2", "8DHS272")
for _ = 1, 5 do d.onUpdate(2) end
check(#deleted == 1, "a second owned car with the same plate is never deleted")
print("dedupe_test: " .. passed .. " checks passed")
