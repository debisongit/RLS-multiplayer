-- RLS-Career-MP server: the fence. Sells or strips a stolen car at the black market's active drop spot (needs car theft on).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Ways to sell: strip (parts for cash, no papers, pays least, safe), sell (as it is, a bit more), resell (fake plate + VIN plate + part number
-- first, all three used up, pays most, safe). (There is no gamble any more: removed at the owner's request.)
-- Players use the Black Market phone app (stolen cars section: every car has Strip, Sell, Resell and the illegal parts buttons, no drop spot needed)
-- or the garage computer buttons (client rlsmp/garage.lua); the chat command
-- /fence <mode> is a hidden developer fallback (only with config ui.chatCommands).
-- A sale needs: black market member, theft record of the player's own, standing within market.pickupRadius of the ACTIVE drop spot
-- (fresh position report), not being chased. The server owns the money and the record; the client only names the car (its plate)
-- and deletes it afterwards when the answer says so.
--
-- GARAGE FLOW (the main way, no drop spot needed): the player opens the RLS garage computer and taps "Strip / illegal parts" on a car
-- (client rlsmp/garage.lua). It asks what is possible, shows a dialog, then asks to do one thing:
--   client rlsmpGarageQuote {plate, model, value, year} -> server rlsmpGarageMenu {ok, kind, plate, strip, fit = [...], items = [...]}
--   client rlsmpGarageDo {action, plate, model, value, year} -> server rlsmpGarageResult {ok, action, pay?, takeCar?, fitted?, err?}
--   action = "strip" | "sell" | "resell" | "fit:fake_plate" | "fit:vin_plate" | "fit:part_number". Fitting uses up the item at once and marks the stolen car's
--   record (rec.papers); resell then counts fitted papers first. The garage menu also carries sell/resell prices (null = missing papers).
--   The phone app sends the same rlsmpGarageDo with `phone = true` (refused when fence.phone is false). Strip of a STOLEN car (needs market membership) and
--   an OWNED car (value comes from the client, capped by fence.maxValue, one per fence.garageCooldown seconds) pays stripRate x value.
-- Flow at the drop spot (phone app button or chat fallback): rlsmpFenceAsk {mode} -> (the client finds the stolen car next to the player)
--       client              -> rlsmpFenceSell {plate, mode}
--       server              -> rlsmpFenceResult {ok, mode, pay, takeCar, err}
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
M.MODES = {"strip", "sell", "resell"}

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
  local lo, hi = math.floor(num(c().minValue, 2000)), math.floor(num(c().maxValue, 300000))
  return clamp(v, math.min(lo, hi), hi)      -- never below minValue (also when the game had no price: 0), never above maxValue
end

-- How many papers (of the three) a player has.
local function fitted(rec, name) return rec ~= nil and type(rec.papers) == "table" and rec.papers[name] == true end
local function papersOwned(pid, rec)       -- papers already fitted to the car count as owned
  local have = {}
  for _, name in ipairs(PAPERS) do if fitted(rec, name) or items.has(pid, name) then have[#have + 1] = name end end
  return have
end

-- The price list for a car value and a player's papers: {strip = n, sell = n, resell = n or nil (missing papers)}.
function M.quotes(pid, value, rec)
  value = clamp(math.floor(num(value, 0)), 0, math.floor(num(c().maxValue, 300000)))
  local out = {
    strip = math.floor(value * num(c().stripRate, 0.45) * (rec and theft.stripFactor(rec) or 1)),
    sell = market.fenceQuote(value),
  }
  local have = pid and papersOwned(pid, rec) or {}
  if #have == 3 then out.resell = math.floor(value * num(c().resellRate, 0.70)) end
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
  if not known then return fail("Unknown way to sell. Use strip, sell or resell.") end
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

  if mode ~= "strip" then
    local why = theft.sellBlock(rec)
    if why then return fail(why) end
  end
  if theft.fresh and not theft.fresh(pid, rec) then return fail("Checking today's market price. Try again in a few seconds.") end
  local value = valueOf(rec)
  local q = M.quotes(pid, value, rec)
  local pay, taken = q[mode], {}
  if mode == "resell" and not pay then
    local missing = {}
    for _, name in ipairs(PAPERS) do if not fitted(rec, name) and not items.has(pid, name) then missing[#missing + 1] = itemLabel(name) end end
    return fail("To resell you need: " .. table.concat(missing, ", ") .. " (order them in the Black Market app).")
  end
  if pay <= 0 then return fail("The fence is not interested in that car.") end

  -- papers this sale uses up
  local use = {}      -- papers still to take from the player's items (fitted ones were used up when fitted)
  if mode == "resell" then
    for _, name in ipairs(PAPERS) do if not fitted(rec, name) then use[#use + 1] = name end end
  end

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

  local result = {ok = true, mode = mode, pay = pay, takeCar = true}
  local rep = repFor(mode)
  if rep > 0 then market.addRep(pid, rep, "fence") end
  util.info(string.format("[fence] %s %s %s (%s, value %d) -> %s", tostring(s.name), mode, plate, tostring(rec.model), value, dollars(pay)))
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
  if theft.repriceAsk then theft.repriceAsk(pid) end      -- the quote below uses the stored value; a fresher one is on its way
  if d.plate ~= nil then theft.noteDamage(pid, d.plate, d.damage) end
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
      menu.strip = math.floor(t.value * num(c().stripRate, 0.45) * (t.rec and theft.stripFactor(t.rec) or 1))
      menu.fit, menu.fitted = {}, {}
      if t.kind == "stolen" then
        local q = M.quotes(pid, t.value, t.rec)
        menu.sell, menu.resell = math.floor(q.sell), q.resell
        menu.damage = t.rec.damage
        menu.sellWhy = theft.sellBlock(t.rec)
        menu.canSell = menu.sellWhy == nil
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
  local pay = math.floor(value * num(c().stripRate, 0.45))
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
  if d.phone == true and c().phone == false then return {ok = false, action = d.action, err = "Selling from the phone is switched off on this server."} end
  if d.plate ~= nil then theft.noteDamage(pid, d.plate, d.damage) end
  local t, err = garageTarget(pid, d)
  if not t then return {ok = false, action = d.action, err = err} end
  if t.kind == "stolen" and not (enabled() and market.isMember(pid)) then
    return {ok = false, action = d.action, err = "The fence only deals with black market members."}
  end
  if d.action == "strip" and t.kind ~= "stolen" then return stripOwned(pid, t, d) end
  for _, mode in ipairs(M.MODES) do
    if d.action == mode then
      if t.kind ~= "stolen" then return {ok = false, action = d.action, err = "That is for stolen cars."} end
      local r = M.sell(pid, t.plate, mode, {garage = true})
      r.action = mode
      return r
    end
  end
  local name = d.action:match("^fit:(%a[%w_]*)$")
  if name then return fitPaper(pid, t, name) end
  return {ok = false, action = d.action, err = "Unknown action."}
end

local function onGarageDo(pid, d)
  local r = M.garageDo(pid, d)
  if r.ok and type(d) == "table" and r.inventoryId == nil then r.inventoryId = tonumber(d.inventoryId) end
  net.send(pid, "rlsmpGarageResult", r)
  if r.ok and r.pay then say(pid, string.format("Done (%s): %s paid.", tostring(r.action), dollars(r.pay))) end
end

-- Chat ----------------------------------------------------------------------------------------------

local function list(pid)
  local recs = mine(pid)
  if #recs == 0 then return say(pid, "You have no stolen cars to sell.") end
  for _, rec in ipairs(recs) do
    local q = M.quotes(pid, valueOf(rec))
    local parts = {string.format("strip %s", dollars(q.strip)), string.format("sell %s", dollars(q.sell))}
    parts[#parts + 1] = q.resell and string.format("resell %s", dollars(q.resell)) or "resell (needs fake plate + VIN plate + part number)"
    say(pid, string.format("%s %s: %s", tostring(rec.model), rec.plate, table.concat(parts, ", ")))
  end
  local spot = market.spotAt(util.now())
  say(pid, "Bring the car to " .. (spot and spot.name or "the drop spot") .. " and use the Black Market app, or sell at the garage computer.")
end

-- For the Black Market phone app: the player's stolen cars with what each way pays (nil = missing papers), and the illegal parts that can be fitted
-- (`fit` = the ones the player owns and the car lacks, `fitted` = labels of the ones already on it). `phone` tells the app whether the buttons work.
local function paperLists(pid, rec)
  local fit, on = {}, {}
  for _, name in ipairs(PAPERS) do
    if fitted(rec, name) then on[#on + 1] = itemLabel(name)
    elseif items.has(pid, name) then fit[#fit + 1] = {name = name, label = itemLabel(name)} end
  end
  return fit, on
end

function M.summary(pid)
  local out = {}
  if not enabled() then return out end
  if theft.repriceAsk then theft.repriceAsk(pid) end
  for _, rec in ipairs(mine(pid)) do
    local q = M.quotes(pid, valueOf(rec), rec)
    local old = tonumber(rec.prevValue)
    local fit, on = paperLists(pid, rec)
    local why = theft.sellBlock(rec)
    out[#out + 1] = {plate = rec.plate, model = rec.model, strip = q.strip, sell = q.sell, resell = q.resell, fit = fit, fitted = on,
      damage = rec.damage, canSell = why == nil, why = why,
      age = rec.vt and math.max(0, util.now() - rec.vt) or nil,       -- seconds since the price was last worked out
      trend = old and (valueOf(rec) > old and 1 or (valueOf(rec) < old and -1 or 0)) or 0}
  end
  return out
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
  theft.noteDamage(pid, d.plate, d.damage)
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
  net.onChat("fence", onChat, true)
  net.onClient("rlsmpFenceSell", onSell)
  lastAsk, lastStrip = {}, {}
  net.onClient("rlsmpGarageQuote", onGarageQuote)
  net.onClient("rlsmpGarageDo", onGarageDo)
end

return M
