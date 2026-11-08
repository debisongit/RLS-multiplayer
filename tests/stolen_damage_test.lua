-- Stolen car damage: server (lua5.3) test. Run: lua5.3 tests/stolen_damage_test.lua <tmpdir>
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
package.loaded["rlsmp.server.plateRecords"] = {flag = function() return true end}
local sessions = require("rlsmp.server.sessions")
local market = require("rlsmp.server.market")
local theft = require("rlsmp.server.theft")
local fence = require("rlsmp.server.fence")
local meetup = require("rlsmp.server.meetup")
local recall = require("rlsmp.server.recall")
theft.init(cfg, tmp .. "/")
fence.init(cfg)
meetup.init(cfg)
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function lastSent(pid, name)
  for i = #sent, 1, -1 do if sent[i].pid == pid and sent[i].name == name then return sent[i].data end end
end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(100 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, 1000
end
join(1, "ann") join(2, "bob")
fire("onConsoleInput", "rlsmp market grant ann")
local acc1, acc2 = sessions.get(1).accountId, sessions.get(2).accountId
local function rec(plate, by) theft.records()[plate] = {plate = plate, model = "etk800", color = "red", value = 10000, year = 2003, by = by, t = now, reported = false} end
local function report(pid, plate, d) fire("rlsmpTheftDamage", pid, json.encode({cars = {{plate = plate, damage = d}}})) end
local function garageDo(pid, plate, action, d)
  fire("rlsmpGarageDo", pid, json.encode({action = action, plate = plate, phone = true, damage = d}))
  return lastSent(pid, "rlsmpGarageResult")
end

-- defaults
check(cfg.fence.maxSellDamage == 0.15 and cfg.fence.damageStripPenalty == 0.5, "config defaults")

-- a report is stored for the owner's record only
rec("DMG 111", acc1)
rec("OTH 222", acc2)
check(theft.noteDamage(1, "OTH 222", 0.1) == false and theft.records()["OTH 222"].damage == nil, "somebody else's record is not touched")
check(theft.noteDamage(1, "DMG 111", "x") == false and theft.noteDamage(1, "NOPE", 0.1) == false, "garbage and unknown plates ignored")
report(1, "DMG 111", 0.23)
check(theft.records()["DMG 111"].damage == 0.23 and theft.records()["DMG 111"].dt == now, "damage + time stored")

-- rate limit: a lower or equal value within 2 s is ignored, a higher one counts
report(1, "DMG 111", 0.01)
check(theft.records()["DMG 111"].damage == 0.23, "a lower report within 2 s is ignored")
report(1, "DMG 111", 0.5)
check(theft.records()["DMG 111"].damage == 0.5, "a higher one counts at once")
now = now + 3
report(1, "DMG 111", 0.2)
check(theft.records()["DMG 111"].damage == 0.2, "later reports replace it")
report(1, "DMG 111", 7)
now = now + 3
check(theft.records()["DMG 111"].damage == 1, "clamped to 1")

-- sellBlock: damaged, unchecked, fine
local r = theft.records()["DMG 111"]
local why, code = theft.sellBlock(r)
check(code == "damaged" and why:find("Too damaged to sell: strip it"), "damaged car: strip only")
r.damage, r.dt = 0.15, now
check(theft.sellBlock(r) == nil, "exactly the limit still sells")
r.damage = 0.16
check(select(2, theft.sellBlock(r)) == "damaged", "just over the limit is refused")
r.damage, r.dt = 0.05, now - 121
why, code = theft.sellBlock(r)
check(code == "unchecked" and why:find("Stand next to the car"), "a report older than 2 minutes must be renewed")
r.damage, r.dt = nil, nil
check(select(2, theft.sellBlock(r)) == "unchecked", "never reported: unchecked")
cfg.fence.maxSellDamage = 0.5
r.damage, r.dt = 0.4, now
check(theft.sellBlock(r) == nil, "limit follows the config")
cfg.fence.maxSellDamage = 0.15

-- the garage / phone flow: sell, resell refused, strip pays less
r.damage, r.dt = 0.4, now
local res = garageDo(1, "DMG 111", "sell", 0.4)
check(res.ok == false and res.err:find("Too damaged"), "sell refused when damaged")
res = garageDo(1, "DMG 111", "resell", 0.4)
check(res.ok == false and res.err:find("Too damaged"), "resell refused when damaged")
check(theft.records()["DMG 111"] and sessions.get(1).profile.ledger.money == 1000, "nothing changed")
fire("rlsmpGarageQuote", 1, json.encode({plate = "DMG 111", damage = 0.4}))
local menu = lastSent(1, "rlsmpGarageMenu")
check(menu.ok and menu.canSell == false and menu.damage == 0.4 and menu.sellWhy:find("strip"), "garage menu says why")
check(menu.strip == math.floor(10000 * 0.45 * (1 - 0.5 * 0.4)), "menu strip price is reduced by damage")
res = garageDo(1, "DMG 111", "strip", 0.4)
check(res.ok and res.pay == 3600, "strip still works: 4500 x (1 - 0.5 x 0.4)")
check(theft.records()["DMG 111"] == nil, "record gone after the strip")

-- an undamaged car sells; no report at all needs a check first
rec("OK 333", acc1)
res = garageDo(1, "OK 333", "sell")
check(res.ok == false and res.err:find("Stand next to the car"), "no report yet: stand next to the car")
res = garageDo(1, "OK 333", "sell", 0.1)
check(res.ok and res.pay == 4000, "light damage sells at the full price")

-- the app list shows damage and the reason
rec("APP 444", acc1)
report(1, "APP 444", 0.3)
local list = fence.summary(1)
local e
for _, x in ipairs(list) do if x.plate == "APP 444" then e = x end end
check(e and e.damage == 0.3 and e.canSell == false and e.why:find("strip") and e.strip == math.floor(10000 * 0.45 * 0.85), "summary: damage, canSell, why, reduced strip")
now = now + 200
list = fence.summary(1)
check(list[1].canSell == false and list[1].why:find("Stand next to"), "summary: old report asks to stand next to the car")

-- meetup: black and market for a stolen car
report(1, "APP 444", 0.05)
fire("rlsmpPos", 1, json.encode({x = 0, y = 0, z = 50, speed = 0, chased = false}))
sent = {}
fire("rlsmpMeetupRequest", 1, json.encode({kind = "black", plate = "APP 444", model = "etk800", price = 1000, damage = 0.6}))
check(lastSent(1, "rlsmpMeetupDenied") and lastSent(1, "rlsmpMeetupDenied").err:find("Too damaged") and not lastSent(1, "rlsmpMeetupSet"), "black meetup refused when damaged")
fire("rlsmpMeetupRequest", 1, json.encode({kind = "market", inv = 2, plate = "APP 444", model = "etk800", price = 1000, damage = 0.6}))
check(lastSent(1, "rlsmpMeetupDenied") and lastSent(1, "rlsmpMeetupDenied").err:find("Too damaged"), "Marketplace meetup of a stolen car refused when damaged")
now = now + 10
sent = {}
fire("rlsmpMeetupRequest", 1, json.encode({kind = "black", plate = "APP 444", model = "etk800", price = 1000, damage = 0.02}))
check(lastSent(1, "rlsmpMeetupSet"), "a clean car gets a meetup")

-- restore: the spec carries the damage; the record keeps it
rec("RES 555", acc1)
theft.records()["RES 555"].damage = 0.4
check(recall.spec(theft.records()["RES 555"]).damage == 0.4, "restore spec keeps the recorded damage")

-- admin rules accept the new keys
local admin = require("rlsmp.server.trafficAdmin")
check(admin ~= nil, "admin loads")
print("stolen_damage_test: " .. passed .. " checks passed")
