-- RLS-Career-MP server: car theft (off by default: config theft.enabled).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server does not know anybody's parked cars (each game spawns its own), so it only hands out a seed per period
-- (`rlsmpTheftConfig {enabled, seed, period, perMille, periodSeconds}`); each game hashes (seed, period, rounded position) of
-- its parked cars and marks about perMille/1000 of them stealable. Every game picks the same way, so two players standing at
-- the same parking spot agree. The seed comes from the server tag and the period number (server clock), so it changes every
-- `periodSeconds` and is the same for everyone. It is re-sent when the period changes.
--
-- What the server owns:
--   * the method table (config theft.methods): which tier a car is in (by year and value), which items each method needs,
--     time, noise and failure chance. A method only works on cars of its own tier.
--   * the item check (items.has) before a start, the failure roll at the end, using up non-durable items on success (items.use).
--   * the witness roll, the report time (30-120 s if seen, ~10 min if not, faster with a GPS tracker), stolen[plate] records
--     in stolen.json, and the plate flag when a car is reported (plateRecords.flag through M.reportHook).
--
-- Flow (all documented in docs/PROTOCOL.md "Car theft"). Players use the popup on the interact key (client rlsmp/theft.lua), never chat:
--   client rlsmpTheftCheck {value, year}            -> rlsmpTheftCan {ok, method, label, seconds, noise, methods = [{method, label, seconds}]} (the popup choices)
--   (developer fallback, only with ui.chatCommands) chat /steal [method] -> rlsmpTheftSteal {method}
--   client rlsmpTheftStart {method, value, year}    -> rlsmpTheftGo {ok, method, seconds, noise} or {ok = false, err}
--   client rlsmpTheftFinish {}  (timer ran out)     -> rlsmpTheftResult {ok} or {ok = false, err} (failure roll, items used)
--   client rlsmpTheftDone {plate, model, color, value, year, x, y, z, witnesses}   (after the car was converted)
--   client rlsmpTheftCancel {}                       (walked away)
--   server rlsmpTheftReported {plate}                (the car was reported stolen; nothing else to do on the client)
-- Inspect hint (black market members only, config theft.inspect; the server answers only inside the real distance):
--   client rlsmpTheftHint {id, x, y}                -> rlsmpTheftHint {id, ok = true} ONLY for a member in range at a stealable car (else silence)
--   (developer fallback, only with ui.chatCommands) chat /inspect -> rlsmpTheftInspectAsk {}; the popup's Inspect does the same on the client
--   client rlsmpTheftInspect {id, x, y, value, year}-> rlsmpTheftInspectGo {ok, seconds}  (same for everybody)
--   client rlsmpTheftInspectFinish {}               -> rlsmpTheftInspected {id, found, text}  (non-members and boring cars get the same text)

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local storage = require("rlsmp.server.storage")
local items = require("rlsmp.server.items")
local positions = require("rlsmp.server.positions")
local market = require("rlsmp.server.market")

local M = {}

local cfg            -- config.theft
local fenceCfg       -- config.fence (maxValue, modelCaps: the server's own limits on the client's car value)
local serverTag = ""
local file
local stolen = {}    -- plate -> record
local pending = {}   -- pid -> {accountId, method, seconds, noise, tier, value, year, started, state = "running" | "open", openedAt}
local cooldown = {}  -- pid -> time before which no new start is accepted
local told = {}      -- pid -> period the config was sent for
local lastCheck = {} -- pid -> time of the last answered check (rate limit)
local inspecting = {} -- pid -> {accountId, id, x, y, value, year, started, seconds}
local inspectNext = {} -- pid -> time before which no new inspect starts
local lastHint = {}  -- pid -> time of the last answered hint request (rate limit)

local random = math.random
function M.setRandom(fn) random = fn or math.random end

local TIER_ORDER = {"old", "immobilizer", "keyless", "luxury"}

local function n(v, default)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
  return v
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function enabled() return cfg ~= nil and cfg.enabled == true end

-- Same rules as plateRecords.cleanPlate (both modules must agree on what a plate is).
function M.cleanPlate(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):upper()
  if #s == 0 or #s > 16 or s:find("[%c|]") then return nil end
  return s
end
local function cleanModel(s)
  if type(s) ~= "string" or #s == 0 or #s > 64 or s:find("[^%w_%-%.]") then return nil end
  return s
end
local function cleanColor(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  if #s == 0 or #s > 24 or s:find("[^%a ]") then return nil end
  return s
end

-- Client-reported car value and year, made sane.
function M.cleanValue(v) return clamp(math.floor(n(v, 0)), 0, 100000000) end
-- The server cannot read the game's catalog, so the client's value is capped: fence.maxValue, and fence.modelCaps[model] when set.
function M.capValue(model, value)
  local f = fenceCfg or {}
  local cap = n(f.maxValue, 300000)
  local mc = type(f.modelCaps) == "table" and tonumber(f.modelCaps[model]) or nil
  if mc and mc > 0 then cap = math.min(cap, mc) end
  return math.min(M.cleanValue(value), math.floor(cap))
end
function M.cleanSource(v) return type(v) == "string" and v ~= "" and v:sub(1, 100):gsub("[^%w%._ /%-%(%)]", "") or nil end
function M.cleanYear(y)
  y = math.floor(n(y, 0))
  if y < 1900 or y > 2100 then return nil end
  return y
end

-- Tier of a car by year and value (config theft.tiers). Unknown year counts as the immobilizer era.
function M.tierFor(value, year)
  local t = cfg.tiers
  year = M.cleanYear(year) or n(t.unknownYear, 2000)
  value = M.cleanValue(value)
  if year < n(t.immobilizerYear, 1995) then return "old" end
  if year < n(t.keylessYear, 2010) then return "immobilizer" end
  if value >= n(t.luxuryValue, 120000) or year >= n(t.newestYear, 2021) then return "luxury" end
  return "keyless"
end

-- Methods of a tier, sorted by name (stable order for picking the first usable one).
function M.methodsFor(tier)
  local out = {}
  for name, m in pairs(cfg.methods) do
    if type(m) == "table" and m.tier == tier and m.enabled ~= false then out[#out + 1] = name end
  end
  table.sort(out, function(a, b)
    local ma, mb = cfg.methods[a], cfg.methods[b]
    local oa, ob = n(ma.order, 99), n(mb.order, 99)
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  return out
end

local function itemList(m)
  local out = {}
  for _, it in ipairs(type(m.items) == "table" and m.items or {}) do
    if type(it) == "string" then out[#out + 1] = it end
  end
  return out
end

-- Items the player lacks for a method (empty = they have everything).
function M.missing(pid, method)
  local m = cfg.methods[method]
  local out = {}
  for _, it in ipairs(m and itemList(m) or {}) do
    if not items.has(pid, it) then out[#out + 1] = it end
  end
  return out
end

local function labelOf(name)
  local c = items.CATALOG[name]
  return c and c.label or name
end

-- A signal jammer (owned, durable) silences the alarm of a method marked `alarm = true`.
local function noiseFor(m, pid)
  local noise = clamp(n(m.noise, 0.5), 0, 1)
  if m.alarm == true and pid and items.has(pid, "jammer") then
    noise = noise * clamp(n(cfg.jammerNoiseFactor, 0.25), 0, 1)
  end
  return noise
end

local function methodInfo(name, pid)
  local m = cfg.methods[name]
  return {
    method = name,
    label = type(m.label) == "string" and m.label or name,
    seconds = math.floor(clamp(n(m.seconds, 10), 1, 600)),
    noise = noiseFor(m, pid),
    jammed = m.alarm == true and pid ~= nil and items.has(pid, "jammer"),
    failChance = clamp(n(m.failChance, 0), 0, 1),
    tracker = m.tracker == true,
  }
end

-- The method a player would use on a car: the requested one (must fit the car's tier and be owned), or the first usable one.
-- Returns info table, or nil + error text.
function M.choose(pid, value, year, wanted)
  local tier = M.tierFor(value, year)
  local list = M.methodsFor(tier)
  if #list == 0 then return nil, "Nothing you know works on this car." end
  if type(wanted) == "string" and wanted ~= "" then
    local m = cfg.methods[wanted]
    if type(m) ~= "table" or m.enabled == false then return nil, "Unknown method: " .. wanted end
    if m.tier ~= tier then return nil, "That method does not work on this car (" .. tier .. ")." end
    list = {wanted}
  end
  local firstMissing
  for _, name in ipairs(list) do
    local lack = M.missing(pid, name)
    if #lack == 0 then
      local info = methodInfo(name, pid)
      info.tier = tier
      return info
    end
    firstMissing = firstMissing or lack
  end
  local labels = {}
  for _, it in ipairs(firstMissing) do labels[#labels + 1] = labelOf(it) end
  return nil, "You need: " .. table.concat(labels, ", ")
end

-- Every method that works on this car and whose tools the player has, in order: list of {method, label, seconds}.
function M.usable(pid, value, year)
  local tier = M.tierFor(value, year)
  local out = {}
  for _, name in ipairs(M.methodsFor(tier)) do
    if #M.missing(pid, name) == 0 then
      local info = methodInfo(name, pid)
      out[#out + 1] = {method = info.method, label = info.label, seconds = info.seconds}
    end
  end
  return out
end

-- Witness roll: chance grows with nearby witnesses and noise. Returns seen (bool), chance.
function M.witnessChance(witnesses, noise)
  local w = clamp(math.floor(n(witnesses, 0)), 0, math.max(0, math.floor(n(cfg.witnessCap, 5))))
  local chance = n(cfg.baseWitnessChance, 0.15) + n(cfg.perWitness, 0.12) * w + n(cfg.noiseWitness, 0.3) * clamp(n(noise, 0), 0, 1)
  return clamp(chance, 0, n(cfg.maxWitnessChance, 0.95))
end

function M.rollWitness(witnesses, noise)
  local chance = M.witnessChance(witnesses, noise)
  return random() < chance, chance
end

-- Seconds until the car is reported. seen: 30-120 s (config), not seen: about 10 minutes. A tracker reports quickly unless blocked.
function M.reportDelay(seen, tracker)
  local d
  if seen then
    local lo = math.max(1, math.floor(n(cfg.seenReportMin, 30)))
    local hi = math.max(lo, math.floor(n(cfg.seenReportMax, 120)))
    d = lo + math.floor(random() * (hi - lo + 1))
    if d > hi then d = hi end
  else
    d = math.max(1, math.floor(n(cfg.unseenReportSeconds, 600)))
  end
  if tracker then d = math.min(d, math.max(1, math.floor(n(cfg.trackerReportSeconds, 20)))) end
  return d
end

-- The seed for a period: small integer, the same for every player (from the server tag), different every period.
local function tagSeed(tag)
  local s = 0
  for i = 1, #(tag or "") do s = (s * 31 + tag:byte(i)) % 1000003 end
  return s
end
function M.periodSeconds() return math.max(60, math.floor(n(cfg.periodSeconds, 3600))) end
function M.periodAt(epoch) return math.floor(epoch / M.periodSeconds()) end
function M.seedFor(period) return (tagSeed(serverTag) * 7919 + period * 104729) % 1000003 end

-- The same pick as the client (rlsmp/lib/theft.lua stealable): FNV-1a over "seed|period|cellX|cellY", 4 m cells. Used so the server can
-- answer hints and scout tips from the real rule without trusting the client.
local CELL = 4
local function fnv(str)
  local h = 2166136261
  for i = 1, #str do h = ((h ~ str:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h
end
M.hash = fnv
function M.stealableAt(period, pos)
  local pm = clamp(math.floor(n(cfg.perMille, 150)), 0, 1000)
  local x, y = n(pos and pos.x, nil), n(pos and pos.y, nil)
  if pm <= 0 or not x or not y then return false end
  period = math.floor(period)
  return fnv(string.format("%d|%d|%d|%d", math.floor(M.seedFor(period)), period, math.floor(x / CELL), math.floor(y / CELL))) % 1000 < pm
end

-- Inspect settings, clamped.
function M.inspectCfg()
  local i = type(cfg.inspect) == "table" and cfg.inspect or {}
  return {enabled = enabled() and i.enabled ~= false, range = clamp(n(i.range, 15), 3, 100),
    seconds = math.floor(clamp(n(i.seconds, 3), 1, 30)), cooldown = clamp(n(i.cooldown, 2), 0, 60)}
end

function M.payload()
  local period = M.periodAt(util.now())
  local ic = M.inspectCfg()
  return {enabled = enabled(), seed = M.seedFor(period), period = period,
    perMille = clamp(math.floor(n(cfg.perMille, 150)), 0, 1000), periodSeconds = M.periodSeconds(),
    radius = clamp(n(cfg.radius, 3), 1, 10), inspect = {enabled = ic.enabled, range = ic.range}}
end

local function save() if file then storage.writeJson(file, {stolen = stolen}) end end

function M.records() return stolen end
function M.isEnabled() return enabled() end

-- For the fence (server/fence.lua): take a record out of memory (nothing is written yet), put it back, write the file.
function M.take(plate)
  local rec = stolen[plate]
  stolen[plate] = nil
  return rec
end
function M.put(rec) if type(rec) == "table" and rec.plate then stolen[rec.plate] = rec end end
M.save = save
function M.pendingOf(pid) return pending[pid] end

-- Called when a stolen car is reported. Replaceable (tests, later modules). Default: flag the plate in plateRecords if present.
local function defaultReportHook(rec)
  local ok, plates = pcall(require, "rlsmp.server.plateRecords")
  if ok and type(plates) == "table" and type(plates.flag) == "function" then
    local fine, err = pcall(plates.flag, rec.plate, rec.model, rec.color, "stolen", rec.by)
    if not fine then util.warn("[theft] plateRecords.flag failed: " .. tostring(err)) end
    return fine
  end
  return false
end
M.reportHook = defaultReportHook

local function accountOf(pid)
  local s = sessions.get(pid)
  return s and s.accountId or nil
end

-- Repricing: RLS's used-car market moves over time, so the owner's game works the value out again every theft.repriceMinutes and sends it
-- (rlsmpTheftValue). Records from before the value fix have no valueSource: their first answer may jump, up to the fence caps.
function M.repriceSeconds() return math.max(60, math.floor(n(cfg and cfg.repriceMinutes, 30) * 60)) end
function M.maxStep() return clamp(n(cfg and cfg.maxRepriceStep, 25), 1, 1000) / 100 end
local function fallback(rec)
  return rec.valueSource == nil or n(rec.value, 0) <= n(fenceCfg and fenceCfg.minValue, 2000)
end
function M.isStale(rec) return util.now() - n(rec.vt, 0) >= M.repriceSeconds() or rec.valueSource == nil end
local asked, capable = {}, {}      -- plate -> time of the last ask; pid -> true once that player's game answered (an old game never does)

-- Ask the owner's game for fresh values of stale records. Returns true when something was asked. `soon` = also ask if asked 15+ s ago.
function M.repriceAsk(pid, soon)
  local acc = accountOf(pid)
  if not acc or not enabled() then return false end
  local now, cars = util.now(), {}
  for plate, rec in pairs(stolen) do
    if rec.by == acc and M.isStale(rec) and now - n(asked[plate], -1e9) >= (soon and 15 or 60) then
      asked[plate] = now
      cars[#cars + 1] = {plate = plate, model = rec.model, config = rec.config}
    end
  end
  if #cars == 0 then return false end
  net.send(pid, "rlsmpTheftReprice", {cars = cars})
  return true
end

-- Before a quote or a payment: true when the value is fresh enough (or the player's game cannot answer). Otherwise it asks and returns false once.
function M.fresh(pid, rec)
  if not M.isStale(rec) or not capable[pid] then return true end
  local t = asked[rec.plate]
  if t and util.now() - t >= 15 and util.now() - t < 60 then return true end   -- asked and no answer: go on with the stored value
  M.repriceAsk(pid, true)
  return false
end

local function onValue(pid, d)
  if type(d) ~= "table" or not enabled() then return end
  local plate = M.cleanPlate(d.plate)
  local rec = plate and stolen[plate]
  if not rec or rec.by ~= accountOf(pid) then return end
  capable[pid] = true
  local now = util.now()
  if rec.valueSource ~= nil and now - n(rec.vt, 0) < M.repriceSeconds() / 2 then return end     -- too early: abuse guard
  local v = M.capValue(rec.model, d.value)
  if v <= 0 then return end
  local old = n(rec.value, 0)
  if not fallback(rec) and old > 0 then
    local step = M.maxStep()
    v = clamp(v, math.floor(old * (1 - step)), math.ceil(old * (1 + step)))
    v = M.capValue(rec.model, v)
  end
  rec.prevValue, rec.value, rec.vt = old, v, now
  rec.valueSource = M.cleanSource(d.source) or "client"
  asked[plate] = nil
  save()
  util.info(string.format("[theft] value of %s %s: %d -> %d (%s)", tostring(rec.model), plate, old, v, rec.valueSource))
end

local function chat(pid, msg) if MP and MP.SendChatMessage then MP.SendChatMessage(pid, "[Theft] " .. msg) end end

-- Handlers -----------------------------------------------------------------------------------------

local function onCheck(pid, d)
  if not enabled() or not sessions.isLoaded(pid) then return end
  local now = util.now()
  if lastCheck[pid] == now then return end   -- at most one answer per second
  lastCheck[pid] = now
  local info, err = M.choose(pid, d.value, d.year, nil)
  if info then
    net.send(pid, "rlsmpTheftCan", {ok = true, id = n(d.id, nil), method = info.method, label = info.label, seconds = info.seconds,
      noise = info.noise, methods = M.usable(pid, d.value, d.year)})
  else
    net.send(pid, "rlsmpTheftCan", {ok = false, id = n(d.id, nil), err = err})
  end
end

-- Inspect hint ---------------------------------------------------------------------------------------
-- The car's x/y come from the client, but the player's own server-side position (positions.lua) must be within range of them, and
-- the pick is judged here with the same rule as the client. A non-member, a boring car or a player too far away gets no hint at all.

local MAX_POS_AGE = 20

local function carNear(pid, d, ic)
  local x, y = n(d.x, nil), n(d.y, nil)
  local pos = positions.get(pid)
  if not (x and y and pos) or util.now() - pos.t > MAX_POS_AGE then return nil end
  if math.sqrt((pos.x - x) ^ 2 + (pos.y - y) ^ 2) > ic.range + 5 then return nil end   -- +5: the last report is a moment old
  return {x = x, y = y}
end

local function onHint(pid, d)
  local ic = M.inspectCfg()
  if not ic.enabled or type(d) ~= "table" or not sessions.isLoaded(pid) or not market.isMember(pid) then return end
  local now = util.now()
  if lastHint[pid] == now then return end
  lastHint[pid] = now
  local car = carNear(pid, d, ic)
  if car and M.stealableAt(M.periodAt(now), car) then net.send(pid, "rlsmpTheftHint", {id = n(d.id, nil), ok = true}) end
end

local BORING = "Just a parked car. Nothing stands out."

-- What a member learns about a stealable car: tier, the ways in (missing tools named), rough risk.
function M.inspectText(pid, value, year)
  local tier = M.tierFor(value, year)
  local ways, alarm, tracker, loud = {}, false, false, false
  for _, name in ipairs(M.methodsFor(tier)) do
    local m = cfg.methods[name]
    local lack = M.missing(pid, name)
    local labels = {}
    for _, it in ipairs(lack) do labels[#labels + 1] = labelOf(it) end
    ways[#ways + 1] = (type(m.label) == "string" and m.label or name) .. (#lack == 0 and " (you have the tools)" or " (missing: " .. table.concat(labels, ", ") .. ")")
    alarm, tracker, loud = alarm or m.alarm == true, tracker or m.tracker == true, loud or n(m.noise, 0) >= 0.6
  end
  local risk = {}
  if alarm then risk[#risk + 1] = "alarm" end
  if tracker then risk[#risk + 1] = "GPS tracker" end
  if loud then risk[#risk + 1] = "loud" end
  return string.format("Easy mark, %s car. Ways in: %s. Risk: %s.", tier, #ways > 0 and table.concat(ways, "; ") or "none you know",
    #risk > 0 and table.concat(risk, ", ") or "low")
end

local function onInspect(pid, d)
  local ic = M.inspectCfg()
  if not ic.enabled or type(d) ~= "table" or not sessions.isLoaded(pid) then return end
  local now = util.now()
  if inspectNext[pid] and now < inspectNext[pid] then return end
  inspectNext[pid] = now + ic.cooldown
  inspecting[pid] = {accountId = accountOf(pid), id = n(d.id, nil), x = n(d.x, nil), y = n(d.y, nil), value = M.cleanValue(d.value),
    year = M.cleanYear(d.year), started = now, seconds = ic.seconds}
  net.send(pid, "rlsmpTheftInspectGo", {ok = true, seconds = ic.seconds})   -- the same for everybody and every car
end

local function onInspectFinish(pid)
  local p = inspecting[pid]
  if not p or p.accountId ~= accountOf(pid) then return end
  inspecting[pid] = nil
  local ic = M.inspectCfg()
  if not ic.enabled or util.now() - p.started < p.seconds - 1 then return end
  local found = market.isMember(pid) and carNear(pid, p, ic) ~= nil and M.stealableAt(M.periodAt(util.now()), p)
  net.send(pid, "rlsmpTheftInspected", {id = p.id, found = found == true, text = found and M.inspectText(pid, p.value, p.year) or BORING})
end

local function onInspectChat(pid)
  if not M.inspectCfg().enabled then return chat(pid, "Car theft is off on this server.") end
  if sessions.isLoaded(pid) then net.send(pid, "rlsmpTheftInspectAsk", {}) end
end

local function goFail(pid, err) net.send(pid, "rlsmpTheftGo", {ok = false, err = err}) end

local function onStart(pid, d)
  if not enabled() then return goFail(pid, "Car theft is off on this server.") end
  if not sessions.isLoaded(pid) then return goFail(pid, "Not in career.") end
  local now = util.now()
  local p = pending[pid]
  if p and p.accountId == accountOf(pid) and now - p.started < p.seconds + 60 then return goFail(pid, "You are already busy.") end
  if cooldown[pid] and now < cooldown[pid] then return goFail(pid, "Wait a moment before trying again.") end
  local info, err = M.choose(pid, d.value, d.year, d.method)
  if not info then return goFail(pid, err) end
  pending[pid] = {accountId = accountOf(pid), method = info.method, seconds = info.seconds, noise = info.noise,
    failChance = info.failChance, tracker = info.tracker, tier = info.tier, value = M.cleanValue(d.value),
    year = M.cleanYear(d.year), started = now, state = "running"}
  util.info(string.format("[theft] %s starts %s on a %s car (%ds)", tostring(pid), info.method, info.tier, info.seconds))
  net.send(pid, "rlsmpTheftGo", {ok = true, method = info.method, label = info.label, seconds = info.seconds, noise = info.noise})
end

local function onCancel(pid)
  if pending[pid] and pending[pid].state == "running" then pending[pid] = nil end
end

local function resultFail(pid, err)
  pending[pid] = nil
  cooldown[pid] = util.now() + math.max(0, math.floor(n(cfg.retrySeconds, 10)))
  net.send(pid, "rlsmpTheftResult", {ok = false, err = err})
end

local function onFinish(pid)
  local p = pending[pid]
  if not p or p.state ~= "running" or p.accountId ~= accountOf(pid) then return end
  local now = util.now()
  if now - p.started < p.seconds - 1 then return resultFail(pid, "Too fast.") end
  -- The tools must still be there (a check now, so nothing is used up when one is missing).
  if #M.missing(pid, p.method) > 0 then return resultFail(pid, "You no longer have the tools.") end
  if random() < p.failChance then
    util.info(string.format("[theft] %s: %s failed", tostring(pid), p.method))
    return resultFail(pid, "It did not work. Try again or walk away.")
  end
  for _, it in ipairs(itemList(cfg.methods[p.method])) do items.use(pid, it) end
  p.state, p.openedAt = "open", now
  net.send(pid, "rlsmpTheftResult", {ok = true})
end

-- What the client sent to rebuild the car later (config, three paints, rotation; docs/PROTOCOL.md "Stolen car restore"). Everything is
-- cleaned: unknown shapes are dropped, numbers are finite and small. Written into rec.car and rec.last.
local function cleanNum(v, lim)
  v = n(v, nil)
  if v == nil or math.abs(v) > lim then return nil end
  return v
end
function M.rememberCar(rec, d)
  local car = {}
  if type(d.config) == "string" and #d.config <= 160 and not d.config:find("[^%w_%-%./ ]") then car.config = d.config end
  if type(d.look) == "table" then
    car.look = {}
    for i = 1, 3 do
      local c = d.look[i]
      if type(c) == "table" then
        local out = {x = cleanNum(c.x, 1e3), y = cleanNum(c.y, 1e3), z = cleanNum(c.z, 1e3), w = cleanNum(c.w, 1e3)}
        if out.x and out.y and out.z and out.w then
          if type(c.m) == "table" then
            out.m = {}
            local count = 0
            for k, v in pairs(c.m) do
              if type(k) == "string" and #k <= 24 and not k:find("[^%w_]") and cleanNum(v, 1e6) and count < 8 then out.m[k], count = v, count + 1 end
            end
          end
          car.look[i] = out
        end
      end
    end
  end
  rec.car = car
  local r = type(d.rot) == "table" and {x = cleanNum(d.rot.x, 2), y = cleanNum(d.rot.y, 2), z = cleanNum(d.rot.z, 2), w = cleanNum(d.rot.w, 2)} or nil
  rec.last = {x = rec.pos.x, y = rec.pos.y, z = rec.pos.z, rot = r and r.x and r.y and r.z and r.w and r or nil, t = util.now()}
end

local function onDone(pid, d)
  local p = pending[pid]
  if not p or p.state ~= "open" or p.accountId ~= accountOf(pid) then return end
  local now = util.now()
  pending[pid] = nil
  cooldown[pid] = now + math.max(0, math.floor(n(cfg.retrySeconds, 10)))
  if now - p.openedAt > 120 then return end
  local plate, model = M.cleanPlate(d.plate), cleanModel(d.model)
  if not plate or not model then
    util.warn("[theft] done without a usable plate/model from " .. tostring(pid))
    return
  end
  local tracker = p.tracker and not items.has(pid, "tracker_blocker")
  if p.tracker and not tracker then chat(pid, "Your tracker blocker killed the GPS tracker.") end
  local value = M.capValue(model, p.value)
  local seen, chance = M.rollWitness(d.witnesses, p.noise)
  local delay = M.reportDelay(seen, tracker)
  local s = sessions.get(pid)
  stolen[plate] = {
    plate = plate, model = model, color = cleanColor(d.color), value = value, year = p.year,
    valueSource = M.cleanSource(d.valueSource) or "client", vt = now, config = M.cleanSource(d.config),
    pos = {x = n(d.x, 0), y = n(d.y, 0), z = n(d.z, 0)}, method = p.method, tier = p.tier,
    by = p.accountId, name = s and s.name or nil, t = now, seen = seen, tracker = tracker == true,
    reportAt = now + delay, reported = false,
  }
  M.rememberCar(stolen[plate], d)
  save()
  util.info(string.format("[theft] %s stole %s %s (%s, %s), seen=%s (%.0f%%), report in %ds",
    tostring(s and s.name or pid), model, plate, p.tier, p.method, tostring(seen), chance * 100, delay))
  chat(pid, "You are in. Drive away and keep a low profile.")
end

-- Report due cars, prune old ones. Returns the reported records (for tests and logs).
function M.reportDue()
  local now, out = util.now(), {}
  local keep = math.max(1, n(cfg.keepHours, 48)) * 3600
  local changed = false
  for plate, rec in pairs(stolen) do
    if not rec.reported and n(rec.reportAt, 0) <= now then
      rec.reported, rec.reportedAt = true, now
      changed = true
      out[#out + 1] = rec
      util.info(string.format("[theft] %s %s reported stolen (%s)", tostring(rec.model), plate, rec.seen and "seen" or "found missing"))
      local ok, err = pcall(M.reportHook, rec)
      if not ok then util.warn("[theft] report hook failed: " .. tostring(err)) end
      for pid in pairs(sessions.all()) do
        if accountOf(pid) == rec.by and sessions.isLoaded(pid) then net.send(pid, "rlsmpTheftReported", {plate = plate}) end
      end
    elseif now - n(rec.t, now) > keep then
      stolen[plate] = nil
      changed = true
    end
  end
  if changed then save() end
  return out
end

function M.pushConfig()
  local live = {}
  local payload
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      payload = payload or M.payload()
      if told[pid] ~= payload.period then
        told[pid] = payload.period
        net.send(pid, "rlsmpTheftConfig", payload)
      end
    end
  end
  for pid in pairs(told) do if not live[pid] then told[pid], pending[pid], cooldown[pid], lastCheck[pid] = nil, nil, nil, nil
    inspecting[pid], inspectNext[pid], lastHint[pid] = nil, nil, nil end end
end

local offTold = false

-- Settings the menu changed: send the config again (also the "theft is off now" one, once).
function M.resend() told = {} offTold = false end

function M.tick()
  if not enabled() then
    -- switched off while players are in: tell every game once, so no prompt stays on screen
    if not offTold then
      offTold = true
      M.pushConfig()
    end
    return
  end
  offTold = false
  M.pushConfig()
  M.reportDue()
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then M.repriceAsk(pid) end
  end
end

local function onSteal(pid, rest)
  if not enabled() then return chat(pid, "Car theft is off on this server.") end
  if not sessions.isLoaded(pid) then return end
  rest = tostring(rest or "")
  if rest == "stop" or rest == "cancel" then
    onCancel(pid)
    net.send(pid, "rlsmpTheftSteal", {stop = true})
    return
  end
  net.send(pid, "rlsmpTheftSteal", {method = rest ~= "" and rest or nil})
end

function M.init(config, pluginRoot)
  cfg = config.theft
  fenceCfg = config.fence
  serverTag = tostring(config.serverTag or "")
  stolen, pending, cooldown, told, lastCheck = {}, {}, {}, {}, {}
  asked, capable = {}, {}
  inspecting, inspectNext, lastHint = {}, {}, {}
  file = pluginRoot and (pluginRoot .. "stolen.json") or nil
  offTold = false
  -- Always listening: every handler checks enabled() itself, so the in-game menu can switch theft on and off without a restart.
  local saved = file and storage.readJson(file)
  if type(saved) == "table" and type(saved.stolen) == "table" then
    for plate, rec in pairs(saved.stolen) do
      if type(rec) == "table" and M.cleanPlate(plate) == plate then stolen[plate] = rec end
    end
  end
  net.onClient("rlsmpTheftCheck", onCheck)
  net.onClient("rlsmpTheftStart", onStart)
  net.onClient("rlsmpTheftFinish", onFinish)
  net.onClient("rlsmpTheftDone", onDone)
  net.onClient("rlsmpTheftValue", onValue)
  net.onClient("rlsmpTheftCancel", onCancel)
  net.onClient("rlsmpTheftHint", onHint)
  net.onClient("rlsmpTheftInspect", onInspect)
  net.onClient("rlsmpTheftInspectFinish", onInspectFinish)
  net.onChat("steal", onSteal, true)
  net.onChat("inspect", onInspectChat, true)
  net.on("rlsmpTheftTick", M.tick)
  MP.CreateEventTimer("rlsmpTheftTick", 1000)
  util.info(enabled() and string.format("Car theft on: %d per mille of parked cars, new pick every %d min", M.payload().perMille, M.periodSeconds() // 60)
    or "Car theft is off (switch it on in the traffic menu or with theft.enabled in config.json)")
end

M.TIER_ORDER = TIER_ORDER
return M
