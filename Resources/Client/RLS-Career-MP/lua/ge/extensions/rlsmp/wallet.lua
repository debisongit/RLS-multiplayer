-- RLS-Career-MP client extension "rlsmp_wallet".
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Reports every money change to the server, and applies the server's balance when
-- it says ours is wrong. The server keeps the real number (see server wallet.lua).

local M = {}

local net = require("rlsmp/lib/net")

local enabled = false
local SYNC_LABEL = "Server balance sync"

local function attrs() return overhaul_career_economy_playerAttributes end

local function reasonLabel(reason)
  if type(reason) ~= "table" then return nil end
  local label = reason.label
  if type(label) == "table" then label = label.txt or label.text end
  if label ~= nil then return tostring(label):sub(1, 120) end
  return nil
end

function M.enable(on) enabled = on == true end

-- RLS fires this after every attribute change (money, XP, ...).
function M.onOverhaulPlayerAttributesChanged(change, reason)
  if not enabled or type(change) ~= "table" then return end
  local money = change.money
  if type(money) ~= "number" or money == 0 then return end
  if type(reason) == "table" and reason.rlsmpSync then return end
  net.send("rlsmpWalletDelta", {d = money, r = reasonLabel(reason)})
end

local function onWalletSet(data)
  local a = attrs()
  local target = tonumber(data.money)
  if not enabled or not a or not target then return end
  local current = a.getAttributeValue("money")
  if current == target then return end
  log("W", "RLS-Career-MP", string.format("Server corrected money %s -> %s (%s)", tostring(current), tostring(target), tostring(data.why)))
  a.setAttributes({money = target}, {label = SYNC_LABEL, rlsmpSync = true, tags = {}})
end

function M.onExtensionLoaded()
  net.on("rlsmpWalletSet", onWalletSet)
end

M._onWalletSet = onWalletSet
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
