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
join(1, "SUCUK21")          -- name in capitals
join(2, "someoneelse")
join(3, "Polakpls", {guest = true})   -- a guest using an admin name
join(4, "guest4321")

-- who ------------------------------------------------------------------------------------------------------------------------------------
check(admin.isAdmin(0) == true, "polakpls is an admin")
check(admin.isAdmin(1) == true, "sucuk21 is an admin, whatever the capitals")
check(admin.isAdmin(2) == false, "anybody else is not")
check(admin.isAdmin(3) == false, "a guest with an admin's name is never an admin")
check(admin.isAdmin(99) == false, "a player that has no session is not")
cfg.trafficAdmin.accountIds = {"acc2"}
check(admin.isAdmin(2) == true, "an account id on the list works too")
cfg.trafficAdmin.accountIds = {}
check(admin.isAdmin(2) == false, "...and stops when it is taken off")
players[0] = "PoLaKpLs"
check(admin.isAdmin(0) == true, "the name is read from BeamMP, not case sensitive")
players[0] = "polakpls"

-- the menu opens only for admins ---------------------------------------------------------------------------------------------------------
nextSecond()
fromClient(2, "rlsmpTrafficAdminGet", {})
local m = take()
check(#m == 1 and m[1].data.ok == false and m[1].data.cfg == nil, "a non-admin gets no settings")
check(#chat > 0 and chat[#chat].pid == 2 and chat[#chat].text:find("not allowed"), "...and is told so in chat")
check(#warned > 0 and warned[#warned]:find("RLSMP-ADMIN refused the traffic menu", 1, true), "the refusal is logged")
nextSecond()
fromClient(0, "rlsmpTrafficAdminGet", {})
m = take()
check(#m == 1 and m[1].data.ok == true and type(m[1].data.cfg) == "table", "an admin gets the settings")
local snap = m[1].data.cfg
check(snap.smartTraffic.mix.normal == 80 and snap.traffic.maxPerPlayer == 18 and snap.weather.mix.clear == 35 and snap.police.antiTeleport == true, "...the current values")
check(snap.trafficAdmin == nil and snap.serverTag == nil and snap.identity == nil, "...and only the editable parts, never the admin list or the server tag")
chat = {}
say(2, "/trafficmenu")
check(#take() == 0 and chat[1].text:find("not allowed"), "/trafficmenu: a non-admin only gets a message")
say(0, "/trafficmenu")
check(find(take(), "rlsmpTrafficAdminOpen", 0) ~= nil, "/trafficmenu: an admin gets the menu opened")

-- changes by a non-admin do nothing ----------------------------------------------------------------------------------------------------------
local before = json.encode(cfg)
set(2, {{p = {"smartTraffic", "mix", "drunk"}, v = 50}})
check(json.encode(cfg) == before, "a non-admin cannot change anything")
check(not find(take(), "rlsmpTrafficAdminResult"), "...and gets no result, only a refusal")
set(3, {{p = {"smartTraffic", "mix", "drunk"}, v = 50}})
check(json.encode(cfg) == before, "a guest with an admin's name cannot either")

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
  {p = {"weather", "force"}, v = "rain"},
  {p = {"weather", "mix", "storm"}, v = 10},
  {p = {"police", "antiTeleport"}, v = false},
})
local r = lastResult()
check(r and r.applied == 11 and #r.rejected == 0 and r.saved == true, "eleven valid changes applied and saved")
check(cfg.smartTraffic.mix.drunk == 5 and cfg.smartTraffic.policeReact == false, "personality percentage and police reaction changed")
check(cfg.traffic.totalBudget == 60, "a whole-number setting is rounded")
check(cfg.trafficVariety.typeWeights.Truck == 0.5 and cfg.trafficVariety.models.pickup == 3, "Type and model weights set")
check(cfg.trafficVariety.zones.highway.Truck == 2 and cfg.trafficVariety.night.pickup == 0, "where (road class) and when (night) set, a new zone map was created")
check(cfg.trafficVariety.swap.enabled == true and cfg.weather.force == "rain" and cfg.weather.mix.storm == 10 and cfg.police.antiTeleport == false, "swap, weather and police settings set")
for name, tbl in pairs(sections) do check(cfg[name] == tbl, "section " .. name .. " is still the same table (the modules keep references to it)") end
local f = assert(io.open(tmp .. "/config/config.json", "r"))
local onDisk = json.decode(f:read("*a"))
f:close()
check(onDisk.smartTraffic.mix.drunk == 5 and onDisk.trafficVariety.models.pickup == 3 and onDisk.weather.force == "rain", "saved to config.json")
check(onDisk.trafficAdmin.names[1] == "polakpls", "(the file is the whole config)")

-- modules resend to everybody, admins get the fresh state ------------------------------------------------------------------------------------------
sent = {}
_G[handlers["rlsmpSmartTrafficTick"]]()
local st = find(sent, "rlsmpSmartTraffic", 0)
check(st ~= nil and st.data.mix.drunk == 5 and st.data.policeReact == false, "smart traffic sends the new percentages to everybody again")
sent = {}
_G[handlers["rlsmpTrafficVarietyTick"]]()
local tv = find(sent, "rlsmpTrafficVariety", 2)
check(tv ~= nil and tv.data.models.pickup == 3 and tv.data.zones.highway.Truck == 2 and tv.data.swap.enabled == true, "traffic variety resends too, to a player who is not an admin")
sent = {}
_G[handlers["rlsmpWeatherTick"]]()
check(find(sent, "rlsmpWeather", 2).data.c == "rain", "the weather module reads the new forced condition")
set(1, {{p = {"traffic", "maxPerPlayer"}, v = 20}})
m = take()
check(find(m, "rlsmpTrafficAdminState", 0) ~= nil and find(m, "rlsmpTrafficAdminState", 1) ~= nil and find(m, "rlsmpTrafficAdminState", 2) == nil, "after a change both admins get the fresh state, a non-admin does not")
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
check(cfg.trafficAdmin.names[1] == "polakpls" and cfg.trafficAdmin.names[2] == "sucuk21", "after all that the admin list is unchanged")
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

print(string.format("traffic_admin_test: %d checks passed", passed))
