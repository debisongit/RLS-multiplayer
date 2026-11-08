# Research: traffic respawn range ("too short") and how to make it longer

Claude A. Sources: RLS source (read only) `ownedServices/trafficVehicle.lua`, `trafficPoliceRole.lua`, `services/police.lua`, `career/police/playerDriving.lua`; our client and server code. Vanilla `gameplay_traffic` (where a recycled car is PLACED, who calls `tryRespawn` and how often) is NOT available here.

## 1. What decides when a traffic car is recycled (verified in the RLS source)

All in `trafficVehicle.lua` (the class, patched on every traffic car):
- `resetValues` (`:196`): per car `respawn = {spawnValue = trafficVars.spawnValue, spawnDirBias = trafficVars.spawnDirBias, spawnRandomization = 1, activeRadius = distance to focus + 500, finalRadius = 1e6, innerRadius = 50, staticVisibility = 1}`. Runs after every (re)placement, so a fresh car starts with a huge radius.
- `updateActiveRadius` (`:472`, every traffic tick): `activeRadius` falls by `tick * spawnValue * (2 - staticVisibility) * 35` per second (35 to 70 m/s times spawnValue) but never below `lerp(160, 80, min(1, spawnValue))`. `finalRadius = activeRadius + focus.speed + max(0, (1 - speed/5) * 80) + up to 150 m straight ahead`. Returns early when `enableRespawn` is false, `spawnValue <= 0` or the car is inactive.
- `tryRespawn` (`:490`): when `finalRadius < focusDist` and no non-traffic car is within its `innerRadius` (50 m), state becomes `fadeOut`; `fade` runs at `dtSim * 4` (about 0.25 s), then `queued`; vanilla places it again and `onRespawn` raises `respawnCount`, state `reset`, then `fadeIn`.
- Other things that lengthen the stay: `modifyRespawnValues(add)` (+1000 m after a crash, +500 to +750 m in police chases), `spawnValue` is quartered at night (`onRefresh`).
- `spawnValue`: `playerDriving.setTrafficVars` = `clamp(6 / max(6, trafficAmount), 0.1, 1)`, set at traffic setup and `resetPlayerState`. 15 cars gives 0.4, so base radius 128 m; 6 cars or fewer gives 1 (80 m); many cars give 0.1 (152 m). Spawn value 0 turns respawning off for a car (never set by us).
- There is NO time-based respawn timer in RLS. The only "time" is the decay of `activeRadius` after a placement (a car placed at 200 m keeps a radius of 700 m and shrinks to about 130 m in 20 to 40 s) and the 0.25 s fade.
- The player's speed enters only through `extraRadius` (more speed = larger radius; a standing or walking player gets +80 m). `setActiveAmount` only sets how many cars are active; it does not change radii.

So by the formula the game's own radius is 80 to 160 m plus 0 to about 300 m, i.e. roughly 130 to 450 m. A car 2 km away is recycled by the game too. The owner's memory of "cars far away stayed, even stuck ones, all the way across the map" does NOT follow from this formula (guess: the old behaviour may have been `bubble` "protect"/other differences, or traffic simply stayed because the pool was small and the player slow; not verifiable).

## 2. What our code changes (verified from our source)

| Module | Effect on respawn distance/eagerness | Default now |
|---|---|---|
| `bubble.lua` `tryRespawn` wrapper | Only KEEPS cars (near another player). Never makes a respawn earlier. | mode `original` |
| `trafficReroll.lua` | After the GAME respawned a car (count went up), 3 s later replaces it in place with another model if far from every player and out of the camera cone. Does not force a respawn. Rate limit 3 per minute. | on |
| `trafficSwap.lua` live | Replaces ANY hidden car that fits the road badly. Not tied to a respawn, so cars that the game left alone (the ones from the start) were replaced. This is the likely cause of "the traffic from the beginning is gone". | NOW OFF (was on) |
| `unjam.lua` | Fade-out of stuck cars. Was: 30 s still, not in the camera cone, 120 m from players: so a stuck car 150 m away out of view was removed. | NOW 120 s and 400 m from EVERY player, one per 5 s, switchable |
| `parked.lua` | Raises the game setting `trafficParkingAmount` and calls `onSettingsChanged`, which calls `gameplay_traffic.setActiveAmount` with the same number as at career start. No radius changed. | unchanged |
| `traffic.lua` quota | `setActiveAmount` ceiling, only lowers when the server quota is below the player's own amount. | unchanged |

## 3. What we added (untested)

- `traffic.respawnRange` (0.5 to 3, default 1.0): `bubble.lua` wraps `updateActiveRadius` on the traffic class and multiplies the freshly computed `respawn.finalRadius` by the range. Police units and cars with `rlsmpHold` are skipped. A guard (`rlsmpScaled`) stops double scaling when the game returns early. Because `tryRespawn` reads `finalRadius`, the existing wrapper and RLS see the scaled value. Why not trafficVars: `spawnValue` can only move the base radius between 80 and 160 m (at most 2x), does not touch `extraRadius`, and RLS rewrites it at traffic setup.
- `traffic.respawnDelay` (0 to 600 s, default 0): the `tryRespawn` wrapper returns without calling RLS when the car was placed (its `respawnCount` last changed, seen in `bubble.onUpdate`) less than that many seconds ago. A car first seen at join counts as placed at that moment.
- `traffic.unjam {enabled, seconds, distance}`: see above; `bubble.minPlayerDistance` gives the distance to the nearest of all players (unknown counts as near).
- Server: all in `config.traffic`, edited in the `[` menu (Amount page), range-checked in `trafficAdmin.lua`, sent in `rlsmpPoliceConfig.range`. Every change logs `RLSMP-ADMIN ... changed` and `RLSMP-P3 range: traffic.respawnRange=2 (was 1)` on the server and `range: changed respawnRange 1 -> 2 (now ...)` on the client. Every 30 s a `range:` line shows range, delay, biggest `finalRadius` and how many recycles the delay held back (only while range or delay differ from the defaults).

## 4. Verified vs guessed

Verified (source): formulas and numbers in section 1; our wrappers only keep or delay; live swap is not tied to a respawn; unit tests for the scaling, the double-scale guard, the delay and the settings.
Guessed (never in game): that vanilla calls `updateActiveRadius` before `tryRespawn` each tick (the scaling relies on the radius being recomputed each tick; if not, the guard keeps the last scaled value, which is still right); that a larger radius really leaves far cars in place (vanilla may also recycle by other rules, e.g. `activeAmount` or road changes); that the old "stayed far away" behaviour is explained by the live swap or unjam; load cost of more active far cars.

## 5. Try next

Set `respawnRange` 2 (about 260 to 900 m) and `respawnDelay` 60 in the menu, drive away and back. Compare the `distance:` line (`radius=`, `nearestRespawn=`) and the `range:` line. If cars still vanish far out, the cause is vanilla placement, not the radius; the lever would then be the car count (`activeAmount`).
