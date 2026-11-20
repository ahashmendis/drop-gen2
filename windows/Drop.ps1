# Drop for Windows - small always-on-top popup.
# Drop papers / project folders -> local Ollama model answers -> result copied to the clipboard.
# Requires: Ollama for Windows running, with at least one local Qwen model downloaded.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

# ---- single instance -------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\DropPopupApp')
if (-not $mutex.WaitOne(0)) { exit }

# ---- settings ----------------------------------------------------------------
$OllamaUrl    = 'http://127.0.0.1:11434'
$SkipDirs     = '\\(target|\.idea|\.git|node_modules|build|out|\.mvn|\.gradle|\.vscode|bin|obj)\\'
$TextExt      = @('.java','.xml','.md','.properties','.yml','.yaml','.json','.txt','.sql','.gradle','.kts','.html','.csv','.cs','.py','.js','.ts')
$DocExt       = @('.pdf','.docx','.md','.txt')

# ---- local configuration (Phase 3: file storage, no Credential Manager) -----
$ConfigDir  = Join-Path $env:APPDATA 'Drop'
$ConfigPath = Join-Path $ConfigDir 'config.json'
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

function Read-DropConfig {
    $defaults = @{
        provider    = 'opencode_go'
        ollama      = @{ base_url = $OllamaUrl; default_model = ''; context = 0 }
        opencode_go = @{ base_url = 'https://opencode.ai/zen/go/v1'; api_key = ''; model = 'mimo-v2.6-flash' }
        network     = @{ connect_timeout = 20; stream_idle_timeout = 120; retry_attempts = 3; retry_backoff = $true }
        preferences = @{ remember_provider = $true; allow_fallback = $false }
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]$defaults[$k]) }
            }
            return $j
        } catch { }
    }
    # First launch: write defaults (never overwrites an existing file above)
    $json = $defaults | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8
    try { icacls $ConfigPath /inheritance:r /grant:r "${env:USERNAME}:M" | Out-Null } catch { }
    return ($defaults | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
}

function Write-DropConfig($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    # Re-assert user-only access every save
    try { icacls $ConfigPath /inheritance:r /grant:r "${env:USERNAME}:M" | Out-Null } catch { }
}

$script:Config = Read-DropConfig
$script:Provider = if ($script:Config.provider -eq 'opencode_go') { 'opencode_go' } else { 'ollama' }
# x-opencode-session: stable for one conversation (prompt + retries reuse it),
# rotated when a new drop starts. Runtime-only, never written to config.json.
$script:SessionId = [guid]::NewGuid().ToString()
$OllamaUrl = $script:Config.ollama.base_url

# Hardware-aware Ollama context target (conservative presets by system RAM;
# a manual ollama.context > 0 wins). Mirrors the macOS implementation.
$script:RamGB = $null
function Ensure-OllamaRamGB {
    if ($null -eq $script:RamGB) {
        $script:RamGB = 8
        try {
            $b = [int64]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory)
            $script:RamGB = [int](($b + 536870912) / 1GB)   # round to nearest GiB
        } catch { }
    }
}
function Get-OllamaContextTarget([int]$manual) {
    if ($manual -gt 0) { return [Math]::Min($manual, 65536) }
    Ensure-OllamaRamGB
    if ($script:RamGB -lt 16) { return 8192 }     # 8 GB class -> 8192
    if ($script:RamGB -lt 32) { return 16384 }    # 16 GB      -> 8192-16384
    if ($script:RamGB -lt 64) { return 16384 }    # 32 GB      -> 16384-32768 (conservative low)
    return 32768                                  # 64 GB+     -> 32768-65536 (conservative low)
}
function Get-OllamaManualContext {
    if ($null -eq $script:Config.ollama.context) { return 0 }
    try { return [int]$script:Config.ollama.context } catch { return 0 }
}
# Automatic context ceiling (final policy): when no manual context is set,
# never allocate more than a conservative share of RAM. A manual override is
# exempt (the 65536 hard cap still applies).
# ---- student-quality helpers (Ollama only) -----------------------------------
# Cut-answer guard: with no output cap (num_predict -1), done_reason 'length'
# means the context filled before the answer finished. The partial answer is
# never discarded - the javac compile-repair pipeline completes it. Only an
# empty answer is a failure.
function Test-OllamaTruncated($obj) {
    if ($obj.done_reason -eq 'length') { return $true }
    return $false
}
# Output sizing (Ollama): min(8192, max(4096, 1536 + 768 * taskCount)),
# counted on the RAW paper (the prompt head's own "Task 1" examples must not
# inflate it). Bounded so one request can never grind for hours (thinking
# tokens count toward it too); any cut answer is completed by the
# compile-repair pipeline.
function Get-OllamaTaskCount([string]$text) {
    $nums = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($m in [regex]::Matches($text, '(?i)\btask\s+(\d+)\b')) {
        [void]$nums.Add([int]$m.Groups[1].Value)
    }
    if ($nums.Count -eq 0) { return 1 }
    return $nums.Count
}
function Get-OllamaNumPredict([string]$text) {
    $t = Get-OllamaTaskCount $text
    $np = 1536 + 768 * $t
    if ($np -lt 4096) { $np = 4096 }
    if ($np -gt 8192) { $np = 8192 }
    return $np
}

function Get-OllamaContextCeiling([int]$manual) {
    if ($manual -gt 0) { return 65536 }
    Ensure-OllamaRamGB
    if ($script:RamGB -lt 16) { return 16384 }  # 8 GB class -> 16384 (full papers need >8192)
    if ($script:RamGB -lt 32) { return 16384 }
    return 65536
}
# Final automatic context for one request: growth + floor + hard cap + ceiling
# clamp. Never grows past the ceiling on its own - an oversized prompt is
# blocked (never truncated) with a pointer to the manual Qwen ctx setting.
function Get-OllamaFinalContext([string]$prompt) {
    $manual = Get-OllamaManualContext
    $need = [int]($prompt.Length / 3) + 8000
    $ctx = 8192
    while ($ctx -lt $need -and $ctx -lt 65536) { $ctx *= 2 }
    $target = Get-OllamaContextTarget $manual
    if ($ctx -lt $target) { $ctx = $target }
    if ($ctx -gt 65536) { $ctx = 65536 }
    $ceil = Get-OllamaContextCeiling $manual
    if ($ctx -gt $ceil) { $ctx = $ceil }
    return $ctx
}

$PromptHeader = @'
You are an expert Java 17 / Spring Boot developer solving a timed 5COSC019W OOP lab exam paper.
Below is the question paper, then the COMPLETE starter project. Aim for full marks.

RULE 1 - USE THE STARTER'S EXACT NAMES. First write, as // comments, an inventory of every class,
method signature, record (with all fields in order), repository method and exception constructor in
the starter. Use ONLY those names. Never invent methods (no findById, findAll, Optional.orElseThrow,
or save() returning a value unless the starter really has them). Copy exception constructor
parameters exactly (if the starter's exception takes a long id, pass the long id, not a String). Use the starter's DTO records
with ALL fields in the right order; never create your own DTO when the starter already has one.
RULE 2 - KEEP WHAT THE PAPER SAYS TO KEEP. Do not change pom.xml, the abstract parent class, DTO
records, the repository API, existing method signatures, package names or annotations such as
@RestControllerAdvice. Replace each "// TODO" and "throw new UnsupportedOperationException(...)"
with real code and leave everything else as given. Create the new classes the paper asks for and
uncomment seed lines when told to.
RULE 3 - VALIDATION GIVES 400, NEVER 500. Null-check before calling methods on a value
(if (x == null || x.isBlank()) throw new IllegalArgumentException(...); only then x.trim()).
Validate every value the paper lists (positive, unique, non-blank, ranges) and save only after all
checks pass. Do arithmetic in long with Math.multiplyExact / Math.addExact / Math.toIntExact, catch
ArithmeticException and rethrow it as IllegalArgumentException. Never divide by a value that could be 0.
RULE 4 - ERROR HANDLER. IllegalArgumentException -> 400 ApiError("BAD_REQUEST", message);
not-found exception -> 404 ApiError("NOT_FOUND", message); conflict exception (if any) -> 409
ApiError("CONFLICT", message). Use the exact codes the paper gives.
RULE 5 - OOP. Put @Override on every overridden method. Process objects through the PARENT type;
never use instanceof or type checks. Sort exactly as the paper says (direction and tie-breaks),
e.g. Comparator.comparingInt(...).thenComparingLong(...) on the parent type's getters.
RULE 6 - FOLLOW EVERY MARK BULLET LITERALLY. Go through each bullet one by one and make the code
do all of it, including every listed rejection reason or code in the right situation.
Idempotency: store the ORIGINAL request per key and compare requests with equals();
same key + same request returns the same result, same key + different request -> 409.
RULE 7 - THIN CONTROLLER. Each handler only calls the service. Name parameters explicitly:
@PathVariable("id"), @RequestParam("minutes"). A POST that creates something returns 201 via
ResponseEntity.status(HttpStatus.CREATED).
RULE 9 - COMMON TRAPS. Keep every annotation already in the starter. Keep ALL the starter's existing import lines
exactly (e.g. keep import java.util.*;); never replace a wildcard import, only ADD imports you need. Variable and return types must
match the starter's method return types exactly. If the paper says an endpoint "returns a JSON object
containing X", return Map.of("X", value), never a bare number.
Controller methods only call the service: no try/catch there; the @RestControllerAdvice handler makes
the 400/404 ApiError responses. Before finishing, re-read every file and fix anything that would not
compile: wrong types, missing imports, methods or constructors that do not exist in the starter.
RULE 10 - HARD PAPERS. Build comparators as a variable, then list.sort(c); never call thenComparing
on a Stream. Never write !x == y; write x != y. Preview/plan methods never change stored state; only
commit persists. For capacity checks build a Map<Integer, int[]> of usage from confirmed reservations
PLUS what this run selected and check EVERY tick of [start, start + duration). Rejection reasons, in
order: larger than capacity -> EXCEEDS_CAPACITY; latestStartTick() < earliest start -> DEADLINE; window
ends before earliest start -> RELEASE_OUTSIDE_WINDOW; nothing fits -> NO_SLOT. Decide reasons with the
parent type's methods, never instanceof. GET lists must be sorted deterministically.
RULE 8 - CHECK SILENTLY. Before you write, work out every example number in the paper against your
code and make sure every name you use exists in the starter and every import is present. Do NOT
write out these checks.

OUTPUT - Java code only. No markdown, no explanations, no inventory, no test commands.
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
For plain Java tasks with no starter project, give each task's code under its // ===== Task N ===== header with a main method.
'@
$ReviewHeader = @'
You are now a strict exam marker AND a senior Java 17 / Spring Boot developer.
Below are the RULES, the exam paper, the starter project, and a DRAFT solution.
Check the draft against every rule and every mark bullet, one by one. Look especially for:
invented methods or names not in the starter, wrong exception constructor parameters, DTO records
with missing or reordered fields, changed signatures or changed protected files, missing validation,
anything that could throw a 500 instead of a 400, unchecked overflow, missing or wrong error-handler
codes, missing @Override, instanceof or type checks, wrong sort direction or tie-break, logic inside
the controller, a POST not returning 201, missing imports, and anything that would not compile.
Recalculate every example number from the paper with the draft's code.
Then output the FINAL corrected solution in exactly the same OUTPUT format as the rules ask
(inventory, tasks, every changed or created file COMPLETE, verification, how to test).
Output only the final solution - code and // comments, no markdown.
'@

# Ollama-only prompt fork (student-level code quality). OpenCode Go keeps
# $PromptHeader / $ReviewHeader byte-for-byte - those ride in its pinned
# request payload. Same rules, same OUTPUT contract; RULE 1's name inventory
# becomes silent (it contradicted OUTPUT's "no inventory"), and a student-level
# quality layer is added.
$OllamaPromptHeader = @'
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
'@
$OllamaReviewHeader = @'
You are now a strict exam marker AND a senior Java 17 / Spring Boot developer.
Below are the RULES, the exam paper, the starter project, and a DRAFT solution.
Check the draft against every rule and every mark bullet, one by one. Look especially for:
invented methods or names not in the starter, wrong exception constructor parameters, DTO records
with missing or reordered fields, changed signatures or changed protected files, missing validation,
anything that could throw a 500 instead of a 400, unchecked overflow, missing or wrong error-handler
codes, missing @Override, instanceof or type checks, wrong sort direction or tie-break, logic inside
the controller, a POST not returning 201, missing imports, and anything that would not compile.
Recalculate every example number from the paper with the draft's code.
Fix ONLY what is wrong or missing: keep every correct part unchanged, and keep the code at
student level - simplest complete solution, no new abstractions, helpers or comments unless the
question requires them. Do not invent requirements. Never claim that hidden tests pass - or that
any test ran - unless it actually did.
Then output the FINAL corrected solution in exactly the same OUTPUT format as the rules ask
(tasks, every changed or created file COMPLETE).
Output only the final solution - code and // comments, no markdown.
'@
$OllamaRepairHeader = @'
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
'@

# ---- native helpers (hotkey + window dragging) -------------------------------
$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DropNative : NativeWindow {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int c);
    public event EventHandler HotKey;
    public int LastHotKeyId;   // WM_HOTKEY id, read by the PowerShell dispatcher
    public DropNative() { CreateHandle(new CreateParams()); }
    public static bool IsIntelliJForeground() {
        var fg = GetForegroundWindow();
        int pid; GetWindowThreadProcessId(fg, out pid);
        try {
            var p = System.Diagnostics.Process.GetProcessById(pid);
            var n = p.ProcessName.ToLowerInvariant();
            if (n.StartsWith("idea")) { return true; }   // idea / idea64 (any version)
        } catch { }
        // Title fallback (macOS checks the localized name too): IntelliJ
        // windows carry "IntelliJ" in the title bar even when renamed/packaged.
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(fg, sb, sb.Capacity);
        return sb.ToString().Contains("IntelliJ");
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) {
            LastHotKeyId = m.WParam.ToInt32();
            if (HotKey != null) { HotKey(this, EventArgs.Empty); }
        }
        base.WndProc(ref m);
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms

# ---- text extraction ---------------------------------------------------------
function Get-DocxText([string]$path) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $entry = $zip.GetEntry('word/document.xml')
        if ($null -eq $entry) { $zip.Dispose(); return '' }
        $sr = New-Object System.IO.StreamReader($entry.Open())
        $xml = $sr.ReadToEnd(); $sr.Close(); $zip.Dispose()
        $xml = $xml -replace '</w:p>', "`n" -replace '<w:tab/>', "`t" -replace '<[^>]+>', ''
        return [System.Net.WebUtility]::HtmlDecode($xml)
    } catch { return '' }
}

function Get-FileText([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if ($ext -eq '.docx') { return Get-DocxText $path }
    if ($ext -eq '.pdf') {
        if (Get-Command pdftotext -ErrorAction SilentlyContinue) {
            try { return ((& pdftotext -layout $path - 2>$null) -join "`n") } catch { return '' }
        }
        return ''
    }
    if ($TextExt -contains $ext) {
        try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
    }
    return ''
}

function Expand-ZipTemp([string]$zip) {
    try {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('drop-' + [guid]::NewGuid().ToString())
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        return $tmp
    } catch { return $null }
}

# Returns @(text, fileCount, codeFileMap). Paper/docs first, then code.
# The map feeds the Ollama compile-repair pipeline (javac): Java sources under
# src/main/java/, keyed from src/main/java onward - exactly like the mac side,
# so an answer file overrides its starter copy instead of duplicating it.
function Collect-Input([string[]]$paths) {
    $docs = New-Object System.Text.StringBuilder
    $code = New-Object System.Text.StringBuilder
    $files = @{}
    $count = 0; $total = 0
    foreach ($p in $paths) {
        if ((-not (Test-Path -LiteralPath $p -PathType Container)) -and $p.ToLower().EndsWith('.zip')) {
            $z = Expand-ZipTemp $p
            if ($z) {
                $r = Collect-Input @($z)
                [void]$code.Append($r[0]); $count += $r[1]
                if ($r[2]) { foreach ($k in @($r[2].Keys)) { $files[$k] = $r[2][$k] } }
                Remove-Item -LiteralPath $z -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            $root = (Get-Item -LiteralPath $p).FullName.TrimEnd('\')
            $items = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { ($_.FullName -notmatch $SkipDirs) -and (-not $_.Name.StartsWith('~$')) -and ($_.Length -lt 150000) }
        } else {
            $root = Split-Path -Parent (Get-Item -LiteralPath $p).FullName
            $items = @(Get-Item -LiteralPath $p)
        }
        foreach ($f in $items) {
            $t = Get-FileText $f.FullName
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $total += $t.Length
            if ($total -gt 400000) { [void]$code.Append("`n[... more files skipped: too large ...]`n"); break }
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            $chunk = "`n===== FILE: $rel =====`n$t"
            if ($DocExt -contains $f.Extension.ToLower()) {
                [void]$docs.Append($chunk)
            } else {
                [void]$code.Append($chunk)
                $norm = $rel -replace '\\', '/'
                $i = $norm.IndexOf('src/main/java/')
                if ($f.Extension.ToLower() -eq '.java' -and $i -ge 0) { $files[$norm.Substring($i)] = $t }
            }
            $count++
        }
    }
    # No unzipped project in the folder? Read the starter ZIP instead.
    if ($code.Length -eq 0) {
        foreach ($p in $paths) {
            if (Test-Path -LiteralPath $p -PathType Container) {
                foreach ($zf in (Get-ChildItem -LiteralPath $p -Recurse -File -Filter *.zip -ErrorAction SilentlyContinue)) {
                    $z = Expand-ZipTemp $zf.FullName
                    if ($z) {
                        $r = Collect-Input @($z)
                        [void]$code.Append($r[0]); $count += $r[1]
                        if ($r[2]) { foreach ($k in @($r[2].Keys)) { $files[$k] = $r[2][$k] } }
                        Remove-Item -LiteralPath $z -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    $out = ''
    if ($docs.Length -gt 0) { $out += "`n######## EXAM PAPER / INSTRUCTIONS ########`n" + $docs.ToString() }
    if ($code.Length -gt 0) { $out += "`n######## STARTER PROJECT FILES ########`n" + $code.ToString() }
    return @($out, $count, $files)
}

# ---- model choice (provider-aware: no localhost:11434 traffic when OpenCode selected) ----
# Qwen-family discovery from GET /api/tags: model metadata first
# (details.family / details.families), falling back to the model name.
# All installed Qwen variants are offered - never a single hardcoded model.
$script:QwenModels    = @()
$script:MissingSaved  = $null
$script:ModelCombo    = $null
# Model metadata for the dropdown: entries are @{Name=<plain name>; Label=<name · size · quant>}.
# $script:QwenModels and $script:Model always hold plain names.
$script:QwenModelDetails = @()

function Sync-ModelCombo {
    $c = $script:ModelCombo
    if ($null -eq $c) { return }
    $c.Items.Clear()
    foreach ($d in $script:QwenModelDetails) { [void]$c.Items.Add($d.Label) }
    if ($script:Model) {
        $i = -1
        for ($k = 0; $k -lt $script:QwenModelDetails.Count; $k++) {
            if ($script:QwenModelDetails[$k].Name -eq $script:Model) { $i = $k; break }
        }
        if ($i -ge 0) { $c.SelectedIndex = $i }
        elseif ($c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    } elseif ($c.Items.Count -gt 0) {
        $c.SelectedIndex = 0
    }
}

# ---- Ollama on-demand lifecycle (quiet laptop): start only when needed -----
# $true when the local Ollama API answers GET /api/tags within $TimeoutSec.
function Test-OllamaApi([int]$TimeoutSec) {
    try {
        $null = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec $TimeoutSec
        return $true
    } catch { return $false }
}

# Resolve the official Ollama install (Start Menu shortcut first, then the
# known install dirs). The bare CLI server ('serve') is a last resort only.
function Start-OllamaApp {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ollama.lnk'
    if (Test-Path -LiteralPath $lnk) {
        try { Start-Process -FilePath $lnk; return $true } catch { }
    }
    foreach ($exe in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\ollama app.exe'))) {
        if (Test-Path -LiteralPath $exe) {
            try { Start-Process -FilePath $exe; return $true } catch { }
        }
    }
    $cli = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (-not (Test-Path -LiteralPath $cli)) {
        $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($cmd) { $cli = $cmd.Source }
    }
    if (Test-Path -LiteralPath $cli) {
        try { Start-Process -FilePath $cli -ArgumentList 'serve'; return $true } catch { }
    }
    return $false
}

# Best-effort one-time CPU demotion of the local Ollama server(s).
# Flag set only when at least one process was actually demoted.
$script:OllamaDemoted = $false
function Set-OllamaLowPriority {
    if ($script:OllamaDemoted) { return }
    try {
        $procs = @(Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue)
        foreach ($p in $procs) { try { $p.PriorityClass = 'BelowNormal' } catch { } }
        if ($procs.Count -gt 0) { $script:OllamaDemoted = $true }
    } catch { }
}

# On-demand start: probe first; when unreachable and asked to start, launch the
# official Ollama app and poll within the connect-timeout budget. Env knobs are
# set on the start path only (best-effort). The server is NEVER killed -
# keep_alive 0 lets it unload models between requests instead.
function Prepare-Ollama([bool]$StartIfNeeded) {
    if ($OllamaUrl -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])') { return $true }  # remote: not ours to manage
    if (Test-OllamaApi 1) {
        Set-OllamaLowPriority
        return $true
    }
    if (-not $StartIfNeeded) { return $false }
    Set-Status 'Starting Ollama...'
    $env:OLLAMA_NUM_PARALLEL = '1'
    $env:OLLAMA_MAX_LOADED_MODELS = '1'
    if (-not (Start-OllamaApp)) { return $false }
    Start-Sleep -Milliseconds 300
    $deadline = (Get-Date).AddSeconds([double]$script:Config.network.connect_timeout)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaApi 1) {
            Set-OllamaLowPriority
            Set-Status 'Ollama ready'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Returns $true when Ollama is reachable (started first when asked). Never
# selects a model that does not exist: the saved selection is used only if it
# is still installed. The combo shows labels (name · size · quant);
# $script:QwenModels / $script:Model always hold plain names.
function Update-OllamaModels([bool]$StartIfNeeded = $false) {
    if (-not (Prepare-Ollama -StartIfNeeded $StartIfNeeded)) { return $false }
    try {
        $script:QwenModelDetails = @()
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 3
        foreach ($m in $tags.models) {
            $n = [string]$m.name
            if ([string]::IsNullOrEmpty($n) -or $n -match 'cloud') { continue }
            $fam = @()
            if ($null -ne $m.details) {
                if ($m.details.family)   { $fam += [string]$m.details.family }
                if ($m.details.families) { $fam += @($m.details.families) }
            }
            if ((($fam -join ' ') -match 'qwen') -or ($n -match 'qwen')) {
                $label = $n
                if ($m.details.parameter_size)     { $label += ' · ' + [string]$m.details.parameter_size }
                if ($m.details.quantization_level) { $label += ' · ' + [string]$m.details.quantization_level }
                $script:QwenModelDetails += @{ Name = $n; Label = $label }
            }
        }
        $script:QwenModelDetails = @($script:QwenModelDetails | Sort-Object { $_.Name })
        $script:QwenModels = @($script:QwenModelDetails | ForEach-Object { [string]$_.Name })
        $script:OllamaOk = $true
        $script:MissingSaved = $null
        $saved = [string]$script:Config.ollama.default_model
        if ($script:QwenModels.Count -gt 0) {
            if ($saved -and ($script:QwenModels -contains $saved)) {
                $script:Model = $saved
            } else {
                if ($saved) { $script:MissingSaved = $saved }
                $script:Model = $script:QwenModels[0]
            }
        } else {
            $script:Model = ''
        }
        Sync-ModelCombo
        return $true
    } catch {
        $script:OllamaOk = $false
        $script:QwenModelDetails = @()
        $script:QwenModels = @()
        $script:MissingSaved = $null
        $script:Model = ''
        Sync-ModelCombo
        return $false
    }
}

$script:Model = ''
$script:CloudOk = $false
if ($script:Provider -eq 'opencode_go') {
    $script:Model = $script:Config.opencode_go.model
    $script:OllamaOk = $false
    $script:CloudOk = -not [string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)
} else {
    [void](Update-OllamaModels)
}

# ---- UI ----------------------------------------------------------------------
$W = 240; $CompactH = 90; $AnswerH = 240   # 90 = drop + model dropdown + buttons
$bg   = [System.Drawing.Color]::FromArgb(32, 32, 38)
$fg   = [System.Drawing.Color]::FromArgb(235, 235, 240)
$dim  = [System.Drawing.Color]::FromArgb(150, 150, 165)
$hi   = [System.Drawing.Color]::FromArgb(70, 60, 140)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.BackColor = $bg
$form.Size = New-Object System.Drawing.Size($W, $CompactH)
$form.AllowDrop = $true
$icoPath = Join-Path $PSScriptRoot 'Drop.ico'
if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $W) / 2)), ($wa.Top + 6))

function Set-Rounded {
    $r = 12
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $r, $r, 180, 90)
    $gp.AddArc($form.Width - $r, 0, $r, $r, 270, 90)
    $gp.AddArc($form.Width - $r, $form.Height - $r, $r, $r, 0, 90)
    $gp.AddArc(0, $form.Height - $r, $r, $r, 90, 90)
    $gp.CloseFigure()
    $form.Region = New-Object System.Drawing.Region($gp)
}

$drop = New-Object System.Windows.Forms.Panel
$drop.Location = New-Object System.Drawing.Point(8, 6)
$drop.Size = New-Object System.Drawing.Size(($W - 16), 34)
$drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$drop.AllowDrop = $true
$drop.Cursor = 'Hand'

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Drop to share'
$title.ForeColor = $fg
$title.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$title.TextAlign = 'MiddleCenter'
$title.Dock = 'Top'; $title.Height = 17
$title.AllowDrop = $true

$status = New-Object System.Windows.Forms.Label
$status.ForeColor = $dim
$status.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$status.TextAlign = 'MiddleCenter'
$status.Dock = 'Fill'
$status.AllowDrop = $true
$drop.Controls.Add($status); $drop.Controls.Add($title)

function New-SmallButton([string]$text, [int]$x, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 64)
    $b.ForeColor = $fg
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 7)
    $b.Location = New-Object System.Drawing.Point($x, 66)
    $b.Size = New-Object System.Drawing.Size($w, 18)
    $b.TabStop = $false
    return $b
}
$btnCopy  = New-SmallButton 'Copy'  ($W - 152) 50
$btnShare = New-SmallButton 'Share' ($W - 98)  56
$btnHide  = New-SmallButton 'x'     ($W - 38)  30
$btnProv  = New-SmallButton 'Ollama' 8 74
$btnProv.Add_Click({ Switch-Provider ($(if ($script:Provider -eq 'ollama') { 'opencode_go' } else { 'ollama' })) })

# Dynamic model selector: every installed Qwen model, discovered from Ollama.
$cmbModel = New-Object System.Windows.Forms.ComboBox
$cmbModel.DropDownStyle = 'DropDownList'
$cmbModel.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$cmbModel.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$cmbModel.ForeColor = $fg
$cmbModel.Location = New-Object System.Drawing.Point(8, 44)
$cmbModel.Size = New-Object System.Drawing.Size(($W - 16), 20)
$cmbModel.TabStop = $false
$script:ModelCombo = $cmbModel
$cmbModel.Add_SelectedIndexChanged({
    if ($script:Provider -ne 'ollama') { return }
    $sel = [string]$script:ModelCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    # The dropdown shows labels; the saved value is the plain model name.
    $name = $sel
    foreach ($d in $script:QwenModelDetails) { if ($d.Label -eq $sel) { $name = [string]$d.Name; break } }
    if ($script:Model -ne $name) {
        # Remember the selected model locally (config file, user-only access).
        $script:Model = $name
        $script:Config.ollama | Add-Member -NotePropertyName default_model -NotePropertyValue $name -Force
        Write-DropConfig $script:Config
    }
})
Sync-ModelCombo

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$box.ForeColor = $fg
$box.BorderStyle = 'None'
$box.Font = New-Object System.Drawing.Font('Consolas', 8)
$box.Location = New-Object System.Drawing.Point(8, 88)
$box.Size = New-Object System.Drawing.Size(($W - 16), ($AnswerH - 8))
$box.Visible = $false

$form.Controls.AddRange(@($drop, $cmbModel, $btnProv, $btnCopy, $btnShare, $btnHide, $box))

function Set-Status([string]$s) { $status.Text = $s }
# Terminal feedback that must reach the user even when the popup is hidden
# (the hotkey runs are headless): status line when visible, tray balloon when
# not. Never used for per-chunk streaming progress - outcomes only.
function Show-Notice([string]$msg) {
    Set-Status $msg
    if (-not $form.Visible) {
        try { $tray.ShowBalloonTip(5000, 'Drop', $msg, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}
# Ollama-only status (never called while OpenCode is selected, so the
# OpenCode status flow is untouched).
function Set-OllamaStatus {
    if ($script:Provider -ne 'ollama') { return }
    if (-not $script:OllamaOk) { Set-Status 'Ollama not running - open Ollama' }
    elseif ($script:QwenModels.Count -eq 0) { Set-Status 'No Qwen models installed - ollama pull a Qwen model first' }
    elseif ($script:MissingSaved) { Set-Status "Saved model '$($script:MissingSaved)' not installed - using '$($script:Model)'" }
    else { Set-Status 'Ready - click to choose files' }
}
if ($script:Provider -eq 'opencode_go') {
    if ($script:CloudOk) { Set-Status 'OpenCode Go ready - click to choose files' }
    else { Set-Status 'No OpenCode API key - open Settings (tray)' }
} else { Set-OllamaStatus }

# ---- provider switching (never silent: only via button/tray/settings) ---------
function Switch-Provider([string]$which) {
    if ($script:Running) { Set-Status 'Busy - wait before switching'; return }
    $script:Provider = $which
    $script:Config.provider = $which
    if ($script:Config.preferences.remember_provider) { Write-DropConfig $script:Config }
    $btnProv.Text = if ($which -eq 'ollama') { 'Ollama' } else { 'OpenCode' }
    $script:Attempt = 0
    if ($which -eq 'opencode_go') {
        $script:Model = $script:Config.opencode_go.model
        $script:CloudOk = -not [string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)
        # Phase 5: no localhost:11434 traffic while OpenCode is selected
        Set-Status $(if ($script:CloudOk) { 'OpenCode Go selected - cloud' } else { 'No OpenCode API key - open Settings (tray)' })
    } else {
        if (Update-OllamaModels $true) {
            if ($script:QwenModels.Count -eq 0) {
                Set-Status 'No Qwen models installed - ollama pull a Qwen model first'
            } elseif ($script:MissingSaved) {
                Set-Status "Saved model '$($script:MissingSaved)' not installed - using '$($script:Model)'"
            } else {
                Set-Status 'Ollama selected - local only'
            }
        } else {
            Set-Status 'Ollama selected - not running'
        }
    }
}

# ---- settings dialog (Phase 6) ------------------------------------------------
function Show-DropSettings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Drop Settings'
    $dlg.Size = New-Object System.Drawing.Size(430, 322)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'

    $lblP = New-Object System.Windows.Forms.Label; $lblP.Text = 'Provider:'; $lblP.Location = New-Object System.Drawing.Point(12, 15); $lblP.AutoSize = $true
    $cmbP = New-Object System.Windows.Forms.ComboBox; $cmbP.DropDownStyle = 'DropDownList'; $cmbP.Location = New-Object System.Drawing.Point(100, 12); $cmbP.Size = New-Object System.Drawing.Size(290, 24)
    [void]$cmbP.Items.AddRange(@('Ollama', 'OpenCode Go'))
    $cmbP.SelectedIndex = if ($script:Provider -eq 'opencode_go') { 1 } else { 0 }
    # Keep Base URL showing the selected provider's own value, so Save can never
    # write the Ollama URL into opencode_go.base_url (or vice versa).
    $cmbP.Add_SelectedIndexChanged({
        $txtB.Text = if ($cmbP.SelectedIndex -eq 1) { $script:Config.opencode_go.base_url } else { $script:Config.ollama.base_url }
    })

    $lblB = New-Object System.Windows.Forms.Label; $lblB.Text = 'Base URL:'; $lblB.Location = New-Object System.Drawing.Point(12, 48); $lblB.AutoSize = $true
    $txtB = New-Object System.Windows.Forms.TextBox; $txtB.Location = New-Object System.Drawing.Point(100, 45); $txtB.Size = New-Object System.Drawing.Size(290, 24)
    $txtB.Text = if ($script:Provider -eq 'opencode_go') { $script:Config.opencode_go.base_url } else { $script:Config.ollama.base_url }

    $lblK = New-Object System.Windows.Forms.Label; $lblK.Text = 'API key:'; $lblK.Location = New-Object System.Drawing.Point(12, 81); $lblK.AutoSize = $true
    $txtK = New-Object System.Windows.Forms.TextBox; $txtK.Location = New-Object System.Drawing.Point(100, 78); $txtK.Size = New-Object System.Drawing.Size(290, 24)
    $txtK.UseSystemPasswordChar = $true
    $txtK.Text = $script:Config.opencode_go.api_key   # local edit only; never logged

    $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = 'Model:'; $lblM.Location = New-Object System.Drawing.Point(12, 114); $lblM.AutoSize = $true
    $txtM = New-Object System.Windows.Forms.TextBox; $txtM.Location = New-Object System.Drawing.Point(100, 111); $txtM.Size = New-Object System.Drawing.Size(290, 24)
    $txtM.Text = $script:Config.opencode_go.model

    # Ollama-only context override (0 = hardware preset); OpenCode Go unaffected.
    $lblC = New-Object System.Windows.Forms.Label; $lblC.Text = 'Qwen ctx:'; $lblC.Location = New-Object System.Drawing.Point(12, 148); $lblC.AutoSize = $true
    $txtC = New-Object System.Windows.Forms.TextBox; $txtC.Location = New-Object System.Drawing.Point(100, 145); $txtC.Size = New-Object System.Drawing.Size(290, 24)
    $txtC.Text = [string](Get-OllamaManualContext)

    $chkR = New-Object System.Windows.Forms.CheckBox; $chkR.Text = 'Remember selected provider'; $chkR.Location = New-Object System.Drawing.Point(100, 175); $chkR.AutoSize = $true
    $chkR.Checked = [bool]$script:Config.preferences.remember_provider
    $chkF = New-Object System.Windows.Forms.CheckBox; $chkF.Text = 'Offer Ollama fallback if OpenCode fails (explicit approval)'; $chkF.Location = New-Object System.Drawing.Point(100, 200); $chkF.AutoSize = $true
    $chkF.Checked = [bool]$script:Config.preferences.allow_fallback

    $lblS = New-Object System.Windows.Forms.Label; $lblS.Location = New-Object System.Drawing.Point(12, 258); $lblS.Size = New-Object System.Drawing.Size(300, 30); $lblS.AutoSize = $false

    $btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = 'Test Connection'; $btnTest.Location = New-Object System.Drawing.Point(100, 228); $btnTest.Size = New-Object System.Drawing.Size(120, 26)
    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = 'Save'; $btnSave.Location = New-Object System.Drawing.Point(230, 228); $btnSave.Size = New-Object System.Drawing.Size(80, 26)

    $btnTest.Add_Click({
        $lblS.Text = 'Testing...'
        [System.Windows.Forms.Application]::DoEvents()
        $b = $txtB.Text.TrimEnd('/')
        if ($cmbP.SelectedIndex -eq 1) {
            if ([string]::IsNullOrWhiteSpace($txtK.Text)) { $lblS.Text = 'Enter an API key first'; return }
            try {
                # Real authenticated chat ping: proves endpoint + key + model together.
                # (GET /models is public, so it cannot verify the key.)
                # Body + headers exactly match the verified 200-OK baseline request.
                $mName = if ([string]::IsNullOrWhiteSpace($txtM.Text)) { $script:Config.opencode_go.model } else { $txtM.Text.Trim() }
                $mb = @{
                    model    = $mName
                    messages = @(@{ role = 'user'; content = 'Reply with exactly: Drop connection successful' })
                    stream   = $false
                } | ConvertTo-Json -Depth 5 -Compress
                $hc = New-Object System.Net.Http.HttpClient
                $hc.Timeout = [TimeSpan]::FromSeconds(30)
                $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$b/chat/completions")
                $rq.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $txtK.Text)
                $rq.Headers.TryAddWithoutValidation('User-Agent', 'Drop/1.0') | Out-Null
                $rq.Headers.TryAddWithoutValidation('x-opencode-session', [guid]::NewGuid().ToString()) | Out-Null
                $rq.Content = New-Object System.Net.Http.StringContent($mb, [System.Text.Encoding]::UTF8, 'application/json')
                $rs = $hc.SendAsync($rq).Result
                if ($rs.IsSuccessStatusCode) {
                    $j = $rs.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                    $word = ([string]$j.choices[0].message.content).Trim()
                    if ($word) { $lblS.Text = 'OK - OpenCode Go answered: ' + $word.Substring(0, [math]::Min(30, $word.Length)) }
                    else { $lblS.Text = 'Endpoint OK but response was empty' }
                }
                elseif ([int]$rs.StatusCode -in 401,403) { $lblS.Text = 'Invalid API key (401/403)' }
                else { $lblS.Text = Get-DropErrorKind ([int]$rs.StatusCode) ($rs.Content.ReadAsStringAsync().Result) }
            } catch {
                $ex = $_.Exception
                while ($ex.InnerException) { $ex = $ex.InnerException }
                $lblS.Text = if ($ex -is [System.Security.Authentication.AuthenticationException]) { 'TLS certificate error' }
                             elseif ($ex -is [System.Net.Sockets.SocketException]) { 'Cannot reach endpoint (network/DNS)' }
                             else { "Cannot reach endpoint: $($ex.Message)" }
            }
        } else {
            try {
                if (-not (Prepare-Ollama -StartIfNeeded $true)) { $lblS.Text = 'Ollama could not be started'; return }
                $null = Invoke-RestMethod -Uri "$b/api/tags" -TimeoutSec 5
                $lblS.Text = 'OK - Ollama reachable'
            } catch { $lblS.Text = 'Ollama not reachable at that URL' }
        }
    })
    $btnSave.Add_Click({
        if ($cmbP.SelectedIndex -eq 1) {
            $script:Config.opencode_go.base_url = $txtB.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($txtK.Text)) { $script:Config.opencode_go.api_key = $txtK.Text }
            if (-not [string]::IsNullOrWhiteSpace($txtM.Text)) { $script:Config.opencode_go.model = $txtM.Text.Trim() }
        } else {
            $script:Config.ollama.base_url = $txtB.Text.Trim()
            Set-Variable -Name OllamaUrl -Value $script:Config.ollama.base_url -Scope Script
        }
        # Ollama context override (0 = hardware preset); stored in the ollama
        # section only - the opencode_go config format is untouched.
        $ctxIn = 0
        if ([int]::TryParse($txtC.Text.Trim(), [ref]$ctxIn) -and $ctxIn -ge 0) {
            $script:Config.ollama | Add-Member -NotePropertyName context -NotePropertyValue $ctxIn -Force
        }
        $script:Config.preferences.remember_provider = $chkR.Checked
        $script:Config.preferences.allow_fallback = $chkF.Checked
        Write-DropConfig $script:Config
        $lblS.Text = 'Saved (key stored locally, user-only access)'
        $dlg.Close()
        Switch-Provider $(if ($cmbP.SelectedIndex -eq 1) { 'opencode_go' } else { 'ollama' })
    })

    $dlg.Controls.AddRange(@($lblP, $cmbP, $lblB, $txtB, $lblK, $txtK, $lblM, $txtM, $lblC, $txtC, $chkR, $chkF, $btnTest, $btnSave, $lblS))
    [void]$dlg.ShowDialog()
}

# drag the window by its background
$native = New-Object DropNative
$form.Add_MouseDown({
    if ($_.Button -eq 'Left') { [void][DropNative]::ReleaseCapture(); [void][DropNative]::SendMessage($form.Handle, 0xA1, 2, 0) }
})

function Toggle-Popup {
    if ($form.Visible) {
        $form.Hide()
    } else {
        $form.Show(); $form.Activate()
        # Refresh the Qwen list when shown (newly installed / removed models are
        # picked up). Ollama-only: OpenCode Go never gets extra traffic here.
        if ($script:Provider -eq 'ollama' -and -not $script:Running) {
            [void](Update-OllamaModels $true)
            Set-OllamaStatus
        }
    }
}

# Frontmost gate for the IntelliJ-workflow hotkeys (Ctrl+Alt+R/C/1-0): they
# act only while IntelliJ or Drop itself is frontmost; presses elsewhere are
# ignored. Ctrl+Alt+D stays global and ungated.
function Test-DropHotkeyGate {
    if ([DropNative]::IsIntelliJForeground()) { return $true }
    return ([DropNative]::GetForegroundWindow() -eq $form.Handle)  # Drop itself frontmost
}

# Ctrl+Alt+R: read Desktop/OOP and start the run - headless, never opens the
# popup (the user opens it manually with Ctrl+Alt+D to watch progress).
function Start-OopRun {
    if (-not (Test-DropHotkeyGate)) { Show-Notice 'Ctrl+Alt+R ignored - front window must be IntelliJ or Drop'; return }
    if ($script:Running) { Show-Notice 'Busy - wait for the current result'; return }
    $oop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OOP'
    if (-not (Test-Path -LiteralPath $oop -PathType Container)) {
        Show-Notice 'OOP folder not found on Desktop'; return
    }
    Start-Answer @($oop)   # headless: never calls Toggle-Popup
}

# Slice "…===== Task N ===== …" up to (excluding) the next Task header.
# The model emits headers as "// ===== Task N =====" (per $PromptHeader), so
# each line is TrimStart'ed and an optional leading '//' stripped BEFORE the
# comparison. StartsWith("===== Task $n =====") pins the trailing header text,
# so Task 1 can never match a Task 10 line. Returns $null when absent.
function Get-TaskSection([string]$answer, [int]$n) {
    $lines = $answer -split "`r?`n"
    $header = "===== Task $n ====="
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimStart()
        if ($t.StartsWith('//')) { $t = $t.Substring(2).TrimStart() }
        if ($t.StartsWith($header)) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimStart()
        if ($t.StartsWith('//')) { $t = $t.Substring(2).TrimStart() }
        if ($t.StartsWith("===== Task ")) { $end = $i; break }
    }
    $slice = ($lines[$start..($end - 1)] -join "`r`n").Trim()
    if ([string]::IsNullOrWhiteSpace($slice)) { return $null }
    return $slice
}

# Ctrl+Alt+C: copy the full last answer (same path as the Copy button).
function Copy-AllAnswer {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Show-Notice 'No answer yet'; return }
    [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
    Show-Notice 'Copied - paste with Ctrl+V'
}

# Ctrl+Alt+1..0: copy just Task N's section of the last answer.
function Copy-TaskAnswer([int]$n) {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Show-Notice 'No answer yet'; return }
    $s = Get-TaskSection $script:LastAnswer $n
    if ($null -eq $s) { Show-Notice "Task $n not found in answer"; return }
    [System.Windows.Forms.Clipboard]::SetText($s)
    Show-Notice "Task $n copied - paste with Ctrl+V"
}

# Hotkeys: id 1 = Ctrl+Alt+D (global), 2 = R (OOP run), 3 = C (copy-all,
# Task 4), 4..13 = 1..9,0 (task copy, Task 4). Dispatch by WndProc-recorded id.
$mods = (0x0001 -bor 0x0002 -bor 0x4000)   # Ctrl + Alt + no-repeat
# Registration can fail when another app owns a combo - collect instead of
# discarding, and tell the user after the tray exists (never fail silently).
$hotkeyFails = @()
if (-not [DropNative]::RegisterHotKey($native.Handle, 1, $mods, 0x44)) { $hotkeyFails += 'Ctrl+Alt+D' }   # D
$vkMap = [ordered]@{ 2 = 0x52; 3 = 0x43; 4 = 0x31; 5 = 0x32; 6 = 0x33; 7 = 0x34
                     8 = 0x35; 9 = 0x36; 10 = 0x37; 11 = 0x38; 12 = 0x39; 13 = 0x30 }
foreach ($id in $vkMap.Keys) {
    if (-not [DropNative]::RegisterHotKey($native.Handle, $id, $mods, $vkMap[$id])) {
        $hotkeyFails += ('Ctrl+Alt+' + [char]$vkMap[$id])
    }
}
$native.add_HotKey({
    switch ($native.LastHotKeyId) {
        1 { Toggle-Popup }
        2 { Start-OopRun }
        3 { Copy-AllAnswer }
        { $_ -ge 4 -and $_ -le 13 } { Copy-TaskAnswer ($_ - 3) }
        default { }
    }
})

# tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
if ($form.Icon) { $tray.Icon = $form.Icon } else { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = 'Drop (Ctrl+Alt+D)'
$tray.Visible = $true
if ($hotkeyFails.Count -gt 0) {
    Show-Notice ('Drop hotkeys already used by another app: ' + ($hotkeyFails -join ', ') + ' - those keys will not work')
}
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / Hide', $null, { Toggle-Popup })
[void]$menu.Items.Add('Copy last result', $null, { Copy-Again })
[void]$menu.Items.Add('Settings...', $null, { Show-DropSettings })
[void]$menu.Items.Add('Quit Drop', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Toggle-Popup } })

# ---- generation --------------------------------------------------------------
$script:Running = $false
$script:LastAnswer = ''
$script:Task = $null
$script:Started = $null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(20)
# Ollama generate gets its own client: a truncation retry can legitimately run
# past 20 minutes (16384 tokens at ~8.7 tok/s ≈ 31 min). OpenCode keeps $client.
$ollamaClient = New-Object System.Net.Http.HttpClient
$ollamaClient.Timeout = [TimeSpan]::FromMinutes(45)

function Copy-Again {
    if ($script:LastAnswer) { [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer); Set-Status 'Copied again - paste with Ctrl+V' }
}

# ---- Ollama compile-repair + HOW TO TEST pipeline (Ollama only) ---------------
# Windows previously had no compile check at all. These mirror the mac pipeline:
# deterministic fixers, javac-driven repair rounds (targeted, max 4), and a
# deterministic "// ===== HOW TO TEST =====" block appended at finalize (the
# prompt head forbids the model writing one, so Drop writes it). OpenCode never
# enters this path.

# Strips markdown code fences (mac stripFences parity).
function Remove-DropFences([string]$t) {
    return ((($t -split "`n") | Where-Object { -not $_.TrimStart().StartsWith('```') }) -join "`r`n")
}

# "// ===== FILE: src/main/java/x/Foo.java =====" -> "Foo.java" (mac fileName).
function Get-DropFileName([string]$hdr) {
    $t = $hdr.Trim()
    if (-not $t.StartsWith('// ===== FILE:')) { return $null }
    $rest = $t.Substring('// ===== FILE:'.Length).Trim()
    $tok = ($rest -split ' ')[0]
    if ([string]::IsNullOrEmpty($tok)) { return $null }
    return [System.IO.Path]::GetFileName($tok)
}

# Answer FILE sections -> ordered map name -> @{ Header; Body } (fences stripped).
function Get-DropAnswerFiles([string]$answer) {
    $map = [ordered]@{}
    $hdr = $null
    $buf = New-Object System.Text.StringBuilder
    foreach ($line in ($answer -split "`r?`n")) {
        $t = $line.Trim()
        if ($t.StartsWith('// ===== FILE:')) {
            if ($hdr) {
                $n = Get-DropFileName $hdr
                if ($n) { $map[$n] = @{ Header = $hdr; Body = (Remove-DropFences $buf.ToString()) } }
            }
            $hdr = $line
            [void]$buf.Clear()
        } elseif ($t.StartsWith('// =====')) {
            if ($hdr) {
                $n = Get-DropFileName $hdr
                if ($n) { $map[$n] = @{ Header = $hdr; Body = (Remove-DropFences $buf.ToString()) } }
            }
            $hdr = $null
            [void]$buf.Clear()
        } elseif ($hdr) {
            [void]$buf.AppendLine($line)
        }
    }
    if ($hdr) {
        $n = Get-DropFileName $hdr
        if ($n) { $map[$n] = @{ Header = $hdr; Body = (Remove-DropFences $buf.ToString()) } }
    }
    return $map
}

# mac parseAnswerFiles parity: FILE sections -> "src/main/java/<pkg>/<File>.java" -> body.
function Get-DropParsedFiles([string]$answer) {
    $result = @{}
    $files = Get-DropAnswerFiles $answer
    foreach ($n in @($files.Keys)) {
        $body = [string]($files[$n]).Body
        $pkg = ''
        foreach ($l in ($body -split "`r?`n")) {
            $t = $l.Trim()
            if ($t.StartsWith('package ')) { $pkg = $t.Substring(8).Replace(';', '').Trim(); break }
        }
        $file = [System.IO.Path]::GetFileName([string]$n)
        if (-not $file.EndsWith('.java')) { continue }
        $dir = ''
        if ($pkg -ne '') { $dir = $pkg.Replace('.', '/') + '/' }
        $result["src/main/java/$dir$file"] = $body
    }
    return $result
}

# mac ensureUtilImport parity: "import java.util.*;" after the package line when missing.
function Add-DropUtilImport([string]$code) {
    if ($code.Contains('import java.util.*;')) { return $code }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($code -split "`r?`n"))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('package ')) {
            $lines.Insert($i + 1, 'import java.util.*;')
            return ($lines -join "`r`n")
        }
    }
    return $code
}

# Deterministic sample values for HOW TO TEST lines.
function Get-DropSampleValue([string]$type) {
    $t = $type.Trim()
    if ($t.StartsWith('boolean') -or $t.StartsWith('Boolean')) { return 'true' }
    if ($t.StartsWith('String')) { return '"abc"' }
    if ($t.StartsWith('LocalDateTime')) { return '"2026-01-01T09:00:00"' }
    if ($t.StartsWith('LocalDate')) { return '"2026-01-01"' }
    if ($t.StartsWith('List') -or $t.StartsWith('Set') -or $t.EndsWith('[]')) { return '[]' }
    return '1'
}

# JSON sample from record components or class fields (depth-capped, no crash on cycles).
function Get-DropJsonSample([string]$type, $files, [int]$depth = 0) {
    if ($depth -ge 3) { return '{}' }
    $t = $type.Trim()
    $scalar = ($t.StartsWith('int') -or $t.StartsWith('long') -or $t.StartsWith('double') -or $t.StartsWith('float') -or
               $t.StartsWith('Integer') -or $t.StartsWith('Long') -or $t.StartsWith('Double') -or $t.StartsWith('boolean') -or
               $t.StartsWith('Boolean') -or $t.StartsWith('String') -or $t.StartsWith('LocalDate') -or
               $t.StartsWith('List') -or $t.StartsWith('Set') -or $t.EndsWith('[]'))
    if ($scalar) { return (Get-DropSampleValue $t) }
    $esc = [regex]::Escape($t)
    foreach ($n in @($files.Keys)) {
        $body = [string]($files[$n]).Body
        $m = [regex]::Match($body, 'record\s+' + $esc + '\s*\(([^)]*)\)')
        if ($m.Success) {
            $pairs = @()
            foreach ($c in ($m.Groups[1].Value -split ',')) {
                $parts = @(($c.Trim() -split '\s+') | Where-Object { $_ -ne '' })
                if ($parts.Count -ge 2) { $pairs += ('"' + $parts[1] + '": ' + (Get-DropJsonSample $parts[0] $files ($depth + 1))) }
            }
            if ($pairs.Count -gt 0) { return '{' + ($pairs -join ', ') + '}' }
        }
        if ([regex]::IsMatch($body, '(?:class|record)\s+' + $esc + '\b')) {
            $pairs = @()
            foreach ($m in [regex]::Matches($body, '(?:private|protected)\s+(?:final\s+)?([A-Za-z0-9_<>, \[\]]+?)\s+(\w+)\s*[;=]')) {
                $ftype = $m.Groups[1].Value.Trim()
                if ($ftype -eq 'static') { continue }
                $pairs += ('"' + $m.Groups[2].Value + '": ' + (Get-DropJsonSample $ftype $files ($depth + 1)))
            }
            if ($pairs.Count -gt 0) { return '{' + ($pairs -join ', ') + '}' }
        }
    }
    return '{}'
}

# mac nameRequestParams parity: explicit names on @PathVariable / @RequestParam.
function Fix-DropNameRequestParams([string]$code) {
    $re = New-Object System.Text.RegularExpressions.Regex '@(PathVariable|RequestParam)(\(([^)]*)\))?(\s+)(final\s+)?([\w.<>\[\],?]+)\s+(\w+)'
    $sb = New-Object System.Text.StringBuilder
    $last = 0
    foreach ($m in $re.Matches($code)) {
        $ann = $m.Groups[1].Value
        $space = $m.Groups[4].Value
        $fin = $m.Groups[5].Value
        $type = $m.Groups[6].Value
        $name = $m.Groups[7].Value
        if ($m.Groups[2].Success) {
            $a = $m.Groups[3].Value.Trim()
            if ($a -eq '') { $newAnn = "@$ann(""$name"")" }
            elseif ($a.StartsWith('"') -or $a.Contains('name') -or $a.Contains('value')) { continue }
            else { $newAnn = "@$ann(name = ""$name"", $a)" }
        } else {
            $newAnn = "@$ann(""$name"")"
        }
        [void]$sb.Append($code.Substring($last, $m.Index - $last))
        [void]$sb.Append($newAnn + $space + $fin + $type + ' ' + $name)
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($code.Substring($last))
    return $sb.ToString()
}

# mac fixReasonOrder parity: DEADLINE check must come before RELEASE_OUTSIDE_WINDOW.
function Fix-DropReasonOrder([string]$code) {
    $pat = '(if \([^{]*\)\s*\{[^{}]*"RELEASE_OUTSIDE_WINDOW"[^{}]*\})(\s*)(if \([^{]*\)\s*\{[^{}]*"DEADLINE"[^{}]*\})'
    return [regex]::Replace($code, $pat, '$3$2$1')
}

# mac alignControllerReturns parity: controller return type matches the service method's.
function Fix-DropControllerReturns([string]$answer, $starter) {
    $types = @{}
    $sig = New-Object System.Text.RegularExpressions.Regex 'public\s+([A-Za-z0-9_<>, ?\[\]]+?)\s+([a-zA-Z0-9_]+)\s*\('
    $files = Get-DropAnswerFiles $answer
    foreach ($n in @($files.Keys)) {
        if (-not ([string]$n).EndsWith('Service.java')) { continue }
        foreach ($m in $sig.Matches([string]($files[$n]).Body)) {
            $type = $m.Groups[1].Value.Trim()
            $name = $m.Groups[2].Value
            if ($type -eq 'class' -or $type.EndsWith(' class')) { continue }
            if (-not $types.Contains($name)) { $types[$name] = $type }
        }
    }
    if ($starter) {
        foreach ($k in @($starter.Keys)) {
            if (-not ([string]$k).EndsWith('Service.java')) { continue }
            foreach ($m in $sig.Matches([string]$starter[$k])) {
                $type = $m.Groups[1].Value.Trim()
                $name = $m.Groups[2].Value
                if ($type -eq 'class' -or $type.EndsWith(' class')) { continue }
                if (-not $types.Contains($name)) { $types[$name] = $type }
            }
        }
    }
    if ($types.Count -eq 0) { return $answer }
    $ctl = New-Object System.Text.RegularExpressions.Regex '(public\s+)([A-Za-z0-9_<>, ?\[\]]+?)(\s+[a-zA-Z0-9_]+\s*\([^)]*\)\s*\{\s*return\s+[a-zA-Z0-9_]+\.)([a-zA-Z0-9_]+)\s*\('
    $overlay = New-Object System.Text.StringBuilder
    $changed = $false
    foreach ($n in @($files.Keys)) {
        if (-not ([string]$n).EndsWith('Controller.java')) { continue }
        $body = [string]($files[$n]).Body
        $new = $body
        $ms = $ctl.Matches($new)
        for ($i = $ms.Count - 1; $i -ge 0; $i--) {
            $m = $ms[$i]
            $have = $m.Groups[2].Value.Trim()
            $call = $m.Groups[4].Value
            if (-not $types.Contains($call)) { continue }
            $want = [string]$types[$call]
            if ($want -eq $have) { continue }
            if ($have.StartsWith('ResponseEntity') -or $have.StartsWith('Map') -or $want -eq 'void') { continue }
            $g2 = $m.Groups[2]
            $new = $new.Substring(0, $g2.Index) + $want + $new.Substring($g2.Index + $g2.Length)
        }
        if ($new -ne $body) {
            $changed = $true
            [void]$overlay.AppendLine([string]($files[$n]).Header)
            [void]$overlay.Append($new)
            [void]$overlay.Append("`r`n")
        }
    }
    if (-not $changed) { return $answer }
    return Merge-DropFixes $answer $overlay.ToString()
}

# mac staticFixes parity: every deterministic fixer in the right order (Ollama only).
function Invoke-DropStaticFixes([string]$answer) {
    $a = Fix-DropNameRequestParams $answer
    $a = Fix-DropReasonOrder $a
    $a = Fix-DropControllerReturns $a $script:StarterFiles
    return $a
}

# mac mergeFixes parity: replace FILE sections by name, new files before HOW TO TEST.
function Merge-DropFixes([string]$answer, [string]$fixes) {
    $fixMap = Get-DropAnswerFiles $fixes
    if ($fixMap.Count -eq 0) { return $answer }
    $secs = New-Object System.Collections.Generic.List[object]
    $secs.Add(@{ Header = $null; Lines = (New-Object System.Text.StringBuilder) })
    foreach ($line in ($answer -split "`r?`n")) {
        if ($line.TrimStart().StartsWith('// =====')) {
            $secs.Add(@{ Header = $line; Lines = (New-Object System.Text.StringBuilder) })
        } else {
            [void]$secs[$secs.Count - 1].Lines.AppendLine($line)
        }
    }
    $used = @{}
    $out = New-Object System.Text.StringBuilder
    foreach ($sec in $secs) {
        $h = $sec.Header
        $n = if ($h) { Get-DropFileName $h } else { $null }
        if ($n -and $fixMap.Contains($n)) {
            [void]$out.AppendLine([string]($fixMap[$n]).Header)
            [void]$out.Append([string]($fixMap[$n]).Body)
            $used[$n] = $true
        } else {
            if ($h -and $h.Contains('HOW TO TEST')) {
                foreach ($k in @($fixMap.Keys)) {
                    if (-not $used.Contains($k)) {
                        $used[$k] = $true
                        [void]$out.AppendLine([string]($fixMap[$k]).Header)
                        [void]$out.Append([string]($fixMap[$k]).Body)
                    }
                }
            }
            if ($h) { [void]$out.AppendLine($h) }
            [void]$out.Append($sec.Lines.ToString())
        }
    }
    foreach ($k in @($fixMap.Keys)) {
        if (-not $used.Contains($k)) {
            $used[$k] = $true
            [void]$out.AppendLine([string]($fixMap[$k]).Header)
            [void]$out.Append([string]($fixMap[$k]).Body)
        }
    }
    return $out.ToString()
}

# mac repairContext parity: the sources javac implicated, COMPLETE, plus the ones
# they reference - never the full question, never unchanged answer files. Falls
# back to all answer files when the error lines name nothing. 40k budget.
function Get-DropRepairContext([string]$answer, [string]$errs) {
    $sources = @{}
    if ($script:StarterFiles) { foreach ($k in @($script:StarterFiles.Keys)) { $sources[$k] = [string]$script:StarterFiles[$k] } }
    $parsed = Get-DropParsedFiles $answer
    foreach ($k in @($parsed.Keys)) { $sources[$k] = Add-DropUtilImport ([string]$parsed[$k]) }
    $names = @{}
    $re = New-Object System.Text.RegularExpressions.Regex '([A-Za-z0-9_$.]+\.java):\d+'
    foreach ($m in $re.Matches($errs)) { $names[$m.Groups[1].Value] = $true }
    $affected = @()
    foreach ($k in @($sources.Keys)) {
        $leaf = [System.IO.Path]::GetFileName([string]$k)
        if ($names.Contains($leaf)) { $affected += [string]$k }
    }
    if ($affected.Count -eq 0) { $affected = @($parsed.Keys) }
    $out = New-Object System.Text.StringBuilder
    $seen = @{}
    $referenced = @{}
    foreach ($k in ($affected | Sort-Object)) {
        if (-not $sources.Contains($k)) { continue }
        $body = [string]$sources[$k]
        [void]$out.AppendLine("// ===== FILE: $k =====")
        [void]$out.Append($body)
        [void]$out.Append("`r`n")
        $seen[$k] = $true
        foreach ($sk in @($sources.Keys)) {
            if ($seen.Contains($sk)) { continue }
            $cls = [System.IO.Path]::GetFileNameWithoutExtension([string]$sk)
            if ($cls -and $body.Contains($cls)) { $referenced[$sk] = $true }
        }
    }
    $total = $out.Length
    foreach ($k in ($referenced.Keys | Sort-Object)) {
        $body = [string]$sources[$k]
        if ($total + $body.Length -ge 40000) { continue }
        [void]$out.AppendLine("// ===== FILE: $k =====")
        [void]$out.Append($body)
        [void]$out.Append("`r`n")
        $seen[$k] = $true
        $total += $body.Length
    }
    return $out.ToString()
}

# javac discovery: JAVA_HOME, then common JDK installs (Temurin/Microsoft/IntelliJ/.jdks), then PATH.
function Find-DropJavac {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\javac.exe') }
    foreach ($root in @("$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Zulu", "$env:LOCALAPPDATA\Programs\Java", "$env:USERPROFILE\.jdks")) {
        if ($root -and (Test-Path -LiteralPath $root)) {
            foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                $candidates += (Join-Path $d.FullName 'bin\javac.exe')
                $candidates += (Join-Path $d.FullName 'jbr\bin\javac.exe')
            }
        }
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command javac -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ~/.m2 Spring + Jakarta + Jackson jars (mac parity); sources/javadoc skipped.
# $null when spring-web is missing: a partial classpath is not a real compile check.
function Get-DropSpringJars {
    $m2 = Join-Path $env:USERPROFILE '.m2\repository'
    $jars = @()
    foreach ($sub in @('org\springframework', 'jakarta', 'com\fasterxml\jackson')) {
        $dir = Join-Path $m2 $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $jars += (Get-ChildItem -LiteralPath $dir -Recurse -File -Filter *.jar -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'sources|javadoc' } |
                  ForEach-Object { $_.FullName })
    }
    if (-not ($jars | Where-Object { $_ -match 'spring-web' })) { return $null }
    return $jars
}

# $null = cannot check (no starter / no JDK / no Spring jars), '' = compiles,
# otherwise javac's FULL error output (tmp paths stripped). Full compile every
# round: partial subsets gave the repair model noisy partial error sets (mac parity).
function Get-DropCompileErrors([string]$answer) {
    if (-not $script:StarterFiles -or $script:StarterFiles.Count -eq 0) { return $null }
    $javac = Find-DropJavac
    if (-not $javac) { return $null }
    $jars = Get-DropSpringJars
    if (-not $jars) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dropc-' + [guid]::NewGuid().ToString())
    $outDir = Join-Path $tmp 'out'
    [void](New-Item -ItemType Directory -Path $outDir -Force)
    $sources = @{}
    foreach ($k in @($script:StarterFiles.Keys)) { $sources[$k] = [string]$script:StarterFiles[$k] }
    $parsed = Get-DropParsedFiles $answer
    foreach ($k in @($parsed.Keys)) { $sources[$k] = Add-DropUtilImport ([string]$parsed[$k]) }
    $paths = @()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($k in @($sources.Keys)) {
        $dest = Join-Path $tmp ([string]$k)
        $dir = Split-Path -Parent $dest
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [System.IO.File]::WriteAllText($dest, [string]$sources[$k], $utf8)
        $paths += $dest
    }
    # Sources stay reachable through -sourcepath. The root must be the PACKAGE
    # root (src/main/java), not the tmp root; the bare tmp root is kept as a
    # second entry for flat layouts (mac parity).
    $srcRoot = Join-Path $tmp 'src\main\java'
    $argList = @('--release', '17', '-proc:none', '-nowarn', '-encoding', 'UTF-8',
                 '-d', $outDir, '-cp', ($jars -join ';'), '-sourcepath', ($srcRoot + ';' + $tmp))
    $argList += $paths
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $javac
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($argList | ForEach-Object {
        $a = [string]$_
        if ($a -match '\s') { '"' + $a + '"' } else { $a }
    }) -join ' ')
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $p.WaitForExit()
    $text = $errTask.Result + $outTask.Result
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # Old JDKs reject --release: cannot check - never fake an error feed.
    if ($text -match 'invalid flag|unrecognized option') { return $null }
    if ($p.ExitCode -eq 0) { return '' }
    return ($text -replace [regex]::Escape($tmp + '\'), '')
}

# One targeted repair round (mac parity): errors + implicated sources only,
# never the full question and previous answer. $true = repair dispatched.
function Start-DropRepairRound([string]$answer, [string]$errs) {
    if ($script:RepairRounds -ge 4) { return $false }
    $script:RepairRounds++
    $script:RepairBase = $answer
    $cap = [string]$errs
    if ($cap.Length -gt 6000) { $cap = $cap.Substring(0, 6000) }
    $n = ([regex]::Matches($errs, 'error:')).Count
    $prompt = $OllamaRepairHeader + "`n`n######## JAVAC ERRORS ########`n" + $cap + "`n`n######## AFFECTED FILES ########`n" + (Get-DropRepairContext $answer $errs)
    $script:Phase = 3
    Set-Status ("Fixing {0} compile error(s)..." -f $n)
    Send-Prompt $prompt
    return $true
}

# Ollama pipeline entry: deterministic fixers first, then compile + repair rounds.
function Start-DropOllamaPipeline([string]$answer) {
    $answer = Remove-DropFences $answer
    $answer = Invoke-DropStaticFixes $answer
    $script:RepairRounds = 0
    Set-Status 'Compiling...'
    $errs = Get-DropCompileErrors $answer
    if ($null -eq $errs) { Complete-DropAnswer $answer $null; return }    # cannot check
    if ($errs -eq '') { Complete-DropAnswer $answer $true; return }        # compiles
    if (Start-DropRepairRound $answer $errs) { return }                    # repair in flight
    Complete-DropAnswer $answer $false                                     # rounds exhausted
}

# Repair response arrived: merge what changed, fix, recompile, loop (mac parity,
# including the no-op stop when the model changed nothing usable).
function Complete-DropPhase3([string]$answer) {
    $fixes = Remove-DropFences $answer
    $merged = Merge-DropFixes $script:RepairBase $fixes
    if ($merged -eq $script:RepairBase) {
        Complete-DropAnswer $script:RepairBase $false
        return
    }
    $answer = Invoke-DropStaticFixes $merged
    Set-Status 'Compiling...'
    $errs = Get-DropCompileErrors $answer
    if ($null -eq $errs) { Complete-DropAnswer $answer $null; return }
    if ($errs -eq '') { Complete-DropAnswer $answer $true; return }
    if (Start-DropRepairRound $answer $errs) { return }
    Complete-DropAnswer $answer $false
}

# Finalize: HOW TO TEST block, clipboard, honest compile-state notice (mac parity).
function Complete-DropAnswer([string]$answer, $compiled) {
    $answer = Add-DropHowToTest $answer
    $script:Running = $false
    $answer = $answer.Trim()
    $script:LastAnswer = $answer
    $box.Text = $answer
    [System.Windows.Forms.Clipboard]::SetText($answer)
    [System.Media.SystemSounds]::Asterisk.Play()
    if ($compiled -eq $true) {
        Show-Notice 'Done! Copied - compiles'
    } elseif ($compiled -eq $false) {
        Show-Notice 'Done! Copied - but still has compile errors - check IntelliJ'
    } elseif (-not $script:StarterFiles -or $script:StarterFiles.Count -eq 0) {
        Show-Notice 'Done! Copied (no starter to compile-check)'
    } else {
        Show-Notice 'Done! Copied (no JDK/Spring found to compile-check)'
    }
}

# The prompt head forbids the model writing a HOW TO TEST section, so Drop
# appends one deterministically at finalize (Ollama only): numbered curl lines
# for the real Spring mappings, or a javac/java recipe for plain Java. Every
# line is a "//" comment, so the pasted answer stays pure code.
function Add-DropHowToTest([string]$answer) {
    $base = $answer
    $i = $base.IndexOf('// ===== HOW TO TEST')
    if ($i -ge 0) {
        $cut = $base.Length
        $j = $base.IndexOf("`n// ===== FILE:", $i)
        if ($j -ge 0) { $cut = $j }
        $base = $base.Substring(0, $i) + $base.Substring($cut)
    }
    $base = $base.Trim()
    $files = Get-DropAnswerFiles $base
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add('// ===== HOW TO TEST =====')
    $isSpring = $false
    foreach ($n in @($files.Keys)) {
        if ([regex]::IsMatch([string]($files[$n]).Body, '@(Rest)?Controller|@(Get|Post|Put|Delete|Patch|Request)Mapping')) { $isSpring = $true; break }
    }
    if ($isSpring) {
        $lines.Add('// 1. Start the app: mvn spring-boot:run')
        $port = '8080'
        foreach ($n in @($files.Keys)) {
            $m = [regex]::Match([string]($files[$n]).Body, 'server\.port\s*=\s*(\d+)')
            if ($m.Success) { $port = $m.Groups[1].Value }
        }
        $step = 2
        foreach ($n in @($files.Keys)) {
            $body = [string]($files[$n]).Body
            if (-not [regex]::IsMatch($body, '@(GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping|RequestMapping)')) { continue }
            $classLoc = $body.IndexOf('class ')
            if ($classLoc -lt 0) { $classLoc = 0 }
            $prefix = ''
            $m = [regex]::Match($body.Substring(0, $classLoc), '@RequestMapping\(\s*(?:(?:value|name)\s*=\s*)?"([^"]*)"')
            if ($m.Success) { $prefix = $m.Groups[1].Value }
            $inner = $body.Substring($classLoc)
            $hits = @()
            foreach ($m in [regex]::Matches($inner, '@(GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping)\s*(?:\(\s*(?:(?:value|name)\s*=\s*)?"([^"]*)"|\(\s*\{\s*"([^"]*)")?')) {
                # GetMapping -> Get -> GET: curl needs the HTTP verb, never the
                # annotation name.
                $verb = $m.Groups[1].Value.Replace('Mapping', '')
                $p = ''
                if ($m.Groups[2].Success) { $p = $m.Groups[2].Value } elseif ($m.Groups[3].Success) { $p = $m.Groups[3].Value }
                $hits += ,@($verb, $p, ($m.Index + $classLoc), $m.Length)
            }
            foreach ($m in [regex]::Matches($inner, '@RequestMapping\(([^)]*)\)')) {
                $args = $m.Groups[1].Value
                $rm = [regex]::Match($args, 'method\s*=\s*RequestMethod\.(\w+)')
                if (-not $rm.Success) { continue }
                $verb = $rm.Groups[1].Value
                $p = ''
                $pm = [regex]::Match($args, '"([^"]*)"')
                if ($pm.Success) { $p = $pm.Groups[1].Value }
                $hits += ,@($verb, $p, ($m.Index + $classLoc), $m.Length)
            }
            foreach ($h in $hits) {
                $verb = $h[0]; $p = $h[1]; $mIdx = $h[2]; $mLen = $h[3]
                $path = ($prefix + $p) -replace '\{[^}]+?\}', '1'
                if (-not $path.StartsWith('/')) { $path = '/' + $path }
                $after = $mIdx + $mLen
                $brace = $body.IndexOf('{', $after)
                if ($brace -lt 0) { $brace = $body.Length }
                $sig = $body.Substring($after, $brace - $after)
                $query = @()
                foreach ($m in [regex]::Matches($sig, '@RequestParam(?:\(\s*(?:(?:value|name)\s*=\s*)?"([^"]*)"[^)]*\))?\s+(?:final\s+)?([\w.<>\[\]]+)\s+(\w+)')) {
                    $qn = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[3].Value }
                    $qv = (Get-DropSampleValue $m.Groups[2].Value) -replace '"', ''
                    $query += ($qn + '=' + $qv)
                }
                $json = ''
                $m = [regex]::Match($sig, '@RequestBody(?:\([^)]*\))?\s+(?:final\s+)?([\w.<>\[\]]+)\s+\w+')
                if ($m.Success) { $json = Get-DropJsonSample $m.Groups[1].Value $files }
                $url = 'http://localhost:' + $port + $path
                if ($query.Count -gt 0) { $url += '?' + ($query -join '&') }
                $line = '// ' + $step + '. Try it: curl -X ' + $verb.ToUpperInvariant() + " '" + $url + "'"
                if ($json -ne '') { $line += ' -H "Content-Type: application/json" -d ' + "'" + $json + "'" }
                $lines.Add($line)
                $step++
            }
        }
        if ($step -eq 2) { $lines.Add('// 2. Call the controller endpoints (paths are in the mappings above)') }
    } else {
        $hasMain = $false
        $mainCls = 'Main'
        foreach ($n in @($files.Keys)) {
            $body = [string]($files[$n]).Body
            if ([regex]::IsMatch($body, 'static\s+void\s+main\s*\(')) {
                $hasMain = $true
                $pkg = ''
                $m = [regex]::Match($body, '(?m)^\s*package\s+([\w.]+)\s*;')
                if ($m.Success) { $pkg = $m.Groups[1].Value }
                $cls = [string]$n -replace '\.java$', ''
                if ($pkg -ne '') { $mainCls = $pkg + '.' + $cls } else { $mainCls = $cls }
                break
            }
        }
        if ($hasMain) {
            # plain Java: javac/java recipe around the class with "static void main"
            $lines.Add('// 1. Compile: javac -d out *.java')
            $lines.Add('// 2. Run:     java -cp out ' + $mainCls)
        } else {
            $lines.Add('// 1. Open the project in IntelliJ and run the main class')
            $lines.Add('// 2. Or from a terminal: javac -d out *.java then java -cp out <MainClass>')
        }
    }
    return $base + "`r`n" + ($lines -join "`r`n") + "`r`n"
}

function Start-Answer([string[]]$paths) {
    if ($script:Running) { Show-Notice 'Busy - wait for the current result'; return }
    $res = Collect-Input $paths
    $paper = $res[0]; $n = $res[1]
    $script:StarterFiles = $res[2]
    if (($paper -split '\s+').Count -lt 15) {
        if ($n -eq 0) {
            # Windows has no built-in PDF text extraction (macOS uses PDFKit):
            # point at the one dependency instead of failing invisibly.
            Show-Notice 'No readable files - PDF papers need pdftotext (install Poppler: winget install oschwartz10612.Poppler)'
        } else { Show-Notice 'No readable text found' }
        return
    }
    if ($script:Provider -eq 'ollama' -and [string]::IsNullOrWhiteSpace($script:Model)) {
        # Never send a request for a model that does not exist.
        Show-Notice 'No Qwen model installed - ollama pull a Qwen model first'
        return
    }
    $script:Paper = $paper
    $script:Files = $n
    $script:Phase = 1
    $script:Attempt = 0
    $script:SessionId = [guid]::NewGuid().ToString()   # new conversation → new session id
    $box.Text = ''
    $script:Running = $true
    # Prompt fork: Ollama gets the student-level rules (silent checks); OpenCode
    # keeps its pinned $PromptHeader byte-for-byte.
    $hdr = $PromptHeader
    if ($script:Provider -eq 'ollama') { $hdr = $OllamaPromptHeader }
    Send-Prompt ($hdr + "`n`n" + $paper)
    Show-Notice "Read $n file(s) - thinking..."
}

# ---- provider adapters (Phase 4/5) -------------------------------------------
# Error classification (Phase 7A): distinct conditions, never one generic blob.
function Get-DropErrorKind([int]$Status, [string]$Body) {
    # The provider's own explanation of WHY the request was rejected - this is
    # what turns a bare "Invalid request (400)" into an actionable message.
    # Parsed defensively; capped; never contains the API key.
    $extra = ''
    if ($Body) {
        if ($Body -match '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        elseif ($Body -match '"error"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        elseif ($Body -match '"detail"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        if ($extra) {
            $extra = $extra -replace '\\n', ' ' -replace '\\r', ' ' -replace '\\"', '"' -replace '\\/', '/'
            if ($extra.Length -gt 160) { $extra = $extra.Substring(0, 160) }
            $extra = ' - ' + $extra
        }
    }
    switch ($Status) {
        400 { return "Invalid request (400)$extra" }
        401 { return "Invalid API key (401)$extra" }
        403 { return "Access denied (403)$extra" }
        404 { return "Endpoint or model not found (404)$extra" }
        408 { return "Request timeout (408)$extra" }
        429 { return "Rate limited (429)$extra" }
        { $_ -ge 500 -and $_ -le 599 } { return "Provider server error ($Status)$extra" }
        default {
            if ($extra) { return "HTTP $Status$extra" }
            return "HTTP $Status"
        }
    }
}

function Test-DropTransient([int]$Status) {
    # Retry only transient conditions; never auth/400/404.
    return ($Status -eq 408 -or $Status -eq 429 -or ($Status -ge 500 -and $Status -le 599))
}

$script:Attempt = 0

function Send-Prompt([string]$prompt) {
    $script:Started = Get-Date
    $script:LastPrompt = $prompt
    if ($script:Provider -eq 'opencode_go') {
        $cfg = $script:Config
        if ([string]::IsNullOrWhiteSpace($cfg.opencode_go.api_key)) {
            $script:Running = $false
            Set-Status 'No OpenCode API key - open Settings from the tray'
            return
        }
        $base = $cfg.opencode_go.base_url.TrimEnd('/')
        # Phase 7D: bounded retries with exponential backoff + jitter (Windows side
        # retries at the Send-Prompt level via the timer's transient classification).
        # Exact shape of the verified (200 OK) baseline request — no extra fields.
        $body = @{
            model    = $cfg.opencode_go.model
            messages = @(@{ role = 'user'; content = $prompt })
            stream   = $false            # Phase 10: Windows keeps non-streaming for now
        } | ConvertTo-Json -Depth 5 -Compress
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$base/chat/completions")
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $cfg.opencode_go.api_key)
        $req.Headers.TryAddWithoutValidation('User-Agent', 'Drop/1.0') | Out-Null
        $req.Headers.TryAddWithoutValidation('x-opencode-session', $script:SessionId) | Out-Null
        $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $script:Task = $client.SendAsync($req)
        return
    }
    # Ollama path (stream:false, keep_alive 0, num_ctx). Final context =
    # growth + floor + hard cap + automatic ceiling. On the automatic path a
    # request whose prompt alone exceeds the ceiling is blocked (never
    # truncated) and pointed at Settings.
    $ctx = Get-OllamaFinalContext $prompt
    if ((Get-OllamaManualContext) -le 0 -and [int]($prompt.Length / 3) -gt $ctx) {
        Set-Status "Prompt too large for automatic context ceiling ($ctx tokens) - raise Qwen ctx in Settings (large contexts use more memory)"
        $script:Running = $false
        return
    }
    if (-not (Prepare-Ollama -StartIfNeeded $true)) {
        Set-Status 'Ollama not running and could not be started'
        $script:Running = $false
        return
    }
    # think = $true matches the backup branch (no think key sent there; qwen3
    # defaults to thinking) - that reasoning keeps the code faithful to the
    # paper's spec. Ollama returns it in its own "thinking" field; the parser
    # reads .response only, so the answer stays pure code. Thinking tokens
    # share the context window; a cut answer is completed by the compile-
    # repair pipeline. Ignored by models without a thinking mode. Ollama
    # request only. num_predict = task-scaled output cap (4096-8192) so one
    # request can never grind for hours; the compile-repair pipeline
    # completes anything it cuts.
    $body = @{ model = $script:Model; prompt = $prompt; stream = $false; think = $true; keep_alive = 0; options = @{ num_ctx = $ctx; temperature = 0.2; num_predict = (Get-OllamaNumPredict $script:Paper) } } | ConvertTo-Json -Depth 5 -Compress
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    $script:Task = $ollamaClient.PostAsync("$OllamaUrl/api/generate", $content)
}

$script:DoubleCheck = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if (-not $script:Running -or $null -eq $script:Task) { return }
    if (-not $script:Task.IsCompleted) {
        $secs = [int]((Get-Date) - $script:Started).TotalSeconds
        if ($script:Phase -eq 1) { $label = 'thinking' } elseif ($script:Phase -eq 3) { $label = 'fixing compile errors' } else { $label = 'double-checking' }
        Set-Status ("{0} file(s) - {1}... {2}s" -f $script:Files, $label, $secs)
        return
    }
    try {
        if ($script:Task.IsFaulted) { throw $script:Task.Exception.InnerException }
        $resp = $script:Task.Result
        $text = $resp.Content.ReadAsStringAsync().Result
        if (-not $resp.IsSuccessStatusCode) {
            $status = [int]$resp.StatusCode
            $kind = Get-DropErrorKind $status $text
            # Phase 7D: retry transient errors with exponential backoff + jitter.
            # Never retry auth/400/404. Retry-After honoured when present.
            $maxAttempts = [int]$script:Config.network.retry_attempts
            if ((Test-DropTransient $status) -and $script:Attempt -lt ($maxAttempts - 1) -and $script:Config.network.retry_backoff) {
                $script:Attempt++
                $delay = [math]::Pow(2, $script:Attempt - 1) + (Get-Random -Minimum 0 -Maximum 500) / 1000.0
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $delay = [math]::Max($delay, $ra.Delta.TotalSeconds) }
                Set-Status ("{0} - retry {1}/{2} in {3:N1}s..." -f $kind, $script:Attempt, ($maxAttempts - 1), $delay)
                Start-Sleep -Seconds $delay
                Send-Prompt $script:LastPrompt
                return
            }
            # Phase 7F: endpoint unreachable on this network? Offer Ollama only with approval.
            $msg = $kind
            # Ollama context rejections: point at the manual Qwen ctx setting.
            if ($script:Provider -eq 'ollama' -and $text -match 'context') {
                $msg += ' - raise Qwen ctx in Settings'
            }
            if ($script:Provider -eq 'opencode_go' -and ($status -in 408,429 -or $status -ge 500 -or $kind -match 'unreachable|timeout')) {
                if ($script:Config.preferences.allow_fallback) {
                    $r = [System.Windows.Forms.MessageBox]::Show(
                        "$kind`n`nSwitch to Ollama (local) for this answer?",
                        'OpenCode Go unavailable', 'YesNo', 'Warning')
                    if ($r -eq 'Yes') {
                        Switch-Provider 'ollama'
                        # Re-send the exact same request through the approved
                        # provider; timer keeps running (Running stays true).
                        # If Ollama also fails, its error path stops cleanly -
                        # no fallback loop (retry is OpenCode-only).
                        Send-Prompt $script:LastPrompt
                        return
                    }
                } else {
                    $msg = "$kind - this network may restrict access (Ollama fallback is off in Settings)"
                }
            }
            $script:Running = $false
            Set-Status $msg
            $box.Text = $text.Substring(0, [math]::Min(500, $text.Length))
            return
        }
        $obj = $text | ConvertFrom-Json
        if ($script:Provider -eq 'opencode_go') {
            # OpenAI-compatible: choices[0].message.content (defensive parse)
            $answer = ''
            if ($obj.choices -and $obj.choices.Count -gt 0) { $answer = [string]$obj.choices[0].message.content }
            if ([string]::IsNullOrWhiteSpace($answer)) {
                $script:Running = $false
                $errTxt = if ($obj.error.message) { [string]$obj.error.message } else { 'empty response' }
                Set-Status "OpenCode error: $errTxt"
                $box.Text = $text.Substring(0, [math]::Min(500, $text.Length))
                return
            }
        } else {
            $answer = [string]$obj.response
            # Cut-answer guard (Ollama only): a cut answer is NEVER discarded
            # and never regenerated from scratch - it falls through to the
            # javac compile-repair pipeline below, which completes it (fixers +
            # up to 4 repair rounds) and copies the honest result. Only an
            # empty answer is a failure.
            if ($script:Provider -eq 'ollama' -and (Test-OllamaTruncated $obj)) {
                if ([string]::IsNullOrWhiteSpace($answer)) {
                    $script:Running = $false
                    Show-Notice 'Context limit reached - no answer produced - raise Qwen ctx in Settings'
                    return
                }
                Set-Status 'Answer cut short by the context - completing via compile repair...'
            }
        }
        $script:Attempt = 0
        if ($script:Phase -eq 1 -and $script:DoubleCheck) {
            $script:Draft = $answer
            $script:Phase = 2
            $rulesHdr = $PromptHeader
            $revHdr = $ReviewHeader
            if ($script:Provider -eq 'ollama') { $rulesHdr = $OllamaPromptHeader; $revHdr = $OllamaReviewHeader }
            Send-Prompt ($revHdr + "`n`n######## RULES ########`n" + $rulesHdr + "`n`n" + $script:Paper + "`n`n######## DRAFT SOLUTION ########`n" + $answer)
            return
        }
        if ($script:Phase -eq 2 -and $answer.Length -lt ($script:Draft.Length / 3)) { $answer = $script:Draft }
        if ($script:Provider -eq 'ollama') {
            # Ollama-only pipeline: deterministic fixers + javac repair rounds +
            # deterministic HOW TO TEST. OpenCode keeps the plain finalize below.
            if ($script:Phase -eq 3) { Complete-DropPhase3 $answer } else { Start-DropOllamaPipeline $answer }
            return
        }
        $script:Running = $false
        $answer = ($answer -split "`n" | Where-Object { -not $_.TrimStart().StartsWith('```') }) -join "`r`n"
        $answer = $answer.Trim()
        $script:LastAnswer = $answer
        $box.Text = $answer
        [System.Windows.Forms.Clipboard]::SetText($answer)
        [System.Media.SystemSounds]::Asterisk.Play()
        Show-Notice 'Done! Copied - paste with Ctrl+V'
    } catch {
        if ($script:Phase -eq 2 -and $script:Draft) {
            $script:Running = $false
            $script:LastAnswer = $script:Draft.Trim(); $box.Text = $script:LastAnswer
            [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
            Show-Notice 'Check failed - draft copied (Ctrl+V)'
            return
        }
        # Phase 7A: classify the transport failure instead of one generic message.
        $inner = $script:Task.Exception
        while ($inner -and $inner.InnerException) { $inner = $inner.InnerException }
        $msg = 'Error'
        if ($inner -is [System.Net.Sockets.SocketException]) {
            $msg = switch ($inner.SocketErrorCode) {
                ([System.Net.Sockets.SocketError]::HostNotFound) { 'DNS lookup failed' }
                ([System.Net.Sockets.SocketError]::TryAgain)    { 'DNS lookup failed' }
                ([System.Net.Sockets.SocketError]::ConnectionRefused) { 'Connection refused - server not running or blocked' }
                ([System.Net.Sockets.SocketError]::TimedOut)    { 'Connection timed out' }
                default { "Network error: $($inner.SocketErrorCode)" }
            }
        } elseif ($inner -is [System.Security.Authentication.AuthenticationException]) {
            $msg = 'TLS certificate error'
        } elseif ($inner -is [System.Net.Http.HttpRequestException]) {
            $msg = "Cannot reach endpoint - this network may restrict access ($($inner.Message))"
        } elseif ($inner -is [System.Threading.Tasks.TaskCanceledException] -or $inner -is [System.TimeoutException]) {
            $msg = 'Request timed out'
        } elseif ($inner) {
            $msg = $inner.Message
        }
        # Phase 7D: transient transport failures retry with backoff too (OpenCode Go
        # only - Ollama keeps its original no-retry behaviour). TLS errors never retry.
        $transient = ($inner -is [System.Threading.Tasks.TaskCanceledException]) -or
            ($inner -is [System.TimeoutException]) -or
            ($inner -is [System.Net.Http.HttpRequestException]) -or
            ($inner -is [System.Net.Sockets.SocketException])
        $maxAttempts = [int]$script:Config.network.retry_attempts
        if ($script:Provider -eq 'opencode_go' -and $transient -and
            $script:Config.network.retry_backoff -and $script:Attempt -lt ($maxAttempts - 1)) {
            $script:Attempt++
            $delay = [math]::Pow(2, $script:Attempt - 1) + (Get-Random -Minimum 0 -Maximum 500) / 1000.0
            Set-Status ("{0} - retry {1}/{2} in {3:N1}s..." -f $msg, $script:Attempt, ($maxAttempts - 1), $delay)
            Start-Sleep -Seconds $delay
            Send-Prompt $script:LastPrompt
            return
        }
        $script:Running = $false
        if ($script:Provider -eq 'ollama' -and $msg -notmatch 'DNS') { $msg += ' - is the Ollama app running?' }
        Set-Status $msg
    }
})
$timer.Start()

# ---- events ------------------------------------------------------------------
$onEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy'; $drop.BackColor = $hi }
}
$onLeave = { $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52) }
$onDrop = {
    $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
    $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($paths) { Start-Answer $paths }
}
foreach ($c in @($form, $drop, $title, $status)) {
    $c.Add_DragEnter($onEnter); $c.Add_DragLeave($onLeave); $c.Add_DragDrop($onDrop)
}
$pick = {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Choose files'
    if ($dlg.ShowDialog($form) -eq 'OK') { Start-Answer $dlg.FileNames }
}
foreach ($c in @($drop, $title, $status)) { $c.Add_Click($pick) }

$btnCopy.Add_Click({ Copy-Again })
$btnHide.Add_Click({ $form.Hide() })
$btnShare.Add_Click({
    $box.Visible = -not $box.Visible
    if ($box.Visible) { $form.Height = $CompactH + $AnswerH } else { $form.Height = $CompactH }
    Set-Rounded
})

Set-Rounded
$form.Show()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$mutex.ReleaseMutex()
