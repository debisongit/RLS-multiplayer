-- Event records: server (lua5.3) test. Run: lua5.3 tests/events_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, chat = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = {pid, m} end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
require("rlsmp.server.util").setJsonCodec(json)
onInit()
local sessions = require("rlsmp.server.sessions")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  sessions.get(pid).stage = "loaded"
end
local function last() return chat[#chat] and chat[#chat][2] end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
join(1, "ann") join(2, "bob")

fire("rlsmpEventDone", 1, json.encode({race = "drag1", t = 65.5}))
check(last():find("New record on drag1: 1:05.50 by ann"), "first run is a record")
local n = #chat
fire("rlsmpEventDone", 1, json.encode({race = "drag1", t = 70}))
check(#chat == n, "slower run says nothing")
fire("rlsmpEventDone", 2, json.encode({race = "drag1", t = 80}))
check(last():find("Personal best"), "bob's first run is a personal best, not a record")
fire("rlsmpEventDone", 2, json.encode({race = "drag1", t = 60}))
check(last():find("New record on drag1: 1:00.00 by bob"), "bob beats the record")
for _, bad in ipairs({{race = "x", t = 0.5}, {race = "x", t = -4}, {race = "x", t = "a"}, {race = "", t = 30}, {race = string.rep("z", 80), t = 30}}) do
  fire("rlsmpEventDone", 1, json.encode(bad))
end
check(not require("rlsmp.server.events").records().x, "bad times and names are ignored")
local list = require("rlsmp.server.events").records().drag1
check(#list == 2 and list[1].name == "bob" and list[2].name == "ann" and list[2].t == 65.5, "one entry per player, best first")
fire("onChatMessage", 1, "ann", "/records drag1")
check(chat[#chat - 1][2]:find("1%. bob") and last():find("2%. ann"), "chat command lists the top")
local saved = json.decode(io.open(tmp .. "/records.json"):read("*a"))
check(saved.drag1[1].name == "bob", "saved to disk")
print("events_test: " .. passed .. " checks passed")
