-- RLS-Career-MP server: settings. Written to config/config.json on first start;
-- edit that file (or use the console) and restart.
-- SPDX-License-Identifier: AGPL-3.0-only

local util = require("rlsmp.server.util")
local storage = require("rlsmp.server.storage")

local M = {}

M.defaults = {
  -- Random tag for this server, so saves from two servers never mix on a player's PC.
  serverTag = "",

  -- The map RLS needs (its garages, spawn, auctions and jobs exist only there). "" turns the check off.
  expectedMap = "rls_west_coast",

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
    maxExemptPerWindow = 10000000,
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

  -- Phase 3: traffic director. The budget is shared between everyone who is in career.
  traffic = {
    enabled = true,
    -- Traffic cars that may be active across the whole server. 0 = automatic: it grows with the players online
    -- (baseBudget + perPlayerBudget x players), so more players means more traffic overall but fewer cars per game.
    -- Any number above 0 fixes the budget instead.
    totalBudget = 0,
    baseBudget = 30,
    perPlayerBudget = 10,
    -- Every player gets at least / at most this many (a lone player gets maxPerPlayer).
    minPerPlayer = 3,
    maxPerPlayer = 18,
    -- How often the director looks for players joining or leaving.
    checkSeconds = 1,
  },

  -- Phase 3: police pursuits.
  police = {
    enabled = true,
    -- Police cars may not be re-placed (respawned / teleported) while the player is being chased.
    antiTeleport = true,
    -- Refuse RLS roadblocks (they put police cars on the road ahead of you).
    blockRoadblocks = true,
  },

  -- Phase 3: "smart traffic" driver personalities. Each game gives its AI traffic cars a personality, picked by
  -- these weights (any numbers, they don't have to add up to 100; 0 turns one off). Only the game's own AI
  -- settings change: slow = careful, ~85% of the limit; aggressive = tailgates, a bit over the limit;
  -- racer = very aggressive, well over the limit; drunk = weaves now and then, uneven speed, sudden braking.
  -- policeReact: a nearby AI police car starts a chase on a racer or drunk (at most one per minute per game).
  -- Untested in-game: set enabled = false if traffic misbehaves.
  -- Phase 3: traffic variety. Which cars the AI traffic and the parked cars use (decided in each game, settings from here).
  trafficVariety = {
    enabled = true,
    -- Weight per car Type of the game's own model list ("Car", "Truck", ...; the game log lists the Types it saw).
    -- Missing = 1, 0 = never. Example: typeWeights = {Truck = 0.5}
    typeWeights = {},
    -- Models from mods this server ships (zip in Resources/Client): model name -> weight. Games without the model skip it.
    -- Example: mods = {mycar = 3}. Every player downloads every mod zip when joining, so keep big car mods to a few.
    mods = {},
    -- Extra multipliers per road class (city, main, highway; from the road's speed limit) and per day or night, per Type.
    -- Example: zones = {highway = {Truck = 2}}, night = {Truck = 0.5}
    zones = {},
    day = {},
    night = {},
    -- A group is picked from oversample x its size candidates; no model fills more than maxShare of a group.
    oversample = 2,
    maxShare = 0.25,
    maxCandidates = 80,
    -- Moving traffic and/or parked cars.
    applyToTraffic = true,
    applyToParked = true,
    -- Road class limits in m/s: slower than city = city, slower than main = main, else highway.
    zoneSpeedLimits = {city = 17, main = 27},
  },

  smartTraffic = {
    enabled = true,
    mix = {normal = 80, slow = 10, aggressive = 6, racer = 3, drunk = 1},
    policeReact = true,
  },

  business = {
    maxMembers = 4,
    membersCanWithdraw = true,
    inviteSeconds = 60,
    maxFleet = 10,
    -- Highest share of a member's earnings they may send to the business bank (percent).
    maxSplit = 50,
    maxRecordBytes = 400000,
  },

  unstuck = {
    cooldownSeconds = 30,
  },

  -- Shared time of day. The server owns the clock: everyone sees the same time, one full day takes `dayMinutes` real minutes.
  time = {
    enabled = true,
    dayMinutes = 45,
    syncSeconds = 5,
  },

  -- Pink-slip duels (/duel <player>). OFF until you list at least one course and set enabled = true.
  -- A course is {name = "airport", start = {x, y, z}, finish = {x, y, z}} in map coordinates; both players must
  -- be near the start. The loser's car moves to the winner. Untested in-game: try with spare cars first.
  duel = {
    enabled = false,
    courses = {},
    startRadius = 60,
    finishRadius = 30,
    countdownSeconds = 5,
    raceTimeoutSeconds = 600,
    minRaceSeconds = 8,
    retrySeconds = 30,
  },

  vehicles = {
    enabled = true,
    -- A player on foot may get into another player's car and ride along as a passenger (they cannot drive it).
    -- Off by default until it has been tested in the game: turn it on to try it.
    allowPassengers = false,
  },

  claims = {
    enabled = true,
    -- Judge crashes and TELL players what would happen, but take no money and change no insurance score. Turn off to go live.
    dryRun = true,
    dashcamPrice = 100,
    -- How long to wait for the second player's report before judging with one.
    reportWindowSeconds = 4,
    pairCooldownSeconds = 20,
    -- Closing speed (m/s) below which a touch is a scrape, not an accident.
    minImpactSpeed = 3,
    -- Fault share from which a player counts as "at fault" for repeat-accident multipliers.
    faultThreshold = 0.6,
    chainWindowSeconds = 60,
    chainStep = 0.5,
    chainMax = 3,
    maxPayout = 25000,
    -- A dashcam on either car always settles a crash (no dice roll). Set to false to keep it a chance instead.
    dashcamAlwaysCaught = true,
    -- Chance of being caught without that rule: base + witnesses nearby + a dashcam on either car. Both cars with dashcams = certain.
    baseConfidence = 0.35,
    perWitness = 0.15,
    witnessCap = 3,
    dashcamBonus = 0.4,
    -- Used when a game could not measure its damage: dollars per (m/s)^2 of closing speed.
    fallbackDamagePerSpeedSq = 15,
  },

  -- Shared dealership stock: everyone sees the same cars for sale (the first player's listings, kept in shop.json).
  -- OFF until tested in-game. Only listings that exist when a player joins are shared; RLS still adds new ones per PC.
  shop = {
    shared = false,
  },

  security = {
    -- RLS "cheats mode" (and Freeroam+) gives free money and vehicles. Never accepted from a client save unless you turn this on.
    allowCheats = false,
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
