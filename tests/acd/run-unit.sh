#!/bin/bash
# ACD unit tests against the code exactly as shipped in the installer (parser, extraction safety, static checks, notes,
# validators incl. the sandbox, repair pipeline). Needs node; the build/type-check cases need a node_modules with react/vite/typescript:
#   ACD_TEST_NODE_MODULES=<dir> (defaults to the Week 2 tutorial project's node_modules when present).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
INSTALLER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
W="$(cd "$(mktemp -d /tmp/dropacdu.XXXXXX)" && pwd -P)"
NM="${ACD_TEST_NODE_MODULES:-$HOME/Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules}"
[ -d "$NM" ] || { echo "SKIP: no node_modules available (set ACD_TEST_NODE_MODULES)"; exit 0; }
"$HERE/../baseline/extract-main.sh" "$INSTALLER" "$W/full.swift"
LN=$(grep -n '^let app = NSApplication.shared$' "$W/full.swift" | tail -1 | cut -d: -f1)
head -n $((LN-1)) "$W/full.swift" > "$W/main.swift"; cat "$HERE/driver_unit.swift" >> "$W/main.swift"
swiftc -Onone "$W/main.swift" -o "$W/acdu" -framework Cocoa -framework PDFKit -framework Carbon 2>"$W/build.log" || { cat "$W/build.log"; exit 1; }
mkdir -p "$W/proj" "$W/support/toolchain"; cp -R "$HERE/fixtures/starter/." "$W/proj/"; ln -s "$NM" "$W/proj/node_modules"; ln -s "$NM" "$W/support/toolchain/node_modules"
DROP_ACD_DIR="$W/support" "$W/acdu" "$HERE/fixtures/starter" "$W/proj" "$REPO"
