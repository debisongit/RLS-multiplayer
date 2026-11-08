-- RLS-Career-MP server: fake plates on the player's OWN cars.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A fake_plate item (server/items.lua) can be fitted to a garage car in the garage computer. The server picks the plate text (a few random
-- choices per player), uses up the item and keeps in the player's profile which car wears which fake plate and what the real plate was:
--   profile.fakePlates[FAKE] = {fake, real, inv, model, t}      (keyed by the fake plate text; inv = RLS inventory id, only a hint)
-- The police records (plateRecords.lua) are keyed by the plate text that is on the car, so the fake plate has its own (clean) record and the
-- real plate's flag is left alone while it is off the car. Radar and fine rules live in the client (police.lua, rlsmp/fakePlate.lua).
--   client rlsmpFakeAsk {}                       -> server rlsmpFakeState {list, have, enabled, choices?}   (choices = 3 fresh plate texts)
--   client rlsmpFakeFit {inv, idx, real, model}  -> server rlsmpFakeResult {ok, action = "fit", fake, real, inv} | {ok = false, err}
--   client rlsmpFakeRestore {fake, failed?}      -> server rlsmpFakeResult {ok, action = "restore", fake, real, inv}
--        failed = true: the game could not put the plate on (the item comes back when the fit was < 60 s ago)
--   client rlsmpFakeDrop {fake}                  the player changed the plate another way (RLS plate shop) or the car is gone: forget the record
--   server rlsmpFakeState also arrives once per session after loading.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local positions = require("rlsmp.server.positions")
local items = require("rlsmp.server.items")

local M = {}

local cfg
local told = {}        -- pid -> session table we already pushed the state to
local offers = {}      -- pid -> {plate, plate, plate}
local lastAct = {}     -- pid -> time of the last accepted request

local random = math.random
function M.setRandom(fn) random = fn or math.random end

local function fcfg() return type(cfg.fakePlates) == "table" and cfg.fakePlates or {} end
local function enabled() return cfg ~= nil and fcfg().enabled ~= false end
local function num(v, d) v = tonumber(v) return (v and v == v and v < math.huge and v > -math.huge) and v or d end

local function profileOf(pid)
  local s = sessions.get(pid)
  return s and s.stage == "loaded" and s.profile or nil
end
local function recordsOf(pid)
  local p = profileOf(pid)
  if not p then return nil end
  if type(p.fakePlates) ~= "table" then p.fakePlates = {} end
  return p.fakePlates
end

-- Plate texts: digit + 3 letters + 3 digits ("7KTB482"), no I, O, Q. RLS allows 1 to 10 characters.
local LETTERS = "ABCDEFGHJKLMNPRSTUVWXYZ"
function M.generate()
  local out = {tostring(random(1, 9))}
  for _ = 1, 3 do local i = random(1, #LETTERS) out[#out + 1] = LETTERS:sub(i, i) end
  for _ = 1, 3 do out[#out + 1] = tostring(random(0, 9)) end
  return table.concat(out)
end

local function taken(plate)
  for pid in pairs(sessions.all()) do
    for fake, r in pairs(recordsOf(pid) or {}) do if fake == plate or r.real == plate then return true end end
  end
  local ok, theft = pcall(require, "rlsmp.server.theft")
  return ok and type(theft) == "table" and theft.records and theft.records()[plate] ~= nil or false
end

local function choices()
  local list, tries = {}, 0
  while #list < 3 and tries < 50 do
    tries = tries + 1
    local p = M.generate()
    local dup = false
    for _, q in ipairs(list) do if q == p then dup = true end end
    if not dup and not taken(p) then list[#list + 1] = p end
  end
  return list
end

local function listOf(pid)
  local out = {}
  for _, r in pairs(recordsOf(pid) or {}) do out[#out + 1] = {fake = r.fake, real = r.real, inv = r.inv, model = r.model} end
  table.sort(out, function(a, b) return a.fake < b.fake end)
  return out
end

local function sendState(pid, withChoices)
  local d = {list = listOf(pid), have = items.count(pid, "fake_plate"), enabled = enabled()}
  if withChoices then
    offers[pid] = choices()
    d.choices = offers[pid]
  end
  net.send(pid, "rlsmpFakeState", d)
end

-- For other modules: the record whose fake or real plate is `plate` in this player's profile, and "fake" | "real" (nil = none).
function M.find(pid, plate)
  for fake, r in pairs(recordsOf(pid) or {}) do
    if fake == plate then return r, "fake" end
    if r.real == plate then return r, "real" end
  end
  return nil
end
function M.wears(pid, plate) local _, which = M.find(pid, plate) return which == "fake" end
-- plateRecords must not wipe the real plate's flag when the plate change it was told about is our own swap.
function M.involves(pid, plate) return M.find(pid, plate) ~= nil end

local function plateRecordsModule()
  local ok, pr = pcall(require, "rlsmp.server.plateRecords")
  return ok and type(pr) == "table" and pr or nil
end
local function cleanPlate(s) local pr = plateRecordsModule() return pr and pr.cleanPlate(s) or nil end
local function cleanModel(s) local pr = plateRecordsModule() return pr and pr.cleanModel(s) or nil end

local function result(pid, t) net.send(pid, "rlsmpFakeResult", t) end

-- One request a second at most, per player.
local function rateLimited(pid)
  local now = util.now()
  if lastAct[pid] and now - lastAct[pid] < num(fcfg().cooldown, 1) then return true end
  lastAct[pid] = now
  return false
end

local function onAsk(pid)
  if not sessions.isLoaded(pid) or rateLimited(pid) then return end
  sendState(pid, true)
end

local function onFit(pid, d)
  local recs = recordsOf(pid)
  if not recs then return end
  local function fail(err) result(pid, {ok = false, action = "fit", err = err}) end
  if not enabled() then return fail("Fake plates are off on this server.") end
  if rateLimited(pid) then return fail("Slow down.") end
  if positions.isChased(pid) then return fail("Lose the police first.") end
  local inv = math.floor(num(d.inv, -1))
  local real, model = cleanPlate(d.real), cleanModel(d.model)
  local offer = offers[pid]
  local fake = offer and offer[math.floor(num(d.idx, 0))]
  if inv < 0 or not real or not model then return fail("Bad car.") end
  if not fake then return fail("That plate is not on offer any more. Open the menu again.") end
  local n = 0
  for _, r in pairs(recs) do
    n = n + 1
    if r.inv == inv or r.real == real or r.fake == real then return fail("This car already wears a fake plate. Restore the real plate first.") end
  end
  if n >= num(fcfg().maxPerPlayer, 16) then return fail("Too many fake plates in use.") end
  if taken(fake) then return fail("That plate is taken. Open the menu again.") end
  if not items.has(pid, "fake_plate") then return fail("You need a fake plate. Buy one at the Black Market.") end
  local p = profileOf(pid)
  recs[fake] = {fake = fake, real = real, inv = inv, model = model, t = util.now()}
  items.take(pid, "fake_plate", 1)
  if not profiles.persist(p) then            -- record and item go to disk together (take saves too, this makes sure the record is in)
    recs[fake] = nil
    items.give(pid, "fake_plate", 1)
    return fail("The server could not save. Nothing was used.")
  end
  offers[pid] = nil
  util.info(string.format("[fakePlate] %s fitted %s over %s on car %d (%s)", tostring(sessions.get(pid).name), fake, real, inv, model))
  result(pid, {ok = true, action = "fit", fake = fake, real = real, inv = inv, have = items.count(pid, "fake_plate")})
  sendState(pid, false)
end

-- Remove a record. `refund`: give the item back (the game failed to fit it). Returns the record.
local function forget(pid, fake, refund)
  local recs = recordsOf(pid)
  local r = recs and recs[fake]
  if not r then return nil end
  recs[fake] = nil
  if refund and util.now() - (tonumber(r.t) or 0) < 60 then items.give(pid, "fake_plate", 1) end
  profiles.persist(profileOf(pid))
  local pr = plateRecordsModule()
  if pr and pr.clearPlate then pr.clearPlate(fake, r.model) end   -- the fake plate is gone; the real plate's record was never touched
  return r
end

local function onRestore(pid, d)
  if not recordsOf(pid) then return end
  local fake = cleanPlate(d.fake)
  local r = fake and forget(pid, fake, d.failed == true)
  if not r then return result(pid, {ok = false, action = "restore", err = "That fake plate is not on file."}) end
  util.info(string.format("[fakePlate] %s restored %s (fake %s)", tostring(sessions.get(pid).name), r.real, fake))
  result(pid, {ok = true, action = "restore", fake = fake, real = r.real, inv = r.inv, failed = d.failed == true})
  sendState(pid, false)
end

local function onDrop(pid, d)
  local fake = cleanPlate(d.fake)
  if fake and forget(pid, fake, false) then
    util.info(string.format("[fakePlate] %s: fake plate %s dropped (plate changed or car gone)", tostring(sessions.get(pid).name), fake))
    sendState(pid, false)
  end
end

-- Push the state once per session after loading (the client puts the markers back and checks the cars).
function M.tick()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      local s = sessions.get(pid)
      if told[pid] ~= s then
        told[pid] = s
        sendState(pid, false)
      end
    end
  end
  for _, t in ipairs({told, offers, lastAct}) do
    for pid in pairs(t) do if not live[pid] then t[pid] = nil end end
  end
end

function M.init(config)
  cfg = config
  told, offers, lastAct = {}, {}, {}
  net.onClient("rlsmpFakeAsk", onAsk)
  net.onClient("rlsmpFakeFit", onFit)
  net.onClient("rlsmpFakeRestore", onRestore)
  net.onClient("rlsmpFakeDrop", onDrop)
  net.on("rlsmpFakeTick", M.tick)
  MP.CreateEventTimer("rlsmpFakeTick", 3000)
end

return M
