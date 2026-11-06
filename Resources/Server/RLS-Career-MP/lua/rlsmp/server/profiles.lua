-- RLS-Career-MP server: player profiles on disk.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- profiles/<beammpAccountId>.json looks like:
-- {
--   schema = 1, accountId = "123", lastName = "Bob",
--   createdAt = 1700000000, updatedAt = 1700000500,
--   ledger = { money = 12000, seeded = true, ... },      -- server-side wallet (see wallet.lua)
--   save   = { files = { ["info.json"] = "<file text>", ["career/playerAttributes.json"] = "..." } }
-- }
-- `save.files` is a full copy of one RLS save slot, file by file, as raw text.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local transfer = require("rlsmp.shared.transfer")
local wallet = require("rlsmp.server.wallet")

local M = {}

M.SCHEMA = 1
M.ATTRIBUTES_FILE = "career/playerAttributes.json"

local cfg, root
local cache = {}  -- accountId -> profile table (only while the player is online)

local function pathFor(accountId)
  return root .. "profiles/" .. accountId .. ".json"
end

local function newProfile(accountId, name)
  local now = util.now()
  return {
    schema = M.SCHEMA,
    accountId = accountId,
    lastName = name,
    createdAt = now,
    updatedAt = now,
    ledger = wallet.newLedger(),
    save = {files = {}},
  }
end

-- Returns profile, isNew
function M.loadOrCreate(accountId, name)
  if cache[accountId] then return cache[accountId], false end
  local profile = storage.readJson(pathFor(accountId))
  local isNew = false
  if type(profile) ~= "table" or type(profile.save) ~= "table" then
    if profile ~= nil then util.warn("Profile " .. accountId .. " is unreadable; starting fresh") end
    profile = newProfile(accountId, name)
    isNew = true
  end
  profile.lastName = name or profile.lastName
  profile.ledger = util.deepMerge(wallet.newLedger(), profile.ledger)
  if type(profile.save.files) ~= "table" then profile.save.files = {} end
  -- A profile with no files yet is still a fresh career from RLS's point of view.
  if next(profile.save.files) == nil then isNew = true end
  cache[accountId] = profile
  return profile, isNew
end

function M.get(accountId) return cache[accountId] end

function M.persist(profile)
  profile.updatedAt = util.now()
  return storage.writeJson(pathFor(profile.accountId), profile, false)
end

function M.unload(accountId)
  cache[accountId] = nil
end

-- What we send to the client on join.
function M.encodeForDownload(profile)
  return util.jsonEncode({files = profile.save.files})
end

local function readMoney(attributesText)
  local attrs = util.jsonDecode(attributesText)
  if type(attrs) ~= "table" or type(attrs.money) ~= "table" then return nil, attrs end
  return tonumber(attrs.money.value), attrs
end

-- Apply an uploaded save. `upload` = { all = {rel = checksum, ...}, files = {rel = text, ...} }
-- `all` lists every file in the client's slot; `files` only holds the ones that changed.
-- Returns result table or nil + reason. reason "resync" means: please send everything.
function M.applyUpload(profile, upload)
  if type(upload) ~= "table" or type(upload.all) ~= "table" then return nil, "bad_upload" end
  local changed = type(upload.files) == "table" and upload.files or {}
  local old = profile.save.files
  local nextFiles, total = {}, 0

  for rel, sum in pairs(upload.all) do
    if not transfer.safeRelativePath(rel) then return nil, "bad_path" end
    local text = changed[rel]
    if text == nil then text = old[rel] end
    if type(text) ~= "string" or transfer.checksum(text) ~= sum then
      return nil, "resync"
    end
    total = total + #text
    nextFiles[rel] = text
  end
  if total > cfg.transfer.maxSaveBytes then return nil, "too_big" end
  if nextFiles["info.json"] == nil then return nil, "missing_info" end

  -- Money check against the server wallet.
  local result = {corrected = false}
  local attrsText = nextFiles[M.ATTRIBUTES_FILE]
  if attrsText then
    local clientMoney, attrs = readMoney(attrsText)
    local target, needsFix = wallet.reconcile(profile.ledger, clientMoney)
    result.money = target
    if needsFix and type(attrs) == "table" then
      attrs.money = type(attrs.money) == "table" and attrs.money or {}
      attrs.money.value = target
      nextFiles[M.ATTRIBUTES_FILE] = util.jsonEncode(attrs)
      result.corrected = true
      util.warn(string.format("Corrected money for %s: client had %s, server says %s",
        tostring(profile.lastName), tostring(clientMoney), tostring(target)))
    end
  end

  profile.save.files = nextFiles
  -- Tell the client the checksum of any file we changed, so its next delta is right.
  result.sums = {}
  if result.corrected then
    result.sums[M.ATTRIBUTES_FILE] = transfer.checksum(nextFiles[M.ATTRIBUTES_FILE])
  end
  return result
end

-- Current checksum of every stored file (the client uses this to send only changes).
function M.checksums(profile)
  local sums = {}
  for rel, text in pairs(profile.save.files) do sums[rel] = transfer.checksum(text) end
  return sums
end

function M.init(config, pluginRoot)
  cfg = config
  root = pluginRoot
  storage.ensureDir(root .. "profiles")
end

return M
