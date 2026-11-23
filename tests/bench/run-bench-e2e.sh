#!/bin/bash
# End-to-end check of benchmark mode against a scripted mock Ollama:
#   qwen-ref    returns the staff reference solutions        -> everything passes
#   qwen-mutant returns a subtly wrong solution per task     -> specific tests fail
#   qwen-broken returns code with a compile error, then the fix on the repair round
# usage: run-bench-e2e.sh <installer.sh>
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
INSTALLER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
W="$(cd "$(mktemp -d /tmp/dropbench-e2e.XXXXXX)" && pwd -P)"; trap 'kill $MOCK 2>/dev/null || true' EXIT
"$HERE/../baseline/extract-main.sh" "$INSTALLER" "$W/full.swift"
LN=$(grep -n '^let app = NSApplication.shared$' "$W/full.swift" | tail -1 | cut -d: -f1)
head -n $((LN-1)) "$W/full.swift" > "$W/main.swift"; cat "$HERE/driver_bench.swift" >> "$W/main.swift"
swiftc -Onone "$W/main.swift" -o "$W/benchx" -framework Cocoa -framework PDFKit -framework Carbon 2>"$W/build.log" || { cat "$W/build.log"; exit 1; }
mkdir -p "$W/bench/tasks"; cp -R "$REPO/bench-tasks/." "$W/bench/tasks/"
# ACD support dir: notes + (when available) a TypeScript toolchain so the tsc-based check can run
mkdir -p "$W/acdsupport/notes" "$W/acdsupport/toolchain"; cp "$REPO/acd-notes/00-conventions.md" "$W/acdsupport/notes/"
NM="${ACD_TEST_NODE_MODULES:-$HOME/Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules}"
[ -d "$NM" ] && ln -s "$NM" "$W/acdsupport/toolchain/node_modules" || true
python3 - "$REPO/bench-tasks" "$W/sol" <<'PY'
import sys, os, shutil
bt, sol = sys.argv[1:]
mut = {  # task -> (file, from, to)  one subtle bug each
 "simple-parking": ("model/WeekendPass.java", "(stayMinutes-480L+59)/60", "(stayMinutes-480L)/60", "edu/practice/parking"),
 "moderate-dispatch": ("service/DispatchService.java", ".thenComparingInt(DispatchMission::energyUnits)", ".thenComparingInt(m->-m.energyUnits())", "edu/practice/dispatch"),
 "extreme-scheduler": ("service/SchedulerService.java", "for(int t=s;t<s+w.getDurationTicks()&&fits;t++){", "for(int t=s;t<s+1&&fits;t++){", "edu/practice/scheduler"),
}
brk = {  # task -> (file, from, to)  a compile error in one file
 "simple-parking": ("model/HourlyPass.java", "long hours=(stayMinutes+59L)/60;", 'long hours="x";'),
 "moderate-dispatch": ("model/GroundMission.java", "long e=2L*getDistanceKm()+5L*getLoadKg();", 'long e="x";'),
 "extreme-scheduler": ("model/BatchWorkload.java", "long age=Math.max(0L,(long)nowTick-getReleaseTick());", 'long age="x";'),
}
for t,(f,a,b,pkg) in mut.items():
    ref = os.path.join(bt, t, "reference")
    for who in ("ref", "mutant", "broken"):
        shutil.copytree(ref, os.path.join(sol, who, t))
    p = os.path.join(sol, "mutant", t, "src/main/java", pkg, f); s = open(p).read(); assert a in s, (t, a); open(p, "w").write(s.replace(a, b, 1))
    f2, a2, b2 = brk[t]
    p = os.path.join(sol, "broken", t, "src/main/java", pkg, f2); s = open(p).read(); assert a2 in s, (t, a2); open(p, "w").write(s.replace(a2, b2, 1))
    fixdir = os.path.join(sol, "broken", t + "_fix", "src/main/java", pkg, os.path.dirname(f2)); os.makedirs(fixdir)
    shutil.copy(os.path.join(ref, "src/main/java", pkg, f2), fixdir)
PY
PORT=$((20000 + RANDOM % 20000))
BENCH_TASKS_DIR="$REPO/bench-tasks" BENCH_SOL_DIR="$W/sol" MOCK_MODELS="qwen-ref:1b,qwen-mutant:1b,qwen-broken:1b" python3 "$HERE/../baseline/mock_ollama.py" $PORT bench "$W/requests.jsonl" & MOCK=$!
sleep 0.7
DROP_ACD_DIR="$W/acdsupport" DROP_BENCH_DIR="$W/bench" "$W/benchx" "http://127.0.0.1:$PORT" | tee "$W/run.log"
mkdir -p "$HERE/out"; rm -rf "$HERE/out/last"; mkdir -p "$HERE/out/last"
cp "$W/bench/results/results.jsonl" "$HERE/out/last/"; cp "$W/bench/reports/"* "$HERE/out/last/" 2>/dev/null || true; cp "$W/run.log" "$HERE/out/last/"
echo "kept: $HERE/out/last"

python3 - "$HERE/out/last/results.jsonl" <<'PYX'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
acd = {r["model"]: r for r in rows if r.get("subject") == "acd"}
ok = fail = 0
def check(n, c, e=""):
    global ok, fail
    if c: ok += 1; print("ok   " + n)
    else: fail += 1; print("FAIL " + n, e)
r, m, b = acd["qwen-ref:1b"]["acd"], acd["qwen-mutant:1b"]["acd"], acd["qwen-broken:1b"]["acd"]
check("ACD ref: objective 40/40, executed 2/2, static 2/2, all 49 answered", (r["objective"]["correct"], r["objective"]["total"], r["executed"]["passed"], r["static"]["passed"], r["answered"]) == (40, 40, 2, 2, 49), r)
check("ACD mutant: A3/B3/E2 wrong, both executed checks fail, one static fails", (m["objective"]["correct"], m["executed"]["passed"], m["static"]["passed"]) == (37, 0, 1), m)
check("ACD broken: unanswered sections count as failures, never as passes", (b["objective"]["correct"], b["answered"]) == (20, 29), b)
check("ACD manual items are never auto-assessed", all(q["status"] == "manual_unassessed" for q in acd["qwen-ref:1b"]["requirements"] if q["kind"] == "manual"))
check("ACD static results are not counted as tests (functional total = objective + executed only)", acd["qwen-ref:1b"]["functional"]["total"] == 42)
check("ACD records the plan, the per-question timings and the notes used", acd["qwen-ref:1b"]["acd_run"]["mode"] == "units" and acd["qwen-ref:1b"]["acd_run"]["units"] == 49 and len(acd["qwen-ref:1b"]["acd_run"]["unit_ms"]) == 49 and acd["qwen-ref:1b"]["conditions"]["notes_chars_available"] > 0)
check("ACD runs record that thinking was off and the model was unloaded", acd["qwen-ref:1b"]["conditions"]["think"] == "off" and acd["qwen-ref:1b"]["acd_run"]["unloads"] >= 1 and acd["qwen-ref:1b"]["acd_run"]["requests"] >= 49)
print("\nACD benchmark assertions: %d/%d" % (ok, ok + fail)); sys.exit(1 if fail else 0)
PYX
