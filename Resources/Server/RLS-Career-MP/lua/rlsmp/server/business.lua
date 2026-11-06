-- RLS-Career-MP server: Business / Syndicate (shared bank + members).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- businesses/<id>.json = { id, name, owner = accountId, bank, members = {accountId = {name, role, joinedAt}}, log = {...} }
-- A player's profile only stores `businessId`. Everything is controlled with chat commands:
--   /biz create <name> | invite <player> | accept | leave | deposit <n> | withdraw <n> | info
--
-- Money moves between the player's server wallet (wallet.lua) and the business bank.
-- Each transfer is saved debit-first, so a crash can lose money but never duplicate it.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")

local M = {}

local cfg, root
local cache = {}     -- business id -> table
local invites = {}   -- target pid -> {id, by, expires}
local counter = 0
local LOG_MAX = 20

local function say(pid, text) MP.SendChatMessage(pid, "[Biz] " .. text) end
local function path(id) return root .. "businesses/" .. id .. ".json" end

local function save(b)
  b.updatedAt = util.now()
  return storage.writeJson(path(b.id), b)
end

local function load(id)
  if type(id) ~= "string" or not id:match("^b[0-9]+$") then return nil end
  if cache[id] then return cache[id] end
  local b = storage.readJson(path(id))
  if type(b) == "table" and type(b.members) == "table" then cache[id] = b return b end
end

local function addLog(b, who, what, amount)
  table.insert(b.log, {t = util.now(), who = who, what = what, amount = amount})
  while #b.log > LOG_MAX do table.remove(b.log, 1) end
end

local function memberCount(b)
  local n = 0
  for _ in pairs(b.members) do n = n + 1 end
  return n
end

-- Tell every online member (optionally except one player).
local function tell(b, text, exceptPid)
  for pid, s in pairs(sessions.all()) do
    if pid ~= exceptPid and s.accountId and b.members[s.accountId] then say(pid, text) end
  end
end

-- The player's business (or nil). Also repairs a profile that points at a business they're no longer in.
local function myBusiness(s)
  local b = load(s.profile.businessId)
  if b and b.members[s.accountId] then return b end
  s.profile.businessId = nil
  return nil
end

local function parseAmount(text)
  local n = tonumber(text)
  if n and n > 0 and n % 1 == 0 and n <= 1e9 then return n end
end

local function findPlayer(name)
  name = tostring(name or ""):lower()
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" and tostring(s.name):lower() == name then return pid, s end
  end
end

-- Push a server-approved balance to the client and save the profile.
local function walletChanged(pid, s)
  profiles.persist(s.profile)
  net.send(pid, "rlsmpWalletSet", {money = s.profile.ledger.money, why = "business"})
end

-- Commands ------------------------------------------------------------------------------------------

local cmds = {}

function cmds.create(pid, s, b, arg)
  if b then return say(pid, "You are already in " .. b.name .. ". Use /biz leave first.") end
  local name = arg:match("^%s*(.-)%s*$")
  if #name < 3 or #name > 24 or name:find("%c") then return say(pid, "Name must be 3-24 characters.") end
  counter = counter + 1
  local id = string.format("b%d%03d", util.now(), counter % 1000)
  b = {id = id, name = name, owner = s.accountId, bank = 0, createdAt = util.now(), log = {},
       members = {[s.accountId] = {name = s.name, role = "owner", joinedAt = util.now()}}}
  cache[id] = b
  save(b)
  s.profile.businessId = id
  profiles.persist(s.profile)
  say(pid, "Created '" .. name .. "'. Invite people with /biz invite <player>.")
end

function cmds.invite(pid, s, b, arg)
  if not b then return say(pid, "You are not in a business.") end
  if memberCount(b) >= cfg.business.maxMembers then return say(pid, "Business is full (" .. cfg.business.maxMembers .. ").") end
  local targetPid, target = findPlayer(arg)
  if not target then return say(pid, "Player '" .. arg .. "' is not online.") end
  if myBusiness(target) then return say(pid, target.name .. " is already in a business.") end
  invites[targetPid] = {id = b.id, by = s.name, expires = util.now() + cfg.business.inviteSeconds}
  say(pid, "Invited " .. target.name .. ".")
  say(targetPid, s.name .. " invited you to '" .. b.name .. "'. Type /biz accept within " .. cfg.business.inviteSeconds .. "s.")
end

function cmds.accept(pid, s, b)
  local inv = invites[pid]
  invites[pid] = nil
  if not inv or inv.expires < util.now() then return say(pid, "No pending invite.") end
  if b then return say(pid, "Leave your current business first.") end
  local target = load(inv.id)
  if not target then return say(pid, "That business no longer exists.") end
  if memberCount(target) >= cfg.business.maxMembers then return say(pid, "That business is full.") end
  target.members[s.accountId] = {name = s.name, role = "member", joinedAt = util.now()}
  addLog(target, s.name, "joined")
  save(target)
  s.profile.businessId = target.id
  profiles.persist(s.profile)
  tell(target, s.name .. " joined the business.")
end

function cmds.leave(pid, s, b)
  if not b then return say(pid, "You are not in a business.") end
  b.members[s.accountId] = nil
  s.profile.businessId = nil
  if next(b.members) == nil then
    -- Last member: the bank is paid out and the business is closed.
    s.profile.ledger.money = s.profile.ledger.money + b.bank
    cache[b.id] = nil
    os.remove(path(b.id))
    walletChanged(pid, s)
    return say(pid, "Business closed. $" .. b.bank .. " from the bank was paid to you.")
  end
  if b.owner == s.accountId then
    local nextId, oldest
    for id, m in pairs(b.members) do
      if not oldest or m.joinedAt < oldest then nextId, oldest = id, m.joinedAt end
    end
    b.owner = nextId
    b.members[nextId].role = "owner"
    tell(b, b.members[nextId].name .. " is the new owner.")
  end
  addLog(b, s.name, "left")
  save(b)
  profiles.persist(s.profile)
  tell(b, s.name .. " left the business.")
  say(pid, "You left '" .. b.name .. "'.")
end

function cmds.deposit(pid, s, b, arg)
  if not b then return say(pid, "You are not in a business.") end
  local n = parseAmount(arg)
  local ledger = s.profile.ledger
  if not n then return say(pid, "Usage: /biz deposit <amount>") end
  if not ledger.seeded then return say(pid, "Wait for your first save, then try again.") end
  if ledger.money < n then return say(pid, "Not enough money.") end
  ledger.money = ledger.money - n
  walletChanged(pid, s)          -- debit first
  b.bank = b.bank + n
  addLog(b, s.name, "deposit", n)
  save(b)
  tell(b, string.format("%s deposited $%d. Bank: $%d", s.name, n, b.bank))
end

function cmds.withdraw(pid, s, b, arg)
  if not b then return say(pid, "You are not in a business.") end
  local n = parseAmount(arg)
  if not n then return say(pid, "Usage: /biz withdraw <amount>") end
  if b.members[s.accountId].role ~= "owner" and not cfg.business.membersCanWithdraw then
    return say(pid, "Only the owner can withdraw.")
  end
  if not s.profile.ledger.seeded then return say(pid, "Wait for your first save, then try again.") end
  if b.bank < n then return say(pid, "The bank only has $" .. b.bank .. ".") end
  b.bank = b.bank - n            -- debit first
  addLog(b, s.name, "withdraw", n)
  save(b)
  s.profile.ledger.money = s.profile.ledger.money + n
  walletChanged(pid, s)
  tell(b, string.format("%s withdrew $%d. Bank: $%d", s.name, n, b.bank))
end

function cmds.info(pid, s, b)
  if not b then return say(pid, "You are not in a business. Create one with /biz create <name>.") end
  local names = {}
  for _, m in pairs(b.members) do names[#names + 1] = m.name .. (m.role == "owner" and " (owner)" or "") end
  table.sort(names)
  say(pid, string.format("%s | Bank $%d | Members: %s", b.name, b.bank, table.concat(names, ", ")))
end

function cmds.help(pid)
  say(pid, "/biz create <name> | invite <player> | accept | leave | deposit <n> | withdraw <n> | info")
end

-- BeamMP chat hook: returning 1 hides the message from other players.
local function onChat(pid, _, message)
  local cmd, arg = tostring(message):match("^/biz%s*(%S*)%s*(.-)%s*$")
  if not cmd then return nil end
  local s = sessions.get(pid)
  if cmd == "" or cmd == "help" then cmds.help(pid)
  elseif not cmds[cmd] then say(pid, "Unknown command. Try /biz help")
  elseif not s or s.stage ~= "loaded" then say(pid, "Your career is still loading.")
  else cmds[cmd](pid, s, myBusiness(s), arg) end
  return 1
end

function M.init(config, pluginRoot)
  cfg, root = config, pluginRoot
  storage.ensureDir(root .. "businesses")
  net.on("onChatMessage", onChat)
end

-- For other modules (shared fleet, mission payouts): the player's business table, or nil.
function M.getFor(pid)
  local s = sessions.get(pid)
  return s and s.profile and myBusiness(s) or nil
end

return M
