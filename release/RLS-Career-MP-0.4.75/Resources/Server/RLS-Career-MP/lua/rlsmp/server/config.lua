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
    -- A save with more money than the server counted (income the server never saw) is adopted up to this much per window; more is corrected. 0 = always correct.
    adoptUpTo = 25000,
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
    -- Lowest traffic amount a player starts with (0 = leave each player's own RLS setting). A game set to 4 shows the same few cars again and again.
    minAmount = 6,
    baseBudget = 16,
    perPlayerBudget = 4,
    -- Every player gets at least / at most this many (a lone player gets maxPerPlayer).
    minPerPlayer = 3,
    maxPerPlayer = 8,
    -- How often the director looks for players joining or leaving.
    checkSeconds = 1,
    -- How far from a player a traffic car may be before the game recycles it (docs/RESEARCH_RESPAWN_RANGE.md).
    -- respawnRange: multiplier on the game's own radius (1 = the game's original, up to 3 = cars stay about three times as far out).
    -- respawnDelay: seconds a car stays at least after the game placed it, before it may be recycled (0 = off, the game's original).
    respawnRange = 1.0,
    -- respawnDistance: meters. A traffic car is recycled only when it is farther than this from EVERY player (never below the game's own radius). 0 = the game's original.
    respawnDistance = 1000,
    respawnDelay = 0,
    -- spawnMinDistance / spawnMaxDistance: meters. A traffic car that the game has just re-placed (it puts it only 100 to 300 m from you) is moved to a
    -- road spot between these distances from the player (client rlsmp_trafficPlace); the traffic fill uses the same ring. Never within 120 m, in the
    -- camera view or near another player. spawnMaxDistance 0 = the game's own placement.
    spawnMinDistance = 250,
    spawnMaxDistance = 1000,
    -- Our own removal of stuck cars (client unjam.lua): only a car that stood still `seconds` and is `distance` m or more from EVERY player; one at a time.
    unjam = {enabled = true, seconds = 120, distance = 400, crashed = true, crashedSeconds = 60, inViewSeconds = 120},   -- crashed: a wrecked car near you also goes (hidden after crashedSeconds, in view after inViewSeconds)
  },

  -- Phase 3: police pursuits.
  police = {
    enabled = true,
    -- Police cars may not be re-placed (respawned / teleported) while the player is being chased.
    antiTeleport = true,
    -- Refuse RLS roadblocks (they put police cars on the road ahead of you).
    blockRoadblocks = true,
    -- RLS charges a "Police fine" when a chase ends in a citation or an arrest. Driving a car that is not registered to you (a stolen car) means
    -- the fine is not charged: the car is not on your name. The chase, the arrest and the plate flag still happen.
    noFineInStolenCar = true,
    -- Speed cameras and red-light cameras (RLS speedTraps) take no money and make no ticket from a stolen car or a car with a fake plate.
    noRadarFineIllegal = true,
    -- A police car that RLS re-places is judged by the client (rlsmp_policeRespawn): when the game put it near you, in view, on your road or straight ahead/behind,
    -- it comes back as a DIFFERENT model on another road far away (see below). `respawnPerMinute` limits how many we build (BeamMP sends every spawn and delete to everybody).
    respawnBehind = true,
    respawnPerMinute = 4,
    -- Where a re-placed cop (and a top-up cop) is allowed to appear: at least `spawnMinDistance` m (straight line) from EVERY player, not in view, not on
    -- the player's own road, not straight ahead or behind; a road on the player's right side is preferred. During a chase the minimum is
    -- `chaseSpawnMinDistance` (reinforcements may come from nearer, never into view).
    spawnMinDistance = 1000,
    chaseSpawnMinDistance = 600,
    spawnPreferRight = true,
    -- Building a car freezes the game for a moment (owner: "drops crazy fps"). A re-placed cop is only rebuilt as another model at most once per
    -- `respawnRebuildSeconds`; in between a cop that RLS put in FRONT of you is moved to the road behind you (no build, no freeze).
    respawnRebuildSeconds = 90,
    -- RLS re-places a police car once it is farther than its own radius. Police get at least this many metres (0 = the game's own radius), so a cop
    -- is not recycled (and put back close, often in front, unseen) every few seconds.
    copRespawnDistance = 450,
    -- How many AI police cars should be on the map. 0 = leave the game's number (default; the owner never asked for more cops). Above 0 the client builds more,
    -- one every `copTopUpSeconds`, up to this number (rlsmp_policeRespawn). Each cop is one more BeamMP car for everybody (MaxCars).
    copCount = 0,
    copTopUpSeconds = 30,
    -- How many of those cops the area and the time of day ask for, and where. The map is cut into squares of `areaSize` metres and at most ONE cop
    -- stands in each square. `copTargets` = cops asked for by area type (road class: city, main road, highway, other = rural / unknown) by day and
    -- by night. Never more than `maxCops` (hard maximum), never more than `copCount`. Client: rlsmp/lib/copBudget.lua.
    maxCops = 3,
    areaSize = 1500,
    copTargets = {
      city = {day = 1, night = 2},
      main = {day = 1, night = 1},
      highway = {day = 1, night = 1},
      other = {day = 0, night = 1},
    },
    -- Which traffic cars another player's game may not recycle (client rlsmp/bubble.lua):
    -- "original" = RLS's own spawn and respawn distances, a car is only kept while another player is within its
    --   own active radius AND has a clear line to it; "protect" = the old strict rule (450 m, or a clear line up to 1 km);
    -- "off" = no protection at all.
    bubbleMode = "original",
    -- false = cops near you are only held while a chase runs (they get recycled normally otherwise). true = hold every cop within 300 m all the time.
    holdNearBeforeChase = false,
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
    -- Broken / junkyard / wreck cars are never traffic: a model or config name containing one of these words is skipped (client picks and re-rolls).
    excludeWords = {"junk", "wreck", "derby", "crash", "rolling", "shell", "undriveable", "parts"},
    -- Moving traffic and/or parked cars.
    applyToTraffic = true,
    applyToParked = true,
    -- Modded cars (from a mod zip) never appear as traffic or parked cars: they are heavy for every player. They can still be bought and driven. false = allowed again.
    noMods = true,
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
    -- mode: "async" (default) = the new car is built through the game's own group spawn queue (no freeze), then the old one is removed;
    -- "inplace" = the game's replaceVehicle on the same car (one freeze of 0.5 to 2 s per re-roll); "off" = no re-rolling.
    respawn = {enabled = true, mode = "async", perMinute = 2, chance = 0.25, repaintChance = 0.5, waitSeconds = 3},
    -- Parked cars: RLS keeps as many as its game setting trafficParkingAmount says (a real log: 2). Each game raises that setting to this amount after the
    -- career starts (never lowers a higher one, gives the old value back on leaving). 0 = leave it alone. Every parked car is a car BeamMP syncs to the others
    -- and counts for the server's per-player car limit (MaxCars in ServerConfig.toml), so raise that too. Car theft needs parked cars to steal.
    -- fullPool: parked cars can be EVERY available model/config (full cars, also those with no simple_traffic stand-in), under RLS's own parked filter
    -- (no police or taxi; junk stays out through excludeWords). simplifiedShare: of the picks that have a stand-in model, this share is shown as the cheap stand-in;
    -- the car you get when you steal it is still the exact picked config (client rlsmp/trafficVariety.lua remembers it). 0 = always full cars.
    parked = {amount = 5, nightAmount = 8, fullPool = false, simplifiedShare = 0.5,
      -- Keep parked cars NEAR the player (RLS leaves its cars where they were created once they are far and switched off, docs/RESEARCH_PARKED_NEAR.md):
      -- when fewer than nearCount (nearNightCount at night) of your parked cars are within nearRadius m, one parked car that is farther than farRadius m from
      -- every player is moved to a free parking spot 120..nearRadius m from you, out of view, at most one per moveEverySeconds. 0 = off.
      nearCount = 3, nearNightCount = 5, nearRadius = 350, farRadius = 700, moveEverySeconds = 8},   -- nightAmount: wanted at night (people park); 0 or below amount = same as day
    -- Rarity: everyday cars are the clear majority. Shares of the picks per tier (renormalised over the tiers that exist). A config is "rare" when its model or
    -- config name has a rareWords word / is in rareModels / has Config Type Race or Drift / a Value of rareValue or more; "uncommon" for uncommonWords or
    -- uncommonValue; else common. Words of 5+ letters match inside names ("offroad" in "offroada331972"), shorter ones whole words only.
    rarity = {enabled = true, common = 0.88, uncommon = 0.10, rare = 0.02,
      rareWords = {"race", "racer", "racing", "drift", "hotrod", "junk", "drag", "crawler", "trophy", "buggy", "formula", "rocket"},
      uncommonWords = {"rally", "offroad", "tuner", "pro", "workpackage", "sport", "taxi", "police", "dune", "turbo"},
      rareModels = {"scintilla", "bolide"}, uncommonValue = 45000, rareValue = 120000},
    -- Preload (lag): no car is built while the frames are slow (slowFrameMs, then settleSeconds of calm), not within minGapSeconds of the last build, not in a
    -- chase. warmShare of the picks come from models
    -- that are already loaded (on the street or built this session). No spare car is ever built or hidden: BeamMP would send it to everybody.
    preload = {enabled = true, minGapSeconds = 6, slowFrameMs = 45, calmFrames = 45, settleSeconds = 3, warmShare = 0.7},
    -- Traffic uses the SAME `configs` model/configs (1 to 6) for `minutes`, then another choice (the game lags when many different configs load; lib/trafficFocus.lua).
    focus = {enabled = true, configs = 2, minutes = 20},
    -- Simplified (cheap "simple_traffic" stand-in) cars, see docs/RESEARCH_SIMPLIFIED.md. OFF by default and never tried in the game.
    -- parked: a stand-in parked car at a stealable spot becomes a real car when a player is within nearRadius (m, at least 120); traffic: a respawned
    -- traffic car farther than nearRadius from every player may come back as a stand-in, and a stand-in that comes within nearRadius is made real.
    -- perMinute = most changes per minute in one game (BeamMP sends every change to everybody). Never police, taxis, jobs, chases or players' cars.
    simplified = {enabled = false, parked = true, traffic = false, nearRadius = 250, perMinute = 4, checkSeconds = 2},
  },

  smartTraffic = {
    enabled = true,
    mix = {normal = 80, slow = 10, aggressive = 6, racer = 3, drunk = 1},
    -- At night every personality's weight is multiplied by this (so night traffic has more racers, aggressive and drunk drivers and fewer slow ones).
    -- With the default mix: about 68% normal, 4% slow, 13% aggressive, 10% racers, 5% drunk. 1 = no change. Cars get a new personality when day turns to night and back.
    nightMult = {normal = 1, slow = 0.5, aggressive = 2.5, racer = 4, drunk = 6},
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
    repriceMinutes = 30,      -- the stolen car value is worked out again by the owner's game this often (RLS used-car market moves)
    maxRepriceStep = 25,      -- one update may change the value by at most this many percent (the first one for an old record may jump)
    recallCooldown = 120,      -- seconds between two "Bring my stolen car here" presses
    recallFee = 0,             -- dollars for one press (0 = free)
    recallReportEvery = 20,    -- seconds: the least time between two place reports for one stolen car
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
    -- A player on foot may get into another PLAYER's car (never their AI traffic or parked cars) and ride along as a passenger (they cannot drive it).
    -- A passenger is put back on foot when the driver gets out, leaves, or the car is gone. See docs/RESEARCH_PASSENGERS.md.
    allowPassengers = true,
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

  -- Fair car shop prices for MODDED cars (client rlsmp_modPrice, lib/modPrice.lua): the price is estimated from power, weight, top speed, drivetrain
  -- and class; the mod author's value is kept when it is within +-tolerance of the estimate. Only models in trafficVariety.mods (or whose files were
  -- downloaded from this server) are touched; also selling, trade-in and insurance value (sell = false: car shop only, which allows buy cheap / sell high). overrides = fixed catalog price per "model" or "model/config".
  -- Example: overrides = {mycar = 45000, ["mycar/sport"] = 60000}
  modPrice = {enabled = true, sell = true, max = 2000000, min = 800, tolerance = 0.35, overrides = {}},

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
    -- The car value is the USED price of the car (the client asks RLS's own valuation, see docs/RESEARCH_STOLEN_VALUE.md).
    -- Payouts, as a share of that value: sell without papers market.fenceCarRate 0.40 < resell 0.70, strip 0.45.
    minValue = 2000,         -- the value is never below this (also used when the game had no price for the car)
    maxValue = 300000,        -- the car value the fence works from is capped here (the value comes from the client)
    modelCaps = {},           -- optional: model name -> highest value accepted for that model, e.g. {bastion = 40000}
    stripRate = 0.45,         -- parts for cash, no papers
    -- A stolen car that is damaged more than this (0..1, 0.15 = 15 percent) cannot be sold, resold or met up: only stripped. Strip pays less the more it is
    -- damaged: payout x (1 - damageStripPenalty x damage). The damage is measured by the owner's game; a sale needs a report younger than damageFreshSeconds.
    maxSellDamage = 0.15,
    damageStripPenalty = 0.5,
    damageFreshSeconds = 120,
    resellRate = 0.70,        -- fake plate + VIN plate + part number, all used up
    -- Strip / sell / resell can also be done from the Black Market phone app, for any stolen car (no drop spot, the garage rules). false = only the garage computer
    -- and the drop spot.
    phone = true,
    rep = {strip = 1, sell = 1, resell = 3},   -- reputation for a good sale
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
    fenceCarRate = 0.40,
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

  -- Fake plates on the player's own cars (garage computer, uses up one fake_plate item; server/fakePlates.lua).
  fakePlates = {
    enabled = true,
    maxPerPlayer = 16,        -- fake plates in use at the same time
    cooldown = 1,             -- seconds between two requests of one player
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
  forceSaveMinutes = 2,

  -- One-time changes already applied to this file (the server writes it; do not edit).
  migrations = {},
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
  -- (deepMerge fills `raw` in place, so look at it first)
  local oldCops = type(raw) == "table" and type(raw.police) == "table" and raw.police.copCount == 3 and raw.police.spawnMinDistance == nil
  local cfg = util.deepMerge(M.defaults, raw)
  -- One-time step: a config.json written before the cop spawn rules still has the old copCount default 3 (extra cops nobody asked for). Reset it to 0.
  if oldCops then
    cfg.police.copCount = 0
    util.info("RLSMP-P3 police.copCount was the old default 3 in config.json: set to 0 (the game's own number of cops); raise it in the [ menu if you want more")
  end
  -- Passengers are on by default now, but older files stored the old default (false): switch it on once. Turn it off again afterwards if you want.
  if type(cfg.migrations) ~= "table" then cfg.migrations = {} end
  if not cfg.migrations.passengersOn then
    cfg.migrations.passengersOn = true
    if type(raw) == "table" and type(raw.vehicles) == "table" and raw.vehicles.allowPassengers == false then cfg.vehicles.allowPassengers = true end
  end
  -- Lag (0.4.64): a config.json written before still has full parked cars (each one is a full car for you AND for every other player);
  -- switch to the cheap stand-ins once. Put it back in the [ menu if you want it (and compare the frame rate).
  if not cfg.migrations.lagTrim then
    cfg.migrations.lagTrim = true
    if cfg.trafficVariety.parked.fullPool == true then
      cfg.trafficVariety.parked.fullPool = false
      util.info("RLSMP-P3 lag trim: trafficVariety.parked.fullPool is now false (cheap stand-ins for parked cars); change it in the [ menu")
    end
  end
  -- Lag (0.4.70): fewer cars and a 1 km traffic range. A config.json written before keeps the old numbers, so set the new defaults once (change them again in the [ menu).
  if not cfg.migrations.carTrim70 then
    cfg.migrations.carTrim70 = true
    local d = M.defaults
    cfg.traffic.maxPerPlayer, cfg.traffic.baseBudget, cfg.traffic.perPlayerBudget, cfg.traffic.minAmount = d.traffic.maxPerPlayer, d.traffic.baseBudget, d.traffic.perPlayerBudget, d.traffic.minAmount
    cfg.traffic.respawnDistance, cfg.traffic.spawnMaxDistance = d.traffic.respawnDistance, d.traffic.spawnMaxDistance
    local pk, dp = cfg.trafficVariety.parked, d.trafficVariety.parked
    pk.amount, pk.nightAmount, pk.nearCount, pk.nearNightCount = dp.amount, dp.nightAmount, dp.nearCount, dp.nearNightCount
    util.info("RLSMP-P3 lag trim 0.4.70: fewer cars (traffic " .. d.traffic.maxPerPlayer .. " per player, parked " .. dp.amount .. "/" .. dp.nightAmount .. ") and traffic range " .. d.traffic.respawnDistance .. " m; change them in the [ menu")
  end
  -- Saves lagged behind (0.4.75): the server asked for a save every 5 minutes; now every 2. An old config.json with the old 5 gets 2 once.
  if not cfg.migrations.saveEvery2 then
    cfg.migrations.saveEvery2 = true
    if cfg.forceSaveMinutes == 5 then cfg.forceSaveMinutes = 2 util.info("RLSMP forceSaveMinutes was 5: now 2 (saves lag less)") end
  end
  if type(cfg.serverTag) ~= "string" or not cfg.serverTag:match("^[a-z0-9]+$") then
    cfg.serverTag = randomTag()
  end
  storage.writeJson(path, cfg, true)
  return cfg
end

return M
