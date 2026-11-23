# Drop for Windows - OOP fixes, ACD subject and benchmark mode (port of the macOS features)

Windows is a separate PowerShell/WinForms app (`windows/Drop.ps1`). The macOS features of `install-drop.sh` are ported behaviour-for-behaviour;
the UI-free logic lives in files next to `Drop.ps1` so it can be tested headless:

| File | Contents |
|---|---|
| `windows/Drop.ps1` | WinForms popup, tray, hotkeys, providers, the original timer-driven request state machine (OpenCode Go and Careful mode), the Benchmark window |
| `windows/DropCore.ps1` | prompt headers, deterministic fixers, javac check, HOW TO TEST (moved unchanged out of `Drop.ps1`), background-job plumbing |
| `windows/DropOop.ps1` | settings, small-context Ollama session, javac/paper fixers, semantic lint, per-task generation, the shared pipeline, OOP run entry |
| `windows/DropAcd.ps1` | answer document, notes, planner, prompts, `AcdFixers` |
| `windows/DropAcdValidate.ps1` | syntax / static / build / tests validation, tool discovery, toolchain preparation |
| `windows/DropAcdRun.ps1` | ACD pipeline (per-question, bounded repair), ACD run entry, blocking OpenCode request (ACD + benchmark only) |
| `windows/DropBench.ps1` | benchmark engine, `results.jsonl`, scoring, report, benchmark job entry |

`Install Drop.cmd` copies all of them (plus `acd-notes/` and `bench-tasks/`); on start Drop copies notes and sample tasks to `%APPDATA%\Drop\acd\notes` and
`%APPDATA%\Drop\bench\tasks` without overwriting your edits. Windows PowerShell 5.1 is the target (no `?:`, `??`, `-Parallel`); files are ASCII.

## What changed for the user
* **OOP default (all OOP runs on Ollama, hotkeys included):** ONE request for the whole paper WITHOUT thinking, through the small-context, memory-aware
  session: context sized to prompt + `num_predict` (2k..32k), model kept loaded (`keep_alive 2m`) during the run, unloaded when it passes 60 % of RAM,
  one retry after an unload on a 5xx, always unloaded when the run ends. Runs on a background runspace (the popup never blocks).
* **Careful mode** (tray -> *ACD careful mode (thinking, slower)*, shared by OOP and ACD): the original thinking request, byte-identical (verified, see below).
  If it returns nothing ("context limit reached - no answer"), Drop retries once without thinking, then writes the answer task by task.
* **OOP per-task** (tray, experimental, off by default): popup runs only; hotkeys and OpenCode Go keep the single request.
* **OOP fixers** (Ollama only): `javacFixes` (missing imports of JDK/Spring/project classes, `getType()`, `List<Long>`, primitive-vs-null, Collection->List,
  `!Math.toIntExact`, undeclared fields), `fixMappingQueryStrings`, `fixSkippedLoop`, `fixInventedWrapper`, `fixControllerDelegation`, paper-wording
  guards ("positive" -> `<= 0`), semantic lint (stubs / ApiError-as-success go back for repair; a repair that adds a placeholder is discarded), and the
  **HOW TO TEST** block (starter's real `server.port`, the paper's own "REST operations to demonstrate" calls, JSON built from the starter's records).
* **ACD subject:** OOP / ACD buttons on the popup (persisted in `%APPDATA%\Drop\settings.json`, never in `config.json`), `> Run folder` reads
  `Desktop\ACD`, per-question pipeline, notes (ranked, lower priority than the task), validation reported separately, `Copy part` field
  (`2` = Task 2, `A1` = question, `Events.tsx` = file) in the expanded pane, `Prepare ACD toolchain...` (tray; asks first; nothing installs automatically).
  Hotkeys stay OOP and ACD has none (by design). A run keeps the subject, inputs and answer slot it started with.
* **Benchmark...** (tray): task / model pickers, OOP request mode, per-task, careful; runs on a background runspace; `results.jsonl` (same schema as
  macOS: schema 1 = OOP, 2 = ACD) under `%APPDATA%\Drop\bench\`; report = Markdown (`Open report`). Reuses `bench-tasks/` unchanged.

## Differences from macOS (deliberate, stated, not hidden)
1. **No sandbox-exec.** macOS runs generated code with no network and writes only to a temp folder. Windows has no equivalent, so code that EXECUTES model
   output is only run where a sandbox exists: Node's permission model (Node 22+; blocks file writes outside the temp folder and child processes, does
   NOT block the network before Node 25). Without it the benchmark's `node-eval` is `not_run` and the starter's `npm test` is `unavailable` - never a pass.
   `node --check`, TypeScript syntactic diagnostics, `tsc --noEmit` and `vite build` do not execute model code and run plainly.
2. **Non-streaming requests** (`stream:false`), consistent with the existing Windows code: status shows the request label and elapsed seconds, not a
   live character count, and a connection lost mid-answer loses the partial answer.
3. **Benchmark report:** ranking, breakdown inputs, per-task, ACD evidence, failures, conditions. The macOS report's strengths/weaknesses table, the
   "what the tests can and cannot verify" tables and HTML output are not ported - run the macOS report builder over the same `results.jsonl`.
4. **Stop** in the Benchmark window takes effect between runs (a request in flight cannot be cancelled).
5. **OpenCode Go in ACD/benchmark** uses a new blocking request function (same request shape as `Send-Prompt`, 3 attempts for 408/429/5xx, no fallback);
   the app's own OpenCode code in `Drop.ps1` is unchanged. This function could only be tested structurally (no API key here).
6. Windows docx text uses `<w:br/>` handling for ACD papers (`Get-AcdDocxText`), otherwise multiple-choice options glue together; the OOP path keeps `Get-DocxText`.

## Verification (see tests/windows/README.md)
Run on a Mac under PowerShell 7.7 (unpacked tarball) against the scripted mock Ollama, real javac/Java/node/tsc/vite: 192 checks + syntax parse
(52 OOP incl. MODERATE 29/36 -> 36/36 with the real Java tests, 12 session, 102 ACD, 4 job, 22 benchmark e2e) and the 5-scenario baseline harness:
the original Drop.ps1 and the ported one in **Careful mode** produce identical answers/status/clipboard/requests (the only diff is javac's temp-path
prefix in repair prompts, stripped on non-Windows hosts by a portability fix). **Not verified anywhere yet:** WinForms (toggle, Run folder, Copy part,
tray items, Benchmark window), Windows PowerShell 5.1 itself, a real Windows javac/node/Ollama, Node-permission sandboxing on Windows, OpenCode Go in ACD/bench.
