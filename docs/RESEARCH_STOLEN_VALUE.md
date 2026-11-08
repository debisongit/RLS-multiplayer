# Research: what a stolen car is worth

Owner report: a stolen Bastion (about 25,000 on the used market) paid 500 for strip and 700 for an illegal sale.
"Verified" = read in the RLS source copy (read only). "Guessed" = not seen in a running game.

## Cause (verified in our code and the owner's log)
- Parked cars are `simple_traffic` stand-ins. Their `partConfig` file name is `<model>_<config>_parked`. `lib/theft.realModel` splits the model off, the rest (`sedan_pre_s_parked`) was passed to `core_vehicles.getConfig(model, key)`, which has no such config, so `Value` stayed 0 (log: `config sedan_pre_s_parked value 0 year nil`).
- Server `fence.valueOf` then used `fence.minValue` 2000: strip 30 percent = 600, sell 35 percent = 700.

## How RLS prices a used car (verified)
- `overhaul_career_market_valueCalculator.getVehicleValuation(opts)` (valueCalculator.lua ~1200) needs `modelName` + `configKey` (catalog profile = parts sum) or `catalogBaseValue`; it applies `age` (years) and `mileageMeters` and returns `bookValue`.
- The dealership (`vehicleShopping/stock.lua populateListingPrice`) calls it with `age = currentYear - year`, the listing's `Mileage`, then multiplies by a seller factor 0.88 to 1.12. So `bookValue` is the used price before the seller's spread.
- `getQuickVehicleValue(baseValue, year, mileage)` is the same valuation without a model (catalog value only).
- `core_vehicles.getConfigList().configs` holds config infos with `model_key`, `key`, `Value`, `Years {min,max}` (RLS itself iterates it this way in valueCalculator `getConfigInfoIndex`).

## What we do now (`lib/stolenValue.lua`, called from `rlsmp/theft.lua` `M.carInfo`)
1. Names tried: the part after the model and the whole file name, both without `_parked` / `_traffic` / `_simple`. Exact key match first, then the longest shared prefix (at least 4 characters). **Guessed**: that stand-in names really are real config keys plus `_parked`; the log line shows what matched.
2. No match: the model's typical config = median catalog `Value` of its configs (police, taxi, junk, race words skipped). Spawn config is then left to the game.
3. Age = this year minus the middle of the config's Years (default 12 years); mileage = 12000 km a year, at least 20,000 and at most 300,000 km (a guess of a typical used car).
4. Value from RLS `getVehicleValuation` (`logContext = "rlsmpStolen"`, so our modPrice wrapper, which only touches `updateVehicleList`, does not change it). Fallbacks in order: `getQuickVehicleValue`, our spec estimate (`lib/modPrice.estimate`, Power/Weight/Top Speed), the plain catalog `Value`, else 0 (server floor).
5. Log: `theft value: model X config Y -> matchedKey (exact|prefix|typical), source S, age A, value V`, once per model and config.
Expected: a Bastion near its used price (the numbers depend on the real config values, **not checked in a game**); mod models use the author's catalog value or our estimate.

## Server (authority)
- The server cannot read the game's catalog, so it cannot recompute. It stores the client value at the end of a theft (`theft.capValue`): at most `fence.maxValue` (300,000) and at most `fence.modelCaps[model]` if the owner sets one, e.g. `{bastion = 40000}`. `fence.valueOf` lifts anything under `fence.minValue` (2000) up to it.
- Existing limits stay: one theft per player cooldown, a record per plate paid once, theft needs the timed action and the witness roll, market members only. A modified client can still claim up to the cap; a learned per-model plausibility check was not built (the first reporter would set the bar).

## Payouts (shares of the used value; config keys, defaults for new servers)
| way | old | new | key |
|---|---|---|---|
| strip parts | 30% | 45% | `fence.stripRate` |
| sell, no papers | 35% | 40% | `market.fenceCarRate` |
| gamble, 1 / 2 papers | 45% / 52.5% | 55% / 60% | `fence.gambleBase`, `fence.gamblePerPaper` |
| gamble trap chance | 30% | 20% | `fence.gambleBust` |
| resell, 3 papers | 60% | 70% | `fence.resellRate` |
Expected gamble value with 1 paper = 0.8 x 55 = 44 percent, above a plain sale (40) so the risk is worth taking; all stay under a legal sale (the market fee is the missing share). Existing `config.json` files keep their old numbers.
