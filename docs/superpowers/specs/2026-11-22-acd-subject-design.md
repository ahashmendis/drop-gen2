# ACD subject (second subject workflow) — approved design

Status: approved in conversation 2026-11-22. macOS only. Not committed.

## Scope (agreed)
Visible OOP / ACD toggle on the popup; `Desktop/ACD` input; ACD prompt using lecture notes as lower-priority context;
normal visible ACD generation; web validation; ACD in the benchmark. **Not built, by agreement:** ACD global hotkeys and hidden/headless
ACD runs. Existing OOP hotkeys, headless run, prompts, pipeline, fixers, javac repair, providers, config stay byte-identical
(verified by `tests/baseline` and `tests/integrity`).

## Architecture
* `Subject {oop, acd}` in UserDefaults key `subject` (default oop). Never touches config.json / provider / model keys.
* OOP path = `DropPipeline` untouched. ACD path = `AcdPipeline` (no javac, no Java fixers). Shared: ProviderAdapter, model discovery.
* Popup entry points (drop, file picker, Run folder button) dispatch by subject. The hotkey path still calls `handle()` (OOP) directly.
* A run captures subject, inputs, prompt set and answer slot at start; toggling during a run changes none of them.
  Slots: `lastAnswer` (OOP, what the hotkeys copy) and `lastAnswerACD`.

## ACD answer format (parser-tested)
`// ===== Task N =====` groups (lettered sections A→1, B→2, … in paper order) · `// ===== Q A1 =====` one per question with the paper's
own identifier · `// ===== FILE: path =====` complete files. Markers are separators and are never written into extracted code;
only a fence pair wrapping a whole file is stripped. Copy field: `2` → Task 2, `A1` → question, `Events.tsx` → that file (clean code).

## Notes (context, lower priority than the task)
Sources: `~/Library/Application Support/Drop/acd/notes/` (installer copies `acd-notes/` beside it, cp -n) and `Desktop/ACD/notes/`.
`.md/.txt/.docx/.pdf/.pptx`. Chunked by heading/slide, ranked by rare-term overlap with the task plus detected technology terms;
`00-conventions.md` always first. Budget ≤ ~3k tokens and shrinks first; the task text is never truncated or dropped — if the task alone
exceeds the context ceiling the run stops with the existing message. Used chunk names are recorded.

## Validation (reported separately; never merged)
syntax (node --check, TypeScript syntactic diagnostics, JSON) · static (HTML structure/a11y, Bootstrap structure, CSS balance, missing hook/router imports)
· build (tsc --noEmit, vite build; needs starter project + deps) · tests (project `test` script). Each is pass / fail / not_run / unavailable.
Summary always says what was NOT verified; a syntax or static pass is never labelled functional correctness. Generated code runs under
`sandbox-exec` (no network, writes only to a temp dir); package.json/configs come from the starter, never from the answer; no automatic npm install.
Optional user-clicked **Prepare ACD toolchain…** menu item runs `npm ci` in `~/Library/Application Support/Drop/acd/toolchain` after a confirmation.

## Repair (≤3 rounds)
Original task requirements are in every repair prompt, plus current files and validation errors; model returns only changed files;
merge keeps everything else. The best candidate (fewest failures) is retained; if repair fails or makes things worse the best answer is kept.

## Benchmark
Task `subject: "acd"`. Kinds: `objective-key` (A/B auto-graded), executable tests (node), static checks, manual rubric. Results store
automated results, static checks and manual items in separate fields; the report ranks per subject and keeps the tables apart.
