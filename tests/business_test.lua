-- Business module test with a fake BeamMP. Run: lua5.3 tests/business_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

local players, chat, sent = {}, {}, {}
MP = {
  RegisterEvent = function() end,
  CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end,
  SendChatMessage = function(pid, text) chat[pid] = chat[pid] or {} table.insert(chat[pid], text) end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000
util.setClock(function() return now end)
onInit()

local sessions = require("rlsmp.server.sessions")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function say(pid, msg) return fire("onChatMessage", pid, players[pid].name, msg) end
local function last(pid) local c = chat[pid] or {} return c[#c] or "" end

-- Join a player and put them straight into "loaded" with some money.
local function join(pid, name, acct, money)
  players[pid] = {name = name, ids = {beammp = acct}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, money
end

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg .. " | last chat: " .. last(1) .. " / " .. last(2), 2) end passed = passed + 1 end

join(1, "alice", "101", 1000)
join(2, "bob", "202", 500)
join(3, "carol", "303", 0)

check(say(1, "hello everyone") == nil, "normal chat untouched")
check(say(1, "/biz create Fast Crew") == 1, "command hides chat")
local pa = sessions.get(1).profile
check(pa.businessId ~= nil, "alice has a business")
say(1, "/biz create Again")
check(last(1):find("already in"), "cannot create twice")

-- invite + accept
say(1, "/biz invite BOB")
check(last(2):find("invited you"), "bob got invite")
say(2, "/biz accept")
local biz = require("rlsmp.server.business").getFor(2)
check(biz and biz.name == "Fast Crew", "bob joined")
say(3, "/biz accept")
check(last(3):find("No pending"), "no invite for carol")

-- deposit / withdraw
say(1, "/biz deposit 400")
check(pa.ledger.money == 600 and biz.bank == 400, "deposit moves money")
local set = sent[1][#sent[1]]
check(set.name == "rlsmpWalletSet" and set.data.money == 600, "client told new balance")
say(2, "/biz deposit 9999")
check(last(2):find("Not enough"), "cannot deposit more than you have")
say(2, "/biz withdraw 150")
check(sessions.get(2).profile.ledger.money == 650 and biz.bank == 250, "member withdraw")
say(2, "/biz withdraw 9999")
check(last(2):find("only has"), "cannot overdraw bank")
say(2, "/biz deposit -5")
check(last(2):find("Usage"), "negative amount refused")
say(2, "/biz deposit 1.5")
check(last(2):find("Usage"), "fraction refused")

-- payout split
say(1, "/biz split 20")
check(last(1):find("20%%"), "split set")
say(1, "/biz split 99")
check(last(1):find("Usage"), "split above the limit refused")
local moneyBefore, bankBefore = pa.ledger.money, biz.bank
fire("rlsmpWalletDelta", 1, json.encode({d = 1000, r = "Delivery", c = "activity:delivery"}))
check(pa.ledger.money == moneyBefore + 1000 - 200 and biz.bank == bankBefore + 200, "20% of earnings goes to the bank")
check(sent[1][#sent[1]].name == "rlsmpWalletSet" and sent[1][#sent[1]].data.money == pa.ledger.money, "client is told the real balance")
fire("rlsmpWalletDelta", 1, json.encode({d = 5000, r = "Sold car", c = "sale"}))
check(biz.bank == bankBefore + 200, "selling a car is not earnings, nothing is split")
fire("rlsmpWalletDelta", 2, json.encode({d = 1000, r = "Delivery", c = "reward"}))
check(biz.bank == bankBefore + 200, "members with split 0 pay nothing")
say(1, "/biz split 0")
say(1, "/biz info")
check(last(1):find("split: 0%%"), "info shows the split")

-- persisted on disk
local disk = json.decode(io.open(tmp .. "/businesses/" .. biz.id .. ".json"):read("*a"))
check(disk.bank == 450 and disk.members["202"] ~= nil, "business saved to disk")


-- fleet ------------------------------------------------------------------------------------------------
local transfer = require("rlsmp/lib/transfer")
local function clientUpload(pid, id, kind, data)
  local header, chunks = transfer.describe(json.encode({kind = kind, data = data}), 40)
  header.id = id
  fire("rlsmpUpBegin", pid, json.encode(header))
  for i, d in ipairs(chunks) do fire("rlsmpUpChunk", pid, json.encode({id = id, i = i, d = d})) end
end
local function lastSent(pid, name)
  for i = #(sent[pid] or {}), 1, -1 do if sent[pid][i].name == name then return sent[pid][i].data end end
end
local car = {model = "etk800", niceName = "ETK 800", config = {parts = {engine = "v6"}}}

say(1, "/biz fleet")
check(last(1):find("empty"), "fleet starts empty")
say(1, "/biz fleet add")
check(lastSent(1, "rlsmpFleetDo").act == "add", "client asked to upload the car")
clientUpload(1, "f1", "fleetAdd", {inv = 3, rec = {model = "x"}})
check(lastSent(1, "rlsmpFleetAck").ok == false, "bad vehicle record refused")
clientUpload(1, "f2", "fleetAdd", {inv = 3, rec = car})
check(lastSent(1, "rlsmpFleetAck").ok == false, "car the server save does not have is refused")
local pf = sessions.get(1).profile.save.files
pf["career/vehicles/3.json"] = json.encode({model = "pickup"})
clientUpload(1, "f2b", "fleetAdd", {inv = 3, rec = car})
check(lastSent(1, "rlsmpFleetAck").ok == false, "car that does not match the saved model is refused")
pf["career/vehicles/3.json"] = json.encode({model = "etk800"})
clientUpload(1, "f2", "fleetAdd", {inv = 3, rec = car})
local ack = lastSent(1, "rlsmpFleetAck")
check(ack.ok and ack.fid == "1" and ack.inv == 3, "car added to fleet")
check(sessions.get(1).profile.fleetOut["3"] == "1", "slot remembered as out")
clientUpload(1, "f2c", "fleetAdd", {inv = 3, rec = car})
check(lastSent(1, "rlsmpFleetAck").ok == false, "same slot cannot be added twice before the save drops it")
pf["career/vehicles/3.json"] = nil
require("rlsmp.server.profiles").applyUpload(sessions.get(1).profile, {all = {["info.json"] = require("rlsmp/lib/transfer").checksum(pf["info.json"] or "")}, files = {["info.json"] = pf["info.json"] or ""}})
check(sessions.get(1).profile.fleetOut["3"] == nil, "slot forgotten once the save no longer has the car")
say(2, "/biz fleet")
check(last(2):find("#1 ETK 800 %- available"), "fleet list shows the car")

say(2, "/biz fleet take 1")
for _ = 1, 20 do fire("rlsmpPump") end
local begin = lastSent(2, "rlsmpChunkBegin")
check(begin and begin.kind == "fleetVehicle" and begin.extra.fid == "1", "car sent to bob")
say(1, "/biz fleet take 1")
check(last(1):find("Already taken by bob"), "cannot take a held car")
say(2, "/biz leave")
check(last(2):find("Return your fleet car"), "cannot leave while holding a car")

clientUpload(1, "f3", "fleetReturn", {fid = "1", inv = 9, rec = car})
check(lastSent(1, "rlsmpFleetAck").ok == false, "non-holder cannot return it")
say(2, "/biz fleet return")
check(lastSent(2, "rlsmpFleetDo").fid == "1", "client asked to return")
local tuned = {model = "etk800", niceName = "ETK 800", config = {parts = {engine = "v8"}}}
clientUpload(2, "f4", "fleetReturn", {fid = "1", inv = 7, rec = tuned})
check(lastSent(2, "rlsmpFleetAck").ok and biz.fleet["1"].heldBy == nil, "car returned")
check(biz.fleet["1"].rec.config.parts.engine == "v8", "changes kept")

say(2, "/biz fleet take 1")
fire("rlsmpFleetRelease", 2, json.encode({fid = "1", why = "no free garage space"}))
check(biz.fleet["1"].heldBy == nil, "failed take frees the car")
disk = json.decode(io.open(tmp .. "/businesses/" .. biz.id .. ".json"):read("*a"))
check(disk.fleet["1"] ~= nil and disk.nextFleet == 2, "fleet saved to disk")

-- retire: owner turns a held fleet car into a personal one
say(2, "/biz fleet take 1")
for _ = 1, 20 do fire("rlsmpPump") end
say(2, "/biz fleet retire")
check(biz.fleet["1"] ~= nil and lastSent(2, "rlsmpFleetRetire") == nil, "a member cannot retire a car")
fire("rlsmpFleetRelease", 2, json.encode({fid = "1", why = "test"}))
say(1, "/biz fleet retire")
check(last(1):find("Take the car first"), "retire needs a held car")
say(1, "/biz fleet take 1")
for _ = 1, 20 do fire("rlsmpPump") end
say(1, "/biz fleet retire")
check(biz.fleet["1"] == nil and lastSent(1, "rlsmpFleetRetire").fid == "1", "owner retires a fleet car for good")

-- full business + invite expiry
require("rlsmp.server.business") -- already loaded
say(1, "/biz invite carol")
now = now + 61
say(3, "/biz accept")
check(last(3):find("No pending"), "invite expires")
for i = 4, 5 do join(i, "p" .. i, tostring(i), 0) end
say(1, "/biz invite carol") say(3, "/biz accept")
say(1, "/biz invite p4") say(4, "/biz accept")
say(1, "/biz invite p5")
check(last(1):find("full"), "max 4 members")

-- owner leaves -> oldest member becomes owner
say(1, "/biz leave")
check(pa.businessId == nil and biz.owner == "202", "bob is new owner")
check(biz.members["202"].role == "owner", "role updated")
say(1, "/biz info")
check(last(1):find("not in a business"), "alice out")

-- members can't withdraw when disabled
RLSMP.config.business.membersCanWithdraw = false
say(3, "/biz withdraw 10")
check(last(3):find("Only the owner"), "withdraw restricted")
RLSMP.config.business.membersCanWithdraw = true

-- last member leaving closes the business and pays out
for _, p in ipairs({3, 4}) do say(p, "/biz leave") end
local before = sessions.get(2).profile.ledger.money
biz.fleet["9"] = {name = "Leftover", model = "x", rec = {}}
say(2, "/biz leave")
check(last(2):find("Fleet cars would be lost"), "last member cannot abandon fleet cars")
biz.fleet = {}
say(2, "/biz leave")
check(sessions.get(2).profile.ledger.money == before + 450, "bank paid out to last member")
local f = io.open(tmp .. "/businesses/" .. biz.id .. ".json")
check(f == nil, "business file removed")

-- /unstuck (qol module): cooldown and loading check
say(1, "/unstuck")
check(lastSent(1, "rlsmpUnstuck") ~= nil, "unstuck sent to client")
local unstuckCount = 0
for _, m in ipairs(sent[1]) do if m.name == "rlsmpUnstuck" then unstuckCount = unstuckCount + 1 end end
say(1, "/road")
for _, m in ipairs(sent[1]) do if m.name == "rlsmpUnstuck" then unstuckCount = unstuckCount - 1 end end
check(unstuckCount == -0 or unstuckCount == 0, "second use inside cooldown is not sent")
check(last(1):find("cooldown"), "cooldown message")
now = now + 31
say(1, "/road")
check(lastSent(1, "rlsmpUnstuck") ~= nil, "works again after cooldown")

-- loading state
players[6] = {name = "slow", ids = {beammp = "606"}}
fire("onPlayerJoin", 6)
say(6, "/biz info")
check(last(6):find("still loading"), "commands wait for career")

print(string.format("business_test: %d checks passed", passed))
