# Research: fake plates on the player's own cars (read from RLS source, nothing played)

RLS source paths are relative to `lua/ge/extensions/overhaul/`. "Verified" = I read the code. "Guessed" = needs a game test. Build: `rlsmp/fakePlate.lua`, `server/fakePlates.lua`.

## How RLS stores a car's plate (verified)
- Record: `overhaul_career_garage_inventory.getVehicles()[inventoryId].config.licenseName`. Set once from the live car when a car is added (`career/garage/inventory/bindings.lua:66`) and by `setLicensePlateText` (`operations.lua:203-210`, used by the $300 plate shop `purchaseLicensePlateText` and the car shop `purchase.lua:384`, `spawn.lua:333`). It is saved with the career (the inventory record).
- Part edits keep it: `career/parts/partInventory.lua:352-355` copies the old `licenseName` onto the new config when it rebuilds the config from the live car. So a fake plate written to the record survives part shop visits.
- Live car: dyn field `licenseText` (`vehicles/licensePlates.lua:28`), read by `core_vehicles.getVehicleLicenseText(veh)` (speed cameras use it, `career/police/speedTraps.lua:61`). `vehicles/licensePlates.lua refreshPlate` re-applies the plate on spawn: it reads the dyn field, clears it and calls `core_vehicles.setPlateText(text, vehId)`, retried a few times until the plate material is ready. `setPlateText(text, vehId)` is what changes the plate texture; RLS calls it the same way in `operations.lua:207` and `setup.lua:445`.
- Plate rules: RLS allows 1 to 10 characters (`operations.lua:225`) and checks `core_vehicles.isLicensePlateValid`.
- **RLS bug (verified, `operations.lua:204-209`)**: `setLicensePlateText` tests `if inventoryId` instead of the vehicle id, so for a car that is not spawned it calls `core_vehicles.setPlateText(text, nil)`. We call RLS's function only when the car is spawned; otherwise we write the record ourselves.

## What we did
1. The server picks 3 random plate texts (`digit + 3 letters + 3 digits`, no I O Q, e.g. `7KTB482`; our own generator, see "guessed"), the player chooses one in a popup (`showConfirmationDialog`, same as the other garage popups).
2. `rlsmpFakeFit`: the server takes one `fake_plate` item and stores in the profile which car (RLS inventory id, model) wears which fake plate and what the real plate was. Server-authoritative; the client changes the plate only after `ok`.
3. Client `applyPlate`: RLS's `setLicensePlateText` for a spawned car (record + texture), the record directly for an unspawned car, plus the dyn field, then `overhaul_career_saveSystem.saveCurrent()` and `computer.refreshMenu()` (what RLS does after a plate purchase).
4. Survives saves, respawns and the part shop because the RLS record itself holds the fake plate. A check every 3 s (`L.decide`) writes the fake plate again if the record or the live car shows the real plate (at most 5 tries per record), and forgets the record (`rlsmpFakeDrop`) when the car is gone from the garage for 3 checks or the player changed the plate another way (plate shop). The first check is 20 s after the server's state (RLS loads its garage first).
5. After a rejoin the server pushes the records (`rlsmpFakeState`); `rlsmp_fakePlate.isFake(vehId)` compares the live plate with them, so `rlsmp_theft.hasFakePlate` is true again without any extra step.

## Police effects
- Radar and red-light cameras, chase citation and arrest fine: no fine while `hasFakePlate` (own car, live plate = a fake plate). The chase itself and the plate flag on a chase end still happen. `police.lua`: the existing wrappers, `inStolenCar()` got the fake plate case.
- Plate reading: the police read the plate on the car, so the lookup is for `fake|model`. That record is separate and clean. The flag on the real plate is not read while the fake plate is on and stays on file until it expires (2 h). A flag raised while wearing the fake plate attaches to the fake plate. Restoring clears the fake plate's record only.
- The swap must not wipe the real flag: the client reports a plate change (`rlsmpPlateChanged`, existing garage-car watch). `plateRecords.onChanged` now ignores a change when the old or new plate belongs to a fake plate record of that player.
- Fake plate found risk: the 20 minute model + colour memory (per player) is checked after the plate record, so a cop reading the fake plate can still chase a car that matches a recent chase. Repainting clears it. No new rule was needed; a test covers it.
- Marketplace sale (meetup): a car whose plate is one of the seller's fake plates is "illegal papers" for the setup roll; legal cars stay at 0.

## Verified vs guessed
Verified (read in source): where the plate lives (`config.licenseName`, dyn `licenseText`), the part shop keeps `licenseName`, `setPlateText(text, vehId)`, the unspawned-car bug, the 1 to 10 character rule, `getVehicleIdFromInventoryId` / `getInventoryIdFromVehicleId` exports, speed camera reads the live plate.

Guessed (needs a game test):
- That RLS spawns a car from the inventory with its `config.licenseName` as the plate text. I did not find that line (the spawn code may take `licenseName` from the config table through BeamNG's own spawn). The 3 s check is the safety net.
- That `core_vehicles.setPlateText` changes the visible plate immediately and `licensePlates.lua` does not undo it.
- **That other players see the new plate.** BeamMP syncs the vehicle; whether the plate text (a dyn field and a texture drawn by the game) is part of that is not known. If not, other players still see the old plate; the server and police logic does not depend on it (the police read the plate on the owner's own game).
- The plate generator: vanilla BeamNG has its own plate generator (`core_vehicles.regenerateVehicleLicenseText` or similar), which is not in the RLS source. We use our own format; `isLicensePlateValid` is not called by the server. The client does not check it either; if a plate were refused by RLS the fit fails and the item is given back (`failed`).
- That `getStatusForTag({"vehicleLicensePlate", "vehicleModification"})` is the right permission (taken from `career/garage/inventory/ui.lua:505`).
- A car sold or traded away while wearing a fake plate keeps the fake plate text; the record is dropped by the 3 s check.
