# Research: riding along as a passenger (and theft only on your own cars)

Claude A. Written without playing the game. Sources: the owner's logs (`/root/.claude/uploads/...`), our code, RLS source (read only) and what I know of BeamNG/BeamMP. BeamMP's source is NOT in this repo, so everything about BeamMP internals is marked.

## 1. Why passengers never worked (what the logs show)

VERIFIED (owner's log `38de4064-beamng.log`):
- `RLSMP-GUARD config received allowPassengers=false` and then `BLOCKED id=179416 jbeam=bx beammp=remote: another player's car (passengers off)`. The server default was `false` and the owner's `config.json` stores it (the server writes every default into `config.json` on start, `config.lua` `M.load`), so flipping the default alone would not have helped existing servers.
- Other players' AI cars and parked cars show up as `beammp=remote ... another player's traffic or parked car`, so the `hideNametag` list from `trafficLabels` works.

VERIFIED (RLS source, `avatar/walkEnterVehicle.lua`, `walkEnterVehicle/approach.lua`):
- A walking player is only walked to a car when `isEnterableVehicle(veh)`: `vehicle.playerUsable ~= false`, not `gameplay_walk.isVehicleBlacklisted(id)`, and `getActive()`. Our guard wraps `isVehicleBlacklisted` and `getInVehicle`.
- RLS seats the player with `gameplay_seatOccupants.requestEnterBestSeat(vehId, 0, walkingPos)`. That does NOT go through `gameplay_walk.getInVehicle`, so our wrapper never saw it. For a car that nobody sits in on OUR side (another player's car: its driver is a remote player), "best seat" is very likely the DRIVER seat, which gives the passenger the controls. RLS's own comment: "Stock passenger permissions block driving" (`permissionMode == 'passenger'`).
- RLS has `overhaul/lib/vehicles/passengerSeats.lua`: `enter(vehicleId)` seats player 0 in a passenger seat with permission mode `passenger` (`gameplay_seatOccupants.requestEnterSeat(..., 'passenger')`, or `requestUnseatedPresence(0, id, 'passenger')` as fallback).
- RLS's taxi ride sets `playerUsable = false` on every other car while you ride (`taxi/core.lua` `blockVehicleSwitching`) and back to `true` afterwards.

GUESSED (not verifiable here, each one is logged now so the next log settles it):
- Whether BeamMP marks remote cars `playerUsable = false` or puts them on the walk blacklist. We now switch `playerUsable` on for passenger-eligible remote cars (log line `made car N usable for passengers (playerUsable was false)`) and take them off the blacklist (`took car N off the walk blacklist`). If neither line ever shows, BeamMP does not do it.
- What BeamMP does when this game switches to a remote vehicle (`onVehicleSwitched`). I believe it only switches the camera (spectate-like) and does not give input to a car it does not own; with the seat in `passenger` mode the controls are blocked by RLS in any case.
- `ownerID` of a BeamMP vehicle: not used. The owner is taken from the server id `pid-vid` (verified: `server/trafficLabels.lua`, `server/claims.lua` use the same format).
- BeamMP removes a player's walking character while that player is inside a car (from the guard's earlier notes). We use that as the "driver is in a car" test: a remote `unicycle` of the same player number in `MPVehicleGE.getVehicles()` = the driver is on foot.

## 2. What we do now (client `rlsmp/vehicleGuard.lua`, server `vehicles.lua`)

- `vehicles.allowPassengers` is now `true` by default. Old `config.json` files with the stored `false` are switched on ONCE (`migrations.passengersOn`); turn it off again in the menu (Theft page, "Players can ride along...") or in the file and it stays off. Changing it in the menu is sent to everybody at once (`vehicles.resend`).
- A remote car may be boarded only when ALL of these hold (each refusal is logged `BLOCKED ... : reason`):
  1. passengers are on, the player is on foot,
  2. it is not the walking character of somebody, and not on the owner's `hideNametag` list (their AI traffic and parked cars),
  3. we have received that owner's traffic list at least once (`rlsmp_trafficLabels.heardFrom(pid)`), otherwise a fresh parked car could look like a player car,
  4. the owner is driving: no remote walking character of the same player number exists. This also covers another player's STOLEN car (it is not on the hideNametag list).
- The seat: `gameplay_seatOccupants.requestEnterBestSeat` is wrapped. For a remote car it is replaced by RLS's `passengerSeats.enter(vehId)`. No passenger seat available means refused, never the driver seat (log `no passenger seat could be given`).
- Controls: a watchdog (every 0.5 s) reads `getPlayerPresence(0).permissionMode`; if it is not `passenger` the player is put out at once (`seat mode is driver, not passenger`).
- Leaving: normal exit is RLS's own (door animation, `toggleWalkingMode`). The guard only notices (`passenger ride ended ... player vehicle is now N`).
- Safe exit when things go wrong: the player is put on foot beside the car with `gameplay_walk.setWalkingMode(true, pos)` (this makes a NEW walking character, which is what the guard already does for refused switches) when the driver gets out (a remote walker of the owner for 2 s: `the driver (player N) got out`), when the car is deleted (`onVehicleDestroyed`: the driver left the server), when BeamMP no longer lists the car, when passengers are switched off, and on leaving the server.

## 3. What to send next (two-player test, passengers)

Both players restart the game after installing; the server host re-runs `tools/install_to_server.sh`. Player A drives, player B walks up on foot and boards. Send both `beamng.log` files and the server console. Grep `RLSMP-GUARD`:

| Line | Tells us |
|---|---|
| `config received allowPassengers=true` | the server default / migration worked |
| `ALLOWED id=... beammp=remote: passenger seat in player N's car (playerUsable=... active=...)` | the guard let B in; the values answer the `playerUsable` guess |
| `made car N usable for passengers` / `took car N off the walk blacklist` | BeamMP (or something) had blocked the car for walking players |
| `passenger seat id=...: lib=true ok=true handled=true seat=...` | RLS gave a passenger seat. `lib=false`: the RLS lib path is different in this RLS version |
| `no passenger seat could be given` | the car has no passenger seat: B stays on foot |
| `switch ... -> ...: ok (passenger)` then `passenger ride started ... (seat mode: passenger)` | B is seated, mode must say passenger |
| `seat mode is driver` | RLS gave the driver seat anyway (then the seat wrapper did not run; tell me) |
| `the driver (player N) got out` / `the car was deleted` / `player vehicle is now` | the three ways a ride ends |
| `BLOCKED ... traffic list of player N not received yet` | B tried within seconds of joining |
| `BLOCKED ... player N is on foot` | A had stepped out |

Also tell me: could B see the road from the passenger seat, could B steer (should not), did B stand beside the car after getting out, did A see B in the car (probably not: BeamMP has no seat for a remote player, so others probably see nothing).

## 4. Theft only on cars of your own game

Owner report: everyone could steal EVERY parked car; before, only the cars that spawned because of you.

What I could verify: RLS fills its parked list (`parkedVehIds`) only from `insertVehicle`, called from its own `activate()` and from `simplified.fixParked`. By that reading a remote car is not in `gameplay_parking.getParkedCarsList`, and no log shows a remote id being targeted (the logs list `beammp=own` for the parked cars). One log DID show `stealable share: 1000/1000` for a while (a menu setting, later 197/1000): that alone makes every parked car of YOUR game stealable. I cannot prove which path let the owner steal a friend's car, so the fix is a check on every path, not on the list:

- `lib/mp.lua isOwn(gameVehicleId)`: single player = true; in a session only a car BeamMP lists with `isLocal == true` (and a server id whose player number is ours when `MPConfig.getPlayerServerID` says it) counts. A car BeamMP does not list yet counts as NOT ours, so a freshly synced remote car cannot slip through.
- `rlsmp/theft.lua`: `parkedIds()` (the one list behind nearestStealable, the interact popup, inspect, scout tip, hints and the census) drops every car that is not ours; `isStealable`, `convertParked`, `startInspect`, `startSteal`, the steal result and the popup check again. Log: `RLSMP-THEFT refused: not our car id=N (remote|unregistered|not ours)` once per car.
- `rlsmp/simplified.lua` (stand-in conversion) only looks at our own parked cars. `theft.liveByPlate` (recall) ignores remote objects, so a restore never deletes another player's car.
- Server: the client sends the BeamMP server id (`sid`, "pid-vid") with `rlsmpTheftCheck`, `rlsmpTheftStart`, `rlsmpTheftHint`, `rlsmpTheftInspect` and with every scout car. `theft.ownsSid(pid, sid)` refuses when the player number is not the sender's (and, when `MP.GetPlayerVehicles` works, when the sender has no such vehicle). Log: `RLSMP-THEFT refused: not our car id=... sid=... from pid=...`. A modified client can still lie about a sid of its own; it cannot name another player's car. UNVERIFIED: that `MP.GetPlayerVehicles(pid)` keys are the vehicle numbers (the check only refuses when the list is not empty and has neither the number nor its text).
- A player cannot enter another player's converted (stolen) car as a driver: the guard checks "remote" BEFORE the converted set, and the converted set only holds our own ids. As a passenger it is allowed only while the owner drives (section 2).
- The pick stays per game: `lib/theft.stealable(seed, period, perMille, position)` over the car's own spot, server default `theft.perMille = 150` (checked by `tests/theft_test.lua`). The seed is the same for everybody, the cars are only the ones your game spawned.

Log lines to send if it still happens: `RLSMP-THEFT refused` (shows what was refused), `RLSMP-THEFT parked cars known: N`, and `stealable car N nearby` with `RLSMP-GUARD ... beammp=own|remote` for that id.
