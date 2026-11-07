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

-- An old duels.json from a build that used stage "hand" (loser uploads the car): those slips are dropped at start.
do
  local f = io.open(tmp .. "/duels.json", "w")
  f:write(json.encode({counter = 3, owed = {
    old1 = {stage = "hand", loser = "x", winner = "y", inv = 1, sum = "abc", model = "m", lastTry = 0},
    keep1 = {stage = "deliver", loser = "x", winner = "nobody", inv = 2, model = "m", rec = {model = "m", config = {}}, lastTry = 0},
  }}))
  f:close()
end

dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000000
util.setClock(function() return now end)
onInit()
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local transfer = require("rlsmp/lib/transfer")
local live = require("rlsmp.server.duel")

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
local function chatSince(n, pid, pattern)
  for i = n + 1, #chat do if chat[i][1] == pid and chat[i][2]:find(pattern) then return true end end
  return false
end
local upSeq = 0
local function sendUpload(pid, body)
  upSeq = upSeq + 1
  local header, chunks = transfer.describe(json.encode(body), 400)
  header.id = "u" .. upSeq
  fire("rlsmpUpBegin", pid, json.encode(header))
  for i, d in ipairs(chunks) do fire("rlsmpUpChunk", pid, json.encode({id = header.id, i = i, d = d})) end
end
local function clientUpload(pid, kind, data) sendUpload(pid, {kind = kind, data = data}) end
-- A normal save upload: the server's files with `changes` applied (false removes a file).
local function saveWith(pid, changes)
  local files = {}
  for rel, text in pairs(sessions.get(pid).profile.save.files) do files[rel] = text end
  for rel, text in pairs(changes) do files[rel] = text or nil end
  local all = {}
  for rel, text in pairs(files) do all[rel] = transfer.checksum(text) end
  sendUpload(pid, {all = all, files = files})
  local ack = lastSent(pid, "rlsmpUpAck")
  assert(ack and ack.ok, "save upload accepted")
end
local function carPath(inv) return "career/vehicles/" .. inv .. ".json" end
local function ping(pid, x) fire("rlsmpDuelPos", pid, json.encode({pos = {x = x, y = 0, z = 0}})) end
local function slipFor(winnerPid)
  local acc = sessions.get(winnerPid).accountId
  for slip, o in pairs(live._owed()) do if o.winner == acc then return slip, o end end
end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

check(live._owed().old1 == nil, "old stage 'hand' slip from duels.json is dropped")
check(live._owed().keep1 ~= nil, "a valid 'deliver' slip is kept")

join(1, "ann") join(2, "bob")
for pid = 1, 2 do sessions.get(pid).profile.save.files["info.json"] = "{}" end
sessions.get(1).profile.save.files[carPath(3)] = json.encode({model = "etk800", config = {parts = {}}, configBaseValue = 20000})
sessions.get(2).profile.save.files[carPath(4)] = json.encode({model = "pickup", config = {parts = {x = "y"}}, configBaseValue = 15000})

-- switched off by default
say(1, "/duel bob")
check(lastChat():find("switched off"), "duels are off by default")
local appCfg = RLSMP.config
check(appCfg.duel and appCfg.duel.enabled == false, "default config has duels disabled")
check(appCfg.duel.maxSpeed == 120 and appCfg.duel.minPings and appCfg.duel.maxValueGapPercent == 0, "anti-cheat defaults")
appCfg.duel.enabled = true
-- array coordinates and a broken course must both work without errors
appCfg.duel.courses = {{name = "broken", start = {"a", "b"}, finish = {x = 1}},
                       {name = "loop", start = {0, 0, 0}, finish = {500, 0, 0}}}

local function challenge()
  say(1, "/duel bob") say(2, "/duel accept")
  return lastSent(1, "rlsmpDuelWho").id
end
local function car(pid, id, inv, model, x, cur)
  fire("rlsmpDuelCar", pid, json.encode({id = id, inv = inv, cur = cur or inv, model = model, pos = {x = x, y = 0, z = 0}}))
end

-- the stake must be the car the player sits in
local id = challenge()
car(1, id, 3, "etk800", 5, 9)
check(lastChat():find("sit in the car"), "stake that is not the current car is refused")

-- value gap (off by default; 10% here: 15000 vs 20000 is too far apart)
appCfg.duel.maxValueGapPercent = 10
id = challenge()
car(1, id, 3, "etk800", 5) car(2, id, 4, "pickup", 10)
check(lastChat():find("too far apart"), "much cheaper stake refused")
appCfg.duel.maxValueGapPercent = 0

-- bad data while picking a course cancels cleanly instead of leaving the duel stuck
appCfg.duel.startRadius = "x"
id = challenge()
car(1, id, 3, "etk800", 5) car(2, id, 4, "pickup", 10)
check(lastChat():find("bad duel data"), "error in onCar cancels the duel")
appCfg.duel.startRadius = 60

-- Main race: bob cheats with a teleport, ann wins fairly, bob's car moves to ann.
id = challenge()
car(1, id, 3, "etk800", 5) car(2, id, 4, "pickup", 10)
check(lastChat():find("Course 'loop'"), "array course coordinates work (broken course skipped)")
now = now + 6
live.tick()
check(lastSent(1, "rlsmpDuelGo") and lastSent(2, "rlsmpDuelGo").finish.x == 500, "go sent with a normalized finish")
ping(1, 5) ping(2, 10)
ping(2, 499)   -- 489 m in one second
for i = 1, 10 do
  now = now + 1
  ping(1, 5 + 50 * i)
  if i == 5 then
    -- bob's game saves (mileage) during the race: the hand-over must not depend on an old fingerprint
    saveWith(2, {[carPath(4)] = json.encode({model = "pickup", config = {parts = {x = "y"}}, configBaseValue = 15000, mileage = 123})})
  end
end
ping(2, 499)   -- 9 s later this would look like a believable speed, but bob already jumped
fire("rlsmpDuelFinish", 2, json.encode({id = id}))
check(not lastChat():find("bob wins"), "speed cheat: teleported player cannot win")
fire("rlsmpDuelFinish", 1, json.encode({id = id}))
check(lastChat():find("ann wins"), "ann wins")
check(lastSent(1, "rlsmpDuelEnd"), "duel ended for clients")

local slip, o = slipFor(1)
check(slip and o.stage == "deliver", "slip stored in stage deliver right away")
check(o.rec.model == "pickup" and o.rec.config.parts.x == "y" and o.rec.mileage == 123 and o.rec.slipId == slip and o.rec.fleetId == nil,
  "winner's record is built from the server's latest copy of the car")
local ack = lastSent(2, "rlsmpDuelAck")
check(ack and ack.ok == true and ack.inv == 4 and ack.model == "pickup", "loser told to remove the car")
check(profiles.isOut(sessions.get(2).profile, 4), "loser's slot marked out at once")
local disk = json.decode(io.open(tmp .. "/duels.json"):read("*a"))
check(disk.owed[slip] and disk.owed[slip].stage == "deliver", "owed car saved to disk")

-- a forged record from the loser's client is ignored
clientUpload(2, "duelHand", {slip = slip, inv = 4, rec = {model = "hypercar", config = {}}})
check(live._owed()[slip].rec.model == "pickup", "forged client record never replaces the server copy")

-- the loser saves again before removing the car (mileage): the slot stays marked out, no chat spam
saveWith(2, {[carPath(4)] = json.encode({model = "pickup", config = {parts = {x = "y"}}, configBaseValue = 15000, mileage = 200})})
check(profiles.isOut(sessions.get(2).profile, 4), "a save with a changed car file keeps the slot marked out")
check(profiles.staleCars(sessions.get(2).profile)[1] == 4, "the car is on the join-time drop list")
local before = #chat
for _ = 1, 5 do now = now + 31 live.tick() end
check(not chatSince(before, 2, "%[Duel%]"), "no repeated chat to the loser")
check(lastSent(2, "rlsmpDuelHand") == nil, "loser is never asked to upload the car")
-- the loser's client removed the car and saved
saveWith(2, {[carPath(4)] = false})
check(not profiles.isOut(sessions.get(2).profile, 4) and live._owed()[slip].loserCleared, "mark cleared once the car is gone")

-- delivery to the winner, retried until a winner save holds the car
for _ = 1, 20 do fire("rlsmpPump") end
local begin = lastSent(1, "rlsmpChunkBegin")
check(begin and begin.kind == "duelVehicle", "car sent to the winner")
fire("rlsmpDuelRelease", 1, json.encode({slip = slip, why = "no free garage space"}))
check(json.decode(io.open(tmp .. "/duels.json"):read("*a")).owed[slip], "failed delivery keeps the car owed")
fire("rlsmpDuelReceived", 1, json.encode({slip = slip}))
check(live._owed()[slip] and live._owed()[slip].stage == "delivered", "received only marks it delivered")
check(json.decode(io.open(tmp .. "/duels.json"):read("*a")).owed[slip], "slip kept until the winner's save has the car")
saveWith(1, {[carPath(11)] = json.encode({model = "pickup", config = {}, slipId = slip})})
check(live._owed()[slip] == nil, "winner's save with the car clears the slip")
check(json.decode(io.open(tmp .. "/duels.json"):read("*a")).owed[slip] == nil, "cleared on disk too")

-- Unusable server copy of the loser's car: no car moves. Also: too few pings means no win.
sessions.get(1).profile.save.files[carPath(5)] = json.encode({model = "etk800", config = {}})
sessions.get(2).profile.save.files[carPath(6)] = json.encode({model = "pickup", config = {}})
id = challenge()
car(1, id, 5, "etk800", 0) car(2, id, 6, "pickup", 0)
now = now + 6 live.tick()
ping(1, 0) ping(2, 0)
now = now + 5 ping(2, 250)
now = now + 5 ping(2, 500)
fire("rlsmpDuelFinish", 2, json.encode({id = id}))
check(not lastChat():find("bob wins"), "finish with too few pings refused")
for _ = 1, 3 do now = now + 1 ping(2, 500) end
sessions.get(1).profile.save.files[carPath(5)] = json.encode({model = "etk800"})   -- no config
fire("rlsmpDuelFinish", 2, json.encode({id = id}))
check(lastChat():find("bob wins") and lastChat():find("No car moves"), "unusable stored car: both told, no car moves")
check(slipFor(2) == nil and not profiles.isOut(sessions.get(1).profile, 5), "no slip, loser keeps the car")
sessions.get(1).profile.save.files[carPath(5)] = json.encode({model = "etk800", config = {}})

-- Forfeit while the loser is offline: the car is marked out in the loser's profile and dropped on the next join.
sessions.get(1).profile.save.files[carPath(7)] = json.encode({model = "etk800", config = {color = "red"}})
id = challenge()
car(1, id, 7, "etk800", 0) car(2, id, 6, "pickup", 0)
now = now + 6 live.tick()
fire("onPlayerDisconnect", 1)
live.tick()
check(lastChat():find("bob wins"), "player who leaves mid-race forfeits")
local slip2, o2 = slipFor(2)
check(slip2 and o2.rec.model == "etk800" and o2.rec.config.color == "red", "offline loser: car built from the stored profile")
check(profiles.get(o2.loser) == nil, "offline loser's profile not left loaded")
join(1, "ann")
check(profiles.staleCars(sessions.get(1).profile)[1] == 7, "offline loser: car on the drop list at the next join")
for _ = 1, 30 do fire("rlsmpPump") end
local down
for i = #(sent[1] or {}), 1, -1 do
  local m = sent[1][i]
  if m.name == "rlsmpChunkBegin" and m.data.kind == "profile" then down = m.data break end
end
check(down and down.extra and down.extra.drop and down.extra.drop[1] == 7, "profile download tells the client to drop it")

-- winner leaves after 'received' but before a save: it goes back to deliver and is re-sent on the next join
fire("rlsmpDuelReceived", 2, json.encode({slip = slip2}))
check(live._owed()[slip2].stage == "delivered", "delivered")
fire("onPlayerDisconnect", 2)
live.tick()
check(live._owed()[slip2].stage == "deliver", "winner left before saving: back to deliver")
print("duel_test: " .. passed .. " checks passed")
