-- RLS-Career-MP server: meetup selling. A sale is finished by driving to a spot the SERVER picks and doing a drop-off there.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Two kinds: "market" (RLS Marketplace sale; the client holds the sale back, we only choose the spot, roll the setup and
-- say when it may finish) and "black" (a stolen car sold to the fence; the server pays like fence.lua, with market.fenceQuote).
-- A fully legal car NEVER gets a police setup. A stolen car, a plate flagged by the police, or a black market car rolls one
-- (config meetup.illegalChance / blackChance, kept between minChance and maxChance so nobody is ever sure). The roll is made when
-- the meetup is created and kept secret until the player arrives. A setup is 1 to 2 police (no roadblocks); the sale does not
-- happen then and the player keeps the car.
--
-- Flow: client rlsmpMeetupRequest {kind, inv, plate, model, price} -> server rlsmpMeetupSet {id, kind, spot, x, y, z, radius, expiresIn}
--       or rlsmpMeetupDenied {err}. Client drives there, stops: rlsmpMeetupArrive {id} -> rlsmpMeetupResult {id, ok, kind, setup, cops, pay, takeCar, err}.
--       rlsmpMeetupCancel {}; hidden developer chat /meetup [black|cancel|status] (the server asks the client with rlsmpMeetupAsk {kind}).

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local positions = require("rlsmp.server.positions")
local market = require("rlsmp.server.market")
local theft = require("rlsmp.server.theft")

local M = {}

local cfg
local open = {}        -- pid -> meetup {id, accountId, kind, inv, plate, model, price, spot, setup, cops, expires}
local cooldown = {}    -- accountId -> time before which no new meetup starts
local lastSpot = {}    -- accountId -> name of the last spot given
local nextId = 0

local random = math.random
function M.setRandom(fn) random = fn or math.random end

local function c() return cfg.meetup end
local function num(v, d)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return d end
  return v
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function say(pid, text) MP.SendChatMessage(pid, "[Meetup] " .. text) end
local function enabled() return cfg ~= nil and c().enabled == true end

local function spotList()
  local src = type(c().spots) == "table" and #c().spots > 0 and c().spots or cfg.market.dropSpots
  local out = {}
  for _, sp in ipairs(type(src) == "table" and src or {}) do
    if type(sp) == "table" and type(sp.name) == "string" and tonumber(sp.x) and tonumber(sp.y) and tonumber(sp.z) then
      out[#out + 1] = {name = sp.name, x = tonumber(sp.x), y = tonumber(sp.y), z = tonumber(sp.z)}
    end
  end
  return out
end

-- A spot for this player: never the last one they got, and (when possible) not near where they stand.
function M.pickSpot(accountId, pos)
  local all = spotList()
  local pool = {}
  for _, sp in ipairs(all) do if sp.name ~= lastSpot[accountId] then pool[#pool + 1] = sp end end
  if #pool == 0 then pool = all end
  if pos then
    local far = {}
    for _, sp in ipairs(pool) do
      if math.sqrt((sp.x - pos.x) ^ 2 + (sp.y - pos.y) ^ 2) >= num(c().minDistance, 300) then far[#far + 1] = sp end
    end
    if #far > 0 then pool = far end
  end
  if #pool == 0 then return nil end
  return pool[math.floor(random() * #pool) % #pool + 1]
end

-- The chance of a setup. Legal = exactly 0. Otherwise inside [minChance, maxChance].
function M.setupChance(kind, illegal)
  if not illegal then return 0 end
  local base = kind == "black" and num(c().blackChance, 0.45) or num(c().illegalChance, 0.35)
  return clamp(base, clamp(num(c().minChance, 0.05), 0.01, 0.99), clamp(num(c().maxChance, 0.85), 0.01, 0.99))
end

-- Stolen (any theft record on the plate), wearing a fake plate (illegal papers, server/fakePlates.lua) or flagged by the police.
local function isIllegal(plate, model, pid)
  if plate and theft.records()[plate] then return true end
  local okF, fp = pcall(require, "rlsmp.server.fakePlates")
  if okF and type(fp) == "table" and pid and plate and fp.wears(pid, plate) then return true end
  local ok, pr = pcall(require, "rlsmp.server.plateRecords")
  if ok and type(pr) == "table" and pr.lookup and plate and model then
    local r = pr.lookup(plate, model, nil, false)
    return r and r.flagged == true or false
  end
  return false
end

local function current(pid)
  local s = sessions.get(pid)
  local m = open[pid]
  if m and (not s or s.accountId ~= m.accountId or util.now() >= m.expires) then
    open[pid] = nil
    if s then net.send(pid, "rlsmpMeetupClear", {id = m.id}) end
    return nil
  end
  return m
end

local function sendSet(pid, m)
  net.send(pid, "rlsmpMeetupSet", {id = m.id, kind = m.kind, spot = m.spot.name, x = m.spot.x, y = m.spot.y, z = m.spot.z,
    radius = num(c().radius, 15), expiresIn = math.max(1, math.floor(m.expires - util.now()))})
end

local function deny(pid, err)
  net.send(pid, "rlsmpMeetupDenied", {err = err})
  say(pid, err)
end

function M.request(pid, d)
  if not enabled() then return deny(pid, "Meetup selling is off. Sell the usual way.") end
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then return end
  local m = current(pid)
  if m then
    sendSet(pid, m)
    return say(pid, "You already have a meetup at " .. m.spot.name .. ". Drop it in the Black Market app if you do not want it.")
  end
  local now = util.now()
  local wait = (cooldown[s.accountId] or 0) - now
  if wait > 0 then return deny(pid, string.format("No buyer right now. Try again in %d s.", math.ceil(wait))) end
  if positions.isChased(pid) then return deny(pid, "Lose the police first.") end
  local kind = d.kind == "black" and "black" or "market"
  local plate = theft.cleanPlate(d.plate)
  local model = type(d.model) == "string" and d.model:sub(1, 40) or nil
  m = {accountId = s.accountId, kind = kind, inv = math.floor(num(d.inv, -1)), plate = plate, model = model,
    price = math.max(0, num(d.price, 0))}
  if kind == "black" then
    if not market.isMember(pid) then return deny(pid, "The black market only deals with members.") end
    local rec = plate and theft.records()[plate]
    if not theft.isEnabled() or not rec or rec.by ~= s.accountId then return deny(pid, "That car is not on your stolen list.") end
  end
  local illegal = kind == "black" or isIllegal(plate, model, pid)
  m.setup = random() < M.setupChance(kind, illegal)
  local lo, hi = clamp(math.floor(num(c().copsMin, 1)), 1, 2), clamp(math.floor(num(c().copsMax, 2)), 1, 2)
  m.cops = clamp(lo + math.floor(random() * (math.max(lo, hi) - lo + 1)), 1, 2)
  m.spot = M.pickSpot(s.accountId, positions.get(pid))
  if not m.spot then return deny(pid, "No meetup spots are set up on this server.") end
  nextId = nextId + 1
  m.id = "m" .. nextId
  m.expires = now + math.max(60, num(c().expireMinutes, 20) * 60)
  lastSpot[s.accountId] = m.spot.name
  open[pid] = m
  util.info(string.format("[meetup] %s %s %s -> %s (illegal=%s)", tostring(s.name), kind, tostring(plate), m.spot.name, tostring(illegal)))
  sendSet(pid, m)
  say(pid, "A buyer will meet you at " .. m.spot.name .. ". Follow the route and stop at the marker.")
end

local function finish(pid, m, wait)
  open[pid] = nil
  cooldown[m.accountId] = util.now() + wait
end

-- The black market pays here, in one profile save (same idea as fence.lua).
local function payBlack(pid, s, m)
  local rec = m.plate and theft.records()[m.plate]
  if not rec or rec.by ~= s.accountId then return nil, "That car is not on your stolen list any more." end
  local value = math.floor(num(rec.value, 0))
  if value <= 0 then value = math.floor(num(cfg.fence.minValue, 2000)) end
  value = clamp(value, 0, math.floor(num(cfg.fence.maxValue, 300000)))
  local pay = math.floor(market.fenceQuote(value))
  local ledger = s.profile.ledger
  if not ledger.seeded then return nil, "Wait for your first save, then try again." end
  local before = ledger.money
  theft.take(m.plate)
  ledger.money = before + pay
  if not profiles.persist(s.profile) then
    ledger.money = before
    theft.put(rec)
    return nil, "The server could not save. Nothing was sold."
  end
  theft.save()
  net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "meetup"})
  return pay
end

function M.arrive(pid, d)
  local s = sessions.get(pid)
  local m = current(pid)
  local function res(t) t.id = d.id net.send(pid, "rlsmpMeetupResult", t) end
  if not s or not m or d.id ~= m.id then return res({ok = false, err = "No meetup is open."}) end
  local pos = positions.get(pid)
  if not pos or util.now() - pos.t > num(cfg.market.positionMaxAge, 20) then
    return res({ok = false, retry = true, err = "The server has no fresh position from you yet."})
  end
  if math.sqrt((pos.x - m.spot.x) ^ 2 + (pos.y - m.spot.y) ^ 2) > num(c().serverRadius, 30) then
    return res({ok = false, retry = true, err = "You are not at the meetup spot."})
  end
  if positions.isChased(pid) then return res({ok = false, retry = true, err = "Lose the police first."}) end
  if m.setup then
    finish(pid, m, num(c().cooldownSeconds, 300))
    util.info(string.format("[meetup] %s was set up at %s (%d cops)", tostring(s.name), m.spot.name, m.cops))
    return res({ok = false, setup = true, kind = m.kind, cops = m.cops})
  end
  if m.kind == "black" then
    local pay, err = payBlack(pid, s, m)
    if not pay then return res({ok = false, kind = "black", err = err}) end
    finish(pid, m, num(c().cooldownSeconds, 300))
    util.info(string.format("[meetup] %s sold stolen %s at %s for %d", tostring(s.name), tostring(m.plate), m.spot.name, pay))
    return res({ok = true, kind = "black", pay = pay, takeCar = true})
  end
  finish(pid, m, num(c().cooldownSeconds, 300))
  util.info(string.format("[meetup] %s finished a Marketplace sale at %s", tostring(s.name), m.spot.name))
  res({ok = true, kind = "market", inv = m.inv})
end

function M.cancel(pid)
  local s = sessions.get(pid)
  local m = current(pid)
  if not m then return say(pid, "You have no meetup open.") end
  finish(pid, m, num(c().cancelCooldownSeconds, 60))
  net.send(pid, "rlsmpMeetupClear", {id = m.id})
  say(pid, "Meetup dropped. The sale stays open; a new buyer needs a moment.")
  if s then util.info("[meetup] " .. tostring(s.name) .. " cancelled") end
end

function M.openOf(pid) return current(pid) end

local function onChat(pid, rest)
  if not enabled() then return say(pid, "Meetup selling is off on this server.") end
  if not sessions.isLoaded(pid) then return end
  local word = tostring(rest or ""):lower():match("^(%S*)")
  if word == "cancel" then return M.cancel(pid) end
  if word == "status" then
    local m = current(pid)
    return say(pid, m and ("Meetup at " .. m.spot.name .. ".") or "No meetup open.")
  end
  if word == "black" then return net.send(pid, "rlsmpMeetupAsk", {kind = "black"}) end
  net.send(pid, "rlsmpMeetupAsk", {kind = "market"})
end

function M.init(config)
  cfg = config
  open, cooldown, lastSpot, nextId = {}, {}, {}, 0
  net.onChat("meetup", onChat, true)
  net.onClient("rlsmpMeetupRequest", M.request)
  net.onClient("rlsmpMeetupArrive", M.arrive)
  net.onClient("rlsmpMeetupCancel", function(pid) M.cancel(pid) end)
end

return M
