# IntelliJ Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add IntelliJ-scoped hotkeys to Drop on macOS and Windows: one combined key reads `Desktop/OOP` and starts the AI run headless (no popup), one copies the full answer, and ⌃⌥1–0 / Ctrl+Alt1–0 copy individual task sections.

**Architecture:** Extend the existing Carbon `RegisterEventHotKey` handler (macOS) and the existing `DropNative` `RegisterHotKey` window (Windows) with new key ids and an id-based dispatcher; each new action reuses the existing pipeline (`handle()` / `Start-Answer`, `copyToClipboard` / `Clipboard.SetText`) and the existing `// ===== Task N =====` header format for slicing. A press-time frontmost gate (IntelliJ or Drop itself) guards every new key; ⌃⌥D / Ctrl+Alt+D stays global and unchanged.

**Tech Stack:** Swift (AppKit/Carbon, embedded in the `install-drop.sh` heredoc), PowerShell 5.1 + WinForms + user32 `RegisterHotKey`.

**Spec:** `docs/superpowers/specs/2026-11-18-intellij-hotkeys-design.md`

## Global Constraints

- OpenCode Go integration is LOCKED: no edits to `OpenCodeGoProvider` (mac) or the `Send-Prompt`/Test Connection opencode branches (Windows) — endpoint, headers, body, streaming, retries, config format all untouched.
- macOS Swift lives inside `install-drop.sh` heredoc: `EOF` (Swift), `CFGEOF` (config), `EOF2` (launchd) delimiters must remain intact and unique.
- Windows: PowerShell 5.1 compatible — no `??` operator; optional config properties via `Add-Member -Force`.
- Combined run is HEADLESS: never call `togglePanel()` / `Toggle-Popup` from ⌃⌥R / Ctrl+Alt+R.
- Frontmost gate applies to new keys only; ⌃⌥D / Ctrl+Alt+D remains ungated.
- Gate allows: IntelliJ (mac bundle id `com.jetbrains.intellij` or name contains "IntelliJ"; Windows process `idea64`/`idea`) **or** Drop itself frontmost.
- No API key may appear in logs, status text, or error messages (existing rule).
- This repo has no automated test harness (existing pattern: compile check + manual verification). Verification steps below follow that pattern.
- Live hotkey checks happen ONCE, after Task 5 rebuilds the app (Tasks 1–4 verify by typecheck/parse only — the running app still has the old code until then).

## Review Focus

Each line's test lives in **Task 5 Step 4** (the consolidated live checklist, run after the rebuild):

1. **Hotkey fires while a non-IntelliJ app is frontmost** (e.g. Safari) — expected: press ignored, no run, no clipboard change. → checklist item 3.
2. **`Desktop/OOP` missing or not a folder** — expected: status "OOP folder not found on Desktop", zero network requests. → checklist item 2.
3. **Copy-task with no answer, or Task N absent from answer** — expected: status message, clipboard left untouched. → checklist items 4 (Task N absent variant: run with a short answer).
4. **⌃⌥R pressed while a run is in progress** — expected: "Busy" status, no second concurrent run. → checklist item 5.
5. **OpenCode Go regression** — expected: Test Connection and a normal drop behave exactly as before. → checklist item 6, plus Task 5 Step 2's diff check.

---

### Task 1: macOS — gate, hotkey registration/dispatch, combined OOP run (⌃⌥R)

**Files:**
- Modify: `install-drop.sh` — Swift heredoc: `registerHotKey()` (~line 1062), new methods on `AppDelegate`, gate helper

**Interfaces:**
- Consumes: existing `handle(_ urls: [URL])` (line ~1207), `setStatus(_:)`, `running`
- Produces:
  - `var hotkeyGateAllowed: Bool` (AppDelegate) — true when IntelliJ or Drop is frontmost
  - `func oopRunHotkey()` (AppDelegate) — headless combined run
  - Dispatch ids: `1`=⌃⌥D toggle, `2`=⌃⌥R, `3`=⌃⌥C (Task 2), `4…13`=⌃⌥1…9,0 (Task 2)
  - Hotkey signature constant `OSType(0x44524F50)` unchanged

- [ ] **Step 1: Replace the hotkey callback + registration with id-based dispatch**

In `registerHotKey()` keep `EventTypeSpec`/`InstallEventHandler` but change the callback to read the pressed id:

```swift
var hkID = EventHotKeyID()
GetEventParameter(event, EventParamName(kEventParamDirectObject),
                  EventParamType(typeEventHotKeyID), nil,
                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
DispatchQueue.main.async {
    switch hkID.id {
    case 1: me.togglePanel()
    case 2: if me.hotkeyGateAllowed { me.oopRunHotkey() }
    // ids 3 and 4…13 added in Task 2
    default: break
    }
}
```

Then register all keys in a loop (replacing the single `RegisterEventHotKey` for D):

```swift
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
```

- [ ] **Step 2: Add `hotkeyGateAllowed` and `oopRunHotkey()` to `AppDelegate`**

```swift
var hotkeyGateAllowed: Bool {
    if let front = NSWorkspace.shared.frontmostApplication {
        if front.bundleIdentifier == "com.jetbrains.intellij" { return true }
        if (front.localizedName ?? "").contains("IntelliJ") { return true }
    }
    return NSApp.isActive   // Drop itself frontmost → allow (test copies from popup)
}

@objc func oopRunHotkey() {
    guard !running else { setStatus("⏳ Busy – wait for the current answer"); return }
    let oop = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/OOP")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: oop.path, isDirectory: &isDir),
          isDir.boolValue else {
        setStatus("⚠️ OOP folder not found on Desktop"); return
    }
    handle([oop])   // headless: handle() never opens the panel
}
```

- [ ] **Step 3: Type-check the extracted Swift**

Run:
```bash
python3 - <<'PY'
import re
src = open('install-drop.sh').read()
m = re.search(r'cat > "\$DIR/main\.swift" <<\'EOF\'\n(.*?)\nEOF\n', src, re.S)
assert m, "heredoc not found"
open('/tmp/drop-main.swift','w').write(m.group(1))
print("extracted", len(m.group(1)), "chars")
PY
swiftc -typecheck /tmp/drop-main.swift && echo TYPECHECK_OK
```
Expected: `extracted … chars` then `TYPECHECK_OK`, exit 0. (Also implicitly proves `EOF` delimiter still matches.)

- [ ] **Step 4: Commit**

```bash
git add install-drop.sh
git commit -m "feat(mac): IntelliJ-gated hotkeys with combined OOP run (⌃⌥R)"
```

---

### Task 2: macOS — copy-all (⌃⌥C) and task slice (⌃⌥1…⌃⌥0)

**Files:**
- Modify: `install-drop.sh` — Swift heredoc: dispatch switch (from Task 1), new static func + two handlers

**Interfaces:**
- Consumes: Task 1 dispatch switch (add `case 3` and `case 4...13`), `lastAnswer`, `copyToClipboard(_:)`, `setStatus(_:)`
- Produces: `static func taskSection(_ answer: String, n: Int) -> String?` (AppDelegate), `func copyAllHotkey()`, `func copyTaskHotkey(_ n: Int)`

- [ ] **Step 1: Add `taskSection` static slicer to `AppDelegate`**

```swift
// Slice "…// ===== Task N ===== …" up to (excluding) the next Task header.
static func taskSection(_ answer: String, n: Int) -> String? {
    let lines = answer.components(separatedBy: "\n")
    let header = "// ===== Task \(n) ====="
    guard let start = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix(header)
    }) else { return nil }
    var end = lines.count
    for i in (start + 1)..<lines.count
    where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("// ===== Task ") {
        end = i; break
    }
    let slice = lines[start..<end].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return slice.isEmpty ? nil : slice
}
```

Note: `hasPrefix("// ===== Task 1 =====")` cannot match a Task 10 header (the "10" diverges before " ====="), so N=1 is safe.

- [ ] **Step 2: Add the two handlers**

```swift
@objc func copyAllHotkey() {
    guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
    copyToClipboard(lastAnswer)
    setStatus("📋 Answer copied · paste with ⌘V")
}

@objc func copyTaskHotkey(_ n: Int) {
    guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
    guard let slice = AppDelegate.taskSection(lastAnswer, n: n) else {
        setStatus("⚠️ Task \(n) not found in answer"); return
    }
    copyToClipboard(slice)
    setStatus("✅ Task \(n) copied · paste with ⌘V")
}
```

- [ ] **Step 3: Extend the dispatch switch from Task 1**

```swift
case 3: if me.hotkeyGateAllowed { me.copyAllHotkey() }
case 4...13: if me.hotkeyGateAllowed { me.copyTaskHotkey(Int(hkID.id - 3)) }
```
(id 4→task 1 … id 12→task 9, id 13→task 10)

- [ ] **Step 4: Type-check**

Run the same extract + `swiftc -typecheck` command as Task 1 Step 3.
Expected: `TYPECHECK_OK`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add install-drop.sh
git commit -m "feat(mac): copy-all ⌃⌥C and per-task copy ⌃⌥1-0"
```

---

### Task 3: Windows — hotkey id plumbing, gate, combined OOP run (Ctrl+Alt+R)

**Files:**
- Modify: `windows/Drop.ps1` — embedded C# `DropNative` (~line 164), registration (~line 630), new functions

**Interfaces:**
- Consumes: existing `Start-Answer([string[]]$paths)`, `Set-Status`, `$script:Running`, `$form`
- Produces:
  - C# `public int LastHotKeyId` + `GetForegroundWindow()` interop on `DropNative`
  - `function Test-DropHotkeyGate` (returns $true/$false)
  - `function Start-OopRun`
  - Ids: `1`=Ctrl+Alt+D (existing, ungated), `2`=R, `3`=C, `4…13`=1…9,0

- [ ] **Step 1: Extend the embedded C# `DropNative` class**

Add to the `DllImport` block:
```csharp
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
public int LastHotKeyId;
public static bool IsIntelliJForeground() {
    int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    try {
        var p = System.Diagnostics.Process.GetProcessById(pid);
        var n = p.ProcessName.ToLowerInvariant();
        return n == "idea64" || n == "idea" || p.MainWindowTitle.Contains("IntelliJ");
    } catch { return false; }
}
```
Change `WndProc` to record the id before raising the event:
```csharp
if (m.Msg == 0x0312) { LastHotKeyId = m.WParam.ToInt32(); if (HotKey != null) HotKey(this, EventArgs.Empty); }
```

- [ ] **Step 2: Add gate + combined-run functions (before the registration block)**

```powershell
function Test-DropHotkeyGate {
    if ([DropNative]::IsIntelliJForeground()) { return $true }
    return ([DropNative]::GetForegroundWindow() -eq $form.Handle)  # Drop itself frontmost
}
function Start-OopRun {
    if (-not (Test-DropHotkeyGate)) { return }
    if ($script:Running) { Set-Status 'Busy - wait for the current result'; return }
    $oop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OOP'
    if (-not (Test-Path -LiteralPath $oop -PathType Container)) {
        Set-Status 'OOP folder not found on Desktop'; return
    }
    Start-Answer @($oop)   # headless: never calls Toggle-Popup
}
```

- [ ] **Step 3: Register keys 2–13 and replace the hotkey handler with a dispatcher**

```powershell
$vk = @{ R = 0x52; C = 0x43; '1' = 0x31; '2' = 0x32; '3' = 0x33; '4' = 0x34
         '5' = 0x35; '6' = 0x36; '7' = 0x37; '8' = 0x38; '9' = 0x39; '0' = 0x30 }
[void][DropNative]::RegisterHotKey($native.Handle, 1, (0x0001 -bor 0x0002 -bor 0x4000), 0x44)  # existing, keep
$hid = 2
foreach ($k in @('R','C','1','2','3','4','5','6','7','8','9','0')) {
    [void][DropNative]::RegisterHotKey($native.Handle, $hid, (0x0001 -bor 0x0002 -bor 0x4000), $vk[$k])
    $hid++
}
$native.add_HotKey({
    switch ($native.LastHotKeyId) {
        1 { Toggle-Popup }
        2 { Start-OopRun }
        # ids 3 and 4…13 added in Task 4
        default { }
    }
})
```
Remove the old `$native.add_HotKey({ Toggle-Popup })` line (replaced by the dispatcher).

- [ ] **Step 4: PowerShell parse check**

Run:
```bash
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'windows/Drop.ps1')) | Out-Null; 'PARSE_OK'"
else
  echo "pwsh not on this Mac - parse check deferred to the Windows machine"
fi
```
Expected: `PARSE_OK`, or the deferral message (then note it for the user's Windows run).

- [ ] **Step 5: Commit**

```bash
git add windows/Drop.ps1
git commit -m "feat(win): Ctrl+Alt+R combined OOP run with IntelliJ gate"
```

---

### Task 4: Windows — copy-all (Ctrl+Alt+C) and task slice (Ctrl+Alt1…0)

**Files:**
- Modify: `windows/Drop.ps1` — new functions + dispatcher cases (Task 3)

**Interfaces:**
- Consumes: Task 3 dispatcher + `Test-DropHotkeyGate`, `$script:LastAnswer`, `Set-Status`
- Produces: `function Get-TaskSection([string]$answer, [int]$n)` (returns string or $null), `function Copy-AllAnswer`, `function Copy-TaskAnswer([int]$n)`

- [ ] **Step 1: Add slicer + copy functions (after `Start-OopRun`)**

```powershell
function Get-TaskSection([string]$answer, [int]$n) {
    $lines = $answer -split "`r?`n"
    $header = "===== Task $n ====="
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith($header)) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith("===== Task ")) { $end = $i; break }
    }
    $slice = ($lines[$start..($end - 1)] -join "`r`n").Trim()
    if ([string]::IsNullOrWhiteSpace($slice)) { return $null }
    return $slice
}
function Copy-AllAnswer {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Set-Status 'No answer yet'; return }
    [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
    Set-Status 'Copied - paste with Ctrl+V'
}
function Copy-TaskAnswer([int]$n) {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Set-Status 'No answer yet'; return }
    $s = Get-TaskSection $script:LastAnswer $n
    if ($null -eq $s) { Set-Status "Task $n not found in answer"; return }
    [System.Windows.Forms.Clipboard]::SetText($s)
    Set-Status "Task $n copied - paste with Ctrl+V"
}
```
Note: `StartsWith("===== Task 1 =====")` cannot match a Task 10 line, so N=1 is safe. The `// ` prefix is intentionally not required (answers may be re-pasted without it).

- [ ] **Step 2: Extend the dispatcher (from Task 3)**

```powershell
3 { Copy-AllAnswer }
{ $_ -ge 4 -and $_ -le 13 } { Copy-TaskAnswer ($_ - 3) }
```
(id 4→task 1 … id 12→task 9, id 13→task 10)

- [ ] **Step 3: Parse check**

Same command as Task 3 Step 4. Expected: `PARSE_OK` (or deferral note).

- [ ] **Step 4: Commit**

```bash
git add windows/Drop.ps1
git commit -m "feat(win): Ctrl+Alt+C copy-all and Ctrl+Alt1-0 task copy"
```

---

### Task 5: README docs, OpenCode integrity check, final rebuild

**Files:**
- Modify: `README.md` — new Hotkeys section
- Verify only: `install-drop.sh` OpenCode regions, `windows/Drop.ps1` opencode branches

**Interfaces:**
- Consumes: nothing (documentation + verification)

- [ ] **Step 1: Add a Hotkeys section to README.md** (after the provider table)

```markdown
## Hotkeys (IntelliJ workflow)

| Action | macOS | Windows |
|---|---|---|
| Read `Desktop/OOP` + start AI run (headless — open the popup manually to watch) | ⌃⌥R | Ctrl+Alt+R |
| Copy full answer | ⌃⌥C | Ctrl+Alt+C |
| Copy Task 1…9 / Task 10 | ⌃⌥1…9 / ⌃⌥0 | Ctrl+Alt1…9 / Ctrl+Alt0 |
| Show / hide popup | ⌃⌥D | Ctrl+Alt+D |

The four new hotkeys act only while IntelliJ IDEA (or Drop itself) is
frontmost — presses are ignored in other apps. Create `Desktop/OOP` by hand
and put the paper + starter project folders inside it.
```

- [ ] **Step 2: Verify OpenCode Go regions unchanged**

Run:
```bash
git diff 6ee60fc..HEAD -- install-drop.sh windows/Drop.ps1 | grep -E '^[+-]' | grep -iE 'opencode|ocKey|ocBase|ocModel|x-opencode|chat/completions|Bearer' || echo "NO_OPENCODE_DIFFS"
```
Inspect every remaining hit: any `+`/`-` line touching OpenCode request code is a violation to revert. Expected: only comment/doc lines or none. (This plan's tasks add no OpenCode edits; this check proves it.)

- [ ] **Step 3: Full macOS rebuild (real deploy + compile)**

Run: `bash install-drop.sh`
Expected: `Building Drop…` completes with no swiftc errors; launchd job reloads.

- [ ] **Step 4: Manual live checklist (hand to the user — hotkeys can't be pressed by the agent)**

1. IntelliJ frontmost, ⌃⌥R → run starts, popup stays closed; ⌃⌥D opens it showing progress; answer lands on clipboard + Glass sound.
2. `mv ~/Desktop/OOP ~/Desktop/OOP-hidden` → ⌃⌥R → status "OOP folder not found on Desktop", no network activity; restore folder.
3. Safari frontmost → ⌃⌥R / ⌃⌥C / ⌃⌥1 → nothing happens (clipboard unchanged).
4. ⌃⌥C → full answer re-copied; ⌃⌥2 → only Task 2 section (starts at its `// ===== Task 2 =====` header, ends before Task 3).
5. Press ⌃⌥R mid-run → "Busy" status, single run continues.
6. OpenCode selected → Settings → Test Connection still answers; normal drop still works (regression).
7. Repeat 1–4 on Windows with Ctrl+Alt.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: IntelliJ hotkey workflow table"
```
