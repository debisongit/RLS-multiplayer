-- RLS-Career-MP server: vehicle rules for players (who may sit in whose car).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The rules themselves are enforced in each player's game (client vehicleGuard). The server only tells every player who is in
-- career what is allowed (`rlsmpVehicleConfig`), once, when they finish loading (same approach as trafficPolice.lua).
--   allowPassengers: a player ON FOOT may get into another player's car and ride along (BeamMP's passenger camera).

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

local cfg
local told = {}   -- pid -> true once they have the settings

function M.payload()
  return {allowPassengers = cfg.allowPassengers == true}
end

function M.push()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      if not told[pid] then
        told[pid] = true
        net.send(pid, "rlsmpVehicleConfig", M.payload())
        util.info(string.format("RLSMP-GUARD vehicle config sent to pid=%s allowPassengers=%s", tostring(pid), tostring(cfg.allowPassengers == true)))
      end
    end
  end
  for pid in pairs(told) do
    if not live[pid] then told[pid] = nil end
  end
end

function M.init(config)
  cfg = config.vehicles
  told = {}
  net.on("rlsmpVehicleTick", function() if cfg.enabled then M.push() end end)
  MP.CreateEventTimer("rlsmpVehicleTick", 1000)
  util.info("Vehicle rules on: allowPassengers=" .. tostring(cfg.allowPassengers == true))
end

return M
