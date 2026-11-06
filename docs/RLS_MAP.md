# How RLS and BeamNG career work (reference for us)

How this was made: all 820 RLS files were indexed (every Lua file's header comment, every save key, every hook),
and the systems we touch were read in full. RLS is about 194k lines of Lua, so "everything" means *indexed
everything, read in depth where it matters to multiplayer*. Vanilla BeamNG is **not** in this repo; where a
statement is about vanilla (not RLS code), it says **[BeamNG knowledge]** and should be treated as likely, not proven.

## 1. The big picture

RLS 2.8 is not a patch on vanilla career. It is a **fork that lives in its own namespace**:

- Code: `lua/ge/extensions/overhaul/...` → extension names `overhaul_<folder>_<file>` (`/` becomes `_`, `_` becomes `__`).
- Data: `gameplay/overhaul/**` (802 JSON files: modules list, facilities, jobs, businesses, economy...).
- UI: `ui/ui-vue` (Vue app, 660 files). Cars/levels/music/art are assets.
- Boot: `scripts/rls_career_overhaul/modScript.lua` loads only `overhaul_shell_extensionManager`.
  That manager reads the JSON manifests in `gameplay/overhaul/career/modules/*.json` (one per career module,
  with an `order`) and loads the whole roster. Add a module = add a file + a manifest.
- RLS has **no vanilla missions** ("Overhaul has no missions"). Its content is jobs, delivery/logistics, events, businesses.
- RLS only runs on its own **game mode** (`overhaul_shell_gameMode`), game state `"overhaul"`.
- Only map in `gameplay/overhaul/maps/` is **`rls_west_coast`**. That is why `west_coast_usa` loses
  facilities, auctions, drop-offs and businesses: they are defined for `rls_west_coast`, not the vanilla map.

### Source size by area (Lua lines)

| Area | Lines | What |
|---|---|---|
| `career/` | 167k | the career itself (see section 4) |
| `jobs/` | 26k | taxi, bus, ambulance, beamEats, repo, quarry, mining, recovery, facility work, cleanup club, card games |
| `events/` | 25k | freeroam events: derby, dakar, burnout, drag, tractor pull, race sessions, leaderboards |
| `lib/` | 21k | shared helpers: save system, ledger, lifecycle, manifests |
| `integration/` | 15k | replaces vanilla traffic / police / parking / taxi / speed traps (see section 6) |
| `phone/` `ui/` `avatar/` `dev/` | 21k | phone apps, UI glue, walking avatar, dev tools |
| `shell/` | 5k | startup, game mode, patch registry, settings, save import |
| `world/` | 7k | level proxy, facilities, weather, fuel, maps, sleep |
| `lua/vehicle/` | 22k | vehicle-side Lua: maintenance, OBD, AI, controllers |

## 2. Startup order

1. BeamNG mounts the zip and runs `modScript.lua` → loads `overhaul_shell_extensionManager` (deferred 0.25 s).
2. `extensionManager.startup()` reads manifests, loads "scopes" in order: `careerCore`, `routes`, `shell`, `services`,
   `vehicleTools`, `guards`, `settings`, `late` (the rest load on demand).
3. `overhaul_world_levelProxy` runs `generate` **when it loads**: it builds `rls_west_coast` from `west_coast_usa`
   (copies text files with patches, references big binaries by path) into `/temp/rls_career/levelCache`, then mounts it.
   Takes a while on first run; removed again when RLS unloads. **This is why a server-sent RLS zip is too late
   for BeamMP's map message.**
4. `extensionManager.refuseCareerStart()` blocks any career start while the `multiplayerbeammp` mod is active.
   We wrap that function at runtime (client `core.lua`).
5. Player starts a career: `overhaul_shell_gameMode.start(profile, slot, startingOptions)` →
   `overhaul_career_career.createOrLoadCareerAndStart` → `career/start/startingModes.lua` → `transitions.lua`.

## 3. Career start and activation (what happens when we call it)

`startingModes.createOrLoadCareerAndStart(name, specificAutosave, startingOptions)`:
- validates names (`lib/save/pathComponent.lua`: no `<>:"/\|?*`, no Windows device names), flushes any pending save,
  sets the save profile, then `career.activateCareer(removeVehicles=true, level)`.
- Level choice: **explicit level > level saved in `career/general.json` > default map**.
  For a *new* save `startingOptions.startingMap` is used. If the level differs from the loaded one, RLS does a
  full level switch (`freeroam_freeroam.startFreeroam`) which would drop a BeamMP session. We avoid that by passing
  the current level and rewriting `general.level` in the save we write (client `saveBridge.patchLevel`).
- `activateCareer` with `removeVehicles=true` calls `core_vehicles.removeAll()` (deletes every vehicle, including
  synced ones). Our players reported no problem, but it is the likely cause of odd vehicle states on join.
- Required modules must be loaded: inventory, payment, permissions, playerAttributes, switchMap.
- Activation ends with hook `onOverhaulActive(true, newSave)` (we use it), and the player must "exist":
  walking (unicycle) or seated in an inventory car, else RLS spawns them at the level's `recoverySpawn`.
- Start options we can pass (`startingModes.applyStartingOptions`): `careerStartMode`, `difficultyMode`, `hardcore`,
  `cheats`, `startingMap`, `startingCash`, `policeEnabled`, `xpMultiplier`, `economyMultiplier`,
  `experimentalMaintenanceEnabled`, `startingGarageMode/Id`, `challengeId`, sandbox economy/xp profiles.
  (Server config `newCareer` forwards a subset.)
- Starting modes: `freshStart` = $10,000 and spawn at the dealership; `apmOnboarding` = no capital + onboarding placement.

## 4. Saves (the most important part for us)

Location: `settings/cloud/overhaul/saves/<profile>/<slot>/` where slot = `autosave1..4` (or named saves).
- `info.json` has the game save version, `OVERHAUL_SCHEMA` (a newer slot is refused), `date`, `displayName`.
  A slot is only "newest" if `info.json` has a `date` and is not `corrupted`.
- A save writes a **full set of files into the oldest free autosave slot** (rotating), via a time-budgeted queue
  (`WRITE_BUDGET_MS = 2.5` per frame), commits `info.json` last, keeps a backup folder until the commit succeeds.
  After a save, `overhaul_career_saveSystem.getLastSaveStats().path` is the folder just written. We rely on this.
- Hooks: `onOverhaulSaveCurrentProfile(path, thumbnails, writer)` (owners write their files),
  `onOverhaulSaveFinished`, `onOverhaulSaveFailed`, `onOverhaulBeforeSaveExit`, `onOverhaulSetProfile`.
- Autosave every 5 minutes, deferred while the player is moving (`playerIsStopped`) or in certain routes.
  `saveSystem.requestSave(reason)` / `saveCurrent()` ask for one.
- Files written (from the key registry plus owner code):
  - `career/general.json` (level, starter bought), `career/playerAttributes.json` (**money**, beamXP, vouchers, branch XP),
    `career/attributeLog.json`, `career/branchUnlocks.json`, `career/logbook.json`, `career/milestones.json`
  - `career/vehicles/<n>.json` (+ `.jpg` thumbnail, `damage/<n>_damageState.json`), `career/inventory.json`, `career/partInventory.json`
  - `career/logisticsDatabase.json`, `career/rls_career/*.json`: `bank.json`, `loans.json`, `credit.json`,
    `globalEconomy.json`, `carmeets.json`, `cleanupClub.json`, `miningHaul.json`, `taxiRating.json`, `time.json`,
    `vehicleTransfer.json`, `guide.json`, option files (`difficultyMode`, `maintenanceMode`, `policePreference`, ...),
    `businesses/*/kits.json`, garage/property/auction/marketplace files, weather and drag files
  - global (not per slot): `settings/RLS/guideGlobal.json`, `settings/RLS/savedTunes.json`
- Our bridge uploads every `*.json` in the slot and skips `.jpg` (RLS regenerates thumbnails).

## 5. Money (what the server must watch)

- All money goes through **one ledger**: `lib/ledger/authority.lua` → accounts `wallet` and `bank:<id>`.
  `playerAttributes.addAttributes({money = x}, reason)` posts to the `wallet` account, then fires
  `onOverhaulPlayerAttributesChanged(change, reason)`. **We hook that** (client `wallet.lua`).
- `reason` is a table: `{label, tags, category, ...}`. We forward only the label.
- Money also lives in places the server does **not** check yet:
  `career/rls_career/bank.json` (personal + business savings accounts, 5-minute delayed transfers, savings interest),
  `loans.json`, property mortgages/rentals, passive businesses, racing team finances, auction bids.
  A modified save could mint money there. Fix idea: hook the ledger itself
  (`overhaul/lib/ledger/authority` `post`) so every account change is reported, and have the server compare
  total net worth, not only `playerAttributes.money`.
- 35 files call `addAttributes`. Payouts come from `career/economy/payment.lua` (`pay`, `reward`, wage holders/escrow),
  jobs, logistics `progress.lua` settlement, employment `settlement.lua`, auction, taxi.

## 6. Vehicles and garages

- `overhaul_career_garage_inventory` owns the vehicle records (`getVehicles()`, `getVehicle(id)`,
  `addVehicle(vehId, inventoryId, options)`, `removeVehicle(id)`, `getCurrentVehicle()` = inventory id of the seated car,
  `getInventoryIdFromVehicleId`, `hasFreeSlot`, `setVehicleDirty`).
  Record fields (from `initializeVehicleRecord`): `model`, `config` (BeamNG part config table), `id`, `owned`,
  `lastKnownLevel`, `year`, `niceName`, `configBaseValue`, `partConditions`, `maintenanceState`, ...
- Capacity comes from owned garages (`garageManager`); `takesNoInventorySpace` configs are free.
- Inventory ids are **per save**, numbers starting at 1 (`personal`), other ids are temporary contract/loaner targets.
- Garages, real estate (`garage/property/*`: mortgages, rentals, negotiation), studio rentals, fast travel,
  towing/map-travel (`switchMap.lua` stages cars and switches level; **unusable on BeamMP**).
- Our fleet feature uses exactly: upload the record, `removeVehicle` after server OK; on take,
  `core_vehicles.spawnNewVehicle(model, {config = record.config, pos = ...})` then `addVehicle(vehId, nil, {owned = true})`.
  RLS itself spawns with `core_vehicles.spawnNewVehicle(model, {config = <table>, pos = ...})` (confirmed in its code).

## 7. Businesses in RLS vs our "Business" (do not mix up)

RLS **businesses** = things the player *buys* (tuning shop, engine shop, passive stores, racing team) with
loans, skill trees, employees, a business bank account, and its own `career/business/fleet.lua` (customer cars).
Our **Business/Syndicate** = a multiplayer crew with a shared bank and shared car pool (server-side).
They are separate. A later step could let a syndicate fund or co-own an RLS business.

## 8. Jobs, logistics, market, events (Phase 4 material)

- `jobs/`: taxi, bus, ambulance, beamEats, repo, quarry, miningHaul, recovery, facilityWork, cleanupClub, cardGames.
- `career/logistics/`: broker (freight offers), parcels, materials contracts, owner-operator contracts, vehicle
  deliveries, loaners, cargo screen, progress (drop-off settlement). Cargo and jobs are generated from
  facilities (`world/facilities.lua`, files in `levels/rls_west_coast/facilities/*`).
- `career/work/employment*`: company shifts, equipment rental, settlement.
- `career/market/`: vehicle shopping, marketplace negotiation, **auction** (`auction/*`, NPC bidders in `auctionNpcs.lua`),
  value calculator. The auction is NPC-driven and local to each client: in MP, two players would see different lots.
- `events/`: derby, dakar, burnout, drag (`integration/patches/dragFreeroamBridge.lua`), tractor pull, race sessions, leaderboards.
- Drag/crawl scores, speed-trap leaderboards, carmeets reputation are per-profile saves.

## 9. Traffic, parking and police (Phase 3 material)

RLS does **not** ship vanilla `gameplay/traffic.lua`. It keeps the vanilla modules (`gameplay_traffic`,
`gameplay_parking`, `gameplay_police`) and **wraps their methods at runtime** in
`integration/ownedServices.lua` through the shell patch registry (`wrapperLifetime`), only while the RLS game mode is active.

- Traffic vehicle class methods replaced by `integration/ownedServices/trafficVehicle.lua`:
  `init, resetPursuit, resetValues, setAiMode, setRole, checkCollisions, fade, tryRespawn, triggerOffense,
  checkOffenses, checkPoliceVisibility, onTrafficTick, onPursuitUpdate, onUpdate, ...`.
- Respawn (**what the Phase 3 anti-teleport work must change**): each vehicle tracks
  `respawn.finalRadius = activeRadius + extra` (`updateActiveRadius`: 80-160 m base, plus focus speed and
  "player looking toward it" bonuses, shrinking when occluded). `tryRespawn()` fades the car out when
  `finalRadius < focusDist`, never for the car the local player sits in, and only if no non-traffic vehicle is
  near its respawn spot. **`focus` = `gameplay_traffic.getFocus()` = the local player only.**
  So in MP each client's traffic only knows its own player; remote cars are just "non-traffic vehicles".
- Police: `integration/services/police.lua` (pursuits, roadblocks, suspects, arrest/evade, teleport grace),
  `ownedServices/trafficPoliceRole.lua` (police AI actions), `career/police/*` (player police job, fines, speed traps).
  `setPursuitMode(mode, targetId, policeIds)`; modes: -1 busted, 0 off, 1+ pursuit level.
  Vehicle switching hands a pursuit to the new car (`onVehicleSwitched`) and inserts the player's car into traffic
  with `gameplay_traffic.insertTraffic(id, true)` (so a player car IS in `getTrafficData()` with `isAi = false`;
  our vehicle guard relies on that).
- Parking: `integration/services/parking.lua` (1,756 lines): spots, pooling, `forceTeleport`, `scatterParkedCars`,
  activation radius.
- Everything above is client-local physics. The server cannot run it, which matches the Traffic Director plan:
  the server only assigns quotas; each client spawns/owns its share, and BeamMP syncs them as that player's vehicles.

## 10. World, levels, UI

- `world/levelProxy.lua`: builds `rls_west_coast` (see section 2). `world/maps.lua` lists maps RLS can run;
  `world/facilities.lua` loads facility files; weather has its own clock (`world/weather*`); fuel prices follow the economy index.
- `levels/rls_west_coast/` holds the RLS overlay (facilities, sites JSONs, race data, MissionGroup edits).
  Facility/site files are read through the merged level VFS.
- UI: Vue app (`ui/ui-vue`), routes registered from Lua (`ui_router`), phone apps (`phone/`).
  Server-driven messages reach it with `guihooks.trigger(...)` (we use `toastrMsg`).

## 11. BeamNG fundamentals we depend on **[BeamNG knowledge]**

- **VFS/mods**: zips are mounted over the game's virtual file system; later mounts win for equal paths.
  `scripts/<mod>/modScript.lua` runs on mount. BeamMP puts server mods under `mods/multiplayer/`.
- **Two Lua worlds**: *GE Lua* (game engine, one per game: `lua/ge/extensions/*`) and *vehicle Lua*
  (one per car, own thread: `lua/vehicle/*`). They talk with `obj:queueLuaCommand` and `be:getObjectByID(id):queueLuaCommand`.
- **Extensions**: a file `lua/ge/extensions/a/b.lua` becomes global `a_b`. Hooks (`onUpdate`, `onVehicleSwitched`,
  `onClientStartMission`, ...) are called on every loaded extension that defines them; `extensions.hook(name, ...)`
  fires custom ones. Unload mode `manual` keeps an extension across level changes.
- **Walking** is a vehicle named `unicycle`. "Player vehicle" can be that or a car.
- **Vanilla career** (0.40): `career_career`, `career_saveSystem`, modules under `lua/ge/extensions/career/modules/`,
  saves at `settings/cloud/saves/<profile>/autosaveN/`. RLS forked these and moved them to `overhaul_*`.
  Vanilla career is **not** active while RLS runs; CareerMP (which wraps vanilla career) therefore cannot run alongside it.
- **BeamMP** (`MPVehicleGE`, `MPCoreNetwork`, `MPGameNetwork`): server picks the map; each client's cars are
  synced to others; `MPVehicleGE.isOwn(id)`, `getServerVehicleID`. Events: `TriggerServerEvent`, `AddEventHandler`;
  server: `MP.RegisterEvent`, `MP.TriggerClientEvent`. Default max event size is limited, hence our 16 KB chunks.

## 12. What this changes in our plan

1. **Server map must be `rls_west_coast`** (RLS's only registered map); RLS installed locally so the proxy level exists first.
2. **Phase 3** must hook RLS's owned traffic methods (`tryRespawn`, `updateActiveRadius`, police `setPursuitMode`),
   not vanilla `gameplay_traffic` alone. The key lever: make `focus`/`focusDist` consider all players
   (distance to the *nearest* player) and treat remote vehicles as potential witnesses for "out of sight".
3. **Money**: extend validation from `playerAttributes.money` to the ledger (wallet + bank accounts + loans).
4. **Auction/market/job offers** are generated locally per client; plan a per-server seed or server-owned offer list in Phase 4.
5. **`removeAll()` on activation** and **map travel** are MP hazards: block `switchMap` travel while online (Phase 4).
6. RLS **cheats mode** (`cheats = true`, `CHEATS_STARTING_CAPITAL = 1e12`) must never be accepted from a client: server
   sets start options; the wallet cap protects us, but we should also refuse `cheats`/`freeroam` start modes in config.
