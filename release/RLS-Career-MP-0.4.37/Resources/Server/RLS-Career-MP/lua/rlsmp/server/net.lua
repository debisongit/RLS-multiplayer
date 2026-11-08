-- RLS-Career-MP server: network glue on top of the BeamMP event API.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- * on(name, fn)          -> handle an event (from clients or from BeamMP itself)
-- * send(pid, name, tbl)  -> send a small JSON message to one player
-- * sendBig(pid, kind, str, extra) -> queue a large string; it goes out in chunks
--   over the next ticks as "rlsmpChunkBegin" + many "rlsmpChunk" messages.
--
-- Event names are plain words (BeamMP splits on ':'), all prefixed with "rlsmp".
-- Times here are wall clock (util.now = os.time), never os.clock (CPU time).

local util = require("rlsmp.server.util")
local transfer = require("rlsmp.shared.transfer")

local M = {}

local cfg
local outbox = {}       -- pid -> list of pending outgoing transfers
local recent = {}       -- pid -> transferId -> {header, chunks, expires}: finished transfers kept briefly so lost chunks can be sent again
local resends = {}      -- pid -> {list = {{id, i}, ...}, queued = {["id:i"] = true}}: lost chunks waiting for pump()
local limits = {}       -- pid -> what -> util.now() of the last accepted request
local KEEP_SECONDS = 120
local WINDOW = 24       -- chunks that may be on the way before the client has confirmed some (a busy client drops what it cannot read)
local SILENCE_SECONDS = 3   -- window full and no news this long: send ONE chunk, then wait again
local REQUEST_EVERY = 1     -- seconds between accepted resend / header requests per player
local MAX_MISSING = 50      -- chunk numbers read from one rlsmpChunkMissing
local MAX_RESEND_QUEUE = 200
local nextTransferId = 0

-- BeamMP wants a *global function name* per event. We generate one per event.
function M.on(eventName, fn)
  local globalName = "rlsmp_handler_" .. eventName
  _G[globalName] = function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      util.err("Handler " .. eventName .. " failed: " .. tostring(result))
      return nil
    end
    return result
  end
  MP.RegisterEvent(eventName, globalName)
end

-- For events coming from a client: decode the JSON body before calling fn(pid, data).
function M.onClient(eventName, fn)
  M.on(eventName, function(pid, raw)
    local data = util.jsonDecode(raw)
    if type(data) ~= "table" then
      util.warn("Ignored " .. eventName .. " from player " .. tostring(pid) .. ": bad JSON")
      return
    end
    return fn(pid, data)
  end)
end

-- Chat commands: net.onChat("biz", fn(pid, rest)) handles "/biz <rest>". The message is hidden from other players.
-- (One BeamMP event can only have one handler, so every module goes through this router.)
local chatCommands = {}
function M.onChat(command, fn) chatCommands[command] = fn end

local function chatRouter(pid, _, message)
  local command, rest = tostring(message):match("^/(%S+)%s*(.-)%s*$")
  local fn = command and chatCommands[command:lower()]
  if not fn then return nil end
  fn(pid, rest)
  return 1
end

function M.send(pid, eventName, data)
  return MP.TriggerClientEvent(pid, eventName, util.jsonEncode(data or {}))
end

-- BeamMP's TriggerClientEvent returns false when the message could not be queued; only an explicit false counts as failed.
local function sendOk(pid, eventName, tbl)
  return MP.TriggerClientEvent(pid, eventName, util.jsonEncode(tbl)) ~= false
end

-- Queue a big string for chunked delivery. `kind` tells the client what it is.
function M.sendBig(pid, kind, payload, extra)
  nextTransferId = nextTransferId + 1
  local header, chunks = transfer.describe(payload, cfg.transfer.chunkSize)
  header.id = nextTransferId
  header.kind = kind
  header.extra = extra
  outbox[pid] = outbox[pid] or {}
  table.insert(outbox[pid], {header = header, chunks = chunks, next = 0, t0 = util.now(), bytes = #payload})
  return header.id
end

function M.pendingFor(pid)
  return outbox[pid] and #outbox[pid] or 0
end

-- Lost chunks queued to go out again for this player.
function M.resendsFor(pid)
  return resends[pid] and #resends[pid].list or 0
end

-- Client requests (missing chunks, lost headers): only from players with a session, at most one per kind per second.
local function allowRequest(pid, what)
  local s = require("rlsmp.server.sessions").get(pid)   -- lazy: sessions requires net
  if not s then return false end
  local now = util.now()
  limits[pid] = limits[pid] or {}
  local last = limits[pid][what]
  if last and now - last < REQUEST_EVERY then return false end
  limits[pid][what] = now
  return true
end

-- Header and chunks of transfer `id` for `pid`: the running job (once its header went out) or the copy kept after sending.
local function findTransfer(pid, id)
  for _, job in ipairs(outbox[pid] or {}) do
    if job.header.id == id then
      if job.next == 0 then return nil end
      return job.header, job.chunks, job.next - 1   -- only chunks already sent can be missing
    end
  end
  local r = recent[pid] and recent[pid][id]
  if r then return r.header, r.chunks, #r.chunks end
  return nil
end

-- The client reports how many chunks of transfer `id` it holds; this lets the next ones go out.
local function onChunkProgress(pid, data)
  local id, got = tonumber(data.id), tonumber(data.got)
  if not id or not got then return end
  for _, job in ipairs(outbox[pid] or {}) do
    if job.header.id == id and got > (job.got or 0) then job.got, job.gotAt = got, util.now() end
  end
end

function M.dropPlayer(pid)
  outbox[pid] = nil
  recent[pid] = nil
  resends[pid] = nil
  limits[pid] = nil
end

-- The client says these chunks of transfer `id` never arrived: queue them again (works while it is still being sent, too).
-- They go out through pump() with the normal per-tick budget, never as one burst.
local function onChunkMissing(pid, data)
  local id, list = tonumber(data.id), data.list
  if not id or type(list) ~= "table" then return end
  if not allowRequest(pid, "missing") then return end
  local _, chunks, sentUpTo = findTransfer(pid, id)
  if not chunks then return end
  local q = resends[pid] or {list = {}, queued = {}}
  local added = 0
  for k = 1, math.min(#list, MAX_MISSING) do
    local i = math.tointeger(tonumber(list[k]))
    local key = i and (id .. ":" .. i)
    if i and chunks[i] and i <= sentUpTo and not q.queued[key] and #q.list < MAX_RESEND_QUEUE then
      q.queued[key] = true
      q.list[#q.list + 1] = {id = id, i = i}
      added = added + 1
    end
  end
  if q.list[1] then resends[pid] = q end
  util.info(string.format("[rlsmp-timing] player %s asked for %d missing chunks of #%d, queued %d", tostring(pid), #list, id, added))
end

-- The client got chunks of a transfer whose rlsmpChunkBegin it never saw: send the header again.
local function onChunkHeader(pid, data)
  local id = tonumber(data.id)
  if not id then return end
  if not allowRequest(pid, "header") then return end
  local header = findTransfer(pid, id)
  if not header then return end
  if sendOk(pid, "rlsmpChunkBegin", header) then
    util.info(string.format("[rlsmp-timing] sent the header of #%d to player %s again", id, tostring(pid)))
  end
end

-- Lost chunks go first and skip the window: they fill the holes that keep the window full.
local function pumpResends(pid, budget)
  local q = resends[pid]
  if not q then return budget end
  while budget > 0 and q.list[1] do
    local r = q.list[1]
    local _, chunks = findTransfer(pid, r.id)
    if chunks and chunks[r.i] then
      if not sendOk(pid, "rlsmpChunk", {id = r.id, i = r.i, d = chunks[r.i]}) then return 0 end   -- try again next tick
      budget = budget - 1
    end
    table.remove(q.list, 1)
    q.queued[r.id .. ":" .. r.i] = nil
  end
  if not q.list[1] then resends[pid] = nil end
  return budget
end

-- Called every pump tick: push a few chunks per player.
local function pump()
  local now = util.now()
  for pid, kept in pairs(recent) do
    for id, r in pairs(kept) do if r.expires < now then kept[id] = nil end end
    if next(kept) == nil then recent[pid] = nil end
  end
  local pids = {}
  for pid in pairs(outbox) do pids[pid] = true end
  for pid in pairs(resends) do pids[pid] = true end
  for pid in pairs(pids) do
    local budget = pumpResends(pid, cfg.transfer.chunksPerTick)
    local queue = outbox[pid] or {}
    while budget > 0 and queue[1] do
      local job = queue[1]
      if job.next == 0 then
        if not sendOk(pid, "rlsmpChunkBegin", job.header) then break end
        job.next = 1
        job.startedAt = now
        job.gotAt = now
      else
        local full = (job.next - 1) - (job.got or 0) >= WINDOW
        local silent = now - (job.gotAt or job.startedAt or now) >= SILENCE_SECONDS
        if full and not silent then break end   -- wait for the client to confirm
        if not sendOk(pid, "rlsmpChunk", {id = job.header.id, i = job.next, d = job.chunks[job.next]}) then break end
        job.next = job.next + 1
        budget = budget - 1
        if job.next > #job.chunks then
          util.info(string.format("[rlsmp-timing] sent %s #%s to player %s: %d bytes, %d chunks, %ds",
            tostring(job.header.kind), tostring(job.header.id), tostring(pid), job.bytes, #job.chunks, now - job.t0))
          table.remove(queue, 1)
          recent[pid] = recent[pid] or {}
          recent[pid][job.header.id] = {header = job.header, chunks = job.chunks, expires = now + KEEP_SECONDS}
        elseif full then
          -- Window full and 3 s without news: this one chunk only, then wait another 3 s (a trickle, not a flood).
          job.gotAt = now
          break
        end
      end
    end
    if outbox[pid] and not outbox[pid][1] then outbox[pid] = nil end
  end
end
M.pump = pump

function M.init(config)
  cfg = config
  M.on("onChatMessage", chatRouter)
  M.on("rlsmpPump", pump)
  M.onClient("rlsmpChunkMissing", onChunkMissing)
  M.onClient("rlsmpChunkProgress", onChunkProgress)
  M.onClient("rlsmpChunkHeader", onChunkHeader)
  MP.CreateEventTimer("rlsmpPump", 50)
end

return M
