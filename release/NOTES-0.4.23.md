## RLS-Career-MP 0.4.23 (pre-release)

Play **RLS Career Overhaul** together on **BeamMP**. Your career is saved on the server, tied to your BeamMP account.

> **Status:** passes all automatic tests. Joining was confirmed on 0.4.10 for one player; builds 0.4.11 to 0.4.23 are **not played in-game yet**.

### New in 0.4.23
- **Sturdier save download**: fixes for the stalls part way through (the server slows down and resends, your game reports progress, lost start messages are asked for again).
- **Duels** (still off by default): cars come from the server's own copy, cheating the finish is caught.
- Also since 0.4.22: crash claims explain every outcome (set `claims.dryRun` to `false` to make them real), shared weather, safety fixes.

### Install (server owner)
1. Download `RLS-Career-MP-0.4.23.zip` below and unzip it.
2. Copy its `Resources` folder into your BeamMP server folder (merge; your config, profiles and businesses are kept).
3. Put the **RLS Career Overhaul** zip in `Resources/Client/` too, and keep no second copy in your own mods folder.
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` and `MaxCars = 100` or more.
5. Restart the server. **Players restart BeamNG once after an update.**

### Known gaps
- Server only checks wallet money, not bank accounts, loans or mortgages.
- A recycled traffic car can still appear ahead of you in view of another player.
- Auctions are different for every player.
- Duels need a course set up in `config.json` and have never been played.

Full history: [CHANGELOG.md](https://github.com/debisongit/rls-multiplayer/blob/claude/amazing-sagan-kh6ecn/CHANGELOG.md)
