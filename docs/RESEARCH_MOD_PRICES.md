# Research: car shop prices of modded cars

Owner report: some mod cars the server ships cost far too little or far too much in the RLS car shop. Decision: automatic price from the specs, car shop only.
Source read (read only): `rls_career_overhaul` at commit of the scratchpad copy. "Verified" = read in that source. "Guessed" = not checked in a running game.

## How RLS builds a shop price (verified)
1. `vehicleShopping/catalog.lua` `prepareDealershipCache` takes every config from `util_configListGenerator.getEligibleVehicles()` and passes it through the dealership filter. Mod cars are in that list like any other.
2. Each kept entry goes through `validation.normalizeVehicleCatalogValue`: `Value` becomes `valueCalculator.getVehicleCatalogProfile(model, config).catalogValue`.
3. `catalogValueFor` (valueCalculator.lua ~844): **the catalog value is the SUM OF THE CAR'S PART VALUES** (`getVehicleCatalogProfile` -> parts catalog). The jbeam/info `Value` is used only when fewer than 3 parts have a value (`MIN_PC_PARTS_FOR_PARTS_CATALOG`) or the sum is 0. So the mod author's mistake is usually in part values (jbeam `information.value`), not in the car's `Value` field.
4. `vehicleShopping/stock/listings.lua` -> `stock.lua populateListingPrice` (line ~125) calls `overhaul_career_market_valueCalculator.getVehicleValuation({catalogBaseValue, mileageMeters, age, modelName, configKey, configInfo, logContext = "updateVehicleList", ...})`. The result's `bookValue` is the base; then a seller range and negotiation multiplier (0.88 to 1.12) and rounding give the listing `Value`.
5. `getVehicleValuation` (line ~1200): `catalogValue = profile.catalogValue` (the `opts.catalogBaseValue` is used ONLY if the profile value is 0 or less), then age/mileage/halo factors; floors are proportional to the catalog value (`catalog * 0.05`, parts floor `catalog * 0.30`) plus an absolute 500.
6. `logContext == "updateVehicleList"` is passed only by `stock.lua` (grep of all callers). Repo jobs, auctions, racing team and car meets use other contexts.
7. Selling or valuing an OWNED car: `getInventoryVehicleValue` / `getQuickVehicleValue` call the file-local `getVehicleValuation`, **not** `M.getVehicleValuation`. A wrapper on the exported function cannot reach them.

## Where a mod car's price comes from (verified)
Parts sum (usually) or the config `Value` (sparse parts). Both are whatever the mod author typed. Nothing in RLS checks them against power or weight. `Source` in the info files is `"Custom"` for RLS's own extra configs on vanilla models; it is not a reliable "is a mod" flag, so it is not used.

## The hook (verified design, untested in game)
Wrap the exported `overhaul_career_market_valueCalculator.getVehicleValuation` (stock.lua calls it through the global, so a wrapper is seen). We let RLS compute, then, only when `opts.logContext == "updateVehicleList"` and the model is a mod, scale `bookValue`, `preDamageValue`, `partsValueFloor` by `estimate / valuation.catalogValue` and set `catalogValue`, `catalogSource = "modPrice"`. Why scale instead of passing our value in: the profile's value wins over `opts.catalogBaseValue`, so passing it in does nothing. Scaling keeps RLS's own age and mileage curve. The wrapper is registered with `wrapperLifetime.registerForwarder` and re-checked every frame (`install()` in `onUpdate`), like the other wrappers. Any error, missing spec or missing server settings returns RLS's own record unchanged.
Listings made before the server settings arrive, or saved from an earlier session, keep their price until the shop restocks.

## Which models count as modded
1. Model name is a key of `trafficVariety.mods` on the server (verified: it is our own config, sent as `models`).
2. OR the real path of `/vehicles/<model>/info.json` (`FS:getFileRealPath`) contains `/multiplayer/` (**guessed**: BeamMP downloads server mods to `mods/multiplayer/`; it is logged as `modprice: model X is a mod car/left alone (... path=...)` so the owner can confirm).
3. Nothing else. Unknown = vanilla = the game's price. Models RLS itself ships extra configs for stay vanilla (the check is per model). `overrides` apply to any model on purpose, so the owner can fix a vanilla car too.

## Estimator (`lib/modPrice.lua`)
Inputs from the config entry (same fields RLS reads, `getConfigNumber`): `Power` (hp), `Weight` (kg), `Top Speed` (m/s: the shop UI feeds it to `units.buildString("speed", ...)`, which takes m/s; **inferred**), `Drivetrain`, `Type`/`Body Style`/`Config Type`/`Name` words, and the year from the listing's age.
- Base from power, log-log through anchors (hp -> price): 60 -> 2.8k, 100 -> 5k, 150 -> 10.5k, 200 -> 19k, 300 -> 38k, 450 -> 85k, 600 -> 160k, 800 -> 380k, 1000 -> 1M, 1400 -> 3M. Anchors are the owner's examples plus hand tuning. **The game's vanilla list is not in the RLS source** (only a few RLS custom info files, e.g. unmarked Bastion 50k and the police Redtail 80k), so nothing was fitted to vanilla data.
- x (expected weight / weight)^0.4, clamped 0.75 to 1.3 (expected = 1000 + 2 hp, clamped 1100 to 1800 kg). Heavy vehicles (4500 kg or more, semi, tractor, bus): 18k + 90 per hp + 4 per kg.
- Small factors: AWD 1.05, RWD 1.02, FWD 0.96; pickup/truck/van/utility 0.85; race/drag/rally 0.9; top speed against what the power usually reaches (+-10 percent); year (0.7 to 1.0, mild, because RLS ages the price itself).
- The result is a CATALOG (new) value. The shop shows it after RLS's age and mileage depreciation, so an old cheap car appears far lower than the estimate.
- Final: clamp to `min` (800) and `max` (2,000,000); if RLS's catalog value is within +-`tolerance` (35 percent) of the estimate it stays; `overrides` (`model` or `model/config`, config.json only because the menu rejects `/` in names) win; no usable power = the game's price.

## Config, wire, menu
Server config `modPrice = {enabled, max, min, tolerance, overrides}` -> `server/modPrice.lua` -> `rlsmpModPrice` (see PROTOCOL.md) -> `rlsmp_modPrice` (sanitizes again). Menu: Market page bottom (enabled, max, min, tolerance); rules in `trafficAdmin.lua`.
Log lines (tag RLSMP-P3): `modprice: <model>/<config> author=<RLS raw value> source=<parts|configFallback...> estimate=<n> used=<n or game> (<override|author|estimate|game>) hp= kg=`, one per model/config, at most 120.

## Selling (owner decision: reprice it too, config `modPrice.sell`)
Verified in valueCalculator.lua (~1377-1428): an owned car is valued by `getInventoryVehicleValue(id, ignoreDamage)` -> `getVehicleValue` -> the FILE-LOCAL `getVehicleValuation({modelName, configKey, ...})` -> the cached catalog profile (same parts-sum catalog value as the shop), then part adjustments and desirability; `getInventoryVehicleSellValue` = that x `getVehicleSellMarketMultiplier()`. The local calls cannot be wrapped, but every outside user calls the EXPORTED functions (grep): marketplace listings and negotiation, garage sell (`inventory/operations.lua`, `ui.lua`), dealer trade-in (`purchase.lua` x `tradeInRate`), insurance (`policyChanges.lua`), auction registration/view, mortgage, taxi, car meets. So we wrap `getInventoryVehicleValue` and `getInventoryVehicleSellValue` (wrapperLifetime, identity re-checked each frame) and multiply the result by `ours / catalog`, where `catalog = getVehicleCatalogProfile(model, configKey).catalogValue` (the value RLS used) and `ours` = the same `decide()` as the shop (specs from `core_vehicles.getConfig`, year from the inventory car). Same ratio on both sides = no buy cheap / sell high. Config key: `config.partConfigFilename` file name, else `config.key` (the same rule as RLS). No usable data, an error, `sell = false` or a vanilla model = RLS's own number. Part adjustments scale too (guess: acceptable).
Not covered: `getQuickVehicleValue(base, year, mileage)` (no model, used by the profile read model), `getVehicleCatalogIntrinsicBookValue` (auction pricing, repo, car meet sales, racing team, recovery jobs).

## Open points
- Path guess for "downloaded from the server" and the m/s guess for Top Speed are unverified; both are visible in the log.
- Dealership stock saved in a savegame keeps old listing prices until it restocks.
- Private-seller listings in the shop use the same context, so they are repriced too.
