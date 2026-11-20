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
    // Remembered so an approved provider fallback can answer the SAME request.
    var lastPrompt: String?
    var lastModel: String?
    var lastLabel: String?
    var expanded = false
    var config = DropConfig.load()
    let W: CGFloat = 230
    let compactH: CGFloat = 94    // drop row + dynamic model selector + button row
    let answerH: CGFloat = 240

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

        dropView.onDrop = { [weak self] urls in self?.handle(urls) }
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

        let stack = NSStackView(views: [dropView, modelPopup, row, scroll])
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
            modelPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: answerH - 5),
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
        if open.runModal() == .OK { handle(open.urls) }
    }

    @objc func copyAgain() {
        if lastAnswer.isEmpty { return }
        copyToClipboard(lastAnswer)
        setStatus("📋 Copied again · paste with ⌘V")
    }

    @objc func toggleAnswer() {
        expanded.toggle()
        scroll.isHidden = !expanded
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

    func stripFences(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func handle(_ urls: [URL]) {
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
        // Prompt fork: Ollama gets the student-level rules (silent checks); OpenCode
        // keeps its pinned PROMPT_HEADER byte-for-byte.
        let header = config.provider == "ollama" ? OLLAMA_PROMPT_HEADER : PROMPT_HEADER
        let prompt = header + "\n\n" + paper
        if !paper.contains(".java =====") {
            setStatus("⚠️ No Java starter found · thinking anyway…")
        } else {
            setStatus("⏳ Read \(fileCount) file(s) · thinking…")
        }
        let check = false
        Task { @MainActor in
            defer { self.running = false; self.dropView.title = "Drop to share" }
            guard var answer = await self.generate(prompt: prompt, model: model, label: "✍️ Writing") else { return }
            if check {
                let review = REVIEW_HEADER + "\n\n######## RULES ########\n" + header
                    + "\n\n" + paper + "\n\n######## DRAFT SOLUTION ########\n" + answer
                self.textView.string = ""
                if let fixed = await self.generate(prompt: review, model: model, label: "🔍 Double-checking"),
                   fixed.count > answer.count / 3 {
                    answer = fixed
                }
            }
            // Compile the answer against the starter; if javac fails, send the errors back for a fix (max 4 rounds)
            var compiled: Bool? = nil
            var rounds = 0
            while true {
                // Deterministic fixers (Ollama only) run before every compile check,
                // so javac judges - and the repair model sees - the fixed answer.
                let fixersOn = self.config.provider == "ollama"
                if fixersOn {
                    answer = AppDelegate.staticFixes(answer, starter: self.starterFiles)
                }
                self.setStatus("🧪 Compiling…")
                // Full compile every round: javac's complete error set is the only
                // truthful feed for the repair model.
                guard let errs = await self.compileErrors(answer) else { compiled = nil; break }
                if errs.isEmpty { compiled = true; break }
                compiled = false
                if rounds >= 4 { break }
                rounds += 1
                let n = errs.components(separatedBy: "error:").count - 1
                let fixPrompt: String
                if self.config.provider == "ollama" {
                    // Targeted repair (Ollama only): errors + implicated sources —
                    // never the full question and previous answer for a small fix.
                    fixPrompt = OLLAMA_REPAIR_HEADER
                        + "\n\n######## JAVAC ERRORS ########\n" + String(errs.prefix(6000))
                        + "\n\n######## AFFECTED FILES ########\n"
                        + AppDelegate.repairContext(answer: answer, starter: self.starterFiles, errs: errs)
                } else {
                    fixPrompt = PROMPT_HEADER + "\n\n" + paper
                        + "\n\n######## YOUR PREVIOUS ANSWER ########\n" + answer
                        + "\n\n######## JAVAC ERRORS ########\n" + String(errs.prefix(6000))
                        + "\n\n" + REPAIR_HEADER
                }
                self.textView.string = ""
                guard let fixes = await self.generate(prompt: fixPrompt, model: model, label: "🔧 Fixing \(n) compile error(s)") else { break }
                let merged = AppDelegate.mergeFixes(answer, fixes)
                if merged == answer { break }
                answer = merged
            }
            var finalAnswer = AppDelegate.applyImportFix(self.stripFences(answer))
            if self.config.provider == "ollama" {
                finalAnswer = AppDelegate.staticFixes(finalAnswer, starter: self.starterFiles)
                // The prompt head forbids the model writing a HOW TO TEST section,
                // so Drop appends one deterministically at finalize (Ollama only).
                finalAnswer = AppDelegate.howToTestBlock(finalAnswer)
            }
            self.lastAnswer = finalAnswer
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
    static func howToTestBlock(_ answer: String) -> String {
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
            for (_, body) in files {
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
            var step = 2
            for (_, body) in files {
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

    // Applies every deterministic fixer in the right order (Ollama path only).
    static func staticFixes(_ answer: String, starter: [String: String]) -> String {
        return alignControllerReturns(fixReasonOrder(nameRequestParams(answer)), starter: starter)
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
