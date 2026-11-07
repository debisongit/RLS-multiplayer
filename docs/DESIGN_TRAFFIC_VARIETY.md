# Design: varied traffic (models and configs)

Decided with the owner. Nothing here has been played in the game yet.

## Decisions
- **Car source:** vanilla cars **and** cars from mods the server ships. (Every player downloads every mod zip at join; a game without a model skips it.
  Joins have already stalled during the save download, so keep big car mods to a few.)
- **Mix control:** server weights per car **Type** (the model list's own `Type`), plus multipliers by **road class** and **day / night**.
- **Left out:** nothing beyond what RLS already refuses (police, junk shells, underpowered cars, broken parts; taxis and police come from their own providers).
- **Where:** moving traffic **and** parked cars (both are built with `core_multiSpawn.createGroup`).
- **Area and time:** the owner chose **live swapping** ("swap cars out of sight as you drive"). Built in steps, see below.

## Build 0.4.19 (step 1, built, untested): the mix when a group is built
Server `server/trafficVariety.lua` sends `rlsmpTrafficVariety` (settings from `config.json` key `trafficVariety`) once to each loaded player.
Client `rlsmp/trafficVariety.lua` wraps `core_multiSpawn.createGroup`:
1. asks the game (through RLS's own filter) for a pool of `oversample` x the group size,
2. adds eligible configs of the server's mod models that are installed on that game (checked with RLS's `isConfigEligible`),
3. picks the group by weight (`lib/trafficVariety.lua`), no model above `maxShare` of a group, every entry unique while the pool allows,
4. gives the game its own untouched group if anything is off (settings missing, police group, no result, an error).
Road class comes from the nearest road's `speedLimit` (city < 17 m/s, main < 27, else highway; `speedLimit` is unverified in the game, a probe line says if it was found);
day or night from `core_environment.getLightState().isNight`.

Why it fits RLS: RLS installs its filter with `overhaul_shell_patches` and re-wraps whenever its wrapper is not "intact". We register our wrapper with
`overhaul/lib/shell/wrapperLifetime.registerForwarder`, so RLS sees us as part of its chain and does not stack on top of us; we never re-wrap while intact.

**Limit of step 1:** a car keeps its model once it exists, so area and time only matter for cars built later (traffic start, refills, parked cars),
not while you drive from the city to the highway. That is what step 2 is for.

## Step 2 (not built): live swapping out of sight
Research so far (RLS source, BeamMP source):
- A traffic car's model never changes after spawn (respawn and pooling move the same object). To change it the car has to be replaced or deleted and respawned.
- RLS recycles cars out of sight through its own `fadeOut` and respawn (`C:tryRespawn`, `C:onRespawn`; `respawnCount` goes up); Claude A's `rlsmp/unjam.lua` and `bubble.stayFor` already use that path.
- `core_vehicles.replaceVehicle(model, options, oldVeh)` replaces a specific car; `lib/replaceGuard.lua` makes it work in a BeamMP session.
- BeamMP: every local spawn is sent to all players (`Os` packet) and each config change means a respawn on every other game; remote spawns queue up while a player drives and
  all appear in one hitch when they stop. So swaps must be rare (a few per minute), only for cars nobody can see, and never for cars in a chase.
- A swapped car must go back into RLS's traffic system (`gameplay_traffic.insertTraffic`), keep its role, and RLS's saved traffic state must stay consistent.
Needs an in-game probe first (what exactly `onRespawn` and the pool do) before any code.

## Open questions
- Which `Type` names does the game use? (The log line `model Types in the pool = ...` lists them after the first group; put them in `typeWeights`.)
- Does the game give a `speedLimit` per road node? (`probe: road class source` says `speedLimit` or `none`.)
- Mods: which ones, and how big? (Join time.)
