# Ollama Quiet-Laptop Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Ollama cheap on laptops — `keep_alive: 0` per request, hardware-capped context, on-demand start with readiness probe, low-priority inference, login auto-start disabled, OpenCode Go as the fresh-install default — without touching the locked OpenCode Go integration.

**Architecture:** All changes are surgical edits inside the two existing delivery artifacts (`install-drop.sh` macOS Swift heredoc; `windows/Drop.ps1` + `windows/Install Drop.cmd`). Each platform gets one sizing helper, one `prepare…` lifecycle helper called first by every Ollama request site, installer-level login-disable lines, and label-only dropdown metadata with label→name resolution at every read site. Verification is structural/extraction tests in a git-ignored per-plan workspace (no pwsh on this Mac — Windows tests are structural pins), plus `swiftc -typecheck` on the extracted Swift, plus a byte-lock diff gate on the OpenCode Go code.

**Tech Stack:** macOS Swift (AppKit, inside heredoc `install-drop.sh` lines 54–1669), Windows PowerShell 5.1 (WinForms) + `cmd`, Python 3 structural tests, `swiftc -typecheck`, git diff gate.

**Spec:** `docs/superpowers/specs/2026-11-18-ollama-quiet-laptop-design.md` (rev 2, approved) — the plan argues from it; executors read both.

## Global Constraints

- **OpenCode Go is byte-locked:** zero edits to its endpoint, auth, headers, request body, model config, streaming, connection test, error handling, UI, config format, or key storage. Verified by the Task 8 diff gate (`opencode_gate.py`), not by review alone.
- `keep_alive` is the explicit value `0` on every `/api/generate` (mac ×1 generate site, win ×1); the string `30m` is gone from both files. No separate unload commands, ever.
- Context: existing preset/manual stays the **floor**; auto path ceiling by RAM — `<16 GB → 16384`, `16–32 GB → 32768`, `≥32 GB → 65536`; hard cap `65536` unchanged; **prompt-fit bypass** grows to fit the prompt's own token estimate (up to 65536); **manual override exempt** (floor + 65536 cap only, no ceiling).
- Readiness probe is `GET /api/tags` (never a bare port check), loopback-only (`127.0.0.1`/`localhost`); start-path poll first attempt ~300 ms, then ~500 ms, bounded by existing `network.connect_timeout` (20 s). Failure → existing connection-error classification (mac `.tcpFailure`, win existing status strings); no new error types, no provider fallback, never crash.
- Never force-kill Ollama, never spawn a second `ollama serve`, never restart a server that is already running; once started, the server stays up.
- Env `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1` only on Drop's start paths (mac `launchctl setenv` best-effort before `open -a Ollama`; win `$env:` inherited by the launched app). Never applied to an already-running server.
- Priority demotion **once per session** (flag), best-effort, errors swallowed: mac `renice 15` via `pgrep -x ollama` + `pgrep -x Ollama` (children inherit); win `BelowNormal` on `ollama*` (runner inherits). Flag set only when at least one process was actually demoted.
- Login disable in installers only: mac `launchctl bootout` + `launchctl disable gui/$(id -u)/com.ollama.ollama`, both `2>/dev/null || true`; win `reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Ollama /f >nul 2>&1`. Nothing else (no uninstall, no model deletion, no HKLM, no SMAppService internals).
- Default provider `opencode_go` at exactly three code sites (mac installer config JSON, mac `var provider`, win `Read-DropConfig`) — **fresh configs only**; existing config.json files are never rewritten (installer write stays behind its existing `if` guard).
- Dynamic Qwen discovery stays (no hardcoded model, no auto-download); dropdown labels gain ` · size · quant` **display only** — every request/config write resolves label→name first.
- Status line only (no new panels): carries `Starting Ollama…` (win: `Starting Ollama...`), `Ollama ready`, the existing connection error on start failure, and the context hint `raise Qwen ctx in Settings…`.
- PS 5.1-safe; Swift stays inside the heredoc; no new dependencies; smallest reliable change set; keys never logged/displayed; 127.0.0.1 only; no firewall changes; no Keychain/Credential Manager.
- Line numbers in this plan refer to BASE `d1ee02f`. After Task 1 edits, locate sites **by the markers given**, not by line number.

## Review Focus

Failure modes no task's tests exercise; each line names its pin and its live check.

1. **Manual Ollama.app open re-registers the SMAppService login job** — disable silently undone after reboot; expected: Ollama still absent at next login, or documented System Settings fallback. Pin: Task 5 asserts `bootout` + `disable` + `|| true` non-fatal in `install-drop.sh`. Live: spec checklist 1 matrix (reboot, manual open, update, reinstall, login/logout).
2. **`launchctl setenv` not propagating to the app-spawned `serve`** — env silently ignored; expected: runner sees both vars, else the step is dropped and ledgered. Pin: Task 3 asserts `setenv` lines sit after the `startIfNeeded` guard (start path only) and both var names present. Live: spec checklist 7.
3. **Ollama already running when Drop starts/switches** — must not restart, must not spawn a duplicate server, demote-once must still fire; expected: first probe returns before any start command. Pin: Task 3/4 assert probe (`/api/tags`) precedes the start command inside the prepare helper; Task 4 asserts startup discovery call passes `$false`. Live: spec checklist 2 (second run instant) + 3.
4. **Metadata label leaks into an API request or saved config** — a read site missing label→name resolution sends `qwen3.5:4b · 4.4B · Q4_K_M` as the model name and every run fails; expected: requests and `default_model`/`model` saves always carry the bare name. Pin: Task 7 asserts `resolvedModelName` at mac `modelChanged` + run-path guard + loadModels selection, and `$d.Name` at win `SelectedIndexChanged`. Live: pick a labeled model, run once, confirm success and that `config.json` stores the bare name.
5. **Start-timeout path (Ollama absent, 20 s expires)** — expected: mac surfaces the existing connection error and the run pipeline stops cleanly; win shows the existing `Ollama not running` status **and resets `$script:Running`**, otherwise the busy guard locks Drop permanently; no silent OpenCode fallback. Pin: Task 3 asserts generate's prepare-fail returns `.failed(DropError(kind: .tcpFailure))`; Task 4 asserts `$script:Running = $false` + status + `return` in Send-Prompt's prepare-fail branch. Live: quit Ollama fully, trigger a run.

---

### Task 1: macOS — `keep_alive: 0`, hardware context ceiling, context hint

**Files:**
- Modify: `install-drop.sh` (Swift heredoc): `DropConfig` (marker `struct DropConfig {`), `OllamaProvider.generate` (marker `func generate(prompt: String` … end marker `// Qwen-family discovery`), comment at `// --- Ollama: existing behaviour moved verbatim`, `AppDelegate.contextSize` (marker `func contextSize(for prompt: String)` … `// Single entry point`).
- Test: `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py` (create), `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh` (create).

**Interfaces:**
- Produces: `DropConfig.ollamaContextCeiling: Int` (computed), `DropConfig.ollamaContextSize(forPrompt prompt: String) -> Int`; generate calls `config.ollamaContextSize(forPrompt:)`; error detail may carry the `Qwen ctx in Settings` hint. Task 3 inserts code at the top of the same `generate` function — keep the function's structure intact.
- Consumes: existing `DropConfig.ollamaTargetContext`, `DropConfig.connectTimeout` (`Double`, line 153), `classifyHTTP(status:retryAfterHeader:detail:)`, `errorDetail(from:)`.

- [ ] **Step 1: Create the test workspace, typecheck helper, and failing tests**

Create `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh`:

```bash
#!/bin/bash
set -e
ROOT="$(git rev-parse --show-toplevel)"
WS="$ROOT/.superpowers/sdd/2026-11-18-ollama-quiet-laptop"
# Extract the Swift heredoc robustly (line numbers shift as we edit):
# from the line after  cat > "$DIR/main.swift" <<'EOF'  up to the next bare EOF line.
awk '/^cat > "\$DIR\/main\.swift" <<'\''EOF'\''$/{f=1;next} /^EOF$/{f=0} f' \
  "$ROOT/install-drop.sh" > "$WS/main.swift"
lines=$(wc -l < "$WS/main.swift" | tr -d ' ')
[ "$lines" -gt 1000 ] || { echo "EXTRACT FAILED ($lines lines)"; exit 1; }
swiftc -typecheck "$WS/main.swift"
echo "TYPECHECK OK ($lines lines)"
```

Create `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py` with this skeleton plus the Task 1 pins:

```python
#!/usr/bin/env python3
import pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[3]
SH = (ROOT / "install-drop.sh").read_text()
fails = []

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else (" -- " + detail)))
    if not cond: fails.append(name)

def between(t, s, e):
    # Tolerant: missing markers yield "" so later `in` checks FAIL cleanly
    # instead of raising during the RED run.
    if s not in t: return ""
    i = t.index(s)
    j = t.find(e, i + len(s))
    return t[i:j] if j != -1 else ""

def brace_block(t, s):
    if s not in t: return ""
    i = t.index(s); d = 0
    for k in range(i, len(t)):
        if t[k] == '{': d += 1
        elif t[k] == '}':
            d -= 1
            if d == 0: return t[i:k+1]
    raise SystemExit("unbalanced block: " + s)

# ---- Task 1: keep_alive 0 + hardware context ceiling ----
gen = between(SH, "func generate(prompt: String", "// Qwen-family discovery")
cfg = brace_block(SH, "struct DropConfig {")
check("T1 keep_alive is 0", '"keep_alive": 0' in gen)
check("T1 no 30m anywhere", "30m" not in SH)
check("T1 verbatim comment updated", "moved verbatim" not in SH)
check("T1 sizing helper exists", "func ollamaContextSize(forPrompt prompt: String) -> Int" in cfg)
ceil = between(cfg, "var ollamaContextCeiling", "func ollamaContextSize")
check("T1 manual override exempt", "guard ollamaContext <= 0 else { return 65536 }" in ceil)
check("T1 ceiling table", all(s in ceil for s in ("gib < 16", "16384", "gib < 32", "32768", "65536")))
siz = cfg[cfg.index("func ollamaContextSize"):] if "func ollamaContextSize" in cfg else ""
check("T1 floor and hard cap kept", "ollamaTargetContext" in siz and "65536" in siz)
check("T1 prompt-fit bypass", "tokens > ctx" in siz and "while fit < tokens" in siz and "fit *= 2" in siz)
check("T1 generate calls helper", "config.ollamaContextSize(forPrompt: prompt)" in gen)
check("T1 generate inline sizing gone", "let needed = prompt.count / 3 + 8000" not in gen)
ctxfn = between(SH, "func contextSize(for prompt: String)", "Single entry point")
check("T1 contextSize delegates", "config.ollamaContextSize(forPrompt: prompt)" in ctxfn)
check("T1 context hint", "Qwen ctx in Settings" in SH and 'contains("context")' in gen and 'contains("length")' in gen)

print("---")
if fails:
    print(f"{len(fails)} FAIL"); sys.exit(1)
print("ALL PASS")
```

The test workspace stays uncommitted scratch (never `git add` it; it is deleted after final review, like the previous plan's).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py`
Expected: `FAIL T1 keep_alive is 0`, `FAIL T1 sizing helper exists`, and the other T1 FAIL lines (current code has `"keep_alive": "30m"` and no ceiling helper); exit 1.

- [ ] **Step 3: Implement the sizing helper on `DropConfig`**

After `ollamaTargetContext` (still inside `struct DropConfig`), add:

```swift
var ollamaContextCeiling: Int {
    guard ollamaContext <= 0 else { return 65536 }   // manual override = consent (spec §2)
    let gib = (ProcessInfo.processInfo.physicalMemory + 536_870_912) / 1_073_741_824
    if gib < 16 { return 16384 }
    if gib < 32 { return 32768 }
    return 65536
}

func ollamaContextSize(forPrompt prompt: String) -> Int {
    let needed = prompt.count / 3 + 8000
    var ctx = 8192
    while ctx < needed && ctx < 65536 { ctx *= 2 }
    ctx = min(max(ctx, ollamaTargetContext), 65536)   // preset/manual floor + hard cap
    ctx = min(ctx, ollamaContextCeiling)              // auto-path hardware ceiling
    let tokens = prompt.count / 3
    if tokens > ctx {                                 // prompt-fit bypass: never truncate the prompt
        var fit = 8192
        while fit < tokens && fit < 65536 { fit *= 2 }
        ctx = fit
    }
    return ctx
}
```

- [ ] **Step 4: Rewire `generate` — sizing, `keep_alive: 0`, context hint**

In `OllamaProvider.generate`: replace the inline `needed`/`ctx` sizing block with `let ctx = config.ollamaContextSize(forPrompt: prompt)`; change `"keep_alive": "30m"` to `"keep_alive": 0`. In the non-200 branch, replace the `classifyHTTP(... detail: errorDetail(from: raw))` call with:

```swift
var detail = errorDetail(from: raw)
if let d = detail, d.lowercased().contains("context"), d.lowercased().contains("length") {
    detail = d + " — raise Qwen ctx in Settings if the paper is large"
}
return .failed(classifyHTTP(status: h.statusCode,
                            retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"),
                            detail: detail))
```

Update the two stale comments: the `// --- Ollama: existing behaviour moved verbatim …` header (must no longer say `moved verbatim`; say `keep_alive 0` unloads right after each answer) and the sizing comment above the body line (point at `config.ollamaContextSize(forPrompt:)`).

- [ ] **Step 5: Delegate `AppDelegate.contextSize`**

Replace its body with `config.ollamaContextSize(forPrompt: prompt)` (helper keeps one copy of the algorithm).

- [ ] **Step 6: Run tests + typecheck to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh`
Expected: `ALL PASS` then `TYPECHECK OK (>1000 lines)`.

- [ ] **Step 7: Commit**

```bash
git add install-drop.sh
git commit -m "feat(ollama): keep_alive 0 + hardware context ceiling (mac)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Windows — `keep_alive: 0`, hardware context ceiling, context hint

**Files:**
- Modify: `windows/Drop.ps1`: RAM-detection + sizing region (markers `function Get-OllamaContextTarget` … `$PromptHeader`), `Send-Prompt` (markers `function Send-Prompt` … `$script:DoubleCheck = $false`), timer non-success path (marker `$msg = $kind`).
- Test: `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py` (create).

**Interfaces:**
- Produces: `Ensure-OllamaRamGB` (fills `$script:RamGB` once), `Get-OllamaContextCeiling([int]$manual) -> [int]`, `Get-OllamaFinalContext([string]$prompt) -> [int]`. Task 4 calls `Prepare-Ollama` inside `Update-OllamaModels` and `Send-Prompt` — those functions must keep their names; Task 7 keeps `Update-OllamaModels`'s new `$StartIfNeeded` parameter (added in Task 4).
- Consumes: existing `Get-OllamaContextTarget`, `Get-OllamaManualContext`, `$script:Config.network.connect_timeout`.

- [ ] **Step 1: Write the failing test**

Create `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py` — same skeleton as the mac test (`ROOT`, `fails`, `check`, `between`, `brace_block`) reading `PS = (ROOT / "windows/Drop.ps1").read_text()`, plus:

```python
# ---- Task 2: keep_alive 0 + hardware context ceiling (win) ----
sp = between(PS, "function Send-Prompt", "$script:DoubleCheck = $false")
oc = brace_block(sp, "if ($script:Provider -eq 'opencode_go')")
ol = sp[sp.index("# Ollama path"):]
check("T2 keep_alive is 0", "keep_alive = 0" in ol)
check("T2 no 30m anywhere", "'30m'" not in PS)
fc = between(PS, "function Get-OllamaContextCeiling", "$PromptHeader")
check("T2 ceiling helper exists", "function Get-OllamaContextCeiling" in PS)
check("T2 ceiling table", all(s in fc for s in ("manual -gt 0", "65536", "Ensure-OllamaRamGB", "16384", "32768")))
check("T2 prompt-fit bypass", "tokens" in fc and "fit" in fc and "65536" in fc)
check("T2 send uses final helper", "Get-OllamaFinalContext $prompt" in ol)
check("T2 inline sizing gone from send", "while ($ctx -lt $need" not in ol)
check("T2 RAM detect exactly once", PS.count("TotalPhysicalMemory") == 1)
check("T2 context hint", "Qwen ctx in Settings" in PS and "-match 'context'" in PS)
check("T2 opencode branch has no ceiling/keep_alive", "Get-OllamaFinalContext" not in oc and "keep_alive" not in oc)
```

Note: the ceiling must consume the shared RAM detection — hence the `Ensure-OllamaRamGB` pin inside `fc`, and `PS.count("TotalPhysicalMemory") == 1` proves the detection was extracted, not duplicated.

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py`
Expected: FAIL lines for keep_alive/ceiling/helper/hint; exit 1. (`T2 no 30m anywhere` fails too — `'30m'` is present at line 850.)

- [ ] **Step 3: Extract RAM detection, add ceiling + final-context helpers**

Between `Get-OllamaManualContext` and `$PromptHeader`:
1. Move the existing `TotalPhysicalMemory` block out of `Get-OllamaContextTarget` into `function Ensure-OllamaRamGB` (fills `$script:RamGB`, defaults 8, `try/catch` swallow — byte-identical logic); both callers start with `Ensure-OllamaRamGB`. `Get-OllamaContextTarget` behavior must not change.
2. Add:

```powershell
function Get-OllamaContextCeiling([int]$manual) {
    if ($manual -gt 0) { return 65536 }          # manual override = consent (spec §2)
    Ensure-OllamaRamGB
    if ($script:RamGB -lt 16) { return 16384 }
    if ($script:RamGB -lt 32) { return 32768 }
    return 65536
}
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
    $tokens = [int]($prompt.Length / 3)
    if ($tokens -gt $ctx) {                       # prompt-fit bypass: never truncate the prompt
        $fit = 8192
        while ($fit -lt $tokens -and $fit -lt 65536) { $fit *= 2 }
        $ctx = $fit
    }
    return $ctx
}
```

- [ ] **Step 4: Rewire `Send-Prompt` Ollama branch + timer hint**

In `Send-Prompt`'s Ollama branch (below `# Ollama path`): replace the inline sizing block with `$ctx = Get-OllamaFinalContext $prompt`; change `keep_alive = '30m'` to `keep_alive = 0`. In the timer's non-success path, immediately after `$msg = $kind`, insert:

```powershell
if ($script:Provider -eq 'ollama' -and $text -match 'context' -and $text -match 'length') {
    $msg = "$kind - raise Qwen ctx in Settings if the paper is large"
}
```

(Leave the opencode fallback block below untouched — the `Provider -eq 'ollama'` guard keeps the hint Ollama-only.)

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add windows/Drop.ps1
git commit -m "feat(ollama): keep_alive 0 + hardware context ceiling (win)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: macOS — on-demand start (`prepareOllama`), env, demote-once, call sites

**Files:**
- Modify: `install-drop.sh`: insert helpers after `OllamaProvider`'s closing brace (immediately before `// --- OpenCode Go`); `OllamaProvider.generate` (top of function); `loadModels` (signature + Task body); `testConnection` ollama branch; `handleGenerationFailure` before `ollama.listModels()`; call sites at settings-save (`config.save()` then `loadModels()`), `toggleProvider` end, show-refresh (`if config.provider == "ollama" && !running`), fallback's `loadModels()`.
- Test: append to `test-ollama-mac.py`.

**Interfaces:**
- Produces: `runSh(_:) -> Int32`, `ollamaManageable(_:) -> Bool`, `ollamaReachable(_:) async -> Bool`, `demoteOllamaOnce()`, `prepareOllama(startIfNeeded: Bool, base: String, timeout: TimeInterval, onStatus: ((String) -> Void)? = nil) async -> Bool`; `loadModels(startIfNeeded: Bool = false)` (Task 7 keeps this exact signature).
- Consumes: Task 1's `generate` structure (insert only at its top); `config.connectTimeout` (`Double`); `generate`'s existing `onStatus` callback (already hops to main at its AppDelegate call site).

- [ ] **Step 1: Append the failing test section**

Append to `test-ollama-mac.py`:

```python
# ---- Task 3: prepareOllama + call sites ----
prep = between(SH, "func prepareOllama", "// --- OpenCode Go")
check("T3 prepare signature", "func prepareOllama(startIfNeeded: Bool, base: String, timeout: TimeInterval, onStatus: ((String) -> Void)? = nil) async -> Bool" in prep)
check("T3 probe is /api/tags", '"/api/tags"' in prep and "/api/version" not in prep)
check("T3 loopback guard", "func ollamaManageable" in SH and "ollamaManageable(base)" in prep)
check("T3 start via open -a Ollama", "open -a Ollama" in prep)
check("T3 env only on start path",
      "startIfNeeded else { return false }" in prep and "launchctl setenv" in prep
      and prep.index("startIfNeeded else { return false }") < prep.index("launchctl setenv"))
check("T3 env vars", "launchctl setenv OLLAMA_NUM_PARALLEL 1" in prep and "launchctl setenv OLLAMA_MAX_LOADED_MODELS 1" in prep)
check("T3 probe before start",
      '"/api/tags"' in prep and "open -a Ollama" in prep
      and prep.index('"/api/tags"') < prep.index("open -a Ollama"))
check("T3 poll timing", "300_000_000" in prep and "500_000_000" in prep and "addingTimeInterval(timeout)" in prep)
check("T3 demote once", "renice 15" in prep and "pgrep -x ollama" in prep and "pgrep -x Ollama" in prep and "ollamaDemoted" in SH)
check("T3 status strings", "Starting Ollama…" in prep and "Ollama ready" in prep)
gen = between(SH, "func generate(prompt: String", "// Qwen-family discovery")
check("T3 generate prepares first",
      "prepareOllama(startIfNeeded: true" in gen and "URLRequest" in gen
      and gen.index("prepareOllama(startIfNeeded: true") < gen.index("URLRequest"))
check("T3 generate start-fail -> tcpFailure", "DropError(kind: .tcpFailure)" in gen)
check("T3 loadModels param", "func loadModels(startIfNeeded: Bool = false)" in SH)
loadm = between(SH, "func loadModels(", "@objc func modelChanged")
check("T3 loadModels prepares when asked", "prepareOllama(startIfNeeded: startIfNeeded" in loadm)
check("T3 show-refresh starts", 'if config.provider == "ollama" && !running { loadModels(startIfNeeded: true) }' in SH)
tc = between(SH, "@objc func testConnection", "func loadModels(")
check("T3 testConnection prepares", "prepareOllama(startIfNeeded: true" in tc)
fb = brace_block(SH, "func handleGenerationFailure(_ err: DropError, provider: ProviderAdapter)")
check("T3 fallback prepares before listModels",
      "prepareOllama(startIfNeeded: true" in fb and "ollama.listModels()" in fb
      and fb.index("prepareOllama(startIfNeeded: true") < fb.index("ollama.listModels()"))
check("T3 fallback loadModels starts", "loadModels(startIfNeeded: true)" in fb)
import re as _re
check("T3 startup stays probe-only (exactly one bare call)", len(_re.findall(r"^\s*loadModels\(\)", SH, _re.M)) == 1)
check("T3 four explicit start call sites", SH.count("loadModels(startIfNeeded: true)") >= 4)
check("T3 OpenCode never prepares", "prepareOllama" not in brace_block(SH, "struct OpenCodeGoProvider: ProviderAdapter {"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py`
Expected: win `ALL PASS`; mac `FAIL T3 prepare signature` and the other T3 FAIL lines; exit 1.

- [ ] **Step 3: Implement the lifecycle helpers**

Insert immediately before `// --- OpenCode Go` (after `OllamaProvider`'s `}`):

```swift
var ollamaDemoted = false

func runSh(_ cmd: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func ollamaManageable(_ base: String) -> Bool {
    guard let u = URL(string: base), let h = u.host else { return false }
    return h == "127.0.0.1" || h == "localhost" || h == "::1"
}

func ollamaReachable(_ base: String) async -> Bool {
    guard let u = URL(string: base + "/api/tags") else { return false }
    var req = URLRequest(url: u)
    req.timeoutInterval = 2
    do {
        let (_, r) = try await URLSession.shared.data(for: req)
        return (r as? HTTPURLResponse)?.statusCode == 200
    } catch { return false }
}

func demoteOllamaOnce() {
    if ollamaDemoted { return }
    let st = runSh("n=0; for p in $(pgrep -x ollama) $(pgrep -x Ollama); do "
                 + "renice 15 -p \"$p\" >/dev/null 2>&1 && n=$((n+1)); done; [ \"$n\" -gt 0 ]")
    if st == 0 { ollamaDemoted = true }
}

// Signature must stay on ONE line — the test pins it as a single-line substring.
func prepareOllama(startIfNeeded: Bool, base: String, timeout: TimeInterval, onStatus: ((String) -> Void)? = nil) async -> Bool {
    guard ollamaManageable(base) else { return true }   // custom base: lifecycle not ours
    if await ollamaReachable(base) { demoteOllamaOnce(); return true }   // already running: leave it alone
    guard startIfNeeded else { return false }
    onStatus?("Starting Ollama…")
    _ = runSh("launchctl setenv OLLAMA_NUM_PARALLEL 1; launchctl setenv OLLAMA_MAX_LOADED_MODELS 1")
    _ = runSh("/usr/bin/open -a Ollama")
    let deadline = Date().addingTimeInterval(timeout)
    try? await Task.sleep(nanoseconds: 300_000_000)
    while Date() < deadline {
        if await ollamaReachable(base) {
            demoteOllamaOnce()
            onStatus?("Ollama ready")
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return false
}
```

- [ ] **Step 4: Wire the call sites**

1. `OllamaProvider.generate` — first statement, before the `URLRequest` line: `guard await prepareOllama(startIfNeeded: true, base: config.ollamaBase, timeout: config.connectTimeout, onStatus: onStatus) else { return .failed(DropError(kind: .tcpFailure)) }`.
2. `loadModels` — signature → `func loadModels(startIfNeeded: Bool = false)`. Inside the Task, before `let names = await provider.listModels()`: `if provider.id == "ollama" { _ = await prepareOllama(startIfNeeded: startIfNeeded, base: cfg.ollamaBase, timeout: cfg.connectTimeout, onStatus: { setStatus($0) }) }` (bare closure capture matches the file's existing style inside this Task).
3. `testConnection` ollama branch — before `let o = OllamaProvider(...)`: `_ = await prepareOllama(startIfNeeded: true, base: cfg.ollamaBase, timeout: cfg.connectTimeout, onStatus: { setStatus($0) })`.
4. `handleGenerationFailure` — immediately before `guard let names = await ollama.listModels()`: same `prepareOllama(... true ...)` call with `onStatus: { setStatus($0) }`; change its trailing `loadModels()` to `loadModels(startIfNeeded: true)`.
5. Settings-save call site (`config.save()` … `loadModels()`), `toggleProvider`'s trailing `loadModels()`, and the show-refresh `if config.provider == "ollama" && !running { loadModels() }` → all become `loadModels(startIfNeeded: true)`. The **startup** call (in setup, right after `registerHotKey()`/`setStatus(...)`) stays bare `loadModels()` — the only bare call left.

- [ ] **Step 5: Run tests + typecheck to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh`
Expected: both tests `ALL PASS`; `TYPECHECK OK (>1000 lines)`.

- [ ] **Step 6: Commit**

```bash
git add install-drop.sh
git commit -m "feat(ollama): on-demand start helper + call sites (mac)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: Windows — on-demand start (`Prepare-Ollama`), env, demote-once, call sites

**Files:**
- Modify: `windows/Drop.ps1`: insert helpers immediately before `function Update-OllamaModels`; `Update-OllamaModels` signature + first statement; `Switch-Provider` ollama branch (`Update-OllamaModels` → `Update-OllamaModels $true`); `Toggle-Popup` show-refresh (same); `Send-Prompt` Ollama branch (prepare guard); settings Test button ollama branch (before the `"$b/api/tags"` probe).
- Test: append to `test-ollama-win.py`.

**Interfaces:**
- Produces: `Test-OllamaApi([int]$sec = 2)`, `Start-OllamaApp()`, `Set-OllamaLowPriority()`, `Prepare-Ollama([bool]$StartIfNeeded)`; `Update-OllamaModels([bool]$StartIfNeeded = $false)` (Task 7 keeps this parameter). `$script:OllamaDemoted` session flag.
- Consumes: Task 2's `Ensure-OllamaRamGB`/sizing (untouched); existing `$OllamaUrl`, `$script:Config.network.connect_timeout`, `Set-Status`.

- [ ] **Step 1: Append the failing test section**

Append to `test-ollama-win.py`:

```python
# ---- Task 4: Prepare-Ollama + call sites ----
prep = between(PS, "function Prepare-Ollama", "function Update-OllamaModels")
check("T4 prepare signature", "function Prepare-Ollama([bool]$StartIfNeeded)" in prep)
check("T4 probe is /api/tags", "$OllamaUrl/api/tags" in prep and "/api/version" not in prep)
check("T4 loopback guard", "127.0.0.1" in prep and "localhost" in prep and "return $true" in prep)
check("T4 start resolves official app", all(s in prep for s in ("Ollama.lnk", "ollama app.exe", "ollama.exe")))
check("T4 never spawns bare serve first",
      "Ollama.lnk" in prep and "'serve'" in prep
      and prep.index("Ollama.lnk") < prep.index("'serve'"))
check("T4 env on start path", "$env:OLLAMA_NUM_PARALLEL" in prep and "$env:OLLAMA_MAX_LOADED_MODELS" in prep)
check("T4 Prepare probes before starting",
      "Test-OllamaApi 1" in prep and "Start-OllamaApp" in prep
      and prep.index("Test-OllamaApi 1") < prep.index("Start-OllamaApp"))
check("T4 poll timing", "300" in prep and "500" in prep and "connect_timeout" in prep)
check("T4 demote once", "BelowNormal" in prep and "$script:OllamaDemoted" in prep and "ollama*" in prep)
check("T4 status strings", "Starting Ollama..." in prep and "Ollama ready" in prep)
upd = between(PS, "function Update-OllamaModels", "# ---- UI")
check("T4 update signature", "function Update-OllamaModels([bool]$StartIfNeeded = $false)" in PS)
check("T4 update prepares", "Prepare-Ollama -StartIfNeeded $StartIfNeeded" in upd)
sw = between(PS, "function Switch-Provider", "\nfunction ")
check("T4 switch starts on demand", "Update-OllamaModels $true" in sw)
tp = between(PS, "function Toggle-Popup", "function Start-OopRun")
check("T4 show-refresh starts on demand", "Update-OllamaModels $true" in tp)
check("T4 startup stays probe-only", PS.count("[void](Update-OllamaModels)") == 1)
sp = between(PS, "function Send-Prompt", "$script:DoubleCheck = $false")
oc = brace_block(sp, "if ($script:Provider -eq 'opencode_go')")
ol = sp[sp.index("# Ollama path"):]
check("T4 send prepares with start", "Prepare-Ollama -StartIfNeeded $true" in ol)
check("T4 send start-fail resets Running", all(s in ol for s in ("$script:Running = $false", "Ollama not running", "return")))
check("T4 opencode send never prepares", "Prepare-Ollama" not in oc)
check("T4 settings test prepares", PS.count("Prepare-Ollama -StartIfNeeded $true") >= 2)
check("T4 switch never prepares for opencode", "Prepare-Ollama" not in sw)
```

Notes: `# ---- UI` is the unique comment after `Update-OllamaModels`'s startup block (line 350) — use it as the end marker so the span always covers the whole function. `Toggle-Popup` (line 629) → `Start-OopRun` (line 653) brackets the show-refresh call at 637.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py`
Expected: T4 FAIL lines (plus any marker-adjustment fix); exit 1; T2 lines still PASS.

- [ ] **Step 3: Implement the lifecycle helpers**

Immediately before `function Update-OllamaModels`, insert:

```powershell
$script:OllamaDemoted = $false
function Test-OllamaApi([int]$sec = 2) {
    try { $null = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec $sec; return $true } catch { return $false }
}
function Start-OllamaApp {
    $env:OLLAMA_NUM_PARALLEL = '1'
    $env:OLLAMA_MAX_LOADED_MODELS = '1'
    $cands = @()
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ollama.lnk'
    if (Test-Path -LiteralPath $lnk) {
        try {
            $sh = New-Object -ComObject WScript.Shell
            $t = $sh.CreateShortcut($lnk)
            if ($t.TargetPath) { $cands += , @($t.TargetPath, $t.Arguments) }
        } catch { }
    }
    $cands += , @("$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe", '')
    $cands += , @("$env:LOCALAPPDATA\Ollama\ollama app.exe", '')
    $cli = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
    if ($cli) { $cands += , @($cli.Source, 'serve') }
    foreach ($p in $cands) {
        if ($p[0] -and (Test-Path -LiteralPath $p[0])) {
            try {
                if ($p[1]) { Start-Process -FilePath $p[0] -ArgumentList $p[1] | Out-Null }
                else { Start-Process -FilePath $p[0] | Out-Null }
                return $true
            } catch { }
        }
    }
    return $false
}
function Set-OllamaLowPriority {
    if ($script:OllamaDemoted) { return }
    $procs = @(Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    foreach ($p in $procs) { try { $p.PriorityClass = 'BelowNormal' } catch { } }
    $script:OllamaDemoted = $true
}
function Prepare-Ollama([bool]$StartIfNeeded) {
    if ($OllamaUrl -notmatch '^https?://(127\.0\.0\.1|localhost)([:/]|$)') { return $true }  # custom base: lifecycle not ours
    if (Test-OllamaApi 1) { Set-OllamaLowPriority; return $true }   # already running: leave it alone
    if (-not $StartIfNeeded) { return $false }
    Set-Status 'Starting Ollama...'
    if (-not (Start-OllamaApp)) { return $false }
    $deadline = (Get-Date).AddSeconds([int]$script:Config.network.connect_timeout)
    Start-Sleep -Milliseconds 300
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaApi 2) { Set-OllamaLowPriority; Set-Status 'Ollama ready'; return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
```

Startup-ordering safety: the only script-load-time call is `[void](Update-OllamaModels)` (passes `$false`), which can never reach the `Set-Status` start path; every `Set-Status`-touching call happens later at runtime, after line 460's definition has executed.

- [ ] **Step 4: Wire the call sites**

1. `Update-OllamaModels` — signature → `function Update-OllamaModels([bool]$StartIfNeeded = $false)`; first statement:

```powershell
if (-not (Prepare-Ollama -StartIfNeeded $StartIfNeeded)) {
    $script:OllamaOk = $false
    $script:QwenModels = @()
    $script:MissingSaved = $null
    $script:Model = ''
    Sync-ModelCombo
    return $false
}
```

(`Task 7` adds `$script:QwenModelDetails = @()` to this reset — do not add it here.)
2. `Switch-Provider` ollama branch: `Update-OllamaModels` → `Update-OllamaModels $true`.
3. `Toggle-Popup` show-refresh: same replacement.
4. Startup line stays `[void](Update-OllamaModels)` (probe-only).
5. `Send-Prompt` Ollama branch — first statements, before the sizing block:

```powershell
if (-not (Prepare-Ollama -StartIfNeeded $true)) {
    $script:Running = $false
    Set-Status 'Ollama not running - open Ollama'
    return
}
```

6. Settings Test ollama branch — wrap: `if (-not (Prepare-Ollama -StartIfNeeded $true)) { $lblS.Text = 'Ollama not reachable at that URL' } else { try { $null = Invoke-RestMethod -Uri "$b/api/tags" -TimeoutSec 5; $lblS.Text = 'OK - Ollama reachable' } catch { $lblS.Text = 'Ollama not reachable at that URL' } }` (the `try/catch` body is the existing code, moved inside the `else`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py`
Expected: both `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add windows/Drop.ps1
git commit -m "feat(ollama): on-demand start helper + call sites (win)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Installers — disable Ollama login auto-start

**Files:**
- Modify: `install-drop.sh` (after `launchctl bootstrap "gui/$(id -u)" "$AGENT"`); `windows/Install Drop.cmd` (after the two `copy` lines, before the shortcut `powershell` line).
- Test: append to `test-ollama-mac.py` and `test-ollama-win.py`.

**Interfaces:**
- Produces: nothing consumed later — pure installer lines (spec §6).
- Consumes: existing installer structure only.

- [ ] **Step 1: Append the failing test sections**

To `test-ollama-mac.py`:

```python
# ---- Task 5: login disable (mac installer) ----
check("T5 bootout ollama job", 'launchctl bootout "gui/$(id -u)/com.ollama.ollama"' in SH)
check("T5 disable ollama job", 'launchctl disable "gui/$(id -u)/com.ollama.ollama"' in SH)
check("T5 non-fatal", SH.index('launchctl bootout "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true') != -1
      and SH.index('launchctl disable "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true') != -1)
check("T5 only ollama job touched", "com.ollama" in SH and SH.count("com.ollama.ollama") == 2)
```

To `test-ollama-win.py`:

```python
# ---- Task 5: login disable (win installer) ----
CMD = (ROOT / "windows" / "Install Drop.cmd").read_text()
check("T5 removes Run value", 'reg delete "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" /v Ollama /f >nul 2>&1' in CMD)
check("T5 no other Run values touched", CMD.count("reg delete") == 1 and "HKLM" not in CMD)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py`
Expected: `T5 bootout ollama job` FAIL (mac), `T5 removes Run value` FAIL (win); exit 1.

- [ ] **Step 3: Insert the installer lines**

`install-drop.sh`, directly after `launchctl bootstrap "gui/$(id -u)" "$AGENT"`:

```bash
# Ollama: never auto-start at login (Drop starts it on demand when used).
launchctl bootout "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true
```

`windows/Install Drop.cmd`, directly after the two `copy` lines:

```bat
rem Ollama: remove login auto-start only (Drop starts it on demand when used).
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Ollama /f >nul 2>&1
echo Ollama login auto-start disabled (starts on demand from Drop).
```

- [ ] **Step 4: Run tests + typecheck to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh && bash -n install-drop.sh`
Expected: both tests `ALL PASS`; `TYPECHECK OK`; `bash -n` silent (exit 0).

- [ ] **Step 5: Commit**

```bash
git add install-drop.sh "windows/Install Drop.cmd"
git commit -m "feat(ollama): disable Ollama login auto-start in installers

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: Default provider = OpenCode Go (fresh configs) + README

**Files:**
- Modify: `install-drop.sh` line 23 area (config JSON `"provider": "ollama"` → `"opencode_go"`) and `DropConfig` (`var provider = "ollama"` → `"opencode_go"`); `windows/Drop.ps1` `Read-DropConfig` (`provider    = 'ollama'` → `'opencode_go'`); `README.md` (config example + Mac step 3 + Windows step 2).
- Test: create `test-readme.py`; append default-provider pins to mac/win test files.

**Interfaces:**
- Produces: nothing consumed by later code tasks — documentation + defaults (spec §8). Existing configs untouched: the installer's config write stays behind its existing `if` guard; no code path rewrites a stored `provider`.
- Consumes: behaviors from Tasks 1–5 (README text describes them).

- [ ] **Step 1: Write the failing tests**

Create `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-readme.py` (same skeleton; reads `README.md`):

```python
RD = (ROOT / "README.md").read_text()
check("R default example", '"provider": "opencode_go"' in RD)
check("R mac on-demand note", RD.count("never at login") >= 2)
check("R keep_alive note", "keep_alive: 0" in RD)
```

Append to `test-ollama-mac.py`:

```python
# ---- Task 6: default provider (mac) ----
check("T6 installer default", '"provider": "opencode_go"' in SH)
check("T6 code default", 'var provider = "opencode_go"' in SH)
```

Append to `test-ollama-win.py`:

```python
# ---- Task 6: default provider (win) ----
import re as _re2
check("T6 read-config default", _re2.search(r"provider\s+= 'opencode_go'", PS) is not None)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-readme.py`
Expected: T6 + R FAIL lines; exit 1.

- [ ] **Step 3: Flip the three defaults**

1. `install-drop.sh` config JSON: `"provider": "ollama",` → `"provider": "opencode_go",` (keep indentation).
2. `install-drop.sh` `DropConfig`: `var provider = "ollama"` → `var provider = "opencode_go"` (keep the trailing comment `// "ollama" | "opencode_go"`).
3. `windows/Drop.ps1` `Read-DropConfig`: `provider    = 'ollama'` → `provider    = 'opencode_go'` (keep column alignment).

- [ ] **Step 4: Update README**

Config example: `"provider": "ollama",` → `"provider": "opencode_go",`.

Mac step 3 becomes:

```markdown
3. For **Ollama**: install Ollama and pull any Qwen model
   (e.g. `ollama pull qwen3-coder`) — Drop discovers every installed Qwen
   model and offers it in the popup's model dropdown. Ollama starts on
   demand only (never at login), unloads every model right after an answer
   (`keep_alive: 0`), and runs at low priority while generating
```

Windows step 2 becomes:

```markdown
2. For **Ollama**: install Ollama for Windows and pull any Qwen model
   (e.g. `ollama pull qwen3-coder`) — the popup's dropdown lists every
   installed Qwen model. Ollama starts on demand only (never at login),
   unloads every model right after an answer (`keep_alive: 0`), and runs
   at low priority while generating
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-readme.py`
Expected: all three `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add install-drop.sh windows/Drop.ps1 README.md
git commit -m "feat: default provider OpenCode Go + README lifecycle notes

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: Model metadata labels in dropdowns (display-only) + label→name resolution

**Files:**
- Modify: `install-drop.sh`: `OllamaProvider` (`listModels` → wrap a new `listModelDetails`), `AppDelegate` (new `modelLabelsToNames` + `resolvedModelName`), `loadModels`, `modelChanged`, run-path model guard (marker `// The popup only ever holds models`). `windows/Drop.ps1`: `Sync-ModelCombo`, `Update-OllamaModels` (details pipeline + catch reset), `$cmbModel.Add_SelectedIndexChanged`, Task 4's prepare-fail reset (add `$script:QwenModelDetails = @()`).
- Test: append to `test-ollama-mac.py` and `test-ollama-win.py`.

**Interfaces:**
- Consumes: Task 3's `loadModels(startIfNeeded:)` signature (keep it), Task 4's `Update-OllamaModels([bool]$StartIfNeeded = $false)` (keep it), unchanged `ProviderAdapter.listModels() async -> [String]?` (protocol must not change — OpenCode lock).
- Produces: `OllamaProvider.listModelDetails() async -> [(name: String, label: String)]?`; `AppDelegate.modelLabelsToNames: [String: String]`, `AppDelegate.resolvedModelName(from:) -> String?`; `$script:QwenModelDetails` (array of `@{Name; Label}`).

- [ ] **Step 1: Append the failing test sections**

To `test-ollama-mac.py`:

```python
# ---- Task 7: metadata labels + resolution (mac) ----
check("T7 protocol unchanged", "func listModels() async -> [String]?" in SH)
check("T7 listModelDetails exists", "func listModelDetails() async -> [(name: String, label: String)]?" in SH)
# Marker includes the impl's trailing "{" so the protocol declaration (same
# signature, no brace) is not matched first.
lm_body = between(SH, "func listModels() async -> [String]? {", "// --- OpenCode Go")
check("T7 listModels wraps details", "listModelDetails" in lm_body and "isQwenFamily" not in lm_body)
check("T7 metadata keys", "parameter_size" in SH and "quantization_level" in SH)
check("T7 label separator", " · " in SH)
loadm = between(SH, "func loadModels(", "@objc func modelChanged")
check("T7 loadModels builds label map", "modelLabelsToNames" in loadm and "listModelDetails" in loadm)
check("T7 loadModels keeps start param", "func loadModels(startIfNeeded: Bool = false)" in SH)
mc = between(SH, "@objc func modelChanged", "// Phase 6: toggle")
check("T7 modelChanged resolves name", "resolvedModelName(from:" in mc)
runp = between(SH, "// The popup only ever holds models", "func generate(prompt: String")
check("T7 run path resolves name", "resolvedModelName(from:" in runp)
check("T7 resolver helper", "func resolvedModelName(from title: String?) -> String?" in SH)
```

To `test-ollama-win.py`:

```python
# ---- Task 7: metadata labels + resolution (win) ----
upd = between(PS, "function Update-OllamaModels", "# ---- UI")
sync = between(PS, "function Sync-ModelCombo", "function Update-OllamaModels")
sel = between(PS, "$cmbModel.Add_SelectedIndexChanged({", "Sync-ModelCombo")
check("T7 details array", "$script:QwenModelDetails" in PS)
check("T7 update builds details", "parameter_size" in upd and "quantization_level" in upd and "Label" in upd)
check("T7 update keeps start param", "function Update-OllamaModels([bool]$StartIfNeeded = $false)" in PS)
check("T7 names still drive saved logic", "$script:QwenModels -contains $script:Model" in upd)
check("T7 sync shows labels", "$d.Label" in sync or "Label" in sync)
check("T7 selection resolves Name", "$d.Name" in sel and "default_model" in sel)
check("T7 catch resets details", upd.count("$script:QwenModelDetails = @()") >= 2)
check("T7 label separator", " · " in PS)
```

(`upd` spans the whole function including its `catch`; the second `QwenModelDetails = @()` reset is the one added to Task 4's prepare-fail block in Step 4.2 below.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py`
Expected: T7 FAIL lines; earlier sections still PASS; exit 1.

- [ ] **Step 3: Implement mac details + resolution**

1. In `OllamaProvider`, move `listModels`' body into `func listModelDetails() async -> [(name: String, label: String)]?` — same cloud filter + `isQwenFamily` filter + sort (by name), but each kept model becomes `(name, label)` where `label = name` plus ` · parameter_size` and ` · quantization_level` when `details` provides them (join `[name] + bits` with `" · "`). Then:

```swift
func listModels() async -> [String]? {
    guard let items = await listModelDetails() else { return nil }
    return items.map { $0.name }
}
```

2. On `AppDelegate`: `var modelLabelsToNames: [String: String] = [:]` and `func resolvedModelName(from title: String?) -> String? { guard let t = title else { return nil }; return modelLabelsToNames[t] ?? t }`.
3. `loadModels` ollama branch — **one** `/api/tags` fetch per call (do not call both `listModels` and `listModelDetails`):

```swift
let details: [(name: String, label: String)]?
let names: [String]?
if provider.id == "ollama" {
    details = await (provider as? OllamaProvider)?.listModelDetails()
    names = details?.map { $0.name }
} else {
    details = nil
    names = await provider.listModels()
}
```

Then set `modelLabelsToNames` from `(details ?? []).map { ($0.label, $0.name) }` (opencode branch: `modelLabelsToNames = [:]`); build the popup `list` from `details?.map { $0.label }` when non-nil (fall back to today's `names`-based path when `details == nil`, preserving every status string). Saved-model selection: when `saved` is a **name**, select via `modelLabelsToNames.first(where: { $0.value == saved })?.key`, else keep the existing `list.contains(saved)` / missingSaved fallbacks (they still see bare names when metadata is absent, because label == name then).
4. `modelChanged`: for ollama, persist `resolvedModelName(from: modelPopup.titleOfSelectedItem)` into both the `model` UserDefaults key and `config.ollamaDefaultModel`; opencode path unchanged (title as-is).
5. Run-path guard (`// The popup only ever holds models`): `guard let model = resolvedModelName(from: modelPopup.titleOfSelectedItem), !model.isEmpty else`.

- [ ] **Step 4: Implement win details + resolution**

1. In `Update-OllamaModels`, replace the `| ForEach-Object { [string]$_.name } | Sort-Object` tail: build `$script:QwenModelDetails = @(... | ForEach-Object { $n = [string]$_.name; $bits = @(); if ($_.details -and $_.details.parameter_size) { $bits += [string]$_.details.parameter_size }; if ($_.details -and $_.details.quantization_level) { $bits += [string]$_.details.quantization_level }; $label = if ($bits.Count -gt 0) { (@($n) + $bits) -join ' · ' } else { $n }; [pscustomobject]@{ Name = $n; Label = $label } } | Sort-Object Name)` then `$script:QwenModels = @($script:QwenModelDetails | ForEach-Object { $_.Name })` (keeps all saved-model logic name-based). In the `catch`, add `$script:QwenModelDetails = @()`.
2. Task 4's prepare-fail reset inside `Update-OllamaModels`: add `$script:QwenModelDetails = @()` alongside the existing resets (this is the second `= @()` count the test expects).
3. `Sync-ModelCombo`: add `$d.Label` items from `$script:QwenModelDetails` (fallback to `$script:QwenModels` names only if details array is empty — they are built together, so the fallback is a one-liner guard, not a second source of truth).
4. `Add_SelectedIndexChanged`: resolve before saving — `$idx = $script:ModelCombo.SelectedIndex`; `$d = if ($idx -ge 0 -and $idx -lt $script:QwenModelDetails.Count) { $script:QwenModelDetails[$idx] } else { $null }`; `$name = if ($d) { [string]$d.Name } else { [string]$script:ModelCombo.SelectedItem }`; then the existing `if ($script:Model -ne …)` block uses `$name` for `$script:Model` and the `default_model` Add-Member value.

- [ ] **Step 5: Run tests + typecheck to verify they pass**

Run: `python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-readme.py && bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh`
Expected: all three tests `ALL PASS`; `TYPECHECK OK`.

- [ ] **Step 6: Commit**

```bash
git add install-drop.sh windows/Drop.ps1
git commit -m "feat(ollama): model size/quantization labels in dropdowns

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 8: Final verification — full suite, OpenCode byte-lock gate, full rebuild

**Files:**
- Create: `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode_gate.py`, `.superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode-gate.sh` (workspace-only, never committed).
- Modify: only if a gate failure or suite failure forces a fix (then RED→GREEN per finding).

**Interfaces:**
- Consumes: everything from Tasks 1–7; BASE for the gate is `d1ee02f` (the commit this plan started from).
- Produces: the evidence for the final report (expert brief §17 deliverable format).

- [ ] **Step 1: Write the OpenCode gate**

`.superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode_gate.py`:

```python
#!/usr/bin/env python3
"""Byte-lock gate: OpenCode Go code must be identical to BASE."""
import subprocess, sys, pathlib
ROOT = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
BASE = sys.argv[1] if len(sys.argv) > 1 else "d1ee02f"
fails = []

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else (" -- " + detail)))
    if not cond: fails.append(name)

def between(t, s, e):
    i = t.index(s); j = t.index(e, i + len(s)); return t[i:j]

def brace_block(t, s):
    i = t.index(s); d = 0
    for k in range(i, len(t)):
        if t[k] == '{': d += 1
        elif t[k] == '}':
            d -= 1
            if d == 0: return t[i:k+1]
    raise SystemExit("unbalanced: " + s)

def show(path):
    return subprocess.check_output(["git", "show", f"{BASE}:{path}"], text=True, cwd=ROOT)

def work(path):
    return (ROOT / path).read_text()

# 1) mac: OpenCodeGoProvider struct byte-identical
b_mac = between(show("install-drop.sh"), "struct OpenCodeGoProvider: ProviderAdapter {", "final class FloatPanel")
w_mac = between(work("install-drop.sh"), "struct OpenCodeGoProvider: ProviderAdapter {", "final class FloatPanel")
check("GATE mac OpenCodeGoProvider identical", b_mac == w_mac)

# 2) win: Send-Prompt's opencode branch byte-identical
b_sp = between(show("windows/Drop.ps1"), "function Send-Prompt", "$script:DoubleCheck = $false")
w_sp = between(work("windows/Drop.ps1"), "function Send-Prompt", "$script:DoubleCheck = $false")
b_oc = brace_block(b_sp, "if ($script:Provider -eq 'opencode_go')")
w_oc = brace_block(w_sp, "if ($script:Provider -eq 'opencode_go')")
check("GATE win Send-Prompt opencode branch identical", b_oc == w_oc)

# 3) no sensitive OpenCode tokens on any changed line
diff = subprocess.check_output(["git", "diff", BASE, "--", "install-drop.sh", "windows/Drop.ps1", "windows/Install Drop.cmd"],
                               text=True, cwd=ROOT)
bad = [l for l in diff.splitlines()
       if l[:1] in "+-" and l[:3] not in ("+++", "---")
       and any(t in l for t in ("x-opencode", "chat/completions", "Bearer", "ocKey", "ocBase",
                                "ocModel", "ocStream", "sessionId", "opencode-session", "api_key"))]
check("GATE no sensitive tokens in diff", not bad, "; ".join(bad[:5]))

print("---")
if fails:
    print(f"{len(fails)} FAIL"); sys.exit(1)
print("GATE PASS")
```

`.superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode-gate.sh`:

```bash
#!/bin/bash
set -e
ROOT="$(git rev-parse --show-toplevel)"
python3 "$ROOT/.superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode_gate.py" "${1:-d1ee02f}"
```

- [ ] **Step 2: Run the gate — expect it to pass**

Run: `bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode-gate.sh d1ee02f`
Expected: `GATE PASS`. If it fails: the failure names a real OpenCode edit — revert that edit (do not weaken the gate), re-run, and ledger the revert.

- [ ] **Step 3: Run the complete suite**

Run:
```bash
python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-mac.py && \
python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-ollama-win.py && \
python3 .superpowers/sdd/2026-11-18-ollama-quiet-laptop/test-readme.py && \
bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/typecheck-mac.sh && \
bash .superpowers/sdd/2026-11-18-ollama-quiet-laptop/opencode-gate.sh d1ee02f && \
bash -n install-drop.sh
```
Expected: three `ALL PASS`, `TYPECHECK OK (>1000 lines)`, `GATE PASS`, `bash -n` silent — exit 0.

- [ ] **Step 4: Full installer rebuild (exercises the new installer lines for real)**

Run: `bash install-drop.sh`
Expected: exit 0, prints `✅ Installed. Starting Drop...`. Side effects are the approved feature set on this machine (Drop reinstalled; `com.ollama.ollama` bootout+disable executed — the login-disable feature the design specifies). If the compile step fails, fix and re-run Steps 1–3 first.

- [ ] **Step 5: Confirm working tree and commit (only if tracked files changed)**

Run: `git status --porcelain -- install-drop.sh windows README.md .gitignore`
Expected: empty (Tasks 1–7 committed everything; gate/tests live in the ignored workspace). If non-empty, commit the fix with the RED→GREEN evidence from the failing step that forced it:

```bash
git add -u
git commit -m "chore(ollama): final verification fixes

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

- [ ] **Step 6: Record suite result**

Run the suite command from Step 3 once more and record its output in the ledger (`Task 8: complete …`). The final report to the human partner follows the expert brief's §17 deliverable list: what changed, files, per-platform lifecycle, discovery behavior, protections, env vars, tests + results, limitations, explicit OpenCode-not-modified confirmation — plus the spec's 8-item user live checklist.

---

## Self-review notes (written during plan creation)

- **Spec coverage:** Decisions 1–9 map to Tasks 1–7 (1→T1/T2, 2→T1/T2, 3→T3/T4, 4→T3/T4, 5→T3/T4, 6→T5, 7→T7, 8→T6, 9→status strings pinned in T3/T4 + hint in T1/T2). Verification section → T8 + live checklist in T8 Step 6. Non-goals: no auto-quit, no config rewrite (T6 flips only defaults; installer `if` guard untouched), no `OLLAMA_MAX_QUEUE`, no new panels.
- **OpenCode lock:** protocol `listModels()` signature untouched (T7 pin); gate at T8 covers struct, send branch, and diff tokens; T6's default lines contain none of the gate's sensitive tokens.
- **Ordering interfaces:** T3→T7 (`loadModels(startIfNeeded:)` kept), T4→T7 (`Update-OllamaModels` param kept; T7 adds `QwenModelDetails` to T4's reset), T1→T3 (same `generate`, insert-only at top), T2→T4 (sizing helpers untouched by T4), T6 after T5 (README describes shipped behavior).
