# Research: hitch-free re-roll through the game's group spawn

Claude A. Problem (owner log, build 0.4.41, `preload:` lines): every re-roll was a synchronous `replaceVehicle`, "build took 527-2326 ms in the call" (median ~780 ms), 29 times in ~1000 s. The old reserve only picked cars, it loaded nothing. The owner confirmed that cars spawned by the game's own group queue ("Vehicle group spawning in progress (1 / 5)") do not drop fps.

Sources: RLS source (read only) and our code. The vanilla game files (`core/multiSpawn.lua`, `gameplay/traffic.lua`) are NOT available here, so what happens inside the queue is **unverified**. Nothing here was played.

## Verified (seen in the RLS source)
- `core_multiSpawn.spawnGroup(group, amount, params)` exists and RLS calls it: `parking.lua:1313` with `{name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms, randomPaints = true}`. `group` is a list of `{model, config}` (same shape as `police.lua` fallback `{model = 'fullsize', config = 'police'}`). `customTransforms` is a list of `{pos = vec3, rot = quat}`.
- Completion is announced by the extension hook `onVehicleGroupSpawned(vehList, groupId, groupName)`; `vehList` is a list of vehicle ids (`parking.lua:1340`, `activate(vehIds)` loops it with `ipairs`). The group `name` comes back as `groupName`, so our own name tells our spawn from RLS's.
- `core_multiSpawn.placeGroup(ids, {...})` has the comment "delays some frames to improve performance" (`police.lua:182`): placement is spread over frames by the game.
- `gameplay_traffic.insertTraffic(id, isPlayer, noPooling)` is how RLS gives a car to traffic (`police.lua:803,903`). Deleting a car with `obj:delete()` is how RLS removes parked cars (`parking.lua:1064`).
- RLS wraps only `core_multiSpawn.createGroup` (`trafficConfigFilter.lua`), not `spawnGroup`; a one-car group of ours is not touched by that filter.

## Guessed (not visible here)
- Why it is smooth: I believe the game builds one car per few frames from a queue ("spawning in progress (n / m)"), with a per-frame time budget, instead of one blocking call. The frame budget, paused physics and vehicle-thread details are **unknown**. The owner's observation is the only evidence.
- `mode = "roadBehind"` is ignored when `customTransforms` is given (RLS passes both). `gap` is probably unused for one car. No `instant` or `name` semantics beyond the name being returned in the hook.
- `gameplay_traffic.removeTraffic(id)` exists (called inside `pcall`; the car is also deleted, and the game removes destroyed cars from traffic itself, I expect).
- Whether the vehicle list arrives before or after the game's placement. We therefore check the new car's place once more 2 s later (moved back if more than 5 m off).
- BeamMP: the group-spawned car is a normal local spawn and is synced like any new car; the old one's delete is synced too. If the server's per-player car limit (MaxCars) is already reached, BeamMP may refuse the extra car for the moments both exist (then no car appears: timeout, counted as a failure).
- The old and the new car stand at the same spot for a short time. Both are out of sight, but if the old car is still active physics could push them apart. Not seen, not tested.

## What was built
`rlsmp/trafficSwap.lua`, `replace(id, entry, maxFailures, onDone, {mode, stillOk})`:
1. `async` (default): checks the usual guards (`canBuild`: frame guard, no chase), reads the old car's place, calls `spawnGroup({{model, config}}, 1, {name = "rlsmpReroll", customTransforms = {old place}})` and returns at once (the call itself is timed).
2. `onVehicleGroupSpawned(..., "rlsmpReroll")` -> `finishAsync`: asks `stillOk` again (the full view gate of the re-roll: not on the camera, not near or visible to another player, not police/jobs/chase/player car). If it fails, or the old car is gone, the NEW car is deleted (`async discarded`). Else `insertTraffic(new)`, `removeTraffic(old)`, `old:delete()`, then the repaint callback.
3. If the message never comes within 25 s the new car is looked for (new id, right model, not remote/player/garage); found = used, else a failure (shared `maxFailures` switch-off). An orphan car is therefore never left alone in the world.
4. Rate limit, one at a time, `perMinute` and the view gate are unchanged. BeamMP sync stays low: one spawn and one delete per re-roll, as before.
`trafficVariety.respawn.mode`: `async` | `inplace` (the old replaceVehicle, a freeze of 0.5 to 2 s) | `off`. If `core_multiSpawn.spawnGroup` or `vec3`/`quat` is missing in async mode nothing is re-rolled and a warning says so (we never fall back silently to the freeze).

The preload reserve was removed (`reserve`, `prepareSeconds`, `ageMax`, the queue and the prefetch): it picked 0.2 ms of work and loaded nothing. Kept: the frame guard and the loaded-model bias (`warmShare`).

## Measuring (read the owner's log)
- `build: <model>/<config> mode=async started, the call took N ms` (should be tiny), then `build: ... mode=async total S s (call N ms, worst frame meanwhile M ms); car A replaced by B; traffic: ...`. `M` is the longest real frame while the queue worked; compare with the old `took 780 ms` figure (`mode=inplace took N ms`).
- `async discarded` (seen meanwhile), `no group-spawned message, adopting ...` (the hook is not delivered to our extension: then the spawn works but we wait 25 s), `swap failed: async: ...`.
- If the freeze is still there with `mode=async`, the cost is not in the queue; set `mode` to `off` (or lower `perMinute`).
