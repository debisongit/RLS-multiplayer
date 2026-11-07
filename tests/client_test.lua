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
server("rlsmpChunkBegin", header)
for i = 1, #chunks do server("rlsmpChunk", {id = 1, i = i, d = (i == 2) and "XXXXXXX" or chunks[i]}) end
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
print(string.format("client_test: %d checks passed", passed))
