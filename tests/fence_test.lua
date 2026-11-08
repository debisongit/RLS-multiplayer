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
RLSMP.config.ui.chatCommands = true   -- these tests drive the hidden chat fallbacks (the default is off)
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
check(q.strip == 4500 and q.sell == 4000 and q.resell == nil and q.gamble == nil, "no papers: strip and sell only (and never a gamble price)")
items.give(1, "fake_plate", 1)
q = fence.quotes(1, 10000)
check(q.gamble == nil and q.gamblePapers == nil and q.resell == nil, "one paper: still no resell, and no gamble price")
items.give(1, "vin_plate", 1)
items.give(1, "part_number", 1)
q = fence.quotes(1, 10000)
check(q.resell == 7000 and q.gamble == nil, "three papers: resell 70%")
check(fence.quotes(1, 10 ^ 12).strip == 135000, "value cap")
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
check(r.ok and r.pay == 4500 and r.takeCar and profile(1).ledger.money == 5500, "strip pays 45%")
check(theft.records()["AAA 111"] == nil and items.count(1, "fake_plate") == 1, "record gone, papers kept")
check(lastSent(1, "rlsmpWalletSet").money == 5500, "wallet pushed")
check(disk(1).ledger.money == 5500, "saved to disk")
check(market.rep(1) == 11, "strip gives 1 rep (founder 10)")
check(not sell(1, "AAA 111", "strip").ok, "the same car cannot be sold twice")
check(profile(1).ledger.money == 5500, "no second payment")

-- sell outright -----------------------------------------------------------------------------------------------------
rec("CCC 333", accountOf(1), 20000)
r = sell(1, "CCC 333", "sell")
check(r.ok and r.pay == 8000 and profile(1).ledger.money == 13500, "sell pays the fence rate")

-- resell needs all three papers, uses them up --------------------------------------------------------------------------
rec("DDD 444", accountOf(1), 10000)
items.take(1, "part_number", 1)
r = sell(1, "DDD 444", "resell")
check(not r.ok and r.err:find("Part number kit"), "resell without all papers names what is missing")
check(theft.records()["DDD 444"] and items.count(1, "fake_plate") == 1, "refused: nothing used")
items.give(1, "part_number", 1)
r = sell(1, "DDD 444", "resell")
check(r.ok and r.pay == 7000 and profile(1).ledger.money == 20500, "resell pays 70%")
check(items.count(1, "fake_plate") == 0 and items.count(1, "vin_plate") == 0 and items.count(1, "part_number") == 0, "all three papers used up")
check(disk(1).items == nil or next(disk(1).items) == nil, "papers gone on disk too")
check(market.rep(1) == 11 + 1 + 3, "rep for resell")

-- there is no gamble any more
rec("EEE 555", accountOf(1), 10000)
items.give(1, "fake_plate", 1)
r = sell(1, "EEE 555", "gamble")
check(not r.ok and r.err:find("Unknown way") and theft.records()["EEE 555"] and items.count(1, "fake_plate") == 1, "gamble: refused as an unknown way, car and paper kept")
check(fence.MODES[1] == "strip" and #fence.MODES == 3, "the ways are strip, sell and resell")
items.take(1, "fake_plate", 1)
theft.take("EEE 555")

-- a car the game had no price for still sells, at the floor value
rec("ZERO 000", accountOf(1), 0)
r = sell(1, "ZERO 000", "strip")
check(r.ok and r.pay == 900, "value 0: the floor (2000) is used, strip pays 900")

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

-- Garage flow (the RLS garage computer button): no drop spot needed ------------------------------------------------------------
local function gquote(pid, body) fire("rlsmpGarageQuote", pid, json.encode(body)) return lastSent(pid, "rlsmpGarageMenu") end
local function gdo(pid, body) fire("rlsmpGarageDo", pid, json.encode(body)) return lastSent(pid, "rlsmpGarageResult") end
standAt(1, spot.x + 900, spot.y + 900)      -- far from any spot and not chased
profile(1).ledger.money = 1000
for k in pairs(profile(1).items or {}) do profile(1).items[k] = nil end
rec("GAR 001", accountOf(1), 10000)
rec("GAR 002", accountOf(2), 10000)
now = now + 5
local m = gquote(1, {plate = "GAR 001", model = "etk800", value = 1})
check(m.ok and m.kind == "stolen" and m.strip == 4500, "menu: stolen car priced from the server record, not the client value")
check(#m.fit == 0, "menu: nothing to fit without items")
now = now + 5
m = gquote(1, {plate = "GAR 002"})
check(not m.ok and m.err:find("somebody else"), "menu: somebody else's stolen plate refused")
now = now + 5
m = gquote(1, {})
check(m.ok and m.items ~= nil and m.kind == nil, "menu without a car is just the item list")
now = now + 5
m = gquote(3, {plate = "GAR 001"})
check(m.ok == false or m.kind ~= "stolen", "a non-member never gets a stolen menu")

-- fitting
items.give(1, "fake_plate", 1)
items.give(1, "vin_plate", 1)
now = now + 5
m = gquote(1, {plate = "GAR 001"})
check(#m.fit == 2 and m.fit[1].name == "fake_plate", "menu offers the two papers the player owns")
local r2 = gdo(1, {action = "fit:fake_plate", plate = "GAR 001"})
check(r2.ok and items.count(1, "fake_plate") == 0 and theft.records()["GAR 001"].papers.fake_plate, "fit: item used up, record marked")
check(not gdo(1, {action = "fit:fake_plate", plate = "GAR 001"}).ok, "cannot fit the same paper twice")
check(not gdo(1, {action = "fit:part_number", plate = "GAR 001"}).ok and not gdo(1, {action = "fit:bogus", plate = "GAR 001"}).ok, "no item / unknown part refused")
check(not gdo(1, {action = "fit:vin_plate", plate = "GAR 002"}).ok and items.count(1, "vin_plate") == 1, "cannot fit onto somebody else's car")
check(not gdo(1, {action = "fit:vin_plate", plate = "NOPE 9"}).ok and items.count(1, "vin_plate") == 1, "cannot fit onto an ordinary car")
check(disk(1).items == nil or disk(1).items.fake_plate == nil, "fitted item gone on disk")
-- fitted papers count at the fence
q = fence.quotes(1, 10000, theft.records()["GAR 001"])
check(q.gamble == nil and q.resell == nil, "quote counts fitted + owned papers (no resell yet with two)")
items.give(1, "part_number", 1)
q = fence.quotes(1, 10000, theft.records()["GAR 001"])
check(q.resell == 7000, "fitted + owned papers together allow a resell")
standAt(1, spot.x, spot.y)
r = sell(1, "GAR 001", "resell")
check(r.ok and r.pay == 7000 and items.count(1, "vin_plate") == 0 and items.count(1, "part_number") == 0 and items.count(1, "fake_plate") == 0,
  "resell uses the fitted paper (already used up) plus the two items")
standAt(1, spot.x + 900, spot.y + 900)

-- strip a stolen car from the garage
rec("GAR 003", accountOf(1), 10000)
local before = profile(1).ledger.money
local sd = gdo(1, {action = "strip", plate = "GAR 003"})
check(sd.ok and sd.pay == 4500 and sd.takeCar and profile(1).ledger.money == before + 4500 and theft.records()["GAR 003"] == nil, "garage strip of a stolen car pays 45%, no drop spot needed")
check(lastSent(1, "rlsmpWalletSet").money == before + 4500, "wallet pushed")
-- sell / resell from the garage too (no drop spot)
rec("GAR 006", accountOf(1), 10000)
now = now + 5
m = gquote(1, {plate = "GAR 006"})
check(m.sell == 4000 and m.resell == nil and m.gamble == nil and m.trap == nil, "menu: sell price, no resell without papers, no gamble")
check(not gdo(1, {action = "resell", plate = "GAR 006"}).ok and not gdo(1, {action = "gamble", plate = "GAR 006"}).ok and theft.records()["GAR 006"],
  "garage resell refused without papers and gamble refused as unknown, car kept")
check(not gdo(1, {action = "sell", plate = "MYCAR 1", value = 5000}).ok, "garage sell is for stolen cars only")
items.give(1, "fake_plate", 1)
now = now + 5
m = gquote(1, {plate = "GAR 006"})
check(m.gamble == nil and m.resell == nil, "menu: one paper changes nothing for the prices")
before = profile(1).ledger.money
local gs = gdo(1, {action = "sell", plate = "GAR 006"})
check(gs.ok and gs.action == "sell" and gs.pay == 4000 and gs.takeCar and profile(1).ledger.money == before + 4000 and theft.records()["GAR 006"] == nil,
  "garage sell pays the fence rate and takes the car")
-- chased players cannot strip a stolen car
rec("GAR 004", accountOf(1), 10000)
standAt(1, spot.x + 900, spot.y + 900, true)
check(not gdo(1, {action = "strip", plate = "GAR 004"}).ok and theft.records()["GAR 004"], "chased: stolen strip refused")
standAt(1, spot.x + 900, spot.y + 900)
-- non-member stolen
rec("GAR 005", accountOf(3), 10000)
check(not gdo(3, {action = "strip", plate = "GAR 005"}).ok and theft.records()["GAR 005"], "non-member cannot strip a stolen car")

-- strip an ordinary garage car: value from the client, capped, rate limited
before = profile(1).ledger.money
now = now + 30
sd = gdo(1, {action = "strip", plate = "MYCAR 1", model = "covet", value = 5000, inventoryId = 7})
check(sd.ok and sd.pay == 2250 and sd.takeCar and sd.inventoryId == 7 and profile(1).ledger.money == before + 2250, "owned car strip pays 45% of the client value")
check(disk(1).ledger.money == before + 2250, "owned strip saved to disk")
check(not gdo(1, {action = "strip", plate = "MYCAR 2", value = 5000}).ok, "second strip right away is refused (cooldown)")
now = now + 30
sd = gdo(1, {action = "strip", plate = "MYCAR 2", value = 10 ^ 12})
check(sd.ok and sd.pay == 135000, "absurd value is capped")
now = now + 30
sd = gdo(1, {action = "strip", value = 0})
check(sd.ok and sd.pay == 900, "no price: the floor value is used")
now = now + 30
check(not gdo(1, {action = "fit:fake_plate", plate = "MYCAR 3"}).ok, "no fitting on ordinary cars")
check(not gdo(1, {action = "weird"}).ok and not gdo(1, {}).ok and gdo(1, {action = 5}).ok == false, "garbage actions refused")
-- failing save
local realP = profiles.persist
profiles.persist = function() return false end
m0 = profile(1).ledger.money
now = now + 30
check(not gdo(1, {action = "strip", value = 1000}).ok and profile(1).ledger.money == m0, "failed save: owned strip pays nothing")
profiles.persist = realP
-- switched off
cfg.fence.garage = false
now = now + 30
check(not gdo(1, {action = "strip", value = 1000}).ok, "garage switched off in config")
cfg.fence.garage = true

-- the value is never below minValue and never above maxValue (or the model's cap)
rec("LOW 111", accountOf(1), 500)
standAt(1, spot.x, spot.y)
local lr = sell(1, "LOW 111", "strip")
check(lr.pay == 900, "value under minValue is lifted to it " .. tostring(lr.err))
check(theft.capValue("bastion", 10 ^ 9) == 300000 and theft.capValue("bastion", 25000) == 25000, "theft cap: fence.maxValue, plausible values pass")
cfg.fence.modelCaps = {bastion = 40000}
check(theft.capValue("bastion", 90000) == 40000 and theft.capValue("covet", 90000) == 90000, "theft cap: per model")
cfg.fence.modelCaps = {}

-- a stale price is refreshed before it is paid (only when the player's game has shown it can answer) ----------------------------
do
  join(3, "cid", 1000)
  fire("onConsoleInput", "rlsmp market grant cid")
  rec("CCC 333", accountOf(3), 10000)
  local cr = theft.records()["CCC 333"]
  cr.valueSource, cr.vt = "rls valuation", now - 3600
  items.give(3, "fake_plate", 1)
  standAt(3, spot.x, spot.y)
  local s3 = fence.summary(3)
  check(lastSent(3, "rlsmpTheftReprice") ~= nil, "the app list asks the game for a new price")
  local mineRow
  for _, row in ipairs(s3) do if row.plate == "CCC 333" then mineRow = row end end
  check(mineRow and mineRow.age >= 3600, "the app list says how old the price is")
  cr.vt = now - 3600
  local before = cr.value
  local r3 = sell(3, "CCC 333", "sell")
  check(r3.ok ~= nil, "an old game that never answered still sells")
  rec("DDD 444", accountOf(3), 10000)
  local dr = theft.records()["DDD 444"]
  dr.valueSource, dr.vt = "rls valuation", now - 3600
  fire("rlsmpTheftValue", 3, json.encode({plate = "DDD 444", value = 10000, source = "x"}))   -- the game can answer now
  dr.vt = now - 3600
  local nowAsked = #sent
  r3 = sell(3, "DDD 444", "strip")
  check(r3.ok == false and r3.err:find("market"), "stale price: the sale waits for a fresh one")
  check(#sent > nowAsked, "and the game is asked")
  fire("rlsmpTheftValue", 3, json.encode({plate = "DDD 444", value = 12000, source = "rls valuation"}))
  r3 = sell(3, "DDD 444", "strip")
  check(r3.ok == true and r3.pay == 5400, "after the answer it pays by the new value")
end


-- the phone: every stolen car has its own buttons, no drop spot, the same server rules --------------------------------------------------
standAt(1, spot.x + 900, spot.y + 900)             -- far from the drop spot
for _, n0 in ipairs({"fake_plate", "vin_plate", "part_number"}) do local c0 = items.count(1, n0) if c0 > 0 then items.take(1, n0, c0) end end
rec("PH 001", accountOf(1), 10000)
rec("PH 002", accountOf(1), 10000)
now = now + 5
local row
for _, r0 in ipairs(fence.summary(1)) do if r0.plate == "PH 001" then row = r0 end end
check(row and row.strip == 4500 and row.sell == 4000 and row.gamble == nil and type(row.fit) == "table" and #row.fit == 0 and #row.fitted == 0, "the app list: prices, no gamble, nothing to fit yet")
items.give(1, "fake_plate", 1)
items.give(1, "vin_plate", 1)
for _, r0 in ipairs(fence.summary(1)) do if r0.plate == "PH 001" then row = r0 end end
check(#row.fit == 2 and row.fit[1].name == "fake_plate" and row.fit[2].name == "vin_plate" and row.fit[1].label == "Fake plate", "the app list offers the papers the player owns")
local ph = gdo(1, {action = "fit:fake_plate", plate = "PH 001", phone = true})
check(ph.ok and ph.fitted == "Fake plate" and items.count(1, "fake_plate") == 0, "phone: fit a paper (no drop spot)")
for _, r0 in ipairs(fence.summary(1)) do if r0.plate == "PH 001" then row = r0 end end
check(#row.fit == 1 and row.fitted[1] == "Fake plate", "...and the list shows it as fitted")
before = profile(1).ledger.money
ph = gdo(1, {action = "strip", plate = "PH 001", phone = true})
check(ph.ok and ph.pay == 4500 and ph.takeCar and profile(1).ledger.money == before + 4500 and theft.records()["PH 001"] == nil, "phone: strip a stolen car far from the drop spot")
before = profile(1).ledger.money
ph = gdo(1, {action = "sell", plate = "PH 002", phone = true})
check(ph.ok and ph.pay == 4000 and theft.records()["PH 002"] == nil, "phone: sell a stolen car far from the drop spot")
check(not gdo(1, {action = "sell", plate = "PH 001", phone = true}).ok, "phone: a car that is already gone cannot be sold twice")
rec("PH 003", accountOf(1), 10000)
check(not gdo(1, {action = "resell", plate = "PH 003", phone = true}).ok and theft.records()["PH 003"], "phone: resell needs the papers, the car is kept")
check(not gdo(1, {action = "gamble", plate = "PH 003", phone = true}).ok, "phone: there is no gamble")
rec("PH 004", accountOf(2), 10000)
check(not gdo(1, {action = "sell", plate = "PH 004", phone = true}).ok and theft.records()["PH 004"], "phone: somebody else's stolen car cannot be sold")
cfg.fence.phone = false
check(not gdo(1, {action = "sell", plate = "PH 003", phone = true}).ok and gdo(1, {action = "sell", plate = "PH 003", phone = true}).err:find("phone"), "fence.phone = false: the phone path is refused")
check(gdo(1, {action = "sell", plate = "PH 003"}).ok, "...while the garage path (no phone flag) still works")
cfg.fence.phone = true
standAt(1, spot.x + 900, spot.y + 900, true)
rec("PH 005", accountOf(1), 10000)
check(not gdo(1, {action = "strip", plate = "PH 005", phone = true}).ok and theft.records()["PH 005"], "phone: not while the police chase you")
standAt(1, spot.x + 900, spot.y + 900)

print(string.format("fence_test: %d checks passed", passed))
