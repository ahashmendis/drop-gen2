#!/bin/bash
# ACD regression harness (macOS): popup logic, ACD pipeline, isolation from OOP, copy paths. Uses a scripted mock Ollama.
# usage: run-acd.sh <installer.sh>
# Optional: ACD_TEST_NODE_MODULES=<a node_modules folder with react/vite/typescript> enables the build assertions
# (defaults to the Week 2 tutorial project's node_modules when present; otherwise build assertions are skipped and reported).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
INSTALLER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
W="$(cd "$(mktemp -d /tmp/dropacd.XXXXXX)" && pwd -P)"; trap 'kill $MOCK 2>/dev/null || true' EXIT
NM="${ACD_TEST_NODE_MODULES:-$HOME/Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules}"
"$HERE/../baseline/extract-main.sh" "$INSTALLER" "$W/full.swift"
LN=$(grep -n '^let app = NSApplication.shared$' "$W/full.swift" | tail -1 | cut -d: -f1)
head -n $((LN-1)) "$W/full.swift" > "$W/main.swift"; cat "$HERE/driver_acd.swift" >> "$W/main.swift"
swiftc -Onone "$W/main.swift" -o "$W/acdx" -framework Cocoa -framework PDFKit -framework Carbon 2>"$W/build.log" || { cat "$W/build.log"; exit 1; }
# ACD input folder: paper + starter project (no node_modules); support dir: notes + toolchain
mkdir -p "$W/acdin" "$W/support/notes" "$W/support/toolchain"
cp -R "$HERE/fixtures/starter/." "$W/acdin/"; cp "$HERE/fixtures/paper.txt" "$W/acdin/"
cp "$REPO/acd-notes/00-conventions.md" "$W/support/notes/"; cp "$HERE/fixtures/lecture-routing.md" "$W/support/notes/"
BUILD=0; if [ -d "$NM" ]; then ln -s "$NM" "$W/support/toolchain/node_modules"; BUILD=1; fi
# OOP input identical to the OOP baseline's
mkdir -p "$W/oopin"; unzip -q "$REPO/SAMPLE/01_SIMPLE_Parking/SIMPLE_Starter_Project.zip" -d "$W/oopin"
cat > "$W/oopin/paper.txt" <<'PAPER'
Task 1 Implement HourlyPass.priceCents: round up partial hours, one hour minimum, reject negative stays.
Task 2 Create WeekendPass with a flat price and seed it in the repository; allQuotes sorts by price then id.
Task 3 Validate input and map IllegalArgumentException to 400 and PassNotFoundException to 404 with ApiError.
Task 4 Controller endpoints: GET quote, GET quotes and POST hourly returning HTTP 201.
PAPER
PORT=$((20000 + RANDOM % 20000)); OUT="$W/out"; mkdir -p "$OUT"
run() { # scenario mode outfile [toggle]
  python3 "$HERE/../baseline/mock_ollama.py" $PORT "$1" "$OUT/$3.requests.jsonl" & MOCK=$!; sleep 0.7
  if [ "$2" = "run" ]; then DROP_ACD_DIR="$W/support" "$W/acdx" run "$W/acdin" "http://127.0.0.1:$PORT" "$OUT/$3.json" "${4:-0}"
  elif [ "$2" = "oop-pertask" ]; then DROP_ACD_DIR="$W/support" "$W/acdx" oop-pertask "$W/oopin" "http://127.0.0.1:$PORT" "$OUT/$3.json"
  else DROP_ACD_DIR="$W/support" "$W/acdx" oop-while-acd "$W/oopin" "http://127.0.0.1:$PORT" "$OUT/$3.json"; fi
  kill $MOCK; wait $MOCK 2>/dev/null || true; echo "ran $3"; }
run acd_pass run pass; run acd_repair run repair; run acd_never run never; run acd_500 run fail500; run acd_pass run toggle 1
run pass oop oopwhileacd; run pertask oop-pertask pertask; DROP_CAREFUL=1 run oop_think_empty oop oopempty
DROP_ACD_DIR="$W/support" "$W/acdx" copy "$OUT/copy.json"; echo "ran copy"
cp -R "$OUT" "$HERE/out_last" 2>/dev/null || { rm -rf "$HERE/out_last"; cp -R "$OUT" "$HERE/out_last"; }
python3 - "$OUT" "$BUILD" "$REPO" <<'PY'
import json, sys, re, os
out, build, repo = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
ok = fail = 0
def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("ok   " + name)
    else: fail += 1; print("FAIL " + name + " " + str(extra)[:300])
def load(n): return json.load(open(f"{out}/{n}.json"))
def reqs(n): return [x for x in (json.loads(l) for l in open(f"{out}/{n}.requests.jsonl")) if not x.get("unload")]
P, R, N, F, T, C = load("pass"), load("repair"), load("never"), load("fail500"), load("toggle"), load("copy")
rp = reqs("pass")
unl = lambda n: [json.loads(l) for l in open(f"{out}/{n}.requests.jsonl") if json.loads(l).get("unload")]
# --- ACD generation: the paper is planned into questions, one small request each ---
check("ACD run produced an answer in the ACD slot, OOP slot untouched", "Q A1" in P["lastAnswerACD"] and "Q D1" in P["lastAnswerACD"] and P["lastAnswerOOP"] == "", P["lastAnswerACD"][:120])
check("planned into 3 requests (A1, A2, D1), not one whole-paper request", len(rp) == 3, len(rp))
objective = [r for r in rp if "Reply with ONLY" in r["prompt"]]; free = [r for r in rp if "Reply with ONLY" not in r["prompt"]]
check("objective questions: tiny budget, no thinking, temperature 0, small context", len(objective) == 2 and all(r["options"]["num_predict"] <= 24 and r["think"] is False and r["options"]["temperature"] == 0 and r["options"]["num_ctx"] <= 4096 for r in objective), [r["options"] for r in objective])
check("objective prompts carry no notes and no Java", all("REFERENCE NOTES" not in r["prompt"] and "javac" not in r["prompt"] and "Spring" not in r["prompt"] for r in objective))
check("thinking is OFF by default for every request", all(r["think"] is False for r in rp))
fr = free[0]; pr = fr["prompt"]
check("free question: ACD module prompt, starter project, FILE instruction", "Advanced Client-Side Development" in pr and "STARTER PROJECT FILES" in pr and "src/App.tsx" in pr and "// ===== FILE:" in pr)
check("free question keeps the exam instructions and the full question", "EXAM INSTRUCTIONS" in pr and "PAPER_MARKER_XYZ" in pr and "Outlet" in pr and "(10 marks)" in pr)
check("free question: notes (lower priority) come before the question, question last", "REFERENCE NOTES" in pr and pr.find("REFERENCE NOTES") < pr.rfind("QUESTION") and pr.rstrip().endswith("(10 marks)"))
check("notes are targeted: routing notes in, unrelated grid notes out", "Outlet renders the matched child" in pr and "grid-template-areas defines named areas" not in pr)
check("free request sized to its marks, context small enough for an 8 GB Mac", fr["options"]["num_predict"] >= 1000 and fr["options"]["num_ctx"] <= 16384, fr["options"])
check("the model is unloaded when the run ends (quiet laptop)", len(unl("pass")) >= 1 and open(f"{out}/pass.requests.jsonl").read().strip().split("\n")[-1].startswith('{"unload"'))
check("status says copied and lists validation, and says behaviour NOT verified", "copied" in P["status"] and "NOT verified" in P["status"] or "Build" in P["status"], P["status"])
check("clipboard holds the ACD answer", P["clipboard"] == P["lastAnswerACD"])
check("answer is assembled in paper order with Task and Q markers", re.findall(r"// ===== (Task \d|Q \w+) =====", P["lastAnswerACD"]) == ["Task 1", "Q A1", "Q A2", "Task 4", "Q D1"], re.findall(r"// ===== (Task \d|Q \w+) =====", P["lastAnswerACD"]))
check("objective answers parsed from the replies", "Q A1 =====\nB" in P["lastAnswerACD"] and "Q A2 =====\nFalse" in P["lastAnswerACD"])
if build:
    check("validation: syntax/static/build pass, tests not run", all(x in P["status"] for x in ["Syntax ✓", "Static ✓", "Build ✓", "Tests —"]) and "NOT verified" in P["status"], P["status"])
else:
    print("skip build assertions (no node_modules available)")
# --- repair keeps requirements and working code ---
rr = reqs("repair")
check("repair: 4 requests (A1, A2, D1, one repair)", len(rr) == 4, len(rr))
check("repair prompt carries the ORIGINAL requirements (the owning question + exam instructions) and the errors", "ORIGINAL TASK REQUIREMENTS" in rr[3]["prompt"] and "PAPER_MARKER_XYZ" in rr[3]["prompt"] and "Outlet" in rr[3]["prompt"] and "VALIDATION ERRORS" in rr[3]["prompt"] and "Hello.tsx" in rr[3]["prompt"])
check("repair result fixes Hello.tsx and keeps Keep.tsx + question blocks", "useState" in R["lastAnswerACD"] and "export const keep = 1;" in R["lastAnswerACD"] and "Q A1" in R["lastAnswerACD"])
check("repair prompt is not the OOP/Java repair", "javac" not in rr[3]["prompt"])
if build: check("repaired answer validates clean", "Build ✓" in R["status"], R["status"])
# --- repair that does not improve: best answer retained ---
check("never-fixed: 4 requests (stops when the repair is worse)", len(reqs("never")) == 4, len(reqs("never")))
check("never-fixed: best earlier answer kept (not the worse repair)", 'export const m: string = 5;' not in N["lastAnswerACD"] and "Q A1" in N["lastAnswerACD"])
if build: check("never-fixed: status reports remaining problems", "problem" in N["status"], N["status"])
check("server error: no answer, no crash, OOP slot untouched, error shown", F["lastAnswerACD"] == "" and F["lastAnswerOOP"] == "" and "❌" in F["status"], F["status"])
check("server error: one reload-and-retry per request, then the model is released", len(unl("fail500")) >= 2)
# --- toggling during an active run ---
check("toggle during run: run was active when toggled and still finished", T["runningAfterStart"] and "Q A1" in T["lastAnswerACD"])
check("toggle during run: answer stayed in the ACD slot, OOP slot empty", T["lastAnswerOOP"] == "")
check("toggle during run: new subject persisted (OOP) without disturbing the run", T["subjectDefaults"] == "oop" and T["providerUnchanged"] and T["modelUnchanged"])
check("toggle during run: view not overwritten by the ACD result after switching to OOP", not T["textHead"].startswith("── Validation"), T["textHead"])
# --- OOP path is independent of the toggle (hotkey path) ---
base = json.load(open(f"{repo}/tests/baseline/out/baseline_orig/pass.json"))
O = load("oopwhileacd")
cut = lambda t: t[:t.find("// ===== HOW TO TEST")] if "// ===== HOW TO TEST" in t else t
check("OOP handle() with the toggle on ACD == original OOP baseline answer (code identical; only the HOW TO TEST block was improved on purpose)", cut(O["lastAnswerOOP"]) == cut(base["lastAnswer"]) and O["lastAnswerACD"] == "", "")
check("... and its prompts are the original OOP prompts", [r["prompt"] for r in reqs("oopwhileacd")] == [r["prompt"] for r in [json.loads(l) for l in open(f"{repo}/tests/baseline/out/baseline_orig/pass.requests.jsonl")]])
# --- OOP per-task path (visible popup run) ---
PT = load("pertask"); pq = reqs("pertask")
check("OOP per-task generation is OFF by default (opt-in)", PT.get("defaultOff") is True)
check("OOP popup run (setting on): one request per task (4), each asking for ONLY that task", len(pq) == 4 and all(f"Write ONLY Task {i + 1} now" in pq[i]["prompt"] for i in range(4)), len(pq))
check("OOP popup run: the original OOP prompt header is used unchanged in every request", all(r["prompt"].startswith(open(f"{repo}/install-drop.sh").read().split('let OLLAMA_PROMPT_HEADER = """')[1][1:80]) for r in pq))
check("OOP popup run: thinking off, small context for each task, model kept for the run then unloaded", all(r["think"] is False for r in pq) and all(r["options"]["num_ctx"] <= 32768 for r in pq) and open(f"{out}/pertask.requests.jsonl").read().strip().split("\n")[-1].startswith('{"unload"'))
check("OOP popup run: later tasks carry the files written so far", "HourlyPass" in pq[1]["prompt"] and "FILES YOU HAVE ALREADY WRITTEN" in pq[2]["prompt"])
check("OOP popup run: answer lands in the OOP slot, compiles, and is copied", "class WeekendPass" in PT["lastAnswerOOP"] and PT["lastAnswerACD"] == "" and "Compiles" in PT["status"], PT["status"])
check("OOP popup run: still the same compile pipeline (HOW TO TEST appended by Drop, Ollama fixers ran)", "HOW TO TEST" in PT["lastAnswerOOP"])
# --- OOP default: ONE no-thinking request through the memory-aware session (no waiting through a failed thinking run) ---
OW = load("oopwhileacd"); ow = reqs("oopwhileacd")
check("OOP default: a single request, thinking OFF, small context, model released afterwards", len(ow) == 1 and ow[0]["think"] is False and ow[0]["options"]["num_predict"] >= 4096 and open(f"{out}/oopwhileacd.requests.jsonl").read().strip().split("\n")[-1].startswith('{"unload"'), [(r["think"], r["options"]) for r in ow])
# --- OOP: the thinking request returns nothing ("context limit reached – no answer produced") -> retried without thinking ---
OE = load("oopempty"); oq = reqs("oopempty")
check("OOP empty-thinking (Careful mode = original thinking request): tried first, then ONE no-thinking retry", len(oq) == 2 and oq[0]["think"] is True and oq[1]["think"] is False, [(r["think"], r["options"]["num_predict"]) for r in oq])
check("OOP empty-thinking: the retry asks for the same prompt with a real token budget and a context sized to it", oq[1]["prompt"] == oq[0]["prompt"] and oq[1]["options"]["num_predict"] >= 4096 and oq[1]["options"]["num_ctx"] >= 4096, oq[1]["options"])
check("OOP empty-thinking: the run now ends with a compiling answer instead of an error", "class WeekendPass" in OE["lastAnswerOOP"] and "Compiles" in OE["status"], OE["status"])
check("OOP empty-thinking: the model is unloaded afterwards", open(f"{out}/oopempty.requests.jsonl").read().strip().split("\n")[-1].startswith('{"unload"'))
# --- copy paths ---
check("OOP hotkey copy-all copies the OOP answer while ACD is selected", C["hotkeyCopyAllWhileACD"].endswith("OOP-TWO") and "OOP-ONE" in C["hotkeyCopyAllWhileACD"])
check("OOP hotkey task-2 copy unchanged while ACD is selected", C["hotkeyTask2WhileACD"].strip().endswith("OOP-TWO") and "OOP-ONE" not in C["hotkeyTask2WhileACD"], C["hotkeyTask2WhileACD"])
check("Copy button follows the selected subject (ACD)", "Q A1" in C["copyButtonACD"] and "OOP-ONE" not in C["copyButtonACD"])
check("copy part: question id A1", C["partA1"].startswith("// ===== Q A1") and "Q A2" not in C["partA1"], C["partA1"])
check("copy part: file name gives clean code", C["partFile"] == "export const h = 1;", C["partFile"])
check("copy part: ACD task 2", "Hello.tsx" in C["partTask2ACD"] or C["partTask2ACD"] == "export const h = 1;", C["partTask2ACD"])
check("copy part: unknown id reports, copies nothing new", "not found" in C["partMissingStatus"])
check("Copy button follows the selected subject (OOP)", "OOP-ONE" in C["copyButtonOOP"])
check("copy part: OOP task 2", C["partTask2OOP"].strip().endswith("OOP-TWO") and "OOP-ONE" not in C["partTask2OOP"], C["partTask2OOP"])
check("subject choice persisted", C["subjectPersisted"] == "oop")
# --- static isolation: ACD code never touches Java machinery; OOP code never touches node ---
src = open(f"{repo}/install-drop.sh").read()
a0, a1 = src.index("enum Subject: String"), src.index("// ---- OOP per-task generation")   # the ACD engine only; the OOP per-task block uses the OOP header by design
acd = src[a0:a1]
for bad in ["runJavac", "staticFixes", "mergeFixes", "repairContext", "OLLAMA_PROMPT_HEADER", "OLLAMA_REPAIR_HEADER", "applyImportFix", "howToTestBlock"]:
    check(f"ACD code does not use Java/OOP machinery: {bad}", bad not in acd.replace("AcdPrompt", ""))
check("ACD code references no javac", "javac" not in acd.lower().replace("// ---- acd", ""))
pipe = src[src.index("enum DropPipeline"):src.index("final class DropView") if "final class DropView" in src[src.index("enum DropPipeline"):] else len(src)]
dp = src[src.index("enum DropPipeline {"):src.index("// Top-anchored scroll content") if "// Top-anchored scroll content" in src else len(src)]
check("OOP pipeline (DropPipeline) never references ACD/node code", "Acd" not in src[src.index("enum DropPipeline {"):src.index("enum DropPipeline {") + 6000] and "node" not in src[src.index("enum DropPipeline {"):src.index("enum DropPipeline {") + 6000].lower())
# --- toolchain install is only ever reachable from the explicit, confirmed menu action ---
calls = [m.start() for m in re.finditer(r"AcdToolchain\.install\(", src)]
check("toolchain install has exactly one call site", len(calls) == 1, len(calls))
body = src[src.index("@objc func prepareToolchain()"):]
body = body[:body.index("\n    }\n}")]
check("... inside prepareToolchain, after the user confirms (runModal == Install)", body.index("runModal() == .alertFirstButtonReturn") < body.index("AcdToolchain.install("))
check("npm is run by the validator only inside the sandbox", src.count('AcdTools.sandboxed(npm') == 1)
# --- installer copies acd-notes beside it, never overwriting (cp -n) ---
import subprocess, tempfile, shutil
m = re.search(r"# ACD lecture notes:.*?\nfi\n", src, flags=re.S)
check("installer has the acd-notes copy step", m is not None)
if m:
    d = tempfile.mkdtemp(); inst = os.path.join(d, "install-drop.sh"); open(inst, "w").write("")
    os.makedirs(os.path.join(d, "acd-notes"))
    open(os.path.join(d, "acd-notes", "00-conventions.md"), "w").write("shipped"); open(os.path.join(d, "acd-notes", "new.md"), "w").write("new")
    support = os.path.join(d, "support"); os.makedirs(os.path.join(support, "acd", "notes"))
    open(os.path.join(support, "acd", "notes", "00-conventions.md"), "w").write("USER EDIT")
    snippet = m.group(0).replace("$0", '"' + inst + '"')
    subprocess.run(["bash", "-c", "set -e; DIR='" + support + "'\n" + snippet], check=True)
    check("notes copied, user's edited file not overwritten", open(os.path.join(support, "acd", "notes", "new.md")).read() == "new" and open(os.path.join(support, "acd", "notes", "00-conventions.md")).read() == "USER EDIT")
    shutil.rmtree(d)
print(f"\n{ok}/{ok + fail} passed"); sys.exit(1 if fail else 0)
PY
