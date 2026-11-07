-- RLS-Career-MP server: feature modules, started in this order.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Each entry is a require path to a module with an `init(cfg, pluginRoot)` function.
-- Add new features by appending one line. Owners (see docs/COLLAB.md):
--   Phase 1/2 (saves, wallet, business)  -> Claude A
--   Phase 3   (traffic director, police) -> Claude B

return {
  "rlsmp.server.identity",
  "rlsmp.server.wallet",
  "rlsmp.server.profiles",
  "rlsmp.server.sessions",
  "rlsmp.server.business",
  "rlsmp.server.qol",
  "rlsmp.server.trafficLabels",
  "rlsmp.server.claims",
  "rlsmp.server.positions",
  "rlsmp.server.traffic",
  "rlsmp.server.trafficPolice",
  "rlsmp.server.trafficVariety",
  "rlsmp.server.weather",
  "rlsmp.server.smartTraffic",
  "rlsmp.server.vehicles",
  "rlsmp.server.events",
  "rlsmp.server.duel",
  "rlsmp.server.clock",
  "rlsmp.server.shop",
}
