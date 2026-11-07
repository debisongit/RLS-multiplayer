## RLS-Career-MP 0.4.24 (pre-release)

Play **RLS Career Overhaul** together on **BeamMP**. Your career is saved on the server, tied to your BeamMP account.

> **Status:** passes all automatic tests. Joining was confirmed on 0.4.10 for one player; builds 0.4.11 to 0.4.24 are **not played in-game yet**.

### New in 0.4.24
- **Plate reading and police records**: cops read your plate when close and slow. Escape a chase and your plate is flagged for 2 hours (and your car's model and colour are remembered for 20 minutes). A flagged plate gets an instant chase. Change the plate or repaint to clear it. Settings: `police.plateReading` in `config.json`.
- Also since 0.4.23: sturdier save download, crash claims explain every outcome, shared weather, duel safety fixes (duels stay off by default).

### Install (server owner)
1. Download `RLS-Career-MP-0.4.24.zip` below and unzip it.
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
