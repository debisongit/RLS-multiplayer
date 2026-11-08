-- Server traffic variety settings test (lua5.3). Run: lua5.3 tests/traffic_variety_server_test.lua
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, handlers = {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
}
Util = {}
require("rlsmp.server.util").setJsonCodec(json)
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}
local cfg = require("rlsmp.server.config").defaults
require("rlsmp.server.net").init(cfg)
local tv = require("rlsmp.server.trafficVariety")
tv.init(cfg, "")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function tick() _G[handlers["rlsmpTrafficVarietyTick"]]() end
local function take() local t = sent sent = {} return t end

-- defaults
check(cfg.trafficVariety.enabled == true and cfg.trafficVariety.maxShare == 0.25 and cfg.trafficVariety.oversample == 2, "defaults")
check(next(cfg.trafficVariety.mods) == nil and next(cfg.trafficVariety.typeWeights) == nil and next(cfg.trafficVariety.models) == nil, "no mods and no weights out of the box")
check(cfg.trafficAdmin == nil, "no admin list: the settings menu is open to everybody")
check(cfg.trafficVariety.zoneSpeedLimits.city == 17 and cfg.trafficVariety.zoneSpeedLimits.main == 27, "road class limits")
check(cfg.trafficVariety.swap.enabled == true and cfg.trafficVariety.swap.live == false, "live swapping: only watches out of the box (it replaces cars the game did not recycle)")

-- sent once, when loaded
stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded -> nothing")
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].name == "rlsmpTrafficVariety" and m[1].data.enabled == true and m[1].data.maxShare == 0.25, "settings sent on load")
check(m[1].data.applyToTraffic == true and m[1].data.applyToParked == true, "traffic and parked on")
check(m[1].data.minAmount == cfg.traffic.minAmount and cfg.traffic.minAmount > 0, "traffic.minAmount travels with the settings, so the first traffic group is big enough")
check(m[1].data.maxCars == 0, "no MP.Settings on this server: the car limit is unknown (0)")
check(m[1].data.swap.enabled == true and m[1].data.swap.live == false and m[1].data.swap.perMinute == 2, "swap settings are sent, watch only")
check(m[1].data.pool.enabled == true and m[1].data.pool.avoidLast == 6 and m[1].data.pool.brandMax == 3, "premade pool settings are sent")
check(m[1].data.respawn.enabled == true and m[1].data.respawn.perMinute == 2 and m[1].data.respawn.repaintChance == 0.5, "respawn re-roll settings are sent, on")
check(m[1].data.parked.amount == 10, "parked amount is sent (default 10)")
check(m[1].data.parked.fullPool == true and m[1].data.parked.simplifiedShare == 0.5, "parked fullPool (on) and simplifiedShare (0.5) are sent")
check(m[1].data.parked.nearCount == 6 and m[1].data.parked.nearNightCount == 10 and m[1].data.parked.nearRadius == 350 and m[1].data.parked.farRadius == 700 and m[1].data.parked.moveEverySeconds == 8, "parked near settings are sent (6 / 10 / 350 / 700 / 8)")
check(m[1].data.rarity.enabled == true and m[1].data.rarity.common == 0.88 and m[1].data.rarity.rare == 0.02 and #m[1].data.rarity.rareWords > 5, "rarity settings are sent")
check(m[1].data.preload.enabled == true and m[1].data.respawn.mode == "async" and m[1].data.preload.reserve == nil and m[1].data.preload.slowFrameMs == 45, "preload settings are sent")
check(m[1].data.simplified.enabled == false and m[1].data.simplified.parked == true and m[1].data.simplified.traffic == false and m[1].data.simplified.nearRadius == 250, "simplified settings are sent, off")
check(m[1].data.zones.highway ~= nil and m[1].data.zones.city ~= nil and m[1].data.night.Truck ~= nil, "default road class and night weights are sent")
tick()
check(#take() == 0, "sent only once")
stages[0] = nil
tick()
stages[0] = "loaded"
tick()
check(#take() == 1, "rejoin gets them again")

-- a hand-edited config.json cannot send rubbish
cfg.trafficVariety.typeWeights = {Truck = 0.5, Bad = "x", Neg = -1, Nan = 0 / 0, [1] = 5, [string.rep("n", 90)] = 1}
cfg.trafficVariety.mods = {mycar = 3, ["other car"] = math.huge}
cfg.trafficVariety.zones = {highway = {Truck = 2}, [7] = {Car = 1}}
local big = {}
for i = 1, 300 do big["t" .. i] = 1 end
cfg.trafficVariety.night = big
stages[1] = "loaded"
tick()
m = take()
local d = m[1].data
check(d.typeWeights.Truck == 0.5 and d.typeWeights.Bad == nil and d.typeWeights.Neg == nil and d.typeWeights.Nan == nil, "bad weights dropped")
check(d.typeWeights[1] == nil and d.typeWeights[string.rep("n", 90)] == nil, "bad names dropped")
check(d.mods.mycar == 3 and d.mods["other car"] == nil, "mod weights kept, infinity dropped")
cfg.trafficVariety.models = {pickup = 2, bad = "x"}
tv.resend()
stages[5] = "loaded"
tick()
m = take()
check(m[1].data.models.pickup == 2 and m[1].data.models.bad == nil, "per-model weights are sent (and sanitized)")
cfg.trafficVariety.models = {}
check(d.zones.highway.Truck == 2 and d.zones[7] == nil, "zones sanitized")
local n = 0
for _ in pairs(d.night) do n = n + 1 end
check(n == 64, "at most 64 entries per table")

-- swap switches follow the config (only a real true counts)
cfg.trafficVariety.swap = {enabled = true, live = "yes", perMinute = 5}
stages[3] = "loaded"
tick()
m = take()
check(m[1].data.swap.enabled == true and m[1].data.swap.live == false and m[1].data.swap.perMinute == 5, "swap switches: enabled passes, a non-true live stays off")
cfg.trafficVariety.swap = nil
stages[4] = "loaded"
tick()
m = take()
check(m[1].data.swap.enabled == false and m[1].data.swap.live == false, "no swap section: off")

-- switched off: still sent (so a game never guesses), with enabled = false
cfg.trafficVariety.enabled = false
stages[2] = "loaded"
tick()
m = take()
check(#m == 1 and m[1].data.enabled == false, "switched off: sent with enabled = false")

-- police variety settings are part of the payload
stages[0] = "loaded"
tv.resend()
tick()
m = take()
local pol = m[1] and m[1].data.police or {}
check(#m >= 1 and pol.enabled == true and pol.models.bastion == 0.3 and pol.undercoverShare == 0.1 and pol.maxShare == 0.4 and pol.undercoverWords[2] == "unmarked", "police variety settings are sent (Bastion low, 10% undercover)")

print(string.format("traffic_variety_server_test: %d checks passed", passed))
