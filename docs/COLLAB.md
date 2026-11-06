# Working together (two Claude sessions + the owner)

The owner decides. Two Claude sessions split the work **by phase** so we rarely touch the same files.

| Area | Owner | Files |
|---|---|---|
| Phase 1 – server saves, handshake, wallet | Claude A | `lua/rlsmp/server/{sessions,profiles,wallet,identity,storage,config,net}.lua`, client `rlsmp/{core,saveBridge,wallet}.lua` |
| Phase 2 – inventory ↔ MPVehicleGE, Business/Syndicate | Claude A | `lua/rlsmp/server/business*.lua`, client `rlsmp/business*.lua`, `rlsmp/inventory*.lua` |
| Phase 3 – Traffic Director, anti-teleport, police pursuits | Claude B | `lua/rlsmp/server/traffic*.lua`, client `rlsmp/traffic*.lua`, `rlsmp/police*.lua` |
| Phase 4 – world interactions | decide later | `rlsmp/world*.lua` |
| Shared | both, small PRs | `shared/transfer.lua`, `server/modules.lua`, `docs/PROTOCOL.md` |

## Rules

1. **Branches**: each session works on its own branch and opens a PR into `main`. Never push to the other's branch.
2. **Events**: prefix by area (`rlsmpBiz*`, `rlsmpTraffic*`, `rlsmpPolice*`). Add every new event to `docs/PROTOCOL.md`.
3. **Server modules**: export `init(cfg, pluginRoot)` and add one line to `server/modules.lua`.
   Use `net.on` / `net.onClient` / `net.send` instead of calling `MP.RegisterEvent` directly.
4. **Config**: add your defaults under your own key in `config.lua` (`traffic = {...}`, `police = {...}`).
5. **Online players**: use `sessions.all()` / `sessions.isLoaded(pid)` – only players with `stage == "loaded"` are in career.
6. **Never edit RLS or BeamMP files.** Wrap functions at runtime like `core.lua` does with `refuseCareerStart`,
   and keep the original so it still works outside multiplayer.
7. **Tests**: `tests/run.sh` must pass before every push. Add a test file for your module.
8. `transfer.lua` exists twice (server + client) and must stay byte-identical (the test checks).

## Notes for Claude B (Phase 3)

- **Read `docs/RLS_MAP.md` section 9 first.** RLS wraps vanilla traffic/police/parking at runtime; its own code is under `lua/ge/extensions/overhaul/integration/services/police.lua`,
  `.../ownedServices/trafficVehicle.lua` and `.../career/police/`. Hook those, not vanilla `gameplay_traffic` only.
- The server knows who is in career via `sessions`. A traffic director can live in `server/traffic.lua`
  and push quotas with `net.send(pid, "rlsmpTrafficQuota", {...})` on join/leave.
