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
| 3 | C→S | `rlsmpLoaded` | `{ok, err?}` after RLS reports the career active (or failed). If the client gave up (`start_timeout`, `ok = false`) but RLS then starts the downloaded career, it sends `{ok = true}` later; the server accepts that for a `failed` session that has its profile |
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
| S→C | `rlsmpPoliceConfig` | `{antiTeleport, blockRoadblocks, bubbleMode, range}` (`range` = `{respawnRange, respawnDelay, unjam = {enabled, seconds, distance}}` from server config `traffic.*`, see `docs/RESEARCH_RESPAWN_RANGE.md`) sent once when a player finishes loading (and again after a menu change). `bubbleMode` is `"original"` (default) \| `"protect"` \| `"off"`: which traffic cars another player's game may not recycle, see `docs/RESEARCH_CHASE_RANGE.md` |

While `antiTeleport` is on (MP career, a chase or not) the client holds every police unit within 300 m of the player (released past 350 m; units
RLS marks `disabled` are let go) by setting `rlsmpHold` (the bubble's `tryRespawn` wrapper then refuses to recycle it), cancels a fade-out already in progress
on a held unit, sets `respawn.spawnDirBias = -1` on every police unit (a unit RLS re-places arrives from behind, not ahead), refuses RLS roadblocks
against the player (if `blockRoadblocks`) and refuses `gameplay_traffic.forceTeleport` on police units. In a chase it also holds the units RLS names
(nearest seen, roadblock unit). It does not use `enableRespawn = false` (RLS then locks the unit).

## Plate reading and police records (Phase 3)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpPlateConfig` | `{enabled, rangeMeters, maxSpeedKmh, minSeconds, maxSeconds, readChance, afterEscapeChance, afterEscapeSeconds, encounterSeconds, copCooldownSeconds, skipChance, retriggerSeconds, offenseScore}` sent once when a player finishes loading (also when `enabled` is false) |
| C→S | `rlsmpPlateLookup` | `{plate, model, color}` a police unit finished reading the player's plate (`color` = colour name, may be missing) |
| S→C | `rlsmpPlateResult` | `{plate, model, flagged, reason?, matchedBy?, limited?}` answer to a lookup; `plate`/`model` echo the normalised request, `matchedBy` = `"plate"` or `"description"`, `limited` = too many lookups (not looked up; the client lets that unit read again later) |
| C→S | `rlsmpPlateEscaped` | `{plate, model, color}` the player escaped an RLS chase in this car |
| C→S | `rlsmpPlateChanged` | `{model, oldPlate, plate, oldColor?, color?}` one of the player's garage cars got a new plate text or paint colour |

Server `plateRecords.lua` owns `config.police.plateFlagSeconds` (7200), `config.police.descriptionSeconds` (1200) and `config.police.plateReading` (master switch `enabled`, default on).
It keeps, shared by every player: **plate flags** keyed by plate text (trimmed, upper case, at most 16 characters) + model, valid `plateFlagSeconds`; **car descriptions** keyed by model + colour name, valid `descriptionSeconds`.
A lookup matches a fresh flag first (`matchedBy = "plate"`, whoever drives that plate + model), then a fresh description (`"description"`) - and a description only for the player whose account made it (the `by` stored with it; a player without an account id never matches one). The client only reads its OWN player's car, so the asker is the driver. Saved in `plates.json`, expired entries pruned every minute.
- `rlsmpPlateEscaped` is accepted only from a loaded player, at most once per `escapeCooldownSeconds` (60), and only if `positions` saw that player chased within `escapeNeedsChaseSeconds` (300, 0 = trust the client). It flags the plate (reason `escaped`) and remembers the description when a colour is given.
- `rlsmpPlateChanged`: at most one per 3 s per player. A different plate text deletes the flag of `oldPlate` + model; a different colour deletes the description `model` + `oldColor`.
- Lookups: at most `lookupsPerMinute` (20) per player are looked up; every lookup gets an answer. While plate reading is off (`plateReading.enabled` false, or `police.enabled` false) lookups answer clean and escapes / changes are ignored. The menu can change these settings live (`plateRecords.resend` sends them again).
- Lua API for other server modules: `flag(plate, model, color, reason, by?)`, `lookup(plate, model, color)`, `clearPlate(plate, model)`, `clearDescription(model, color)`, `prune()`, `records()`.

Client `plates.lua` (`rlsmp_plates`, pure rules in `lib/plateRead.lua`), only in a multiplayer session while the career is active, after the config arrived, every 0.5 s, for the local player's car only:
- A reader is an AI police unit (RLS role `police`, not disabled, not chasing, object active) whose RLS data `role.validTargets[playerCar]` says `visible` and `dist` (squared) <= `rangeMeters`², while the player's traffic-data `speed` is under `maxSpeedKmh`. Skipped while the player is chased (`rlsmp_police.isPursuit()`, pursuit mode not 0 or a queued pursuit start), on foot (RLS `isPerson` entry or `unicycle`), in an AI car (passenger), playing as a cop (`overhaul_career_police_playerDriving.getPlayerIsCop()`), or while a lookup / chase start is pending.
- Each unit decides once per `encounterSeconds` whether it reads (`readChance`; `afterEscapeChance` for `afterEscapeSeconds` after an escape in this game). A read takes `minSeconds`..`maxSeconds` (random), shown with `ui_message` (category `rlsmpPlateRead`) as `Police reading your plate: 7AB____` (letters revealed = progress). Out of range, too fast or another unit: the read starts again from zero. A unit that finished a read leaves the player alone for `copCooldownSeconds`.
- Flagged result: no new chase for that plate + model within `retriggerSeconds` (our own memory, RLS wipes its pursuit table when a chase ends), then the unit lets it go with `skipChance`, otherwise the player's traffic vehicle gets `triggerOffense({key = "wantedPlate", value = plate, score = offenseScore})` (RLS x0.75, first pursuit level at 150). If after 1.5 s no pursuit runs or is queued, `setPursuitMode(1, playerCar, unit)`.
- Escape = RLS hook `onPursuitAction(vehId, "evade", pursuit)` for the player's car (or RLS's walk hand-off car). Ends where RLS's evade timer is still under 1 s (its "stalemate" end in `career/police/playerDriving.lua`) are not escapes.
- Plate text and paint colour of the current garage car (by inventory id; paint jobs respawn the car) are watched; a change sends `rlsmpPlateChanged`. Empty plate text (RLS refreshing the plate) is ignored.
- Colour name: from the spawn config `paints[1].baseColor`, else the live `obj.color` (linear, converted), one of black, white, silver, grey, red, orange, brown, yellow, green, teal, blue, purple, pink.
Log lines: `RLSMP-P3 ... plates:` (client), `[plates]` (server).

## Smart traffic: driver personalities (Phase 3)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpSmartTraffic` | `{enabled, mix = {normal, slow, aggressive, racer, drunk}, policeReact}` sent once when a player finishes loading (also when `enabled` is false) |

Server `smartTraffic.lua` owns `config.smartTraffic` (defaults: on, mix 80/10/6/3/1, policeReact on) and sends weights as numbers >= 0
(anything else becomes 0); they need not add up to 100. Client `personalities.lua` (`rlsmp_personalities`, pure logic in `lib/personality.lua`)
does nothing until this arrives, and only in a multiplayer session while the career is active.

Each game picks one personality per AI traffic car (by vehicle id) the first time the car is seen active, and changes only the game's own AI
settings: `ai.setAggression`, `ai.setSpeedMode("limit")` + `ai.setSpeed` (cap worked out from the road limit) or `"legal"`, `ai.driveInLane`.
`normal` is left to RLS. Settings are re-sent every ~20 s (+-4 s), at once after RLS respawns the car or gives it the standard role back,
when the road limit changes, and on each drunk event (lane keeping off for 1-2.5 s every 8-20 s, a new speed every 4-8 s, 15% of those a
hard brake). Skipped: anything but RLS's `standard` role, cars in or about to start a pursuit, the player's car, other players' cars,
parked cars, the player's garage cars, crashed cars (until RLS respawns them), cars RLS's vehicle policy marks `roleLocked` / `pursuitImmune`, inactive cars. Cars handed back for any
reason but a pursuit, role change or crash, and every car when the feature turns off or the career closes, get RLS's traffic values back
(`baseAggression`, `"legal"`, lane keeping on). No horn, lights or markers.

`policeReact`: a racer or drunk that is fast (over max(16.7 m/s, 1.2 x limit + 2 m/s)) or weaving, on two checks in a row, within 80 m of an
AI police car that is free (no target, no pursuit mode, not on cooldown or disabled), gets `setPursuitMode(1, carId, policeId)` (RLS's police service). At most one per 60 s per game, never
while the player is chased (`rlsmp_police.isPursuit()`) or another pursuit runs. Not a network event. Log lines: `RLSMP-P3 ... smart:`.

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
A parked car the player stole (car theft, below) may be entered: exactly the vehicle ids `rlsmp_theft` converted.
Log lines use the tag `RLSMP-GUARD`.

## Phase 4: world

- Profile download `extra.drop` (list of inventory ids): cars the server already handed to a fleet (or later escrow) but that are still in the save after a crash. The client removes them ~8 s after the career starts (`fleet.dropStale`) and saves.
  The server fingerprints the car file (`profiles.markOut`), so a different car in the same slot is never removed.

- **Map travel** is refused online (client `world.lua` wraps `overhaul_career_garage_switchMap.switchMap` and `resolveTravelBlockers`). No messages.
- `rlsmpEventDone` (client to server) `{race, t, place}`: a finished RLS freeroam event (from the RLS hook `onRlsFreeroamRaceResultFinalized`; only timed races, not derby/burnout/tractor pull).
  Server `events.lua` keeps the top 5 per event in `records.json`, announces records in chat, `/records [event]` lists them. Times are client-reported, no money depends on them.
  Limits: one accepted run per player (account) per 5 s, others are ignored; a record goes to everybody's chat only if it is the event's first time or beats the old record
  by at least 0.05 s (otherwise only the player is told); a player can open a new event name only while they hold fewer than 40 events alone (nobody else has a time there).
- Map travel wrapping: `world.lua` checks every frame that `switchMap` / `resolveTravelBlockers` are still its wrappers and wraps again if RLS put new functions there.

### Pink-slip duels (server `duel.lua`, client `duel.lua`; off by default: `duel.enabled`)

Chat: `/duel <player>`, `/duel accept`, `/duel cancel`, `/duel claim` (re-send a won car now). Needs at least one course in `config.json`
(`duel.courses`, `start`/`finish` as `{x, y, z}` or `{x = .., y = .., z = ..}`; a course without usable numbers is skipped with a warning).
- server to client: `rlsmpDuelWho {id}` (answer with your car), `rlsmpDuelGo {id, finish, radius}`, `rlsmpDuelEnd {id}`,
  `rlsmpDuelAck {ok, inv, slip, model}` (loser: remove this car now and save; the client skips it if the model differs or the car is in a job),
  big transfer `duelVehicle {slip, rec}` (winner).
- client to server: `rlsmpDuelCar {id, inv, cur, model, pos}` (`cur` = the inventory id of the car the player sits in; must equal `inv`),
  `rlsmpDuelPos {pos}` (1 per second during a duel), `rlsmpDuelFinish {id}`, `rlsmpDuelReceived {slip}`, `rlsmpDuelRelease {slip, why}`.
- Removed: `rlsmpDuelHand` and the upload kind `duelHand`. The loser's client never sends the car any more: the winner's
  record is built from the server's own copy (`career/vehicles/<inv>.json`, must have `model` = the staked model and a `config` table).
  If that copy is unusable, the winner is announced but no car moves.
- At the win the slip goes into `duels.json` in stage `deliver`, the loser's slot is marked out (`profiles.markOut`, so the join-time
  `extra.drop` list removes it if the loser was offline or the removal failed) and re-marked after any loser save that still has the car.
  `rlsmpDuelReceived` only moves the slip to `delivered`; it is removed when a later winner save holds a car with that `slipId`
  (or any winner save 60 s later). If the winner leaves before that, it goes back to `deliver` and is re-sent on the next join.
  Old `duels.json` entries in stage `hand` are dropped at start (nothing had moved yet).
- Plausibility (config `duel.maxSpeed` = 120 m/s, `duel.minPings` = 5): a ping implying a faster jump than `maxSpeed` since the last
  accepted one is refused and that player cannot win the duel; a finish needs the start position (at GO) within `startRadius` of the
  course start, start-to-finish straight distance over elapsed time under `maxSpeed`, and at least `minPings` pings since GO.
  `duel.maxValueGapPercent` (0 = off) refuses a duel when the cheaper car (server copy's `configBaseValue`, RLS's base price of the config, not the depreciated value) is more than that many percent cheaper.
- See the safety rules at the top of `server/duel.lua`.

## Black market (server `market.lua`, client `market.lua`)

Custom (RLS has none). Players use the Black Market phone app (and the automatic pickup in the drop circle); the server owns membership, reputation, orders and money.

Hidden developer fallback, only while `ui.chatCommands` is true (below): `/market` (help) · `list` · `buy <item> [count]` · `orders` · `pickup` · `invite <player>` · `accept` · `fence`.
Console: `rlsmp market grant <player>` (online player becomes a member with `market.founderRep`) · `rlsmp market revoke <player>`.

- Profile: `market = {member, rep, invites (used), invitedBy, joinedAt, nextOrder, orders = [{id, item, n, price, at, readyAt, spot = {name, x, y, z}}]}`. Items go to `profile.items` (`items.lua`).
- Invites: `baseInvites` (2) + 1 per `repPerInvite` (10) rep, at most `maxInvites`. An invite is reserved and saved when sent; it comes back to an online inviter if it expires (`inviteSeconds`), the invitee leaves, or it was not needed.
- Buying: item must be in `items.CATALOG` and in `market.tiers` (`{price, minRep, off?}`), rep >= `minRep`, wallet seeded and money >= price (no debt). Tools (durable items) once only, also not while one is on order. At most `maxOpenOrders` open orders.
  The debit and the order are written in the same profile save, then `rlsmpWalletSet {money, why = "market"}` goes out (server-side spending; the client applies it as a sync and does not report it back).
- Delivery: ready `minDelaySeconds`..`maxDelaySeconds` after buying, at the spot that is active at that moment (`spotAt(readyAt)`; the spot rotates every `rotateMinutes`, each cycle of n periods visits every spot once in an order shuffled from the cycle number, never the same spot twice in a row). The spot is copied into the order.
- Pickup: the order must be ready, the player not chased, the latest `rlsmpPos` report (`positions.lua`) at most `positionMaxAge` s old and within `pickupRadius` m (horizontal) of the spot. The order is removed and the items given in the same save, so a second pickup finds nothing.
- Reputation (for other modules): `market.addRep(pid, n, why)` / `market.lossRep(pid, n, why)`, whole numbers, at most `maxRepChange` per call, kept between 0 and `maxRep`. `market.bust(pid, opts)` costs `bustRep` (a member with less is thrown out, open orders stay theirs) and takes used-up items (and tools if `bustTakesTools` or `opts.takeTools`).
- Fence: `market.fenceQuote(value | {value, kind = "car"|"part"})` = value x `fenceCarRate` / `fencePartRate`, whole dollars.

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpMarketDrop` | `{id, item, label, n, spot, x, y, z, readyIn}` a paid package; sent on buy and again once after each join for every open order. The client toasts, draws a marker at a ready spot within 300 m and, inside 15 m, asks `rlsmp_positions.reportNow()` and sends the pickup by itself (retry every 10 s while inside); a successful answer opens a small OK popup |
| S→C | `rlsmpMarketClear` | `{id}` package collected |

### Phone app (RLS phone, "Black Market")

Files: `gameplay/overhaul/phone/apps/black-market.json` (RLS phone app manifest with one `uiRoutes` row), `ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue` (the screen),
client `rlsmp/market.lua` (`M.uiGet()` every 1.5 s, `M.uiAct(action, a, b)`; reachable from the UI as `lua.rlsmp_market.uiGet()`), server `market.lua` ("Phone app channel").
The screen has no rules: it shows what the server last sent and relays taps. Nothing in the view imports from the RLS mod's files.

| Direction | Event | Body |
|---|---|---|
| C→S | `rlsmpMarketGet` | `{}` at most one answer per player per second |
| S→C | `rlsmpMarketState` | `{ready, member, money, spot, owned = [{name, label, count}], stolen = [{plate, model, strip, sell, resell?, gamble?}], meetup = {spot, kind}?, invite = {from, seconds}?}` plus, for members, `{rep, invitesLeft, items = [{name, label, price, minRep, durable, locked, have, onOrder}], orders = [{id, item, label, n, spot, readyIn, ready}] (orders also for players who were thrown out but still have paid orders)}` |
| C→S | `rlsmpMarketAct` | `{a = "buy" \| "pickup" \| "invite" \| "accept" \| "scout", item?, n?, who?, cars?}`; at most one per player per second (a separate limit from Get). Runs the same command as the chat (the buttons `fence`, `meetup` and `meetupCancel` never reach the server, the client extension runs them: `rlsmp_theft.fence(mode)` with mode strip|sell|resell|gamble, `rlsmp_meetup.startBlack()`, `rlsmp_meetup.cancel()`; `scout` has no chat form; `cars` = `[{x, y, z}]`, at most 8 stealable parked cars the game sees near the player) |
| S→C | `rlsmpMarketResult` | `{text}` what the command would have said in chat (collected instead of sent to chat), then a fresh `rlsmpMarketState` |
| S→C | `rlsmpMarketScout` | `{marks = [{x, y, z}], seconds}` after a bought scout tip: 2 to 3 stealable parked cars, shown as small spheres (no text) for `seconds` |

Scout tip (members, needs `theft.enabled`, config `market.scout`): the server knows no parked car, so the game sends the stealable ones it sees. The server keeps those within `radius` (800 m) of the
player's own `rlsmpPos` position (fresh, `positionMaxAge`) that `theft.stealableAt` (same hash as the client) also picks, picks `minCount`..`maxCount` at random, charges `price`, and starts a
`cooldownSeconds` wait. Nothing found = nothing charged. `seconds` is cut to what is left of the current theft pick (a car stealable now may not be next period), and a tip is refused in the last 60 s.
More than `freeUsesPerHour` tips an hour cost `repCost` reputation each. `rlsmpMarketState.scout = {price, minRep, locked, radius, minCount, maxCount, minutes, wait}` (members only, absent when off).


## Flow control

- `rlsmpChunkProgress {id, got}` (client to server): sent every 8 chunks received, plus a heartbeat about once per second (from `rlsmp_core`)
  while any download is unfinished and no every-8 report went out in that second (a lost report would keep the window shut).
  The server keeps at most 24 chunks in flight beyond `got` (a busy client drops what it cannot read, which stalled a 177 chunk save at 129 and 153).
  When the window is full and 3 s of wall clock pass without news, it sends ONE chunk and waits another 3 s (a trickle, not a flood). `got` values that do not grow are ignored.

## Lost chunks

- `rlsmpChunkMissing {id, list}` (client to server): up to 50 chunk numbers of transfer `id` that never arrived. During the save download the client asks every 4 s while there is a gap
  below the highest chunk received (even while later chunks still trickle in) or after 4 s without progress, one transfer per request (several unfinished transfers take turns).
  For a transfer still being sent the server queues only chunks it already sent (never pushes unsent ones past the window). The server accepts it only from players with a session, at most one per second per player,
  reads at most 50 numbers (whole numbers that exist, each queued once) and queues them; `pump()` sends them first, within the normal per-tick budget
  (`transfer.chunksPerTick`), outside the window. Source: the running transfer, or a copy kept for 2 minutes after sending (at most 200 queued per player).
- `rlsmpChunkHeader {id}` (client to server): a chunk came for a transfer whose `rlsmpChunkBegin` never arrived. Asked once at the first such chunk, again about every 3 s
  until it comes. The client keeps up to 64 chunks of up to 4 such transfers meanwhile. Same session / one-per-second rule. The server answers with `rlsmpChunkBegin`
  (the original header) from the running transfer (once its header went out) or the kept copy.
- The client ignores a `rlsmpChunkBegin` for a transfer it already has or has finished (so a second header never wipes chunks), and chunks of finished transfers
  (a late resend never runs a big handler twice). Transfer ids are never reused while connected.
- A chunk the server could not queue (`MP.TriggerClientEvent` returned `false`) is tried again on the next tick.

## Shared time of day

- `rlsmpTime {m, r, dm}` (server to client, every `time.syncSeconds`, loaded players only): game minute of the day (0 = midnight) game minutes per real second right now, and real minutes per full day (RLS day shape).
  Computed from the server wall clock (`server/clock.lua`), so restarts keep it consistent. Client `clock.lua` draws the sky 4x per second and
  moves RLS's weather forward every 10 s (`sleepTo`); RLS's own day cycle is paused while connected. Config `time = {enabled, dayMinutes = 45, syncSeconds = 5}`.

## Settings menu (server `trafficAdmin.lua`, client `trafficMenu.lua`; open to every player since 0.4.29)

- `rlsmpTrafficAdminGet {}` (client to server): asks for the settings. Answer `rlsmpTrafficAdminState {ok, cfg}`; `ok = false` (no `cfg`) only for somebody who is not on the server (no session).
- `rlsmpTrafficAdminSet {set = {{p = {"trafficVariety","typeWeights","Truck"}, v = 0.5}}, rm = {{"trafficVariety","models","pickup"}}}` (client to server): path arrays, never strings. Answer `rlsmpTrafficAdminResult {ok, applied, rejected = {{p, why}}, saved}`, then a fresh state to every admin online.
- `rlsmpTrafficAdminOpen {}` (server to client): sent by the chat command `/trafficmenu`; the client then asks for the state.
- Editable: traffic, smart traffic, variety, weather and police settings, plus (0.4.29) `theft.*` (also `theft.methods.<name>.seconds|noise|failChance|enabled` for each method in the config), `fence.*` (and `fence.rep.<mode>`) and `market.*` (and `market.tiers.<item>.price|minRep|off` for each item sold). Not editable: the admin list, drop spot places, a method's item list or tier, anything not on the allowlist. `theft.enabled` is live: theft always listens and refuses while off; the modules' `resend()` makes the games hear a change (`theft.resend`).
- There is no admin list any more: every player on the server (guests too) can open the menu and change settings. `server/trafficAdmin.lua` is what limits them: every path must match an allowlist rule with a type and a range, weight maps accept names of plain characters (max 64, max 64 entries), at most 3 requests per second per player, every change is logged with the player's name and account id (`RLSMP-ADMIN`). Values change INSIDE the existing config tables, `config.json` is rewritten, modules `resend()`; everybody who asked for the settings (or changed something) gets the fresh state.
- Client `trafficMenu.lua` (ImGui window) + `lib/trafficMenu.lua` (pending changes, patch). Action `rlsmpTrafficMenu` (`core/input/actions/rlsmp.json`), default key `leftbracket` (`settings/inputmaps/keyboard_rlsmp.json`).

## Shared weather

- `rlsmpWeather {c, p, n}` (server to client, every `weather.syncSeconds`, loaded players only): the condition `c` (one of RLS's six: `clear`, `partlyCloudy`, `overcast`, `drizzle`, `rain`, `storm`),
  the period number `p` and the seconds `n` until the next period. The server (`server/weather.lua`) computes it from its wall clock: every `weather.periodMinutes` there is a random severity and the weather glides
  smoothly to the next one's, split into conditions by the weights of `weather.mix` (so it passes through the conditions in between, one step at a time). Config `weather = {enabled, periodMinutes = 15,
  syncSeconds = 10, mix = {clear, partlyCloudy, overcast, drizzle, rain, storm}, force = ""}`.
  Client `weather.lua` makes RLS show it with `overhaul_world_weather.forceCondition` (RLS's `forceCondition("clear")` moves its clock to noon, so the clock is put back to the server minute at once) and forces again
  only when RLS changed what it shows after our last force. Nothing is done while RLS's external override (another weather mod) is active. RLS's own forecast phone notifications
  (`forecastNotifications`) are switched off once per session, because they describe the player's local forecast.

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

## Traffic variety

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpTrafficVariety` | `{enabled, typeWeights, mods, zones, day, night, oversample, maxShare, maxCandidates, applyToTraffic, applyToParked, zoneSpeedLimits, swap, police, pool, respawn, parked, rarity, preload}` sent once when a player finishes loading (also when `enabled` is false). `pool = {enabled, avoidLast, brandWindow, brandMax, streetMax, configsPerModel, popPower, ageMax}` (premade round-robin pool), `respawn = {enabled, perMinute, chance, repaintChance, waitSeconds, checkSeconds}` (re-roll of respawned traffic cars), `parked = {amount}` (the client raises its game setting `trafficParkingAmount` to this; 0 = leave alone), `rarity = {enabled, common, uncommon, rare, rareWords, uncommonWords, rareModels, uncommonValue, rareValue}` (share of picks per tier; words are matched in model and config names), `preload = {enabled, reserve, prepareSeconds, minGapSeconds, slowFrameMs, calmFrames, settleSeconds, warmShare, ageMax}` (lag protection: frame guard, picks prepared ahead, bias to loaded models), `simplified = {enabled, parked, traffic, nearRadius, perMinute, checkSeconds}` (cheap stand-in cars, off by default, see docs/RESEARCH_SIMPLIFIED.md). All sanitized again on the client. |
| S→C | `rlsmpModPrice` | `{enabled, max, min, tolerance, overrides = {["model" or "model/config"] = price}, models = {name, ...}}` sent once when a player finishes loading (and again after a menu change). Client `rlsmp_modPrice` sanitizes it again and, for modded models (the `models` list = keys of `trafficVariety.mods`, or files under mods/multiplayer), scales the car shop listing price to `lib/modPrice.lua`'s estimate. See docs/RESEARCH_MOD_PRICES.md. |
| S→C | `rlsmpTrafficVariety` | `{enabled, typeWeights, mods, zones, day, night, oversample, maxShare, maxCandidates, applyToTraffic, applyToParked, zoneSpeedLimits, swap, police, pool, respawn, parked, rarity, preload}` sent once when a player finishes loading (also when `enabled` is false). `pool = {enabled, avoidLast, brandWindow, brandMax, streetMax, configsPerModel, popPower, ageMax}` (premade round-robin pool), `respawn = {enabled, mode, perMinute, chance, repaintChance, waitSeconds, checkSeconds}` (re-roll of respawned traffic cars; `mode` = `"async"` default, the new car is built through the game's group spawn queue, `"inplace"` = replaceVehicle in place with a freeze, `"off"`), `parked = {amount}` (the client raises its game setting `trafficParkingAmount` to this; 0 = leave alone), `rarity = {enabled, common, uncommon, rare, rareWords, uncommonWords, rareModels, uncommonValue, rareValue}` (share of picks per tier; words are matched in model and config names), `preload = {enabled, minGapSeconds, slowFrameMs, calmFrames, settleSeconds, warmShare}` (lag protection: frame guard, bias to loaded models), `simplified = {enabled, parked, traffic, nearRadius, perMinute, checkSeconds}` (cheap stand-in cars, off by default, see docs/RESEARCH_SIMPLIFIED.md). All sanitized again on the client. |

Weights are `{name = number >= 0}` (at most 64 entries, names up to 64 characters). `typeWeights`, `zones[zone]`, `day` and `night` are keyed by the model's `Type`;
`mods` by model name. `swap` = `{enabled, live, perMinute, hiddenSeconds, checkSeconds, minRatio, maxFailures}` (live swapping; `enabled` only watches, `live` replaces cars). The client sanitizes everything again. Settings are forgotten when the player leaves the server. `police` = `{enabled, models, undercoverShare, maxShare, undercoverWords}` (police groups, see `docs/RESEARCH_POLICE_MIX.md`).

## Car theft (server `theft.lua`, client `theft.lua` + `lib/theft.lua`; off by default: `theft.enabled`)

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpTheftConfig` | `{enabled, seed, period, perMille, periodSeconds, radius}` sent when a player is loaded and again when the period changes |
| C→S | `rlsmpTheftCheck` | `{id, value, year}` the player stands within `radius` m of a stealable parked car (`id` = local game id, only echoed back) |
| S→C | `rlsmpTheftCan` | `{ok, id, method, label, seconds, noise, methods = [{method, label, seconds}]}` or `{ok = false, id, err}`; `methods` = every method the player has the tools for (the popup buttons); the key toast is shown only on `ok` (at most one answer per second per player) |
| S→C | `rlsmpTheftSteal` | `{method?}` from the hidden chat fallback `/steal [method]`; `{stop = true}` from `/steal stop`. The popup does not use it: its button calls `rlsmp_theft.choose("steal:<method>")`, which sends `rlsmpTheftStart` |
| C→S | `rlsmpTheftStart` | `{method?, value, year}` |
| S→C | `rlsmpTheftGo` | `{ok, method, label, seconds, noise}` or `{ok = false, err}` |
| C→S | `rlsmpTheftCancel` | `{}` the player walked away |
| C→S | `rlsmpTheftFinish` | `{}` the timer ran out |
| S→C | `rlsmpTheftResult` | `{ok}` or `{ok = false, err}` (failure roll; non-durable items are used up only on `ok`) |
| C→S | `rlsmpTheftDone` | `{plate, model, color, value, year, x, y, z, witnesses}` after the parked car was turned into a real car |
| S→C | `rlsmpTheftReported` | `{plate}` the car was reported stolen (the client only marks it; police find it by the plate) |

### Inspect hint (members only; config `theft.inspect`)

| Direction | Event | Body |
|---|---|---|
| C→S | `rlsmpTheftHint` | `{id, x, y}` the player is within `inspect.range` of a stealable parked car (the game asks again every 15 s while it stands there and nothing came back) |
| S→C | `rlsmpTheftHint` | `{id, ok = true}` ONLY for a black market member whose server-side position is within range (+5 m) of x/y at a car `theft.stealableAt` picks. Everybody else gets no answer at all |
| S→C | `rlsmpTheftInspectAsk` | `{}` from the hidden chat fallback `/inspect`; the game picks the nearest parked car of ANY kind within range. The popup's Inspect button does the same for the car it was opened for |
| C→S | `rlsmpTheftInspect` | `{id, x, y, z, value, year}` |
| S→C | `rlsmpTheftInspectGo` | `{ok, seconds}` the same for every player and car (`inspect.seconds`, 3) |
| C→S | `rlsmpTheftInspectFinish` | `{}` the timer ran out (earlier than `seconds - 1` is ignored) |
| S→C | `rlsmpTheftInspected` | `{id, found, text}` a member in range at a stealable car: tier, ways in with missing tools named, risk (alarm, GPS tracker, loud). Anyone else: `found = false` and the same "Just a parked car" text |

The game shows the hint as a small toast ("Press [key] to look closer", the key read from the player's bindings), never a text label. The key is the input action `rlsmpInteract` (default Y) and opens a small popup: Inspect, one button per steal method the player has tools for, Cancel. One start per `inspect.cooldown` s. `rlsmpTheftConfig` also carries `inspect = {enabled, range}`.
Honest limit: the seed is still sent to every game (the prompt at 3 m works for everybody), so a modified client can work out the stealable cars itself; the server only never confirms it.

- Stealable pick: every client hashes (`seed`, `period`, x and y of the parked car rounded down to a 4 m grid) with FNV-1a and takes the car when
  `hash % 1000 < perMille`. The seed comes from the server tag and the period (`floor(serverTime / periodSeconds)`), so it is the same for everyone and
  no client uses its own clock. Two games only agree about a car when their cars stand on the same spot (each game spawns its own parked cars).
- The server derives the tier from the (cleaned) `value` and `year` (`theft.tiers`: before `immobilizerYear` = old, before `keylessYear` = immobilizer,
  `luxuryValue` or more, or `newestYear` and later = luxury, else keyless; unknown year = `unknownYear`). A method works only on its own tier and needs
  all its items (`items.has`). One action per player, `retrySeconds` after a failure or a theft. `Finish` earlier than `seconds - 1` after the start fails.
- Witness chance = `baseWitnessChance + perWitness x min(witnesses, witnessCap) + noiseWitness x noise`, at most `maxWitnessChance`. Seen: reported
  `seenReportMin`-`seenReportMax` s later; unseen: `unseenReportSeconds`; a method with `tracker` (luxury) reports within `trackerReportSeconds`
  unless the thief owns a `tracker_blocker`. Records live in `stolen.json` (`stolen[plate]`, plate cleaned like `plateRecords.cleanPlate`), pruned
  after `keepHours`. On the report the server calls `plateRecords.flag(plate, model, color, "stolen", accountId)` if that module exists (`theft.reportHook`).
- Items that change a theft: immobilizer-era cars need `lockout_kit` + `key_programmer` + `blank_key` (the `key_programmer` method, tools kept, blank key used up). `jammer` (owned) multiplies the noise of methods marked `alarm = true` (luxury) by `theft.jammerNoiseFactor` (0.25) in `rlsmpTheftGo` and in the witness roll. `tracker_blocker` (owned) turns the fast tracker report off and the thief gets a chat line.
- The stolen car is not added to the garage inventory. The client keeps it in `rlsmp_theft.stolenCars()`; `vehicleGuard` lets the player into exactly
  the converted vehicle ids (`lib/theft` converted set, removed when the car is destroyed). Log tag `RLSMP-THEFT`.

## The fence (server `fence.lua`; client part is in `rlsmp/theft.lua`; needs `theft.enabled`)

Players use the garage computer buttons ("Garage flow" below) or the Black Market app (stolen cars section, buttons Strip, Sell, Resell, Gamble for the stolen car they stand next to at the drop spot). Hidden developer fallback (only with `ui.chatCommands`): `/fence` lists the stolen cars, `/fence strip | sell | resell | gamble`.
- Prices are shares of the car's value (from the theft record, capped at `fence.maxValue`): `strip` `stripRate` (0.30), `sell` `market.fenceCarRate` (0.35), `resell` `resellRate` (0.60, needs fake_plate + vin_plate + part_number, all used up), `gamble` `gambleBase` (0.45) + `gamblePerPaper` (0.075) per extra paper, using the papers the player has up to `gambleMaxPapers` (2), used up; `gambleBust` (0.30) chance of a trap: no money, car taken, `market.bust`. Good sales give `fence.rep[mode]` reputation.
- The server checks: fence enabled and theft on, loaded player, black market member, the plate is in the player's OWN theft record, the latest `rlsmpPos` report is fresh and within `market.pickupRadius` of the active drop spot (`market.spotAt(now)`), not chased, wallet seeded, one sale at a time. The record leaves memory, money and papers change in ONE profile save, then `stolen.json` is written; a failed save undoes everything.

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpFenceAsk` | `{mode}` from the chat command; the client looks for a stolen car within 8 m of the player (who must be on foot) |
| C→S | `rlsmpFenceSell` | `{plate, mode}` |
| S→C | `rlsmpFenceResult` | `{ok, mode, pay, busted?, takeCar?, err?}`; the client deletes the car only when `takeCar` is true (a sale or a trap) |
| S→C | `rlsmpWalletSet` | `{money, why = "fence"}` the new balance after a paid sale |

## Meetup selling (server `meetup.lua`, client `rlsmp/meetup.lua`; research in `docs/RESEARCH_MEETUP_SALE.md`)

A Marketplace sale (and a black market car sale) is finished at a spot the SERVER picks. A Marketplace sale starts from the RLS Marketplace app (hook on `sellVehicle`); a stolen car from the Black Market app button "Sell by meetup" (`rlsmp_meetup.startBlack()`), "Drop the meetup" cancels. Hidden developer fallback (only with `ui.chatCommands`): `/meetup`, `/meetup black`, `/meetup cancel`, `/meetup status`.
- Server rules: spot from `meetup.spots` (empty = `market.dropSpots`), never the player's last spot, at least `minDistance` from them when possible; one open meetup per player; `cooldownSeconds` after a meetup, `cancelCooldownSeconds` after a cancel; expires after `expireMinutes`; arrival needs a fresh `rlsmpPos` within `serverRadius` and no chase.
- Setup roll (made at creation, secret until arrival): a fully legal car never rolls (0). A plate in the theft records or flagged by `plateRecords`, and every black market car, rolls `illegalChance` / `blackChance` clamped to `minChance..maxChance`. A setup is `copsMin..copsMax` (1 to 2) police, no roadblocks; the sale does not happen and the player keeps the car (cooldown applies).
- Money: `market` kind is paid by RLS locally with its own offer value (the server cannot check that number). `black` kind is paid by the server (`market.fenceQuote`, one profile save, record removed).

| Direction | Event | Body |
|---|---|---|
| S→C | `rlsmpMeetupAsk` | `{kind = "market"\|"black"}` from the chat command |
| C→S | `rlsmpMeetupRequest` | `{kind, inv?, plate?, model?, price?}` |
| S→C | `rlsmpMeetupSet` | `{id, kind, spot, x, y, z, radius, expiresIn}` (client sets the GPS route) |
| S→C | `rlsmpMeetupDenied` | `{err}` |
| C→S | `rlsmpMeetupArrive` | `{id}` (stopped in the circle for 2.5 s) |
| S→C | `rlsmpMeetupResult` | `{id, ok, kind, retry?, setup?, cops?, pay?, takeCar?, inv?, err?}` |
| C→S | `rlsmpMeetupCancel` | `{}` |
| S→C | `rlsmpMeetupClear` | `{id}` |
| S→C | `rlsmpWalletSet` | `{money, why = "meetup"}` after a black market sale |
### Garage flow (the "Strip / illegal parts" button in RLS's garage computer; server `fence.lua`, client `rlsmp/garage.lua`)

Config `fence.garage` (true) and `fence.garageCooldown` (20 s). No drop spot needed. Stolen cars need black market membership and `theft.enabled`; ordinary garage cars do not.

| Direction | Event | Body |
|---|---|---|
| C→S | `rlsmpGarageQuote` | `{plate?, model?, value?, year?}`; without a car it only asks for the item list. At most one per second |
| S→C | `rlsmpGarageMenu` | `{ok, err?, items = [{name, label, count}], kind = "stolen" or "owned", plate, model, strip, fit = [{name, label}], fitted = [label]}`; `strip` is what stripping pays; for stolen cars also `sell`, `resell` (null without all three papers), `gamble` (null without a paper) and `trap` (percent); `fit` lists papers the player owns and has not fitted |
| C→S | `rlsmpGarageDo` | `{action = "strip", "sell", "resell", "gamble" (the last three for stolen cars only), "fit:fake_plate", "fit:vin_plate" or "fit:part_number", plate, model, value, year, inventoryId?}` |
| S→C | `rlsmpGarageResult` | `{ok, action, err?, pay?, takeCar?, inventoryId?, fitted?}`; on a paid sale (or a gamble that ended in a trap, `takeCar` true with `ok` false) the client removes the car (RLS `removeVehicle` for an owned car, `rlsmp_theft.removeStolenByPlate` for a stolen one). Followed by `rlsmpWalletSet` |

A plate that is in somebody else's theft record is refused. A stolen car's value comes from the server's record; an ordinary car's value is the client's, capped by `fence.maxValue`. Fitting uses the item up at once and sets `papers[name]` on the stolen record; resell and gamble count fitted papers first.

## Reserved prefixes for later phases

- `rlsmpBiz*` – Phase 2 business / syndicate (Claude A)
- `rlsmpTraffic*`, `rlsmpPolice*` – Phase 3 (Claude B)
- `rlsmpWorld*` – Phase 4
- `rlsmpMarket*` – black market

## Chat commands are hidden fallbacks (config `ui.chatCommands`, default false)

`/steal`, `/inspect`, `/fence`, `/market`, `/meetup` and `/items` only work while `ui.chatCommands` is true (set it in `config.json`; nobody needs it). With it off the server answers one plain line ("That is done in the game menus now") and does nothing else. Registered with `net.onChat(name, fn, true)`. No toast, hint or text names them any more; `tests/no_chat_hints_test.lua` scans for that.

Client input action `rlsmpInteract` (`core/input/actions/rlsmp.json`, default key Y in `settings/inputmaps/keyboard_rlsmp.json`) calls `rlsmp_theft.interact()`. See `docs/RESEARCH_THEFT_UI.md`.
