# RLS-Career-MP

Play **RLS Career Overhaul** together on **BeamMP**, with saves stored on the server.

> Status: **Phase 1 (server saves) built and unit-tested, not yet tested in-game.**

## What works (Phase 1)

- Your career is saved **on the server**, tied to your BeamMP account.
- Joining downloads your save and drops you straight into RLS career.
- Every time RLS saves, only the changed files go back to the server.
- The server keeps its own wallet: impossible payouts are refused and edited saves get fixed.

## Install (server owner)

1. Install or update in one command (keeps your config, profiles and businesses):
   ```bash
   tools/install_to_server.sh /path/to/BeamMP-Server
   ```
   This copies the server plugin and builds the client zip into `Resources/Client/`. Re-run it after every update, then restart the server.
3. Put the **RLS Career Overhaul** zip in `Resources/Client/` too. BeamMP switches off every local mod the server does not send, so
   players must not keep a differently named copy of RLS in their own mods folder (that makes RLS load and unload twice).
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` and `MaxCars = 100` or more.
   **This is required**, not optional: on `west_coast_usa` RLS has no starter garage, no garage slots (you cannot buy cars), no auctions or jobs.
   The server logs a warning and tells joining players when the map is wrong.
5. Start the server once. Edit `Resources/Server/RLS-Career-MP/config/config.json`, then restart.

Console: `rlsmp status`, `rlsmp save`, `rlsmp reset <player name or account id>` (archives that career to `profiles/archive/` and drops the player; the next join starts a new one).

Player chat commands: `/records` (event best times); `/dashcam` ($100 per car, makes crash verdicts reliable); `/unstuck` (or `/road`) moves you to the nearest road, in a car or on foot; `/biz help` for the business.

## Troubleshooting

- **Slow join / "Preparing the RLS map..."**: RLS builds `rls_west_coast` on your PC the first time (about a minute) and reuses it afterwards,
  but it deletes that map whenever RLS unloads. A second RLS zip in your own `mods` folder makes BeamMP unload/reload RLS on every join.
  Keep only the server's copy.
- **No garage / can't buy cars**: RLS gives the free starter garage only to brand-new careers. A career first created on the wrong map never gets one.
  Run `rlsmp reset <player>` on the server (the old save is archived), then rejoin. The server warns about such careers when they join.
- **"Your save stopped downloading" / "The server did not send your save"**: the join gave up instead of leaving you in plain BeamNG. Leave and rejoin.
  Your server save is not touched. Send the lines with `[rlsmp-timing]` (the `download N/M chunks` lines show where it stopped) and the server's `[rlsmp-timing] sent profile #N to player N: ... chunks in ...s` line (it is printed only when the whole save has gone out).
- **Check the build**: the client logs `client loaded, build X` and the server logs each player's build on join. They must match.
- **Black character**: `unicycle/beamling.dae` failing to load means a broken game file; use Steam "Verify integrity of game files".
- **Send logs with** the lines containing `[rlsmp-timing]` (join phases) from `beamng.log`.
- Other players' cars are kept when your career starts; if they still look black, send the log.

## Roadmap

1. ✅ Server-side saves + join handshake + server wallet
2. Duo Business / Syndicate: ✅ shared bank + members (`/biz help`) · ✅ shared fleet (`/biz fleet`, untested in-game) · next: payout split
3. Distributed traffic director + anti-teleport police pursuits
4. Dealerships, garages, freeroam events, pink-slip races

Docs: [handoff for Claude B](docs/HANDOFF_CLAUDE_B.md) · [next features and plans](docs/NEXT_FEATURES.md) · [how RLS works](docs/RLS_MAP.md) · [architecture](docs/ARCHITECTURE.md) · [protocol](docs/PROTOCOL.md) · [teamwork rules](docs/COLLAB.md)

## Dev

```bash
tests/run.sh
```
Needs `lua5.3` and `luajit`.

## Credits & license

- [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul) by RLS Modding (AGPL-3.0) – required, not bundled.
- Ideas from [CareerMP](https://github.com/StanleyDudek/CareerMP) by Dudekahedron (no code copied; it has no license file).
- This project: AGPL-3.0-only (see `LICENSE`), to match RLS.
