# Research: cars popping in close to a walking player, and cars vanishing in front of them

Claude A. Sources: RLS source (read only) `ownedServices/trafficVehicle.lua`, `career/police/playerDriving.lua`; owner log build 0.4.36, walking (`4fbbd693-beamng.log`). Vanilla `gameplay_traffic` is NOT available here: where vanilla PLACES a respawned car is not verifiable.

## Verified from RLS source
- Radius: `activeRadius = lerp(160, 80, min(1, spawnValue))`; `extraRadius = focus.speed + max(0, (1 - speed/5) * 80) + up to 150 straight ahead`. A walker (speed about 0) gets the slow bonus of +80: finalRadius about 160 to 310 m. There is NO special on-foot radius logic in RLS. A car is recycled when `finalRadius < focusDist`.
- `spawnValue = clamp(6 / max(6, trafficAmount), 0.1, 1)` (`setTrafficVars`, only at traffic setup / `resetPlayerState`). Not touched by us.
- `respawnCount` goes up in `onRespawn`, state `reset`, then `fadeIn`.
- `onSettingsChanged` (which `parked.lua` calls) sets `gameplay_traffic.setActiveAmount(trafficActive)` = the same number as at career start, plus the parked amount. It does not touch `spawnValue` or any radius.

## Verified from the owner log
- Walking started 244 s. Quota arrived 244.6 s: `active=15 players=1`. No `TRAFFIC ceiling lowered` line: our quota never changed the amount.
- Bubble mode `original` and `players=1`: `playerPositions()` is empty, the bubble passes everything to RLS. It cannot cause this in a one-player test.
- Traffic group `want=4`: only about 3 normal cars + cop + taxi exist. With so few cars each one is recycled and re-placed often (17 re-rolls in 330 s from 3 ids). That is expected from a tiny pool, not proof of a short distance.
- Each re-roll was `replaced in place, same id`, started 4 s after the respawn count rose, i.e. while the car was in `reset`/`fadeIn` right after its placement.
- `parked: 4 -> 10` at 256.9 s worked.

## The log does NOT contain
Any distance. We cannot say from this log how far the cars were placed. Guess, not verified: vanilla placement distance on foot is short (the pop-ins around the corner), and the same in original RLS; what differs in our build is only what we do to the car AFTER it was placed.

## What in our code can act near the player (ranked)
1. `trafficReroll` (the only suspect that touches cars right after placement): its "hidden" test was `camVisible ~= true` = one ray from the car to the avatar. It knows nothing about the camera direction, the ray is short for a walker, and nothing checked distance. `replaceVehicle` in place reloads the object: the car shows at full alpha at once (guess: skips the 0.25 s fade), at the spot where it was just placed. This fits both reports: pop-in around the corner and a car changing or vanishing in front of the face.
2. `trafficSwap` (live swap, off by default) and `unjam` (30 s stuck, then fadeOut) used the same weak hidden test.
3. `bubble.tryRespawn` wrapper: no effect with one player (see above). With a friend, `original` mode only keeps cars near the friend, never changes distances.
4. `parked.lua`: only the parked amount and a repeat of the career's own active amount. Not a radius change (verified), small chance of a side effect inside vanilla `setActiveAmount` (not verifiable).
5. `traffic.lua` quota: inactive in this log (15 >= amount).

## What changed (untested)
- `lib/viewGate.lua` + `bubble.viewReason(car)`: a car is untouchable when it is closer than 120 m to the local player or any other player, or in a cone of about 80 degrees either side of the camera up to 500 m, or the player position is unknown. Used by re-roll, live swap and stuck recycling in addition to the old tests. Skips counted as `view gate: near|nearOther|inView|noFocus`; re-roll counts `reroll skipped (...)`.
- The re-roll log line now has `dist=` and `camVisible=`.
- `distance:` line every 30 s (while in a server): `walking`, biggest `finalRadius`, `activeAmount`, cars, `respawns/min`, `nearestRespawn` (metres from the player when the respawn count rose), `spawnValue`, bubble mode. Debug lines per respawn/fade-out with dist, camVisible, view, radius; `despawn near player` (warning) when RLS fades a car out within 120 m (that one is RLS's own, we only log it).
- Switch to restore pure original behaviour: server config `trafficVariety.respawn.enabled = false` (no re-roll at all). `police.bubbleMode` stays `original`.

## Next if it is still wrong
Send the log: compare `nearestRespawn` with `radius`. If respawns are near 100 m with re-roll off, it is vanilla/RLS (then the lever is `spawnValue`/`spawnDirBias`, not tried). If `despawn near player` appears, RLS itself fades cars near the walker (finalRadius smaller than distance cannot be near 120 m by formula; a bug would show there).
