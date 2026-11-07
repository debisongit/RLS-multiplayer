-- RLS-Career-MP shared transfer helpers.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- This exact file is used on BOTH sides:
--   server: Resources/Server/RLS-Career-MP/lua/rlsmp/shared/transfer.lua  (Lua 5.3)
--   client: Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/lib/transfer.lua (LuaJIT / 5.1)
-- Keep it 5.1-compatible (no //, no bit operators, no goto) and keep both copies identical.
-- tests/run.sh fails if they drift.
--
-- What it does: big strings (a whole save) do not fit in one BeamMP event, so we
-- split them into numbered chunks, send them, and glue them back together on the
-- other side. A checksum proves nothing got lost or mangled on the way.

local M = {}

M.PROTOCOL = 1
-- Bump on every release. Logged by the client on load and by the server on join, so mixed builds are easy to spot.
M.BUILD = "0.4.6"

-- Fletcher-32 over the bytes of a string, using plain arithmetic so it runs on any Lua.
function M.checksum(str)
  local sum1, sum2 = 0, 0
  local len = #str
  local i = 1
  while i <= len do
    -- process in blocks so string.byte gets a sane number of results at once
    local last = i + 255
    if last > len then last = len end
    local bytes = {string.byte(str, i, last)}
    for k = 1, #bytes do
      sum1 = (sum1 + bytes[k]) % 65535
      sum2 = (sum2 + sum1) % 65535
    end
    i = last + 1
  end
  return string.format("%04x%04x", sum2, sum1)
end

-- Split a string into a list of pieces of at most `size` bytes.
function M.split(str, size)
  assert(type(str) == "string", "split expects a string")
  assert(type(size) == "number" and size >= 1, "split expects a positive size")
  local chunks = {}
  local len = #str
  if len == 0 then
    chunks[1] = ""
    return chunks
  end
  local i = 1
  while i <= len do
    chunks[#chunks + 1] = string.sub(str, i, i + size - 1)
    i = i + size
  end
  return chunks
end

-- Describe a payload before sending it: how many chunks, total length, checksum.
function M.describe(str, size)
  local chunks = M.split(str, size)
  return {n = #chunks, len = #str, sum = M.checksum(str)}, chunks
end

-- Assembler: collects chunks for one transfer and tells you when it is complete.
-- header = {n = chunkCount, len = totalLength, sum = checksum}
function M.newAssembler(header)
  local self = {
    n = tonumber(header.n) or 0,
    len = tonumber(header.len) or -1,
    sum = header.sum,
    parts = {},
    received = 0,
  }

  -- Returns true when a chunk was stored, false + reason when it was rejected.
  function self:add(index, data)
    index = tonumber(index)
    if not index or index < 1 or index > self.n or index % 1 ~= 0 then return false, "bad_index" end
    if type(data) ~= "string" then return false, "bad_data" end
    if self.parts[index] == nil then
      self.received = self.received + 1
    end
    self.parts[index] = data
    return true
  end

  function self:isComplete()
    return self.n > 0 and self.received >= self.n
  end

  -- Glue everything together and verify. Returns the string, or nil + reason.
  function self:finish()
    if not self:isComplete() then return nil, "incomplete" end
    local out = table.concat(self.parts, "", 1, self.n)
    if #out ~= self.len then return nil, "length_mismatch" end
    if self.sum and M.checksum(out) ~= self.sum then return nil, "checksum_mismatch" end
    return out
  end

  return self
end

-- A save file path inside a save slot, like "career/playerAttributes.json".
-- Rejects anything that could escape the slot folder.
function M.safeRelativePath(rel)
  if type(rel) ~= "string" or rel == "" or #rel > 240 then return false end
  if rel:find("\\", 1, true) or rel:find("%c") then return false end
  if rel:sub(1, 1) == "/" or rel:find(":", 1, true) then return false end
  if ("/" .. rel .. "/"):find("/%.%.?/") then return false end
  if not rel:match("%.json$") then return false end
  return true
end

return M
