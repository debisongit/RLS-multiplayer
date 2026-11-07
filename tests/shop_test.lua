-- Shared dealership stock: server (lua5.3) test. Run: lua5.3 tests/shop_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players = {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() return true end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
os.execute('mkdir -p "' .. tmp .. '/config"')
local f = io.open(tmp .. "/config/config.json", "w") f:write('{"shop":{"shared":true}}') f:close()
dofile("Resources/Server/RLS-Career-MP/main.lua")
require("rlsmp.server.util").setJsonCodec(json)
onInit()
local sessions = require("rlsmp.server.sessions")
local shop = require("rlsmp.server.shop")
local transfer = require("rlsmp.shared.transfer")
local cfg = RLSMP.config
local MAP = "rls_west_coast"

local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function fromClient(pid, ev, tbl) return fire(ev, pid, json.encode(tbl)) end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fromClient(pid, "rlsmpHello", {v = transfer.PROTOCOL, build = transfer.BUILD})
  sessions.get(pid).stage = "loaded"
end
local function leave(pid) fire("onPlayerDisconnect", pid) end
local uploadId = 0
local function upload(pid, files)
  local all = {}
  for rel, text in pairs(files) do all[rel] = transfer.checksum(text) end
  uploadId = uploadId + 1
  local header, chunks = transfer.describe(json.encode({all = all, files = files}), 4000)
  header.id = tostring(uploadId)
  fromClient(pid, "rlsmpUpBegin", header)
  for i, d in ipairs(chunks) do fromClient(pid, "rlsmpUpChunk", {id = header.id, i = i, d = d}) end
end
local function stored(pid) return sessions.get(pid).profile.save.files end
local function exists(p) local h = io.open(p, "r") if h then h:close() return true end return false end

local function shopFile(ids, extra)
  local list = {}
  for _, id in ipairs(ids) do list[#list + 1] = {shopId = id, Name = "car" .. id, sellerId = "dealerA"} end
  local data = {
    version = 69, valuationSchemaVersion = 12, limitedMileageDealerSchemaVersion = 2,
    maps = {[MAP] = {vehiclesInShop = list, sellersInfos = {dealerA = {lastGenerationTime = 5}}, dirtyDate = "d" .. ids[1]},
            other_map = {vehiclesInShop = {{shopId = 7, Name = "elsewhere"}}}},
    vehicleWatchlist = {["42"] = "unsold"},
    discoveredDealers = {[MAP] = {dealerA = true}},
    rtPendingFleetPurchases = {x = {{purchaseId = "p1"}}},
    rewardVehicleGrants = {{id = "g1"}},
  }
  for k, v in pairs(extra or {}) do data[k] = v end
  return json.encode(data)
end
local function save(shopText, starter)
  local files = {["info.json"] = '{"version":1}', ["career/general.json"] = json.encode({level = MAP, boughtStarterVehicle = starter ~= false})}
  if shopText then files["career/vehicleShop.json"] = shopText end
  return files
end
local function ids(text, map)
  local out = {}
  for _, v in ipairs(json.decode(text).maps[map or MAP].vehiclesInShop) do out[#out + 1] = v.shopId end
  return table.concat(out, ",")
end

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local shopJson = tmp .. "/shop.json"

-- Off: nothing is stored and nothing is changed.
cfg.shop.shared = false
join(1, "ann")
upload(1, save(shopFile({1, 2, 3})))
check(not exists(shopJson), "switch off: no shop.json")
check(shop.state().sourceAccountId == nil, "switch off: no source")
check(shop.markSold(1) == false and not exists(shopJson), "switch off: markSold does nothing")
cfg.shop.shared = true

-- A career that has not bought its starter car never becomes the source.
join(3, "cid")
upload(3, save(shopFile({90, 91}), false))
check(shop.state().sourceAccountId == nil, "pre-starter save is not a source")

-- First usable upload becomes the source.
upload(1, save(shopFile({1, 2, 3})))
check(shop.state().sourceAccountId == "1001", "ann is the source")
check(exists(shopJson), "master written to shop.json")
check(#shop.state().entry.vehiclesInShop == 3 and shop.state().entry.dirtyDate == "d1", "master holds ann's listings")

-- Another player's upload does not touch the master.
join(2, "bob")
upload(2, save(shopFile({50, 51})))
check(ids(stored(2)["career/vehicleShop.json"]) == "50,51", "bob's own upload is stored as is")
check(#shop.state().entry.vehiclesInShop == 3, "bob does not change the master")

-- Bob rejoins: his map entry becomes the master, the rest of his file stays his.
leave(2) join(2, "bob")
local bobShop = json.decode(stored(2)["career/vehicleShop.json"])
check(ids(stored(2)["career/vehicleShop.json"]) == "1,2,3", "bob gets the shared listings")
check(bobShop.maps[MAP].dirtyDate == "d1" and bobShop.maps[MAP].sellersInfos.dealerA.lastGenerationTime == 5, "sellers and dirty date shared")
check(bobShop.vehicleWatchlist["42"] == "unsold" and bobShop.discoveredDealers[MAP].dealerA == true, "watchlist and discovery kept")
check(bobShop.rtPendingFleetPurchases.x[1].purchaseId == "p1" and bobShop.rewardVehicleGrants[1].id == "g1", "pending purchases and grants kept")
check(bobShop.maps.other_map.vehiclesInShop[1].Name == "elsewhere", "other maps kept")

-- Sold listings leave the master and stay out while the source's save still lists them.
check(shop.markSold(2) == true, "markSold finds the listing")
check(json.decode(io.open(shopJson):read("*a")).sold["2"] ~= nil, "sold id saved")
upload(1, save(shopFile({1, 2, 3, 4})))
check(#shop.state().entry.vehiclesInShop == 3 and shop.state().entry.dirtyDate == "d1", "source refresh keeps the sold one out")
leave(2) join(2, "bob")
check(ids(stored(2)["career/vehicleShop.json"]) == "1,3,4", "bob does not see the sold car")
upload(1, save(shopFile({1, 3, 4})))
check(shop.state().sold["2"] == nil, "sold id forgotten once the source dropped it too")

-- Files that do not fit are sent as they are.
local function rejoinWith(files)
  leave(2)
  players[2] = {name = "bob", ids = {beammp = "1002"}}
  local p = require("rlsmp.server.profiles").loadOrCreate("1002", "bob")
  p.save.files = files
  join(2, "bob")
  return stored(2)["career/vehicleShop.json"]
end
check(rejoinWith(save(nil))  == nil, "missing file stays missing")
check(rejoinWith(save("{not json")) == "{not json", "broken file untouched")
local oldVersion = shopFile({60}, {version = 68})
check(rejoinWith(save(oldVersion)) == oldVersion, "other RLS shop version untouched")
local noMaps = json.encode({version = 69, valuationSchemaVersion = 12, limitedMileageDealerSchemaVersion = 2})
check(rejoinWith(save(noMaps)) == noMaps, "file without maps untouched")
local preStarter = shopFile({61})
check(rejoinWith(save(preStarter, false)) == preStarter, "pre-starter career keeps its starter stock")
check(ids(rejoinWith(save(shopFile({62})))) == "1,3,4", "matching file gets the master")

-- Restart: the master and source come back from shop.json.
shop.init(cfg, RLSMP_PLUGIN_ROOT)
local st = shop.state()
check(st.sourceAccountId == "1001" and st.map == MAP and st.versions.version == 69, "shop.json reloads source and versions")
check(#st.entry.vehiclesInShop == 3 and st.entry.vehiclesInShop[3].shopId == 4, "shop.json reloads the listings")
print("shop_test: " .. passed .. " checks passed")
