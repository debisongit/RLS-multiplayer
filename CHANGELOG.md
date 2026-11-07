# Changelog

Plain list of what changed in each build. The build number shows in the game log (`client loaded, build X`) and the server log.
"Untested" means it passed the automatic tests but nobody has played it yet.

## 0.4.13
- Traffic bubble: a traffic car is only recycled when it is more than 450 m from every other player and none can see it. (untested)

## 0.4.12
- Traffic quota can go back up when a player leaves. Your own traffic setting is restored when you leave the server.
- Traffic is not cut in the middle of a police chase.
- Chase timer in the log uses real time. (untested)

## 0.4.11
- Save download waits for the game to confirm progress, so a busy game is not flooded. Fixes downloads freezing part way (seen at 129 and 153 of 177 pieces). (untested)

## 0.4.10
- Joining a server a second time without restarting the game now starts the mod again (log showed it never started). (joined fine for one player)
- Lost save pieces are asked for again after 4 seconds of silence.

## 0.4.9
- Shared time of day: the server owns the clock, 45 real minutes per day, same shape as RLS's day (quick dawn and dusk). Sleeping no longer changes time. (untested)

## 0.4.8
- A failed or stuck earlier join no longer blocks the next one. If the "world ready" signal is missed, the join starts after 10 seconds anyway. (untested)

## 0.4.7
- Pink-slip duels (`/duel`): loser's car goes to the winner, held safely on the server in between. Off by default, needs a course in `config.json`. (untested)

## 0.4.6
- Event records only count timed races (not derby, burnout, tractor pull).
- Map travel is blocked on both RLS entry points.
- Cars that already went to a fleet are cleared from your garage if a crash brought them back. (untested)

## 0.4.5
- Event records: finished races are reported and the server announces new records. `/records` lists them. (untested)

## 0.4.4
- Adding a car to the fleet checks the server's own copy of your save and blocks adding the same car twice. (untested)

## 0.4.3
- RLS map travel is blocked online (it would drop you from the server). (untested)
- You can ride the taxi RLS hails for you. Optional passenger rides in other players' cars. (untested)

## 0.4.2
- A dashcam on either car always settles a crash.

## 0.4.1
- The join gives up cleanly (with a message) if the save download stalls, instead of leaving you in plain BeamNG.

## 0.4.0
- Dashcams (`/dashcam`, $100 per car), crash judging and insurance claims (dry run: tells you, takes no money).
- Traffic budget grows with the number of players.

## 0.3.4
- Entering other players' cars or AI traffic is refused up front (no more teleport to the default spawn). (untested)

## 0.3.3
- Name tags are hidden on AI traffic. (untested)

## 0.3.2
- `/unstuck` keeps the car's damage. (untested)

## 0.1.0 to 0.3.1
- Server-side saves tied to your BeamMP account, join handshake, RLS starts on BeamMP.
- Server wallet with money categories (loans, sales and transfers are not refused).
- Business / Syndicate: shared bank, members, shared fleet, payout split, fleet retire.
- `/unstuck` for cars and walkers, map gate for `rls_west_coast`, other players' cars are kept when your career starts.
- Install script, build stamp, wrong-map warning, career reset (`rlsmp reset`), start settings locked, cheats refused.
- Traffic director (shared budget) and police anti-teleport (Claude B).
