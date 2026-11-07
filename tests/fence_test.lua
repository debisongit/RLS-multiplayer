-- The fence: server (lua5.3) test. Run: lua5.3 tests/fence_test.lua <tmpdir>
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
-- theft must be on for the fence: switch it on and re-init it (modules read their config at init)
cfg.theft.enabled = true
package.loaded["rlsmp.server.plateRecords"] = {flag = function() return true end}
local sessions = require("rlsmp.server.sessions")
local items = require("rlsmp.server.items")
local market = require("rlsmp.server.market")
local theft = require("rlsmp.server.theft")
local fence = require("rlsmp.server.fence")
theft.init(cfg, tmp .. "/")
fence.init(cfg)
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function join(pid, name, money)
  players[pid] = {name = name, ids = {beammp = tostring(100 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, money or 1000
end
local function say(pid, text) fire("onChatMessage", pid, players[pid].name, text) end
local function last(pid)
  for i = #chat, 1, -1 do if chat[i][1] == pid then return chat[i][2] end end
  return ""
end
local function lastSent(pid, name)
  for i = #sent, 1, -1 do if sent[i].pid == pid and sent[i].name == name then return sent[i].data end end
end
local function disk(pid) return json.decode(io.open(tmp .. "/profiles/" .. (100 + pid) .. ".json"):read("a")) end
local function profile(pid) return sessions.get(pid).profile end
local lastPos = {}
local function standAt(pid, x, y, chased)
  now = math.max(now, (lastPos[pid] or 0) + 1)
  lastPos[pid] = now
  fire("rlsmpPos", pid, json.encode({x = x, y = y, z = 50, speed = 0, chased = chased == true}))
end
local function sell(pid, plate, mode) fire("rlsmpFenceSell", pid, json.encode({plate = plate, mode = mode})) return lastSent(pid, "rlsmpFenceResult") end
local function rec(plate, by, value)
  theft.records()[plate] = {plate = plate, model = "etk800", color = "red", value = value, year = 2003, by = by, t = now, reported = false}
end

join(1, "ann") join(2, "bob") join(3, "cid")
local function accountOf(pid) return sessions.get(pid).accountId end
fire("onConsoleInput", "rlsmp market grant ann")
fire("onConsoleInput", "rlsmp market grant bob")
local spot = market.spotAt(now)
check(spot ~= nil, "a drop spot is active")

-- the list ---------------------------------------------------------------------------------------------------
say(1, "/fence")
check(last(1):find("no stolen cars"), "nothing to sell yet")
rec("AAA 111", accountOf(1), 10000)
rec("BBB 222", accountOf(2), 10000)
say(1, "/fence")
check(last(1):find("drop spot") or last(1):find(spot.name, 1, true), "list ends with where to go")
local q = fence.quotes(1, 10000)
check(q.strip == 3000 and q.sell == 3500 and q.resell == nil and q.gamble == nil, "no papers: strip and sell only")
items.give(1, "fake_plate", 1)
q = fence.quotes(1, 10000)
check(q.gamble == 4500 and q.gamblePapers == 1 and q.resell == nil, "one paper: gamble 45%")
items.give(1, "vin_plate", 1)
check(fence.quotes(1, 10000).gamble == 5250, "two papers: gamble 52.5%")
items.give(1, "part_number", 1)
q = fence.quotes(1, 10000)
check(q.resell == 6000 and q.gamble == 5250 and q.gamblePapers == 2, "three papers: resell 60%, gamble still uses two")
check(fence.quotes(1, 10 ^ 12).strip == 90000, "value cap")
check(fence.quotes(1, "x").strip == 0 and fence.quotes(1, 0 / 0).sell == 0, "garbage value")

-- the ask: the server tells the client to look for the car -----------------------------------------------------
say(1, "/fence strip")
check(lastSent(1, "rlsmpFenceAsk") and lastSent(1, "rlsmpFenceAsk").mode == "strip", "chat asks the client")
say(3, "/fence strip")
check(last(3):find("only deals with black market members"), "non-member refused")

-- refusals ------------------------------------------------------------------------------------------------------
standAt(1, spot.x + 500, spot.y)
local r = sell(1, "AAA 111", "strip")
check(not r.ok and r.err:find("Bring the car"), "too far from the spot")
check(profile(1).ledger.money == 1000 and theft.records()["AAA 111"], "nothing changed")
standAt(1, spot.x, spot.y, true)
r = sell(1, "AAA 111", "strip")
check(not r.ok and r.err:find("police"), "chased")
standAt(1, spot.x, spot.y)
check(not sell(1, "BBB 222", "strip").ok, "somebody else's car")
check(not sell(1, "NOPE", "strip").ok and not sell(1, nil, "strip").ok and not sell(1, "AAA 111", "bogus").ok and not sell(1, "AAA 111", nil).ok, "unknown plate or mode")
check(not sell(1, "AAA\0 111", "strip").ok, "bad plate text")
rec("HHH 888", accountOf(3), 10000)
standAt(3, spot.x, spot.y)
r = sell(3, "HHH 888", "strip")
check(not r.ok and r.err:find("members") and theft.records()["HHH 888"] and profile(3).ledger.money == 1000, "a non-member cannot sell even their own record")
check(profile(1).ledger.money == 1000, "still nothing paid")

-- strip -------------------------------------------------------------------------------------------------------------
r = sell(1, "AAA 111", "strip")
check(r.ok and r.pay == 3000 and r.takeCar and profile(1).ledger.money == 4000, "strip pays 30%")
check(theft.records()["AAA 111"] == nil and items.count(1, "fake_plate") == 1, "record gone, papers kept")
check(lastSent(1, "rlsmpWalletSet").money == 4000, "wallet pushed")
check(disk(1).ledger.money == 4000, "saved to disk")
check(market.rep(1) == 11, "strip gives 1 rep (founder 10)")
check(not sell(1, "AAA 111", "strip").ok, "the same car cannot be sold twice")
check(profile(1).ledger.money == 4000, "no second payment")

-- sell outright -----------------------------------------------------------------------------------------------------
rec("CCC 333", accountOf(1), 20000)
r = sell(1, "CCC 333", "sell")
check(r.ok and r.pay == 7000 and profile(1).ledger.money == 11000, "sell pays the fence rate")

-- resell needs all three papers, uses them up --------------------------------------------------------------------------
rec("DDD 444", accountOf(1), 10000)
items.take(1, "part_number", 1)
r = sell(1, "DDD 444", "resell")
check(not r.ok and r.err:find("Part number kit"), "resell without all papers names what is missing")
check(theft.records()["DDD 444"] and items.count(1, "fake_plate") == 1, "refused: nothing used")
items.give(1, "part_number", 1)
r = sell(1, "DDD 444", "resell")
check(r.ok and r.pay == 6000 and profile(1).ledger.money == 17000, "resell pays 60%")
check(items.count(1, "fake_plate") == 0 and items.count(1, "vin_plate") == 0 and items.count(1, "part_number") == 0, "all three papers used up")
check(disk(1).items == nil or next(disk(1).items) == nil, "papers gone on disk too")
check(market.rep(1) == 11 + 1 + 3, "rep for resell")

-- gamble: needs a paper; safe branch and trap branch ------------------------------------------------------------------------
rec("EEE 555", accountOf(1), 10000)
r = sell(1, "EEE 555", "gamble")
check(not r.ok and r.err:find("at least one"), "gamble without papers refused")
items.give(1, "fake_plate", 2)
fence.setRandom(function() return 0.99 end)
r = sell(1, "EEE 555", "gamble")
check(r.ok and r.pay == 4500 and not r.busted and items.count(1, "fake_plate") == 1, "gamble lucky: pays, one paper used")
rec("FFF 666", accountOf(1), 10000)
local repBefore, moneyBefore = market.rep(1), profile(1).ledger.money
fence.setRandom(function() return 0.01 end)
r = sell(1, "FFF 666", "gamble")
check(r.busted and not r.ok and r.takeCar and r.pay == 0, "gamble trap: busted")
check(profile(1).ledger.money == moneyBefore and theft.records()["FFF 666"] == nil, "trap: no money, car gone")
check(market.rep(1) == repBefore - cfg.market.bustRep, "trap costs reputation")
check(items.count(1, "fake_plate") == 0, "trap: paper used up")
fence.setRandom(nil)

-- theft off: the fence is closed -----------------------------------------------------------------------------------------
cfg.fence.enabled = false
rec("GGG 777", accountOf(1), 10000)
check(not sell(1, "GGG 777", "strip").ok, "fence switched off")
say(1, "/fence")
check(last(1):find("closed"), "chat says closed")
cfg.fence.enabled = true

-- a failing save undoes everything -------------------------------------------------------------------------------------------
local profiles = require("rlsmp.server.profiles")
local realPersist = profiles.persist
profiles.persist = function() return false end
local m0 = profile(1).ledger.money
r = sell(1, "GGG 777", "strip")
check(not r.ok and r.err:find("could not save") and profile(1).ledger.money == m0 and theft.records()["GGG 777"], "failed save: money and record restored")
profiles.persist = realPersist
r = sell(1, "GGG 777", "strip")
check(r.ok, "works again after the save problem")

print(string.format("fence_test: %d checks passed", passed))
