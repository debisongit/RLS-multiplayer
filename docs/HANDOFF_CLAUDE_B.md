# Handoff for Claude B (Phase 3: traffic and police)

Read this first, then `docs/COLLAB.md`, `docs/RLS_MAP.md`, `docs/NEXT_FEATURES.md`, `docs/PROTOCOL.md`.
State at hand-off: **build 0.4.0**, branch `claude/amazing-sagan-kh6ecn`, all `tests/run.sh` suites pass. Nothing from builds 0.3.2 to 0.4.0
has been played yet (see "What is verified" below).

## 1. What this project is, in one minute

RLS Career Overhaul (a fork of the BeamNG career, namespace `overhaul_*`) does not run on BeamMP by itself. We add:

- **Server plugin** `Resources/Server/RLS-Career-MP/` (BeamMP server Lua 5.3). Keeps each player's RLS save on the server, keeps the
  money truth, runs businesses, claims, traffic quotas.
- **Client mod** `Resources/Client/RLS-Career-MP/` (BeamNG LuaJIT, zipped by `tools/build_client_zip.sh`). Writes the server's save to
  disk, starts the RLS career, reports changes back.
- Never edit RLS or BeamMP files. Wrap functions at runtime, keep the original, and wrap **once per module table** (the game reloads
  modules while mods change). Pattern: `Resources/Client/.../lib/mapGate.lua`, `lib/removeGuard.lua`, `vehicleGuard.lua` (`wrapped` weak table + `install()` called every frame).

## 2. How a player's session flows

1. Client loads, `rlsmp_core` waits for the world (`onWorldReadyState(2)`), sends `rlsmpHello {v, build}`.
2. Server `sessions.lua` loads `profiles/<beammpAccountId>.json` and streams it down in chunks (`net.sendBig`, 16 KB each, checksummed).
3. Client `saveBridge` writes it to `settings/cloud/overhaul/saves/<profile>/autosave1/`, lifts RLS's "no BeamMP" block, starts the career
   on the **server's map** (`rls_west_coast`), then sends `rlsmpLoaded`. Only players with `sessions.isLoaded(pid)` are "in career".
4. After every RLS save the client uploads only the changed JSON files; the server rebuilds the slot, locks start settings, refuses cheats,
   compares money with its own wallet and corrects it.
5. Money changes: client reports `rlsmpWalletDelta {d, r, c}` (amount, reason label, **RLS money category**). Server `wallet.lua` accepts or
   refuses, with limits for *earned* money and separate limits for *moved* money (loans, sales, transfers).

Key files (server): `net.lua` (events, chunking, **chat router**), `sessions.lua` (handshake, uploads, wallet events, hooks `onEarned`, `onBig`),
`profiles.lua`, `wallet.lua`, `business.lua`, `claims.lua`, `qol.lua`, `trafficLabels.lua`, your `traffic.lua` / `trafficPolice.lua`.
Key files (client): `core.lua` (state machine, enables everything), `saveBridge.lua`, `wallet.lua`, `fleet.lua`, `vehicleGuard.lua`, `unstuck.lua`,
`trafficLabels.lua`, `claims.lua`, your `traffic.lua` / `police.lua`, `lib/net.lua`, `lib/mp.lua`.

## 3. Rules of the road (we learned these the hard way)

**Network layer**
- One BeamMP event name = **one handler**. `net.on(name, fn)` registers a global function per event; a second `net.on` with the same name
  silently replaces the first (this is why `onPlayerJoin`/`onPlayerDisconnect` belong to `sessions.lua` only and why chat goes through `net.onChat("command", fn)`).
  Use your own timer events (`MP.CreateEventTimer("yourTick", ms)`) instead of piggybacking.
- Server modules export `init(cfg, pluginRoot)` and are listed in `server/modules.lua` (order matters: sessions before anything that uses it).
- Event names are prefixed by area: `rlsmpBiz*`, `rlsmpTraffic*`, `rlsmpPolice*`, `rlsmpWorld*`. Document every event in `docs/PROTOCOL.md`.
- Client code that is not an extension goes in `lib/`. Extensions are loaded from `core.lua` (`extensions.load(...)` list + `enable(true/false)` in
  the three places: career active, career closed, server leave). Your two modScript `load(...)` lines also work; either is fine, be consistent.
- `lib/transfer.lua` exists twice (server `shared/` and client `lib/`) and must stay **byte identical**. It also holds `BUILD`.

**Releases**
- Bump `M.BUILD` in `shared/transfer.lua`, then `cp` it over the client copy (the test checks they match). The client logs `client loaded, build X`;
  the server logs each player's build on join. A mismatch means someone forgot `tools/install_to_server.sh <server folder>`. This has already wasted one test round.
- Config: add defaults under your own key in `server/config.lua`; the file merges missing keys into existing `config.json` files automatically.

**BeamNG / BeamMP facts that bit us**
- RLS refuses to start while BeamMP is active; we wrap `overhaul_shell_extensionManager.refuseCareerStart`.
- RLS career start calls `core_vehicles.removeAll()`, which deleted other players' cars. `lib/removeGuard.lua` skips vehicles BeamMP knows as remote.
- BeamMP deletes the player's walking character (`unicycle`) the moment they enter any car. Never "switch back" to a unicycle; refuse before entering
  (`vehicleGuard` wraps `gameplay_walk.isVehicleBlacklisted` and `getInVehicle`).
- BeamMP leaves the server with "map not found" if the map isn't in `core_levels` when announced. RLS builds `rls_west_coast` after it loads; `lib/mapGate.lua` bridges that.
- BeamMP disables any local mod the server doesn't send, so RLS must come from the server (and only one copy of it).
- `spawn.safeTeleport(veh, pos, rot, checkOnlyStatics, visibilityPoint, removeTraffic, centeredPosition, resetVehicle)`: **resetVehicle defaults to true and repairs the car**. Pass `false`.
- `MPVehicleGE.getVehicles()` (keyed by server id "0-7", fields `gameVehicleID`, `isLocal`, `hideNametag`) is the safe lookup. `getServerVehicleID(id)` logs errors for unknown cars. `lib/mp.lua` wraps this.
- `map.objects[id]` has `pos`, `vel`, `dirVec` and `objectCollisions[otherId] == 1` while touching; works for remote cars too (RLS traffic uses it).
- `player car in traffic data`: RLS inserts the player's car with `isAi = false` (`gameplay_traffic.insertTraffic(id, true)`). AI traffic has `isAi == true`.
- RLS **wraps vanilla traffic/police/parking at runtime** (`overhaul/integration/ownedServices.lua`): hook RLS's owned methods (`tryRespawn`, `updateActiveRadius`,
  `integration/services/police.lua`), not the vanilla files. Traffic "focus" is the **local player only**, so remote cars are just obstacles to each game's traffic.
- Everything physical is client side. The server cannot run AI; it directs.

**Tests**
- `tests/run.sh` must pass before every push (needs `lua5.3`, `luajit`; syntax checks every Lua file). Server tests use a fake BeamMP and `tests/support/json.lua`; client tests fake the game globals.
  Look at `tests/claims_test.lua` + `tests/claims_client_test.lua` for the newest pattern.
- Both of us push to the same branch. Always `git fetch && git rebase origin/claude/amazing-sagan-kh6ecn` before pushing; if a push is rejected, rebase and rerun the tests.

**Working with the owner**
- Short, plain, relaxed answers; no jargon walls; few em dashes. They are not a professional developer. They test in-game with a friend and send `beamng.log` files:
  grep for `[rlsmp-timing]`, `RLSMP-P3`, `Spawning object`, `|E|`. Give them a numbered test list and say exactly which build to expect.
- Ask when a design choice is theirs (they answer fast); decide small things yourself and say so. Be honest about what is untested.

## 4. What changed in your area (please read)

- `config.lua` traffic defaults: `totalBudget = 0` now means **automatic**: `baseBudget 30 + perPlayerBudget 10 x players`, `maxPerPlayer 18` (was a fixed 40 / 15).
  `totalBudget > 0` still fixes it, so your field-test settings (`totalBudget = 6`) still work. `traffic.quotaFor` handles both; `tests/traffic_test.lua` expectations updated (15 -> 18, etc.).
  Your field-test doc still says "default budget of 40": please refresh it.
- New `server/trafficLabels.lua` + client `trafficLabels.lua`: each game lists its AI traffic and parked cars; everyone hides those name tags. It uses `gameplay_traffic.getTrafficData()` `isAi` and `gameplay_parking.getParkedCarsList(true)`. If you add new kinds of AI cars (racers, event props), make sure they show up in `collectOwn()`.
- `claims` (below) treats a remote car with `hideNametag == true` as traffic and ignores it.
- The quota is a **ceiling only**: it never raises traffic above what RLS spawns. Making traffic denser needs RLS's own traffic amount; test it before changing.

## 5. Systems already built that you can build on

- **Business** (`/biz ...`): shared bank, members, payout split, shared fleet (check-out model). `business.getFor(pid)` gives a player's business.
- **Claims** (`server/claims.lua`, client `claims.lua`): `/dashcam` ($100 per car). Games report contacts with other players' cars; the server judges fault from closing speeds, chance of being caught from dashcams and nearby cars, payout from RLS's per-part repair price, repeat-accident multiplier, RLS insurance claim for the at-fault driver. **`claims.dryRun = true`**: tells players, takes no money. The pure functions `claims.judge` and `claims.confidence` are easy to extend (red light, wrong way, police pursuits).
- **Wallet categories**: `sessions.onEarned(fn)` fires for accepted *earned* money (e.g. police rewards, fines are negative so not included).
- **Chat commands**: `net.onChat("name", function(pid, rest) ... end)`; message is hidden from other players.
- **`/unstuck`** (nearest road, keeps damage), **vehicle guard**, **map gate**, **career reset** (`rlsmp reset <player>`), **save lock** (start settings fixed, cheats refused).

## 6. What is verified, and what is not

Played and confirmed by the owner (build 0.3.0 era): joining, saves, garage after reset, sync of movement and traffic, map `rls_west_coast`, business basics.
**Not played yet:** `/unstuck` keeping damage (0.3.2), traffic name tags (0.3.3), entry refusal (0.3.4), dashcam + claims + traffic scaling (0.4.0), business payout split and
fleet retire, the save lock. Your Phase 3 police and quota work was field-test-documented (`docs/FIELD_TEST_PHASE3.md`) but check which build the owner used.

## 7. Suggested next work for you (in this order)

1. **Field-test round for Phase 3 on build 0.4.0** (refresh `docs/FIELD_TEST_PHASE3.md`: new defaults, build number, install script). Include the anti-teleport police checks against RLS's `tryRespawn`.
2. **Server-directed traffic** (`docs/NEXT_FEATURES.md` section 1): time-of-day multiplier on the quota, zone weights (city/highway/rural/port), zones assigned so different players' traffic doesn't overlap.
   Needs player positions on the server; check what the BeamMP server API gives (`MP.GetPositionRaw` in some versions) or have each client send its position every 2 s (`rlsmpPos`, small and validated).
3. **Police + claims**: pursuits and crashes interact (a crash during a chase shouldn't double-charge). Add a flag from your police code to the claim report (client sends `inPursuit`), and let the judge reduce the at-fault payout for the player being chased by a cop (or raise it for the cop).
4. **Dynamic AI traffic** (experimental, behind a config switch): driver personalities (aggressive overtakers, slow drivers, drunk weaving, no-plate cars that trigger an RLS police offense, street racers), then road events. See `NEXT_FEATURES.md` section 3. Keep CPU in mind (it is all per-game).
5. After the owner has played the claims dry run: switch `claims.dryRun` off together with them, and tune `confidence` / payout numbers from real incidents (the server logs `[claims] ... CAUGHT / got away`).

Ask the owner before building: how many players typically join (decides budget numbers), and whether racers/no-plate cars should be chased by the existing police.

## 8. Where the sources are (for reading, not editing)

- RLS: `https://github.com/RLS-Modding/rls_career_overhaul` (2.8.x, AGPL; `docs/RLS_MAP.md` indexes it).
- BeamMP client: `https://github.com/BeamMP/BeamMP` (`lua/ge/extensions/MPVehicleGE.lua`, `MPCoreNetwork.lua`, `beammp/multiplayer.lua`).
- CareerMP (`StanleyDudek/CareerMP`): ideas only, **no license**, never copy code. It must not be installed together with RLS.
