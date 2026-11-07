-- Server shared weather test (lua5.3). Run: lua5.3 tests/weather_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, handlers, timers = {}, {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function(ev, ms) timers[ev] = ms end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
}
Util = {}
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local fakeNow = 1000000
util.now = function() return fakeNow end
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}
local cfg = require("rlsmp.server.config").defaults
cfg.serverTag = "abc123"
require("rlsmp.server.net").init(cfg)
local W = require("rlsmp.server.weather")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local STEP = {}
for i, n in ipairs(W.CONDITIONS) do STEP[n] = i end

-- defaults ----------------------------------------------------------------------------------------------------------
check(cfg.weather.enabled == true and cfg.weather.periodMinutes == 15 and cfg.weather.syncSeconds == 10 and cfg.weather.force == "", "defaults")
check(#W.CONDITIONS == 6 and W.CONDITIONS[1] == "clear" and W.CONDITIONS[6] == "storm", "RLS's six conditions, in RLS's order")

-- mix -----------------------------------------------------------------------------------------------------------------
local mix = W.mix({clear = 1, rain = 3, storm = -4, drizzle = "x", overcast = 0 / 0})
check(mix.clear == 1 and mix.rain == 3 and mix.storm == 0 and mix.drizzle == 0 and mix.overcast == 0, "bad weights count as 0")
check(W.mix({}).clear == 35 and W.mix("junk").storm == 3, "nothing usable: the default mix")
check(W.mix({clear = 0}).clear == 35, "all zero: the default mix")

-- repeatable --------------------------------------------------------------------------------------------------------------
local c = {periodMinutes = 15, mix = cfg.weather.mix, force = "", serverTag = "abc123"}
local a1, p1 = W.at(5000000, c)
local a2, p2 = W.at(5000000, c)
check(a1 == a2 and p1 == p2, "the same time gives the same weather")
local _, _, left = W.at(7200000 + 100, c)
check(left == 800, "seconds until the next period (" .. left .. ")")

-- smooth, and follows the mix ----------------------------------------------------------------------------------------------------
local counts, maxJump, total = {}, 0, 0
local prev
local len = 15 * 60
for t = 0, 6000 * len, 10 do                                 -- one sample every 10 s, like the server's sync
  local cond = W.at(t, c)
  counts[cond] = (counts[cond] or 0) + 1
  total = total + 1
  if prev then maxJump = math.max(maxJump, math.abs(STEP[cond] - STEP[prev])) end
  prev = cond
end
check(maxJump == 1, "between two syncs the weather moves at most one step (" .. maxJump .. ")")
for _, name in ipairs(W.CONDITIONS) do check((counts[name] or 0) > 0, name .. " does occur") end
check(counts.clear > counts.overcast and counts.overcast > counts.storm and counts.partlyCloudy > counts.drizzle, "common conditions are more common than rare ones")
local share = function(n) return counts[n] / total * 100 end
-- gliding between random values favours the middle conditions a little, so the mix is followed only roughly
check(math.abs(share("clear") - 35) < 6 and math.abs(share("partlyCloudy") - 25) < 6 and math.abs(share("overcast") - 20) < 6, "roughly the mix (clear " .. string.format("%.0f", share("clear")) .. "%, partly " .. string.format("%.0f", share("partlyCloudy")) .. "%, overcast " .. string.format("%.0f", share("overcast")) .. "%)")
check(share("rain") > 4 and share("rain") < 12 and share("storm") > 1.5 and share("storm") < 5 and share("drizzle") > 5 and share("drizzle") < 11, "rain, drizzle and storm are rarer (rain " .. string.format("%.1f", share("rain")) .. "%, storm " .. string.format("%.1f", share("storm")) .. "%)")
local runs, runStart, runCond = {}, 0, nil
for t = 0, 400 * len, 10 do
  local cond = W.at(t, c)
  if cond ~= runCond then if runCond then runs[#runs + 1] = t - runStart end runCond, runStart = cond, t end
end
local longest, shortest = 0, math.huge
for _, r in ipairs(runs) do longest = math.max(longest, r) shortest = math.min(shortest, r) end
check(longest > 2 * len and shortest < len, "it stays the same for a while, and changes within a period too (longest " .. longest .. " s, shortest " .. shortest .. " s)")
local onlyClear = {}
for t = 0, 200 * len, 30 do onlyClear[W.at(t, {periodMinutes = 15, mix = {clear = 1}, serverTag = "abc123"})] = true end
check(next(onlyClear) == "clear" and next(onlyClear, "clear") == nil, "mix with only clear: always clear")

-- another server, another weather -------------------------------------------------------------------------------------------------------
local differ = 0
for period = 1, 400 do
  if W.at(period * len + 5, c) ~= W.at(period * len + 5, {periodMinutes = 15, mix = cfg.weather.mix, force = "", serverTag = "zzz999"}) then differ = differ + 1 end
end
check(differ > 100, "a different server tag gives a different weather (" .. differ .. " of 400 differ)")

-- force ---------------------------------------------------------------------------------------------------------------------------------
c.force = "rain"
check(W.at(5000000, c) == "rain" and W.at(9999999, c) == "rain", "forced: always that condition")
c.force = "hail"
check(W.at(5000000, c) == a1, "an unknown forced condition is ignored")

-- init and tick --------------------------------------------------------------------------------------------------------------------------
W.init(cfg)
check(timers["rlsmpWeatherTick"] == 10000, "timer every syncSeconds")
stages[0] = "await_hello"
W.tick()
check(#sent == 0, "not loaded: nothing")
stages[0] = "loaded" stages[1] = "loaded"
cfg.weather.force = ""
W.tick()
check(#sent == 2 and sent[1].name == "rlsmpWeather", "every loaded player gets the weather")
local m = sent[1].data
check(STEP[m.c] ~= nil and type(m.p) == "number" and m.n > 0 and m.n <= 900, "message: condition, period, seconds left")
local expected = W.at(fakeNow, {periodMinutes = 15, mix = cfg.weather.mix, force = "", serverTag = "abc123"})
check(m.c == expected, "it is the condition of this moment")
sent = {}
fakeNow = fakeNow + 900 * 40
W.tick()
check(#sent == 2, "again later")
cfg.weather.force = "storm"
sent = {}
W.tick()
check(sent[1].data.c == "storm", "forced from the config")

-- disabled: the timer exists (it can be switched on while the server runs) but nothing is sent ---------------------------------------------------------
handlers = {}
cfg.weather.enabled = false
cfg.weather.force = ""
W.init(cfg)
check(handlers["rlsmpWeatherTick"] ~= nil, "disabled: the timer is still registered, so enabling it later works")
sent = {}
_G[handlers["rlsmpWeatherTick"]]()
check(#sent == 0, "disabled: tick sends nothing")
cfg.weather.enabled = true
_G[handlers["rlsmpWeatherTick"]]()
check(#sent == 2, "switched on again while running: the weather is sent")

print(string.format("weather_test: %d checks passed", passed))
