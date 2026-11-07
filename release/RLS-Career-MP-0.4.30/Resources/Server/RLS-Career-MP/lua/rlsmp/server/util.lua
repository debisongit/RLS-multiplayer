-- RLS-Career-MP server: tiny helpers shared by every server module.
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

local TAG = "[RLS-Career-MP]"

function M.log(level, msg)
  print(string.format("%s %s %s", TAG, level, tostring(msg)))
end
function M.info(msg) M.log("INFO ", msg) end
function M.warn(msg) M.log("WARN ", msg) end
function M.err(msg) M.log("ERROR", msg) end

-- JSON goes through BeamMP's Util.* in the real server. Tests can swap in their own codec.
local codec = nil
function M.setJsonCodec(c) codec = c end

function M.jsonEncode(value)
  if codec then return codec.encode(value) end
  return Util.JsonEncode(value)
end

function M.jsonDecode(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ok, value
  if codec then
    ok, value = pcall(codec.decode, text)
  else
    ok, value = pcall(Util.JsonDecode, text)
  end
  if ok then return value end
  return nil
end

function M.jsonPretty(text)
  if codec or not (Util and Util.JsonPrettify) then return text end
  return Util.JsonPrettify(text)
end

-- Seconds since epoch. Tests can freeze time.
local clock = os.time
function M.setClock(fn) clock = fn end
function M.now() return clock() end

function M.deepMerge(defaults, actual)
  if type(actual) ~= "table" then actual = {} end
  for k, v in pairs(defaults) do
    if type(v) == "table" and not v[1] then
      actual[k] = M.deepMerge(v, actual[k])
    elseif actual[k] == nil then
      actual[k] = v
    end
  end
  return actual
end

return M
