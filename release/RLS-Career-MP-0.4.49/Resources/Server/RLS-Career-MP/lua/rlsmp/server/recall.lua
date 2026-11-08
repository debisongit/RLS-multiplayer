-- RLS-Career-MP server: put a stolen car back (after a rejoin, or on a button). Needs car theft on.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A stolen car is only a local car of its thief, so it vanishes when they leave. The theft record (server/theft.lua) keeps what is
-- needed to rebuild it (rec.car = config + paints, rec.last = place + rotation, rec.ownerPos = the owner's last server-side position).
-- A record exists only while the car is still the player's: sold, stripped and trapped cars are taken out by the fence, so they are never put back.
--   client rlsmpStolenPos {cars = [{plate, x, y, z, rot}]}   the game reports its stolen cars (rate limited per plate, config theft.recallReportEvery)
--   server rlsmpStolenRestore {auto, cars = [spec], spots = [{x, y, z, name}]}
--        auto = true once per session after the career loaded (the game puts each car back at its last place when that is free)
--        auto = false answers a button: the game puts the cars beside the player
--        spec = {plate, model, config, look, value, year, color, x, y, z, rot}
--   client rlsmpStolenRecall {plate?}                        the button ("Bring my stolen car here")
--   server rlsmpStolenRecallResult {ok = false, err}         when the button was refused (owner only, cooldown theft.recallCooldown, fee theft.recallFee)

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")
local positions = require("rlsmp.server.positions")
local theft = require("rlsmp.server.theft")

local M = {}

local cfg
local told = {}        -- pid -> the session table we already restored for
local lastPlate = {}   -- plate -> time of the last accepted position report
local recallAt = {}    -- pid -> time before which no new button recall is accepted
local dirty, savedAt = false, 0

local function num(v, default)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  return v
end
local function tcfg() return cfg.theft end

local function accountOf(pid)
  local s = sessions.get(pid)
  return s and s.accountId or nil
end

-- The player's records, oldest first.
function M.mine(pid)
  local acc, list = accountOf(pid), {}
  if not acc then return list end
  for _, rec in pairs(theft.records()) do
    if rec.by == acc then list[#list + 1] = rec end
  end
  table.sort(list, function(a, b) return (a.t or 0) < (b.t or 0) end)
  return list
end

-- What the game needs to rebuild one car.
function M.spec(rec)
  local at = rec.last or rec.ownerPos or rec.pos or {}
  local car = rec.car or {}
  return {plate = rec.plate, model = rec.model, config = car.config, look = car.look, value = rec.value, year = rec.year, color = rec.color,
    x = at.x, y = at.y, z = at.z, rot = at.rot}
end

local function specs(list)
  local out = {}
  for i, rec in ipairs(list) do
    if i > 8 then break end
    out[#out + 1] = M.spec(rec)
  end
  return out
end

local function dropSpots()
  local out = {}
  for _, sp in ipairs(type(cfg.market) == "table" and type(cfg.market.dropSpots) == "table" and cfg.market.dropSpots or {}) do
    if type(sp) == "table" and tonumber(sp.x) and tonumber(sp.y) and tonumber(sp.z) then
      out[#out + 1] = {x = sp.x, y = sp.y, z = sp.z, name = sp.name}
    end
  end
  return out
end

local function flush(force)
  local now = util.now()
  if dirty and (force or now - savedAt >= 30) then
    dirty, savedAt = false, now
    theft.save()
  end
end

-- A game reports where its stolen cars stand now.
local function onPos(pid, d)
  if not theft.isEnabled() or type(d) ~= "table" or type(d.cars) ~= "table" or not sessions.isLoaded(pid) then return end
  local now, acc = util.now(), accountOf(pid)
  local every = math.max(1, num(tcfg().recallReportEvery, 20))
  local mypos = positions.get(pid)
  for i, c in ipairs(d.cars) do
    if i > 8 then break end
    local plate = type(c) == "table" and theft.cleanPlate(c.plate) or nil
    local rec = plate and theft.records()[plate]
    local x, y, z = num(c.x, nil), num(c.y, nil), num(c.z, nil)
    if rec and rec.by == acc and x and y and z and math.abs(x) < 1e5 and math.abs(y) < 1e5 and math.abs(z) < 1e4
        and now - (lastPlate[plate] or -1e9) >= every then
      lastPlate[plate] = now
      local r = type(c.rot) == "table" and {x = num(c.rot.x, nil), y = num(c.rot.y, nil), z = num(c.rot.z, nil), w = num(c.rot.w, nil)} or nil
      if not (r and r.x and r.y and r.z and r.w and math.abs(r.x) <= 2 and math.abs(r.y) <= 2 and math.abs(r.z) <= 2 and math.abs(r.w) <= 2) then r = nil end
      rec.last = {x = x, y = y, z = z, rot = r, t = now}
      if mypos then rec.ownerPos = {x = mypos.x, y = mypos.y, z = mypos.z, t = now} end
      dirty = true
    end
  end
  flush(false)
end

-- Automatic: once per session, as soon as the career runs.
local function pushAuto()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      local s = sessions.get(pid)
      if told[pid] ~= s then
        told[pid] = s
        local list = theft.isEnabled() and M.mine(pid) or {}
        if #list > 0 then
          net.send(pid, "rlsmpStolenRestore", {auto = true, cars = specs(list), spots = dropSpots()})
          util.info(string.format("[recall] %s: %d stolen car(s) to put back", tostring(s.name or pid), #list))
        end
      end
    end
  end
  for pid in pairs(told) do if not live[pid] then told[pid], recallAt[pid] = nil, nil end end
end

local function refuse(pid, err) net.send(pid, "rlsmpStolenRecallResult", {ok = false, err = err}) end

-- The button. Owner only, a record must exist, cooldown, optional fee.
local function onRecall(pid, d)
  if not theft.isEnabled() then return refuse(pid, "Car theft is off on this server.") end
  if not sessions.isLoaded(pid) then return refuse(pid, "Not in career.") end
  d = type(d) == "table" and d or {}
  local list = M.mine(pid)
  local plate = d.plate ~= nil and theft.cleanPlate(d.plate) or nil
  if plate then
    local one
    for _, rec in ipairs(list) do if rec.plate == plate then one = rec end end
    list = one and {one} or {}
  end
  if #list == 0 then return refuse(pid, "You have no stolen car to bring.") end
  local now = util.now()
  local wait = (recallAt[pid] or 0) - now
  if wait > 0 then return refuse(pid, string.format("Wait %d s before calling a car again.", math.ceil(wait))) end
  local fee = math.max(0, math.floor(num(tcfg().recallFee, 0)))
  local s = sessions.get(pid)
  if fee > 0 then
    local profile = s and s.profile
    local ledger = profile and profile.ledger
    if not (ledger and ledger.seeded) then return refuse(pid, "Wait for your first save, then try again.") end
    if ledger.money < fee then return refuse(pid, string.format("Bringing the car costs $%d.", fee)) end
    local before = ledger.money
    ledger.money = before - fee
    if not profiles.persist(profile) then
      ledger.money = before
      return refuse(pid, "The server could not save. Nothing was charged.")
    end
    net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "recall"})
  end
  recallAt[pid] = now + math.max(0, num(tcfg().recallCooldown, 120))
  util.info(string.format("[recall] %s asks for %d stolen car(s) beside them", tostring(s and s.name or pid), #list))
  net.send(pid, "rlsmpStolenRestore", {auto = false, cars = specs(list), spots = {}})
end

function M.tick()
  pushAuto()
  flush(false)
end

function M.init(config)
  cfg = config
  told, lastPlate, recallAt, dirty, savedAt = {}, {}, {}, false, 0
  net.onClient("rlsmpStolenPos", onPos)
  net.onClient("rlsmpStolenRecall", onRecall)
  net.on("rlsmpRecallTick", M.tick)
  MP.CreateEventTimer("rlsmpRecallTick", 3000)
end

M._flush = flush
return M
