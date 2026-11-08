# Research: a "Strip" button in RLS's own garage (read from RLS source, nothing played)

Paths are relative to `lua/ge/extensions/overhaul/` in the RLS source. "Verified" = I read the code. "Not verified" = needs a game test.

## How the garage computer asks for buttons (verified)
- `career/garage/computer.lua` `rebuildMenuData` builds `menuData` (`computerFacility`, `vehiclesInGarage = {{inventoryId, vehicleName, ...}}`) and two tables: `computerFunctions.general[id]` and `computerFunctions.vehicleSpecific[inventoryId][id]`. Then it calls `extensions.hook("onOverhaulComputerAddFunctions", menuData, computerFunctions)`. **Every loaded extension that has that function gets called**, so our own extension can add buttons without editing any RLS file.
- A button is a table `{id, label, order, callback, disabled?, reason?, routeTarget?}`. `routeTarget` is only for buttons that open an RLS screen. RLS's own "Maintenance" button (`career/maintenance/maintenanceComputer.lua:259`) has **no routeTarget**, just `callback`, so a Lua-only button is an accepted pattern. `reason = {type = "text", label = "..."}` shows why a button is greyed out (`disabled = true`).
- The screen (`ComputerMain.vue`) lists `vehicleSpecific[activeInventoryId]` tiles first, then `general`, and calls `computerButtonCallback(id, inventoryId)` -> `computer.lua computerButtonCallback` -> our `callback`.
- Per-car buttons exist only for cars in the **closest garage** (`getInventoryIdsInClosestGarage`). A stolen car that is not in the inventory never gets a per-car button.
- Guard used by RLS: `menuData.computerFacility.functions["vehicleInventory"]`. We use the same guard.
- The hook runs while RLS builds its screen. An error in it could break the whole garage screen, so our hook is wrapped in `pcall`.

## Removing a car from the RLS inventory (verified)
- `career/garage/inventory/bindings.lua:235` `removeVehicle(inventoryId)`: refuses while a delivery job needs the car (`canRemoveLogisticsVehicle`), discards damage state, deletes the object, clears the record, fires `onOverhaulVehicleRemoved`, refreshes the UI. Exported as `overhaul_career_garage_inventory.removeVehicle`.
- `career/parts/partInventory.lua:782` `onOverhaulVehicleRemoved` **deletes every part whose `location` is that car**. So stripping a car also removes its installed parts. The payout is **cash only**: no parts are handed to the player (RLS has no strip feature, `junkVehicle` is only a permission tag).
- `sellVehicle` (`operations.lua:63`) pays RLS's price through `removeVehicle`; we do **not** use it, we pay from the server wallet. After `removeVehicle` the client calls `overhaul_career_saveSystem.saveCurrent()` and `overhaul_career_garage_computer.refreshMenu()` (the same two things RLS does after a sale).
- Safety checks we run before asking the server: `v.owned ~= false`, no `timeToAccess` (rented / unavailable), no `listedForAuction`, `overhaul_career_permissions.getStatusForTag({"vehicleSelling"}, {inventoryId})`, and `canRemoveLogisticsVehicle`. Not verified: whether financed or loaned cars are blocked by the `vehicleSelling` tag (I did not read the loan code). If they are not, a player could strip a car they still owe on.

## Stolen cars are NOT in the RLS inventory, on purpose
`docs/RESEARCH_PLATES_THEFT.md` shows a way to add one (`addVehicle`). I did not, for three reasons: (1) RLS's own Sell button would then pay full value and skip the fence; (2) RLS's plate change (`purchaseLicensePlateText`, $300) would change the plate our server record is keyed on; (3) it needs a free inventory slot. So the stolen car gets its own **general** button, "Stolen car: PLATE", shown while one of our stolen cars is within 60 m of the player. Both buttons open the same dialog.

## Dialog (not verified)
The choice (strip, fit a part) uses the vanilla guihook `showConfirmationDialog {text, buttons = {{label, luaCallback, enabled}}, class = "recoveryPrompt"}`. RLS's own debug code (`dev/debug/vehicleSpawn.lua:129`) uses exactly this shape, but I found no use in normal play. Not verified: whether the dialog closes by itself after a click, whether the text shows line breaks. A refusal from the server is shown as a toast. A `luaCallback` is a plain Lua string (we call `rlsmp_garage.choose("strip")`; the argument is one of our own fixed words and is checked again in `choose`). The chat command `/fence` stays as the fallback.

## Items in the RLS inventory: what is possible, what I did
RLS has no item inventory. The closest thing is the **part inventory** (`career/parts/partInventory.lua`): `partInventory` is a plain table `partId -> part`, `addPartToInventory(part)` (exported) inserts one, and the "My parts" screen lists everything. I could have made fake parts and decided **not to**, because of risks I cannot test:
- `sellParts` pays RLS cash for any part in storage (`location 0`): a fake part with a value is a money leak.
- The list UI (`sendUIData`, ~line 545) calls `getPartResaleValue`, `getVehicleModelDisplayName(part.vehicleModel)` and `core_vehicle_partmgmt.getTranslation` on part fields. A part without a real jbeam path may throw and break "My parts" for the whole career.
- `updateVehicleMaps` indexes by `part.containingSlot` (a nil key would crash it).
- The part inventory is saved in the RLS save (`career/partInventory.json`) and our save sync uploads it, so a bad entry stays in the save, and vanilla would read it without our mod.

What the build does instead: the server profile (`profile.items`) stays the only truth, and the garage screen has a general button **"Black market items"** that lists the items (the per-car dialog lists them too). That is the closest safe thing inside RLS's garage screen. If the owner wants them inside "My parts", the next step is a test in a throwaway career with ONE part flagged `rlsmpItem = true`, value 0, `containingSlot = "rlsmp_<name>"`, rebuilt from the server list on every join.

## Fitting parts (design in this build)
Fitting a fake plate / VIN plate / part number kit onto a **stolen** car is a server action: the item is used up at once and the stolen record gets `papers[name] = true` (saved in `stolen.json`). It does **not** change the plate text on the car, and nothing is installed in the RLS part tree (a part number swap has no RLS counterpart). The fence (`/fence resell`, `gamble`) counts fitted papers first, then items the player still carries. A real plate change would clear the police flag (design doc) but needs re-keying the theft record and the plate record; left for later.

## Money authority and its limit
- Stolen car: the value comes from the server's own theft record. Fully server side.
- Ordinary garage car: the server has **no copy of the RLS inventory**, so the value is the client's word (`getInventoryVehicleValue`). It is capped by `fence.maxValue`, paid at `stripRate` (30%, below what RLS's Sell pays), rate limited (`fence.garageCooldown`, 20 s) and logged. A modified client can still invent cars; the real fix needs a server copy of the inventory (not built).
- If the server pays and RLS then refuses to remove the car, the player is told to contact the server owner (and it is logged). The pre-checks above are there to make that rare.

## What I could not verify
All game behaviour: that our hook is called and the tile shows, the dialog, `removeVehicle` from our side, the permission tag on loans, and that `vehicleSpecific[inventoryId]` exists for each listed car at hook time (RLS creates it just before the hook, so yes by the code).
