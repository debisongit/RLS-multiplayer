-- RLS-Career-MP client entry. BeamNG runs this when the mod is mounted.
-- SPDX-License-Identifier: AGPL-3.0-only
load('rlsmp_core')
setExtensionUnloadMode('rlsmp_core', 'manual')
-- Phase 3 (traffic / police): loaded separately so core.lua stays untouched.
load('rlsmp_traffic')
setExtensionUnloadMode('rlsmp_traffic', 'manual')
load('rlsmp_police')
setExtensionUnloadMode('rlsmp_police', 'manual')
