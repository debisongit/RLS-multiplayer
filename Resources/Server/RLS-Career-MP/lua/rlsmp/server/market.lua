-- RLS-Career-MP server: the black market (custom, RLS has none). Server owns everything; the client only shows the drop.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Access is invite + reputation. The first member is made by the server owner (console: rlsmp market grant <player>).
-- A member invites with /market invite <player>; that player types /market accept. Each invite is reserved (and saved)
-- when it is sent, so an offline inviter cannot be over-spent; an invite that expires while its inviter is still online
-- is given back.
--
-- profile.market = {member, rep, invites = invites used, invitedBy, joinedAt, nextOrder, orders = {order...}}
-- order = {id, item, n, price, at, readyAt, spot = {name, x, y, z}}  (the spot is copied in, so rotations or config
-- edits never strand a paid order). Orders stay until picked up, also for a player who was thrown out.
--
-- Money: /market buy takes it from the server wallet (ledger.money) and writes the order in the SAME profiles.persist,
-- then pushes rlsmpWalletSet. The client applies that as a sync (not reported back), so it is plain spending.
-- Pickup: the order is removed and the item given in the same persist (items.give saves the profile).
-- A crash can never charge without an order, nor deliver twice.
--
-- Pickup position comes from server/positions.lua (the client's regular rlsmpPos reports, horizontal distance).
-- Positions are client-made: faking one only skips the drive to a package that was already paid for.
--
-- Other modules: market.addRep(pid, n, why), market.lossRep(pid, n, why), market.bust(pid, opts),
-- market.isMember(pid), market.rep(pid), market.fenceQuote(valueOrCar), market.spotAt(t).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local items = require("rlsmp.server.items")
local positions = require("rlsmp.server.positions")

local M = {}

local cfg
local invites = {}   -- target pid -> {s = target session, byPid, bySession, byName, expires}

local function c() return cfg.market end
local function say(pid, text) MP.SendChatMessage(pid, "[Market] " .. text) end
local function dollars(n) return string.format("$%d", math.floor(n)) end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- A loaded, non-guest player with a saved profile, or nil.
local function loaded(pid)
  local s = sessions.get(pid)
  if s and s.stage == "loaded" and s.profile and s.accountId and not s.guest then return s end
end

-- The market part of a profile, repaired. `create` makes it for a player who never had one.
local function stateOf(profile, create)
  local m = profile.market
  if type(m) ~= "table" then
    if not create then return nil end
    m = {member = false, rep = 0, invites = 0}
    profile.market = m
  end
  m.member = m.member == true
  m.rep = tonumber(m.rep) or 0
  m.invites = tonumber(m.invites) or 0
  m.nextOrder = tonumber(m.nextOrder) or 1
  if type(m.orders) ~= "table" then m.orders = {} end
  return m
end

local function memberState(pid)
  local s = loaded(pid)
  local m = s and stateOf(s.profile)
  if m and m.member then return m, s end
  return nil, s
end

function M.isMember(pid) return memberState(pid) ~= nil end
function M.rep(pid)
  local m = memberState(pid)
  return m and m.rep or nil
end

function M.invitesAllowed(m)
  local per = c().repPerInvite > 0 and math.floor(math.max(0, m.rep) / c().repPerInvite) or 0
  return math.min(c().maxInvites, c().baseInvites + per)
end
local function invitesLeft(m) return math.max(0, M.invitesAllowed(m) - m.invites) end

-- The sale entry of an item, or nil when it is not sold (unknown to items.CATALOG, switched off, bad price).
function M.offer(name)
  local t = type(name) == "string" and c().tiers[name]
  if type(t) ~= "table" or t.off or not items.known(name) then return nil end
  local price, minRep = tonumber(t.price), tonumber(t.minRep) or 0
  if not (finite(price) and price > 0 and finite(minRep)) then return nil end
  return {name = name, label = items.CATALOG[name].label, price = math.floor(price), minRep = minRep,
          durable = items.CATALOG[name].durable}
end

local function offers()
  local list = {}
  for name in pairs(c().tiers) do
    local o = M.offer(name)
    if o then list[#list + 1] = o end
  end
  table.sort(list, function(a, b) return a.minRep < b.minRep or (a.minRep == b.minRep and a.price < b.price) end)
  return list
end

-- Drop spots ---------------------------------------------------------------------------------------

local function spots()
  local list = {}
  for _, sp in ipairs(type(c().dropSpots) == "table" and c().dropSpots or {}) do
    if type(sp) == "table" and type(sp.name) == "string" and finite(sp.x) and finite(sp.y) and finite(sp.z) then
      list[#list + 1] = sp
    end
  end
  return list
end

-- The drop spot that is active at time t (seconds): the same answer for the same t, every server restart.
-- It changes every rotateMinutes; it never stays on the same spot two periods in a row when there is a choice.
function M.spotAt(t)
  local list = spots()
  local n = #list
  if n == 0 then return nil end
  local period = math.floor(t / math.max(60, c().rotateMinutes * 60))
  local function base(p) return math.floor(((p * 2654435761 + 12345) % 4294967296) / 65536) % n + 1 end
  local i = base(period)
  if n > 1 and i == base(period - 1) then i = i % n + 1 end
  local sp = list[i]
  return {name = sp.name, x = sp.x, y = sp.y, z = sp.z}, period
end

local function dropMessage(o, now)
  local info = items.CATALOG[o.item]
  return {id = o.id, item = o.item, label = info and info.label or o.item, n = o.n, spot = o.spot.name,
          x = o.spot.x, y = o.spot.y, z = o.spot.z, readyIn = math.max(0, o.readyAt - now)}
end

-- Commands -----------------------------------------------------------------------------------------

local cmds = {}

local function findPlayer(name)
  name = tostring(name or ""):lower()
  if name == "" then return nil end
  for pid, s in pairs(sessions.all()) do
    if tostring(s.name):lower() == name or s.accountId == name then return pid, s end
  end
end

local function help(pid)
  local s = loaded(pid)
  if not s then return say(pid, "Wait until your career has loaded.") end
  local m = stateOf(s.profile)
  local open = m and #m.orders or 0
  if not (m and m.member) then
    local inv = invites[pid]
    if inv and inv.s == s and inv.expires >= util.now() then
      return say(pid, inv.byName .. " invited you. Type /market accept to join.")
    end
    say(pid, "You are not in the black market. A member has to invite you, then you type /market accept.")
    if open > 0 then say(pid, "You still have " .. open .. " paid package(s): /market orders, /market pickup.") end
    return
  end
  say(pid, string.format("Reputation %d. Invites left %d. Open orders %d.", m.rep, invitesLeft(m), open))
  say(pid, "Commands: /market list | buy <item> [count] | orders | pickup | invite <player> | fence")
end

function cmds.list(pid)
  local m = memberState(pid)
  if not m then return say(pid, "Members only.") end
  local can, nextRep, locked = {}, nil, 0
  for _, o in ipairs(offers()) do
    if m.rep >= o.minRep then
      can[#can + 1] = string.format("%s [%s] %s%s", o.label, o.name, dollars(o.price), o.durable and "" or " each")
    else
      locked = locked + 1
      if not nextRep or o.minRep < nextRep then nextRep = o.minRep end
    end
  end
  if #can == 0 then say(pid, "Nothing for you yet.") else say(pid, "For sale: " .. table.concat(can, ", ")) end
  if locked > 0 then say(pid, string.format("%d more item(s) unlock with reputation (next at %d).", locked, nextRep)) end
end

local function hasOnOrder(m, item)
  for _, o in ipairs(m.orders) do if o.item == item then return true end end
  return false
end

function cmds.buy(pid, arg)
  local m, s = memberState(pid)
  if not m then return say(pid, "Members only.") end
  local name, count = tostring(arg or ""):lower():match("^(%S+)%s*(%d*)$")
  local o = M.offer(name)
  if not o then return say(pid, "Usage: /market buy <item> [count]. See /market list.") end
  if m.rep < o.minRep then return say(pid, o.label .. " needs reputation " .. o.minRep .. ".") end
  local n = tonumber(count ~= "" and count or "1")
  if o.durable and n ~= 1 then return say(pid, o.label .. " is a tool: one lasts forever.") end
  if n < 1 or n > 10 then return say(pid, "Count must be 1 to 10.") end
  if o.durable and (items.has(pid, name) or hasOnOrder(m, name)) then
    return say(pid, "You already have a " .. o.label .. " (or one on the way). Tools last forever.")
  end
  if #m.orders >= c().maxOpenOrders then return say(pid, "Pick up your open orders first (/market orders).") end
  local ledger = s.profile.ledger
  local total = o.price * n
  if not ledger.seeded then return say(pid, "Wait for your first save, then try again.") end
  if ledger.money < total then return say(pid, "That costs " .. dollars(total) .. ".") end
  local now = util.now()
  local lo, hi = math.floor(c().minDelaySeconds), math.floor(c().maxDelaySeconds)
  if hi < lo then hi = lo end
  local readyAt = now + math.random(lo, hi)
  local spot = M.spotAt(readyAt)
  if not spot then return say(pid, "No drop spots are set up on this server.") end
  local order = {id = "o" .. math.floor(m.nextOrder), item = name, n = n, price = total, at = now, readyAt = readyAt, spot = spot}
  -- Debit and order go to disk together; if the write fails, undo both.
  ledger.money = ledger.money - total
  m.orders[#m.orders + 1] = order
  m.nextOrder = m.nextOrder + 1
  if not profiles.persist(s.profile) then
    ledger.money = ledger.money + total
    table.remove(m.orders)
    m.nextOrder = m.nextOrder - 1
    return say(pid, "The server could not save. Nothing was charged.")
  end
  net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "market"})
  net.send(pid, "rlsmpMarketDrop", dropMessage(order, now))
  util.info(string.format("Market: %s bought %dx %s for %d, drop %s at +%ds", s.name, n, name, total, spot.name, readyAt - now))
  say(pid, string.format("Paid %s for %s%s. The package will be at %s in about %d s. Drive there and type /market pickup.",
    dollars(total), o.label, n > 1 and (" x" .. n) or "", spot.name, readyAt - now))
end

function cmds.orders(pid)
  local s = loaded(pid)
  local m = s and stateOf(s.profile)
  if not (m and #m.orders > 0) then return say(pid, "No open orders.") end
  local now, parts = util.now(), {}
  for _, o in ipairs(m.orders) do
    local label = items.CATALOG[o.item] and items.CATALOG[o.item].label or o.item
    parts[#parts + 1] = string.format("%s%s: %s", label, o.n > 1 and (" x" .. o.n) or "",
      o.readyAt <= now and ("waiting at " .. o.spot.name) or string.format("at %s in %d s", o.spot.name, o.readyAt - now))
  end
  say(pid, table.concat(parts, "; "))
end

local function distance(pos, spot)
  local dx, dy = pos.x - spot.x, pos.y - spot.y
  return math.sqrt(dx * dx + dy * dy)
end

function cmds.pickup(pid)
  local s = loaded(pid)
  local m = s and stateOf(s.profile)
  if not (m and #m.orders > 0) then return say(pid, "No open orders.") end
  local now = util.now()
  local ready = 0
  for _, o in ipairs(m.orders) do if o.readyAt <= now then ready = ready + 1 end end
  if ready == 0 then return say(pid, "Your package is not there yet (/market orders).") end
  if positions.isChased(pid) then return say(pid, "Lose the police first.") end
  local pos = positions.get(pid)
  if not pos or now - pos.t > c().positionMaxAge then
    return say(pid, "The server has no fresh position from you yet. Wait a few seconds and try again.")
  end
  local got, nearest, nearestName = {}, nil, nil
  for i = #m.orders, 1, -1 do
    local o = m.orders[i]
    if o.readyAt <= now then
      local d = distance(pos, o.spot)
      if d <= c().pickupRadius then
        table.remove(m.orders, i)                       -- removed first: items.give saves both changes at once
        local ok, why = items.give(pid, o.item, o.n)
        if ok then
          got[#got + 1] = o
        else
          table.insert(m.orders, i, o)
          util.warn(string.format("Market: could not give %s to %s: %s", tostring(o.item), s.name, tostring(why)))
        end
      elseif not nearest or d < nearest then
        nearest, nearestName = d, o.spot.name
      end
    end
  end
  if #got == 0 then
    if nearest then return say(pid, string.format("No package here. Nearest: %s, %.0f m away.", nearestName, nearest)) end
    return say(pid, "Could not hand over the package, try again.")
  end
  local parts = {}
  for _, o in ipairs(got) do
    net.send(pid, "rlsmpMarketClear", {id = o.id})
    parts[#parts + 1] = (items.CATALOG[o.item].label) .. (o.n > 1 and (" x" .. o.n) or "")
  end
  util.info(string.format("Market: %s picked up %d package(s)", s.name, #got))
  say(pid, "Picked up: " .. table.concat(parts, ", ") .. ". See /items.")
end

function cmds.invite(pid, arg)
  local m, s = memberState(pid)
  if not m then return say(pid, "Members only.") end
  if invitesLeft(m) < 1 then return say(pid, "No invites left. More come with reputation.") end
  local targetPid, target = findPlayer(arg)
  if not target or targetPid == pid or not loaded(targetPid) then return say(pid, "Player '" .. tostring(arg) .. "' is not online.") end
  local tm = stateOf(target.profile)
  if tm and tm.member then return say(pid, target.name .. " is already in.") end
  local old = invites[targetPid]
  if old and old.s == target and old.expires >= util.now() then return say(pid, target.name .. " already has an invite.") end
  m.invites = m.invites + 1      -- reserved now, saved now
  profiles.persist(s.profile)
  invites[targetPid] = {s = target, byPid = pid, bySession = s, byName = s.name, expires = util.now() + c().inviteSeconds}
  say(pid, string.format("Invited %s. Invites left %d.", target.name, invitesLeft(m)))
  say(targetPid, s.name .. " invited you to the black market. Type /market accept within " .. c().inviteSeconds .. " s.")
end

function cmds.accept(pid)
  local s = loaded(pid)
  local inv = invites[pid]
  if not (s and inv and inv.s == s and inv.expires >= util.now()) then return say(pid, "No open invite.") end
  invites[pid] = nil
  local m = stateOf(s.profile, true)
  if m.member then return say(pid, "You are already in.") end
  m.member = true
  m.rep = math.max(m.rep, c().startRep)
  m.invitedBy = inv.byName
  m.joinedAt = util.now()
  profiles.persist(s.profile)
  say(pid, "You are in. Your reputation is " .. m.rep .. ". See /market list.")
  if sessions.get(inv.byPid) == inv.bySession then say(inv.byPid, s.name .. " accepted your invite.") end
end

function cmds.fence(pid)
  say(pid, string.format("The fence buys stolen cars (about %d%% of their value) and parts (about %d%%). It opens with the car theft feature.",
    math.floor(c().fenceCarRate * 100 + 0.5), math.floor(c().fencePartRate * 100 + 0.5)))
end

local function onChat(pid, rest)
  if not c().enabled then return say(pid, "The black market is closed on this server.") end
  local sub, arg = tostring(rest or ""):match("^(%S*)%s*(.-)$")
  local fn = cmds[(sub or ""):lower()]
  if fn then return fn(pid, arg) end
  help(pid)
end

-- Reputation (for other modules) -------------------------------------------------------------------

-- Change a member's reputation by n (whole number, at most market.maxRepChange either way). Kept between 0 and maxRep.
-- Returns the new reputation, or nil + reason.
function M.addRep(pid, n, why)
  n = tonumber(n)
  if not finite(n) then return nil, "bad amount" end
  n = n >= 0 and math.floor(n) or -math.floor(-n)
  n = math.max(-c().maxRepChange, math.min(c().maxRepChange, n))
  local m, s = memberState(pid)
  if not m then return nil, "not a member" end
  local old = m.rep
  m.rep = math.max(0, math.min(c().maxRep, old + n))
  if m.rep == old then return m.rep end
  profiles.persist(s.profile)
  say(pid, string.format("Reputation %+d (%s). Now %d.", m.rep - old, tostring(why or "job"), m.rep))
  for _, o in ipairs(offers()) do
    if o.minRep > old and o.minRep <= m.rep then say(pid, "New items unlocked: /market list") break end
  end
  return m.rep
end

function M.lossRep(pid, n, why)
  local v = tonumber(n)
  if not finite(v) then return nil, "bad amount" end
  return M.addRep(pid, -math.abs(v), why)
end

-- Caught by the police (called by theft/police code). Costs market.bustRep reputation (a member who has less is
-- thrown out, rep 0, open orders stay theirs) and takes used-up items, and tools too when bustTakesTools or opts.takeTools.
-- Works for non-members too (items only). opts = {rep = n, takeItems = false, takeTools = true}.
-- Returns {member, rep, expelled, taken = {item names}} or nil + reason.
function M.bust(pid, opts)
  opts = type(opts) == "table" and opts or {}
  local s = loaded(pid)
  if not s then return nil, "player not loaded" end
  local m = stateOf(s.profile)
  local result = {member = m ~= nil and m.member, taken = {}}
  if m and m.member then
    local cost = tonumber(opts.rep) or c().bustRep
    if not finite(cost) or cost < 0 then cost = c().bustRep end
    cost = math.floor(cost)
    result.cost = cost
    if m.rep < cost then
      m.member, m.rep, result.expelled = false, 0, true
    else
      m.rep = m.rep - cost
    end
    result.rep = m.rep
  end
  local papers = opts.takeItems ~= false and c().bustTakesPapers
  local tools = opts.takeItems ~= false and (opts.takeTools == true or c().bustTakesTools)
  for _, it in ipairs(items.list(pid)) do
    local durable = items.CATALOG[it.name].durable
    if (durable and tools) or (not durable and papers) then
      if items.take(pid, it.name, it.count) then result.taken[#result.taken + 1] = it.name end
    end
  end
  profiles.persist(s.profile)
  if result.expelled then
    say(pid, "Busted. The black market does not trust you any more: you are out (open orders are still yours).")
  elseif result.member then
    say(pid, string.format("Busted. Reputation -%d, now %d.", result.cost, m.rep))
  end
  if #result.taken > 0 then say(pid, "The police took: " .. table.concat(result.taken, ", ") .. ".") end
  util.info(string.format("Market: %s busted (rep %s, took %d item kinds%s)", s.name, tostring(result.rep), #result.taken,
    result.expelled and ", expelled" or ""))
  return result
end

-- The fence (opens with car theft) ----------------------------------------------------------------

-- What the fence pays: a number (a car's value) or {value = n, kind = "car" | "part"}. Returns whole dollars, 0 if invalid.
function M.fenceQuote(valueOrCar)
  local value, kind = valueOrCar, "car"
  if type(valueOrCar) == "table" then
    value = tonumber(valueOrCar.value)
    kind = valueOrCar.kind == "part" and "part" or "car"
  end
  if not finite(value) or value <= 0 then return 0 end
  local rate = kind == "part" and c().fencePartRate or c().fenceCarRate
  return math.floor(value * rate)
end

-- Console (rlsmp market ...) -----------------------------------------------------------------------

function M.console(arg)
  local sub, who = tostring(arg or ""):match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "grant" or sub == "revoke" then
    local pid, s = findPlayer(who)
    if not (s and s.profile and s.accountId and not s.guest) then
      return "RLS-Career-MP: '" .. tostring(who) .. "' is not online (the player must be on the server)"
    end
    local m = stateOf(s.profile, true)
    if sub == "grant" then
      m.member = true
      m.rep = math.max(m.rep, c().founderRep)
      m.invitedBy = m.invitedBy or "server"
      m.joinedAt = m.joinedAt or util.now()
      profiles.persist(s.profile)
      say(pid, "You are in the black market. Reputation " .. m.rep .. ". Type /market for help.")
      return string.format("RLS-Career-MP: %s is a black market member (rep %d)", tostring(s.name), m.rep)
    end
    m.member = false
    profiles.persist(s.profile)
    say(pid, "You are no longer in the black market.")
    return "RLS-Career-MP: " .. tostring(s.name) .. " removed from the black market"
  end
  return "RLS-Career-MP: rlsmp market grant <player> | rlsmp market revoke <player>"
end

-- Timer: invite expiry (an expired invite goes back to its inviter while they are online), drops re-sent after a join,
-- and one "your package is ready" message per order.
local function tick()
  local now = util.now()
  for targetPid, inv in pairs(invites) do
    if inv.expires < now or sessions.get(targetPid) ~= inv.s then
      invites[targetPid] = nil
      if sessions.get(inv.byPid) == inv.bySession and inv.bySession.profile then
        local m = stateOf(inv.bySession.profile)
        if m and m.invites > 0 then
          m.invites = m.invites - 1
          profiles.persist(inv.bySession.profile)
          say(inv.byPid, "Your invite was not accepted; you get it back.")
        end
      end
    end
  end
  for pid, s in pairs(sessions.all()) do
    local m = loaded(pid) and stateOf(s.profile)
    if m and #m.orders > 0 then
      if not s.marketSynced then
        for _, o in ipairs(m.orders) do net.send(pid, "rlsmpMarketDrop", dropMessage(o, now)) end
      end
      s.marketTold = s.marketTold or {}
      for _, o in ipairs(m.orders) do
        if o.readyAt <= now and not s.marketTold[o.id] then
          s.marketTold[o.id] = true
          say(pid, "Your package is waiting at " .. o.spot.name .. ". Drive there and type /market pickup.")
        end
      end
    end
    if m then s.marketSynced = true end
  end
end
M._tick = tick

function M.init(config)
  cfg = config
  for name in pairs(c().tiers) do
    if not items.known(name) then util.warn("market.tiers: '" .. tostring(name) .. "' is not an item, ignored") end
  end
  if #spots() == 0 then util.warn("market.dropSpots is empty: nobody can buy") end
  net.onChat("market", onChat)
  net.on("rlsmpMarketTick", tick)
  MP.CreateEventTimer("rlsmpMarketTick", 5000)
end

return M
