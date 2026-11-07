-- RLS-Career-MP server: shared event records (Phase 4).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Each game runs RLS freeroam events on its own and reports finished runs (rlsmpEventDone).
-- The server keeps the best time per event and announces new records. /records [event] lists them.
-- Times come from the client, so they are only bragging rights: no money depends on them.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

local M = {}

local file
local records = {}  -- race -> { {name=, id=, t=}, ... } best first, one entry per player

local MAX_TOP, MAX_RACES, MIN_TIME = 5, 200, 3
local SUBMIT_EVERY = 5        -- seconds between accepted runs per account (wall clock)
local ANNOUNCE_MARGIN = 0.05  -- a record goes to everybody's chat only when it beats the old one by at least this much
local MAX_SOLO_RACES = 40     -- events one player may hold alone (nobody else has a time there): one client cannot fill MAX_RACES with junk
local lastAccepted = {}       -- accountId -> util.now() of the last accepted run

local function say(pid, text) MP.SendChatMessage(pid, "[Events] " .. text) end

local function fmt(t) return string.format("%d:%05.2f", math.floor(t / 60), t % 60) end

local function soloRaces(accountId)
  local n = 0
  for _, list in pairs(records) do
    if #list == 1 and list[1].id == accountId then n = n + 1 end
  end
  return n
end

-- Returns result, oldBest. result: "record" (new best for the event), "pb" (new personal best), "slower" (valid run,
-- nothing new) or nil (refused). oldBest: the event's best time before this run (nil for an event seen for the first time).
function M.submit(race, accountId, name, t)
  if type(race) ~= "string" or #race == 0 or #race > 60 then return nil end
  t = tonumber(t)
  if not t or t < MIN_TIME or t > 86400 then return nil end
  if not records[race] then
    local count = 0
    for _ in pairs(records) do count = count + 1 end
    if count >= MAX_RACES or soloRaces(accountId) >= MAX_SOLO_RACES then return nil end
    records[race] = {}
  end
  local list = records[race]
  local oldBest = list[1] and list[1].t
  for i, e in ipairs(list) do
    if e.id == accountId then
      if t >= e.t then return "slower", oldBest end
      table.remove(list, i)
      break
    end
  end
  table.insert(list, {name = name, id = accountId, t = t})
  table.sort(list, function(a, b) return a.t < b.t end)
  while #list > MAX_TOP do table.remove(list) end
  storage.writeJson(file, records)
  return list[1].id == accountId and "record" or "pb", oldBest
end

local function onDone(pid, data)
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then return end
  local now = util.now()
  local last = lastAccepted[s.accountId]
  if last and now - last < SUBMIT_EVERY then return end
  local result, oldBest = M.submit(data.race, s.accountId, s.name, data.t)
  if not result then return end
  lastAccepted[s.accountId] = now
  local t = tonumber(data.t)
  if result == "record" and (oldBest == nil or oldBest - t >= ANNOUNCE_MARGIN - 1e-9) then
    MP.SendChatMessage(-1, string.format("[Events] New record on %s: %s by %s!", data.race, fmt(t), s.name))
  elseif result == "record" then
    say(pid, string.format("New record on %s: %s (less than %.2f s faster, not announced)", data.race, fmt(t), ANNOUNCE_MARGIN))
  elseif result == "pb" then
    say(pid, string.format("Personal best on %s: %s", data.race, fmt(t)))
  end
end

local function onRecords(pid, arg)
  local list = records[arg]
  if arg ~= "" and list then
    for i, e in ipairs(list) do say(pid, string.format("%d. %s  %s", i, e.name, fmt(e.t))) end
    return
  end
  local names = {}
  for race, l in pairs(records) do names[#names + 1] = string.format("%s (%s %s)", race, l[1].name, fmt(l[1].t)) end
  table.sort(names)
  if #names == 0 then return say(pid, "No event records yet.") end
  say(pid, "Records: " .. table.concat(names, ", ", 1, math.min(#names, 8)) .. ". /records <event> shows the top 5.")
end

function M.init(_, pluginRoot)
  file = pluginRoot .. "records.json"
  records = storage.readJson(file) or {}
  net.onClient("rlsmpEventDone", onDone)
  net.onChat("records", onRecords)
end

M.records = function() return records end

return M
