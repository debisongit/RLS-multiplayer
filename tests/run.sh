#!/usr/bin/env bash
# Runs all tests. Needs lua5.3 (BeamMP server Lua) and luajit (BeamNG Lua).
set -euo pipefail
cd "$(dirname "$0")/.."

# The shared transfer lib must be identical on both sides.
cmp Resources/Server/RLS-Career-MP/lua/rlsmp/shared/transfer.lua \
    Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/lib/transfer.lua \
  || { echo "transfer.lua copies differ! Copy the server one over the client one."; exit 1; }

# Syntax check every Lua file with the matching interpreter.
find Resources/Server -name '*.lua' -print0 | xargs -0 -n1 luac5.3 -p
find Resources/Client -name '*.lua' -print0 | while IFS= read -r -d '' f; do luajit -bl "$f" >/dev/null; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
lua5.3 tests/server_test.lua "$tmp"
lua5.3 tests/business_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/traffic_labels_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/claims_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/events_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/duel_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/clock_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/resend_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/positions_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/shop_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/items_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/plate_records_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/traffic_test.lua
lua5.3 tests/traffic_police_test.lua
lua5.3 tests/traffic_variety_server_test.lua
lua5.3 tests/traffic_admin_test.lua "$(mktemp -d -p "$tmp")"
lua5.3 tests/weather_test.lua
lua5.3 tests/smart_traffic_test.lua
lua5.3 tests/vehicles_test.lua
luajit tests/client_test.lua
luajit tests/download_watch_test.lua
luajit tests/fleet_client_test.lua
luajit tests/guard_test.lua
luajit tests/replace_guard_test.lua
luajit tests/claims_client_test.lua
luajit tests/traffic_labels_client_test.lua
luajit tests/unstuck_test.lua
luajit tests/bubble_test.lua
luajit tests/unjam_test.lua
luajit tests/dedupe_test.lua
luajit tests/clock_client_test.lua
luajit tests/core_start_test.lua
luajit tests/world_client_test.lua
luajit tests/duel_client_test.lua
luajit tests/join_protect_test.lua
luajit tests/traffic_client_test.lua
luajit tests/traffic_variety_lib_test.lua
luajit tests/traffic_menu_lib_test.lua
luajit tests/traffic_menu_client_test.lua
luajit tests/traffic_variety_client_test.lua
luajit tests/traffic_swap_lib_test.lua
luajit tests/traffic_swap_client_test.lua
luajit tests/weather_client_test.lua
luajit tests/police_client_test.lua
luajit tests/positions_client_test.lua
luajit tests/personalities_client_test.lua
luajit tests/plate_read_lib_test.lua
luajit tests/plates_client_test.lua
echo "All tests passed."
