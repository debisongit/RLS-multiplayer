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
local now = 1000
require("rlsmp.server.util").setClock(function() return now end)
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
local function done(pid, tbl) now = now + 6 fire("rlsmpEventDone", pid, json.encode(tbl)) end

done(1, {race = "drag1", t = 65.5})
check(last():find("New record on drag1: 1:05.50 by ann"), "first run is a record")
local n = #chat
done(1, {race = "drag1", t = 70})
check(#chat == n, "slower run says nothing")
done(2, {race = "drag1", t = 80})
check(last():find("Personal best"), "bob's first run is a personal best, not a record")
done(2, {race = "drag1", t = 60})
check(last():find("New record on drag1: 1:00.00 by bob"), "bob beats the record")
for _, bad in ipairs({{race = "x", t = 0.5}, {race = "x", t = -4}, {race = "x", t = "a"}, {race = "", t = 30}, {race = string.rep("z", 80), t = 30}}) do
  done(1, bad)
end
check(not require("rlsmp.server.events").records().x, "bad times and names are ignored")
local list = require("rlsmp.server.events").records().drag1
check(#list == 2 and list[1].name == "bob" and list[2].name == "ann" and list[2].t == 65.5, "one entry per player, best first")
fire("onChatMessage", 1, "ann", "/records drag1")
check(chat[#chat - 1][2]:find("1%. bob") and last():find("2%. ann"), "chat command lists the top")
local saved = json.decode(io.open(tmp .. "/records.json"):read("*a"))
check(saved.drag1[1].name == "bob", "saved to disk")

-- rate limit: one accepted run per 5 s per player
local events = require("rlsmp.server.events")
now = now + 10
fire("rlsmpEventDone", 1, json.encode({race = "spam1", t = 30}))
fire("rlsmpEventDone", 1, json.encode({race = "spam2", t = 30}))
check(events.records().spam1 and not events.records().spam2, "second run within 5 s is ignored")
now = now + 4
fire("rlsmpEventDone", 1, json.encode({race = "spam2", t = 30}))
check(not events.records().spam2, "still ignored after 4 s")
now = now + 1
fire("rlsmpEventDone", 1, json.encode({race = "spam2", t = 30}))
check(events.records().spam2, "accepted again after 5 s")
fire("rlsmpEventDone", 2, json.encode({race = "spam2", t = 29}))
check(events.records().spam2[1].name == "bob", "the limit is per player")

-- a record is announced only when it beats the old one by at least 0.05 s
local before = #chat
done(1, {race = "drag1", t = 59.98})
check(#chat == before + 1 and chat[#chat][1] == 1 and last():find("not announced"), "a 0.02 s better record is only told to the player")
check(events.records().drag1[1].name == "ann", "but it is still the record")
done(2, {race = "drag1", t = 59.93})
check(chat[#chat][1] == -1 and last():find("New record on drag1: 0:59.93 by bob"), "0.05 s better is announced")

-- one player cannot fill the board with junk event names
local refused = 0
for k = 1, 60 do
  done(1, {race = "junk" .. k, t = 30})
  if not events.records()["junk" .. k] then refused = refused + 1 end
end
check(refused > 0 and refused < 60, "new events from one player are capped (" .. refused .. " refused)")
done(2, {race = "fresh", t = 30})
check(events.records().fresh, "other players can still add events")
done(2, {race = "junk1", t = 31})
done(1, {race = "junkAfter", t = 30})
check(events.records().junkAfter, "an event someone else also ran no longer counts against the cap")
print("events_test: " .. passed .. " checks passed")
