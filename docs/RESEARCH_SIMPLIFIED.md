# Research: simplified ("simple_traffic") cars, parked and moving

Claude A. Sources: the RLS source (read only), our own code, the owner's earlier logs. The vanilla game files (`gameplay/traffic.lua`, `core/multiSpawn.lua`, `core/vehicles.lua`, `vehicles/simple_traffic/*`) and BeamMP are NOT in this repo and I could not read them, so everything about their insides is **unverified**. Nothing here was played.

## 1. What "simplified" is (verified in RLS source / owner log)
- It is a real model name, `simple_traffic`. A simplified car is an object whose `jbeam` is `simple_traffic`; the REAL model is only in the config file name: `vehicles/simple_traffic/legran_sedan_pre_s_parked.pc` stands for a legran. RLS reads it the same way (`ownedServices/trafficVehicle.lua:139-146`: `if obj.jbeam == 'simple_traffic'` take the part after the last `/`, match `%w*`, look that model up for the display name). Our `lib/theft.lua` `realModel` does the same.
- There is **no runtime "simplified physics" switch** in RLS (grep for `simplif`/`simple_traffic` finds only `trafficVehicle.lua:139`, `taxi.lua:296` and an unrelated route function). RLS never converts simplified to full at runtime ("no code switches simplified to full physics at runtime", `RESEARCH_PLATES_THEFT.md`). The only conversion we know that works is replace/delete + spawn.
- The owner's log (0.4.32): both parked cars were `simple_traffic` (`pickup_d25_parked.pc`, `legran_sedan_pre_s_parked.pc`). So **the game already offers only stand-ins for parked cars** (group filter `Type = PropParked`, RLS `trafficConfigFilter.isParkedSpawnIntent`; parked configs may be undriveable shells, `parkedPool` skips the engine/wheel/power checks). The same log's traffic group had only real models (taxi, Bastion, Roamer).
- `taxi.lua:296`: "Keep the traffic provider's pooling/spawn path, but never its simplified models." That comment says the traffic provider CAN hand out simplified models (probably a vanilla traffic option; **unverified** which setting and whether it is on in RLS), and `trafficVehicle.lua` handles them as traffic. RLS's wrapper keeps its own rule for traffic: `isConfigEligible` rejects configs with no engine slot and zero power (`noEngine`), power under 60 (`powerBelow`), missing wheels. Whether the stand-in configs pass that is **unknown**: the new `simplified: stand-in configs ...` log line prints how many pass and the rejection reasons. We respect RLS's filter and do not bypass it. If it rejects all, RLS is saying "no simplified moving traffic" and the traffic half stays idle.
- Our code kept stand-ins out of the traffic pool on purpose (`BLOCKED_MODELS.simple_traffic` in `rlsmp/trafficVariety.lua`, still true) and the re-roll used to skip them.

## 2. What is different between a stand-in and a real car (mostly unverified)
| Topic | Known / guess |
|---|---|
| Physics cost | Stand-in = reduced model (few nodes, **guess**). The real saving is unmeasured; nobody has frame times. |
| Where a parked car costs anything | RLS keeps parked cars in a vehicle pool (`core_vehicleActivePooling`, `parking.lua` `insertVehicle`, pool "overhaulParking"). Far parked cars are `setActive(0)`: physics frozen, nearly free whatever the model. So for PARKED cars the stand-in mostly saves nodes/memory for the few ACTIVE ones near a player, and BeamMP sync size. **The big win is therefore for moving traffic, not parked cars.** (An alternative cheap mode for far cars is exactly that pooling; RLS already does it for parked cars and the vanilla traffic system pools far traffic, details **unverified**.) |
| Collisions, damage | A stand-in is probably a rigid/simple body: little or no deformation, no parts; **unverified**. |
| Lights, mirrors, interior, doors | Probably missing or fake; **unverified**. A real car is needed to enter and drive (theft); that is why the steal code converts. |
| AI driving | Traffic code handles them (`trafficVehicle.lua:139`), so they can drive; **unverified** how well. |
| Police, chases, jobs, taxis | Must be real (taxi code says so explicitly). We never touch these. |
| BeamMP | Each spawn/replace is synced to everybody; a stand-in is a normal vehicle for BeamMP. |

## 3. How a car gets one model or the other
- Spawn time: `core_multiSpawn.createGroup(amount, params)` returns a list of `{model, config}` entries. Our `createGroup` wrapper (`rlsmp/trafficVariety.lua` `build`) can put any entries in the group, including `{model = "simple_traffic", config = "<real>_..."}`. For parked groups the game already returns stand-ins; with `simplified.parked` on we keep only stand-ins when the game offered enough of them (`lib/simplified.preferSimple`, log `simplified: parked group offered ...`). For traffic we do NOT put stand-ins into the group (they would appear near the player at spawn).
- After spawn: only replace/delete+spawn. In place works: the log of 0.4.36 shows `replaceVehicle` keeps the same id (`swap done (replaced in place, same id)`). That is how both halves convert.
- Stealability belongs to the SPOT, not the car: `rlsmp/theft.lua` `isStealable` hashes the 4 m cell of the car; RLS re-parks pool cars to other spots (`finishParkingPlacement`, `forceTeleport`). So the model cannot be chosen at group time; a car must be checked after it stands somewhere, and a car we upgraded can later be moved to a non-stealable spot.

## 4. What was built (`rlsmp/simplified.lua`, `lib/simplified.lua`; all OFF by default)
Server config `trafficVariety.simplified = {enabled=false, parked=true, traffic=false, nearRadius=250, perMinute=4, checkSeconds=2}` (travels in the existing `rlsmpTrafficVariety` event, sanitized again on the client: radius 120..1000 m, never below the view gate; STATIC rules in `trafficAdmin.lua`; checkboxes in the `[` menu "amount" page).

**Parked (feasible, built, untested):**
- A stand-in whose SPOT is stealable (the same `M.isStealable` pick as theft, so it needs `theft.enabled`) is replaced in place by the real model once a player is within `nearRadius`. Real model from the config name; real config: the config the name matches, else a random eligible config of that model from the premade pool. Paint and plate are passed in the replace options (**unverified** that `replaceVehicle` honours `paint`/`licenseText`).
- Afterwards `fixParked` makes it a parked car again for RLS: if the id changed it calls `parking.removeVehicle(old)` then `parking.insertVehicle(new)` (both exported by `parking.lua`; the cap check passes because the old car is removed first, `insertVehicle` sets `playerUsable=false`, `ignoreTraffic`, `isParked`, walk blacklist and the pool); in all cases it re-sets those fields and `electrics.setIgnitionLevel(0)`. Theft then finds it in `getParkedCarsList` as before, and at steal time `convertParked` still deletes + spawns it (unchanged), so stealing works the same with a stand-in or a real car.
- The reverse (back to a stand-in) only for cars WE upgraded, when the spot is no longer stealable and every player is farther than 1.5 x `nearRadius`.
- Not possible / limits: a stealable stand-in that is inside the view gate (within 120 m of any player or in front of the camera, 500 m cone) is NOT upgraded; it stays a stand-in and the old path (convert at steal time) handles it. Cars in `parking.isSpawnPending()` or not on a spot are skipped. Unverified: that replacing an inactive pool car works, that the pool (`vehPool`) accepts the new object, that spot ownership (`spot.vehicle`) is repaired by `insertVehicle`.

**Moving traffic (partly feasible, built, untested, default off):**
- The respawn re-roll is the main lever (a car is replaced anyway, so no extra hitch): `simplified.adapt` turns the pool pick into a stand-in of the same model when the car is farther than `nearRadius` from EVERY player (local player and remote players' positions from `bubble.otherPlayers`) and a traffic stand-in config of that model exists and passed RLS's filter. Otherwise a real car, as before.
- A stand-in that comes within `nearRadius` of a player is upgraded in place (through `trafficSwap.replace`: frame guard, BeamMP marker, position check, failure switch-off, `perMinute` budget shared by parked and traffic changes, one change per round).
- **What is NOT possible:** the view gate makes live radius conversion mostly impossible. A car that approaches from ahead stays inside the 500 m camera cone until it is within 120 m, and a car within 120 m is never touched. Such a car arrives as a stand-in. I did not break the owner's rule. A real car is never turned into a stand-in while it drives (each change is a ~1 s hitch synced to all players); only at respawn.
- The traffic of one game is spawned around THAT player, so cars far from every player are only those at the rim of the spawn radius or that wandered off. Expect a modest share of stand-ins. The `simplified: ... traffic simple=N full=M` census line shows the real share.
- Excluded through `personality.skipReason`: police, taxis, jobs, pursuit, crashed, locked/owned cars, held police, remote players' cars, the player's car.

## 5. Logs to send (tag RLSMP-P3, all start with `simplified:`)
- `simplified: stand-in configs N (parked P, traffic T that pass RLS's traffic filter, for M real models); config Types: ...; rejected by the filter: reason=count; first: ...` once. **If T is 0 the traffic half cannot work**; the reasons say why.
- `simplified: parked group offered N stand-ins of M entries (...)`.
- Every 30 s: `simplified: parked simple=A full=B (upgraded by us C) | traffic simple=D full=E | parked up=.. back=.., traffic up=.., respawn stand-in=.. real=.., not started=..`.
- Per change: `simplified: parked car ID -> REAL (...) (new id | replaced in place, same id); now car ID2`, `simplified: parked car ID toFull took N ms in the call`, `simplified: traffic stand-in ID -> REAL ...`, `simplified: respawn car at N m from every player: stand-in X for Y`, plus the usual `swap done`, `preload: build ... took N ms`, `swap failed`.
- Counters via `rlsmp_simplified.report()`: `simplified: skipped (near|nearOther|inView|camVisible|noGate|not parked on a spot)`, `not started`.

## 6. First things to check in a log
1. Does `stand-in configs` show traffic configs that pass the filter (T > 0)?
2. After a parked upgrade: is the new car still listed in RLS's parked cars (census `parked simple/full`), does theft's census still count it, did the car keep its place and plate?
3. `swap failed` / `simplified: ... not started` lines; the 3-failures switch-off stops all of it.
4. The `took N ms` figures and whether frames hitch at an upgrade.
5. Does a stand-in look wrong when seen up close in a view that the gate allows (>120 m, outside the cone)?
