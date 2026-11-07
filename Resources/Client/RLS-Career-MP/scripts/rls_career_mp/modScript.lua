-- RLS-Career-MP client entry. BeamNG runs this when the mod is mounted.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Joining a server a second time without restarting the game can leave an old, half-dead copy of our
-- extensions in memory (load() then does nothing). So each one is unloaded first if it is still there.
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
boot('rlsmp_weather')
