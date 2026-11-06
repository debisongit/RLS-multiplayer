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
| C→S | `rlsmpWalletDelta` | `{d = moneyChange, r = reasonLabel}` |
| S→C | `rlsmpWalletSet` | `{money, why}` server-approved balance; client applies it |

## Traffic director (Phase 3)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpTrafficQuota` | `{active, players, rev}` ceiling for active traffic cars on this client; sent on join and whenever the number of career players changes |

`quota = clamp(floor(traffic.totalBudget / players), minPerPlayer, maxPerPlayer)`. The client only ever *lowers*
`gameplay_traffic` active amount to the quota (re-checked every 3 s); RLS events that lower traffic are left alone.

## Reserved prefixes for later phases

- `rlsmpBiz*` – Phase 2 business / syndicate (Claude A)
- `rlsmpTraffic*`, `rlsmpPolice*` – Phase 3 (Claude B)
- `rlsmpWorld*` – Phase 4
