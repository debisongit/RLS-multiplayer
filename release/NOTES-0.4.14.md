## RLS-Career-MP 0.4.14 (pre-release)

Play **RLS Career Overhaul** together on **BeamMP**. Your career is saved on the server, tied to your BeamMP account.

> **Status:** passes all automatic tests. Joining was confirmed on 0.4.10 for one player; builds 0.4.11 to 0.4.14 are **not played in-game yet**.

### New in 0.4.14
- **Police**: only the cops tied to your chase are frozen, not every police car. Our hooks survive RLS replacing the functions they wrap.
- **Positions**: each game tells the server where it is and whether it is being chased (`/where` shows it). Groundwork for server-directed traffic.
- **Shared dealership stock**: same listings for everyone. Off by default (`shop.shared` in `config.json`). New listings still differ per player.

### Install (server owner)
1. Download `RLS-Career-MP-0.4.14.zip` below and unzip it.
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
