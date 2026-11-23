#!/bin/bash
# Extract the Swift source embedded in an installer to a file.
# usage: extract-main.sh <install-drop.sh> <out.swift>
set -e
awk '
  /^cat > "\$DIR\/main.swift" <<'"'"'EOF'"'"'$/ { on=1; next }
  on && /^EOF$/ { exit }
  on { print }
' "$1" > "$2"
test -s "$2"
