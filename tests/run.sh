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
luajit tests/client_test.lua
luajit tests/fleet_client_test.lua
echo "All tests passed."
