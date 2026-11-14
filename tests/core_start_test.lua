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
local function hellos() local n = 0 for _, d in ipairs(sentData) do if d.name == "rlsmpHello" and not d.data.again then n = n + 1 end end return n end   -- first hellos only

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

-- 0.4.64: a download that stops is asked for again (smaller and slower each time) before the join gives up
core.onServerLeave()
core.onWorldReadyState(2)
local h4, ch4 = transfer.describe(string.rep("z", 400), 10)   -- 40 chunks
h4.id, h4.kind, h4.extra = 700, "profile", {profile = "rlsmpabc1"}
handlers.rlsmpChunkBegin(json.encode(h4))
for i = 1, 29 do handlers.rlsmpChunk(json.encode({id = 700, i = i, d = ch4[i]})) end
local r0 = count("rlsmpRetry")
for _ = 1, 11 do core.onUpdate(1) end
check(count("rlsmpRetry") == r0, "no retry before 12 s of silence")
for _ = 1, 3 do core.onUpdate(1) end
check(count("rlsmpRetry") == r0 + 1 and core.getState() == "downloading", "12 s without a new chunk: the save is asked for again")
local retryMsg
for k = #sentData, 1, -1 do if sentData[k].name == "rlsmpRetry" then retryMsg = sentData[k].data break end end
check(retryMsg.attempt == 1, "...attempt 1")
-- the new transfer arrives and completes: the join goes on
local h5, ch5 = transfer.describe(json.encode({files = {["info.json"] = "{}"}}), 4)
h5.id, h5.kind, h5.extra = 701, "profile", {profile = "rlsmpabc1"}
handlers.rlsmpChunkBegin(json.encode(h5))
for i = 1, #ch5 do handlers.rlsmpChunk(json.encode({id = 701, i = i, d = ch5[i]})) end
check(core.getState() == "starting", "the second download finishes: RLS starts")
-- a server that never answers: three retries, then the join fails
core.onServerLeave()
core.onWorldReadyState(2)
handlers.rlsmpChunkBegin(json.encode(h4))
handlers.rlsmpChunk(json.encode({id = 700, i = 1, d = ch4[1]}))
local r1 = count("rlsmpRetry")
for _ = 1, 400 do core.onUpdate(1) end
check(count("rlsmpRetry") == r1 + 3, "at most three retries, got " .. (count("rlsmpRetry") - r1) .. " state " .. core.getState())
check(core.getState() == "failed", "...then the join gives up")
-- no answer to the hello: hello again (twice) before the 60 s give-up
core.onServerLeave()
core.onWorldReadyState(2)
local hs = hellos()
for _ = 1, 45 do core.onUpdate(1) end
local repeats = 0 for _, d in ipairs(sentData) do if d.name == "rlsmpHello" and d.data.again then repeats = repeats + 1 end end
check(repeats >= 2, "silence after the hello: it is sent again (repeats so far " .. repeats .. ")")
local again
for k = #sentData, 1, -1 do if sentData[k].name == "rlsmpHello" then again = sentData[k].data break end end
check(again.again == 2, "...marked as a repeat")

-- No hello while the game is still building cars (other players' cars); it goes out once calm, or after a SHORT limit (0.4.76: 3 s of quiet,
-- at most 20 s, and the player is told why nothing happens yet)
local toasts = {}
guihooks.trigger = function(name, data) if name == "toastrMsg" then toasts[#toasts + 1] = data.msg end end
core.onServerLeave()
local h0 = hellos()
core.onVehicleSpawned(42)
core.onWorldReadyState(2)
check(core.getState() == "waiting_rls" and hellos() == h0, "cars were just built: the hello waits")
for _ = 1, 2 do core.onUpdate(1) end
check(hellos() == h0, "still waiting after 2 s")
core.onVehicleSpawned(43)
for _ = 1, 2 do core.onUpdate(1) end
check(hellos() == h0, "another car restarts the quiet time")
core.onUpdate(1)
check(hellos() == h0 + 1 and core.getState() == "hello_sent", "3 s without a new car: hello")
check(#toasts == 0, "a short wait shows no message")
core.onServerLeave()
core.onVehicleSpawned(1)
core.onWorldReadyState(2)
local saidAt
for i = 1, 30 do
  core.onUpdate(1)
  if i % 2 == 0 then core.onVehicleSpawned(i) end
  if not saidAt and hellos() == h0 + 2 then saidAt = i end
end
check(saidAt ~= nil and saidAt <= 22, "cars keep coming: the join waits at most about 20 s, then says hello anyway (said at " .. tostring(saidAt) .. " s)")
local told = 0
for _, m in ipairs(toasts) do if m:find("other players' cars", 1, true) then told = told + 1 end end
check(told == 1, "a longer wait tells the player once why the career has not started yet (" .. told .. ")")
-- the wait can never reach the server's hello limit (120 s by default) on its own
check(saidAt < 60, "the calm wait stays far below the server's hello timeout")
print("core_start_test: " .. passed .. " checks passed")
