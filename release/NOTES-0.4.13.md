## RLS-Career-MP 0.4.13 (pre-release)

Play **RLS Career Overhaul** together on **BeamMP**. Your career is saved on the server, tied to your BeamMP account.

> **Status:** passes all automatic tests. Joining was confirmed on 0.4.10 for one player; builds 0.4.11 to 0.4.13 are **not played in-game yet**.

### Highlights
- **Server saves**: join and your career loads from the server, every RLS save goes back. The server keeps the money truth.
- **Duo Business**: shared bank, members, payout split, shared fleet (`/biz help`).
- **Dashcams and insurance claims** (`/dashcam`): crash verdicts, still a dry run (no money moves).
- **Shared time of day**: the server owns the clock, 45 real minutes per day, RLS day shape.
- **Traffic**: server budget grows with players, quota goes back up when someone leaves, cars are not recycled near other players, no traffic cuts during a police chase.
- **Safety nets**: save download waits for your game and resends lost pieces; rejoining restarts the mod cleanly; map travel is blocked online.
- **World**: event records (`/records`), pink-slip duels (`/duel`, off by default).
- **Quality of life**: `/unstuck` (cars and on foot, keeps damage), you can't enter other players' cars or AI traffic.

### Install (server owner)
1. Download `RLS-Career-MP-0.4.13.zip` below and unzip it.
2. Copy its `Resources` folder into your BeamMP server folder (merge; your config, profiles and businesses are kept).
3. Put the **RLS Career Overhaul** zip in `Resources/Client/` too, and keep no second copy in your own mods folder.
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` and `MaxCars = 100` or more.
5. Restart the server. **Players restart BeamNG once after an update.**

### Known gaps
- Server only checks wallet money, not bank accounts, loans or mortgages.
- A recycled traffic car can still appear ahead of you in view of another player.
- Auctions and shop stock are different for every player.
- Duels need a course set up in `config.json` and have never been played.

Full history: [CHANGELOG.md](https://github.com/debisongit/rls-multiplayer/blob/claude/amazing-sagan-kh6ecn/CHANGELOG.md)
