-- Stolen car damage number (LuaJIT). Run: luajit tests/stolen_damage_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local SD = require("rlsmp/lib/stolenDamage")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(SD.fraction(0) == 0 and SD.fraction(150) == 0.15 and SD.fraction(500) == 0.5, "raw / 1000")
check(SD.fraction(1000) == 1 and SD.fraction(50000) == 1 and SD.fraction(-5) == 0, "clamped to 0..1")
check(SD.fraction(nil) == nil and SD.fraction("x") == nil and SD.fraction(0 / 0) == nil, "no number, no fraction")
check(SD.fraction("230") == 0.23 and SD.fraction(1234.5678) == 1, "numeric text, rounding")
check(SD.fraction(100, 200) == 0.5 and SD.fraction(100, 0) == 0.1, "own scale, bad scale falls back")
check(SD.combine(0, 0.4) == 0.4 and SD.combine(0.6, 0.4) == 0.6 and SD.combine(0.1, nil) == 0.1, "a restored car keeps its recorded damage")
check(SD.combine(nil, 0.4) == nil, "no live reading stays unknown")
print("stolen_damage_lib_test: " .. passed .. " checks passed")
