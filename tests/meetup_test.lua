-- Meetup selling: server (lua5.3) test. Run: lua5.3 tests/meetup_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, chat, sent = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[#sent + 1] = {pid = pid, name = name, data = json.decode(data)} return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end, GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = {pid, m} end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1800 * 1000
util.setClock(function() return now end)
onInit()
local cfg = RLSMP.config
cfg.theft.enabled = true
local sessions = require("rlsmp.server.sessions")
local theft = require("rlsmp.server.theft")
local meetup = require("rlsmp.server.meetup")
theft.init(cfg, tmp .. "/")
meetup.init(cfg)
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(100 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, 1000
end
local function lastSent(pid, name)
  for i = #sent, 1, -1 do if sent[i].pid == pid and sent[i].name == name then return sent[i].data end end
end
local lastPos = {}
local function standAt(pid, x, y, chased)
  now = math.max(now, (lastPos[pid] or 0) + 1)
  lastPos[pid] = now
  fire("rlsmpPos", pid, json.encode({x = x, y = y, z = 50, speed = 0, chased = chased == true}))
end
local function request(pid, t) sent = {} fire("rlsmpMeetupRequest", pid, json.encode(t)) return lastSent(pid, "rlsmpMeetupSet"), lastSent(pid, "rlsmpMeetupDenied") end
local function arrive(pid, id) fire("rlsmpMeetupArrive", pid, json.encode({id = id})) return lastSent(pid, "rlsmpMeetupResult") end
local function dummyRandom(v) meetup.setRandom(function() return v end) end

join(1, "ann")
local acc = sessions.get(1).accountId
local legal = {kind = "market", inv = 3, plate = "LEG 111", model = "etk800", price = 9000}

-- chances: legal is exactly 0, illegal is never 0 or 1
check(meetup.setupChance("market", false) == 0 and meetup.setupChance("black", false) == 0, "legal car: no setup chance")
cfg.meetup.illegalChance, cfg.meetup.blackChance = 0, 5
check(meetup.setupChance("market", true) == 0.05 and meetup.setupChance("black", true) == 0.85, "illegal chance stays inside min and max")
cfg.meetup.illegalChance, cfg.meetup.blackChance = 0.35, 0.45

-- a legal car with the worst possible roll is never set up; the spot is far from the player
dummyRandom(0)
standAt(1, 0, 0)
local set = request(1, legal)
check(set and set.id and set.spot and set.radius == 15 and set.x, "legal sale gets a meetup spot")
check(set.kind == "market", "kind market")
local first = set.spot
standAt(1, 5000, 5000)
local r = arrive(1, set.id)
check(r.retry and not r.ok, "too far away: try again later")
local sp = cfg.market.dropSpots
local spotOf = {}
for _, s in ipairs(sp) do spotOf[s.name] = s end
standAt(1, spotOf[first].x, spotOf[first].y, true)
r = arrive(1, set.id)
check(r.retry and r.err:find("police"), "chased: wait")
standAt(1, spotOf[first].x, spotOf[first].y)
r = arrive(1, set.id)
check(r.ok and not r.setup and r.kind == "market" and r.inv == 3, "legal car: sale may finish, never a setup (roll 0)")

-- cooldown and a different spot next time
set, r = request(1, legal)
check(set == nil and r and r.err:find("Try again"), "cooldown after a sale")
now = now + 301
set = request(1, legal)
check(set and set.spot ~= first, "a different spot than last time")
fire("rlsmpMeetupCancel", 1, "{}")
check(meetup.openOf(1) == nil and lastSent(1, "rlsmpMeetupClear"), "cancel clears")
set, r = request(1, legal)
check(set == nil and r, "cancel has a short cooldown")
now = now + 61

-- a stolen car (theft record) rolls the setup
theft.records()["STO 222"] = {plate = "STO 222", model = "etk800", color = "red", value = 20000, year = 2003, by = acc, t = now}
local stolen = {kind = "market", inv = 4, plate = "STO 222", model = "etk800", price = 9000}
dummyRandom(0)
set = request(1, stolen)
standAt(1, spotOf[set.spot].x, spotOf[set.spot].y)
r = arrive(1, set.id)
check(r.setup and not r.ok and r.cops >= 1 and r.cops <= 2, "stolen car, bad roll: setup with 1 or 2 cops")
now = now + 301
dummyRandom(0.99)
set = request(1, stolen)
standAt(1, spotOf[set.spot].x, spotOf[set.spot].y)
r = arrive(1, set.id)
check(r.ok and not r.setup, "stolen car, good roll: no setup (the player cannot be sure)")
now = now + 301
local seen = {}
for _, v in ipairs({0, 0.2, 0.5, 0.99}) do
  dummyRandom(v)
  local s2 = request(1, stolen)
  standAt(1, spotOf[s2.spot].x, spotOf[s2.spot].y)
  local rr = arrive(1, s2.id)
  check(rr.cops == nil or (rr.cops >= 1 and rr.cops <= 2), "cops always 1 or 2")
  seen[#seen + 1] = rr
  now = now + 301
end

-- black market: needs membership and an own theft record, pays through the server
dummyRandom(0.99)
set, r = request(1, {kind = "black", plate = "STO 222", model = "etk800"})
check(set == nil and r and r.err:find("members"), "black market needs membership")
fire("onConsoleInput", "rlsmp market grant ann")
set, r = request(1, {kind = "black", plate = "NOPE 1", model = "etk800"})
check(set == nil and r and r.err:find("stolen list"), "plate must be on your stolen list")
set = request(1, {kind = "black", plate = "STO 222", model = "etk800"})
check(set and set.kind == "black", "black meetup set")
local before = sessions.get(1).profile.ledger.money
standAt(1, spotOf[set.spot].x, spotOf[set.spot].y)
r = arrive(1, set.id)
check(r.ok and r.takeCar and r.pay == 7000, "black sale paid by the server (35% of 20000)")
check(sessions.get(1).profile.ledger.money == before + 7000 and theft.records()["STO 222"] == nil, "money in, record gone")
check(lastSent(1, "rlsmpWalletSet").money == before + 7000, "wallet told")

-- expiry and wrong id
now = now + 301
dummyRandom(0.99)
set = request(1, legal)
check(arrive(1, "zzz").ok == false, "wrong id refused")
now = now + 21 * 60
check(meetup.openOf(1) == nil, "an old meetup expires")

print(string.format("meetup_test: %d checks passed", passed))
