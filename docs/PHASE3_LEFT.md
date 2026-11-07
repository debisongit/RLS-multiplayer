# Phase 3: what is left (audit of build 0.4.2, nothing played in-game)

For Claude B. Smallest first.

1. NOTE: the owner later asked for a little MORE traffic than the first spec, so the numbers stay as they are. Original: spec wants about 5 cars solo and 9-10 for two. Set `baseBudget 0, perPlayerBudget 5, maxPerPlayer 5, minPerPlayer 2` (now 30/10/18, so 1 and 2 players both get 18). Update `tests/traffic_test.lua`.
2. DONE (0.4.12): quota can rise again, no cuts during a chase. Was: quota only goes down (client `traffic.lua` ~l.158). Remember the player's own activeAmount and raise back toward `min(quota, original)` when the quota rises. Do not lower while `rlsmp_police.isPursuit()`.
3. DONE (0.4.12): pursuit timer uses wall clock.
4. DONE (after 0.4.13, untested in-game): wrapper stored in the marker, identity checked, replaced functions rewrapped. Was: `police.lua` wrap flag `__rlsmp_<name>` stays true if RLS re-assigns the function; store the wrapper and compare identity.
5. DONE (after 0.4.13, untested in-game): freeze `pursuit.sight.policeId`, `pursuit.roadblockTargetId` and police within 300 m (release past 350 m); all police if the player position is unknown. Note: RLS sets `role.targetId` on every unit, so it cannot be used. Was: Freeze only cops tied to the chase (the player's pursuit ids, or within ~300 m), not all police.
6. Field test: do frozen cops (`enableRespawn=false` makes RLS state `locked`) still chase? If not, wrap `tryRespawn` to return early for pursuing cops instead.
7. DONE in build 0.4.13 (`bubble.lua`, untested in-game): the recycle half of the multi-player bubble. A traffic car is only recycled when it is more than 450 m from every other player and none has a clear line to it. STILL OPEN: the spawn half (a recycled car is placed ahead of the LOCAL player and may appear in front of another player). Original note: Wrap RLS traffic `tryRespawn` / `updateActiveRadius` (`trafficVehicle.lua` ~l.472-525): only fade or respawn a car if it is more than 450 m from EVERY player car (local + `MPVehicleGE` remote) and nobody has line of sight. Client only, MP only, non-police only.
8. FIRST HALF DONE (untested in-game): clients send `rlsmpPos {x,y,z,speed,chased}`, server `positions.lua` stores it (`/where` to check). STILL OPEN: traffic.lua using it for zones. Original: Needs server work: players send `rlsmpPos` every ~2 s so zones can be assigned; report pursuit state to the server.
9. Verify with 2 clients: no pop-ins in view of either player, quota rises when someone leaves, chases end with cops released.
