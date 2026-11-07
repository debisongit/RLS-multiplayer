-- Join start logic of rlsmp_core (LuaJIT). Run: luajit tests/core_start_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
function log() end
function setExtensionUnloadMode() end
local sent = {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = name end
AddEventHandler = function() end
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
print("core_start_test: " .. passed .. " checks passed")
