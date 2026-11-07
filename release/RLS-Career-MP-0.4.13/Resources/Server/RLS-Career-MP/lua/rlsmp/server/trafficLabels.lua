-- RLS-Career-MP server: hides the name tags of AI traffic cars.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- BeamMP gives every car the name of the player whose game spawned it, so one player's 30 traffic cars show up as
-- 30 players with the same name. Each game knows which of ITS cars are AI traffic or parked cars, so it tells us the
-- list (`rlsmpTrafficIds {ids = {"0-7", ...}}`) and we relay it to everyone else, who hide those name tags.
-- The relay only accepts ids that belong to the sender ("<playerId>-<n>").

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local lists = {}     -- pid -> {ids}
local greeted = {}   -- pid -> true once they have been sent everyone's lists

local MAX_IDS = 400

local function validIds(pid, ids)
  if type(ids) ~= "table" or #ids > MAX_IDS then return nil end
  local clean, prefix = {}, tostring(pid) .. "-"
  for _, id in ipairs(ids) do
    if type(id) == "string" and id:sub(1, #prefix) == prefix and id:match("^%d+%-%d+$") then clean[#clean + 1] = id end
  end
  return clean
end

local function relay(from, ids, onlyTo)
  for pid in pairs(sessions.all()) do
    if pid ~= from and sessions.isLoaded(pid) and (not onlyTo or onlyTo == pid) then
      net.send(pid, "rlsmpTrafficIdsRx", {from = from, ids = ids})
    end
  end
end

local function onIds(pid, data)
  if not sessions.isLoaded(pid) then return end
  local ids = validIds(pid, data.ids)
  if not ids then return end
  lists[pid] = ids
  relay(pid, ids)
end

-- Newly loaded players get everyone's current lists; leavers are forgotten.
function M.tick()
  for pid in pairs(lists) do
    if not sessions.isLoaded(pid) then lists[pid] = nil end
  end
  for pid in pairs(greeted) do
    if not sessions.isLoaded(pid) then greeted[pid] = nil end
  end
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) and not greeted[pid] then
      greeted[pid] = true
      for from, ids in pairs(lists) do
        if from ~= pid then net.send(pid, "rlsmpTrafficIdsRx", {from = from, ids = ids}) end
      end
    end
  end
end

function M.init()
  net.onClient("rlsmpTrafficIds", onIds)
  net.on("rlsmpLabelsTick", M.tick)
  MP.CreateEventTimer("rlsmpLabelsTick", 2000)
end

return M
