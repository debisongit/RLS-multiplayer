-- RLS-Career-MP client entry. BeamNG runs this when the mod is mounted.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Joining a server a second time without restarting the game can leave an old, half-dead copy of our
-- extensions in memory (load() then does nothing). So each one is unloaded first if it is still there.
-- Controls menu group for our key binding (guarded: if the game's category table is not there the binding still works, just ungrouped).
pcall(function()
  setExtensionUnloadMode("core_input_categories", "manual")
  extensions.load("core_input_categories")
  if core_input_categories then core_input_categories.rlsmp = {order = 4.3, icon = "extension", title = "RLS Career MP"} end
end)

local function boot(name)
  if extensions and extensions.isExtensionLoaded and extensions.unload and extensions.isExtensionLoaded(name) then
    pcall(extensions.unload, name)
  end
  load(name)
  setExtensionUnloadMode(name, 'manual')
end

boot('rlsmp_core')
-- Phase 3 (traffic / police): loaded separately so core.lua stays untouched.
boot('rlsmp_traffic')
boot('rlsmp_police')
boot('rlsmp_trafficVariety')
boot('rlsmp_trafficSwap')
boot('rlsmp_trafficReroll')
boot('rlsmp_trafficFill')
boot('rlsmp_parked')
boot('rlsmp_modPrice')
boot('rlsmp_simplified')
boot('rlsmp_weather')
boot('rlsmp_trafficMenu')
