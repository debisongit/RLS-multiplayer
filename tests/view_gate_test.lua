-- View gate and respawn watch (LuaJIT). Run: luajit tests/view_gate_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local G = require("rlsmp/lib/viewGate")
local W = require("rlsmp/lib/respawnWatch")
local n = 0
local function eq(a, b, m) n = n + 1 if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end
local me, fwd = {x = 0, y = 0, z = 0}, {x = 0, y = 1, z = 0}
eq(G.reason({x = 50, y = 0, z = 0}, me, me, fwd, {}), "near", "close car")
eq(G.reason({x = 300, y = 0, z = 0}, me, me, fwd, {{x = 300, y = 50, z = 0}}), "nearOther", "near a friend")
eq(G.reason({x = 0, y = 300, z = 0}, me, me, fwd, {}), "inView", "ahead of the camera")
eq(G.reason({x = 0, y = -300, z = 0}, me, me, fwd, {}), nil, "behind the camera")
eq(G.reason({x = 0, y = 800, z = 0}, me, me, fwd, {}), nil, "ahead but far")
eq(G.reason({x = 0, y = -300, z = 0}, nil, me, fwd, {}), "noFocus", "no focus means no")
eq(G.reason({x = 300, y = 0, z = 0}, me, nil, nil, {}), nil, "no camera data: distance only")
local w = W.new()
eq(W.observe(w, 1, 0, "active", 100, 0), nil, "baseline")
eq(W.observe(w, 1, 1, "reset", 140, 5), "respawn", "count up")
eq(W.observe(w, 1, 1, "fadeOut", 60, 6), "fadeout", "fade out")
eq(W.observe(w, 1, 1, "fadeOut", 60, 7), nil, "same fade")
W.observe(w, 2, 0, "active", 100, 8) W.observe(w, 2, 1, "reset", 90, 10)
local c, near = W.summary(w, 20)
eq(c, 2, "two respawns") eq(near, 90, "nearest")
eq((W.summary(w, 200)), 0, "window expires")
print("view_gate_test ok (" .. n .. " checks)")
