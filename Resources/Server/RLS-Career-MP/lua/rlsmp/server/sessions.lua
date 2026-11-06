-- RLS-Career-MP server: the join handshake, save uploads and wallet messages.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Flow (see docs/PROTOCOL.md for every message):
--   1. player joins                 -> session created, waiting for "hello"
--   2. client  -> rlsmpHello         -> we load their profile and stream it down in chunks
--   3. client writes the save, starts RLS career -> rlsmpLoaded
--   4. every RLS save               -> client uploads changed files (rlsmpUpBegin + rlsmpUpChunk)
--   5. money changes                -> rlsmpWalletDelta, checked by wallet.lua

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local transfer = require("rlsmp.shared.transfer")
local identity = require("rlsmp.server.identity")
local profiles = require("rlsmp.server.profiles")
local wallet = require("rlsmp.server.wallet")

local M = {}

local cfg
local sessions = {}   -- pid -> session

-- Public: other modules (business, traffic) can look up who is online and in which stage.
function M.get(pid) return sessions[pid] end
function M.all() return sessions end
function M.isLoaded(pid) return sessions[pid] ~= nil and sessions[pid].stage == "loaded" end

local function startingOptions()
  local opts = {}
  for k, v in pairs(cfg.newCareer) do
    if v ~= "" and v ~= 0 then opts[k] = v end
  end
  return opts
end

local function fail(pid, code, msg)
  net.send(pid, "rlsmpError", {code = code, msg = msg})
end

local function onPlayerJoin(pid)
  sessions[pid] = {
    pid = pid,
    name = MP.GetPlayerName(pid),
    accountId = identity.accountId(pid),
    stage = "await_hello",
    joinedAt = util.now(),
    lastForceSave = util.now(),
    uploads = {},
    ledgerDirty = false,
  }
end

local function onPlayerDisconnect(pid)
  local s = sessions[pid]
  sessions[pid] = nil
  net.dropPlayer(pid)
  if s and s.profile then
    if not s.guest then profiles.persist(s.profile) end
    profiles.unload(s.accountId)
  end
end

local function onHello(pid, data)
  local s = sessions[pid]
  if not s then onPlayerJoin(pid) s = sessions[pid] end
  if s.stage ~= "await_hello" then return end

  if tonumber(data.v) ~= transfer.PROTOCOL then
    MP.DropPlayer(pid, "RLS-Career-MP version mismatch. Restart BeamMP so it downloads the server's mod again.")
    return
  end

  local accountId = s.accountId
  if not accountId then
    if not cfg.identity.allowGuests then
      MP.DropPlayer(pid, "Please log in to BeamMP to play here (guests can't save).")
      return
    end
    -- Guest mode: an in-memory profile keyed by name that is never written to disk.
    accountId = "guest_" .. (tostring(s.name):gsub("[^%w]", "")) .. "_" .. tostring(pid)
    s.guest = true
  end

  -- One account, one session. Prevents two PCs fighting over one save.
  for otherPid, other in pairs(sessions) do
    if otherPid ~= pid and other.accountId == accountId and other.profile then
      MP.DropPlayer(pid, "Your account is already playing on this server.")
      return
    end
  end

  local profile, isNew = profiles.loadOrCreate(accountId, s.name)
  s.accountId = accountId
  s.profile = profile
  s.stage = "downloading"

  local payload = profiles.encodeForDownload(profile)
  net.sendBig(pid, "profile", payload, {
    profile = identity.localProfileName(accountId),
    isNew = isNew,
    startingOptions = startingOptions(),
    money = profile.ledger.seeded and profile.ledger.money or nil,
  })
  util.info(string.format("Sending %s profile to %s (%d bytes)", isNew and "NEW" or "saved", s.name, #payload))
end

local function onLoaded(pid, data)
  local s = sessions[pid]
  if not s or s.stage ~= "downloading" then return end
  if data.ok then
    s.stage = "loaded"
    util.info(s.name .. " is in their RLS career")
  else
    s.stage = "failed"
    util.err(s.name .. " could not start career: " .. tostring(data.err))
  end
end

-- Uploads -------------------------------------------------------------------------------------------

local function finishUpload(pid, s, id, up)
  s.uploads[id] = nil
  local text, problem = up.assembler:finish()
  if not text then
    net.send(pid, "rlsmpUpAck", {id = id, ok = false, err = problem, resync = true})
    return
  end
  local upload = util.jsonDecode(text)
  local result, reason = profiles.applyUpload(s.profile, upload)
  if not result then
    net.send(pid, "rlsmpUpAck", {id = id, ok = false, err = reason, resync = (reason == "resync")})
    return
  end
  if not s.guest then profiles.persist(s.profile) end
  s.ledgerDirty = false
  net.send(pid, "rlsmpUpAck", {id = id, ok = true, money = result.money, corrected = result.corrected, sums = result.sums})
  if result.corrected then
    net.send(pid, "rlsmpWalletSet", {money = result.money, why = "save_check"})
  end
end

local function onUpBegin(pid, data)
  local s = sessions[pid]
  if not s or not s.profile then return end
  local len = tonumber(data.len) or -1
  local n = tonumber(data.n) or 0
  if len < 0 or len > cfg.transfer.maxSaveBytes or n < 1 or n > (cfg.transfer.maxSaveBytes / 100) then
    net.send(pid, "rlsmpUpAck", {id = data.id, ok = false, err = "too_big"})
    return
  end
  local id = tostring(data.id)
  s.uploads[id] = {assembler = transfer.newAssembler(data), startedAt = util.now()}
end

local function onUpChunk(pid, data)
  local s = sessions[pid]
  if not s then return end
  local id = tostring(data.id)
  local up = s.uploads[id]
  if not up then return end
  up.assembler:add(data.i, data.d)
  if up.assembler:isComplete() then finishUpload(pid, s, id, up) end
end

-- Wallet ---------------------------------------------------------------------------------------------

local function onWalletDelta(pid, data)
  local s = sessions[pid]
  if not s or not s.profile then return end
  local ok, why = wallet.applyDelta(s.profile.ledger, data.d, data.r)
  s.ledgerDirty = true
  if not ok then
    util.warn(string.format("Refused money change %s for %s (%s, reason: %s)",
      tostring(data.d), s.name, why, tostring(data.r)))
    net.send(pid, "rlsmpWalletSet", {money = s.profile.ledger.money, why = why})
  end
end

-- Timers -----------------------------------------------------------------------------------------------

local lastLedgerFlush = 0

local function tick()
  local now = util.now()
  for pid, s in pairs(sessions) do
    if s.stage == "await_hello" and cfg.handshake.helloTimeoutSeconds > 0
        and now - s.joinedAt > cfg.handshake.helloTimeoutSeconds then
      MP.DropPlayer(pid, "RLS-Career-MP did not load. Make sure RLS Career Overhaul is installed.")
    end
    for id, up in pairs(s.uploads) do
      if now - up.startedAt > cfg.transfer.uploadTimeoutSeconds then s.uploads[id] = nil end
    end
    if s.stage == "loaded" and cfg.forceSaveMinutes > 0 and now - s.lastForceSave >= cfg.forceSaveMinutes * 60 then
      s.lastForceSave = now
      net.send(pid, "rlsmpSaveNow", {})
    end
  end
  -- Keep wallets safe even if the server crashes between saves.
  if now - lastLedgerFlush >= 60 then
    lastLedgerFlush = now
    for _, s in pairs(sessions) do
      if s.ledgerDirty and s.profile and not s.guest then
        profiles.persist(s.profile)
        s.ledgerDirty = false
      end
    end
  end
end
M.tick = tick

-- Save everyone (used by the console command and on shutdown).
function M.saveAll()
  for _, s in pairs(sessions) do
    if s.profile and not s.guest then profiles.persist(s.profile) end
  end
end

function M.init(config)
  cfg = config
  net.on("onPlayerAuth", identity.onPlayerAuth)
  net.on("onPlayerJoin", onPlayerJoin)
  net.on("onPlayerDisconnect", onPlayerDisconnect)
  net.on("onShutdown", M.saveAll)
  net.onClient("rlsmpHello", onHello)
  net.onClient("rlsmpLoaded", onLoaded)
  net.onClient("rlsmpUpBegin", onUpBegin)
  net.onClient("rlsmpUpChunk", onUpChunk)
  net.onClient("rlsmpWalletDelta", onWalletDelta)
  net.on("rlsmpTick", tick)
  MP.CreateEventTimer("rlsmpTick", 1000)
end

return M
