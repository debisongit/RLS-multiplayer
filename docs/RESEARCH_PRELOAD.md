# Research: preloading cars (lag when a traffic car is re-rolled)

Claude A. Sources: the owner's log of build 0.4.36 (`4fbbd693-beamng.log`), our own code, and what I know of BeamNG/BeamMP. The vanilla game files (`core/vehicles.lua`, `core/multiSpawn.lua`, `gameplay/traffic.lua`, `jbeam/*`) and BeamMP's `MPVehicleGE` are NOT in this repo, so everything about their insides is **unverified** and marked so.

## 1. What the log shows (verified)

Every re-roll is `replaceVehicle` on the same id (`swap done (replaced in place, same id)`), 15 of them in 330 s (one every 11 to 50 s), always `pool stage 1` (the best stage, so nothing was relaxed: that is normal). One example, `275`:

```
274.446  spawn.lua   Spawning vehicle 'etk800'
274.487  vehicleLoader partConfigData = vehicles/etk800/844_250_A.pc
274.489  jbeam.getAvailableSlotNameMap  (duplicate-part error spam)
274.675  collada      Duplicate mesh ... (error spam, one block per mesh file)
274.722  collada      Mesh Cache rebuilt summary: 3 of 205 files freshly loaded, 40 already in cache ... 351 of 2423 meshes loaded
274.749  core_vehicle_manager.loader   GE load time: 0.26 s
275.19   MPVehicleGE  Vehicle 96360 updated from - to etk800   (BeamMP syncs the edit)
275.30   libbeamng.loader  Vehicle loading took: 7.9 ms
275.32   controller.init (vehicle thread starts its controllers)
275.40   our "swap done"
```

So one re-roll is roughly **0.9 to 1 s of wall time** in the game, in this order: config + jbeam resolve (the "GE load time" 0.24 to 0.29 s in every swap), collada mesh loading (the "Mesh Cache" lines; only the meshes not loaded yet), the physics object creation (`Vehicle loading took` 7 to 10 ms), the vehicle-side Lua init (controllers), then BeamMP's `onVehicleSpawned` / `sendVehicleEdit`. The log has **no frame times**, so I cannot say which of these steps is the visible hitch; the GE-side steps (jbeam, meshes, BeamMP) run on the main game thread and are my first suspects (**guess**). The first big loads at session start (`GE load time: 5.95 s`) are the cold start.

Other things in the same log: `Camera switched to "orbit"` appears around each swap (before and after the new car). That is probably the game's camera setup for the new object, not the player's camera (**unverified**, worth watching: if the player's view jumps at a re-roll, that is a second bug). `scoutGauges` FATAL LUA ERROR lines come from a vehicle-side UI script and are unrelated.

## 2. What is expensive when a car is built (mostly guesses, from the log)

| Step | Seen in log | Can we prepare it in advance? |
|---|---|---|
| model + config lookup (`core_vehicles.getModel`, config `.pc` JSON) | not timed | Yes, cheap: the game caches model data; we read it ahead (**unverified** that this saves anything measurable). |
| jbeam parts resolve ("GE load time", 0.24 to 0.3 s) | yes, every swap | Not without building a car. Unknown whether the game caches parsed jbeam per model between spawns (the later GE load times are smaller than the first, 0.06 to 0.4 s, which suggests a cache for repeated models: **guess**). |
| mesh loading (collada, "351 of 2423 meshes loaded") | yes | Only by having the model loaded already: meshes stay in the mesh cache once used. This is why we bias picks to models already on the street. |
| physics object + vehicle thread Lua init | yes (small ms, then controllers) | No. |
| BeamMP sync (`sendVehicleEdit`, spawn/delete to all players) | yes | No, and it multiplies with the player count. |
| texture/material load | not in the log | **unknown**. |

## 3. What the engine offers, and why we did not use it

- **Hidden / off-map spare cars**: nothing in the engine builds a car without an object in the world, and BeamMP's `MPVehicleGE` sends every spawned local vehicle to the server and from there to every player (the `Vehicle ... updated`/`custom data ... was sent` lines are exactly that). A hidden reserve car would therefore show up for the other players (and count against `MaxCars`). **Rejected on purpose.** (BeamMP has no "do not sync this one" flag that I know of; **unverified**, and editing BeamMP is not allowed anyway.)
- **Reusing deactivated traffic cars (vehicle pooling)**: BeamNG's traffic system does keep and re-place cars (that is the respawn we already hook), but the model stays; changing the model of an existing object is the same `replaceVehicle` cost. `core_vehicleActivePooling` only hides/sleeps far cars (**unverified details**); it does not make a new model cheaper.
- **`core_multiSpawn` groups**: spawning a whole group is still N full builds; it only batches the request. Not cheaper per car.
- **Spawning at start**: the game's own first groups are built while loading (the 5.9 s load); that cost is paid at a moment nobody minds. After that every change is a live build.

So the engine cannot hold a built-but-invisible-to-BeamMP car for us. What is left is to make each build **rarer, spaced out, cheaper where possible, and never at a bad moment**.

## 4. What was built (all untested in the game)

Config `trafficVariety.preload` (server, sent to clients, sanitized again): `enabled, reserve=3, prepareSeconds=4, minGapSeconds=6, slowFrameMs=45, calmFrames=45, settleSeconds=3, warmShare=0.7, ageMax=240`.

1. **Frame guard** (`lib/trafficPreload.lua`, used by `rlsmp/trafficSwap.lua` `canBuild()` and checked inside `M.replace`, so both the re-roll and live swapping obey it): the real frame time of the last `calmFrames` frames is tracked. A build is refused while a frame was longer than `slowFrameMs` less than `settleSeconds` ago, while the average is above it, within `minGapSeconds` of the last build, while the police module says the player is in a pursuit, or while physics is paused (`be:getEnabled() == false`). A build is itself a slow frame, so builds space themselves out. Race and loading screens are **not** detected by name (I know no safe check); they show up as slow frames, so the guard covers them indirectly.
2. **Reserve** (`rlsmp/trafficReroll.lua` `prepare`): up to `reserve` picks are made ahead with the same pool selector (so the round robin and brand caps count them), one per `prepareSeconds`, only when a build would be allowed. For each, `core_vehicles.getModel(model)` and `jsonReadFile(vehicles/<model>/<config>.pc)` are called inside a `pcall` to warm the game's data caches. A re-roll takes the oldest ready pick that is not the car's own model; a pick expires after `ageMax` s and is dropped when the road class or day/night changed since it was made (so the zone weights are never stale). If the reserve is empty the pick is made on the spot as before.
3. **Warm bias** (`rlsmp/trafficVariety.lua` `noteWarm`, `pickReplacement`): models seen in the traffic table, in a group, or built by a re-roll count as warm. With chance `warmShare` the pick is made only among warm models (if at least 6 exist; else the whole pool). Goal: reuse already loaded meshes. **Unverified** that it lowers the hitch; the data to check it is in the log lines below.
4. **Logs**: `preload: prepared <model>/<config> in N ms; ready X of Y`, `preload: build <model>/<config> took N ms in the call (from the reserve | picked on the spot)`, `preload: build postponed: <reason>` (on change), `preload: builds allowed again`, counters `builds (reserve)`, `builds (on the spot)`, `build postponed (...)`, `pool picks (warm model)`. The `took N ms` figure is `os.clock()` around the game's `replaceVehicle` call, i.e. the blocking part on the game thread. **If this number is small but you still see hitches, the cost is outside the call (mesh/vehicle thread/BeamMP) and the frame guard plus a lower `respawn.perMinute` are the only levers left.**

BeamMP: nothing new is spawned or synced by the preload; only the same single replace per re-roll as before, and fewer of them when frames are slow.

## 5. Related change in the same work: rarity and area weights

Owner log picks such as `bx/pro_drift_M`, `muscle/race`, `scintilla/gt_spider`, `beachbuggy/tuner_m`, `sunburst2/joes_junk_career_sunburst_sedan` showed the pool was a flat list of all configs. Now (`lib/trafficVariety.lua`):

- Each config gets a tier: `rare` (name words like race, drift, hotrod, junk, drag, crawler, buggy, formula; models scintilla, bolide; Config Type Race or Drift; Value of 120000 or more), `uncommon` (rally, offroad, tuner, pro, workpackage, sport, taxi, police, dune, turbo; Value 45000 or more), else `common`. Words of 5+ letters match inside names, shorter ones whole words only. Config Type and Value are read from the model's config info when present (**unverified** field names `Config Type` and `Value`; the name words work without them).
- The tiers get shares of the picks (88 / 10 / 2, renormalised over the tiers that exist in the list) in both `select` (groups) and `pickOne` (re-rolls). Tested over 3000 picks with a 40-model pool: common at least 80%, rare at most 4%. With a very small model pool the round-robin "unused for long" boost can push rare picks higher; uncommon and rare models get no such boost.
- Road class (city/main/highway from the road's speed limit) and day/night weights already existed but the shipped defaults were empty, so they did nothing. Defaults now: trucks, vans, semis more on highways, fewer in the city and at night, small cars a little more in the city. The weights reach the reroll through `pickReplacement` -> `pickOne` -> `M.weight`. The road class comes from the road under the **player**, not under the re-rolled car (**limitation**). The log line `variety context: zone=... night=...` appears when it changes; `zone=nil` means the game gave no speed limit and the zone weights are then not used.

## 6. Check first in the next log

`preload: prepared`, `preload: build ... took N ms (from the reserve / picked on the spot)`, `build postponed`, `variety context:`, and compare hitch moments with the `swap done` times (about 1 s after `Spawning vehicle`). Also whether the camera still switches to orbit at a re-roll.
