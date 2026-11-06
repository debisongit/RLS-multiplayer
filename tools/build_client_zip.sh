#!/usr/bin/env bash
# Packs the client mod folder into the .zip that BeamMP sends to players.
# Output: Resources/Client/RLS-Career-MP.zip
set -euo pipefail
cd "$(dirname "$0")/.."
src="Resources/Client/RLS-Career-MP"
out="$PWD/Resources/Client/RLS-Career-MP.zip"
rm -f "$out"
python3 - "$src" "$out" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src).replace(os.sep, "/"))
PY
echo "Built $out"
