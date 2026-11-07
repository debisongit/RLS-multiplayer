-- Car theft: server (lua5.3) test. Run: lua5.3 tests/theft_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent, chat = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end, GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = {pid, m} end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000000
util.setClock(function() return now end)
onInit()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

local cfg = RLSMP.config
check(cfg.theft and cfg.theft.enabled == false, "theft is off by default")
check(_G.rlsmp_handler_rlsmpTheftStart ~= nil, "off: the handlers are there anyway (the menu can switch theft on live)")

-- A fake plateRecords (the real one is built elsewhere); the report must reach it.
local flagged = {}
package.loaded["rlsmp.server.plateRecords"] = {flag = function(...) flagged[#flagged + 1] = {...} return true end}

cfg.theft.enabled = true
local theft = require("rlsmp.server.theft")
theft.init(cfg, tmp .. "/")
local sessions = require("rlsmp.server.sessions")
local items = require("rlsmp.server.items")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function client(pid, ev, t) return fire(ev, pid, json.encode(t or {})) end
local function last(pid, name)
  for i = #(sent[pid] or {}), 1, -1 do if sent[pid][i].name == name then return sent[pid][i].data end end
end
players[1] = {name = "ann", ids = {beammp = "11"}}
players[2] = {name = "bob", ids = {beammp = "22"}}
for pid = 1, 2 do
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  sessions.get(pid).stage = "loaded"
end

-- Switched off: every handler refuses, the games are told once, and switching on again needs no restart
cfg.theft.enabled = false
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").ok == false and last(1, "rlsmpTheftGo").err:find("off"), "off: a start is refused")
client(1, "rlsmpTheftCheck", {id = 5, value = 4000, year = 1988})
check(last(1, "rlsmpTheftCan") == nil, "off: no prompt answers")
theft.resend()
theft.tick()
check(last(1, "rlsmpTheftConfig") and last(1, "rlsmpTheftConfig").enabled == false, "off: the games are told it is off")
local toldCount = 0
for _, m in ipairs(sent[1]) do if m.name == "rlsmpTheftConfig" then toldCount = toldCount + 1 end end
theft.tick() theft.tick()
local toldAfter = 0
for _, m in ipairs(sent[1]) do if m.name == "rlsmpTheftConfig" then toldAfter = toldAfter + 1 end end
check(toldAfter == toldCount, "off: told once, not every second")
cfg.theft.enabled = true
theft.resend()
theft.tick()
check(last(1, "rlsmpTheftConfig").enabled == true, "switched on again: the games hear it at once")
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").ok == false and not tostring(last(1, "rlsmpTheftGo").err):find("off"), "on again: a start is judged by the tools, not refused as off")

-- Difficulty table
check(theft.tierFor(5000, 1985) == "old", "1985 car: old")
check(theft.tierFor(5000, 2002) == "immobilizer", "2002 car: immobilizer")
check(theft.tierFor(30000, 2015) == "keyless", "2015 cheap car: keyless")
check(theft.tierFor(250000, 2015) == "luxury", "2015 expensive car: luxury")
check(theft.tierFor(30000, 2023) == "luxury", "newest car: luxury")
check(theft.tierFor(250000, 1970) == "old", "an expensive classic is still old")
check(theft.tierFor(1000, nil) == "immobilizer", "unknown year counts as immobilizer era")
check(theft.tierFor("x", "y") == "immobilizer", "garbage values are cleaned")
local kl = theft.methodsFor("keyless")
check(kl[1] == "signal_cloner" and kl[2] == "relay_box" and kl[3] == "injection", "keyless methods in their order")

-- Config to every loaded player, once per period
theft.tick()
local c1, c2 = last(1, "rlsmpTheftConfig"), last(2, "rlsmpTheftConfig")
check(c1 and c1.enabled == true and c1.perMille == 150 and c1.periodSeconds == 3600, "config sent")
check(c1.seed == c2.seed and c1.period == c2.period and c1.seed == math.floor(c1.seed) and c1.seed < 1000003, "same small integer seed for everyone")
local n1 = #sent[1]
theft.tick()
check(#sent[1] == n1, "not re-sent within the period")
now = now + 3600
theft.tick()
local c3 = last(1, "rlsmpTheftConfig")
check(c3.period == c1.period + 1 and c3.seed ~= c1.seed, "new period: new seed, re-sent")

-- Check / start need the items
math.randomseed(1)
client(1, "rlsmpTheftCheck", {id = 5, value = 4000, year = 1988})
check(last(1, "rlsmpTheftCan").ok == false and last(1, "rlsmpTheftCan").id == 5, "no tools: no prompt")
client(1, "rlsmpTheftStart", {method = "window_screwdriver", value = 4000, year = 1988})
local go = last(1, "rlsmpTheftGo")
check(go.ok == false and go.err:find("Window punch") and go.err:find("Screwdriver"), "start refused, missing items named")
items.give(1, "window_punch")
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").err:find("Screwdriver") and not last(1, "rlsmpTheftGo").err:find("Window"), "only the missing one is named")
items.give(1, "screwdriver")
now = now + 1
client(1, "rlsmpTheftCheck", {id = 5, value = 4000, year = 1988})
local can = last(1, "rlsmpTheftCan")
check(can.ok and can.method == "window_screwdriver" and can.seconds == 8, "tools owned: prompt with method and time")
client(1, "rlsmpTheftStart", {method = "signal_cloner", value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").ok == false and last(1, "rlsmpTheftGo").err:find("does not work"), "a method of another tier is refused")
client(1, "rlsmpTheftStart", {method = "teleport", value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").ok == false and last(1, "rlsmpTheftGo").err:find("Unknown"), "unknown method refused")

-- Success path, injected random
theft.setRandom(function() return 0.99 end)   -- no failure, nobody sees it
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
go = last(1, "rlsmpTheftGo")
check(go.ok and go.seconds == 8 and go.noise == 0.9 and go.method == "window_screwdriver", "go with time and noise")
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
check(last(1, "rlsmpTheftGo").ok == false and last(1, "rlsmpTheftGo").err:find("busy"), "one action at a time")
client(1, "rlsmpTheftDone", {plate = "ABC 123", model = "covet"})
check(theft.records()["ABC 123"] == nil, "done before finish is ignored")
now = now + 3
client(1, "rlsmpTheftFinish", {})
check(last(1, "rlsmpTheftResult").ok == false and last(1, "rlsmpTheftResult").err:find("fast"), "finishing too early fails")
check(items.has(1, "window_punch") and items.has(1, "screwdriver"), "nothing used on failure")
now = now + 20   -- after the retry cooldown
client(1, "rlsmpTheftStart", {value = 4000, year = 1988})
now = now + 8
client(1, "rlsmpTheftFinish", {})
check(last(1, "rlsmpTheftResult").ok == true, "result ok")
check(items.has(1, "window_punch") and items.has(1, "screwdriver"), "durable tools stay")
client(1, "rlsmpTheftDone", {plate = " abc 123 ", model = "covet", color = "Red", value = 4000, year = 1988, x = 1, y = 2, z = 3, witnesses = 0})
local rec = theft.records()["ABC 123"]
check(rec and rec.model == "covet" and rec.color == "red" and rec.by == "11" and rec.seen == false, "stolen record kept, plate cleaned")
check(rec.reportAt == now + 600, "unseen: reported after ten minutes")
check(theft.pendingOf(1) == nil, "action closed")

-- Consumables are used on success
items.give(1, "key_programmer")
items.give(1, "blank_key", 2)
now = now + 20
client(1, "rlsmpTheftStart", {value = 9000, year = 2004})
check(last(1, "rlsmpTheftGo").ok == false and last(1, "rlsmpTheftGo").err:find("Lockout kit"), "immobilizer car: no way in without a lockout kit")
items.give(1, "lockout_kit")
client(1, "rlsmpTheftStart", {value = 9000, year = 2004})
check(last(1, "rlsmpTheftGo").method == "key_programmer", "immobilizer car: lockout kit, key programmer, blank key")
now = now + 25
theft.setRandom(function() return 0.0 end)  -- would fail (failChance 0.15 > 0)
client(1, "rlsmpTheftFinish", {})
check(last(1, "rlsmpTheftResult").ok == false and items.count(1, "blank_key") == 2, "failure roll: nothing used up")
now = now + 20
theft.setRandom(function() return 0.5 end)
client(1, "rlsmpTheftStart", {value = 9000, year = 2004})
now = now + 25
client(1, "rlsmpTheftFinish", {})
check(last(1, "rlsmpTheftResult").ok == true and items.count(1, "blank_key") == 1 and items.has(1, "key_programmer") and items.has(1, "lockout_kit"), "blank key used, programmer and lockout kit kept")
theft.setRandom(function() return 0.0 end)  -- seen, earliest report
client(1, "rlsmpTheftDone", {plate = "XYZ9", model = "pessima", color = "blue", witnesses = 2})
local r2 = theft.records()["XYZ9"]
check(r2.seen == true and r2.reportAt == now + 30, "seen: reported after 30 s (lowest roll)")

-- Witness chance and report timing
check(math.abs(theft.witnessChance(0, 0) - 0.15) < 1e-9, "base witness chance")
check(math.abs(theft.witnessChance(2, 0.5) - (0.15 + 0.24 + 0.15)) < 1e-9, "witnesses and noise add up")
check(theft.witnessChance(100, 1) == 0.95, "capped")
check(theft.witnessChance(100, 0) == theft.witnessChance(5, 0), "witness count capped")
theft.setRandom(function() return 0.999 end)
check(theft.reportDelay(true, false) == 120, "seen: at most 120 s")
check(theft.reportDelay(false, true) == 20, "tracker: fast")
theft.setRandom(function() return 0.3 end)
check(theft.rollWitness(0, 0) == false and theft.rollWitness(3, 0) == true, "roll uses the injected random")

-- Reporting: plate flagged once, thief told
now = now + 30
local due = theft.reportDue()
check(#due == 1 and due[1].plate == "XYZ9" and r2.reported, "seen car reported at its time")
check(#flagged == 1 and flagged[1][1] == "XYZ9" and flagged[1][2] == "pessima" and flagged[1][3] == "blue" and flagged[1][4] == "stolen" and flagged[1][5] == "11",
  "plateRecords.flag(plate, model, color, 'stolen', accountId)")
check(last(1, "rlsmpTheftReported").plate == "XYZ9", "thief hears about it")
check(#theft.reportDue() == 0 and #flagged == 1, "reported only once")
now = now + 600
check(#theft.reportDue() == 1 and #flagged == 2, "unseen car reported later")

-- Luxury tracker unless blocked
items.give(2, "can_injector") items.give(2, "key_programmer") items.give(2, "blank_key")
theft.setRandom(function() return 0.9 end)
client(2, "rlsmpTheftStart", {value = 300000, year = 2019})
check(last(2, "rlsmpTheftGo").method == "luxury_injection", "luxury method")
now = now + 45
client(2, "rlsmpTheftFinish", {})
client(2, "rlsmpTheftDone", {plate = "LUX1", model = "vivace", color = "black", witnesses = 0})
check(theft.records()["LUX1"].reportAt == now + 20 and theft.records()["LUX1"].tracker, "tracker reports in 20 s")
check(math.abs(last(2, "rlsmpTheftGo").noise - 0.6) < 1e-9, "luxury alarm: full noise without a jammer")

-- A jammer silences the alarm of the luxury method (noise x 0.25), and the witness chance follows
items.give(2, "jammer")
items.give(2, "blank_key")
now = now + 20
client(2, "rlsmpTheftStart", {value = 300000, year = 2019})
check(math.abs(last(2, "rlsmpTheftGo").noise - 0.15) < 1e-9, "jammer: luxury noise 0.6 -> 0.15")
check(math.abs(theft.pendingOf(2).noise - 0.15) < 1e-9, "jammer: the witness roll uses the quiet noise")
client(2, "rlsmpTheftCancel", {})
check(math.abs(theft.witnessChance(0, 0.15) - (0.15 + 0.3 * 0.15)) < 1e-9, "quiet noise lowers the witness chance")
-- methods without an alarm are not changed by a jammer
items.give(2, "signal_cloner")
now = now + 20
client(2, "rlsmpTheftStart", {value = 20000, year = 2016})
check(math.abs(last(2, "rlsmpTheftGo").noise - 0.1) < 1e-9, "jammer does nothing for a method without an alarm")
client(2, "rlsmpTheftCancel", {})

-- A tracker blocker makes the luxury tracker report like any other car, and tells the thief
items.give(2, "tracker_blocker")
now = now + 20
client(2, "rlsmpTheftStart", {value = 300000, year = 2019})
now = now + 45
theft.setRandom(function() return 0.9 end)
client(2, "rlsmpTheftFinish", {})
check(last(2, "rlsmpTheftResult").ok == true, "luxury theft with blocker and jammer works")
client(2, "rlsmpTheftDone", {plate = "LUX2", model = "vivace", color = "black", witnesses = 0})
local lux2 = theft.records()["LUX2"]
check(lux2 and lux2.tracker == false and lux2.reportAt == now + 600, "tracker blocker: no fast report, the normal ten minutes")
local blocked = false
for i = #chat, 1, -1 do if chat[i][1] == 2 and chat[i][2]:find("tracker blocker killed") then blocked = true break end end
check(blocked, "the thief is told the tracker was killed")

-- Cancel and the chat command
items.give(2, "signal_cloner")
now = now + 20
client(2, "rlsmpTheftStart", {value = 20000, year = 2016})
check(theft.pendingOf(2) ~= nil, "running")
client(2, "rlsmpTheftCancel", {})
check(theft.pendingOf(2) == nil, "cancel clears it")
fire("onChatMessage", 2, "bob", "/steal relay_box")
check(last(2, "rlsmpTheftSteal").method == "relay_box", "/steal forwards the method to the game")

-- Persistence
local onDisk = json.decode(io.open(tmp .. "/stolen.json"):read("*a"))
check(onDisk.stolen["ABC 123"] and onDisk.stolen["LUX1"], "stolen.json written")
theft.init(cfg, tmp .. "/")
check(theft.records()["LUX1"] and theft.records()["LUX1"].reported == false, "records loaded again after a restart")
now = now + 30
check(#theft.reportDue() == 1, "and still reported after the restart")
now = now + 49 * 3600
theft.reportDue()
theft.reportDue()   -- a record that was still waiting for its report is reported first and pruned on the next pass
check(next(theft.records()) == nil, "old records pruned")

-- No plateRecords: the hook is quiet
package.loaded["rlsmp.server.plateRecords"] = nil
package.preload["rlsmp.server.plateRecords"] = function() error("no such module") end
check(theft.reportHook({plate = "A", model = "b"}) == false, "missing plateRecords is fine")
print("theft_test: " .. passed .. " checks passed")
