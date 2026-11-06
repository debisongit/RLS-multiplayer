-- End-to-end test of the server plugin with a fake BeamMP API and a fake player.
-- Run: lua5.3 tests/server_test.lua <tmpdir>   (tests/run.sh does this)
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

-- Fake BeamMP --------------------------------------------------------------------------------------
local players = {}       -- pid -> {name, ids}
local inbox = {}         -- pid -> list of {name, data}
local dropped = {}       -- pid -> reason
local timers = {}

MP = {
  RegisterEvent = function(ev, fname) end,
  CreateEventTimer = function(ev, ms) timers[ev] = ms end,
  TriggerClientEvent = function(pid, name, data)
    inbox[pid] = inbox[pid] or {}
    table.insert(inbox[pid], {name = name, data = json.decode(data)})
    return true
  end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function(pid, reason) dropped[pid] = reason end,
  SendChatMessage = function(pid, text) _G.__chat = _G.__chat or {} table.insert(_G.__chat, text) end,
  GetPlayers = function() local t = {} for pid, p in pairs(players) do t[pid] = p.name end return t end,
}
Util = {}

RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000
util.setClock(function() return now end)
onInit()

local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function fromClient(pid, ev, tbl) return fire(ev, pid, json.encode(tbl)) end

-- Fake player: uses the real CLIENT transfer lib to put chunks back together.
local transfer = require("rlsmp/lib/transfer")
local function drain(pid)
  for _ = 1, 1000 do fire("rlsmpPump") end
  local msgs = inbox[pid] or {}
  inbox[pid] = {}
  local out, asm = {}, {}
  for _, m in ipairs(msgs) do
    if m.name == "rlsmpChunkBegin" then
      asm[m.data.id] = {a = transfer.newAssembler(m.data), h = m.data}
    elseif m.name == "rlsmpChunk" then
      local job = asm[m.data.id]
      job.a:add(m.data.i, m.data.d)
      if job.a:isComplete() then
        local text = assert(job.a:finish())
        table.insert(out, {name = "big:" .. job.h.kind, data = json.decode(text), extra = job.h.extra})
      end
    else
      table.insert(out, m)
    end
  end
  return out
end
local function find(msgs, name)
  for _, m in ipairs(msgs) do if m.name == name then return m end end
end

local function upload(pid, id, all, files, chunkSize)
  local text = json.encode({all = all, files = files})
  local header, chunks = transfer.describe(text, chunkSize or 50)
  header.id = id
  fromClient(pid, "rlsmpUpBegin", header)
  for i, d in ipairs(chunks) do fromClient(pid, "rlsmpUpChunk", {id = id, i = i, d = d}) end
  return drain(pid)
end

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end

-- 1. Guests are refused at auth ----------------------------------------------------------------------
check(type(fire("onPlayerAuth", "guestguy", "USER", true, {ip = "1.2.3.4"})) == "string", "guest refused")
check(fire("onPlayerAuth", "bob", "USER", false, {beammp = "1001"}) == nil, "account allowed")

-- 1b. Build mismatch is reported to the player (not fatal)
players[9] = {name = "stale", ids = {beammp = "9009"}}
fire("onPlayerJoin", 9)
fromClient(9, "rlsmpHello", {v = 1, build = "0.0.1"})
check(_G.__chat and _G.__chat[#_G.__chat]:find("differs from the server"), "old client build gets a warning")
check(dropped[9] == nil, "old build is not kicked")
fire("onPlayerDisconnect", 9)

-- 2. First join: new profile is streamed down --------------------------------------------------------
players[0] = {name = "bob", ids = {beammp = "1001"}}
fire("onPlayerJoin", 0)
fromClient(0, "rlsmpHello", {v = 1})
local msgs = drain(0)
local prof = find(msgs, "big:profile")
check(prof ~= nil, "profile delivered")
check(prof.extra.isNew == true, "new profile flagged")
check(prof.extra.profile:match("^rlsmp[a-z0-9]+1001$") ~= nil, "local profile name is plain lowercase: " .. prof.extra.profile)
fromClient(0, "rlsmpLoaded", {ok = true})

-- 3. Before the first save, starting cash just follows along ------------------------------------------
fromClient(0, "rlsmpWalletDelta", {d = 5000, r = "Starting Capital"})
check(#drain(0) == 0, "no correction before seeding")

-- 4. First upload seeds the server wallet -------------------------------------------------------------
local info = json.encode({version = 64, date = "x"})
local attrs = function(money) return json.encode({money = {value = money}, beamXP = {value = 0}}) end
local all = {["info.json"] = transfer.checksum(info), ["career/playerAttributes.json"] = transfer.checksum(attrs(5000))}
msgs = upload(0, "1", all, {["info.json"] = info, ["career/playerAttributes.json"] = attrs(5000)})
local ack = find(msgs, "rlsmpUpAck")
check(ack and ack.data.ok == true, "first upload ok")
check(ack.data.money == 5000 and ack.data.corrected == false, "seeded at 5000")
local onDisk = json.decode(io.open(tmp .. "/profiles/1001.json"):read("*a"))
check(onDisk.ledger.money == 5000 and onDisk.ledger.seeded == true, "ledger on disk")

-- 5. Normal payout accepted, crazy payout refused -----------------------------------------------------
fromClient(0, "rlsmpWalletDelta", {d = 1000, r = "Delivery"})
check(#drain(0) == 0, "normal payout accepted")
fromClient(0, "rlsmpWalletDelta", {d = 50000000, r = "Totally legit"})
local set = find(drain(0), "rlsmpWalletSet")
check(set and set.data.money == 6000, "huge payout refused, balance pushed back")

-- 6. Rate limit inside the window ----------------------------------------------------------------------
for _ = 1, 2 do fromClient(0, "rlsmpWalletDelta", {d = 700000}) end
check(#drain(0) == 0, "two big payouts fine")
fromClient(0, "rlsmpWalletDelta", {d = 700000})
check(find(drain(0), "rlsmpWalletSet") ~= nil, "third big payout in 5 min refused")
now = now + 301
fromClient(0, "rlsmpWalletDelta", {d = 700000})
check(#drain(0) == 0, "window reset after 5 min")
local expected = 6000 + 700000 * 3

-- 7. Cheated save gets corrected (only the changed file is sent) ---------------------------------------
all["career/playerAttributes.json"] = transfer.checksum(attrs(99999999))
msgs = upload(0, "2", all, {["career/playerAttributes.json"] = attrs(99999999)})
ack = find(msgs, "rlsmpUpAck")
check(ack.data.ok and ack.data.corrected and ack.data.money == expected, "cheated money corrected")
check(find(msgs, "rlsmpWalletSet").data.money == expected, "client told the real balance")
check(ack.data.sums["career/playerAttributes.json"] ~= nil, "new checksum returned")

-- 8. Claiming a file the server doesn't have -> resync ----------------------------------------------
all["career/inventory.json"] = transfer.checksum("{}")
msgs = upload(0, "3", all, {})
ack = find(msgs, "rlsmpUpAck")
check(ack.data.ok == false and ack.data.resync == true, "resync requested")
all["career/inventory.json"] = nil

-- 9. Path tricks are refused ----------------------------------------------------------------------------
msgs = upload(0, "4", {["../../evil.json"] = transfer.checksum("{}"), ["info.json"] = transfer.checksum(info)},
  {["../../evil.json"] = "{}"})
check(find(msgs, "rlsmpUpAck").data.err == "bad_path", "path escape refused")

-- 10. Same account twice -> second is dropped ---------------------------------------------------------
players[1] = {name = "bob2", ids = {beammp = "1001"}}
fire("onPlayerJoin", 1)
fromClient(1, "rlsmpHello", {v = 1})
check(dropped[1] ~= nil, "duplicate account dropped")
fire("onPlayerDisconnect", 1)

-- 11. Wrong protocol version -> dropped ---------------------------------------------------------------
players[2] = {name = "old", ids = {beammp = "2002"}}
fire("onPlayerJoin", 2)
fromClient(2, "rlsmpHello", {v = 999})
check(dropped[2] ~= nil, "old client dropped")
fire("onPlayerDisconnect", 2)

-- 12. Rejoin gets the corrected save back --------------------------------------------------------------
fire("onPlayerDisconnect", 0)
players[0] = {name = "bob", ids = {beammp = "1001"}}
fire("onPlayerJoin", 0)
fromClient(0, "rlsmpHello", {v = 1})
prof = find(drain(0), "big:profile")
check(prof.extra.isNew == false, "returning player")
local savedAttrs = json.decode(prof.data.files["career/playerAttributes.json"])
check(savedAttrs.money.value == expected, "download has server-approved money")
check(prof.extra.money == expected, "header carries balance")

-- 13. Hello timeout ----------------------------------------------------------------------------------
players[3] = {name = "nomod", ids = {beammp = "3003"}}
fire("onPlayerJoin", 3)
now = now + 121
fire("rlsmpTick")
check(dropped[3] ~= nil, "player without client mod dropped after timeout")

-- 14. Forced save request ----------------------------------------------------------------------------
now = now + 301
fire("rlsmpTick")
check(find(drain(0), "rlsmpSaveNow") == nil, "not loaded yet -> no save request")
fromClient(0, "rlsmpLoaded", {ok = true})
now = now + 301
fire("rlsmpTick")
check(find(drain(0), "rlsmpSaveNow") ~= nil, "save requested every 5 min")

-- 15. Broken main file falls back to .bak --------------------------------------------------------------
local storage = require("rlsmp.server.storage")
storage.writeJson(tmp .. "/x.json", {a = 1})
storage.writeJson(tmp .. "/x.json", {a = 2})
io.open(tmp .. "/x.json", "w"):close() -- simulate a corrupted / empty file
check(storage.readJson(tmp .. "/x.json").a == 1, "backup used")

-- 16. Console ------------------------------------------------------------------------------------------
check(fire("onConsoleInput", "rlsmp status"):find("bob") ~= nil, "status lists player")

-- 17. Money categories: moving money is not earning ----------------------------------------------------------
local wallet = require("rlsmp.server.wallet")
local led = wallet.newLedger()
led.seeded, led.money = true, 1000
check(wallet.applyDelta(led, 2000000, "Loan payout", "loan") == true and led.money == 2001000, "big loan payout accepted")
check(wallet.applyDelta(led, 1500000, "Sold car", "sale") == true, "big car sale accepted")
check(#led.window == 0, "moving money does not use up the earning limit")
local ok, why = wallet.applyDelta(led, 6000000, "x", "transfer")
check(ok == false and why == "gain_too_large", "even a transfer has a cap")
ok, why = wallet.applyDelta(led, 1000, "debug", "cheat")
check(ok == false and why == "cheat_category", "cheat money refused")
ok = wallet.applyDelta(led, 800000, "x", "reward")
check(ok == false, "earnings category still limited")
ok = wallet.applyDelta(led, 800000, "x", nil)
check(ok == false, "no category counts as earning")
check(wallet.applyDelta(led, -5000, "Fuel", "fuel") == true, "spending always fine")
local led2 = wallet.newLedger()
led2.seeded, led2.money = true, 0
check(wallet.applyDelta(led2, 5000000, "a", "transfer") and wallet.applyDelta(led2, 5000000, "b", "transfer"), "two big transfers fit the window")
ok, why = wallet.applyDelta(led2, 1000000, "c", "transfer")
check(ok == false and why == "gain_rate_limited", "endless transfers are rate limited")

-- 18. Career reset and wrong-map careers -------------------------------------------------------------------
local profilesMod = require("rlsmp.server.profiles")
check(profilesMod.mapOf({save = {files = {["career/general.json"] = json.encode({level = "west_coast_usa"})}}}) == "west_coast_usa", "map of a career is read from its save")
check(profilesMod.mapOf({save = {files = {}}}) == nil, "no save, no map")
RLSMP.serverMap = "rls_west_coast"
local profilePath = tmp .. "/profiles/1001.json"
check(io.open(profilePath) ~= nil, "bob has a profile on disk")
local out = fire("onConsoleInput", "rlsmp reset bob")
check(out:find("career reset") and out:find("archive"), "reset reports the archive: " .. tostring(out))
check(io.open(profilePath) == nil, "profile file removed")
check(dropped[0] and dropped[0]:find("reset"), "online player is dropped with a message")
local archived = io.popen("ls " .. tmp .. "/profiles/archive/ 2>/dev/null"):read("*a")
check(archived:find("^1001%-%d+%.json"), "old save archived, not deleted")
fire("onPlayerDisconnect", 0)
check(io.open(profilePath) == nil, "leaving does not write the old profile back")
players[0] = {name = "bob", ids = {beammp = "1001"}}
fire("onPlayerJoin", 0)
fromClient(0, "rlsmpHello", {v = 1, build = require("rlsmp.shared.transfer").BUILD})
prof = find(drain(0), "big:profile")
check(prof.extra.isNew == true, "next join is a brand-new career")
check(fire("onConsoleInput", "rlsmp reset nobody-here!"):find("could not reset"), "unknown player is reported, nothing breaks")

print(string.format("server_test: %d checks passed", passed))
