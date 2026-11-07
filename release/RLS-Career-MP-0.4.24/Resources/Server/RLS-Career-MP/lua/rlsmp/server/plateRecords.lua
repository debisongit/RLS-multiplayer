-- RLS-Career-MP server: police records for plate reading (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Police AI runs in each player's game (client rlsmp_plates). This module is the shared memory of all cops
-- on the server:
--  * plate flags, keyed by plate text + car model, last police.plateFlagSeconds (2 real hours by default).
--    A new plate text clears the old plate's flag at once (the client reports it).
--  * car descriptions (model + colour name) last police.descriptionSeconds (20 minutes); a repaint clears it.
-- Flags come from escaped chases (rlsmpPlateEscaped, validated: the player was chased lately, rate limited)
-- and from other server modules through M.flag(plate, model, color, reason).
-- A finished read asks rlsmpPlateLookup; we answer rlsmpPlateResult {plate, model, flagged, reason, matchedBy}.
-- Settings go to each player once when they finish loading (rlsmpPlateConfig), also when switched off.
-- Records persist in plates.json.

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local positions = require("rlsmp.server.positions")
local storage = require("rlsmp.server.storage")
local util = require("rlsmp.server.util")

local M = {}

local cfg          -- config.police
local pcfg         -- config.police.plateReading
local file
local data = {flags = {}, desc = {}}
local told = {}         -- pid -> true once they have the settings
local lastChased = {}   -- pid -> util.now() of the last tick that saw them chased (positions.isChased)
local lastEscape = {}   -- pid -> time of their last accepted escape report
local lastLookup = {}   -- pid -> time of their last answered lookup
local lastChange = {}   -- pid -> time of their last plate/paint change report
local tickCount = 0

local CHANGE_EVERY = 3  -- seconds between plate/paint change reports per player

-- Input cleaning (the same rules as the client's lib/plateRead.cleanPlate).
function M.cleanPlate(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):upper()
  if #s == 0 or #s > 16 or s:find("[%c|]") then return nil end
  return s
end
function M.cleanModel(s)
  if type(s) ~= "string" or #s == 0 or #s > 64 or s:find("[^%w_%-%.]") then return nil end
  return s
end
-- Colour names are optional: "" or nil means unknown (no description is kept then).
function M.cleanColor(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  if #s == 0 or #s > 24 or s:find("[^%a ]") then return nil end
  return s
end

local function plateKey(plate, model) return plate .. "|" .. model end
local function descKey(model, color) return model .. "|" .. color end

local function save() if file then storage.writeJson(file, data) end end

local function flagSeconds() return tonumber(cfg.plateFlagSeconds) or 7200 end
local function descSeconds() return tonumber(cfg.descriptionSeconds) or 1200 end

-- Flag a plate (+ remember the description when a colour is known). For other modules too
-- (theft, stolen reports). Returns true when stored. `by` is an optional account id (kept for logs).
function M.flag(plate, model, color, reason, by)
  plate, model, color = M.cleanPlate(plate), M.cleanModel(model), M.cleanColor(color)
  if not plate or not model then return false end
  reason = type(reason) == "string" and reason ~= "" and reason:sub(1, 32) or "flagged"
  local now = util.now()
  data.flags[plateKey(plate, model)] = {plate = plate, model = model, color = color, reason = reason, t = now, by = by}
  if color then
    data.desc[descKey(model, color)] = {model = model, color = color, plate = plate, reason = reason, t = now, by = by}
  end
  save()
  util.info(string.format("[plates] flagged %s %s (%s) reason=%s", model, plate, tostring(color), reason))
  return true
end

-- {flagged, reason, matchedBy = "plate" | "description" | nil}. Pure read, expired entries count as absent.
function M.lookup(plate, model, color)
  plate, model, color = M.cleanPlate(plate), M.cleanModel(model), M.cleanColor(color)
  if not plate or not model then return {flagged = false} end
  local now = util.now()
  local f = data.flags[plateKey(plate, model)]
  if f and now - (f.t or 0) < flagSeconds() then
    return {flagged = true, reason = f.reason, matchedBy = "plate"}
  end
  local d = color and data.desc[descKey(model, color)]
  if d and now - (d.t or 0) < descSeconds() then
    return {flagged = true, reason = d.reason, matchedBy = "description"}
  end
  return {flagged = false}
end

-- The plate of that car changed: its old flag goes at once.
function M.clearPlate(plate, model)
  plate, model = M.cleanPlate(plate), M.cleanModel(model)
  if not plate or not model or not data.flags[plateKey(plate, model)] then return false end
  data.flags[plateKey(plate, model)] = nil
  save()
  util.info(string.format("[plates] plate flag cleared %s %s (new plate)", model, plate))
  return true
end

-- The car was repainted: the description with the old colour goes at once.
function M.clearDescription(model, color)
  model, color = M.cleanModel(model), M.cleanColor(color)
  if not model or not color or not data.desc[descKey(model, color)] then return false end
  data.desc[descKey(model, color)] = nil
  save()
  util.info(string.format("[plates] description cleared %s %s (repainted)", model, color))
  return true
end

-- Drop expired entries; returns how many went.
function M.prune()
  local now, gone = util.now(), 0
  for k, f in pairs(data.flags) do
    if now - (tonumber(f.t) or 0) >= flagSeconds() then data.flags[k] = nil gone = gone + 1 end
  end
  for k, d in pairs(data.desc) do
    if now - (tonumber(d.t) or 0) >= descSeconds() then data.desc[k] = nil gone = gone + 1 end
  end
  if gone > 0 then save() end
  return gone
end

function M.records() return data end

local function n(v, default) v = tonumber(v) return (v and v == v and v < math.huge) and v or default end

function M.payload()
  return {
    enabled = pcfg.enabled == true,
    rangeMeters = n(pcfg.rangeMeters, 15),
    maxSpeedKmh = n(pcfg.maxSpeedKmh, 50),
    minSeconds = n(pcfg.minSeconds, 3),
    maxSeconds = n(pcfg.maxSeconds, 6),
    readChance = n(pcfg.readChance, 0.35),
    afterEscapeChance = n(pcfg.afterEscapeChance, 1),
    afterEscapeSeconds = n(pcfg.afterEscapeSeconds, 1200),
    encounterSeconds = n(pcfg.encounterSeconds, 60),
    copCooldownSeconds = n(pcfg.copCooldownSeconds, 300),
    skipChance = n(pcfg.skipChance, 0.2),
    retriggerSeconds = n(pcfg.retriggerSeconds, 120),
    offenseScore = n(pcfg.offenseScore, 400),
  }
end

local function loaded(pid)
  local s = sessions.get(pid)
  return s ~= nil and s.stage == "loaded" and s or nil
end

local function onEscaped(pid, d)
  if not pcfg.enabled then return end
  local s = loaded(pid)
  if not s then return end
  local now = util.now()
  local cooldown = n(pcfg.escapeCooldownSeconds, 60)
  if lastEscape[pid] and now - lastEscape[pid] < cooldown then
    util.warn(string.format("[plates] escape report from pid=%s ignored (another one %ds ago)", tostring(pid), now - lastEscape[pid]))
    return
  end
  local window = n(pcfg.escapeNeedsChaseSeconds, 300)
  if window > 0 and not (lastChased[pid] and now - lastChased[pid] <= window) then
    util.warn(string.format("[plates] escape report from pid=%s (%s) refused: no police chase seen in the last %ds",
      tostring(pid), tostring(s.name), window))
    return
  end
  if M.flag(d.plate, d.model, d.color, "escaped", s.accountId) then
    lastEscape[pid] = now
  else
    util.warn("[plates] escape report from pid=" .. tostring(pid) .. " had a bad plate or model")
  end
end

local function onLookup(pid, d)
  if not loaded(pid) then return end
  local plate, model = M.cleanPlate(d.plate), M.cleanModel(d.model)
  if not plate or not model then return end
  local now = util.now()
  local result
  local gap = 60 / math.max(1, n(pcfg.lookupsPerMinute, 20))
  if not pcfg.enabled then
    result = {flagged = false}
  elseif lastLookup[pid] and now - lastLookup[pid] < gap then
    result = {flagged = false, limited = true}   -- answered anyway, so the game never waits
  else
    lastLookup[pid] = now
    result = M.lookup(plate, model, d.color)
  end
  result.plate, result.model = plate, model
  net.send(pid, "rlsmpPlateResult", result)
  if result.flagged then
    util.info(string.format("[plates] pid=%s read %s %s: FLAGGED by %s (%s)", tostring(pid), model, plate,
      tostring(result.matchedBy), tostring(result.reason)))
  end
end

local function onChanged(pid, d)
  if not pcfg.enabled or not loaded(pid) then return end
  local now = util.now()
  if lastChange[pid] and now - lastChange[pid] < CHANGE_EVERY then return end
  lastChange[pid] = now
  local model = M.cleanModel(d.model)
  if not model then return end
  local old, new = M.cleanPlate(d.oldPlate), M.cleanPlate(d.plate)
  if old and old ~= new then M.clearPlate(old, model) end
  local oldColor, color = M.cleanColor(d.oldColor), M.cleanColor(d.color)
  if oldColor and oldColor ~= color then M.clearDescription(model, oldColor) end
end

function M.tick()
  local now = util.now()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      if positions.isChased(pid) then lastChased[pid] = now end
      if not told[pid] then
        told[pid] = true
        local p = M.payload()
        net.send(pid, "rlsmpPlateConfig", p)
        util.info(string.format("RLSMP-P3 plate reading config sent to pid=%s enabled=%s", tostring(pid), tostring(p.enabled)))
      end
    end
  end
  -- Forget players who left (ids are reused).
  for _, t in ipairs({told, lastChased, lastEscape, lastLookup, lastChange}) do
    for pid in pairs(t) do if not live[pid] then t[pid] = nil end end
  end
  tickCount = tickCount + 1
  if tickCount % 60 == 0 then M.prune() end
end

function M.init(config, pluginRoot)
  cfg = config.police
  pcfg = cfg.plateReading
  file = (pluginRoot or "") .. "plates.json"
  local stored = storage.readJson(file)
  data = {flags = type(stored) == "table" and type(stored.flags) == "table" and stored.flags or {},
          desc = type(stored) == "table" and type(stored.desc) == "table" and stored.desc or {}}
  told, lastChased, lastEscape, lastLookup, lastChange, tickCount = {}, {}, {}, {}, {}, 0
  M.prune()
  net.onClient("rlsmpPlateEscaped", onEscaped)
  net.onClient("rlsmpPlateLookup", onLookup)
  net.onClient("rlsmpPlateChanged", onChanged)
  net.on("rlsmpPlateTick", M.tick)
  MP.CreateEventTimer("rlsmpPlateTick", 1000)
  util.info("Plate reading: enabled=" .. tostring(pcfg.enabled) .. ", flag " .. flagSeconds() .. "s, description " .. descSeconds() .. "s")
end

return M
