-- Lost-chunk resend: server (lua5.3) test. Run: lua5.3 tests/resend_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
require("rlsmp.server.util").setJsonCodec(json)
onInit()
local net = require("rlsmp.server.net")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function count(pid, name) local n = 0 for _, m in ipairs(sent[pid] or {}) do if m.name == name then n = n + 1 end end return n end

players[1] = {name = "ann", ids = {beammp = "1"}}
local id = net.sendBig(1, "test", string.rep("x", 100000), nil)
for _ = 1, 60 do net.pump() end
local total = count(1, "rlsmpChunk")
check(total >= 6 and net.pendingFor(1) == 0, "transfer fully sent")
fire("rlsmpChunkMissing", 1, json.encode({id = id, list = {2, 5, 99}}))
check(count(1, "rlsmpChunk") == total + 2, "missing chunks sent again (unknown index ignored)")
local last = sent[1][#sent[1]].data
check(last.id == id and last.i == 5 and #last.d > 0, "resent chunk carries the data")
fire("rlsmpChunkMissing", 1, json.encode({id = 999, list = {1}}))
check(count(1, "rlsmpChunk") == total + 2, "unknown transfer ignored")
net.dropPlayer(1)
fire("rlsmpChunkMissing", 1, json.encode({id = id, list = {1}}))
check(count(1, "rlsmpChunk") == total + 2, "nothing kept after the player left")
print("resend_test: " .. passed .. " checks passed")
