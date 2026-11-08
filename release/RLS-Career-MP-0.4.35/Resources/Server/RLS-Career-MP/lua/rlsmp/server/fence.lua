-- RLS-Career-MP server: the fence. Sells or strips a stolen car at the black market's active drop spot (needs car theft on).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Chat: /fence            lists the cars you stole and what each way pays
--       /fence strip      parts for cash (no papers, pays least, safe)
--       /fence sell       sell it as it is to the fence (no papers, a bit more)
--       /fence resell     swap fake plate + VIN plate + part number first (all three used up), pays most, safe
--       /fence gamble     swap one or two of the papers (the ones you have, up to 2, used up): pays between, but the buyer may be a trap
-- A sale needs: black market member, theft record of the player's own, standing within market.pickupRadius of the ACTIVE drop spot
-- (fresh position report), not being chased. The server owns the money and the record; the client only names the car (its plate)
-- and deletes it afterwards when the answer says so.
--
-- GARAGE FLOW (the main way, no drop spot needed): the player opens the RLS garage computer and taps "Strip / illegal parts" on a car
-- (client rlsmp/garage.lua). It asks what is possible, shows a dialog, then asks to do one thing:
--   client rlsmpGarageQuote {plate, model, value, year} -> server rlsmpGarageMenu {ok, kind, plate, strip, fit = [...], items = [...]}
--   client rlsmpGarageDo {action, plate, model, value, year} -> server rlsmpGarageResult {ok, action, pay?, takeCar?, fitted?, err?}
--   action = "strip" | "fit:fake_plate" | "fit:vin_plate" | "fit:part_number". Fitting uses up the item at once and marks the stolen car's
--   record (rec.papers); /fence resell and gamble then count fitted papers first. Strip of a STOLEN car (needs market membership) and
--   an OWNED car (value comes from the client, capped by fence.maxValue, one per fence.garageCooldown seconds) pays stripRate x value.
-- Flow (chat fallback): chat /fence <mode>  -> rlsmpFenceAsk {mode}          (the client finds the stolen car next to the player)
--       client              -> rlsmpFenceSell {plate, mode}
--       server              -> rlsmpFenceResult {ok, mode, pay, busted, takeCar, err}
-- Order of writes: the record leaves memory, the wallet and papers change in ONE profile save, then the theft file is written.
-- If the profile cannot be saved, everything is undone.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local items = require("rlsmp.server.items")
local positions = require("rlsmp.server.positions")
local market = require("rlsmp.server.market")
local theft = require("rlsmp.server.theft")

local M = {}

local cfg
local busy = {}      -- pid -> true while a sale is being worked on

local random = math.random
function M.setRandom(fn) random = fn or math.random end

local PAPERS = {"fake_plate", "vin_plate", "part_number"}
M.MODES = {"strip", "sell", "resell", "gamble"}

local function c() return cfg.fence end
local function say(pid, text) MP.SendChatMessage(pid, "[Fence] " .. text) end
local function dollars(n) return string.format("$%d", math.floor(n)) end
local function num(v, default)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  return v
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function enabled() return cfg ~= nil and c().enabled == true and theft.isEnabled() end

local function itemLabel(name) return items.CATALOG[name] and items.CATALOG[name].label or name end

-- The value the fence works from: the record's value (the floor when the game had no price for the car), capped.
local function valueOf(rec)
  local v = math.floor(num(rec.value, 0))
  if v <= 0 then v = math.floor(num(c().minValue, 2000)) end
  return clamp(v, 0, math.floor(num(c().maxValue, 300000)))
end

-- How many papers (of the three) a player has.
local function fitted(rec, name) return rec ~= nil and type(rec.papers) == "table" and rec.papers[name] == true end
local function papersOwned(pid, rec)       -- papers already fitted to the car count as owned
  local have = {}
  for _, name in ipairs(PAPERS) do if fitted(rec, name) or items.has(pid, name) then have[#have + 1] = name end end
  return have
end

-- The price list for a car value and a player's papers: {strip = n, sell = n, resell = n or nil (missing papers), gamble = n or nil}.
function M.quotes(pid, value, rec)
  value = clamp(math.floor(num(value, 0)), 0, math.floor(num(c().maxValue, 300000)))
  local out = {
    strip = math.floor(value * num(c().stripRate, 0.30)),
    sell = market.fenceQuote(value),
  }
  local have = pid and papersOwned(pid, rec) or {}
  if #have == 3 then out.resell = math.floor(value * num(c().resellRate, 0.60)) end
  if #have >= 1 then
    local used = math.min(#have, math.floor(num(c().gambleMaxPapers, 2)))
    out.gamble = math.floor(value * (num(c().gambleBase, 0.45) + num(c().gamblePerPaper, 0.075) * (used - 1)))
    out.gamblePapers = used
  end
  return out
end

local function profileOf(pid)
  local s = sessions.get(pid)
  return s and s.stage == "loaded" and s.profile or nil, s
end

local function mine(pid)
  local s = sessions.get(pid)
  local list = {}
  for _, rec in pairs(theft.records()) do
    if s and rec.by == s.accountId then list[#list + 1] = rec end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  return list
end

local function atSpot(pid)
  local now = util.now()
  local spot = market.spotAt(now)
  if not spot then return false, "No drop spots are set up on this server." end
  if positions.isChased(pid) then return false, "Lose the police first." end
  local pos = positions.get(pid)
  if not pos or now - pos.t > num(cfg.market.positionMaxAge, 20) then
    return false, "The server has no fresh position from you yet. Wait a few seconds and try again."
  end
  local dx, dy = pos.x - spot.x, pos.y - spot.y
  if math.sqrt(dx * dx + dy * dy) > num(cfg.market.pickupRadius, 20) then
    return false, "The fence works at " .. spot.name .. " right now. Bring the car there."
  end
  return true
end

local function repFor(mode) return math.floor(num(c().rep and c().rep[mode], 0)) end

-- Do one sale. Returns the result table (also what the client gets). Everything is checked here.
function M.sell(pid, plate, mode, opts)
  local function fail(err) return {ok = false, mode = mode, err = err} end
  if not enabled() then return fail("The fence is closed.") end
  local profile, s = profileOf(pid)
  if not profile then return fail("Not in career.") end
  if not market.isMember(pid) then return fail("The fence only deals with black market members.") end
  if type(plate) ~= "string" or not theft.cleanPlate(plate) then return fail("Unknown car.") end
  plate = theft.cleanPlate(plate)
  local known = false
  for _, m in ipairs(M.MODES) do if m == mode then known = true end end
  if not known then return fail("Unknown way to sell. Use strip, sell, resell or gamble.") end
  local rec = theft.records()[plate]
  if not rec or rec.by ~= s.accountId then return fail("That car is not on your list.") end
  if opts and opts.garage then
    if positions.isChased(pid) then return fail("Lose the police first.") end
  else
    local ok, why = atSpot(pid)
    if not ok then return fail(why) end
  end
  local ledger = profile.ledger
  if not ledger.seeded then return fail("Wait for your first save, then try again.") end
  if busy[pid] then return fail("One at a time.") end

  local value = valueOf(rec)
  local q = M.quotes(pid, value, rec)
  local pay, taken, busted = q[mode], {}, false
  if mode == "resell" and not pay then
    local missing = {}
    for _, name in ipairs(PAPERS) do if not fitted(rec, name) and not items.has(pid, name) then missing[#missing + 1] = itemLabel(name) end end
    return fail("To resell you need: " .. table.concat(missing, ", ") .. ".")
  end
  if mode == "gamble" and not pay then return fail("To gamble you need at least one of: fake plate, VIN plate, part number.") end
  if pay <= 0 then return fail("The fence is not interested in that car.") end

  -- papers this sale uses up
  local use = {}      -- papers still to take from the player's items (fitted ones were used up when fitted)
  if mode == "resell" then
    for _, name in ipairs(PAPERS) do if not fitted(rec, name) then use[#use + 1] = name end end
  elseif mode == "gamble" then
    local have = papersOwned(pid, rec)
    for i = 1, q.gamblePapers do if not fitted(rec, have[i]) then use[#use + 1] = have[i] end end
  end
  if mode == "gamble" and random() < clamp(num(c().gambleBust, 0.30), 0, 1) then busted, pay = true, 0 end

  busy[pid] = true
  local saved = {}
  for _, name in ipairs(use) do saved[name] = items.count(pid, name) end
  local before = ledger.money
  theft.take(plate)
  ledger.money = ledger.money + pay
  profile.items = profile.items or {}
  for _, name in ipairs(use) do                 -- taken by hand so wallet and papers go to disk in ONE save below
    local have = tonumber(profile.items[name]) or 0
    if have > 0 then
      profile.items[name] = have > 1 and have - 1 or nil
      taken[#taken + 1] = name
    end
  end
  local persisted = profiles.persist(profile)
  if not persisted then
    ledger.money = before
    theft.put(rec)
    for name, n in pairs(saved) do profile.items[name] = n > 0 and n or nil end
    busy[pid] = nil
    return fail("The server could not save. Nothing was sold.")
  end
  busy[pid] = nil
  theft.save()
  if pay > 0 then net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "fence"}) end

  local result = {ok = true, mode = mode, pay = pay, busted = busted, takeCar = true}
  if busted then
    market.bust(pid, {})
    result.ok = false
    result.err = "The buyer was a trap. The police have the car."
  else
    local rep = repFor(mode)
    if rep > 0 then market.addRep(pid, rep, "fence") end
  end
  util.info(string.format("[fence] %s %s %s (%s, value %d) -> %s%s", tostring(s.name), mode, plate, tostring(rec.model), value,
    dollars(pay), busted and ", BUSTED" or ""))
  return result
end

-- Garage flow -----------------------------------------------------------------------------------------------

local lastAsk, lastStrip = {}, {}     -- pid -> util.now()

local function garageOn() return cfg ~= nil and c().enabled == true and c().garage ~= false end
local function short(v, n) return tostring(v or ""):sub(1, n or 40) end

-- Works out what the car in a request is: "stolen" (our own theft record, value from the server) or "owned" (client's word, capped).
local function garageTarget(pid, d)
  local s = sessions.get(pid)
  local plate = type(d.plate) == "string" and theft.cleanPlate(d.plate) or nil
  local rec = plate and theft.records()[plate]
  if rec then
    if not s or rec.by ~= s.accountId then return nil, "That plate is on somebody else's stolen car." end
    return {kind = "stolen", plate = plate, rec = rec, value = valueOf(rec), model = short(rec.model)}
  end
  local value = clamp(math.floor(num(d.value, 0)), 0, math.floor(num(c().maxValue, 300000)))
  return {kind = "owned", plate = plate, value = value, model = short(d.model)}
end

local function onGarageQuote(pid, d)
  if type(d) ~= "table" or not sessions.isLoaded(pid) then return end
  local now = util.now()
  if lastAsk[pid] and now - lastAsk[pid] < 1 then return end
  lastAsk[pid] = now
  local menu = {ok = true, items = items.list(pid)}
  if not garageOn() then
    menu.ok, menu.err = false, "The garage strip is closed on this server."
  elseif d.plate ~= nil or d.value ~= nil then       -- a car was named (otherwise: just the item list)
    local t, err = garageTarget(pid, d)
    if not t then
      menu.ok, menu.err = false, err
    elseif t.kind == "stolen" and not (enabled() and market.isMember(pid)) then
      menu.ok, menu.err = false, "The fence only deals with black market members."
    else
      menu.kind, menu.plate, menu.model = t.kind, t.plate, t.model
      menu.strip = math.floor(t.value * num(c().stripRate, 0.30))
      menu.fit, menu.fitted = {}, {}
      if t.kind == "stolen" then
        for _, name in ipairs(PAPERS) do
          if fitted(t.rec, name) then menu.fitted[#menu.fitted + 1] = itemLabel(name)
          elseif items.has(pid, name) then menu.fit[#menu.fit + 1] = {name = name, label = itemLabel(name)} end
        end
      end
    end
  end
  net.send(pid, "rlsmpGarageMenu", menu)
end

-- Strip a car that is NOT on the stolen list (an ordinary garage car). The value is the client's word, so it is capped and rate limited.
local function stripOwned(pid, t, d)
  local function fail(err) return {ok = false, action = "strip", err = err} end
  local profile, s = profileOf(pid)
  if not profile then return fail("Not in career.") end
  local ledger = profile.ledger
  if not ledger.seeded then return fail("Wait for your first save, then try again.") end
  local now = util.now()
  if lastStrip[pid] and now - lastStrip[pid] < num(c().garageCooldown, 20) then return fail("Slow down a moment.") end
  if busy[pid] then return fail("One at a time.") end
  local value = t.value > 0 and t.value or math.floor(num(c().minValue, 2000))
  local pay = math.floor(value * num(c().stripRate, 0.30))
  if pay <= 0 then return fail("Nothing to pay for that car.") end
  local before = ledger.money
  busy[pid] = true
  ledger.money = before + pay
  if not profiles.persist(profile) then
    ledger.money = before
    busy[pid] = nil
    return fail("The server could not save. Nothing was stripped.")
  end
  busy[pid] = nil
  lastStrip[pid] = now
  net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "fence"})
  util.info(string.format("[fence] %s stripped own car %s (%s, value %d) -> %s", tostring(s.name), tostring(t.plate), t.model, value, dollars(pay)))
  return {ok = true, action = "strip", pay = pay, takeCar = true, inventoryId = tonumber(d.inventoryId)}
end

-- Fit one paper to a stolen car: the item is used up now, the record remembers it.
local function fitPaper(pid, t, name)
  local function fail(err) return {ok = false, action = "fit:" .. tostring(name), err = err} end
  local known = false
  for _, p in ipairs(PAPERS) do if p == name then known = true end end
  if not known then return fail("Unknown part.") end
  if t.kind ~= "stolen" then return fail("Only stolen cars need illegal parts.") end
  if fitted(t.rec, name) then return fail("Already fitted.") end
  if not items.take(pid, name, 1) then return fail("You do not have a " .. itemLabel(name) .. ".") end
  t.rec.papers = t.rec.papers or {}
  t.rec.papers[name] = true
  theft.save()
  local s = sessions.get(pid)
  util.info(string.format("[fence] %s fitted %s to %s", tostring(s and s.name), name, tostring(t.plate)))
  return {ok = true, action = "fit:" .. name, fitted = itemLabel(name)}
end

function M.garageDo(pid, d)
  if type(d) ~= "table" or type(d.action) ~= "string" then return {ok = false, err = "Bad request."} end
  if not garageOn() then return {ok = false, action = d.action, err = "The garage strip is closed on this server."} end
  if not sessions.isLoaded(pid) then return {ok = false, action = d.action, err = "Not in career."} end
  local t, err = garageTarget(pid, d)
  if not t then return {ok = false, action = d.action, err = err} end
  if t.kind == "stolen" and not (enabled() and market.isMember(pid)) then
    return {ok = false, action = d.action, err = "The fence only deals with black market members."}
  end
  if d.action == "strip" then
    if t.kind == "stolen" then
      local r = M.sell(pid, t.plate, "strip", {garage = true})
      r.action = "strip"
      return r
    end
    return stripOwned(pid, t, d)
  end
  local name = d.action:match("^fit:(%a[%w_]*)$")
  if name then return fitPaper(pid, t, name) end
  return {ok = false, action = d.action, err = "Unknown action."}
end

local function onGarageDo(pid, d)
  local r = M.garageDo(pid, d)
  if r.ok and type(d) == "table" and r.inventoryId == nil then r.inventoryId = tonumber(d.inventoryId) end
  net.send(pid, "rlsmpGarageResult", r)
  if r.ok and r.action == "strip" then say(pid, string.format("Stripped: %s paid.", dollars(r.pay))) end
end

-- Chat ----------------------------------------------------------------------------------------------

local function list(pid)
  local recs = mine(pid)
  if #recs == 0 then return say(pid, "You have no stolen cars to sell.") end
  for _, rec in ipairs(recs) do
    local q = M.quotes(pid, valueOf(rec))
    local parts = {string.format("strip %s", dollars(q.strip)), string.format("sell %s", dollars(q.sell))}
    parts[#parts + 1] = q.resell and string.format("resell %s", dollars(q.resell)) or "resell (needs fake plate + VIN plate + part number)"
    parts[#parts + 1] = q.gamble and string.format("gamble %s (%d%% trap)", dollars(q.gamble), math.floor(num(c().gambleBust, 0.30) * 100 + 0.5))
      or "gamble (needs a paper)"
    say(pid, string.format("%s %s: %s", tostring(rec.model), rec.plate, table.concat(parts, ", ")))
  end
  local spot = market.spotAt(util.now())
  say(pid, "Bring the car to " .. (spot and spot.name or "the drop spot") .. ", get out, and type /fence strip | sell | resell | gamble.")
end

local function onChat(pid, rest)
  if not enabled() then return say(pid, "The fence is closed on this server (car theft is off).") end
  if not sessions.isLoaded(pid) then return end
  if not market.isMember(pid) then return say(pid, "The fence only deals with black market members.") end
  local mode = tostring(rest or ""):lower():match("^(%S*)")
  if mode == "" or mode == "list" then return list(pid) end
  net.send(pid, "rlsmpFenceAsk", {mode = mode})
end

local function onSell(pid, d)
  if type(d) ~= "table" then return end
  local result = M.sell(pid, d.plate, type(d.mode) == "string" and d.mode or "")
  net.send(pid, "rlsmpFenceResult", result)
  if result.ok then
    say(pid, string.format("Done: %s paid for the %s.", dollars(result.pay), result.mode))
  elseif result.err then
    say(pid, result.err)
  end
end

function M.init(config)
  cfg = config
  busy = {}
  net.onChat("fence", onChat)
  net.onClient("rlsmpFenceSell", onSell)
  lastAsk, lastStrip = {}, {}
  net.onClient("rlsmpGarageQuote", onGarageQuote)
  net.onClient("rlsmpGarageDo", onGarageDo)
end

return M
