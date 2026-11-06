-- RLS-Career-MP server: settings. Written to config/config.json on first start;
-- edit that file (or use the console) and restart.
-- SPDX-License-Identifier: AGPL-3.0-only

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")

local M = {}

M.defaults = {
  -- Random tag for this server, so saves from two servers never mix on a player's PC.
  serverTag = "",

  identity = {
    -- Guests have no BeamMP account ID, so their progress cannot be tied to them.
    allowGuests = false,
  },

  transfer = {
    -- Bytes per network chunk. Smaller = safer, bigger = faster.
    chunkSize = 16000,
    -- Chunks the server sends to one player per pump tick (tick = 50 ms).
    chunksPerTick = 6,
    -- Largest save we accept from a client, in bytes.
    maxSaveBytes = 64 * 1024 * 1024,
    -- Drop a half-finished upload after this many seconds.
    uploadTimeoutSeconds = 120,
  },

  handshake = {
    -- Kick players who have not loaded the client mod within this many seconds (0 = never).
    helloTimeoutSeconds = 120,
  },

  -- Settings for brand-new careers. Passed to RLS's career start.
  newCareer = {
    careerStartMode = "",      -- "" = RLS default. Example values depend on RLS: "freeroam" enables cheats.
    difficultyMode = "",       -- "" = RLS default
    startingCash = 0,          -- 0 = let RLS decide
    hardcore = false,
    policeEnabled = true,
    experimentalMaintenanceEnabled = false,
  },

  wallet = {
    -- The biggest single payout we trust from a client.
    maxSingleGain = 750000,
    -- Money that only MOVES (bank to wallet, loan payout, selling your own car) is not "earning", so it skips
    -- the single/window limits. It still has its own cap per change. "cheat" gains are always refused.
    exemptCategories = {"transfer", "loan", "sale", "property", "refund"},
    maxExemptGain = 5000000,
    -- The most money a client may earn inside one window.
    maxGainPerWindow = 2000000,
    windowSeconds = 300,
    -- The most a brand-new career may start with.
    maxStartingMoney = 1000000,
    -- Allow this much drift (rounding, fees) between client and server before correcting.
    tolerance = 1,
    -- Lowest balance allowed (RLS has loans, so a bit of debt is fine).
    minBalance = -10000000,
  },

  business = {
    maxMembers = 4,
    membersCanWithdraw = true,
    inviteSeconds = 60,
    maxFleet = 10,
    maxRecordBytes = 400000,
  },

  unstuck = {
    cooldownSeconds = 30,
  },

  -- How often the server asks clients to save, in minutes (0 = rely on RLS autosave only).
  forceSaveMinutes = 5,
}

local function randomTag()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  math.randomseed(os.time() + math.floor(os.clock() * 100000))
  for i = 1, 8 do
    local k = math.random(1, #chars)
    out[i] = chars:sub(k, k)
  end
  return table.concat(out)
end

function M.load(path)
  local raw = storage.readJson(path)
  local cfg = util.deepMerge(M.defaults, raw)
  if type(cfg.serverTag) ~= "string" or not cfg.serverTag:match("^[a-z0-9]+$") then
    cfg.serverTag = randomTag()
  end
  storage.writeJson(path, cfg, true)
  return cfg
end

return M
