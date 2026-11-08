-- RLS-Career-MP server: settings for fair car shop prices of modded cars (config `modPrice`).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The price work happens in each player's game (client rlsmp_modPrice). The server owns the settings and sends them once to each player when
-- they finish loading (`rlsmpModPrice`), like trafficVariety.lua. The list of mod models is the keys of trafficVariety.mods.
-- STATIC edit rules for the [ menu are in trafficAdmin.lua; overrides ("model" or "model/config" -> price) are config.json only.

local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local util = require("rlsmp.server.util")

local M = {}

local MAX_ENTRIES = 200
local MAX_NAME = 128

local cfg, root
local told = {}

local function finite(v) v = tonumber(v) if v and v == v and v > -math.huge and v < math.huge then return v end end

function M.payload()
  local p = type(cfg) == "table" and cfg or {}
  local overrides, n = {}, 0
  for k, v in pairs(type(p.overrides) == "table" and p.overrides or {}) do
    v = finite(v)
    if type(k) == "string" and k ~= "" and #k <= MAX_NAME and v and v > 0 and n < MAX_ENTRIES then overrides[k] = v n = n + 1 end
  end
  local models = {}
  for name in pairs(type(root) == "table" and type(root.mods) == "table" and root.mods or {}) do
    if type(name) == "string" and name ~= "" and #name <= 64 and #models < MAX_ENTRIES then models[#models + 1] = name end
  end
  table.sort(models)
  return {enabled = p.enabled ~= false, sell = p.sell ~= false, max = finite(p.max), min = finite(p.min), tolerance = finite(p.tolerance), overrides = overrides, models = models}
end

function M.push()
  local live = {}
  for pid in pairs(sessions.all()) do
    if sessions.isLoaded(pid) then
      live[pid] = true
      if not told[pid] then
        told[pid] = true
        local p = M.payload()
        net.send(pid, "rlsmpModPrice", p)
        util.info(string.format("RLSMP-P3 modprice settings sent to pid=%s enabled=%s models=%d", tostring(pid), tostring(p.enabled), #p.models))
      end
    end
  end
  for pid in pairs(told) do if not live[pid] then told[pid] = nil end end
end

function M.resend() told = {} end

function M.init(config)
  cfg = config.modPrice
  root = config.trafficVariety
  told = {}
  net.on("rlsmpModPriceTick", function() M.push() end)
  MP.CreateEventTimer("rlsmpModPriceTick", 1000)
  util.info("Mod prices: enabled=" .. tostring(type(cfg) == "table" and cfg.enabled))
end

return M
