-- RLS-Career-MP server: the money truth.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The client tells us every money change ("+2500, delivery payout"). We keep our own
-- balance. Payouts that look impossible are refused. When the client uploads a save,
-- we compare its money with ours; if they differ, OUR number wins and we push a fix.
--
-- A brand-new career is "unseeded": RLS hands out starting cash in its own way,
-- so the first saved balance (capped by maxStartingMoney) becomes the starting point.

local util = require("rlsmp.server.util")

local M = {}

local cfg

function M.newLedger()
  return {money = 0, seeded = false, rejected = 0, window = {}}
end

-- Sum of gains inside the time window. Also drops entries that are too old.
local function windowTotal(ledger, now)
  local kept, total = {}, 0
  for _, e in ipairs(ledger.window) do
    if e.t > now - cfg.wallet.windowSeconds then
      kept[#kept + 1] = e
      total = total + e.a
    end
  end
  ledger.window = kept
  return total
end

-- Apply one reported change. Returns true if accepted, false + reason if refused.
function M.applyDelta(ledger, amount, reason)
  amount = tonumber(amount)
  if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
    return false, "not_a_number"
  end
  if not ledger.seeded then
    -- Before the first save we just follow along; the seed step decides the real start.
    ledger.money = ledger.money + amount
    return true
  end
  local now = util.now()
  if amount > 0 then
    if amount > cfg.wallet.maxSingleGain then
      ledger.rejected = ledger.rejected + 1
      return false, "gain_too_large"
    end
    if windowTotal(ledger, now) + amount > cfg.wallet.maxGainPerWindow then
      ledger.rejected = ledger.rejected + 1
      return false, "gain_rate_limited"
    end
    table.insert(ledger.window, {t = now, a = amount})
  elseif ledger.money + amount < cfg.wallet.minBalance then
    ledger.rejected = ledger.rejected + 1
    return false, "below_min_balance"
  end
  ledger.money = ledger.money + amount
  return true
end

-- Called with the money value found in an uploaded save.
-- Returns the value the save SHOULD have, and whether a correction is needed.
function M.reconcile(ledger, clientMoney)
  clientMoney = tonumber(clientMoney)
  if not ledger.seeded then
    local start = clientMoney or 0
    if start > cfg.wallet.maxStartingMoney then start = cfg.wallet.maxStartingMoney end
    ledger.money = start
    ledger.seeded = true
    return start, clientMoney ~= start
  end
  if not clientMoney then return ledger.money, true end
  if math.abs(clientMoney - ledger.money) > cfg.wallet.tolerance then
    return ledger.money, true
  end
  -- Tiny rounding differences: adopt the client's number so drift never piles up.
  ledger.money = clientMoney
  return clientMoney, false
end

function M.init(config)
  cfg = config
end

return M
