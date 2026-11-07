# Field test: Phase 3 (traffic budget + police anti-teleport)

Nothing in Phase 3 has run in the real game yet. The unit tests use fake game objects, so this run
answers whether the real BeamNG / RLS / BeamMP objects behave the way the code assumes.
Plan for about 30 minutes, one player (a second player is optional, see the end).

## Versions this was built against

| Component | Version |
|---|---|
| RLS-Career-MP (this repo) | default branch `claude/amazing-sagan-kh6ecn`, code commit `71c42cf`, build `0.4.18` (everything on the default branch; later commits only change documents) |
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
   It prints `Installed RLS-Career-MP build 0.4.18`. It is a bash script: on Windows run it from Git Bash or WSL.
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
8. **Check the build.** The server log must say `joined with client build 0.4.18 (server build 0.4.18)` and the game log must
   say `client loaded, build 0.4.18`. If the two builds differ, you are running an old client zip (this has already wasted a test round): re-run the install
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

## Taxis and riding along (build 0.4.18)

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

## Garage part shop (build 0.4.18)

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

