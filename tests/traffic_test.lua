-- Server traffic director test (lua5.3): budget maths, joins/leaves, quota messages.
-- Run: lua5.3 tests/traffic_test.lua   (tests/run.sh does this)
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, timers, handlers = {}, {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function(ev, ms) timers[ev] = ms end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
}
Util = {}
require("rlsmp.server.util").setJsonCodec(json)

-- Fake sessions: pid -> stage
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}

local cfg = require("rlsmp.server.config").defaults
local net = require("rlsmp.server.net")
net.init(cfg)
local traffic = require("rlsmp.server.traffic")
traffic.init(cfg, "")

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end
local function tick() _G[handlers["rlsmpTrafficTick"]]() end
local function take() local t = sent sent = {} return t end

-- 1. Budget maths
local c = {totalBudget = 40, minPerPlayer = 3, maxPerPlayer = 15}
check(traffic.quotaFor(1, c) == 15, "lone player capped at max")
check(traffic.quotaFor(4, c) == 10, "40 / 4 = 10")
check(traffic.quotaFor(10, c) == 4, "40 / 10 = 4")
check(traffic.quotaFor(30, c) == 3, "never below min")
check(traffic.quotaFor(0, c) == 15, "empty server")
check(timers["rlsmpTrafficTick"] == 1000, "timer registered")

-- 2. Players who have not finished loading get nothing
stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded -> no quota")

-- 3. First loaded player
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].pid == 0 and m[1].name == "rlsmpTrafficQuota" and m[1].data.active == 15, "solo quota 15")
tick()
check(#take() == 0, "no change -> silence")

-- 4. Second player joins: both rebalanced, same revision
stages[1] = "loaded"
tick()
m = take()
-- 40/2 = 20 but capped at 15, so player 0 keeps 15 and only player 1 hears about it
check(#m == 1 and m[1].pid == 1 and m[1].data.active == 15, "second player gets 15 (cap)")

-- 5. Crowd: everyone shrinks
for pid = 2, 9 do stages[pid] = "loaded" end
tick()
m = take()
check(#m == 10, "all ten players told")
local rev = m[1].data.rev
for _, x in ipairs(m) do check(x.data.active == 4 and x.data.players == 10 and x.data.rev == rev, "ten players -> 4 each") end

-- 6. Leaving players free budget for the rest
for pid = 4, 9 do stages[pid] = nil end
tick()
m = take()
check(#m == 4 and m[1].data.active == 10 and m[1].data.rev > rev, "four left -> 10 each, newer revision")
check(traffic.current(0) == 10 and traffic.current(9) == nil, "bookkeeping follows the players")

-- 7. Disabled director stays quiet
cfg.traffic.enabled = false
stages[5] = "loaded"
tick()
check(#take() == 0, "disabled -> silent")

print(string.format("traffic_test: %d checks passed", passed))
