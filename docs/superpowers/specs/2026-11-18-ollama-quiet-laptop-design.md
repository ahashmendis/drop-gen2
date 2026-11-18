# Ollama quiet-laptop design

**Date:** 2026-11-18 (rev 2 — incorporates the external expert brief of the same date)
**Status:** awaiting approval
**Scope:** laptop-friendly Ollama lifecycle + resource management across macOS and
Windows, on-demand start, login-start disabled, OpenCode Go as default provider.
OpenCode Go integration stays byte-locked.

## Problem

1. Every Ollama answer requests `keep_alive: "30m"` — model + runner resident
   30 min after each run (memory pressure, heat).
2. The runner executes at normal priority — during generation the laptop
   freezes and fans spin.
3. Ollama auto-starts at login (macOS: launchd job `com.ollama.ollama` via the
   app's SMAppService; Windows: `HKCU\...\Run\Ollama`) and idles all day.
4. Auto context growth can request `num_ctx = 65536` on any machine — on an
   8 GB Mac that alone can exhaust unified memory. (`needed = prompt/3 + 8000`,
   doubles from 8192 to a fixed 65536 cap, both platforms.)
5. Fresh installs default to Ollama, not OpenCode Go.

## Goals

- Ollama never starts at login; starts on demand only.
- Models unload immediately after every generation (`keep_alive: 0`).
- Ollama yields to foreground apps; context and concurrency are bounded by
  hardware; the laptop stays usable during inference.
- Dynamic Qwen discovery with useful model info; no hardcoded model; no
  automatic downloads.
- Server once started stays running; no force-kills; no duplicate servers;
  a server that was already running is left alone.
- Fresh installs default to OpenCode Go; existing configs never rewritten.
- Never crash Drop; never silently fall back to OpenCode Go.
- OpenCode Go request/auth/streaming/retry/config-format/key-storage: zero
  edits (diff-gate verified before finishing).

## Non-goals

- Auto-quitting Ollama when idle or on provider switch (idle `serve` is
  light; restart-per-switch is worse; `keep_alive: 0` already removes the
  heavy part).
- Rewriting an existing config.json (existing installs keep their remembered
  provider until the user clicks the switch button once).
- `OLLAMA_MAX_QUEUE` edits — Ollama's default queue is already bounded.
- New settings panels, new dependencies, model downloads, firewall changes,
  LAN exposure, any change to OpenCode Go.

## Decisions

### 1. `keep_alive: 0` on every `/api/generate` (both platforms, both mac sites)

Explicit per-request API-level unload — not the server default. Cost accepted:
~1–3 s cold load next run. No unload commands are ever sent separately (never
mid-generation); Ollama owns its own unloading. The old "moved verbatim
(… keep_alive …)" comment is updated: this is now intentional.

### 2. Hardware-aware context ceiling (auto path only)

Existing logic kept: hardware preset/manual value is a **floor**; prompt-size
growth doubles from 8192; global hard cap 65536. **New:** the auto path is
clamped to a hardware ceiling:

| RAM | preset floor (existing) | auto ceiling (new) |
|---|---|---|
| < 16 GB | 8192 | **16384** |
| 16–32 GB | 16384 | **32768** |
| ≥ 32 GB | 16384 / 32768 | **65536** |

- **Prompt-fit bypass:** if the prompt's own token estimate exceeds the
  ceiling, grow to fit the prompt anyway (up to the 65536 hard cap) — a
  truncated prompt silently corrupts the answer, which is worse than a higher
  peak; the run still unloads immediately after.
- **Manual override is exempt:** an explicit Settings → Qwen ctx value is the
  user's consent and behaves exactly as today (floor, cap 65536).
- If Ollama still rejects the prompt (context-length error), surface a status
  hint pointing at Settings → Qwen ctx instead of a bare failure.
- Applied at all generate sites (mac ×2, win ×1).

### 3. On-demand start — one helper, HTTP readiness probe

`prepareOllama()` (mac) / `Prepare-Ollama` (win), called first by every
Ollama request site: model discovery (startup, provider switch, dropdown
show) and `/api/generate`. Never called on OpenCode paths (preserves the
"no localhost traffic while OpenCode is selected" guarantee).

Procedure:
1. Probe readiness with a real API call: `GET /api/tags` (not a bare port
   check).
2. If it answers → continue.
3. If not → start Ollama, set resource env (Decision 4), then poll `/api/tags`:
   first attempt after ~300 ms, then every ~500 ms, bounded by the existing
   `network.connect_timeout` (20 s — inside the expert's 15–30 s window; no
   new setting).
4. Start commands — the official app owns the server lifecycle:
   - macOS: `open -a Ollama` (works with the login agent disabled; never
     spawn a second `ollama serve`).
   - Windows: launch the installed Ollama **application** (resolve: Start
     Menu shortcut target → standard per-user install locations → PATH);
     never spawn a bare duplicate `serve`.
5. If still not ready → report via the existing connection-error
   classification ("endpoint unreachable / connection refused"), no new error
   types, no provider fallback.
6. If Ollama was already running (started by the user earlier), do nothing
   extra beyond the once-per-session demotion — no restart, no interference.

### 4. Resource env limits (best-effort, only on start paths)

- `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1` — set only when Drop
  starts Ollama:
  - Windows: passed as environment to the launched app (child inherits).
  - macOS: `launchctl setenv` for both immediately before `open -a Ollama`
    (best-effort; propagation to the app's `serve` is verified in the live
    checklist — if it does not propagate, the step is dropped and ledgered;
    `keep_alive: 0` + Drop's single-generation guard already bound the load).
- Never touches a server that is already running (env is start-time only).
- Drop's existing `Running` guard remains the single-generation gate; a second
  request while busy gets the existing "Busy — wait" state (never concurrent
  inference).

### 5. Priority demotion — secondary, once, best-effort

- Applied **once per Drop session** (flag), not per request: when Drop starts
  Ollama, or on first touch if it was already running.
- macOS: `renice 15` on exact process-name matches — `pgrep -x ollama`
  (the `ollama` binary serves, runs, and is the runner's comm name) plus
  `pgrep -x Ollama` (the app). Children inherit the nice value, so the
  per-run runner is covered.
- Windows: `PriorityClass = BelowNormal` on `ollama*` processes; the runner
  inherits from the server.
- Any failure is swallowed — Ollama keeps working; priority is explicitly
  *not* the primary lever (keep_alive 0, context ceilings, and env limits
  are). Readback verification happens in tests, not in a runtime loop; no
  repeated renicing.

### 6. Disable login auto-start (installer, best-effort, targeted)

- **macOS (`install-drop.sh`):** `launchctl bootout gui/$UID/com.ollama.ollama`
  then `launchctl disable gui/$UID/com.ollama.ollama` — non-fatal if absent.
  Nothing else: no uninstall, no model deletion, no app-bundle edits, no
  SMAppService internals.
  *Expert caution honored:* this is verified across the full matrix —
  reboot, manual Ollama.app open, Drop-launched start, Ollama update,
  reinstall, login/logout — before being called done. Known risk: the app may
  re-register on manual open. If verification shows that, the fallback is a
  documented System Settings → Login Items toggle (and only then consider a
  re-disable on Drop startup) — decided from evidence, not guessed now.
- **Windows (`Install Drop.cmd`):** remove only the `Ollama` value from
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (best-effort; no
  admin-required HKLM surgery, no other startup entries touched). Manual
  launch still works.

### 7. Dynamic Qwen discovery (mostly existing — extended)

Already in place and kept: `GET /api/tags`, metadata-first family detection
(`details.family`/`details.families`, name fallback), no hardcoded model,
local persistence of selection, graceful fallback when the saved model
disappears, clear "no Qwen models — ollama pull …" message, never auto-
download, refresh when the model dropdown is shown, discovery at startup and
on provider switch (verified: win `Update-OllamaModels` at startup/switch/
show; mac `loadModels()` on show + startup).
**Added:** dropdown labels include parameter size and quantization when the
tags metadata provides them (e.g. `qwen3.5:4b · 4.4B · Q4_K_M`) — display
only, both platforms. No new refresh button (show-to-refresh already exists).

### 8. Default provider = OpenCode Go (fresh configs only)

- mac: installer default `config.json` `"provider": "ollama"` →
  `"opencode_go"`; in-code default `var provider` likewise.
- win: `Read-DropConfig` defaults `provider = 'ollama'` → `'opencode_go'`.
- README example updated. Existing configs untouched — on an existing install
  the user clicks ☁️ OpenCode once; `remember_provider` keeps it.
- Fresh installs with no key yet show the existing "No OpenCode API key —
  open Settings" guidance. Silent fallback stays off.

### 9. UX (status line only, no redesign)

Existing status line carries: "Starting Ollama…", "Ollama ready", the existing
connection error on start failure, existing Busy/running states, existing
"no Qwen models" message, and the new context-length hint (Decision 2).
No new panels, buttons, or settings beyond what exists.

## Constraints honored

- OpenCode Go: zero edits (post-change diff grep gate for
  `opencode|ocKey|x-opencode|Bearer|api_key|chat/completions` must be empty).
- No config overwrites on reinstall; keys never touched; local file storage
  only; no Keychain/Credential Manager; no proxies; no firewall changes;
  127.0.0.1 only; no telemetry; no auto-downloads.
- PS 5.1-safe; Swift stays inside the heredoc; no new dependencies; smallest
  reliable change set; existing Drop functionality preserved.

## Verification

**Automated (RED first, structural/extraction style):**
- `keep_alive` is `0`; `30m` gone (all generate sites).
- Context ceiling + prompt-fit bypass + manual-exemption logic present at all
  three generate sites; ceiling values match the table.
- `prepareOllama`/`Prepare-Ollama` exists and wraps every Ollama request
  site; readiness probe is `/api/tags` (not a port check); OpenCode paths
  never call it.
- Login-disable commands present in installers; env limits set on start
  paths; default provider is `opencode_go` at all three default sites;
  dropdown metadata display present.
- OpenCode diff gate empty; full suite green (typecheck, task-section,
  win/mac structural + invariant suites, new pins).

**User live checklist (both platforms where applicable):**
1. Reboot → Ollama not running at login (expert matrix: also after manual
   app open, Drop-launched start, Ollama update, reinstall, login/logout).
2. Provider switch to Ollama (or first run) → "Starting Ollama…" → ready
   within ~20 s; a second run starts instantly.
3. After each answer → `ollama runner` gone (`ps`/Task Manager); server
   still answers `/api/tags`.
4. During a run → laptop stays usable; verify demoted priority took effect
   (nice/BelowNormal readback) including the runner.
5. Context: an 8 GB-class machine never requests > 16384 automatically
   (large-paper prompt-fit bypass documented if it triggers); manual Qwen ctx
   override still honored; context-length error shows the Settings hint.
6. Discovery: dropdown lists all installed Qwen models with size/quant where
   metadata exists; missing saved model falls back gracefully; no auto
   downloads; refresh-on-show picks up newly installed models.
7. Env: (mac, if `launchctl setenv` propagates) runner sees
   `OLLAMA_NUM_PARALLEL`/`OLLAMA_MAX_LOADED_MODELS`; otherwise the step is
   dropped and ledgered.
8. OpenCode Test Connection green; request headers/body/streaming byte-
   unchanged; existing config's provider unchanged until switch button
   pressed once.

**Final report** follows the expert brief's deliverable list: what changed,
files, per-platform lifecycle, discovery behavior, protections, env vars,
tests + results, limitations, explicit OpenCode-not-modified confirmation.
