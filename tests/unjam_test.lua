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
print("unjam_test: " .. passed .. " checks passed")
