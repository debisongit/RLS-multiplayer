# Handoff: take over from Claude A (written at 0.4.14)

Read first: `docs/HANDOFF_CLAUDE_B.md` (architecture, lessons, rules), `docs/COLLAB.md`, `docs/PROTOCOL.md`, `docs/DESIGN_THEFT_PLATES_TRAFFIC.md` (owner's decisions for the next features), `CHANGELOG.md`.
Branch: **`claude/amazing-sagan-kh6ecn`** (only push there; always `git fetch origin claude/amazing-sagan-kh6ecn && git rebase origin/claude/amazing-sagan-kh6ecn` before pushing; `tests/run.sh` must pass; no PR unless asked).
Repo on GitHub: `debisongit/rls-multiplayer` (default listing shows our branch).

## Working with the owner (important)
- Not a professional developer. Short, plain, relaxed answers, almost no em dashes, no jargon walls. Label anything not played in-game as **untested**.
- They test in-game with a friend and send `beamng.log` (client) and the server console log. A separate person hosts the server and must re-run `tools/install_to_server.sh <server folder>` after every update (the log shows it was forgotten before). Players should restart BeamNG once after an update.
- They like being asked design questions (use AskUserQuestion, 4 at a time, with a recommended first option). Decide small things yourself.
- Never edit RLS or BeamMP files. Never copy CareerMP code.

## State right now
- **Latest build: 0.4.14** (all `tests/run.sh` suites pass). GitHub Release page `v0.4.13` exists (zip attached); the **v0.4.14 release workflow run succeeded** (check the Releases page for the zip).
- Last confirmed in-game by the owner: joining on 0.4.10 for one player; the other player's download stalled (153/177 or 129/177 pieces). 0.4.11 added flow control (server sends in a window of 24 chunks and waits for `rlsmpChunkProgress`) and 0.4.10 added resend. **Nothing from 0.4.11 to 0.4.14 has been played.** First thing to ask the owner: did the save download finish with 0.4.11+? If not, get the server console lines (`[rlsmp-timing]`, "asked for N missing chunks").
- Server log noise they sent (harmless): `zlib uncompress() failed, trying with a larger buffer` (BeamMP unpacking a big upload burst) and `Ignored a change to ...difficultyMode.json` (RLS rewrote a locked start-settings file; server keeps its copy). Could lower that log line to debug.

## How releases work
1. Bump `M.BUILD` in `Resources/Server/RLS-Career-MP/lua/rlsmp/shared/transfer.lua` and `cp` it over `Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/lib/transfer.lua` (a test enforces identical files).
2. Add a section to `CHANGELOG.md` (plain language, mark "(untested)").
3. Write `release/NOTES-<build>.md` (copy the previous one, change the "New in" part) then run `tools/make_release.sh` (runs the tests, builds `release/RLS-Career-MP-<build>/` and the zip).
4. Commit, rebase, push.
5. Publish: the sandbox cannot push tags or call a create-release API, but the GitHub MCP tool **`mcp__github__actions_run_trigger`** (method `run_workflow`, owner `debisongit`, repo `rls-multiplayer`, workflow `release.yml`, ref `claude/amazing-sagan-kh6ecn`, inputs `{"version":"0.4.15"}`) starts `.github/workflows/release.yml` on the owner's account. It builds the zip and creates a **pre-release** (or attaches the zip if the release page already exists). Check the run with `actions_list`.
   Note: tag `v0.4.13` already exists remotely at an older commit.

## Unmerged work in progress (two background helpers were still running)
Helpers work in git worktrees under `.claude/worktrees/agent-*` (git-ignored) and commit there; their commits are visible from the main repo, so merge with `git cherry-pick <hash>` (resolve `tests/run.sh` conflicts by keeping both lines). Check `git branch -a` for `worktree-agent-*` branches and `git log <branch>`.
1. **Smart traffic personalities** (agent id `a4eaee6d7a64f1b48`, branch `worktree-agent-a4eaee6d7a64f1b48`): server `smartTraffic.lua` + client `rlsmp/personalities.lua`. If its commit exists, review it, cherry-pick, run tests, bump to 0.4.15, changelog, release. If nothing was committed, rebuild from the spec in `docs/DESIGN_THEFT_PLATES_TRAFFIC.md` section 1 (mix 80/10/6/3/1, drunk weaves by toggling `ai.driveInLane`, racers high aggression, no hints, cops chase racers/drunk, rate limited, config `smartTraffic`).
2. **Research on plates/paint/police/parked cars/inventory/parts/items** (agent id `ad89ba09d931bd98d`): read-only; its report may not have reached you. If missing, redo it: where RLS stores plate text, VIN or any unique car identity, paint, how police offenses/pursuits start (`overhaul/integration/ownedServices/trafficVehicle.lua`, `integration/services/police.lua`), parked car spawn and "simplified" state, `overhaul_career_garage_inventory.addVehicle`, part inventory, any item system. RLS source copy is at `/tmp/claude-0/-home-user-RLS-multiplayer/fadd21f2-00bc-5e48-a402-13b67bf3f6be/scratchpad/src/rls_career_overhaul/` (may be gone in a new container; re-clone `https://github.com/RLS-Modding/rls_career_overhaul` read-only).

## Next features (owner's order and decisions are in `docs/DESIGN_THEFT_PLATES_TRAFFIC.md`)
1. **Smart traffic** (above).
2. **Plate reading and police records**: cop reads plate within ~15 m, under ~50 km/h, 3 to 6 s, letter by letter, progress shown to the player; record belongs to the plate, shared server-wide (server module keeps `plateFlags`, flag ~2 real hours, plate change clears it; model+color memory ~20 min, repaint clears; flagged plate = instant chase, cop skips 1 in 5). Needs the research result for where plates/paint live and a hook to start a pursuit.
3. **Car theft**: server picks a few parked cars per area per session (same for all players), they spawn non-simplified; short timed actions (hold key, progress bar, noise) with methods by car value/year (window + screwdriver, signal cloning device, harder ones TBD); witness check then report after 30-120 s (seen) or ~10 min (unseen); strip for parts / resell after changing plate + VIN + a part number / gamble; caught in a reported car = chase, fine, car taken back. **Answered**: items come from a custom black market (phone app + drop spot), tools last forever, invite + reputation access, theft methods by car age are in the design doc. **Still to ask**: how reputation is earned and lost, invites per player, drop spot rules, prices.
   `rlsmp/vehicleGuard.lua` currently blocks entering any non-owned car; theft needs an exception path (its comment says "A future steal feature would add its exception in isBlocked()").

## Other open items
- Phase 3 leftovers: `docs/PHASE3_LEFT.md` (spawn half of the bubble, field test of the police freeze: do frozen cops still chase, `RELEASED/FROZE/rewrapped` log lines).
- Server positions exist now (`server/positions.lua`, `/where`); traffic quota does not use them yet (ideas: group players within ~500 m, skip cuts for chased players, zone weights).
- Shared shop stock (`server/shop.lua`) is built but **off** (`shop.shared`); it still needs a client wrap (`vehicleShopping/stock` `.new` -> `updateVehicleList`) and live sale events to be useful.
- Pink-slip duels (`server/duel.lua`) are off; need a `duel.courses` entry and a real test with spare cars.
- Known money gaps: server checks wallet money only, not bank, loans, mortgages.
- Marketplace ETK -> other car swap, "flicking" desync when looking around: never reproduced or explained.
- Quality notes: all new events must be in `docs/PROTOCOL.md`; one BeamMP event name = one handler; wrap RLS functions once per module table and re-check identity every frame; use `os.time()` not `os.clock()` for real time.
