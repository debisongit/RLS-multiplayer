# Research: plates, paint, police, parked cars, garage, parts, items (read from RLS source, nothing played)

RLS source paths below are relative to `lua/ge/extensions/overhaul/`. "[BeamNG]" = vanilla behaviour not checked. Plan decisions are in `DESIGN_THEFT_PLATES_TRAFFIC.md`.

## Plates and identity
- Live car: dyn field `licenseText` (`integration/services/parking.lua:852`, `vehicles/licensePlates.lua:27`, `core_vehicles.getVehicleLicenseText(veh)`). Inventory record: `vehicles[id].config.licenseName`.
- Change: `purchaseLicensePlateText(inventoryId, text)` ($300, owned cars only, 1-10 chars) in `career/garage/inventory/operations.lua:217-237`; `setLicensePlateText` at `:203`. **Bug at `:206`**: checks `inventoryId` instead of `vehId`, can hit the wrong car for an unspawned car.
- No VIN. Inventory ids are reused (lowest free integer). A stable id exists as `financeId` (`lib/vehicles/financeIdentity.lua`, created lazily; call its ensure yourself). Plates are not unique and can be bought, so key a police flag on plate + model, with our own VIN field (store inside the record table, the save keeps whole records).

## Paint
- Inventory: `record.config.paints` (up to 3 tables, `baseColor`...). Live car: `obj.color`, `obj:getMetallicPaintData()`, `colorPalette0/1`. Paint shop: `career/parts/painting.lua` (`apply` writes config.paints and respawns).
- **AI cars get a new random paint when re-parked or re-spawned** (`parking.lua:169-171`, `trafficVehicle.lua:692-694`): capture colour at theft time.

## Police
- Offense keys: speeding, racing, reckless, wrongWay, intersection, hitPolice, hitTraffic (`integration/ownedServices/trafficVehicle.lua:549-616`). Only checked while `pursuit.policeVisible`.
- No stolen/wanted-plate/plate-scan concept exists. "Wanted" = pursuit heat only.
- Per unit knowledge: `role.validTargets[id] = {dist, interDist, visible}` (`ownedServices/trafficPoliceRole.lua:265-294`), visible = within 100 m and a ray cast. `getNearestPoliceVehicle`, `getPoliceVehicles` in `integration/services/police.lua`.
- **Instant pursuit hook**: `gameplay_traffic.getTrafficData()[vehId]:triggerOffense({key='stolenVehicle', score=X})` (X>=200 raw reaches mode 1, ~1200 jumps toward mode 2), or `overhaul_integration_services_police.setPursuitMode(2, vehId, {policeId})`. New offense keys need a translation `ui.traffic.infractions.<key>`.
- Evade ends with `setPursuitMode(0)` -> `resetAll()` which **wipes the whole pursuit table**. A wanted flag must live outside it and have its own re-trigger cooldown or the chase restarts in a loop. Cooldown after pursuit end per unit: max(10, arrestTime+5) s. evadeTime 40, evadeRadius 80, arrestTime 5, arrestRadius 15.

## Parked cars
- Spawned by `integration/services/parking.lua:1208-1316` (group `autoParking`, `propparked` configs, paint randomised); each gets `playerUsable=false`, dyn fields `ignoreTraffic`, `isParked`, walk blacklist, pool `overhaulParking`, ignition level 0. No locks or keys.
- Parked configs may be undriveable shells (engine/wheel checks skipped, `integration/patches/trafficConfigFilter.lua`). "simplified" models only handled for traffic; **no code switches simplified to full physics at runtime**.
- Evidenced way to make a driveable car: snapshot model, config, pos, rot, 3 paints, `licenseText`; delete the parked object; `core_vehicles.spawnNewVehicle(model, {config, pos, rot, ..., licenseText, autoEnterVehicle=false})`; then `be:enterVehicle`. Map `simple_traffic` models to the real model. Do not use `parking.removeVehicle`. Never keep `isParked="true"` on the new car; set `ignoreParking=true`.
- Entry gates: `avatar/walkEnterVehicle.lua:114-122` (playerUsable, blacklist, active). Our `rlsmp/vehicleGuard.lua` `isBlocked` blocks remote cars, AI traffic and parked cars; a steal exception goes there (`:12` comment).

## Adding the car to the garage
- `overhaul_career_garage_inventory.addVehicle(vehId, inventoryId|nil, {owned, year, finalPrice, takesNoInventorySpace, starter, ...})` (`career/garage/inventory/bindings.lua:150-188`), returns nil when no free slot. Parts arrive later (`onOverhaulAddedVehiclePartsToInventory`). Precedent: `career/market/auction/registration.lua:286`.
- Value: `career/market/valueCalculator.lua` `getQuickVehicleValue(baseValue, year, mileage)`, `getInventoryVehicleValue(id)`. Base value and year from `core_vehicles.getConfig(model, configKey).Value/.Years`.

## Parts
- `career/parts/partInventory.lua`: parts have `value`, `location` (inventory id, 0 = storage). `removePart` is local, not exported; `sellParts(ids)` pays 0.55 of depreciated value but only for parts with location 0. No strip-car feature exists, `junkVehicle` is only a permission. Part-out value: sum of resale values, or jbeam `information.value` x 0.55.

## Items
- RLS has **no item/tool inventory**. We must create one (store server-side in the profile). Selling surface: a new phone app (`gameplay/overhaul/phone/apps/*.json` + `ui/ui-vue/mods/<mod>/phoneApps/*.js`, `lib/phone/appCatalog.lua`) or the `onOverhaulComputerAddFunctions` hook. Payment: `overhaul_career_economy_payment.pay` / `playerAttributes.addAttributes({money=x}, reason)`; use a distinct money reason/category for theft income so the server wallet treats it right (`sellVehicle` posts a `vehicleSold` tag).

## Multiplayer risks
- Police, traffic, parking are per client; a player can only steal parked cars their own client spawned; other players' cars are never police targets on my client. BeamMP cannot hand a car over (delete and respawn). Drop `hideNametag` handling for a converted car in `trafficLabels`.
- Hooks needed: (a) plate reading: ~0.5 s loop on the police `validTargets[myId].visible` + distance, read plate, ask server flag, trigger offense; (b) steal: vehicleGuard exception + convert function + record (plate, model, colour, value, time); (c) sell/strip: pay `getQuickVehicleValue x factor` with own label then delete, or `addVehicle` then strip parts.
