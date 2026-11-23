#!/bin/bash
# Characterization run of the normal-generation pipeline against a scripted
# mock Ollama. usage: run-baseline.sh <installer.sh> <label>
# Writes tests/baseline/out/<label>/<scenario>.{json,requests.jsonl}
# Compare two labels with: diff -r out/baseline out/after
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; LABEL="$2"
REPO="$(cd "$HERE/../.." && pwd)"
W="$(cd "$(mktemp -d /tmp/dropbase.XXXXXX)" && pwd -P)"; trap 'rm -rf "$W"; kill $MOCK 2>/dev/null || true' EXIT
"$HERE/extract-main.sh" "$INSTALLER" "$W/full.swift"
# drop the final app-launch lines, append the driver
LN=$(grep -n '^let app = NSApplication.shared$' "$W/full.swift" | tail -1 | cut -d: -f1)
head -n $((LN-1)) "$W/full.swift" > "$W/main.swift"; cat "$HERE/driver.swift" >> "$W/main.swift"
swiftc -Onone "$W/main.swift" -o "$W/drophx" -framework Cocoa -framework PDFKit -framework Carbon 2>"$W/build.log" \
  || { cat "$W/build.log"; exit 1; }
# synthetic input: starter project + a short task text (fixture, not an official paper)
mkdir -p "$W/in"; unzip -q "$REPO/SAMPLE/01_SIMPLE_Parking/SIMPLE_Starter_Project.zip" -d "$W/in"
cat > "$W/in/paper.txt" <<'PAPER'
Task 1 Implement HourlyPass.priceCents: round up partial hours, one hour minimum, reject negative stays.
Task 2 Create WeekendPass with a flat price and seed it in the repository; allQuotes sorts by price then id.
Task 3 Validate input and map IllegalArgumentException to 400 and PassNotFoundException to 404 with ApiError.
Task 4 Controller endpoints: GET quote, GET quotes and POST hourly returning HTTP 201.
PAPER
OUT="$HERE/out/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
PORT=$((20000 + RANDOM % 20000))
for SC in pass repair truncated never_fixed http500; do
  python3 "$HERE/mock_ollama.py" $PORT $SC "$OUT/$SC.requests.jsonl" & MOCK=$!
  sleep 0.7
  "$W/drophx" "$W/in" "http://127.0.0.1:$PORT" "$OUT/$SC.json"
  kill $MOCK; wait $MOCK 2>/dev/null || true
  echo "ran $SC"
done
