-- RLS-Career-MP server: who is this player? We key saves by BeamMP account ID,
-- because names can change or be copied. Guests have no ID.
-- SPDX-License-Identifier: AGPL-3.0-only

local util = require("rlsmp.server.util")

local M = {}

local cfg

-- Account IDs are numbers in practice, but only ever trust a safe filename-ish string.
local function cleanId(id)
  if id == nil then return nil end
  id = tostring(id)
  if id:match("^[%w_-]+$") and #id <= 64 then return id end
  return nil
end
M.cleanId = cleanId

function M.accountId(pid)
  local ids = MP.GetPlayerIdentifiers(pid)
  return cleanId(type(ids) == "table" and ids.beammp or nil)
end

-- Folder name used on the player's PC for this server's copy of their save.
-- RLS lowercases new profile names and strips everything except a-z and 0-9,
-- so we hand it a name that already looks like that (otherwise it renames the folder).
function M.localProfileName(accountId)
  return (("rlsmp" .. cfg.serverTag .. tostring(accountId)):lower():gsub("[^a-z0-9]", ""))
end

-- BeamMP "onPlayerAuth": returning a string refuses the connection with that message.
function M.onPlayerAuth(name, role, isGuest, identifiers)
  if cfg.identity.allowGuests then return nil end
  local id = cleanId(type(identifiers) == "table" and identifiers.beammp or nil)
  if isGuest or not id then
    util.info("Refused guest " .. tostring(name))
    return "This server saves your career to your BeamMP account. Please log in to BeamMP (guests can't save)."
  end
  return nil
end

function M.init(config)
  cfg = config
end

return M
