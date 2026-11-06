-- RLS-Career-MP server: Business / Syndicate (shared bank + members).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- businesses/<id>.json = { id, name, owner = accountId, bank, members = {accountId = {name, role, joinedAt}}, log = {...} }
-- A player's profile only stores `businessId`. Everything is controlled with chat commands:
--   /biz create <name> | invite <player> | accept | leave | deposit <n> | withdraw <n> | info
--   /biz fleet list | add | take <n> | return
--
-- Shared fleet = "check-out" model. A fleet car lives in exactly one place: stored in the business,
-- or in ONE member's RLS inventory. Members drive/tune it like their own car and `return` it when done.
-- The car's saved record (`rec`: model, parts, paints...) travels through the client mod (client fleet.lua).
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
  if type(b) == "table" and type(b.members) == "table" then b.fleet = b.fleet or {}
    b.nextFleet = b.nextFleet or 1
    cache[id] = b
    return b
  end
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
  b = {id = id, name = name, owner = s.accountId, bank = 0, createdAt = util.now(), log = {}, fleet = {}, nextFleet = 1,
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

local function heldBy(b, accountId)
  for fid, v in pairs(b.fleet) do if v.heldBy == accountId then return fid end end
end

function cmds.leave(pid, s, b)
  if not b then return say(pid, "You are not in a business.") end
  if heldBy(b, s.accountId) then return say(pid, "Return your fleet car first (/biz fleet return).") end
  if memberCount(b) == 1 and next(b.fleet) then return say(pid, "Fleet cars would be lost. Take them out of the fleet first.") end
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

-- Fleet ---------------------------------------------------------------------------------------------

local function holderName(b, v)
  return v.heldBy and b.members[v.heldBy] and b.members[v.heldBy].name or nil
end

function cmds.fleet(pid, s, b, arg)
  if not b then return say(pid, "You are not in a business.") end
  local sub, rest = arg:match("^(%S*)%s*(.-)$")
  if sub == "add" then
    local count = 0
    for _ in pairs(b.fleet) do count = count + 1 end
    if count >= cfg.business.maxFleet then return say(pid, "Fleet is full (" .. cfg.business.maxFleet .. ").") end
    net.send(pid, "rlsmpFleetDo", {act = "add"})
  elseif sub == "take" then
    local fid = tonumber(rest)
    local v = fid and b.fleet[tostring(fid)]
    if not v then return say(pid, "No fleet car with that number. See /biz fleet list.") end
    if v.heldBy then return say(pid, "Already taken by " .. tostring(holderName(b, v)) .. ".") end
    if heldBy(b, s.accountId) then return say(pid, "Return your current fleet car first.") end
    v.heldBy = s.accountId
    save(b)
    net.sendBig(pid, "fleetVehicle", util.jsonEncode({fid = tostring(fid), rec = v.rec}), {fid = tostring(fid)})
    say(pid, "Sending " .. v.name .. " to your garage...")
  elseif sub == "return" then
    if not heldBy(b, s.accountId) then return say(pid, "You don't have a fleet car.") end
    net.send(pid, "rlsmpFleetDo", {act = "return", fid = heldBy(b, s.accountId)})
  else
    local ids = {}
    for fid in pairs(b.fleet) do ids[#ids + 1] = tonumber(fid) end
    table.sort(ids)
    if #ids == 0 then return say(pid, "Fleet is empty. Sit in a car and use /biz fleet add.") end
    for _, fid in ipairs(ids) do
      local v = b.fleet[tostring(fid)]
      say(pid, string.format("#%d %s - %s", fid, v.name, v.heldBy and ("held by " .. tostring(holderName(b, v))) or "available"))
    end
  end
end

-- Client uploads --------------------------------------------------------------------------------------

local function validRecord(rec)
  return type(rec) == "table" and type(rec.model) == "string" and type(rec.config) == "table"
    and #util.jsonEncode(rec) <= cfg.business.maxRecordBytes
end

local function onFleetAdd(pid, s, data)
  local b = myBusiness(s)
  local ack = {act = "add", ok = false, inv = data.inv}
  local count = 0
  if b then for _ in pairs(b.fleet) do count = count + 1 end end
  if b and validRecord(data.rec) and count < cfg.business.maxFleet then
    local fid = tostring(b.nextFleet)
    b.nextFleet = b.nextFleet + 1
    data.rec.fleetId = fid
    b.fleet[fid] = {name = tostring(data.rec.niceName or data.rec.model):sub(1, 40), model = data.rec.model,
                    rec = data.rec, addedBy = s.accountId}
    addLog(b, s.name, "fleet add", tonumber(fid))
    save(b)
    ack.ok, ack.fid = true, fid
    tell(b, s.name .. " added " .. b.fleet[fid].name .. " to the fleet (#" .. fid .. ").")
  else
    say(pid, "Could not add that car to the fleet.")
  end
  net.send(pid, "rlsmpFleetAck", ack)
end

local function onFleetReturn(pid, s, data)
  local b = myBusiness(s)
  local v = b and b.fleet[tostring(data.fid)]
  local ack = {act = "return", ok = false, inv = data.inv}
  if v and v.heldBy == s.accountId and validRecord(data.rec) then
    data.rec.fleetId = tostring(data.fid)
    v.rec, v.heldBy = data.rec, nil
    addLog(b, s.name, "fleet return", tonumber(data.fid))
    save(b)
    ack.ok = true
    tell(b, s.name .. " returned " .. v.name .. " (#" .. data.fid .. ").")
  else
    say(pid, "Could not return that car.")
  end
  net.send(pid, "rlsmpFleetAck", ack)
end

-- The client could not take the car (garage full, spawn failed): free it again.
local function onFleetRelease(pid, data)
  local s = sessions.get(pid)
  local b = s and s.profile and myBusiness(s)
  local v = b and b.fleet[tostring(data.fid)]
  if v and v.heldBy == s.accountId then
    v.heldBy = nil
    save(b)
    say(pid, "Fleet car released: " .. tostring(data.why or "could not be taken"))
  end
end

function cmds.help(pid)
  say(pid, "/biz create <name> | invite <player> | accept | leave | deposit <n> | withdraw <n> | info | fleet")
end

-- /biz <command> <argument>
local function onChat(pid, text)
  local cmd, arg = text:match("^(%S*)%s*(.-)$")
  local s = sessions.get(pid)
  if cmd == "" or cmd == "help" then cmds.help(pid)
  elseif not cmds[cmd] then say(pid, "Unknown command. Try /biz help")
  elseif not s or s.stage ~= "loaded" then say(pid, "Your career is still loading.")
  else cmds[cmd](pid, s, myBusiness(s), arg) end
end

function M.init(config, pluginRoot)
  cfg, root = config, pluginRoot
  storage.ensureDir(root .. "businesses")
  net.onChat("biz", onChat)
  sessions.onBig("fleetAdd", onFleetAdd)
  sessions.onBig("fleetReturn", onFleetReturn)
  net.onClient("rlsmpFleetRelease", onFleetRelease)
end

-- For other modules (shared fleet, mission payouts): the player's business table, or nil.
function M.getFor(pid)
  local s = sessions.get(pid)
  return s and s.profile and myBusiness(s) or nil
end

return M
