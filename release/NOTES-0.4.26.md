## RLS-Career-MP 0.4.26 (pre-release)

Play **RLS Career Overhaul** together on **BeamMP**. Your career is saved on the server, tied to your BeamMP account.

> **Status:** passes all automatic tests. Joining was confirmed on 0.4.10 for one player. Builds 0.4.11 to 0.4.26 are **not played in-game yet**, so expect bugs and send your `beamng.log` and the server console log.

### New since 0.4.13
- **Black market** (chat commands): invite plus reputation, order tools and papers, pick them up at a drop spot. First member: `rlsmp market grant <player>` in the server console.
- **Car theft** (**off by default**, set `theft.enabled` to `true`): steal a few parked cars with the right tools. Stolen cars can't be sold or stripped yet.
- **Plate reading and police records**: cops read your plate when close and slow. Escape a chase or get arrested and your plate is flagged for 2 hours (and your car's model and colour are remembered for 20 minutes). A flagged plate gets an instant chase. Change the plate or repaint to clear it.
- **Smart traffic**: AI drivers have personalities (normal, slow, aggressive, racer, drunk). Stuck cars are recycled one by one. Traffic uses more varied cars.
- **Shared weather and a shared 45 minute day**: everyone sees the same sky.
- **Crash claims explain themselves**: if a crash gets no verdict, you see why. Set `claims.dryRun` to `false` in `config.json` to make claims real (the default only shows "TEST MODE").
- **Sturdier save download**: fixes for the stalls part way through, and for joining a second time without restarting the game.
- **Part shop fix**: changing parts no longer leaves a second copy of your car.
- **Safety fixes** from a code review (freeze when the game replaces a car, duplicate-car cleanup, police chase logic, duels).

### Install (server owner)
1. Download `RLS-Career-MP-0.4.26.zip` below and unzip it.
2. Copy its `Resources` folder into your BeamMP server folder (merge; your config, profiles and businesses are kept).
3. Put the **RLS Career Overhaul** zip in `Resources/Client/` too, and keep no second copy in your own mods folder.
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` and `MaxCars = 100` or more.
5. Restart the server. **Players restart BeamNG once after an update.**

### Known gaps
- Stolen cars can't be stripped, resold or sold to the fence yet.
- The black market has no phone app yet.
- Pink-slip duels are off by default and have never been played.
- Shared dealership stock is off by default (`shop.shared`) and only half-built.
- Server only checks wallet money, not bank accounts, loans or mortgages.
- A recycled traffic car can still appear ahead of you in view of another player.

Full history: [CHANGELOG.md](https://github.com/debisongit/rls-multiplayer/blob/claude/amazing-sagan-kh6ecn/CHANGELOG.md)
