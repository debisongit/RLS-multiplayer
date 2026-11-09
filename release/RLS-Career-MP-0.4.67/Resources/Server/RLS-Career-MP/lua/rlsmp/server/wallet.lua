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
  return {money = 0, seeded = false, rejected = 0, window = {}, exemptWindow = {}}
end

-- Sum of gains inside the time window. Also drops entries that are too old.
local function windowTotal(ledger, now, field)
  field = field or "window"
  local kept, total = {}, 0
  for _, e in ipairs(ledger[field]) do
    if e.t > now - cfg.wallet.windowSeconds then
      kept[#kept + 1] = e
      total = total + e.a
    end
  end
  ledger[field] = kept
  return total
end

local function isExempt(category)
  for _, c in ipairs(cfg.wallet.exemptCategories) do
    if c == category then return true end
  end
  return false
end

-- True for money that was EARNED (jobs, rewards, services), as opposed to moved (loans, sales, transfers) or cheated.
function M.isEarning(category)
  return category ~= "cheat" and not isExempt(category)
end

-- Apply one reported change. Returns true if accepted, false + reason if refused.
-- `category` is RLS's money category for the change (see overhaul/lib/ledger/categories.lua).
function M.applyDelta(ledger, amount, reason, category)
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
  if amount > 0 and category == "cheat" then
    ledger.rejected = ledger.rejected + 1
    return false, "cheat_category"
  end
  if amount > 0 and isExempt(category) then
    if amount > cfg.wallet.maxExemptGain then
      ledger.rejected = ledger.rejected + 1
      return false, "gain_too_large"
    end
    -- moving money around: not counted as earnings, but it has its own (larger) cap per window
    if windowTotal(ledger, now, "exemptWindow") + amount > cfg.wallet.maxExemptPerWindow then
      ledger.rejected = ledger.rejected + 1
      return false, "gain_rate_limited"
    end
    table.insert(ledger.exemptWindow, {t = now, a = amount})
  elseif amount > 0 then
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
    -- The save has MORE money than the server counted: income the server never saw (a payout that came in a way it was not told about, a
    -- message lost on the way). A real player lost 13,073 to the old rule ("Server balance sync" -13,073), so a limited amount of extra money is
    -- adopted instead of being taken away: at most `adoptUpTo` per `windowSeconds`, and every case is logged. Bigger jumps are still corrected.
    local extra = clientMoney - ledger.money
    local limit = tonumber(cfg.wallet.adoptUpTo) or 0
    if extra > 0 and limit > 0 then
      ledger.adoptWindow = ledger.adoptWindow or {}
      local now = os.time()
      if windowTotal(ledger, now, "adoptWindow") + extra <= limit then
        table.insert(ledger.adoptWindow, {t = now, a = extra})
        util.info(string.format("RLSMP-WALLET adopted %d more than the server counted (client %d, server %d)", extra, clientMoney, ledger.money))
        ledger.money = clientMoney
        return clientMoney, false
      end
    end
    util.info(string.format("RLSMP-WALLET corrected: client %s, server %s (difference %d)", tostring(clientMoney), tostring(ledger.money), clientMoney - ledger.money))
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
