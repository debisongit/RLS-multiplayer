-- RLS-Career-MP client extension "rlsmp_saveBridge".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Moves RLS saves between the server and this PC.
--   writeProfile(): server copy -> settings/cloud/overhaul/saves/<profile>/autosave1/...
--   after every RLS save (hook onOverhaulSaveFinished): read the slot RLS just wrote,
--   upload only files that changed since the server last saw them.
-- The server is the boss: whatever was on disk for this profile is wiped before writing.

local M = {}

local transfer = require("rlsmp/lib/transfer")
local net = require("rlsmp/lib/net")

local SAVE_ROOT = "settings/cloud/overhaul/saves/"
local SLOT = "autosave1"
local FILES_PER_FRAME = 12

-- File system access, swappable for tests.
local fs = {
  exists = function(p) return FS:directoryExists(p) end,
  removeDir = function(p) return FS:directoryRemove(p) end,
  mkdir = function(p) return FS:directoryCreate(p, true) end,
  write = function(p, text) return writeFile(p, text) end,
  read = function(p) return readFile(p) end,
  findJson = function(dir) return FS:findFiles(dir, "*.json", -1, true, false) end,
}
function M.setFs(overrides) for k, v in pairs(overrides) do fs[k] = v end end

local enabled = false       -- true only while playing an MP career
local profileName
local chunkSize = 16000
local serverSums = {}       -- rel path -> checksum the server currently has
local uploadSeq = 0
local inFlight              -- {id, sums}
local pendingUpload = false -- another save finished while we were uploading
local collect               -- current file-reading job, spread over frames

local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("^/+", "")) end

function M.getSaveRoot() return SAVE_ROOT end
function M.getProfileName() return profileName end
function M.isEnabled() return enabled end

-- RLS remembers the level a career was on; on BeamMP the server picks the map,
-- so point the save at the level we are actually on to stop RLS from switching maps.
local function patchLevel(text, level)
  if not level or type(text) ~= "string" then return text end
  local ok, data = pcall(jsonDecode, text)
  if not ok or type(data) ~= "table" then return text end
  if data.level == level then return text end
  data.level = level
  return jsonEncode(data)
end

-- Write the server's copy of the save. Returns the slot folder to load, or nil for a new career.
function M.writeProfile(name, files, currentLevel)
  profileName = name
  local profileDir = SAVE_ROOT .. name
  if fs.exists(profileDir) then fs.removeDir(profileDir) end
  serverSums = {}
  inFlight, pendingUpload, collect = nil, false, nil

  local count = 0
  for rel, text in pairs(files or {}) do
    if transfer.safeRelativePath(rel) and type(text) == "string" then
      serverSums[rel] = transfer.checksum(text)
      if rel == "career/general.json" then text = patchLevel(text, currentLevel) end
      local full = profileDir .. "/" .. SLOT .. "/" .. rel
      local dir = full:match("^(.*)/[^/]+$")
      if dir then fs.mkdir(dir) end
      fs.write(full, text)
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return SLOT
end

function M.enable(on, opts)
  enabled = on == true
  if opts and opts.chunkSize then chunkSize = opts.chunkSize end
  if not enabled then inFlight, pendingUpload, collect = nil, false, nil end
end

-- Ask RLS to save now (the upload follows automatically when the save finishes).
function M.requestSave(reason)
  if not enabled then return false end
  local ss = overhaul_career_saveSystem
  if not ss then return false end
  if ss.requestSave then return ss.requestSave(reason or "rlsmp") end
  return ss.saveCurrent()
end

-- Upload ---------------------------------------------------------------------------------------------

local function startCollect(slotPath)
  local base = norm(slotPath)
  local list = {}
  for _, full in ipairs(fs.findJson("/" .. base) or {}) do
    local p = norm(full)
    if p:sub(1, #base + 1) == base .. "/" then
      local rel = p:sub(#base + 2)
      if transfer.safeRelativePath(rel) then list[#list + 1] = {rel = rel, full = "/" .. p} end
    end
  end
  collect = {list = list, index = 1, all = {}, changed = {}, changedCount = 0}
end

local function finishCollect()
  local job = collect
  collect = nil
  if next(job.all) == nil then return end
  if job.changedCount == 0 then
    -- Still tell the server about deletions, but only if something actually disappeared.
    local gone = false
    for rel in pairs(serverSums) do if not job.all[rel] then gone = true break end end
    if not gone then return end
  end
  uploadSeq = uploadSeq + 1
  local id = tostring(uploadSeq)
  inFlight = {id = id, sums = job.all}
  net.sendBig("rlsmpUpBegin", "rlsmpUpChunk", id, jsonEncode({all = job.all, files = job.changed}), chunkSize)
end

-- Called from onUpdate: read a few files per frame so big garages don't freeze the game.
local function stepCollect()
  local job = collect
  local last = math.min(job.index + FILES_PER_FRAME - 1, #job.list)
  for i = job.index, last do
    local entry = job.list[i]
    local text = fs.read(entry.full)
    if type(text) == "string" then
      local sum = transfer.checksum(text)
      job.all[entry.rel] = sum
      if serverSums[entry.rel] ~= sum then
        job.changed[entry.rel] = text
        job.changedCount = job.changedCount + 1
      end
    end
  end
  job.index = last + 1
  if job.index > #job.list then finishCollect() end
end

function M.uploadSlot(slotPath)
  if not enabled or not slotPath then return end
  if inFlight or collect then
    pendingUpload = slotPath
    return
  end
  startCollect(slotPath)
end

local function lastSavedSlot()
  local ss = overhaul_career_saveSystem
  local stats = ss and ss.getLastSaveStats and ss.getLastSaveStats()
  return stats and stats.path
end

local function onUpAck(ack)
  if not inFlight or tostring(ack.id) ~= inFlight.id then return end
  local sent = inFlight
  inFlight = nil
  if ack.ok then
    serverSums = sent.sums
    for rel, sum in pairs(ack.sums or {}) do serverSums[rel] = sum end
  elseif ack.resync then
    -- Server lost track; forget what it has so the next upload sends everything.
    serverSums = {}
    pendingUpload = pendingUpload or lastSavedSlot()
  else
    log("E", "RLS-Career-MP", "Server refused save upload: " .. tostring(ack.err))
  end
  if pendingUpload then
    local slot = pendingUpload
    pendingUpload = false
    M.uploadSlot(slot)
  end
end

-- Hooks ------------------------------------------------------------------------------------------------

function M.onOverhaulSaveFinished()
  if not enabled then return end
  M.uploadSlot(lastSavedSlot())
end

function M.onUpdate()
  if collect then stepCollect() end
  net.pump(4)
end

function M.onExtensionLoaded()
  net.on("rlsmpUpAck", onUpAck)
  net.on("rlsmpSaveNow", function() M.requestSave("rlsmp_server") end)
end

-- test hooks
M._serverSums = function() return serverSums end
M._inFlight = function() return inFlight end
M._onUpAck = onUpAck

M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("saveBridge", M)
return M
