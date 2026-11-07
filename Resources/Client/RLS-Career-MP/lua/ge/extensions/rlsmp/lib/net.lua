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

local function onChunkBegin(h)
  incoming[tostring(h.id)] = {assembler = transfer.newAssembler(h), header = h}
end

local function onChunk(c)
  local id = tostring(c.id)
  local job = incoming[id]
  if not job then return end
  job.assembler:add(c.i, c.d)
  -- Tell the server how far we are, so it sends no faster than we can read.
  if job.assembler.received % 8 == 0 and not job.assembler:isComplete() then
    M.send("rlsmpChunkProgress", {id = tonumber(id), got = job.assembler.received})
  end
  if not job.assembler:isComplete() then return end
  incoming[id] = nil
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

-- Progress of incoming transfers, for a loading message: received, total.
function M.incomingProgress()
  local got, total = 0, 0
  for _, job in pairs(incoming) do
    got = got + job.assembler.received
    total = total + job.assembler.n
  end
  return got, total
end

-- Ask the server to send again the chunks of unfinished downloads that have not shown up (at most 50 per transfer).
function M.requestMissing()
  local asked = 0
  for id, job in pairs(incoming) do
    local list = {}
    for i = 1, job.assembler.n do
      if job.assembler.parts[i] == nil then
        list[#list + 1] = i
        if #list >= 50 then break end
      end
    end
    if #list > 0 then
      M.send("rlsmpChunkMissing", {id = tonumber(id), list = list})
      asked = asked + #list
    end
  end
  return asked
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
  registered = {}   -- BeamMP forgets our handlers when a session ends: register them again next time
end

function M.init()
  M.on("rlsmpChunkBegin", onChunkBegin)
  M.on("rlsmpChunk", onChunk)
end

return M
