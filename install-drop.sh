#!/bin/bash
# Installs "Drop": a small floating popup at the top of the screen.
# Drop PDF / Word files on it -> local Ollama model answers -> answer is copied to the clipboard.
set -e

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Installing Apple Command Line Tools..."
  xcode-select --install
  echo "Run this script again after the install finishes."
  exit 1
fi

DIR="$HOME/Library/Application Support/Drop"
APP="$HOME/Applications/Drop.app"
mkdir -p "$DIR" "$HOME/Applications"

# ACD lecture notes: an acd-notes folder next to this installer is copied in (cp -n: never overwrites your edits)
if [ -d "$(cd "$(dirname "$0")" && pwd)/acd-notes" ]; then
  mkdir -p "$DIR/acd/notes"
  cp -Rn "$(cd "$(dirname "$0")" && pwd)/acd-notes/." "$DIR/acd/notes/" 2>/dev/null || true
fi

# Benchmark tasks: a bench-tasks folder next to this installer is copied in (cp -n: never overwrites your own edits)
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SRC_DIR/bench-tasks" ]; then
  mkdir -p "$DIR/bench/tasks"
  cp -Rn "$SRC_DIR/bench-tasks/." "$DIR/bench/tasks/" 2>/dev/null || true
fi

# Local configuration (Phase 3): created once, never overwritten on update,
# so an existing API key survives reinstalls. 0600 = owner read/write only.
CONFIG="$DIR/config.json"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'CFGEOF'
{
  "provider": "opencode_go",
  "ollama": {
    "base_url": "http://127.0.0.1:11434",
    "default_model": "",
    "context": 0
  },
  "opencode_go": {
    "base_url": "https://opencode.ai/zen/go/v1",
    "api_key": "",
    "model": "mimo-v2.6-flash"
  },
  "network": {
    "connect_timeout": 20,
    "stream_idle_timeout": 120,
    "retry_attempts": 3,
    "retry_backoff": true
  },
  "preferences": {
    "remember_provider": true,
    "allow_fallback": false
  }
}
CFGEOF
fi
chmod 600 "$CONFIG" 2>/dev/null || true
chmod 700 "$DIR" 2>/dev/null || true

# Remove the older attempts
rm -rf "$HOME/Applications/Java Answers.app"
pkill -x Drop 2>/dev/null || true

cat > "$DIR/main.swift" <<'EOF'
import Cocoa
import PDFKit
import Carbon
import CryptoKit

let SKIP_DIRS: Set<String> = [".idea", "target", ".git", "node_modules", "build", ".mvn", ".gradle", "out", ".vscode"]
let TEXT_EXT: Set<String> = ["java", "xml", "md", "properties", "yml", "yaml", "json", "txt", "sql", "gradle", "kts", "html", "csv"]
let PROMPT_HEADER = """
You are an expert Java 17 / Spring Boot developer. Below is a practical exam paper (Word/PDF/README)
followed by the files of the starter Maven project that goes with it.
Rules:
- Do EVERY task in the paper (Task 1, Task 2, ...), following each marking point exactly.
- Read the STARTER PROJECT FILES first. Use their exact package names, class names, method names,
  record fields and constructor parameters. Never invent repository methods or packages.
- Work inside the starter project: fill in every TODO, keep the same package names, class names,
  method signatures and file paths. Do NOT change the parent class, DTO records or repository API
  unless a task says so. Create any new class the paper asks for. Uncomment seed lines when told to.
- Use polymorphism where the paper asks (no instanceof / type checks). Validate inputs as described.
- Null-check text BEFORE calling any method on it: if (x == null || x.isBlank()) throw new
  IllegalArgumentException(...); only then x.trim(). A null field in a POST body must give 400, never 500.
- Put @Override on EVERY method that overrides a parent method (including ones the starter left without it).
- If a bullet says a SERVICE method must validate something, validate it explicitly in that service method
  too (e.g. if (minutes <= 0) throw new IllegalArgumentException(...)), even if the model also checks it.
- Do overflow-prone maths fully in long (e.g. long hours = (minutes + 59L) / 60).
- Build comparators as a variable first, then sort: Comparator<T> c = Comparator.comparingInt(...).reversed()
  .thenComparingLong(T::getId); list.sort(c);  Never call thenComparing on a Stream.
- Never put ! in front of an int or a comparison like !a == b; write a != b.
- Idempotency (same key + same request -> same result, same key + different request -> 409): keep a
  Map<String, OriginalRequest> and a Map<String, Result>; on a repeat compare the stored REQUEST with the
  new one using equals(); identical -> return the stored result without saving again; different -> throw
  the starter's conflict exception. Never compare the request with values taken from the result.
- When choosing a status or reason, decide it with the parent type's methods (e.g. latestStartTick(),
  getters), never with instanceof or casts. Use each listed reason code in its exact situation.
- Error codes: 400 -> ApiError("BAD_REQUEST", ...), 404 -> "NOT_FOUND", 409 -> "CONFLICT" unless the paper says otherwise.
- Preview / plan / quote methods must never change stored state; work on copies. Only commit/save methods persist.
- Capacity per time unit: build a Map<Integer, int[]> of usage from the confirmed reservations PLUS what you
  selected so far in this run, and check EVERY tick of the half-open interval [start, start + duration).
- Rejection reasons: check in this order unless the paper says otherwise: job larger than capacity ->
  EXCEEDS_CAPACITY; deadline already impossible (latestStartTick() < earliest start) -> DEADLINE; window
  ends before the earliest start -> RELEASE_OUTSIDE_WINDOW; no feasible start found -> NO_SLOT.
- Lists returned by GET endpoints must be in a deterministic order (sort them, e.g. by start then id).
- Keep every annotation that is already in the starter (e.g. @RestControllerAdvice stays @RestControllerAdvice).
- Keep ALL the starter's existing import lines exactly (e.g. keep import java.util.*;). Never replace
  a wildcard import with single imports; only ADD imports you need.
- Variable and return types must match the starter's method return types exactly (if a service method
  returns the parent type, the controller must use the parent type too).
- If the paper says an endpoint "returns a JSON object containing X", return Map.of("X", value), never a bare number.
- Wrap Math.toIntExact / energy or price calculations that can overflow in try/catch(ArithmeticException)
  and rethrow new IllegalArgumentException(...) so the API answers 400, not 500.
- Name every @PathVariable / @RequestParam explicitly, e.g. @PathVariable("id"), @RequestParam("capacity").
- Controller methods only call the service: no try/catch, no validation, no building error bodies there;
  the @RestControllerAdvice handler turns exceptions into 400/404 with ApiError(code, message).
- A POST that creates something returns ResponseEntity.status(HttpStatus.CREATED).body(created).
- Sort with Comparator.comparingInt(Parent::a).reversed().thenComparingInt(Parent::b).thenComparingLong(Parent::getId)
  exactly in the direction the paper states.
- Method references only work for methods with matching parameters: urgencyAt(int) needs a lambda,
  e.g. Comparator.comparingInt((Workload w) -> w.urgencyAt(nowTick)). Return types must match exactly
  (a method declared to return List cannot return a Collection).
- Before finishing, re-read every file you wrote and fix anything that would not compile:
  wrong types, missing imports, methods or constructors that do not exist in the starter.
Output ONLY code, no markdown, and NO task list or summary at the start.
Organise the answer BY TASK, in order. Start each task with its own header line, then give every
Java file that task adds or changes, each one COMPLETE, with a FILE header naming the file to put it in:
// ===== Task 1 =====
// ===== FILE: src/main/java/.../GroundMission.java =====
// ===== Task 2 =====
// ===== FILE: src/main/java/.../AirMission.java =====
// ===== FILE: src/main/java/.../DispatchService.java =====
(Directly under each FILE header write that file's full Java code. Never write placeholders.)
If a file was already given under an earlier task and this task changes it, give it AGAIN, complete,
including the earlier tasks' code (so the last copy of each file is the final version).
Finish with a comment block "// ===== HOW TO TEST =====" listing curl commands for the paper's functional checks.
For plain Java tasks with no starter project, use // ===== Task 1 ===== headers and include a main method.
"""
let REVIEW_HEADER = ""
let REPAIR_HEADER = """
Your previous answer above does NOT compile. The JAVAC ERRORS section shows the exact errors.
Fix every error. Use only classes, methods, record fields and constructors that exist in the starter
files (or that you create yourself). Keep everything that was already correct.
Output ONLY the files you change to fix the errors, each one COMPLETE and starting with its
// ===== FILE: src/main/java/.../ClassName.java ===== header line.
No task list, no explanations, no test commands, no unchanged files.
"""

// Ollama-only prompt fork (student-level code quality). OpenCode Go keeps
// PROMPT_HEADER / REPAIR_HEADER byte-for-byte — those ride in its pinned
// request payload. Same rules, same OUTPUT contract (HOW TO TEST included);
// a silent self-check replaces nothing and a student-level layer is added.
let OLLAMA_PROMPT_HEADER = """
You are an expert Java 17 / Spring Boot developer. Below is a practical exam paper (Word/PDF/README)
followed by the files of the starter Maven project that goes with it.
Rules:
- Do EVERY task in the paper (Task 1, Task 2, ...), following each marking point exactly.
- Read the STARTER PROJECT FILES first. Use their exact package names, class names, method names,
  record fields and constructor parameters. Never invent repository methods or packages.
- Work inside the starter project: fill in every TODO, keep the same package names, class names,
  method signatures and file paths. Do NOT change the parent class, DTO records or repository API
  unless a task says so. Create any new class the paper asks for. Uncomment seed lines when told to.
- Use polymorphism where the paper asks (no instanceof / type checks). Validate inputs as described.
- Null-check text BEFORE calling any method on it: if (x == null || x.isBlank()) throw new
  IllegalArgumentException(...); only then x.trim(). A null field in a POST body must give 400, never 500.
- Put @Override on EVERY method that overrides a parent method (including ones the starter left without it).
- If a bullet says a SERVICE method must validate something, validate it explicitly in that service method
  too (e.g. if (minutes <= 0) throw new IllegalArgumentException(...)), even if the model also checks it.
- Overflow handling (long maths + Math.toIntExact + try/catch) ONLY when the paper or a TODO mentions
  overflow, very large values or 'must not crash/500'; otherwise write the plain calculation.
- Sort with Collections.sort(list, new Comparator<...>() { compare(...) }) as in the SORTING example below.
- Never put ! in front of an int or a comparison like !a == b; write a != b.
- Idempotency (same key + same request -> same result, same key + different request -> 409): keep a
  Map<String, OriginalRequest> and a Map<String, Result>; on a repeat compare the stored REQUEST with the
  new one using equals(); identical -> return the stored result without saving again; different -> throw
  the starter's conflict exception. Never compare the request with values taken from the result.
- When choosing a status or reason, decide it with the parent type's methods (e.g. latestStartTick(),
  getters), never with instanceof or casts. Use each listed reason code in its exact situation.
- Error codes: 400 -> ApiError("BAD_REQUEST", ...), 404 -> "NOT_FOUND", 409 -> "CONFLICT" unless the paper says otherwise.
- Preview / plan / quote methods must never change stored state; work on copies. Only commit/save methods persist.
- Capacity per time unit: build a Map<Integer, int[]> of usage from the confirmed reservations PLUS what you
  selected so far in this run, and check EVERY tick of the half-open interval [start, start + duration).
- Rejection reasons: check in this order unless the paper says otherwise: job larger than capacity ->
  EXCEEDS_CAPACITY; deadline already impossible (latestStartTick() < earliest start) -> DEADLINE; window
  ends before the earliest start -> RELEASE_OUTSIDE_WINDOW; no feasible start found -> NO_SLOT.
- Confirmed reservations: store them as a List<Reservation> holding the ACTUAL start/end ticks chosen
  by the plan. Build the usage map from those, and GET /reservations returns those (sorted). Never rebuild a
  reservation's start from releaseTick. Each tick reserved by one commit must not be booked again.
- Decide the rejection reason BEFORE the slot search, in this order: cpu > cpuCapacity or memory >
  memoryCapacity -> EXCEEDS_CAPACITY; latestStartTick() < earliest start -> DEADLINE; latest allowed
  start < earliest start -> RELEASE_OUTSIDE_WINDOW; only then search; nothing fits -> NO_SLOT.
- Words like "preventing overflow" or "safe arithmetic" in a bullet mean: do that formula in long and
  convert with Math.toIntExact (catch ArithmeticException -> IllegalArgumentException).
- String keys in a request (runKey, name, ...): null or blank -> IllegalArgumentException (400).
- Lists returned by GET endpoints must be in a deterministic order (sort them, e.g. by start then id).
- Keep every annotation that is already in the starter (e.g. @RestControllerAdvice stays @RestControllerAdvice).
- Keep ALL the starter's existing import lines exactly (e.g. keep import java.util.*;). Never replace
  a wildcard import with single imports; only ADD imports you need.
- Variable and return types must match the starter's method return types exactly (if a service method
  returns the parent type, the controller must use the parent type too).
- If the paper says an endpoint "returns a JSON object containing X", return Map.of("X", value), never a bare number.
- When the paper asks for overflow handling: wrap Math.toIntExact in try/catch(ArithmeticException)
  and rethrow new IllegalArgumentException(...) so the API answers 400, not 500.
- Name every @PathVariable / @RequestParam explicitly, e.g. @PathVariable("id"), @RequestParam("capacity").
- Controller methods only call the service: no try/catch, no validation, no building error bodies there;
  the @RestControllerAdvice handler turns exceptions into 400/404 with ApiError(code, message).
- A POST that creates a new item (e.g. POST /hourly, POST /air) returns the created object with
  @PostMapping("...") + @ResponseStatus(HttpStatus.CREATED) on the controller method (the way the lectures
  teach it). Use ResponseEntity ONLY in @ExceptionHandler methods. Preview/plan/commit-style POSTs keep 200
  unless the paper says 201. Import org.springframework.http.HttpStatus.
- Sort exactly in the directions and tie-break order the paper states (see the SORTING example).
- Return types must match exactly (a method declared to return List cannot return a Collection).
- Before finishing, re-read every file you wrote and fix anything that would not compile:
  wrong types, missing imports, methods or constructors that do not exist in the starter.
CODE STYLE: write simple, step-by-step Java that a second-year student would write and can explain:
plain if statements and for loops (no streams), clear variable names, one small step per line, no clever
one-liners (e.g. hours = minutes / 60; if (minutes % 60 != 0) { hours++; } instead of (minutes + 59) / 60).
Simple style must NOT drop correctness: still use null checks, @Override, the exact sort order,
and every validation the paper asks for.
NO EXTRA PARTS: write ONLY what the paper and the starter TODOs ask for. Do not add extra methods,
getters, fields, classes, endpoints, logging, comments or checks that no task asks for. Do not repeat
starter files you did not change. But never leave out anything a task or mark bullet DOES ask for.
SORTING - write every sort like this (the style of the module's official answers). Do NOT use
Comparator.comparingInt / .reversed() / thenComparing chains or :: method references:
Collections.sort(list, new Comparator<ParentType>() {
    @Override
    public int compare(ParentType first, ParentType second) {
        int result = Integer.compare(second.priority(), first.priority());    // DESCENDING: second before first
        if (result != 0) {
            return result;
        }
        result = Integer.compare(first.energyUnits(), second.energyUnits());  // ASCENDING: first before second
        if (result != 0) {
            return result;
        }
        return Long.compare(first.getId(), second.getId());                   // ID ascending tie-break
    }
});
(Use the starter's real parent type and the paper's real sort keys and directions. A value that needs a
parameter, e.g. urgencyAt(nowTick), is called inside compare(); nowTick must not be reassigned.)
NO TERNARY: write if/else instead of ? : (e.g. if (medical) { return 3; } return 1;).
ONE STATEMENT PER LINE in the code you write.
STYLE EXAMPLE (optional) - when a task has a similar calculation, prefer this simple style; otherwise
write whatever is correct and clear for that task:
@Override
public int priceCents(int stayMinutes) {
    if (stayMinutes <= 0) {
        throw new IllegalArgumentException("stayMinutes must be positive");
    }
    int hours = stayMinutes / 60;
    if (stayMinutes % 60 != 0) {
        hours++;
    }
    return hours * rateCents;
}
(Only if the paper asks for overflow handling, replace the return with:
    try { return Math.toIntExact((long) hours * rateCents); }
    catch (ArithmeticException e) { throw new IllegalArgumentException("price overflow"); } )
SLOT SEARCH EXAMPLE (use this shape when a paper schedules jobs into ticks with CPU/memory capacity):
Map<Integer, int[]> usage = new HashMap<>();            // tick -> {cpu, memory}
for (Reservation r : confirmedReservations) { addUsage(usage, r); }
for (Workload w : ranked) {
    if (w.getCpuCores() > cpuCap || w.getMemoryMb() > memCap) { rejected.add(new Rejection(w.getId(), "EXCEEDS_CAPACITY")); continue; }
    if (w.latestStartTick() < earliest) { rejected.add(new Rejection(w.getId(), "DEADLINE")); continue; }
    if (latest < earliest) { rejected.add(new Rejection(w.getId(), "RELEASE_OUTSIDE_WINDOW")); continue; }
    int chosen = -1;
    for (int start = earliest; start <= latest; start++) {
        boolean fits = true;
        for (int t = start; t < start + w.getDurationTicks(); t++) {
            int[] u = usage.getOrDefault(t, new int[2]);
            if (u[0] + w.getCpuCores() > cpuCap || u[1] + w.getMemoryMb() > memCap) { fits = false; break; }
        }
        if (fits) { chosen = start; break; }
    }
    if (chosen == -1) { rejected.add(new Rejection(w.getId(), "NO_SLOT")); continue; }
    Reservation res = new Reservation(w.getId(), chosen, chosen + w.getDurationTicks(), w.getCpuCores(), w.getMemoryMb());
    selected.add(res);
    addUsage(usage, res);                                 // later jobs in THIS run see it
}
private void addUsage(Map<Integer, int[]> usage, Reservation r) {
    for (int t = r.startTick(); t < r.endTickExclusive(); t++) {
        int[] u = usage.computeIfAbsent(t, k -> new int[2]);
        u[0] += r.cpuCores();
        u[1] += r.memoryMb();
    }
}
IDEMPOTENT COMMIT EXAMPLE (use the starter's own class names). Compare the stored REQUEST, never re-run
preview to compare plans (a retry would see its own reservations and give a different plan):
private final Map<String, CommitRequest> requestsByKey = new HashMap<>();
private final Map<String, SchedulePlan> plansByKey = new HashMap<>();
public synchronized SchedulePlan commit(CommitRequest request) {
    if (request.runKey() == null || request.runKey().isBlank()) { throw new IllegalArgumentException("runKey is required"); }
    if (requestsByKey.containsKey(request.runKey())) {
        if (!requestsByKey.get(request.runKey()).equals(request)) { throw new CommitConflictException(request.runKey()); }
        return plansByKey.get(request.runKey());          // identical retry: same plan, nothing saved again
    }
    SchedulePlan plan = preview(request.asPlanRequest());
    confirmedReservations.addAll(plan.selected());
    requestsByKey.put(request.runKey(), request);
    plansByKey.put(request.runKey(), plan);
    return plan;
}
GET reservations: copy the list, then sort it (startTick ascending, then id ascending) with a Comparator written like the SORTING example.
NEVER write placeholder or stub methods (e.g. a helper that just returns an empty list "for now").
KEEP GIVEN CODE EXACTLY: in every starter file you change, copy every line the starter already has
EXACTLY as given - same spacing, same one-line style, same names and signatures (inside a class use its
fields the way the starter does, e.g. medical, not isMedical()). Replace ONLY the TODO comment and the
throw new UnsupportedOperationException(...) line inside each TODO method with your code. Never reformat,
re-indent, split, rename or reorder a given line. ("One statement per line" applies only to code you add.)
LECTURE STYLE - plain code a student can explain line by line:
- Write annotations by their short name (@ExceptionHandler, @GetMapping), never the full package name.
- Error handlers return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(new ErrorResponse(...)) (same
  form for NOT_FOUND and CONFLICT); never ResponseEntity.badRequest().
- "Calculate before saving": create the object, call its own method once (e.g. mission.energyUnits();),
  then save it. Never copy a formula from a model class into the service.
- Keep the starter's method signatures and return types exactly (e.g. keep DispatchMission addAir(...));
  controller methods return the same type the service returns - no casts.
- No ternary ? :, no streams, no method references ::, no clever one-liners; one statement per line.
- Delete the starter's // TODO comments once that TODO is done.
- Use only things a 2nd-year OOP module teaches: classes, extends/super, @Override, if/else, for loops,
  List/ArrayList/Map/HashMap, try/catch, the written-out Comparator shown in SORTING, Spring annotations.
ORDER OF CHECKS: when the paper says which check comes first (words like "first", "then", "only then",
"before", "even when"), write the checks in EXACTLY that order. E.g. "check the SKU first, then validate qty"
means: look the item up and throw the not-found exception BEFORE any qty check.
ROUNDING: "X% off, rounded down" applies to the PRICE: price = price * (100 - X) / 100 in long
(10% off: price * 9 / 10; half price: price / 2). NEVER write price - price / 10 or price - price * X / 100,
which rounds the discount down and the price UP. Only if the paper says the DISCOUNT is rounded down, use
price - (price * X / 100).
CHARACTER RULES: "only A-Z, 0-9 and '-'" means exactly those ASCII characters: use text.matches("[A-Z0-9-]{3,12}")
(with the paper's lengths); never Character.isLetter/isLetterOrDigit, which also accept letters like E-acute.
GETTERS vs RECORDS: check how each starter request/response type is declared. If it is an ordinary class
with getters, call EXACTLY the getters it declares (getId(), getDistanceKm(), and e.g. getCritical() if that is
what it declares - never request.id() or an isX() that does not exist). Only records use x() accessors. Build
response objects with their declared constructors (e.g. new ErrorResponse("BAD_REQUEST", message)).
Use the exact package names (exception vs error, repository vs repo) and URL paths the starter uses.
CLASS NAMES: use EXACTLY the class, file, method and field names written in the paper and the starter
(e.g. if the paper says "introduce DeadlineWorkload", the file is DeadlineWorkload.java). Never use a name
from these instructions' examples unless the paper uses it too.
Output ONLY code, no markdown, and NO task list or summary at the start.
Organise the answer BY TASK, in order. Start each task with its own header line, then give every
Java file that task adds or changes, each one COMPLETE, with a FILE header naming the file to put it in:
// ===== Task 1 =====
// ===== FILE: src/main/java/.../<ClassNameFromPaper>.java =====
// ===== Task 2 =====
// ===== FILE: src/main/java/.../<NewClassNameFromPaper>.java =====
// ===== FILE: src/main/java/.../<ServiceFromStarter>.java =====
(Directly under each FILE header write that file's full Java code. Never write placeholders.)
EVERY task in the paper (Task 1, Task 2, Task 3, Task 4, ...) MUST get its own "// ===== Task N =====" header,
even when its code lives in a file shared with another task. Give each file ONCE, complete, under the
LAST task that changes it. Under the earlier task write one comment line instead, e.g.
// Task 2 <method>() is in <ServiceFromStarter>.java under Task 3
Do NOT add a HOW TO TEST section or any text after the last file.
For plain Java tasks with no starter project, use // ===== Task 1 ===== headers and include a main method.
"""
// Ollama-only repair fork: targeted repair — errors + implicated sources only,
// never the whole question and previous answer for a small fix (§4).
let OLLAMA_REPAIR_HEADER = """
Your previous answer does NOT compile. The JAVAC ERRORS section shows the exact errors and the
AFFECTED FILES section shows the relevant sources (the files implicated by those errors plus the
starter files they use).
Fix ONLY what the JAVAC ERRORS implicate. Keep every part that already works exactly as it is -
do not redesign, do not add classes, methods, comments or explanations.
Use only classes, methods, record fields and constructors that exist in the given files (or that
you create yourself).
Output ONLY the files you must change to fix the errors, each one COMPLETE and starting with its
// ===== FILE: src/main/java/.../ClassName.java ===== header line.
No task list, no explanations, no test commands, no unchanged files.
"""

// ===== Configuration (Phase 3): local file, never Keychain =====
let CONFIG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Drop/config.json")

struct DropConfig {
    var provider = "opencode_go"            // "ollama" | "opencode_go" (fresh installs only; saved configs win)
    var ollamaBase = "http://127.0.0.1:11434"
    // Last selected Ollama model (the dropdown only ever offers models that
    // are actually installed — never a hardcoded model name).
    var ollamaDefaultModel = ""
    // Manual Ollama context override: 0 = use the hardware-aware preset.
    var ollamaContext = 0
    var ocBase = "https://opencode.ai/zen/go/v1"
    var ocKey = ""
    var ocModel = "mimo-v2.6-flash"
    var connectTimeout = 20.0
    var streamIdleTimeout = 120.0
    var retryAttempts = 3
    var retryBackoff = true
    var rememberProvider = true
    var allowFallback = false
    // x-opencode-session value: stable for one conversation (initial prompt +
    // compile-repair rounds + retries all reuse it), new id per conversation.
    // Runtime-only — never written to config.json.
    var sessionId = UUID().uuidString
    // Runtime-only output cap for Ollama requests, sized per run from the
    // paper's task count (AppDelegate.numPredict). 0 = 4096 floor (e.g.
    // Settings test-connection). Never written to config.json.
    var numPredict = 0
    // Request streaming (SSE) replies. If the server rejects that shape with a
    // 400, the adapter retries once in the verified non-streaming shape
    // (the baseline curl contract, HTTP 200 confirmed). Internal, not persisted.
    var ocStream = true

    static func load() -> DropConfig {
        var c = DropConfig()
        guard let data = try? Data(contentsOf: CONFIG_URL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = obj["provider"] as? String { c.provider = v }
        if let o = obj["ollama"] as? [String: Any] {
            if let v = o["base_url"] as? String, !v.isEmpty { c.ollamaBase = v }
            if let v = o["default_model"] as? String { c.ollamaDefaultModel = v }
            if let v = o["context"] as? Int, v >= 0 { c.ollamaContext = v }
        }
        if let o = obj["opencode_go"] as? [String: Any] {
            if let v = o["base_url"] as? String, !v.isEmpty { c.ocBase = v }
            if let v = o["api_key"] as? String { c.ocKey = v }
            if let v = o["model"] as? String, !v.isEmpty { c.ocModel = v }
        }
        if let n = obj["network"] as? [String: Any] {
            if let v = n["connect_timeout"] as? Double { c.connectTimeout = v }
            else if let v = n["connect_timeout"] as? Int { c.connectTimeout = Double(v) }
            if let v = n["stream_idle_timeout"] as? Double { c.streamIdleTimeout = v }
            else if let v = n["stream_idle_timeout"] as? Int { c.streamIdleTimeout = Double(v) }
            if let v = n["retry_attempts"] as? Int { c.retryAttempts = v }
            if let v = n["retry_backoff"] as? Bool { c.retryBackoff = v }
        }
        if let p = obj["preferences"] as? [String: Any] {
            if let v = p["remember_provider"] as? Bool { c.rememberProvider = v }
            if let v = p["allow_fallback"] as? Bool { c.allowFallback = v }
        }
        return c
    }

    func save() {
        let obj: [String: Any] = [
            "provider": provider,
            "ollama": ["base_url": ollamaBase, "default_model": ollamaDefaultModel, "context": ollamaContext],
            "opencode_go": ["base_url": ocBase, "api_key": ocKey, "model": ocModel],
            "network": ["connect_timeout": connectTimeout, "stream_idle_timeout": streamIdleTimeout,
                        "retry_attempts": retryAttempts, "retry_backoff": retryBackoff],
            "preferences": ["remember_provider": rememberProvider, "allow_fallback": allowFallback]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: CONFIG_URL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CONFIG_URL.path)
        }
    }

    // Hardware-aware Ollama context target (conservative presets by system
    // RAM; a manual `ollama.context` override wins). Applied as a floor in
    // OllamaProvider.generate alongside the prompt-size sizing, so big papers
    // still grow the context as before while small requests get the preset.
    var ollamaTargetContext: Int {
        guard ollamaContext <= 0 else { return min(ollamaContext, 65536) }
        // Round to nearest GiB (machines report slightly under nominal RAM).
        let gib = (ProcessInfo.processInfo.physicalMemory + 536_870_912) / 1_073_741_824
        switch gib {
        case ..<16:  return 8192    // 8 GB class  → 8192
        case 16..<32: return 16384  // 16 GB       → 8192–16384
        case 32..<64: return 16384  // 32 GB       → 16384–32768 (conservative low end)
        default:      return 32768  // 64 GB+      → 32768–65536 (conservative low end)
        }
    }

    // Automatic context ceiling (final policy): when no manual context is set,
    // never allocate more than a conservative share of RAM. A manual
    // `ollama.context` override is exempt (the 65536 hard cap still applies).
    var ollamaContextCeiling: Int {
        guard ollamaContext <= 0 else { return 65536 }
        let gib = (ProcessInfo.processInfo.physicalMemory + 536_870_912) / 1_073_741_824
        if gib < 16 { return 16384 }    // 8 GB class  → 16384 (full papers need >8192)
        if gib < 32 { return 16384 }    // 16 GB       → 16384
        return 65536                    // 32 GB+      → 65536
    }

    // Final automatic context for one request: prompt-size growth (capped at
    // 65536), floored at the hardware-aware target, hard-capped at 65536, then
    // clamped to the automatic ceiling. It never grows past the ceiling on its
    // own — an oversized prompt is blocked (never truncated) with a pointer to
    // the manual Qwen ctx setting.
    func ollamaContextSize(forPrompt prompt: String) -> Int {
        let needed = prompt.count / 3 + 8000
        var ctx = 8192
        while ctx < needed && ctx < 65536 { ctx *= 2 }
        ctx = min(max(ctx, ollamaTargetContext), 65536)
        return min(ctx, ollamaContextCeiling)
    }
}

// ===== Error classification (Phase 7A): distinct conditions, never one generic blob =====
enum DropErrorKind {
    case noInternet, dnsFailure, tcpFailure, tlsFailure, endpointUnreachable
    case authFailure, modelNotFound, invalidRequest, rateLimited, serverOutage
    case timeout, interrupted, unknown(String)

    var message: String {
        switch self {
        case .noInternet:          return "No internet connection"
        case .dnsFailure:          return "DNS lookup failed (can't resolve opencode.ai)"
        case .tcpFailure:          return "Cannot reach the server (connection refused/blocked)"
        case .tlsFailure:          return "TLS certificate error"
        case .endpointUnreachable: return "API endpoint unreachable – this network may restrict access"
        case .authFailure:         return "Invalid API key (401/403)"
        case .modelNotFound:       return "Endpoint or model not found (404)"
        case .invalidRequest:      return "Invalid request (400)"
        case .rateLimited:         return "Rate limited (429)"
        case .serverOutage:        return "Provider server error (5xx)"
        case .timeout:             return "Request timed out"
        case .interrupted:         return "Stream interrupted"
        case .unknown(let d):      return d
        }
    }
    var isTransient: Bool {
        switch self {
        case .noInternet, .dnsFailure, .tcpFailure, .endpointUnreachable, .rateLimited, .serverOutage, .timeout:
            return true
        default: return false
        }
    }
}

struct DropError: Error {
    let kind: DropErrorKind
    var retryAfter: TimeInterval? = nil
    // Server-provided explanation (e.g. WHY a 400 happened), parsed defensively
    // from the error body. Never contains the API key; capped at 200 chars.
    var detail: String? = nil

    var displayMessage: String {
        guard let d = detail, !d.isEmpty else { return kind.message }
        return "\(kind.message) — \(d)"
    }
}

func classifyURLError(_ error: Error) -> DropError {
    if let e = error as? DropError { return e }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return DropError(kind: .noInternet)
        case NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost: return DropError(kind: .dnsFailure)
        case NSURLErrorCannotConnectToHost: return DropError(kind: .tcpFailure)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid: return DropError(kind: .tlsFailure)
        case NSURLErrorTimedOut: return DropError(kind: .timeout)
        case NSURLErrorCancelled: return DropError(kind: .unknown("Cancelled"))
        default: break
        }
    }
    return DropError(kind: .unknown(error.localizedDescription))
}

func classifyHTTP(status: Int, retryAfterHeader: String?, detail: String? = nil) -> DropError {
    var ra: TimeInterval? = nil
    if let h = retryAfterHeader, let secs = TimeInterval(h) { ra = secs }
    switch status {
    case 400: return DropError(kind: .invalidRequest, retryAfter: nil, detail: detail)
    case 401, 403: return DropError(kind: .authFailure, retryAfter: nil, detail: detail)
    case 404: return DropError(kind: .modelNotFound, retryAfter: nil, detail: detail)
    case 408: return DropError(kind: .timeout, retryAfter: ra, detail: detail)
    case 429: return DropError(kind: .rateLimited, retryAfter: ra, detail: detail)
    case 500...599: return DropError(kind: .serverOutage, retryAfter: ra, detail: detail)
    default: return DropError(kind: .unknown("HTTP \(status)"), retryAfter: ra, detail: detail)
    }
}

// Best-effort extraction of the provider's own explanation from an error body.
// Handles {"error":{"message":…}}, {"error":"…"}, {"message":…}, {"detail":…}.
// Returns nil for non-JSON or unknown shapes (never fabricates a message).
func errorDetail(from body: String) -> String? {
    guard !body.isEmpty,
          let data = body.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    if let d = obj as? [String: Any] {
        if let e = d["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
        if let e = d["error"] as? String, !e.isEmpty { return String(e.prefix(200)) }
        if let m = d["message"] as? String, !m.isEmpty { return String(m.prefix(200)) }
        if let m = d["detail"] as? String, !m.isEmpty { return String(m.prefix(200)) }
    }
    return nil
}

// ===== Provider abstraction (Phases 4-5) =====
enum GenOutcome {
    case ok(String)
    case interrupted(String)     // partial content already delivered to the UI
    case failed(DropError)
}

protocol ProviderAdapter {
    var id: String { get }
    var displayName: String { get }
    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome
    // Optional lightweight model discovery; nil = use configured default only.
    func listModels() async -> [String]?
}

// --- Ollama: local generation (streaming, keep_alive 0, num_ctx via helper) ---
struct OllamaProvider: ProviderAdapter {
    let config: DropConfig
    var id: String { "ollama" }
    var displayName: String { "Ollama" }

    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome {
        // On-demand start: probe first, open the Ollama app when it is not up
        // (never a duplicate server; never killed afterwards).
        guard await prepareOllama(startIfNeeded: true, base: config.ollamaBase,
                                  timeout: config.connectTimeout, onStatus: { onStatus($0) }) else {
            onStatus("⚠️ Ollama could not be started")
            return .failed(DropError(kind: .tcpFailure))
        }
        // Output bounded by the paper's task count: min(8192, max(4096,
        // 1536 + 768 x tasks)) — thinking tokens count toward it too, so one
        // request can never grind for hours. A cut answer (done_reason
        // 'length') is NEVER discarded and never regenerated from scratch:
        // the compile-repair loop in handle() completes it (javac errors +
        // up to 4 fix rounds). Only an empty answer is a failure.
        while true {
            var req = URLRequest(url: URL(string: config.ollamaBase + "/api/generate")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 900
            // Final context: growth + floor + hard cap + automatic ceiling. The
            // oversized-prompt block lives in AppDelegate.generate; nothing here
            // ever grows past the ceiling on its own.
            let ctx = config.ollamaContextSize(forPrompt: prompt)
            // "think": true matches the backup branch (it sends no think key and
            // qwen3 defaults to thinking) — that reasoning is what keeps the code
            // faithful to the paper's spec. Ollama returns it in its own
            // "thinking" field; the parser reads "response" only, so the answer
            // stays pure code. Thinking tokens share the context window (num_ctx)
            // — a cut answer is completed by the compile-repair loop. Ignored by
            // models without a thinking mode. Ollama request only — OpenCode is
            // untouched.
            // num_predict = task-scaled output cap (4096–8192) so one request
            // can never grind for hours; the compile-repair loop completes
            // anything it cuts.
            let np = config.numPredict > 0 ? config.numPredict : 4096
            let body: [String: Any] = ["model": model, "prompt": prompt, "stream": true,
                                       "think": true, "keep_alive": 0,
                                       "options": ["num_ctx": ctx, "temperature": 0.2, "num_predict": np]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            var answer = ""
            var thinking = 0
            var truncated = false
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                    // Surface Ollama's own reason (e.g. "model 'x' not found).
                    var raw = ""
                    for try await l in bytes.lines {
                        raw += l
                        if raw.count > 1024 { break }
                    }
                    var detail = errorDetail(from: raw)
                    // Context rejections: point at the manual Qwen ctx setting.
                    if raw.contains("context") || raw.contains("length") {
                        let base = detail ?? ""
                        detail = base.isEmpty ? "raise Qwen ctx in Settings" : base + " · " + "raise Qwen ctx in Settings"
                    }
                    return .failed(classifyHTTP(status: h.statusCode,
                                                retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"),
                                                detail: detail))
                }
                for try await line in bytes.lines {
                    guard let d = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if let e = obj["error"] as? String {
                        return .failed(DropError(kind: .unknown("Ollama: \(e)")))
                    }
                    if let th = obj["thinking"] as? String, !th.isEmpty {
                        thinking += th.count
                        onStatus("🧠 Thinking… \(thinking) chars")
                    }
                    if let piece = obj["response"] as? String, !piece.isEmpty {
                        answer += piece
                        onChunk(piece)
                        onStatus("\(label)… \(answer.count) chars")
                    }
                    // Truncation detection: with no output cap the only cut
                    // cause is a full context (done_reason 'length'); 'stop' is
                    // the model's natural end.
                    if let dr = obj["done_reason"] as? String, dr == "length" { truncated = true }
                }
                if truncated {
                    // done_reason 'length' means the context filled before the
                    // model finished. The partial answer is never discarded and
                    // never regenerated from scratch: handle()'s compile-repair
                    // loop completes it. Only an empty answer is a failure.
                    if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .failed(DropError(kind: .unknown(
                            "context limit reached – no answer produced; raise Qwen ctx in Settings")))
                    }
                    onStatus("⚠️ Answer cut short by the context – completing via compile repair…")
                }
                return .ok(answer)
            } catch {
                let e = classifyURLError(error)
                if !answer.isEmpty { return .interrupted(answer) }
                return .failed(e)
            }
        }
    }

    // Qwen-family discovery from GET /api/tags: model metadata first
    // (details.family / details.families), falling back to the model name.
    // All installed Qwen variants are offered — no single hardcoded model.
    static func isQwenFamily(_ m: [String: Any]) -> Bool {
        if let d = m["details"] as? [String: Any] {
            var fams: [String] = []
            if let f = d["family"] as? String { fams.append(f) }
            if let fs = d["families"] as? [String] { fams += fs }
            if fams.contains(where: { $0.lowercased().contains("qwen") }) { return true }
        }
        if let n = m["name"] as? String, n.lowercased().contains("qwen") { return true }
        return false
    }

    // Model list with metadata labels (name · size · quant) for the dropdown.
    func listModelDetails() async -> [(name: String, label: String)]? {
        guard let url = URL(string: config.ollamaBase + "/api/tags") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return nil }
            return models
                .filter { !(($0["name"] as? String) ?? "").contains("cloud") }
                .filter { OllamaProvider.isQwenFamily($0) }
                .compactMap { m -> (name: String, label: String)? in
                    guard let n = m["name"] as? String else { return nil }
                    let d = m["details"] as? [String: Any]
                    var label = n
                    if let s = d?["parameter_size"] as? String, !s.isEmpty { label += " · " + s }
                    if let q = d?["quantization_level"] as? String, !q.isEmpty { label += " · " + q }
                    return (name: n, label: label)
                }
                .sorted { $0.name < $1.name }
        } catch { return nil }
    }

    func listModels() async -> [String]? {
        // Names only: the protocol surface is unchanged; labels come from
        // listModelDetails (OpenCode Go untouched).
        await listModelDetails()?.map { $0.name }
    }
}

// --- Ollama on-demand lifecycle (quiet laptop): start only when needed ---
// We only ever manage a LOCAL Ollama install: if ollama.base_url points at a
// remote host we neither start nor stop anything there.
func ollamaManageable(_ base: String) -> Bool {
    guard let host = URL(string: base)?.host else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
}

// On-demand start: probe (GET /api/tags) first; when unreachable and asked to
// start, open the official Ollama app and poll within the caller's timeout.
// Env knobs are set on the start path only (best-effort; they apply to servers
// launched afterwards). The server is NEVER killed — `keep_alive: 0` lets it
// unload models between requests instead.
func prepareOllama(startIfNeeded: Bool, base: String, timeout: TimeInterval, onStatus: ((String) -> Void)? = nil) async -> Bool {
    guard ollamaManageable(base) else { return true }   // remote: not ours to manage
    func reachable() async -> Bool {
        guard let u = URL(string: base + "/api/tags") else { return false }
        var r = URLRequest(url: u)
        r.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    if await reachable() {
        demoteOllamaOnce()
        return true
    }
    guard startIfNeeded else { return false }
    onStatus?("Starting Ollama…")
    for cmd in ["launchctl setenv OLLAMA_NUM_PARALLEL 1",
                "launchctl setenv OLLAMA_MAX_LOADED_MODELS 1"] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run(); p.waitUntilExit()
    }
    // Official app (open -a Ollama), never a bare `ollama serve` first.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Ollama"]
    do { try p.run(); p.waitUntilExit() } catch { return false }
    try? await Task.sleep(nanoseconds: 300_000_000)
    if await reachable() {
        demoteOllamaOnce()
        onStatus?("Ollama ready")
        return true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if await reachable() {
            demoteOllamaOnce()
            onStatus?("Ollama ready")
            return true
        }
    }
    return false
}

// Best-effort one-time CPU demotion of a local Ollama server (secondary
// optimization). Never fails the request; the flag is set only when renice ran.
var ollamaDemoted = false
func demoteOllamaOnce() {
    guard !ollamaDemoted else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pid=$(pgrep -x ollama || pgrep -x Ollama); if [ -n \"$pid\" ]; then renice 15 -p $pid >/dev/null 2>&1 && echo ok; fi"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
        ollamaDemoted = true
    }
}

// --- OpenCode Go: direct HTTPS, Bearer auth, SSE streaming, retries with backoff+jitter ---
struct OpenCodeGoProvider: ProviderAdapter {
    let config: DropConfig
    var id: String { "opencode_go" }
    var displayName: String { "OpenCode Go" }

    private var endpoint: URL? {
        let base = config.ocBase.hasSuffix("/") ? String(config.ocBase.dropLast()) : config.ocBase
        return URL(string: base + "/chat/completions")
    }

    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome {
        guard !config.ocKey.isEmpty else { return .failed(DropError(kind: .authFailure)) }
        guard let url = endpoint else { return .failed(DropError(kind: .endpointUnreachable)) }

        let attempts = max(1, config.retryAttempts)
        let stream = config.ocStream
        var lastError = DropError(kind: .endpointUnreachable)
        for attempt in 0..<attempts {
            if attempt > 0 && config.retryBackoff {
                // Exponential backoff + jitter; honour Retry-After when the provider sent one.
                let base = pow(2.0, Double(attempt - 1))
                let jitter = Double.random(in: 0...0.5)
                let delay = max(lastError.retryAfter ?? 0, base + jitter)
                onStatus("⏳ Retry \(attempt)/\(attempts - 1) in \(String(format: "%.1f", delay))s…")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var res = await attemptOnce(url: url, prompt: prompt, model: model,
                                        label: label, stream: stream,
                                        onChunk: onChunk, onStatus: onStatus)
            if case .failed(let e) = res, stream, case .invalidRequest = e.kind {
                // Streaming shape rejected (400): retry exactly once in the
                // non-streaming shape the baseline test verified (HTTP 200).
                onStatus("⚠️ Streaming rejected – retrying non-streaming…")
                res = await attemptOnce(url: url, prompt: prompt, model: model,
                                        label: label, stream: false,
                                        onChunk: onChunk, onStatus: onStatus)
            }
            switch res {
            case .ok(let a): return .ok(a)
            case .interrupted(let partial): return .interrupted(partial)
            case .failed(let e):
                lastError = e
                // Only transient errors are retried; auth/400/404 fail fast.
                if !e.kind.isTransient { return .failed(e) }
            }
        }
        return .failed(lastError)
    }

    private func attemptOnce(url: URL, prompt: String, model: String, label: String,
                             stream: Bool,
                             onChunk: @escaping (String) -> Void,
                             onStatus: @escaping (String) -> Void) async -> GenOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + config.ocKey, forHTTPHeaderField: "Authorization")
        req.setValue("Drop/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(config.sessionId, forHTTPHeaderField: "x-opencode-session")
        req.timeoutInterval = config.streamIdleTimeout   // idle timeout; long generations keep streaming
        // Exact shape of the verified (200 OK) baseline request — no extra fields.
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": stream
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var answer = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                // Capture the error body for diagnostics (never contains the key).
                var raw = ""
                for try await l in bytes.lines {
                    raw += l
                    if raw.count > 2048 { break }
                }
                return .failed(classifyHTTP(status: h.statusCode,
                                            retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"),
                                            detail: errorDetail(from: raw)))
            }
            // Standard OpenAI-compatible SSE: data: {...} … data: [DONE]
            var plain = ""   // non-SSE lines, kept for a single-object JSON fallback
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else {
                    if plain.count < 4_194_304 { plain += line + "\n" }
                    continue
                }
                let payload = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }   // stream finished normally
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue } // malformed chunk: skip safely
                if let errObj = obj["error"] {
                    var msg = String(describing: errObj)
                    if let d = errObj as? [String: Any], let m = d["message"] as? String { msg = m }
                    if answer.isEmpty { return .failed(DropError(kind: .unknown(msg))) }
                    return .interrupted(answer)
                }
                if let choices = obj["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let piece = delta["content"] as? String, !piece.isEmpty {
                    answer += piece
                    onChunk(piece)
                    onStatus("\(label)… \(answer.count) chars")
                }
            }
            if answer.isEmpty {
                // Server replied with one chat.completion JSON object instead of
                // an SSE stream (stream ignored or stream:false) — parse it properly.
                if let s = OpenCodeGoProvider.chatContent(from: plain) {
                    onChunk(s)
                    return .ok(s)
                }
                if let d = errorDetail(from: plain) {
                    return .failed(DropError(kind: .unknown(d)))
                }
                return .failed(DropError(kind: .interrupted))
            }
            return .ok(answer)
        } catch {
            let e = classifyURLError(error)
            // Content already shown to the user: never replay the request (would duplicate output).
            if !answer.isEmpty { return .interrupted(answer) }
            return .failed(e)
        }
    }

    // GET {base}/models is OpenAI-compatible and free; fall back to the configured model.
    func listModels() async -> [String]? {
        guard !config.ocKey.isEmpty, let base = URL(string: config.ocBase.hasSuffix("/")
              ? String(config.ocBase.dropLast()) : config.ocBase) else { return nil }
        guard let url = URL(string: base.absoluteString + "/models") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + config.ocKey, forHTTPHeaderField: "Authorization")
        req.setValue("Drop/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(config.sessionId, forHTTPHeaderField: "x-opencode-session")
        req.timeoutInterval = config.connectTimeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return nil }
            let ids = arr.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : ids
        } catch { return nil }
    }

    // Extracts content from a single chat.completion JSON object
    // ({"choices":[{"message":{"content":…}}]} — the non-streaming reply shape).
    static func chatContent(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return content
    }
}

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var title = "Drop to share" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                     : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()

        let t = title as NSString
        let ta: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor]
        let ts = t.size(withAttributes: ta)
        t.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - 1), withAttributes: ta)

        let s = subtitle as NSString
        let sa: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor]
        let ss = s.size(withAttributes: sa)
        let w = min(ss.width, bounds.width - 16)
        s.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - ss.height, width: w, height: ss.height),
               withAttributes: sa)
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let u = urls(sender)
        if u.isEmpty { return false }
        onDrop?(u)
        return true
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// ===== Shared generation pipeline (normal mode AND benchmark mode) =====
// The exact generate → fixers → javac → repair loop that used to live inside
// AppDelegate.handle(), parameterised by hooks so the popup (UI hooks) and the
// benchmark (headless hooks) run the SAME code, prompts and repair logic.
struct PipelineHooks {
    var generate: (_ prompt: String, _ label: String) async -> String?
    var compile: (_ answer: String) async -> String?     // nil = cannot compile-check
    var status: (_ s: String) -> Void
    var resetOutput: () -> Void
}

struct PipelineResult {
    var answer: String          // final answer (fences stripped, fixers applied)
    var compiled: Bool?         // true / false / nil = could not compile-check
    var repairRounds: Int
    var generationMs: Int       // all generate() calls, initial + repairs
    var compileMs: Int          // all compile checks
    var lastErrors: String      // javac errors of the last failed compile ("" if none)
}

enum DropPipeline {
    @MainActor
    static func run(paper: String, provider: String, starter: [String: String],
                    hooks: PipelineHooks) async -> PipelineResult? {
        func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
        var genMs = 0, compMs = 0
        let header = provider == "ollama" ? OLLAMA_PROMPT_HEADER : PROMPT_HEADER
        let prompt = header + "\n\n" + paper
        let check = false
        var t0 = nowMs()
        guard var answer = await hooks.generate(prompt, "✍️ Writing") else { return nil }
        genMs += nowMs() - t0
        if check {
            let review = REVIEW_HEADER + "\n\n######## RULES ########\n" + header
                + "\n\n" + paper + "\n\n######## DRAFT SOLUTION ########\n" + answer
            hooks.resetOutput()
            if let fixed = await hooks.generate(review, "🔍 Double-checking"),
               fixed.count > answer.count / 3 {
                answer = fixed
            }
        }
        // Compile the answer against the starter; if javac fails, send the errors back for a fix (max 4 rounds)
        var compiled: Bool? = nil
        var rounds = 0
        var lastErrs = ""
        var detPasses = 0
        while true {
            // Deterministic fixers (Ollama only) run before every compile check,
            // so javac judges - and the repair model sees - the fixed answer.
            let fixersOn = provider == "ollama"
            if fixersOn {
                answer = AppDelegate.paperFixes(AppDelegate.staticFixes(answer, starter: starter), paper: paper, starter: starter)
            }
            hooks.status("🧪 Compiling…")
            // Full compile every round: javac's complete error set is the only
            // truthful feed for the repair model.
            t0 = nowMs()
            let errsOpt = await hooks.compile(answer)
            compMs += nowMs() - t0
            guard var errs = errsOpt else { compiled = nil; break }
            var lintOnly = false
            if errs.isEmpty {
                // Ollama only: code that compiles but is a stub / wrong kind of response goes back for repair too
                if provider == "ollama" && rounds < 4 {
                    let lint = AppDelegate.semanticFindings(answer)
                    if !lint.isEmpty { errs = lint; lintOnly = true }
                }
                if errs.isEmpty { compiled = true; lastErrs = ""; break }
            }
            compiled = lintOnly ? true : false
            lastErrs = lintOnly ? "" : errs
            // Ollama only: fix what javac names exactly (missing import, non-existent accessor, generic mismatch) without a model call
            if provider == "ollama" && detPasses < 3 {
                let det = AppDelegate.javacFixes(answer, starter: starter, errs: errs)
                if det != answer { detPasses += 1; answer = det; continue }
            }
            if rounds >= 4 { break }
            rounds += 1
            let n = errs.components(separatedBy: "error:").count - 1
            let fixPrompt: String
            if provider == "ollama" {
                // Targeted repair (Ollama only): errors + implicated sources —
                // never the full question and previous answer for a small fix.
                fixPrompt = OLLAMA_REPAIR_HEADER
                    + "\n\n######## JAVAC ERRORS ########\n" + String(errs.prefix(6000))
                    + "\n\n######## AFFECTED FILES ########\n"
                    + AppDelegate.repairContext(answer: answer, starter: starter, errs: errs)
            } else {
                fixPrompt = PROMPT_HEADER + "\n\n" + paper
                    + "\n\n######## YOUR PREVIOUS ANSWER ########\n" + answer
                    + "\n\n######## JAVAC ERRORS ########\n" + String(errs.prefix(6000))
                    + "\n\n" + REPAIR_HEADER
            }
            hooks.resetOutput()
            t0 = nowMs()
            let fixesOpt = await hooks.generate(fixPrompt, "🔧 Fixing \(n) compile error(s)")
            genMs += nowMs() - t0
            guard let fixes = fixesOpt else { break }
            let merged = AppDelegate.mergeFixes(answer, fixes)
            if merged == answer { break }
            if provider == "ollama" && AppDelegate.introducesPlaceholders(old: answer, new: merged) { break }   // never accept a stub just to compile
            answer = merged
        }
        var finalAnswer = AppDelegate.applyImportFix(AppDelegate.stripFencesText(answer))
        if provider == "ollama" {
            finalAnswer = AppDelegate.paperFixes(AppDelegate.staticFixes(finalAnswer, starter: starter), paper: paper, starter: starter)
            // The prompt head forbids the model writing a HOW TO TEST section,
            // so Drop appends one deterministically at finalize (Ollama only).
            finalAnswer = AppDelegate.howToTestBlock(finalAnswer, starter: starter, paper: paper)
        }
        return PipelineResult(answer: finalAnswer, compiled: compiled, repairRounds: rounds,
                              generationMs: genMs, compileMs: compMs, lastErrors: lastErrs)
    }
}

// ===== Benchmark mode (additive) =====================================================
// Runs the SAME DropPipeline as normal generation over fixed tasks and several models,
// grades the results and records them. Isolation rules: this code never writes
// lastAnswer, the clipboard, config.json, UserDefaults or any normal-mode state; it
// works on a COPY of the config, never falls back to another provider, and stores
// everything under ~/Library/Application Support/Drop/bench/.

// DROP_BENCH_DIR is a test hook (the end-to-end harness points it at a scratch folder).
let BENCH_DIR: URL = ProcessInfo.processInfo.environment["DROP_BENCH_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Drop/bench")

func benchHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
}
func benchHash(_ s: String) -> String { benchHash(Data(s.utf8)) }
func benchISO(_ d: Date = Date()) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
}

// ---- tasks ----
struct BenchRequirement {
    var id: String, text: String
    var marks: Double
    var kind: String            // automated | objective | static | manual | untestable
    var tests: [String]
    var note: String
    var question: String = ""   // ACD: the paper's question identifier this requirement grades
    var answer: String = ""     // ACD objective: the key ("B", "True", "False")
    var rubric: String = ""     // ACD manual: what the marks are for
    var check: [String: Any] = [:]   // ACD executed / static check definition
}

struct BenchTask {
    var id: String, title: String, level: String
    var dir: URL
    var paperFile: String, starterFile: String
    var testMain: String, testsDir: String, supportDir: String
    var expectedNewFiles: [String]
    var requirements: [BenchRequirement]
    var declaredTests: Int      // test("…") calls found in the test sources
    var subject: String = "oop" // "oop" (Java pipeline) | "acd" (web pipeline)

    static func loadAll() -> [BenchTask] {
        let root = BENCH_DIR.appendingPathComponent("tasks")
        let fm = FileManager.default
        var out: [BenchTask] = []
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where !name.hasPrefix("_") && !name.hasPrefix(".") {
            let dir = root.appendingPathComponent(name)
            if let t = load(dir: dir) { out.append(t) }
        }
        return out
    }

    static func load(dir: URL) -> BenchTask? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("task.json")),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? String else { return nil }
        let inputs = o["inputs"] as? [String: Any] ?? [:]
        let tests = o["tests"] as? [String: Any] ?? [:]
        var reqs: [BenchRequirement] = []
        for r in (o["requirements"] as? [[String: Any]] ?? []) {
            reqs.append(BenchRequirement(id: r["id"] as? String ?? "?", text: r["text"] as? String ?? "",
                                         marks: (r["marks"] as? NSNumber)?.doubleValue ?? 0,
                                         kind: r["kind"] as? String ?? "automated",
                                         tests: r["tests"] as? [String] ?? [], note: r["note"] as? String ?? "",
                                         question: r["question"] as? String ?? "", answer: r["answer"] as? String ?? "",
                                         rubric: r["rubric"] as? String ?? "", check: r["check"] as? [String: Any] ?? [:]))
        }
        var t = BenchTask(id: id, title: o["title"] as? String ?? id, level: o["level"] as? String ?? "", dir: dir,
                          paperFile: inputs["paper"] as? String ?? "", starterFile: inputs["starter"] as? String ?? "",
                          testMain: tests["main"] as? String ?? "", testsDir: tests["dir"] as? String ?? "tests",
                          supportDir: tests["support"] as? String ?? "../_support",
                          expectedNewFiles: o["expectedNewFiles"] as? [String] ?? [], requirements: reqs, declaredTests: 0)
        t.subject = o["subject"] as? String ?? "oop"
        let tdir = dir.appendingPathComponent(t.testsDir)
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? []) where f.hasSuffix(".java") {
            let src = (try? String(contentsOf: tdir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            t.declaredTests += src.components(separatedBy: "test(\"").count - 1
        }
        if t.subject == "acd" { t.declaredTests = reqs.filter { $0.kind == "objective" || $0.kind == "automated" }.count }
        return t
    }

    /// Identical inputs for every model: the paper and the UNZIPPED starter, laid out like Desktop/OOP.
    /// Returns the folder to read plus a hash of the exact input bytes.
    func prepareInput(into work: URL) -> (URL, String)? {
        let fm = FileManager.default
        let input = work.appendingPathComponent("input")
        try? fm.removeItem(at: input)
        try? fm.createDirectory(at: input, withIntermediateDirectories: true)
        var hashData = Data()
        let paper = dir.appendingPathComponent(paperFile)
        if !paperFile.isEmpty, let d = try? Data(contentsOf: paper) {
            hashData.append(d)
            try? fm.copyItem(at: paper, to: input.appendingPathComponent(paper.lastPathComponent))
        }
        let zip = dir.appendingPathComponent(starterFile)
        if !starterFile.isEmpty, let d = try? Data(contentsOf: zip) {
            hashData.append(d)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, input.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() } catch { return nil }
        }
        if hashData.isEmpty { return nil }
        return (input, benchHash(hashData))
    }
}

// ---- running external tools ----
func benchRun(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String, timedOut: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "cannot start \(exe): \(error)", false) }
    var timedOut = false
    let wd = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: wd)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    wd.cancel()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "", timedOut)
}

enum BenchEnv {
    static func jdkBin() -> String? {
        let fm = FileManager.default
        var homes: [String] = []
        let r = benchRun("/usr/libexec/java_home", [], timeout: 10)
        let h = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 && !h.isEmpty { homes.append(h) }
        let userHome = fm.homeDirectoryForCurrentUser.path
        for dir in [userHome + "/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"] {
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed() { homes.append(dir + "/" + n + "/Contents/Home") }
        }
        for app in ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []) where app.hasPrefix("IntelliJ") {
            homes.append("/Applications/" + app + "/Contents/jbr/Contents/Home")
        }
        for h in homes where fm.isExecutableFile(atPath: h + "/bin/javac") && fm.isExecutableFile(atPath: h + "/bin/java") { return h + "/bin" }
        return nil
    }

    /// One newest version of each artifact the test support needs (mixed versions in ~/.m2 would not run).
    static func runtimeClasspath() -> String? {
        let m2 = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".m2/repository")
        let arts = ["org/springframework/spring-web", "org/springframework/spring-core", "org/springframework/spring-context",
                    "org/springframework/spring-beans", "org/springframework/spring-aop", "org/springframework/spring-expression",
                    "com/fasterxml/jackson/core/jackson-databind", "com/fasterxml/jackson/core/jackson-core",
                    "com/fasterxml/jackson/core/jackson-annotations", "org/jspecify/jspecify",
                    "io/micrometer/micrometer-commons", "io/micrometer/micrometer-observation"]
        var jars: [String] = []
        for a in arts {
            let base = m2.appendingPathComponent(a)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            let name = (a as NSString).lastPathComponent
            if let v = versions.last(where: { FileManager.default.fileExists(atPath: base.path + "/\($0)/\(name)-\($0).jar") }) {
                jars.append(base.path + "/\(v)/\(name)-\(v).jar")
            } else if a.contains("spring-web") || a.contains("jackson-databind") { return nil }
        }
        return jars.joined(separator: ":")
    }
}

// ---- functional tests ----
struct BenchTestResult { var id: String, title: String, passed: Bool, message: String }

enum BenchTestOutcome {
    case notRun(String)                         // never counts as a pass
    case ran([BenchTestResult])
}

enum BenchTestRunner {
    static func run(task: BenchTask, answer: String, starter: [String: String]) -> BenchTestOutcome {
        guard let bin = BenchEnv.jdkBin() else { return .notRun("no JDK found") }
        guard let cp = BenchEnv.runtimeClasspath() else { return .notRun("Spring/Jackson jars not found in ~/.m2") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("dropbench-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: tmp) }
        var sources = starter
        for (k, v) in AppDelegate.parseAnswerFiles(answer) { sources[k] = AppDelegate.ensureUtilImport(v) }
        var paths: [String] = []
        for (k, v) in sources where !k.hasSuffix("Application.java") {
            let u = tmp.appendingPathComponent(k)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? v.write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        let support = task.dir.appendingPathComponent(task.supportDir).standardizedFileURL
        let tests = task.dir.appendingPathComponent(task.testsDir)
        for d in [support, tests] {
            for f in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []) where f.hasSuffix(".java") { paths.append(d.appendingPathComponent(f).path) }
        }
        let out = tmp.appendingPathComponent("out")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let c = benchRun(bin + "/javac", ["--release", "17", "-parameters", "-proc:none", "-nowarn", "-encoding", "UTF-8",
                                          "-d", out.path, "-cp", cp] + paths, timeout: 180)
        if c.status != 0 {
            let first = c.output.replacingOccurrences(of: tmp.path + "/", with: "")
                .components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(3).joined(separator: " | ")
            return .notRun("tests could not be compiled against this solution (missing or incompatible API): \(first)")
        }
        let r = benchRun(bin + "/java", ["-Dbench.src=" + tmp.appendingPathComponent("src/main/java").path,
                                         "-cp", out.path + ":" + cp, task.testMain], timeout: 120)
        if r.timedOut { return .notRun("tests timed out after 120 s (possible infinite loop in the solution)") }
        var results: [BenchTestResult] = []
        for line in r.output.components(separatedBy: "\n") where line.hasPrefix("TEST\t") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3 else { continue }
            let name = f[1]
            let id = name.components(separatedBy: " ").first ?? name
            let title = name.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
            results.append(BenchTestResult(id: id, title: title, passed: f[2] == "PASS", message: f.count > 3 ? f[3] : ""))
        }
        if results.isEmpty { return .notRun("test program produced no results: " + String(r.output.prefix(300))) }
        return .ran(results)
    }
}

// ---- code quality (automated simplicity checks) ----
enum BenchQuality {
    /// 10 points; every deduction is listed so the score is auditable.
    static func analyze(answer: String, starter: [String: String], expectedNew: [String]) -> (points: Double, notes: [String]) {
        let files = AppDelegate.parseAnswerFiles(answer)
        var pts = 10.0
        var notes: [String] = []
        let newFiles = files.keys.filter { starter[$0] == nil }
        let extra = newFiles.filter { f in !expectedNew.contains(where: { f.hasSuffix($0) }) }
        if !extra.isEmpty {
            let d = min(6.0, 2.0 * Double(extra.count)); pts -= d
            notes.append("−\(Int(d)): \(extra.count) extra file(s) the task did not ask for: " + extra.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }
        var abstractions: [String] = []
        for f in newFiles {
            let body = files[f] ?? ""
            for pat in [#"\binterface\s+\w+"#, #"\babstract\s+class\s+\w+"#, #"\benum\s+\w+"#] {
                if body.range(of: pat, options: .regularExpression) != nil { abstractions.append((f as NSString).lastPathComponent); break }
            }
        }
        if !abstractions.isEmpty {
            let d = min(4.0, 2.0 * Double(abstractions.count)); pts -= d
            notes.append("−\(Int(d)): extra abstractions (interface/abstract class/enum): " + abstractions.joined(separator: ", "))
        }
        var longMethods = 0
        for (_, body) in files {
            var depth = 0, start = -1, lineNo = 0
            for line in body.components(separatedBy: "\n") {
                lineNo += 1
                for ch in line {
                    if ch == "{" { depth += 1; if depth == 2 { start = lineNo } }
                    else if ch == "}" { if depth == 2, start > 0, lineNo - start > 40 { longMethods += 1 }; depth -= 1 }
                }
            }
        }
        if longMethods > 0 {
            let d = min(3.0, Double(longMethods)); pts -= d
            notes.append("−\(Int(d)): \(longMethods) method(s) longer than 40 lines")
        }
        let all = files.values.joined(separator: "\n")
        if all.contains("TODO") || all.contains("UnsupportedOperationException") {
            pts -= 3; notes.append("−3: leftover TODO / UnsupportedOperationException")
        }
        if files.isEmpty { pts = 0; notes = ["no Java files found in the answer"] }
        return (max(0, pts), notes)
    }
}

// ---- one run's record ----
struct BenchModelRef {
    var provider: String        // "ollama" | "opencode_go"
    var name: String
    var info: [String: Any]     // digest, parameter_size, quantization_level, family … (Ollama) / {} (cloud)
}

struct BenchSettings {
    var runId: String
    var base: DropConfig
    var oopPerTask = false      // OOP + Ollama: one request per task (the popup's visible path)
    var oopMode = "auto"        // "auto": same as the app (no-thinking single request unless Careful mode) · "original": the thinking request · "nothink": force no-thinking
    var fastOOP: Bool { oopMode == "nothink" || (oopMode == "auto" && !AcdSettings.careful) }
}

enum BenchStore {
    static var resultsURL: URL { BENCH_DIR.appendingPathComponent("results/results.jsonl") }
    static func ensureDirs() {
        for d in ["tasks", "results", "runs", "reports"] {
            try? FileManager.default.createDirectory(at: BENCH_DIR.appendingPathComponent(d), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }
    static func append(_ rec: [String: Any]) {
        ensureDirs()
        guard let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) else { return }
        var line = data; line.append(0x0A)
        if !FileManager.default.fileExists(atPath: resultsURL.path) {
            FileManager.default.createFile(atPath: resultsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = try? FileHandle(forWritingTo: resultsURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    }
    static func loadAll() -> [[String: Any]] {
        guard let s = try? String(contentsOf: resultsURL, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n").compactMap { l in
            guard !l.isEmpty, let d = l.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }
    static func ollamaInfo(base: String) async -> [String: [String: Any]] {
        guard let u = URL(string: base + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = o["models"] as? [[String: Any]] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for m in ms {
            guard let n = m["name"] as? String else { continue }
            let d = m["details"] as? [String: Any] ?? [:]
            out[n] = ["digest": (m["digest"] as? String ?? ""), "size_bytes": m["size"] as? Int ?? 0,
                      "modified_at": m["modified_at"] as? String ?? "", "family": d["family"] as? String ?? "",
                      "parameter_size": d["parameter_size"] as? String ?? "", "quantization": d["quantization_level"] as? String ?? ""]
        }
        return out
    }
}

// ---- the runner ----
@MainActor
final class BenchRunner {
    let tasks: [BenchTask]
    let models: [BenchModelRef]
    let settings: BenchSettings
    let log: (String) -> Void
    let collector = AppDelegate()          // a private instance: reuses the real file-extraction code, never shown

    init(tasks: [BenchTask], models: [BenchModelRef], settings: BenchSettings, log: @escaping (String) -> Void) {
        self.tasks = tasks; self.models = models; self.settings = settings; self.log = log
    }

    func runAll() async {
        BenchStore.ensureDirs()
        let total = tasks.count * models.count
        var n = 0
        for m in models {
            for t in tasks {
                if Task.isCancelled { log("⏹ Stopped."); return }
                n += 1
                log("\n[\(n)/\(total)] \(m.provider == "ollama" ? "🦙" : "☁️") \(m.name) · \(t.id)")
                await runOne(model: m, task: t)
            }
        }
        log("\n✅ Benchmark finished: \(total) run(s) recorded in results.jsonl")
    }

    /// Headless generation with the same context-ceiling rule as AppDelegate.generate and NO provider fallback.
    func generate(provider: ProviderAdapter, cfg: DropConfig, prompt: String, model: String, label: String,
                  failure: inout String?) async -> String? {
        if provider.id == "ollama" && cfg.ollamaContext <= 0 {
            let autoCtx = cfg.ollamaContextSize(forPrompt: prompt)
            if prompt.count / 3 > autoCtx {
                failure = "prompt needs ~\(prompt.count / 3) tokens, above the automatic context ceiling (\(autoCtx)); raise Qwen ctx in Settings"
                return nil
            }
        }
        var lastLogged = 0
        let outcome = await provider.generate(prompt: prompt, model: model, label: label,
                                              onChunk: { _ in }, onStatus: { [weak self] s in
            guard let self = self else { return }
            // throttle: one progress line per ~1500 chars / status change
            if let r = s.range(of: "… "), let c = Int(s[r.upperBound...].replacingOccurrences(of: " chars", with: "")) {
                if c - lastLogged >= 1500 { lastLogged = c; DispatchQueue.main.async { self.log("    \(label)… \(c) chars") } }
            }
        })
        switch outcome {
        case .ok(let a):
            if a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failure = "empty response from provider"; return nil }
            return a
        case .interrupted(let partial):
            failure = "stream interrupted (partial answer kept, \(partial.count) chars)"
            return partial.isEmpty ? nil : partial
        case .failed(let err):
            failure = err.displayMessage
            return nil
        }
    }

    func runOne(model: BenchModelRef, task: BenchTask) async {
        if task.subject == "acd" { await runOneACD(model: model, task: task); return }
        let started = Date()
        let safe = model.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let runDir = BENCH_DIR.appendingPathComponent("runs/\(settings.runId)/\(model.provider)_\(safe)/\(task.id)")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var rec: [String: Any] = [
            "schema": 1, "run_id": settings.runId, "started_at": benchISO(started),
            "provider": model.provider, "model": model.name, "model_info": model.info,
            "task": task.id, "task_title": task.title, "run_dir": runDir.path,
        ]
        guard let (inputDir, inputHash) = task.prepareInput(into: runDir) else {
            rec["final_status"] = "error"; rec["error"] = "could not prepare task input"; rec["finished_at"] = benchISO()
            BenchStore.append(rec); log("  ❌ could not prepare task input"); return
        }
        rec["input_hash"] = inputHash
        collector.starterFiles = [:]
        let (paper, fileCount) = collector.collect(inputDir)
        let starter = collector.starterFiles
        if paper.split(whereSeparator: { $0.isWhitespace }).count < 15 {
            rec["final_status"] = "error"; rec["error"] = "no readable task text"; rec["finished_at"] = benchISO()
            BenchStore.append(rec); log("  ❌ no readable task text"); return
        }
        var cfg = settings.base
        cfg.provider = model.provider
        cfg.sessionId = UUID().uuidString
        cfg.numPredict = AppDelegate.numPredict(forPaper: paper)
        if model.provider == "opencode_go" { cfg.ocModel = model.name }
        let provider: ProviderAdapter = model.provider == "opencode_go" ? OpenCodeGoProvider(config: cfg) : OllamaProvider(config: cfg)
        let header = model.provider == "ollama" ? OLLAMA_PROMPT_HEADER : PROMPT_HEADER
        rec["conditions"] = [
            "files_read": fileCount, "starter_files": starter.count, "num_predict": cfg.numPredict,
            "ollama_context_setting": cfg.ollamaContext, "temperature": 0.2, "keep_alive": 0, "think": true,
            "prompt_header_hash": benchHash(header),
            "repair_header_hash": benchHash(model.provider == "ollama" ? OLLAMA_REPAIR_HEADER : REPAIR_HEADER),
            "deterministic_fixers": model.provider == "ollama", "max_repair_rounds": 4,
        ]
        var failure: String?
        var oopSession: AcdOllamaSession?
        var oopPlan: OopPerTask.Plan?
        if settings.oopPerTask && model.provider == "ollama", let plan = OopPerTask.plan(paperBlock: paper),
           await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout) {
            oopSession = AcdOllamaSession(config: cfg, model: model.name); oopPlan = plan
        } else if settings.fastOOP && model.provider == "ollama", await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout) {
            oopSession = AcdOllamaSession(config: cfg, model: model.name)
        }
        rec["oop_per_task"] = oopSession != nil && oopPlan != nil
        var condCopy = rec["conditions"] as? [String: Any] ?? [:]
        condCopy["oop_per_task"] = oopSession != nil && oopPlan != nil
        condCopy["oop_request"] = oopPlan != nil ? "one request per task, thinking off" : (oopSession != nil ? "single request, thinking off, small context" : "single request, thinking on (original)")
        rec["conditions"] = condCopy
        let hooks = PipelineHooks(
            generate: { [unowned self] prompt, label in
                self.log("  \(label)…")
                if let s = oopSession, oopPlan == nil, settings.fastOOP {
                    let r = await s.generate(AcdRequest(prompt: prompt, label: label, kind: label == "✍️ Writing" ? "whole" : "repair",
                                                        numPredict: label == "✍️ Writing" ? max(cfg.numPredict, 4096) : 4000, temperature: 0.2, think: false))
                    if let e = r.error { failure = "\(label): \(e)"; await MainActor.run { self.log("  ⚠️ " + e) }; return r.text.isEmpty ? nil : r.text }
                    return r.text
                }
                if let s = oopSession, let plan = oopPlan {
                    func ask(_ req: AcdRequest) async -> String? {
                        let r = await s.generate(req)
                        if let e = r.error { failure = "\(req.label): \(e)"; let msg = failure ?? e; await MainActor.run { self.log("  ⚠️ " + msg) }; return r.text.isEmpty ? nil : r.text }
                        return r.text
                    }
                    if label == "✍️ Writing" { return await OopPerTask.writeAnswer(plan: plan, careful: AcdSettings.careful, generate: { await ask($0) }, status: { _ in }) }
                    return await ask(AcdRequest(prompt: prompt, label: label, kind: "repair", numPredict: 4000, temperature: 0.2, think: false))
                }
                var f: String?
                let a = await self.generate(provider: provider, cfg: cfg, prompt: prompt, model: model.name, label: label, failure: &f)
                if let f = f { failure = f; self.log("  ⚠️ \(f)") }
                return a
            },
            compile: { answer in
                if starter.isEmpty { return nil }
                return await Task.detached(priority: .userInitiated) { AppDelegate.runJavac(answer: answer, starter: starter) }.value
            },
            status: { [unowned self] s in if s.hasPrefix("🧪") { self.log("  🧪 compiling…") } },
            resetOutput: {})
        let result = await DropPipeline.run(paper: paper, provider: model.provider, starter: starter, hooks: hooks)
        if let s = oopSession { await s.release() }
        if Task.isCancelled { log("  ⏹ cancelled — this run is not recorded"); return }
        rec["finished_at"] = benchISO()
        guard let res = result else {
            rec["final_status"] = "generation_failed"; rec["error"] = failure ?? "no answer"
            rec["generation_ms"] = Int(Date().timeIntervalSince(started) * 1000)
            BenchStore.append(rec); log("  ❌ generation failed: \(failure ?? "no answer")"); return
        }
        try? res.answer.write(to: runDir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        rec["answer_path"] = runDir.appendingPathComponent("answer.txt").path
        rec["generation_ms"] = res.generationMs
        rec["compile_ms"] = res.compileMs
        rec["repair_rounds"] = res.repairRounds
        let compileStatus = res.compiled == nil ? "unchecked" : (res.compiled! ? "compiled" : "failed")
        rec["compile_status"] = compileStatus
        if !res.lastErrors.isEmpty { rec["compile_errors"] = String(res.lastErrors.prefix(1500)) }
        // functional tests: only when the solution compiles (never awarded when not executed)
        var functional: [String: Any] = ["declared": task.declaredTests]
        var verdict: [String: BenchTestResult] = [:]
        if compileStatus == "failed" {
            functional["ran"] = false; functional["reason"] = "solution does not compile"
        } else {
            log("  🧪 running \(task.declaredTests) functional tests…")
            switch await Task.detached(priority: .userInitiated, operation: {
                BenchTestRunner.run(task: task, answer: res.answer, starter: starter) }).value {
            case .notRun(let why):
                functional["ran"] = false; functional["reason"] = why
            case .ran(let rs):
                functional["ran"] = true
                functional["total"] = rs.count
                functional["passed"] = rs.filter { $0.passed }.count
                functional["failed"] = rs.filter { !$0.passed }.map { ["id": $0.id, "title": $0.title, "message": $0.message] }
                for r in rs { verdict[r.id] = r }
            }
        }
        rec["functional"] = functional
        // requirement coverage: automated / manual / untestable kept apart
        var reqs: [[String: Any]] = []
        let ran = (functional["ran"] as? Bool) == true
        for r in task.requirements {
            var status: String
            var failed: [String] = []
            switch r.kind {
            case "manual": status = "manual_unassessed"
            case "untestable": status = "untestable"
            default:
                if !ran { status = "not_run" }
                else {
                    let missing = r.tests.filter { verdict[$0] == nil }
                    failed = r.tests.filter { verdict[$0]?.passed == false } + missing
                    status = failed.isEmpty && !r.tests.isEmpty ? "verified" : "failed"
                }
            }
            var d: [String: Any] = ["id": r.id, "marks": r.marks, "kind": r.kind, "status": status, "text": r.text]
            if !failed.isEmpty { d["failed_tests"] = failed }
            reqs.append(d)
        }
        rec["requirements"] = reqs
        let q = BenchQuality.analyze(answer: res.answer, starter: starter, expectedNew: task.expectedNewFiles)
        rec["quality"] = ["auto_points": q.points, "auto_max": 10, "notes": q.notes]
        rec["final_status"] = !ran ? "tests_not_run" : ((functional["passed"] as? Int) == (functional["total"] as? Int) ? "all_tests_passed" : "some_tests_failed")
        BenchStore.append(rec)
        let secs = Double(res.generationMs + res.compileMs) / 1000
        let tline: String
        if ran { tline = "tests \(functional["passed"] ?? 0)/\(functional["total"] ?? 0)" } else { tline = "tests NOT RUN (\(functional["reason"] ?? "?"))" }
        log("  → \(compileStatus == "compiled" ? "compiles ✓" : compileStatus == "failed" ? "compile errors ✗" : "compile unchecked") · \(res.repairRounds) repair(s) · \(tline) · \(String(format: "%.0f", secs)) s")
    }
}

// ---- ACD benchmark: objective key grading, executed checks, static checks, manual rubric — kept apart ----
enum BenchACDCheck {
    /// Fenced code first (what a student would paste), then the whole answer text.
    static func codeCandidates(_ text: String) -> [String] {
        var fenced: [String] = [], cur: [String]? = nil
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = cur { fenced.append(c.joined(separator: "\n")); cur = nil } else { cur = [] }
            } else if cur != nil { cur!.append(line) }
        }
        var out: [String] = []
        if !fenced.isEmpty { out.append(fenced.joined(separator: "\n")) }
        out.append(text)
        return out
    }

    static func tempDir() -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("dropacd-c-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return acdRealPath(raw)
    }

    /// status: verified | failed | not_run (tool missing) | static_pass | static_fail
    static func run(check: [String: Any], text: String) -> (status: String, detail: String) {
        switch check["type"] as? String ?? "" {
        case "regex-all":
            var missing: [String] = []
            for p in (check["patterns"] as? [String] ?? []) where text.range(of: p, options: [.regularExpression, .caseInsensitive]) == nil { missing.append(p) }
            let any = check["anyOf"] as? [String] ?? []
            if !any.isEmpty && !any.contains(where: { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { missing.append("one of: " + any.joined(separator: " | ")) }
            return missing.isEmpty ? ("static_pass", "all patterns present") : ("static_fail", "missing: " + missing.joined(separator: "; "))
        case "node-eval":
            guard let node = AcdTools.find("node") else { return ("not_run", "node not found") }
            let setup = check["setup"] as? String ?? "", declares = check["declares"] as? String ?? "", expr = check["expr"] as? String ?? "", expect = check["expect"] as? String ?? ""
            var lastErr = "no runnable code found"
            for cand in codeCandidates(text) {
                let tmp = tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
                let declared = !declares.isEmpty && cand.range(of: "\\b(const|let|var)\\s+\(declares)\\b", options: .regularExpression) != nil
                let script = (declared ? "" : setup + "\n") + cand + "\n;process.stdout.write('\\n__RESULT__' + JSON.stringify(" + expr + "));\n"
                let f = tmp.appendingPathComponent("answer.cjs")
                try? script.write(to: f, atomically: true, encoding: .utf8)
                let r = AcdTools.sandboxed(node, [f.path], cwd: tmp, writable: [tmp.path], timeout: 20)
                if let range = r.output.range(of: "__RESULT__") {
                    let got = String(r.output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return got == expect ? ("verified", "result \(got)") : ("failed", "expected \(expect) but the code produced \(got)")
                }
                lastErr = String(r.output.replacingOccurrences(of: tmp.path + "/", with: "").prefix(200))
            }
            return ("failed", lastErr)
        case "ts-compile":
            guard let node = AcdTools.find("node") else { return ("not_run", "node not found") }
            guard let nm = AcdTools.toolchainNM, FileManager.default.fileExists(atPath: nm.appendingPathComponent("typescript/bin/tsc").path) else {
                return ("not_run", "TypeScript is not installed (Prepare ACD toolchain)") }
            let suffix = check["suffix"] as? String ?? ""
            var lastErr = "no code found"
            for cand in codeCandidates(text) {
                let tmp = tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
                try? (cand + "\n" + suffix).write(to: tmp.appendingPathComponent("answer.ts"), atomically: true, encoding: .utf8)
                let r = AcdTools.sandboxed(node, [acdRealPath(nm).appendingPathComponent("typescript/bin/tsc").path, "--noEmit", "--strict", "--target", "es2022", "--skipLibCheck", "answer.ts"],
                                           cwd: tmp, writable: [tmp.path], timeout: 60)
                if r.status == 0 { return ("verified", "compiles under tsc --strict and rejects the invalid objects") }
                lastErr = String(r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").prefix(3).joined(separator: " | ").prefix(250))
            }
            return ("failed", lastErr)
        default: return ("not_run", "unknown check type")
        }
    }
}

extension BenchRunner {
    func runOneACD(model: BenchModelRef, task: BenchTask) async {
        let started = Date()
        let safe = model.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let runDir = BENCH_DIR.appendingPathComponent("runs/\(settings.runId)/\(model.provider)_\(safe)/\(task.id)")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var rec: [String: Any] = [
            "schema": 2, "subject": "acd", "run_id": settings.runId, "started_at": benchISO(started),
            "provider": model.provider, "model": model.name, "model_info": model.info,
            "task": task.id, "task_title": task.title, "run_dir": runDir.path,
        ]
        guard let (inputDir, inputHash) = task.prepareInput(into: runDir) else {
            rec["final_status"] = "error"; rec["error"] = "could not prepare task input"; rec["finished_at"] = benchISO()
            BenchStore.append(rec); log("  ❌ could not prepare task input"); return
        }
        rec["input_hash"] = inputHash
        let input = AcdInput.collect(inputDir, extract: { self.collector.extractText($0) })
        if input.taskOnly.split(whereSeparator: { $0.isWhitespace }).count < 15 {
            rec["final_status"] = "error"; rec["error"] = "no readable task text"; rec["finished_at"] = benchISO()
            BenchStore.append(rec); log("  ❌ no readable task text"); return
        }
        var cfg = settings.base
        cfg.provider = model.provider
        cfg.sessionId = UUID().uuidString
        if model.provider == "opencode_go" { cfg.ocModel = model.name }
        let ceiling = model.provider == "ollama" ? (cfg.ollamaContext > 0 ? min(cfg.ollamaContext, 65536) : cfg.ollamaContextCeiling) : 32768
        let chunks = AcdNotes.load(dirs: [AcdNotes.installedDir, AcdNotes.desktopDir], extract: { self.collector.extractText($0) })
        let careful = AcdSettings.careful
        let runInput = AcdRunInput(taskText: input.taskOnly, paperBlock: input.paper, starter: input.starter, chunks: chunks, careful: careful,
                                   ceilingTokens: ceiling, questionCount: input.questionCount)
        let plan = AcdPlan.make(input.taskOnly)
        rec["conditions"] = [
            "files_read": input.fileCount, "starter_files": input.starter.count, "mode": plan.units.count >= 2 ? "units" : "whole",
            "units": plan.units.count, "careful_mode": careful, "think": careful ? "free questions only" : "off",
            "ollama_context_setting": cfg.ollamaContext, "temperature": "0 objective / 0.2 free", "keep_alive": "2m during the run, unloaded when it ends or grows past 60% of RAM",
            "prompt_header_hash": benchHash(ACD_PROMPT_HEADER + AcdPrompt.module), "repair_header_hash": benchHash(ACD_REPAIR_HEADER),
            "deterministic_fixers": true, "max_repair_rounds": AcdPipeline.maxRepairs, "notes_chars_available": chunks.reduce(0) { $0 + $1.text.count },
        ]
        var failure: String?
        let starter = input.starter, root = input.projectRoot
        var session: AcdOllamaSession?
        let generate: (AcdRequest) async -> String?
        var statusCount = 0
        if model.provider == "ollama" {
            guard await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout) else {
                rec["final_status"] = "generation_failed"; rec["error"] = "Ollama could not be started"; rec["finished_at"] = benchISO()
                BenchStore.append(rec); log("  ❌ Ollama could not be started"); return
            }
            let s = AcdOllamaSession(config: cfg, model: model.name)
            session = s
            generate = { [unowned self] req in
                if req.kind != "objective" { self.log("  \(req.label)…") }
                let r = await s.generate(req)
                if let e = r.error { failure = "\(req.label): \(e)"; self.log("  ⚠️ " + failure!); return r.text.isEmpty ? nil : r.text }
                return r.text
            }
        } else {
            generate = { [unowned self] req in
                if req.kind != "objective" { self.log("  \(req.label)…") }
                var f: String?
                let a = await self.generate(provider: OpenCodeGoProvider(config: cfg), cfg: cfg, prompt: req.prompt, model: model.name, label: req.label, failure: &f)
                if let f = f { failure = f; self.log("  ⚠️ \(f)") }
                return a
            }
        }
        let hooks = AcdHooks(
            generate: generate,
            validate: { files in await Task.detached(priority: .userInitiated) { AcdValidator.validate(files: files, starter: starter, projectRoot: root) }.value },
            status: { [unowned self] s in statusCount += 1; if s.hasPrefix("⏳ ACD ·") && statusCount % 10 == 0 { self.log("  " + s.replacingOccurrences(of: "⏳ ACD · ", with: "")) } },
            resetOutput: {})
        let result = await AcdPipeline.run(input: runInput, hooks: hooks)
        if let s = session { await s.release() }
        if Task.isCancelled { log("  ⏹ cancelled — this run is not recorded"); return }
        rec["finished_at"] = benchISO()
        guard let res = result else {
            rec["final_status"] = "generation_failed"; rec["error"] = failure ?? "no answer"
            rec["generation_ms"] = Int(Date().timeIntervalSince(started) * 1000)
            BenchStore.append(rec); log("  ❌ generation failed: \(failure ?? "no answer")"); return
        }
        try? res.answer.write(to: runDir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        rec["answer_path"] = runDir.appendingPathComponent("answer.txt").path
        rec["generation_ms"] = res.generationMs
        rec["compile_ms"] = res.validationMs
        rec["repair_rounds"] = res.repairRounds
        if !res.repairNote.isEmpty { rec["repair_note"] = res.repairNote }
        rec["acd_run"] = ["mode": res.mode, "units": res.unitCount, "unanswered": res.unanswered, "unit_ms": res.unitMs, "notes_used": res.notesUsed,
                          "requests": session?.requestCount ?? 0, "unloads": session?.unloadCount ?? 0]

        // ---- grade: each kind of evidence is kept separate ----
        let doc = AcdDoc.parse(res.answer)
        let qtext = doc.questionText
        var reqs: [[String: Any]] = [], failedList: [[String: String]] = []
        var objCorrect = 0, objTotal = 0, execPass = 0, execTotal = 0, staticPass = 0, staticTotal = 0
        var sections: [String: [Int]] = [:]
        var expectedQ = Set<String>()
        for r in task.requirements {
            if !r.question.isEmpty { expectedQ.insert(r.question) }
            var d: [String: Any] = ["id": r.id, "marks": r.marks, "kind": r.kind, "text": r.text]
            switch r.kind {
            case "objective":
                objTotal += 1
                let got = qtext[r.question].flatMap { AcdObjective.normalise($0) }
                let ok = got == r.answer
                let sec = String(r.question.prefix(1)); var cur = sections[sec] ?? [0, 0]; cur[1] += 1; if ok { cur[0] += 1 }; sections[sec] = cur
                if ok { objCorrect += 1; d["status"] = "verified" }
                else {
                    d["status"] = "failed"; d["failed_tests"] = [r.id]
                    d["expected"] = r.answer; d["got"] = got ?? "(no readable answer)"
                    failedList.append(["id": r.id, "title": "objective", "message": "expected \(r.answer) but got \(got ?? "no readable answer")"])
                }
            case "automated":
                execTotal += 1
                let c = BenchACDCheck.run(check: r.check, text: qtext[r.question] ?? "")
                d["status"] = c.status == "verified" ? "verified" : (c.status == "not_run" ? "not_run" : "failed")
                d["detail"] = c.detail
                if c.status == "verified" { execPass += 1 } else { d["failed_tests"] = [r.id]; failedList.append(["id": r.id, "title": "executed check", "message": c.detail]) }
            case "static":
                staticTotal += 1
                let c = BenchACDCheck.run(check: r.check, text: qtext[r.question] ?? "")
                d["status"] = c.status; d["detail"] = c.detail
                if c.status == "static_pass" { staticPass += 1 }
            case "manual": d["status"] = "manual_unassessed"; d["rubric"] = r.rubric
            default: d["status"] = "untestable"
            }
            reqs.append(d)
        }
        let answeredIDs = expectedQ.filter { !(qtext[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || doc.part($0) != nil }
        rec["requirements"] = reqs
        rec["functional"] = ["ran": true, "declared": objTotal + execTotal, "total": objTotal + execTotal, "passed": objCorrect + execPass, "failed": failedList]
        rec["acd"] = [
            "objective": ["correct": objCorrect, "total": objTotal], "objective_by_section": sections,
            "executed": ["passed": execPass, "total": execTotal], "static": ["passed": staticPass, "total": staticTotal],
            "answered": answeredIDs.count, "expected_questions": expectedQ.count,
            "validation": res.validation.jsonObject, "validation_summary": res.validation.summary, "validation_failures": res.validation.failureCount,
            "rejected_paths": doc.rejectedPaths,
        ]
        var qpts = 10.0, qnotes: [String] = []
        if !doc.rejectedPaths.isEmpty { let d = min(6.0, 2.0 * Double(doc.rejectedPaths.count)); qpts -= d; qnotes.append("−\(Int(d)): file path(s) outside the project rejected: " + doc.rejectedPaths.joined(separator: ", ")) }
        let placeholders = qtext.values.filter { $0.contains("TODO") || $0.contains("...") }.count
        if placeholders > 0 { let d = min(4.0, Double(placeholders)); qpts -= d; qnotes.append("−\(Int(d)): \(placeholders) answer(s) contain TODO/placeholders") }
        rec["quality"] = ["auto_points": qpts, "auto_max": 10, "notes": qnotes]
        rec["compile_status"] = "n/a"
        rec["final_status"] = objCorrect + execPass == objTotal + execTotal ? "all_automated_passed" : "some_automated_failed"
        BenchStore.append(rec)
        let secs = Double(res.generationMs + res.validationMs) / 1000
        log("  → objective \(objCorrect)/\(objTotal) · executed \(execPass)/\(execTotal) · static \(staticPass)/\(staticTotal) · answered \(answeredIDs.count)/\(expectedQ.count) · manual items pending · \(String(format: "%.0f", secs)) s")
    }
}

// ---- scoring + ranked report -------------------------------------------------------
// Methodology (also printed in every report):
//   Functional correctness 40  passed tests / declared tests (0 and flagged when tests did not run)
//   Requirement coverage   20  marks of AUTOMATED requirements whose linked tests all passed / automated marks
//   Compilation            15  15 when it compiles first time, -3 per repair round (min 3), 0 if it never compiles
//   Code quality           15  10 automated simplicity checks (deductions listed) + 5 manual rating (0 if unassessed)
//   Efficiency             10  speed relative to the fastest model on the task, MULTIPLIED by the functional
//                              fraction, so speed alone can never score and cannot outweigh correctness
// Code length is not scored directly. Manual and untestable requirements are reported, never counted as passed.

struct BenchScore {
    var provider: String, model: String, task: String
    var subject = "oop"
    var objCorrect = 0, objTotal = 0, execPass = 0, execTotal = 0, staticPass = 0, staticTotal = 0
    var objSections: [String: [Int]] = [:]
    var answered = 0, expectedQ = 0
    var staticMarks = 0.0, manualAssessedMarks = 0.0, manualAssessedItems = 0, manualItems = 0
    var validationSummary = ""
    var functional = 0.0, coverage = 0.0, compilation = 0.0, qualityAuto = 0.0, qualityManual = 0.0, efficiency = 0.0
    var testsRan = false, manualAssessed = false
    var passed = 0, total = 0
    var compiled = false, compileStatus = "unchecked"
    var repairs = 0, genMs = 0, compMs = 0
    var verifiedMarks = 0.0, autoMarks = 0.0, manualMarks = 0.0, untestableCount = 0, paperMarks = 0.0
    var failedReqs: [String] = [], failedTests: [(String, String)] = []
    var notRunReason = "", finalStatus = "", info: [String: Any] = [:], inputHash = "", conditions: [String: Any] = [:]
    var overall: Double { functional + coverage + compilation + qualityAuto + qualityManual + efficiency }
    var totalMs: Int { genMs + compMs }
}

enum BenchBlock {
    case h(Int, String), p(String), table([String], [[String]]), list([String])
}

enum BenchReport {
    static func manualKey(_ provider: String, _ model: String, _ task: String) -> String { "\(provider):\(model) | \(task)" }

    static func scores(results: [[String: Any]], manual: [String: Any]) -> [BenchScore] {
        var latest: [String: [String: Any]] = [:]
        var order: [String] = []
        for r in results {
            guard let p = r["provider"] as? String, let m = r["model"] as? String, let t = r["task"] as? String else { continue }
            let k = "\(p)|\(m)|\(t)"
            if latest[k] == nil { order.append(k) }
            latest[k] = r
        }
        var out: [BenchScore] = []
        for k in order {
            let r = latest[k]!
            var s = BenchScore(provider: r["provider"] as! String, model: r["model"] as! String, task: r["task"] as! String)
            s.info = r["model_info"] as? [String: Any] ?? [:]
            s.subject = r["subject"] as? String ?? "oop"
            s.inputHash = r["input_hash"] as? String ?? ""
            s.conditions = r["conditions"] as? [String: Any] ?? [:]
            s.finalStatus = r["final_status"] as? String ?? "?"
            s.genMs = r["generation_ms"] as? Int ?? 0
            s.compMs = r["compile_ms"] as? Int ?? 0
            s.repairs = r["repair_rounds"] as? Int ?? 0
            s.compileStatus = r["compile_status"] as? String ?? "none"
            s.compiled = s.compileStatus == "compiled"
            if s.compiled { s.compilation = max(3, 15 - 3 * Double(s.repairs)) }
            if s.subject == "acd" {
                // ACD has no compiler: "validity" = fraction of the paper's questions answered, halved if generated code files fail validation
                let a = r["acd"] as? [String: Any] ?? [:]
                s.answered = a["answered"] as? Int ?? 0; s.expectedQ = a["expected_questions"] as? Int ?? 0
                let fails = a["validation_failures"] as? Int ?? 0
                s.compilation = s.expectedQ > 0 ? 15 * Double(s.answered) / Double(s.expectedQ) * (fails > 0 ? 0.5 : 1) : 0
                s.compiled = s.expectedQ > 0 && s.answered == s.expectedQ
                s.compileStatus = "answered \(s.answered)/\(s.expectedQ)"
                s.validationSummary = a["validation_summary"] as? String ?? ""
                let ob = a["objective"] as? [String: Any] ?? [:], ex = a["executed"] as? [String: Any] ?? [:], st = a["static"] as? [String: Any] ?? [:]
                s.objCorrect = ob["correct"] as? Int ?? 0; s.objTotal = ob["total"] as? Int ?? 0
                s.execPass = ex["passed"] as? Int ?? 0; s.execTotal = ex["total"] as? Int ?? 0
                s.staticPass = st["passed"] as? Int ?? 0; s.staticTotal = st["total"] as? Int ?? 0
                for (k, v) in (a["objective_by_section"] as? [String: [Int]] ?? [:]) { s.objSections[k] = v }
            }
            let f = r["functional"] as? [String: Any] ?? [:]
            s.testsRan = (f["ran"] as? Bool) == true
            s.total = f["total"] as? Int ?? (f["declared"] as? Int ?? 0)
            s.passed = f["passed"] as? Int ?? 0
            s.notRunReason = f["reason"] as? String ?? ""
            for x in (f["failed"] as? [[String: Any]] ?? []) { s.failedTests.append((x["id"] as? String ?? "?", x["message"] as? String ?? "")) }
            if s.testsRan && s.total > 0 { s.functional = 40 * Double(s.passed) / Double(s.total) }
            for q in (r["requirements"] as? [[String: Any]] ?? []) {
                let marks = (q["marks"] as? NSNumber)?.doubleValue ?? 0
                s.paperMarks += marks
                switch q["kind"] as? String ?? "" {
                case "manual":
                    s.manualMarks += marks; s.manualItems += 1
                    if let mr = (manual[manualKey(s.provider, s.model, s.task)] as? [String: Any])?["requirements"] as? [String: Any],
                       let got = (mr[q["id"] as? String ?? ""] as? NSNumber)?.doubleValue { s.manualAssessedMarks += max(0, min(marks, got)); s.manualAssessedItems += 1 }
                case "static": s.staticMarks += marks      // pattern checks: reported, never counted as tests or coverage
                case "untestable": s.untestableCount += 1
                default:
                    s.autoMarks += marks
                    if (q["status"] as? String) == "verified" { s.verifiedMarks += marks }
                    else if (q["status"] as? String) == "failed" { s.failedReqs.append(q["id"] as? String ?? "?") }
                }
            }
            if s.autoMarks > 0 { s.coverage = 20 * s.verifiedMarks / s.autoMarks }
            let ql = r["quality"] as? [String: Any] ?? [:]
            s.qualityAuto = (ql["auto_points"] as? NSNumber)?.doubleValue ?? 0
            if let m = manual[manualKey(s.provider, s.model, s.task)] as? [String: Any], let rating = (m["quality"] as? NSNumber)?.doubleValue {
                s.qualityManual = max(0, min(5, rating)); s.manualAssessed = true
            }
            out.append(s)
        }
        // efficiency: relative to the fastest run on the same task, gated by correctness
        var fastest: [String: Int] = [:]
        for s in out where s.totalMs > 0 { fastest[s.task] = min(fastest[s.task] ?? Int.max, s.totalMs) }
        for i in out.indices {
            let s = out[i]
            let frac = (s.testsRan && s.total > 0) ? Double(s.passed) / Double(s.total) : 0
            if let fast = fastest[s.task], s.totalMs > 0 { out[i].efficiency = 10 * min(1, Double(fast) / Double(s.totalMs)) * frac }
        }
        return out
    }

    struct ModelAgg {
        var provider: String, model: String
        var rows: [BenchScore]
        func avg(_ f: (BenchScore) -> Double) -> Double { rows.isEmpty ? 0 : rows.map(f).reduce(0, +) / Double(rows.count) }
        var overall: Double { avg { $0.overall } }
        var correctness: Double { avg { $0.functional + $0.coverage } }   // /60: tests + requirement coverage only
        var passed: Int { rows.map { $0.passed }.reduce(0, +) }
        var total: Int { rows.map { $0.total }.reduce(0, +) }
        var funcRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
        var compileRate: Double { rows.isEmpty ? 0 : Double(rows.filter { $0.compiled }.count) / Double(rows.count) }
    }

    static func sectionBlocks(sc: [BenchScore], tasks: [BenchTask], subject: String) -> [BenchBlock] {
        var blocks: [BenchBlock] = []
        var groups: [String: [BenchScore]] = [:]
        for s in sc { groups["\(s.provider)|\(s.model)", default: []].append(s) }
        var aggs = groups.map { ModelAgg(provider: $0.value[0].provider, model: $0.value[0].model, rows: $0.value) }
        // Correctness first: speed, quality and code length can only break ties in correctness.
        aggs.sort { a, b in
            if abs(a.correctness - b.correctness) > 0.05 { return a.correctness > b.correctness }
            if abs(a.overall - b.overall) > 0.001 { return a.overall > b.overall }
            return a.avg { Double($0.totalMs) } < b.avg { Double($0.totalMs) }
        }
        let allTasks = Set(sc.map { $0.task })
        func f1(_ d: Double) -> String { String(format: "%.1f", d) }
        func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
        func sec(_ ms: Double) -> String { String(format: "%.1f", ms / 1000) }

        // ranking
        var rank: [[String]] = []
        for (i, a) in aggs.enumerated() {
            let partial = a.rows.count < allTasks.count ? " ⚠ \(a.rows.count)/\(allTasks.count) tasks" : ""
            let notRun = a.rows.filter { !$0.testsRan }.count
            let covMarks = a.rows.map { $0.verifiedMarks }.reduce(0, +), paper = a.rows.map { $0.paperMarks }.reduce(0, +)
            rank.append(["\(i + 1)", a.model + (a.provider == "opencode_go" ? " (cloud)" : ""), f1(a.correctness) + " / 60", f1(a.overall) + partial,
                         a.total == 0 ? "not run" : "\(a.passed)/\(a.total) (\(pct(a.funcRate)))" + (notRun > 0 ? " · \(notRun) task(s) not run" : ""),
                         paper == 0 ? "—" : pct(covMarks / paper), pct(a.compileRate),
                         sec(a.avg { Double($0.genMs) }), sec(a.avg { Double($0.compMs) }), f1(a.avg { Double($0.repairs) }),
                         f1(a.avg { $0.qualityAuto + $0.qualityManual })])
        }
        blocks.append(.h(3, "Overall ranking"))
        blocks.append(.table(["#", "Model", "Correctness /60", "Overall /100", subject == "acd" ? "Automated results (objective + executed)" : "Functional tests", "Paper marks verified", subject == "acd" ? "Complete answers" : "Compile success", "Avg generation s", subject == "acd" ? "Avg validation s" : "Avg compile s", "Avg repairs", "Quality /15"], rank))
        blocks.append(.p("Ranking is correctness-first: models are ordered by Correctness (functional tests + requirement coverage, 60 points); only models with equal correctness are ordered by Overall, then speed. So response speed, code quality and code length can never lift a less correct model above a more correct one. Overall (/100) is shown for information. A model run on fewer tasks than others is marked ⚠ and is not directly comparable. “Paper marks verified” counts only marks proven by automated tests, out of the full 100 marks of each paper."))

        // breakdown
        blocks.append(.h(3, "Score breakdown (average per task)"))
        var br: [[String]] = []
        for a in aggs {
            br.append([a.model, f1(a.avg { $0.functional }) + " / 40", f1(a.avg { $0.coverage }) + " / 20", f1(a.avg { $0.compilation }) + " / 15",
                       f1(a.avg { $0.qualityAuto }) + " + " + f1(a.avg { $0.qualityManual }) + " / 15", f1(a.avg { $0.efficiency }) + " / 10", f1(a.overall)])
        }
        blocks.append(.table(["Model", "Functional correctness", "Requirement coverage", subject == "acd" ? "Validity" : "Compilation", "Code quality (auto + manual)", "Efficiency", "Overall"], br))

        // per task
        blocks.append(.h(3, "Per-task results"))
        var pt: [[String]] = []
        for t in allTasks.sorted() {
            for a in aggs {
                guard let s = a.rows.first(where: { $0.task == t }) else { continue }
                let tests = s.testsRan ? "\(s.passed)/\(s.total)" : "NOT RUN"
                pt.append([t, a.model, f1(s.overall), s.compileStatus + (s.repairs > 0 ? " (\(s.repairs) repair)" : ""), tests,
                           sec(Double(s.genMs)), sec(Double(s.compMs)), s.testsRan ? "" : s.notRunReason])
            }
        }
        blocks.append(.table(["Task", "Model", "Score", subject == "acd" ? "Answers present" : "Compilation", subject == "acd" ? "Automated passed" : "Tests passed", "Gen s", "Compile s", "Note"], pt))

        if subject == "acd" { blocks += acdEvidenceBlocks(aggs: aggs, tasks: tasks) }

        // strengths / weaknesses
        blocks.append(.h(3, "Strengths and weaknesses"))
        let comps: [(String, (BenchScore) -> Double, Double)] = [("functional correctness", { $0.functional }, 40), ("requirement coverage", { $0.coverage }, 20),
                                                                  ("compilation without repairs", { $0.compilation }, 15), ("code simplicity", { $0.qualityAuto }, 10),
                                                                  ("efficiency", { $0.efficiency }, 10)]
        for a in aggs {
            var strong: [String] = [], weak: [String] = []
            for (name, fn, mx) in comps {
                let mine = a.avg(fn) / mx
                let others = aggs.filter { $0.model != a.model || $0.provider != a.provider }.map { $0.avg(fn) / mx }
                if let best = others.max(), mine >= best, mine >= 0.6 { strong.append("\(name) (\(pct(mine)))") }
                else if others.isEmpty && mine >= 0.8 { strong.append("\(name) (\(pct(mine)))") }
                if mine < 0.6 { weak.append("\(name) (\(pct(mine)))") }
                else if let worst = others.min(), mine < worst, aggs.count > 1 { weak.append("\(name) (\(pct(mine)), lowest of the group)") }
            }
            var notes: [String] = []
            if a.avg({ Double($0.repairs) }) >= 1 { notes.append("needed \(f1(a.avg { Double($0.repairs) })) repair round(s) per task on average") }
            let unrun = a.rows.filter { !$0.testsRan }
            if !unrun.isEmpty { notes.append("functional tests did not run for: " + unrun.map { "\($0.task) (\($0.notRunReason.isEmpty ? $0.finalStatus : $0.notRunReason))" }.joined(separator: "; ")) }
            blocks.append(.h(4, a.model + (a.provider == "opencode_go" ? " (cloud)" : "")))
            blocks.append(.list(["Strengths: " + (strong.isEmpty ? "none stands out" : strong.joined(separator: ", ")),
                                 "Weaknesses: " + (weak.isEmpty ? "none stands out" : weak.joined(separator: ", "))] + notes.map { "Note: " + $0 }))
        }

        // failures
        blocks.append(.h(3, "Failed requirements and tests"))
        var anyFail = false
        for a in aggs {
            var lines: [String] = []
            for s in a.rows where !s.failedReqs.isEmpty || !s.failedTests.isEmpty {
                let ft = s.failedTests.prefix(6).map { "\($0.0): \($0.1)" }.joined(separator: " · ")
                lines.append("\(s.task): requirements \(s.failedReqs.isEmpty ? "—" : s.failedReqs.joined(separator: ", ")) · \(s.failedTests.count) failing test(s)" + (ft.isEmpty ? "" : " — " + ft))
            }
            if !lines.isEmpty { anyFail = true; blocks.append(.h(4, a.model)); blocks.append(.list(lines)) }
        }
        if !anyFail { blocks.append(.p("No failing tests recorded.")) }

        if subject == "acd" { blocks += acdCoverageBlocks(tasks: tasks) } else {
        // coverage of the source material
        blocks.append(.h(3, "What the tests can and cannot verify"))
        var cv: [[String]] = []
        for t in tasks.sorted(by: { $0.id < $1.id }) {
            let auto = t.requirements.filter { $0.kind == "automated" }, man = t.requirements.filter { $0.kind == "manual" }, unt = t.requirements.filter { $0.kind == "untestable" }
            cv.append([t.id, "\(Int(auto.map { $0.marks }.reduce(0, +))) marks · \(auto.count) req.", "\(Int(man.map { $0.marks }.reduce(0, +))) marks · \(man.count) req.",
                       "\(unt.count)", "\(t.declaredTests)"])
        }
        blocks.append(.table(["Task", "Verified by automated tests", "Assessed manually (never scored as passed)", "Not testable (source unclear or missing)", "Declared tests"], cv))
        let untestable = tasks.flatMap { t in t.requirements.filter { $0.kind == "untestable" }.map { "\(t.id) \($0.id): \($0.text) — \($0.note)" } }
        if !untestable.isEmpty { blocks.append(.list(untestable)) }
        blocks.append(.p("When a missing question paper or an unclear rule is added, change the requirement's kind in task.json and add tests; the engine does not change."))

        }

        // conditions
        blocks.append(.h(3, "Conditions and reproducibility"))
        var cd: [[String]] = []
        for a in aggs {
            let s = a.rows[0]
            let i = s.info
            let ver = [i["digest"] as? String, i["parameter_size"] as? String, i["quantization"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            cd.append([a.model, a.provider, ver.isEmpty ? "(provider does not expose a version)" : ver.map { String($0.prefix(14)) }.joined(separator: " · "),
                       "\(s.conditions["num_predict"] ?? "?")", "\(s.conditions["ollama_context_setting"] ?? "?")", "\(s.conditions["prompt_header_hash"] ?? "?")",
                       (s.conditions["deterministic_fixers"] as? Bool) == true ? "yes" : "no"])
        }
        blocks.append(.table(["Model", "Provider", "Version (digest · size · quant)", "num_predict", "ctx setting", "Prompt hash", "Ollama fixers"], cd))
        let hashes = allTasks.sorted().map { t in "\(t): " + Set(sc.filter { $0.task == t }.map { $0.inputHash }).sorted().joined(separator: ", ") }
        blocks.append(.list(["Task input hashes (must be identical across models): " + hashes.joined(separator: " · "),
                             (sc.contains { ($0.conditions["oop_per_task"] as? Bool) == true } ? "OOP runs marked per-task used one request per task with thinking off (the popup's visible path); others used the original single request (think on, keep_alive 0) — compare like with like." : "Temperature 0.2, think on, keep_alive 0, max 4 repair rounds — identical for every Ollama model."),
                             "Ollama runs include Drop's deterministic code fixers, so scores describe model + Drop pipeline, not the raw model. Some fixers target patterns seen in these sample tasks; treat results on unrelated tasks as more representative of the raw model.",
                             "Code-quality manual rating (0–5) is read from bench/results/manual.json; unassessed items score 0 and are excluded from nothing else."]))
        return blocks
    }

    static func acdEvidenceBlocks(aggs: [ModelAgg], tasks: [BenchTask]) -> [BenchBlock] {
        var blocks: [BenchBlock] = []
        func f1(_ d: Double) -> String { String(format: "%.1f", d) }
        blocks.append(.h(3, "ACD evidence, kept separate"))
        blocks.append(.p("Automated results are objective answers graded against the answer key and checks that were actually executed or compiled. Static checks are pattern checks on the answer text: they are NOT tests and never count as functional correctness. Manual rubric marks come only from manual.json and are never added automatically. A syntax or static pass of generated code is reported on its own line and is not proof the code behaves correctly."))
        var rows: [[String]] = []
        for a in aggs {
            for s in a.rows {
                let sec = ["A", "B", "E"].compactMap { k in s.objSections[k].map { "\(k) \($0[0])/\($0[1])" } }.joined(separator: " · ")
                let manualLine = s.manualItems == 0 ? "—" : "\(f1(s.manualAssessedMarks)) of \(Int(s.manualMarks)) marks assessed (\(s.manualAssessedItems)/\(s.manualItems) items); \(s.manualItems - s.manualAssessedItems) unassessed"
                rows.append([a.model, s.task, "\(s.objCorrect)/\(s.objTotal)" + (sec.isEmpty ? "" : " (\(sec))"), "\(s.execPass)/\(s.execTotal)",
                             "\(s.staticPass)/\(s.staticTotal) (not tests)", s.validationSummary.isEmpty ? "—" : s.validationSummary, "\(s.answered)/\(s.expectedQ)", manualLine])
            }
        }
        blocks.append(.table(["Model", "Task", "Objective answers (auto-graded)", "Executed checks", "Static checks", "Generated-code validation", "Answers present", "Manual rubric"], rows))
        return blocks
    }

    static func acdCoverageBlocks(tasks: [BenchTask]) -> [BenchBlock] {
        var blocks: [BenchBlock] = []
        blocks.append(.h(3, "What the ACD checks can and cannot verify"))
        var cv: [[String]] = []
        for t in tasks.sorted(by: { $0.id < $1.id }) {
            func m(_ k: String) -> String { let r = t.requirements.filter { $0.kind == k }; return "\(Int(r.map { $0.marks }.reduce(0, +))) marks · \(r.count) item(s)" }
            cv.append([t.id, m("objective"), m("automated"), m("static"), m("manual"), m("untestable")])
        }
        blocks.append(.table(["Task", "Auto-graded objective", "Executed checks", "Static pattern checks (not tests)", "Manual rubric (needs a person)", "Not testable"], cv))
        let untestable = tasks.flatMap { t in t.requirements.filter { $0.kind == "untestable" }.map { "\(t.id) \($0.id): \($0.text) — \($0.note)" } }
        if !untestable.isEmpty { blocks.append(.list(untestable)) }
        return blocks
    }

    static func build(results: [[String: Any]], tasks: [BenchTask], manual: [String: Any]) -> (md: String, html: String) {
        let sc = scores(results: results, manual: manual)
        var blocks: [BenchBlock] = []
        blocks.append(.h(1, "Drop model benchmark report"))
        blocks.append(.p("Generated \(benchISO()). Source: results.jsonl — latest run per model and task. All models received identical task files and the same Drop pipeline (prompts, Ollama fixers, javac compile + repair loop)."))
        if sc.isEmpty {
            blocks.append(.p("No benchmark results recorded yet. Open Benchmark… from the Drop menu, select tasks and models, and run."))
            return (render(blocks, html: false), render(blocks, html: true))
        }
        blocks.append(.h(2, "Scoring methodology"))
        blocks.append(.table(["Component", "Points", "How it is computed"], [
            ["Functional correctness", "40", "passed tests / declared tests of the task. If the tests did not run (solution does not compile, JDK missing, tests incompatible) the score is 0 and the run is flagged — never a pass."],
            ["Requirement coverage", "20", "marks of AUTOMATED requirements whose linked tests all passed / marks of automated requirements (paper marks, Section A + B)."],
            ["Compilation", "15", "15 if the answer compiles first time; minus 3 per repair round (minimum 3); 0 if it never compiles or could not be checked."],
            ["Code quality", "15", "10 automated: start at 10; −2 per extra file the task did not ask for (max −6), −2 per extra interface/abstract class/enum (max −4), −1 per method over 40 lines (max −3), −3 for leftover TODO/UnsupportedOperationException. 5 manual: your 0–5 rating from bench/results/manual.json (0 if unassessed)."],
            ["Efficiency", "10", "10 × speed × functional fraction, speed = fastest total time on the task / this model's total time (generation + compile). Zero for a model that passes no tests."],
        ]))
        blocks.append(.p("Code length is not scored. Manual and untestable requirements are listed in their own table and are never counted as passed."))
        if sc.contains(where: { $0.subject == "acd" }) {
            blocks.append(.table(["ACD component", "Points", "How it is computed"], [
                ["Functional correctness", "40", "objective answers matching the answer key + executed checks passed, over all such items. Static pattern checks and manual rubric items are not included."],
                ["Requirement coverage", "20", "marks of objective and executed requirements that were verified / marks of all objective and executed requirements."],
                ["Validity (replaces Compilation)", "15", "15 × answered questions / questions in the paper; halved if generated code files fail syntax, static or build validation. No compiler exists for ACD answers."],
                ["Code quality", "15", "10 automated (deductions listed per run) + 5 manual rating."],
                ["Efficiency", "10", "same rule as OOP: speed × functional fraction."],
            ]))
        }
        for subj in ["oop", "acd"] {
            let part = sc.filter { $0.subject == subj }
            if part.isEmpty { continue }
            blocks.append(.h(2, subj == "acd" ? "ACD (web: React, TypeScript, HTML/CSS)" : "OOP (Java)"))
            blocks += sectionBlocks(sc: part, tasks: tasks.filter { $0.subject == subj }, subject: subj)
        }
        return (render(blocks, html: false), render(blocks, html: true))
    }

    static func render(_ blocks: [BenchBlock], html: Bool) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var o = ""
        if html {
            o += "<!doctype html><html><head><meta charset=\"utf-8\"><title>Drop benchmark report</title><style>"
            o += "body{font:14px -apple-system,Helvetica,sans-serif;max-width:1100px;margin:24px auto;padding:0 16px;color:#1d1d1f}table{border-collapse:collapse;margin:10px 0;width:100%}"
            o += "th,td{border:1px solid #d2d2d7;padding:5px 8px;text-align:left;vertical-align:top;font-size:12.5px}th{background:#f5f5f7}h1,h2,h3{margin:18px 0 6px}li{margin:3px 0}"
            o += "@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}th{background:#2c2c2e}th,td{border-color:#48484a}}</style></head><body>\n"
        }
        for b in blocks {
            switch b {
            case .h(let n, let t): o += html ? "<h\(n)>\(esc(t))</h\(n)>\n" : String(repeating: "#", count: n) + " " + t + "\n\n"
            case .p(let t): o += html ? "<p>\(esc(t))</p>\n" : t + "\n\n"
            case .list(let items):
                o += html ? "<ul>" + items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>\n" : items.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
            case .table(let head, let rows):
                if html {
                    o += "<table><tr>" + head.map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
                    for r in rows { o += "<tr>" + r.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }
                    o += "</table>\n"
                } else {
                    o += "| " + head.joined(separator: " | ") + " |\n|" + head.map { _ in "---" }.joined(separator: "|") + "|\n"
                    for r in rows { o += "| " + r.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |\n" }
                    o += "\n"
                }
            }
        }
        if html { o += "</body></html>\n" }
        return o
    }

    @discardableResult
    static func writeReport() -> URL? {
        BenchStore.ensureDirs()
        let results = BenchStore.loadAll()
        let tasks = BenchTask.loadAll()
        var manual: [String: Any] = [:]
        if let d = try? Data(contentsOf: BENCH_DIR.appendingPathComponent("results/manual.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { manual = o }
        let (md, html) = build(results: results, tasks: tasks, manual: manual)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = BENCH_DIR.appendingPathComponent("reports")
        let mdURL = dir.appendingPathComponent("report-\(stamp).md"), htmlURL = dir.appendingPathComponent("report-\(stamp).html")
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return htmlURL
    }
}

// ---- Benchmark window (opened from the tray menu: "Benchmark…") -------------------------
// Top-anchored scroll content (a normal NSView is bottom-up and would pin short lists to the bottom).
final class BenchFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class BenchWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var tasks: [BenchTask] = []
    var models: [BenchModelRef] = []
    var taskBoxes: [NSButton] = []
    var modelBoxes: [NSButton] = []
    let taskStack = NSStackView()
    let modelStack = NSStackView()
    let ocBox = NSButton(checkboxWithTitle: "OpenCode Go (cloud)", target: nil, action: nil)
    let ocField = NSTextField(string: "")
    let logScroll = NSTextView.scrollableTextView()
    let runBtn = NSButton(title: "Run benchmark", target: nil, action: nil)
    let stopBtn = NSButton(title: "Stop", target: nil, action: nil)
    var runTask: Task<Void, Never>?
    let currentConfig: () -> DropConfig
    let normalRunInProgress: () -> Bool

    init(config: @escaping () -> DropConfig, normalRunInProgress: @escaping () -> Bool) {
        self.currentConfig = config
        self.normalRunInProgress = normalRunInProgress
        super.init()
        build()
    }

    var logView: NSTextView { logScroll.documentView as! NSTextView }

    func log(_ s: String) {
        logView.textStorage?.append(NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
        logView.scrollToEndOfDocument(nil)
    }

    func listView(_ stack: NSStackView) -> NSScrollView {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sv = NSScrollView()
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        let doc = BenchFlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
                                     stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -8),
                                     stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6)])
        sv.documentView = doc
        doc.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor).isActive = true
        return sv
    }

    func button(_ t: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; b.controlSize = .small; return b
    }

    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Drop — Model Benchmark"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = window.contentView!
        func title(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .boldSystemFont(ofSize: 12); return l }

        let taskCol = NSStackView(views: [title("Tasks"), listView(taskStack), button("Open tasks folder", #selector(openTasks))])
        let modelHeader = NSStackView(views: [title("Models"), button("Refresh", #selector(refreshModels))])
        modelHeader.orientation = .horizontal
        ocBox.target = self
        ocField.placeholderString = "OpenCode model id"; ocField.controlSize = .small
        let ocRow = NSStackView(views: [ocBox, ocField]); ocRow.orientation = .horizontal
        let modelCol = NSStackView(views: [modelHeader, listView(modelStack), ocRow])
        for c in [taskCol, modelCol] { c.orientation = .vertical; c.alignment = .leading; c.spacing = 6 }
        let top = NSStackView(views: [taskCol, modelCol]); top.orientation = .horizontal; top.distribution = .fillEqually; top.spacing = 12
        top.alignment = .top

        runBtn.target = self; runBtn.action = #selector(startRun); runBtn.bezelStyle = .rounded; runBtn.keyEquivalent = "\r"
        stopBtn.target = self; stopBtn.action = #selector(stopRun); stopBtn.bezelStyle = .rounded; stopBtn.isEnabled = false
        let bar = NSStackView(views: [runBtn, stopBtn, button("Generate report", #selector(makeReport)), button("Open results folder", #selector(openResults))])
        bar.orientation = .horizontal; bar.spacing = 8
        logScroll.borderType = .bezelBorder

        let all = NSStackView(views: [top, bar, logScroll])
        all.orientation = .vertical; all.alignment = .leading; all.spacing = 8
        all.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(all)
        NSLayoutConstraint.activate([all.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                                     all.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                                     all.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                                     all.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                                     top.leadingAnchor.constraint(equalTo: all.leadingAnchor), top.trailingAnchor.constraint(equalTo: all.trailingAnchor),
                                     top.heightAnchor.constraint(equalToConstant: 230),
                                     logScroll.leadingAnchor.constraint(equalTo: all.leadingAnchor), logScroll.trailingAnchor.constraint(equalTo: all.trailingAnchor)])
        window.center()
    }

    func show() {
        reloadTasks()
        ocField.stringValue = currentConfig().ocModel
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if models.isEmpty && logView.string.isEmpty {
            log("Benchmark runs use the same pipeline as the popup but never touch its answer, clipboard or settings.")
            log("Click Refresh to list installed Qwen models (this starts Ollama if it is not running).")
        }
    }

    func reloadTasks() {
        tasks = BenchTask.loadAll()
        taskStack.arrangedSubviews.forEach { taskStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        taskBoxes = []
        if tasks.isEmpty {
            taskStack.addArrangedSubview(NSTextField(wrappingLabelWithString: "No tasks yet. Click “Open tasks folder” and copy the bench-tasks folders in."))
        }
        for t in tasks {
            let b = NSButton(checkboxWithTitle: "\(t.title) (\(t.level))", target: nil, action: nil)
            b.state = .on
            taskStack.addArrangedSubview(b); taskBoxes.append(b)
        }
    }

    @objc func openTasks() {
        BenchStore.ensureDirs()
        NSWorkspace.shared.open(BENCH_DIR.appendingPathComponent("tasks"))
    }
    @objc func openResults() {
        BenchStore.ensureDirs()
        NSWorkspace.shared.open(BENCH_DIR)
    }

    @objc func refreshModels() {
        let cfg = currentConfig()
        log("Looking for installed Qwen models…")
        Task { @MainActor in
            guard await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout) else {
                self.log("⚠️ Ollama could not be reached."); return
            }
            let details = await OllamaProvider(config: cfg).listModelDetails() ?? []
            let info = await BenchStore.ollamaInfo(base: cfg.ollamaBase)
            self.models = details.map { BenchModelRef(provider: "ollama", name: $0.name, info: info[$0.name] ?? [:]) }
            self.modelStack.arrangedSubviews.forEach { self.modelStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            self.modelBoxes = []
            if details.isEmpty { self.modelStack.addArrangedSubview(NSTextField(wrappingLabelWithString: "No Qwen model installed — ollama pull a Qwen model first.")) }
            for d in details {
                let b = NSButton(checkboxWithTitle: d.label, target: nil, action: nil)
                self.modelStack.addArrangedSubview(b); self.modelBoxes.append(b)
            }
            self.log("Found \(details.count) Qwen model(s).")
        }
    }

    @objc func startRun() {
        if normalRunInProgress() { log("⏳ A normal generation is running in the popup — wait for it to finish."); return }
        let pickedTasks = zip(tasks, taskBoxes).filter { $0.1.state == .on }.map { $0.0 }
        var pickedModels = zip(models, modelBoxes).filter { $0.1.state == .on }.map { $0.0 }
        let cfg = currentConfig()
        if ocBox.state == .on {
            let id = ocField.stringValue.trimmingCharacters(in: .whitespaces)
            if cfg.ocKey.isEmpty || id.isEmpty { log("⚠️ OpenCode Go needs an API key (Settings…) and a model id."); return }
            let a = NSAlert()
            a.messageText = "Send task files to OpenCode Go?"
            a.informativeText = "OpenCode Go is a cloud service. Running it sends each selected task's paper and starter files, and the generated code during repairs, to \(cfg.ocBase). Ollama runs stay on this Mac."
            a.addButton(withTitle: "Send to OpenCode Go"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { log("OpenCode Go not included."); return }
            pickedModels.append(BenchModelRef(provider: "opencode_go", name: id, info: [:]))
        }
        if pickedTasks.isEmpty || pickedModels.isEmpty { log("⚠️ Select at least one task and one model."); return }
        runBtn.isEnabled = false; stopBtn.isEnabled = true
        let runner = BenchRunner(tasks: pickedTasks, models: pickedModels,
                                 settings: BenchSettings(runId: "run-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"), base: cfg),
                                 log: { [weak self] in self?.log($0) })
        log("▶️ Starting: \(pickedModels.count) model(s) × \(pickedTasks.count) task(s)")
        runTask = Task { @MainActor in
            await runner.runAll()
            self.runBtn.isEnabled = true; self.stopBtn.isEnabled = false
            if !Task.isCancelled { self.makeReport() }
        }
    }

    @objc func stopRun() { runTask?.cancel(); log("Stopping after the current request…") }

    @objc func makeReport() {
        if let url = BenchReport.writeReport() { log("📄 Report: \(url.path)"); NSWorkspace.shared.open(url) }
        else { log("⚠️ Could not write the report.") }
    }

    func windowWillClose(_ notification: Notification) {}
}

// ===== Subjects: OOP (existing) and ACD (Advanced Client-Side Development) ==================
// The OOP path (DropPipeline, handle(), hotkeys) is untouched. ACD has its own prompts, input
// handling, parser, validators and pipeline below; both share ProviderAdapter and model discovery.

enum Subject: String {
    case oop, acd
    var label: String { self == .oop ? "OOP" : "ACD" }
    var folder: String { self == .oop ? "Desktop/OOP" : "Desktop/ACD" }
    /// Persisted under its own key; never touches config.json, the provider key or the model key.
    static var saved: Subject {
        Subject(rawValue: UserDefaults.standard.string(forKey: "subject") ?? "oop") ?? .oop
    }
    func save() { UserDefaults.standard.set(rawValue, forKey: "subject") }
}

let ACD_SUPPORT_DIR = ProcessInfo.processInfo.environment["DROP_ACD_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Drop/acd")

// ---- prompts (ACD only; the OOP/Java prompts are separate constants and unchanged) ----
let ACD_PROMPT_HEADER = """
You are completing a task for the university module Advanced Client-Side Development (ACD): HTML5, CSS3, Bootstrap,
JavaScript (ES6+), TypeScript, React (hooks, React Router, forms and validation, REST API consumption, TanStack Query,
Zustand, JWT-protected routes) and responsive, accessible UI. All work is client-side; never write a backend.

PRIORITY: the TASK section below is the specification. Follow its requirements exactly: the language (TypeScript or
JavaScript), file and component names, routes, props, API endpoints, marks and wording. The REFERENCE NOTES are course
material for conventions and terminology only. If the notes and the task disagree, the task wins. Answer every question and
every part of every task; never skip one and never invent requirements.

STYLE: simple, readable, student-level code that a second-year student could write. No over-engineering, no extra
abstractions, no libraries the task or the starter project does not already use. Keep every import and structure the
starter files already have and change only what the task requires. Complete files only, never placeholders or "...".

OUTPUT FORMAT (exactly; no introduction, no summary, no markdown fences):
Group the answer under task headers in the paper's order. A paper with numbered tasks or exercises uses its own numbers.
A paper with lettered sections uses Task 1 for section A, Task 2 for section B, and so on.
// ===== Task 1 =====
Under each task give one block per question, headed with the paper's own question identifier exactly as written (A1, B7, C3, D2):
// ===== Q A1 =====
For a multiple-choice question the first line is ONLY the letter (B). For true/false the first line is ONLY True or False.
An optional one-line reason may follow. For a short answer write the answer text. If a question has sub-parts, answer them
inside the same block using the paper's own labels (a., b., c.).
For code, give every file the question adds or changes, COMPLETE, each under its own header:
// ===== FILE: src/pages/Students.tsx =====
(Directly under a FILE header put that file's full code, nothing else. A file given again later replaces the earlier copy.)
For a task without question identifiers, use only the Task header and FILE headers.
"""

let ACD_REPAIR_HEADER = """
The code you wrote for the TASK failed validation. The ORIGINAL TASK REQUIREMENTS below still apply in full: do not drop,
weaken or reinterpret any of them. VALIDATION ERRORS lists exactly what failed and CURRENT FILES shows the code as it stands.
Fix the reported problems and keep everything that already works unchanged. Output ONLY the files you change, each COMPLETE,
each under its own header line:
// ===== FILE: src/path/File.tsx =====
No explanations, no markdown fences, no unchanged files, no question blocks.
"""

// ---- answer document: tasks, questions, files ----
struct AcdSegment {
    enum Kind { case preamble, task(Int), question(String), file(String) }
    var kind: Kind
    var header: String
    var body: [String]
}

struct AcdDoc {
    var segments: [AcdSegment] = []

    static let taskRe = try! NSRegularExpression(pattern: #"^//\s*=====\s*Task\s+(\d+)\s*=====\s*$"#)
    static let questionRe = try! NSRegularExpression(pattern: #"^//\s*=====\s*Q\s+([A-Za-z]{1,3}\d{1,3}(?:\.[A-Za-z0-9]+)?)\s*=====\s*$"#)
    static let fileRe = try! NSRegularExpression(pattern: #"^//\s*=====\s*FILE:\s*(.+?)\s*=====\s*$"#)

    private static func match(_ re: NSRegularExpression, _ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Only a path that stays inside the project is accepted (no absolute paths, no "..", no hidden control chars).
    static func sanitizePath(_ raw: String) -> String? {
        var p = raw.trimmingCharacters(in: CharacterSet(charactersIn: " `'\"*"))
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        if p.isEmpty || p.hasPrefix("/") || p.hasPrefix("~") || p.contains("\\") || p.contains("\0") { return nil }
        if p.split(separator: "/").contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) { return nil }
        return p
    }

    static func parse(_ text: String) -> AcdDoc {
        var doc = AcdDoc()
        var cur = AcdSegment(kind: .preamble, header: "", body: [])
        func flush() {
            if case .preamble = cur.kind, cur.body.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return }
            doc.segments.append(cur)
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let n = match(taskRe, line), let i = Int(n) { flush(); cur = AcdSegment(kind: .task(i), header: line, body: []) }
            else if let q = match(questionRe, line) { flush(); cur = AcdSegment(kind: .question(q.uppercased()), header: line, body: []) }
            else if let f = match(fileRe, line) { flush(); cur = AcdSegment(kind: .file(sanitizePath(f) ?? "!" + f), header: line, body: []) }
            else { cur.body.append(line) }
        }
        flush()
        return doc
    }

    func render() -> String {
        var out: [String] = []
        for s in segments {
            if case .preamble = s.kind {} else { out.append(s.header) }
            out += s.body
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File content without the marker line; surrounding blank lines and ONE wrapping fence pair are removed,
    /// every other line (including backticks inside template literals) is left exactly as written.
    static func clean(_ lines: [String]) -> String {
        var l = lines
        while let f = l.first, f.trimmingCharacters(in: .whitespaces).isEmpty { l.removeFirst() }
        while let e = l.last, e.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        if l.count >= 2, let f = l.first?.trimmingCharacters(in: .whitespaces), f.hasPrefix("```"),
           !f.dropFirst(3).contains("`"), l.last?.trimmingCharacters(in: .whitespaces) == "```" {
            l.removeFirst(); l.removeLast()
            while let f2 = l.first, f2.trimmingCharacters(in: .whitespaces).isEmpty { l.removeFirst() }
            while let e2 = l.last, e2.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        }
        if let f = l.first, f.hasPrefix("\u{FEFF}") { l[0] = String(f.dropFirst()) }
        return l.isEmpty ? "" : l.joined(separator: "\n") + "\n"
    }

    /// path -> clean code (last copy of a file wins). Invalid paths are dropped and listed in `rejectedPaths`.
    var files: [String: String] {
        var out: [String: String] = [:]
        for s in segments { if case .file(let p) = s.kind, !p.hasPrefix("!") { out[p] = AcdDoc.clean(s.body) } }
        return out
    }
    var fileOrder: [String] {
        var seen = Set<String>(), o: [String] = []
        for s in segments { if case .file(let p) = s.kind, !p.hasPrefix("!"), seen.insert(p).inserted { o.append(p) } }
        return o
    }
    var rejectedPaths: [String] {
        segments.compactMap { if case .file(let p) = $0.kind, p.hasPrefix("!") { return String(p.dropFirst()) } else { return nil } }
    }
    var questionIDs: [String] { segments.compactMap { if case .question(let q) = $0.kind { return q } else { return nil } } }

    /// First answer line of each question (objective answers) — text under the Q marker only, files excluded.
    var questionText: [String: String] {
        var out: [String: String] = [:]
        for s in segments { if case .question(let q) = s.kind { out[q] = out[q] ?? AcdDoc.clean(s.body) } }
        return out
    }

    /// Replace files (and questions) from `fixes`; everything else is preserved in place. New files are appended.
    func merging(_ fixes: AcdDoc) -> AcdDoc {
        var out = self
        for f in fixes.segments {
            switch f.kind {
            case .file(let p) where !p.hasPrefix("!"):
                if let i = out.segments.lastIndex(where: { if case .file(let q) = $0.kind { return q == p } else { return false } }) {
                    out.segments[i].body = f.body
                } else { out.segments.append(f) }
            case .question(let id):
                if let i = out.segments.lastIndex(where: { if case .question(let q) = $0.kind { return q == id } else { return false } }) {
                    out.segments[i].body = f.body
                }
            default: break
            }
        }
        return out
    }

    /// Copy target: "2" = Task 2, "A1" = question, "Events.tsx" = file. Single-file results come back as clean code only.
    func part(_ keyRaw: String) -> String? {
        let key = keyRaw.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        func sliceText(_ from: Int, until stop: (AcdSegment) -> Bool) -> String? {
            var idx = [from]
            var j = from + 1
            while j < segments.count, !stop(segments[j]) { idx.append(j); j += 1 }
            let parts = idx.map { segments[$0] }
            let nonFile = parts.filter { if case .file = $0.kind { return false } else { return true } }
            let files = parts.filter { if case .file = $0.kind { return true } else { return false } }
            let loose = nonFile.contains { s in s.body.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            if files.count == 1, !loose { return AcdDoc.clean(files[0].body).trimmingCharacters(in: .newlines) }
            let t = AcdDoc(segments: parts).render()
            return t.isEmpty ? nil : t
        }
        if let n = Int(key) {
            guard let i = segments.firstIndex(where: { if case .task(let t) = $0.kind { return t == n } else { return false } }) else { return nil }
            return sliceText(i) { if case .task = $0.kind { return true } else { return false } }
        }
        if AcdDoc.questionRe.firstMatch(in: "// ===== Q \(key.uppercased()) =====", range: NSRange(location: 0, length: ("// ===== Q \(key.uppercased()) =====" as NSString).length)) != nil,
           !key.contains("/") {
            let id = key.uppercased()
            guard let i = segments.firstIndex(where: { if case .question(let q) = $0.kind { return q == id } else { return false } }) else { return nil }
            return sliceText(i) { s in
                switch s.kind { case .task, .question: return true; default: return false } }
        }
        let f = files
        if let p = f.keys.sorted().first(where: { $0 == key || $0.hasSuffix("/" + key) }), let body = f[p] {
            return body.trimmingCharacters(in: .newlines)
        }
        return nil
    }
}

// ---- reading text out of office files without new dependencies ----
enum AcdText {
    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// One block per slide, text runs joined per paragraph.
    static func pptxSlides(_ url: URL) -> [String] {
        let list = benchRun("/usr/bin/unzip", ["-Z1", url.path], timeout: 20)
        guard list.status == 0 else { return [] }
        let names = list.output.components(separatedBy: "\n").filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        var out: [String] = []
        let run = try! NSRegularExpression(pattern: #"<a:t>([^<]*)</a:t>"#)
        for n in names {
            let r = benchRun("/usr/bin/unzip", ["-p", url.path, n], timeout: 20)
            var paras: [String] = []
            for p in r.output.components(separatedBy: "</a:p>") {
                let ns = p as NSString
                let t = run.matches(in: p, range: NSRange(location: 0, length: ns.length)).map { unescapeXML(ns.substring(with: $0.range(at: 1))) }.joined()
                if !t.trimmingCharacters(in: .whitespaces).isEmpty { paras.append(t) }
            }
            if !paras.isEmpty { out.append(paras.joined(separator: "\n")) }
        }
        return out
    }
}

// ---- ACD input: paper + starter project, no Java assumptions ----
struct AcdInput {
    var paper: String            // prompt block: task text + starter files
    var taskOnly: String         // the task/paper text without starter code (for note ranking)
    var starter: [String: String]
    var projectRoot: URL?        // folder holding package.json / index.html (for node_modules reuse)
    var fileCount: Int
    var questionCount: Int

    static let docExt: Set<String> = ["docx", "doc", "rtf", "pdf", "pptx"]
    static let textDocExt: Set<String> = ["md", "txt"]
    static let codeExt: Set<String> = ["html", "htm", "css", "scss", "js", "jsx", "mjs", "cjs", "ts", "tsx", "json"]
    static let skipDirs: Set<String> = ["node_modules", "dist", "build", ".git", ".vite", ".idea", ".vscode", "coverage", "notes", ".next", "out"]
    static let skipFiles: Set<String> = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".DS_Store"]

    static func countQuestions(_ text: String) -> Int {
        var ids = Set<String>()
        let q = try! NSRegularExpression(pattern: #"(?m)^\s*([A-E]\d{1,2})[.):]\s"#)
        let ns = text as NSString
        for m in q.matches(in: text, range: NSRange(location: 0, length: ns.length)) { ids.insert(ns.substring(with: m.range(at: 1))) }
        let t = try! NSRegularExpression(pattern: #"\b(?:Task|Exercise)\s+(\d+)\b"#)
        var tasks = Set<String>()
        for m in t.matches(in: text, range: NSRange(location: 0, length: ns.length)) { tasks.insert(ns.substring(with: m.range(at: 1))) }
        return max(ids.count, tasks.count, 1)
    }

    static func collect(_ dir: URL, extract: (URL) -> String) -> AcdInput {
        let fm = FileManager.default
        var docs = "", code = ""
        var starter: [String: String] = [:]
        var zips: [URL] = []
        var count = 0, total = 0
        var rootCandidates: [URL] = []
        let base = dir.path
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                let vals = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if vals?.isDirectory == true { if skipDirs.contains(f.lastPathComponent) { en.skipDescendants() }; continue }
                if (vals?.fileSize ?? 0) > 150_000 || skipFiles.contains(f.lastPathComponent) || f.lastPathComponent.hasPrefix("~$") { continue }
                let ext = f.pathExtension.lowercased()
                if ext == "zip" { zips.append(f); continue }
                let rel = f.path.hasPrefix(base + "/") ? String(f.path.dropFirst(base.count + 1)) : f.lastPathComponent
                if docExt.contains(ext) {
                    let text = ext == "pptx" ? AcdText.pptxSlides(f).enumerated().map { "--- slide \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n") : extract(f)
                    if !text.isEmpty { docs += "\n===== FILE: \(rel) =====\n" + text; count += 1 }
                } else if textDocExt.contains(ext) && !rel.contains("/src/") && !rel.hasPrefix("src/") {
                    if let t = try? String(contentsOf: f, encoding: .utf8), !t.isEmpty { docs += "\n===== FILE: \(rel) =====\n" + t; count += 1 }
                } else if codeExt.contains(ext) || f.lastPathComponent == ".env.example" {
                    guard let t = try? String(contentsOf: f, encoding: .utf8), !t.isEmpty else { continue }
                    total += t.count
                    if total > 300_000 { code += "\n[... more files skipped: project too large ...]\n"; break }
                    if f.lastPathComponent == "package.json" || f.lastPathComponent == "index.html" { rootCandidates.append(f.deletingLastPathComponent()) }
                    starter[rel] = t; count += 1
                }
            }
        }
        if starter.isEmpty && !zips.isEmpty {   // starter given as a zip: unpack to a resolved temp folder
            for z in zips {
                let tmp = fm.temporaryDirectory.appendingPathComponent("dropacd-" + UUID().uuidString)
                try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let r = benchRun("/usr/bin/ditto", ["-x", "-k", z.path, tmp.path], timeout: 60)
                if r.status == 0 {
                    let sub = collect(tmp, extract: extract)
                    docs += "\n" + (sub.taskOnly.isEmpty ? "" : sub.taskOnly)
                    for (k, v) in sub.starter { starter[k] = v }
                    count += sub.fileCount
                    rootCandidates.append(contentsOf: sub.projectRoot.map { [$0] } ?? [])
                }
            }
        }
        // starter paths relative to the project root (the folder with package.json), so "src/App.tsx" means the same everywhere
        var root: URL? = rootCandidates.sorted { $0.path.count < $1.path.count }.first
        if root == nil, !starter.isEmpty { root = dir }
        var rebased: [String: String] = [:]
        if let r = root, r.path != dir.path, r.path.hasPrefix(base + "/") {
            let prefix = String(r.path.dropFirst(base.count + 1)) + "/"
            for (k, v) in starter { rebased[k.hasPrefix(prefix) ? String(k.dropFirst(prefix.count)) : k] = v }
        } else { rebased = starter }
        for k in rebased.keys.sorted() { code += "\n===== FILE: \(k) =====\n" + rebased[k]! }
        let paperBlock = (docs.isEmpty ? "" : "\n######## TASK / PAPER ########\n" + docs)
            + (code.isEmpty ? "" : "\n######## STARTER PROJECT FILES ########\n" + code)
        return AcdInput(paper: paperBlock, taskOnly: docs, starter: rebased, projectRoot: root, fileCount: count,
                        questionCount: countQuestions(docs))
    }
}

// ---- lecture notes: selected by relevance, always lower priority than the task ----
struct AcdNoteChunk { var source: String; var title: String; var text: String }

enum AcdNotes {
    static var installedDir: URL { ACD_SUPPORT_DIR.appendingPathComponent("notes") }
    static var desktopDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ACD/notes") }

    static func load(dirs: [URL], extract: (URL) -> String) -> [AcdNoteChunk] {
        let fm = FileManager.default
        var out: [AcdNoteChunk] = []
        var seen = Set<String>()
        for d in dirs {
            guard let en = fm.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in en {
                let ext = f.pathExtension.lowercased()
                guard ["md", "txt", "docx", "pdf", "pptx"].contains(ext), seen.insert(f.lastPathComponent + "\(ext)").inserted else { continue }
                var units: [(String, String)] = []   // (title, text)
                if ext == "pptx" {
                    for (i, s) in AcdText.pptxSlides(f).enumerated() { units.append(("slide \(i + 1): " + (s.components(separatedBy: "\n").first ?? ""), s)) }
                } else {
                    let text = (ext == "md" || ext == "txt") ? ((try? String(contentsOf: f, encoding: .utf8)) ?? "") : extract(f)
                    var title = f.deletingPathExtension().lastPathComponent, buf: [String] = []
                    func flush() { if !buf.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { units.append((title, buf.joined(separator: "\n"))) }; buf = [] }
                    for line in text.components(separatedBy: "\n") {
                        if line.hasPrefix("#") { flush(); title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                        buf.append(line)
                    }
                    flush()
                }
                for (title, text) in units {   // keep chunks small so selection can be precise
                    var cur = ""
                    for para in text.components(separatedBy: "\n\n") {
                        if cur.count + para.count > 900, !cur.isEmpty { out.append(AcdNoteChunk(source: f.lastPathComponent, title: title, text: cur)); cur = "" }
                        cur += (cur.isEmpty ? "" : "\n\n") + para
                    }
                    if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(AcdNoteChunk(source: f.lastPathComponent, title: title, text: cur)) }
                }
            }
        }
        return out
    }

    static let stop: Set<String> = ["the", "and", "for", "that", "this", "with", "from", "are", "was", "will", "you", "your", "can", "all", "any", "not",
                                    "use", "using", "each", "which", "when", "write", "following", "should", "must", "marks", "mark", "question", "task", "what"]
    static let tech: Set<String> = ["react", "router", "useparams", "usenavigate", "usestate", "useeffect", "usememo", "usecallback", "context", "zustand",
                                    "tanstack", "query", "bootstrap", "grid", "flex", "flexbox", "typescript", "interface", "jwt", "form", "validation", "fetch",
                                    "axios", "promise", "async", "await", "css", "html", "accessibility", "aria", "responsive", "media", "clamp", "outlet",
                                    "navigate", "protected", "token", "reduce", "optional", "union", "hook", "hooks", "props", "state"]

    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { if cur.count >= 3, !stop.contains(cur) { out.append(cur) }; cur = "" }
        }
        if cur.count >= 3, !stop.contains(cur) { out.append(cur) }
        return out
    }

    /// Top-ranked chunks within `budgetChars`. Convention files (00-*) always come first. Returns what was used.
    static func select(task: String, chunks: [AcdNoteChunk], budgetChars: Int) -> (text: String, used: [String]) {
        if budgetChars < 400 || chunks.isEmpty { return ("", []) }
        let taskTokens = Set(tokens(task))
        var df: [String: Int] = [:]
        let chunkTokens = chunks.map { Set(tokens($0.title + " " + $0.text)) }
        for s in chunkTokens { for t in s { df[t, default: 0] += 1 } }
        let n = Double(chunks.count)
        var scored: [(Double, Int)] = []
        let convFirst = budgetChars >= 4000
        for (i, c) in chunks.enumerated() where !(convFirst && c.source.hasPrefix("00-")) {
            var score = 0.0
            for t in chunkTokens[i] where taskTokens.contains(t) {
                score += log(1 + n / Double(df[t] ?? 1)) + (tech.contains(t) ? 2.0 : 0)
            }
            if score > 0 { scored.append((score, i)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        var text = "", used: [String] = []
        func add(_ c: AcdNoteChunk) -> Bool {
            let piece = "[\(c.source) · \(c.title)]\n\(c.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            if text.count + piece.count > budgetChars { return false }
            text += piece; used.append("\(c.source) · \(c.title)"); return true
        }
        if convFirst { for c in chunks where c.source.hasPrefix("00-") { if text.count < 3500 { _ = add(c) } } }
        for (_, i) in scored { _ = add(chunks[i]) }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), used)
    }
}

enum AcdPrompt {
    /// Notes shrink first: budget = what is left of the context ceiling after header + task, capped at ~3k tokens.
    /// The task text is never cut; if it alone exceeds the ceiling, AppDelegate.generate blocks the run (existing rule).
    static func notesBudget(ceilingTokens: Int, headerAndTaskChars: Int) -> Int {
        let free = (ceilingTokens - 8000) * 3 - headerAndTaskChars - 1500
        return max(0, min(9000, free))
    }
    static func build(notes: String, paper: String) -> String {
        ACD_PROMPT_HEADER + "\n\n"
            + (notes.isEmpty ? "" : "######## REFERENCE NOTES (course material; lower priority than the task) ########\n" + notes + "\n\n")
            + paper
    }
    static func repair(paper: String, files: [String: String], errors: String, affected: Set<String>) -> String {
        var cur = ""
        let omitted = files.keys.filter { !affected.isEmpty && !affected.contains($0) }.sorted()
        for k in files.keys.sorted() where affected.isEmpty || affected.contains(k) { cur += "\n===== FILE: \(k) =====\n" + (files[k] ?? "") }
        if !omitted.isEmpty { cur += "\n(unchanged files not shown: \(omitted.joined(separator: ", ")))\n" }
        return ACD_REPAIR_HEADER + "\n\n######## ORIGINAL TASK REQUIREMENTS ########\n" + paper
            + "\n\n######## CURRENT FILES ########\n" + cur
            + "\n\n######## VALIDATION ERRORS ########\n" + String(errors.prefix(4000))
    }
}

// ---- ACD validation: separate, honestly-labelled checks ------------------------------------
// syntax  = the code parses (node --check / TypeScript syntactic diagnostics / JSON)
// static  = rule-based inspection (HTML structure + accessibility, Bootstrap structure, CSS balance, missing imports)
// build   = tsc --noEmit + vite build on the STARTER project's own config (needs dependencies)
// tests   = the starter project's own test script (needs dependencies and a test script)
// A syntax or static pass is never functional correctness; the summary always says what was not verified.

struct AcdCheck {
    var name: String            // syntax | static | build | tests
    var status: String          // pass | fail | not_run | unavailable
    var detail: String
    var failures: Int
    var warnings: Int
    var ms: Int
}

struct AcdValidation {
    var checks: [AcdCheck]
    var failureCount: Int { checks.reduce(0) { $0 + $1.failures } }
    func check(_ n: String) -> AcdCheck? { checks.first { $0.name == n } }
    var errorText: String {
        checks.filter { $0.status == "fail" }.map { "[\($0.name)]\n" + $0.detail }.joined(separator: "\n\n")
    }
    var summary: String {
        if checks.allSatisfy({ $0.status == "not_run" }) { return "no code files to validate" }
        func mark(_ c: AcdCheck?) -> String {
            guard let c = c else { return "—" }
            switch c.status {
            case "pass": return "✓" + (c.warnings > 0 ? " (\(c.warnings) warning\(c.warnings == 1 ? "" : "s"))" : "")
            case "fail": return "✗ (\(c.failures))"
            case "unavailable": return "n/a"
            default: return "—"
            }
        }
        let s = "Syntax \(mark(check("syntax"))) · Static \(mark(check("static"))) · Build \(mark(check("build"))) · Tests \(mark(check("tests")))"
        let testsPass = check("tests")?.status == "pass"
        return s + (testsPass ? "" : " — behaviour NOT verified (no functional tests ran)")
    }
    var jsonObject: [[String: Any]] {
        checks.map { ["name": $0.name, "status": $0.status, "failures": $0.failures, "warnings": $0.warnings, "ms": $0.ms,
                      "detail": String($0.detail.prefix(1500))] }
    }
}

/// True canonical path (realpath). URL.resolvingSymlinksInPath() turns /private/var into /var, which a sandbox rule would not match.
func acdRealPath(_ u: URL) -> URL {
    guard let c = realpath(u.path, nil) else { return u }
    defer { free(c) }
    return URL(fileURLWithPath: String(cString: c))
}

enum AcdTools {
    static func find(_ name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", home + "/.volta/bin"]
        if let vs = try? fm.contentsOfDirectory(atPath: home + "/.nvm/versions/node") { dirs += vs.sorted().reversed().map { home + "/.nvm/versions/node/\($0)/bin" } }
        for d in dirs where fm.isExecutableFile(atPath: d + "/" + name) { return d + "/" + name }
        return nil
    }
    static var toolchainNM: URL? {
        let u = ACD_SUPPORT_DIR.appendingPathComponent("toolchain/node_modules")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Runs a command with no network and with writes limited to `writable` (sandbox-exec). Output is stdout+stderr.
    static func sandboxed(_ exe: String, _ args: [String], cwd: URL, writable: [String], env: [String: String] = [:],
                          timeout: TimeInterval) -> (status: Int32, output: String, timedOut: Bool) {
        var rules = "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")"
        for w in writable where !w.contains("\"") { rules += " (subpath \"\(w)\")" }
        rules += ")"
        let profile = "(version 1)(allow default)(deny network*)(deny file-write*)" + rules
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, exe] + args
        p.currentDirectoryURL = cwd
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = ((find("node") as NSString?)?.deletingLastPathComponent ?? "/usr/local/bin") + ":/usr/bin:/bin"
        e["CI"] = "1"; e["NO_COLOR"] = "1"; e["FORCE_COLOR"] = "0"
        e["TMPDIR"] = cwd.appendingPathComponent(".tmp").path
        e["npm_config_update_notifier"] = "false"; e["npm_config_cache"] = cwd.appendingPathComponent(".npm").path
        for (k, v) in env { e[k] = v }
        p.environment = e
        try? FileManager.default.createDirectory(at: cwd.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "cannot start: \(error)", false) }
        var timedOut = false
        let wd = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: wd)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); wd.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "", timedOut)
    }
}

enum AcdValidator {
    static let protectedNames = ["package.json", "package-lock.json", "tsconfig", "vite.config", "eslint.config", ".env", "vitest.config"]
    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "!doctype"]
    static let optionalEnd: Set<String> = ["p", "li", "td", "th", "tr", "thead", "tbody", "tfoot", "option", "dt", "dd", "html", "body", "head"]

    static func now() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    // ---------- static: HTML ----------
    static func htmlFindings(_ src: String) -> (errors: [String], warnings: [String]) {
        var errors: [String] = [], warnings: [String] = []
        let tag = try! NSRegularExpression(pattern: #"<(!--[\s\S]*?--|/?([a-zA-Z][a-zA-Z0-9-]*)([^>]*?)(/?))>"#)
        let ns = src as NSString
        var stack: [String] = [], headings: [Int] = []
        var skipUntil: String? = nil
        var inputs = 0, labels = 0, imgNoAlt = 0
        for m in tag.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range)
            if whole.hasPrefix("<!--") { continue }
            let closing = whole.hasPrefix("</")
            let name = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2)).lowercased()
            if let su = skipUntil { if closing && name == su { skipUntil = nil; if stack.last == su { stack.removeLast() } }; continue }
            if name.isEmpty { continue }
            if !closing && (name == "script" || name == "style") && !whole.hasSuffix("/>") { skipUntil = name; stack.append(name); continue }
            if name == "input" { if !whole.lowercased().contains("type=\"hidden\"") && !whole.lowercased().contains("type=\"submit\"") && !whole.lowercased().contains("type=\"button\"") { inputs += 1 } }
            if name == "img" && !closing && !whole.contains("alt=") { imgNoAlt += 1 }
            if name == "label" && !closing { labels += 1 }
            if !closing && whole.contains("aria-label") { labels += 1 }
            if !closing, name.count == 2, name.hasPrefix("h"), let l = Int(name.dropFirst()), (1...6).contains(l) { headings.append(l) }
            if voidTags.contains(name) || whole.hasSuffix("/>") { continue }
            if closing {
                if let i = stack.lastIndex(of: name) {
                    for s in stack[(i + 1)...] where !optionalEnd.contains(s) { errors.append("<\(s)> is not closed before </\(name)>") }
                    stack.removeSubrange(i...)
                } else { errors.append("unexpected closing tag </\(name)>") }
            } else { stack.append(name) }
        }
        for s in stack where !optionalEnd.contains(s) { errors.append("<\(s)> is never closed") }
        let lower = src.lowercased()
        if lower.contains("<html") {
            if !lower.contains("<!doctype html") { warnings.append("missing <!DOCTYPE html>") }
            if !lower.contains("lang=") { warnings.append("<html> has no lang attribute") }
            if !lower.contains("<title") { warnings.append("missing <title>") }
        }
        if imgNoAlt > 0 { warnings.append("\(imgNoAlt) <img> without alt") }
        if inputs > 0 && labels == 0 { warnings.append("form inputs without any <label> or aria-label") }
        var prev = 0
        for h in headings { if prev > 0 && h > prev + 1 { warnings.append("heading level jumps from h\(prev) to h\(h)"); break }; prev = h }
        if lower.contains("data-bs-") && !lower.contains("bootstrap") { warnings.append("data-bs-* attributes used but Bootstrap JS is not loaded") }
        if lower.contains("class=\"col") && !lower.contains("class=\"row") && !lower.contains("class=\"container") { warnings.append("Bootstrap .col used outside a .row/.container") }
        return (errors, warnings)
    }

    // ---------- static: CSS ----------
    static func cssFindings(_ src: String) -> [String] {
        var errors: [String] = []
        var s = src
        while let a = s.range(of: "/*") {
            guard let b = s.range(of: "*/", range: a.upperBound..<s.endIndex) else { errors.append("unterminated /* comment"); s.removeSubrange(a.lowerBound...); break }
            s.removeSubrange(a.lowerBound..<b.upperBound)
        }
        let open = s.filter { $0 == "{" }.count, close = s.filter { $0 == "}" }.count
        if open != close { errors.append("unbalanced braces: \(open) '{' vs \(close) '}'") }
        return errors
    }

    // ---------- static: missing imports in JS/TS/JSX/TSX ----------
    static let importRules: [(names: [String], pkgs: [String])] = [
        (["useState", "useEffect", "useRef", "useMemo", "useCallback", "useContext", "useReducer", "useLayoutEffect"], ["react"]),
        (["useParams", "useNavigate", "useLocation", "useSearchParams", "Outlet", "Link", "NavLink", "Navigate", "createBrowserRouter", "RouterProvider", "BrowserRouter", "Routes", "Route"], ["react-router", "react-router-dom"]),
        (["useQuery", "useMutation", "useQueryClient", "QueryClient", "QueryClientProvider"], ["@tanstack/react-query"]),
    ]
    static func importFindings(_ src: String) -> [String] {
        var out: [String] = []
        for rule in importRules {
            for n in rule.names {
                let used = src.range(of: "\\b\(n)\\s*\\(", options: .regularExpression) != nil || src.range(of: "<\(n)[\\s/>]", options: .regularExpression) != nil
                if !used { continue }
                let imported = src.range(of: "import[^;]*\\b\(n)\\b[^;]*from", options: .regularExpression) != nil
                    || src.range(of: "(const|let|var)\\s*\\{[^}]*\\b\(n)\\b[^}]*\\}", options: .regularExpression) != nil
                let defined = src.range(of: "(function|const|let|var|class)\\s+\(n)\\b", options: .regularExpression) != nil
                let qualified = src.contains("React.\(n)")
                if !imported && !defined && !qualified { out.append("\(n) is used but not imported from \(rule.pkgs[0])") }
            }
        }
        return out
    }

    // ---------- the validator ----------
    /// `files` = the answer's files (path -> code). `starter` = the starter project's files (package.json, configs, src…).
    static func validate(files: [String: String], starter: [String: String], projectRoot: URL?) -> AcdValidation {
        let fm = FileManager.default
        let tmpRaw = fm.temporaryDirectory.appendingPathComponent("dropacd-v-" + UUID().uuidString)
        try? fm.createDirectory(at: tmpRaw, withIntermediateDirectories: true)
        let tmp = acdRealPath(tmpRaw)
        defer { try? fm.removeItem(at: tmp) }
        let hasPkg = starter["package.json"] != nil
        var ignored: [String] = []
        func write(_ rel: String, _ text: String) {
            let u = tmp.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        for (k, v) in starter { write(k, v) }
        for (k, v) in files {
            if hasPkg, protectedNames.contains(where: { (k as NSString).lastPathComponent.hasPrefix($0) }) { ignored.append(k); continue }
            write(k, v)
        }
        let node = AcdTools.find("node")
        let nm: URL? = {
            if let r = projectRoot, fm.fileExists(atPath: r.appendingPathComponent("node_modules").path) { return acdRealPath(r.appendingPathComponent("node_modules")) }
            return AcdTools.toolchainNM.map { acdRealPath($0) }
        }()
        if let nm = nm { try? fm.createSymbolicLink(at: tmp.appendingPathComponent("node_modules"), withDestinationURL: nm) }
        var checks: [AcdCheck] = []
        let paths = files.keys.sorted()

        // ===== syntax =====
        var t0 = now()
        var synErr: [String] = [], synUnavail: [String] = [], synChecked = 0
        let tsPath = nm?.appendingPathComponent("typescript/lib/typescript.js").path
        var tsFiles: [String] = []
        for p in paths {
            let ext = (p as NSString).pathExtension.lowercased()
            let full = tmp.appendingPathComponent(p).path
            if ["js", "mjs", "cjs"].contains(ext) {
                guard let n = node else { synUnavail.append(p + " (node not found)"); continue }
                let r = AcdTools.sandboxed(n, ["--check", full], cwd: tmp, writable: [tmp.path], timeout: 30)
                synChecked += 1
                if r.status != 0 { synErr.append(p + ": " + r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").prefix(6).joined(separator: " | ")) }
            } else if ["ts", "tsx", "jsx"].contains(ext) { tsFiles.append(p) }
            else if ext == "json" {
                synChecked += 1
                if (try? JSONSerialization.jsonObject(with: Data((files[p] ?? "").utf8))) == nil { synErr.append(p + ": invalid JSON") }
            }
        }
        if !tsFiles.isEmpty {
            if let n = node, let ts = tsPath, fm.fileExists(atPath: ts) {
                let script = """
                const ts = require(process.argv[2]); const fs = require('fs'); let bad = 0;
                for (const f of process.argv.slice(3)) {
                  const r = ts.transpileModule(fs.readFileSync(f, 'utf8'), { reportDiagnostics: true, fileName: f,
                    compilerOptions: { jsx: ts.JsxEmit.Preserve, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } });
                  for (const d of (r.diagnostics || [])) {
                    const pos = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : { line: 0, character: 0 };
                    console.log(f + ':' + (pos.line + 1) + ':' + (pos.character + 1) + ' ' + ts.flattenDiagnosticMessageText(d.messageText, ' ')); bad++; } }
                process.exit(bad ? 1 : 0);
                """
                write(".drop-syntax.cjs", script)
                let r = AcdTools.sandboxed(n, [tmp.appendingPathComponent(".drop-syntax.cjs").path, ts] + tsFiles.map { tmp.appendingPathComponent($0).path },
                                           cwd: tmp, writable: [tmp.path], timeout: 60)
                synChecked += tsFiles.count
                if r.status != 0 { synErr += r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(12).map { $0 } }
            } else { synUnavail.append(tsFiles.joined(separator: ", ") + " (TypeScript is not installed: run Prepare ACD toolchain)") }
        }
        if !synErr.isEmpty { checks.append(AcdCheck(name: "syntax", status: "fail", detail: synErr.joined(separator: "\n"), failures: synErr.count, warnings: 0, ms: now() - t0)) }
        else if !synUnavail.isEmpty { checks.append(AcdCheck(name: "syntax", status: "unavailable", detail: "not checked: " + synUnavail.joined(separator: "; ") + (synChecked > 0 ? " · \(synChecked) other file(s) parsed fine" : ""), failures: 0, warnings: 0, ms: now() - t0)) }
        else if synChecked == 0 { checks.append(AcdCheck(name: "syntax", status: "not_run", detail: "no JS/TS/JSON files in the answer", failures: 0, warnings: 0, ms: 0)) }
        else { checks.append(AcdCheck(name: "syntax", status: "pass", detail: "\(synChecked) file(s) parse without syntax errors", failures: 0, warnings: 0, ms: now() - t0)) }

        // ===== static =====
        t0 = now()
        var stErr: [String] = [], stWarn: [String] = [], stChecked = 0
        for p in paths {
            let ext = (p as NSString).pathExtension.lowercased()
            let text = files[p] ?? ""
            if ["html", "htm"].contains(ext) { stChecked += 1; let f = htmlFindings(text); stErr += f.errors.map { "\(p): \($0)" }; stWarn += f.warnings.map { "\(p): \($0)" } }
            else if ["css", "scss"].contains(ext) { stChecked += 1; stErr += cssFindings(text).map { "\(p): \($0)" } }
            else if ["js", "jsx", "ts", "tsx", "mjs"].contains(ext) { stChecked += 1; stErr += importFindings(text).map { "\(p): \($0)" } }
        }
        let stDetail = (stErr + stWarn.map { "warning: " + $0 }).joined(separator: "\n") + (ignored.isEmpty ? "" : "\nnote: ignored \(ignored.joined(separator: ", ")) (build configuration comes from the starter project)")
        if !stErr.isEmpty { checks.append(AcdCheck(name: "static", status: "fail", detail: stDetail, failures: stErr.count, warnings: stWarn.count, ms: now() - t0)) }
        else if stChecked == 0 { checks.append(AcdCheck(name: "static", status: "not_run", detail: "no HTML/CSS/JS/TS files to inspect", failures: 0, warnings: 0, ms: 0)) }
        else { checks.append(AcdCheck(name: "static", status: "pass", detail: stDetail.isEmpty ? "\(stChecked) file(s) inspected, no findings" : stDetail, failures: 0, warnings: stWarn.count, ms: now() - t0)) }

        // ===== build (starter project's own configuration) =====
        t0 = now()
        let writable = [tmp.path] + (nm.map { n in [".vite", ".vite-temp", ".cache", ".tmp"].map { n.appendingPathComponent($0).path } } ?? [])
        if !hasPkg {
            checks.append(AcdCheck(name: "build", status: "not_run", detail: "no starter project (package.json) to build against", failures: 0, warnings: 0, ms: 0))
        } else if node == nil || nm == nil || tsPath.map({ !fm.fileExists(atPath: $0) }) ?? true {
            checks.append(AcdCheck(name: "build", status: "unavailable", detail: "dependencies not installed for this project (use Prepare ACD toolchain, or install them in the starter folder)", failures: 0, warnings: 0, ms: 0))
        } else {
            var log = "", failed = false
            let tsc = nm!.appendingPathComponent("typescript/bin/tsc").path
            let cfg = starter["tsconfig.app.json"] != nil ? "tsconfig.app.json" : (starter["tsconfig.json"] != nil ? "tsconfig.json" : nil)
            if let cfg = cfg {
                let r = AcdTools.sandboxed(node!, [tsc, "-p", cfg, "--noEmit"], cwd: tmp, writable: writable, timeout: 180)
                if r.status != 0 { failed = true; log += "tsc (\(cfg)):\n" + r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").prefix(40).joined(separator: "\n") + "\n" }
            }
            let vite = nm!.appendingPathComponent("vite/bin/vite.js").path
            if !failed, fm.fileExists(atPath: vite), starter["index.html"] != nil {
                let r = AcdTools.sandboxed(node!, [vite, "build", "--outDir", tmp.appendingPathComponent(".out").path, "--emptyOutDir"], cwd: tmp, writable: writable, timeout: 240)
                if r.status != 0 { failed = true; log += "vite build:\n" + r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").prefix(40).joined(separator: "\n") + "\n" }
            }
            if cfg == nil && !fm.fileExists(atPath: vite) { checks.append(AcdCheck(name: "build", status: "not_run", detail: "the starter has neither a tsconfig nor Vite", failures: 0, warnings: 0, ms: 0)) }
            else { checks.append(AcdCheck(name: "build", status: failed ? "fail" : "pass", detail: failed ? log : "type-check and bundle succeeded on the starter's configuration", failures: failed ? 1 : 0, warnings: 0, ms: now() - t0)) }
        }

        // ===== tests (the starter's own test script) =====
        t0 = now()
        if let pj = starter["package.json"], let d = try? JSONSerialization.jsonObject(with: Data(pj.utf8)) as? [String: Any],
           let sc = d["scripts"] as? [String: Any], sc["test"] != nil {
            if let npm = AcdTools.find("npm"), nm != nil {
                let r = AcdTools.sandboxed(npm, ["test", "--silent"], cwd: tmp, writable: writable, timeout: 240)
                let out = r.output.replacingOccurrences(of: tmp.path + "/", with: "").components(separatedBy: "\n").suffix(40).joined(separator: "\n")
                checks.append(AcdCheck(name: "tests", status: r.timedOut ? "fail" : (r.status == 0 ? "pass" : "fail"), detail: r.timedOut ? "timed out" : out,
                                       failures: r.status == 0 && !r.timedOut ? 0 : 1, warnings: 0, ms: now() - t0))
            } else { checks.append(AcdCheck(name: "tests", status: "unavailable", detail: "npm or project dependencies not available", failures: 0, warnings: 0, ms: 0)) }
        } else {
            checks.append(AcdCheck(name: "tests", status: "not_run", detail: "the starter project defines no test script", failures: 0, warnings: 0, ms: 0))
        }
        return AcdValidation(checks: checks)
    }
}

// ---- the ACD pipeline: generate → validate → bounded, requirement-preserving repair ----
// ---- ACD v2: plan the paper into questions, one small request each ------------------------------------
// Measured on a 4B model with an 8 GB Mac: one whole-paper request with thinking spends its whole token budget
// thinking (empty answer) and grows memory past RAM. One question per request, no thinking, small contexts,
// and unloading when the model grows is faster and more accurate. "Careful mode" turns thinking on for free-form questions.

enum AcdSettings {
    static var careful: Bool { UserDefaults.standard.bool(forKey: "acdCareful") }
    static func setCareful(_ on: Bool) { UserDefaults.standard.set(on, forKey: "acdCareful") }
    /// OOP per-task generation for the visible popup run. OFF by default: on a 8 GB Mac with a 4B model it was measured SLOWER than the single request.
    static var oopPerTask: Bool { UserDefaults.standard.bool(forKey: "oopPerTask") }
    static func setOopPerTask(_ on: Bool) { UserDefaults.standard.set(on, forKey: "oopPerTask") }
}

struct AcdUnit {
    enum Kind { case mcq, tf, free }
    var id: String
    var task: Int
    var kind: Kind
    var text: String
    var marks: Int
    var isObjective: Bool { kind != .free }
}

struct AcdPlan {
    var preamble: String          // exam instructions before the first question
    var units: [AcdUnit]

    static func make(_ text: String) -> AcdPlan {
        let sectionRe = try! NSRegularExpression(pattern: #"^\s*Section\s+([A-Z])\b(.*)$"#)
        let unitRe = try! NSRegularExpression(pattern: #"^\s*([A-Z]{1,2}\d{1,3})[.)]\s"#)
        let taskRe = try! NSRegularExpression(pattern: #"^\s*(?:Task|Exercise|Question)\s+(\d{1,2})\b"#)
        func first(_ re: NSRegularExpression, _ s: String, _ g: Int = 1) -> String? {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > g, m.range(at: g).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: g))
        }
        var pre: [String] = [], raw: [(id: String, sec: String, tfSection: Bool, lines: [String])] = []
        var sec = "", tfSection = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("===== FILE:") && raw.isEmpty { continue }              // file wrapper lines of the extractor
            if let s = first(sectionRe, line) { sec = s; tfSection = line.lowercased().contains("true") && line.lowercased().contains("false"); if !raw.isEmpty { raw[raw.count - 1].lines.append("") }; continue }
            if let id = first(unitRe, line) { raw.append((id, sec, tfSection, [line])); continue }
            if raw.isEmpty { pre.append(line) } else if !line.hasPrefix("END OF") { raw[raw.count - 1].lines.append(line) }
        }
        var units: [AcdUnit] = []
        func marks(_ s: String) -> Int {
            let re = try! NSRegularExpression(pattern: #"\((\d+)\s*marks?\)"#, options: .caseInsensitive)
            return first(re, s).flatMap { Int($0) } ?? 0
        }
        if raw.count >= 2 {
            for r in raw {
                let t = r.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let hasOptions = t.range(of: #"(?s)(^|\s)\(?A[.)]\s.+\s\(?B[.)]\s"#, options: .regularExpression) != nil
                let tf = !hasOptions && (r.tfSection || t.lowercased().contains("true or false") || t.lowercased().contains("true/false"))
                let kind: AcdUnit.Kind = hasOptions ? .mcq : (tf ? .tf : .free)
                let letter = r.id.first!.asciiValue.map { Int($0) - 64 } ?? 1
                units.append(AcdUnit(id: r.id.uppercased(), task: letter, kind: kind, text: t, marks: marks(t)))
            }
            return AcdPlan(preamble: String(pre.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(900)), units: units)
        }
        // no lettered questions: split by "Task N" / "Exercise N" / "Question N"
        var tasks: [(n: Int, lines: [String])] = []
        pre = []
        for line in text.components(separatedBy: "\n") {
            if let n = first(taskRe, line).flatMap({ Int($0) }) { tasks.append((n, [line])); continue }
            if tasks.isEmpty { pre.append(line) } else { tasks[tasks.count - 1].lines.append(line) }
        }
        if tasks.count >= 2 {
            for t in tasks {
                let body = t.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                units.append(AcdUnit(id: "T\(t.n)", task: t.n, kind: .free, text: body, marks: marks(body)))
            }
            return AcdPlan(preamble: String(pre.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(900)), units: units)
        }
        return AcdPlan(preamble: "", units: [])
    }
}

extension AcdObjective {
    /// Reads a one-question reply: tolerates "B", "B.", "(b) reduce()", "A1: B", "Answer: B" and True/False variants.
    static func fromReply(_ reply: String, id: String, tf: Bool) -> String? {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "^\\W*" + NSRegularExpression.escapedPattern(for: id) + "\\W+", options: [.regularExpression, .caseInsensitive]) { t = String(t[r.upperBound...]) }
        if let r = t.range(of: #"^\W*(answer|correct answer)\s*[:\-]?\s*"#, options: [.regularExpression, .caseInsensitive]) { t = String(t[r.upperBound...]) }
        guard let v = normalise(t) else { return nil }
        if tf { return v == "True" || v == "False" ? v : nil }
        return ["A", "B", "C", "D"].contains(v) ? v : nil
    }
}

struct AcdRequest {
    var prompt: String
    var label: String
    var kind: String            // objective | free | whole | repair
    var numPredict: Int
    var temperature: Double
    var think: Bool
}

extension AcdPrompt {
    static let module = "You are answering a question of a university exam for the module Advanced Client-Side Development (HTML5, CSS3, Bootstrap, JavaScript, TypeScript, React, React Router, TanStack Query, Zustand, JWT and front-end security). All code is client-side."

    static func objective(_ u: AcdUnit, strict: Bool = false) -> String {
        let reply = u.kind == .tf ? "True or False" : "the letter of the correct option (A, B, C or D)"
        let only = u.kind == .tf ? "a single word: True or False." : "a single letter: A, B, C or D."
        return module + "\nReply with ONLY " + reply + ". No explanation, no other words." + (strict ? "\nYour whole reply must be " + only : "") + "\n\nQUESTION\n" + u.text + "\n"
    }

    static func free(_ u: AcdUnit, preamble: String, notes: String, starter: String) -> String {
        var p = module + "\nWrite exactly what the question asks for and nothing else:\n"
            + "- Code: complete, correct code in a fenced block (```tsx, ```ts or ```js). Use the language the question or the exam instructions name, otherwise TypeScript. Import everything you use.\n"
            + "- Explanations: short, plain sentences with one clear point per mark shown.\n"
            + "- Answer every part (a, b, c, ...) using the question's own labels. Do not repeat the question. No introduction or summary.\n"
            + "- Satisfy every requirement exactly as stated (structure, names, routes, layout, behaviour). Do not omit, move or rename anything the question lists.\n"
            + "- Use the exact names the question gives: route paths and parameter names (a route /students/:studentId is read as studentId), endpoints (write /api/events, never invent a host), components, props and files.\n"
            + "- Use only the libraries the question or the exam instructions name (for example no Zustand in a data-fetching question). A custom hook you write must be called by the component you show. Never declare a type that you also import.\n"
            + "- If the question says pages share a layout, every listed page is a child route of that layout. In TypeScript a catch variable is `unknown`: narrow it with `instanceof Error` before reading .message. In React effects that use an AbortController, never set state after the request was aborted.\n"
        if !starter.isEmpty {
            p += "- The starter project files are shown below. When the question asks you to create or change a file, give the COMPLETE file under its own header line `// ===== FILE: src/path/File.tsx =====` (no fences around it), keeping all existing imports and structure.\n"
        }
        if u.marks > 0 { p += "- This question is worth \(u.marks) marks.\n" }
        if !preamble.isEmpty { p += "\nEXAM INSTRUCTIONS\n" + preamble + "\n" }
        if !notes.isEmpty { p += "\nREFERENCE NOTES (course material; the question wins if they disagree)\n" + notes + "\n" }
        if !starter.isEmpty { p += "\nSTARTER PROJECT FILES\n" + starter + "\n" }
        return p + "\nQUESTION\n" + u.text + "\n"
    }
}

// ---- ACD deterministic fixers (ACD answers only; OOP's fixers are separate and untouched) -------------------
// A 4B model writes sound code but slips on exact names and strict-TypeScript details. These rules repair five
// recurring slips in free-form answers WITHOUT another model call. Each rule changes nothing unless its exact pattern is present.
// Caveat (stated in the benchmark report too): they target patterns seen in practice papers, so scores describe model + fixers.
enum AcdFixers {
    static func apply(_ text: String, question: String) -> String {
        var t = text
        t = fixInventedHosts(t, question: question)
        t = alignRouteParamsToQuestion(t, question: question)
        t = fixRouteParamNames(t)
        t = fixUnknownCatch(t)
        t = fixStateAfterAbort(t)
        t = fixLayoutRoutes(t, question: question)
        t = fixDuplicateTypeImports(t)
        t = fixMissingImports(t)
        return t
    }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static func matches(_ r: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] { r.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }

    /// "https://made-up.example/api/events" -> "/api/events" when the question names the path but not that host.
    static func fixInventedHosts(_ t: String, question: String) -> String {
        var out = t
        let r = re(#"https?://([A-Za-z0-9.-]+)(/api/[A-Za-z0-9/_\-.{}$]*)"#)
        for m in matches(r, t).reversed() {
            let ns = out as NSString
            let host = ns.substring(with: m.range(at: 1)), path = ns.substring(with: m.range(at: 2))
            if !question.contains(host) && question.contains(path) { out = ns.replacingCharacters(in: m.range, with: path) }
        }
        return out
    }

    /// The question names the route parameter (/students/:studentId) but the answer used another (:id): use the question's name in the route (the next rule renames its uses).
    static func alignRouteParamsToQuestion(_ t: String, question: String) -> String {
        var qp = Set<String>()
        for m in matches(re(#"/\w[\w\-/]*/:(\w+)"#), question) { qp.insert((question as NSString).substring(with: m.range(at: 1))) }
        var ap = Set<String>()
        for m in matches(re(#"path\s*=\s*[{"'`]([^"'`}]*)"#), t) {
            let value = (t as NSString).substring(with: m.range(at: 1))
            for pm in matches(re(#":(\w+)"#), value) { ap.insert((value as NSString).substring(with: pm.range(at: 1))) }
        }
        guard qp.count == 1, ap.count == 1, let q = qp.first, let a = ap.first, q != a else { return t }
        var out = t
        for m in matches(re(#"path\s*=\s*[{"'`][^"'`}]*"#), t).reversed() {
            let ns = out as NSString
            let piece = ns.substring(with: m.range)
            let fixed = re(":" + NSRegularExpression.escapedPattern(for: a) + "\\b").stringByReplacingMatches(in: piece, range: NSRange(location: 0, length: (piece as NSString).length), withTemplate: ":" + q)
            if fixed != piece { out = ns.replacingCharacters(in: m.range, with: fixed) }
        }
        return out
    }

    /// A route "/students/:studentId" read as `const { id } = useParams()` -> `{ studentId }` (only when the answer has exactly one route parameter).
    static func fixRouteParamNames(_ t: String) -> String {
        var params = Set<String>()
        for m in matches(re(#"path\s*=\s*[{"'`]([^"'`}]*)"#), t) {
            let value = (t as NSString).substring(with: m.range(at: 1))
            for pm in matches(re(#":(\w+)"#), value) { params.insert((value as NSString).substring(with: pm.range(at: 1))) }
        }
        guard params.count == 1, let p = params.first else { return t }
        // every `const { x } = useParams()` (code and the explanation's snippets) follows the route's parameter name
        var out = t
        for m in matches(re(#"const\s*\{\s*(\w+)\s*\}\s*=\s*useParams(?:<[^>]*>)?\(\)"#), t).reversed() {
            let ns = out as NSString
            let x = ns.substring(with: m.range(at: 1))
            if x == p { continue }
            let head = ns.substring(to: m.range.location)
            let tail = ns.substring(from: m.range.location)
            // rename the variable from its declaration to the end of its function (next closing brace at column 0)
            var scope = tail, rest = ""
            if let end = tail.range(of: "\n}") { scope = String(tail[..<end.upperBound]); rest = String(tail[end.upperBound...]) }
            let ident = re("(?<![.\\w\"'`])" + NSRegularExpression.escapedPattern(for: x) + "(?![\\w:\"'`])")
            scope = ident.stringByReplacingMatches(in: scope, range: NSRange(location: 0, length: (scope as NSString).length), withTemplate: p)
            out = head + scope + rest
        }
        return out
    }

    /// `catch (err) { ... err.name ... }`: err is `unknown` under strict TypeScript, so cast before reading name/message.
    static func fixUnknownCatch(_ t: String) -> String {
        var out = t
        for m in matches(re(#"catch\s*\((\w+)\)\s*\{"#), t).reversed() {
            let ns = out as NSString
            let name = ns.substring(with: m.range(at: 1))
            var depth = 1, i = m.range.location + m.range.length
            while i < ns.length, depth > 0 { let c = ns.character(at: i); if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1 }; i += 1 }
            let blockRange = NSRange(location: m.range.location + m.range.length, length: max(0, i - 1 - (m.range.location + m.range.length)))
            var block = ns.substring(with: blockRange)
            if block.contains("\(name): Error") { continue }
            let use = re("(?<![.\\w])(?<!instanceof Error \\? )(?<!instanceof Error && )" + NSRegularExpression.escapedPattern(for: name) + "\\.(name|message)\\b")
            let fixed = use.stringByReplacingMatches(in: block, range: NSRange(location: 0, length: (block as NSString).length), withTemplate: "(\(name) as Error).$1")
            if fixed != block { block = fixed; out = ns.replacingCharacters(in: blockRange, with: block) }
        }
        return out
    }

    /// `finally { setLoading(false); }` next to an AbortController updates state after an abort/unmount: guard it.
    static func fixStateAfterAbort(_ t: String) -> String {
        guard t.contains("new AbortController()") else { return t }
        let nameRe = re(#"(?:(?:const|let|var)\s+(\w+)\s*(?::[^=;]+)?=\s*new AbortController\(\)|(\w+)\s*=\s*new AbortController\(\))"#)
        guard let nm = matches(nameRe, t).first else { return t }
        let ns = t as NSString
        let name = nm.range(at: 1).location != NSNotFound ? ns.substring(with: nm.range(at: 1)) : ns.substring(with: nm.range(at: 2))
        let fin = re(#"finally\s*\{\s*(set\w+\([^;{}]*\));?\s*\}"#)
        var out = t
        for m in matches(fin, t).reversed() {
            let o = out as NSString
            let whole = o.substring(with: m.range)
            if whole.contains("aborted") { continue }
            let stmt = o.substring(with: m.range(at: 1))
            out = o.replacingCharacters(in: m.range, with: "finally {\n        if (!\(name)?.signal.aborted) {\n          \(stmt);\n        }\n      }")
        }
        return out
    }


    // ---- imports inside fenced code blocks ----
    /// Names used but not imported (React hooks, React Router, TanStack Query) get added to the block's import line, or a new import line.
    static func fixMissingImports(_ t: String) -> String {
        let fence = re("(```[a-zA-Z]*\\n)([\\s\\S]*?)(```)")
        var out = t
        for m in matches(fence, t).reversed() {
            let ns = out as NSString
            var code = ns.substring(with: m.range(at: 2))
            var changed = false
            for rule in AcdValidator.importRules {
                var missing: [String] = []
                for n in rule.names {
                    let used = code.range(of: "\\b\(n)\\s*\\(", options: .regularExpression) != nil || code.range(of: "<\(n)[\\s/>]", options: .regularExpression) != nil
                    if !used { continue }
                    let imported = code.range(of: "import[^;]*\\b\(n)\\b[^;]*from", options: .regularExpression) != nil
                        || code.range(of: "(const|let|var)\\s*\\{[^}]*\\b\(n)\\b[^}]*\\}", options: .regularExpression) != nil
                    let defined = code.range(of: "(function|const|let|var|class)\\s+\(n)\\b", options: .regularExpression) != nil
                    if !imported && !defined && !code.contains("React.\(n)") { missing.append(n) }
                }
                if missing.isEmpty { continue }
                // prefer a package this block already imports from
                let pkg = rule.pkgs.first(where: { code.contains("from '\($0)'") || code.contains("from \"\($0)\"") }) ?? rule.pkgs.last ?? rule.pkgs[0]
                let existing = re("import\\s*\\{([^}]*)\\}\\s*from\\s*(['\"])" + NSRegularExpression.escapedPattern(for: pkg) + "\\2")
                if let em = matches(existing, code).first {
                    let cns = code as NSString
                    let have = cns.substring(with: em.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let quote = cns.substring(with: em.range(at: 2))
                    code = cns.replacingCharacters(in: em.range, with: "import { \(([have] + missing).joined(separator: ", ")) } from \(quote)\(pkg)\(quote)")
                } else {
                    code = "import { \(missing.joined(separator: ", ")) } from '\(pkg)';\n" + code
                }
                changed = true
            }
            if changed { out = ns.replacingCharacters(in: m.range(at: 2), with: code) }
        }
        return out
    }

    /// `import type { A } from '../types/x'` next to a local `interface A {…}`: the import points at a module that does not exist and clashes with the declaration.
    static func fixDuplicateTypeImports(_ t: String) -> String {
        let fence = re("(```[a-zA-Z]*\\n)([\\s\\S]*?)(```)")
        var out = t
        for m in matches(fence, t).reversed() {
            let ns = out as NSString
            var code = ns.substring(with: m.range(at: 2))
            let imp = re(#"import\s+(?:type\s+)?\{([^}]*)\}\s*from\s*['"](\.{1,2}/[^'"]*)['"];?[ \t]*\n?"#)
            for im in matches(imp, code).reversed() {
                let cns = code as NSString
                let names = cns.substring(with: im.range(at: 1)).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let local = names.filter { code.range(of: "\\b(interface|type|class|enum)\\s+\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }
                if local.isEmpty { continue }
                let rest = names.filter { !local.contains($0) }
                let whole = cns.substring(with: im.range)
                let module = cns.substring(with: im.range(at: 2))
                code = cns.replacingCharacters(in: im.range, with: rest.isEmpty ? "" : whole.replacingOccurrences(of: cns.substring(with: im.range(at: 1)), with: " " + rest.joined(separator: ", ") + " ").replacingOccurrences(of: module, with: module))
            }
            if code != ns.substring(with: m.range(at: 2)) { out = ns.replacingCharacters(in: m.range(at: 2), with: code) }
        }
        return out
    }

    /// A top-level `<Route path="/settings" .../>` placed after the shared layout route although the question lists that page: move it inside the layout.
    static func fixLayoutRoutes(_ t: String, question: String) -> String {
        guard question.lowercased().contains("layout") else { return t }
        let ns = t as NSString
        struct Tag { var range: NSRange; var kind: Int; var path: String }     // kind: 0 open, 1 self-closing, 2 close
        var tags: [Tag] = []
        for m in matches(re(#"<Route\b|</Route>"#), t) {
            if ns.substring(with: m.range) == "</Route>" { tags.append(Tag(range: m.range, kind: 2, path: "")); continue }
            var i = m.range.location + m.range.length, braces = 0
            while i < ns.length {                                    // the tag ends at the first '>' outside {...}
                let c = ns.character(at: i)
                if c == 0x7B { braces += 1 } else if c == 0x7D { braces -= 1 } else if c == 0x3E && braces == 0 { break }
                i += 1
            }
            guard i < ns.length else { return t }
            let r = NSRange(location: m.range.location, length: i + 1 - m.range.location)
            let text = ns.substring(with: r)
            var path = ""
            if let pm = matches(re(#"path\s*=\s*"([^"]*)""#), text).first { path = (text as NSString).substring(with: pm.range(at: 1)) }
            tags.append(Tag(range: r, kind: text.hasSuffix("/>") ? 1 : 0, path: path))
        }
        guard let li = tags.firstIndex(where: { $0.kind == 0 && $0.path == "/" }) else { return t }
        let layoutElement: String = {
            let txt = ns.substring(with: tags[li].range)
            if let m = matches(re(#"element\s*=\s*\{\s*(<\w+\s*/>)\s*\}"#), txt).first { return (txt as NSString).substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "") }
            return ""
        }()
        var depth = 1, ci: Int?
        for k in (li + 1)..<tags.count {
            if tags[k].kind == 0 { depth += 1 } else if tags[k].kind == 2 { depth -= 1; if depth == 0 { ci = k; break } }
        }
        guard let closeIdx = ci else { return t }
        var removals: [NSRange] = [], moved: [String] = []
        // second route that wraps the SAME layout around a listed page (with one `index` child): that page becomes a child of the first layout
        if !layoutElement.isEmpty {
            var k = closeIdx + 1
            while k < tags.count {
                let tg = tags[k]
                if tg.kind == 0, tg.path.hasPrefix("/"), tg.path != "/", question.contains(tg.path) {
                    let openTxt = ns.substring(with: tg.range).replacingOccurrences(of: " ", with: "")
                    var d = 1, j = k + 1, closeJ: Int?
                    while j < tags.count { if tags[j].kind == 0 { d += 1 } else if tags[j].kind == 2 { d -= 1; if d == 0 { closeJ = j; break } }; j += 1 }
                    if openTxt.contains("element={" + layoutElement + "}"), let cj = closeJ {
                        let inner = ns.substring(with: NSRange(location: tg.range.location + tg.range.length, length: tags[cj].range.location - (tg.range.location + tg.range.length)))
                        if let im = matches(re(#"<Route\s+index\s+element\s*=\s*(\{(?:[^{}]|\{[^{}]*\})*\})\s*/>"#), inner).first {
                            let element = (inner as NSString).substring(with: im.range(at: 1))
                            var start = tg.range.location
                            while start > 0, ns.character(at: start - 1) == 0x20 || ns.character(at: start - 1) == 0x09 { start -= 1 }
                            let end = tags[cj].range.location + tags[cj].range.length
                            removals.append(NSRange(location: start, length: end - start))
                            moved.append("<Route path=\"\(tg.path)\" element=\(element) />")
                        }
                    }
                    k = (closeJ ?? k) + 1
                    continue
                }
                k += 1
            }
        }
        for k in (closeIdx + 1)..<tags.count where tags[k].kind == 1 && tags[k].path.hasPrefix("/") && tags[k].path != "/*" && question.contains(tags[k].path) {
            var start = tags[k].range.location
            // swallow the route's own line (indentation) and a comment line directly above it
            while start > 0, ns.character(at: start - 1) == 0x20 || ns.character(at: start - 1) == 0x09 { start -= 1 }
            var r = NSRange(location: start, length: tags[k].range.location + tags[k].range.length - start)
            let before = ns.substring(to: start)
            if let cm = matches(re(#"\n[ \t]*\{/\*[^*]*\*/\}[ \t]*\n$"#), before).first, before.range(of: "outside", options: .caseInsensitive, range: before.index(before.startIndex, offsetBy: cm.range.location)..<before.endIndex) != nil {
                r = NSRange(location: cm.range.location + 1, length: r.location + r.length - (cm.range.location + 1))
            }
            removals.append(r)
            moved.append(ns.substring(with: tags[k].range))
        }
        if moved.isEmpty { return t }
        var out = t as NSString
        for r in removals.reversed() { out = out.replacingCharacters(in: r, with: "") as NSString }
        // insert before the layout's closing tag (its location is unaffected: removals are all after it)
        let close = tags[closeIdx].range
        var lineStart = close.location
        while lineStart > 0, out.character(at: lineStart - 1) == 0x20 || out.character(at: lineStart - 1) == 0x09 { lineStart -= 1 }
        let indent = out.substring(with: NSRange(location: lineStart, length: close.location - lineStart)) + "  "
        let insertion = moved.map { indent + $0 + "\n" }.joined()
        return out.replacingCharacters(in: NSRange(location: lineStart, length: 0), with: insertion) as String
    }
}

struct AcdHooks {
    var generate: (_ request: AcdRequest) async -> String?
    var validate: (_ files: [String: String]) async -> AcdValidation
    var status: (_ s: String) -> Void
    var resetOutput: () -> Void
}

struct AcdRunInput {
    var taskText: String                 // the task / paper text, no starter code
    var paperBlock: String               // task + starter files as one prompt block (whole mode and repair fallback)
    var starter: [String: String]
    var chunks: [AcdNoteChunk]
    var careful: Bool
    var ceilingTokens: Int
    var questionCount: Int
}

struct AcdResult {
    var answer: String
    var validation: AcdValidation
    var repairRounds: Int
    var generationMs: Int
    var validationMs: Int
    var repairNote: String      // why repair stopped / whether the best earlier answer was kept
    var mode: String = "units"  // units | whole
    var unitCount: Int = 0
    var unanswered: [String] = []
    var notesUsed: [String] = []
    var unitMs: [String: Int] = [:]
}

enum AcdPipeline {
    static let maxRepairs = 3

    static func starterBlock(_ starter: [String: String], limit: Int = 7000) -> String {
        var out = "", omitted: [String] = []
        for k in starter.keys.sorted() {
            let piece = "===== FILE: \(k) =====\n" + (starter[k] ?? "") + "\n"
            if out.count + piece.count > limit { omitted.append(k); continue }
            out += piece
        }
        return out + (omitted.isEmpty ? "" : "(not shown: \(omitted.joined(separator: ", ")))\n")
    }

    @MainActor
    static func run(input: AcdRunInput, hooks: AcdHooks) async -> AcdResult? {
        func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
        var genMs = 0, valMs = 0
        let plan = AcdPlan.make(input.taskText)
        var answerText = ""
        var owners: [String: String] = [:]          // file path -> question id that produced it
        var unanswered: [String] = [], notesUsed: [String] = [], unitMs: [String: Int] = [:]
        let mode = plan.units.count >= 2 ? "units" : "whole"
        let starterText = starterBlock(input.starter)
        if mode == "units" {
            var texts: [String: String] = [:]
            for (i, u) in plan.units.enumerated() {
                hooks.status("⏳ ACD · \(i + 1)/\(plan.units.count) · \(u.id)")
                hooks.resetOutput()
                let t0 = nowMs()
                var reply: String?
                if u.isObjective {
                    reply = await hooks.generate(AcdRequest(prompt: AcdPrompt.objective(u), label: "\(u.id)", kind: "objective", numPredict: 24, temperature: 0, think: false))
                    var v = reply.flatMap { AcdObjective.fromReply($0, id: u.id, tf: u.kind == .tf) }
                    if v == nil {   // one stricter retry for an unreadable reply
                        let r2 = await hooks.generate(AcdRequest(prompt: AcdPrompt.objective(u, strict: true), label: "\(u.id) retry", kind: "objective", numPredict: 16, temperature: 0, think: false))
                        v = r2.flatMap { AcdObjective.fromReply($0, id: u.id, tf: u.kind == .tf) }
                    }
                    if let v = v { texts[u.id] = v } else { unanswered.append(u.id) }
                } else {
                    let base = min(3000, 500 + 180 * max(u.marks, 3))
                    let budget = AcdPrompt.notesBudget(ceilingTokens: input.ceilingTokens, headerAndTaskChars: u.text.count + starterText.count + 1800 + base * 3) / 6   // small, targeted
                    let notes = AcdNotes.select(task: u.text, chunks: input.chunks, budgetChars: min(1500, budget))
                    notesUsed += notes.used
                    let prompt = AcdPrompt.free(u, preamble: plan.preamble, notes: notes.text, starter: starterText)
                    reply = await hooks.generate(AcdRequest(prompt: prompt, label: u.id, kind: "free", numPredict: input.careful ? min(6000, base * 2 + 1500) : base,
                                                            temperature: 0.2, think: input.careful))
                    if (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && input.careful {   // thinking ate the budget: answer without it
                        reply = await hooks.generate(AcdRequest(prompt: prompt, label: "\(u.id) (no thinking)", kind: "free", numPredict: base, temperature: 0.2, think: false))
                    }
                    if let r0 = reply, !r0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let r = AcdFixers.apply(r0, question: u.text)     // deterministic slips: names, hosts, strict-TS catch, abort, layout
                        texts[u.id] = r
                        for p in AcdDoc.parse(r).files.keys { owners[p] = u.id }
                    } else { unanswered.append(u.id) }
                }
                unitMs[u.id] = nowMs() - t0
                genMs += nowMs() - t0
            }
            if texts.isEmpty { return nil }
            var out: [String] = [], lastTask = -1
            for u in plan.units {
                guard let t = texts[u.id] else { continue }
                if u.task != lastTask { out.append("// ===== Task \(u.task) ====="); lastTask = u.task }
                out.append("// ===== Q \(u.id) =====\n" + t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            answerText = out.joined(separator: "\n")
        } else {
            // no recognisable questions: one request for the whole task (small notes, no thinking unless Careful mode)
            hooks.status("⏳ ACD · writing the answer…")
            let sizing = min(6000, max(2500, 1200 + 400 * input.questionCount))
            let budget = AcdPrompt.notesBudget(ceilingTokens: input.ceilingTokens, headerAndTaskChars: ACD_PROMPT_HEADER.count + input.paperBlock.count + sizing * 3)
            let notes = AcdNotes.select(task: input.taskText, chunks: input.chunks, budgetChars: min(budget, 4500))
            notesUsed = notes.used
            let t0 = nowMs()
            guard let first = await hooks.generate(AcdRequest(prompt: AcdPrompt.build(notes: notes.text, paper: input.paperBlock), label: "✍️ Writing", kind: "whole",
                                                              numPredict: input.careful ? sizing * 2 : sizing, temperature: 0.2, think: input.careful)) else { return nil }
            genMs += nowMs() - t0
            answerText = first
        }
        var current = AcdDoc.parse(answerText)
        hooks.status("🧪 Validating…")
        var t0 = nowMs()
        var val = await hooks.validate(current.files)
        valMs += nowMs() - t0
        var best = (doc: current, val: val)
        var rounds = 0
        var note = ""
        while best.val.failureCount > 0 && rounds < maxRepairs && !best.doc.files.isEmpty {
            rounds += 1
            let files = best.doc.files
            let errors = best.val.errorText
            let affected = Set(files.keys.filter { errors.contains($0) || errors.contains(($0 as NSString).lastPathComponent) })
            // the ORIGINAL requirements stay in the prompt: the questions that own the failing files (or the whole task)
            let ownerIDs = Set(affected.compactMap { owners[$0] })
            var requirements = input.paperBlock
            if mode == "units" && !ownerIDs.isEmpty {
                requirements = (plan.preamble.isEmpty ? "" : plan.preamble + "\n\n") + plan.units.filter { ownerIDs.contains($0.id) }.map { $0.text }.joined(separator: "\n\n")
                    + (starterText.isEmpty ? "" : "\n\nSTARTER PROJECT FILES\n" + starterText)
            }
            let prompt = AcdPrompt.repair(paper: requirements, files: files, errors: errors, affected: affected)
            hooks.resetOutput()
            t0 = nowMs()
            let fixesOpt = await hooks.generate(AcdRequest(prompt: prompt, label: "🔧 Fixing \(best.val.failureCount) problem(s)", kind: "repair", numPredict: 3000, temperature: 0.2, think: false))
            genMs += nowMs() - t0
            guard let fixesText = fixesOpt else { note = "repair request failed — best answer kept"; break }
            let merged = best.doc.merging(AcdDoc.parse(fixesText))
            if merged.render() == best.doc.render() { note = "repair changed nothing — best answer kept"; break }
            hooks.status("🧪 Validating…")
            t0 = nowMs()
            let v2 = await hooks.validate(merged.files)
            valMs += nowMs() - t0
            if v2.failureCount < best.val.failureCount || (v2.failureCount == best.val.failureCount && v2.failureCount == 0) {
                best = (merged, v2)
            } else { note = "repair round \(rounds) did not improve (\(v2.failureCount) vs \(best.val.failureCount) problems) — best earlier answer kept"; break }
        }
        if best.val.failureCount > 0 && note.isEmpty { note = "problems remain after \(rounds) repair round(s)" }
        current = best.doc; val = best.val
        return AcdResult(answer: current.render(), validation: val, repairRounds: rounds, generationMs: genMs, validationMs: valMs, repairNote: note,
                         mode: mode, unitCount: plan.units.count, unanswered: unanswered, notesUsed: notesUsed, unitMs: unitMs)
    }
}

// ---- Ollama for ACD: small contexts, per-request thinking, memory-aware (OOP's OllamaProvider is untouched) ----
final class AcdOllamaSession {
    let config: DropConfig
    let model: String
    var onProgress: (String) -> Void = { _ in }
    private(set) var requestCount = 0, unloadCount = 0

    init(config: DropConfig, model: String) { self.config = config; self.model = model }

    /// The model's resident size grows with every request (prefix cache). Unload it before it outgrows physical RAM.
    func residentBytes() async -> Int64? {
        guard let u = URL(string: config.ollamaBase + "/api/ps"), let (data, _) = try? await URLSession.shared.data(from: u),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ms = o["models"] as? [[String: Any]] else { return nil }
        let m = ms.first { ($0["name"] as? String) == model || ($0["model"] as? String) == model } ?? ms.first
        return (m?["size"] as? NSNumber)?.int64Value
    }

    func unload() async {
        guard let u = URL(string: config.ollamaBase + "/api/generate") else { return }
        var req = URLRequest(url: u); req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: req)
        unloadCount += 1
    }

    /// Always call when the run ends (success or failure): quiet laptop — nothing stays loaded.
    func release() async { await unload() }

    func generate(_ r: AcdRequest) async -> (text: String, error: String?) {
        let limit = Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.6)
        if let b = await residentBytes(), b > limit { await unload() }
        let cap = min(32768, config.ollamaContext > 0 ? config.ollamaContext : config.ollamaContextCeiling)
        let promptTokens = r.prompt.count / 3
        var ctx = 2048
        while ctx < promptTokens + r.numPredict + 300 && ctx < cap { ctx *= 2 }
        ctx = min(ctx, cap)
        if promptTokens + 300 + 256 > ctx {
            return ("", "this request needs about \(promptTokens) tokens, above the context limit (\(ctx)); raise Qwen ctx in Settings")
        }
        let np = min(r.numPredict, max(256, ctx - promptTokens - 300))
        var attempt = 0
        while true {
            attempt += 1
            guard let url = URL(string: config.ollamaBase + "/api/generate") else { return ("", "bad Ollama address") }
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 900
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": model, "prompt": r.prompt, "stream": true, "think": r.think, "keep_alive": "2m",
                                       "options": ["num_ctx": ctx, "temperature": r.temperature, "num_predict": np]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            var answer = "", thinking = 0, doneReason = ""
            do {
                requestCount += 1
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                    var raw = ""
                    for try await l in bytes.lines { raw += l; if raw.count > 600 { break } }
                    if h.statusCode >= 500 && attempt == 1 { await unload(); try? await Task.sleep(nanoseconds: 3_000_000_000); continue }   // memory pressure: reload once
                    return ("", classifyHTTP(status: h.statusCode, retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"), detail: errorDetail(from: raw)).displayMessage)
                }
                for try await line in bytes.lines {
                    guard let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if let e = obj["error"] as? String { return (answer, "Ollama: \(e)") }
                    if let th = obj["thinking"] as? String, !th.isEmpty { thinking += th.count; onProgress("\(r.label) · thinking \(thinking) chars") }
                    if let piece = obj["response"] as? String, !piece.isEmpty { answer += piece; onProgress("\(r.label) · \(answer.count) chars") }
                    if let dr = obj["done_reason"] as? String { doneReason = dr }
                }
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ("", doneReason == "length"
                            ? "no answer within the \(np)-token budget" + (r.think ? " (the model spent it thinking; turn Careful mode off)" : "")
                            : "empty response")
                }
                return (answer, nil)
            } catch {
                if !answer.isEmpty { return (answer, nil) }
                return ("", classifyURLError(error).displayMessage)
            }
        }
    }
}

// ---- objective answers (multiple choice / true-false) ----
enum AcdObjective {
    /// Normalised answer of a question block: "A".."D", "True" or "False"; nil when it cannot be read.
    static func normalise(_ blockText: String) -> String? {
        let first = blockText.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: " *`_\t")) ?? ""
        let l = first.lowercased()
        for (w, v) in [("true", "True"), ("false", "False")] where l == w || l.hasPrefix(w + " ") || l.hasPrefix(w + ".") || l.hasPrefix(w + ",") || l.hasPrefix(w + "-") || l.hasPrefix(w + ":") || l.hasPrefix(w + ")") { return v }
        if let m = first.range(of: #"^\(?([A-Da-d])(?:[\)\.\:\-– ]|$)"#, options: .regularExpression) { return String(first[m]).filter { $0.isLetter }.uppercased() }
        return nil
    }
}

// ---- user-triggered toolchain install (never automatic) ----
enum AcdToolchain {
    static var dir: URL { ACD_SUPPORT_DIR.appendingPathComponent("toolchain") }
    static func findPackageJSON() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ACD")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: URL?
        for case let f as URL in en {
            if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { if f.lastPathComponent == "node_modules" { en.skipDescendants() }; continue }
            if f.lastPathComponent == "package.json", best == nil || f.path.count < best!.path.count { best = f }
        }
        return best
    }
    /// Runs `npm ci` / `npm install` in the toolchain folder. Only ever called after the user confirmed it.
    static func install(packageJSON: URL) -> (ok: Bool, output: String) {
        guard let npm = AcdTools.find("npm") else { return (false, "npm was not found (install Node.js first)") }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dir.appendingPathComponent("package.json"))
        try? fm.copyItem(at: packageJSON, to: dir.appendingPathComponent("package.json"))
        let lock = packageJSON.deletingLastPathComponent().appendingPathComponent("package-lock.json")
        let hasLock = fm.fileExists(atPath: lock.path)
        if hasLock { try? fm.removeItem(at: dir.appendingPathComponent("package-lock.json")); try? fm.copyItem(at: lock, to: dir.appendingPathComponent("package-lock.json")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: npm)
        p.arguments = hasLock ? ["ci", "--no-audit", "--no-fund"] : ["install", "--no-audit", "--no-fund"]
        p.currentDirectoryURL = dir
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = ((AcdTools.find("node") as NSString?)?.deletingLastPathComponent ?? "/usr/local/bin") + ":/usr/bin:/bin"
        p.environment = e
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}

// ---- AppDelegate: subject toggle, ACD run, part copy, toolchain (all additive) ----------------
extension AppDelegate {
    func currentAnswer(for s: Subject) -> String { s == .acd ? lastAnswerACD : lastAnswer }

    @objc func subjectChanged() {
        let s: Subject = subjectControl.selectedSegment == 1 ? .acd : .oop
        subject = s
        s.save()                       // its own UserDefaults key; provider/model/config are not touched
        updateSubjectUI()
        if !running { textView.string = currentAnswer(for: s) }   // a running run keeps streaming into the view untouched
    }

    func updateSubjectUI() {
        subjectControl.selectedSegment = subject == .acd ? 1 : 0
        subjectControl.selectedSegmentBezelColor = subject == .acd ? .systemTeal : .systemBlue
        runFolderBtn.toolTip = "Run \(subject.folder) now (visible)"
        partField.placeholderString = subject == .acd ? "2 · A1 · File.tsx" : "Task number"
        if !running { setStatus("\(subject.label) · reads \(subject.folder)") }
    }

    /// Popup entry point for dropped files, the file picker and the Run folder button.
    /// The OOP hotkeys never come through here: they call handle() directly, so they stay OOP whatever the toggle says.
    func dispatchSubject(_ urls: [URL]) {
        if subject == .acd { handleACD(urls) } else { handleOOP(urls, perTask: AcdSettings.oopPerTask) }
    }

    @objc func runSubjectFolder() {
        guard !running else { setStatus("⏳ Busy – wait for the current answer"); return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subject.folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            setStatus("⚠️ \(subject.label) folder not found on Desktop"); return
        }
        dispatchSubject([dir])
    }

    /// Copy a part of the selected subject's answer: "2" = Task 2, "A1" = question A1, "Events.tsx" = that file.
    @objc func copyPart() {
        let key = partField.stringValue.trimmingCharacters(in: .whitespaces)
        let answer = currentAnswer(for: subject)
        guard !answer.isEmpty else { setStatus("No \(subject.label) answer yet"); return }
        guard !key.isEmpty else { setStatus("Type a task number, question id or file name"); return }
        let slice: String?
        if subject == .acd { slice = AcdDoc.parse(answer).part(key) }
        else if let n = Int(key) { slice = AppDelegate.taskSection(answer, n: n) } else { slice = nil }
        guard let s = slice else { setStatus("⚠️ \"\(key)\" not found in the \(subject.label) answer"); return }
        copyToClipboard(s)
        setStatus("✅ \(key) copied · paste with ⌘V")
    }

    // ---- visible ACD run (never headless, never hotkey-triggered) ----
    func handleACD(_ urls: [URL]) {
        if running { setStatus("⏳ Busy – wait for the current answer"); return }
        guard let model = resolvedModelName(from: modelPopup.titleOfSelectedItem), !model.isEmpty else {
            setStatus(config.provider == "ollama" ? "⚠️ No Qwen model installed – ollama pull a Qwen model first" : "⚠️ No model selected")
            return
        }
        // Everything the run needs is captured NOW; toggling the subject afterwards cannot change any of it.
        let input = AcdInput.collectMany(urls, extract: { self.extractText($0) })
        if input.taskOnly.split(whereSeparator: { $0.isWhitespace }).count < 15 && input.starter.isEmpty {
            setStatus(input.fileCount == 0 ? "⚠️ Nothing readable found for ACD" : "⚠️ No readable task text (scanned PDF?)")
            return
        }
        let providerId = config.provider
        let cfg = config
        let ceiling = providerId == "ollama"
            ? (cfg.ollamaContext > 0 ? min(cfg.ollamaContext, 65536) : cfg.ollamaContextCeiling)
            : 32768
        let chunks = AcdNotes.load(dirs: [AcdNotes.installedDir, AcdNotes.desktopDir], extract: { self.extractText($0) })
        let runInput = AcdRunInput(taskText: input.taskOnly, paperBlock: input.paper, starter: input.starter, chunks: chunks,
                                   careful: AcdSettings.careful, ceilingTokens: ceiling, questionCount: input.questionCount)
        running = true
        textView.string = ""
        dropView.title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        setStatus("⏳ ACD · read \(input.fileCount) file(s) · planning…")
        let starter = input.starter, root = input.projectRoot
        Task { @MainActor in
            defer { self.running = false; self.dropView.title = "Drop to share" }
            var session: AcdOllamaSession?
            var lastError = ""
            let generate: (AcdRequest) async -> String?
            if providerId == "ollama" {
                // on-demand start (quiet laptop); the session unloads the model when it grows and when the run ends
                guard await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout, onStatus: { self.setStatus($0) }) else {
                    self.setStatus("⚠️ Ollama could not be started"); return
                }
                let s = AcdOllamaSession(config: cfg, model: model)
                s.onProgress = { p in DispatchQueue.main.async { self.setStatus("⏳ ACD · " + p) } }
                session = s
                generate = { req in
                    let r = await s.generate(req)
                    if let e = r.error { lastError = "\(req.label): \(e)"; self.setStatus("⚠️ " + lastError); return r.text.isEmpty ? nil : r.text }
                    return r.text
                }
            } else {
                generate = { req in await self.generate(prompt: req.prompt, model: model, label: req.label) }
            }
            let hooks = AcdHooks(
                generate: generate,
                validate: { files in
                    await Task.detached(priority: .userInitiated) { AcdValidator.validate(files: files, starter: starter, projectRoot: root) }.value },
                status: { self.setStatus($0) },
                resetOutput: { self.textView.string = "" })
            let result = await AcdPipeline.run(input: runInput, hooks: hooks)
            if let s = session { await s.release() }
            guard let result = result else { self.setStatus("❌ ACD: no answer produced" + (lastError.isEmpty ? "" : " · " + lastError)); return }
            self.lastAnswerACD = result.answer                       // the ACD slot — never the OOP one the hotkeys copy
            let missing = result.unanswered.isEmpty ? "" : "\nUNANSWERED: " + result.unanswered.joined(separator: ", ") + (lastError.isEmpty ? "" : " (" + lastError + ")")
            if self.subject == .acd {
                self.textView.string = "── Validation ──\n" + result.validation.summary
                    + (result.repairNote.isEmpty ? "" : "\n" + result.repairNote) + missing + "\n\n" + result.answer
            }
            self.copyToClipboard(result.answer)
            NSSound(named: NSSound.Name("Glass"))?.play()
            let bad = result.validation.failureCount
            self.setStatus((bad == 0 && result.unanswered.isEmpty ? "✅ ACD answer copied" : "⚠️ ACD answer copied, \(bad + result.unanswered.count) problem(s)") + " · " + result.validation.summary
                           + (result.unanswered.isEmpty ? "" : " · unanswered " + result.unanswered.joined(separator: ","))
                           + (result.repairNote.isEmpty ? "" : " · " + result.repairNote))
        }
    }

    /// The model spent its whole token budget THINKING and wrote nothing ("context limit reached – no answer produced"): ask again without thinking,
    /// through the small-context, memory-aware session; if that is empty too, write the answer task by task.
    func oopThinkingFallback(prompt: String, label: String, model: String, paper: String, firstRequest: Bool) async -> String? {
        guard await prepareOllama(startIfNeeded: true, base: config.ollamaBase, timeout: config.connectTimeout) else { return nil }
        let s = AcdOllamaSession(config: config, model: model)
        s.onProgress = { p in DispatchQueue.main.async { self.setStatus("⏳ retry without thinking · " + p) } }
        setStatus("⚠️ The model used its token budget thinking — retrying without thinking…")
        var out = await oopSessionRequest(s, AcdRequest(prompt: prompt, label: label + " (no thinking)", kind: "whole", numPredict: max(config.numPredict, 4096), temperature: 0.2, think: false))
        if (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, firstRequest, let plan = OopPerTask.plan(paperBlock: paper) {
            out = await OopPerTask.writeAnswer(plan: plan, careful: false, generate: { await self.oopSessionRequest(s, $0) }, status: { self.setStatus($0) })
        }
        await s.release()
        return (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
    }

    /// One request through the memory-aware session; failures show in the status line and return nil.
    func oopSessionRequest(_ s: AcdOllamaSession, _ req: AcdRequest) async -> String? {
        let r = await s.generate(req)
        if let e = r.error { setStatus("⚠️ \(req.label): \(e)"); return r.text.isEmpty ? nil : r.text }
        return r.text
    }

    @objc func toggleOopPerTask() {
        AcdSettings.setOopPerTask(!AcdSettings.oopPerTask)
        setStatus(AcdSettings.oopPerTask ? "OOP per-task generation on (experimental)" : "OOP popup run: single request (default)")
    }

    @objc func toggleCareful() {
        AcdSettings.setCareful(!AcdSettings.careful)
        setStatus(AcdSettings.careful ? "ACD careful mode on (slower)" : "ACD fast mode (default)")
    }

    // ---- optional, explicitly user-triggered: never runs automatically ----
    @objc func prepareToolchain() {
        guard let pj = AcdToolchain.findPackageJSON() else {
            let a = NSAlert(); a.messageText = "No starter project found"
            a.informativeText = "Put the course starter project (with its package.json) in Desktop/ACD first; its dependencies define the toolchain."
            a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "Prepare ACD toolchain?"
        a.informativeText = "This runs npm to download the dependencies listed in\n\(pj.path)\ninto ~/Library/Application Support/Drop/acd/toolchain. It needs internet and may take a few minutes. Nothing is installed unless you click Install."
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        setStatus("⏳ Installing ACD toolchain…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AcdToolchain.install(packageJSON: pj)
            DispatchQueue.main.async {
                self.setStatus(r.ok ? "✅ ACD toolchain ready" : "⚠️ Toolchain install failed")
                if !r.ok { let e = NSAlert(); e.messageText = "Toolchain install failed"; e.informativeText = String(r.output.suffix(800)); e.runModal() }
            }
        }
    }
}

extension AcdInput {
    /// One folder is read in place (its own node_modules can be reused); other drops are merged.
    static func collectMany(_ urls: [URL], extract: (URL) -> String) -> AcdInput {
        let fm = FileManager.default
        var merged = AcdInput(paper: "", taskOnly: "", starter: [:], projectRoot: nil, fileCount: 0, questionCount: 1)
        for u in urls {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            var dir = u
            if !isDir.boolValue {
                let tmpRaw = fm.temporaryDirectory.appendingPathComponent("dropacd-f-" + UUID().uuidString)
                try? fm.createDirectory(at: tmpRaw, withIntermediateDirectories: true)
                dir = acdRealPath(tmpRaw)
                try? fm.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent))
            }
            let one = collect(isDir.boolValue ? acdRealPath(u) : dir, extract: extract)
            merged.paper += one.paper
            merged.taskOnly += one.taskOnly
            for (k, v) in one.starter { merged.starter[k] = v }
            merged.projectRoot = merged.projectRoot ?? one.projectRoot
            merged.fileCount += one.fileCount
        }
        merged.questionCount = countQuestions(merged.taskOnly)
        return merged
    }
}

// ---- OOP per-task generation (visible popup run only; the hotkey/headless run and OpenCode keep the original single request) ----
// The whole-paper request puts ~9k prompt tokens + a thinking budget into one call. This path asks for ONE task per request,
// reusing the unchanged OLLAMA_PROMPT_HEADER (so the student-level rules are identical) and the same compile → repair pipeline afterwards.
// The stable prefix (header, paper preamble, starter, worked examples) comes first so Ollama's prefix cache can reuse it between tasks.
enum OopPerTask {
    struct Part { var n: Int; var text: String; var marks: Int }
    struct Plan { var preamble: String; var tasks: [Part]; var postamble: String; var starterText: String }

    static func plan(paperBlock: String) -> Plan? {
        let marker = "######## STARTER PROJECT FILES ########"
        var docs = paperBlock, starter = ""
        if let r = paperBlock.range(of: marker) { docs = String(paperBlock[..<r.lowerBound]); starter = String(paperBlock[r.upperBound...]) }
        let lines = docs.components(separatedBy: "\n")
        let marked = try! NSRegularExpression(pattern: #"^\s*Task\s+(\d+)\s*[–\-:].*\[\s*(\d+)\s*marks"#)
        let plain = try! NSRegularExpression(pattern: #"^\s*Task\s+(\d+)\b"#)
        func heads(_ re: NSRegularExpression) -> [(idx: Int, n: Int, marks: Int)] {
            var out: [(Int, Int, Int)] = []
            for (i, l) in lines.enumerated() {
                let ns = l as NSString
                if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)), let n = Int(ns.substring(with: m.range(at: 1))) {
                    let marks = m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
                    out.append((i, n, marks))
                }
            }
            return out
        }
        var hs = heads(marked)
        if Set(hs.map { $0.n }).count < 2 { hs = heads(plain) }
        // one heading per task number: with marks the match is already the real heading; otherwise the LAST one (earlier ones are marks-table rows)
        var lastIdx: [Int: Int] = [:]; for (k, h) in hs.enumerated() { lastIdx[h.n] = k }
        hs = hs.enumerated().filter { lastIdx[$0.element.n] == $0.offset }.map { $0.element }.sorted { $0.idx < $1.idx }
        guard hs.count >= 2 else { return nil }
        let stops = ["illustrative calculations", "rest operations", "section b", "submission and final"]
        func isStop(_ l: String) -> Bool { let t = l.lowercased().trimmingCharacters(in: .whitespaces); return stops.contains { t.hasPrefix($0) } }
        // for a "Task 1/2/3" table the rows come before the real headings: use only headings after the last repeated block when marks are present
        var parts: [Part] = []
        var endOfTasks = lines.count
        for (k, h) in hs.enumerated() {
            var end = k + 1 < hs.count ? hs[k + 1].idx : lines.count
            if let s = ((h.idx + 1)..<end).first(where: { isStop(lines[$0]) }) { end = s; if k == hs.count - 1 { endOfTasks = s } }
            parts.append(Part(n: h.n, text: lines[h.idx..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), marks: h.marks))
        }
        let pre = lines[0..<hs[0].idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let post = endOfTasks < lines.count ? lines[endOfTasks...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Plan(preamble: String(pre.suffix(3500)), tasks: parts, postamble: String(post.prefix(3000)), starterText: starter.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func prompt(plan: Plan, part: Part, written: [String: String]) -> String {
        var starter = plan.starterText
        // a file already rewritten by an earlier task replaces the starter copy
        if !written.isEmpty {
            let keep = ("\n" + starter).components(separatedBy: "\n===== FILE: ")
            var rebuilt = keep.first ?? ""
            for chunk in keep.dropFirst() {
                let name = chunk.components(separatedBy: " =====").first ?? ""
                if !written.keys.contains(where: { $0.hasSuffix(name) }) { rebuilt += "\n===== FILE: " + chunk }
            }
            starter = rebuilt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var p = OLLAMA_PROMPT_HEADER + "\n\n######## EXAM PAPER / INSTRUCTIONS ########\n" + plan.preamble
            + "\n\n######## STARTER PROJECT FILES ########\n" + starter
        if !plan.postamble.isEmpty { p += "\n\n######## WORKED EXAMPLES AND CHECKS FROM THE PAPER ########\n" + plan.postamble }
        if !written.isEmpty {
            p += "\n\n######## FILES YOU HAVE ALREADY WRITTEN FOR EARLIER TASKS (keep them compatible) ########"
            for k in written.keys.sorted() { p += "\n// ===== FILE: \(k) =====\n" + (written[k] ?? "") }
        }
        p += "\n\n######## THIS REQUEST ########\nWrite ONLY Task \(part.n) now. Output the header line // ===== Task \(part.n) ===== and then every Java file that Task \(part.n) adds or changes, each COMPLETE, each under its own // ===== FILE: ... ===== header line. "
            + "If Task \(part.n) changes a file written for an earlier task, give that file again in full including the earlier code. Do not write any other task and do not write a HOW TO TEST section.\n\n######## TASK \(part.n) ########\n" + part.text + "\n"
        return p
    }

    /// One request per task; the combined answer has the usual "// ===== Task N =====" + FILE layout the rest of the pipeline expects.
    @MainActor
    static func writeAnswer(plan: Plan, careful: Bool, generate: (AcdRequest) async -> String?, status: (String) -> Void) async -> String? {
        var combined = ""
        var written: [String: String] = [:]
        var produced = 0
        for (i, part) in plan.tasks.enumerated() {
            status("⏳ Task \(part.n) (\(i + 1)/\(plan.tasks.count))")
            let prompt = prompt(plan: plan, part: part, written: written)
            let budget = min(6000, 1500 + 120 * max(part.marks, 10))
            var reply = await generate(AcdRequest(prompt: prompt, label: "Task \(part.n)", kind: "free", numPredict: careful ? min(8000, budget * 2) : budget, temperature: 0.2, think: careful))
            if (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && careful {
                reply = await generate(AcdRequest(prompt: prompt, label: "Task \(part.n) (no thinking)", kind: "free", numPredict: budget, temperature: 0.2, think: false))
            }
            guard var r = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { continue }
            if !r.contains("// ===== Task \(part.n) =====") { r = "// ===== Task \(part.n) =====\n" + r }
            combined += (combined.isEmpty ? "" : "\n") + r
            written = AppDelegate.parseAnswerFiles(combined)
            produced += 1
        }
        return produced == 0 ? nil : combined
    }
}

// ---- OOP (Ollama only): fixes driven by javac's own error text, applied BEFORE asking the model to repair ----
// A 4B model writes sound Java but often forgets an import, calls a method that does not exist, or mismatches a generic type.
// Those are mechanical: javac names the exact file, symbol and kind, so Drop can fix them deterministically and recompile
// without spending a repair round (or a model call). Every rule fires only for its own javac error.
extension AppDelegate {
    /// JDK / Spring names models commonly use without importing.
    static let wellKnownImports: [String: String] = [
        "Collectors": "java.util.stream.Collectors", "Stream": "java.util.stream.Stream", "IntStream": "java.util.stream.IntStream",
        "ConcurrentHashMap": "java.util.concurrent.ConcurrentHashMap", "CopyOnWriteArrayList": "java.util.concurrent.CopyOnWriteArrayList",
        "AtomicLong": "java.util.concurrent.atomic.AtomicLong", "AtomicInteger": "java.util.concurrent.atomic.AtomicInteger",
        "LocalDate": "java.time.LocalDate", "LocalDateTime": "java.time.LocalDateTime", "Duration": "java.time.Duration", "Instant": "java.time.Instant",
        "BigDecimal": "java.math.BigDecimal", "BigInteger": "java.math.BigInteger",
        "List": "java.util.List", "Map": "java.util.Map", "Set": "java.util.Set", "ArrayList": "java.util.ArrayList", "HashMap": "java.util.HashMap",
        "HashSet": "java.util.HashSet", "LinkedList": "java.util.LinkedList", "TreeMap": "java.util.TreeMap", "LinkedHashMap": "java.util.LinkedHashMap",
        "Collection": "java.util.Collection", "Collections": "java.util.Collections", "Comparator": "java.util.Comparator", "Optional": "java.util.Optional",
        "Objects": "java.util.Objects", "Arrays": "java.util.Arrays", "Iterator": "java.util.Iterator", "Deque": "java.util.Deque", "ArrayDeque": "java.util.ArrayDeque",
        "ResponseEntity": "org.springframework.http.ResponseEntity", "HttpStatus": "org.springframework.http.HttpStatus", "MediaType": "org.springframework.http.MediaType",
        "RestController": "org.springframework.web.bind.annotation.RestController", "RequestMapping": "org.springframework.web.bind.annotation.RequestMapping",
        "GetMapping": "org.springframework.web.bind.annotation.GetMapping", "PostMapping": "org.springframework.web.bind.annotation.PostMapping",
        "PutMapping": "org.springframework.web.bind.annotation.PutMapping", "DeleteMapping": "org.springframework.web.bind.annotation.DeleteMapping",
        "RequestBody": "org.springframework.web.bind.annotation.RequestBody", "RequestParam": "org.springframework.web.bind.annotation.RequestParam",
        "PathVariable": "org.springframework.web.bind.annotation.PathVariable", "ExceptionHandler": "org.springframework.web.bind.annotation.ExceptionHandler",
        "RestControllerAdvice": "org.springframework.web.bind.annotation.RestControllerAdvice", "ResponseStatus": "org.springframework.web.bind.annotation.ResponseStatus",
        "Service": "org.springframework.stereotype.Service", "Repository": "org.springframework.stereotype.Repository", "Component": "org.springframework.stereotype.Component",
    ]

    private static func packageName(of body: String) -> String? {
        for l in body.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("package ") { return t.dropFirst(8).replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func javacFixes(_ answer: String, starter: [String: String], errs: String) -> String {
        let files = parseAnswerFiles(answer)
        if files.isEmpty { return answer }
        // every class the project defines (starter + answer): simple name -> fully qualified
        var project: [String: String] = [:]
        for (path, body) in starter.merging(files, uniquingKeysWith: { _, new in new }) where path.hasSuffix(".java") {
            guard let pkg = packageName(of: body) else { continue }
            project[((path as NSString).lastPathComponent as NSString).deletingPathExtension] = pkg + "." + ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        let all = (Array(starter.values) + Array(files.values)).joined(separator: "\n")
        let headRe = try! NSRegularExpression(pattern: #"^(\S+\.java):(\d+): error: (.*)$"#)
        let symRe = try! NSRegularExpression(pattern: #"symbol:\s+(class|method|variable)\s+(\w+)"#)
        var blocks: [(file: String, msg: String, text: String)] = []
        for line in errs.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = headRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                blocks.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 3)), line))
            } else if !blocks.isEmpty { blocks[blocks.count - 1].text += "\n" + line }
        }
        var edited: [String: String] = [:]
        func current(_ f: String) -> String { edited[f] ?? files[f] ?? "" }
        let listLong = all.contains("List<Long>")
        for b in blocks {
            guard files[b.file] != nil else { continue }               // only files the answer wrote can be edited
            var kind = "", name = ""
            let ns = b.text as NSString
            if let m = symRe.firstMatch(in: b.text, range: NSRange(location: 0, length: ns.length)) { kind = ns.substring(with: m.range(at: 1)); name = ns.substring(with: m.range(at: 2)) }
            var body = current(b.file)
            if b.msg == "cannot find symbol", kind == "class", let fq = wellKnownImports[name] ?? project[name] {
                let pkg = (fq as NSString).deletingPathExtension
                if packageName(of: body) != pkg, !body.contains("import \(fq);"), !body.contains("import \(pkg).*;") {
                    var lines = body.components(separatedBy: "\n")
                    if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package ") }) { lines.insert("import \(fq);", at: i + 1); body = lines.joined(separator: "\n") }
                }
            } else if b.msg == "cannot find symbol", kind == "method", name == "getType",
                      all.range(of: #"\bgetType\s*\(\s*\)\s*\{"#, options: .regularExpression) == nil {
                body = body.replacingOccurrences(of: ".getType()", with: ".getClass().getSimpleName()")      // no such accessor: the simple class name is the type
            } else if b.msg.hasPrefix("bad operand types"), b.text.contains("<null>"), let ln = Int(b.text.components(separatedBy: ":").dropFirst().first ?? "") {
                // a primitive (e.g. long id()) compared with null can never be null: drop that comparison on the reported line
                var lines = ensureUtilImport(body).components(separatedBy: "\n")      // javac numbered the file with runJavac's extra import line
                if ln >= 1 && ln <= lines.count {
                    var l = lines[ln - 1]
                    for pat in [#"\b[\w.]+(?:\(\))?\s*==\s*null\s*\|\|\s*"#, #"\s*\|\|\s*[\w.]+(?:\(\))?\s*==\s*null"#, #"\b[\w.]+(?:\(\))?\s*!=\s*null\s*&&\s*"#, #"\s*&&\s*[\w.]+(?:\(\))?\s*!=\s*null"#] {
                        l = try! NSRegularExpression(pattern: pat).stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: "")
                    }
                    lines[ln - 1] = l; body = lines.joined(separator: "\n")
                }
            } else if b.msg.range(of: #"^incompatible types: (Collection|Set)<(\w+)> cannot be converted to (List|Set)<"#, options: .regularExpression) != nil,
                      let ln = Int(b.text.components(separatedBy: ":").dropFirst().first ?? "") {
                // a Collection assigned to a List/Set variable: copy it into the type the variable declares
                var lines = ensureUtilImport(body).components(separatedBy: "\n")
                if ln >= 1 && ln <= lines.count {
                    let target = b.msg.contains("converted to Set<") ? "HashSet" : "ArrayList"
                    let re = try! NSRegularExpression(pattern: #"=\s*(?!new\s)(.+?);"#)
                    let l = lines[ln - 1]
                    lines[ln - 1] = re.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: "= new \(target)<>($1);")
                    body = lines.joined(separator: "\n")
                }
            } else if b.msg.hasPrefix("bad operand type int for unary operator '!'"), let ln = Int(b.text.components(separatedBy: ":").dropFirst().first ?? "") {
                // `if (!Math.toIntExact(x)) { throw … }`: toIntExact already throws on overflow, so the statement is just the call
                var lines = ensureUtilImport(body).components(separatedBy: "\n")
                if ln >= 1 && ln <= lines.count {
                    let re = try! NSRegularExpression(pattern: #"if\s*\(\s*!\s*(Math\.toIntExact\([^)]*\))\s*\)\s*\{[^{}]*\}"#)
                    let l = lines[ln - 1]
                    lines[ln - 1] = re.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: "$1;")
                    body = lines.joined(separator: "\n")
                }
            } else if b.msg == "cannot find symbol", kind == "variable",
                      let cm = try? NSRegularExpression(pattern: "\\(([^)]*\\b([\\w<>\\[\\]]+)\\s+" + name + "\\b[^)]*)\\)\\s*\\{[^}]*this\\." + name + "\\s*=").firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)),
                      !body.contains("private final \((body as NSString).substring(with: cm.range(at: 2))) \(name);") {
                // a constructor assigns this.<name> but the field was never declared: declare it with the parameter's type
                let ns = body as NSString
                let type = ns.substring(with: cm.range(at: 2))
                let before = ns.substring(to: cm.range.location)
                if let cls = try? NSRegularExpression(pattern: #"class\s+\w+[^{]*\{"#).matches(in: before, range: NSRange(location: 0, length: (before as NSString).length)).last {
                    body = ns.replacingCharacters(in: NSRange(location: cls.range.location + cls.range.length, length: 0), with: "\n  private final \(type) \(name);")
                }
            } else if (b.msg.hasPrefix("incompatible types") || b.msg.contains("cannot infer type-variable")) && listLong {
                // a List<Long> field built as strings: pass the list itself
                let re = try! NSRegularExpression(pattern: #"(\w+)\.stream\(\)\.map\((?:Long::toString|String::valueOf)\)\.collect\(Collectors\.toList\(\)\)"#)
                body = re.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "$1")
            }
            if body != current(b.file) { edited[b.file] = body }
        }
        if edited.isEmpty { return answer }
        let fixes = edited.keys.sorted().map { "// ===== FILE: \($0) =====\n" + (edited[$0] ?? "") }.joined(separator: "\n")
        return mergeFixes(answer, fixes)
    }

    /// @GetMapping("/plan?capacity=...&urgentOnly=false") copies a query string into the path, which never matches: keep only the path.
    static func fixMappingQueryStrings(_ answer: String) -> String {
        let re = try! NSRegularExpression(pattern: #"(@(?:Get|Post|Put|Delete|Patch|Request)Mapping\(\s*(?:value\s*=\s*)?")(/[^"?]*)\?[^"]*(")"#)
        return re.stringByReplacingMatches(in: answer, range: NSRange(location: 0, length: (answer as NSString).length), withTemplate: "$1$2$3")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatPanel!
    let dropView = DropView(frame: .zero)
    let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var expandBtn: NSButton!
    var providerBtn: NSButton!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var running = false
    var starterFiles: [String: String] = [:]
    var lastAnswer = ""
    var benchWC: BenchWindowController?
    var subject: Subject = Subject.saved          // OOP unless the user chose ACD (own UserDefaults key)
    var lastAnswerACD = ""                        // ACD slot; lastAnswer stays the OOP slot the hotkeys copy
    var lastFailureMessage = ""                   // why the last provider request failed (drives the no-thinking retry)
    var subjectControl: NSSegmentedControl!
    var runFolderBtn: NSButton!
    var partField: NSTextField!
    var partRow: NSStackView!
    // Remembered so an approved provider fallback can answer the SAME request.
    var lastPrompt: String?
    var lastModel: String?
    var lastLabel: String?
    var expanded = false
    var config = DropConfig.load()
    let W: CGFloat = 230
    let compactH: CGFloat = 121   // drop row + OOP/ACD toggle row + dynamic model selector + button row
    let answerH: CGFloat = 267    // answer pane + the copy-part row

    var activeProvider: ProviderAdapter {
        config.provider == "opencode_go"
            ? OpenCodeGoProvider(config: config)
            : OllamaProvider(config: config)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.midX - W / 2, y: screen.maxY - compactH - 6, width: W, height: compactH)
        panel = FloatPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        dropView.onDrop = { [weak self] urls in self?.dispatchSubject(urls) }
        dropView.onClick = { [weak self] in self?.chooseFiles() }

        modelPopup.controlSize = .small
        modelPopup.font = NSFont.systemFont(ofSize: 11)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.toolTip = "Installed Qwen models (discovered from Ollama)"

        func small(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.controlSize = .mini
            b.font = NSFont.systemFont(ofSize: 9)
            b.bezelStyle = .rounded
            return b
        }
        let copyBtn = small("Copy", #selector(copyAgain))
        expandBtn = small("Share ▾", #selector(toggleAnswer))
        let quitBtn = small("✕", #selector(hidePanel))
        quitBtn.toolTip = "Hide (click the menu bar icon to show again)"
        providerBtn = small(config.provider == "ollama" ? "🦙 Ollama" : "☁️ OpenCode", #selector(toggleProvider))
        providerBtn.toolTip = "Switch provider (Ollama local / OpenCode Go cloud)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [providerBtn, spacer, copyBtn, expandBtn, quitBtn])
        row.spacing = 6

        textView.isEditable = false
        textView.font = mono
        textView.drawsBackground = false
        scroll.drawsBackground = false
        scroll.isHidden = true

        // OOP / ACD toggle (visible, remembered under its own key) + visible "Run folder" button
        subjectControl = NSSegmentedControl(labels: ["OOP", "ACD"], trackingMode: .selectOne, target: self, action: #selector(subjectChanged))
        subjectControl.controlSize = .small
        subjectControl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        subjectControl.toolTip = "Subject: OOP reads Desktop/OOP (Java) · ACD reads Desktop/ACD (web)"
        runFolderBtn = small("▶ Run folder", #selector(runSubjectFolder))
        let subjectSpacer = NSView()
        subjectSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let subjectRow = NSStackView(views: [subjectControl, subjectSpacer, runFolderBtn])
        subjectRow.spacing = 6
        partField = NSTextField(string: "")
        partField.controlSize = .small
        partField.font = NSFont.systemFont(ofSize: 11)
        partField.target = self
        partField.action = #selector(copyPart)
        let partBtn = small("Copy part", #selector(copyPart))
        partBtn.toolTip = "Copy one part of the answer: a task number (2), a question id (A1) or a file name (Events.tsx)"
        partRow = NSStackView(views: [partField, partBtn])
        partRow.spacing = 6
        partRow.isHidden = true

        let stack = NSStackView(views: [dropView, subjectRow, modelPopup, row, partRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: fx.bottomAnchor, constant: -8),
            dropView.heightAnchor.constraint(equalToConstant: 30),
            dropView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subjectRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            partRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: answerH - 5 - 27),
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Drop")
            b.image?.isTemplate = true
            b.toolTip = "Drop – click to show/hide, right-click for menu"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateSubjectUI()
        registerHotKey()
        panel.orderFrontRegardless()
        setStatus(config.provider == "opencode_go" ? "Connecting to OpenCode Go…" : "Connecting to Ollama…")
        loadModels()
    }

    // ===== Settings (Phase 6): provider, API key, connection test =====
    var settingsWin: NSWindow?
    var keyField: NSSecureTextField!
    var baseField: NSTextField!
    var modelField: NSTextField!
    var contextField: NSTextField!
    var testStatus: NSTextField!

    // Benchmark mode (additive): own window, own state; normal generation is untouched.
    @MainActor @objc func openBenchmark() {
        if benchWC == nil {
            benchWC = BenchWindowController(config: { DropConfig.load() }, normalRunInProgress: { [weak self] in self?.running ?? false })
        }
        benchWC?.show()
    }

    @objc func openSettings() {
        if settingsWin == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 258),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Drop Settings"
            let stack = NSStackView(frame: NSRect(x: 12, y: 12, width: 356, height: 234))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8

            func labeled(_ label: String, _ field: NSView) -> NSView {
                let l = NSTextField(labelWithString: label)
                l.font = NSFont.systemFont(ofSize: 11)
                l.translatesAutoresizingMaskIntoConstraints = false
                let h = NSStackView(views: [l, field])
                h.orientation = .horizontal
                h.spacing = 6
                l.widthAnchor.constraint(equalToConstant: 90).isActive = true
                return h
            }

            baseField = NSTextField(string: config.provider == "ollama" ? config.ollamaBase : config.ocBase)
            keyField = NSSecureTextField(string: config.ocKey)
            keyField.placeholderString = "oc_… (OpenCode Go only)"
            modelField = NSTextField(string: config.ocModel)
            // Ollama-only context override (0 = hardware preset). Stored in the
            // ollama config section; OpenCode Go is unaffected by this field.
            contextField = NSTextField(string: "\(config.ollamaContext)")
            contextField.placeholderString = "0 = auto (RAM preset)"
            for f in [baseField!, keyField!, modelField!, contextField!] as [NSTextField] {
                f.translatesAutoresizingMaskIntoConstraints = false
                f.widthAnchor.constraint(equalToConstant: 250).isActive = true
            }

            let fallback = NSButton(checkboxWithTitle: "Offer Ollama fallback if OpenCode Go fails",
                                    target: self, action: #selector(fallbackToggled))
            fallback.state = config.allowFallback ? .on : .off
            let remember = NSButton(checkboxWithTitle: "Remember selected provider",
                                    target: self, action: #selector(rememberToggled))
            remember.state = config.rememberProvider ? .on : .off

            let testBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
            let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveSettings))
            let btnRow = NSStackView(views: [testBtn, saveBtn])
            btnRow.orientation = .horizontal
            btnRow.spacing = 8

            testStatus = NSTextField(labelWithString: "")
            testStatus.font = NSFont.systemFont(ofSize: 11)
            testStatus.lineBreakMode = .byTruncatingTail
            testStatus.maximumNumberOfLines = 2

            stack.addArrangedSubview(labeled("Base URL", baseField))
            stack.addArrangedSubview(labeled("API key", keyField))
            stack.addArrangedSubview(labeled("Model", modelField))
            stack.addArrangedSubview(labeled("Qwen ctx", contextField))
            stack.addArrangedSubview(fallback)
            stack.addArrangedSubview(remember)
            stack.addArrangedSubview(btnRow)
            stack.addArrangedSubview(testStatus)
            w.contentView?.addSubview(stack)
            settingsWin = w
        }
        // Prefill current values each time it opens
        baseField.stringValue = config.provider == "ollama" ? config.ollamaBase : config.ocBase
        keyField.stringValue = config.ocKey
        modelField.stringValue = config.ocModel
        contextField.stringValue = "\(config.ollamaContext)"
        NSApp.activate(ignoringOtherApps: true)
        settingsWin?.makeKeyAndOrderFront(nil)
    }

    @objc func fallbackToggled(_ s: NSButton) { config.allowFallback = (s.state == .on); config.save() }
    @objc func rememberToggled(_ s: NSButton) { config.rememberProvider = (s.state == .on); config.save() }

    @objc func saveSettings() {
        // Never wipe a stored key with an empty field (Phase 3).
        let newKey = keyField.stringValue
        if !newKey.isEmpty { config.ocKey = newKey }
        let newBase = baseField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newBase.isEmpty {
            if config.provider == "ollama" { config.ollamaBase = newBase } else { config.ocBase = newBase }
        }
        let newModel = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newModel.isEmpty && config.provider == "opencode_go" { config.ocModel = newModel }
        // Ollama context override (0 = hardware preset); never touches opencode_go.
        if let v = Int(contextField.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0 {
            config.ollamaContext = v
        }
        config.save()   // re-asserts 0600
        testStatus.stringValue = "Saved (key stored locally, 0600)"
        loadModels(startIfNeeded: true)
    }

    // Phase 6: Test Connection — real authenticated ping, key never displayed.
    @objc func testConnection() {
        saveSettings()
        let cfg = config
        testStatus.stringValue = "Testing…"
        Task { @MainActor in
            if cfg.provider == "ollama" {
                let o = OllamaProvider(config: cfg)
                guard await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase,
                                          timeout: cfg.connectTimeout) else {
                    testStatus.stringValue = "❌ Ollama could not be started"
                    return
                }
                if let names = await o.listModels(), !names.isEmpty {
                    testStatus.stringValue = "✅ Ollama OK – \(names.count) model(s)"
                } else {
                    testStatus.stringValue = "❌ Ollama not reachable at \(cfg.ollamaBase)"
                }
            } else {
                if cfg.ocKey.isEmpty {
                    testStatus.stringValue = "❌ Enter an API key first"
                    return
                }
                // Tiny real request proves endpoint + key + model together.
                // Single attempt, connect_timeout budget: a blocked network
                // should fail the TEST quickly instead of sitting in retries.
                var testCfg = cfg
                testCfg.retryAttempts = 1
                testCfg.streamIdleTimeout = cfg.connectTimeout
                testCfg.sessionId = UUID().uuidString   // the test is its own conversation
                testCfg.ocStream = false                // exact baseline request (verified 200 OK)
                let oc = OpenCodeGoProvider(config: testCfg)
                let out = await oc.generate(prompt: "Reply with exactly: Drop connection successful",
                                            model: cfg.ocModel, label: "Testing",
                                            onChunk: { _ in }, onStatus: { _ in })
                switch out {
                case .ok(let a):
                    testStatus.stringValue = "✅ OpenCode Go OK – \(a.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))"
                case .interrupted:
                    testStatus.stringValue = "✅ OpenCode Go OK (stream ended early)"
                case .failed(let e):
                    testStatus.stringValue = "❌ \(e.displayMessage)"
                }
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func setStatus(_ s: String) { dropView.subtitle = s }

    // Provider-aware discovery: Ollama hits localhost /api/tags; OpenCode Go hits
    // GET {base}/models with the stored key. No cross-talk: each path only talks
    // to its own endpoint (Phase 5: no localhost:11434 requests when OpenCode selected).
    func loadModels(startIfNeeded: Bool = false) {
        let provider = activeProvider
        let cfg = config
        Task { @MainActor in
            if provider.id == "opencode_go" && cfg.ocKey.isEmpty {
                modelPopup.removeAllItems()
                modelPopup.addItem(withTitle: cfg.ocModel)
                setStatus("⚠️ No OpenCode API key – open Settings (gear in tray)")
                return
            }
            // On-demand Ollama start — never while OpenCode is selected (the
            // branch above returns first). Startup passes startIfNeeded:false
            // (probe only).
            if provider.id == "ollama" {
                guard await prepareOllama(startIfNeeded: startIfNeeded, base: cfg.ollamaBase,
                                          timeout: cfg.connectTimeout) else {
                    modelPopup.removeAllItems()
                    setStatus("⚠️ Ollama not running and could not be started")
                    return
                }
            }
            var names: [String]? = nil
            modelPopup.removeAllItems()
            // Ollama: only installed Qwen-family models (discovered from
            // /api/tags — never a hardcoded name). The dropdown shows metadata
            // labels (name · size · quant); the saved/sent value stays the
            // plain model name. OpenCode Go list handling unchanged.
            var labelMap: [String: String] = [:]
            let list: [String]
            if provider.id == "ollama" {
                let details = await OllamaProvider(config: cfg).listModelDetails()
                for d in details ?? [] { labelMap[d.label] = d.name }
                list = (details ?? []).map { $0.label }
                names = details?.map { $0.name }
            } else {
                names = await provider.listModels()
                list = (names?.isEmpty == false) ? names! : [cfg.ocModel]
            }
            self.modelLabelsToNames = labelMap
            modelPopup.addItems(withTitles: list)
            let savedKey = provider.id == "ollama" ? "model" : "oc_model"
            var missingSaved: String? = nil
            if provider.id == "ollama", let saved = UserDefaults.standard.string(forKey: savedKey),
               let idx = list.firstIndex(where: { self.resolvedModelName(from: $0) == saved }) {
                modelPopup.selectItem(at: idx)
            } else if provider.id == "ollama" {
                // Saved model no longer installed → never select a model that
                // does not exist; fall back to an existing one (or leave the
                // dropdown empty when no Qwen model is installed at all).
                if let saved = UserDefaults.standard.string(forKey: "model"), !saved.isEmpty, !list.isEmpty {
                    missingSaved = saved
                }
                if !list.isEmpty { modelPopup.selectItem(at: 0) }
            } else if provider.id == "opencode_go", let m = list.first(where: { $0 == cfg.ocModel }) {
                modelPopup.selectItem(withTitle: m)
            }
            if provider.id == "opencode_go" {
                setStatus(names != nil ? "OpenCode Go ready · \(list.count) model(s)" : "OpenCode Go · \(cfg.ocModel)")
            } else if names == nil {
                setStatus("⚠️ Ollama not running – open the Ollama app")
            } else if list.isEmpty {
                setStatus("⚠️ No Qwen models installed – ollama pull a Qwen model first")
            } else if let m = missingSaved {
                setStatus("⚠️ Saved model “\(m)” not installed · using “\(list[0])”")
            } else {
                setStatus("Ready · click to choose files")
            }
        }
    }

    // Dropdown titles may be metadata labels ("name · size · quant"); the
    // saved and sent model is always the plain name behind the label.
    var modelLabelsToNames: [String: String] = [:]
    func resolvedModelName(from title: String?) -> String? {
        guard let t = title, !t.isEmpty else { return nil }
        return modelLabelsToNames[t] ?? t
    }

    @objc func modelChanged() {
        let key = config.provider == "ollama" ? "model" : "oc_model"
        let name = resolvedModelName(from: modelPopup.titleOfSelectedItem)
        UserDefaults.standard.set(name, forKey: key)
        if config.provider == "opencode_go", let m = name {
            config.ocModel = m
            config.save()
        } else if config.provider == "ollama", let m = name {
            // Mirror the selection into config (local file, same 0600 rules).
            config.ollamaDefaultModel = m
            config.save()
        }
    }

    // Phase 6: toggle button in the popup switches provider; never silent — user clicks.
    @objc func toggleProvider() {
        guard !running else { setStatus("⏳ Busy – wait before switching"); return }
        config.provider = config.provider == "ollama" ? "opencode_go" : "ollama"
        if config.rememberProvider { config.save() }
        providerBtn.title = config.provider == "ollama" ? "🦙 Ollama" : "☁️ OpenCode"
        modelPopup.removeAllItems()
        // Ollama items arrive from loadModels() a moment later (discovered
        // Qwen models only); OpenCode Go keeps its configured model.
        if config.provider != "ollama" { modelPopup.addItem(withTitle: config.ocModel) }
        setStatus(config.provider == "ollama" ? "Ollama selected · local only"
                                              : "OpenCode Go selected · cloud")
        loadModels(startIfNeeded: true)
    }

    @objc func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.level = .modalPanel
        if open.runModal() == .OK { dispatchSubject(open.urls) }
    }

    @objc func copyAgain() {
        let answer = currentAnswer(for: subject)   // OOP: exactly lastAnswer as before
        if answer.isEmpty { return }
        copyToClipboard(answer)
        setStatus("📋 Copied again · paste with ⌘V")
    }

    @objc func toggleAnswer() {
        expanded.toggle()
        scroll.isHidden = !expanded
        partRow.isHidden = !expanded
        expandBtn.title = expanded ? "Share ▴" : "Share ▾"
        var f = panel.frame
        let h = expanded ? compactH + answerH : compactH
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func hidePanel() { panel.orderOut(nil) }

    @objc func toggleDoubleCheck() {
        let cur = UserDefaults.standard.object(forKey: "doubleCheck") as? Bool ?? false
        UserDefaults.standard.set(!cur, forKey: "doubleCheck")
        setStatus(!cur ? "Double-check on" : "Double-check off")
    }

    // Control + Option + D shows / hides the popup from anywhere; the other
    // IntelliJ-workflow hotkeys dispatch by EventHotKeyID id (plan
    // docs/superpowers/plans/2026-11-18-intellij-hotkeys.md):
    // 1 = ⌃⌥D toggle, 2 = ⌃⌥R OOP run, 3 = ⌃⌥C copy-all, 4…13 = ⌃⌥1…9,0 task copy.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                switch hkID.id {
                case 1: me.togglePanel()
                case 2: if me.hotkeyGateAllowed { me.oopRunHotkey() }
                case 3: if me.hotkeyGateAllowed { me.copyAllHotkey() }
                case 4...13: if me.hotkeyGateAllowed { me.copyTaskHotkey(Int(hkID.id - 3)) }
                default: break
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let mods = UInt32(controlKey | optionKey)
        let bindings: [(UInt32, UInt32)] = [
            (UInt32(kVK_ANSI_D), 1), (UInt32(kVK_ANSI_R), 2),
            (UInt32(kVK_ANSI_C), 3), (UInt32(kVK_ANSI_1), 4), (UInt32(kVK_ANSI_2), 5),
            (UInt32(kVK_ANSI_3), 6), (UInt32(kVK_ANSI_4), 7), (UInt32(kVK_ANSI_5), 8),
            (UInt32(kVK_ANSI_6), 9), (UInt32(kVK_ANSI_7), 10), (UInt32(kVK_ANSI_8), 11),
            (UInt32(kVK_ANSI_9), 12), (UInt32(kVK_ANSI_0), 13)
        ]
        for (kc, hid) in bindings {
            let id = EventHotKeyID(signature: OSType(0x44524F50), id: hid)
            RegisterEventHotKey(kc, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            // Refresh the Qwen list when shown (newly installed / removed models
            // are picked up). Ollama-only: OpenCode Go never gets extra traffic.
            if config.provider == "ollama" && !running { loadModels(startIfNeeded: true) }
        }
    }

    // Frontmost gate for the IntelliJ-workflow hotkeys (⌃⌥R/C/1-0): they act
    // only while IntelliJ IDEA or Drop itself is frontmost; presses elsewhere
    // are ignored. ⌃⌥D stays global and ungated.
    var hotkeyGateAllowed: Bool {
        if let front = NSWorkspace.shared.frontmostApplication {
            if front.bundleIdentifier == "com.jetbrains.intellij" { return true }
            if (front.localizedName ?? "").contains("IntelliJ") { return true }
        }
        // Drop itself: the panel is .nonactivatingPanel (shown with
        // orderFrontRegardless), so it can be key while NSApp.isActive is
        // false and frontmostApplication still names the other app — check
        // key-window too, or ⌃⌥C/1-0 are ignored while the popup is key.
        if NSApp.isActive { return true }
        return NSApp.windows.contains(where: { $0.isKeyWindow })
    }

    // ⌃⌥R: read Desktop/OOP and start the run — headless, never opens the
    // panel (the user opens it manually with ⌃⌥D to watch progress).
    @objc func oopRunHotkey() {
        guard !running else { setStatus("⏳ Busy – wait for the current answer"); return }
        let oop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OOP")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: oop.path, isDirectory: &isDir),
              isDir.boolValue else {
            setStatus("⚠️ OOP folder not found on Desktop"); return
        }
        handle([oop])   // handle() never opens the panel
    }

    // ⌃⌥C: copy the full last answer (same clipboard path as the Copy button).
    @objc func copyAllHotkey() {
        guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
        copyToClipboard(lastAnswer)
        setStatus("📋 Answer copied · paste with ⌘V")
    }

    // ⌃⌥1…0: copy just Task N's section of the last answer, so each task can
    // be pasted into IntelliJ separately.
    @objc func copyTaskHotkey(_ n: Int) {
        guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
        guard let slice = AppDelegate.taskSection(lastAnswer, n: n) else {
            setStatus("⚠️ Task \(n) not found in answer"); return
        }
        copyToClipboard(slice)
        setStatus("✅ Task \(n) copied · paste with ⌘V")
    }

    // Slice "…// ===== Task N ===== …" up to (excluding) the next Task header.
    // hasPrefix("// ===== Task 1 =====") cannot match a Task 10 header, so N=1
    // is safe. Extracted verbatim by the task-section behavior test.
    static func taskSection(_ answer: String, n: Int) -> String? {
        let lines = answer.components(separatedBy: "\n")
        let header = "// ===== Task \(n) ====="
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(header)
        }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count
        where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("// ===== Task ") {
            end = i
            break
        }
        let slice = lines[start..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slice.isEmpty ? nil : slice
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            let show = NSMenuItem(title: "Show / Hide", action: #selector(togglePanel), keyEquivalent: "")
            show.target = self
            m.addItem(show)
            let copy = NSMenuItem(title: "Copy last answer", action: #selector(copyAgain), keyEquivalent: "")
            copy.target = self
            m.addItem(copy)
            let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            m.addItem(settings)
            let bench = NSMenuItem(title: "Benchmark…", action: #selector(openBenchmark), keyEquivalent: "")
            bench.target = self
            m.addItem(bench)
            let care = NSMenuItem(title: "ACD careful mode (thinking, slower)", action: #selector(toggleCareful), keyEquivalent: "")
            care.target = self
            care.state = AcdSettings.careful ? .on : .off
            care.toolTip = "Off (default): fast, one question per request, no thinking. On: the model thinks before free-form answers; much slower on an 8 GB Mac."
            m.addItem(care)
            let pt = NSMenuItem(title: "OOP per-task generation (experimental)", action: #selector(toggleOopPerTask), keyEquivalent: "")
            pt.target = self
            pt.state = AcdSettings.oopPerTask ? .on : .off
            pt.toolTip = "Popup OOP run only (not the hotkeys). One request per task instead of one for the whole paper. Off by default: measured slower on an 8 GB Mac."
            m.addItem(pt)
            let tool = NSMenuItem(title: "Prepare ACD toolchain…", action: #selector(prepareToolchain), keyEquivalent: "")
            tool.target = self
            m.addItem(tool)
            m.addItem(.separator())
            let q = NSMenuItem(title: "Quit Drop", action: #selector(quit), keyEquivalent: "q")
            q.target = self
            m.addItem(q)
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    func extractText(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string ?? "" }
        if ["txt", "java", "md", "csv"].contains(ext) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Reads a file, or every useful text file inside a folder (e.g. a starter project)
    func collect(_ url: URL) -> (String, Int) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            if url.pathExtension.lowercased() == "zip" { return collectZip(url) }
            return ("\n===== FILE: \(url.lastPathComponent) =====\n" + extractText(url), 1)
        }
        var zips: [URL] = []
        var docs = ""
        var code = ""
        var count = 0
        var total = 0
        let base = url.path
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return ("", 0) }
        for case let f as URL in en {
            let vals = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                if SKIP_DIRS.contains(f.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if (vals?.fileSize ?? 0) > 150_000 || f.lastPathComponent.hasPrefix("~$") { continue }
            let ext = f.pathExtension.lowercased()
            if ext == "zip" { zips.append(f); continue }
            var text = ""
            if TEXT_EXT.contains(ext) {
                text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            } else if ["pdf", "docx", "doc", "rtf"].contains(ext) {
                text = extractText(f)
            } else { continue }
            if text.isEmpty { continue }
            total += text.count
            if total > 400_000 { code += "\n[... more files skipped: project too large ...]\n"; break }
            let rel = f.path.hasPrefix(base + "/") ? String(f.path.dropFirst(base.count + 1)) : f.lastPathComponent
            if ext == "java", let r = rel.range(of: "src/main/java/") { starterFiles[String(rel[r.lowerBound...])] = text }
            let chunk = "\n===== FILE: \(rel) =====\n" + text
            if ["pdf", "docx", "doc", "rtf", "md", "txt"].contains(ext) { docs += chunk } else { code += chunk }
            count += 1
        }
        // No unzipped project in the folder? Read the starter ZIP instead.
        if code.isEmpty {
            for z in zips {
                let (t, n) = collectZip(z)
                code += t
                count += n
            }
        }
        let paper = docs.isEmpty ? "" : "\n######## EXAM PAPER / INSTRUCTIONS ########\n" + docs
        let project = code.isEmpty ? "" : "\n######## STARTER PROJECT FILES ########\n" + code
        return (paper + project, count)
    }

    func collectZip(_ zip: URL) -> (String, Int) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return ("", 0) }
        let (text, n) = collect(tmp)
        try? FileManager.default.removeItem(at: tmp)
        return (text, n)
    }

    func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func stripFences(_ s: String) -> String { AppDelegate.stripFencesText(s) }
    static func stripFencesText(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The OOP entry used by the hotkeys and the original popup flow: ONE request for the whole paper, exactly as before.
    func handle(_ urls: [URL]) { handleOOP(urls, perTask: false) }

    /// perTask == true (visible popup run, Ollama only): one request per task. perTask == false is byte-for-byte the original behaviour.
    func handleOOP(_ urls: [URL], perTask: Bool) {
        if running { setStatus("⏳ Busy – wait for the current answer"); return }
        starterFiles = [:]
        var paper = ""
        var fileCount = 0
        for f in urls {
            let (text, n) = collect(f)
            paper += text
            fileCount += n
        }
        if paper.split(whereSeparator: { $0.isWhitespace }).count < 15 {
            setStatus(fileCount == 0 ? "⚠️ macOS blocked reading – allow Drop in Privacy settings"
                                      : "⚠️ No readable text (scanned PDF?)")
            return
        }
        // The popup only ever holds models that exist (Ollama: installed Qwen
        // models; OpenCode: configured model) — never send a nonexistent one.
        // Labels resolve back to the plain model name before sending.
        guard let model = resolvedModelName(from: modelPopup.titleOfSelectedItem), !model.isEmpty else {
            setStatus(config.provider == "ollama"
                      ? "⚠️ No Qwen model installed – ollama pull a Qwen model first"
                      : "⚠️ No model selected")
            return
        }
        // New conversation → new x-opencode-session id, reused by every
        // request of this run (prompt, repair rounds, retries).
        config.sessionId = UUID().uuidString
        // Size the output cap from the RAW paper (the prompt head's own
        // "Task 1" examples must not inflate the count). Bounded so one run
        // can never grind for hours; a cut answer is completed by repair.
        config.numPredict = Self.numPredict(forPaper: paper)
        running = true
        textView.string = ""
        dropView.title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        // Prompt fork (Ollama: student-level rules; OpenCode: pinned PROMPT_HEADER) now
        // lives in DropPipeline.run — the same code the benchmark uses.
        if !paper.contains(".java =====") {
            setStatus("⚠️ No Java starter found · thinking anyway…")
        } else {
            setStatus("⏳ Read \(fileCount) file(s) · thinking…")
        }
        let starter = self.starterFiles
        let providerId = config.provider
        Task { @MainActor in
            defer { self.running = false; self.dropView.title = "Drop to share" }
            var session: AcdOllamaSession?
            var taskPlan: OopPerTask.Plan?
            // Ollama, Careful mode off (the default): one request WITHOUT thinking through the small-context, memory-aware session.
            // The original thinking request spent its token budget thinking on this hardware (empty answer, or ~10 min and still no compile).
            // perTask (opt-in) writes the answer task by task instead. Careful mode on = the original single thinking request, unchanged.
            let wantPerTask = perTask && providerId == "ollama"
            let wantFast = providerId == "ollama" && !AcdSettings.careful
            if wantPerTask || wantFast,
               await prepareOllama(startIfNeeded: true, base: self.config.ollamaBase, timeout: self.config.connectTimeout, onStatus: { self.setStatus($0) }) {
                let s = AcdOllamaSession(config: self.config, model: model)
                s.onProgress = { p in DispatchQueue.main.async { self.setStatus("⏳ " + p) } }
                session = s
                if wantPerTask { taskPlan = OopPerTask.plan(paperBlock: paper) }
            }
            let hooks = PipelineHooks(
                generate: { prompt, label in
                    if let s = session {
                        let first = label == "✍️ Writing"
                        if first, let plan = taskPlan {
                            return await OopPerTask.writeAnswer(plan: plan, careful: AcdSettings.careful,
                                                                generate: { req in await self.oopSessionRequest(s, req) }, status: { self.setStatus($0) })
                        }
                        var out = await self.oopSessionRequest(s, AcdRequest(prompt: prompt, label: label, kind: first ? "whole" : "repair",
                                                                             numPredict: first ? max(self.config.numPredict, 4096) : 4000, temperature: 0.2, think: false))
                        if first, (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let plan = OopPerTask.plan(paperBlock: paper) {
                            out = await OopPerTask.writeAnswer(plan: plan, careful: false, generate: { req in await self.oopSessionRequest(s, req) }, status: { self.setStatus($0) })
                        }
                        return out
                    }
                    let r = await self.generate(prompt: prompt, model: model, label: label)
                    if r == nil, providerId == "ollama", self.lastFailureMessage.contains("no answer produced") {
                        return await self.oopThinkingFallback(prompt: prompt, label: label, model: model, paper: paper, firstRequest: label == "✍️ Writing")
                    }
                    return r
                },
                compile: { answer in await self.compileErrors(answer) },
                status: { self.setStatus($0) },
                resetOutput: { self.textView.string = "" })
            let pipelineResult = await DropPipeline.run(paper: paper, provider: providerId, starter: starter, hooks: hooks)
            if let s = session { await s.release() }            // quiet laptop: nothing stays loaded
            guard let result = pipelineResult else { return }
            let compiled = result.compiled
            self.lastAnswer = result.answer
            self.textView.string = self.lastAnswer
            self.copyToClipboard(self.lastAnswer)
            NSSound(named: NSSound.Name("Glass"))?.play()
            switch compiled {
            case .some(true): self.setStatus("✅ Copied! Compiles · paste with ⌘V")
            case .some(false): self.setStatus("⚠️ Copied, but still has compile errors – check IntelliJ")
            case .none: self.setStatus(self.starterFiles.isEmpty ? "✅ Copied! (no starter to compile against)"
                                                                 : "⚠️ Copied – couldn't compile-check (no JDK/Spring found)")
            }
        }
    }

    func compileErrors(_ answer: String) async -> String? {
        let files = starterFiles
        if files.isEmpty { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            return AppDelegate.runJavac(answer: answer, starter: files)
        }.value
    }

    // ---- Ollama student-quality helpers (never used on the OpenCode path) ----

    // Base file names javac implicated ("Foo.java:12: error:" lines).
    static func errorFileNames(_ errs: String) -> Set<String> {
        var names = Set<String>()
        let re = try? NSRegularExpression(pattern: #"([A-Za-z0-9_$.]+\.java):\d+"#)
        let ns = NSRange(errs.startIndex..., in: errs)
        for m in (re?.matches(in: errs, range: ns) ?? []) {
            if let r = Range(m.range(at: 1), in: errs) { names.insert(String(errs[r])) }
        }
        return names
    }

    // Targeted repair context (Ollama only): the sources javac implicated, each
    // COMPLETE, plus the sources they reference (simple-name matching) — never
    // the full question, never unchanged answer files. Falls back to all answer
    // files when the error lines name nothing.
    static func repairContext(answer: String, starter: [String: String], errs: String) -> String {
        var sources = starter
        for (k, v) in parseAnswerFiles(answer) { sources[k] = AppDelegate.ensureUtilImport(v) }
        let names = errorFileNames(errs)
        var affected = sources.keys.filter { names.contains(($0 as NSString).lastPathComponent) }
        if affected.isEmpty { affected = Array(parseAnswerFiles(answer).keys) }
        var out: [String] = []
        var seen = Set<String>()
        var referenced = Set<String>()
        for k in affected.sorted() {
            guard let body = sources[k] else { continue }
            out.append("// ===== FILE: " + k + " =====")
            out.append(body)
            seen.insert(k)
            for sk in sources.keys where !seen.contains(sk) {
                let cls = ((sk as NSString).lastPathComponent as NSString).deletingPathExtension
                if !cls.isEmpty && body.contains(cls) { referenced.insert(sk) }
            }
        }
        var total = out.joined(separator: "\n").count
        for k in referenced.sorted() {
            guard let body = sources[k], total + body.count < 40000 else { continue }
            out.append("// ===== FILE: " + k + " =====")
            out.append(body)
            seen.insert(k)
            total += body.count
        }
        return out.joined(separator: "\n")
    }

    // nil = could not check (no JDK / no Spring jars in ~/.m2), "" = compiles, otherwise javac errors.
    // Every round compiles the FULL source set and returns javac's complete output:
    // partial subsets gave the repair model noisy partial error sets.
    static func runJavac(answer: String, starter: [String: String]) -> String? {
        let fm = FileManager.default
        let jh = Process()
        jh.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let jp = Pipe()
        jh.standardOutput = jp
        jh.standardError = Pipe()
        do { try jh.run() } catch { return nil }
        let homeData = jp.fileHandleForReading.readDataToEndOfFile()
        jh.waitUntilExit()
        let home = (String(data: homeData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if jh.terminationStatus == 0 && !home.isEmpty { candidates.append(home + "/bin/javac") }
        let userHome = fm.homeDirectoryForCurrentUser.path
        for dir in [userHome + "/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"] {
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed() {
                candidates.append(dir + "/" + name + "/Contents/Home/bin/javac")
            }
        }
        for app in ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []) where app.hasPrefix("IntelliJ") {
            candidates.append("/Applications/" + app + "/Contents/jbr/Contents/Home/bin/javac")
        }
        candidates += ["/opt/homebrew/opt/openjdk/bin/javac", "/usr/local/opt/openjdk/bin/javac"]
        guard let javac = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }

        let m2 = fm.homeDirectoryForCurrentUser.appendingPathComponent(".m2/repository")
        var jars: [String] = []
        for sub in ["org/springframework", "jakarta", "com/fasterxml/jackson"] {
            if let en = fm.enumerator(at: m2.appendingPathComponent(sub), includingPropertiesForKeys: nil) {
                for case let f as URL in en where f.pathExtension == "jar" {
                    let n = f.lastPathComponent
                    if !n.contains("sources") && !n.contains("javadoc") { jars.append(f.path) }
                }
            }
        }
        if !jars.contains(where: { $0.contains("spring-web") }) { return nil }

        let tmp = fm.temporaryDirectory.appendingPathComponent("dropc-" + UUID().uuidString)
        var sources = starter
        for (k, v) in parseAnswerFiles(answer) { sources[k] = AppDelegate.ensureUtilImport(v) }
        var paths: [String] = []
        for (k, v) in sources {
            let u = tmp.appendingPathComponent(k)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? v.write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        let out = tmp.appendingPathComponent("out")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: javac)
        var args = ["--release", "17", "-proc:none", "-nowarn", "-encoding", "UTF-8",
                    "-d", out.path, "-cp", jars.joined(separator: ":")]
        // Sources stay reachable through -sourcepath. The root
        // must be the PACKAGE root (src/main/java), not the tmp root — javac
        // resolves `edu.a.B` to <root>/edu/a/B.java. The bare tmp root is kept
        // as a second entry for flat layouts.
        args += ["-sourcepath", tmp.path + "/src/main/java:" + tmp.path]
        args += paths
        p.arguments = args
        let ep = Pipe()
        p.standardError = ep
        p.standardOutput = ep
        do { try p.run() } catch { return nil }
        let data = ep.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        if p.terminationStatus == 0 { return "" }
        let text = String(data: data, encoding: .utf8) ?? "compile failed"
        return text.replacingOccurrences(of: tmp.path + "/", with: "")
    }

    static func sections(_ text: String) -> [(String?, [String])] {
        var res: [(String?, [String])] = [(nil, [])]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("// =====") {
                res.append((line, []))
            } else {
                res[res.count - 1].1.append(line)
            }
        }
        return res
    }

    static func fileName(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.hasPrefix("// ===== FILE:") else { return nil }
        let rest = String(h.dropFirst("// ===== FILE:".count)).trimmingCharacters(in: .whitespaces)
        guard let path = rest.components(separatedBy: " ").first, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    // Gives every @PathVariable / @RequestParam an explicit name: @PathVariable long id -> @PathVariable("id") long id
    static func nameRequestParams(_ code: String) -> String {
        guard let re = try? NSRegularExpression(pattern:
            "@(PathVariable|RequestParam)(\\(([^)]*)\\))?(\\s+)(final\\s+)?([\\w.<>\\[\\],?]+)\\s+(\\w+)") else { return code }
        var out = code as NSString
        let matches = re.matches(in: code, range: NSRange(location: 0, length: out.length))
        for m in matches.reversed() {
            let ns = out
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let ann = g(1), let space = g(4), let type = g(6), let name = g(7) else { continue }
            let fin = g(5) ?? ""
            var newAnn: String
            if let args = g(3) {
                let a = args.trimmingCharacters(in: .whitespaces)
                if a.isEmpty { newAnn = "@\(ann)(\"\(name)\")" }
                else if a.hasPrefix("\"") || a.contains("name") || a.contains("value") { continue }
                else { newAnn = "@\(ann)(name = \"\(name)\", \(a))" }
            } else {
                newAnn = "@\(ann)(\"\(name)\")"
            }
            let replacement = newAnn + space + fin + type + " " + name
            out = ns.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return out as String
    }

    // If the RELEASE_OUTSIDE_WINDOW check comes straight before the DEADLINE check, swap them (DEADLINE must win)
    static func fixReasonOrder(_ code: String) -> String {
        let pattern = #"(if \([^{]*\)\s*\{[^{}]*"RELEASE_OUTSIDE_WINDOW"[^{}]*\})(\s*)(if \([^{]*\)\s*\{[^{}]*"DEADLINE"[^{}]*\})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return code }
        return re.stringByReplacingMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length),
                                           withTemplate: "$3$2$1")
    }

    // A controller method whose body is just "return service.x(...)" must return exactly the type that
    // service method returns (e.g. DispatchMission, not AirMission). Fixes the return type automatically.
    static func alignControllerReturns(_ answer: String, starter: [String: String]) -> String {
        // 1) return types of the service's public methods (answer copy first, starter as fallback)
        var serviceTypes: [String: String] = [:]
        guard let sig = try? NSRegularExpression(pattern: "public\\s+([A-Za-z0-9_<>, ?\\[\\]]+?)\\s+([a-zA-Z0-9_]+)\\s*\\(") else { return answer }
        func collect(_ text: String) {
            let ns = text as NSString
            for m in sig.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let type = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let name = ns.substring(with: m.range(at: 2))
                if type == "class" || type.hasSuffix(" class") { continue }
                if serviceTypes[name] == nil { serviceTypes[name] = type }
            }
        }
        for sec in sections(answer) {
            if let n = fileName(sec.0), n.hasSuffix("Service.java") { collect(sec.1.joined(separator: "\n")) }
        }
        for (path, text) in starter where path.hasSuffix("Service.java") { collect(text) }
        if serviceTypes.isEmpty { return answer }
        // 2) in controller files, fix "public T m(...) { return svc.x(...)" when T differs from x's type
        guard let ctl = try? NSRegularExpression(pattern:
            "(public\\s+)([A-Za-z0-9_<>, ?\\[\\]]+?)(\\s+[a-zA-Z0-9_]+\\s*\\([^)]*\\)\\s*\\{\\s*return\\s+[a-zA-Z0-9_]+\\.)([a-zA-Z0-9_]+)\\s*\\(") else { return answer }
        var out: [String] = []
        var inController = false
        for sec in sections(answer) {
            if let h = sec.0 {
                out.append(h)
                inController = (fileName(h) ?? "").hasSuffix("Controller.java")
            }
            var body = sec.1.joined(separator: "\n")
            if inController {
                let ns = body as NSString
                for m in ctl.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let have = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    let call = ns.substring(with: m.range(at: 4))
                    guard let want = serviceTypes[call], want != have else { continue }
                    if have.hasPrefix("ResponseEntity") || have.hasPrefix("Map") || want == "void" { continue }
                    body = (body as NSString).replacingCharacters(in: m.range(at: 2), with: want)
                }
            }
            if !sec.1.isEmpty { out.append(body) }
        }
        return out.joined(separator: "\n")
    }

    // The prompt head forbids the model from writing a HOW TO TEST section, so
    // Drop appends one deterministically at finalize (Ollama only): numbered
    // curl lines for the real Spring mappings, or a javac/java recipe for plain
    // Java. Every line is a "//" comment, so the pasted answer stays pure code.
    static func howToTestBlock(_ answer: String, starter: [String: String] = [:], paper: String = "") -> String {
        // Strip any model-written HOW TO TEST block first (the head forbids one,
        // but a stray block must never survive into the final answer).
        var base = answer
        if let m = base.range(of: "// ===== HOW TO TEST") {
            var cut = base.endIndex
            if let next = base.range(of: "\n// ===== FILE:", range: m.upperBound..<base.endIndex) {
                cut = next.lowerBound
            }
            base = String(base[..<m.lowerBound]) + String(base[cut...])
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)

        // File bodies from the answer's FILE sections (what the student pastes is what we document).
        var files: [(String, String)] = []
        for sec in sections(base) {
            if let n = fileName(sec.0) { files.append((n, sec.1.joined(separator: "\n"))) }
        }

        // record/class shapes may live in the STARTER (e.g. a DTO record the answer only uses): look there too when sampling JSON
        let lookup: [(String, String)] = files + starter.sorted { $0.key < $1.key }.compactMap { k, v in files.contains(where: { $0.0 == (k as NSString).lastPathComponent }) ? nil : ((k as NSString).lastPathComponent, v) }
        func sample(_ type: String) -> String {
            let t = type.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("boolean") || t.hasPrefix("Boolean") { return "true" }
            if t.hasPrefix("String") { return "\"abc\"" }
            if t.hasPrefix("LocalDateTime") { return "\"2026-01-01T09:00:00\"" }
            if t.hasPrefix("LocalDate") { return "\"2026-01-01\"" }
            if t.hasPrefix("List") || t.hasPrefix("Set") || t.hasSuffix("[]") { return "[]" }
            return "1"
        }
        func jsonFor(_ type: String, depth: Int = 0) -> String {
            // Depth-capped: a self-referential DTO must never crash the finalize.
            if depth >= 3 { return "{}" }
            let t = type.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("int") || t.hasPrefix("long") || t.hasPrefix("double") || t.hasPrefix("float")
                || t.hasPrefix("Integer") || t.hasPrefix("Long") || t.hasPrefix("Double")
                || t.hasPrefix("boolean") || t.hasPrefix("Boolean") || t.hasPrefix("String")
                || t.hasPrefix("LocalDate") || t.hasPrefix("List") || t.hasPrefix("Set") || t.hasSuffix("[]") {
                return sample(t)
            }
            for (_, body) in lookup {
                let ns = body as NSString
                let full = NSRange(location: 0, length: ns.length)
                let esc = NSRegularExpression.escapedPattern(for: t)
                // record Foo(Type a, Type b)
                if let re = try? NSRegularExpression(pattern: "record\\s+" + esc + "\\s*\\(([^)]*)\\)"),
                   let m = re.firstMatch(in: body, range: full) {
                    var pairs: [String] = []
                    for c in ns.substring(with: m.range(at: 1)).components(separatedBy: ",") {
                        let parts = c.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").filter { !$0.isEmpty }
                        if parts.count >= 2 { pairs.append("\"\(parts[1])\": \(jsonFor(parts[0], depth: depth + 1))") }
                    }
                    if !pairs.isEmpty { return "{" + pairs.joined(separator: ", ") + "}" }
                }
                // class Foo { private Type name; ... }
                if body.range(of: "(?:class|record)\\s+" + esc + "\\b", options: .regularExpression) != nil,
                   let re = try? NSRegularExpression(pattern: "(?:private|protected)\\s+(?:final\\s+)?([A-Za-z0-9_<>, \\[\\]]+?)\\s+(\\w+)\\s*[;=]") {
                    var pairs: [String] = []
                    for m in re.matches(in: body, range: full) {
                        let ftype = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                        if ftype == "static" { continue }
                        pairs.append("\"\(ns.substring(with: m.range(at: 2)))\": \(jsonFor(ftype, depth: depth + 1))")
                    }
                    if !pairs.isEmpty { return "{" + pairs.joined(separator: ", ") + "}" }
                }
            }
            return "{}"
        }

        // The deterministic block itself.
        var lines: [String] = ["", "// ===== HOW TO TEST ====="]
        let isSpring = files.contains { $0.1.range(of: "@(Rest)?Controller|@(Get|Post|Put|Delete|Patch|Request)Mapping", options: .regularExpression) != nil }
        if isSpring {
            lines.append("// 1. Start the app: mvn spring-boot:run")
            var port = "8080"
            for (_, body) in files {
                if let re = try? NSRegularExpression(pattern: "server\\.port\\s*=\\s*(\\d+)"),
                   let m = re.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                    port = (body as NSString).substring(with: m.range(at: 1))
                }
            }
            // the starter's application.properties is part of the paper block: use its real port
            if port == "8080", let re = try? NSRegularExpression(pattern: "server\\.port\\s*=\\s*(\\d+)"),
               let m = re.firstMatch(in: paper, range: NSRange(location: 0, length: (paper as NSString).length)) { port = (paper as NSString).substring(with: m.range(at: 1)) }
            // the paper's own "REST operations to demonstrate" calls (real ids, real JSON) beat synthesised ones
            let demo = paperDemoCalls(paper)
            var step = 2
            if !demo.isEmpty {
                for d in demo {
                    var line = "// \(step). Try it: curl -X \(d.verb) 'http://localhost:\(port)\(d.path)'"
                    if !d.json.isEmpty { line += " -H \"Content-Type: application/json\" -d '\(d.json)'" }
                    lines.append(line); step += 1
                }
            }
            for (_, body) in (demo.isEmpty ? files : []) {
                let ns = body as NSString
                let full = NSRange(location: 0, length: ns.length)
                guard body.range(of: "@(GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping|RequestMapping)", options: .regularExpression) != nil else { continue }
                var classLoc = ns.range(of: "class ").location
                if classLoc == NSNotFound { classLoc = 0 }
                // class-level @RequestMapping prefix (must come before the class keyword)
                var prefix = ""
                if let re = try? NSRegularExpression(pattern: "@RequestMapping\\(\\s*(?:(?:value|name)\\s*=\\s*)?\"([^\"]*)\""),
                   let m = re.firstMatch(in: body, range: NSRange(location: 0, length: classLoc)) {
                    prefix = ns.substring(with: m.range(at: 1))
                }
                let inner = NSRange(location: classLoc, length: full.length - classLoc)
                var hits: [(String, String, NSRange)] = []
                if let re = try? NSRegularExpression(pattern: "@(GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping)\\s*(?:\\(\\s*(?:(?:value|name)\\s*=\\s*)?\"([^\"]*)\"|\\(\\s*\\{\\s*\"([^\"]*)\")?") {
                    for m in re.matches(in: body, range: inner) {
                        // GetMapping -> Get -> GET: curl needs the HTTP verb, never
                        // the annotation name.
                        let verb = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "Mapping", with: "")
                        var p = ""
                        if m.range(at: 2).location != NSNotFound { p = ns.substring(with: m.range(at: 2)) }
                        else if m.range(at: 3).location != NSNotFound { p = ns.substring(with: m.range(at: 3)) }
                        hits.append((verb, p, m.range))
                    }
                }
                if let re = try? NSRegularExpression(pattern: "@RequestMapping\\(([^)]*)\\)") {
                    for m in re.matches(in: body, range: inner) {
                        let args = ns.substring(with: m.range(at: 1))
                        guard let rre = try? NSRegularExpression(pattern: "method\\s*=\\s*RequestMethod\\.(\\w+)"),
                              let rm = rre.firstMatch(in: args, range: NSRange(location: 0, length: (args as NSString).length)) else { continue }
                        let verb = (args as NSString).substring(with: rm.range(at: 1))
                        var p = ""
                        if let pre = try? NSRegularExpression(pattern: "\"([^\"]*)\""),
                           let pm = pre.firstMatch(in: args, range: NSRange(location: 0, length: (args as NSString).length)) {
                            p = (args as NSString).substring(with: pm.range(at: 1))
                        }
                        hits.append((verb, p, m.range))
                    }
                }
                for (verb, p, mrange) in hits {
                    var path = prefix + p
                    if let re = try? NSRegularExpression(pattern: "\\{[^}]+\\}") {
                        path = re.stringByReplacingMatches(in: path, range: NSRange(location: 0, length: (path as NSString).length), withTemplate: "1")
                    }
                    if !path.hasPrefix("/") { path = "/" + path }
                    // signature: everything from the annotation to the method body's brace
                    let after = NSRange(location: NSMaxRange(mrange), length: full.length - NSMaxRange(mrange))
                    let brace = ns.range(of: "{", options: [], range: after).location
                    let sigEnd = brace == NSNotFound ? full.length : brace
                    let sig = ns.substring(with: NSRange(location: after.location, length: sigEnd - after.location))
                    let sigNS = sig as NSString
                    let sigRange = NSRange(location: 0, length: sigNS.length)
                    var query: [String] = []
                    var json = ""
                    if let re = try? NSRegularExpression(pattern: "@RequestParam(?:\\(\\s*(?:(?:value|name)\\s*=\\s*)?\"([^\"]*)\"[^)]*\\))?\\s+(?:final\\s+)?([\\w.<>\\[\\]]+)\\s+(\\w+)") {
                        for m in re.matches(in: sig, range: sigRange) {
                            let qn = m.range(at: 1).location != NSNotFound ? sigNS.substring(with: m.range(at: 1)) : sigNS.substring(with: m.range(at: 3))
                            let qv = sample(sigNS.substring(with: m.range(at: 2))).replacingOccurrences(of: "\"", with: "")
                            query.append("\(qn)=\(qv)")
                        }
                    }
                    if let re = try? NSRegularExpression(pattern: "@RequestBody(?:\\([^)]*\\))?\\s+(?:final\\s+)?([\\w.<>\\[\\]]+)\\s+\\w+"),
                       let m = re.firstMatch(in: sig, range: sigRange) {
                        json = jsonFor(sigNS.substring(with: m.range(at: 1)))
                    }
                    var url = "http://localhost:\(port)" + path
                    if !query.isEmpty { url += "?" + query.joined(separator: "&") }
                    var line = "// \(step). Try it: curl -X \(verb.uppercased()) '\(url)'"
                    if !json.isEmpty { line += " -H \"Content-Type: application/json\" -d '\(json)'" }
                    lines.append(line)
                    step += 1
                }
            }
            if step == 2 { lines.append("// 2. Call the controller endpoints (paths are in the mappings above)") }
        } else if files.contains(where: { $0.1.range(of: "static\\s+void\\s+main\\s*\\(", options: .regularExpression) != nil }) {
            // plain Java: javac/java recipe around the class with "static void main"
            var mainCls = "Main"
            for (n, body) in files {
                if body.range(of: "static\\s+void\\s+main\\s*\\(", options: .regularExpression) != nil {
                    let ns = body as NSString
                    var pkg = ""
                    if let re = try? NSRegularExpression(pattern: "(?m)^\\s*package\\s+([\\w.]+)\\s*;"),
                       let m = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                        pkg = ns.substring(with: m.range(at: 1))
                    }
                    let cls = n.replacingOccurrences(of: ".java", with: "")
                    mainCls = pkg.isEmpty ? cls : pkg + "." + cls
                    break
                }
            }
            lines.append("// 1. Compile: javac -d out $(find . -name \"*.java\")")
            lines.append("// 2. Run:     java -cp out \(mainCls)")
        } else {
            lines.append("// 1. Open the project in IntelliJ and run the main class")
            lines.append("// 2. Or from a terminal: javac -d out $(find . -name \"*.java\") then java -cp out <MainClass>")
        }
        return base + "\n" + lines.joined(separator: "\n") + "\n"
    }

    /// "GET /api/missions/101/energy" / "POST /api/missions/air  JSON {...}" lines under the paper's REST-operations heading.
    static func paperDemoCalls(_ paper: String) -> [(verb: String, path: String, json: String)] {
        var text = paper
        if let r = paper.range(of: "REST operations", options: .caseInsensitive) { text = String(paper[r.lowerBound...]) } else { return [] }
        let re = try! NSRegularExpression(pattern: #"(?m)^\s*(GET|POST|PUT|PATCH|DELETE)\s+(/\S*)(?:\s+(?:JSON\s+)?(\{.*\}))?\s*$"#)
        var out: [(String, String, String)] = []
        var seen = Set<String>()
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let verb = ns.substring(with: m.range(at: 1)), path = ns.substring(with: m.range(at: 2))
            let json = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            if seen.insert(verb + path + json).inserted { out.append((verb, path, json)) }
            if out.count >= 8 { break }
        }
        return out
    }

    /// Rules that need the paper's wording: a field the paper calls "positive" must be rejected at 0 (`< 0` -> `<= 0`).
    static func paperFixes(_ answer: String, paper: String, starter: [String: String] = [:]) -> String {
        var out = fixControllerDelegation(answer, starter: starter, paper: paper)
        let phrase = try! NSRegularExpression(pattern: #"(?i)\bpositive\s+([A-Za-z ]+?)(?=[,.;:\n]|$)"#)
        let ns = paper as NSString
        var tokens = Set<String>()
        for m in phrase.matches(in: paper, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: m.range(at: 1)).components(separatedBy: " and ") {
                if let w = part.split(separator: " ").last { tokens.insert(String(w).lowercased()) }
            }
        }
        // a parameter the paper says must be positive (e.g. "reject non-positive plan capacity") gets a guard when the method has none
        for tkn in tokens where tkn.count >= 3 && !["integer", "number", "value", "values", "int", "long", "id", "distance", "stays", "stay"].contains(tkn) {
            let sig = try! NSRegularExpression(pattern: "(public\\s+[\\w<>\\[\\], ?]+\\s+\\w+\\s*\\([^)]*\\b(?:int|long|double)\\s+" + NSRegularExpression.escapedPattern(for: tkn) + "\\b[^)]*\\)\\s*\\{)")
            let nsOut = out as NSString
            for m in sig.matches(in: out, range: NSRange(location: 0, length: nsOut.length)).reversed() {
                let after = nsOut.substring(from: m.range.location + m.range.length)
                let bodyStart = String(after.prefix(400))
                if bodyStart.range(of: tkn + "\\s*(<=|<)\\s*[01]L?\\b", options: .regularExpression) != nil { continue }
                out = (out as NSString).replacingCharacters(in: NSRange(location: m.range.location + m.range.length, length: 0), with: "\n  if (\(tkn) <= 0) { throw new IllegalArgumentException(\"\(tkn) must be positive\"); }") as String
            }
        }
        for tkn in tokens where tkn.count >= 2 && !["integer", "number", "value", "values", "int", "long"].contains(tkn) {
            let re = try! NSRegularExpression(pattern: "(?i)(\\.(?:get)?" + NSRegularExpression.escapedPattern(for: tkn) + "\\w*\\(\\)\\s*)<(\\s*0L?\\b)")
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "$1<=$2")
        }
        return out
    }


    // ---- controllers that wrap results in an invented class instead of delegating to the service ----
    private static func matchingBrace(_ s: NSString, open: Int) -> Int? {
        var depth = 0, i = open
        while i < s.length { let c = s.character(at: i); if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1; if depth == 0 { return i } }; i += 1 }
        return nil
    }

    /// `private static class ApiResponse { ApiResponse(String code, String message) … }` duplicates the starter's `ApiError(String code, String message)`:
    /// use the starter's DTO and drop the invented class.
    static func fixInventedWrapper(_ answer: String, starter: [String: String]) -> String {
        let files = parseAnswerFiles(answer)
        var records: [String: [String]] = [:]
        let recRe = try! NSRegularExpression(pattern: #"record\s+(\w+)\s*\(([^)]*)\)"#)
        for body in starter.values {
            let ns = body as NSString
            for m in recRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                records[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2)).components(separatedBy: ",").map { String($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
            }
        }
        if records.isEmpty { return answer }
        var edited: [String: String] = [:]
        let clsRe = try! NSRegularExpression(pattern: #"\n[ \t]*private\s+static\s+class\s+(\w+)\s*\{"#)
        for (path, body) in files {
            var b = body
            for m in clsRe.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)).reversed() {
                let ns = b as NSString
                let name = ns.substring(with: m.range(at: 1))
                guard let close = matchingBrace(ns, open: m.range.location + m.range.length - 1) else { continue }
                let cls = ns.substring(with: NSRange(location: m.range.location, length: close + 1 - m.range.location))
                guard let cm = try? NSRegularExpression(pattern: "(?:public\\s+)?" + name + "\\s*\\(([^)]*)\\)").firstMatch(in: cls, range: NSRange(location: 0, length: (cls as NSString).length)) else { continue }
                let types = (cls as NSString).substring(with: cm.range(at: 1)).components(separatedBy: ",").map { String($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
                guard let rec = records.first(where: { $0.value == types && !$0.value.isEmpty }) else { continue }
                var nb = ns.replacingCharacters(in: NSRange(location: m.range.location, length: close + 1 - m.range.location), with: "")
                nb = try! NSRegularExpression(pattern: "\\b" + name + "\\b").stringByReplacingMatches(in: nb, range: NSRange(location: 0, length: (nb as NSString).length), withTemplate: rec.key)
                b = nb
            }
            if b != body { edited[path] = b }
        }
        if edited.isEmpty { return answer }
        return mergeFixes(answer, edited.keys.sorted().map { "// ===== FILE: \($0) =====\n" + (edited[$0] ?? "") }.joined(separator: "\n"))
    }

    /// A controller method that returns ApiError as a success response (the model wrapped the result) is rewritten to delegate to the service:
    /// GET -> the service result (or a one-key map holding it, named from the paper's "containing <key>"), POST -> 201 with the service result.
    static func fixControllerDelegation(_ answer: String, starter: [String: String], paper: String) -> String {
        let files = parseAnswerFiles(answer)
        var svc: [String: String] = [:]                     // service method -> return type
        let sigRe = try! NSRegularExpression(pattern: #"public\s+([\w<>,?\[\] ]+?)\s+(\w+)\s*\((?:[^()]|\([^()]*\))*\)\s*\{"#)
        for (path, body) in starter.merging(files, uniquingKeysWith: { _, n in n }) where path.hasSuffix("Service.java") {
            let ns = body as NSString
            for m in sigRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) { svc[ns.substring(with: m.range(at: 2))] = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces) }
        }
        if svc.isEmpty { return answer }
        var key = ""
        if let m = try? NSRegularExpression(pattern: #"(?i)object containing (\w+)"#).firstMatch(in: paper, range: NSRange(location: 0, length: (paper as NSString).length)) { key = (paper as NSString).substring(with: m.range(at: 1)) }
        let methRe = try! NSRegularExpression(pattern: #"(@(?:Get|Post|Put|Delete)Mapping(?:\([^)]*\))?)\s+public\s+([\w<>,?\[\] ]+?)\s+(\w+)\s*\(((?:[^()]|\([^()]*\))*)\)\s*\{"#)
        var edited: [String: String] = [:]
        for (path, body) in files where body.range(of: #"@RestController\b(?!Advice)"#, options: .regularExpression) != nil {
            var b = body
            for m in methRe.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)).reversed() {
                let ns = b as NSString
                let annotation = ns.substring(with: m.range(at: 1)), retType = ns.substring(with: m.range(at: 2)), name = ns.substring(with: m.range(at: 3)), params = ns.substring(with: m.range(at: 4))
                guard retType.contains("ApiError"), let close = matchingBrace(ns, open: m.range.location + m.range.length - 1) else { continue }
                let inner = ns.substring(with: NSRange(location: m.range.location + m.range.length, length: close - (m.range.location + m.range.length)))
                guard let cm = try? NSRegularExpression(pattern: #"service\.(\w+)\(([^)]*)\)"#).firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)),
                      let ret = svc[(inner as NSString).substring(with: cm.range(at: 1))] else { continue }
                let call = (inner as NSString).substring(with: cm.range(at: 1)), args0 = (inner as NSString).substring(with: cm.range(at: 2))
                var args = args0
                if annotation.hasPrefix("@PostMapping"), let rb = try? NSRegularExpression(pattern: #"@RequestBody\s+[\w<>]+\s+(\w+)"#).firstMatch(in: params, range: NSRange(location: 0, length: (params as NSString).length)) { args = (params as NSString).substring(with: rb.range(at: 1)) }
                let primitive = ["int", "long", "Integer", "Long", "double", "boolean", "String"].contains(ret)
                var rtype: String, stmt: String
                if annotation.hasPrefix("@PostMapping") { rtype = "ResponseEntity<\(ret)>"; stmt = "return ResponseEntity.status(HttpStatus.CREATED).body(service.\(call)(\(args)));" }
                else if primitive { let k = key.isEmpty ? name : key; rtype = "Map<String, \(ret == "int" ? "Integer" : (ret == "long" ? "Long" : "Object"))>"; stmt = "return Map.of(\"\(k)\", service.\(call)(\(args)));" }
                else { rtype = ret; stmt = "return service.\(call)(\(args));" }
                let whole = NSRange(location: m.range.location, length: close + 1 - m.range.location)
                b = (b as NSString).replacingCharacters(in: whole, with: "\(annotation) public \(rtype) \(name)(\(params)) {\n  \(stmt)\n }") as String
            }
            if b != body { edited[path] = b }
        }
        if edited.isEmpty { return answer }
        return mergeFixes(answer, edited.keys.sorted().map { "// ===== FILE: \($0) =====\n" + (edited[$0] ?? "") }.joined(separator: "\n"))
    }

    /// Findings for code that COMPILES but is not a real answer: placeholders, and ApiError returned as a success response from a controller.
    /// Formatted like javac errors so the targeted repair prompt can name the file. Empty = nothing to report.
    static func semanticFindings(_ answer: String) -> String {
        var out: [String] = []
        for (path, body) in parseAnswerFiles(answer).sorted(by: { $0.key < $1.key }) {
            if body.range(of: #"@RestController\b(?!Advice)"#, options: .regularExpression) != nil {
                let re = try! NSRegularExpression(pattern: #"public\s+(?:ResponseEntity<ApiError>|ApiError)\s+(\w+)\s*\("#)
                let ns = body as NSString
                for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                    let back = ns.substring(with: NSRange(location: max(0, m.range.location - 90), length: min(90, m.range.location)))
                    if back.contains("@ExceptionHandler") { continue }
                    out.append("\(path):1: error: controller method \(ns.substring(with: m.range(at: 1)))() returns ApiError as a normal response; ApiError is only for error responses. Return what the service method returns (a DTO or a map holding the value).")
                }
            }
            for marker in ["not implemented", "UnsupportedOperationException", "TODO"] where body.range(of: marker, options: .caseInsensitive) != nil {
                out.append("\(path):1: error: contains a placeholder (\(marker)); write the real implementation.")
            }
        }
        return out.joined(separator: "\n")
    }

    /// A repair must never swap real logic for stubs just to make javac happy.
    static func introducesPlaceholders(old: String, new: String) -> Bool {
        func count(_ a: String) -> Int { semanticFindings(a).components(separatedBy: "\n").filter { !$0.isEmpty }.count }
        return count(new) > count(old)
    }

    /// `for (X m : missions) { skipped.add(m.getId()); }` after a selection loop adds EVERY mission as skipped. Move the add into the "does not fit" branch.
    static func fixSkippedLoop(_ answer: String) -> String {
        let lone = try! NSRegularExpression(pattern: #"\n[ \t]*for\s*\(\s*[\w<>]+\s+(\w+)\s*:\s*(\w+)\s*\)\s*\{\s*skipped\.add\(\1\.getId\(\)\);\s*\}[ \t]*(?=\n)"#)
        let ns = answer as NSString
        guard let lm = lone.firstMatch(in: answer, range: NSRange(location: 0, length: ns.length)) else { return answer }
        let listVar = ns.substring(with: lm.range(at: 2))
        let head = ns.substring(to: lm.range.location)
        if head.components(separatedBy: "skipped.add(").count > 1 { return answer }          // a real skip branch already exists
        let sel = try! NSRegularExpression(pattern: "for\\s*\\(\\s*[\\w<>]+\\s+(\\w+)\\s*:\\s*" + NSRegularExpression.escapedPattern(for: listVar) + "\\s*\\)\\s*\\{[\\s\\S]*?if\\s*\\([^\\n{]*\\)\\s*\\{\\s*continue;\\s*\\}")
        guard let sm = sel.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return answer }
        let v = (head as NSString).substring(with: sm.range(at: 1))
        var fixedHead = (head as NSString).substring(with: sm.range)
        guard let r = fixedHead.range(of: "{ continue; }", options: [.backwards]) ?? fixedHead.range(of: "{continue;}", options: [.backwards]) else { return answer }
        fixedHead.replaceSubrange(r, with: "{ skipped.add(\(v).getId()); continue; }")
        let newHead = (head as NSString).replacingCharacters(in: sm.range, with: fixedHead)
        return newHead + ns.substring(from: lm.range.location + lm.range.length)
    }

    // Applies every deterministic fixer in the right order (Ollama path only).
    static func staticFixes(_ answer: String, starter: [String: String]) -> String {
        return fixSkippedLoop(fixMappingQueryStrings(alignControllerReturns(fixReasonOrder(nameRequestParams(fixInventedWrapper(answer, starter: starter))), starter: starter)))
    }

    // Replaces the answer's FILE sections with the fixed versions (adds new files before HOW TO TEST)
    static func mergeFixes(_ answer: String, _ fixes: String) -> String {
        let fixSecs = sections(fixes).filter { fileName($0.0) != nil }
        if fixSecs.isEmpty { return answer }
        var byName: [String: (String?, [String])] = [:]
        for f in fixSecs { byName[fileName(f.0)!] = f }
        var used = Set<String>()
        var out: [String] = []
        func emitUnused() {
            for f in fixSecs {
                let n = fileName(f.0)!
                if !used.contains(n) { out.append(f.0!); out += f.1; used.insert(n) }
            }
        }
        for sec in sections(answer) {
            if let n = fileName(sec.0), let f = byName[n] {
                out.append(f.0!); out += f.1; used.insert(n)
            } else {
                if let h = sec.0, h.contains("HOW TO TEST") { emitUnused() }
                if let h = sec.0 { out.append(h) }
                out += sec.1
            }
        }
        emitUnused()
        return out.joined(separator: "\n")
    }

    // Adds "import java.util.*;" after the package line when a file has no java.util wildcard import
    static func ensureUtilImport(_ code: String) -> String {
        if code.contains("import java.util.*;") { return code }
        var lines = code.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package ") }) {
            lines.insert("import java.util.*;", at: i + 1)
            return lines.joined(separator: "\n")
        }
        return code
    }

    // Rewrites every FILE section of the answer with the import fix applied (so what you paste matches what compiled)
    static func applyImportFix(_ answer: String) -> String {
        var out: [String] = []
        var inFile = false
        var buf: [String] = []
        func flush() {
            if inFile { out.append(contentsOf: ensureUtilImport(buf.joined(separator: "\n")).components(separatedBy: "\n")) }
            else { out.append(contentsOf: buf) }
            buf = []
        }
        for line in answer.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// =====") {
                flush()
                out.append(line)
                inFile = t.hasPrefix("// ===== FILE:")
            } else {
                buf.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    // Splits "// ===== FILE: ... =====" sections into src/main/java/<package>/<File>.java -> content
    static func parseAnswerFiles(_ answer: String) -> [String: String] {
        var result: [String: String] = [:]
        var name: String? = nil
        var buf: [String] = []
        func flush() {
            guard let n = name else { return }
            let body = buf.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
            var pkg = ""
            for l in body.components(separatedBy: "\n") {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("package ") {
                    pkg = String(t.dropFirst(8)).replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            let file = (n as NSString).lastPathComponent
            guard file.hasSuffix(".java") else { return }
            let dir = pkg.isEmpty ? "" : pkg.replacingOccurrences(of: ".", with: "/") + "/"
            result["src/main/java/" + dir + file] = body
        }
        for line in answer.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// ===== FILE:") {
                flush()
                buf = []
                let rest = String(t.dropFirst("// ===== FILE:".count)).trimmingCharacters(in: .whitespaces)
                name = rest.components(separatedBy: " ").first
            } else if t.hasPrefix("// =====") {
                flush()
                buf = []
                name = nil
            } else if name != nil {
                buf.append(line)
            }
        }
        flush()
        return result
    }

    func contextSize(for prompt: String) -> Int {
        config.ollamaContextSize(forPrompt: prompt)
    }

    // Output sizing (Ollama): min(8192, max(4096, 1536 + 768 x taskCount)),
    // counted on the RAW paper. Bounded so one request can never grind for
    // hours (thinking tokens count toward it too); any cut answer is
    // completed by the compile-repair loop.
    static func taskCount(in text: String) -> Int {
        var nums = Set<Int>()
        let re = try? NSRegularExpression(pattern: #"\b[Tt]ask\s+(\d+)\b"#)
        let ns = NSRange(text.startIndex..., in: text)
        for m in (re?.matches(in: text, range: ns) ?? []) {
            if let r = Range(m.range(at: 1), in: text), let n = Int(text[r]) { nums.insert(n) }
        }
        return nums.isEmpty ? 1 : nums.count
    }
    static func numPredict(forPaper paper: String) -> Int {
        min(8192, max(4096, 1536 + 768 * taskCount(in: paper)))
    }

    // Single entry point for ALL providers (Phase 9: shared pipeline).
    // The repair loop in handle() calls this too, so both providers get
    // compile-check + two repair rounds for free.
    @MainActor
    func generate(prompt: String, model: String, label: String) async -> String? {
        lastFailureMessage = ""
        // Final context policy: a request whose prompt alone exceeds the
        // automatic ceiling is BLOCKED — never truncated. The user is told to
        // raise the manual Qwen ctx setting (larger contexts pressure memory
        // and slow the Mac).
        if activeProvider.id == "ollama" && config.ollamaContext <= 0 {
            let autoCtx = config.ollamaContextSize(forPrompt: prompt)
            if prompt.count / 3 > autoCtx {
                setStatus("⚠️ Prompt needs ~\(prompt.count / 3) tokens – above this Mac's automatic context ceiling (\(autoCtx)). Raise Qwen ctx in Settings (larger contexts use more memory and slow the laptop).")
                return nil
            }
        }
        let provider = activeProvider
        lastPrompt = prompt
        lastModel = model
        lastLabel = label
        let outcome = await provider.generate(
            prompt: prompt, model: model, label: label,
            // Adapters run off the main actor; hop before touching AppKit (chunks
            // dispatch in FIFO order, so output order is preserved).
            onChunk: { [weak self] piece in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.textView.textStorage?.append(NSAttributedString(string: piece, attributes: [
                        .font: self.mono,
                        .foregroundColor: NSColor.textColor]))
                    self.textView.scrollToEndOfDocument(nil)
                }
            },
            onStatus: { [weak self] s in
                DispatchQueue.main.async { self?.setStatus(s) }
            })
        switch outcome {
        case .ok(let answer):
            // A "success" with no content would otherwise copy an empty answer.
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setStatus("❌ Empty response from provider")
                return nil
            }
            return answer
        case .interrupted(let partial):
            setStatus("⚠️ Stream interrupted – partial answer kept (\(partial.count) chars)")
            return partial.isEmpty ? nil : partial
        case .failed(let err):
            return await handleGenerationFailure(err, provider: provider)
        }
    }

    // Phase 7A/7F: distinct diagnostics + optional, user-approved Ollama fallback.
    // Returns an answer if the user approved the switch and the fallback
    // succeeded; nil otherwise (the caller's pipeline then stops cleanly).
    @MainActor
    func handleGenerationFailure(_ err: DropError, provider: ProviderAdapter) async -> String? {
        // Never echo the key; classified message + server detail contain no credentials.
        lastFailureMessage = err.displayMessage
        setStatus("❌ \(err.displayMessage)")
        textView.string = ""
        guard provider.id == "opencode_go" else { return nil }
        // Phase 8: fallback only ever PROPOSED, requires explicit approval, off by default.
        guard config.allowFallback else { return nil }
        let ollama = OllamaProvider(config: config)
        guard await prepareOllama(startIfNeeded: true, base: config.ollamaBase,
                                  timeout: config.connectTimeout) else { return nil }
        guard let names = await ollama.listModels(), !names.isEmpty else { return nil }
        let a = NSAlert()
        a.messageText = "OpenCode Go unavailable"
        a.informativeText = "\(err.displayMessage).\n\nOllama is running locally with \(names.count) model(s). Switch to Ollama for this answer?"
        a.addButton(withTitle: "Switch to Ollama")
        a.addButton(withTitle: "Stay on OpenCode Go")
        if a.runModal() == .alertFirstButtonReturn {
            config.provider = "ollama"
            config.save()
            providerBtn.title = "🦙 Ollama"
            setStatus("Switched to Ollama (local) · retrying…")
            loadModels(startIfNeeded: true)
            // Re-send the exact same request through the approved provider.
            // If Ollama also fails this returns nil (no fallback loop: the
            // provider guard above stops any second proposal).
            guard let lp = lastPrompt else { return nil }
            // lastModel is the OpenCode model (mimo…) — Ollama needs one of
            // ITS installed Qwen models instead: the saved selection if still
            // installed, otherwise the first discovered Qwen model.
            let preferred = UserDefaults.standard.string(forKey: "model")
            guard let ollamaModel = (preferred.flatMap { names.contains($0) ? $0 : nil }) ?? names.first
            else { return nil }
            return await generate(prompt: lp, model: ollamaModel, label: lastLabel ?? "✍️ Writing")
        }
        return nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
EOF

cat > "$DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.drop</string>
  <key>CFBundleName</key><string>Drop</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
EOF

echo "Building Drop..."
swiftc -O "$DIR/main.swift" -o "$DIR/Drop" -framework Cocoa -framework PDFKit -framework Carbon \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"

# Run Drop through launchd (so macOS doesn't show the launcher in the Dock as "running in background")
AGENT="$HOME/Library/LaunchAgents/local.drop.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.drop</string>
  <key>ProgramArguments</key><array><string>$DIR/Drop</string></array>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$DIR/log.txt</string>
  <key>StandardErrorPath</key><string>$DIR/log.txt</string>
</dict>
</plist>
EOF2
launchctl bootout "gui/$(id -u)/local.drop" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

# Quiet laptop: Ollama never auto-starts at login (best-effort; only its own
# login job is touched — other startup items are left alone). Drop starts the
# Ollama app on demand when Ollama is selected.
launchctl bootout "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true

# Small launcher app (Spotlight: "Drop") - just asks launchd to (re)start the popup
rm -rf "$APP"
osacompile -o "$APP" \
  -e 'do shell script "launchctl kickstart -k gui/$(id -u)/local.drop"'

# Custom icon
[ -f "$HOME/Downloads/Drop.icns" ] && cp "$HOME/Downloads/Drop.icns" "$DIR/Drop.icns"
if [ -f "$DIR/Drop.icns" ]; then
  cp "$DIR/Drop.icns" "$APP/Contents/Resources/applet.icns"
  touch "$APP"
fi

echo "✅ Installed. Starting Drop..."
launchctl kickstart -k "gui/$(id -u)/local.drop"
