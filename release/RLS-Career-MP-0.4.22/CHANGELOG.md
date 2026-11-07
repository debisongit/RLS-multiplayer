# Changelog

Plain list of what changed in each build. The build number shows in the game log (`client loaded, build X`) and the server log.
"Untested" means it passed the automatic tests but nobody has played it yet.

## 0.4.22
- Crash claims: a crash that ends without a verdict now tells you why (chat and server log), instead of nothing happening: scrape under the impact speed limit, another claim too soon after, missing data. Both games log `RLSMP-CLAIMS` lines and the server logs every `[claims] report`. The client also notices contact when only your own car has the collision flag. NOTE: `claims.dryRun` is still true in `config.json` by default, which only SHOWS "TEST MODE ... pays $X" and moves no money; set `claims.dryRun` to false in the server's config.json to make it real. (untested)
- Review fixes: the duplicate-car cleanup never deletes a car bound to a garage slot (two owned cars can share a plate); police units tied to your chase are held back from recycling without switching RLS's own chase logic off; the traffic bubble only checks cars RLS is about to recycle and ignores line of sight beyond 1 km; stuck-car recycling skips cars with respawn off; replace-vehicle guard no longer loops (freeze) and refuses other players' cars. (untested)

## 0.4.21
- Shared weather: everybody now sees the same weather. Before, each game ran its own RLS forecast (made from the player's own save). Now the server picks one of RLS's six conditions (clear, partly cloudy, overcast, drizzle, rain, storm) from its own clock, like the shared time of day: it glides smoothly through the conditions in between, a new random target every 15 real minutes, with the mix set in the server config (`weather`). Every game tells RLS to show it with RLS's own `forceCondition`, so rain, wet roads and tire grip stay consistent with what you see. `weather.force` pins one condition for everybody (handy for testing). RLS's own "Rain approaching" phone notifications (from the local forecast) are switched off. Still local: RLS's morning fog, temperature, thunder timing and weather app; changes snap instead of fading. (untested)

## 0.4.20
- Traffic variety, step 2 (live swapping), safe first version: a traffic car that nobody can see (not on your camera, not near or visible to another player, never police, taxis, pursuits or jobs) can be swapped for a model that suits the current road class and time of day better. Two switches in the server config under `trafficVariety.swap`, both OFF by default: `enabled` only watches and logs "swap would happen ..." (changes nothing), `live` really replaces the car (experimental, never tried in the game; it switches itself off after 3 failures). At most 2 swaps per minute. With default weights nothing is ever swapped, because every car weighs the same. Log tag `RLSMP-P3`. (untested)

## 0.4.19
- Traffic variety, step 1: traffic and parked cars use more varied models and configs. Each game builds its groups from a bigger pool, no model fills more than 25% of a group, and the server can weight car Types, road classes (city, main, highway), day and night, and add cars from mods the server ships (`trafficVariety` in the server config). Nothing is excluded beyond what RLS already refuses. Cars keep their model once they exist, so area and time only apply to cars built from now on; live swapping while you drive is step 2. Log tag `RLSMP-P3`, design in `docs/DESIGN_TRAFFIC_VARIETY.md`. (untested)

## 0.4.18
- Part shop fix: buying or removing a part at your garage computer no longer spawns a second car. BeamMP's "replace vehicle" ignores which car RLS names and replaces the car YOU are in; in the shop you stand on foot, so it replaced your walking character and left the shopped car behind, still frozen ("a fake car you can hop in but can't drive"). Now the named car is replaced in place. Log tag `RLSMP-REPLACE`. This is the cause behind the duplicate car that 0.4.17 cleans up, so after this build no copy is left behind and that cleanup is only a safety net. (untested; the missing power steering may be a separate problem)

## 0.4.17
- Duplicate car after changing parts: when RLS replaces a car, a leftover copy (same model and plate, not the car RLS keeps) is deleted after 4 seconds. Never the car you sit in or other players' cars. This heals the symptom; the real cause (the old car not being removed on a part change) is not found yet. Log line: `dedupe: deleting stale copy`. (untested)

## 0.4.16
- Stuck traffic: an AI car that has not moved for 30 seconds (honking, jammed) is recycled by RLS, one car every 5 seconds at most. Never a car you can see, never one near or visible to another player, never police, job or chase cars. (untested)

## 0.4.15
- Smart traffic: AI cars get driver personalities (default mix 80% normal, 10% slow, 6% aggressive, 3% racer, 1% drunk, all in `config.json` under `smartTraffic`). Drunk drivers weave and brake hard, racers drive fast. All keep their lane. No hints, you spot them by how they drive. Cops react to racers and drunk drivers (at most one chase per minute). Off switch: `smartTraffic.enabled`. (untested)

## 0.4.14
- Police: only the cops tied to your chase are frozen (the one that sees you, the roadblock unit, any police within 300 m), others stay free. Our police wrappers survive RLS replacing the functions. (untested)
- Each game reports its position and chase state to the server every few seconds (`/where` shows what the server has). Groundwork for server-directed traffic. (untested)
- Shared dealership stock: the server can give everyone the same listings. Off by default (`shop.shared`); new listings still differ per player and sales are not live yet. (untested)

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
