#!/bin/bash
# Real-model check of the ACD pipeline on the mock paper (uses your Ollama and the model you name; unloads it when done).
# usage: run-real.sh <installer.sh> <model> [task-id] [careful]   (default task: acd-mock-ict)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
INSTALLER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; MODEL="$2"; TASK="${3:-acd-mock-ict}"; MODE="${4:-}"; OUTNAME="real-$TASK"
W="$(cd "$(mktemp -d /tmp/dropreal.XXXXXX)" && pwd -P)"
"$HERE/../baseline/extract-main.sh" "$INSTALLER" "$W/full.swift"
LN=$(grep -n '^let app = NSApplication.shared$' "$W/full.swift" | tail -1 | cut -d: -f1)
head -n $((LN-1)) "$W/full.swift" > "$W/main.swift"; cat "$HERE/driver_real.swift" >> "$W/main.swift"
swiftc -Onone "$W/main.swift" -o "$W/realx" -framework Cocoa -framework PDFKit -framework Carbon 2>"$W/build.log" || { cat "$W/build.log"; exit 1; }
mkdir -p "$W/bench/tasks" "$W/acdsupport/notes" "$W/acdsupport/toolchain"; cp -R "$REPO/bench-tasks/." "$W/bench/tasks/"
cp "$REPO/acd-notes/00-conventions.md" "$W/acdsupport/notes/"
NM="${ACD_TEST_NODE_MODULES:-$HOME/Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules}"
[ -d "$NM" ] && ln -s "$NM" "$W/acdsupport/toolchain/node_modules" || true
[ "$MODE" = "careful" ] && defaults write realx acdCareful -bool true || defaults write realx acdCareful -bool false
START=$(date +%s)
DROP_ACD_DIR="$W/acdsupport" DROP_BENCH_DIR="$W/bench" "$W/realx" "http://127.0.0.1:11434" "$MODEL" "$TASK" | tee "$W/run.log"
echo "elapsed: $(( $(date +%s) - START )) s"
mkdir -p "$HERE/out"; OUTDIR="$HERE/out/${OUTNAME}${5:+-$5}"; rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"; cp "$W/bench/results/results.jsonl" "$W/run.log" "$OUTDIR/"; cp "$W/bench/reports/"* "$OUTDIR/" 2>/dev/null || true; cp -R "$W/bench/runs" "$OUTDIR/runs" 2>/dev/null || true
ollama stop "$MODEL" >/dev/null 2>&1 || true
echo "kept: $OUTDIR"
