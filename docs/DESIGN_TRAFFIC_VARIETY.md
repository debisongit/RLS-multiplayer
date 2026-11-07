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

How it lives next to RLS: RLS installs its own `createGroup` filter with `overhaul_shell_patches` and re-checks it every ~2 s. We register our wrapper with
`overhaul/lib/shell/wrapperLifetime.registerForwarder`, so RLS sees us as part of its chain and does not wrap over us again. The other way round does not work: RLS's own
wrapper is not registered as a forwarder, so when RLS wraps OVER us our check says "not intact" and we wrap again on top. The older layer stays in the chain but is switched
off (a plain passthrough), and a re-entrancy counter makes sure only one layer ever builds a group (`rewrapped createGroup` counts these in the log). The test
`tests/traffic_variety_client_test.lua` section 9 reproduces this order (and fails without the fix).

**Limit of step 1:** a car keeps its model once it exists, so area and time only matter for cars built later (traffic start, refills, parked cars),
not while you drive from the city to the highway. That is what step 2 is for.

## Step 2: live swapping out of sight (build 0.4.20, built, untested)
The owner chose "swap cars out of sight as you drive". It is built as a careful first version, **off by default**, in two switches under `trafficVariety.swap`:
- `enabled`: **watch only**. Every `checkSeconds` the client looks at the traffic cars; one that is hidden for `hiddenSeconds` in a row and that weighs clearly less than a
  different offered model for the current road class and time of day (`minRatio` 1.5) is logged as `swap would happen (watch only): car .. A (Type, weight) -> B/config (Type, weight)`.
  Nothing in the game changes. At most `perMinute` decisions per minute.
- `live`: **really replaces the car** (experimental). It calls the game's own `replaceVehicle` (captured by `lib/replaceGuard.lua`) for that one car with a named config, finds
  the new car and hands it to RLS's traffic with `gameplay_traffic.insertTraffic`. After `maxFailures` failures it switches itself off and only watches.

What counts as "out of sight": not visible on this camera (`camVisible`), not within 450 m of or visible to any other player (Claude A's `rlsmp_bubble`), and
`personality.skipReason` is nil (standard civilian AI car, active, not in a pursuit, not crashed, not a job car, not the player's or another player's, not parked).
Candidates are only entries the game offered in recent traffic groups (already filtered by RLS), kept by `rlsmp_trafficVariety`.
With default weights every car weighs 1, so nothing is ever swapped: swapping only follows real weights (type, road class, day or night, mods).

BeamMP facts that shaped it: a swap is a delete and a spawn that every other game receives (their spawns queue up while they drive), so the rate is low and only invisible cars are used.
Still unverified in the game: what `replaceVehicle` returns for a different model, whether `insertTraffic` is enough to restore the car's role and pooling, and RLS's saved traffic state
after a swap. The watch-only mode and the `swap done` / `swap failed` log lines are there to find that out.

## Open questions
- Which `Type` names does the game use? (The log line `model Types in the pool = ...` lists them after the first group; put them in `typeWeights`.)
- Does the game give a `speedLimit` per road node? (`probe: road class source` says `speedLimit` or `none`.)
- Mods: which ones, and how big? (Join time.)
