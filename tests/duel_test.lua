-- Pink-slip duel: server (lua5.3) test. Run: lua5.3 tests/duel_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent, chat = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = {pid, m} end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000000
util.setClock(function() return now end)
onInit()
local sessions = require("rlsmp.server.sessions")
local transfer = require("rlsmp/lib/transfer")

local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = transfer.BUILD}))
  sessions.get(pid).stage = "loaded"
end
local function lastSent(pid, name)
  for i = #(sent[pid] or {}), 1, -1 do if sent[pid][i].name == name then return sent[pid][i].data end end
end
local function say(pid, text) fire("onChatMessage", pid, players[pid].name, text) end
local function lastChat() return chat[#chat] and chat[#chat][2] or "" end
local function clientUpload(pid, id, kind, data)
  local header, chunks = transfer.describe(json.encode({kind = kind, data = data}), 40)
  header.id = id
  fire("rlsmpUpBegin", pid, json.encode(header))
  for i, d in ipairs(chunks) do fire("rlsmpUpChunk", pid, json.encode({id = id, i = i, d = d})) end
end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

join(1, "ann") join(2, "bob")
local car1 = {model = "etk800", niceName = "ETK", config = {parts = {}}}
sessions.get(1).profile.save.files["career/vehicles/3.json"] = json.encode({model = "etk800"})
sessions.get(2).profile.save.files["career/vehicles/4.json"] = json.encode({model = "pickup"})

-- switched off by default
say(1, "/duel bob")
check(lastChat():find("switched off"), "duels are off by default")
local duelCfg = RLSMP.config.duel
check(duelCfg and duelCfg.enabled == false, "default config has duels disabled")
-- turn on for the test (the module reads the live config table)
local live = require("rlsmp.server.duel")
local appCfg = RLSMP and RLSMP.config or nil
check(appCfg, "config reachable")
appCfg.duel.enabled = true
appCfg.duel.courses = {{name = "loop", start = {x = 0, y = 0, z = 0}, finish = {x = 500, y = 0, z = 0}}}

say(1, "/duel bob")
say(2, "/duel accept")
local who = lastSent(1, "rlsmpDuelWho")
check(who and lastSent(2, "rlsmpDuelWho"), "both asked for their car")
fire("rlsmpDuelCar", 1, json.encode({id = who.id, inv = 3, model = "etk800", pos = {x = 5, y = 0, z = 0}}))
fire("rlsmpDuelCar", 2, json.encode({id = who.id, inv = 4, model = "pickup", pos = {x = 10, y = 0, z = 0}}))
check(lastChat():find("Starting in"), "countdown announced")
now = now + 6
live.tick()
check(lastSent(1, "rlsmpDuelGo") and lastSent(2, "rlsmpDuelGo"), "go sent")

-- too early or too far finishes are ignored
fire("rlsmpDuelPos", 2, json.encode({pos = {x = 499, y = 0, z = 0}}))
fire("rlsmpDuelFinish", 2, json.encode({id = who.id}))
check(lastChat():find("Starting in") or not lastChat():find("wins"), "finish before minimum race time ignored")
now = now + 10
fire("rlsmpDuelPos", 1, json.encode({pos = {x = 50, y = 0, z = 0}}))
fire("rlsmpDuelFinish", 1, json.encode({id = who.id}))
check(not lastChat():find("wins"), "finish far from the line ignored")
fire("rlsmpDuelFinish", 2, json.encode({id = who.id}))
check(lastChat():find("bob wins"), "bob wins")
check(lastSent(1, "rlsmpDuelEnd"), "duel ended for clients")

-- loser is asked for the car; a changed car is refused
live.tick()
local hand = lastSent(1, "rlsmpDuelHand")
check(hand and hand.inv == 3, "loser asked to hand over the car")
sessions.get(1).profile.save.files["career/vehicles/3.json"] = json.encode({model = "etk800", edited = true})
clientUpload(1, "h1", "duelHand", {slip = hand.slip, inv = 3, rec = car1})
check(lastSent(1, "rlsmpDuelAck").ok == false, "car that changed since the race is not handed over")
sessions.get(1).profile.save.files["career/vehicles/3.json"] = json.encode({model = "etk800"})
clientUpload(1, "h2", "duelHand", {slip = hand.slip, inv = 3, rec = car1})
check(lastSent(1, "rlsmpDuelAck").ok == true, "hand-over accepted")
check(require("rlsmp.server.profiles").isOut(sessions.get(1).profile, 3), "slot marked out so a crash can't bring it back")
local disk = json.decode(io.open(tmp .. "/duels.json"):read("*a"))
check(next(disk.owed) ~= nil, "owed car saved to disk")

-- delivery to the winner, retried until confirmed
now = now + 40
live.tick()
for _ = 1, 20 do fire("rlsmpPump") end
local begin = lastSent(2, "rlsmpChunkBegin")
check(begin and begin.kind == "duelVehicle", "car sent to the winner")
fire("rlsmpDuelRelease", 2, json.encode({slip = hand.slip, why = "no free garage space"}))
check(next(json.decode(io.open(tmp .. "/duels.json"):read("*a")).owed) ~= nil, "failed delivery keeps the car owed")
fire("rlsmpDuelReceived", 2, json.encode({slip = hand.slip}))
check(next(json.decode(io.open(tmp .. "/duels.json"):read("*a")).owed) == nil, "confirmed delivery clears the slip")

-- forfeit: leaving mid-race loses
say(1, "/duel bob") say(2, "/duel accept")
who = lastSent(1, "rlsmpDuelWho")
sessions.get(1).profile.save.files["career/vehicles/5.json"] = json.encode({model = "etk800"})
fire("rlsmpDuelCar", 1, json.encode({id = who.id, inv = 5, model = "etk800", pos = {x = 0, y = 0, z = 0}}))
fire("rlsmpDuelCar", 2, json.encode({id = who.id, inv = 4, model = "pickup", pos = {x = 0, y = 0, z = 0}}))
now = now + 6 live.tick()
fire("onPlayerDisconnect", 2)
live.tick()
check(lastChat():find("ann wins"), "player who leaves mid-race forfeits")
print("duel_test: " .. passed .. " checks passed")
