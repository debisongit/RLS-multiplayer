-- An old config.json gets the new lower car numbers once, and keeps changes made afterwards (lua5.3). Run: lua5.3 tests/config_trim_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
MP = MP or {RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() return true end, GetPlayerIdentifiers = function() return {} end, GetPlayerName = function() return "x" end, DropPlayer = function() end, SendChatMessage = function() end}
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local storage = require("rlsmp.server.storage")
local files = {}
local written
storage.writeJson = function(path, data) written = data files[path] = data return true end
files["cfg"] = {traffic = {maxPerPlayer = 18, baseBudget = 30, perPlayerBudget = 10, minAmount = 10, respawnDistance = 4000, spawnMaxDistance = 4000},
  trafficVariety = {parked = {amount = 10, nightAmount = 16, nearCount = 6, nearNightCount = 10}}}
storage.readJson = function(path) return files[path] end
local config = require("rlsmp.server.config")
local c = config.load("cfg")
check(c.traffic.maxPerPlayer == 8 and c.traffic.baseBudget == 16 and c.traffic.perPlayerBudget == 4 and c.traffic.minAmount == 6, "old traffic amounts get the new defaults")
check(c.traffic.respawnDistance == 1000 and c.traffic.spawnMaxDistance == 1000, "the 4 km range becomes 1 km")
local p = c.trafficVariety.parked
check(p.amount == 5 and p.nightAmount == 8 and p.nearCount == 3 and p.nearNightCount == 5, "old parked amounts get the new defaults")
check(c.migrations.carTrim70 == true, "the step is remembered")
-- a later change by the owner stays
written.traffic.maxPerPlayer = 12
local again = config.load("cfg")
check(again.traffic.maxPerPlayer == 12, "a value changed after the step is kept")
print("config_trim_test: " .. passed .. " checks passed")
