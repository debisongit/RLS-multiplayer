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
3. Also put the **RLS Career Overhaul** mod zip in `Resources/Client/` so players get it.
4. In `ServerConfig.toml`: `Map = "/levels/west_coast_usa/info.json"` and `MaxCars = 100` or more.
5. Start the server once. Edit `Resources/Server/RLS-Career-MP/config/config.json`, then restart.

Console: `rlsmp status`, `rlsmp save`.

## Roadmap

1. ✅ Server-side saves + join handshake + server wallet
2. Duo Business / Syndicate: ✅ shared bank + members (`/biz help`) · next: shared fleet via MPVehicleGE, payout split
3. Distributed traffic director + anti-teleport police pursuits
4. Dealerships, garages, freeroam events, pink-slip races

Docs: [architecture](docs/ARCHITECTURE.md) · [protocol](docs/PROTOCOL.md) · [teamwork rules](docs/COLLAB.md)

## Dev

```bash
tests/run.sh
```
Needs `lua5.3` and `luajit`.

## Credits & license

- [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul) by RLS Modding (AGPL-3.0) – required, not bundled.
- Ideas from [CareerMP](https://github.com/StanleyDudek/CareerMP) by Dudekahedron (no code copied; it has no license file).
- This project: AGPL-3.0-only (see `LICENSE`), to match RLS.
