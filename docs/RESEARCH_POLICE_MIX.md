# Research: why the police look the same (Bastion, undercover)

Read-only look at the RLS source (`rls_career_overhaul`). Anything marked **unverified** I could not see (the game's own vehicles folder is not available here).

## How the police group is built
- `overhaul/integration/services/police.lua` registers the police "special vehicle provider". Its `buildGroup(count, options)`:
  1. if `options.autoLoadFromFile` (career `playerDriving.lua` line ~270 always sets it to `true`) or the game setting `trafficSmartSelections` is on, it loads the level's **`police.vehGroup.json`** with `gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'police'})`, shuffles it and calls `core_multiSpawn.fitGroup(fileData, count)`;
  2. only when there is no file it calls the game's `gameplay_traffic_trafficUtils.createPoliceGroup(count)` (unverified, it is vanilla: I expect it to call `core_multiSpawn.createGroup` with the `Config Type` filter `police`);
  3. if that is empty, `count` x `{model = 'fullsize', config = 'police'}`.
- Group size is `ceil(totalTraffic * 0.05)` (`getDesiredCount`), so a police group is only 1 to a few cars.
- So on rls_west_coast the police normally do NOT go through `createGroup` at all (our old wrapper never saw them, and it skipped police anyway). `trafficConfigFilter.lua` only filters `createGroup` batches; for police intent (`Config Type` police > 0 and `other` 0) it keeps every entry (police pool).

## What the map offers
`levels/rls_west_coast/police.vehGroup.json` ("West Coast USA - Police") has 5 entries, **all model `bastion`**:

| config | undercover? |
|---|---|
| `police_v8_awd_A` | no (marked). No `.pc`/`info` file in RLS: probably a vanilla config (unverified) |
| `police_unmarked_v8_awd_A_Red` | yes (unmarked) |
| `police_unmarked_v8_awd_A_Silver` | yes (unmarked) |
| `police_unmarked_v8_awd_A_Blue` | yes (unmarked) |
| `undercover_redtail` | yes (undercover) |

Result: 5 of 5 cars are Bastions and 4 of 5 (80 percent) are unmarked or undercover. That is the "samey" look.

## Police configs RLS ships (`vehicles/bastion/info_*.json`, `Config Type: Police`)
| config | Population value | note |
|---|---|---|
| `police_redtail` | 500 | marked, not in the vehGroup file |
| `police_v6_awd_A` | none | marked, not in the vehGroup file |
| `police_unmarked_v8_awd_A_Red/Silver/Blue` | 2000 each | unmarked |
| `undercover_redtail` | 100 | undercover |

Counts: 6 police configs, all Bastion (2 marked, 4 unmarked/undercover). RLS ships no other police model. Other Bastion configs (joes_junk, roller, used_and_abused) are not police.
Default traffic: `trafficConfigFilter` rejects Config Type `Police` and names containing `police` for normal traffic, so the Bastion police never appear as civilians.

## Vanilla police cars (unverified)
BeamNG itself ships police configs for several models (for example the `fullsize` police, and `Config Type: Police` configs of other cars); RLS's fallback uses `fullsize/police`. I cannot list them here. The client now logs `police pool: N configs: model=count, ...` once per session, from the game's own model list (Config Type "Police", spawnable, passes RLS's filter): send that line to see the real counts.

## What we changed (untested in game)
`rlsmp/trafficVariety.lua` (+ `lib/trafficVariety.lua`) now also wraps `core_multiSpawn.fitGroup`: when RLS hands it a group where every entry is a police config (the file group), we build the group ourselves from the police pool with the server's `trafficVariety.police` settings; the same re-pick is used for a `createGroup` call with police intent. Anything odd (no pool, error, all weights 0, setting off) gives the game its own group. Existing police cars and chases (`rlsmpHold`) are not touched; only newly built groups change.
- `models`: weight per police model (default `bastion = 0.3`, missing = 1, 0 = never).
- `undercoverShare` (0.1): config names containing a word of `undercoverWords` (`undercover`, `unmarked`) count as undercover. Groups are tiny, so the cap is rounded at random (2 cars x 0.1 = 0.2 undercover: one in five groups may have one).
- `maxShare` (0.4): most of one model in a group (relaxed when too few models exist).
- If the game has no police model besides the Bastion, groups are still all Bastions (just fewer undercover); more variety then needs a police car mod (put the zip in the server's Resources/Client; mods are not added to the police pool automatically unless their configs have Config Type Police).
- Unverified: `fitGroup`'s signature `(group, count)` (we pass extra arguments through), and that the vanilla police configs have `Config Type = Police`.
