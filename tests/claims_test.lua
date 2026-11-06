-- Dashcam + crash claims, server side (lua5.3). Run: lua5.3 tests/claims_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent, chat = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
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
local now = 5000
util.setClock(function() return now end)
onInit()
local sessions = require("rlsmp.server.sessions")
local claims = require("rlsmp.server.claims")
local cfg = RLSMP.config.claims
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function say(pid, msg) return fire("onChatMessage", pid, players[pid].name, msg) end
local function join(pid, name, money)
  players[pid] = {name = name, ids = {beammp = tostring(2000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, money
  return s
end
local function lastSent(pid, name)
  for i = #(sent[pid] or {}), 1, -1 do if sent[pid][i].name == name then return sent[pid][i].data end end
end
local function lastChat(pid) local c = chat[pid] or {} return c[#c] or "" end
local function countSent(pid, name) local n = 0 for _, m in ipairs(sent[pid] or {}) do if m.name == name then n = n + 1 end end return n end

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m .. " | " .. lastChat(0) .. " / " .. lastChat(1), 2) end passed = passed + 1 end

-- judge ----------------------------------------------------------------------------------------------------
local function car(x, vx) return {p = {x, 0, 0}, v = {vx, 0, 0}} end
local a, b, closing = claims.judge(car(0, 20), car(10, 0))
check(a == 1 and b == 0 and math.abs(closing - 20) < 1e-9, "driving into a parked car: 100% your fault")
a, b = claims.judge(car(0, 15), car(10, -15))
check(math.abs(a - 0.5) < 1e-9, "head-on: 50/50")
a, b = claims.judge(car(0, 0), car(10, -10))
check(a == 0 and b == 1, "the car that moves into the other one is at fault, not the parked one")
a, b = claims.judge(car(0, 30), car(10, 10))
check(math.abs(a - 1) < 1e-9 and b == 0, "rear-ending a car that moves away: the car behind is at fault")
a, b, closing = claims.judge(car(0, 2), car(10, 0))
check(closing < cfg.minImpactSpeed, "a slow tap is below the accident threshold")

-- confidence ---------------------------------------------------------------------------------------------
check(claims.confidence(false, false, 0) == 0.35, "no dashcam, nobody around: a gamble (35%)")
check(math.abs(claims.confidence(false, false, 2) - 0.65) < 1e-9, "witnesses nearby raise the chance")
check(math.abs(claims.confidence(false, false, 9) - 0.8) < 1e-9, "witnesses are capped")
check(math.abs(claims.confidence(true, false, 0) - 0.75) < 1e-9, "one dashcam helps a lot")
check(claims.confidence(true, true, 0) == 1, "two dashcams: certain")

-- dashcam purchase --------------------------------------------------------------------------------------------
local sa = join(0, "alice", 1000)
local sb = join(1, "bob", 5000)
say(0, "/dashcam")
check(lastSent(0, "rlsmpWhatCar") ~= nil, "server asks which car you are in")
fire("rlsmpMyCar", 0, json.encode({inv = 3, model = "etk800", name = "ETK 800"}))
check(sa.profile.ledger.money == 900 and sa.profile.dashcams["3"] == "etk800", "dashcam costs $100 and is recorded for that car")
check(lastSent(0, "rlsmpWalletSet").money == 900, "client told the new balance")
say(0, "/dashcam") fire("rlsmpMyCar", 0, json.encode({inv = 3, model = "etk800"}))
check(lastChat(0):find("already"), "second dashcam on the same car refused")
check(sa.profile.ledger.money == 900, "and not charged")
fire("rlsmpMyCar", 0, json.encode({inv = 4, model = "pickup"}))
check(sa.profile.dashcams["4"] == nil, "an answer nobody asked for is ignored")
sa.profile.ledger.money = 50
say(0, "/dashcam") fire("rlsmpMyCar", 0, json.encode({inv = 5, model = "pickup"}))
check(sa.profile.dashcams["5"] == nil and lastChat(0):find("costs"), "not enough money, no dashcam")
sa.profile.ledger.money = 10000

-- hits --------------------------------------------------------------------------------------------------------
local function report(pid, me, with, inv, model, mine, other, damage, nearby)
  fire("rlsmpHit", pid, json.encode({me = me, with = with, inv = inv, model = model, mine = mine, other = other, damage = damage, nearby = nearby}))
end
local A, B = {p = {0, 0, 0}, v = {20, 0, 0}}, {p = {10, 0, 0}, v = {0, 0, 0}}   -- alice drives into parked bob
sb.profile.dashcams = {["7"] = "pickup"}

-- dry run: everyone is told, nothing is taken
cfg.dryRun = true
math.random = function() return 0 end   -- always "caught"
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
check(#(chat[1] or {}) == 0 or not lastChat(1):find("TEST MODE"), "one report is not judged yet")
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(lastChat(0):find("TEST MODE") and lastChat(1):find("TEST MODE"), "dry run: both players are told what would happen")
check(sa.profile.ledger.money == 10000 and sb.profile.ledger.money == 5000, "dry run: no money moves")
check(countSent(0, "rlsmpClaimPenalty") == 0, "dry run: no insurance claim")

-- live: at-fault pays the damage the other car took
cfg.dryRun = false
now = now + 100   -- long after the dry run, so the repeat-accident count starts fresh
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == 8000 and sb.profile.ledger.money == 7000, "alice pays bob $2000 for his damage")
check(lastSent(0, "rlsmpClaimPenalty").damage == 2000, "alice's game files an insurance claim")
check(lastSent(1, "rlsmpClaimPenalty") == nil, "bob was not at fault: no claim for him")

-- same pair again straight away: ignored (one claim per incident)
local before = sa.profile.ledger.money
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == before, "the same crash is not charged twice")

-- repeat accidents cost more
now = now + 25   -- past the pair cooldown, still inside the 60 s chain window
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == before - 3000, "second at-fault accident in a minute: x1.5")

-- getting away with it
cfg.dryRun = false
now = now + 400
math.random = function() return 0.99 end
local m1 = sa.profile.ledger.money
sb.profile.dashcams = nil
local aCams = sa.profile.dashcams
sa.profile.dashcams = nil
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == m1 and lastChat(0):find("Nobody could prove") and lastChat(0):find("No dashcam"), "no dashcam, nobody around, bad luck: nobody is charged")
-- one dashcam is enough, even with the worst luck
sa.profile.dashcams = aCams
now = now + 400
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == m1 - 2000, "one dashcam: always caught, no dice")
m1 = sa.profile.ledger.money
-- with the rule switched off it is a gamble again
cfg.dashcamAlwaysCaught = false
now = now + 400
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == m1, "rule off: one dashcam is only a 75% chance")
cfg.dashcamAlwaysCaught = true
sa.profile.dashcams = nil
-- with two dashcams there is no luck involved
sa.profile.dashcams = {["3"] = "etk800"} sb.profile.dashcams = {["7"] = "pickup"}
now = now + 400
report(0, "0-1", "1-1", 3, "etk800", A, B, 100, 0)
report(1, "1-1", "0-1", 7, "pickup", B, A, 2000, 0)
check(sa.profile.ledger.money == m1 - 2000, "both dashcams: always caught")

-- a single report is judged after the wait
math.random = function() return 0 end
now = now + 400
local m2 = sa.profile.ledger.money
report(0, "0-1", "1-1", 3, "etk800", A, B, nil, 0)
claims.tick()
check(sa.profile.ledger.money == m2, "still waiting for the other report")
now = now + cfg.reportWindowSeconds + 1
claims.tick()
check(sa.profile.ledger.money < m2, "judged on one report after the window (damage estimated from impact speed)")
check(m2 - sa.profile.ledger.money <= cfg.maxPayout, "estimate is capped")

-- lies and noise
now = now + 400
local m3 = sa.profile.ledger.money
report(0, "1-1", "0-1", 3, "etk800", A, B, 100, 0)   -- claims to be bob's car
report(0, "0-1", "0-2", 3, "etk800", A, B, 100, 0)   -- hit itself
claims.tick() now = now + 10 claims.tick()
check(sa.profile.ledger.money == m3 and next(claims._pending()) == nil, "reports about other people's cars or yourself are ignored")
print(string.format("claims_test: %d checks passed", passed))
