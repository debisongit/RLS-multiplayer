-- Mod car price estimator test (LuaJIT). Run: luajit tests/mod_price_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local P = require("rlsmp/lib/modPrice")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function between(v, lo, hi, m) check(v and v >= lo and v <= hi, string.format("%s (got %s, want %d..%d)", m, tostring(v), lo, hi)) end

-- anchors from the owner
between(P.estimate({hp = 100, weight = 1500, year = 1990, drivetrain = "FWD", words = "car hatchback"}), 3000, 6000, "100 hp old hatchback")
between(P.estimate({hp = 300, weight = 1500, year = 2015, drivetrain = "RWD", words = "car sedan"}), 30000, 45000, "300 hp sedan")
between(P.estimate({hp = 600, weight = 1500, year = 2018, drivetrain = "AWD", words = "car coupe"}), 120000, 200000, "600 hp sports car")
between(P.estimate({hp = 1100, weight = 1400, year = 2022, drivetrain = "AWD", words = "car coupe"}), 1000000, 4000000, "hypercar")
between(P.estimate({hp = 300, weight = 1500, year = 2015, topSpeed = 80}), 25000, 60000, "top speed in m/s works")
between(P.estimate({hp = 450, weight = 8000, words = "semi tractor"}), 40000, 200000, "heavy truck")
check(P.estimate({hp = 300, weight = 900, year = 2015}) > P.estimate({hp = 300, weight = 2200, year = 2015}), "lighter costs more")
check(P.estimate({hp = 200}) < P.estimate({hp = 400}), "more power costs more")

-- missing or odd data -> nil (the game's price)
check(P.estimate(nil) == nil and P.estimate({}) == nil and P.estimate({hp = 0}) == nil, "no power: nil")
check(P.estimate({hp = 0/0}) == nil and P.estimate({hp = 1e9}) == nil, "nan and absurd power: nil")
check(P.estimate({hp = "x"}) == nil, "text power: nil")
check(P.estimate({hp = 200, weight = -5}) ~= nil, "a bad weight is ignored")

-- decide
local cfg = P.sanitize({})
check(cfg.enabled and cfg.max == 2000000 and cfg.min == 800 and cfg.tolerance == 0.35, "defaults")
local spec = {hp = 300, weight = 1500, year = 2015}
local est = P.estimate(spec)
local used, e, why = P.decide(cfg, {model = "m", config = "c"}, spec, est * 1.2)
check(why == "author" and used == est * 1.2, "inside +-35 percent: the author's value stays")
used, e, why = P.decide(cfg, {model = "m", config = "c"}, spec, est * 1.5)
check(why == "estimate" and used == est, "outside: the estimate")
used, e, why = P.decide(cfg, {model = "m", config = "c"}, spec, 12)
check(why == "estimate" and used == est, "absurdly cheap: the estimate")
used, e, why = P.decide(cfg, {model = "m", config = "c"}, spec, 9e9)
check(why == "estimate" and used == est, "absurdly expensive: the estimate")
used, e, why = P.decide(cfg, {model = "m", config = "c"}, spec, nil)
check(why == "estimate" and used == est, "no author value: the estimate")
used, e, why = P.decide(cfg, {model = "m", config = "c"}, {}, 5000)
check(used == nil and why == "game", "no specs: leave the game's price")
used = P.decide(P.sanitize({max = 100000}), {model = "m"}, {hp = 1200, weight = 1400}, 1)
check(used == 100000, "cap")
used = P.decide(cfg, {model = "m"}, {hp = 11, weight = 100}, 1)
check(used >= 800, "floor 800 even for a tiny car")
local ov = P.sanitize({overrides = {m = 50000, ["m/sport"] = 70000, bad = "x", huge = 1e12}})
used, e, why = P.decide(ov, {model = "m", config = "sport"}, spec, 1)
check(used == 70000 and why == "override", "model/config override wins")
used = P.decide(ov, {model = "m", config = "other"}, spec, 1)
check(used == 50000, "model override")
check(ov.overrides.bad == nil and ov.overrides.huge == nil, "bad overrides are dropped")

-- sanitize
local s = P.sanitize({enabled = false, max = "abc", min = -5, tolerance = 99, models = {"a", 5, string.rep("x", 100)}})
check(s.enabled == false and s.max == 2000000 and s.min == 100 and s.tolerance == 5, "sanitize clamps")
check(s.models.a and not s.models[5], "model list sanitized")
check(P.sanitize("junk").enabled == true and P.sanitize({}).sell == true and P.sanitize({sell = false}).sell == false, "junk settings = defaults; sell on by default")

-- who is a mod
check(P.isModded({listed = true}), "listed model")
check(not P.isModded({listed = true, official = true}), "official wins over the list")
check(P.isModded({path = "C:/Users/x/AppData/Local/BeamNG.drive/0.37/mods/multiplayer/cars.zip"}), "downloaded from a server")
check(not P.isModded({path = "C:/Program Files/BeamNG.drive/content/vehicles/etk800.zip"}), "game file")
check(not P.isModded({}) and not P.isModded(nil), "unknown = not a mod")

-- rescale keeps RLS's curve
local v = {catalogValue = 1000000, bookValue = 400000, preDamageValue = 400000, partsValueFloor = 300000}
P.rescale(v, 40000, 800)
check(math.abs(v.bookValue - 16000) < 1e-6 and v.catalogValue == 40000 and v.catalogSource == "modPrice", "ratio applied")
local w = {catalogValue = 1000, bookValue = 500}
P.rescale(w, 100, 800)
check(w.bookValue == 800, "listing floor")
check(P.rescale(nil, 5) == nil, "no record: nothing")

print("mod_price_lib_test: " .. passed .. " checks passed")
