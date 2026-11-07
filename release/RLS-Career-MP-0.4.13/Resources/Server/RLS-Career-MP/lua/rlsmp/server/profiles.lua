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
M.CHEATS_FILE = "career/rls_career/cheats.json"
-- Chosen when the career is created; after the server has stored them, a client's later edits are ignored.
M.LOCKED_FILES = {
  "career/rls_career/careerStartMode.json",
  "career/rls_career/difficultyMode.json",
  "career/rls_career/hardcore.json",
  "career/rls_career/sandboxEconomyProfile.json",
  "career/rls_career/sandboxXpProfile.json",
}

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

-- The map (level id) this career was last saved on, read from the stored RLS save.
function M.mapOf(profile)
  local text = profile and profile.save and profile.save.files and profile.save.files["career/general.json"]
  local general = text and util.jsonDecode(text)
  return type(general) == "table" and type(general.level) == "string" and general.level or nil
end

-- Start over: the old profile is archived (never deleted), the next join creates a brand-new career.
function M.reset(accountId)
  local profile = cache[accountId] or storage.readJson(pathFor(accountId))
  if not profile then return false, "no profile for " .. tostring(accountId) end
  local archive = string.format("%sprofiles/archive/%s-%d.json", root, accountId, util.now())
  if not storage.writeJson(archive, profile) then return false, "could not archive the old profile, nothing was deleted" end
  os.remove(pathFor(accountId))
  os.remove(pathFor(accountId) .. ".bak")
  cache[accountId] = nil
  return true, archive
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

local function vehicleFile(inv) return "career/vehicles/" .. tostring(inv) .. ".json" end

-- Remember that the car in inventory slot `inv` was handed over (fleet, later pink slips) under `ref`.
-- Its file text is fingerprinted, so a different car that later takes the same slot is never mistaken for it.
function M.markOut(profile, inv, ref)
  local text = profile.save.files[vehicleFile(inv)]
  if not text then return false end
  profile.fleetOut = profile.fleetOut or {}
  profile.fleetOut[tostring(inv)] = {ref = ref, sum = transfer.checksum(text)}
  return true
end

function M.isOut(profile, inv)
  return profile.fleetOut ~= nil and profile.fleetOut[tostring(inv)] ~= nil
end

-- Slots the client must clear on join (a crash left the handed-over car in the save).
function M.staleCars(profile)
  local list = {}
  for inv in pairs(profile.fleetOut or {}) do list[#list + 1] = tonumber(inv) end
  table.sort(list)
  return list
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

  -- Start settings are fixed once stored, and cheats mode is never accepted (unless the owner allows it).
  local result = {corrected = false, sums = {}}
  for _, rel in ipairs(M.LOCKED_FILES) do
    local kept = old[rel]
    if kept and nextFiles[rel] ~= nil and nextFiles[rel] ~= kept then
      nextFiles[rel] = kept
      result.sums[rel] = transfer.checksum(kept)
      util.warn(string.format("Ignored a change to %s from %s", rel, tostring(profile.lastName)))
    end
  end
  local cheatsText = nextFiles[M.CHEATS_FILE]
  if cheatsText and not cfg.security.allowCheats then
    local cheats = util.jsonDecode(cheatsText)
    if type(cheats) == "table" and cheats.cheatsMode == true then
      nextFiles[M.CHEATS_FILE] = util.jsonEncode({cheatsMode = false})
      result.sums[M.CHEATS_FILE] = transfer.checksum(nextFiles[M.CHEATS_FILE])
      util.warn(tostring(profile.lastName) .. "'s save had cheats mode on; turned off")
    end
  end

  -- Money check against the server wallet.
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

  -- A car that left for a fleet is forgotten once the client's save no longer has that car in that slot.
  if profile.fleetOut then
    for inv, mark in pairs(profile.fleetOut) do
      local text = nextFiles[vehicleFile(inv)]
      if text == nil or transfer.checksum(text) ~= mark.sum then profile.fleetOut[inv] = nil end
    end
  end

  profile.save.files = nextFiles
  -- Tell the client the checksum of any file we changed, so its next delta is right.
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
