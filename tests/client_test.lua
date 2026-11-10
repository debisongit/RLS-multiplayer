-- Client-side test (LuaJIT, like the game). Fakes BeamNG/BeamMP globals and an in-memory disk.
-- Run: luajit tests/client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

-- Fake game globals ------------------------------------------------------------------------------------
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent = {}
local handlers = {}
TriggerServerEvent = function(name, data) table.insert(sent, {name = name, data = json.decode(data)}) end
AddEventHandler = function(name, fn) handlers[name] = fn end

local disk = {}
local function fakeFs()
  return {
    exists = function(p)
      for k in pairs(disk) do if k:sub(1, #p + 1) == p .. "/" then return true end end
      return false
    end,
    removeDir = function(p) for k in pairs(disk) do if k:sub(1, #p + 1) == p .. "/" then disk[k] = nil end end end,
    mkdir = function() end,
    write = function(p, t) disk[(p:gsub("^/+", ""))] = t return true end,
    read = function(p) return disk[(p:gsub("^/+", ""))] end,
    findJson = function(dir)
      local d = dir:gsub("^/+", "")
      local out = {}
      for k in pairs(disk) do if k:sub(1, #d + 1) == d .. "/" and k:match("%.json$") then out[#out + 1] = "/" .. k end end
      table.sort(out)
      return out
    end,
  }
end

local transfer = require("rlsmp/lib/transfer")
local net = require("rlsmp/lib/net")
net.init()
local bridge = require("rlsmp/saveBridge")
bridge.setFs(fakeFs())
bridge.onExtensionLoaded()

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end
local function server(name, tbl) handlers[name](json.encode(tbl)) end

-- 1. Chunked download reassembles and calls the "profile" handler ----------------------------------------
local got
net.onBig("profile", function(text, extra) got = {text = text, extra = extra} end)
local payload = json.encode({files = {["info.json"] = '{"version":64}'}})
local header, chunks = transfer.describe(payload, 7)
header.id, header.kind, header.extra = 1, "profile", {profile = "rlsmpabc1001"}
server("rlsmpChunkBegin", header)
for i = #chunks, 1, -1 do server("rlsmpChunk", {id = 1, i = i, d = chunks[i]}) end -- out of order on purpose
check(got and got.text == payload and got.extra.profile == "rlsmpabc1001", "download reassembled")

-- 2. Corrupted chunk is detected ----------------------------------------------------------------------
got = nil
local bad
net.onBig("profile", function(text, extra, problem) bad = problem end)
header.id = 2   -- the server never reuses a transfer id; a finished id is ignored
server("rlsmpChunkBegin", header)
for i = 1, #chunks do server("rlsmpChunk", {id = 2, i = i, d = (i == 2) and "XXXXXXX" or chunks[i]}) end
check(bad == "checksum_mismatch", "corruption detected")

-- 3. writeProfile wipes old local data and patches the level -----------------------------------------
local root = bridge.getSaveRoot()
disk[root .. "rlsmpabc1001/autosave3/career/old.json"] = "{}"
local files = {
  ["info.json"] = '{"version":64}',
  ["career/general.json"] = '{"level":"west_coast_usa","boughtStarterVehicle":true}',
  ["career/playerAttributes.json"] = '{"money":{"value":100}}',
  ["../escape.json"] = "{}",
}
local slot = bridge.writeProfile("rlsmpabc1001", files, "rls_west_coast")
check(slot == "autosave1", "slot returned")
check(disk[root .. "rlsmpabc1001/autosave3/career/old.json"] == nil, "stale local files wiped")
check(json.decode(disk[root .. "rlsmpabc1001/autosave1/career/general.json"]).level == "rls_west_coast", "level patched")
check(disk["settings/cloud/overhaul/escape.json"] == nil, "path escape ignored")
check(bridge.writeProfile("rlsmpnew1", {}, "x") == nil, "empty profile = new career")
bridge.writeProfile("rlsmpabc1001", files, "rls_west_coast")

-- 4. After a save, only changed files are uploaded ---------------------------------------------------
bridge.enable(true, {chunkSize = 20})
local slotPath = "/" .. root .. "rlsmpabc1001/autosave2"
-- RLS saves into the next autosave folder, starting from what it loaded (the level-patched files).
local loadedPrefix = root .. "rlsmpabc1001/autosave1/"
local copy = {}
for k, text in pairs(disk) do
  if k:sub(1, #loadedPrefix) == loadedPrefix then copy[root .. "rlsmpabc1001/autosave2/" .. k:sub(#loadedPrefix + 1)] = text end
end
for k, text in pairs(copy) do disk[k] = text end
disk[root .. "rlsmpabc1001/autosave2/career/playerAttributes.json"] = '{"money":{"value":250}}'
disk[root .. "rlsmpabc1001/autosave2/career/vehicles/1.jpg"] = "binary"
sent = {}
bridge.uploadSlot(slotPath)
for _ = 1, 200 do bridge.onUpdate() end
check(sent[1].name == "rlsmpUpBegin", "upload begins")
local asm = transfer.newAssembler(sent[1].data)
for i = 2, #sent do asm:add(sent[i].data.i, sent[i].data.d) end
local up = json.decode(assert(asm:finish()))
check(up.files["career/playerAttributes.json"] ~= nil, "changed file sent")
check(up.files["info.json"] == nil, "unchanged file not sent")
check(up.files["career/general.json"] ~= nil, "level-patched file counts as changed")
check(up.all["info.json"] ~= nil and up.all["career/vehicles/1.jpg"] == nil, "full list of json files only")

-- 5. Ack updates what the server has; next identical save sends nothing --------------------------------
server("rlsmpUpAck", {id = sent[1].data.id, ok = true})
check(bridge._inFlight() == nil, "upload finished")
sent = {}
bridge.uploadSlot(slotPath)
for _ = 1, 50 do bridge.onUpdate() end
check(#sent == 0, "nothing changed -> no upload")

-- 6. Resync ack -> next upload sends everything --------------------------------------------------------
disk[root .. "rlsmpabc1001/autosave2/career/playerAttributes.json"] = '{"money":{"value":300}}'
bridge.uploadSlot(slotPath)
for _ = 1, 50 do bridge.onUpdate() end
local firstId = sent[1].data.id
overhaul_career_saveSystem = {getLastSaveStats = function() return {path = slotPath} end}
sent = {}
server("rlsmpUpAck", {id = firstId, ok = false, resync = true})
for _ = 1, 50 do bridge.onUpdate() end
asm = transfer.newAssembler(sent[1].data)
for i = 2, #sent do asm:add(sent[i].data.i, sent[i].data.d) end
up = json.decode(assert(asm:finish()))
check(up.files["info.json"] ~= nil, "resync uploads all files")

-- 7. Wallet: reports deltas, ignores its own sync, applies corrections --------------------------------
local wallet = require("rlsmp/wallet")
wallet.onExtensionLoaded()
wallet.enable(true)
local money = 100
overhaul_career_economy_playerAttributes = {
  getAttributeValue = function() return money end,
  setAttributes = function(v, reason)
    local d = v.money - money
    money = v.money
    wallet.onOverhaulPlayerAttributesChanged({money = d}, reason)
  end,
}
sent = {}
wallet.onOverhaulPlayerAttributesChanged({money = 500}, {label = {txt = "ui.delivery"}})
check(sent[1].name == "rlsmpWalletDelta" and sent[1].data.d == 500 and sent[1].data.r == "ui.delivery", "delta reported")
sent = {}
server("rlsmpWalletSet", {money = 42})
check(money == 42 and #sent == 0, "correction applied without echoing back")
wallet.onOverhaulPlayerAttributesChanged({beamXP = 10}, {})
check(#sent == 0, "non-money change ignored")

-- lost chunks are asked for again
do
  local netlib = require("rlsmp/lib/net")
  netlib.reset()
  netlib.init()
  local tr = require("rlsmp/lib/transfer")
  local header, chunks = tr.describe(string.rep("y", 50000), 16000)
  header.id = 77
  handlers["rlsmpChunkBegin"](json.encode(header))
  handlers["rlsmpChunk"](json.encode({id = 77, i = 1, d = chunks[1]}))
  handlers["rlsmpChunk"](json.encode({id = 77, i = 3, d = chunks[3]}))
  sent = {}
  check(netlib.requestMissing() == 2, "two chunks missing")
  check(sent[#sent].name == "rlsmpChunkMissing", "asks the server")
  sent = {}
  for i = 1, 8 do handlers["rlsmpChunk"](json.encode({id = 77, i = 1, d = chunks[1]})) end
  check(#sent == 0, "no progress report before 8 chunks")
end

-- heartbeat, lost headers, late duplicates
do
  local netlib = require("rlsmp/lib/net")
  netlib.reset()
  netlib.init()
  local tr = require("rlsmp/lib/transfer")
  local calls, text = 0, nil
  netlib.onBig("hb", function(t) calls = calls + 1 text = t end)
  local data = string.rep("abcdefghijklmnop", 200)
  local h, ch = tr.describe(data, 100)   -- 32 chunks
  h.id, h.kind = 90, "hb"
  local function named(name) local out = {} for _, m in ipairs(sent) do if m.name == name then out[#out + 1] = m.data end end return out end
  -- heartbeat sends the current count while a download runs, unless the every-8 report just went out
  server("rlsmpChunkBegin", h)
  sent = {}
  for i = 1, 5 do server("rlsmpChunk", {id = 90, i = i, d = ch[i]}) end
  netlib.heartbeat()
  local p = named("rlsmpChunkProgress")
  check(#p == 1 and p[1].id == 90 and p[1].got == 5, "heartbeat reports progress between the every-8 reports")
  sent = {}
  for i = 6, 8 do server("rlsmpChunk", {id = 90, i = i, d = ch[i]}) end
  check(#named("rlsmpChunkProgress") == 1, "every-8 report")
  netlib.heartbeat()
  check(#named("rlsmpChunkProgress") == 1, "no heartbeat right after a report")
  netlib.heartbeat()
  check(#named("rlsmpChunkProgress") == 2 and named("rlsmpChunkProgress")[2].got == 8, "next heartbeat repeats the count (the report may have been lost)")
  -- a duplicate header must not wipe what we have
  server("rlsmpChunkBegin", h)
  local got0 = netlib.incomingProgress()
  check(got0 == 8, "a second rlsmpChunkBegin keeps the chunks received so far")
  for i = 9, #ch do server("rlsmpChunk", {id = 90, i = i, d = ch[i]}) end
  check(calls == 1 and text == data, "transfer completes once")
  sent = {}
  server("rlsmpChunk", {id = 90, i = 3, d = ch[3]})
  server("rlsmpChunkBegin", h)
  for i = 1, #ch do server("rlsmpChunk", {id = 90, i = i, d = ch[i]}) end
  check(calls == 1 and #named("rlsmpChunkHeader") == 0 and netlib.incomingProgress() == 0, "late chunks or headers of a finished transfer are ignored")
  netlib.heartbeat()
  check(#named("rlsmpChunkProgress") == 0, "no heartbeat without a download")

  -- the header was lost: chunks for an unknown id ask for it (once), are kept, and are used when it comes
  local h2, ch2 = tr.describe(string.rep("Z", 1000), 100)   -- 10 chunks
  h2.id, h2.kind = 91, "hb"
  sent = {}
  for i = 1, 6 do server("rlsmpChunk", {id = 91, i = i, d = ch2[i]}) end
  local asks = named("rlsmpChunkHeader")
  check(#asks == 1 and asks[1].id == 91, "unknown transfer: header asked for once")
  netlib.heartbeat() netlib.heartbeat()
  check(#named("rlsmpChunkHeader") == 1, "not asked again at once")
  netlib.heartbeat()
  check(#named("rlsmpChunkHeader") == 2, "asked again after about 3 s without it")
  server("rlsmpChunkBegin", h2)
  check(netlib.incomingProgress() == 6, "chunks that came before the header are kept")
  for i = 7, 10 do server("rlsmpChunk", {id = 91, i = i, d = ch2[i]}) end
  check(calls == 2 and text == string.rep("Z", 1000), "transfer with a lost header completes")
  sent = {}
  netlib.heartbeat() netlib.heartbeat() netlib.heartbeat()
  check(#named("rlsmpChunkHeader") == 0, "no more header requests once it came")

  -- requestMissing takes turns between unfinished transfers (the server takes one request per second)
  local a, ca = tr.describe(string.rep("a", 500), 100)
  local b, cb = tr.describe(string.rep("b", 500), 100)
  a.id, a.kind, b.id, b.kind = 95, "hb", 96, "hb"
  server("rlsmpChunkBegin", a) server("rlsmpChunkBegin", b)
  server("rlsmpChunk", {id = 95, i = 1, d = ca[1]}) server("rlsmpChunk", {id = 96, i = 2, d = cb[2]})
  sent = {}
  netlib.requestMissing() netlib.requestMissing() netlib.requestMissing()
  local m = named("rlsmpChunkMissing")
  check(#m == 3 and m[1].id == 95 and m[2].id == 96 and m[3].id == 95 and #m[1].list == 4, "one transfer per request, taking turns")
end
-- 9. Leaving: the "leave" call waits for a save and its upload (the connection is gone right after it)
do
  local calls, requested = {}, 0
  MPCoreNetwork = {leaveServer = function(goBack) calls[#calls + 1] = goBack end}
  overhaul_career_saveSystem = {requestSave = function() requested = requested + 1 return true end, getLastSaveStats = function() return {path = slotPath} end}
  bridge.enable(true, {chunkSize = 20})
  for _ = 1, 50 do bridge.onUpdate() end
  while bridge._inFlight() do server("rlsmpUpAck", {id = bridge._inFlight().id, ok = true}) for _ = 1, 20 do bridge.onUpdate() end end   -- an earlier test's upload
  bridge.onUpdate()   -- installs the wrapper
  disk[root .. "rlsmpabc1001/autosave2/career/playerAttributes.json"] = '{"money":{"value":999}}'
  MPCoreNetwork.leaveServer(true)
  check(requested == 1 and #calls == 0, "leaving asks RLS for a save and does not leave yet")
  MPCoreNetwork.leaveServer(true)
  check(requested == 1 and #calls == 0, "a second press changes nothing")
  for _ = 1, 20 do bridge.onUpdate() end
  check(#calls == 0, "no save finished yet: still waiting")
  sent = {}
  bridge.onOverhaulSaveFinished()
  for _ = 1, 200 do bridge.onUpdate() end
  check(#calls == 0 and sent[1] and sent[1].name == "rlsmpUpBegin", "the save is uploading: still waiting")
  server("rlsmpUpAck", {id = sent[1].data.id, ok = true})
  bridge.onUpdate()
  check(#calls == 1 and calls[1] == true, "after the upload is acknowledged the real leave runs with its arguments")
  -- nothing to save (RLS never answers): leaves after the time limit
  calls = {}
  local realClock = os.clock
  MPCoreNetwork.leaveServer(false)
  check(#calls == 0, "waiting again")
  os.clock = function() return realClock() + 60 end
  bridge.onUpdate()
  os.clock = realClock
  check(#calls == 1 and calls[1] == false, "no answer: it leaves after the time limit")
  -- not in a session: leaves at once
  bridge.enable(false)
  calls = {}
  MPCoreNetwork.leaveServer(true)
  check(#calls == 1, "not enabled: leaves at once")
  bridge.enable(true, {chunkSize = 20})
end

print(string.format("client_test: %d checks passed", passed))
