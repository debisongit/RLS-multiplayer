# Field test: Phase 3 (traffic budget + police anti-teleport)

Nothing in Phase 3 has run in the real game yet. The unit tests use fake game objects, so this run
answers whether the real BeamNG / RLS / BeamMP objects behave the way the code assumes.
Plan for about 30 minutes, one player (a second player is optional, see the end).

## Versions this was built against

| Component | Version |
|---|---|
| RLS-Career-MP (this repo) | default branch `claude/amazing-sagan-kh6ecn`, code commit `5cc551f`, build `0.4.21` (everything on the default branch; later commits only change documents) |
| RLS Career Overhaul source read | v2.8.0, commit `e701d9e2218ca12ff70ba4a09c0c91514e96e380` (29 Oct 2026) |
| BeamNG.drive | **not pinned, write yours down** (docs target 0.38 / 0.39) |
| BeamMP (server and client) | **not pinned, write yours down** |
| Operating system | Windows assumed in the commands below |

Please put your own BeamNG, BeamMP and RLS versions at the top of what you send back.
Vanilla BeamNG's traffic code was never read; only RLS's code was.

## Install

1. From the repo root, install (or update) the mod into your BeamMP server folder in one command. It copies the
   server plugin, builds the client zip and puts it into the server's `Resources/Client/`, and keeps your `config/`,
   `profiles/` and `businesses/` folders. Do not unzip the client zip.
   ```bash
   tools/install_to_server.sh /path/to/BeamMP-Server
   ```
   It prints `Installed RLS-Career-MP build 0.4.21`. It is a bash script: on Windows run it from Git Bash or WSL.
2. Put the RLS Career Overhaul zip in the server's `Resources/Client/` as well.
3. On your own PC, delete any local `rls_career_overhaul_v2.8.0_hotfix.zip` (or any other copy of RLS) from your BeamNG
   mods folder, so RLS is not unloaded and rebuilt on every join.
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` and `MaxCars = 100` or more. The server warns, and
   tells joining players, if the map is wrong.
5. Start the server once, then stop it. This writes
   `Resources/Server/RLS-Career-MP/config/config.json`.
6. Edit that file. Under `"traffic"` set `"totalBudget": 6` and `"minPerPlayer": 2`; leave
   `"maxPerPlayer"` at 18. This is deliberate. The default (`totalBudget` 0) means automatic: 30 cars plus 10 per player,
   at most 18 per player, so a single player would get 18 cars, which is above what you will normally have, and the limit
   would never visibly act. Any `totalBudget` above 0 fixes the budget instead. Under `"police"`,
   leave `"antiTeleport": true` and `"blockRoadblocks": true`. Start the server again.
7. Join with BeamNG. In BeamNG's own settings, set the **traffic amount to 15 or more** (the max is fine).
8. **Check the build.** The server log must say `joined with client build 0.4.21 (server build 0.4.21)` and the game log must
   say `client loaded, build 0.4.21`. If the two builds differ, you are running an old client zip (this has already wasted a test round): re-run the install
   command, restart the server and rejoin.

Client-side settings are not stored in the server file, so nothing else needs changing. Do not rename the zip.

## What to capture

Close nothing yet. The game log is overwritten the next time the game starts, so extract it **before**
you relaunch the game.

1. Find the newest `beamng.log` (PowerShell):
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\BeamNG*" -Recurse -Filter beamng.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
   ```
2. Pull out only our lines (replace the path with the one printed above):
   ```powershell
   Select-String -Path "C:\path\printed\above\beamng.log" -SimpleMatch "RLSMP-P3","RLSMP-GUARD","RLSMP-REPLACE" | ForEach-Object { $_.Line } | Set-Content p3-client.txt
   ```
3. Same for the server. Run this in the BeamMP server folder:
   ```powershell
   Select-String -Path "Server.log" -SimpleMatch "RLSMP-P3","RLSMP-GUARD","RLSMP-REPLACE" | ForEach-Object { $_.Line } | Set-Content p3-server.txt
   ```
4. Send back `p3-client.txt` and `p3-server.txt`, plus the answers to the "What you saw" list at the bottom.

If you are on Linux or the search finds nothing, send the whole `beamng.log` and tell me its path.

## The questions this run answers

### 1. Does the code see your pursuit at all?

This is the most important one. The anti-teleport only works if the player's own car is in RLS's traffic data.
```
RLSMP-P3 ... probe: player vehicle in traffic data = true
```
`= true` → good, pursuits are read directly from the game. This is the expected result: RLS inserts the player's car into the
traffic data (`gameplay_traffic.insertTraffic(id, true)`).
`= false` → the code falls back to the RLS hook (`hook onPursuitModeUpdate mode=N` lines). That path works in
unit tests but has never run in the game, so tell me if you see it.
If you are chased and there is **no** `pursuit START` line at all, the feature is inert. Send the log.

### 2. Do police cars stop respawning during a chase, and does anything still pop in?
```
pursuit START mode=2 antiTeleport=true blockRoadblocks=true
FROZE police id=123 respawnCount=0 was enableRespawn=true
pursuit END after 95s, units frozen at end=3, leaks so far=0
RELEASED police id=123 enableRespawn back to true
```
`LEAK police id=123 was re-placed during the pursuit` → a police car was put somewhere new even though we
switched respawn off. That is a path I do not block and cannot see (it lives in vanilla BeamNG). **This is the
line I most want to see if it appears.** Note roughly what you were doing at that moment.
The freeze relies on RLS's own `tryRespawn` (in `trafficVehicle.lua`), which returns early when a unit's `enableRespawn` is off.
So with the freeze on, a police car that is out of sight should simply stay where it is, not reappear ahead of you.
If a cop visibly pops in ahead of you and there is **no** `LEAK` line, tell me when it happened. That means the
car was spawned new (not respawned), which this build does not watch for.

### 3. Are roadblocks and teleports refused, and who asks for them?
```
patched setupRoadblock = true
patched forceTeleport = true
BLOCKED setupRoadblock from .../trafficVehicle.lua:898
BLOCKED forceTeleport(police) from <some file>:<line>
```
`patched ... = false (not available yet, will retry)` is normal at first. It should turn into `= true` within a
second of the pursuit starting. If it never does, that wrapper is not working; send the log.
Roadblocks only appear in a high pursuit (mode 3). If you never reach it, there will be no `BLOCKED setupRoadblock`
line and that part stays untested.

### 4. Does the traffic ceiling work?
Server (`p3-server.txt`):
```
RLSMP-P3 traffic quota sent to pid=0 active=6 players=1 rev=1
RLSMP-P3 police config sent to pid=0 antiTeleport=true blockRoadblocks=true
```
Client:
```
quota received active=6 players=1 rev=1
TRAFFIC ceiling lowered 15 -> 6
```
`quota received` but never `TRAFFIC ceiling lowered` → traffic was already at or below 6 when checked. Raise the
traffic amount in settings and wait 5 seconds.

## The exercise

Join, wait until your RLS career is loaded and you can drive. Then:

1. **Drive normally for 3 minutes.** Traffic should be thin (about 6 cars). Check the log for answer 4 now.
2. **Start a police chase** the usual RLS way, for example speeding past a police car. Keep it going for at
   least 2 minutes. Pay attention to the road **ahead** of you: does a police car ever appear out of nowhere in
   front of you?
3. **Keep the chase going** (crash, speed, run red lights) to try to reach the highest level. Roadblocks only
   happen at the top level.
4. **Lose them once** (evade) and **get arrested once**. Both should end the pursuit; look for `pursuit END`.
5. **Walk (do not drive)** to a garage computer or use the big map to teleport while no chase is running,
   then start another chase. The code path for teleporting differs from driving.
6. When done, open the in-game console (the `~` key) and type:
   ```
   rlsmp_police.report()
   ```
   If you get an error saying `rlsmp_police` is nil, type `extensions.rlsmp_police.report()` instead.
   Then run the extraction commands above.

The census at the end looks like this (numbers are examples):
```
census begin
  units frozen                      : 9
  units released                    : 9
  setupRoadblock BLOCKED            : 2
  forceTeleport(police) BLOCKED     : 14
  LEAKS (re-placed while frozen)    : 0
  setupRoadblock BLOCKED callers (top 15):
       2  .../trafficVehicle.lua:898
census end
```
The callers list is what I will use to decide what to hook next.

## Named failure modes

| What you see | What it means | Fix |
|---|---|---|
| No `RLSMP-P3` lines in the client log at all | Client mod not loaded, or you searched an old log | Check the zip is in `Resources/Client/`, rejoin, extract again. Send the log. |
| `rlsmp_police loaded` appears but no `probe:` lines follow | Unexpected, the probes print at the same time | Send the log |
| Client log has `rlsmp_police loaded` and the server log has no `police config sent` line | Your career never reached the loaded stage on the server | Look for an `rlsmpLoaded` problem or the Phase 1 load; send both logs |
| `probe: player vehicle in traffic data = false` | See question 1 | Send the log |
| Chase happens but no `pursuit START` | Pursuit not detected, feature inert | Send the log and say when the chase began |
| Police cars stay frozen or never leave after the chase | `pursuit END` or `RELEASED` missing | Type `rlsmp_police.report()`, send everything. A restart of the game clears it. |
| Cop pops in ahead, with a `LEAK` line | A respawn path we did not block | Send the log (this is the data I need) |
| Cop pops in ahead, with **no** `LEAK` line | A new car was spawned (not respawned) | Send the log and the time it happened |
| You never see a roadblock | Normal below pursuit level 3 | Nothing, just say you did not reach it |
| Roadblock appears while chased, and no `BLOCKED setupRoadblock` line | Roadblock built through a path that skips the wrapper | Send the log |
| A game error line mentioning `rlsmp` or `p3` | A bug in this build | Send the log |
| RLS police feel broken **outside** a chase | The wrappers should pass through when not chased | Send the log. Turn the feature off by setting `"antiTeleport": false` in the server config and restarting. |

## Known gaps

- **New spawns are not watched.** This build stops existing police cars from being re-placed. If RLS or vanilla
  creates a brand-new police car in front of you, that is not caught. It would show as a pop-in with no `LEAK` line.
- **Vanilla traffic code is unread.** The respawn logic and `forceTeleport` argument order come from how RLS calls
  them, not from the vanilla source. If `BLOCKED forceTeleport(police)` never appears, that is not necessarily a
  problem.
- **Frozen police never despawn during a chase,** however far behind they fall. The cost is that a long chase can
  leave several parked police cars; RLS's own evade ends the chase, then they are released.
- **Traffic quota is a count only.** It does not look at where players are, so two players in the same spot still
  each get their own cars.
- **The server does not see pursuits.** Another player does not see your police chase from the server's point of view.
- **Not tested with more than one player,** and not with three or more.

## Optional: a second player (10 extra minutes)

Have a second player join the same server. With `totalBudget` 6 and `minPerPlayer` 2, each of you should get 3.
Expect on the server `traffic quota sent ... active=3 players=2`, and on both clients `TRAFFIC ceiling lowered`.
When the second player leaves, the first should get `active=6` again. Send both clients' logs if you can.

## What you saw (send these with the logs)

1. Your BeamNG, BeamMP and RLS versions.
2. Did a police car ever appear out of nowhere in front of you during a chase? Roughly when?
3. Did the chase end properly when you evaded and when you were arrested?
4. Did traffic look thinner than usual with the settings above?
5. Anything that looked broken outside a chase (police, traffic, money, saving)?

## Taxis and riding along (build 0.4.21)

Two things changed in the vehicle guard (it used to refuse every AI car and every other player's car):

1. **Taxis.** The taxi RLS hailed for you can be entered again. RLS's own taxi state decides (`waitingForPickup`,
   `pullingOverForPickup`, `occupied`, ...). Every other AI taxi is still refused.
2. **Riding along in a friend's car.** Off by default. To try it, in the server's `config.json` set
   `"vehicles": {"enabled": true, "allowPassengers": true}` and restart. A player **on foot** can then get into another
   player's car as a passenger (BeamMP gives the passenger camera). You cannot drive it.

Log tag for both is `RLSMP-GUARD` (already included in the capture commands above).

### Test steps
1. **Taxi.** On foot, hail a taxi the normal RLS way (phone or waving). Walk to it and get in. Ride a short way, then get out.
   Expected log lines:
   ```
   RLSMP-GUARD|ALLOWED id=123 jbeam=... beammp=own: taxi hailed for you (waitingForPickup)
   RLSMP-GUARD|switch 45(unicycle) -> 123(...): ok (hired cab), own walkers now: 0
   ```
   `beammp=` may say `own` or `unregistered`, depending on whether BeamMP has registered the cab yet. Either is fine.
   After getting out you should be on foot next to the taxi.
2. **Another taxi.** Try to get into a taxi you did not hail. You should get "You can't drive that vehicle" and a line
   `BLOCKED ... AI traffic (taxi state: ...)`.
3. **Riding along (two players, passengers on).** Player A drives. Player B walks up on foot and gets into A's car.
   Expected on B: `ALLOWED ... passenger seat in another player's car`, then a passenger camera, and B cannot steer.
   Then B presses F (get out). B should stand beside the car.
4. **Another player's taxi or parked car (passengers on).** B tries to get into one of A's AI cars, for example a taxi
   driving past A. It must be refused: `BLOCKED ... another player's traffic or parked car`.
5. **Passengers off (default).** B tries to get into A's car: refused with `BLOCKED ... (passengers off)`.

### Named failure modes
| What you see | What it means |
|---|---|
| Hailed taxi still refused: `BLOCKED ... AI traffic (taxi state: X)` while the cab waits for you | The taxi state name `X` is not in my list. Send the log line. |
| After entering a taxi or a friend's car you are teleported to some other car or stuck | BeamMP or RLS moved you. Send the lines `switch ...` and any `Found suitable vehicle` line from the game log. `own walkers now: 0` right after a switch is normal while inside a car. |
| After getting out you stand at the default spawn or cannot get out | The walking character was not recreated. Send the log. Turn `allowPassengers` back off. |
| Passenger sees the road but the car "teleports" or lags | Normal: you are not really in the car, you see what BeamMP shows. Tell me how bad it is. |
| RLS screens (fuel, damage, phone) misbehave while riding | RLS treats the car you sit in as your car. Tell me which screen. |

### Known gaps
- Other players probably will not see the passenger sitting in the car.
- While you ride, RLS thinks the friend's car is your car: police pursuits, traffic around you and fuel or damage screens
  may act oddly. The server's claims ignore passenger reports, so crashes are still judged by the drivers.
- A walking player is never allowed into another player's walking character, and nobody can drive someone else's car.
- Another player's AI traffic is recognised by the name-tag flag that `trafficLabels` sets, which can take 2 to 4 seconds for a car
  that has only just appeared. In that short window a new traffic car of A's could be entered by B by mistake. Tell me if it happens.

## Garage part shop (build 0.4.21)

**The bug:** at the garage computer you shop for parts while standing on foot. RLS rebuilds the car with `replaceVehicle(model, options, theCar)`.
BeamMP ignores `theCar` and replaces the car the PLAYER is in, which is the walking character. A new car appeared and took over,
and the shopped car stayed behind, still frozen by the shop. **The fix:** when RLS names a specific car, that car is replaced in place.
Log tag `RLSMP-REPLACE` (already in the capture commands above).

### Test steps
1. Join, load your career, walk to your own garage computer and open the part shop for one of your cars.
2. Add a part to the cart (for example power steering) and watch the car. It must change **in place**: no second car, you stay on foot.
3. Buy it and leave the shop. Walk to the car, get in and drive. It must drive normally and have the part.
4. Do it a second time with another part, and once with removing a part.
5. If an old "fake car" is still around from before the fix, leave the server and rejoin. I have not confirmed that clears it.

Expected log lines:
```
RLSMP-REPLACE|captured the game's own replaceVehicle                      (once, when the game starts)
RLSMP-REPLACE|wrapped core_vehicles.replaceVehicle (beammp's version: true, game's own known: true)
RLSMP-REPLACE|replace etk800 target=123(etk800) but player is in 45(unicycle) (beammp knows target: true): replacing the target itself
```
(The last line appears each time the cart changes.)

### Named failure modes
| What you see | What it means |
|---|---|
| `W RLSMP-REPLACE|the game's own replaceVehicle was not captured before BeamMP swapped it` | The fix is inactive: our mod loaded too late. Send the log. |
| A second car still appears and there is no `replacing the target itself` line | RLS used a different path than I found. Send the whole log from the shop session. |
| `... is the player's own car (passthrough)` and the bug still happens | The player was in the car, so another cause. Send the log. |
| The car changes in place but is still frozen after you leave the shop | RLS's own unfreeze did not run. Send the log. |
| The car changes in place but the part is missing | A separate problem from the replace. Send the log and the name of the part. |
| Other players see the old version of your car | The change was not synced to them. Tell me. |
| `W RLS-Career-MP|dedupe: deleting stale copy ...` after a purchase | Build 0.4.17's cleanup found a leftover copy, so the replace still left a car behind. Send the log: the fix did not cover your case. |

### Known gaps
- Not played in the game. The missing power steering could be a separate problem; this build only fixes which car is replaced.
- Fixing it relies on the game's own `replaceVehicle` being captured before BeamMP swaps it (the warning line above says if it was not).

## Traffic variety, step 1 (build 0.4.21)

More varied traffic and parked cars (see `docs/DESIGN_TRAFFIC_VARIETY.md`). **Live swapping while you drive is not in this build**:
a car keeps its model once it exists, so road class and day or night only change cars built later (traffic start, refills, parked cars).

### Test steps
1. Install `0.4.21` (check both logs say `0.4.21`), join, start your career and drive for a few minutes. Does the traffic look more varied (more different models,
   no model repeated many times in a row)? Do the same on a second join.
2. Look for these lines in the game log (tag `RLSMP-P3`):
   ```
   RLSMP-P3|wrapped core_multiSpawn.createGroup (variety)
   RLSMP-P3|traffic variety settings received: enabled=true mods=0 maxShare=0.25 oversample=2.0 traffic=true parked=true
   RLSMP-P3|probe: group filters = Config Type,Type; first entry fields = config,model...; model Types in the pool = Car=..,Truck=..
   RLSMP-P3|probe: road class source = speedLimit
   RLSMP-P3|variety traffic group: want=12 pool=24 mods=0 picked=12 distinct models=8 relaxed=0 zone=city night=false
   ```
   and on the server `RLSMP-P3 traffic variety sent to pid=...`. **Send me the `probe:` lines**: they tell me the real `Type` names and whether the game knows road speed limits.
3. Try a weight: in the server `config.json` set `"trafficVariety": {"typeWeights": {"Truck": 0}}` (use a Type name from the probe line) and restart.
   No cars of that Type should appear in newly built groups.
4. Optional, with a car mod: put its zip in the server's `Resources/Client` folder, list the model name under `"mods": {"modname": 3}`, restart. Every player downloads the zip when joining.

### Named failure modes
| What you see | What it means |
|---|---|
| No `wrapped core_multiSpawn.createGroup (variety)` line | The wrapper was not installed (the game's spawner was not ready). Send the log. |
| `W RLSMP-P3|RLS's wrapperLifetime is not available` | RLS is missing or changed; variety stays off. Send the log. |
| `probe: road class source = none` | The game gave no speed limit for the road: road class multipliers do nothing. Day and night still work. |
| `variety failed, the game's own group is used` | An error inside our code; the game was not affected. Send the log line. |
| `W RLSMP-P3|rewrapped createGroup ...` | Normal a few times: RLS wrapped over ours (for example when the career starts) and we put one layer on top; the older layer is switched off. If it repeats every few seconds, send the log. |
| Taxis disappear or cannot be hailed | Taxis should not pass through this code, but I could not verify that in the game. Set `"trafficVariety": {"applyToTraffic": false}` and restart; send me the log. |
| `relaxed=` above 0 in the group line | The pool was too small for the 25% rule. Not a problem by itself. |
| `mod model X is not installed here` | That game does not have the mod. It skips it. Other players with the mod may see black blobs if they do not. |
| Black blobs and a pop-up for every car on another player's screen | They are missing a mod model that someone's traffic uses. Remove the mod or make sure the zip is in `Resources/Client`. |
| Traffic or police behave oddly after this build | Set `"trafficVariety": {"enabled": false}` and restart the server; send me the log. |

### Known gaps
- Not played. Everything about the car lists comes from reading RLS's code; the game's own spawner code is not visible to me.
- Joins have stalled before during the save download; a big car mod makes joins heavier for everybody.

## Live swapping (build 0.4.21)

Traffic cars that nobody can see are swapped for a model that suits the road class and the time of day (see `docs/DESIGN_TRAFFIC_VARIETY.md`, step 2).
Both switches are **off by default** and nothing is swapped with default weights, so first set some weights (see the traffic variety section).

### Test steps
1. Watch only first. In the server `config.json` set (use a Type name from the `probe:` line of the traffic variety test):
   ```
   "trafficVariety": {"night": {"Truck": 0}, "swap": {"enabled": true}}
   ```
   Restart and join **by day**, drive around, then wait for night (or change the time). Cars built during the day were allowed to be trucks; when night falls, a hidden
   truck now weighs 0 and may be swapped. (Cars built from now on already follow the weights, so a swap only shows when the situation changes after a car was built.
   Another way, if the traffic variety `probe:` said `road class source = speedLimit`: set `"zones": {"highway": {"Car": 0}}` and drive from a city road onto a highway.)
   In the game log look for lines like:
   ```
   RLSMP-P3|swap would happen (watch only): car 123 pickup (Truck, weight 0.00) -> sunburst/c1 (Car, weight 1.00) zone=city night=true
   ```
   Send me the log. No car must change; if one does, tell me.
2. Only after step 1 looks sensible: also set `"live": true`. Expected lines:
   ```
   RLSMP-P3|swap LIVE: car 123 pickup (...) -> sunburst/c1 (...)
   RLSMP-P3|swap done (new id): car 123 is now car 456 (sunburst/c1); traffic: inserted into traffic
   or
   RLSMP-P3|swap done (replaced in place, same id): car 123 is now car 123 (sunburst/c1); traffic: already in traffic
   ```
   **Send me which of the two `swap done` lines you get.** It tells me how the game's replace really works.
   Drive for 10 minutes. Does a car ever vanish or appear in front of you? Do swapped cars drive normally? Do other players see odd cars, black blobs, or lag spikes?
3. If something looks wrong, set `"live": false` and restart the server. Live switches itself off after 3 failures.

### Named failure modes
| What you see | What it means |
|---|---|
| No `swap would happen` lines at night | Every car weighs the same, or no car has been hidden for 5 s, or the weights you set do not match the `Type` names. Send the log. |
| `swap failed: the game's own replaceVehicle or the car is not available` | The fix for replacing a specific car is not active. Send the log. |
| `swap failed: no new car appeared after the replace` | Neither a new car nor a changed model was found within 3 s. Send the log. |
| The same car appears again and again in the watch-only lines | It should not: a car is looked at once per 10 minutes. Send the log. |
| `live swapping switched itself off after too many failures` | Expected safety net. Send the `swap failed` lines. |
| A swapped car stands still, has no driver, or never moves | It was not put back into traffic properly. Send the `swap done` line and the car id. |
| A car vanishes or appears in view | It should never happen (only invisible cars). Send the time and the log. |
| Spawn hitches for other players, black blobs | The swap rate is too high for BeamMP. Lower `perMinute`, or turn `live` off. |

### Known gaps
- Never run in the game. Live swapping is the riskiest part of the traffic variety feature; keep it to a test session first.
- The new car is created at the old car's place by the game's own replace; whether RLS keeps its traffic role, pooling and saved state for it is unverified.

## Shared weather (build 0.4.21)

Before, every game ran its own RLS weather, so players saw different weather. Now the server picks one of RLS's six conditions (clear, partlyCloudy, overcast, drizzle, rain, storm) from its clock and every game
shows it through RLS's own weather system, so rain, wet roads and tire grip match what you see. Time of day was already shared.

### Test steps (two players)
1. Install `0.4.21` (both logs say `0.4.21`). For a first quick test pin the weather: in the server `config.json` set `"weather": {"force": "rain"}` and restart. Both players join and load their career.
   Both should see rain within about 10 seconds. Then set `"force": "clear"`, restart: both see clear sky and the **time of day is unchanged** (RLS's own "clear" jumps its clock to noon; we put it back).
2. Remove `force` (set it to `""`) and play 30 minutes together. Look out the window at the same moment: same clouds, same rain? Try each condition if the server cycles through them
   (`"periodMinutes": 2` makes it change fast; the server log has `RLSMP-P3 weather period N: <condition>` on every change).
3. In the game log (tag `RLSMP-P3`):
   ```
   RLSMP-P3|rlsmp_weather loaded
   RLSMP-P3|weather from the server: rain (period 123, 600 s left)
   RLSMP-P3|weather: RLS's own forecast notifications switched off (they describe the local forecast, not the server's)
   RLSMP-P3|weather: forced rain (RLS showed clear, now shows rain)
   ```
   Send me those lines. **Tell me if the sky or the rain flickers, or if the game stutters when the weather changes.**

### Named failure modes
| What you see | What it means |
|---|---|
| Players still see different weather | Send both game logs. Look for `weather: forced` and `weather: forceCondition(...) failed`. |
| `W RLSMP-P3|another weather mod has priority` | RLS's "external override" (another weather mod) is on: shared weather does nothing. |
| `W RLSMP-P3|RLS's weather module is not available` | RLS's weather is not loaded; nothing to sync. |
| `weather: forceCondition(x) failed (refused)` | RLS refused (not ready, or an override). It retries every 30 s. |
| Many `weather: forced` lines in a row for the same condition | RLS keeps changing it back (its own forecast). One line per RLS change is normal; a stream is not. Send the log. |
| Phone pop-ups like "Rain approaching" that do not match the weather | They come from RLS's own local forecast. We switch them off (the log line above); if you still get them, tell me. |
| RLS's weather app (phone) shows a different forecast | Expected: the app shows the player's local forecast, not the server's. |
| The time of day jumps to noon when it turns clear | The clock restore did not work. Send the log. |
| Rain but the roads are dry, or grip feels wrong | RLS applies wetness itself. Tell me what condition and for how long. |

### Known gaps
- Never played. Based on reading RLS's weather code; the engine's own code is not visible to me.
- Still local to each game: RLS's morning fog, the temperature, and the timing of thunder sounds.
- Changes snap (RLS applies a forced condition immediately) instead of fading.
- When a game's own forecast moves into its next segment it can show its own weather for up to about 2 seconds before it is forced back. Tell me if you notice it.
- On by default (unlike live swapping). Kill switch: `"weather": {"enabled": false}` in the server config. RLS saves "dynamic weather on", "rainy days allowed" and "forecast notifications off" in each player's career save; switching the feature off later does not undo that.
- RLS saves the forced condition in the player's career save (its dynamic weather setting becomes on, rainy days allowed). That is expected.
- The mix is followed roughly: the in-between conditions are a little more common than their weights say.



## Traffic settings menu (build 0.4.23)

**Who:** since 0.4.29 every player (there is no admin list). In 0.4.23 to 0.4.28 only `polakpls` and `sucuk21` could use it.

**Steps**
1. Join the server. Press `[`. A window "RLS Traffic settings" should open. If nothing happens, type `/trafficmenu`.
2. Cars: move a car type slider (for example Truck to 0), press Apply. The status line should say "1 setting applied and saved". Look at `config/config.json` on the server: `trafficVariety.typeWeights.Truck` is 0.
3. Search a single car, set its slider, Apply. Same check under `trafficVariety.models`.
4. Where & when: choose Highways, then Night, change a weight, Apply.
5. Behaviour: change the personality mix; the percentages next to the sliders follow.
6. Press `[` again (or Close): the window closes. Have a second player press `[`: they get the window too, and see the new values after you press Apply.
7. Send me the lines tagged `traffic menu`, `probe: ui_imgui` and `RLSMP-ADMIN` from the game log and server log.

### Named failure modes
| What you see | What it means |
|---|---|
| `[` does nothing, `/trafficmenu` works | First game log (0.4.29): the game logged `Could not create a description for binding keyboard0::leftbracket`, so that name is not valid. 0.4.31 binds both `lbracket` and `leftbracket`; send the log lines `Could not create a description for binding` (the control named there is the wrong one). Or rebind under Controls > RLS Career MP. |
| Window never appears, log `probe: ui_imgui is not available` | ImGui missing in this game; menu cannot be drawn. |
| Window appears but the mouse does not click it | ImGui input vs game input. Send the `probe:` line (it lists mouse/visibility functions). |
| Typing in the search box also drives the car | Known risk: keys reach the game while typing. Tell me. |
| `W traffic menu draw failed` | A widget call failed; send the line. |
| Status "N refused (path: why)" | The server refused a value (out of range or unknown setting). Send the text. |
| "applied but NOT saved to config.json" | Server cannot write its config; check file permissions and the server log. |

### Known gaps
- Never played. Key name, mouse handling and typing while driving are unverified.
- A car keeps its model once spawned; new weights apply to cars built from now on (and to swaps if Swapping is on).
- Hand edits to `config.json` while the server runs are overwritten by the next Apply. Intervals read only at start (timer periods, weather period) are not editable here.
- Everybody can change the settings (including prices, what the fence pays and whether theft is on): the server only checks ranges. Every change is in the server log as `RLSMP-ADMIN <name> ... changed ...`.


## The fence (build 0.4.27)

Needs `"theft": {"enabled": true}` in the server config, and a black market member (console `rlsmp market grant <name>`).

**Steps**
1. Steal a car (see the theft section). The log has `RLSMP-THEFT converting parked ...`.
2. Type `/fence`: it lists the car with prices for strip, sell, resell, gamble. Note the drop spot name it gives.
3. Drive to that spot (the ACTIVE one, the one `/fence` names). Get OUT of the car and stand next to it.
4. `/fence strip`. Expect: a toast "Sold: $...", the car disappears, your money goes up by 30% of the car's value, and a `[fence]` line in the server log.
5. Try `/fence sell` far from the spot: expect "Bring the car there". Try while a cop chases you: "Lose the police first".
6. With a fake plate, a VIN plate and a part number from the market: `/fence resell` pays 60% and uses all three. With one or two: `/fence gamble`; about 3 in 10 should be a trap.
7. Send me the lines tagged `RLSMP-THEFT` (client) and `[fence]` (server), plus what money showed before and after.

### Named failure modes
| What you see | What it means |
|---|---|
| "Get out of the car and stand next to it first" | You were still in the car. The car is deleted, so you must be on foot. |
| "Stand next to the stolen car you want to sell" | More than 8 m away, or the game lost track of the car (a reload). Send the log. |
| "That car is not on your list" | The server has no record: the theft was never confirmed (check `[theft] ... stole` in the server log), or you restarted the game. |
| "Bring the car there" although you are at the spot | The spot moved (every 30 minutes), or `/where` shows a different position. Send `/where`. |
| "The server has no fresh position" | Wait 10 s and retry. If it never works the client position reports are not reaching the server. |
| Money did not change on screen but the server log says paid | `rlsmpWalletSet` was not applied. Send both logs. |
| The car stays after "Sold" | The delete failed. Send the client log. |

### Known gaps
- Never played. Stripping pays cash only: RLS has no way to take parts off a car, so nothing goes to your part inventory.
- The car must be in the same game session that stole it: after a restart the server still has the record but the game forgot the car, so it can't be sold (the record expires after `keepHours`).
- The value of a car comes from the game's price list (client-reported, capped at `fence.maxValue`). A car with no price in the list is valued at `fence.minValue` (2000): if payouts look tiny, the game had no price for that model.


## Lockout kit, jammer, tracker blocker (build 0.4.28)

1. Buy a lockout kit (`/market buy lockout_kit`, rep 10) and try an immobilizer-era car (about 1995 to 2010). Without the kit the prompt says "You need: Lockout kit". With kit + key programmer + blank key it works, takes about 25 s and is quiet (noise 0.2).
2. Luxury car (new or over $120000) with the connector injector, key programmer and blank key: note the noise in the log. With a signal jammer owned it should be a quarter of that. A luxury theft without a tracker blocker is reported within about 20 s; with one you get "Your tracker blocker killed the GPS tracker" and the usual report time.
3. Send me the `RLSMP-THEFT` and `[theft]` lines.

Known gaps: police cannot ping a tracker or be sent after a car you stole with one unblocked beyond the normal report; finding and removing a tracker is not built. Old `config.json` files that already list `key_programmer` under `theft.methods` need `lockout_kit` added by hand.


## Black Market phone app (build 0.4.28)

1. Join as a market member (`rlsmp market grant <name>` in the server console). Open the phone, App Store, find **Black Market**, press GET, open it from the home screen.
2. You should see your reputation, invites left and money at the top, the shop list, and at the bottom an invite box and the Stolen cars hint.
3. Buy a Screwdriver: the money drops, an "Your orders" card appears, and a green note says "Paid ...". The in-game toast about the drop spot still shows.
4. Wait for the order to read "Ready", drive to the spot, press "Collect here". The package should arrive (`/items` shows it).
5. As a player who is NOT a member: the app says "You are not in". Have a member invite you from the app: an "<name> invited you" card with Accept appears within a couple of seconds.
6. Send me: a screenshot of the app, and the game log lines that contain `Ignoring phone app manifest`, `PhoneBlackMarket`, `rlsmp_market` or `[Overhaul]`.

### Named failure modes
| What you see | What it means |
|---|---|
| No "Black Market" in the App Store | RLS did not accept the manifest, or did not read it from our mod. The game log has `Ignoring phone app manifest ...` with the reason. Send it. |
| The app opens but is blank / "Could not load .../PhoneBlackMarket.vue" | The UI could not load our view file (a second UI mod folder may need an entry file). Send the log line. |
| "No connection" (first seen in game with build 0.4.28/0.4.29; 0.4.31 showed the cause, `lua.rlsmp_market` was an empty stub; 0.4.32 uses raw engineLua instead: if it still fails, the grey text lists every route's error) (original note: the app opened, so the manifest and view load fine) | The view could not call the market extension. Since 0.4.30 the card shows the error text underneath: send a screenshot, plus the game log lines with `RLSMP-MARKET` (that line appears when the call DID reach Lua; no line = it never got there) and `Black Market could not reach the game`. |
| "Not available" | The career is not active on the server yet (the market extension is switched off until it is). |
| "Connecting..." forever | The server never answered `rlsmpMarketGet`: market disabled on the server, or you are not loaded. |
| A tap does nothing | At most one action per second is accepted. Tap again. |

### Known gaps
- Never run in the game. The view itself is covered by an automatic test with a fake bridge (tests/phone_app, optional), and RLS's own manifest checks accept the manifest, but the real RLS phone UI has not loaded it.
- The icon is a stock icon name (`shoppingCart`), not a picture.
- Selling stolen cars is still chat only (`/fence`): it needs the car deleted in the game, so it stays a command.


## Theft, fence and market pages in the menu (build 0.4.29)

1. Press `[`. The tab row now has ten tabs (five to a row): the last three are Theft, Fence, Market.
2. Theft page: tick "Car theft on", press Apply. The status should say "1 setting applied and saved"; the server log shows `RLSMP-ADMIN ... theft.enabled=true`, and `config/config.json` has `"enabled": true` under `theft`. Walking up to a parked car should now give the theft prompt (if you own the tools), without a server restart. Untick it and Apply: the prompt stops.
3. Fence page: change "Strip pays" to 0.5, Apply, then use `/fence` at the drop spot: the quote follows.
4. Market page: change an item's price, Apply, then `/market list` shows the new price.
5. Out-of-range values (typed into a number box beyond its range) are clamped by the menu and refused by the server with "out of range".
6. Send me: the `traffic menu`, `RLSMP-ADMIN` and `RLSMP-THEFT` lines.

Known gaps: never played. Drop spot places are only in `config.json`. Changes made to `config.json` by hand while the server runs are overwritten by the next Apply.


## Plate reading fixes (build 0.4.29)

1. Two players drive the same model in the same colour. Player A escapes a police chase (so the car's description is remembered for 20 minutes). Player B drives slowly past a cop: B should NOT get the "wanted" chase from the description. If A changes plates and drives slowly past a cop, A still should.
2. Menu, Police page: untick "Police rules on" and Apply. Cops should stop reading plates (no "Police reading your plate" text) until you tick it again.
3. Send the `[plates]` server log lines and the `plates` client log lines if anything looks wrong.


## No fine in a stolen car (build 0.4.50)

1. Steal a car (see the theft section) and get caught for speeding or a chase ending in a citation or arrest. Expected: the message says "Citation: no fine, this car is not registered to you." (or "Arrest: ..."), your money does not drop, and the game log has `police fine NOT charged`.
2. Do the same in a car from your own garage: the fine is charged as before.
3. If you are fined in the stolen car anyway, send the game log lines with `finePay` / `police fine` and the exact message you saw: it means RLS charged the fine another way.
Known gaps: only RLS's own "Police fine" is covered (not other fees); the chase, arrest and plate flag still happen. Loaned or rented garage cars are still fined.


## More bad drivers at night (build 0.4.51)

1. Drive in traffic at night (the game's light state says night) for a few minutes and watch: about one in three cars should now be something other than a normal driver (aggressive tailgaters, racers going far over the limit, drunk weavers). By day it is about one in five.
2. The log has `smart: it is night now: new personalities from the night mix` when night falls and `... day now ...` at dawn. The line `smart: personalities now ...` (census) shows the counts if you call `rlsmp_personalities.census()` from the console.
3. Menu (`[`), Behaviour page: the "at night x" sliders change it live. Set a night multiplier to 1 to switch the effect off.
Known gaps: never played; it only changes WHICH personality a car draws, not how bad a racer or a drunk is.


## Police cars come back behind you, as another model (build 0.4.52)

1. Drive until cops get re-placed (a chase, or just driving through the city). Search the game log for `police respawn:`.
2. Expected sequence: `cop N re-placed X m in front of / behind the player`, `building <model> behind the player`, `new cop M came out Y m behind the player`, `done, new cop M (<model>), old cop N removed`. The new model is not the old one.
3. If you see `came out IN FRONT`, `too close` or `failed`, the placement did not work as hoped: send those lines and the next ones. After three failures the log says `switched off for this session` and RLS places cops as before.
4. Check that the new cop chases you like the others (role police is set the way RLS's own police service does it).
Settings: Police page of the `[` menu (on/off, builds a minute, how far behind).
Known gaps: never played. What `roadBehind` does with one car and a gap is a guess (the log lines tell); BeamMP sends each spawn and delete to everybody, and the per-player car limit (`MaxCars`) can refuse the extra car for a moment.
