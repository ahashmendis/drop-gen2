# Drop — ACD subject (Advanced Client-Side Development)

Drop has two subjects. The **OOP / ACD toggle** on the popup (under the drop zone) chooses which one the popup uses. The choice is
remembered across restarts under its own key (`subject`); it never touches the provider, model or `config.json`. OOP is the default.

| | OOP | ACD |
|---|---|---|
| Folder (▶ Run folder, or drop files on the popup) | `Desktop/OOP` | `Desktop/ACD` |
| Prompt and pipeline | existing Java pipeline (javac + repair) | ACD prompt + web validation + safe repair |
| Hotkeys (⌃⌥R/C/D/1…0) | unchanged, always OOP | none (by design) |
| Answer / copy | `Copy`, hotkeys | `Copy`, **Copy part** (expanded pane) |

Switching the toggle never interrupts a run; the run keeps the subject, inputs and answer slot it started with. ⌃⌥C and ⌃⌥1…0 keep
copying the OOP answer whichever subject is selected.

## How an ACD answer is produced (built for a small model on an 8 GB Mac)
Measured on `qwen3.5:4b`: one request for the whole paper with thinking on spends its entire token budget thinking (empty answer: "context limit
reached – no answer"), and the model's memory grows past RAM. So Drop **plans the paper into questions and sends one small request each**:
* **Objective (multiple choice / true-false):** one question per request, no thinking, no notes, temperature 0, ≤ 24 tokens, 2–4k context. Measured:
  40/40 on the mock paper in ~70 s (batches of 5/10 or adding notes scored lower).
* **Free-form (short answer / code):** one question per request with the exam instructions, the starter project (when there is one) and a *small, targeted* set of
  lecture-note excerpts (≤ ~1.5k chars, ranked against that question). Token budget scales with the marks. Thinking is **off** by default.
* **Careful mode** (tray menu → *ACD careful mode*): lets the model think before free-form answers. Much slower (minutes per question on this machine); if thinking
  eats the budget the question is retried without thinking, so you never get an empty answer.
* **Memory:** the model stays loaded during a run but Drop unloads it when its size passes 60 % of RAM, retries once after an unload on a server error, and
  always unloads it when the run ends (quiet laptop).
* Markers (`Task`, `Q`) are added by Drop, not by the model, so the format never depends on a small model following it. Papers with no recognisable questions
  fall back to one request for the whole task.

## Input (`Desktop/ACD`)
A paper/task (`.docx`, `.pdf`, `.txt`, `.md`) plus an optional starter project (folder or zip: Vite/React/TS or plain HTML/CSS/JS).
Lecture notes: `acd-notes/` beside the installer is copied to `~/Library/Application Support/Drop/acd/notes/` (never overwriting your
edits) and `Desktop/ACD/notes/` is also read. Notes (`.md .txt .docx .pdf .pptx`) are ranked against each question; only relevant excerpts go in, labelled
**lower priority than the question**. The question text is never truncated — if one question alone exceeds the context limit the run reports it.
Do not put answer keys in the notes folder.

## Answer format and copying
`// ===== Task N =====` groups (lettered sections A→1, B→2 …), `// ===== Q A1 =====` per question with the paper's own id,
`// ===== FILE: path =====` per file. **Copy part** takes `2` (Task 2), `A1` (a question) or `Events.tsx` (a file, clean code only).

## Validation — four separate results
* **Syntax** — it parses (node --check, TypeScript syntactic diagnostics, JSON).
* **Static** — rule-based inspection (HTML structure/accessibility, Bootstrap structure, CSS balance, missing hook/router imports). Warnings do not fail.
* **Build** — `tsc --noEmit` + `vite build` on the **starter's own configuration** (needs dependencies).
* **Tests** — the starter's own `test` script (only if it has one).
The status line always says what was not verified; a syntax/static pass is never reported as functional correctness. Generated code runs
under `sandbox-exec` (no network, writes only to a temp folder); the answer's `package.json`/configs are ignored when the starter has them.
Dependencies: the starter's own `node_modules`, or the toolchain folder created by tray menu → **Prepare ACD toolchain…** (explicit, asks first,
runs `npm ci`/`npm install`; nothing is ever installed automatically). Without dependencies, Build/Tests show `n/a`, never a pass.

## Repair (≤ 3 rounds)
Each repair prompt contains the original task requirements, the current files and the exact validation errors; the model returns only
changed files, which are merged over the existing answer. The best candidate is kept: a repair that does not improve is discarded.

## Benchmark
Tray menu → **Benchmark…**. ACD tasks (`subject: "acd"` in `task.json`) report four evidence types separately: auto-graded objective
answers (A/B/E sections against the key), executed checks (node/tsc), static pattern checks (explicitly *not tests*) and manual rubric marks
(`results/manual.json`: `{"ollama:model | acd-mock-ict": {"requirements": {"D1.a": 3}}}`; never added automatically). Rankings are per subject.
