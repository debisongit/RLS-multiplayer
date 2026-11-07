# Phase 3: what is left (audit of build 0.4.2, nothing played in-game)

For Claude B. Smallest first.

1. Config: spec wants about 5 cars solo and 9-10 for two. Set `baseBudget 0, perPlayerBudget 5, maxPerPlayer 5, minPerPlayer 2` (now 30/10/18, so 1 and 2 players both get 18). Update `tests/traffic_test.lua`.
2. Quota only goes down (client `traffic.lua` ~l.158). Remember the player's own activeAmount and raise back toward `min(quota, original)` when the quota rises. Do not lower while `rlsmp_police.isPursuit()`.
3. Pursuit timer uses `os.clock()` (CPU time). Use wall clock.
4. `police.lua` wrap flag `__rlsmp_<name>` stays true if RLS re-assigns the function; store the wrapper and compare identity.
5. Freeze only cops tied to the chase (the player's pursuit ids, or within ~300 m), not all police.
6. Field test: do frozen cops (`enableRespawn=false` makes RLS state `locked`) still chase? If not, wrap `tryRespawn` to return early for pursuing cops instead.
7. NOT BUILT: multi-player bubble. Wrap RLS traffic `tryRespawn` / `updateActiveRadius` (`trafficVehicle.lua` ~l.472-525): only fade or respawn a car if it is more than 450 m from EVERY player car (local + `MPVehicleGE` remote) and nobody has line of sight. Client only, MP only, non-police only.
8. Needs server work: players send `rlsmpPos` every ~2 s so zones can be assigned; report pursuit state to the server.
9. Verify with 2 clients: no pop-ins in view of either player, quota rises when someone leaves, chases end with cops released.
