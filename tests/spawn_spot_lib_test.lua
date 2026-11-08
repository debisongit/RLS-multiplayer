-- Spawn spot rules (LuaJIT): where a cop or a traffic car may appear. Run: luajit tests/spawn_spot_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local S = require("rlsmp/lib/spawnSpot")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local P, D = {x = 0, y = 0, z = 0}, {x = 0, y = 1}
-- the player looks along +y: +x is the RIGHT hand side
local dist, along, side = S.rel(P, D, {x = 300, y = 400})
check(math.abs(dist - 500) < 1e-9 and math.abs(along - 400) < 1e-9 and side < 0 and math.abs(side + 300) < 1e-9, "a point at +x is on the RIGHT (side < 0), 400 m ahead")
_, _, side = S.rel(P, D, {x = -300, y = -400})
check(side > 0, "a point at -x is on the left (side > 0)")
local _, a2, s2 = S.rel(P, {x = 1, y = 0}, {x = 100, y = -50})   -- looking along +x: the right hand is -y
check(a2 == 100 and s2 < 0, "heading +x: a point at -y is on the right")

local ctx = {player = P, dir = D, minDist = 1000, corridor = 40, others = {}}
check(S.reject({x = 500, y = 500, z = 0}, ctx) == "near", "closer than 1000 m: refused")
check(S.reject({x = 1200, y = 0, z = 0}, ctx) == nil, "1200 m to the right, off the line: allowed")
check(S.reject({x = 10, y = 1500, z = 0}, ctx) == "line", "1500 m straight ahead: refused (literally in front)")
check(S.reject({x = -10, y = -1500, z = 0}, ctx) == "line", "1500 m straight behind: refused")
ctx.others = {{x = 1200, y = 300, z = 0}}
check(S.reject({x = 1200, y = 0, z = 0}, ctx) == "near", "within 1000 m of ANOTHER player: refused")
ctx.others = {}
ctx.road = "main"
check(S.reject({x = 1200, y = 0, z = 0, road = "main"}, ctx) == "sameRoad", "the player's own road: refused")
check(S.reject({x = 1200, y = 0, z = 0, road = "side"}, ctx) == nil, "another road: allowed")
ctx.road = nil
-- the camera cone: a spot 600 m in front of the camera is seen; the same spot behind it is not
ctx.cam, ctx.fwd, ctx.minDist, ctx.corridor = {x = 0, y = 0, z = 0}, {x = 0, y = 1, z = 0}, 200, 0
check(S.reject({x = 20, y = 300, z = 0}, ctx) == "view", "250..500 m in the camera cone: refused")
check(S.reject({x = 20, y = -300, z = 0}, ctx) == nil, "the same distance behind the camera: allowed")
check(S.reject({x = 50, y = 50, z = 0}, {player = P, minDist = 0}) == "view", "within 120 m of the player: never (the view gate)")
check(S.reject({x = 1, y = 1}, {}) == "noPlayer", "no player: refused")

-- pick: the right side first, then the nearer one
local ctx2 = {player = P, dir = D, minDist = 1000, corridor = 40, others = {}}
local best, why = S.pick({{x = -1100, y = 200, z = 0}, {x = 1500, y = 200, z = 0}, {x = 1100, y = 300, z = 0}, {x = 300, y = 0, z = 0}}, ctx2, true)
check(best and best.x == 1100 and best.side < 0 and why.near == 1, "right side preferred, nearer of the right ones; the near one is counted in the reasons")
best = S.pick({{x = -1100, y = 200, z = 0}, {x = 1500, y = 200, z = 0}}, ctx2, false)
check(best.x == -1100, "no right preference: the nearer one")
best = S.pick({{x = -1100, y = 200, z = 0}}, ctx2, true)
check(best and best.x == -1100, "right preferred but only a left spot exists: the left spot is used")
check(S.pick({{x = 10, y = 1200, z = 0}}, ctx2, true) == nil, "only a spot in front: nothing")

-- the traffic ring
local lo, hi = S.ring(250, 4000)
check(lo == 250 and hi == 4000, "ring 250..4000")
lo, hi = S.ring(10, 4000)
check(lo == 120, "never below 120 m")
lo, hi = S.ring(250, 0)
check(lo == 0 and hi == 0, "max 0 = the game's own placement")
lo, hi = S.ring(250, 9000)
check(hi == 6000, "max capped at 6000")
check(S.ringDistance(250, 4000, 0) == 250 and S.ringDistance(250, 4000, 1) == 4000 and S.ringDistance(250, 4000, 0.5) == 2125, "evenly spread over the distance")

print(string.format("spawn_spot_lib_test: %d checks passed", passed))
