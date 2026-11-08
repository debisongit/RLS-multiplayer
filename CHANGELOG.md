# Changelog

## 0.4.46 (all untested in-game)
- No more broken junk cars in traffic (`trafficVariety.excludeWords`). (Claude A)
- Traffic is only recycled when farther than 4 km from every player (`traffic.respawnDistance`, 0 = the game's own distance). (Claude A)
- The traffic car count now really reaches `traffic.minAmount`: the first group is made bigger, missing cars are added one every 4 s through the smooth spawn path (`fill:` log lines). (Claude A)

## Unreleased (untested in-game)
- The traffic car COUNT now reaches the server minimum. The owner's log showed 5 cars for an amount of 4: `setActiveAmount` only limits how many existing cars are active, it never makes a car, so raising it to 10 changed nothing. Now (1) the first traffic group the game asks for is built as big as `min(quota, traffic.minAmount)` when the client already knows it (the minimum now also travels in `rlsmpTrafficVariety`), and (2) when fewer cars exist than that, the missing ones are built one at a time, at most one every 4 s, through the same hitch-free one-car group spawn as the re-roll, placed out of sight behind the camera and given to RLS traffic; they take their model from the variety pool like the others. Not in a chase, not while a job or race has cut the traffic amount, not on slow frames, not within 3 cars of BeamMP's `MaxCars`; the cars it added are left alone by the stuck-car recycling, re-roll and swap for 2 minutes. Never above the minimum. Log lines start with `fill:`. Untested. (Claude A)
- Stolen cars were worth almost nothing: the parked cars are stand-ins with config names like `sedan_pre_s_parked`, the game's price was not found (value 0) and the fence paid its floor of 2000 (strip 600, sell 700 even for a Bastion). Now the value is what a used car of that kind sells for: RLS's own valuation of the real config (name without `_parked`, then closest name), else of the model's typical config, with the config's age and a typical mileage; if that fails RLS's quick value, then our spec estimate. Log lines `theft value:` (model, config, source, value). (Claude A)
- Payouts rebalanced so crime pays but less than a legal sale: strip parts 45 percent of the value (was 30), sell without papers 40 (was 35), gamble 55 percent with one paper and 60 with two (was 45 and 52.5) with a 20 percent trap chance (was 30), resell with all three papers 70 (was 60). The value is never below `fence.minValue` and never above `fence.maxValue`. (Claude A)
- New defaults only reach NEW servers. An existing `config.json` keeps its old numbers: to get the new ones set `fence.stripRate` 0.45, `market.fenceCarRate` 0.40, `fence.gambleBase` 0.55, `fence.gamblePerPaper` 0.05, `fence.gambleBust` 0.20, `fence.resellRate` 0.70 (or delete those keys). Optional new key `fence.modelCaps = {bastion = 40000}` limits the value accepted for a model. Damage does not lower the price yet. Details and what is guessed: `docs/RESEARCH_STOLEN_VALUE.md`. (Claude A)
- Junk cars are gone from traffic: the owner's log showed the re-roll picking `joesjunk_career_*` configs (RLS's broken junkyard cars that do not drive). New server setting `trafficVariety.excludeWords` (default junk, wreck, derby, crash, rolling, shell, undriveable, parts): a model, config or Config Type containing one of these is never picked by group building, the pool, the re-roll or live swapping. A junk car in the game's own group is re-picked away too. (Claude A)
- Traffic cars are recycled only when they are farther than `traffic.respawnDistance` meters (default 4000, 0 = the game's own radius, slider in the `[` menu) from every player; police in a chase are untouched. Cars are still placed back 100 to 300 m from the player like the game does. The game's old radius of 130 to 450 m made 5 to 12 cars a minute pop out and in. Warning: with only a few cars in traffic, they now drive away and few stay near you; raise the amount. (Claude A)
- The raised traffic amount now holds: RLS put the player's own number (4) back after our parked-cars top-up, 5 s after we set 10. Every 10 s the amount is set again if it is back at the game's own setting, and the log shows the value read back (`TRAFFIC amount was reset by the game ...`). Raising the amount does not create cars: the log says how many cars exist. (Claude A)
- New log line `range: effective respawn distance=...` every 30 s. (Claude A)

## 0.4.45 (untested in-game)
- Same few cars again and again: the owner's log showed the game's own traffic amount was only 4, so 4 cars kept respawning around the player every few seconds. The server now lifts a lower amount to `traffic.minAmount` (default 10, never above the quota, 0 = leave the player's own). Costs some frame rate on weak PCs: lower it if it lags. (Claude A)

## 0.4.44 (untested in-game)
- Selling a modded car uses the same fair price as the dealership (`modPrice.sell`, on by default), so there is no cheap-buy, high-sell trick. Not covered yet: auction pricing, repo jobs, car meet sales and the racing team. (Claude A)

## 0.4.43 (all untested in-game)
- Car changes without the freeze: the new car is built through the game's own group spawn queue, then the old one is removed (`trafficVariety.respawn.mode`: async, inplace, off). The useless preload reserve is gone. (Claude A)
- Fair prices for modded cars in the dealership, estimated from power, weight, year and class (`modPrice`). Selling will follow. (Claude A)

## 0.4.42 (stopgap, untested)
- Lag fix, first step: the owner's log showed every car model change freezes the game for 0.5 to 2.3 s (29 times in 1000 s). Changes now happen for only about a quarter of respawns, 2 a minute at most. The real fix (changing cars without a freeze) is being built. (Claude A)

## Unreleased: fair car shop prices for modded cars (all untested in-game)
- New server setting `modPrice` (`enabled`, `max` 2,000,000, `min` 800, `tolerance` 0.35, `overrides`): the RLS car shop price of a MODDED car is estimated from power, weight, top speed, drivetrain and class instead of the mod author's value. If the author's value is within 35 percent of the estimate it is kept. Never below 800 or above `max`. (Claude A)
- Only models listed in `trafficVariety.mods` (or whose files came from this server's download folder) are touched. Vanilla cars, the auction and repo jobs keep the game's prices. Fixed prices: `overrides = {mycar = 45000, ["mycar/sport"] = 60000}` in config.json. (Claude A)
- A few controls are in the `[` menu under Market. Log lines start with `modprice:` (model/config, author value, estimate, used); send them to tune the numbers. Research and what is verified or guessed: `docs/RESEARCH_MOD_PRICES.md`. (Claude A)
- Known gap: a mod car bought at the new price is still SOLD at the game's value, so an author value that is too high can be sold for profit. See the research doc. (Claude A)
## Unreleased: hitch-free car variety (all untested in-game)
- A re-rolled traffic car no longer freezes the game: new setting `trafficVariety.respawn.mode` = `async` (default) | `inplace` | `off`. Async builds the new car through the game's own group spawn queue (`core_multiSpawn.spawnGroup`, a one-car group), gives it to RLS traffic, and only then removes the old car (the view rules are checked again first; if somebody can see the spot by then, the new car is deleted instead). `inplace` is the old freeze-in-place way (0.5 to 2 s per re-roll). If the game has no group spawn, nothing is re-rolled (logged). (Claude A)
- The "reserve" of picks made ahead is gone (it only picked, it loaded nothing): `preload.reserve`, `prepareSeconds`, `ageMax` removed; the frame guard and the loaded-model bias stay. (Claude A)
- New log lines `build: <model>/<config> mode=async|inplace ...` with the call time, the total time and the worst frame meanwhile, to measure it. What is verified or guessed: `docs/RESEARCH_ASYNC_SWAP.md`. (Claude A)

- Selling is repriced the same way (`modPrice.sell`, default on): sell value, trade-in, insurance and garage value of an owned mod car use the same fair price, so there is no cheap-buy / high-sell trick. Auction, repo, car meet and the profile read model still use the game's value. (Claude A)
## 0.4.41 (all untested in-game)
- Traffic respawn range: `traffic.respawnRange` (1.0 = the game's own, up to 3) and `traffic.respawnDelay`, both on the [ menu Amount page. Live swapping is now OFF by default (it replaced cars the game never recycled). Stuck-car cleanup now waits 120 s and only acts on cars 400 m from every player, one at a time. (Claude A)

## Unreleased: traffic respawn range (all untested in-game)
- New settings `traffic.respawnRange` (multiplier on the game's own respawn radius, 1.0 = the game's original, up to 3) and `traffic.respawnDelay` (least seconds a car stays after the game placed it, 0 = off); both in the `[` menu under Amount. Log lines start with `range:` and show the values before and after. (Claude A)
- Stuck-car recycling (`traffic.unjam`) is stricter now: stuck 120 s (was 30) and 400 m or more from every player (own game and the others), still one car at a time; can be switched off. (Claude A)
- Live model swapping (`trafficVariety.swap.live`) is now off by default: it replaced cars the game had not recycled. The re-roll still only happens after the game itself respawned the car and never forces a respawn. (Claude A)
- Research and what is verified or guessed: `docs/RESEARCH_RESPAWN_RANGE.md`. (Claude A)

## 0.4.40 (all untested in-game, off by default)
- Simplified cars (`trafficVariety.simplified`, off): stealable parked spots turn into real cars when a player comes within 250 m, other parked cars stay simplified; far-away traffic can return as simplified cars and is upgraded when it comes near. Details and limits in `docs/RESEARCH_SIMPLIFIED.md`. (Claude A)

## Unreleased: simplified (cheap stand-in) cars (all untested in-game, off by default)
- New setting `trafficVariety.simplified` (`enabled`, `parked`, `traffic`, `nearRadius`, `perMinute`; also in the `[` menu): keep BeamNG's cheap `simple_traffic` stand-ins where nobody looks and use real cars where it matters, for a better frame rate. Everything is off until you switch `enabled` on. (Claude A)
- Parked cars: they are stand-ins already. A stand-in at a stealable spot (the same pick as the theft code) becomes a real car when a player comes within `nearRadius` (default 250 m), and goes back when its spot is no longer stealable and everybody is far away. Never within 120 m of a player or in front of the camera; then the steal code still converts it as before. (Claude A)
- Moving traffic (`traffic`, default off): a respawned car far from every player may come back as a stand-in of the same model, and a stand-in that comes within `nearRadius` is made a real car. Cars that approach from ahead cannot be changed in view, so they arrive as stand-ins; that is a limit of the view rule, see the research. (Claude A)
- Police, taxis, jobs, chases and all players' cars are never touched; changes are limited per minute and wait for calm frames. Logs start with `simplified:` (counts of stand-ins and real cars, upgrades, ms per change, and what RLS's filter said about the stand-in configs). Research and what is unverified: `docs/RESEARCH_SIMPLIFIED.md`. (Claude A)

## 0.4.39 (all untested in-game)
- Stealing no longer needs chat commands. Near a parked car press the interact key (default Y, set in Controls under RLS Career MP) for a small popup: Inspect, a button per steal method you have tools for, Cancel. Fence (strip, sell, resell, gamble) lives in the garage and the Black Market app, pickup is automatic in the drop circle. The old chat commands are off unless `ui.chatCommands` is true. (Claude A)

## Unreleased: no more chat commands for stealing (all untested in-game)
- Stealing and inspecting: walk up to a parked car and a small toast says "Press [Y]". The key opens a small popup: Inspect, the ways to steal it you have the tools for, Cancel. No typing. (Claude A)
- Fence: the garage computer now has Strip, Sell, Resell and Gamble for a stolen car; the Black Market phone app has the same four buttons for the stolen car you stand next to at the drop spot. (Claude A)
- Black Market phone app: your items, your stolen cars with prices, "Sell by meetup" and "Drop the meetup". Orders, items, invites and the scout tip were already there. (Claude A)
- Packages are collected by themselves when you stop inside the drop circle; a small popup says what you got. (Claude A)
- The chat commands `/steal /inspect /fence /market /meetup /items` still exist but only for developers: new setting `ui.chatCommands` (default false) switches them off, and no message names them any more. (Claude A)
- Research and what is unverified: `docs/RESEARCH_THEFT_UI.md`. (Claude A)

## 0.4.38 (all untested in-game)
- Theft hints for black market members: `/inspect` near a parked car (3 s) tells its weakness, tools and risk; a Scout tip in the black market app marks 2 to 3 stealable cars for about 10 minutes. (Claude A)
- The big debug text labels on meetup and drop markers are gone. (Claude A)

## 0.4.38, more detail: inspect hint and scout tip
- Black market members get a small toast when they walk within about 15 m of a stealable parked car ("type /inspect"). Everyone else never sees it. (Claude A)
- `/inspect` takes 3 s and tells the car's tier, the tools it needs (missing ones listed) and the rough risk (alarm, GPS tracker, loud). Boring cars and non-members get the same wait and a plain "nothing stands out"; the server judges distance, membership and the pick itself. (Claude A)
- Black Market phone app: "Scout tip" button. It marks 2 to 3 stealable parked cars within 800 m with small floating dots for up to 10 minutes. Price, rep, cooldown in `market.scout`; more than 3 tips an hour cost 1 reputation each. (Claude A)
- Settings: `theft.inspect` and `market.scout` (also in the `[` menu). Docs: PROTOCOL "Inspect hint" and "Scout tip". (Claude A)

## 0.4.37 (all untested in-game)
- Less lag from car changes: a frame guard postpones changes after slow frames, picks are prepared ahead. Hidden spare cars are not possible with BeamMP. (Claude A)
- Realistic mix: everyday cars about 88%, rare ones (race, drift, hotrod, junk) about 2%; trucks and vans favoured on highways. (Claude A)
- Cars are never changed or recycled within 120 m of a player or in the camera view; `distance:` log lines every 30 s. Turn the car changing off with `trafficVariety.respawn.enabled=false`. (Claude A)

## 0.4.37, more detail: respawn distance
- Traffic on foot: our re-roll, live swap and stuck-car recycling now never touch a car closer than 120 m to any player or in front of the camera (a wide cone, up to 500 m). The old test was only a line from the car to the avatar. (Claude A)
- New log line `distance:` every 30 s (radius, active amount, respawns in the last minute, nearest respawn distance), plus a line per respawn and a warning when a car fades out near you. (Claude A)
- See `docs/RESEARCH_RESPAWN_DISTANCE.md`. Switch for the original behaviour: `trafficVariety.respawn.enabled = false`. (Claude A)

## 0.4.36 (all untested in-game)
- Traffic: premade pool that rotates brands and models (no repeat within 6 picks, max 3 of a brand), respawned cars get a new model and config out of sight (3 a minute), parked car amount raised to 10 (`trafficVariety.parked.amount`). (Claude A)
- Police chase: cops near you are held before a chase starts, fading-out cops are cancelled, cops re-placed should come from behind. Spawn range is back to the original game behavior by default (`police.bubbleMode`: original, protect, off). (Claude A)

## 0.4.37, more detail: preload and rarity
- Lag: building a replacement car costs about a second of work in your game (the log shows jbeam, meshes and the vehicle thread loading). New lag protection: no car is built while the last frames were slow (and not for 3 s after a slow frame), never two builds within 6 s, never in a chase. Config `trafficVariety.preload`. (Claude A)
- Lag: a small reserve (3) of picks is chosen ahead and their data read ahead, one every 4 s in calm moments; the re-roll uses them. No hidden spare car is built, because BeamMP would send it to everybody. 70% of picks come from models that are already on the street or built before (their meshes are loaded). (Claude A)
- Log lines `preload: prepared ... ready N of M`, `preload: build ... took N ms`, `preload: build postponed: ...` so you can send logs. (Claude A)
- Variety: everyday cars are now the clear majority (88% common, 10% uncommon like rally/tuner/offroad/workpackage, 2% rare like race/drift/hotrod/junk/exotic), config `trafficVariety.rarity`, sliders on the [ menu amount page. (Claude A)
- Variety: default road class and night weights (trucks and vans on highways, fewer in the city and at night, small cars like the city); one log line `variety context: zone=... night=...` when it changes. (Claude A)
- All untested in the game. (Claude A)

## 0.4.36, more detail: chase and traffic range
- Police: cops near you are now held BEFORE a chase starts (not only after the game noticed it), so a cop that sees you is not recycled in the half second before the chase flips on. A cop that is already fading out when it gets held fades back in. Untested. (Claude A)
- Police: every police car gets "respawn away from you" (`spawnDirBias = -1`), so a cop that RLS re-places anyway should arrive from behind, not ahead. This is a guess about vanilla placement, see `docs/RESEARCH_CHASE_RANGE.md`. Roadblocks and police teleports are also refused before the chase is noticed. Untested. (Claude A)
- Traffic range: new setting `police.bubbleMode` (menu: Police page). Default `original` = RLS's own spawn and respawn distances; a car is only kept while another player is inside its own radius and sees it. `protect` = the old strict rule (450 m, or line of sight up to 1 km), `off` = no protection. The old rule is what made respawns far and repetitive. Untested. (Claude A)
- The LEAK log line now says how far the cop was and whether it was ahead of you, and a new log line says when a fade-out was cancelled. (Claude A)

## 0.4.35 (all untested in-game)
- Meetup selling: Marketplace sales send you to a meetup spot to drop the car off. Only stolen or fake-paper cars can be a police setup (1 to 2 cops); a fully legal car never is. (Claude A)
- Garage: Strip and illegal parts buttons in your RLS garage, plus a Black market items button. (Claude A)
- Police variety: more police models, fewer undercovers, fewer Bastions. (Claude A)

## 0.4.36, more detail: traffic pool
- Respawned traffic cars now change: when RLS respawns a traffic car out of everybody's sight, it is replaced by a different model with a different config (and half of them get new paint). Rate-limited (3 a minute), never police, taxis, chases, job, crashed or player cars, and it stops itself after 3 failures. Settings `trafficVariety.respawn`. Untested in game. (Claude A)
- Premade car pool: traffic groups and re-rolled cars are picked from a few configs of every model the game could use (RLS's own traffic filter applies), round robin: not the same model within the last 6 picks, at most 3 of one brand in the last 12, at most 3 of one brand on the street. Settings `trafficVariety.pool`. Untested in game. (Claude A)
- More parked cars: after the career starts, the game setting `trafficParkingAmount` is raised to `trafficVariety.parked.amount` (default 10; your log had 2) and RLS tops the cars up; the old value comes back when you leave. 0 = leave alone. More parked cars are more BeamMP cars per player, so check `MaxCars`. Untested in game. (Claude A)
- The `[` menu "amount" page got the pool, re-roll and parked settings. Research and unverified bits: `docs/RESEARCH_TRAFFIC_POOL.md`. (Claude A)
- Note: with default weights live swapping never swaps (everything weighs the same); only the new re-roll changes cars on a default server. (Claude A)
## 0.4.35, more detail: meetup selling
- New meetup selling. A Marketplace sale no longer finishes at once: you get a GPS route to a meetup spot the server picks, stop there for a moment, and the sale completes. Spots change each time and there is a cooldown. Untested in game, and the hook into the Marketplace is unverified (see `docs/RESEARCH_MEETUP_SALE.md`). (untested) (Claude A)
- A fully legal car is never set up. A stolen car or a car with a police-flagged plate has a chance that the buyer is a police setup: 1 or 2 cops chase you, no roadblocks, no sale. The chance is never 0 or 100 percent for those cars, so you cannot be sure. (untested) (Claude A)
- Black market: `/meetup black` sells a stolen car you drive by meetup; the server pays. `/meetup` is the fallback for a garage car. Settings in config `meetup`. (untested) (Claude A)
## 0.4.35, more detail: police variety
- Police cars: RLS's west coast police list is 5 Bastions (4 of 5 unmarked or undercover), and its police do not even go through the group builder we wrapped. We now also wrap `fitGroup` and re-pick police groups from every police config the game has: Bastion weight 0.3, about 10 percent undercover, at most 40 percent of one model. New server block `trafficVariety.police` (also in the `[` menu on the amount page). Research: `docs/RESEARCH_POLICE_MIX.md`. Untested in game. (Claude A)
## 0.4.35, more detail: garage strip
- New: a **"Strip / illegal parts"** button inside RLS's own garage computer, on every car you own (greyed out for loaned, rented or auctioned cars). It opens a small dialog: strip the car for cash (30% of its value; the car and its parts leave your RLS garage) or fit a fake plate, VIN plate or part number kit you bought. Untested in game. (Claude A)
- Stolen cars are not in the RLS garage, so they get an extra button "Stolen car: PLATE" in the same computer when one stands within 60 m. Stripping a stolen car works anywhere (no drop spot) but needs the black market. Untested. (Claude A)
- Fitted parts are remembered on the stolen car; `/fence resell` and `gamble` count them, so you do not have to carry the items to the drop spot. The fake plate does not change the plate text yet. Untested. (Claude A)
- A new "Black market items" button in the garage lists what you own. Items are NOT put into RLS's "My parts" list: a made-up part could break that screen (see `docs/RESEARCH_GARAGE_STRIP.md`). (Claude A)
- The chat commands `/fence ...` still work as before. New settings `fence.garage` and `fence.garageCooldown`. Stripping an ordinary car trusts the car value from your game (capped, 20 s between strips); this is a known weak spot. (Claude A)

## 0.4.34
- Car theft now logs `parked cars known: N, within 60 m: M, nearest ...` every 30 s while you walk, to find out why so few cars can be stolen. Your last log showed RLS only spawned 2 parked cars in total. (Claude A)

## 0.4.33
- Traffic variety no longer misses the first traffic group: a real log showed RLS built it about 1 s before the server's settings arrived, so every car kept its model for the whole session. Now the built-in defaults are used until the server speaks. (Claude A)
- Live swapping of hidden traffic cars is **on by default** on new servers (`trafficVariety.swap.enabled` and `live`), so respawned cars change model. It stops itself after 3 failures. Existing servers: set both to `true` in `config.json` or in the traffic menu. Untested in-game.

## Summary of 0.4.14 to 0.4.33 (what was added, in one place)
Every line below, and every line of the list further down, ends with who made it: **Claude A** (saves, wallet, business, claims, plates, market, theft core) or **Claude B** (traffic, police, variety, weather, traffic menu, fence, phone app).
- 0.4.14: police freeze only the cops in your chase, players report positions (`/where`), shared shop stock (off). (Claude A)
- 0.4.15: smart traffic personalities. 0.4.16: stuck traffic recycling. 0.4.17: duplicate-car cleanup. (Claude A)
- 0.4.18: part shop fix. (Claude B)
- 0.4.19 and 0.4.20: traffic variety and live swapping (watch only). 0.4.21: shared weather. (Claude B)
- 0.4.22: crash claims explain themselves and review fixes. (Claude A)
- 0.4.23: sturdier save download and safer duels. (Claude A)
- 0.4.23: traffic settings menu on the `[` key, only for the admins the server lists. (Claude B)
- 0.4.24: plate reading and police records. 0.4.25: arrest flags the plate. 0.4.26: black market and car theft core. (Claude A)
- 0.4.27: the fence (sell or strip stolen cars). 0.4.28: Black Market phone app, lockout kit, signal jammer, tracker blocker feedback. 0.4.29: theft, fence and market settings in the in-game menu. 0.4.30: Black Market phone app connection fix. 0.4.31: `[` key name fix, broken mod cars kept out of traffic groups. 0.4.32: Black Market phone app connection fixed (raw engineLua). (Claude B)

Plain list of what changed in each build. The build number shows in the game log (`client loaded, build X`) and the server log.
"Untested" means it passed the automatic tests but nobody has played it yet.
When you add a line, end it with `(Claude A)` or `(Claude B)`, whoever made the change. Both of us write in this one file.

## 0.4.32
- Black Market phone app: FOUND THE CAUSE of "No connection". The owner's screenshot of 0.4.31 showed the error `...[fn] is not a function`: the phone's `lua.rlsmp_market` is only an empty stub for an extension the RLS phone was never told about (RLS's own code says so and uses raw `engineLua` for that reason). The app now talks to the game with the raw `engineLua(code, callback)` call that RLS itself uses (the two `lua` proxy ways stay as fallbacks), says "Not loaded" if the game answers that the market extension is missing, escapes everything it sends into the Lua text, and still shows every error text when nothing works. (untested in game) (Claude B)

## 0.4.31
- From the owner's first game log (build 0.4.29): (1) The `[` key never got bound: the game logged "Could not create a description for binding keyboard0::leftbracket", so `leftbracket` is not the game's name for that key. The key map now binds BOTH `lbracket` and `leftbracket` to the settings menu; whichever name the game does not know logs one harmless error at start. `/trafficmenu` in chat opens the menu either way. (2) A traffic group that included a car called G30_Domestic crashed the spawn ("missing stage 1 data", then BeamMP's FATAL LUA ERROR): the model's folder has no .jbeam files (a leftover of a removed mod). The traffic variety code now never puts a model without .jbeam files into a group (logged once per model as `variety: <model> has no .jbeam files`); if the game cannot be asked, nothing is filtered, and if every offered model is broken the game keeps its own group. Cars the game's own spawner picks outside our groups can still be that broken model: remove the leftover mod folder to be sure. (3) The log showed the Black Market app opening three times (route and view load fine); it was build 0.4.29, before the connection fix in 0.4.30, so the "No connection" cause is still unconfirmed. (untested in game) (Claude B)

## 0.4.30
- Black Market phone app: first game test showed the app opens but said "No connection". The app now tries both ways RLS reaches the game (`lua.rlsmp_market` and `lua.extensions.rlsmp_market`), asks the game to load the market extension if it is missing, and shows the real error text under "No connection" so a screenshot tells what failed. The game log gets one line `RLSMP-MARKET the phone app reached the market extension` the first time the app calls in. Whether this fixes it is not known yet. (untested in game) (Claude B)

## 0.4.29
- The in-game settings menu (`[` key, only for the admins the server lists) now also edits **car theft**, the **fence** and the **black market**, on three new pages: Theft (on/off, how many parked cars are stealable, witness and report chances, report times, which cars need which method, and each method's time, noise and failure chance), Fence (open/closed, what strip, resell and gamble pay, the trap chance, reputation per sale) and Market (open/closed, bust cost, delays, invites, and the price, reputation needed and on/off of every item). The server checks every number against a range, saves it to `config.json` and applies it at once. Theft can now be switched on and off from the menu without restarting the server (the games are told straight away). Drop spot places and the list of admins are still only in `config.json`. (untested in game) (Claude B)
- **The settings menu is now open to every player.** The admin list (`trafficAdmin` names and account ids) is gone: any player on the server can press `[`, and open the pages and change settings. The server still only accepts settings on its allowlist and within their ranges, allows 3 requests per second per player, saves to `config.json`, and logs every change with the player's name (`RLSMP-ADMIN`). Everybody who has the menu open sees a change at once. WARNING: that includes prices, what the fence pays and turning theft on or off. (untested in game) (Claude B)
- Plate reading fixes: a remembered car description (model and colour, kept 20 minutes after an escape) now only catches the player who made it, so a stranger in the same model and colour is no longer chased by mistake (a flagged PLATE still catches whoever drives it). `police.enabled = false` now also switches plate reading off, and the menu's Police page has the plate reading settings (on/off, reading range and speed, chances, how long a flag and a description last). (untested in game) (Claude B)
- Carrying out a steal while an admin switches theft off stops the steal at once. (untested in game) (Claude B)

## 0.4.28
- **Black Market phone app**: a real app on the RLS phone (open the phone, App Store, "Black Market", GET). Members see their reputation, invites and money, what is for sale (tools show "Owned" or "On order", locked items show the reputation they need), a quantity picker for papers, their open orders with a "Collect here" button, and an invite box; people who were invited see an Accept button. It does exactly what the chat commands do (`/market ...` still works). The Stolen cars box tells you to use `/fence` at the drop spot. Not a member: the app says it is invite only. (untested in game) (Claude B)
- Immobilizer-era cars (about 1995 to 2010) now need a way in: the new **lockout kit** (a tool, kept forever, black market rep 10, $2500) joins the key programmer and a blank key, so you open the door quietly instead of smashing the window. NOTE: if your server's `config.json` already contains `theft.methods.key_programmer`, add `"lockout_kit"` to its `items` list by hand (or delete that key so the new default is used); the market tier `lockout_kit` is added automatically. (untested) (Claude B)
- **Signal jammer** now does something: it silences the alarm of luxury cars, so their theft noise (and with it the chance a witness sees you) drops to a quarter (`theft.jammerNoiseFactor`). Methods without an alarm are unchanged. (untested) (Claude B)
- **Tracker blocker** (already worked) now tells you in chat when it killed a luxury car's GPS tracker, so the car is reported after the normal time instead of within 20 seconds. Still missing: police pinging the tracker, and finding and removing it. (untested) (Claude B)

## 0.4.27
- The fence: stolen cars can now be turned into money. Drive the stolen car to the black market's ACTIVE drop spot (same spot as package pickups, it moves every 30 minutes), get out, stand next to it and type `/fence` to see what each way pays, then `/fence strip` (30% of the car's value, no papers), `/fence sell` (35%, no papers), `/fence resell` (60%, needs fake plate + VIN plate + part number, all used up) or `/fence gamble` (swap one or two papers: 45% or 52.5%, but a 30% chance the buyer is a trap: no money, the car is gone, you lose reputation). Black market members only; not while police chase you; good sales give reputation. The server pays, checks the spot and the car's owner, and saves money and papers together; the game only deletes the car after the server says so. Settings: `fence` in `config.json`. Needs `theft.enabled`. A car the game has no price for is valued at `fence.minValue` (2000). Note: stripping pays cash, it does not put parts into your part inventory. (untested) (Claude B)

## 0.4.26
- Black market (chat commands, a phone app comes later): `/market` help, `/market list`, `/market buy <item>`, `/market orders`, `/market pickup`, `/market invite <player>`, `/market accept`. Access is by invite plus reputation; the server owner makes the first member with the console command `rlsmp market grant <player>`. Orders are paid at once and delivered 1 to 2 minutes later to a drop spot (4 spots from RLS parking sites, one active at a time, changing every 30 minutes); `/market pickup` works when you stand within 20 m. Tools last forever, papers are used up. Prices and reputation tiers are in `config.json` under `market`. A bust costs reputation. The fence (buying stolen cars) opens with the next theft step. (untested) (Claude A)
- Car theft core, OFF by default (`theft.enabled` in `config.json`): about 15% of parked cars are stealable (the server picks them, same for everyone, changing every hour). Walk up, `/steal`; the method depends on the car's year and value (old: window punch and screwdriver; immobilizer era: key programmer and blank key; keyless: relay box, signal cloner or connector injector; luxury: needs more tools and has a tracker). A timed action with noise and a failure chance; on success the parked car is replaced by a real driveable car and you can get in. Witnesses decide when it is reported; a reported theft flags the plate for the cops. You cannot yet strip, resell or sell stolen cars (next step). (untested) (Claude A)

## 0.4.25
- Being arrested now flags your plate too (same 2 hours as after an escape, reason "arrested"). An arrest does not make cops read you more often, only an escape does. (untested) (Claude A)

## 0.4.24
- Plate reading and police records: a cop within 15 m reads your plate while you drive under 50 km/h (3 to 6 seconds, "Police reading your plate: AB ___" on screen; speeding up or driving off cancels it). After you escape a chase the plate is flagged for 2 real hours and the car's model and colour are remembered for 20 minutes (any player in the same model and colour can be picked up by the description). A read of a flagged plate starts an instant chase (one cop in five skips it, and the same plate is not chased again within 2 minutes). Changing the plate or repainting clears the flag. Normal reads: 35% of passing cops, 100% in the 20 minutes after an escape. Settings under `police.plateReading` in `config.json`, switch `police.plateReading.enabled`. Being arrested does not flag the plate yet. (untested) (Claude A)
- Player items module on the server (`/items`), groundwork for the black market and car theft. (Claude A)

## 0.4.23
- Traffic settings menu: press `[` in the game (rebindable under Controls > RLS Career MP, or type `/trafficmenu` in chat) to open a window for the AI traffic settings: which car types and single cars are common or never (0 = never), where (city / main roads / highways) and when (day / night) they appear, how drivers behave (personality mix with percentages), how many cars, swapping, shared weather and police options. Edit freely, then press Apply: the server checks every value, applies it at once, and saves it to `config.json`. ONLY players listed in the server config `trafficAdmin.names` (default `polakpls`, `sucuk21`; `accountIds` also works) can open it or change anything: the SERVER decides, so nobody can get around it by editing their client; guests are always refused; changes are rate limited and logged (`RLSMP-ADMIN`). New: per-car weights (`trafficVariety.models`). Settings are now live: changing weather on/off, variety, driver mix, police options takes effect without a restart (cars keep their model once they exist). (untested in game) (Claude B)

## 0.4.23
- Save download made sturdier (the stalls at 129 and 153 of 177 pieces): the server waits on real time and sends one piece at a time if your game goes quiet, your game reports its progress every second, a lost start message is asked for again, and the resend request can no longer flood the server. If your career is late to start (RLS finished loading after the 3 minute limit), it now still comes online. (untested) (Claude A)
- Event record board: a limit of one run per 5 seconds, new records are only announced when they beat the old one by 0.05 s, and one player cannot flood it with junk event names. Map travel block re-checks itself if RLS replaces the function. (untested) (Claude A)
- Pink-slip duels (still off by default): the winner gets a car built from the server's own copy, not from the loser's PC; cars are marked as handed over the moment someone wins; fake finish positions are caught; you must sit in the car you stake. (untested) (Claude A)

## 0.4.22
- Crash claims: a crash that ends without a verdict now tells you why (chat and server log), instead of nothing happening: scrape under the impact speed limit, another claim too soon after, missing data. Both games log `RLSMP-CLAIMS` lines and the server logs every `[claims] report`. The client also notices contact when only your own car has the collision flag. NOTE: `claims.dryRun` is still true in `config.json` by default, which only SHOWS "TEST MODE ... pays $X" and moves no money; set `claims.dryRun` to false in the server's config.json to make it real. (untested) (Claude A)
- Review fixes: the duplicate-car cleanup never deletes a car bound to a garage slot (two owned cars can share a plate); police units tied to your chase are held back from recycling without switching RLS's own chase logic off; the traffic bubble only checks cars RLS is about to recycle and ignores line of sight beyond 1 km; stuck-car recycling skips cars with respawn off; replace-vehicle guard no longer loops (freeze) and refuses other players' cars. (untested) (Claude A)

## 0.4.21
- Shared weather: everybody now sees the same weather. Before, each game ran its own RLS forecast (made from the player's own save). Now the server picks one of RLS's six conditions (clear, partly cloudy, overcast, drizzle, rain, storm) from its own clock, like the shared time of day: it glides smoothly through the conditions in between, a new random target every 15 real minutes, with the mix set in the server config (`weather`). Every game tells RLS to show it with RLS's own `forceCondition`, so rain, wet roads and tire grip stay consistent with what you see. `weather.force` pins one condition for everybody (handy for testing). RLS's own "Rain approaching" phone notifications (from the local forecast) are switched off. Still local: RLS's morning fog, temperature, thunder timing and weather app; changes snap instead of fading. (untested) (Claude B)

## 0.4.20
- Traffic variety, step 2 (live swapping), safe first version: a traffic car that nobody can see (not on your camera, not near or visible to another player, never police, taxis, pursuits or jobs) can be swapped for a model that suits the current road class and time of day better. Two switches in the server config under `trafficVariety.swap`, both OFF by default: `enabled` only watches and logs "swap would happen ..." (changes nothing), `live` really replaces the car (experimental, never tried in the game; it switches itself off after 3 failures). At most 2 swaps per minute. With default weights nothing is ever swapped, because every car weighs the same. Log tag `RLSMP-P3`. (untested) (Claude B)

## 0.4.19
- Traffic variety, step 1: traffic and parked cars use more varied models and configs. Each game builds its groups from a bigger pool, no model fills more than 25% of a group, and the server can weight car Types, road classes (city, main, highway), day and night, and add cars from mods the server ships (`trafficVariety` in the server config). Nothing is excluded beyond what RLS already refuses. Cars keep their model once they exist, so area and time only apply to cars built from now on; live swapping while you drive is step 2. Log tag `RLSMP-P3`, design in `docs/DESIGN_TRAFFIC_VARIETY.md`. (untested) (Claude B)

## 0.4.18
- Part shop fix: buying or removing a part at your garage computer no longer spawns a second car. BeamMP's "replace vehicle" ignores which car RLS names and replaces the car YOU are in; in the shop you stand on foot, so it replaced your walking character and left the shopped car behind, still frozen ("a fake car you can hop in but can't drive"). Now the named car is replaced in place. Log tag `RLSMP-REPLACE`. This is the cause behind the duplicate car that 0.4.17 cleans up, so after this build no copy is left behind and that cleanup is only a safety net. (untested; the missing power steering may be a separate problem) (Claude B)

## 0.4.17
- Duplicate car after changing parts: when RLS replaces a car, a leftover copy (same model and plate, not the car RLS keeps) is deleted after 4 seconds. Never the car you sit in or other players' cars. This heals the symptom; the real cause (the old car not being removed on a part change) is not found yet. Log line: `dedupe: deleting stale copy`. (untested) (Claude A)

## 0.4.16
- Stuck traffic: an AI car that has not moved for 30 seconds (honking, jammed) is recycled by RLS, one car every 5 seconds at most. Never a car you can see, never one near or visible to another player, never police, job or chase cars. (untested) (Claude A)

## 0.4.15
- Smart traffic: AI cars get driver personalities (default mix 80% normal, 10% slow, 6% aggressive, 3% racer, 1% drunk, all in `config.json` under `smartTraffic`). Drunk drivers weave and brake hard, racers drive fast. All keep their lane. No hints, you spot them by how they drive. Cops react to racers and drunk drivers (at most one chase per minute). Off switch: `smartTraffic.enabled`. (untested) (Claude A)

## 0.4.14
- Police: only the cops tied to your chase are frozen (the one that sees you, the roadblock unit, any police within 300 m), others stay free. Our police wrappers survive RLS replacing the functions. (untested) (Claude A)
- Each game reports its position and chase state to the server every few seconds (`/where` shows what the server has). Groundwork for server-directed traffic. (untested) (Claude A)
- Shared dealership stock: the server can give everyone the same listings. Off by default (`shop.shared`); new listings still differ per player and sales are not live yet. (untested) (Claude A)

## 0.4.13
- Traffic bubble: a traffic car is only recycled when it is more than 450 m from every other player and none can see it. (untested) (Claude A)

## 0.4.12
- Traffic quota can go back up when a player leaves. Your own traffic setting is restored when you leave the server. (Claude A)
- Traffic is not cut in the middle of a police chase. (Claude A)
- Chase timer in the log uses real time. (untested) (Claude A)

## 0.4.11
- Save download waits for the game to confirm progress, so a busy game is not flooded. Fixes downloads freezing part way (seen at 129 and 153 of 177 pieces). (untested) (Claude A)

## 0.4.10
- Joining a server a second time without restarting the game now starts the mod again (log showed it never started). (joined fine for one player) (Claude A)
- Lost save pieces are asked for again after 4 seconds of silence. (Claude A)

## 0.4.9
- Shared time of day: the server owns the clock, 45 real minutes per day, same shape as RLS's day (quick dawn and dusk). Sleeping no longer changes time. (untested) (Claude A)

## 0.4.8
- A failed or stuck earlier join no longer blocks the next one. If the "world ready" signal is missed, the join starts after 10 seconds anyway. (untested) (Claude A)

## 0.4.7
- Pink-slip duels (`/duel`): loser's car goes to the winner, held safely on the server in between. Off by default, needs a course in `config.json`. (untested) (Claude A)

## 0.4.6
- Event records only count timed races (not derby, burnout, tractor pull). (Claude A)
- Map travel is blocked on both RLS entry points. (Claude A)
- Cars that already went to a fleet are cleared from your garage if a crash brought them back. (untested) (Claude A)

## 0.4.5
- Event records: finished races are reported and the server announces new records. `/records` lists them. (untested) (Claude A)

## 0.4.4
- Adding a car to the fleet checks the server's own copy of your save and blocks adding the same car twice. (untested) (Claude A)

## 0.4.3
- RLS map travel is blocked online (it would drop you from the server). (untested) (Claude A)
- You can ride the taxi RLS hails for you. Optional passenger rides in other players' cars. (untested) (Claude B)

## 0.4.2
- A dashcam on either car always settles a crash. (Claude A)

## 0.4.1
- The join gives up cleanly (with a message) if the save download stalls, instead of leaving you in plain BeamNG. (Claude A)

## 0.4.0
- Dashcams (`/dashcam`, $100 per car), crash judging and insurance claims (dry run: tells you, takes no money). (Claude A)
- Traffic budget grows with the number of players. (Claude A)

## 0.3.4
- Entering other players' cars or AI traffic is refused up front (no more teleport to the default spawn). (untested) (Claude A)

## 0.3.3
- Name tags are hidden on AI traffic. (untested) (Claude A)

## 0.3.2
- `/unstuck` keeps the car's damage. (untested) (Claude A)

## 0.1.0 to 0.3.1
- Server-side saves tied to your BeamMP account, join handshake, RLS starts on BeamMP. (Claude A)
- Server wallet with money categories (loans, sales and transfers are not refused). (Claude A)
- Business / Syndicate: shared bank, members, shared fleet, payout split, fleet retire. (Claude A)
- `/unstuck` for cars and walkers, map gate for `rls_west_coast`, other players' cars are kept when your career starts. (Claude A)
- Install script, build stamp, wrong-map warning, career reset (`rlsmp reset`), start settings locked, cheats refused. (Claude A)
- Traffic director (shared budget) and police anti-teleport. (Claude B)
