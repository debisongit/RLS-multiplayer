-- Fake plates on own cars: server (lua5.3) test. Run: lua5.3 tests/fake_plates_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")
local players, sent, chat = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[#sent + 1] = {pid = pid, name = name, data = json.decode(data)} return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end, GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = m end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 2000000
util.setClock(function() return now end)
onInit()
local cfg = RLSMP.config
cfg.theft.enabled = true
local sessions = require("rlsmp.server.sessions")
local items = require("rlsmp.server.items")
local plates = require("rlsmp.server.plateRecords")
local fake = require("rlsmp.server.fakePlates")
local meetup = require("rlsmp.server.meetup")
local theft = require("rlsmp.server.theft")
theft.init(cfg, tmp .. "/")
meetup.init(cfg)
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function client(ev, pid, body) now = now + 5 return fire(ev, pid, json.encode(body)) end
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
local function last(pid, name)
  for i = #sent, 1, -1 do if sent[i].pid == pid and sent[i].name == name then return sent[i].data end end
end

join(1, "ann") join(2, "bob")

-- generator: 7 characters, digit + 3 letters + 3 digits, no I O Q
for _ = 1, 200 do
  local p = fake.generate()
  check(p:match("^[1-9][A-HJ-NP-Z][A-HJ-NP-Z][A-HJ-NP-Z]%d%d%d$") and not p:find("[IOQ]"), "plate format " .. p)
end

-- state after loading, once
sent = {}
fire("rlsmpFakeTick")
local st = last(1, "rlsmpFakeState")
check(st and #st.list == 0 and st.have == 0 and st.enabled == true, "state pushed after loading")
sent = {}
fire("rlsmpFakeTick")
check(last(1, "rlsmpFakeState") == nil, "state pushed only once")

-- fit needs the item and an offer
client("rlsmpFakeAsk", 1, {})
st = last(1, "rlsmpFakeState")
check(#st.choices == 3 and st.choices[1] ~= st.choices[2], "three different choices")
sent = {}
client("rlsmpFakeFit", 1, {inv = 3, idx = 1, real = "abc 123", model = "covet"})
check(last(1, "rlsmpFakeResult").ok == false and last(1, "rlsmpFakeResult").err:find("need a fake plate"), "no item: refused")

items.give(1, "fake_plate", 2)
client("rlsmpFakeAsk", 1, {})
local choice = last(1, "rlsmpFakeState").choices[2]
sent = {}
client("rlsmpFakeFit", 1, {inv = 3, idx = 9, real = "ABC 123", model = "covet"})
check(last(1, "rlsmpFakeResult").ok == false, "choice not on offer: refused")
client("rlsmpFakeFit", 1, {inv = 3, idx = 2, real = "ABC 123", model = "bad model!"})
check(last(1, "rlsmpFakeResult").ok == false, "bad model: refused")

-- a flag on the real plate, then fit
plates.flag("ABC 123", "covet", "red", "escaped", "acc")
check(plates.lookup("ABC 123", "covet", "red", false).flagged, "real plate is flagged")
client("rlsmpFakeFit", 1, {inv = 3, idx = 2, real = "abc 123", model = "covet"})
local res = last(1, "rlsmpFakeResult")
check(res.ok and res.fake == choice and res.real == "ABC 123" and res.inv == 3 and res.have == 1, "fit ok, item used up")
check(items.count(1, "fake_plate") == 1, "one fake_plate item taken (server-side)")
local rec = sessions.get(1).profile.fakePlates[choice]
check(rec and rec.real == "ABC 123" and rec.inv == 3 and rec.model == "covet", "record stored in the profile")
check(#last(1, "rlsmpFakeState").list == 1, "state lists the fake plate")

-- the plate change report of our own swap must not clear the real flag
client("rlsmpPlateChanged", 1, {model = "covet", oldPlate = "ABC 123", plate = choice})
check(plates.lookup("ABC 123", "covet", nil, false).flagged, "real plate flag survives the swap")
-- fake plate is a clean plate with its own record
check(plates.lookup(choice, "covet", nil, false).flagged == false, "fake plate: clean record")
check(plates.lookup(choice, "covet", "red", "acc").flagged and plates.lookup(choice, "covet", "red", "acc").matchedBy == "description",
  "model + colour memory (20 min) still catches the car on the fake plate")
check(plates.lookup(choice, "covet", "blue", "acc").flagged == false, "repainted: not caught")
-- a flag raised while wearing the fake plate attaches to the fake plate
plates.flag(choice, "covet", nil, "escaped", "acc")
check(plates.lookup(choice, "covet", nil, false).matchedBy == "plate", "flag on the fake plate")

-- one fake plate per car, per real plate
client("rlsmpFakeAsk", 1, {})
client("rlsmpFakeFit", 1, {inv = 3, idx = 1, real = choice, model = "covet"})
check(last(1, "rlsmpFakeResult").ok == false, "already wears a fake plate")
client("rlsmpFakeAsk", 1, {})
client("rlsmpFakeFit", 1, {inv = 4, idx = 1, real = "ABC 123", model = "covet"})
check(last(1, "rlsmpFakeResult").ok == false, "same real plate again: refused")

-- meetup: illegal papers
check(meetup.setupChance("market", true) > 0, "illegal setup chance above zero")
players[1].ids = {beammp = "101"}
local function sellRoll(pid, plate)
  meetup.setRandom(function() return 0.0 end)
  sent = {}
  fire("rlsmpPos", pid, json.encode({x = 0, y = 0, z = 50, speed = 0, chased = false}))
  client("rlsmpMeetupRequest", pid, {kind = "market", inv = 3, plate = plate, model = "covet", price = 5000})
  return last(pid, "rlsmpMeetupSet"), last(pid, "rlsmpMeetupDenied")
end
local set = sellRoll(1, choice)
check(set ~= nil, "meetup opens")
local m = meetup.openOf(1)
check(m and m.setup == true, "selling a car with a fake plate: setup roll applies (illegal papers)")
meetup.cancel(1)
-- a clean car of another player stays at 0
local set2 = sellRoll(2, "CLEAN 1")
check(set2 ~= nil and meetup.openOf(2).setup == false, "fully legal car: no setup")
meetup.cancel(2)

-- restore
client("rlsmpFakeRestore", 1, {fake = choice})
res = last(1, "rlsmpFakeResult")
check(res.ok and res.real == "ABC 123" and res.inv == 3, "restore answers with the real plate")
check(next(sessions.get(1).profile.fakePlates) == nil, "record removed")
check(items.count(1, "fake_plate") == 1, "restore does not give the item back")
check(plates.lookup("ABC 123", "covet", nil, false).flagged, "real plate record is back in use (still flagged)")
check(plates.lookup(choice, "covet", nil, false).flagged == false, "fake plate record cleared")
client("rlsmpFakeRestore", 1, {fake = choice})
check(last(1, "rlsmpFakeResult").ok == false, "restore twice: refused")

-- failed fit: item comes back
client("rlsmpFakeAsk", 1, {})
client("rlsmpFakeFit", 1, {inv = 5, idx = 1, real = "ZZZ 1", model = "pickup"})
res = last(1, "rlsmpFakeResult")
check(res.ok and items.count(1, "fake_plate") == 0, "second fit uses the last item")
client("rlsmpFakeRestore", 1, {fake = res.fake, failed = true})
check(items.count(1, "fake_plate") == 1, "the game could not fit it: item refunded")

-- drop
client("rlsmpFakeAsk", 1, {})
client("rlsmpFakeFit", 1, {inv = 5, idx = 1, real = "ZZZ 1", model = "pickup"})
res = last(1, "rlsmpFakeResult")
client("rlsmpFakeDrop", 1, {fake = res.fake})
check(next(sessions.get(1).profile.fakePlates) == nil, "drop forgets the record")

-- the profile keeps the record over a reload
client("rlsmpFakeAsk", 1, {})
items.give(1, "fake_plate", 1)
client("rlsmpFakeFit", 1, {inv = 6, idx = 1, real = "KEEP 1", model = "covet"})
res = last(1, "rlsmpFakeResult")
local profiles = require("rlsmp.server.profiles")
local onDisk = json.decode(io.open(tmp .. "/profiles/" .. sessions.get(1).accountId .. ".json"):read("a"))
check(onDisk.fakePlates and onDisk.fakePlates[res.fake] and onDisk.fakePlates[res.fake].real == "KEEP 1", "record is saved with the profile")

-- chased players cannot swap plates
client("rlsmpPos", 2, {x = 1, y = 2, z = 3, speed = 10, chased = true})
items.give(2, "fake_plate", 1)
client("rlsmpFakeAsk", 2, {})
client("rlsmpFakeFit", 2, {inv = 1, idx = 1, real = "BOB 1", model = "covet"})
check(last(2, "rlsmpFakeResult").ok == false and last(2, "rlsmpFakeResult").err:find("police"), "no plate swap while chased")

print("fake_plates_test: " .. passed .. " checks passed")
