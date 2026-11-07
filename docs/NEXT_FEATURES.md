# Next features: what is possible and how we would build it

Written from what the BeamMP and RLS code allow (see `docs/RLS_MAP.md`). Nothing here is built yet except where marked.

## 1. "Server-sided" traffic

**Hard limit:** the BeamMP server cannot run physics or AI, and a BeamMP car belongs to the player whose game spawned it
(it cannot be handed to another player). So traffic can never literally live on the server. What we *can* do is make
the server the **boss**: it decides where, when and how much traffic exists, and each game only carries out its orders.

| Wish | Possible? | How |
|---|---|---|
| Traffic doesn't show the player's name | **Done** (build 0.3.3) | `trafficLabels`: each game tells the server which of its cars are AI traffic / parked cars, everyone hides those name tags |
| Spawn anywhere | Yes | Server picks spawn areas (road nodes / zones from the map's data) and tells the player nearest to each area to spawn there. Needs the server to know player positions (BeamMP `MP.GetPositionRaw`) |
| Scales with time of day | Yes | Server owns a world clock; density curve per hour (rush hour, night) is sent as a multiplier on the existing per-player quota (`rlsmpTrafficQuota`) |
| Scales with area | Yes | Zone table (city / highway / rural / port) with a weight each; quota is split by the zone a player is in |
| Nobody's traffic crashes into another player's traffic | **Partly** | Each game's AI cannot see the other games' AI cars well. Reduce it by keeping traffic of different players in different areas (server assigns non-overlapping spawn zones). It cannot be fully solved without shared AI |

Builds on the other Claude's director (`server/traffic.lua`, quotas). Owner: Claude B, I add the name-tag part.

## 2. Dashcams and insurance claims

**Idea:** crashes between players are judged by the server using evidence from both games; the at-fault player's
insurance score drops and they pay out of pocket.

**Evidence:** BeamNG already tracks contacts between vehicles (`map.objects[id].objectCollisions`, which RLS's own traffic
code uses). Every game can see contacts between its own car and any other car, including remote players' cars.
It reports: time, who it touched, both speeds, both headings, positions, whether a red light / lane was involved.

**Server judgement (one incident = two reports within ~2 s):**
1. Who hit whom first (the car whose front/side contact came first, using relative velocity and direction).
2. Rear-end: the car behind is at fault unless the front car reversed.
3. Intersection: red light / wrong side adds fault.
4. Chain accidents: if one car causes contacts with 2+ others within 30 s, fault multiplies ("caused multiple accidents").
5. Penalty: insurance score drop (RLS has an insurance module: driver score, premiums) plus a payout from the wallet
   (server-checked, so it cannot be dodged). Unpaid payouts become a debt on the next login.

**Dashcam:** a real "windshield slot" needs a JBeam part for every car model: heavy, and every player would need the same
car mods. Recommended instead: a **per-car upgrade bought for $100** (chat or RLS shop), saved on the car's record
(like our fleet tag). With a dashcam the car's reports count as admissible *evidence* and give a discount on claims;
without one the server still judges, but only on the other player's report and with less certainty. Open question below.

**Anti-cheat:** reports are checked against both sides; a player who never reports or lies is overruled by the other
report. Server keeps the last 30 s of each report so it can re-judge.

## 3. Dynamic AI traffic (experimental)

All of this is **client-side per game**, seeded and scheduled by the server so players share the same "events".

| Behaviour | How |
|---|---|
| Overtaking, slow drivers, aggressive drivers | Vary the AI parameters per car at spawn (`setAiParameters`: aggression, risk, speed limit factor); RLS already has `setAiParameters` hooks in its traffic vehicle class |
| Drunk drivers | Add weaving + wrong-lane drifting (periodic AI steering offset), triggers a police offense |
| No plate | Clear the plate text on some cars; RLS police `triggerOffense` gets a new `noPlate` offense that starts a pursuit |
| Street racers | A "racer" role that picks another racer and drag-races; reward/offense hooks exist (`events/` has race code) |
| Road events (breakdown, accident scene, roadblock) | Server schedules an event at a road node and tells the nearest player to place props + cars (RLS has prop/roadblock code in `police.lua`) |

Risk: more AI per game = more CPU. Needs the quota system above and a global on/off switch.

**Built (untested in-game): driver personalities** (`config.smartTraffic`, server `smartTraffic.lua`, client `personalities.lua` +
`lib/personality.lua`, event `rlsmpSmartTraffic`). Built-in AI settings only: normal 80 / slow 10 / aggressive 6 / racer 3 / drunk 1,
everyone keeps their lane except the drunk's short weaves; nearby AI police may chase racers and drunks (`policeReact`, one per minute per game).
No plates, street-racer pairs and road events are still open.

## Decisions made (by the owner)

- Dashcam = $100 per-car upgrade. **Built** (`/dashcam`).
- A crash without a dashcam is still judged, but "caught" is a gamble that depends on the cars around. **Built** (35% base, +15% per car nearby up to 3, +40% if either car has a dashcam, 100% if both).
- Penalty follows the damaged parts (RLS's own per-part repair price), paid by the at-fault player and recorded as an RLS insurance claim. **Built, dry run first** (`claims.dryRun`).
- Traffic scales with the players online, a little more than before. **Built**: budget = 30 + 10 per player, up to 18 cars per game (was a fixed 40 / 15).

## Suggested order

1. Test the current build (join, garage, business, fleet, /unstuck, payout split, name tags).
2. Server-directed traffic: time-of-day and zone scaling (small, builds on the quota).
3. Collision reports and the incident judge **without** money first (log only), so we can see how fair it is.
4. Dashcam purchase, insurance penalty, payouts.
5. Dynamic AI personalities, then road events.

## Questions for the owner

1. Dashcam as a $100 per-car upgrade (simple, works with any car) or a real windshield part (heavy, needs a JBeam mod)?
2. Should a crash with **no** dashcam still be judged (just less certain), or only crashes where at least one car has one?
3. Penalty size: score drop per at-fault incident, and payout = a percentage of the other car's repair cost?
4. Should traffic density also react to the number of **real** players online (fewer players = more AI), or stay fixed?
