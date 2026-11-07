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
local earnedHooks = {}  -- fn(pid, session, amount, category), called after the server accepted earned money
local bigHandlers = {}  -- kind -> fn(pid, session, data); lets other modules receive big client uploads
local savedHooks = {}     -- fn(pid, session, profile), after a save upload was stored
local downloadHooks = {}  -- fn(pid, session, profile), right before the profile is encoded for a joining player

local function runHooks(list, ...)
  for _, fn in ipairs(list) do
    local ok, problem = pcall(fn, ...)
    if not ok then util.err("hook failed: " .. tostring(problem)) end
  end
end

-- Console: archive and clear one career (by online player name or BeamMP account id). Online players are dropped.
function M.resetCareer(who)
  who = tostring(who or "")
  local accountId, pid
  for p, s in pairs(sessions) do
    if s.accountId == who or tostring(s.name):lower() == who:lower() then pid, accountId = p, s.accountId end
  end
  accountId = accountId or identity.cleanId(who)
  if not accountId then return false, "tell me a player name (online) or a BeamMP account id" end
  if pid then sessions[pid].profile = nil end   -- so leaving does not write it back
  local ok, result = profiles.reset(accountId)
  if ok and pid then MP.DropPlayer(pid, "Your career was reset by the server owner. Rejoin to start a new one.") end
  return ok, result
end

function M.onEarned(fn) earnedHooks[#earnedHooks + 1] = fn end

-- Public: other modules (business, traffic) can look up who is online and in which stage.
function M.get(pid) return sessions[pid] end
function M.all() return sessions end
-- Other modules: receive a big upload that the client labelled with `kind` (see client fleet.lua).
function M.onBig(kind, fn) bigHandlers[kind] = fn end
-- Other modules (shop): look at a save after it was stored, or change it before it goes down on join.
function M.onSaved(fn) savedHooks[#savedHooks + 1] = fn end
function M.beforeDownload(fn) downloadHooks[#downloadHooks + 1] = fn end
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

  util.info(string.format("%s joined with client build %s (server build %s)", tostring(s.name), tostring(data.build), transfer.BUILD))
  if data.build ~= transfer.BUILD then
    MP.SendChatMessage(pid, "[RLS] Your RLS-Career-MP version differs from the server's. Restart BeamMP so it downloads the server's mod again.")
  end
  if RLSMP and RLSMP.mapWarning then MP.SendChatMessage(pid, "[RLS] " .. RLSMP.mapWarning) end

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

  local t0 = os.clock()
  local profile, isNew = profiles.loadOrCreate(accountId, s.name)
  -- A career made on another map has no starter garage here (RLS only grants one to brand-new careers).
  local careerMap = profiles.mapOf(profile)
  if RLSMP and RLSMP.serverMap and careerMap and careerMap ~= RLSMP.serverMap then
    util.warn(string.format("%s's career was made on map '%s' but the server runs '%s'. Run: rlsmp reset %s",
      tostring(s.name), careerMap, RLSMP.serverMap, tostring(s.name)))
    MP.SendChatMessage(pid, "[RLS] Your career was created on another map (" .. careerMap .. "), so you may have no garage. Ask the server owner to run: rlsmp reset " .. tostring(s.name))
  end
  s.accountId = accountId
  s.profile = profile
  s.stage = "downloading"

  runHooks(downloadHooks, pid, s, profile)
  local payload = profiles.encodeForDownload(profile)
  util.info(string.format("[rlsmp-timing] loaded and encoded %s's profile: %d bytes, %.2fs", tostring(s.name), #payload, os.clock() - t0))
  net.sendBig(pid, "profile", payload, {
    profile = identity.localProfileName(accountId),
    isNew = isNew,
    startingOptions = startingOptions(),
    drop = profiles.staleCars(profile),
    money = profile.ledger.seeded and profile.ledger.money or nil,
  })
  util.info(string.format("Sending %s profile to %s (%d bytes)", isNew and "NEW" or "saved", s.name, #payload))
end

local function onLoaded(pid, data)
  local s = sessions[pid]
  if not s then return end
  -- A client that gave up waiting for RLS (start timeout) may still see the career start later: let it recover.
  local late = s.stage == "failed" and data.ok and s.profile ~= nil
  if s.stage ~= "downloading" and not late then return end
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
  if type(upload) == "table" and upload.kind then
    local fn = bigHandlers[upload.kind]
    if fn and s.stage == "loaded" then fn(pid, s, upload.data or {}) end
    return
  end
  local result, reason = profiles.applyUpload(s.profile, upload)
  if not result then
    net.send(pid, "rlsmpUpAck", {id = id, ok = false, err = reason, resync = (reason == "resync")})
    return
  end
  if not s.guest then profiles.persist(s.profile) end
  s.ledgerDirty = false
  runHooks(savedHooks, pid, s, s.profile)
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
  local ok, why = wallet.applyDelta(s.profile.ledger, data.d, data.r, data.c)
  s.ledgerDirty = true
  if not ok then
    util.warn(string.format("Refused money change %s for %s (%s, reason: %s)",
      tostring(data.d), s.name, why, tostring(data.r)))
    net.send(pid, "rlsmpWalletSet", {money = s.profile.ledger.money, why = why})
  elseif (tonumber(data.d) or 0) > 0 and wallet.isEarning(data.c) then
    for _, fn in ipairs(earnedHooks) do fn(pid, s, tonumber(data.d), data.c) end
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
