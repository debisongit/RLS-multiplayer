-- Traffic menu server test (lua5.3). Run: lua5.3 tests/traffic_admin_test.lua <tmpdir>
-- The security boundary of the in-game traffic menu: who may change settings, what may be changed, and what happens afterwards.
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")

local sent, chat, handlers, warned = {}, {}, {}, {}
local players = {}      -- pid -> BeamMP name
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
  SendChatMessage = function(pid, text) table.insert(chat, {pid = pid, text = text}) end,
  GetPlayerName = function(pid) return players[pid] end,
}
Util = {}
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local second = 1000
util.now = function() return second end
local origWarn = util.warn
util.warn = function(msg) warned[#warned + 1] = msg end

local sess = {}   -- pid -> session table
package.loaded["rlsmp.server.sessions"] = {
  all = function() return sess end,
  get = function(pid) return sess[pid] end,
  isLoaded = function(pid) return sess[pid] ~= nil and sess[pid].stage == "loaded" end,
}
local function join(pid, name, extra)
  players[pid] = name
  sess[pid] = {pid = pid, name = name, accountId = "acc" .. pid, guest = false, stage = "loaded"}
  for k, v in pairs(extra or {}) do sess[pid][k] = v end
end

local configModule = require("rlsmp.server.config")
local cfg = util.deepMerge(configModule.defaults, {})
cfg.serverTag = "tag"
require("rlsmp.server.net").init(cfg)
for _, m in ipairs({"smartTraffic", "trafficVariety", "trafficPolice", "traffic", "weather"}) do require("rlsmp.server." .. m).init(cfg, tmp .. "/") end
local admin = require("rlsmp.server.trafficAdmin")
admin.init(cfg, tmp .. "/")

local sections = {smartTraffic = cfg.smartTraffic, trafficVariety = cfg.trafficVariety, traffic = cfg.traffic, weather = cfg.weather, police = cfg.police}

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function take() local t = sent sent = {} return t end
local function find(list, name, pid) for _, m in ipairs(list) do if m.name == name and (pid == nil or m.pid == pid) then return m end end end
local function fromClient(pid, ev, tbl) _G[handlers[ev]](pid, json.encode(tbl)) end
local function say(pid, text) _G[handlers["onChatMessage"]](pid, players[pid], text) end
local function nextSecond() second = second + 1 end
local function set(pid, changes, rm) nextSecond() fromClient(pid, "rlsmpTrafficAdminSet", {set = changes, rm = rm}) end
local function lastResult() local m = find(take(), "rlsmpTrafficAdminResult") return m and m.data end

join(0, "polakpls")
join(1, "SUCUK21")
join(2, "someoneelse")
join(3, "guest1234", {guest = true})
join(4, "guest4321")

-- who: everybody on the server (no admin list any more) ----------------------------------------------------------------------------------------
check(admin.canUse(0) == true and admin.canUse(1) == true and admin.canUse(2) == true, "every player may use the menu")
check(admin.canUse(3) == true and admin.canUse(4) == true, "also guests")
check(admin.canUse(99) == false, "but not somebody who has no session (not on the server)")
check(cfg.trafficAdmin == nil and admin.isAdmin == nil, "there is no admin list and no admin check left")

-- the menu opens for everybody -----------------------------------------------------------------------------------------------------------------
nextSecond()
fromClient(2, "rlsmpTrafficAdminGet", {})
local m = take()
check(#m == 1 and m[1].data.ok == true and type(m[1].data.cfg) == "table", "an ordinary player gets the settings")
local snap = m[1].data.cfg
check(snap.smartTraffic.mix.normal == 80 and snap.traffic.maxPerPlayer == 18 and snap.weather.mix.clear == 35 and snap.police.antiTeleport == true, "...the current values")
check(snap.trafficAdmin == nil and snap.serverTag == nil and snap.identity == nil, "...and only the editable parts, never the server tag or other config")
nextSecond()
fromClient(99, "rlsmpTrafficAdminGet", {})
m = take()
check(#m == 1 and m[1].data.ok == false and m[1].data.cfg == nil, "a pid without a session gets nothing")
chat = {}
say(2, "/trafficmenu")
check(find(take(), "rlsmpTrafficAdminOpen", 2) ~= nil, "/trafficmenu opens the menu for an ordinary player")
say(3, "/trafficmenu")
check(find(take(), "rlsmpTrafficAdminOpen", 3) ~= nil, "...and for a guest")
local before = json.encode(cfg)
set(99, {{p = {"smartTraffic", "mix", "drunk"}, v = 50}})
check(json.encode(cfg) == before and not find(take(), "rlsmpTrafficAdminResult"), "somebody not on the server cannot change anything")
set(2, {{p = {"smartTraffic", "mix", "drunk"}, v = 7}})
r = lastResult()
check(r and r.applied == 1 and cfg.smartTraffic.mix.drunk == 7, "an ordinary player can change a setting")
set(3, {{p = {"smartTraffic", "mix", "drunk"}, v = 6}})
r = lastResult()
check(r and r.applied == 1 and cfg.smartTraffic.mix.drunk == 6, "a guest can too")

-- valid changes -----------------------------------------------------------------------------------------------------------------------------------
set(0, {
  {p = {"smartTraffic", "mix", "drunk"}, v = 5},
  {p = {"smartTraffic", "policeReact"}, v = false},
  {p = {"traffic", "totalBudget"}, v = 60.4},
  {p = {"trafficVariety", "typeWeights", "Truck"}, v = 0.5},
  {p = {"trafficVariety", "models", "pickup"}, v = 3},
  {p = {"trafficVariety", "zones", "highway", "Truck"}, v = 2},
  {p = {"trafficVariety", "night", "pickup"}, v = 0},
  {p = {"trafficVariety", "swap", "enabled"}, v = true},
  {p = {"trafficVariety", "parked", "amount"}, v = 14},
  {p = {"trafficVariety", "respawn", "perMinute"}, v = 5},
  {p = {"trafficVariety", "pool", "brandMax"}, v = 2},
  {p = {"weather", "force"}, v = "rain"},
  {p = {"weather", "mix", "storm"}, v = 10},
  {p = {"police", "antiTeleport"}, v = false},
  {p = {"police", "bubbleMode"}, v = "protect"},
})
local r = lastResult()
check(r and r.applied == 15 and #r.rejected == 0 and r.saved == true, "fifteen valid changes applied and saved")
check(cfg.smartTraffic.mix.drunk == 5 and cfg.smartTraffic.policeReact == false, "personality percentage and police reaction changed")
check(cfg.traffic.totalBudget == 60, "a whole-number setting is rounded")
check(cfg.trafficVariety.typeWeights.Truck == 0.5 and cfg.trafficVariety.models.pickup == 3, "Type and model weights set")
check(cfg.trafficVariety.zones.highway.Truck == 2 and cfg.trafficVariety.night.pickup == 0, "where (road class) and when (night) set, a new zone map was created")
check(cfg.trafficVariety.swap.enabled == true and cfg.weather.force == "rain" and cfg.weather.mix.storm == 10 and cfg.police.antiTeleport == false and cfg.police.bubbleMode == "protect", "swap, weather and police settings set")
check(cfg.trafficVariety.parked.amount == 14 and cfg.trafficVariety.respawn.perMinute == 5 and cfg.trafficVariety.pool.brandMax == 2, "parked, respawn and pool settings can be set from the menu")
for name, tbl in pairs(sections) do check(cfg[name] == tbl, "section " .. name .. " is still the same table (the modules keep references to it)") end
local f = assert(io.open(tmp .. "/config/config.json", "r"))
local onDisk = json.decode(f:read("*a"))
f:close()
check(onDisk.smartTraffic.mix.drunk == 5 and onDisk.trafficVariety.models.pickup == 3 and onDisk.weather.force == "rain", "saved to config.json")
check(onDisk.traffic ~= nil and onDisk.serverTag == cfg.serverTag, "(the file is the whole config)")

-- police variety settings are editable and in the snapshot ---------------------------------------------------------------------------------------------
take()
set(1, {{p = {"trafficVariety", "police", "models", "bastion"}, v = 0.1}, {p = {"trafficVariety", "police", "undercoverShare"}, v = 0.2},
  {p = {"trafficVariety", "police", "maxShare"}, v = 0.5}, {p = {"trafficVariety", "police", "enabled"}, v = true}})
r = lastResult()
check(r and r.applied == 4 and #r.rejected == 0, "police variety settings apply")
check(cfg.trafficVariety.police.models.bastion == 0.1 and cfg.trafficVariety.police.undercoverShare == 0.2, "...and are stored")
check(admin.snapshot().trafficVariety.police.models.bastion == 0.1 and admin.snapshot().trafficVariety.police.maxShare == 0.5, "...and are in the snapshot for the menu")
set(1, {{p = {"trafficVariety", "police", "undercoverShare"}, v = 5}, {p = {"trafficVariety", "police", "undercoverWords"}, v = 1}})
r = lastResult()
check(r and r.applied == 0 and #r.rejected == 2, "out-of-range share and the word list are refused")

-- modules resend to everybody, admins get the fresh state ------------------------------------------------------------------------------------------
sent = {}
_G[handlers["rlsmpSmartTrafficTick"]]()
local st = find(sent, "rlsmpSmartTraffic", 0)
check(st ~= nil and st.data.mix.drunk == 5 and st.data.policeReact == false, "smart traffic sends the new percentages to everybody again")
sent = {}
_G[handlers["rlsmpTrafficVarietyTick"]]()
local tv = find(sent, "rlsmpTrafficVariety", 2)
check(tv ~= nil and tv.data.models.pickup == 3 and tv.data.zones.highway.Truck == 2 and tv.data.swap.enabled == true, "traffic variety resends too, to a player who has the menu closed")
sent = {}
_G[handlers["rlsmpWeatherTick"]]()
check(find(sent, "rlsmpWeather", 2).data.c == "rain", "the weather module reads the new forced condition")
set(1, {{p = {"traffic", "maxPerPlayer"}, v = 20}})
m = take()
check(find(m, "rlsmpTrafficAdminState", 1) ~= nil and find(m, "rlsmpTrafficAdminState", 2) ~= nil and find(m, "rlsmpTrafficAdminState", 3) ~= nil and find(m, "rlsmpTrafficAdminState", 4) == nil,
  "after a change everybody who has the menu open (asked, or changed something) gets the fresh state, a player who never opened it does not")
check(find(m, "rlsmpTrafficAdminResult", 1).data.applied == 1, "the sender gets the result")

-- the allowlist ---------------------------------------------------------------------------------------------------------------------------------------
local function rejectedWith(change)
  set(0, {change})
  local res = lastResult()
  return res and res.applied == 0 and #res.rejected == 1 and res.rejected[1].why or "NOT REJECTED"
end
check(rejectedWith({p = {"trafficAdmin", "names"}, v = {"me"}}):find("not an editable"), "the admin list cannot be edited from the menu")
check(rejectedWith({p = {"identity", "allowGuests"}, v = true}):find("not an editable"), "identity settings cannot be edited")
check(rejectedWith({p = {"serverTag"}, v = "x"}):find("bad path"), "the server tag cannot be edited")
check(rejectedWith({p = {"transfer", "chunkSize"}, v = 1}):find("not an editable"), "transfer settings cannot be edited")
check(rejectedWith({p = {"claims", "dryRun"}, v = false}):find("not an editable"), "claims settings cannot be edited")
check(rejectedWith({p = {"wallet", "maxSingleGain"}, v = 9e9}):find("not an editable"), "wallet limits cannot be edited")
check(rejectedWith({p = {"trafficVariety"}, v = {}}):find("bad path"), "a whole section cannot be replaced")
check(rejectedWith({p = {"weather", "periodMinutes"}, v = 5}):find("not an editable"), "weather period (read once) is not editable")
check(rejectedWith({p = {"traffic", "checkSeconds"}, v = 0}):find("not an editable"), "timer intervals (read once) are not editable")
check(rejectedWith({p = {"smartTraffic", "mix", "unicorn"}, v = 1}):find("not an editable"), "unknown personality")
check(rejectedWith({p = {"trafficVariety", "zones", "mars", "Truck"}, v = 1}):find("not an editable"), "unknown zone")
check(rejectedWith({p = {"trafficVariety", "models", "a.b"}, v = 1}):find("bad name"), "a dot in a name")
check(rejectedWith({p = {"trafficVariety", "models", string.rep("x", 70)}, v = 1}):find("bad name"), "a too long name")
check(rejectedWith({p = {"trafficVariety", "models", "../x"}, v = 1}):find("bad name"), "path characters in a name")
check(rejectedWith({p = {"trafficVariety", "models", ""}, v = 1}):find("bad name"), "an empty name")
check(rejectedWith({p = {"trafficVariety", "typeWeights", "Truck"}, v = 21}):find("out of range"), "a weight above 20")
check(rejectedWith({p = {"trafficVariety", "typeWeights", "Truck"}, v = -1}):find("out of range"), "a negative weight")
check(rejectedWith({p = {"smartTraffic", "mix", "slow"}, v = 101}):find("out of range"), "a percentage above 100")
check(rejectedWith({p = {"traffic", "maxPerPlayer"}, v = 0}):find("out of range"), "max per player below 1")
check(rejectedWith({p = {"trafficVariety", "maxShare"}, v = 0}):find("out of range"), "maxShare below 0.05")
check(rejectedWith({p = {"traffic", "totalBudget"}, v = "60"}):find("needs a number"), "a number sent as text")
local nanApplied, nanRejected = admin.applyPatch({set = {{p = {"traffic", "totalBudget"}, v = 0 / 0}, {p = {"traffic", "totalBudget"}, v = math.huge}}})
check(nanApplied == 0 and #nanRejected == 2 and cfg.traffic.totalBudget == 60, "NaN and infinity are not accepted (checked directly: JSON cannot carry them)")
check(rejectedWith({p = {"weather", "enabled"}, v = 1}):find("true or false"), "a number sent for a switch")
check(rejectedWith({p = {"weather", "force"}, v = "hail"}):find("not an allowed"), "an unknown weather condition")
check(rejectedWith({p = {"weather", "force"}, v = 5}):find("not an allowed"), "a number for the weather condition")
check(rejectedWith({p = "weather.force", v = "rain"}) ~= "NOT REJECTED", "a path that is not a list")
check(rejectedWith({p = {"weather", 5}, v = "rain"}):find("bad path"), "a path with a number in it")
check(rejectedWith({p = {"a", "b", "c", "d", "e"}, v = 1}):find("bad path"), "a path that is too long")
check(rejectedWith({v = 1}) ~= "NOT REJECTED", "a change without a path")
check(cfg.weather.force == "rain" and cfg.traffic.maxPerPlayer == 20, "...and so are the earlier settings")

-- a mix of good and bad: the good ones count ---------------------------------------------------------------------------------------------------------------
set(0, {{p = {"traffic", "baseBudget"}, v = 35}, {p = {"traffic", "baseBudget"}, v = "x"}, {p = {"serverTag"}, v = "y"}})
r = lastResult()
check(r.applied == 1 and #r.rejected == 2 and cfg.traffic.baseBudget == 35, "good changes are applied even if others in the same message are rejected")

-- removing a weight ---------------------------------------------------------------------------------------------------------------------------------------------
set(0, nil, {{"trafficVariety", "models", "pickup"}, {"trafficVariety", "zones", "highway", "Truck"}, {"trafficVariety", "models", "never_set"}})
r = lastResult()
check(r.applied == 2 and cfg.trafficVariety.models.pickup == nil and cfg.trafficVariety.zones.highway.Truck == nil, "weights can be reset to default (removed)")
set(0, nil, {{"traffic", "totalBudget"}})
r = lastResult()
check(r.applied == 0 and r.rejected[1].why:find("cannot be removed"), "a normal setting cannot be removed")
check(cfg.traffic.totalBudget == 60, "...it stays")

-- limits --------------------------------------------------------------------------------------------------------------------------------------------------------------
local many = {}
for i = 1, 65 do many[i] = {p = {"trafficVariety", "models", "m" .. i}, v = 1} end
set(0, many)
r = lastResult()
check(r.applied == 0 and r.rejected[1].why:find("too many"), "more than 64 changes in one message: all refused")
check(cfg.trafficVariety.models.m1 == nil, "...none applied")
second = second + 1
take()
for i = 1, 5 do fromClient(0, "rlsmpTrafficAdminSet", {set = {{p = {"traffic", "baseBudget"}, v = 40 + i}}}) end
local results = 0
for _, msg in ipairs(take()) do if msg.name == "rlsmpTrafficAdminResult" then results = results + 1 end end
check(results == 3, "at most 3 messages per second are handled (" .. results .. ")")

-- a settings change keeps working when the config cannot be saved ------------------------------------------------------------------------------------------------
local blocker = assert(io.open(tmp .. "/blocker", "w")) blocker:write("a file, not a folder") blocker:close()
admin.init(cfg, tmp .. "/blocker/")          -- config/config.json cannot be created below a plain file
set(0, {{p = {"traffic", "baseBudget"}, v = 33}})
r = lastResult()
check(r and r.applied == 1 and r.saved == false and cfg.traffic.baseBudget == 33, "if config.json cannot be written: applied in memory, the result says saved = false")
check(warned[#warned] ~= nil, "(and nothing crashed)")

-- the weather module follows its switch live -----------------------------------------------------------------------------------------------------------------------
admin.init(cfg, tmp .. "/")
set(0, {{p = {"weather", "enabled"}, v = false}})
take()
_G[handlers["rlsmpWeatherTick"]]()
check(not find(take(), "rlsmpWeather"), "weather switched off from the menu: nothing is sent any more")
set(0, {{p = {"weather", "enabled"}, v = true}})
take()
_G[handlers["rlsmpWeatherTick"]]()
check(find(take(), "rlsmpWeather") ~= nil, "...and on again")

-- theft, fence and black market settings ---------------------------------------------------------------------------------------------------------------------------
admin.init(cfg, tmp .. "/")
take()
set(0, {{p = {"theft", "perMille"}, v = 300}, {p = {"theft", "jammerNoiseFactor"}, v = 0.5}, {p = {"theft", "methods", "window_screwdriver", "seconds"}, v = 12},
  {p = {"theft", "methods", "signal_cloner", "failChance"}, v = 0.5}, {p = {"fence", "stripRate"}, v = 0.4}, {p = {"fence", "rep", "resell"}, v = 5},
  {p = {"market", "tiers", "screwdriver", "price"}, v = 999}, {p = {"market", "tiers", "jammer", "off"}, v = true}, {p = {"market", "fenceCarRate"}, v = 0.5},
  {p = {"theft", "enabled"}, v = true}})
r = lastResult()
check(r.applied == 10 and #r.rejected == 0, "theft, fence and market settings are accepted")
check(cfg.theft.perMille == 300 and cfg.theft.methods.window_screwdriver.seconds == 12 and cfg.theft.methods.signal_cloner.failChance == 0.5
  and cfg.fence.stripRate == 0.4 and cfg.fence.rep.resell == 5 and cfg.market.tiers.screwdriver.price == 999 and cfg.market.tiers.jammer.off == true
  and cfg.market.fenceCarRate == 0.5 and cfg.theft.enabled == true, "...and written into the live config tables")
set(0, {{p = {"theft", "perMille"}, v = 5000}, {p = {"theft", "witnessCap"}, v = -1}, {p = {"theft", "tiers", "keylessYear"}, v = 1800},
  {p = {"fence", "rep", "resell"}, v = 99}, {p = {"fence", "stripRate"}, v = 3}, {p = {"market", "pickupRadius"}, v = 1},
  {p = {"market", "tiers", "screwdriver", "price"}, v = 0}, {p = {"theft", "methods", "window_screwdriver", "noise"}, v = 3}, {p = {"theft", "methods", "signal_cloner", "failChance"}, v = 2}})
r = lastResult()
check(r.applied == 0 and #r.rejected == 9, "every out-of-range value is refused (" .. tostring(#r.rejected) .. " of 9)")
check(cfg.theft.perMille == 300 and cfg.market.tiers.screwdriver.price == 999, "...and nothing changed")
set(0, {{p = {"theft", "methods", "made_up_method", "seconds"}, v = 5}, {p = {"market", "tiers", "made_up_item", "price"}, v = 5},
  {p = {"theft", "methods", "window_screwdriver", "items"}, v = 5}, {p = {"market", "dropSpots"}, v = 5}, {p = {"fence", "enabled", "x"}, v = true},
  {p = {"trafficAdmin", "names"}, v = "x"}, {p = {"theft", "methods", "window_screwdriver", "tier"}, v = "luxury"}})
r = lastResult()
check(r.applied == 0 and #r.rejected == 7, "unknown methods and items, item lists, drop spots, the admin list and tiers of methods cannot be set")
set(0, {{p = {"theft", "perMille"}, v = 250.6}})
lastResult()
check(cfg.theft.perMille == 251, "whole-number settings are rounded")
-- the snapshot carries the new sections for the menu
local sn = admin.snapshot()
check(sn.theft.perMille == 251 and sn.theft.methods.window_screwdriver.seconds == 12 and sn.theft.tiers.keylessYear == cfg.theft.tiers.keylessYear
  and sn.fence.rep.resell == 5 and sn.market.tiers.screwdriver.price == 999 and sn.market.fenceCarRate == 0.5, "the snapshot has theft, fence and market values")
check(sn.market.dropSpots == nil and sn.theft.methods.window_screwdriver.items == nil and sn.theft.methods.window_screwdriver.tier == nil, "...and only the editable ones")
local allOn = true
for name, m in pairs(sn.theft.methods) do if m.enabled ~= true then allOn = false end end
check(next(sn.theft.methods) ~= nil and allOn, "the default methods have no enabled key in the config but show as ON in the menu")
cfg.theft.methods.relay_box.enabled = false
check(admin.snapshot().theft.methods.relay_box.enabled == false and admin.snapshot().theft.methods.signal_cloner.enabled == true, "a method switched off shows as off")
cfg.theft.methods.relay_box.enabled = nil
set(0, {{p = {"police", "copCount"}, v = 2}, {p = {"police", "copCount"}, v = 9}, {p = {"police", "copTopUpSeconds"}, v = 1}, {p = {"police", "copTopUpSeconds"}, v = 45}})
r = lastResult()
check(r and r.applied == 2 and #r.rejected == 2 and cfg.police.copCount == 2 and cfg.police.copTopUpSeconds == 45, "police car count and top-up time: in range accepted, out of range refused")
check(admin.snapshot().police.copCount == 2 and admin.snapshot().police.copTopUpSeconds == 45, "the snapshot carries them")
cfg.police.copCount, cfg.police.copTopUpSeconds = 3, 30
set(0, {{p = {"police", "respawnRebuildSeconds"}, v = 5}, {p = {"police", "respawnRebuildSeconds"}, v = 120}, {p = {"police", "copRespawnDistance"}, v = 9000}, {p = {"police", "copRespawnDistance"}, v = 600}})
r = lastResult()
check(cfg.police.respawnRebuildSeconds == 120 and cfg.police.copRespawnDistance == 600, "rebuild interval and cop respawn distance: in range accepted")
check(admin.snapshot().police.respawnRebuildSeconds == 120 and admin.snapshot().police.copRespawnDistance == 600, "...and in the snapshot")
cfg.police.respawnRebuildSeconds, cfg.police.copRespawnDistance = 90, 450
set(0, {{p = {"trafficVariety", "focus", "configs"}, v = 9}, {p = {"trafficVariety", "focus", "configs"}, v = 1}, {p = {"trafficVariety", "focus", "minutes"}, v = 30}, {p = {"trafficVariety", "focus", "enabled"}, v = false}})
r = lastResult()
check(cfg.trafficVariety.focus.configs == 1 and cfg.trafficVariety.focus.minutes == 30 and cfg.trafficVariety.focus.enabled == false, "focus settings: in range accepted")
check(admin.snapshot().trafficVariety.focus.configs == 1 and admin.snapshot().trafficVariety.focus.minutes == 30, "...and in the snapshot")
cfg.trafficVariety.focus = {enabled = true, configs = 2, minutes = 20}
set(0, {{p = {"fence", "phone"}, v = false}, {p = {"fence", "gambleBust"}, v = 0.1}, {p = {"fence", "gambleBase"}, v = 0.5}})
r = lastResult()
check(r and r.applied == 1 and #r.rejected == 2 and cfg.fence.phone == false and admin.snapshot().fence.phone == false, "fence.phone can be switched; the gamble settings are gone from the menu's allowlist")
check(admin.snapshot().fence.gambleBust == nil and admin.snapshot().fence.rep.gamble == nil, "...and from the snapshot")
cfg.fence.phone = true
set(0, {{p = {"police", "respawnBehind"}, v = false}, {p = {"police", "respawnPerMinute"}, v = 99}, {p = {"police", "spawnMinDistance"}, v = 1500}, {p = {"police", "spawnMinDistance"}, v = 50}})
r = lastResult()
check(r and r.applied == 2 and #r.rejected == 2 and cfg.police.respawnBehind == false and cfg.police.spawnMinDistance == 1500, "cop respawn settings: in range accepted, out of range refused")
check(admin.snapshot().police.respawnBehind == false and admin.snapshot().police.spawnMinDistance == 1500, "the snapshot carries them")
cfg.police.respawnBehind, cfg.police.spawnMinDistance = true, 1000
set(0, {{p = {"police", "chaseSpawnMinDistance"}, v = 700}, {p = {"police", "chaseSpawnMinDistance"}, v = 10}, {p = {"police", "spawnPreferRight"}, v = false}, {p = {"police", "respawnGap"}, v = 150}})
r = lastResult()
check(r and r.applied == 2 and #r.rejected == 2 and cfg.police.chaseSpawnMinDistance == 700 and cfg.police.spawnPreferRight == false, "chase minimum distance and right-side preference: in range accepted; the old respawnGap is no longer a setting")
check(admin.snapshot().police.chaseSpawnMinDistance == 700 and admin.snapshot().police.spawnPreferRight == false, "...and in the snapshot")
cfg.police.chaseSpawnMinDistance, cfg.police.spawnPreferRight = 600, true
set(0, {{p = {"traffic", "spawnMinDistance"}, v = 300}, {p = {"traffic", "spawnMinDistance"}, v = 10}, {p = {"traffic", "spawnMaxDistance"}, v = 3000}, {p = {"traffic", "spawnMaxDistance"}, v = 9000}})
r = lastResult()
check(r and r.applied == 2 and #r.rejected == 2 and cfg.traffic.spawnMinDistance == 300 and cfg.traffic.spawnMaxDistance == 3000, "traffic spawn ring: in range accepted, out of range refused")
check(admin.snapshot().traffic.spawnMinDistance == 300 and admin.snapshot().traffic.spawnMaxDistance == 3000, "...and in the snapshot")
cfg.traffic.spawnMinDistance, cfg.traffic.spawnMaxDistance = 250, 4000
set(0, {{p = {"smartTraffic", "nightMult", "drunk"}, v = 8}, {p = {"smartTraffic", "nightMult", "racer"}, v = 25}, {p = {"smartTraffic", "nightMult", "bogus"}, v = 1}})
r = lastResult()
check(r and r.applied == 1 and #r.rejected == 2 and cfg.smartTraffic.nightMult.drunk == 8, "night multipliers: in range accepted, out of range and unknown names refused")
check(admin.snapshot().smartTraffic.nightMult.drunk == 8 and admin.snapshot().smartTraffic.nightMult.racer == 4, "the snapshot carries them")
cfg.smartTraffic.nightMult.drunk = 6
set(0, {{p = {"police", "noFineInStolenCar"}, v = false}})
r = lastResult()
check(r and r.applied == 1 and cfg.police.noFineInStolenCar == false and admin.snapshot().police.noFineInStolenCar == false, "the no-fine-in-a-stolen-car switch can be changed from the menu")
cfg.police.noFineInStolenCar = true
check(admin.snapshot().police.noFineInStolenCar == true, "...and is on by default")
set(0, {{p = {"police", "enabled"}, v = false}, {p = {"police", "plateReading", "readChance"}, v = 0.2}, {p = {"police", "plateReading", "rangeMeters"}, v = 500}})
r = lastResult()
check(r.applied == 2 and #r.rejected == 1 and cfg.police.enabled == false and cfg.police.plateReading.readChance == 0.2 and cfg.police.plateReading.rangeMeters ~= 500,
  "police on/off and plate reading settings can be edited, out of range refused")
check(admin.snapshot().police.enabled == false and admin.snapshot().police.plateReading.readChance == 0.2, "the snapshot has them")
cfg.police.enabled = true
set(0, {{p = {"theft", "enabled"}, v = false}})
take()
check(cfg.theft.enabled == false and admin.snapshot().theft.enabled == false, "theft can be switched off again")

-- simplified (stand-in) cars: off by default, editable with ranges, in the snapshot
check(cfg.trafficVariety.simplified.enabled == false and cfg.trafficVariety.simplified.traffic == false and cfg.trafficVariety.simplified.nearRadius == 250, "simplified: off by default")
set(0, {{p = {"trafficVariety", "simplified", "enabled"}, v = true}, {p = {"trafficVariety", "simplified", "nearRadius"}, v = 300}, {p = {"trafficVariety", "simplified", "nearRadius"}, v = 50}, {p = {"trafficVariety", "simplified", "perMinute"}, v = 99}})
r = lastResult()
check(r.applied == 2 and #r.rejected == 2 and cfg.trafficVariety.simplified.enabled == true and cfg.trafficVariety.simplified.nearRadius == 300, "simplified: switch and radius edited, radius under 120 m and 99 per minute refused")
check(admin.snapshot().trafficVariety.simplified.enabled == true and admin.snapshot().trafficVariety.simplified.nearRadius == 300, "simplified: in the snapshot")
cfg.trafficVariety.simplified.enabled = false

-- respawn range and delay: defaults keep the game's original, editable within range, sent to the clients inside rlsmpPoliceConfig
check(cfg.traffic.respawnRange == 1.0 and cfg.traffic.respawnDelay == 0, "range: defaults are the game's original (1.0, 0 s)")
check(cfg.traffic.unjam.enabled == true and cfg.traffic.unjam.seconds == 120 and cfg.traffic.unjam.distance == 400, "range: stuck recycling needs 120 s and 400 m")
check(cfg.trafficVariety.swap.live == false, "range: live swapping (replaces cars the game did not recycle) is off by default")
check(require("rlsmp.server.trafficPolice").payload().range.respawnRange == 1, "range: the clients get it with the police config")
set(0, {{p = {"traffic", "respawnRange"}, v = 2.5}, {p = {"traffic", "respawnDelay"}, v = 45}, {p = {"traffic", "respawnRange"}, v = 9}, {p = {"traffic", "unjam", "distance"}, v = 10}})
r = lastResult()
check(r.applied == 2 and #r.rejected == 2 and cfg.traffic.respawnRange == 2.5 and cfg.traffic.respawnDelay == 45, "range: edited, above 3 and a too small unjam distance refused")
check(cfg.traffic.unjam.crashed == true and cfg.traffic.unjam.crashedSeconds == 60 and cfg.traffic.unjam.inViewSeconds == 120, "range: crashed rule defaults")
check(admin.snapshot().traffic.respawnRange == 2.5 and admin.snapshot().traffic.unjam.seconds == 120, "range: in the snapshot")
local pc = require("rlsmp.server.trafficPolice").payload()
check(pc.range.respawnRange == 2.5 and pc.range.respawnDelay == 45 and pc.range.unjam.enabled == true, "range: the payload follows the edit")
cfg.traffic.respawnRange, cfg.traffic.respawnDelay = 1.0, 0

-- respawnDistance: default 4000 m, 0 to 6000, sent with the range
check(cfg.traffic.respawnDistance == 4000, "range: default recycle distance 4000 m")
check(require("rlsmp.server.trafficPolice").payload().range.respawnDistance == 4000, "range: the distance is in the payload")
set(0, {{p = {"traffic", "respawnDistance"}, v = 2500}, {p = {"traffic", "respawnDistance"}, v = 7000}, {p = {"traffic", "respawnDistance"}, v = -1}})
r = lastResult()
check(r.applied == 1 and #r.rejected == 2 and cfg.traffic.respawnDistance == 2500, "range: distance edited, above 6000 and below 0 refused")
check(admin.snapshot().traffic.respawnDistance == 2500 and require("rlsmp.server.trafficPolice").payload().range.respawnDistance == 2500, "range: distance in snapshot and payload")
set(0, {{p = {"traffic", "respawnDistance"}, v = 0}})
check(cfg.traffic.respawnDistance == 0, "range: 0 = the game's own radius")
cfg.traffic.respawnDistance = 4000
check(type(cfg.trafficVariety.excludeWords) == "table" and cfg.trafficVariety.excludeWords[1] == "junk", "variety: default exclude words in the server config")
check(require("rlsmp.server.trafficVariety").payload().excludeWords[1] == "junk", "variety: exclude words sent to the clients")

print(string.format("traffic_admin_test: %d checks passed", passed))
