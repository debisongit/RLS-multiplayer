-- RLS-Career-MP client: keep other players' cars alive while RLS starts the career.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS activation calls core_vehicles.removeAll(), which deletes EVERY vehicle in the scene, including the cars
-- BeamMP synced from other players (log: remote unicycle deleted the instant the career started).
-- While enabled, removeAll() only deletes vehicles that are not another player's.

local mp = require("rlsmp/lib/mp")

local M = {}

local enabled = false
local installed = false
local original

function M.enable(on) enabled = on == true end
function M.isEnabled() return enabled end

local function removeAllExceptRemote(...)
  if not enabled then return original(...) end
  local remote = mp.remoteSet()
  for i = be:getObjectCount() - 1, 0, -1 do
    local obj = be:getObject(i)
    if obj and not remote[obj:getID()] then obj:delete() end
  end
end

function M.install()
  if installed or not (core_vehicles and core_vehicles.removeAll) then return installed end
  original = core_vehicles.removeAll
  core_vehicles.removeAll = removeAllExceptRemote
  installed = true
  return true
end

return M
