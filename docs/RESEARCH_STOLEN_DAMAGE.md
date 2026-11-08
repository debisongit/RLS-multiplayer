# Research: damage of a stolen car

Owner rule: a stolen car can only be sold when it is NOT damaged. If it is damaged you can only strip it.
"Verified" = read in the RLS source copy (read only). "Guessed" = not seen in a running game.

## How RLS measures damage (verified in source)
There are two different ideas in RLS:

1. **Live damage number of a spawned car**: `map.objects[vehId].damage` (BeamNG's own running damage total). Used by
   - `events/utils.lua getVehicleDamage()` (race rewards, host sessions): `map.objects[playerVehicleId].damage or 0`.
   - `career/business/racingTeam/racingTeam/fleet.lua`: `info.damage = objectData.damage`, `info.locked = damage >= threshold` (default threshold 1000, `racingTeam/ui.lua` `vehicleDamageThreshold = 1000`).
   - `integration/ownedServices/trafficVehicle.lua`: `self.damage = map.objects[id].damage`, a traffic car "respawned with big damage" at 500; police role `highDamage`.
   - Derby (`derbyParticipants.getVehicleDamageNormalized`): raw / 50000 x 100 for a display bar (50000 is the "totally destroyed" display maximum, too coarse for a sell rule).
   - Tuning shop `views.lua getVehicleDamageByVehId`: same field.
2. **Broken parts of an inventory car**: `valueCalculator.getRepairDetails` / `brokenParts.find(invVehInfo, partInventory)`, `partConditionsNeedRepair` = at least `brokenPartsThreshold` (3) parts with `integrityValue == 0`. This is what the Marketplace, repair quotes and repo use. It needs an RLS inventory vehicle with part conditions. A stolen car is **not** in the RLS inventory (our own record plus a local car), so this path does not apply.

`valueCalculator.lua ~1125` also has `opts.damageAdjustment` (money subtracted from the book value); it is a price, not a 0..1 number.
Also seen: `quarry/manager.lua` reads `beamstate.damage` and `beamstate.getPartDamageData()` inside the vehicle (needs a Lua round trip, not used).

## What we use
`map.objects[id].damage` of the live stolen car, divided by `SCALE = 1000` and clamped to 0..1, rounded to 2 decimals (`lib/stolenDamage.lua`). Reasons: it is a global read (no callback into the vehicle thread), it exists for every spawned car, and RLS itself uses it for "this car is too damaged" decisions (racing team lock at 1000, wrecked traffic at 500).
- **Verified**: the field exists and is read this way in RLS; the 1000 and 500 thresholds are RLS's.
- **Guessed**: that 1000 is a good "100 percent". A small dent might be 20 to 100 raw (2 to 10 percent), a hard crash several hundred. The sell limit 0.15 therefore means about 150 raw. The scale is one constant (`SD.SCALE`); ask the owner for the percentage shown after a bump and after a crash and adjust.
- **Guessed**: that a freshly spawned car reports 0 (a parked traffic stand-in that was converted keeps its own number; the theft convert respawns the car, so it should start at 0, but a car that was already dented in the world could start higher).
- Not damage: tyres, engine wear and soft faults (`career/repair/finiteDamage.lua`) are not counted.

## Rules (server, `fence.*`, all in the `[` menu and `trafficAdmin.lua`)
- `maxSellDamage` 0.15: above it Sell, Resell, Marketplace meetup and black meetup of that car are refused ("Too damaged to sell: strip it."). Strip stays.
- `damageStripPenalty` 0.5: strip pays `stripRate x value x (1 - penalty x damage)` (stolen cars only; own garage cars are not affected).
- `damageFreshSeconds` 120: a sale needs a report younger than this ("Stand next to the car so it can be checked."). Strip needs no report.
- The client measures only a car within 80 m of the player, so a report means the owner's game really sees the car.
- The server stores `rec.damage` and `rec.dt` only on the sender's own record. A report within 2 s of the previous one counts only if the damage rose. The file is saved when the damage changes by 5 points or crosses the limit.

## Restore
A recalled or auto-restored stolen car is a newly spawned, undamaged car. The restore spec carries `damage`, the client keeps it on the car (`rec.damage`) and `damageOf` uses the larger of live and recorded, so a wreck cannot be repaired by recalling it. There is no way to repair a stolen car on purpose (no sell path for a wreck, so strip it).

## Limits
- The damage is the client's word. A modified client can report 0. Same trust level as the car value (capped server side); the server only enforces freshness, ownership and rate.
- The 2 minute freshness means the app must be open or a request made near the car; the app sends a report on every poll while the car is within 80 m.
