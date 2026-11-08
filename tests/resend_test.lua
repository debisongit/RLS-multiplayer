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
local now = 5000
require("rlsmp.server.util").setClock(function() return now end)
onInit()
local net = require("rlsmp.server.net")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function count(pid, name) local n = 0 for _, m in ipairs(sent[pid] or {}) do if m.name == name then n = n + 1 end end return n end

players[1] = {name = "ann", ids = {beammp = "1"}}
fire("onPlayerJoin", 1)
local id = net.sendBig(1, "test", string.rep("x", 100000), nil)
for _ = 1, 60 do net.pump() end
local total = count(1, "rlsmpChunk")
check(total >= 6 and net.pendingFor(1) == 0, "transfer fully sent")
fire("rlsmpChunkMissing", 1, json.encode({id = id, list = {2, 5, 99}}))
check(count(1, "rlsmpChunk") == total and net.resendsFor(1) == 2, "missing chunks are queued, not sent at once (unknown index ignored)")
net.pump()
check(count(1, "rlsmpChunk") == total + 2 and net.resendsFor(1) == 0, "missing chunks sent again by the pump")
local last = sent[1][#sent[1]].data
check(last.id == id and last.i == 5 and #last.d > 0, "resent chunk carries the data")
now = now + 1
fire("rlsmpChunkMissing", 1, json.encode({id = 999, list = {1}}))
net.pump()
check(count(1, "rlsmpChunk") == total + 2, "unknown transfer ignored")
net.dropPlayer(1)
now = now + 1
fire("rlsmpChunkMissing", 1, json.encode({id = id, list = {1}}))
check(count(1, "rlsmpChunk") == total + 2, "nothing kept after the player left")
-- flow control: only a window of chunks goes out until the client confirms progress
players[2] = {name = "bob", ids = {beammp = "2"}}
fire("onPlayerJoin", 2)
local before = count(2, "rlsmpChunk")
local id2 = net.sendBig(2, "big", string.rep("z", 16000 * 100), nil)
for _ = 1, 100 do net.pump() end
local out = count(2, "rlsmpChunk") - before
check(out > 0 and out <= 24, "no more than the window is sent before the client confirms (" .. out .. ")")
fire("rlsmpChunkProgress", 2, json.encode({id = id2, got = 24}))
for _ = 1, 100 do net.pump() end
local out2 = count(2, "rlsmpChunk") - before
check(out2 > out and out2 <= 48, "confirmed progress lets more chunks go")
for g = 24, 100, 8 do fire("rlsmpChunkProgress", 2, json.encode({id = id2, got = g})) for _ = 1, 10 do net.pump() end end
for _ = 1, 100 do net.pump() end
check(net.pendingFor(2) == 0, "transfer finishes when the client keeps confirming")

-- the window fallback trickles: after 3 s (wall clock) of silence ONE chunk, then wait again
players[3] = {name = "cid", ids = {beammp = "3"}}
fire("onPlayerJoin", 3)
local id3 = net.sendBig(3, "big", string.rep("q", 16000 * 100), nil)
for _ = 1, 50 do net.pump() end
local w = count(3, "rlsmpChunk")
check(w == 24, "window of 24 out")
now = now + 2
for _ = 1, 50 do net.pump() end
check(count(3, "rlsmpChunk") == w, "nothing more before 3 s of silence")
now = now + 1
for _ = 1, 50 do net.pump() end
check(count(3, "rlsmpChunk") == w + 1, "after 3 s exactly one chunk, not a flood (" .. count(3, "rlsmpChunk") - w .. ")")
now = now + 2
for _ = 1, 50 do net.pump() end
check(count(3, "rlsmpChunk") == w + 1, "the timer starts again after the trickled chunk")
now = now + 1
for _ = 1, 50 do net.pump() end
check(count(3, "rlsmpChunk") == w + 2, "next trickled chunk 3 s later")
fire("rlsmpChunkProgress", 3, json.encode({id = id3, got = 26}))
for _ = 1, 50 do net.pump() end
check(count(3, "rlsmpChunk") == 26 + 24, "progress opens the full window again")

-- missing-chunk requests: session only, one per second, at most 50, through the pump budget
local before3 = count(3, "rlsmpChunk")
local many = {}
for i = 1, 100 do many[i] = i end
fire("rlsmpChunkMissing", 3, json.encode({id = id3, list = many}))
check(net.resendsFor(3) == 50, "at most 50 chunks per request (" .. net.resendsFor(3) .. ")")
now = now  -- same second
fire("rlsmpChunkMissing", 3, json.encode({id = id3, list = {60, 61}}))
check(net.resendsFor(3) == 50, "a second request in the same second is ignored")
net.pump()
local perTick = count(3, "rlsmpChunk") - before3
check(perTick > 0 and perTick <= 6, "resends go out at the pump's pace (" .. perTick .. " in one tick)")
for _ = 1, 20 do net.pump() end
check(net.resendsFor(3) == 0, "all queued resends went out")
now = now + 1
fire("rlsmpChunkMissing", 3, json.encode({id = id3, list = {1, 1, 1, 2, 2.5, "x", -1}}))
check(net.resendsFor(3) == 2, "duplicates and bad numbers are not queued twice")
now = now + 1
fire("rlsmpChunkMissing", 3, json.encode({id = id3, list = {1, 2, 3}}))
check(net.resendsFor(3) == 3, "already queued chunks are not queued again")
for _ = 1, 5 do net.pump() end
now = now + 1
local mark = #sent[3]
fire("rlsmpChunkMissing", 3, json.encode({id = id3, list = {5, 80}}))
check(net.resendsFor(3) == 1, "a running transfer resends only chunks it already sent (80 is still to come)")
net.pump()
local outNow = {}
for k = mark + 1, #sent[3] do if sent[3][k].name == "rlsmpChunk" then outNow[#outNow + 1] = sent[3][k].data.i end end
check(outNow[1] == 5 and #outNow <= 2 and outNow[2] ~= 80, "the resend goes first, chunk 80 is not pushed outside the window")
players[4] = {name = "ghost", ids = {beammp = "4"}}
local ghostId = net.sendBig(4, "big", string.rep("g", 50000), nil)
for _ = 1, 20 do net.pump() end
local g = count(4, "rlsmpChunk")
now = now + 5
fire("rlsmpChunkMissing", 4, json.encode({id = ghostId, list = {1, 2}}))
fire("rlsmpChunkHeader", 4, json.encode({id = ghostId}))
for _ = 1, 5 do net.pump() end
check(count(4, "rlsmpChunk") == g and count(4, "rlsmpChunkBegin") == 1, "no session: requests ignored")

-- a lost rlsmpChunkBegin is sent again on request, for a running or a finished transfer
local function lastOf(pid, name) for k = #sent[pid], 1, -1 do if sent[pid][k].name == name then return sent[pid][k].data end end end
local b0 = count(3, "rlsmpChunkBegin")
now = now + 1
fire("rlsmpChunkHeader", 3, json.encode({id = id3}))
local h = lastOf(3, "rlsmpChunkBegin")
check(count(3, "rlsmpChunkBegin") == b0 + 1 and h.id == id3 and h.n == 100 and h.kind == "big" and h.sum, "running transfer: header sent again")
fire("rlsmpChunkHeader", 3, json.encode({id = id3}))
check(count(3, "rlsmpChunkBegin") == b0 + 1, "header requests are limited to one per second")
now = now + 1
fire("rlsmpChunkHeader", 3, json.encode({id = 4242}))
check(count(3, "rlsmpChunkBegin") == b0 + 1, "unknown transfer: no header")
local queuedId = net.sendBig(3, "later", "abc", nil)
now = now + 1
fire("rlsmpChunkHeader", 3, json.encode({id = queuedId}))
check(count(3, "rlsmpChunkBegin") == b0 + 1, "a transfer whose header has not gone out yet is not answered")
for g2 = 26, 100, 8 do fire("rlsmpChunkProgress", 3, json.encode({id = id3, got = g2})) for _ = 1, 10 do net.pump() end end
fire("rlsmpChunkProgress", 3, json.encode({id = id3, got = 100}))
for _ = 1, 50 do net.pump() end
check(net.pendingFor(3) == 0, "transfers finished")
local b1 = count(3, "rlsmpChunkBegin")
now = now + 1
fire("rlsmpChunkHeader", 3, json.encode({id = id3}))
check(count(3, "rlsmpChunkBegin") == b1 + 1 and lastOf(3, "rlsmpChunkBegin").id == id3, "finished transfer: header from the kept copy")

-- a failed send (BeamMP returns false) is tried again later, nothing is skipped
players[5] = {name = "eve", ids = {beammp = "5"}}
fire("onPlayerJoin", 5)
local realTrigger = MP.TriggerClientEvent
local failing = true
MP.TriggerClientEvent = function(pid, name, data)
  if pid == 5 and failing then return false end
  return realTrigger(pid, name, data)
end
local payload5 = string.rep("abcdefghij", 6000)
local id5 = net.sendBig(5, "eve", payload5, nil)
for _ = 1, 10 do net.pump() end
check(count(5, "rlsmpChunk") == 0 and net.pendingFor(5) == 1, "nothing counted as sent while sending fails")
failing = false
for _ = 1, 50 do net.pump() end
local transfer = require("rlsmp.shared.transfer")
local asm
for _, m in ipairs(sent[5]) do
  if m.name == "rlsmpChunkBegin" then asm = transfer.newAssembler(m.data)
  elseif m.name == "rlsmpChunk" then asm:add(m.data.i, m.data.d) end
end
check(asm and asm:isComplete() and asm:finish() == payload5, "every chunk arrived once sending works again")
MP.TriggerClientEvent = realTrigger

-- a client that gave up waiting for RLS can still finish loading later
local sessions = require("rlsmp.server.sessions")
players[6] = {name = "late", ids = {beammp = "6"}}
fire("onPlayerJoin", 6)
fire("rlsmpLoaded", 6, json.encode({ok = true}))
check(sessions.get(6).stage == "await_hello", "no loading before the hello")
fire("rlsmpHello", 6, json.encode({v = 1, build = transfer.BUILD}))
fire("rlsmpLoaded", 6, json.encode({ok = false, err = "start_timeout"}))
check(sessions.get(6).stage == "failed", "start timeout marks the session failed")
fire("rlsmpLoaded", 6, json.encode({ok = true}))
check(sessions.isLoaded(6), "a late success after the timeout loads the player")

-- 0.4.64: a stalled download is sent again, smaller and slower each time
players[7] = {name = "slow", ids = {beammp = "7"}}
fire("onPlayerJoin", 7)
fire("rlsmpRetry", 7, json.encode({attempt = 1}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 0, "a retry before the hello does nothing")
fire("rlsmpHello", 7, json.encode({v = 1, build = transfer.BUILD}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 1 and sessions.get(7).stage == "downloading", "the hello starts the first download")
local function lastBegin() for k = #sent[7], 1, -1 do if sent[7][k].name == "rlsmpChunkBegin" then return sent[7][k].data end end end
local firstChunks = lastBegin().n
sessions.get(7).profile.save.files["pad.json"] = string.rep("x", 60000)   -- a bigger save, so the chunk size shows in the chunk count
for _ = 1, 20 do net.pump() end
fire("rlsmpRetry", 7, json.encode({attempt = 0}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 1, "attempt 0 is ignored")
firstChunks = math.ceil(60000 / 16000)
fire("rlsmpRetry", 7, json.encode({attempt = 1}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 2, "the retry sends a new header")
local n1 = lastBegin().n
check(n1 > firstChunks, "attempt 1 uses smaller chunks, so more of them (" .. firstChunks .. " -> " .. n1 .. ")")
fire("rlsmpRetry", 7, json.encode({attempt = 3}))
net.pump()
local n3 = lastBegin().n
check(n3 > n1, "attempt 3 is smaller still (" .. n1 .. " -> " .. n3 .. ")")
local sentBefore = count(7, "rlsmpChunk")
net.pump()
check(count(7, "rlsmpChunk") - sentBefore == 1, "the retry paces one chunk per tick (" .. (count(7, "rlsmpChunk") - sentBefore) .. ")")
fire("rlsmpRetry", 7, json.encode({attempt = 9}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 3, "an attempt number above three is ignored")
now = now + 2
fire("rlsmpHello", 7, json.encode({v = 1, build = transfer.BUILD, again = 2}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 4, "a repeated hello (marked again) counts as a retry")
fire("rlsmpHello", 7, json.encode({v = 1, build = transfer.BUILD}))
net.pump()
check(count(7, "rlsmpChunkBegin") == 4, "a plain repeated hello is still ignored")
fire("onPlayerDisconnect", 7)
fire("onPlayerJoin", 7)
fire("rlsmpHello", 7, json.encode({v = 1, build = transfer.BUILD}))
net.pump()
local hb = lastBegin()
check(hb.n == math.ceil(hb.len / 16000), "a new join starts at the normal chunk size again (" .. hb.n .. " chunks for " .. hb.len .. " bytes)")
print("resend_test: " .. passed .. " checks passed")
