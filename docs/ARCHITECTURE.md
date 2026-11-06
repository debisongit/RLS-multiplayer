# Architecture

## What we build on (analysis of the two source projects)

**RLS Career Overhaul 2.8.x** (`RLS-Modding/rls_career_overhaul`, AGPL-3.0)
- Lives in its own namespace: `lua/ge/extensions/overhaul/...` → extensions named `overhaul_*`
  (e.g. `overhaul_career_saveSystem`, `overhaul_career_economy_playerAttributes`).
- Boots through `scripts/rls_career_overhaul/modScript.lua` → `overhaul_shell_extensionManager`.
- **Blocks itself on BeamMP**: `overhaul_shell_extensionManager.refuseCareerStart()` returns true when
  the `multiplayerbeammp` mod is active. Everything career-related checks this first.
- Saves: `settings/cloud/overhaul/saves/<profile>/autosaveN/` – many JSON files (+ `.jpg` thumbnails).
  Useful hooks: `onOverhaulSaveFinished`, `onOverhaulActive(active, newSave)`,
  `onOverhaulPlayerAttributesChanged(change, reason)`. `getLastSaveStats().path` = folder just written.
- Career start: `overhaul_shell_gameMode.start(profile, slot, startingOptions)`.
  `startingOptions.startingMap` wins over the level stored in the save.
- Runs on a generated proxy level `rls_west_coast` (built from `west_coast_usa` at runtime).
- Already has its own business, fleet, police and traffic systems we will hook in later phases.

**CareerMP** (`StanleyDudek/CareerMP`)
- Wraps *vanilla* career for BeamMP. Its README says it does not support BeamNG 0.39+, and RLS 2.8
  forks the 0.40 save system, so CareerMP can't be used as a runtime dependency.
- It has **no license file**, so we do not copy its code. We reuse its proven *ideas*:
  start career on `onWorldReadyState(2)`, server-pushed config, vehicle active-state sync,
  synced traffic-light timer, payment rate-limits. These come back in Phase 2–4 as our own code.

## Phase 1 design: server-authoritative saves

```
 Player PC (BeamNG + RLS + our client mod)            BeamMP server (our plugin)
 ───────────────────────────────────────────          ───────────────────────────────
 world ready ── rlsmpHello ───────────────────────▶   load profiles/<beammpId>.json
 write save to disk  ◀─── chunks of the save ─────   (or a new empty one)
 lift RLS's BeamMP block, start career
 career active ── rlsmpLoaded ────────────────────▶   stage = loaded
 every money change ── rlsmpWalletDelta ──────────▶   wallet: accept / refuse (limits)
 RLS save finished ── changed files (chunks) ─────▶   rebuild save, compare money with wallet,
                    ◀── rlsmpUpAck / rlsmpWalletSet   fix cheats, write file (crash-safe)
```

Key rules
- **Identity** = BeamMP account ID (guests refused by default). One session per account.
- **Server wins**: on join the local copy of that profile is wiped and replaced.
- **Money** is double-entry: client reports deltas, server keeps the balance. Gains above
  `maxSingleGain` or over `maxGainPerWindow` are refused. A save whose money disagrees is rewritten.
- **New careers** are "unseeded" until the first save (RLS grants its own starting cash);
  the first saved balance, capped at `maxStartingMoney`, becomes the server's starting point.
- **Bandwidth**: uploads only contain files whose checksum changed; thumbnails are skipped.
- **Map**: careers start on whatever map the server loaded, and `career/general.json` is patched
  to that level, so RLS never tries to switch maps (that would disconnect the player).

## Code map

```
Resources/Server/RLS-Career-MP/
  main.lua                    entry: config, modules, console (`rlsmp status`, `rlsmp save`)
  lua/rlsmp/shared/transfer.lua  chunking + checksum (identical copy on client)
  lua/rlsmp/server/
    modules.lua   list of feature modules (append yours here)
    net.lua       event registration, JSON send, chunked send queue (50 ms pump)
    sessions.lua  handshake, uploads, wallet events, timers
    profiles.lua  profiles/<id>.json load/save, apply uploads
    wallet.lua    server money ledger + limits
    identity.lua  BeamMP account ID, guest policy, local profile name
    storage.lua   crash-safe JSON writes (.tmp → file, .bak fallback)
    config.lua    defaults → config/config.json
Resources/Client/RLS-Career-MP/          (zipped by tools/build_client_zip.sh)
  scripts/rls_career_mp/modScript.lua    loads rlsmp_core
  lua/ge/extensions/rlsmp/
    core.lua        handshake state machine, RLS gate patch, career start
    saveBridge.lua  write server save to disk, diff + upload after each RLS save
    wallet.lua      report money deltas, apply server corrections
    lib/net.lua     client network glue + chunk assembler/uploader
    lib/transfer.lua
tests/            lua5.3 server e2e test, luajit client test (`tests/run.sh`)
```

## Known limits / to verify in-game (Phase 1)

1. **Map**: RLS features (auction, facilities, businesses) live in `levels/rls_west_coast/`, a map RLS generates on the player's PC
   after RLS loads (`overhaul_world_levelProxy`, cache in `/temp/rls_career/levelCache`, rebuilt every time RLS loads).
   BeamMP announces the map ~3 s after it activates the server mods, long before the proxy exists (the log shows it finished ~50 s later).
   Plan: a client "map gate" waits for the proxy before the level loads. Unverified in-game.
2. Needs a live test on BeamNG 0.38/0.39 + BeamMP: event payload size (we use 16 KB chunks),
   `FS:findFiles` path format, and whether RLS's proxy level `rls_west_coast` can be the server map.
   Fallback: server `Map = "/levels/west_coast_usa/info.json"`.
3. RLS shows a one-time "doesn't work with BeamMP" toast at boot (before our patch runs). Harmless.
4. RLS's other money stores (bank accounts, loans) are not server-checked yet → Phase 2.
5. The ESC menu can still load another local profile while online → block in Phase 2.
6. Progress since the last save (up to `forceSaveMinutes`) is lost if the game crashes.
