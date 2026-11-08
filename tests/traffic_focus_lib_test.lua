-- Traffic focus (pure rules). Run: luajit tests/traffic_focus_lib_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local F = require("rlsmp/lib/trafficFocus")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local d = F.sanitize(nil)
check(d.enabled and d.configs == 2 and d.minutes == 20, "defaults: 2 configs for 20 minutes")
d = F.sanitize({configs = 99, minutes = 0, enabled = false})
check(d.enabled == false and d.configs == 6 and d.minutes == 1, "out of range values are clamped, off stays off")
d = F.sanitize({configs = "x", minutes = 0 / 0})
check(d.configs == 2 and d.minutes == 20, "garbage falls back to the defaults")

local cfg = F.sanitize({configs = 2, minutes = 20})
local st = F.newState()
check(F.due(st, cfg, 0), "nothing chosen yet: a choice is due")
check(F.current(st, cfg) == nil, "no focus yet")
check(F.set(st, cfg, {{model = "a", config = "x"}, {model = "a", config = "x"}, {model = "b", config = "y"}, {model = "c", config = "z"}}, 100), "set")
check(#st.entries == 2 and st.entries[1].model == "a" and st.entries[2].model == "b", "distinct entries, at most `configs`")
check(not F.due(st, cfg, 100 + 1199) and F.due(st, cfg, 100 + 1200), "due after exactly 20 minutes")
check(st.rotations == 1, "one choice made")
check(not F.set(st, cfg, {}, 5000) and st.entries == nil, "an empty choice clears the focus (a new try follows)")
F.set(st, cfg, {{model = "a", config = "x"}}, 0)
local cur = F.current(st, cfg)
cur[1].model = "changed"
check(st.entries[1].model == "a", "current() hands out copies")
check(F.current(st, {enabled = false}) == nil, "switched off: no focus")

local g = F.group({{model = "a", config = "x"}, {model = "b", config = "y"}}, 10, function() return 1 end)
local na = 0
for _, e in ipairs(g) do if e.model == "a" then na = na + 1 end end
check(#g == 10 and na == 5, "two entries share ten cars evenly")
g = F.group({{model = "a", config = "x"}}, 4)
check(#g == 4 and g[4].model == "a", "one entry fills the group")
check(#F.group({}, 3) == 0, "no entries: no cars")
print(string.format("traffic_focus_lib_test: %d checks passed", passed))
