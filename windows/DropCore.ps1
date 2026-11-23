# DropCore.ps1 - UI-free pipeline code shared by Drop.ps1 (WinForms app) and the test harnesses.
# Dot-sourced by Drop.ps1; contains only function and variable definitions (no WinForms, no side effects).
# Moved unchanged from Drop.ps1: prompt headers, deterministic fixers, javac compile check, HOW TO TEST block.
# Windows PowerShell 5.1 compatible (no ?: / ?? / -Parallel).

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

# (Invoke-DropStaticFixes - every deterministic fixer in the right order - lives in DropOop.ps1 with the newer fixers.)

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
    $srcRoot = Join-Path $tmp 'src/main/java'
    $argList = @('--release', '17', '-proc:none', '-nowarn', '-encoding', 'UTF-8',
                 '-d', $outDir, '-cp', ($jars -join [System.IO.Path]::PathSeparator), '-sourcepath', ($srcRoot + [System.IO.Path]::PathSeparator + $tmp))
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
    return (($text -replace [regex]::Escape($tmp + '\'), '') -replace [regex]::Escape($tmp + '/'), '')
}
# The prompt head forbids the model writing a HOW TO TEST section, so Drop
# appends one deterministically at finalize (Ollama only): numbered curl lines
# for the real Spring mappings, or a javac/java recipe for plain Java. Every
# line is a "//" comment, so the pasted answer stays pure code.
function Add-DropHowToTest([string]$answer, $starter = $null, [string]$paper = '') {
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
    # record/class shapes may live in the STARTER (a DTO record the answer only uses): look there too when sampling JSON
    $lookup = [ordered]@{}
    foreach ($n in @($files.Keys)) { $lookup[$n] = $files[$n] }
    if ($starter) {
        foreach ($k in @($starter.Keys | Sort-Object)) {
            $leaf = [System.IO.Path]::GetFileName([string]$k)
            if (-not $lookup.Contains($leaf)) { $lookup[$leaf] = @{ Header = ''; Body = [string]$starter[$k] } }
        }
    }
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
        # the starter's application.properties is part of the paper block: use its real port
        if ($port -eq '8080') {
            $pm = [regex]::Match($paper, 'server\.port\s*=\s*(\d+)')
            if ($pm.Success) { $port = $pm.Groups[1].Value }
        }
        # the paper's own "REST operations to demonstrate" calls (real ids, real JSON) beat synthesised ones
        $demo = @(Get-DropPaperDemoCalls $paper)
        $step = 2
        foreach ($d in $demo) {
            $line = '// ' + $step + '. Try it: curl -X ' + $d[0] + " 'http://localhost:" + $port + $d[1] + "'"
            if ($d[2] -ne '') { $line += ' -H "Content-Type: application/json" -d ' + "'" + $d[2] + "'" }
            $lines.Add($line)
            $step++
        }
        $scan = if ($demo.Count -gt 0) { @() } else { @($files.Keys) }
        foreach ($n in $scan) {
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
                if ($m.Success) { $json = Get-DropJsonSample $m.Groups[1].Value $lookup }
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

# ---- input collection settings (same values as Drop.ps1 had; defined here so tests/runspaces can use Collect-Input) ----
if (-not $SkipDirs) { $SkipDirs = '\\(target|\.idea|\.git|node_modules|build|out|\.mvn|\.gradle|\.vscode|bin|obj)\\' }
if (-not $TextExt)  { $TextExt  = @('.java','.xml','.md','.properties','.yml','.yaml','.json','.txt','.sql','.gradle','.kts','.html','.csv','.cs','.py','.js','.ts') }
if (-not $DocExt)   { $DocExt   = @('.pdf','.docx','.md','.txt') }

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


# ---- newer, UI-free code of this port (loaded after everything above so it can extend it) ----
. (Join-Path $PSScriptRoot 'DropOop.ps1')
. (Join-Path $PSScriptRoot 'DropAcd.ps1')
. (Join-Path $PSScriptRoot 'DropAcdValidate.ps1')
. (Join-Path $PSScriptRoot 'DropAcdRun.ps1')
. (Join-Path $PSScriptRoot 'DropBench.ps1')

# ---- background jobs: one runspace per run so the UI thread never blocks (shared by Drop.ps1 and the tests) ----------
# The runspace dot-sources DropCore.ps1 again, runs one entry point and reports through a synchronized hashtable
# (Status text, Cancel flag, bench log lines). The UI thread polls Handle.IsCompleted from its timer.
$script:DropCoreDir = $PSScriptRoot
function Start-DropJob([string]$kind, $params) {
    $sync = [hashtable]::Synchronized(@{ Status = ''; Cancel = $false; Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $core = Join-Path $script:DropCoreDir 'DropCore.ps1'
    [void]$ps.AddScript({
        param($core, $kind, $p, $sync)
        $ErrorActionPreference = 'Continue'
        . $core
        switch ($kind) {
            'oop'       { return (Invoke-DropOopRun $p $sync) }
            'acd'       { return (Invoke-DropAcdRun $p $sync) }
            'bench'     { return (Invoke-DropBenchJob $p $sync) }
            'toolchain' { return (Install-AcdToolchain $p.PackageJson) }
        }
    }).AddArgument($core).AddArgument($kind).AddArgument($params).AddArgument($sync)
    $handle = $ps.BeginInvoke()
    return @{ Ps = $ps; Rs = $rs; Handle = $handle; Sync = $sync; Kind = $kind; Started = [DateTime]::UtcNow }
}
function Test-DropJobDone($job) { return [bool]$job.Handle.IsCompleted }
# Collects the job's result hashtable (last hashtable written to the output) and disposes the runspace.
function Receive-DropJob($job) {
    $res = $null
    try {
        $out = $job.Ps.EndInvoke($job.Handle)
        foreach ($o in @($out)) { if ($o -is [hashtable] -or $o -is [System.Collections.Specialized.OrderedDictionary]) { $res = $o } }
        if ($null -eq $res) {
            $err = ''
            if ($job.Ps.Streams.Error.Count -gt 0) { $err = [string]$job.Ps.Streams.Error[0] }
            $res = @{ Ok = $false; Error = $(if ($err) { $err } else { 'the background run ended without a result' }) }
        }
    } catch { $res = @{ Ok = $false; Error = [string]$_.Exception.Message } }
    finally { try { $job.Ps.Dispose(); $job.Rs.Dispose() } catch { } }
    return $res
}
function Stop-DropJob($job) { $job.Sync.Cancel = $true; try { [void]$job.Ps.BeginStop($null, $null) } catch { } }
