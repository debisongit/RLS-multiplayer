-- RLS-Career-MP server: pink-slip duels (Phase 4). OFF by default (config duel.enabled).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- /duel <player>  challenge   /duel accept   /duel cancel   /duel claim (re-send a car you won right now)
-- Both players sit in the car they stake and stand near the start of a configured course. A countdown runs, the
-- first one to reach the finish wins and the loser's car moves to the winner.
--
-- Safety rules (a car must never vanish and never be copied):
--   1. The staked car must exist in the SERVER's copy of the save (model and config readable, same model the client
--      named) and must be the car the player is sitting in.
--   2. The moment a winner is declared, the server builds the winner's car from ITS OWN copy of the loser's car file
--      (never from anything the loser's client sends). If that file is missing or unusable, no car moves at all.
--      The slip is stored in `owed` (duels.json) in stage "deliver" first, then the loser's slot is marked out
--      (profiles.markOut, saved in the loser's profile) and the loser's client is told to remove the car
--      (rlsmpDuelAck). If the loser is offline or the removal does not happen, the join-time drop list
--      (profiles.staleCars) removes it on the next join. Any later loser save that still has the car re-marks it
--      (mileage changes the file, which would otherwise clear the mark), until a save arrives without the car.
--      Write order: duels.json before the loser's profile, so a crash in between can at worst leave a copy, never lose the car.
--   3. The winner gets the stored car through the fleet-style download, re-sent every duel.retrySeconds while online.
--      rlsmpDuelReceived only marks it "delivered"; the slip is dropped when a later winner save contains a car tagged
--      with the slip (or, after 60 s, any later winner save). If the winner leaves before that, it goes back to "deliver".
--   4. If the loser quits mid-race the winner wins.
-- Positions and finishing are reported by the clients (so they can be cheated); the server checks plausibility:
-- finite numbers only, no jump faster than duel.maxSpeed between pings, start position near the course start at GO,
-- straight start-to-finish distance over elapsed time below duel.maxSpeed, at least duel.minPings pings during the race.

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")

local M = {}

local MAX_COORD = 100000
local DELIVERED_GRACE = 60   -- seconds after rlsmpDuelReceived before any winner save closes the slip

local cfg, file
-- slipId -> {loser, winner, inv, model, stage = "deliver"|"delivered", rec, lastTry, deliveredAt, loserCleared}
local owed = {}
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

local function finite(v)
  v = tonumber(v)
  if v and v == v and math.abs(v) <= MAX_COORD then return v end
end

-- A clean {x, y, z} from {x=..,y=..,z=..} or {x, y, z}; nil when anything is not a sane number.
local function toPos(p)
  if type(p) ~= "table" then return nil end
  local x, y, z = finite(p.x or p[1]), finite(p.y or p[2]), finite(p.z or p[3])
  if x and y and z then return {x = x, y = y, z = z} end
end

local function dist(p, q)
  local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function maxSpeed() return tonumber(cfg.duel.maxSpeed) or 120 end

-- Courses with usable coordinates (both table styles accepted). Idempotent, so it is safe to run on every use.
local function courses()
  local out = {}
  for i, c in ipairs(type(cfg.duel.courses) == "table" and cfg.duel.courses or {}) do
    local start = type(c) == "table" and toPos(c.start)
    local fin = type(c) == "table" and toPos(c.finish)
    if start and fin then
      c.start, c.finish = start, fin
      out[#out + 1] = c
    elseif not (type(c) == "table" and c.warned) then
      util.warn("[duel] course " .. i .. " (" .. tostring(type(c) == "table" and c.name) .. ") has no usable start/finish, skipped")
      if type(c) == "table" then c.warned = true end
    end
  end
  return out
end

local function carFile(inv) return "career/vehicles/" .. tostring(inv) .. ".json" end

-- Decode the server's copy of a car. Returns the record or nil + reason.
local function storedCar(profile, inv, model)
  local text = profile and profile.save and profile.save.files[carFile(inv)]
  if not text then return nil, "the server save does not have that car yet (wait for the autosave)" end
  local stored = util.jsonDecode(text)
  if type(stored) ~= "table" or type(stored.model) ~= "string" or type(stored.config) ~= "table" then
    return nil, "the server copy of that car is unreadable"
  end
  if stored.model ~= model then return nil, "that car does not match your saved car" end
  return stored, text
end

-- The staked car as the server sees it. Returns {inv, model, value} or nil + reason.
local function checkCar(s, inv, model)
  local stored, why = storedCar(s.profile, inv, model)
  if not stored then return nil, why end
  if profiles.isOut(s.profile, inv) then return nil, "that car is already handed over" end
  for _, o in pairs(owed) do
    if o.loser == s.accountId and o.inv == tonumber(inv) and not o.loserCleared then return nil, "that car is already owed to someone" end
  end
  -- RLS stores the config's base price in the car file (configBaseValue); the depreciated value is only computed in-game.
  return {inv = tonumber(inv), model = model, value = tonumber(stored.configBaseValue) or tonumber(stored.value)}
end

local function finish(d)
  net.send(d.a, "rlsmpDuelEnd", {id = d.id})
  net.send(d.b, "rlsmpDuelEnd", {id = d.id})
  duels[d.id] = nil
  if byPid[d.a] == d.id then byPid[d.a] = nil end
  if byPid[d.b] == d.id then byPid[d.b] = nil end
end

local function pidOf(accountId)
  for pid, s in pairs(sessions.all()) do
    if s.stage == "loaded" and s.accountId == accountId then return pid, s end
  end
end

-- The loser's profile, online or not. Returns profile, loadedHere (unload when done).
local function loserProfile(accountId)
  local _, s = pidOf(accountId)
  if s and s.profile then return s.profile, false end
  local p = profiles.get(accountId)
  if p then return p, false end
  return profiles.loadOrCreate(accountId), true
end

local function declareWinner(d, winnerPid, why)
  local loserPid = winnerPid == d.a and d.b or d.a
  local w = sessions.get(winnerPid)
  if not w then return finish(d) end
  local loserCar = d.cars[loserPid]
  local loserId = d.ids[loserPid]
  local profile, loadedHere = loserProfile(loserId)
  local stored = storedCar(profile, loserCar.inv, loserCar.model)
  local rec = stored
  if rec then
    rec.thumbnail, rec.defaultThumbnail, rec.fleetId = nil, nil, nil
    if #util.jsonEncode(rec) > cfg.business.maxRecordBytes then rec = nil end
  end
  if not rec then
    if loadedHere then profiles.unload(loserId) end
    util.warn(string.format("[duel] %s won but the loser's %s is not usable in the server save; no car moves", w.name, tostring(loserCar.model)))
    both(d, string.format("%s wins%s, but the loser's car could not be read from the server save. No car moves.",
      w.name, why and (" (" .. why .. ")") or ""))
    return finish(d)
  end
  counter = counter + 1
  local slip = "s" .. util.now() .. "x" .. counter
  rec.slipId = slip
  owed[slip] = {loser = loserId, winner = d.ids[winnerPid], inv = loserCar.inv, model = loserCar.model,
                stage = "deliver", rec = rec, lastTry = 0}
  persist()   -- before the loser's profile: a crash in between can leave a copy, never lose the car
  profiles.markOut(profile, loserCar.inv, slip)
  profiles.persist(profile)
  if loadedHere then profiles.unload(loserId) end
  both(d, string.format("%s wins%s! The %s goes to the winner.", w.name, why and (" (" .. why .. ")") or "", tostring(loserCar.model)))
  if sessions.get(loserPid) then
    net.send(loserPid, "rlsmpDuelAck", {ok = true, inv = loserCar.inv, slip = slip, model = loserCar.model})
  end
  util.info(string.format("[duel] %s won the %s of %s; slip %s", w.name, tostring(loserCar.model), tostring(loserId), slip))
  finish(d)
end

-- Chat ---------------------------------------------------------------------------------------------

local function startDuel(d)
  local a, b = sessions.get(d.a), sessions.get(d.b)
  if not (a and b) then return finish(d) end
  d.stage = "asking"
  d.cars, d.pos, d.last, d.pings, d.ids = {}, {}, {}, {}, {[d.a] = a.accountId, [d.b] = b.accountId}
  d.expires = util.now() + 20
  net.send(d.a, "rlsmpDuelWho", {id = d.id})
  net.send(d.b, "rlsmpDuelWho", {id = d.id})
end

local function onChat(pid, text)
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then return say(pid, "Your career is still loading.") end
  if not cfg.duel.enabled then return say(pid, "Duels are switched off on this server.") end
  local cmd = text:match("^(%S*)")
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
    for _, o in pairs(owed) do if o.stage == "deliver" then o.lastTry = 0 end end
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

local function onCarUnsafe(pid, data, d)
  local s = sessions.get(pid)
  local pos = toPos(data.pos)
  if not s or not pos or not tonumber(data.inv) then
    both(d, "Duel cancelled: " .. (s and s.name or "a player") .. " is not in a car.")
    return finish(d)
  end
  if tonumber(data.cur) ~= tonumber(data.inv) then
    both(d, "Duel cancelled: " .. s.name .. " - you must sit in the car you stake (update the mod if this keeps happening).")
    return finish(d)
  end
  local car, why = checkCar(s, data.inv, tostring(data.model))
  if not car then
    both(d, "Duel cancelled: " .. s.name .. " - " .. why .. ".")
    return finish(d)
  end
  d.cars[pid], d.pos[pid], d.last[pid] = car, pos, {pos = pos, t = util.now()}
  if not (d.cars[d.a] and d.cars[d.b]) then return end
  local gap = tonumber(cfg.duel.maxValueGapPercent) or 0
  if gap > 0 then
    local va, vb = d.cars[d.a].value, d.cars[d.b].value
    if not (va and vb) then
      both(d, "Duel cancelled: the value of a staked car is unknown to the server.")
      return finish(d)
    end
    if math.min(va, vb) < math.max(va, vb) * (1 - gap / 100) then
      both(d, string.format("Duel cancelled: the cars' values are too far apart (max %d%% difference).", gap))
      return finish(d)
    end
  end
  -- both cars are fine: find a course whose start is close to both
  local list = courses()
  local other = d.pos[pid == d.a and d.b or d.a]
  for _, c in ipairs(list) do
    if dist(pos, c.start) <= cfg.duel.startRadius and dist(other, c.start) <= cfg.duel.startRadius then
      d.course, d.stage, d.t0 = c, "countdown", util.now() + cfg.duel.countdownSeconds
      both(d, string.format("Course '%s'. Starting in %d seconds. Cars at stake!", tostring(c.name), cfg.duel.countdownSeconds))
      return
    end
  end
  local names = {}
  for _, c in ipairs(list) do names[#names + 1] = tostring(c.name) end
  both(d, "Duel cancelled: you both need to be at a course start (" .. (#names > 0 and table.concat(names, ", ") or "none set up") .. ").")
  finish(d)
end

local function onCar(pid, data)
  local d = duels[tonumber(data.id)]
  if not d or d.stage ~= "asking" or (pid ~= d.a and pid ~= d.b) or d.cars[pid] then return end
  local ok, err = pcall(onCarUnsafe, pid, data, d)
  if not ok then
    util.warn("[duel] onCar failed: " .. tostring(err))
    if duels[d.id] then
      both(d, "Duel cancelled: bad duel data (check duel.courses in config.json).")
      finish(d)
    end
  end
end

local function onPos(pid, data)
  local d = duels[byPid[pid]]
  local pos = toPos(data.pos)
  if not (d and pos and d.pos and d.last and d.last[pid]) then return end
  local now, last = util.now(), d.last[pid]
  -- util.now() is whole seconds, so two honest pings can share a second: count at least 1 s.
  if dist(pos, last.pos) / math.max(now - last.t, 1) > maxSpeed() then
    if not d.jumped then d.jumped = {} end
    if not d.jumped[pid] then
      d.jumped[pid] = true
      util.warn("[duel] position jump from " .. tostring(pid) .. " refused")
      say(pid, "Your car jumped too far (reset or teleport?). You can't win this duel.")
    end
    return
  end
  d.pos[pid], d.last[pid] = pos, {pos = pos, t = now}
  if d.stage == "racing" then d.pings[pid] = (d.pings[pid] or 0) + 1 end
end

local function onFinish(pid)
  local d = duels[byPid[pid]]
  if not (d and d.stage == "racing") then return end
  local pos, start = d.pos[pid], d.startPos and d.startPos[pid]
  local elapsed = util.now() - d.t0
  if elapsed < cfg.duel.minRaceSeconds then return end
  if not pos or dist(pos, d.course.finish) > cfg.duel.finishRadius * 3 then return end
  if d.jumped and d.jumped[pid] then return end
  if (d.pings[pid] or 0) < (tonumber(cfg.duel.minPings) or 5) then return end
  if not start or dist(start, d.course.start) > cfg.duel.startRadius then return end
  if dist(start, pos) / math.max(elapsed, 1) > maxSpeed() then return end
  declareWinner(d, pid)
end

-- Delivery (winner) ----------------------------------------------------------------------------------

local function onReceived(pid, data)
  local s = sessions.get(pid)
  local o = s and owed[tostring(data.slip)]
  if o and o.winner == s.accountId and o.stage == "deliver" then
    o.stage, o.deliveredAt = "delivered", util.now()
    persist()
    say(pid, "Your new car is in your garage.")
  end
end

local function onRelease(pid, data)
  local o = owed[tostring(data.slip)]
  if o then say(pid, "Could not take the car: " .. tostring(data.why) .. ". It waits for you (use /duel claim).") end
end

local function hasSlipCar(profile, slip)
  for rel, text in pairs(profile.save.files) do
    if rel:match("^career/vehicles/[^/]+%.json$") and text:find(slip, 1, true) then
      local rec = util.jsonDecode(text)
      if type(rec) == "table" and rec.slipId == slip then return true end
    end
  end
  return false
end

-- After every accepted save upload.
function M.onSaved(pid, s, profile)
  local changed = false
  for slip, o in pairs(owed) do
    if o.loser == s.accountId and not o.loserCleared then
      local text = profile.save.files[carFile(o.inv)]
      local rec = text and util.jsonDecode(text)
      if not text then
        o.loserCleared = true
        changed = true
      elseif type(rec) == "table" and rec.model == o.model and not profiles.isOut(profile, o.inv) then
        -- The loser saved before removing the car (mileage changed the file): keep the slot marked out.
        profiles.markOut(profile, o.inv, slip)
        if not s.guest then profiles.persist(profile) end
      end
    end
    if o.winner == s.accountId and (o.stage == "deliver" or o.stage == "delivered") then
      if hasSlipCar(profile, slip) then
        owed[slip] = nil
        changed = true
      elseif o.stage == "delivered" and util.now() - (o.deliveredAt or 0) >= DELIVERED_GRACE then
        util.warn("[duel] slip " .. slip .. ": winner's save has no car tagged with it 60 s after delivery; closing it anyway")
        owed[slip] = nil
        changed = true
      end
    end
  end
  if changed then persist() end
end

-- Time-driven work: countdown, timeouts, forfeits, pending deliveries.
function M.tick()
  local now = util.now()
  for _, d in pairs(duels) do
    local a, b = sessions.get(d.a), sessions.get(d.b)
    if d.stage == "racing" or d.stage == "countdown" then
      if not a or not b then
        if a or b then declareWinner(d, a and d.a or d.b, "opponent left") else finish(d) end
      elseif d.stage == "countdown" and now >= d.t0 then
        d.stage, d.t0 = "racing", now
        d.startPos = {[d.a] = d.pos[d.a], [d.b] = d.pos[d.b]}
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
    local pid = pidOf(o.winner)
    if o.stage == "delivered" and not pid then
      o.stage, o.lastTry = "deliver", 0   -- winner left before a save confirmed it: send again on the next join
      persist()
    elseif o.stage == "deliver" and pid and now - (o.lastTry or 0) >= cfg.duel.retrySeconds then
      o.lastTry = now
      net.sendBig(pid, "duelVehicle", util.jsonEncode({slip = slip, rec = o.rec}), {slip = slip})
    end
  end
end

function M.init(config, pluginRoot)
  cfg = config
  file = pluginRoot .. "duels.json"
  local saved = storage.readJson(file) or {}
  owed, counter = type(saved.owed) == "table" and saved.owed or {}, tonumber(saved.counter) or 0
  -- Old builds kept slips in stage "hand" (waiting for the loser's upload). Nothing was marked out yet, so drop them.
  local dropped = false
  for slip, o in pairs(owed) do
    if type(o) ~= "table" or (o.stage ~= "deliver" and o.stage ~= "delivered") or type(o.rec) ~= "table" then
      util.warn("[duel] dropping old slip " .. tostring(slip) .. " (stage " .. tostring(type(o) == "table" and o.stage) .. "); no car moves")
      owed[slip] = nil
      dropped = true
    end
  end
  if dropped then persist() end
  courses()
  net.onChat("duel", onChat)
  net.onClient("rlsmpDuelCar", onCar)
  net.onClient("rlsmpDuelPos", onPos)
  net.onClient("rlsmpDuelFinish", function(pid) onFinish(pid) end)
  net.onClient("rlsmpDuelReceived", onReceived)
  net.onClient("rlsmpDuelRelease", onRelease)
  sessions.onSaved(M.onSaved)
  net.on("rlsmpDuelTick", M.tick)
  MP.CreateEventTimer("rlsmpDuelTick", 1000)
end

M._owed = function() return owed end

return M
