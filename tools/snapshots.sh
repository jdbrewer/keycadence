#!/bin/zsh
# Renders every screen of a Debug build to PNGs. Usage: tools/snapshots.sh <output dir>
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$1"
build/Build/Products/Debug/Keycadence.app/Contents/MacOS/Keycadence --snapshot | python3 -I -c '
import base64, sys
out = sys.argv[1]
for line in sys.stdin:
    if line.startswith("SNAPSHOT "):
        _, name, data = line.split()
        open(f"{out}/{name}.png", "wb").write(base64.b64decode(data))
        print(name)
' "$1"
