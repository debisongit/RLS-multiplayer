# Research: where police and traffic cars appear (cops far away on another street, traffic in a 4 km ring)

Claude A. Sources: RLS source (read only) `ownedServices/trafficVehicle.lua`, `trafficPoliceRole.lua`, `services/police.lua`, `services/taxi/core.lua`, `services/parking.lua`, `jobs/beamEats.lua`; our client and server code. Vanilla `gameplay_traffic` (the code that places a recycled car) is NOT in the RLS source. Nothing here was played in the game.

Owner (plain): "I never asked for more cops, in real life you do not see that many police cars around you. Traffic should spawn and despawn in a 4 km radius. Cop cars that respawn must NOT spawn literally in front of or behind the player. Better: about a block away in a different street, or a street on the player's right side, at least about 1 km away."

## 1. What we found (verified in the RLS source)

- A traffic car has `respawn = {spawnValue, spawnDirBias, spawnRandomization, activeRadius, finalRadius, innerRadius, staticVisibility}` (`trafficVehicle.lua:196-215`, set in `resetValues`). **There is no spawn distance (min/max) field.** `spawnRandomization` is "branching and scattering" of the search, `spawnDirBias` is -1 (away) to 1 (towards). So "set the spawn radius fields like spawnDirBias" has nothing to set. RLS never says how far from the player a recycled car is placed: that is vanilla code.
- Recycle ("despawn") is decided by `finalRadius < focusDist` in `tryRespawn`; our `bubble.lua` already raises `finalRadius` to `traffic.respawnDistance` (4000 m) for normal traffic, so a traffic car is recycled only farther than 4 km from every player (audit: `lib/range.lua` `effective`, `bubble.lua` `installRadius`, tests `range_test`, `bubble_test`). Police get their own floor `police.copRespawnDistance` (450 m).
- Where the game puts a recycled car was seen only in the owner's logs: 100 to 140 m from the player (`docs/RESEARCH_RESPAWN_RANGE.md` 4b). So the despawn radius was 4 km but a respawn came back close. That is what this change fixes.
- Police placement in RLS: roadblocks use `gameplay_traffic_trafficUtils.findSpawnPointOnRoute(origin, dir, spawnDist, ...)` (ahead of the target, `police.lua:221`), `pursuitStart` adds 500 m of radius, `onRefresh` re-targets the pursuit. `gameplay_traffic.forceTeleport(id)` takes only an id (vanilla chooses the place), so it cannot be used to place a car where we want; it is also refused for police by `police.lua` (ours).
- Tools RLS itself uses for a road spot: `gameplay_traffic_trafficUtils.findSafeSpawnPoint(pos, dir, min, max, target, {minDrivability})` + `finalizeSpawnPoint(pos, dir, n1, n2, {legalDirection})` (`taxi/core.lua:854-869`), `map.getMap().nodes[...]` with `.pos` and `.radius` (`police.lua:226`), `map.findClosestRoad(pos)` whose first result is a road name (`beamEats.lua:469`), `core_multiSpawn.spawnGroup(group, n, {name, mode = "roadBehind", gap, customTransforms})` (`parking.lua:1313`).

## 2. What we built (untested)

Rules (pure, `lib/spawnSpot.lua`, tests `spawn_spot_lib_test`): a spot is allowed when it is
1. at least `minDist` from EVERY player. This is the **straight-line (horizontal) distance, not the path length**: a path search for every candidate is too slow, and a path is never shorter than the straight line, so the real driving distance is at least this;
2. not within 120 m of a player and not in the local camera cone (`lib/viewGate.lua`; other players' cameras are unknown, they are covered by the distance rule);
3. police only: not on the player's own road (`map.findClosestRoad` name differs), and not straight ahead of or behind the player (more than 40 m sideways from the line of the player's heading).
Preference: a spot on the player's right-hand side (cross product of the heading and the offset: with heading +y, +x is the right), then the nearest.

Finder (`rlsmp/spawnSpot.lua`): it samples 160 random drivable nodes of `map.getMap().nodes`, keeps those in the distance ring, applies the cheap rules, asks the road name for at most 8 survivors, picks the best and lays it into its lane with `finalizeSpawnPoint`. It does not use `findSafeSpawnPoint` because that searches in one direction from a point and its reach is unknown; the node table reaches the whole map (4 km needs that). Anything missing gives nil and the car stays as the game placed it. Every attempt writes a `spawn:` log line (distance, side, road, ring, or the reasons for a refusal).

Police (`rlsmp/policeRespawn.lua`): when a police unit's `respawnCount` rises we judge where the game put it. Fine = left alone (log "fine, left alone"). Not allowed = find a spot in the ring [min, 2.5 x min]; then either build a new cop of ANOTHER model there (at most once per `respawnRebuildSeconds`, `spawnGroup` with `customTransforms`, then `insertTraffic` + `setRole('police')` like RLS) or, between builds, move the same car with `spawn.safeTeleport`. A cop inside 300 m is removed at once (an unseen car so close makes the player's car brake). The new car is judged again; too near = deleted and counted as a failure (3 failures switch it off). The old "150 m behind on the player's trail" and "roadBehind gap 150" behaviour is removed.
- `police.spawnMinDistance` 1000 m (300 to 3000), `police.chaseSpawnMinDistance` 600 m (200 to 3000, used while `rlsmp_police.isPursuit()`: reinforcements may come from nearer along the roads and arrive, never into view and never straight in front or behind), `police.spawnPreferRight` true.
- **`police.copCount` default is now 0** (leave the game's number). The top-up code stays as an option; with `copCount` above 0 a top-up cop is built at such a spot. An existing `config.json` that still holds the old default 3 and has none of the new keys is reset to 0 once at server start (log line `RLSMP-P3 police.copCount was the old default 3`).

Traffic (`rlsmp/trafficPlace.lua`, `rlsmp/trafficFill.lua`): when a normal traffic car's `respawnCount` rises (the game just re-placed it), it is moved to a road spot between `traffic.spawnMinDistance` (250) and `traffic.spawnMaxDistance` (4000) from the player, spread evenly over the distance (not over the area), with `spawn.safeTeleport(..., resetVehicle=false)` and then `veh:onRefresh()`. A car the game already placed inside the ring and out of view is left alone. The fill (`traffic.minAmount`) builds its missing cars in the same ring instead of 150 to 400 m behind the camera (the old place is the fallback). One car per second, never in a chase, never police, our fill cars, held cars or other players' cars. `spawnMaxDistance` 0 = the game's own placement.
- Cost: pooling/freezing far cars is the game's job (RLS's `updateActiveRadius` and `tryRespawn` return early for inactive cars, `trafficVehicle.lua:473,494`); we add no per-frame work except a 0.25 s counter check; one node sample (160 table reads) per moved car.
- Warning for the owner: 10 cars spread over a 4 km disc is about one car per 5 square kilometres. Near the player it will feel emptier. The distribution is even over distance to soften that; raise `traffic.minAmount` or lower `spawnMaxDistance` (menu, Amount page) if it is too empty.

Settings (menu `[`): Amount page (new traffic at least / at most), Police page (distances, right side). Rules in `trafficAdmin.lua` STATIC. `respawnGap` is gone.

## 3. Verified vs guessed

Verified (source / unit tests): no spawn distance fields in RLS; the 4 km recycle path; the helper calls and their use in RLS; the rules (side, corridor, view, distance) and all branches of the police and traffic code with stubs; config defaults, migration, admin ranges, payloads.

Guessed (never in game):
- `node.links` is a table keyed by neighbour node id and `node.drivability` exists (vanilla map graph; used only inside pcall/nil checks). If wrong the finder returns nil and nothing is moved (log: `spawn: ...: no spot (0 nodes in the ring ...)`).
- `map.findClosestRoad` returns the road name first (as RLS uses it); a road name is a whole named road, so "same road" is coarse.
- `core_multiSpawn.spawnGroup` obeys `customTransforms` together with `mode = "roadBehind"` (copied from RLS parking and from `trafficSwap.spawnNew`, which is the same call and was played for the fill).
- That a traffic car or cop moved with `safeTeleport` keeps driving/chasing. For traffic we call RLS's `onRefresh` (resets AI and respawn radius; the source shows `self._teleport = nil` there). A moved cop keeps its role and state without a refresh. If cars stand still after a move, look for `spawn: traffic car ... moved` lines and set `traffic.spawnMaxDistance` to 0.
- That the vanilla placement really puts cars at 100 to 300 m in the owner's current build (seen in 0.4.4x logs), and that nothing else (BeamMP, the game) recycles a far car earlier.
- That another player sees the teleported traffic car correctly (BeamMP sends position updates of local cars).
- Chase behaviour of cops placed 600 to 1500 m away: they have to drive to you; RLS's own reinforcement logic is unchanged.

## 4. What to read in the next log
`spawn:` lines (spot distance, side, `RIGHT`/`left`, road, reasons for refusals), `police respawn:` (re-placed N m: not allowed (reason) / fine), `police respawn: cop X moved to a spot`, `police respawn: new cop came out N m`, `spawn: traffic car X re-placed by the game N m from you, moved to M m (ring ...)`, `fill:` lines, and `range: ... spawn=250..4000m`.
