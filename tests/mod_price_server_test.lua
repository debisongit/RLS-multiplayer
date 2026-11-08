-- Server mod price settings test (lua5.3). Run: lua5.3 tests/mod_price_server_test.lua <tmpdir>
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")
local tmp = arg[1] or "/tmp"

local sent, handlers = {}, {}
MP = {
  RegisterEvent = function(ev, fname) handlers[ev] = fname end,
  CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) table.insert(sent, {pid = pid, name = name, data = json.decode(data)}) end,
  GetPlayerName = function() return "p" end,
}
Util = {}
require("rlsmp.server.util").setJsonCodec(json)
local stages = {}
package.loaded["rlsmp.server.sessions"] = {
  all = function() return stages end,
  get = function(pid) return stages[pid] and {pid = pid} or nil end,
  isLoaded = function(pid) return stages[pid] == "loaded" end,
}
local cfg = require("rlsmp.server.config").defaults
require("rlsmp.server.net").init(cfg)
local mp = require("rlsmp.server.modPrice")
mp.init(cfg, "")

local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local function tick() _G[handlers["rlsmpModPriceTick"]]() end
local function take() local t = sent sent = {} return t end

-- defaults
local d = cfg.modPrice
check(d.sell == true and d.enabled == true and d.max == 2000000 and d.min == 800 and d.tolerance == 0.35 and next(d.overrides) == nil, "defaults")

-- sent once, after load, with the mod model list
stages[0] = "await_hello"
tick()
check(#take() == 0, "not loaded: nothing")
cfg.trafficVariety.mods = {zcar = 2, acar = 1, [""] = 1}
stages[0] = "loaded"
tick()
local m = take()
check(#m == 1 and m[1].name == "rlsmpModPrice" and m[1].data.enabled == true and m[1].data.max == 2000000, "settings sent on load")
check(#m[1].data.models == 2 and m[1].data.models[1] == "acar" and m[1].data.models[2] == "zcar", "mod models listed, sorted, empty name dropped")
tick()
check(#take() == 0, "sent once")
mp.resend()
tick()
check(#take() == 1, "resend after a change")
stages[0] = nil
tick()
stages[0] = "loaded"
tick()
check(#take() == 1, "again after a rejoin")

-- overrides: only numbers
cfg.modPrice.overrides = {acar = 5000, ["acar/x"] = 9000, bad = "no", [""] = 5}
mp.resend()
tick()
m = take()
check(m[1].data.overrides.acar == 5000 and m[1].data.overrides["acar/x"] == 9000 and m[1].data.overrides.bad == nil, "overrides sanitized")

-- the menu: allowed settings and ranges, snapshot shows them
local admin = require("rlsmp.server.trafficAdmin")
admin.init(cfg, tmp .. "/")
local applied, rejected = admin.applyPatch({set = {
  {p = {"modPrice", "enabled"}, v = false},
  {p = {"modPrice", "max"}, v = 500000},
  {p = {"modPrice", "tolerance"}, v = 0.5},
  {p = {"modPrice", "min"}, v = 50},
  {p = {"modPrice", "sell"}, v = false},
  {p = {"modPrice", "overrides", "acar"}, v = 1},
  {p = {"modPrice", "max"}, v = "lots"},
}})
check(applied == 4 and #rejected == 3, "three valid, three rejected")
check(cfg.modPrice.enabled == false and cfg.modPrice.max == 500000 and cfg.modPrice.tolerance == 0.5 and cfg.modPrice.min == 800, "values set, bad ones not")
check(cfg.modPrice.overrides.acar == 5000, "overrides cannot be edited from the menu")
local snap = admin.snapshot()
check(snap.modPrice.enabled == false and snap.modPrice.max == 500000, "the menu snapshot shows modPrice, also when off")

print("mod_price_server_test: " .. passed .. " checks passed")
