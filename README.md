# RLS-Career-MP (RLS Multiplayer)

A comprehensive multiplayer synchronization framework and server suite that enables full **RLS Career Overhaul** gameplay over **BeamMP** servers in BeamNG.drive.

**Current Version:** `v0.4.26`

---

## Overview

**RLS-Career-MP** bridges single-player career mechanics with dedicated multiplayer sessions. It synchronizes player economies, dynamic traffic, garages, law enforcement encounters, custom license plates, and competitive PvP systems across all connected clients.

---

## Key Features

### 💰 Economy & Progression
- **Synchronized Wallets & Banking (`wallet`):** Shared server-side tracking of cash and bank balances.
- **Player Shops & Marketplaces (`shop`, `market`):** Purchase career items, parts, and exchange goods or vehicles with other connected players.
- **Business Systems (`business`):** Operate career businesses and generate passive income within a multiplayer session.
- **Item Synchronization (`items`):** Sync inventory items, mission delivery containers, and cargo.
- **Save State Persistence (`profiles`, `saveBridge`):** Persistent server-backed career profiles with recovery logic and client save bridging.

### 🏁 Competitive & Multiplayer Systems
- **Street Duels & Betting (`duel`):** Challenge nearby players to head-to-head sprint or drag races with configurable wagers.
- **Fleet Management (`fleet`):** Manage owned vehicles across multiple garages and summon fleet cars without losing state.
- **Proximity Bubbles & Spatial Tracking (`bubble`, `positions`):** High-frequency position relaying filtered by proximity grid bubbles to maximize network performance.

### 🚨 Law Enforcement, Theft & Ownership
- **License Plate Management (`plates`, `plateRecords`, `plateRead`):** Dynamic registration plate detection, vehicle identification, and state database records.
- **Vehicle Theft Mechanics (`theft`):** Steal parked or abandoned vehicles, hotwire ignitions, and trigger wanted statuses.
- **Police Interventions (`police`, `trafficPolice`):** Synchronized police responses, radar checks, road blockades, and pursuit events.

### 🚗 Smart Synchronized Traffic
- **Coordinated Traffic Lifecycle (`traffic`, `smartTraffic`):** Server-managed AI traffic density to balance CPU load across clients.
- **Vehicle Variety & Custom Swapping (`trafficVariety`, `trafficSwap`):** Diverse traffic pools matched to the player's level, map region, and current economy bracket.
- **Driver AI Personalities (`personalities`):** Distinct driving traits (aggressive, cautious, erratic) synced across clients.
- **Overhead Status & Labels (`trafficLabels`):** Real-time UI markers for AI, traffic roles, player vehicles, and pursuit targets.
- **In-Game Settings Menu (`trafficMenu`, `trafficAdmin`):** press `[` (or `/trafficmenu`): every player can change the traffic, theft, fence, black market, police and weather settings; the server checks the ranges and logs each change.

### 🛠️ Stability, Guards & Network QoL
- **Deduplication Engine (`dedupe`):** Prevents duplicate ghost vehicles on connect/reconnect.
- **Lifecycle Guards (`vehicleGuard`, `removeGuard`, `replaceGuard`):** Protects active vehicles against unexpected despawns and client-side overwrite conflicts.
- **World & Environment Sync (`clock`, `weather`, `world`):** Synchronizes dynamic time-of-day progression, sun angles, and ambient weather.
- **Auto-Recovery Utilities (`unstuck`, `unjam`):** Safe collision unstuck routines and network queue unjamming mechanisms.
- **Map Loading Protection (`mapGate`, `downloadWatch`):** Prevents premature script initialization until maps, assets, and dependencies finish loading.

---

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── release.yml                 # Automated release packaging CI workflow
├── docs/                               # Developer and architecture documentation
│   ├── ARCHITECTURE.md                 # System overview, state machines, and lifecycle
│   ├── COLLAB.md                       # Collaborative workflow notes
│   ├── DESIGN_THEFT_PLATES_TRAFFIC.md  # Detailed theft, plates & traffic specs
│   ├── DESIGN_TRAFFIC_VARIETY.md       # Procedural traffic pooling architecture
│   ├── FIELD_TEST_PHASE3.md            # Multiplayer test logs and bench data
│   ├── HANDOFF_CLAUDE_B.md             # Subsystem state documentation
│   ├── HANDOFF_CLAUDE_NEXT.md          # Implementation handoff notes
│   ├── NEXT_FEATURES.md                # Roadmapped enhancements
│   ├── PHASE3_LEFT.md                  # Milestone task tracking
│   ├── PROTOCOL.md                     # Packet specifications and event formats
│   ├── RESEARCH_PLATES_THEFT.md        # Technical research on plate binding
│   └── RLS_MAP.md                      # Map integration notes (West Coast USA, etc.)
├── release/                            # Pre-compiled zip archives and release notes
│   ├── NOTES-0.4.13.md ... NOTES-0.4.26.md
│   ├── RLS-Career-MP-0.4.26.zip        # Ready-to-deploy release package
│   └── RLS-Career-MP-0.4.26/           # Unpacked release mirror
├── Resources/
│   ├── Client/
│   │   └── RLS-Career-MP/              # BeamNG client extension mod
│   │       ├── locales/translations/   # Localization files (en-US, etc.)
│   │       ├── lua/ge/extensions/rlsmp/# Client-side Lua extensions & libraries
│   │       ├── scripts/rls_career_mp/  # Lifecycle bootstrap script (modScript.lua)
│   │       └── settings/inputmaps/     # Custom keybinds (e.g., keyboard_rlsmp.json)
│   └── Server/
│       └── RLS-Career-MP/              # BeamMP server plugin
│           ├── lua/rlsmp/server/       # Server authority Lua modules
│           ├── lua/rlsmp/shared/       # Shared utility libraries
│           └── main.lua                # Server entry point
├── tests/                              # Standalone unit & integration test suite
│   ├── support/json.lua                # Headless JSON test mock
│   ├── run.sh                          # Headless Lua test runner
│   └── *_test.lua                      # Subsystem test files (traffic, theft, claims, etc.)
├── tools/                              # Automation and deployment toolchain
│   ├── build_client_zip.sh             # Compiles Resources/Client into a mod zip
│   ├── install_to_server.sh            # Auto-installs client/server mods to BeamMP directory
│   └── make_release.sh                 # Packages a versioned distribution release
├── CHANGELOG.md                        # Version-by-version release history
├── LICENSE                             # GNU AGPLv3 license terms
└── README.md                           # Main documentation
```

---

## Installation & Setup

### Requirements
- **BeamNG.drive** (v0.38+ / v0.40+)
- **[BeamMP Server](https://github.com/BeamMP/BeamMP-Server)** (v3.0.0+)
- **[RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul)** (`rls_career_overhaul.zip` client mod)

---

### Method 1: Using Pre-Built Releases (Recommended)

1. Navigate to the [`release/`](release/) folder (or GitHub Releases tab) and download **`RLS-Career-MP-0.4.26.zip`**.
2. Extract the archive contents:
   - Place `RLS-Career-MP.zip` (located inside `Resources/Client/`) into your server's `Resources/Client/` directory.
   - Ensure `rls_career_overhaul.zip` is also present inside your server's `Resources/Client/` folder.
   - Copy the `Resources/Server/RLS-Career-MP/` folder directly into your server's `Resources/Server/` directory.
3. Configure your server in `ServerConfig.toml`:
   ```toml
   Name = "RLS Career Overhaul Multiplayer"
   Port = 30814
   AuthKey = "YOUR_BEAMMP_AUTHKEY"
   Map = "/levels/west_coast_usa/info.json"
   MaxCars = 100
   MaxPlayers = 10
   ```
4. Start `BeamMP-Server`. Connected clients will automatically download the mod pack upon joining.

---

### Method 2: Building From Source

If you clone the repository directly or develop custom modules, use the automation scripts in `tools/`:

```bash
# 1. Clone the repository
git clone https://github.com/debisongit/RLS-multiplayer.git
cd RLS-multiplayer

# 2. Build the client mod zip (produces Resources/Client/RLS-Career-MP.zip)
chmod +x tools/*.sh tests/*.sh
./tools/build_client_zip.sh

# 3. Direct deployment to a local BeamMP server
./tools/install_to_server.sh /path/to/your/BeamMP-Server

# 4. (Optional) Bundle a new versioned release archive
./tools/make_release.sh
```

---

## Testing & Quality Assurance

The project includes an isolated Lua test suite covering serialization, network events, traffic state machines, and ownership logic.

Run the tests locally using:

```bash
./tests/run.sh
```

To run individual component tests:
```bash
lua tests/theft_test.lua
lua tests/traffic_variety_server_test.lua
lua tests/market_test.lua
```

---

## Network Architecture & Protocol

All client-server messages are handled via BeamMP custom events prefixed with the module namespace (e.g., `rlsmp:theft`, `rlsmp:duel`, `rlsmp:traffic`).

Key sync channels:
- **`rlsmp:wallet`**: Authoritative currency, transactions, and balance transfers.
- **`rlsmp:traffic`**: Spawn queue assignments, seed broadcasts, and state handoffs.
- **`rlsmp:claims`**: Plate registration data and legal ownership verification.
- **`rlsmp:duel`**: Challenge handshake, state verification, waypoint trigger, and payoff resolution.

For full payload layouts and event arguments, consult [`docs/PROTOCOL.md`](docs/PROTOCOL.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Credits & Acknowledgments

This project is built upon open-source tooling and the collective work of the BeamNG and BeamMP modding communities:

- **[RLS Modding](https://github.com/RLS-Modding)** — Creators of [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul), [MPFreeroamEvents](https://github.com/RLS-Modding/MPFreeroamEvents), and [ModConflictResolver](https://github.com/RLS-Modding/ModConflictResolver).
- **[BeamMP Team](https://beammp.com/)** — Creators of the BeamMP multiplayer client mod and dedicated server framework.
- **[StanleyDudek (Dudekahedron)](https://github.com/StanleyDudek/CareerMP)** — Foundational pioneer of [CareerMP](https://github.com/StanleyDudek/CareerMP), establishing early prototypes for multiplayer career synchronization.
- **Project Contributors** — Developed and maintained by [debisongit](https://github.com/debisongit) and project contributors, assisted by Claude Code.

*Disclaimer: This is an unofficial community project and is not affiliated with, endorsed by, or sponsored by BeamNG GmbH or the BeamMP Team.*

---

## License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)** to maintain compatibility with upstream mod dependencies ([RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul) and [BeamMP](https://github.com/BeamMP/BeamMP)).

Under AGPL-3.0:
- You are free to run, study, modify, and share this software.
- If you modify this software and run it on a public server or network, you must make your modified source code available to users under the AGPLv3.

For the full legal terms, refer to the [`LICENSE`](LICENSE) file in the root directory.
