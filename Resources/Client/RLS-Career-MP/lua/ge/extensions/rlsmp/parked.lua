-- RLS-Career-MP client extension "rlsmp_parked": more parked cars (car theft needs cars to steal).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS (integration/services/parking.lua) keeps as many parked cars as the game setting trafficParkingAmount (0 = automatic: 4 to 20).
-- A real log showed "Parking system started with 2 active / 2 total vehicles". The server asks for an amount
-- (config trafficVariety.parked.amount, arrives in rlsmpTrafficVariety). After the career runs we:
--   1. raise that game setting (never lowering a higher value the player chose) and remember the old value,
--   2. call RLS's own overhaul_career_police_playerDriving.onSettingsChanged(), which recomputes the wanted amounts, sets the active amount and calls
--      overhaul_integration_services_parking.syncParkedCount() (top-up through core_multiSpawn.createGroup, so the parked variety applies),
--   3. ask for a top-up again every few seconds until enough cars exist (a top-up is refused while another spawn is still running),
--   4. give the old value back when the player leaves the server.
-- Nothing is edited in RLS. If the player switched parked cars off (setting trafficParkedVehicles or RLS's noParkedMode) nothing happens.
-- Every parked car is a car BeamMP syncs to the other players, and the server's per-player car limit counts them: keep the amount moderate.
-- Pure decision: lib/parked.lua (tests: tests/parked_client_test.lua).

local M = {}

local Pk = require("rlsmp/lib/parked")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")

local KEY = "trafficParkingAmount"
local CHECK_EVERY = 2     -- seconds between looks
local SYNC_EVERY = 5      -- seconds between top-up requests

local original            -- the setting before we raised it
local released            -- the wanted amount we stopped managing because someone else changed the setting
local applied             -- the value we wrote
local tries, lastSync, timer, clock = 0, -SYNC_EVERY, 0, 0
local slowFor = 0       -- seconds the frame time has been bad (more parked cars cost frames: do not add while the game struggles)
local logged = {}

local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end
local function ext(name) return rawget(_G, "rlsmp_" .. name) or package.loaded["rlsmp/" .. name] end
local function once(key, msg) if not logged[key] then logged[key] = true p3.log("I", msg) end end

local function getSetting()
  if not (settings and settings.getValue) then return nil end
  local ok, v = pcall(settings.getValue, KEY)
  return ok and tonumber(v) or 0
end

local function noParked()
  if settings and settings.getValue then
    local ok, v = pcall(settings.getValue, "trafficParkedVehicles")
    if ok and v == false then return true end
  end
  local s = rawget(_G, "overhaul_shell_settings")
  if s and s.getSetting then
    local ok, v = pcall(s.getSetting, "noParkedMode")
    if ok and v then return true end
  end
  return false
end

local function parking() return rawget(_G, "overhaul_integration_services_parking") end

local function haveCars()
  local pk = parking()
  return pk and pk.getParkedCarsAmount and tonumber(pk.getParkedCarsAmount()) or 0
end

-- Tell RLS the setting changed: it recomputes its wanted amounts, the active amount and tops the parked cars up.
local function notifyRls()
  local pd = rawget(_G, "overhaul_career_police_playerDriving")
  if pd and pd.onSettingsChanged then
    local ok, err = pcall(pd.onSettingsChanged)
    if not ok then p3.log("W", "parked: RLS onSettingsChanged failed: " .. tostring(err)) end
  end
  local pk = parking()
  if pk and pk.syncParkedCount then
    local ok, res = pcall(pk.syncParkedCount)
    if not ok then p3.log("W", "parked: syncParkedCount failed: " .. tostring(res)) end
  end
end

local function setSetting(value)
  if not (settings and settings.setValue) then return false end
  local ok, err = pcall(settings.setValue, KEY, value)
  if not ok then p3.log("W", "parked: could not write " .. KEY .. ": " .. tostring(err)) end
  return ok
end

-- One round (also called by tests). Returns the plan word.
function M.check()
  if not (mp.isMPSession() and careerActive()) then return "idle" end
  local v = ext("trafficVariety")
  local cfg = v and v.getConfig and v.getConfig()
  if not cfg then return "idle" end
  local current = getSetting()
  if current == nil then return "idle" end
  local wanted = cfg.parked.amount
  local night = false
  if v.contextNow then
    local okc, ctx = pcall(v.contextNow)
    night = okc and type(ctx) == "table" and ctx.night == true
  end
  if night and (cfg.parked.nightAmount or 0) > wanted and wanted > 0 then wanted = cfg.parked.nightAmount end
  -- never ADD parked cars while the frame rate is bad (the amount is only lowered again at day, RLS removes cars by itself)
  if slowFor > 5 and applied ~= nil and wanted > applied then wanted = applied end
  local state = {wanted = wanted, current = current, noParked = noParked(), applied = applied, released = released, have = haveCars(), tries = tries}
  local act = Pk.plan(state)
  if act == "skip" then
    once("noparked", "parked: parked cars are switched off in the game settings, leaving them alone")
  elseif act == "set" then
    if original == nil then original = current end
    if setSetting(state.wanted) then
      applied = state.wanted
      tries, lastSync = 0, clock
      p3.count("parked amount set")
      p3.log("I", string.format("parked: setting %s %s -> %s (parked cars now %s)", KEY, tostring(current), tostring(state.wanted), tostring(state.have)))
      notifyRls()
    end
  elseif act == "sync" then
    if clock - lastSync < SYNC_EVERY then return act end   -- spaced out: RLS refuses a top-up while another spawn runs
    lastSync = clock
    tries = tries + 1
    notifyRls()
    p3.count("parked top-up asked")
  elseif act == "done" then
    once("done" .. tostring(applied), string.format("parked: %s parked cars now (wanted %s)", tostring(state.have), tostring(applied)))
  elseif act == "giveup" then
    once("giveup", string.format("parked: only %s of %s parked cars after %d top-up requests; giving up", tostring(state.have), tostring(applied), tries))
  elseif act == "forget" then
    p3.log("I", string.format("parked: %s was changed by someone else (now %s); no longer managed", KEY, tostring(current)))
    original, applied, released = nil, nil, state.wanted
  elseif act == "restore" then
    if setSetting(original) then p3.log("I", string.format("parked: server wants no change; %s back to %s", KEY, tostring(original))) end
    original, applied = nil, nil
    notifyRls()
  elseif act == "idle" and state.wanted > 0 and original == nil then
    once("enough", string.format("parked: %s is already %s (wanted %s), parked cars now %s", KEY, tostring(current), tostring(state.wanted), tostring(state.have)))
  end
  return act
end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  if dtReal > 0.045 then slowFor = slowFor + dtReal else slowFor = math.max(0, slowFor - dtReal * 2) end
  clock, timer = clock + dtReal, timer + dtReal
  if timer < CHECK_EVERY then return end
  timer = 0
  M.check()
end

-- Give the player's own setting back.
function M.onServerLeave()
  if applied ~= nil and original ~= nil and getSetting() == applied then
    setSetting(original)
    p3.log("I", string.format("parked: left the server, %s back to %s", KEY, tostring(original)))
  end
  original, applied, released, tries, lastSync, timer, clock, logged = nil, nil, nil, 0, -SYNC_EVERY, 0, 0, {}
end

function M.report() return p3.report() end
function M.onExtensionLoaded() p3.log("I", "rlsmp_parked loaded") end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
