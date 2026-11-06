# RLS-Career-MP

Play **RLS Career Overhaul** together on **BeamMP**, with saves stored on the server.

> Status: **Phase 1 (server saves) built and unit-tested, not yet tested in-game.**

## What works (Phase 1)

- Your career is saved **on the server**, tied to your BeamMP account.
- Joining downloads your save and drops you straight into RLS career.
- Every time RLS saves, only the changed files go back to the server.
- The server keeps its own wallet: impossible payouts are refused and edited saves get fixed.

## Install (server owner)

1. Copy `Resources/Server/RLS-Career-MP/` into your BeamMP server's `Resources/Server/`.
2. Build the client mod and copy it into `Resources/Client/`:
   ```bash
   tools/build_client_zip.sh
   ```
3. Put the **RLS Career Overhaul** zip in `Resources/Client/` too. BeamMP switches off every local mod the server does not send, so
   players must not keep a differently named copy of RLS in their own mods folder (that makes RLS load and unload twice).
4. In `ServerConfig.toml`: `Map = "/levels/rls_west_coast/info.json"` (needed for auctions, drop-offs, businesses) and `MaxCars = 100` or more.
   Plain `west_coast_usa` works too, but RLS loses its map features there.
5. Start the server once. Edit `Resources/Server/RLS-Career-MP/config/config.json`, then restart.

Console: `rlsmp status`, `rlsmp save`.

Player chat commands: `/unstuck` (or `/road`) moves you to the nearest road, in a car or on foot; `/biz help` for the business.

## Troubleshooting

- **Slow join / "Preparing the RLS map..."**: RLS builds `rls_west_coast` on your PC the first time (about a minute) and reuses it afterwards,
  but it deletes that map whenever RLS unloads. A second RLS zip in your own `mods` folder makes BeamMP unload/reload RLS on every join.
  Keep only the server's copy.
- **Send logs with** the lines containing `[rlsmp-timing]` (join phases) from `beamng.log`.
- Other players' cars are kept when your career starts; if they still look black, send the log.

## Roadmap

1. ✅ Server-side saves + join handshake + server wallet
2. Duo Business / Syndicate: ✅ shared bank + members (`/biz help`) · ✅ shared fleet (`/biz fleet`, untested in-game) · next: payout split
3. Distributed traffic director + anti-teleport police pursuits
4. Dealerships, garages, freeroam events, pink-slip races

Docs: [how RLS works](docs/RLS_MAP.md) · [architecture](docs/ARCHITECTURE.md) · [protocol](docs/PROTOCOL.md) · [teamwork rules](docs/COLLAB.md)

## Dev

```bash
tests/run.sh
```
Needs `lua5.3` and `luajit`.

## Credits & license

- [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul) by RLS Modding (AGPL-3.0) – required, not bundled.
- Ideas from [CareerMP](https://github.com/StanleyDudek/CareerMP) by Dudekahedron (no code copied; it has no license file).
- This project: AGPL-3.0-only (see `LICENSE`), to match RLS.
