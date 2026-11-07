#!/usr/bin/env bash
# Builds release/RLS-Career-MP-<build>/ : the server plugin and the client zip, ready to copy into a BeamMP server.
set -euo pipefail
cd "$(dirname "$0")/.."
build="$(grep -o 'BUILD = "[^"]*"' Resources/Server/RLS-Career-MP/lua/rlsmp/shared/transfer.lua | cut -d'"' -f2)"
out="release/RLS-Career-MP-$build"
tests/run.sh >/dev/null
rm -rf release/RLS-Career-MP-*
mkdir -p "$out/Resources/Server/RLS-Career-MP" "$out/Resources/Client"
cp -r Resources/Server/RLS-Career-MP/lua Resources/Server/RLS-Career-MP/main.lua "$out/Resources/Server/RLS-Career-MP/"
tools/build_client_zip.sh >/dev/null
cp Resources/Client/RLS-Career-MP.zip "$out/Resources/Client/"
cp CHANGELOG.md "$out/"
cat > "$out/INSTALL.txt" <<TXT
RLS-Career-MP build $build

1. Copy the Resources folder from here into your BeamMP server folder (merge it; your config, profiles and businesses are not touched).
   Or run: tools/install_to_server.sh /path/to/BeamMP-Server
2. Put the RLS Career Overhaul zip in Resources/Client/ as well.
3. ServerConfig.toml:  Map = "/levels/rls_west_coast/info.json"   and   MaxCars = 100 or more.
4. Restart the server. Players restart BeamNG once after an update.
See README.md for troubleshooting and CHANGELOG.md for what changed.
TXT
(cd release && rm -f RLS-Career-MP-*.zip && zip -qr "RLS-Career-MP-$build.zip" "RLS-Career-MP-$build")
# Hand-written notes (release/NOTES-<build>.md) are kept; otherwise they are cut from the changelog.
if [ ! -f "release/NOTES-$build.md" ]; then
  awk -v v="## $build" '$0==v{p=1;next} /^## /{p=0} p' CHANGELOG.md > "release/NOTES-$build.md"
  echo "" >> "release/NOTES-$build.md"
  echo "Install: unzip, copy the Resources folder into your BeamMP server folder (see INSTALL.txt inside). Full history: CHANGELOG.md." >> "release/NOTES-$build.md"
fi
echo "Release built: $out (+ release/RLS-Career-MP-$build.zip and release/NOTES-$build.md)"
