#!/usr/bin/env bash
# Installs (or updates) RLS-Career-MP into a BeamMP server folder in one go:
#   tools/install_to_server.sh /path/to/BeamMP-Server
# Copies the server plugin (keeps your config/, profiles/ and businesses/), and puts a freshly built
# client zip into Resources/Client/. Then restart the server. Players re-download the mod on their next join.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:?usage: install_to_server.sh <BeamMP server folder>}"
[ -d "$dest/Resources" ] || { echo "No Resources/ folder in $dest. Is that the BeamMP server folder?"; exit 1; }

plugin="$dest/Resources/Server/RLS-Career-MP"
mkdir -p "$plugin"
rm -rf "$plugin/lua"
cp -r "$here/Resources/Server/RLS-Career-MP/lua" "$plugin/lua"
cp "$here/Resources/Server/RLS-Career-MP/main.lua" "$plugin/main.lua"

mkdir -p "$dest/Resources/Client"
"$here/tools/build_client_zip.sh" >/dev/null
cp "$here/Resources/Client/RLS-Career-MP.zip" "$dest/Resources/Client/RLS-Career-MP.zip"

build="$(grep -o 'BUILD = "[^"]*"' "$here/Resources/Server/RLS-Career-MP/lua/rlsmp/shared/transfer.lua" | cut -d'"' -f2)"
echo "Installed RLS-Career-MP build $build into $dest"
echo "Next: set  Map = \"/levels/rls_west_coast/info.json\"  in ServerConfig.toml, make sure the RLS Career Overhaul zip is in Resources/Client/, then restart."
