# Research: varied respawns, a premade car pool, more parked cars

Read-only look at the RLS source (`rls_career_overhaul`) and the owner's log (build 0.4.32). Anything marked **unverified** I could not see: the vanilla game files (`gameplay/traffic.lua`, `core/multiSpawn.lua`, `core/vehicles.lua`) are not in the RLS repo.

## 1. What the log showed
- One traffic group only: `Spawning vehicle group with 5 vehicles: autoTraffic` (a taxi, a police Bastion, a Bastion drag, a Roamer, another taxi). No second group in 16 minutes.
- Parked cars: `Spawning vehicle group with 2 vehicles: autoParking`, then `Parking system started with 2 active / 2 total vehicles`. Both were model `simple_traffic` (configs `pickup_d25_parked.pc`, `legran_sedan_pre_s_parked.pc`): parked cars are the cheap "simplified" stand-ins, the real model is only in the config name.
- `Ignoring deprecated setting: trafficParkedAmount` is only the old setting name in the owner's settings file. It is not the one RLS reads.
- The server settings arrived 2.7 s after the first group (fixed in 0.4.33).
- Note: with default weights every car weighs 1 and live swapping needs a car to weigh `minRatio` (1.5) times more than the offer, so on a default server **live swapping never swaps anything**, even though it is on by default. It only follows real weights. That is why this work does not use it for picking.

## 2. Why respawned cars keep their model (RLS source)
`overhaul/integration/ownedServices/trafficVehicle.lua`:
- `C:tryRespawn()` (line ~490): when `respawn.finalRadius < focusDist` (and no other player's car is too close) it sets `self.state = 'fadeOut'`. `C:fade` ends in `state = 'queued'`. The vanilla traffic system then moves a `queued` car to a new spot and calls `C:onRespawn()` (line ~691), which does `respawnCount = respawnCount + 1`, `respawnActive = true`, `state = 'reset'`. `onRefresh` then sets `fadeIn` and `active`.
- The only thing RLS re-rolls on respawn is the paint (`useRandomPaint` -> `core_vehicle_manager.setVehiclePaintsNames(id, core_vehiclePaints.getRandomPaintsByVehicle(id))`). The model and config never change. The vanilla step that moves the queued car is not in the RLS repo (**unverified**: whether the move happens before or after `onRespawn`; we wait one poll after the count goes up, so both orders work).
- Do not wrap `tryRespawn`/`onRespawn`: `rlsmp/bubble.lua` already re-wraps `class.tryRespawn` every frame, RLS installs class methods directly (`ownedServices.lua` `methodNames`), and `onRespawn` runs inside the vanilla traffic loop (changing the traffic table there would be unsafe). Instead we **poll** `gameplay_traffic.getTrafficData()` and watch each car's `respawnCount` (a plain field) go up.

## 3. Where a different model can come from
- RLS ships **one** vehicle group file: `levels/rls_west_coast/police.vehGroup.json` (5 Bastions). There is no traffic or parked `.vehGroup.json` in RLS. `police.lua` loads it with `gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'police'})`. Whether the vanilla `west_coast_usa` level has `traffic`/`parked` group files is **unverified**; the log says traffic came from `autoTraffic` (the generator), so there is none in use. So there is no ready-made car pool from files to reuse; the pool has to come from the model list.
- `core_multiSpawn.createGroup(amount, params)` is the generator. RLS wraps it (`trafficConfigFilter.lua`): it asks the original for 3x the amount up to 4 times, keeps entries that pass `isConfigEligible(model, config, params)` (rejects Police, `Frame`/`joesJunkshell`, power below 60, empty engine, missing wheels, square wheels) and returns the group. Its picking uses the model list's `Population` (unverified) and `Config Type` weights (`joesjunkcar 0.05`).
- `trafficConfigFilter.isConfigEligible` is exported and cached, so we use it for every config of the pool. `gameplay_traffic_trafficUtils.getBaseGroupParams()` (what RLS's parked code uses as the base for its params) gives the allowed model Types; we read them from there when present, otherwise skip `Prop*`, `Trailer`, `simple_traffic`, `unicycle`.
- The model list (`core_vehicles.getModelList().models[name]`) has `Type` (used already) and, unverified, `Brand`. Config entries (`core_vehicles.getModel(name).configs[cfg]`) have `Config Type` (known: RLS reads it) and, unverified, `Population`. If `Brand` is missing the per-brand cap simply does not apply to that model. If `Population` is missing the config counts as normal.

## 4. The pool selector (built)
`lib/trafficVariety.lua`: `newPool`, `poolNote`, `poolFactor`, `popFactor`, `pickOne`, and `select(..., mem)`.
- Premade pool (client `rlsmp/trafficVariety.lua`): built once per session, 3 models per frame, from every spawnable model of the right Types, up to `pool.configsPerModel` (5) random eligible configs each. Logged as `premade pool: N configs of M models, B brands`.
- Round robin: a model is not allowed again within the last `avoidLast` (6) picks (the window shrinks when fewer models exist), at most `brandMax` (3) picks of one brand in the last `brandWindow` (12), at most `streetMax` (3) cars of one brand on the street now. The rest are weighted: least recently used gets up to 7x, times the server's weights (Type, model, road class, day or night), times a mild Population factor (`popPower` 0.5; 0 = off). Every model is equally likely whatever its number of configs.
- `pickOne` relaxes in five steps (all rules, no brand caps, no avoid window but not the model picked last, any other model, same model with another config) and returns nil only when nothing at all is usable (the car then stays).
- Groups (`createGroup` wrapper) add the premade pool to the game's offer and use the same memory, so a refill or a new group continues the round robin instead of restarting it.
- Parked groups do not use the pool (they are simplified stand-ins).

## 5. The respawn re-roll (built)
`rlsmp/trafficReroll.lua` + `lib/trafficReroll.lua`. When a car's `respawnCount` goes up it is "due" for `waitSeconds` (3). It is replaced once:
- `personality.skipReason` is nil (standard civilian AI; not player, remote, parked, police/taxi/job role, pursuit, crashed, locked/owned); the state may be `reset`, `fadeIn` or `active` (asked to skipReason as if active); not `rlsmpHold`;
- not on this camera (`camVisible`), the bubble is on, and `bubble.stayFor` is false (nobody near or looking);
- `respawn.perMinute` (3) not used up, `respawn.chance` (1) passed, not `simple_traffic`, no other swap running.
The replacing is `rlsmp_trafficSwap.replace` (the game's own `replaceVehicle` captured by `replaceGuard`, with `{config = ..., autoEnterVehicle = false}`), result check (new id or in place), `insertTraffic` if the traffic system lost it, and the shared 3-failures switch-off. New in it: it marks the car in BeamMP's table (`entry.jbeam = "-"`, the same marker `replaceGuard` uses) so the change is synced, and checks the new car stands where the old one stood (moves it back if it is more than 5 m away). Afterwards `respawn.repaintChance` (0.5) of the cars get random paint (RLS's own call).
- **Unverified in the game**: what `replaceVehicle` returns for a different model, whether BeamMP syncs it correctly, whether `insertTraffic` restores the role and pooling, whether the respawned car is really already at its new spot when we act. The log lines `reroll:` and `swap done (...)`/`swap failed` are there to find out. It stops itself after `swap.maxFailures` failures (shared with live swapping).
- Clones: a car that appears without a respawn goes through `createGroup` and so through the pool. A car created some other way is not re-rolled (no hook found).

## 6. Parked cars: how many (RLS source)
`overhaul/integration/services/parking.lua`:
- `getParkedCarCap()` (line ~721): 0 if the player switched parked cars off (`settings trafficParkedVehicles == false` or RLS `noParkedMode`); else the game setting **`trafficParkingAmount`** if > 0; else `clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 20)`.
- `enforceParkedCarCap()` deletes every parked car above the cap, so spawning extra cars would just be undone: **the setting is the lever**.
- `syncParkedCount()` (exported) tops up to the cap through `setupVehicles(missing, {keepCurrent = true, farOnly = ...})`; returns false while a spawn is pending. `setActiveAmount(n)` sets how many are active at once (default unlimited, but `playerDriving` resets it to its own `desiredParkingAmount`).
- `career/police/playerDriving.lua` `getFallbackTrafficAmounts()` reads the same setting for the first spawn (`setupTrafficHelper(traffic, options, parkingAmount)`); `M.onSettingsChanged` (exported, also the game hook) recomputes `desiredParkingAmount`, calls `setActiveAmount` and `syncParkedCount`.
- The auto value is never below 4, so the **2** in the log can only be an explicit `trafficParkingAmount = 2` in the owner's game settings (or `trafficRestrictForCareer`, which would also have given 1 traffic car; the log had 5). I could not see the owner's settings file. The client logs the old value (`parked: setting trafficParkingAmount 2 -> 10`).

### What we do (`rlsmp/parked.lua`, config `trafficVariety.parked.amount`, default 10, 0 = leave alone)
1. After the career runs and the server's settings are here: `settings.setValue("trafficParkingAmount", amount)` unless the player's own value is already higher. Remember the old value.
2. Call RLS's `overhaul_career_police_playerDriving.onSettingsChanged()` (recomputes everything) and `overhaul_integration_services_parking.syncParkedCount()`.
3. Retry the top-up every 5 s (at most 12 times) while there are too few cars.
4. If someone else changes the setting afterwards we stop managing it. On leaving the server the old value is put back.
- **Unverified**: `settings.setValue` is assumed to take (key, value); it may also write the player's settings file (the old value is restored on leaving, but a crash would leave the raised one); the vanilla UI slider might have a lower maximum than 30, the code path does not care. Nothing in RLS or BeamMP files is edited.
- Cost: every parked car is a synced BeamMP car for that player. BeamMP's per-player limit (`MaxCars` in `ServerConfig.toml`, default 1 on a stock server) counts them, as it already does for traffic. Keep `parked.amount` moderate (10 default, hard cap 30). Parked cars are cheap `simple_traffic` stand-ins, so the load is mostly network.
- The theft code finds parked cars through `gameplay_parking.getParkedCarsList`, so more parked cars mean more to steal; the 30 s census line in `rlsmp/theft.lua` shows the effect.

## 7. Untested list (first things to check in the next log)
`premade pool:` lines (config, model and brand counts; if 0, the Type or filter assumption is wrong), `variety traffic group:` (premade count and the car names), `reroll:` and `swap done`/`swap failed`, `parked: setting trafficParkingAmount`, then `Parking system started with N active / M total vehicles` and `parked: N parked cars now`.
