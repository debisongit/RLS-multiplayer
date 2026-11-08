-- RLS-Career-MP client: pure decision for the parked car amount (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS keeps as many parked cars as the game setting trafficParkingAmount says (0 = automatic, 4 to 20). The server asks for `wanted`
-- (config trafficVariety.parked.amount, 0 = leave the game alone). We raise the setting (never lower the player's own higher value),
-- remember what it was, and put it back when the player leaves. This only decides what to do next:
--   state = {wanted, current (the setting now), noParked, applied (what we set, or nil), released (the wanted value we stopped managing), have, tries}
--   "skip"    the player switched parked cars off (the setting or RLS's noParkedMode): do nothing
--   "idle"    nothing to do
--   "set"     write the setting (and tell RLS)
--   "sync"    the setting is right but there are too few cars: ask RLS to top up
--   "done"    enough cars
--   "restore" the server no longer wants it: give the old value back
--   "forget"  somebody else changed the setting after us: leave it alone and stop managing it
--   "giveup"  too many top-up attempts

local M = {}

M.MAX_TRIES = 12

function M.plan(s)
  local wanted = tonumber(s.wanted) or 0
  local current = tonumber(s.current) or 0
  if s.noParked then return "skip" end
  if wanted <= 0 then return s.applied and "restore" or "idle" end
  if s.applied == nil then
    if current >= wanted or s.released == wanted then return "idle" end
    return "set"
  end
  if current ~= s.applied then return "forget" end
  if wanted ~= s.applied then return "set" end
  if (tonumber(s.have) or 0) >= wanted then return "done" end
  if (tonumber(s.tries) or 0) >= M.MAX_TRIES then return "giveup" end
  return "sync"
end

return M
