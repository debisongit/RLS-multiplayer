-- Stolen car restore: server (lua5.3) test. Run: lua5.3 tests/recall_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[#sent + 1] = {pid = pid, name = name, data = json.decode(data)} return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end, GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
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
local theft = require("rlsmp.server.theft")
local recall = require("rlsmp.server.recall")
theft.init(cfg, tmp .. "/")
recall.init(cfg)
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function client(pid, ev, t) return fire(ev, pid, json.encode(t or {})) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function lastSent(pid, name) for i = #sent, 1, -1 do if sent[i].pid == pid and sent[i].name == name then return sent[i].data end end end
local function count(name) local c = 0 for _, s in ipairs(sent) do if s.name == name then c = c + 1 end end return c end
local function join(pid, name, money)
  players[pid] = {name = name, ids = {beammp = tostring(100 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  local s = sessions.get(pid)
  s.stage = "loaded"
  s.profile.ledger.seeded, s.profile.ledger.money = true, money or 1000
end
join(1, "ann") join(2, "bob")

-- the record keeps what is needed to rebuild the car (rememberCar)
local rec = {plate = "AB 1", model = "covet", pos = {x = 1, y = 2, z = 3}, by = "101", t = now, value = 5000, year = 1990}
theft.records()["AB 1"] = rec
theft.rememberCar(rec, {config = "vehicles/covet/base.pc", rot = {x = 0, y = 0, z = 0.7, w = 0.7},
  look = {{x = 1, y = 0, z = 0, w = 1, m = {metallic = 0.5, bad = "x"}}, "junk", {x = 0, y = 1, z = 0, w = 1}}})
check(rec.car.config == "vehicles/covet/base.pc" and rec.car.look[1].m.metallic == 0.5 and rec.car.look[1].m.bad == nil
  and rec.car.look[2] == nil and rec.car.look[3].y == 1, "config and paints kept, junk dropped")
check(rec.last.x == 1 and rec.last.rot.w == 0.7, "last place and rotation start at the theft spot")
theft.rememberCar(rec, {config = "../../evil;rm", rot = {x = 0, y = 0, z = 0, w = 1e9}})
check(rec.car.config == nil and rec.last.rot == nil, "bad config and rotation refused")
theft.rememberCar(rec, {config = "vehicles/covet/base.pc", rot = {x = 0, y = 0, z = 0.7, w = 0.7},
  look = {{x = 1, y = 0, z = 0, w = 1}, nil, {x = 0, y = 1, z = 0, w = 1}}})

-- place reports: owner only, rate limited
now = now + 100
client(1, "rlsmpPos", {x = 500, y = 500, z = 40, speed = 0})
client(1, "rlsmpStolenPos", {cars = {{plate = "ab 1", x = 10, y = 20, z = 30, rot = {x = 0, y = 0, z = 0, w = 1}}}})
check(rec.last.x == 10 and rec.last.rot.w == 1 and rec.ownerPos.x == 500, "owner's report stored with the owner's own place")
client(1, "rlsmpStolenPos", {cars = {{plate = "AB 1", x = 99, y = 99, z = 30}}})
check(rec.last.x == 10, "rate limited per plate")
now = now + 30
client(2, "rlsmpStolenPos", {cars = {{plate = "AB 1", x = 77, y = 77, z = 30}}})
check(rec.last.x == 10, "another player cannot move your car")
client(1, "rlsmpStolenPos", {cars = {{plate = "AB 1", x = 1e9, y = 5, z = 30}}})
check(rec.last.x == 10, "absurd place refused")
client(1, "rlsmpStolenPos", {cars = {{plate = "AB 1", x = 11, y = 21, z = 30}}})
check(rec.last.x == 11 and rec.last.rot == nil, "a later report replaces it")
recall._flush(true)
local f = assert(io.open(tmp .. "/stolen.json"))
local saved = json.decode(f:read("a"))
f:close()
check(saved.stolen["AB 1"].last.x == 11 and saved.stolen["AB 1"].car.config, "saved to stolen.json")

-- automatic restore: once per session, only the player's own records
recall.tick()
local auto = lastSent(1, "rlsmpStolenRestore")
check(auto and auto.auto == true and #auto.cars == 1 and auto.cars[1].plate == "AB 1"
  and auto.cars[1].config == "vehicles/covet/base.pc" and auto.cars[1].x == 11, "auto restore carries the spec")
check(lastSent(2, "rlsmpStolenRestore") == nil, "no record, no message")
local n1 = count("rlsmpStolenRestore")
recall.tick() recall.tick()
check(count("rlsmpStolenRestore") == n1, "no spam: once per session")

-- sold or stripped (taken by the fence): nothing to restore
local taken = theft.take("AB 1")
fire("onPlayerDisconnect", 1)
recall.tick()
join(1, "ann")
recall.tick()
check(count("rlsmpStolenRestore") == n1, "a record the fence took is not restored")
theft.put(taken)

-- the button: owner, record, cooldown, fee
client(2, "rlsmpStolenRecall", {})
check(lastSent(2, "rlsmpStolenRecallResult").ok == false, "no stolen car: refused")
client(1, "rlsmpStolenRecall", {plate = "zz 9"})
check(lastSent(1, "rlsmpStolenRecallResult").err:find("no stolen"), "unknown plate refused")
client(1, "rlsmpStolenRecall", {})
local m = lastSent(1, "rlsmpStolenRestore")
check(m.auto == false and #m.cars == 1, "button: cars beside the player")
local before = count("rlsmpStolenRestore")
now = now + 10
client(1, "rlsmpStolenRecall", {})
check(count("rlsmpStolenRestore") == before and lastSent(1, "rlsmpStolenRecallResult").err:find("Wait"), "cooldown")
now = now + 200
cfg.theft.recallFee = 300
sessions.get(1).profile.ledger.money = 100
client(1, "rlsmpStolenRecall", {plate = "AB 1"})
check(lastSent(1, "rlsmpStolenRecallResult").err:find("300") and count("rlsmpStolenRestore") == before, "fee: too poor, refused")
sessions.get(1).profile.ledger.money = 1000
client(1, "rlsmpStolenRecall", {plate = "AB 1"})
check(count("rlsmpStolenRestore") == before + 1 and sessions.get(1).profile.ledger.money == 700, "fee charged")
cfg.theft.enabled = false
now = now + 200
client(1, "rlsmpStolenRecall", {})
check(lastSent(1, "rlsmpStolenRecallResult").err:find("off"), "theft off: refused")
print("recall_test: " .. passed .. " checks passed")
