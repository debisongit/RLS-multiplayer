-- Player items: server (lua5.3) test. Run: lua5.3 tests/items_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, chat = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end, GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = m end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
require("rlsmp.server.util").setJsonCodec(json)
onInit()
local sessions = require("rlsmp.server.sessions")
local items = require("rlsmp.server.items")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
players[1] = {name = "ann", ids = {beammp = "1"}}
fire("onPlayerJoin", 1)
fire("rlsmpHello", 1, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
check(items.give(1, "screwdriver", 1) == false, "not loaded yet: refused")
sessions.get(1).stage = "loaded"
check(items.give(1, "screwdriver") and items.has(1, "screwdriver"), "give and has")
check(items.give(1, "magic_wand") == false, "unknown item refused")
check(items.give(1, "fake_plate", 2) and items.count(1, "fake_plate") == 2, "count")
check(items.use(1, "screwdriver") and items.has(1, "screwdriver"), "durable tool stays after use")
check(items.use(1, "fake_plate") and items.count(1, "fake_plate") == 1, "paper is used up")
check(items.take(1, "fake_plate", 5) == false and items.count(1, "fake_plate") == 1, "cannot take more than owned")
check(items.take(1, "fake_plate", 1) and not items.has(1, "fake_plate"), "taken")
fire("onChatMessage", 1, "ann", "/items")
check(chat[#chat]:find("Screwdriver"), "/items lists")
check(sessions.get(1).profile.items.screwdriver == 1, "stored in the profile")
print("items_test: " .. passed .. " checks passed")
