-- Plate reading rules (LuaJIT). Run: luajit tests/plate_read_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local R = require("rlsmp/lib/plateRead")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function seq(...) local v, i = {...}, 0 return function() i = i + 1 return v[i] or 0 end end

-- config
local cfg = R.sanitizeConfig({enabled = true})
check(cfg.enabled and cfg.rangeMeters == 15 and cfg.maxSpeedKmh == 50 and cfg.minSeconds == 3 and cfg.maxSeconds == 6, "defaults")
check(cfg.skipChance == 0.2 and cfg.retriggerSeconds == 120 and cfg.offenseScore == 400, "defaults 2")
local bad = R.sanitizeConfig({rangeMeters = "x", skipChance = 7, minSeconds = 5, maxSeconds = 2, readChance = 0 / 0})
check(bad.enabled == false and bad.rangeMeters == 15 and bad.skipChance == 1 and bad.maxSeconds == 5 and bad.readChance == 0.35, "bad values clamped")
check(R.sanitizeConfig(nil).enabled == false, "no body -> off")

-- plates, colours, mask
check(R.cleanPlate("  ab 12   cd ") == "AB 12 CD", "plate trimmed, upper, spaces collapsed")
check(R.cleanPlate("") == nil and R.cleanPlate("   ") == nil and R.cleanPlate(nil) == nil, "empty plate -> nil")
check(R.cleanPlate(string.rep("A", 17)) == nil and R.cleanPlate("A|B") == nil, "too long / separator refused")
check(R.colorName(0.9, 0.05, 0.05) == "red" and R.colorName(0.05, 0.1, 0.8) == "blue" and R.colorName(0.1, 0.7, 0.1) == "green", "hues")
check(R.colorName(0.95, 0.95, 0.95) == "white" and R.colorName(0.02, 0.02, 0.02) == "black" and R.colorName(0.65, 0.65, 0.66) == "silver"
  and R.colorName(0.4, 0.4, 0.4) == "grey", "neutrals")
check(R.colorName(0.95, 0.85, 0.1) == "yellow" and R.colorName(0.95, 0.5, 0.1) == "orange" and R.colorName(0.45, 0.25, 0.1) == "brown", "warm")
check(R.colorName(nil, 1, 1) == nil, "no colour")
check(math.abs(R.srgbFromLinear(0.214) - 0.5) < 0.02 and R.srgbFromLinear(-1) == 0 and R.srgbFromLinear(3) == 1, "linear -> sRGB")
check(R.mask("7AB123", 0) == "______" and R.mask("7AB123", 0.5) == "7AB___" and R.mask("7AB123", 1) == "7AB123", "mask")
check(R.mask("AB 12", 0.4) == "AB __", "mask keeps spaces")

-- nearest reader: dist is SQUARED in RLS (validTargets)
local function cop(dsq, visible, extra)
  local v = {isAi = true, role = {name = "police", state = "none", flags = {}, validTargets = {[1] = {dist = dsq, visible = visible}}}}
  for k, x in pairs(extra or {}) do v.role[k] = x end
  return v
end
local traffic = {[1] = {isAi = false}, [10] = cop(14 * 14, true), [11] = cop(10 * 10, false), [12] = cop(16 * 16, true)}
local id, d = R.nearestReader(traffic, 1, 225)
check(id == 10 and d == 196, "visible unit at 14 m reads, hidden unit at 10 m does not, 16 m is out of range")
traffic[13] = cop(5 * 5, true, {state = "disabled"})
traffic[14] = cop(6 * 6, true, {flags = {pursuit = true}})
check(R.nearestReader(traffic, 1, 225) == 10, "disabled / chasing units skipped")
traffic[15] = cop(4 * 4, true)
check(R.nearestReader(traffic, 1, 225, function(i) return i ~= 15 end) == 10, "inactive object skipped")
check(R.nearestReader(traffic, 1, 225) == 15, "nearest wins")
check(R.nearestReader({[1] = {}}, 1, 225) == nil, "no police")

-- read timer
local c = R.sanitizeConfig({enabled = true, readChance = 1, minSeconds = 3, maxSeconds = 6, copCooldownSeconds = 300, encounterSeconds = 60})
local r = R.newReader()
local st, x = R.update(r, 0, 0.5, {copId = 10}, c, seq(0, 0.5))   -- encounter roll 0 (< 1: reads), need 3 + 0.5*3 = 4.5 s
check(st == "reading" and x == 0 and r.need == 4.5, "read starts, 4.5 s")
local t = 0
for _ = 1, 8 do t = t + 0.5 st, x = R.update(r, t, 0.5, {copId = 10}, c) end
check(st == "reading" and math.abs(x - 4 / 4.5) < 1e-9, "progress after 4 s")
t = t + 0.5
st, x = R.update(r, t, 0.5, {copId = 10}, c)
check(st == "done" and x == 10, "done after 4.5 s")
check(R.update(r, t + 0.5, 0.5, {copId = 10}, c) == nil, "that unit leaves you alone afterwards")
check(R.update(r, t + 301, 0.5, {copId = 10}, c, seq(0, 0)) == "reading", "...until its cooldown ran out")

-- reset when leaving range / speeding (cand = nil)
r = R.newReader()
R.update(r, 0, 0.5, {copId = 20}, c, seq(0, 0))
R.update(r, 0.5, 0.5, {copId = 20}, c)
check(R.update(r, 1, 0.5, nil, c) == "reset" and r.cop == nil and r.got == 0, "out of range resets")
check(R.update(r, 1.5, 0.5, nil, c) == nil, "nothing after the reset")
st, x = R.update(r, 2, 0.5, {copId = 20}, c, seq(0.99))
check(st == "reading" and x == 0, "back in range starts from zero (same encounter, no new roll)")
st = R.update(r, 2.5, 0.5, {copId = 21}, c, seq(0, 0))
check(st == "reading" and r.cop == 21 and r.got == 0, "another unit starts its own read")

-- random reads: chance per encounter, injected random
local c2 = R.sanitizeConfig({enabled = true, readChance = 0.3, afterEscapeChance = 1, encounterSeconds = 60})
r = R.newReader()
check(R.update(r, 0, 0.5, {copId = 30}, c2, seq(0.5)) == nil, "roll 0.5 >= 0.3: this unit does not read")
check(R.update(r, 30, 0.5, {copId = 30}, c2, seq(0)) == nil, "decision kept for the encounter")
check(R.update(r, 61, 0.5, {copId = 30}, c2, seq(0.1, 0)) == "reading", "new encounter, roll 0.1 < 0.3: reads")
r = R.newReader()
check(R.update(r, 0, 0.5, {copId = 31, recentEscape = true}, c2, seq(0.9, 0)) == "reading", "after an escape the chance is higher")
R.prune(r, 1000)
check(next(r.encounters) == nil, "prune drops old encounters")

-- chase decision: skip chance and our own cooldown
local cd = {}
local c3 = R.sanitizeConfig({enabled = true, skipChance = 0.2, retriggerSeconds = 120})
local go, why = R.decideChase(false, cd, "K", 0, c3, seq(0.9))
check(not go and why == "clean", "clean plate: no chase")
go = R.decideChase(true, cd, "K", 0, c3, seq(0.5))
check(go == true and cd.K == 120, "flagged, roll 0.5 >= 0.2: chase, cooldown set")
go, why = R.decideChase(true, cd, "K", 60, c3, seq(0.5))
check(not go and why == "cooldown", "same plate within 120 s: no new chase")
go, why = R.decideChase(true, cd, "K", 121, c3, seq(0.1))
check(not go and why == "skipped" and cd.K == 241, "roll 0.1 < 0.2: the cop lets it go (cooldown still set)")
local skips = 0
for i = 0, 99 do
  local cdi = {}
  if select(2, R.decideChase(true, cdi, "K", 0, c3, function() return i / 100 end)) == "skipped" then skips = skips + 1 end
end
check(skips == 20, "1 in 5 skipped")

-- stalemate vs escape
check(R.isStalemate({timers = {evade = 0}}) and not R.isStalemate({timers = {evade = 40}}) and not R.isStalemate(nil), "stalemate")

print("plate_read_lib_test: " .. passed .. " checks passed")
