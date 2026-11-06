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

`quota = clamp(floor(traffic.totalBudget / players), minPerPlayer, maxPerPlayer)`. The client only ever *lowers*
`gameplay_traffic` active amount to the quota (re-checked every 3 s); RLS events that lower traffic are left alone.

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

## Reserved prefixes for later phases

- `rlsmpBiz*` – Phase 2 business / syndicate (Claude A)
- `rlsmpTraffic*`, `rlsmpPolice*` – Phase 3 (Claude B)
- `rlsmpWorld*` – Phase 4
