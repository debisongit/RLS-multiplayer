-- RLS-Career-MP server: shared dealership stock (off by default: config shop.shared).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS rolls dealership listings on each PC with math.random, so two players see different cars. With shop.shared on,
-- the server keeps ONE copy of the current map's listings in shop.json:
--   * The first player who uploads a usable career/vehicleShop.json becomes the "source". Their maps[<map>] entry
--     (vehiclesInShop, sellersInfos, dirtyDate) is the master. Later uploads from the same account refresh it.
--   * On every join, before the profile goes down, the joining player's maps[<map>] entry is replaced by the master.
--     Their watchlist, discovered dealers, pending purchases, reward grants and other maps are left alone.
--   * M.markSold(shopId) takes a listing out of the master and keeps it out of later refreshes.
-- Anything odd (missing file, broken JSON, other RLS shop version, a career that has not bought its starter car yet)
-- means: send the player's file as it is.
--
-- Not covered (needs a client wrap, see docs/PROTOCOL.md "Shared dealership stock"): RLS refills open dealer slots
-- on every PC the first time the shop opens, so new listings still differ between players, and a sale is only seen
-- by others after they rejoin.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local transfer = require("rlsmp.shared.transfer")
local sessions = require("rlsmp.server.sessions")

local M = {}

M.FILE = "career/vehicleShop.json"
M.GENERAL_FILE = "career/general.json"
-- RLS throws the whole shop file away when these differ, so the master only goes to saves with the same ones.
local VERSION_FIELDS = {"version", "valuationSchemaVersion", "limitedMileageDealerSchemaVersion"}

local cfg, path
local state  -- {sourceAccountId, map, versions = {}, entry = {vehiclesInShop, sellersInfos, dirtyDate}, sold = {[id] = time}}
local lastSourceSum

local function enabled() return cfg ~= nil and type(cfg.shop) == "table" and cfg.shop.shared == true end

-- The level id RLS saves listings under (getCurrentLevelIdentifier()).
function M.mapId()
  local map = RLSMP and RLSMP.serverMap
  if type(map) ~= "string" or map == "" then map = cfg and cfg.expectedMap end
  if type(map) ~= "string" or map == "" then return nil end
  return map
end

local function decode(text)
  if type(text) ~= "string" then return nil end
  local ok, data = pcall(util.jsonDecode, text)
  if ok and type(data) == "table" then return data end
  return nil
end

-- RLS keeps a new career on starter-only stock until its first car; such a save must neither feed nor get the master.
local function boughtStarter(files)
  local general = decode(files[M.GENERAL_FILE])
  return general ~= nil and general.boughtStarterVehicle == true
end

local function versionsOf(data)
  local v = {}
  for _, k in ipairs(VERSION_FIELDS) do v[k] = data[k] end
  return v
end

local function sameVersions(data)
  for _, k in ipairs(VERSION_FIELDS) do
    if tostring(data[k]) ~= tostring(state.versions and state.versions[k]) then return false end
  end
  return true
end

local function idOf(listing) return type(listing) == "table" and listing.shopId ~= nil and tostring(listing.shopId) or nil end

local function withoutSold(list)
  local out = {}
  for _, listing in ipairs(type(list) == "table" and list or {}) do
    local id = idOf(listing)
    if not (id and state.sold[id]) then out[#out + 1] = listing end
  end
  return out
end

local function save() return storage.writeJson(path, state, false) end

function M.state() return state end

-- Called after a player's upload was stored. Picks the source and refreshes the master from it.
function M.onSaved(pid, s, profile)
  if not enabled() or s.guest then return end
  local text = profile.save.files[M.FILE]
  if not text then return end
  if state.sourceAccountId and state.sourceAccountId ~= s.accountId then return end
  local sum = transfer.checksum(text)
  if state.sourceAccountId and sum == lastSourceSum then return end
  local map = M.mapId()
  local data = decode(text)
  if not map or not data or type(data.maps) ~= "table" or type(data.maps[map]) ~= "table" then return end
  local entry = data.maps[map]
  if type(entry.vehiclesInShop) ~= "table" or not boughtStarter(profile.save.files) then return end

  local first = state.sourceAccountId == nil
  -- A sold id stays blocked only while the source's own save still lists it (their PC does not know about the sale).
  local stillListed = {}
  for _, listing in ipairs(entry.vehiclesInShop) do
    local id = idOf(listing)
    if id then stillListed[id] = true end
  end
  for id in pairs(state.sold) do
    if not stillListed[id] then state.sold[id] = nil end
  end
  state.sourceAccountId = s.accountId
  state.map = map
  state.versions = versionsOf(data)
  state.entry = {
    vehiclesInShop = withoutSold(entry.vehiclesInShop),
    sellersInfos = type(entry.sellersInfos) == "table" and entry.sellersInfos or {},
    dirtyDate = entry.dirtyDate,
  }
  lastSourceSum = sum
  save()
  if first then
    util.info(string.format("[shop] %s's dealership stock is now the shared stock for %s (%d listings)",
      tostring(s.name), map, #state.entry.vehiclesInShop))
  end
end

-- Called right before a profile is sent to a joining player. Rewrites the stored file so client and server checksums agree.
function M.beforeDownload(pid, s, profile)
  if not enabled() or not state.entry then return end
  local map = M.mapId()
  if not map or map ~= state.map then return end
  local files = profile.save.files
  local data = decode(files[M.FILE])
  if not data or type(data.maps) ~= "table" or not sameVersions(data) or not boughtStarter(files) then return end
  data.maps[map] = {
    vehiclesInShop = withoutSold(state.entry.vehiclesInShop),
    sellersInfos = state.entry.sellersInfos,
    dirtyDate = state.entry.dirtyDate,
  }
  local ok, text = pcall(util.jsonEncode, data)
  if not ok or type(text) ~= "string" then return end
  files[M.FILE] = text
end

-- Take a listing out of the shared stock (call it when a player buys it). Returns true if the master had it.
function M.markSold(shopId)
  if shopId == nil or not enabled() then return false end
  local id = tostring(shopId)
  state.sold[id] = util.now()
  local had = false
  if state.entry then
    local before = #state.entry.vehiclesInShop
    state.entry.vehiclesInShop = withoutSold(state.entry.vehiclesInShop)
    had = #state.entry.vehiclesInShop < before
  end
  save()
  return had
end

function M.init(config, pluginRoot)
  cfg = config
  path = pluginRoot .. "shop.json"
  state = {sold = {}}
  lastSourceSum = nil
  if not enabled() then return end
  local saved = storage.readJson(path)
  if type(saved) == "table" then state = saved end
  if type(state.sold) ~= "table" then state.sold = {} end
  if type(state.entry) ~= "table" or type(state.entry.vehiclesInShop) ~= "table" then state.entry = nil end
  if state.map and state.map ~= M.mapId() then
    util.info("[shop] the server map changed, so the shared stock starts over")
    state = {sold = {}}
  end
  -- sessions runs these inside pcall, so a bug here never blocks a join or an upload.
  sessions.onSaved(M.onSaved)
  sessions.beforeDownload(M.beforeDownload)
end

return M
