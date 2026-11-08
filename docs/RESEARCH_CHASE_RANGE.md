# Research: cops in front of the player, and the traffic spawn range

Claude A. Sources: RLS source (read only) `overhaul/integration/ownedServices/trafficVehicle.lua`, `trafficPoliceRole.lua`, `services/police.lua`, `ownedServices.lua`, `career/police/playerDriving.lua`, and the owner's log (build 0.4.32, `RLSMP-P3` lines at 307 to 363 s). Vanilla BeamNG files are NOT available here, so everything about vanilla placement is a guess and marked so.

## 1. How RLS recycles and places traffic (verified in the RLS source)

- `ownedServices.lua` puts RLS's own methods (`tryRespawn`, `fade`, `onTrafficTick`, ...) on the traffic vehicle CLASS (metatable). So wrapping the class method (what `bubble.lua` does) works for every car.
- `C:updateActiveRadius`: `activeRadius = lerp(160, 80, min(1, spawnValue))`, plus `extraRadius = focus.speed + up to 80 when slow + up to 150 when you look straight at the car`. `finalRadius = activeRadius + extraRadius`. A car that is outside view for a while loses radius (down to 80 to 160 m).
- `C:tryRespawn`: when `finalRadius < focusDist` (the car is further than its radius from the focus, the local player) and no non-traffic car is very close, the car goes into state `fadeOut`. `fade()` runs at `dtSim * 4` (about 0.25 s), then the state is `queued`.
- A `queued` car is placed again by vanilla traffic code (NOT in the RLS repo) near the focus; `onRespawn` raises `respawnCount`, `onRefresh` resets the values. `respawn.spawnDirBias` ("-1 away from you ... 1 towards you") and `spawnRandomization` are per-car fields filled from the traffic vars in `resetValues`.
- Police: `pursuitStart` does `modifyRespawnValues(500)` once (radius +500 m). `onRefresh` (that is, after every re-placement) finds the player's pursuit as target and starts the chase again, and sets `respawn.spawnRandomization = 0.25`. So any cop that is recycled and re-placed during a chase simply joins the chase where vanilla put it. That is RLS's "reinforcement" path; there is no separate "spawn ahead" function in RLS.
- `setupRoadblock` (police.lua) puts cars via `findSpawnPointOnRoute(... spawnDist 120 ...)` AHEAD of the target. `gameplay_traffic.forceTeleport` is only used by RLS for an arrested AI suspect (`recycleArrestedAiSuspect`), not for police.
- `playerDriving.setTrafficVars` sets `spawnValue = clamp(6 / max(6, trafficAmount), 0.1, 1)`: with few traffic cars the value is 1 and the active radius is the minimum 80 m, so cars recycle quickly. This is RLS's own behaviour, we do not touch it.

## 2. The owner's log (verified)

```
307.897  Pursuit started ... Reason: speeding
307.8975 hook onPursuitModeUpdate mode=1 / pursuit START
307.8976 FROZE police id=95693 respawnCount=10 was enableRespawn=true
308.438  LEAK police id=95693 was re-placed (respawnCount 11)
```

Reading: the hook fires at the END of `setPursuitMode`, after `pursuitStart` already added 500 m to the radius, so RLS made no new recycle decision in those 0.54 s. The cop was most likely ALREADY in `fadeOut` or `queued` when the chase began (a cop that just saw you and was far enough to be recycled). Our hold only stops new `tryRespawn` calls; it cannot stop a fade that is running or a placement that is queued. So the "gap before the hook" was real but is not the whole story. (The state of the cop at that moment is not in the log: guessed. The FROZE line now prints `state=` and `alpha=` to prove it.)

## 3. What we changed for cops (all untested in game)

1. Hold early: police within 300 m of the player get the `rlsmpHold` flag all the time (also with no chase), released past 350 m. Units with role state `disabled` (wrecked, cooling down after a chase) are let go. Cost: a cop within 300 m is never recycled, which RLS rarely does anyway (its radius is 80 to 400 m).
2. Cancel a running fade: a held cop in `fadeOut` is set back to `fadeIn` every frame (the fade lasts only 0.25 s, the 0.5 s check would miss it). Guess: setting the state back is accepted by RLS's `onTrafficTick` (it only reads `state == 'fadeIn'` and `fade()`; looks safe in the source).
3. Direction: every police car gets `respawn.spawnDirBias = -1` each check (0.5 s; `resetValues` rewrites it after each respawn). GUESS: vanilla placement reads this per-car field. RLS copies the traffic var into the car in `resetValues`, which suggests it is read from there. If the log still shows `LEAK ... ahead=yes`, vanilla ignores it. Restored when the module stops.
4. Roadblocks (against the player or an unknown target) and `forceTeleport` on a police car are refused at any time, not only after we noticed the chase (RLS can call `setupRoadblock` in the first half second).
5. Better LEAK line (`dist=` and `ahead=`), `CANCELLED fade-out` line, counters.

NOT done: a cop that is `queued` (invisible) cannot be stopped from being placed; far cops (more than 350 m, or not named by RLS) are still recycled and re-placed (now biased to behind). Holding every cop at any distance would remove reinforcements. Next step if cops still land ahead: after a LEAK, move the cop ourselves to a point behind the player (needs `findSpawnPointOnRoute`, unverified).

## 4. Traffic range: what our code changed (verified from our source)

Only `bubble.lua` (the `tryRespawn` wrapper) changes where cars vanish. There is no wrapper on `updateActiveRadius`, no change to `spawnValue` or the radius. Other pieces:

- `bubble.lua` old rule ("protect"): a car outside the local radius is NOT recycled if another player is within 450 m, or has a clear line to it up to 1 km. On open ground a clear line over 1 km is normal, and two friends driving together are always inside 450 m of many cars, so almost nothing recycles, the pool goes stale and the cars you meet are far, old or in the same places. This is the likely cause of "repetitive, far, odd". Guess (not measured): no counter existed.
- `unjam.lua` (30 s still, then RLS fade out) and `traffic.lua` (the active-amount ceiling, raised back by us) change how many and which cars, not distances. The traffic ceiling lowers `activeAmount` (never during a chase).
- Other traffic modules (`trafficSwap`, `trafficVariety`) are another helper's, untouched; they call `bubble.stayFor`, which stays strict in every mode.

## 5. What changed for range (untested)

`police.bubbleMode` (server config, menu Police page, sent in `rlsmpPoliceConfig`):

- `original` (default): the wrapper only keeps a car when another player is closer than THAT CAR's own `finalRadius` (the radius RLS would use for you) AND has a clear line. Everything else goes to RLS unchanged, so respawn distances are RLS's. Car stays only if the other player is where RLS itself would consider it "near".
- `protect`: the old rule.
- `off`: no protection (only the police hold stays).

New census counters: `bubble: kept for another player`, `bubble: passed to RLS`, `bubble: police held` (`rlsmp_police.report()`). Compare them after a drive with a friend.

## 6. Verified vs guessed

Verified (source): class-level wrapping, the radius formulas, fade timing, the roadblock spawn, reinforcement through `onRefresh`, log timeline.
Guessed: that the cop was fading or queued at chase start; that vanilla placement uses `spawnDirBias`; that `fadeOut` to `fadeIn` is clean; that the old bubble caused the odd respawns.
Test next: drive a chase with the friend, search `RLSMP-P3` for `LEAK`, `CANCELLED`, `FROZE`, `bubble mode`.
