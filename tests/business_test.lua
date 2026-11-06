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
check(sessions.get(2).profile.ledger.money == before + 250, "bank paid out to last member")
local f = io.open(tmp .. "/businesses/" .. biz.id .. ".json")
check(f == nil, "business file removed")

-- loading state
players[6] = {name = "slow", ids = {beammp = "606"}}
fire("onPlayerJoin", 6)
say(6, "/biz info")
check(last(6):find("still loading"), "commands wait for career")

print(string.format("business_test: %d checks passed", passed))
