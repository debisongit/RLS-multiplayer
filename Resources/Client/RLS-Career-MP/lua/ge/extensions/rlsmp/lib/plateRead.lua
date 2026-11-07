-- RLS-Career-MP client: plate reading rules (plain module, no game calls; tests: tests/plate_read_lib_test.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Used by rlsmp_plates. Everything that decides something lives here so it can be tested without the game:
-- which police unit can read the plate, the read timer, the "chase or not" decision, colour names.

local M = {}

M.OFFENSE_KEY = "wantedPlate"

-- Defaults, also the limits a server value is clamped to ({default, min, max}).
local LIMITS = {
  rangeMeters = {15, 3, 60},
  maxSpeedKmh = {50, 5, 200},
  minSeconds = {3, 0.5, 60},
  maxSeconds = {6, 0.5, 60},
  readChance = {0.35, 0, 1},
  afterEscapeChance = {1, 0, 1},
  afterEscapeSeconds = {1200, 0, 86400},
  encounterSeconds = {60, 5, 3600},
  copCooldownSeconds = {300, 5, 86400},
  skipChance = {0.2, 0, 1},
  retriggerSeconds = {120, 10, 86400},
  offenseScore = {400, 1, 100000},
}

local function num(v, lim)
  v = tonumber(v)
  if not v or v ~= v or v == math.huge or v == -math.huge then return lim[1] end
  if v < lim[2] then return lim[2] end
  if v > lim[3] then return lim[3] end
  return v
end

-- The server's rlsmpPlateConfig body -> a clean settings table (bad or missing values get the defaults).
function M.sanitizeConfig(data)
  data = type(data) == "table" and data or {}
  local out = {enabled = data.enabled == true}
  for name, lim in pairs(LIMITS) do out[name] = num(data[name], lim) end
  if out.maxSeconds < out.minSeconds then out.maxSeconds = out.minSeconds end
  return out
end

-- Plate text as the server keys it: trimmed, upper case, inner spaces collapsed. nil if empty or odd.
function M.cleanPlate(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):upper()
  if #s == 0 or #s > 16 or s:find("[%c|]") then return nil end
  return s
end

function M.key(plate, model) return tostring(plate) .. "|" .. tostring(model) end

-- BeamNG live colours (obj.color) are linear; paint configs (baseColor) are sRGB-like.
function M.srgbFromLinear(c)
  c = tonumber(c) or 0
  if c <= 0 then return 0 end
  if c >= 1 then return 1 end
  return c ^ (1 / 2.2)
end

-- A plain colour name from 0..1 sRGB values (what a witness would say). nil if the input is not numbers.
function M.colorName(r, g, b)
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not r or not g or not b then return nil end
  local function c01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
  r, g, b = c01(r), c01(g), c01(b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local v, d = mx, mx - mn
  local s = mx == 0 and 0 or d / mx
  if v < 0.15 then return "black" end
  if s < 0.18 then
    if v > 0.85 then return "white" end
    if v > 0.55 then return "silver" end
    return "grey"
  end
  local h
  if mx == r then h = 60 * (((g - b) / d) % 6)
  elseif mx == g then h = 60 * ((b - r) / d + 2)
  else h = 60 * ((r - g) / d + 4) end
  if h < 15 or h >= 345 then return "red" end
  if h < 40 then return v < 0.6 and "brown" or "orange" end
  if h < 70 then return "yellow" end
  if h < 165 then return "green" end
  if h < 200 then return "teal" end
  if h < 255 then return "blue" end
  if h < 290 then return "purple" end
  return "pink"
end

-- The AI police unit that can read the player's plate right now, using RLS's own per-unit knowledge
-- (trafficPoliceRole.lua onTrafficTick: role.validTargets[id] = {dist = SQUARED distance, interDist, visible}).
-- Units that are disabled, chasing, or whose object is inactive are skipped (same rules as RLS's getNearestPoliceVehicle).
-- isActive(id) is optional (be:getObjectActive). Returns id, squared distance.
function M.nearestReader(traffic, playerId, rangeSq, isActive)
  local bestId, bestD
  for id, veh in pairs(traffic or {}) do
    local role = type(veh) == "table" and veh.role
    if id ~= playerId and type(role) == "table" and role.name == "police" and veh.isAi ~= false
      and role.state ~= "disabled" and not (type(role.flags) == "table" and role.flags.pursuit) then
      local t = type(role.validTargets) == "table" and role.validTargets[playerId]
      local d = type(t) == "table" and tonumber(t.dist)
      if d and t.visible == true and d <= rangeSq and (not isActive or isActive(id)) and (not bestD or d < bestD) then
        bestId, bestD = id, d
      end
    end
  end
  return bestId, bestD
end

function M.newReader()
  return {cop = nil, need = 0, got = 0, encounters = {}, copDone = {}}
end

-- One check of the read timer.
-- cand = nil (no unit in range, player too fast, ...) or {copId, recentEscape}.
-- Returns: nil (nothing going on), "reset" (a read was going and stopped), "reading", fraction, or "done", copId.
-- A unit that comes near decides once per encounterSeconds whether it reads at all (readChance, or
-- afterEscapeChance shortly after an escape). A unit that finished a read leaves this player alone for copCooldownSeconds.
function M.update(r, now, dt, cand, cfg, rnd)
  rnd = rnd or math.random
  local cop = cand and cand.copId
  if cop and r.copDone[cop] and now < r.copDone[cop] then cop = nil end
  if cop and r.cop ~= cop then
    local enc = r.encounters[cop]
    if not enc or now >= enc.untilT then
      local chance = cand.recentEscape and cfg.afterEscapeChance or cfg.readChance
      enc = {read = rnd() < chance, untilT = now + cfg.encounterSeconds}
      r.encounters[cop] = enc
    end
    if not enc.read then cop = nil end
  end
  if not cop then
    if r.cop then
      r.cop, r.got, r.need = nil, 0, 0
      return "reset"
    end
    return nil
  end
  if r.cop ~= cop then   -- a new read (another unit taking over starts from zero)
    r.cop, r.got = cop, 0
    r.need = cfg.minSeconds + rnd() * (cfg.maxSeconds - cfg.minSeconds)
    return "reading", 0
  end
  r.got = r.got + (dt or 0)
  if r.got >= r.need then
    r.copDone[cop] = now + cfg.copCooldownSeconds
    r.cop, r.got, r.need = nil, 0, 0
    return "done", cop
  end
  return "reading", r.need > 0 and r.got / r.need or 1
end

-- Forget encounter / cooldown entries that ran out (keeps the tables small on a long session).
function M.prune(r, now)
  for id, enc in pairs(r.encounters) do if now >= enc.untilT then r.encounters[id] = nil end end
  for id, t in pairs(r.copDone) do if now >= t then r.copDone[id] = nil end end
end

-- "7AB____": the letters read so far (flavour only; the fraction is the real progress).
function M.mask(plate, fraction)
  plate = tostring(plate or "")
  local n = math.floor(#plate * math.max(0, math.min(1, tonumber(fraction) or 0)))
  return plate:sub(1, n) .. plate:sub(n + 1):gsub("[^ ]", "_")
end

-- After a read: start a chase? Returns true, or false + why ("clean", "cooldown", "skipped").
-- The cooldown is our own: RLS wipes the whole pursuit table when a chase ends, so it cannot remember.
function M.decideChase(flagged, cooldowns, key, now, cfg, rnd)
  rnd = rnd or math.random
  if not flagged then return false, "clean" end
  if cooldowns[key] and now < cooldowns[key] then return false, "cooldown" end
  cooldowns[key] = now + cfg.retriggerSeconds
  if rnd() < cfg.skipChance then return false, "skipped" end
  return true
end

-- RLS also calls evadeVehicle when a chase stalls (career/police/playerDriving.lua: player stopped, police not
-- closing for 10 s; the evade timer is still 0 then). That is not a real escape.
function M.isStalemate(pursuitData)
  local timers = type(pursuitData) == "table" and type(pursuitData.timers) == "table" and pursuitData.timers
  local evade = timers and tonumber(timers.evade) or nil
  return evade ~= nil and evade < 1
end

return M
