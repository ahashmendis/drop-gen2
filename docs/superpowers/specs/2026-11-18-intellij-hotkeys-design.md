# Design: IntelliJ-driven hotkeys for Drop (read OOP folder, run, copy answers)

Date: 2026-11-18
Status: awaiting human approval
Platforms: macOS (`install-drop.sh` embedded Swift) and Windows (`windows/Drop.ps1`)

## Intent

The user works inside IntelliJ IDEA and wants to drive Drop entirely from
keyboard shortcuts, without clicking the popup:

1. **One combined hotkey** — read the exam content from a fixed folder and
   immediately start the AI run.
2. **Copy-all hotkey** — put the full answer on the clipboard in one press.
3. **Per-task copy hotkeys** — ⌃⌥1…⌃⌥10 (Ctrl+Alt+1…0 on Windows) copy just
   Task N's section of the answer, so each task can be pasted into IntelliJ
   separately.
4. These hotkeys must **only act while IntelliJ is in use**, never swallow
   those keystrokes elsewhere.

The `OOP` folder on the Desktop is created manually by the user and must
contain the two project folders (paper + starter). Drop reads whatever is
there.

## Goals

- Combined hotkey (headless — never auto-opens the popup; the user opens it
  manually with ⌃⌥D / Ctrl+Alt+D): collect `~/Desktop/OOP` (macOS) /
  `~\Desktop\OOP` (Windows) + start the standard generation pipeline
  (extract → prompt → provider → compile-check/repairs on macOS → clipboard
  + notification).
- Copy-all hotkey copies the last completed answer.
- Task hotkeys 1–10 slice the last answer on `// ===== Task N =====` headers
  and copy that section only.
- Hotkeys registered always (decision A), but act only when the frontmost
  context is IntelliJ IDEA or Drop itself.
- Full parity: same hotkey scheme and behaviour on Windows with Ctrl+Alt.
- Existing ⌃⌥D / Ctrl+Alt+D show-hide hotkey unchanged and still global.

## Non-goals / anti-goals

- No changes to OpenCode Go provider code (locked): no endpoint, header,
  body, streaming, retry, test-connection, or config-format edits. The new
  hotkeys call the existing shared `generate()` entry point, which already
  routes to whichever provider is selected.
- No changes to Ollama discovery/context features just delivered.
- No configuration UI for the OOP path — it is fixed at Desktop/OOP (a
  missing folder is an error state, not a setting).
- No silent fallback, no new network destinations, no key handling changes.
- Not making the hotkeys work while a third-party app is frontmost (that is
  the rejected option B).

## Approaches (decided)

**A (chosen): always registered, gated at press time.**
Carbon `RegisterEventHotKey` (macOS) / `RegisterHotKey` (Windows) register
every shortcut once at startup. Each handler first checks the frontmost
context; if it is not IntelliJ and not Drop, the press is ignored (and
because these combos have no system-wide meaning, nothing else is disturbed).
- Simple: no process watching, no register/unregister lifecycle.
- ⌃⌥D stays exactly as it is (global show/hide).

**B (rejected): register only while the IntelliJ process is running.**
Watches for idea64/IntelliJ process; keys vanish when it quits. Rejected:
more moving parts, registration lag, and no real benefit over press-time
gating.

## Hotkey map (both platforms)

| Action | macOS | Windows |
|---|---|---|
| Read OOP + start run (combined) | ⌃⌥R | Ctrl+Alt+R |
| Copy full answer | ⌃⌥C | Ctrl+Alt+C |
| Copy Task N (N = 1…9) | ⌃⌥1 … ⌃⌥9 | Ctrl+Alt+1 … Ctrl+Alt9 |
| Copy Task 10 | ⌃⌥0 | Ctrl+Alt0 |
| Show/hide popup (existing, global) | ⌃⌥D | Ctrl+Alt+D |

Keys: R = `kVK_ANSI_R` / 0x52, C = `kVK_ANSI_C` / 0x43, digits 0x30–0x39.
Windows registers each combo on the existing native window with a distinct
hotkey id; `WndProc` dispatches by id.

## Behaviour spec

### Frontmost gate (decision A)

- **macOS:** allowed when `NSWorkspace.shared.frontmostApplication` is
  IntelliJ IDEA (bundle id `com.jetbrains.intellij` or localized name
  containing "IntelliJ"), **or** Drop itself is the active app / its panel
  is key — so the user can also re-copy from the popup. Otherwise ignore.
- **Windows:** allowed when the foreground window's process is `idea64` /
  `idea` (IntelliJ), **or** the foreground window handle is Drop's own
  `$form` (or its children). Otherwise ignore.
- The gate applies to R/C/1–0 only. ⌃⌥D / Ctrl+Alt+D has no gate (today's
  behaviour).

### Combined read+start (⌃⌥R)

1. If a run is already in progress → status "Busy – wait for the current
   answer" and return.
2. The run is headless: never auto-open the popup (status is stored; the
   user opens it manually with ⌃⌥D whenever they want to watch progress).
3. Resolve the OOP folder (`~/Desktop/OOP`, `~\Desktop\OOP`). If missing →
   status "⚠️ OOP folder not found on Desktop" and return (no request sent).
4. Collect its contents with the existing folder collection logic (nested
   folders, zips, PDFs/Word/text — unchanged; the two project folders are
   just subfolders of OOP).
5. Same guards as today's drop flow: minimum readable text, model selected
   (Ollama: Qwen present), provider chosen.
6. Run the existing pipeline unchanged: prompt construction, streaming /
   non-streaming per provider, javac compile-check + 2 repair rounds
   (macOS), clipboard copy, notification sound. Provider is simply whichever
   is active — no provider code edits.

### Copy full answer (⌃⌥C)

- Copies the last completed answer to the clipboard (same
  `copyToClipboard` / `Clipboard.SetText` path as the existing Copy button).
- No answer yet → status "No answer yet" and the clipboard is left untouched.

### Copy Task N (⌃⌥1…⌃⌥0)

- Slices `lastAnswer` on `// ===== Task N =====` headers using the existing
  section parser (the same header format the repair loop already parses).
- Section found → copy that section (from its header up to the next Task
  header) to the clipboard; status "✅ Task N copied".
- Answer empty → "No answer yet"; Task N absent → "⚠️ Task N not found in
  answer". Clipboard never cleared on failure.
- Slices the **last completed** answer, not a partially streaming one.

### Windows parity notes

- Same four actions, Ctrl+Alt combos, same gate, same OOP path.
- Windows keeps its existing pipeline differences (no javac repair loop,
  stream:false) — unchanged.
- Process check via `GetForegroundWindow` + `GetWindowThreadProcessId`;
  process name `idea64` or `idea`.

## Constraints

- OpenCode Go integration is locked and untouched (verified by review of
  every edited region before completion).
- Credentials stay in the local 0600/icacls config; hotkeys never touch or
  log keys.
- No new network calls beyond the existing provider requests.
- macOS: Swift source lives inside the `install-drop.sh` heredoc — keep
  `EOF` / `CFGEOF` / `EOF2` delimiters intact.
- Windows: PowerShell 5.1 compatible (no `??`, `Add-Member -Force` for
  optional config keys).
- Bash/compile verification may be blocked in-session; if so, the user runs
  the build/test commands.

## What's left to the builder

Exact placement of the new Carbon handler ids / Windows hotkey ids, the
IntelliJ bundle-id check implementation, and wiring the gate into the
existing `handle()` / `Start-Answer` paths so the combined hotkey reuses the
normal pipeline instead of duplicating it.
