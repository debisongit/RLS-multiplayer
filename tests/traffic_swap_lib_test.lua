-- Live swapping pure logic test (LuaJIT). Run: luajit tests/traffic_swap_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local V = require("rlsmp/lib/trafficVariety")
local S = require("rlsmp/lib/trafficSwap")

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function lcg(seed) local s = seed return function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end end

-- settings ---------------------------------------------------------------------------------------------------------
local d = V.sanitize(nil).swap
check(d.enabled == false and d.live == false, "both switches are off by default")
check(d.perMinute == 2 and d.hiddenSeconds == 5 and d.checkSeconds == 2 and d.minRatio == 1.5 and d.maxFailures == 3, "default numbers")
local s = V.sanitize({swap = {enabled = true, live = "yes", perMinute = 999, hiddenSeconds = -4, checkSeconds = 0, minRatio = 0.1, maxFailures = 0}}).swap
check(s.enabled == true and s.live == false, "only a real true turns a switch on")
check(s.perMinute == 12 and s.hiddenSeconds == 1 and s.checkSeconds == 0.5 and s.minRatio == 1 and s.maxFailures == 1, "numbers are clamped")
check(V.sanitize({swap = "junk"}).swap.enabled == false, "junk swap settings: defaults")

-- hidden tracking ----------------------------------------------------------------------------------------------------
local tr = S.newTracker()
check(S.seeHidden(tr, 7, true, 10) == 0, "first moment hidden: 0 s")
check(S.seeHidden(tr, 7, true, 14) == 4, "hidden for 4 s")
check(S.seeHidden(tr, 7, false, 15) == 0, "seen once: the count restarts")
check(S.seeHidden(tr, 7, true, 16) == 0, "...from zero")
S.seeHidden(tr, 8, true, 16)
S.forget(tr, {[8] = true})
check(tr.hidden[7] == nil and tr.hidden[8] == 16, "cars that are gone are forgotten")

-- rate limit ----------------------------------------------------------------------------------------------------------
tr = S.newTracker()
local sw = {perMinute = 2}
check(S.allowed(tr, 100, sw), "nothing yet: allowed")
S.record(tr, 100) S.record(tr, 110)
check(not S.allowed(tr, 120, sw), "two in the last minute: not allowed")
check(S.allowed(tr, 161, sw), "the first one is more than 60 s old: allowed again")
check(not S.allowed(S.newTracker(), 0, {perMinute = 0}), "perMinute 0 never allows")

-- decide --------------------------------------------------------------------------------------------------------------
local types = {pickup = "Truck", van = "Truck", sedan = "Car", hatch = "Car"}
local function infoOf(e) return {type = types[e.model]} end
local pool = {{model = "sedan", config = "a"}, {model = "hatch", config = "b"}, {model = "pickup", config = "c"}, {model = "van", config = "d"}}
local truck = {model = "pickup", config = "x"}

local cfg = V.sanitize({})
local r = S.decide(truck, pool, {}, cfg, infoOf, lcg(1))
check(r == nil, "default weights (everything 1): nothing is ever swapped")

cfg = V.sanitize({night = {Truck = 0}})
local rep, wc, wr = S.decide(truck, pool, {night = true}, cfg, infoOf, lcg(1))
check(rep ~= nil and rep.model ~= "pickup" and types[rep.model] == "Car", "a truck at night (weight 0) is replaced by a car")
check(wc == 0 and wr == 1, "weights reported")
check(S.decide(truck, pool, {night = false}, cfg, infoOf, lcg(1)) == nil, "the same truck by day stays")

cfg = V.sanitize({zones = {highway = {Truck = 3}}})
local sedan = {model = "sedan", config = "q"}
local swaps, wrong = 0, 0
for seed = 1, 60 do
  rep, wc, wr = S.decide(sedan, pool, {zone = "highway"}, cfg, infoOf, lcg(seed))
  if rep then swaps = swaps + 1 if types[rep.model] ~= "Truck" or wr ~= 3 or wc ~= 1 then wrong = wrong + 1 end end
end
check(swaps >= 40 and wrong == 0, "a car on the highway gives way to a truck (weight 3 against 1): " .. swaps .. " of 60 rounds, never to a car")
cfg = V.sanitize({zones = {highway = {Truck = 1.2}}})
local tooSmall = 0
for seed = 1, 60 do if S.decide(sedan, pool, {zone = "highway"}, cfg, infoOf, lcg(seed)) then tooSmall = tooSmall + 1 end end
check(tooSmall == 0, "a gain below minRatio 1.5 is not worth a swap")
cfg = V.sanitize({zones = {highway = {Truck = 1.2}}, swap = {minRatio = 1.1}})
local lowered = 0
for seed = 1, 60 do if S.decide(sedan, pool, {zone = "highway"}, cfg, infoOf, lcg(seed)) then lowered = lowered + 1 end end
check(lowered >= 20, "...unless minRatio is lowered (" .. lowered .. " of 60 rounds swap)")

-- always a different model; nothing to choose from
cfg = V.sanitize({night = {Truck = 0}})
check(S.decide(truck, {{model = "pickup", config = "z"}}, {night = true}, cfg, infoOf, lcg(1)) == nil, "only the same model on offer: no swap")
check(S.decide(truck, {}, {night = true}, cfg, infoOf, lcg(1)) == nil, "empty candidate list: no swap")
check(S.decide(truck, pool, {night = true}, V.sanitize({typeWeights = {Car = 0}, night = {Truck = 0}}), infoOf, lcg(1)) == nil, "everything weighs 0: no swap")

print(string.format("traffic_swap_lib_test: %d checks passed", passed))
