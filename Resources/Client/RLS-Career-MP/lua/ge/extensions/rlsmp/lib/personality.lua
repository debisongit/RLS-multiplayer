-- RLS-Career-MP client: "smart traffic" driver personalities, the pure part (no game globals, unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The extension rlsmp_personalities feeds this module the traffic data, a clock and a random source,
-- and sends the AI command strings it builds to the vehicles. Everything here is deterministic given
-- the injected `rnd()` (a function returning 0 <= x < 1) and `now` (seconds).
--
-- Only the game's own AI settings are used (RLS's overhaulAi, lua/vehicle/extensions/overhaulAi.lua):
--   ai.setAggression(x)            higher = later braking, shorter gaps (tailgating), harder acceleration
--   ai.setSpeedMode("limit"|"legal") + ai.setSpeed(m/s)
--                                   "limit" caps at the given speed and IGNORES the road limit, so we
--                                   recompute the cap from the road limit (veh.tracking.speedLimit)
--   ai.driveInLane("on"|"off")     lane keeping; only the drunk turns it off, for a second or two

local M = {}

M.ORDER = {"normal", "slow", "aggressive", "racer", "drunk"}   -- fixed order: pick() must not depend on pairs()
M.DEFAULT_MIX = {normal = 80, slow = 10, aggressive = 6, racer = 3, drunk = 1}

M.REAPPLY = 20          -- seconds between re-sends of a car's settings (RLS / AI resets can undo them)
M.REAPPLY_JITTER = 4    -- +- seconds, so 18 cars do not all re-send in the same frame
M.LIMIT_STEP = 0.5      -- m/s change of the road limit that makes us re-send the speed cap

-- aggression: RLS traffic default is getTrafficVars().baseAggression (unknown value, ~0.3 in vanilla).
-- factor / extra: cap = max(limit * factor, limit + extra) in m/s.
M.PROFILES = {
  slow       = {aggression = 0.20, factor = 0.85, extra = -math.huge},
  aggressive = {aggression = 0.75, factor = 1.15, extra = 0},
  racer      = {aggression = 1.00, factor = 1.50, extra = 8},
  drunk      = {aggression = 0.45, factor = 1.00, extra = -math.huge},
}

-- Drunk driver timing (seconds) and shape.
M.DRUNK = {
  weaveGapMin = 8, weaveGapRand = 12,      -- lane keeping off every 8..20 s
  weaveMin = 1, weaveRand = 1.5,           -- for 1..2.5 s
  wobbleGapMin = 4, wobbleGapRand = 4,     -- a new speed every 4..8 s
  wobbleMin = 0.70, wobbleRand = 0.45,     -- 70%..115% of the road limit
  brakeChance = 0.15,                      -- chance that a wobble is a hard brake instead
  brakeMin = 1, brakeRand = 0.5,           -- for 1..1.5 s
  brakeSpeed = 2,                          -- m/s cap while "braking"
  brakeAggression = 1.0,                   -- brake hard
}

-- Police reaction.
M.POLICE = {
  radius = 80,          -- metres between the police car and the bad driver
  cooldown = 60,        -- at most one AI pursuit started per this many seconds (per game)
  hits = 2,             -- consecutive suspicious checks needed (no one-frame spikes)
  minFast = 16.7,       -- m/s (RLS MIN_SPEEDING_SPEED): never "fast" below this
  fastFactor = 1.2,     -- RLS SPEEDING_LIMIT_FACTOR
  fastExtra = 2,        -- plus this many m/s
  unknownLimitFast = 25,-- m/s that counts as fast when the road limit is unknown
  weaveMemory = 5,      -- a drunk counts as weaving for this long after a weave started
}

local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end

-- Every personality gets a weight >= 0. Not a table -> the default mix; missing or bad entries -> 0.
function M.sanitizeMix(mix)
  local out = {}
  if type(mix) ~= "table" then
    for _, name in ipairs(M.ORDER) do out[name] = M.DEFAULT_MIX[name] end
    return out
  end
  for _, name in ipairs(M.ORDER) do
    local w = tonumber(mix[name])
    out[name] = (w and finite(w) and w > 0) and w or 0
  end
  return out
end

-- The weights at night (or whenever): every personality's weight times its multiplier. Missing, bad or negative multipliers count as 1
-- (unchanged), at most 100. `mult` not a table -> the mix unchanged.
function M.withMultipliers(mix, mult)
  local out = M.sanitizeMix(mix)
  if type(mult) ~= "table" then return out end
  for _, name in ipairs(M.ORDER) do
    local m = tonumber(mult[name])
    if not (m and finite(m) and m >= 0) then m = 1 end
    out[name] = out[name] * math.min(m, 100)
  end
  return out
end

-- Pick a personality from the weights with one random number r in [0, 1). Zero total -> "normal".
function M.pick(mix, r)
  mix = M.sanitizeMix(mix)
  local total = 0
  for _, name in ipairs(M.ORDER) do total = total + mix[name] end
  if total <= 0 then return "normal" end
  r = tonumber(r) or 0
  if r < 0 then r = 0 end
  local x, acc, last = r * total, 0, "normal"
  for _, name in ipairs(M.ORDER) do
    local w = mix[name]
    if w > 0 then
      acc = acc + w
      last = name
      if x < acc then return name end
    end
  end
  return last   -- r >= 1 (bad random source): the last personality that has weight
end

-- The speed cap (m/s) for a personality on a road with this limit, or nil = use "legal".
function M.capFor(name, limit, drunkFactor)
  local p = M.PROFILES[name]
  if not p or not finite(limit) or limit <= 0 then return nil end
  local factor = p.factor
  if name == "drunk" then factor = drunkFactor or 1 end
  return math.max(limit * factor, limit + p.extra)
end

local function speedPart(cap)
  if cap then return string.format('ai.setSpeedMode("limit") ai.setSpeed(%.3f)', cap) end
  return 'ai.setSpeedMode("legal")'
end

-- One batched command string for the car (sent with obj:queueLuaCommand). nil for "normal" (left to RLS).
function M.command(name, limit, drunk)
  local p = M.PROFILES[name]
  if not p then return nil end
  local aggression, cap, lane = p.aggression, M.capFor(name, limit), "on"
  if name == "drunk" and drunk then
    if drunk.braking then
      aggression, cap = M.DRUNK.brakeAggression, M.DRUNK.brakeSpeed
    else
      cap = M.capFor(name, limit, drunk.factor)
    end
    if drunk.laneOff then lane = "off" end
  end
  return string.format('ai.setAggression(%.3f) %s ai.driveInLane("%s")', aggression, speedPart(cap), lane)
end

-- What RLS's own setAiMode('traffic') sets: put a car back the way RLS left it.
function M.restoreCommand(baseAggression)
  local a = finite(baseAggression) and baseAggression or 0.3
  return string.format('ai.setAggression(%.3f) ai.setSpeedMode("legal") ai.driveInLane("on")', a)
end

-- Why we must leave this traffic car alone (a reason string), or nil if we may drive it.
-- ctx = {playerId, remote = {id = true}, parked = {id = true}, owned(id), locked(id, veh), objectActive(id)}
function M.skipReason(id, veh, ctx)
  ctx = ctx or {}
  if type(veh) ~= "table" then return "noData" end
  if veh.isAi ~= true then return "notAi" end
  if veh.isPerson then return "person" end
  if ctx.playerId ~= nil and id == ctx.playerId then return "player" end
  if ctx.remote and ctx.remote[id] then return "remote" end
  if ctx.parked and ctx.parked[id] then return "parked" end
  if type(veh.role) ~= "table" or veh.role.name ~= "standard" then return "role" end
  local pursuit = veh.pursuit
  if type(pursuit) == "table" and (tonumber(pursuit.mode) or 0) ~= 0 then return "pursuit" end
  if type(veh.queuedFuncs) == "table" and veh.queuedFuncs.pursuitStart then return "pursuit" end
  if type(veh.activeData) == "table" and veh.activeData.tCrash then return "crashed" end   -- RLS's crash reaction owns it until respawn
  if veh.state ~= "active" then return "notActive" end
  if ctx.objectActive and not ctx.objectActive(id) then return "notActive" end
  if ctx.owned and ctx.owned(id) then return "owned" end
  if ctx.locked and ctx.locked(id, veh) then return "locked" end
  return nil
end

-- RLS changes the AI itself in these cases (pursuit / new role sets a new AI mode, crash reaction): send nothing.
function M.rlsTakesOver(reason) return reason == "pursuit" or reason == "role" or reason == "crashed" end

---------------------------------------------------------------------------------------------------
-- Drunk driver: a small state machine driven by the clock.

function M.newDrunk(now, rnd)
  local D = M.DRUNK
  return {
    laneOff = false,
    nextWeave = now + D.weaveGapMin + rnd() * D.weaveGapRand,
    weaveEnd = nil,
    lastWeave = -math.huge,
    factor = 1,
    braking = false,
    brakeEnd = nil,
    nextWobble = now + D.wobbleGapMin + rnd() * D.wobbleGapRand,
  }
end

-- Advance the state to `now`. Returns a list of events ("laneOff", "laneOn", "speed", "brake", "brakeEnd");
-- any event means the car needs a new command.
function M.drunkStep(d, now, rnd)
  local D, events = M.DRUNK, {}
  if d.laneOff then
    if now >= d.weaveEnd then
      d.laneOff, d.weaveEnd = false, nil
      d.nextWeave = now + D.weaveGapMin + rnd() * D.weaveGapRand
      events[#events + 1] = "laneOn"
    end
  elseif now >= d.nextWeave then
    d.laneOff = true
    d.lastWeave = now
    d.weaveEnd = now + D.weaveMin + rnd() * D.weaveRand
    events[#events + 1] = "laneOff"
  end
  if d.braking then
    if now >= d.brakeEnd then
      d.braking, d.brakeEnd, d.factor = false, nil, 1
      d.nextWobble = now + D.wobbleGapMin + rnd() * D.wobbleGapRand
      events[#events + 1] = "brakeEnd"
    end
  elseif now >= d.nextWobble then
    if rnd() < D.brakeChance then
      d.braking = true
      d.brakeEnd = now + D.brakeMin + rnd() * D.brakeRand
      events[#events + 1] = "brake"
    else
      d.factor = D.wobbleMin + rnd() * D.wobbleRand
      d.nextWobble = now + D.wobbleGapMin + rnd() * D.wobbleGapRand
      events[#events + 1] = "speed"
    end
  end
  return events
end

-- Back to a sober state (used when we hand the car back to RLS).
function M.drunkSober(d)
  d.laneOff, d.weaveEnd, d.braking, d.brakeEnd, d.factor = false, nil, false, nil, 1
end

---------------------------------------------------------------------------------------------------
-- Per-car scheduler.

-- A new cache entry for a car seen active for the first time.
function M.newEntry(name, now, rnd)
  local e = {name = name, nextApply = now, respawnCount = nil, eligible = false, lastLimit = nil, hits = 0, touched = false}
  if name == "drunk" then e.drunk = M.newDrunk(now, rnd) end
  return e
end

local function limitMoved(a, b)
  if a == nil and b == nil then return false end
  if a == nil or b == nil then return true end
  return math.abs(a - b) > M.LIMIT_STEP
end

-- Decide whether the car needs its command now. Returns the command string or nil. Updates the entry.
-- veh needs `respawnCount` and `tracking.speedLimit` (m/s).
function M.schedule(e, veh, now, rnd)
  if e.name == "normal" then e.eligible = true return nil end
  local limit = type(veh.tracking) == "table" and tonumber(veh.tracking.speedLimit) or nil
  if limit and limit <= 0 then limit = nil end
  local need = false
  if not e.eligible then need = true end                          -- first time, or back from a skip
  if e.respawnCount ~= veh.respawnCount then need = true end     -- RLS onRefresh reset the parameters
  if now >= e.nextApply then need = true end                     -- periodic re-apply
  if limitMoved(e.lastLimit, limit) then need = true end          -- new road limit: new cap
  if e.drunk and #M.drunkStep(e.drunk, now, rnd) > 0 then need = true end
  e.eligible = true
  e.respawnCount = veh.respawnCount
  if not need then return nil end
  e.lastLimit = limit
  e.nextApply = now + M.REAPPLY + (rnd() * 2 - 1) * M.REAPPLY_JITTER
  e.touched = true
  return M.command(e.name, limit, e.drunk)
end

---------------------------------------------------------------------------------------------------
-- Police reaction.

-- Is this racer / drunk driving badly enough for a nearby cop? (`speed` m/s, `limit` m/s or nil)
function M.suspicious(e, speed, limit, now)
  if e.name ~= "racer" and e.name ~= "drunk" then return false end
  local P = M.POLICE
  speed = tonumber(speed) or 0
  local fast
  if finite(limit) and limit > 0 then
    fast = speed >= math.max(P.minFast, limit * P.fastFactor + P.fastExtra)
  else
    fast = speed >= P.unknownLimitFast
  end
  if fast then return true end
  if e.drunk and speed > 5 and (e.drunk.laneOff or now - e.drunk.lastWeave < P.weaveMemory) then return true end
  return false
end

function M.newLimiter(cooldown) return {cooldown = cooldown or M.POLICE.cooldown, last = -math.huge} end

-- May we start an AI pursuit now? ctx = {playerChased, anyPursuit}. Returns ok, reason.
function M.mayStart(lim, now, ctx)
  ctx = ctx or {}
  if ctx.playerChased then return false, "playerChased" end
  if ctx.anyPursuit then return false, "pursuitRunning" end
  if now - lim.last < lim.cooldown then return false, "cooldown" end
  return true
end

function M.noteStart(lim, now) lim.last = now end

-- Nearest AI police car within `radius` of pos, from a list {id, pos, usable}. Returns id, distance.
function M.nearestPolice(pos, units, radius)
  local best, bestD = nil, radius or M.POLICE.radius
  for _, u in ipairs(units) do
    if u.usable and u.pos then
      local dx, dy, dz = u.pos.x - pos.x, u.pos.y - pos.y, (u.pos.z or 0) - (pos.z or 0)
      local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist <= bestD then best, bestD = u.id, dist end
    end
  end
  return best, best and bestD or nil
end

return M
