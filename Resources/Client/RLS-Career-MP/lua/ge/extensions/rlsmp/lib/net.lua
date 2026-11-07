-- RLS-Career-MP client: network glue on top of BeamMP's TriggerServerEvent / AddEventHandler.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- * on(name, fn)        -> handle a JSON message from the server
-- * send(name, tbl)     -> send a small JSON message to the server
-- * onBig(kind, fn)     -> handle a big chunked payload from the server (fn(text, extra))
-- * sendBig(...)        -> queue a big upload; pump() pushes a few chunks per frame
--
-- Plain module (not an extension) so it can be unit tested outside the game.

local transfer = require("rlsmp/lib/transfer")

local M = {}

local api = {
  -- swapped out by tests
  trigger = function(name, data) TriggerServerEvent(name, data) end,
  addHandler = function(name, fn) AddEventHandler(name, fn) end,
  encode = function(v) return jsonEncode(v) end,
  decode = function(s) return jsonDecode(s) end,
  log = function(level, msg) log(level, "RLS-Career-MP", msg) end,
}
function M.setApi(overrides) for k, v in pairs(overrides) do api[k] = v end end

local handlers = {}
local bigHandlers = {}
local incoming = {}      -- transfer id -> {assembler, header}
local outgoing = {}      -- list of pending uploads
local registered = {}

local function decodeOrNil(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, v = pcall(api.decode, raw)
  if ok and type(v) == "table" then return v end
  return nil
end

local function dispatch(name, raw)
  local fn = handlers[name]
  if not fn then return end
  local data = decodeOrNil(raw)
  if not data then
    api.log("W", "Bad JSON in " .. name)
    return
  end
  local ok, problem = pcall(fn, data)
  if not ok then api.log("E", name .. " handler failed: " .. tostring(problem)) end
end

function M.on(name, fn)
  handlers[name] = fn
  if not registered[name] then
    registered[name] = true
    api.addHandler(name, function(raw) dispatch(name, raw) end)
  end
end

function M.send(name, data)
  api.trigger(name, api.encode(data or {}))
end

function M.onBig(kind, fn) bigHandlers[kind] = fn end

local ORPHAN_IDS = 4         -- unknown transfers we hold chunks for while their header is asked for again
local ORPHAN_CHUNKS = 64     -- chunks kept per unknown transfer
local HEADER_ASK_EVERY = 3   -- heartbeats (about seconds) between repeated header requests
local done = {}              -- finished transfer ids: late duplicate chunks or headers for them are ignored
local orphans = {}           -- transfer id -> {parts = {i = d}, count, wait}: chunks that came before (or without) their rlsmpChunkBegin
local lastAsked              -- transfer id the last requestMissing asked about (they take turns)

local function addChunk(id, job, i, d)
  if job.assembler:add(i, d) then
    i = tonumber(i)
    if i > (job.top or 0) then job.top = i end
  end
  -- Tell the server how far we are, so it sends no faster than we can read.
  if job.assembler.received % 8 == 0 and not job.assembler:isComplete() then
    M.send("rlsmpChunkProgress", {id = tonumber(id), got = job.assembler.received})
    job.progressSent = true
  end
  if not job.assembler:isComplete() then return end
  incoming[id] = nil
  done[id] = true
  local text, problem = job.assembler:finish()
  local fn = bigHandlers[job.header.kind]
  if not fn then return end
  if not text then
    api.log("E", "Transfer " .. tostring(job.header.kind) .. " broken: " .. tostring(problem))
    fn(nil, job.header.extra, problem)
    return
  end
  fn(text, job.header.extra)
end

-- A header we already have (a late copy after we asked again) must not wipe the chunks received so far.
local function onChunkBegin(h)
  local id = tostring(h.id)
  if incoming[id] or done[id] then return end
  local job = {assembler = transfer.newAssembler(h), header = h}
  incoming[id] = job
  local kept = orphans[id]
  orphans[id] = nil
  if kept then
    for i, d in pairs(kept.parts) do
      if incoming[id] ~= job then break end   -- completed (and handled) already
      addChunk(id, job, i, d)
    end
  end
end

local function askHeader(id)
  M.send("rlsmpChunkHeader", {id = tonumber(id)})
end

local function onChunk(c)
  local id = tostring(c.id)
  if done[id] then return end
  local job = incoming[id]
  if job then return addChunk(id, job, c.i, c.d) end
  -- Its rlsmpChunkBegin never arrived: ask for it once (heartbeat repeats), keep a few chunks meanwhile.
  local o = orphans[id]
  if not o then
    local n = 0
    for _ in pairs(orphans) do n = n + 1 end
    if n >= ORPHAN_IDS then return end
    o = {parts = {}, count = 0, wait = 0}
    orphans[id] = o
    askHeader(id)
  end
  local i = tonumber(c.i)
  if i and type(c.d) == "string" and o.parts[i] == nil and o.count < ORPHAN_CHUNKS then
    o.parts[i] = c.d
    o.count = o.count + 1
  end
end

-- Call about once per second. While a download runs, tell the server how far we are if the every-8-chunks
-- report did not just go out (a lost report would otherwise hold the server's send window shut), and ask
-- again for headers that have not come.
function M.heartbeat()
  for id, job in pairs(incoming) do
    if job.progressSent then
      job.progressSent = false
    elseif job.assembler.received > 0 and not job.assembler:isComplete() then
      M.send("rlsmpChunkProgress", {id = tonumber(id), got = job.assembler.received})
    end
  end
  for id, o in pairs(orphans) do
    o.wait = o.wait + 1
    if o.wait >= HEADER_ASK_EVERY then
      o.wait = 0
      askHeader(id)
    end
  end
end

-- Progress of incoming transfers, for a loading message: received, total.
function M.incomingProgress()
  local got, total = 0, 0
  for _, job in pairs(incoming) do
    got = got + job.assembler.received
    total = total + job.assembler.n
  end
  return got, total
end

-- True when a download has a gap below the highest chunk received: those were lost (the server sends in order).
-- Ask for them right away even while new chunks still trickle in.
function M.hasHoles()
  for _, job in pairs(incoming) do
    for i = 1, (job.top or 0) - 1 do
      if job.assembler.parts[i] == nil then return true end
    end
  end
  return false
end

-- Ask the server to send again the chunks of an unfinished download that have not shown up (at most 50).
-- One transfer per call (the server takes one request per second), taking turns when several are unfinished.
function M.requestMissing()
  local ids = {}
  for id, job in pairs(incoming) do
    if job.assembler.received < job.assembler.n then ids[#ids + 1] = id end
  end
  if #ids == 0 then return 0 end
  table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  local pick = ids[1]
  for _, id in ipairs(ids) do
    if lastAsked and (tonumber(id) or 0) > (tonumber(lastAsked) or 0) then pick = id break end
  end
  lastAsked = pick
  local job = incoming[pick]
  local list = {}
  for i = 1, job.assembler.n do
    if job.assembler.parts[i] == nil then
      list[#list + 1] = i
      if #list >= 50 then break end
    end
  end
  M.send("rlsmpChunkMissing", {id = tonumber(pick), list = list})
  return #list
end

-- Queue an upload: sends beginEvent with {id, n, len, sum} then chunkEvent with {id, i, d}.
function M.sendBig(beginEvent, chunkEvent, id, text, chunkSize)
  local header, chunks = transfer.describe(text, chunkSize)
  header.id = id
  table.insert(outgoing, {beginEvent = beginEvent, chunkEvent = chunkEvent, header = header, chunks = chunks, next = 0})
end

function M.isUploading() return outgoing[1] ~= nil end

function M.pump(budget)
  budget = budget or 4
  while budget > 0 and outgoing[1] do
    local job = outgoing[1]
    if job.next == 0 then
      M.send(job.beginEvent, job.header)
      job.next = 1
    else
      M.send(job.chunkEvent, {id = job.header.id, i = job.next, d = job.chunks[job.next]})
      job.next = job.next + 1
      budget = budget - 1
      if job.next > #job.chunks then table.remove(outgoing, 1) end
    end
  end
end

function M.reset()
  incoming = {}
  outgoing = {}
  done, orphans, lastAsked = {}, {}, nil   -- transfer ids start again on the next server
  registered = {}   -- BeamMP forgets our handlers when a session ends: register them again next time
end

function M.init()
  M.on("rlsmpChunkBegin", onChunkBegin)
  M.on("rlsmpChunk", onChunk)
end

return M
