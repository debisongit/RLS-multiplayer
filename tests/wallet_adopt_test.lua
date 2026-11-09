-- Wallet reconcile: extra money in a save is adopted up to a limit, bigger jumps are corrected (lua5.3). Run: lua5.3 tests/wallet_adopt_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
MP = MP or {RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() return true end, GetPlayerIdentifiers = function() return {} end, GetPlayerName = function() return "x" end, DropPlayer = function() end, SendChatMessage = function() end}
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local wallet = require("rlsmp.server.wallet")
local config = require("rlsmp.server.config")
wallet.init(config.defaults)
local L = wallet.newLedger()
check(wallet.reconcile(L, 1000) == 1000, "first save seeds the ledger")
local m, fix = wallet.reconcile(L, 1000)
check(m == 1000 and fix == false, "same money: nothing to fix")
m, fix = wallet.reconcile(L, 14000)   -- 13,000 more than the server counted
check(m == 14000 and fix == false and L.money == 14000, "13,000 extra is adopted (a real player lost this to the old rule)")
m, fix = wallet.reconcile(L, 14000 + 20000)   -- another 20,000 inside the same window: over the limit (25,000)
check(m == 14000 and fix == true, "a second big jump inside the window is corrected")
m, fix = wallet.reconcile(L, 5000)   -- LESS money than the server counted
check(m == 14000 and fix == true, "less money than the server counted is still corrected")
print("wallet_adopt_test: " .. passed .. " checks passed")
