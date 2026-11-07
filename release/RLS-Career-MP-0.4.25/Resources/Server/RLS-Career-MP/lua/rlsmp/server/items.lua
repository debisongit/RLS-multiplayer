-- RLS-Career-MP server: player items (tools and papers for the black market and car theft).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS has no item system, so we keep one on the server, inside the player's profile: profile.items = {name = count}.
-- The server is the only writer. Other modules (blackmarket, theft) use give/take/has. /items lists yours.
-- Item names are plain words (see M.CATALOG); unknown names are refused so a bug cannot invent items.

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")

local M = {}

-- name -> {label, durable}. Durable tools last forever (owner's decision); papers and parts are used up.
M.CATALOG = {
  screwdriver     = {label = "Screwdriver", durable = true},
  window_punch    = {label = "Window punch", durable = true},
  key_programmer  = {label = "Key programmer", durable = true},
  blank_key       = {label = "Blank key", durable = false},
  relay_box       = {label = "Relay box", durable = true},
  signal_cloner   = {label = "Signal cloner", durable = true},
  can_injector    = {label = "Connector injector", durable = true},
  tracker_blocker = {label = "Tracker blocker", durable = true},
  fake_plate      = {label = "Fake plate", durable = false},
  vin_plate       = {label = "VIN plate", durable = false},
  part_number     = {label = "Part number kit", durable = false},
}

local function profileOf(pid)
  local s = sessions.get(pid)
  return s and s.stage == "loaded" and s.profile or nil
end

function M.known(name) return M.CATALOG[name] ~= nil end

function M.count(pid, name)
  local p = profileOf(pid)
  return p and p.items and tonumber(p.items[name]) or 0
end

function M.has(pid, name) return M.count(pid, name) > 0 end

-- Returns true, or false + reason.
function M.give(pid, name, n)
  n = math.floor(tonumber(n) or 1)
  if not M.known(name) then return false, "unknown item" end
  if n < 1 or n > 100 then return false, "bad amount" end
  local p = profileOf(pid)
  if not p then return false, "player not loaded" end
  p.items = p.items or {}
  p.items[name] = (tonumber(p.items[name]) or 0) + n
  profiles.persist(p)
  return true
end

function M.take(pid, name, n)
  n = math.floor(tonumber(n) or 1)
  local p = profileOf(pid)
  if not (p and M.known(name) and n >= 1) then return false, "nothing to take" end
  local have = p.items and tonumber(p.items[name]) or 0
  if have < n then return false, "not enough" end
  p.items[name] = have - n
  if p.items[name] <= 0 then p.items[name] = nil end
  profiles.persist(p)
  return true
end

-- Use an item: durable tools stay, the rest is consumed. Returns true if the player had it.
function M.use(pid, name)
  local info = M.CATALOG[name]
  if not (info and M.has(pid, name)) then return false end
  if not info.durable then M.take(pid, name, 1) end
  return true
end

function M.list(pid)
  local p = profileOf(pid)
  local out = {}
  for name, n in pairs(p and p.items or {}) do
    if M.CATALOG[name] then out[#out + 1] = {name = name, label = M.CATALOG[name].label, count = n} end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function onItems(pid)
  local list = M.list(pid)
  if #list == 0 then return MP.SendChatMessage(pid, "[Items] You have no items.") end
  local parts = {}
  for _, it in ipairs(list) do parts[#parts + 1] = it.label .. (M.CATALOG[it.name].durable and "" or (" x" .. it.count)) end
  MP.SendChatMessage(pid, "[Items] " .. table.concat(parts, ", "))
end

function M.init()
  net.onChat("items", onItems)
end

return M
