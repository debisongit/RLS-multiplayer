-- RLS-Career-MP client extension "rlsmp_world" (Phase 4: RLS world interactions).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Step 1: no map travel while online. RLS "travel to another map" loads a new level, which would drop the
-- player from the BeamMP server (and the server only runs one map). We refuse it in both places RLS checks.
-- Wrapped once per module table, installed every frame (modules get reloaded).

local M = {}

local net = require("rlsmp/lib/net")

local enabled = false
function M.enable(on) enabled = on == true end

local MESSAGE = "Map travel is disabled in multiplayer."

local function toast()
  if guihooks then
    guihooks.trigger("toastrMsg", {type = "warning", title = "RLS Career MP", msg = MESSAGE, config = {timeOut = 4000}})
  end
end

-- RLS calls its local switchMap from resolveTravelBlockers, so both exported entry points are wrapped.
local wrapped = setmetatable({}, {__mode = "k"})
local function refuse(original)
  return function(...)
    if enabled then toast() return false, MESSAGE end
    return original(...)
  end
end

function M.install()
  local sm = overhaul_career_garage_switchMap
  if not sm or wrapped[sm] then return sm ~= nil end
  wrapped[sm] = true
  if sm.switchMap then sm.switchMap = refuse(sm.switchMap) end
  if sm.resolveTravelBlockers then sm.resolveTravelBlockers = refuse(sm.resolveTravelBlockers) end
  return true
end

-- Step 2: event results. RLS announces every finished freeroam run with the game hook
-- onRlsFreeroamRaceResultFinalized(payload) (seconds in finishTime). Only timed races count here: derby (demo),
-- burnout and tractor pull are scored by points or distance, so lower is not better for them.
local NOT_TIMED = {demo = true, burnout = true, tractorPull = true}

function M.onRlsFreeroamRaceResultFinalized(payload)
  if not enabled or type(payload) ~= "table" or payload.invalidLap then return end
  if type(payload.raceName) ~= "string" or not tonumber(payload.finishTime) then return end
  for _, kind in ipairs(type(payload.disciplineIds) == "table" and payload.disciplineIds or {}) do
    if NOT_TIMED[kind] then return end
  end
  local metrics = type(payload.resultMetrics) == "table" and payload.resultMetrics or {}
  net.send("rlsmpEventDone", {race = payload.raceName, t = tonumber(payload.finishTime), place = tonumber(metrics.placement)})
end

function M.onUpdate() M.install() end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
