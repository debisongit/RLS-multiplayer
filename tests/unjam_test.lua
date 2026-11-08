-- Stuck traffic recycling (LuaJIT). Run: luajit tests/unjam_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local logged = {}
function log(_, _, m) logged[#logged + 1] = m end
local U = require("rlsmp/lib/unjam")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure tracker
local t = U.new()
check(U.seen(t, 1, 0, 0, 0, 0) == 0, "starts at zero")
check(U.seen(t, 1, 0.5, 0, 0, 10) == 10, "stays put, timer keeps running")
check(U.seen(t, 1, 0, 0, 3, 11) == 0, "moving resets the timer")
check(U.seen(t, 1, 50, 0, 0, 12) == 0, "far from the anchor resets the timer")
local hidden = {{id = 1, stuck = 140, hidden = true}, {id = 2, stuck = 150, hidden = false}, {id = 3, stuck = 121, hidden = true}, {id = 4, stuck = 10, hidden = true}}
check(U.pick(t, hidden, 100) == 1, "longest stuck HIDDEN car goes first, visible ones are skipped")
check(U.pick(t, hidden, 102) == nil, "one by one: not again within the gap")
check(U.pick(t, hidden, 106) == 1 or U.pick(t, hidden, 106) == nil, "later again")

-- extension with fakes
local state = {}
local function car(id, x, speed, extra)
  local v = {isAi = true, role = {name = "standard"}, state = "active", pos = {x = x, y = 0}, speed = speed, id = id, queuedFuncs = {horn = true}, camVisible = false}
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end
local cars = {[1] = car(1, 0, 0), [2] = car(2, 100, 0, {camVisible = true}), [3] = car(3, 200, 12), [4] = car(4, 300, 0, {role = {name = "police"}})}
getObjectByID = function() return nil end
gameplay_traffic = {getTrafficData = function() return cars end}
be = {getPlayerVehicleID = function() return 99 end, getObjectActive = function() return true end}
package.loaded["rlsmp/personalities"] = {context = function() return {remote = {}, parked = {}, playerId = 99} end}
local stayNear = {}
local dist = {}
package.loaded["rlsmp/bubble"] = {stayFor = function(v) return stayNear[v.id] == true end, minPlayerDistance = function(v) return dist[v.id] or 1000 end}
local P = require("rlsmp/lib/personality")
package.loaded["rlsmp/lib/personality"] = P
local unjam = require("rlsmp/unjam")
unjam.onUpdate(1)
check(cars[1].state == "active", "disabled: nothing happens")
unjam.enable(true)
for _ = 1, 119 do unjam.onUpdate(1) end
check(cars[1].state == "active", "not yet 120 s (the default)")
for _ = 1, 3 do unjam.onUpdate(1) end
check(cars[1].state == "fadeOut" and next(cars[1].queuedFuncs) == nil, "stuck hidden car is recycled (horn timers cleared)")
check(cars[2].state == "active", "a car a player can see is left alone")
check(cars[3].state == "active", "a moving car is left alone")
check(cars[4].state == "active", "police are left alone")
cars[2].camVisible = false
stayNear[2] = true
for _ = 1, 8 do unjam.onUpdate(1) end
check(cars[2].state == "active", "near another player: stays")
stayNear[2] = false
for _ = 1, 3 do unjam.onUpdate(1) end
check(cars[2].state == "fadeOut", "recycled once nobody can see it, and one at a time")
-- far from everyone is required: a stuck car 200 m from a player is left alone, 400 m or more is recycled
local far = {[5] = car(5, 400, 0)}
cars = {[5] = far[5]}
gameplay_traffic = {getTrafficData = function() return cars end}
dist[5] = 200
for _ = 1, 130 do unjam.onUpdate(1) end
check(cars[5].state == "active", "stuck but only 200 m from a player: left alone")
dist[5] = 400
for _ = 1, 3 do unjam.onUpdate(1) end
check(cars[5].state == "fadeOut", "stuck and 400 m from everyone: recycled")
-- the server switch and numbers
cars = {[6] = car(6, 900, 0)}
unjam.configure({enabled = false, seconds = 40, distance = 500})
dist[6] = 800
for _ = 1, 60 do unjam.onUpdate(1) end
check(cars[6].state == "active", "server switch off: nothing is recycled")
unjam.configure({enabled = true, seconds = 40, distance = 500})
for _ = 1, 45 do unjam.onUpdate(1) end
check(cars[6].state == "fadeOut", "server numbers (40 s, 500 m) are used")
-- crashed cars near players (traffic.unjam.crashed)
local hp = 1000
os.clockhp = function() return hp end
local viewed, d7 = {}, {}
package.loaded["rlsmp/bubble"] = {stayFor = function() return false end, minPlayerDistance = function(v) return d7[v.id] or 10 end,
  viewReason = function(v) return viewed[v.id] end}
unjam.configure({enabled = true, seconds = 120, distance = 400, crashed = true, crashedSeconds = 60, inViewSeconds = 120})
cars = {[7] = car(7, 50, 0, {activeData = {tCrash = hp}}), [8] = car(8, 60, 0, {activeData = {tCrash = hp}, role = {name = "police"}}),
  [9] = car(9, 70, 5, {activeData = {tCrash = hp}})}
gameplay_traffic = {getTrafficData = function() return cars end}
viewed[7], viewed[9] = "inView", "inView"
local function run(n) for _ = 1, n do hp = hp + 1 unjam.onUpdate(1) end end
run(50)
check(cars[7].state == "active", "crashed 50 s in view: stays")
viewed[7] = nil
run(15)
check(cars[7].state == "fadeOut", "crashed, nobody sees it: removed after crashedSeconds")
check(logged[#logged]:find("unjam: crashed car id=7 dist=10 seen=false removed after", 1, true), "crash log line")
check(cars[8].state == "active", "crashed police car is left alone")
check(cars[9].state == "active", "damaged car that is still driving stays")
cars[9].speed = 0
viewed[9] = "inView"
run(125)
check(cars[9].state == "active", "in view but within 40 m of a player: stays")
d7[9] = 80
run(10)
check(cars[9].state == "fadeOut", "in view after inViewSeconds and 40 m or more away: faded out")
cars = {[10] = car(10, 90, 0, {activeData = {tCrash = hp - 500}})}
unjam.configure({crashed = false})
run(15)
check(cars[10].state == "active", "crashed rule off: nothing")
print("unjam_test: " .. passed .. " checks passed")
