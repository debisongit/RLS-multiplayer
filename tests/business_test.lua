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

-- persisted on disk
local disk = json.decode(io.open(tmp .. "/businesses/" .. biz.id .. ".json"):read("*a"))
check(disk.bank == 250 and disk.members["202"] ~= nil, "business saved to disk")


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
local ack = lastSent(1, "rlsmpFleetAck")
check(ack.ok and ack.fid == "1" and ack.inv == 3, "car added to fleet")
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
say(2, "/biz leave")
check(last(2):find("Fleet cars would be lost"), "last member cannot abandon fleet cars")
biz.fleet = {}
say(2, "/biz leave")
check(sessions.get(2).profile.ledger.money == before + 250, "bank paid out to last member")
local f = io.open(tmp .. "/businesses/" .. biz.id .. ".json")
check(f == nil, "business file removed")

-- loading state
players[6] = {name = "slow", ids = {beammp = "606"}}
fire("onPlayerJoin", 6)
say(6, "/biz info")
check(last(6):find("still loading"), "commands wait for career")

print(string.format("business_test: %d checks passed", passed))
