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

-- RLS only has its garages, spawn point and jobs on its own map; warn loudly when the server is set to something else.
local function checkServerMap(cfg)
  if cfg.expectedMap == "" then return nil end
  local f = io.open("ServerConfig.toml", "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local map = text:match('[\n^]%s*Map%s*=%s*"([^"]*)"')
  if map and not map:find("/" .. cfg.expectedMap .. "/", 1, true) then
    return string.format("This server's map is %s, but RLS needs /levels/%s/info.json (no starter garage, garage slots or jobs otherwise).",
      map, cfg.expectedMap)
  end
  return nil
end

function onInit()
  util.info("Loading v" .. RLSMP.version .. " build " .. require("rlsmp.shared.transfer").BUILD)
  local cfg = config.load(PLUGIN_ROOT .. "config/config.json")
  RLSMP.config = cfg
  RLSMP.mapWarning = checkServerMap(cfg)
  if RLSMP.mapWarning then util.warn(RLSMP.mapWarning) end
  net.init(cfg)
  for _, modulePath in ipairs(require("rlsmp.server.modules")) do
    local mod = require(modulePath)
    if type(mod.init) == "function" then mod.init(cfg, PLUGIN_ROOT) end
  end
  net.on("onConsoleInput", onConsoleInput)
  util.info("Ready (server tag " .. cfg.serverTag .. ")")
end
