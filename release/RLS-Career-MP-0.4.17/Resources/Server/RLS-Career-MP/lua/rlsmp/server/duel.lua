-- RLS-Career-MP server: pink-slip duels (Phase 4). OFF by default (config duel.enabled).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- /duel <player>  challenge   /duel accept   /duel cancel   /duel claim (retry a pending car hand-over)
-- Both players sit in the car they stake and stand near the start of a configured course. A countdown runs, the
-- first one to reach the finish wins and the loser's car moves to the winner.
--
-- Safety rules (a car must never vanish and never be copied):
--   1. The staked car must exist in the SERVER's copy of the save; its file is fingerprinted when the duel starts.
--   2. After the race the loser's client uploads the car. The server stores it in `owed` (duels.json) and marks the
--      slot as handed over (profiles.markOut), so a crash cannot bring the old copy back. Only then does the loser's client delete it.
--   3. The winner gets the stored car through the fleet-style download. It stays in `owed` until the winner's game says it
--      arrived (or a copy tagged with the slip is already in the garage), and is re-sent while the winner is online.
--   4. If the loser quits mid-race the winner wins. If the loser is offline after losing, the hand-over waits for the next join.
-- Positions and finishing are reported by the clients (so they can be cheated), the server checks plausibility only.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")

local M = {}

local cfg, file
local owed = {}      -- slipId -> {loser, winner, inv, sum, model, stage = "hand"|"deliver", rec, lastTry}
local duels = {}     -- duelId -> {id, a, b, stage, ...}
local byPid = {}     -- pid -> duelId
local nextId = 0
local counter = 0

local function say(pid, text) MP.SendChatMessage(pid, "[Duel] " .. text) end
local function both(d, text) say(d.a, text) say(d.b, text) end
local function persist() storage.writeJson(file, {owed = owed, counter = counter}) end

local function findPlayer(name)
  name = tostring(name or ""):lower()
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" and tostring(s.name):lower() == name then return pid, s end
  end
end

local function dist(p, q)
  local dx, dy, dz = p.x - q.x, p.y - q.y, (p.z or 0) - (q.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function validPos(p)
  return type(p) == "table" and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and p
end

local function carFile(inv) return "career/vehicles/" .. tostring(inv) .. ".json" end

-- The staked car as the server sees it. Returns {inv, model, sum} or nil + reason.
local function checkCar(s, inv, model)
  local text = s.profile.save.files[carFile(inv)]
  if not text then return nil, "the server save does not have that car yet (wait for the autosave)" end
  local stored = util.jsonDecode(text)
  if type(stored) == "table" and type(stored.model) == "string" and stored.model ~= model then
    return nil, "that car does not match your saved car"
  end
  if profiles.isOut(s.profile, inv) then return nil, "that car is already handed over" end
  for _, o in pairs(owed) do
    if o.loser == s.accountId and o.inv == tonumber(inv) then return nil, "that car is already owed to someone" end
  end
  return {inv = tonumber(inv), model = model, sum = require("rlsmp.shared.transfer").checksum(text)}
end

local function finish(d)
  net.send(d.a, "rlsmpDuelEnd", {id = d.id})
  net.send(d.b, "rlsmpDuelEnd", {id = d.id})
  duels[d.id] = nil
  if byPid[d.a] == d.id then byPid[d.a] = nil end
  if byPid[d.b] == d.id then byPid[d.b] = nil end
end

local function declareWinner(d, winnerPid, why)
  local loserPid = winnerPid == d.a and d.b or d.a
  local w, l = sessions.get(winnerPid), sessions.get(loserPid)
  if not w then return finish(d) end
  both(d, string.format("%s wins%s!", w.name, why and (" (" .. why .. ")") or ""))
  local loserCar = d.cars[loserPid]
  counter = counter + 1
  local slip = "s" .. os.time() .. "x" .. counter
  owed[slip] = {loser = d.ids[loserPid], winner = d.ids[winnerPid], inv = loserCar.inv, sum = loserCar.sum,
                model = loserCar.model, stage = "hand", lastTry = 0}
  persist()
  util.info(string.format("[duel] %s beat %s; slip %s (%s)", w.name, l and l.name or "?", slip, loserCar.model))
  finish(d)
end

-- Chat ---------------------------------------------------------------------------------------------

local function startDuel(d)
  local a, b = sessions.get(d.a), sessions.get(d.b)
  if not (a and b) then return finish(d) end
  d.stage = "asking"
  d.cars, d.pos, d.ids = {}, {}, {[d.a] = a.accountId, [d.b] = b.accountId}
  d.expires = util.now() + 20
  net.send(d.a, "rlsmpDuelWho", {id = d.id})
  net.send(d.b, "rlsmpDuelWho", {id = d.id})
end

local function onChat(pid, text)
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then return say(pid, "Your career is still loading.") end
  if not cfg.duel.enabled then return say(pid, "Duels are switched off on this server.") end
  local cmd, arg = text:match("^(%S*)%s*(.-)$")
  if cmd == "accept" then
    local d
    for _, x in pairs(duels) do if x.b == pid and x.stage == "challenged" then d = x end end
    if not d then return say(pid, "Nobody has challenged you.") end
    return startDuel(d)
  elseif cmd == "cancel" then
    local d = duels[byPid[pid]]
    if not d then return say(pid, "You are not in a duel.") end
    if d.stage == "racing" or d.stage == "countdown" then return say(pid, "Too late to cancel, drive!") end
    both(d, s.name .. " cancelled the duel.")
    return finish(d)
  elseif cmd == "claim" then
    for _, o in pairs(owed) do o.lastTry = 0 end
    return say(pid, "Checking pending cars...")
  elseif cmd == "" or cmd == "help" then
    return say(pid, "/duel <player> | accept | cancel | claim. Loser's car goes to the winner. Meet at a course start.")
  end
  local targetPid, target = findPlayer(text)
  if not target or targetPid == pid then return say(pid, "Player '" .. text .. "' is not online.") end
  if byPid[pid] or byPid[targetPid] then return say(pid, "One of you is already in a duel.") end
  nextId = nextId + 1
  local d = {id = nextId, a = pid, b = targetPid, stage = "challenged", expires = util.now() + 60}
  duels[d.id], byPid[pid], byPid[targetPid] = d, d.id, d.id
  say(pid, "Challenged " .. target.name .. ". Your cars are at stake!")
  say(targetPid, s.name .. " challenges you to a pink-slip duel. Loser's car goes to the winner. Type /duel accept (60s).")
end

-- Client messages -------------------------------------------------------------------------------------

local function onCar(pid, data)
  local d = duels[tonumber(data.id)]
  if not d or d.stage ~= "asking" or (pid ~= d.a and pid ~= d.b) or d.cars[pid] then return end
  local s = sessions.get(pid)
  local pos = validPos(data.pos)
  if not s or not pos or not tonumber(data.inv) then
    both(d, "Duel cancelled: " .. (s and s.name or "a player") .. " is not in a car.")
    return finish(d)
  end
  local car, why = checkCar(s, data.inv, tostring(data.model))
  if not car then
    both(d, "Duel cancelled: " .. s.name .. " - " .. why .. ".")
    return finish(d)
  end
  d.cars[pid], d.pos[pid] = car, pos
  if not (d.cars[d.a] and d.cars[d.b]) then return end
  -- both cars are fine: find a course whose start is close to both
  for _, c in ipairs(cfg.duel.courses) do
    if c.start and c.finish and dist(pos, c.start) <= cfg.duel.startRadius and dist(d.pos[pid == d.a and d.b or d.a], c.start) <= cfg.duel.startRadius then
      d.course, d.stage, d.t0 = c, "countdown", util.now() + cfg.duel.countdownSeconds
      both(d, string.format("Course '%s'. Starting in %d seconds. Cars at stake!", tostring(c.name), cfg.duel.countdownSeconds))
      return
    end
  end
  local names = {}
  for _, c in ipairs(cfg.duel.courses) do names[#names + 1] = tostring(c.name) end
  both(d, "Duel cancelled: you both need to be at a course start (" .. (#names > 0 and table.concat(names, ", ") or "none set up") .. ").")
  finish(d)
end

local function onPos(pid, data)
  local d = duels[byPid[pid]]
  local pos = validPos(data.pos)
  if d and pos and d.pos then d.pos[pid] = pos end
end

local function onFinish(pid)
  local d = duels[byPid[pid]]
  if not (d and d.stage == "racing") then return end
  local pos = d.pos[pid]
  if util.now() - d.t0 < cfg.duel.minRaceSeconds then return end
  if not pos or dist(pos, d.course.finish) > cfg.duel.finishRadius * 3 then return end
  declareWinner(d, pid)
end

-- Car hand-over (loser) and delivery (winner) -----------------------------------------------------------

local function onHand(pid, s, data)
  local o = owed[tostring(data.slip)]
  if not o or o.stage ~= "hand" or o.loser ~= s.accountId then return end
  local ack = {ok = false, inv = o.inv, slip = data.slip}
  local text = s.profile.save.files[carFile(o.inv)]
  local rec = data.rec
  if text and require("rlsmp.shared.transfer").checksum(text) == o.sum and type(rec) == "table"
     and type(rec.model) == "string" and type(rec.config) == "table"
     and #util.jsonEncode(rec) <= cfg.business.maxRecordBytes then
    rec.slipId = data.slip
    rec.fleetId = nil
    o.rec, o.stage = rec, "deliver"
    profiles.markOut(s.profile, o.inv, data.slip)
    profiles.persist(s.profile)
    persist()
    ack.ok = true
    say(s.pid or 0, "Your " .. tostring(o.model) .. " goes to the winner.")
  else
    say(s.pid or 0, "Could not hand over the car (it changed since the race?). It stays owed; use /duel claim to retry.")
  end
  net.send(s.pid, "rlsmpDuelAck", ack)
end

local function pidOf(accountId)
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" and s.accountId == accountId then return pid, s end
  end
end

local function onReceived(pid, data)
  local s = sessions.get(pid)
  local o = s and owed[tostring(data.slip)]
  if o and o.winner == s.accountId and o.stage == "deliver" then
    owed[tostring(data.slip)] = nil
    persist()
    say(pid, "Your new car is in your garage.")
  end
end

local function onRelease(pid, data)
  local o = owed[tostring(data.slip)]
  if o then say(pid, "Could not take the car: " .. tostring(data.why) .. ". It waits for you (use /duel claim).") end
end

-- Time-driven work: countdown, timeouts, forfeits, pending hand-overs/deliveries.
function M.tick()
  local now = util.now()
  for _, d in pairs(duels) do
    local a, b = sessions.get(d.a), sessions.get(d.b)
    if d.stage == "racing" or d.stage == "countdown" then
      if not a or not b then
        if a or b then declareWinner(d, a and d.a or d.b, "opponent left") else finish(d) end
      elseif d.stage == "countdown" and now >= d.t0 then
        d.stage, d.t0 = "racing", now
        for _, p in ipairs({d.a, d.b}) do net.send(p, "rlsmpDuelGo", {id = d.id, finish = d.course.finish, radius = cfg.duel.finishRadius}) end
        both(d, "GO!")
      elseif d.stage == "racing" and now - d.t0 > cfg.duel.raceTimeoutSeconds then
        both(d, "Nobody finished in time. Duel cancelled, no car moves.")
        finish(d)
      end
    elseif not a or not b or now > d.expires then
      if a or b then say(a and d.a or d.b, "Duel cancelled.") end
      finish(d)
    end
  end
  for slip, o in pairs(owed) do
    if now - (o.lastTry or 0) >= cfg.duel.retrySeconds then
      if o.stage == "hand" then
        local pid, s = pidOf(o.loser)
        if pid then
          o.lastTry = now
          if not s.profile.save.files[carFile(o.inv)] then
            util.warn("[duel] slip " .. slip .. ": the loser's car is gone from the save, dropping the slip")
            owed[slip] = nil
            persist()
          else
            net.send(pid, "rlsmpDuelHand", {slip = slip, inv = o.inv})
          end
        end
      elseif o.stage == "deliver" then
        local pid = pidOf(o.winner)
        if pid then
          o.lastTry = now
          net.sendBig(pid, "duelVehicle", util.jsonEncode({slip = slip, rec = o.rec}), {slip = slip})
        end
      end
    end
  end
end

function M.init(config, pluginRoot)
  cfg = config
  file = pluginRoot .. "duels.json"
  local saved = storage.readJson(file) or {}
  owed, counter = saved.owed or {}, tonumber(saved.counter) or 0
  net.onChat("duel", onChat)
  net.onClient("rlsmpDuelCar", onCar)
  net.onClient("rlsmpDuelPos", onPos)
  net.onClient("rlsmpDuelFinish", function(pid) onFinish(pid) end)
  net.onClient("rlsmpDuelReceived", onReceived)
  net.onClient("rlsmpDuelRelease", onRelease)
  sessions.onBig("duelHand", onHand)
  net.on("rlsmpDuelTick", M.tick)
  MP.CreateEventTimer("rlsmpDuelTick", 1000)
end

return M
