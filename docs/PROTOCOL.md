# RLS-Career-MP network protocol (v1)

All messages are BeamMP events with a JSON body. Names start with `rlsmp`.
`C→S` = client to server, `S→C` = server to client.

## Big payloads (chunked)

Anything that may be large (a whole save) is split into chunks.

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpChunkBegin` | `{id, kind, n, len, sum, extra}` |
| S→C | `rlsmpChunk` | `{id, i, d}` (i = 1..n) |
| C→S | `rlsmpUpBegin` | `{id, n, len, sum}` |
| C→S | `rlsmpUpChunk` | `{id, i, d}` |

`sum` is a Fletcher-32 checksum (`transfer.checksum`). Chunks can arrive in any order.

## Join handshake

| # | Direction | Event | Body / meaning |
|---|---|---|---|
| 1 | C→S | `rlsmpHello` | `{v}` protocol version. Sent when the world is ready (`onWorldReadyState(2)`). |
| 2 | S→C | big payload, `kind = "profile"` | text = `{files = {rel = fileText}}`, extra = `{profile, isNew, startingOptions, money}` |
| 3 | C→S | `rlsmpLoaded` | `{ok, err?}` after RLS reports the career active (or failed) |
| – | S→C | `rlsmpError` | `{code, msg}` |

Server drops the player if: wrong `v`, no BeamMP account (unless `allowGuests`), account already online,
or no `rlsmpHello` within `handshake.helloTimeoutSeconds`.

## Saves

| Direction | Event | Body |
|---|---|---|
| C→S | upload (`rlsmpUpBegin`/`rlsmpUpChunk`) | text = `{all = {rel = checksum}, files = {rel = text}}` (only changed files in `files`) |
| S→C | `rlsmpUpAck` | `{id, ok, err?, resync?, money?, corrected?, sums?}` |
| S→C | `rlsmpSaveNow` | `{}` asks the client to save now (every `forceSaveMinutes`) |

`resync = true` means the server could not rebuild the save; the client resends everything.
`sums` lists files the server changed (e.g. corrected money) so the client's next diff is right.

## Wallet

| Direction | Event | Body |
|---|---|---|
| C→S | `rlsmpWalletDelta` | `{d = moneyChange, r = reasonLabel, c = rlsMoneyCategory}` |
| S→C | `rlsmpWalletSet` | `{money, why}` server-approved balance; client applies it |

## Traffic director (Phase 3)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpTrafficQuota` | `{active, players, rev}` ceiling for active traffic cars on this client; sent on join and whenever the number of career players changes |

`quota = clamp(floor(budget / players), minPerPlayer, maxPerPlayer)` where `budget` = `traffic.totalBudget` if above 0, else `baseBudget + perPlayerBudget x players` (grows with players online). The client only ever *lowers*
`gameplay_traffic` active amount to the quota (re-checked every 3 s); RLS events that lower traffic are left alone.

### Player positions (groundwork for server-directed traffic)

| Direction | Event | Body |
|---|---|---|
| C→S | `rlsmpPos` | `{x, y, z, speed, chased}` meters, m/s, `chased` = the client's `rlsmp_police.isPursuit()` |

Client `positions.lua` checks every 2 s while the career runs, using whatever the player controls (car or walking character).
It skips the report while the player moved less than 5 m, but sends at least every 10 s and at once (at most every 1.5 s) when `chased` changes.
Server `positions.lua` accepts it only from loaded players, only finite numbers with |x|,|y| <= 100000, |z| <= 20000, 0 <= speed <= 1000,
and at most one report per second per player. It keeps the latest one per player and forgets it when the player leaves (or the id is reused).
Lua API for other server modules: `get(pid)`, `all()`, `distance(a, b)` (horizontal), `near(pid, radius)` (pids, closest first),
`nearest(pid)` (pid, distance), `isChased(pid)`. Chat `/where` shows your own last stored position.

## Police pursuits (Phase 3)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpPoliceConfig` | `{antiTeleport, blockRoadblocks}` sent once when a player finishes loading |

While the player is chased (their traffic-data `pursuit.mode` >= 1) and `antiTeleport` is on, the client keeps every police unit
from respawning (`enableRespawn = false`), refuses RLS roadblocks (if `blockRoadblocks`) and
refuses `gameplay_traffic.forceTeleport` on police units. Everything is restored when the pursuit ends.

## Business (chat commands, server-side)

Typed in BeamMP chat, hidden from other players. Money moves through the server wallet and
the client gets a normal `rlsmpWalletSet`.

`/biz create <name>` · `invite <player>` · `accept` · `leave` · `deposit <n>` · `withdraw <n>` · `info`

Rules: max `business.maxMembers` (4); owner leaving hands ownership to the oldest member; the last member
leaving closes the business and gets the bank. Saved in `businesses/<id>.json`.

### Business fleet

Chat: `/biz fleet` (list) · `fleet add` (car you sit in) · `fleet take <n>` · `fleet return` · `fleet retire` (owner: the car you hold leaves the fleet for good).
Payout split: `/biz split <0-50>` sends that % of your earned money (not loans, sales or transfers) to the business bank.
A fleet car exists in exactly one place: stored in the business, or in one member's RLS inventory (tagged `fleetId`).

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpFleetDo` | `{act = "add" \| "return", fid?}` client uploads the car it sits in |
| C→S | upload with `{kind = "fleetAdd"/"fleetReturn", data = {inv, fid?, rec}}` | `rec` = RLS inventory record (model, config, ...) |
| S→C | `rlsmpFleetAck` | `{act, ok, inv, fid?}` client removes the car from its inventory only when `ok` |
| S→C | big payload `kind = "fleetVehicle"` | `{fid, rec}` client spawns it and adds it to its inventory |
| S→C | `rlsmpFleetRetire` | `{fid}` owner retired the car you hold (`/biz fleet retire`): drop its fleet tag, it is now your own car |
| C→S | `rlsmpFleetRelease` | `{fid, why}` take failed (garage full, spawn error): free the car |

## Quality of life

Chat `/unstuck` or `/road`. Server checks career loaded and `unstuck.cooldownSeconds`, then sends `rlsmpUnstuck {}`;
the client teleports the car or walking character to the nearest road (not during pursuits or above 6 m/s).

## Traffic name tags

`rlsmpTrafficIds {ids = {"<pid>-<n>", ...}}` (C→S): this game's AI traffic and parked cars. The server keeps only ids that start with the
sender's player id and relays them as `rlsmpTrafficIdsRx {from, ids}` (S→C) to every other loaded player, who hide those name tags.
New players receive everyone's current lists within 2 s.

## Dashcams and crash claims

`/dashcam` installs a dashcam on the car you sit in (`claims.dashcamPrice`, default $100). Flow: server `rlsmpWhatCar {}` -> client
`rlsmpMyCar {inv, model, name}` -> server charges, stores `profile.dashcams[inv] = model` (checked against the car in later reports).

A game watches the car its player drives. On contact with another player's car (not traffic, not a walking player) it sends, after the
contact ends, `rlsmpHit {me, with, inv, model, mine = {p, v, d}, other = {p, v, d}, damage?, nearby}`: server vehicle ids, snapshots
of both cars from just before impact, the repair price of the damage taken (RLS's per-part price) and how many cars were within 40 m.
The server accepts only reports where `me` belongs to the sender. One report is enough; it waits `reportWindowSeconds` for the other.

Verdict: fault share = whose velocity pointed into the other car (closing speed), 50/50 if both did. Chance of being caught =
`baseConfidence + witnesses x perWitness (+ dashcamBonus if either car has one)`, 100% if both do; otherwise "nobody could prove it".
Payout = damage of the other car x fault share x repeat multiplier (x1.5 per extra at-fault accident within 60 s, max x3), capped.
S->C `rlsmpClaimPenalty {damage}` makes the at-fault game file an RLS insurance claim (driver score drops).
`claims.dryRun = true` (default) only tells players what would happen.

## Vehicle rules

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpVehicleConfig` | `{allowPassengers}` sent once when a player finishes loading |

The client vehicle guard refuses other players' cars, AI traffic and parked cars. Exceptions: the taxi RLS hailed for the player
(decided by RLS's own taxi state: `pullingOverForPickup`, `waitingForPickup`, `occupied`, `pullingOverForDropoff`, `waitingForDropoff`),
and, when `allowPassengers` is on, another player's car for a player who is on foot (a passenger; BeamMP gives the passenger camera).
Log lines use the tag `RLSMP-GUARD`.

## Phase 4: world

- Profile download `extra.drop` (list of inventory ids): cars the server already handed to a fleet (or later escrow) but that are still in the save after a crash. The client removes them ~8 s after the career starts (`fleet.dropStale`) and saves.
  The server fingerprints the car file (`profiles.markOut`), so a different car in the same slot is never removed.

- **Map travel** is refused online (client `world.lua` wraps `overhaul_career_garage_switchMap.switchMap` and `resolveTravelBlockers`). No messages.
- `rlsmpEventDone` (client to server) `{race, t, place}`: a finished RLS freeroam event (from the RLS hook `onRlsFreeroamRaceResultFinalized`; only timed races, not derby/burnout/tractor pull).
  Server `events.lua` keeps the top 5 per event in `records.json`, announces records in chat, `/records [event]` lists them. Times are client-reported, no money depends on them.

### Pink-slip duels (server `duel.lua`, client `duel.lua`; off by default: `duel.enabled`)

Chat: `/duel <player>`, `/duel accept`, `/duel cancel`, `/duel claim`. Needs at least one course in `config.json` (`duel.courses`).
- server to client: `rlsmpDuelWho {id}` (answer with your car), `rlsmpDuelGo {id, finish, radius}`, `rlsmpDuelEnd {id}`,
  `rlsmpDuelHand {slip, inv}` (loser: upload this car), `rlsmpDuelAck {ok, inv, slip}` (remove it now), big transfer `duelVehicle {slip, rec}` (winner).
- client to server: `rlsmpDuelCar {id, inv, model, pos}`, `rlsmpDuelPos {pos}` (1 per second during a duel), `rlsmpDuelFinish {id}`,
  upload kind `duelHand {slip, inv, rec}`, `rlsmpDuelReceived {slip}`, `rlsmpDuelRelease {slip, why}`.
- Owed cars are kept in `duels.json` until the winner confirms. See the safety rules at the top of `server/duel.lua`.

## Flow control

- `rlsmpChunkProgress {id, got}` (client to server): sent every 8 chunks received. The server keeps at most 24 chunks in flight beyond `got`
  (a busy client drops what it cannot read, which stalled a 177 chunk save at 129 and 153). After 3 s without news it trickles on anyway.

## Lost chunks

- `rlsmpChunkMissing {id, list}` (client to server): up to 50 chunk numbers of transfer `id` that never arrived. The client asks after 4 s without progress, repeating every 4 s.
  The server resends them (up to 60 per request) from the running transfer or from a copy it keeps for 2 minutes after sending.

## Shared time of day

- `rlsmpTime {m, r, dm}` (server to client, every `time.syncSeconds`, loaded players only): game minute of the day (0 = midnight) game minutes per real second right now, and real minutes per full day (RLS day shape).
  Computed from the server wall clock (`server/clock.lua`), so restarts keep it consistent. Client `clock.lua` draws the sky 4x per second and
  moves RLS's weather forward every 10 s (`sleepTo`); RLS's own day cycle is paused while connected. Config `time = {enabled, dayMinutes = 45, syncSeconds = 5}`.

## Shared dealership stock (server `shop.lua`; off by default: `shop.shared`)

No new network events: it rides on the save upload and the profile download.
- The first logged-in player whose upload has a usable `career/vehicleShop.json` (and `career/general.json` `boughtStarterVehicle == true`) becomes the
  source. Their `maps[<server map>]` entry (`vehiclesInShop`, `sellersInfos`, `dirtyDate`) is the master, kept in `shop.json` with the source account id,
  the map and RLS's `version` / `valuationSchemaVersion` / `limitedMileageDealerSchemaVersion`. Later uploads from the source refresh it.
- On join (`sessions.beforeDownload` hook, before `profiles.encodeForDownload`) the player's stored `maps[<server map>]` entry is replaced by the master.
  The rest of the file (watchlist, discovered dealers, pending fleet purchases, reward grants, other maps) is theirs. The stored copy is changed too,
  so client and server checksums agree. Skipped when the file is missing or broken, has no `maps`, has other version numbers, or the career has not
  bought its starter car (RLS keeps starter-only stock until then).
- `shop.markSold(shopId)` (server Lua, nothing calls it yet) removes a listing from the master; it stays out until the source's own save drops it.
- Known gap: RLS does not save `nextShopUpdateTime`, so the first time the shop opens each game runs `updateVehicleList(false)`, expires old offers and
  fills open dealer slots with its own `math.random`. Only listings that existed at join are shared; a sale is seen by others only after they rejoin.

## Reserved prefixes for later phases

- `rlsmpBiz*` – Phase 2 business / syndicate (Claude A)
- `rlsmpTraffic*`, `rlsmpPolice*` – Phase 3 (Claude B)
- `rlsmpWorld*` – Phase 4
