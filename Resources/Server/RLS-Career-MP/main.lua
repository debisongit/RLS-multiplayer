-- RLS-Career-MP (SERVER) - multiplayer bridge for RLS Career Overhaul on BeamMP.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- BeamMP runs every .lua file in the root of this folder, so this is the only one.
-- Everything else lives under lua/ and is loaded with require().

local PLUGIN_ROOT = RLSMP_PLUGIN_ROOT or "Resources/Server/RLS-Career-MP/"
package.path = PLUGIN_ROOT .. "lua/?.lua;" .. package.path

local util = require("rlsmp.server.util")
local config = require("rlsmp.server.config")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")

RLSMP = RLSMP or {}
RLSMP.version = "0.1.0"

local function onConsoleInput(line)
  local cmd, arg = tostring(line):match("^%s*rlsmp%s+(%S+)%s*(.-)%s*$")
  if not cmd then return nil end
  if cmd == "save" then
    sessions.saveAll()
    return "RLS-Career-MP: all online profiles saved"
  elseif cmd == "status" then
    local lines = {"RLS-Career-MP " .. RLSMP.version}
    for pid, s in pairs(sessions.all()) do
      lines[#lines + 1] = string.format("  [%d] %s  stage=%s  money=%s", pid, tostring(s.name), s.stage,
        s.profile and tostring(s.profile.ledger.money) or "-")
    end
    return table.concat(lines, "\n")
  end
  return "RLS-Career-MP commands: rlsmp status | rlsmp save"
end

function onInit()
  util.info("Loading v" .. RLSMP.version)
  local cfg = config.load(PLUGIN_ROOT .. "config/config.json")
  RLSMP.config = cfg
  net.init(cfg)
  for _, modulePath in ipairs(require("rlsmp.server.modules")) do
    local mod = require(modulePath)
    if type(mod.init) == "function" then mod.init(cfg, PLUGIN_ROOT) end
  end
  net.on("onConsoleInput", onConsoleInput)
  util.info("Ready (server tag " .. cfg.serverTag .. ")")
end
