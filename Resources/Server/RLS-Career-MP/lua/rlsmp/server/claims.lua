-- RLS-Career-MP server: dashcams, crash judging and insurance claims.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every game watches its OWN car. When that car touches another player's car it sends `rlsmpHit` with a snapshot of both
-- cars at first contact (position, velocity, heading), how many cars were nearby, and the repair price of the damage it took.
-- The server pairs the two reports (one report is enough), works out who drove into whom, and decides if anybody "got caught":
--
--   fault     = whose velocity pointed INTO the other car at first contact (closing speed), 50/50 when both did or neither did
--   caught    = chance = base + dashcam bonus + witnesses nearby. No dashcam and nobody around = a gamble you may win.
--   payout    = damage the other car took x your share of fault x chain multiplier (several accidents in a row cost more)
--   insurance = the at-fault game applies an RLS claim for that amount, which lowers the driver score
--
-- `claims.dryRun` (default on) does all of it but only TELLS players what would have happened; no money, no score change.
-- Dashcams: /dashcam installs one on the car you are in for `claims.dashcamPrice`. Stored here by inventory id + model.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local profiles = require("rlsmp.server.profiles")

local M = {}

local cfg
local pending = {}     -- pairKey -> {reports = {[pid] = report}, first = time}
local lastClaim = {}   -- pairKey -> time of the last judged incident
local faultLog = {}    -- pid -> {times of recent at-fault incidents}
local pendingCar = {}  -- pid -> true while we wait for /dashcam's "which car am I in"

-- Pure helpers ---------------------------------------------------------------------------------------------

local function flat(v)
  return {x = tonumber(v and v[1]) or 0, y = tonumber(v and v[2]) or 0}
end

local function dot(a, b) return a.x * b.x + a.y * b.y end

-- Who drove into whom. a/b = {p = {x,y,z}, v = {x,y,z}}. Returns shareA, shareB (fault, sum 1) and the closing speed in m/s.
function M.judge(a, b)
  local pa, pb, va, vb = flat(a.p), flat(b.p), flat(a.v), flat(b.v)
  local dx, dy = pb.x - pa.x, pb.y - pa.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return 0.5, 0.5, 0 end
  local n = {x = dx / len, y = dy / len}
  local closeA = dot(va, n)                        -- how fast A moves toward B
  local closeB = dot(vb, {x = -n.x, y = -n.y})     -- how fast B moves toward A
  local ca, cb = math.max(closeA, 0), math.max(closeB, 0)
  local closing = closeA + closeB
  if ca + cb < 1e-6 then return 0.5, 0.5, closing end
  return ca / (ca + cb), cb / (ca + cb), closing
end

-- Chance that the verdict sticks ("gets caught").
function M.confidence(dashA, dashB, witnesses, c)
  c = c or cfg.claims
  if dashA and dashB then return 1 end
  local value = c.baseConfidence + math.min(witnesses or 0, c.witnessCap) * c.perWitness
  if dashA or dashB then value = value + c.dashcamBonus end
  return math.max(0, math.min(1, value))
end

local function recordFault(pid, now)
  faultLog[pid] = faultLog[pid] or {}
  table.insert(faultLog[pid], now)
end

local function chainMultiplier(pid, now)
  local list, kept = faultLog[pid] or {}, {}
  for _, t in ipairs(list) do
    if now - t <= cfg.claims.chainWindowSeconds then kept[#kept + 1] = t end
  end
  faultLog[pid] = kept
  local n = #kept
  return math.min(cfg.claims.chainMax, 1 + cfg.claims.chainStep * math.max(0, n - 1)), n
end

local function pairKey(a, b)
  if a > b then a, b = b, a end
  return a .. "|" .. b
end

local function ownerOf(serverId)
  return tonumber(tostring(serverId):match("^(%d+)%-"))
end

-- Judging ----------------------------------------------------------------------------------------------------

local function say(pid, text) MP.SendChatMessage(pid, "[Claim] " .. text) end

local function hasDashcam(session, report)
  local cams = session and session.profile and session.profile.dashcams
  return cams ~= nil and report ~= nil and report.inv ~= nil and cams[tostring(report.inv)] == report.model
end

-- Move money between two online players, debit first.
local function transfer(fromPid, toPid, amount)
  local from, to = sessions.get(fromPid), sessions.get(toPid)
  if not (from and to and amount > 0) then return end
  from.profile.ledger.money = from.profile.ledger.money - amount
  profiles.persist(from.profile)
  net.send(fromPid, "rlsmpWalletSet", {money = from.profile.ledger.money, why = "claim"})
  to.profile.ledger.money = to.profile.ledger.money + amount
  profiles.persist(to.profile)
  net.send(toPid, "rlsmpWalletSet", {money = to.profile.ledger.money, why = "claim"})
end

local function fmt(n) return string.format("$%d", math.floor(n + 0.5)) end

-- reports: {[pid] = report}. a/b are the two player ids involved.
local function resolve(key, entry)
  pending[key] = nil
  local now = util.now()
  local aPid, bPid = entry.a, entry.b
  local ra, rb = entry.reports[aPid], entry.reports[bPid]
  local sa, sb = sessions.get(aPid), sessions.get(bPid)
  if not (sa and sb and sessions.isLoaded(aPid) and sessions.isLoaded(bPid)) then return end
  if lastClaim[key] and now - lastClaim[key] < cfg.claims.pairCooldownSeconds then return end

  -- Each side's own snapshot of its own car is the most accurate; fall back to the other side's view of it.
  local snapA = (ra and ra.mine) or (rb and rb.other)
  local snapB = (rb and rb.mine) or (ra and ra.other)
  if not (snapA and snapB) then return end

  local shareA, shareB, closing = M.judge(snapA, snapB)
  if closing < cfg.claims.minImpactSpeed then return end   -- a scrape or a tap, not an accident
  lastClaim[key] = now

  -- Damage: what each car reports for itself; if a game could not measure it, estimate from the impact speed.
  local estimate = math.min(cfg.claims.maxPayout, cfg.claims.fallbackDamagePerSpeedSq * closing * closing)
  local dmgA = math.min(cfg.claims.maxPayout, tonumber(ra and ra.damage) or estimate)
  local dmgB = math.min(cfg.claims.maxPayout, tonumber(rb and rb.damage) or estimate)

  local dashA, dashB = hasDashcam(sa, ra), hasDashcam(sb, rb)
  local witnesses = math.min(tonumber(ra and ra.nearby) or math.huge, tonumber(rb and rb.nearby) or math.huge)
  if witnesses == math.huge then witnesses = 0 end
  local chance = M.confidence(dashA, dashB, witnesses)
  local caught = math.random() <= chance

  local header = string.format("%s vs %s: closing %.0f m/s, fault %d%% / %d%%, evidence %d%%.",
    tostring(sa.name), tostring(sb.name), closing, math.floor(shareA * 100 + 0.5), math.floor(shareB * 100 + 0.5), math.floor(chance * 100 + 0.5))
  util.info("[claims] " .. header .. (caught and " CAUGHT" or " got away"))

  if not caught then
    say(aPid, "Nobody could prove who caused that crash. No claim. (" .. math.floor(chance * 100 + 0.5) .. "% evidence)")
    say(bPid, "Nobody could prove who caused that crash. No claim. (" .. math.floor(chance * 100 + 0.5) .. "% evidence)")
    return
  end

  local multA, multB = 1, 1
  if shareA >= cfg.claims.faultThreshold then recordFault(aPid, now) multA = chainMultiplier(aPid, now) end
  if shareB >= cfg.claims.faultThreshold then recordFault(bPid, now) multB = chainMultiplier(bPid, now) end
  local payA = math.min(cfg.claims.maxPayout, dmgB * shareA * multA)   -- A pays for B's damage
  local payB = math.min(cfg.claims.maxPayout, dmgA * shareB * multB)

  for _, side in ipairs({{aPid, bPid, sa, sb, payA, shareA, multA}, {bPid, aPid, sb, sa, payB, shareB, multB}}) do
    local payer, receiver, ps, rs, amount, share, mult = side[1], side[2], side[3], side[4], side[5], side[6], side[7]
    if amount >= 1 then
      local text = string.format("%s: %s at fault %d%%%s pays %s.", cfg.claims.dryRun and "TEST MODE" or "Claim", tostring(ps.name),
        math.floor(share * 100 + 0.5), mult > 1 and (" (x" .. string.format("%.1f", mult) .. " repeat accidents)") or "", fmt(amount))
      say(payer, text) say(receiver, text)
      if not cfg.claims.dryRun then
        transfer(payer, receiver, amount)
        net.send(payer, "rlsmpClaimPenalty", {damage = amount})   -- their game files an RLS claim: driver score drops
      end
    end
  end
end

-- Reports -----------------------------------------------------------------------------------------------------

local function onHit(pid, data)
  if not cfg.claims.enabled or not sessions.isLoaded(pid) then return end
  local me, other = tostring(data.me or ""), tostring(data.with or "")
  local mine, theirs = ownerOf(me), ownerOf(other)
  if mine ~= pid or not theirs or theirs == pid then return end    -- only report your own car, against someone else's
  local key = pairKey(me, other)
  local entry = pending[key] or {a = pid, b = theirs, reports = {}, first = util.now()}
  if entry.a ~= pid and entry.b ~= pid then return end
  entry.reports[pid] = data
  pending[key] = entry
  if entry.reports[entry.a] and entry.reports[entry.b] then resolve(key, entry) end
end

function M.tick()
  local now = util.now()
  for key, entry in pairs(pending) do
    if now - entry.first >= cfg.claims.reportWindowSeconds then resolve(key, entry) end
  end
end

-- Dashcams -----------------------------------------------------------------------------------------------------

local function onMyCar(pid, data)
  if not pendingCar[pid] then return end
  pendingCar[pid] = nil
  local s = sessions.get(pid)
  if not (s and s.profile) then return end
  local inv, model = tonumber(data.inv), tostring(data.model or "")
  if not inv or model == "" then return say(pid, "Sit in one of your own cars first.") end
  s.profile.dashcams = s.profile.dashcams or {}
  if s.profile.dashcams[tostring(inv)] == model then return say(pid, "This car already has a dashcam.") end
  local price = cfg.claims.dashcamPrice
  local ledger = s.profile.ledger
  if not ledger.seeded then return say(pid, "Wait for your first save, then try again.") end
  if ledger.money < price then return say(pid, "A dashcam costs " .. fmt(price) .. ".") end
  ledger.money = ledger.money - price               -- debit first
  s.profile.dashcams[tostring(inv)] = model
  profiles.persist(s.profile)
  net.send(pid, "rlsmpWalletSet", {money = ledger.money, why = "dashcam"})
  say(pid, string.format("Dashcam installed on your %s for %s.", tostring(data.name or model), fmt(price)))
end

local function dashcamCommand(pid)
  local s = sessions.get(pid)
  if not s or s.stage ~= "loaded" then return MP.SendChatMessage(pid, "[Claim] Your career is still loading.") end
  pendingCar[pid] = true
  net.send(pid, "rlsmpWhatCar", {})
end

function M.init(config)
  cfg = config
  net.onClient("rlsmpHit", onHit)
  net.onClient("rlsmpMyCar", onMyCar)
  net.onChat("dashcam", dashcamCommand)
  net.on("rlsmpClaimsTick", M.tick)
  MP.CreateEventTimer("rlsmpClaimsTick", 1000)
end

M._pending = function() return pending end
return M
