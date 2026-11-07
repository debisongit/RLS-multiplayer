-- Shared clock: server (lua5.3) test. Run: lua5.3 tests/clock_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 2700 * 5      -- a multiple of the 45 minute period: game minute 0
util.setClock(function() return now end)
onInit()
local sessions = require("rlsmp.server.sessions")
local clock = require("rlsmp.server.clock")
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
for pid, name in pairs({[1] = "ann", [2] = "bob"}) do
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
end
sessions.get(1).stage = "loaded"   -- bob is still loading
check(clock.minuteAt(0, 45) == 0 and clock.minuteAt(2700, 45) == 0, "starts at midnight and wraps after 45 minutes")
local dawn = select(1, clock.minuteAt(4 * 45, 45))
check(math.abs(dawn - 240) < 1e-6, "first part ends at 04:00 after 4/60 of the day")
check(math.abs(clock.minuteAt(28 * 45, 45) - 720) < 1e-6, "noon is 28/60 of the way")
local _, r1 = clock.minuteAt(10, 45)
local _, r2 = clock.minuteAt(1000, 45)
check(r2 < r1 or r2 > 0, "rate reported")
clock.tick()
local function last(pid, n) for i = #(sent[pid] or {}), 1, -1 do if sent[pid][i].name == n then return sent[pid][i].data end end end
check(last(1, "rlsmpTime") and last(1, "rlsmpTime").m == 0 and last(1, "rlsmpTime").dm == 45, "loaded player gets the time")
check(last(2, "rlsmpTime") == nil, "player still loading gets nothing")
now = now + 180
clock.tick()
check(math.abs(last(1, "rlsmpTime").m - 240) < 1e-6, "04:00 after 3 real minutes")
print("clock_test: " .. passed .. " checks passed")
