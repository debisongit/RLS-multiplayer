-- RLS-Career-MP server: crash-safe JSON files on disk.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Writes go to "<file>.tmp" first, then replace the real file, keeping "<file>.bak"
-- as a fallback. If the server dies mid-write, the old save is still there.

local util = require("rlsmp.server.util")

local M = {}

local function fsExists(path)
  if FS and FS.Exists then return FS.Exists(path) end
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function mkdirs(dir)
  if not dir or dir == "" or fsExists(dir) then return end
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(dir)
  else
    os.execute('mkdir -p "' .. dir .. '"')
  end
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

function M.exists(path) return fsExists(path) end
function M.ensureDir(dir) mkdirs(dir) end

-- Read and decode a JSON file. Falls back to the .bak copy if the main one is broken.
function M.readJson(path)
  local data = util.jsonDecode(readAll(path))
  if data ~= nil then return data end
  local backup = util.jsonDecode(readAll(path .. ".bak"))
  if backup ~= nil then
    util.warn("Using backup copy of " .. path)
    return backup
  end
  return nil
end

function M.writeJson(path, value, pretty)
  local dir = path:match("^(.*)/[^/]+$")
  mkdirs(dir)
  local ok, text = pcall(util.jsonEncode, value)
  if not ok or type(text) ~= "string" then
    util.err("Could not encode JSON for " .. path .. ": " .. tostring(text))
    return false
  end
  if pretty then text = util.jsonPretty(text) end

  local tmp = path .. ".tmp"
  local f, problem = io.open(tmp, "wb")
  if not f then
    util.err("Could not open " .. tmp .. ": " .. tostring(problem))
    return false
  end
  f:write(text)
  f:close()

  -- os.rename will not overwrite on Windows, so move the old file aside first.
  local bak = path .. ".bak"
  if fsExists(path) then
    os.remove(bak)
    os.rename(path, bak)
  end
  local renamed, renameProblem = os.rename(tmp, path)
  if not renamed then
    util.err("Could not move " .. tmp .. " into place: " .. tostring(renameProblem))
    if fsExists(bak) then os.rename(bak, path) end
    return false
  end
  return true
end

return M
