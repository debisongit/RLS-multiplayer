-- Join start logic of rlsmp_core (LuaJIT). Run: luajit tests/core_start_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent, sentData = {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = name sentData[#sentData + 1] = {name = name, data = json.decode(data)} end
local handlers = {}
AddEventHandler = function(name, fn) handlers[name] = fn end
guihooks = {trigger = function() end}
extensions = {load = function() end}
local mp = true
MPCoreNetwork = {isMPSession = function() return mp end}
local level = "rls_west_coast"
getCurrentLevelIdentifier = function() return level end
overhaul_shell_extensionManager = {}
overhaul_shell_gameMode = {}
local core = require("rlsmp/core")
core.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function hellos() local n = 0 for _, v in ipairs(sent) do if v == "rlsmpHello" then n = n + 1 end end return n end

-- normal start
core.onWorldReadyState(2)
check(core.getState() == "hello_sent" and hellos() == 1, "world ready sends hello")
core.onWorldReadyState(2)
check(hellos() == 1, "a join in progress is not restarted")

-- a failed earlier attempt must not block the next world-ready
core.onServerLeave()
core.onWorldReadyState(2)
check(hellos() == 2, "start again after leaving")
for _ = 1, 400 do core.onUpdate(1) end   -- no answer from the server: the join gives up
check(core.getState() == "failed", "silent server ends in failed")
core.onWorldReadyState(2)
check(core.getState() == "hello_sent" and hellos() == 3, "a failed attempt is retried on the next world-ready")

-- the world-ready signal never came (mod mounted late)
core.onServerLeave()
local before = hellos()
for _ = 1, 8 do core.onUpdate(1) end
check(hellos() == before, "not before 10 s")
for _ = 1, 5 do core.onUpdate(1) end
check(hellos() == before + 1, "safety net starts the join after 10 s")
mp = false
core.onServerLeave()
for _ = 1, 20 do core.onUpdate(1) end
check(hellos() == before + 1, "never starts outside a multiplayer session")

-- downloads send a progress heartbeat; a career that RLS starts after our start timeout still gets going
mp = true
local walletOn = false
rlsmp_wallet = {enable = function(on) walletOn = on end}
rlsmp_saveBridge = {enable = function() end, writeProfile = function() return "autosave1" end, requestSave = function() end}
overhaul_shell_gameMode.start = function() return true end
local function lastLoaded() for k = #sentData, 1, -1 do if sentData[k].name == "rlsmpLoaded" then return sentData[k].data end end end
local function count(name) local n = 0 for _, v in ipairs(sent) do if v == name then n = n + 1 end end return n end
-- a failed join that never downloaded anything does not come back to life
core.onServerLeave()
core.onWorldReadyState(2)
for _ = 1, 400 do core.onUpdate(1) end
check(core.getState() == "failed", "no answer: failed")
core.onOverhaulActive(true)
check(core.getState() == "failed" and not walletOn, "RLS starting without our download is not adopted")
core.onServerLeave()
core.onWorldReadyState(2)
local transfer = require("rlsmp/lib/transfer")
local text = json.encode({files = {["info.json"] = "{}"}})
local h, ch = transfer.describe(text, 4)
h.id, h.kind, h.extra = 500, "profile", {profile = "rlsmpabc1"}
handlers.rlsmpChunkBegin(json.encode(h))
for i = 1, 3 do handlers.rlsmpChunk(json.encode({id = 500, i = i, d = ch[i]})) end
local p0 = count("rlsmpChunkProgress")
core.onUpdate(1)
check(count("rlsmpChunkProgress") == p0 + 1, "download heartbeat sent about once per second")
core.onUpdate(0.3)
check(count("rlsmpChunkProgress") == p0 + 1, "not every frame")
for i = 4, #ch do handlers.rlsmpChunk(json.encode({id = 500, i = i, d = ch[i]})) end
check(core.getState() == "starting", "profile downloaded, RLS starting")
for _ = 1, 185 do core.onUpdate(1) end
check(core.getState() == "failed" and lastLoaded().ok == false, "start timeout reported")
core.onOverhaulActive(true)
check(core.getState() == "active" and walletOn and lastLoaded().ok == true, "late RLS activation recovers: active, modules on, rlsmpLoaded ok")
core.onOverhaulActive(false)
check(core.getState() == "idle" and not walletOn, "closing the career afterwards works as usual")
-- lost chunks are asked for while later ones still trickle in (the server trickles when its window is full)
core.onServerLeave()
core.onWorldReadyState(2)
local h3, ch3 = transfer.describe(string.rep("w", 400), 10)   -- 40 chunks
h3.id, h3.kind, h3.extra = 600, "profile", {profile = "rlsmpabc1"}
handlers.rlsmpChunkBegin(json.encode(h3))
for _, i in ipairs({1, 2, 3, 10}) do handlers.rlsmpChunk(json.encode({id = 600, i = i, d = ch3[i]})) end
local m0 = count("rlsmpChunkMissing")
local nextChunk, asked = 11, nil
for step = 1, 6 do
  core.onUpdate(1)
  if step % 3 == 0 then handlers.rlsmpChunk(json.encode({id = 600, i = nextChunk, d = ch3[nextChunk]})) nextChunk = nextChunk + 1 end
  if count("rlsmpChunkMissing") > m0 and not asked then asked = step end
end
local miss
for k = #sentData, 1, -1 do if sentData[k].name == "rlsmpChunkMissing" then miss = sentData[k].data break end end
check(asked and asked <= 5 and miss.id == 600 and miss.list[1] == 4 and miss.list[6] == 9, "holes are asked for within ~4 s although chunks keep coming")
print("core_start_test: " .. passed .. " checks passed")
