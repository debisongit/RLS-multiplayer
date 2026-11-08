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
    -- How far from a player a traffic car may be before the game recycles it (docs/RESEARCH_RESPAWN_RANGE.md).
    -- respawnRange: multiplier on the game's own radius (1 = the game's original, up to 3 = cars stay about three times as far out).
    -- respawnDelay: seconds a car stays at least after the game placed it, before it may be recycled (0 = off, the game's original).
    respawnRange = 1.0,
    respawnDelay = 0,
    -- Our own removal of stuck cars (client unjam.lua): only a car that stood still `seconds` and is `distance` m or more from EVERY player; one at a time.
    unjam = {enabled = true, seconds = 120, distance = 400},
  },

  -- Phase 3: police pursuits.
  police = {
    enabled = true,
    -- Police cars may not be re-placed (respawned / teleported) while the player is being chased.
    antiTeleport = true,
    -- Refuse RLS roadblocks (they put police cars on the road ahead of you).
    blockRoadblocks = true,
    -- Which traffic cars another player's game may not recycle (client rlsmp/bubble.lua):
    -- "original" = RLS's own spawn and respawn distances, a car is only kept while another player is within its
    --   own active radius AND has a clear line to it; "protect" = the old strict rule (450 m, or a clear line up to 1 km);
    -- "off" = no protection at all.
    bubbleMode = "original",
    -- Police records (server plateRecords.lua), shared by all cops on the server:
    -- a flagged plate (plate text + car model) lasts this many real seconds; a new plate text clears it at once.
    plateFlagSeconds = 7200,
    -- Cops also remember the car (model + colour) of an escaped chase this long; a repaint clears it.
    descriptionSeconds = 1200,
    -- Police read the plate of a car near them. Untested in-game: set enabled = false if it misbehaves.
    plateReading = {
      enabled = true,
      rangeMeters = 15,            -- the police car must be this close (and see you)
      maxSpeedKmh = 50,            -- and you slower than this
      minSeconds = 3,              -- a read takes minSeconds..maxSeconds (random each time)
      maxSeconds = 6,
      readChance = 0.35,           -- chance that a police car coming near bothers to read your plate
      afterEscapeChance = 1.0,     -- the same, for afterEscapeSeconds after you escaped a chase
      afterEscapeSeconds = 1200,
      encounterSeconds = 60,       -- a police car decides this once per this many seconds
      copCooldownSeconds = 300,    -- a police car that read your plate leaves you alone this long
      skipChance = 0.2,            -- a flagged plate is let go 1 time in 5
      retriggerSeconds = 120,      -- no new plate chase for the same plate within this time
      offenseScore = 400,          -- RLS pursuit score of the "wantedPlate" offense (RLS x0.75; 150 = first level)
      escapeCooldownSeconds = 60,  -- at most one escape report per player per this many seconds
      escapeNeedsChaseSeconds = 300, -- escape reports count only if the player was seen chased this recently (0 = trust)
      lookupsPerMinute = 20,
    },
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
    -- Weight per single car model (the game's model name, for example "pickup"); wins over the weight of its Type. 0 = never.
    models = {},
    -- Models from mods this server ships (zip in Resources/Client): model name -> weight. Games without the model skip it.
    -- Example: mods = {mycar = 3}. Every player downloads every mod zip when joining, so keep big car mods to a few.
    mods = {},
    -- Extra multipliers per road class (city, main, highway; from the road's speed limit) and per day or night, per Type.
    -- Example: zones = {highway = {Truck = 2}}, night = {Truck = 0.5}
    -- Defaults: trucks and vans on highways, fewer in the city, fewer at night; small cars like the city (model names that do not exist are ignored).
    zones = {
      city = {Truck = 0.5, van = 0.8, semi = 0.2, md_series = 0.5, covet = 1.5, sunburst2 = 1.4, miramar = 1.4, vivace = 1.3, bx = 1.3},
      highway = {Truck = 2, van = 2, semi = 3, md_series = 2, pickup = 1.5, covet = 0.6, bx = 0.5},
    },
    day = {},
    night = {Truck = 0.6, semi = 0.4},
    -- A group is picked from oversample x its size candidates; no model fills more than maxShare of a group.
    oversample = 2,
    maxShare = 0.25,
    maxCandidates = 80,
    -- Moving traffic and/or parked cars.
    applyToTraffic = true,
    applyToParked = true,
    -- Road class limits in m/s: slower than city = city, slower than main = main, else highway.
    zoneSpeedLimits = {city = 17, main = 27},
    -- Live swapping: a traffic car that nobody can see is replaced by a model that fits the road class and day or night better.
    -- enabled = only watch and log what would happen (changes nothing). live = really replace the cars (EXPERIMENTAL, OFF by default: it replaces cars that the game did not recycle).
    swap = {enabled = true, live = false, perMinute = 2, hiddenSeconds = 5, checkSeconds = 2, minRatio = 1.5, maxFailures = 3},
    -- Police cars (RLS's west coast list is only Bastions, 4 of 5 unmarked/undercover). Weight per police model (missing = 1, 0 = never; default Bastion low),
    -- undercoverShare = about this share of police cars may be unmarked/undercover (name contains a word of undercoverWords), maxShare = most of one model in a group.
    police = {enabled = true, models = {bastion = 0.3}, undercoverShare = 0.1, maxShare = 0.4, undercoverWords = {"undercover", "unmarked"}},
    -- Premade pool: traffic groups and re-rolled cars are picked from a few configs of EVERY model the game could use (RLS's own traffic filter applies),
    -- round robin: a model is not used again within the last avoidLast picks, at most brandMax of one brand in the last brandWindow picks,
    -- at most streetMax cars of one brand on the street. popPower 0 = every config equally likely, 1 = follow the game's Population value.
    pool = {enabled = true, avoidLast = 6, brandWindow = 12, brandMax = 3, streetMax = 3, configsPerModel = 5, popPower = 0.5},
    -- Respawn re-roll: when RLS respawns a traffic car out of everybody's sight, it comes back as another model with another config
    -- (needs pool.enabled). perMinute = most re-rolls per minute in one game (BeamMP sends every one to every player: keep it low). chance = share of respawns re-rolled.
    -- repaintChance = share of re-rolled cars that also get random paint. Never police, taxis, chased, crashed, job or player cars.
    respawn = {enabled = true, perMinute = 2, chance = 0.25, repaintChance = 0.5, waitSeconds = 3},
    -- Parked cars: RLS keeps as many as its game setting trafficParkingAmount says (a real log: 2). Each game raises that setting to this amount after the
    -- career starts (never lowers a higher one, gives the old value back on leaving). 0 = leave it alone. Every parked car is a car BeamMP syncs to the others
    -- and counts for the server's per-player car limit (MaxCars in ServerConfig.toml), so raise that too. Car theft needs parked cars to steal.
    parked = {amount = 10},
    -- Rarity: everyday cars are the clear majority. Shares of the picks per tier (renormalised over the tiers that exist). A config is "rare" when its model or
    -- config name has a rareWords word / is in rareModels / has Config Type Race or Drift / a Value of rareValue or more; "uncommon" for uncommonWords or
    -- uncommonValue; else common. Words of 5+ letters match inside names ("offroad" in "offroada331972"), shorter ones whole words only.
    rarity = {enabled = true, common = 0.88, uncommon = 0.10, rare = 0.02,
      rareWords = {"race", "racer", "racing", "drift", "hotrod", "junk", "drag", "crawler", "trophy", "buggy", "formula", "rocket"},
      uncommonWords = {"rally", "offroad", "tuner", "pro", "workpackage", "sport", "taxi", "police", "dune", "turbo"},
      rareModels = {"scintilla", "bolide"}, uncommonValue = 45000, rareValue = 120000},
    -- Preload (lag): no car is built while the frames are slow (slowFrameMs, then settleSeconds of calm), not within minGapSeconds of the last build, not in a
    -- chase. `reserve` picks are made ahead and their data read ahead (one per prepareSeconds, only in calm moments); warmShare of the picks come from models
    -- that are already loaded (on the street or built this session). No spare car is ever built or hidden: BeamMP would send it to everybody.
    preload = {enabled = true, reserve = 3, prepareSeconds = 4, minGapSeconds = 6, slowFrameMs = 45, calmFrames = 45, settleSeconds = 3, warmShare = 0.7, ageMax = 240},
    -- Simplified (cheap "simple_traffic" stand-in) cars, see docs/RESEARCH_SIMPLIFIED.md. OFF by default and never tried in the game.
    -- parked: a stand-in parked car at a stealable spot becomes a real car when a player is within nearRadius (m, at least 120); traffic: a respawned
    -- traffic car farther than nearRadius from every player may come back as a stand-in, and a stand-in that comes within nearRadius is made real.
    -- perMinute = most changes per minute in one game (BeamMP sends every change to everybody). Never police, taxis, jobs, chases or players' cars.
    simplified = {enabled = false, parked = true, traffic = false, nearRadius = 250, perMinute = 4, checkSeconds = 2},
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

  -- Shared weather: the server picks one of RLS's six conditions per period and every game shows it (like the shared time of day).
  weather = {
    enabled = true,
    -- Real minutes per weather period (a game day is time.dayMinutes real minutes).
    periodMinutes = 15,
    syncSeconds = 10,
    -- How common each condition is (weights). A period never jumps more than two steps from the one before.
    mix = {clear = 35, partlyCloudy = 25, overcast = 20, drizzle = 8, rain = 9, storm = 3},
    -- Pin one condition for everybody (clear, partlyCloudy, overcast, drizzle, rain, storm), "" = use the mix. Handy for testing.
    force = "",
  },

  -- Pink-slip duels (/duel <player>). OFF until you list at least one course and set enabled = true.
  -- A course is {name = "airport", start = {x, y, z}, finish = {x, y, z}} in map coordinates
  -- ({x = .., y = .., z = ..} works too); both players must
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
    -- Anti-cheat plausibility (positions are client-reported): fastest believable speed in m/s between pings and
    -- from start to finish, and the fewest position pings (1 per second) a finisher must have sent during the race.
    maxSpeed = 120,
    minPings = 5,
    -- Refuse a duel when the cheaper car is more than this many percent cheaper than the other one (0 = off).
    maxValueGapPercent = 0,
  },

  -- Car theft (a popup next to a parked car). OFF until the owner has tried it in the game.
  -- Each game marks about perMille/1000 of its parked cars stealable; the pick changes every periodSeconds (same for everyone).
  -- A car's tier comes from its year and value (tiers); each method works on one tier, needs the listed items (see server
  -- items.lua; durable tools stay, the rest is used up on success), takes `seconds`, makes `noise` (0-1, raises the witness
  -- chance) and fails with `failChance` (nothing is used up then). Set a method's enabled = false to turn it off.
  -- Reported stolen: seenReportMin-Max s after the theft if a witness saw it, unseenReportSeconds if not, trackerReportSeconds
  -- for cars with a GPS tracker (luxury) unless the thief owns a tracker blocker. Reports flag the plate for the police.
  theft = {
    enabled = false,
    perMille = 150,
    periodSeconds = 3600,
    radius = 3,
    retrySeconds = 10,
    tiers = {immobilizerYear = 1995, keylessYear = 2010, newestYear = 2021, luxuryValue = 120000, unknownYear = 2000},
    methods = {
      window_screwdriver = {tier = "old", order = 1, label = "Smash the window, screwdriver in the ignition",
        items = {"window_punch", "screwdriver"}, seconds = 8, noise = 0.9, failChance = 0.05},
      key_programmer = {tier = "immobilizer", order = 1, label = "Open the door quietly, program a blank key at the diagnostic port",
        items = {"lockout_kit", "key_programmer", "blank_key"}, seconds = 25, noise = 0.2, failChance = 0.15},
      signal_cloner = {tier = "keyless", order = 1, label = "Clone the key fob signal",
        items = {"signal_cloner"}, seconds = 15, noise = 0.1, failChance = 0.2},
      relay_box = {tier = "keyless", order = 2, label = "Relay the owner's key signal",
        items = {"relay_box"}, seconds = 8, noise = 0.1, failChance = 0.45},
      injection = {tier = "keyless", order = 3, label = "Inject through a headlight connector, program a blank key",
        items = {"can_injector", "blank_key"}, seconds = 30, noise = 0.3, failChance = 0.1},
      luxury_injection = {tier = "luxury", order = 1, label = "Two steps: connector injection, then a programmed key (alarm, GPS tracker)",
        items = {"can_injector", "key_programmer", "blank_key"}, seconds = 45, noise = 0.6, failChance = 0.25, tracker = true, alarm = true},
    },
    -- A signal jammer silences the alarm of methods marked `alarm = true`: their noise is multiplied by this.
    jammerNoiseFactor = 0.25,
    baseWitnessChance = 0.15,
    perWitness = 0.12,
    witnessCap = 5,
    noiseWitness = 0.3,
    maxWitnessChance = 0.95,
    seenReportMin = 30,
    seenReportMax = 120,
    unseenReportSeconds = 600,
    trackerReportSeconds = 20,
    keepHours = 48,
    -- Inspect hint (black market MEMBERS ONLY): a member on foot within `range` m of a stealable parked car gets a small toast;
    -- inspecting takes `seconds` and tells tier, tools (missing ones) and rough risk. Everybody else only ever hears "looks boring".
    inspect = {enabled = true, range = 15, seconds = 3, cooldown = 2},
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

  -- Black market (server market.lua): invite + reputation, order in the phone app, collect at a drop spot.
  -- Nobody is in until the server owner types `rlsmp market grant <player>` in the server console.
  -- The fence sells or strips stolen cars at the black market's active drop spot (needs theft.enabled and a market member).
  -- Rates are shares of the car's value. market.fenceCarRate is what "sell" pays.
  fence = {
    enabled = true,
    garage = true,            -- the "Strip / illegal parts" button in the RLS garage computer (client rlsmp/garage.lua)
    garageCooldown = 20,      -- seconds between two strips of ordinary (not stolen) garage cars per player
    minValue = 2000,         -- used when the game had no price for the car (value 0)
    maxValue = 300000,        -- the car value the fence works from is capped here (the value comes from the game)
    stripRate = 0.30,         -- parts for cash, no papers
    resellRate = 0.60,        -- fake plate + VIN plate + part number, all used up
    gambleBase = 0.45,        -- swap one or two papers: base share with one paper...
    gamblePerPaper = 0.075,   -- ...plus this for each extra paper
    gambleMaxPapers = 2,
    gambleBust = 0.30,        -- chance the buyer is a trap: no money, car gone, market.bust
    rep = {strip = 1, sell = 1, resell = 3, gamble = 2},   -- reputation for a good sale
  },
  market = {
    enabled = true,
    founderRep = 10,          -- rep of a member made with the console command
    startRep = 0,             -- rep of an invited member
    maxRep = 100,
    maxRepChange = 25,        -- the most one addRep/lossRep call may change
    baseInvites = 2,          -- invites per member, plus one per `repPerInvite` rep, up to maxInvites
    repPerInvite = 10,
    maxInvites = 8,
    inviteSeconds = 120,
    bustRep = 10,             -- rep lost when caught; a bust you cannot pay in rep throws you out
    bustTakesPapers = true,   -- a bust takes your used-up items (plates, VIN plates, part numbers, blank keys)
    bustTakesTools = false,   -- and, if true, your tools too
    minDelaySeconds = 60,     -- an order is at the drop spot this long after buying (random in between)
    maxDelaySeconds = 120,
    maxOpenOrders = 3,
    pickupRadius = 20,        -- meters (horizontal) from the spot; the client hints at 15
    positionMaxAge = 20,      -- seconds; an older position report does not count for a pickup
    rotateMinutes = 30,       -- the active drop spot changes this often (same for everyone, from the server clock)
    -- {name, x, y, z}. Defaults are parking spots from RLS's own rls_west_coast sites files, never visited in game.
    -- Use /where in game to read a spot's position and put your own list in config.json.
    dropSpots = {
      {name = "Joe's Junkyard", x = 154.5, y = 763.3, z = 102.1},
      {name = "Dockyards parking", x = -13.5, y = 579.7, z = 74.7},
      {name = "Belasco Auto back lot", x = -698.6, y = 808.7, z = 74.9},
      {name = "Jefferson parking", x = -393.4, y = 178.1, z = 100.7},
    },
    -- The fence pays this share of a stolen car's or part's value (legit sales pay more).
    fenceCarRate = 0.35,
    fencePartRate = 0.3,
    -- Scout tip (phone app, members, needs theft.enabled): marks minCount..maxCount stealable parked cars within `radius` m for `seconds`
    -- (never longer than the current theft pick lasts). More than freeUsesPerHour tips an hour cost repCost reputation each.
    scout = {enabled = true, price = 3000, minRep = 5, radius = 800, seconds = 600, minCount = 2, maxCount = 3,
      cooldownSeconds = 120, freeUsesPerHour = 3, repCost = 1},
    -- item -> {price, minRep}; item names come from items.lua CATALOG. Set off = true to stop selling one.
    tiers = {
      screwdriver     = {price = 400, minRep = 0},
      window_punch    = {price = 600, minRep = 0},
      fake_plate      = {price = 1500, minRep = 0},
      blank_key       = {price = 800, minRep = 10},
      lockout_kit     = {price = 2500, minRep = 10},
      key_programmer  = {price = 12000, minRep = 10},
      vin_plate       = {price = 4000, minRep = 10},
      part_number     = {price = 3000, minRep = 10},
      tracker_blocker = {price = 15000, minRep = 25},
      signal_cloner   = {price = 25000, minRep = 25},
      relay_box       = {price = 30000, minRep = 25},
      jammer          = {price = 40000, minRep = 50},
      can_injector    = {price = 45000, minRep = 50},
    },
  },

  -- Meetup selling: a Marketplace (or black market) sale is finished by driving to a spot the SERVER picks (server/meetup.lua).
  -- A fully legal car never gets a police setup. A stolen car or a car with illegal papers does, with these chances
  -- (kept between minChance and maxChance so the player is never sure). A setup brings copsMin..copsMax police (1 to 2).
  meetup = {
    enabled = true,
    spots = {},               -- {name, x, y, z}; empty = use market.dropSpots
    radius = 15,              -- meters (horizontal) the client wants for the drop-off
    serverRadius = 30,        -- meters the server accepts (positions are a few seconds old)
    minDistance = 300,        -- the new spot is at least this far from where the player stands (when enough spots exist)
    expireMinutes = 20,       -- an unfinished meetup ends after this
    cooldownSeconds = 300,    -- after a finished or ambushed meetup the player waits this long
    cancelCooldownSeconds = 60,
    illegalChance = 0.35,     -- setup chance for a stolen / police-flagged car sold through the Marketplace
    blackChance = 0.45,       -- setup chance for a stolen car sold through the black market
    minChance = 0.05,
    maxChance = 0.85,
    copsMin = 1,
    copsMax = 2,
  },

  -- ui.chatCommands: the old chat commands for theft, fence, market, meetup and items (/steal, /inspect, /fence, /market, /meetup, /items) are
  -- hidden developer fallbacks. Players use the popup, the phone app, the garage computer and the Marketplace app instead. Off unless an admin turns it on.
  ui = {
    chatCommands = false,
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
