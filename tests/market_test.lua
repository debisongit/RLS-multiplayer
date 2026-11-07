-- Black market: server (lua5.3) test. Run: lua5.3 tests/market_test.lua <tmpdir>
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
local sessions = require("rlsmp.server.sessions")
local items = require("rlsmp.server.items")
local market = require("rlsmp.server.market")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function join(pid, name, money)
  players[pid] = {name = name, ids = {beammp = tostring(100 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  if money ~= false then s.profile.ledger.seeded, s.profile.ledger.money = true, money or 100000 end
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
local function standAt(pid, x, y)
  now = math.max(now, (lastPos[pid] or 0) + 1)   -- the positions module keeps one report per second
  lastPos[pid] = now
  fire("rlsmpPos", pid, json.encode({x = x, y = y, z = 50, speed = 0, chased = false}))
end

-- fixed delay for the tests
cfg.market.minDelaySeconds, cfg.market.maxDelaySeconds = 60, 60

join(1, "ann") join(2, "bob") join(3, "cid") join(4, "dan", 500)

-- Nobody is in until the console grants it -----------------------------------------------------------
say(1, "/market")
check(last(1):find("not in the black market"), "non-member help")
say(1, "/market list")
check(last(1):find("Members only"), "list is members only")
say(1, "/market buy screwdriver")
check(last(1):find("Members only") and profile(1).ledger.money == 100000, "non-member cannot buy")
check(fire("onConsoleInput", "rlsmp market grant nobody"):find("not online"), "grant needs an online player")
check(fire("onConsoleInput", "rlsmp market"):find("grant"), "console usage")
check(fire("onConsoleInput", "rlsmp market grant ann"):find("member"), "grant ann")
check(market.isMember(1) and market.rep(1) == cfg.market.founderRep, "founder rep")
check(disk(1).market.member == true, "grant saved")
say(1, "/market")
check(last(1):find("Commands"), "member help")
check(chat[#chat - 1][2]:find("Reputation 10%. Invites left 3"), "help shows rep and invites (2 + 1 per 10 rep)")

-- Invites ------------------------------------------------------------------------------------------
say(2, "/market invite cid")
check(last(2):find("Members only"), "non-member cannot invite")
say(2, "/market accept")
check(last(2):find("No open invite"), "accept without invite")
say(1, "/market invite ann")
check(last(1):find("not online"), "cannot invite yourself")
say(1, "/market invite nobody")
check(last(1):find("not online"), "unknown player")
say(1, "/market invite BOB")
check(last(2):find("invited you") and profile(1).market.invites == 1 and disk(1).market.invites == 1, "invite reserved and saved")
say(1, "/market invite bob")
check(last(1):find("already has an invite") and profile(1).market.invites == 1, "no double invite")
say(3, "/market accept")
check(last(3):find("No open invite"), "someone else cannot take bob's invite")
say(2, "/market accept")
check(market.isMember(2) and market.rep(2) == cfg.market.startRep and disk(2).market.invitedBy == "ann", "bob joined")
check(last(1):find("bob accepted"), "inviter told")
say(1, "/market invite bob")
check(last(1):find("already in"), "member cannot be invited")
-- expired invite: given back while the inviter is online
say(1, "/market invite cid")
check(profile(1).market.invites == 2, "second invite reserved")
now = now + cfg.market.inviteSeconds + 1
market._tick()
check(profile(1).market.invites == 1 and last(1):find("get it back"), "expired invite refunded")
say(3, "/market accept")
check(not market.isMember(3), "expired invite cannot be accepted")
-- expired but not swept yet, then invited again: the first reservation is given back
say(1, "/market invite cid")
check(profile(1).market.invites == 2, "re-invite reserved")
now = now + cfg.market.inviteSeconds + 1
say(1, "/market invite cid")
check(profile(1).market.invites == 2, "unswept expired invite refunded before the new one")
-- invitee made a member by the console meanwhile: accept gives the slot back
fire("onConsoleInput", "rlsmp market grant cid")
say(3, "/market accept")
check(last(3):find("already in") and profile(1).market.invites == 1, "accept when already in: slot refunded")
fire("onConsoleInput", "rlsmp market revoke cid")
check(not market.isMember(3) and disk(3).market.member == false, "console revoke")
-- limit: bob has 2 invites at rep 0
say(2, "/market invite cid")
say(2, "/market invite dan")
check(profile(2).market.invites == 2, "bob used two")
players[5] = nil
join(5, "eve")
say(2, "/market invite eve")
check(last(2):find("No invites left") and profile(2).market.invites == 2, "invite limit")
-- invitee leaves: the reservation comes back to the online inviter
fire("onPlayerDisconnect", 4)
market._tick()
check(profile(2).market.invites == 1, "invitee left: refunded")
say(3, "/market accept")
check(market.isMember(3), "cid joined")
check(market.invitesAllowed({rep = 100, invites = 0}) == cfg.market.maxInvites, "invites are capped")

-- Reputation ---------------------------------------------------------------------------------------
check(market.addRep(5, 5, "x") == nil, "addRep: non-member ignored")
check(market.addRep(2, "abc") == nil and market.addRep(2, 0 / 0) == nil and market.addRep(2, math.huge) == nil, "addRep: bad input")
check(market.addRep(2, 1000, "big job") == cfg.market.maxRepChange, "addRep capped per call")
check(chat[#chat - 1][2]:find("Reputation %+25") and last(2):find("unlocked"), "rep change told, unlock told")
check(disk(2).market.rep == 25, "rep saved")
check(market.lossRep(2, 5, "messed up") == 20, "lossRep")
check(market.lossRep(2, -5, "sign ignored") == 15, "lossRep always loses")
check(market.lossRep(2, 25) == 0 and market.lossRep(2, 25) == 0, "rep never below 0")
check(market.lossRep(2, "x") == nil, "lossRep bad input")
market.addRep(2, 3.7, "fraction")
check(market.rep(2) == 3, "whole numbers only")

-- Buying: rep gating, bad input, catalog only --------------------------------------------------------
say(2, "/market list")
check(chat[#chat - 1][2]:find("Screwdriver") and not chat[#chat - 1][2]:find("Key programmer"), "list shows only what rep allows")
check(last(2):find("next at 10"), "list hints at the next tier")
say(2, "/market buy key_programmer")
check(last(2):find("needs reputation 10") and profile(2).ledger.money == 100000, "rep gate")
say(2, "/market buy")
check(last(2):find("Usage"), "buy without item")
say(2, "/market buy magic_wand")
check(last(2):find("Usage"), "unknown item")
cfg.market.tiers.magic_wand = {price = 1, minRep = 0}
say(2, "/market buy magic_wand")
check(last(2):find("Usage") and market.offer("magic_wand") == nil, "a tier entry that is not in items.CATALOG is never sold")
cfg.market.tiers.magic_wand = nil
say(2, "/market buy screwdriver 2")
check(last(2):find("one lasts forever"), "tools: one only")
say(2, "/market buy fake_plate 11")
check(last(2):find("1 to 10"), "count limit")
say(2, "/market buy fake_plate 0")
check(last(2):find("1 to 10"), "count zero")
say(2, "/market buy fake_plate -1")
check(last(2):find("Usage"), "negative count")
cfg.market.tiers.window_punch.off = true
say(2, "/market buy window_punch")
check(last(2):find("Usage"), "switched-off item")
cfg.market.tiers.window_punch.off = nil
profile(3).ledger.money = 100
say(3, "/market buy screwdriver")
check(last(3):find("costs %$400") and profile(3).ledger.money == 100 and #profile(3).market.orders == 0, "not enough money")
profile(3).ledger.seeded = false
profile(3).ledger.money = 100000
say(3, "/market buy screwdriver")
check(last(3):find("first save") and #profile(3).market.orders == 0, "unseeded wallet refused")
profile(3).ledger.seeded = true

-- Buy: debited and order in the same saved file --------------------------------------------------------
local expectSpot = market.spotAt(now + 60)
say(2, "/market buy fake_plate 3")
local o = profile(2).market.orders[1]
check(profile(2).ledger.money == 100000 - 4500, "money debited")
check(o and o.item == "fake_plate" and o.n == 3 and o.price == 4500 and o.readyAt == now + 60, "order created")
check(o.spot.name == expectSpot.name and o.spot.x == expectSpot.x, "spot = the one active when it is ready")
local d = disk(2)
check(d.ledger.money == 95500 and d.market.orders[1].id == o.id, "debit and order on disk together")
check(lastSent(2, "rlsmpWalletSet").money == 95500 and lastSent(2, "rlsmpWalletSet").why == "market", "wallet pushed")
local drop = lastSent(2, "rlsmpMarketDrop")
check(drop.id == o.id and drop.spot == expectSpot.name and drop.readyIn == 60 and drop.label == "Fake plate", "client told the drop")
check(last(2):find(expectSpot.name, 1, true), "player told the spot name")
say(2, "/market buy screwdriver")
check(#profile(2).market.orders == 2, "second order")
say(2, "/market buy screwdriver")
check(last(2):find("already have"), "tool already on order")
say(2, "/market buy fake_plate")
say(2, "/market buy fake_plate")
check(last(2):find("open orders first") and #profile(2).market.orders == 3, "open order limit")

-- Pickup ---------------------------------------------------------------------------------------------
local sp = o.spot
standAt(2, sp.x, sp.y)
say(2, "/market pickup")
check(last(2):find("not there yet") and items.count(2, "fake_plate") == 0, "not before readyAt")
now = o.readyAt
market._tick()
check(last(2):find("waiting at"), "ready message")
local told = #chat
market._tick()
check(#chat == told, "ready message only once")
standAt(2, sp.x + 500, sp.y)
say(2, "/market pickup")
check(last(2):find("No package here") and last(2):find("500 m"), "far away: refused with distance")
check(items.count(2, "fake_plate") == 0, "nothing given far away")
standAt(2, sp.x + 10, sp.y + 5)
now = now + cfg.market.positionMaxAge + 1
say(2, "/market pickup")
check(last(2):find("no fresh position"), "stale position refused")
standAt(2, sp.x + 10, sp.y + 5)
fire("rlsmpPos", 2, json.encode({x = sp.x, y = sp.y, z = 50, speed = 0, chased = true}))
now = now + 1
fire("rlsmpPos", 2, json.encode({x = sp.x, y = sp.y, z = 50, speed = 0, chased = true}))
say(2, "/market pickup")
check(last(2):find("police"), "not during a chase")
now = now + 1
fire("rlsmpPos", 2, json.encode({x = sp.x + 10, y = sp.y + 5, z = 50, speed = 0, chased = false}))
lastPos[2] = now
local before = #profile(2).market.orders
say(2, "/market pickup")
check(before == 3 and items.count(2, "fake_plate") == 4 and items.has(2, "screwdriver") and last(2):find("Picked up"),
  "all ready packages at this spot picked up")
check(#profile(2).market.orders == 0, "orders gone")
check(lastSent(2, "rlsmpMarketClear") ~= nil, "client told to clear")
check(disk(2).items.fake_plate == 4, "items on disk")
for _, left in ipairs(disk(2).market.orders) do check(left.id ~= o.id, "order removed on disk") end
local have = items.count(2, "fake_plate")
say(2, "/market pickup")
check(items.count(2, "fake_plate") == have, "duplicate pickup impossible")

-- Persistence over a rejoin --------------------------------------------------------------------------
say(2, "/market buy window_punch")
local openOrders = #profile(2).market.orders
check(openOrders == 1, "a new open order")
fire("onPlayerDisconnect", 2)
join(2, "bob", false)
check(profile(2).ledger.money == disk(2).ledger.money and profile(2).ledger.money < 95500, "money kept")
check(market.isMember(2) and market.rep(2) == 3 and #profile(2).market.orders == openOrders, "membership, rep, orders survive a rejoin")
sent = {}
market._tick()
local resent = 0
for _, m in ipairs(sent) do if m.pid == 2 and m.name == "rlsmpMarketDrop" then resent = resent + 1 end end
check(resent == openOrders, "drops re-sent after a join")
sent = {}
market._tick()
check(#sent == 0, "re-sent only once")

-- Bust -----------------------------------------------------------------------------------------------
market.addRep(2, 20, "job")
items.give(2, "screwdriver")
local r = market.bust(2)
check(r.rep == 23 - cfg.market.bustRep and not r.expelled and market.isMember(2), "bust costs rep")
check(items.count(2, "fake_plate") == 0 and items.has(2, "screwdriver"), "bust takes papers, keeps tools")
r = market.bust(2, {takeTools = true, rep = 5})
check(r.rep == 8 and not items.has(2, "screwdriver"), "bust options")
r = market.bust(2)
check(r.expelled and not market.isMember(2) and disk(2).market.member == false, "a bust you cannot pay throws you out")
say(2, "/market buy screwdriver")
check(last(2):find("Members only"), "expelled cannot buy")
say(2, "/market orders")
check(last(2):find("Window punch"), "expelled still sees paid orders")
now = now + 61
standAt(2, profile(2).market.orders[1].spot.x, profile(2).market.orders[1].spot.y)
say(2, "/market pickup")
check(items.has(2, "window_punch"), "expelled can still pick up a paid order")
check(market.bust(99) == nil, "bust of unknown player")
r = market.bust(5)
check(r and r.member == false, "bust of a non-member only takes items")

-- Spot rotation --------------------------------------------------------------------------------------
local period = cfg.market.rotateMinutes * 60
local t0 = 1800 * 2000
local a = market.spotAt(t0)
check(market.spotAt(t0 + period - 1).name == a.name, "same spot inside one period")
check(market.spotAt(t0).name == a.name, "deterministic")
local changed, seen = 0, {}
for k = 0, 40 do
  local x, y = market.spotAt(t0 + k * period), market.spotAt(t0 + (k + 1) * period)
  seen[x.name] = true
  if x.name ~= y.name then changed = changed + 1 end
end
check(changed == 41, "never the same spot two periods in a row")
local kinds = 0
for _ in pairs(seen) do kinds = kinds + 1 end
check(kinds == #cfg.market.dropSpots, "every spot gets used")
local saved = cfg.market.dropSpots
for _, n in ipairs({2, 3, 5, 7}) do
  local list = {}
  for i = 1, n do list[i] = {name = "s" .. i, x = i, y = 0, z = 0} end
  cfg.market.dropSpots = list
  local repeats, used = 0, {}
  for k = 0, 500 do
    local x, y = market.spotAt(t0 + k * period), market.spotAt(t0 + (k + 1) * period)
    used[x.name] = true
    if x.name == y.name then repeats = repeats + 1 end
  end
  local u = 0
  for _ in pairs(used) do u = u + 1 end
  check(repeats == 0 and u == n, n .. " spots: never twice in a row, all used")
end
cfg.market.dropSpots = {{name = "only", x = 1, y = 2, z = 3}, {name = "bad", x = "no", y = 0, z = 0}}
check(market.spotAt(t0).name == "only" and market.spotAt(t0 + period).name == "only", "one valid spot, bad ones skipped")
cfg.market.dropSpots = {}
check(market.spotAt(t0) == nil, "no spots")
say(3, "/market buy screwdriver")
check(last(3):find("No drop spots") and profile(3).ledger.money == 100000, "no spots: nothing charged")
cfg.market.dropSpots = saved

-- Fence ----------------------------------------------------------------------------------------------
check(market.fenceQuote(10000) == 3500, "fence car")
check(market.fenceQuote({value = 1000, kind = "part"}) == 300, "fence part")
check(market.fenceQuote({value = 1000}) == 350, "fence table defaults to car")
check(market.fenceQuote(-5) == 0 and market.fenceQuote("x") == 0 and market.fenceQuote(0 / 0) == 0 and market.fenceQuote(nil) == 0, "fence bad input")
say(3, "/market fence")
check(last(3):find("35%%") and last(3):find("car theft"), "fence stub explains")

-- Phone app channel ------------------------------------------------------------------------------------------
join(5, "eve") join(6, "fay")
local function app(pid, ev, t) now = now + 2 fire(ev, pid, json.encode(t or {})) end
local function chatCount() return #chat end
app(5, "rlsmpMarketGet")
local st = lastSent(5, "rlsmpMarketState")
check(st and st.ready and st.member == false and st.items == nil and st.money == 100000, "app: a non-member gets no shop")
fire("onConsoleInput", "rlsmp market grant eve")
app(5, "rlsmpMarketGet")
st = lastSent(5, "rlsmpMarketState")
check(st.member and st.rep == 10 and st.invitesLeft == 3 and #st.items >= 8 and st.spot ~= nil, "app: a member gets rep, invites, items, the active spot")
local screw
for _, it in ipairs(st.items) do if it.name == "screwdriver" then screw = it end end
check(screw and screw.price == 400 and screw.locked == false and screw.durable == true and screw.have == 0, "app: item rows carry price, lock state, ownership")
local lockedRow
for _, it in ipairs(st.items) do if it.name == "jammer" then lockedRow = it end end
check(lockedRow and lockedRow.locked == true and lockedRow.minRep == 50, "app: a high tier item shows as locked")
-- buying through the app: same rules, same money, the text comes back instead of chat
local chats = chatCount()
app(5, "rlsmpMarketAct", {a = "buy", item = "screwdriver", n = 1})
local res = lastSent(5, "rlsmpMarketResult")
check(res and res.text:find("Paid") and chatCount() == chats, "app: buy answers in the app, nothing goes to chat")
check(profile(5).ledger.money == 100000 - 400 and #profile(5).market.orders == 1, "app: the money and the order are the normal ones")
st = lastSent(5, "rlsmpMarketState")
check(#st.orders == 1 and st.orders[1].item == "screwdriver" and st.orders[1].ready == false and st.money == 99600, "app: a fresh state follows the action")
app(5, "rlsmpMarketAct", {a = "buy", item = "screwdriver", n = 1})
check(lastSent(5, "rlsmpMarketResult").text:find("already have"), "app: refusals come back as text too")
app(5, "rlsmpMarketAct", {a = "buy", item = "jammer", n = 1})
check(lastSent(5, "rlsmpMarketResult").text:find("reputation"), "app: the rep gate holds")
app(5, "rlsmpMarketAct", {a = "buy", item = "nonsense", n = 99999})
check(lastSent(5, "rlsmpMarketResult").text:find("Usage"), "app: junk item is refused")
check(profile(5).ledger.money == 99600, "app: junk charged nothing")
app(5, "rlsmpMarketAct", {a = "teleport"})
local before = lastSent(5, "rlsmpMarketResult")
app(5, "rlsmpMarketAct", "not a table")
app(5, "rlsmpMarketAct", {a = 5})
check(lastSent(5, "rlsmpMarketResult") == before, "app: unknown actions and garbage are ignored")
-- a non-member cannot buy through the app
app(6, "rlsmpMarketAct", {a = "buy", item = "screwdriver", n = 1})
check(lastSent(6, "rlsmpMarketResult").text:find("Members only") and profile(6).ledger.money == 100000, "app: non-member refused")
-- invite and accept through the app
app(5, "rlsmpMarketAct", {a = "invite", who = "fay"})
check(lastSent(5, "rlsmpMarketResult").text:find("Invited fay"), "app: invite")
app(6, "rlsmpMarketGet")
st = lastSent(6, "rlsmpMarketState")
check(st.member == false and st.invite and st.invite.from == "eve", "app: the invited player sees the invite")
app(6, "rlsmpMarketAct", {a = "accept"})
check(lastSent(6, "rlsmpMarketResult").text:find("You are in") and lastSent(6, "rlsmpMarketState").member == true, "app: accept")
-- pickup: not there yet, then at the spot
app(5, "rlsmpMarketAct", {a = "pickup"})
check(lastSent(5, "rlsmpMarketResult").text:find("not there yet") or lastSent(5, "rlsmpMarketResult").text:find("position"), "app: pickup too early")
-- one request per second, a click is not eaten by a refresh in the same second
now = now + 2
fire("rlsmpMarketGet", 5, "{}")
local n0 = #sent
fire("rlsmpMarketGet", 5, "{}")
check(#sent == n0, "app: refresh flood answered once per second")
fire("rlsmpMarketAct", 5, json.encode({a = "pickup"}))
check(lastSent(5, "rlsmpMarketResult") ~= before and #sent > n0, "app: an action right after a refresh still works")
cfg.market.enabled = false
local n1 = #sent
app(5, "rlsmpMarketGet")
app(5, "rlsmpMarketAct", {a = "pickup"})
check(#sent == n1, "app: closed market answers nothing")
cfg.market.enabled = true

-- Switched off ---------------------------------------------------------------------------------------
cfg.market.enabled = false
say(3, "/market list")
check(last(3):find("closed"), "disabled")
cfg.market.enabled = true

print("market_test: " .. passed .. " checks passed")
