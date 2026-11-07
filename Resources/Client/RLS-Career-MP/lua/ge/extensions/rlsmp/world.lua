-- RLS-Career-MP client extension "rlsmp_world" (Phase 4: RLS world interactions).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Step 1: no map travel while online. RLS "travel to another map" loads a new level, which would drop the
-- player from the BeamMP server (and the server only runs one map). We refuse it in both places RLS checks.
-- install() runs every frame and wraps again whenever the functions there are not ours (modules get reloaded).

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
-- Every install() checks that the functions there are still ours: a reloaded module table, or RLS putting a
-- new function into the same table, gets wrapped again (like lib/replaceGuard.lua).
local NAMES = {"switchMap", "resolveTravelBlockers"}
local ours = {}                                    -- name -> our current wrapper
local isOurs = setmetatable({}, {__mode = "k"})    -- every wrapper we made (never wrap our own wrapper)
local function refuse(original)
  local fn = function(...)
    if enabled then toast() return false, MESSAGE end
    return original(...)
  end
  isOurs[fn] = true
  return fn
end

function M.install()
  local sm = overhaul_career_garage_switchMap
  if not sm then return false end
  for _, name in ipairs(NAMES) do
    local current = sm[name]
    if type(current) == "function" and current ~= ours[name] and not isOurs[current] then
      ours[name] = refuse(current)
      sm[name] = ours[name]
    end
  end
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
