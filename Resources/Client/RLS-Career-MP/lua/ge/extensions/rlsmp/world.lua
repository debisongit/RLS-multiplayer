-- RLS-Career-MP client extension "rlsmp_world" (Phase 4: RLS world interactions).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Step 1: no map travel while online. RLS "travel to another map" loads a new level, which would drop the
-- player from the BeamMP server (and the server only runs one map). We refuse it in both places RLS checks.
-- Wrapped once per module table, installed every frame (modules get reloaded).

local M = {}

local enabled = false
function M.enable(on) enabled = on == true end

local MESSAGE = "Map travel is disabled in multiplayer."

local function toast()
  if guihooks then
    guihooks.trigger("toastrMsg", {type = "warning", title = "RLS Career MP", msg = MESSAGE, config = {timeOut = 4000}})
  end
end

local wrapped = setmetatable({}, {__mode = "k"})
function M.install()
  local sm = overhaul_career_garage_switchMap
  if not sm or wrapped[sm] then return sm ~= nil end
  wrapped[sm] = true
  local originalSwitch, originalBlockers = sm.switchMap, sm.getTravelBlockers
  if originalSwitch then
    sm.switchMap = function(...)
      if enabled then toast() return false, MESSAGE end
      return originalSwitch(...)
    end
  end
  if originalBlockers then
    sm.getTravelBlockers = function(...)
      if enabled then return {MESSAGE} end
      return originalBlockers(...)
    end
  end
  return true
end

function M.onUpdate() M.install() end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
