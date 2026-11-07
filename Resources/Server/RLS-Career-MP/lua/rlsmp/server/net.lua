-- RLS-Career-MP server: network glue on top of the BeamMP event API.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- * on(name, fn)          -> handle an event (from clients or from BeamMP itself)
-- * send(pid, name, tbl)  -> send a small JSON message to one player
-- * sendBig(pid, kind, str, extra) -> queue a large string; it goes out in chunks
--   over the next ticks as "rlsmpChunkBegin" + many "rlsmpChunk" messages.
--
-- Event names are plain words (BeamMP splits on ':'), all prefixed with "rlsmp".

local util = require("rlsmp.server.util")
local transfer = require("rlsmp.shared.transfer")

local M = {}

local cfg
local outbox = {}       -- pid -> list of pending outgoing transfers
local recent = {}       -- pid -> transferId -> {chunks, expires}: finished transfers kept briefly so lost chunks can be sent again
local KEEP_SECONDS = 120
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

-- Queue a big string for chunked delivery. `kind` tells the client what it is.
function M.sendBig(pid, kind, payload, extra)
  nextTransferId = nextTransferId + 1
  local header, chunks = transfer.describe(payload, cfg.transfer.chunkSize)
  header.id = nextTransferId
  header.kind = kind
  header.extra = extra
  outbox[pid] = outbox[pid] or {}
  table.insert(outbox[pid], {header = header, chunks = chunks, next = 0, t0 = os.clock(), bytes = #payload})
  return header.id
end

function M.pendingFor(pid)
  return outbox[pid] and #outbox[pid] or 0
end

function M.dropPlayer(pid)
  outbox[pid] = nil
  recent[pid] = nil
end

-- The client says these chunks of transfer `id` never arrived: send them again (works while it is still being sent, too).
local function onChunkMissing(pid, data)
  local id, list = tonumber(data.id), data.list
  if not id or type(list) ~= "table" then return end
  local chunks
  for _, job in ipairs(outbox[pid] or {}) do if job.header.id == id then chunks = job.chunks end end
  if not chunks and recent[pid] and recent[pid][id] then chunks = recent[pid][id].chunks end
  if not chunks then return end
  local sent = 0
  for _, i in ipairs(list) do
    i = tonumber(i)
    if i and chunks[i] and sent < 60 then
      MP.TriggerClientEvent(pid, "rlsmpChunk", util.jsonEncode({id = id, i = i, d = chunks[i]}))
      sent = sent + 1
    end
  end
  util.info(string.format("[rlsmp-timing] player %s asked for %d missing chunks of #%d, sent %d", tostring(pid), #list, id, sent))
end

-- Called every pump tick: push a few chunks per player.
local function pump()
  local now = os.time()
  for pid, kept in pairs(recent) do
    for id, r in pairs(kept) do if r.expires < now then kept[id] = nil end end
    if next(kept) == nil then recent[pid] = nil end
  end
  for pid, queue in pairs(outbox) do
    local budget = cfg.transfer.chunksPerTick
    while budget > 0 and queue[1] do
      local job = queue[1]
      if job.next == 0 then
        M.send(pid, "rlsmpChunkBegin", job.header)
        job.next = 1
        job.startedAt = os.clock()
      else
        MP.TriggerClientEvent(pid, "rlsmpChunk",
          util.jsonEncode({id = job.header.id, i = job.next, d = job.chunks[job.next]}))
        job.next = job.next + 1
        budget = budget - 1
        if job.next > #job.chunks then
          util.info(string.format("[rlsmp-timing] sent %s #%s to player %s: %d bytes, %d chunks, %.1fs",
            tostring(job.header.kind), tostring(job.header.id), tostring(pid), job.bytes, #job.chunks, os.clock() - job.t0))
          table.remove(queue, 1)
          recent[pid] = recent[pid] or {}
          recent[pid][job.header.id] = {chunks = job.chunks, expires = os.time() + KEEP_SECONDS}
        end
      end
    end
    if not queue[1] then outbox[pid] = nil end
  end
end
M.pump = pump

function M.init(config)
  cfg = config
  M.on("onChatMessage", chatRouter)
  M.on("rlsmpPump", pump)
  M.onClient("rlsmpChunkMissing", onChunkMissing)
  MP.CreateEventTimer("rlsmpPump", 50)
end

return M
