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
-- Flow: chat /fence <mode>  -> rlsmpFenceAsk {mode}          (the client finds the stolen car next to the player)
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
local function papersOwned(pid)
  local have = {}
  for _, name in ipairs(PAPERS) do if items.has(pid, name) then have[#have + 1] = name end end
  return have
end

-- The price list for a car value and a player's papers: {strip = n, sell = n, resell = n or nil (missing papers), gamble = n or nil}.
function M.quotes(pid, value)
  value = clamp(math.floor(num(value, 0)), 0, math.floor(num(c().maxValue, 300000)))
  local out = {
    strip = math.floor(value * num(c().stripRate, 0.30)),
    sell = market.fenceQuote(value),
  }
  local have = pid and papersOwned(pid) or {}
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
function M.sell(pid, plate, mode)
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
  local ok, why = atSpot(pid)
  if not ok then return fail(why) end
  local ledger = profile.ledger
  if not ledger.seeded then return fail("Wait for your first save, then try again.") end
  if busy[pid] then return fail("One at a time.") end

  local value = valueOf(rec)
  local q = M.quotes(pid, value)
  local pay, taken, busted = q[mode], {}, false
  if mode == "resell" and not pay then
    local missing = {}
    for _, name in ipairs(PAPERS) do if not items.has(pid, name) then missing[#missing + 1] = itemLabel(name) end end
    return fail("To resell you need: " .. table.concat(missing, ", ") .. ".")
  end
  if mode == "gamble" and not pay then return fail("To gamble you need at least one of: fake plate, VIN plate, part number.") end
  if pay <= 0 then return fail("The fence is not interested in that car.") end

  -- papers this sale uses up
  local use = {}
  if mode == "resell" then use = PAPERS
  elseif mode == "gamble" then
    local have = papersOwned(pid)
    for i = 1, q.gamblePapers do use[#use + 1] = have[i] end
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
end

return M
