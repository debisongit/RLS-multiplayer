-- Traffic respawn range and delay (LuaJIT). Run: luajit tests/range_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function setExtensionUnloadMode() end
local logged = {}
function log(_, _, m) logged[#logged + 1] = m end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- pure logic
local R = require("rlsmp/lib/range")
local d = R.sanitize(nil)
check(d.respawnRange == 1 and d.respawnDelay == 0 and d.respawnDistance == 4000, "defaults: range 1, no delay, recycle at 4000 m")
check(d.spawnMinDistance == 250 and d.spawnMaxDistance == 4000, "defaults: new traffic is placed 250 to 4000 m from the player")
check(R.sanitize({spawnMaxDistance = 99999}).spawnMaxDistance == 6000 and R.sanitize({spawnMaxDistance = 0}).spawnMaxDistance == 0 and R.sanitize({spawnMinDistance = 1}).spawnMinDistance == 120, "spawn ring clamped (max 0 = game)")
check(R.sanitize({respawnDistance = 0}).respawnDistance == 0 and R.sanitize({respawnDistance = 99999}).respawnDistance == 6000 and R.sanitize({respawnDistance = -3}).respawnDistance == 0, "distance 0 (game original) to 6000")
check(R.sanitize({respawnDistance = "x"}).respawnDistance == 4000, "distance garbage falls back to 4000")
check(d.unjam.enabled == true and d.unjam.seconds == 120 and d.unjam.distance == 400, "unjam defaults: 120 s, 400 m")
check(R.sanitize({respawnRange = 9}).respawnRange == 3, "range capped at 3")
check(R.sanitize({respawnRange = 0}).respawnRange == 0.5, "range never below 0.5")
check(R.sanitize({respawnRange = "x"}).respawnRange == 1, "garbage falls back to the default")
check(R.sanitize({respawnDelay = -5}).respawnDelay == 0 and R.sanitize({respawnDelay = 9999}).respawnDelay == 600, "delay clamped")
check(d.unjam.crashed == true and d.unjam.crashedSeconds == 60 and d.unjam.inViewSeconds == 120, "crashed defaults")
check(R.sanitize({unjam = {crashed = false, crashedSeconds = 1, inViewSeconds = 9999}}).unjam.crashed == false and R.sanitize({unjam = {crashedSeconds = 1}}).unjam.crashedSeconds == 15, "crashed rule sanitized")
check(R.sanitize({unjam = {enabled = false, seconds = 1, distance = 1}}).unjam.seconds == 30, "unjam seconds clamped")
check(R.scale(100, 2) == 200 and R.scale(100, 1) == 100 and R.scale(1e6, 3) == 1e6, "scale: radius times range, the 1e6 placeholder stays")
check(R.effective(150, 1, 4000) == 4000 and R.effective(150, 1, 0) == 150 and R.effective(150, 2, 0) == 300 and R.effective(5000, 1, 4000) == 5000 and R.effective(300, 2, 400) == 600 and R.effective(1e6, 1, 4000) == 1e6, "effective: max of scaled game radius and the distance, the 1e6 placeholder stays")
check(R.holdByDelay(10, 15, 20) and not R.holdByDelay(10, 31, 20) and not R.holdByDelay(10, 15, 0) and not R.holdByDelay(nil, 15, 20), "delay hold")
check(R.describe(d, d) == nil, "no change, no text")
check(R.describe(d, R.sanitize({respawnRange = 2})):find("respawnRange 1 %-> 2"), "change text has before and after")

-- bubble wrappers on a fake traffic class
MPCoreNetwork = {isMPSession = function() return true end}
MPVehicleGE = {getVehicles = function() return {} end}
map = {objects = {}}
local ticks, respawned = 0, 0
local class = {}
class.__index = class
class.updateActiveRadius = function(self) ticks = ticks + 1 if self.fresh then self.respawn.finalRadius = 100 end end
class.tryRespawn = function() respawned = respawned + 1 end
local car = setmetatable({pos = {x = 0, y = 0, z = 0}, enableRespawn = true, respawn = {finalRadius = 100}, focusDist = 500, respawnCount = 1, role = {name = "standard"}, fresh = true}, class)
local cop = setmetatable({pos = {x = 0, y = 0, z = 0}, enableRespawn = true, respawn = {finalRadius = 100}, focusDist = 500, respawnCount = 1, role = {name = "police"}, fresh = true}, class)
gameplay_traffic = {getTrafficData = function() return {[1] = car, [2] = cop} end, getTrafficVars = function() return {} end}
local b = require("rlsmp/bubble")
b.install()
b.enable(true)
car:updateActiveRadius()
check(car.respawn.finalRadius == 4000, "default: a car is recycled only farther than 4000 m")
check(car.rlsmpGameRadius == 100, "the game's own radius is remembered")
cop:updateActiveRadius()
check(cop.respawn.finalRadius == 100, "police radius untouched by the distance")
b.setRange({respawnDistance = 0})
car:updateActiveRadius()
check(car.respawn.finalRadius == 100, "distance 0, range 1: the radius is the game's own")
b.setRange({respawnDistance = 150})
car:updateActiveRadius()
check(car.respawn.finalRadius == 150, "distance 150 above the game radius 100")
b.setRange({respawnDistance = 50})
car.fresh = true
car:updateActiveRadius()
check(car.respawn.finalRadius == 100, "distance below the game radius: the game radius stays")
b.setRange({respawnDistance = 0})
car:updateActiveRadius()
b.setRange({respawnRange = 2, respawnDistance = 0})
check(logged[#logged]:find("range: changed respawnRange 1 %-> 2"), "range: line with before and after")
car:updateActiveRadius()
check(car.respawn.finalRadius == 200, "range 2: the game's radius times 2")
car.fresh = false
car:updateActiveRadius() car:updateActiveRadius()
check(car.respawn.finalRadius == 200, "game returned early (no recompute): not scaled twice")
car.fresh = true
car:updateActiveRadius()
check(car.respawn.finalRadius == 200, "recomputed every tick: still 2x, not compounding")
cop:updateActiveRadius()
check(cop.respawn.finalRadius == 100, "police radius untouched")
b.setRange({respawnRange = 1, respawnDistance = 0})
car:updateActiveRadius()
check(car.respawn.finalRadius == 100, "back to 1: the game's own again")

-- respawn delay: a car the game placed less than `delay` seconds ago is not recycled
b.setRange({respawnDelay = 30, respawnDistance = 0})
b.onUpdate(1)                    -- stamps both cars (clock 1)
car:tryRespawn()
check(respawned == 0, "inside the minimum stay: not recycled")
for _ = 1, 31 do b.onUpdate(1) end
car:tryRespawn()
check(respawned == 1, "after the delay: the game decides")
car.respawnCount = 2             -- the game placed it again
b.onUpdate(1)
car:tryRespawn()
check(respawned == 1, "placed again: the delay starts again")
b.setRange({})
car:tryRespawn()
check(respawned == 2, "delay 0: the game's original")
print("range_test: " .. passed .. " checks passed")
