# Research: how RLS sells a player's car, and where we hook it (read from RLS source, nothing played)

RLS paths are relative to `lua/ge/extensions/overhaul/`. Everything under "Unverified" has not been run in game.

## How the Marketplace sale works (read in source)
- Listings live in `career/market/marketplace.lua` (`listedVehicles`, saved in `career/marketplace.json`). The phone Marketplace app lists a car, RLS generates buyer offers over time (`generateOffer`).
- Accepting an offer goes `M.acceptOffer` / `M.acceptOfferById` (phone) / negotiation `takeTheirOffer` (`marketplace/negotiation.lua`) -> local `acceptOffer` -> `syncSpawnedListingPartConditions` (async callback) -> `tryAcceptOfferAfterSync` -> `completeAcceptOffer` -> `completeInventorySale` (`marketplace.lua:717`).
- `completeInventorySale` calls **`overhaul_career_garage_inventory.sellVehicle(inventoryId, payout)`** through the global, and only when that returns true removes the offer and calls `publishVehicleSale`. A false result shows "The sale could not be completed. Please try again." and keeps the offer.
- `sellVehicle` (`career/garage/inventory/operations.lua:63`) pays with `playerAttributes.addAttributes({money=...}, {category="sale", tags={"vehicleSold","selling"}})` and removes the car (`helpers.removeVehicle`, which fires `onOverhaulVehicleRemoved`, so the listing goes too). Our wallet module already reports that money change to the server.
- Other callers of the same function: car meets (`carmeets.lua:532`), the auction (`auction/registration.lua:348`), racing team (own path), and the garage UI (`sellVehicleFromInventory`, which calls the LOCAL function, so a wrapper never sees it).

## The hook we use
`overhaul_career_garage_inventory.sellVehicle` is a field of the extension table (`inventory.lua:804`), looked up at call time by the Marketplace. Wrapping that field catches every Marketplace route (phone accept, negotiation, by-id) with one wrapper. Wrapping `marketplace.acceptOffer` would NOT work: the phone path uses the local function.
- Only Marketplace calls are held. The wrapper walks the call stack (`debug.getinfo(level, "S").source`) and holds the sale only when a frame comes from a file with "marketplace" in its name. Car meets and the auction have other file names and run as before. Async callbacks defined in `marketplace.lua` still show that file, so the check works after the part-condition sync too.
- Held means the wrapper returns false. RLS then shows its generic "sale could not be completed" text (we add our own toast with the meetup) and the offer stays.
- At the meetup the extension calls the saved original `sellVehicle(inventoryId, price)` with a bypass flag, then `publishVehicleSale`. The payout is RLS's own offer value, paid by RLS locally and reported by the wallet module as before.
- Wrapped once per table, identity re-checked every frame (`rlsmp/meetup.lua` `install`).

## Unverified (be honest)
1. That the call stack really contains the marketplace file at the time of `sellVehicle` (it should, `completeInventorySale` is not a tail call; the test uses a fake chunk name). If the check never matches, nothing is held and sales stay instant. Check the log for `wrapped overhaul_career_garage_inventory.sellVehicle` and `held sale of car`.
2. How the phone app looks after the sale is held (it will show RLS's failure text once).
3. That removing the car while the player sits in it (the sale runs at the meetup) behaves. RLS normally sells from a computer, on foot.
4. `core_groundMarkers.setPath(vec3, {clearPathOnReachingTarget = false})` as the route (same call RLS `passive.lua:939` makes) and `clearOwnedPath(token)` to remove it. RLS jobs share this route; a taxi or delivery job can replace ours.
5. The police setup: `overhaul_integration_services_police.setPursuitMode(1, playerVehicleId, {copIds})` (`police.lua:536`) only sends the listed units, but RLS may add others later. We pass the 1 or 2 nearest existing units and stay at level 1 (no roadblocks there as far as the source shows). It needs police units to exist in traffic; if none are known we fall back to plate-reading's `startChase`. Whether cops are close enough to arrive in time is unknown.
6. Stolen cars are NOT in the RLS inventory in this build (they live in `theft.lua`), so they cannot go through the Marketplace. They use the Black Market path (`/meetup black`).

## Black Market and the phone app
The Black Market phone app is not changed. Selling a stolen car by meetup is `/meetup black` (sit in or stand next to the car); it pays `market.fenceQuote(value)` like the fence, written by the server. Selling parts stays with `/fence strip`. A phone button can call `rlsmp_meetup` later with raw `engineLua` (not the `lua` proxy).

## Entry point if the hook does not match
Chat `/meetup` (sit in the garage car you want to sell) starts the same flow with RLS's quick sell value.
