# Drop Benchmark Mode — Design

Status: approved in conversation (approach 1, macOS first); macOS implemented and verified. Not committed.

## Intent
Drop stays an everyday code-generation tool. Benchmark mode is an **additional**
capability that runs the *real* Drop pipeline (prompts, Ollama fixers, javac
compile + repair) over fixed tasks and several models, records the results, and
ranks the models. Goal: pick the model that produces the simplest complete,
correct Java solution.

## Goals
- Visible benchmark runs with progress; results persisted.
- Reusable fixed task collection (user-supplied, any material).
- Identical inputs and conditions for every model; reproducible records.
- Transparent scoring; correctness outweighs speed and length.
- Ranked comparison report.

## Non-goals / anti-goals
- No change to popup, hotkeys, headless run, clipboard/task copy, file
  extraction, existing prompts, OpenCode Go integration, config format.
- No silent provider fallback; no files sent to a provider that was not chosen.
- No new dependencies (Swift + AppKit + the JDK Drop already uses).
- Benchmark never writes `lastAnswer`, the clipboard, `config.json`, or the
  saved popup model/provider.

## Approach (chosen)
Extract the body of `AppDelegate.handle()` (generate → fixers → javac →
repair loop → finalize) into `DropPipeline`, which takes injected closures
(`generate`, `compile`, `status`, `phase hooks`) and returns a `PipelineResult`
(final answer, compiled flag, repair rounds, generation ms, compile ms, error
text). `handle()` calls it with the UI closures and behaves identically. The
benchmark calls it with headless closures. Rejected: a parallel copy of the loop
(drifts from the real pipeline) and an external script (would not test Drop).

Benchmark generation uses a **config copy** (`DropConfig` is a struct) and its
own provider instance, so it cannot mutate the live app state. Failures are
recorded, never rerouted to another provider.

## Task format (`~/Library/Application Support/Drop/bench/tasks/<id>/`)
- `paper.*` / `starter.zip` (or a folder): same inputs the normal flow reads
- `task.json`: id, title, requirements `[ {id, text} ]`
- `tests/`: Java checks; each test declares the requirement ids it verifies

Tasks are copied/referenced read-only; sample tasks in `SAMPLE/` are never
modified. Drafted tests for them live in `bench-tasks/` in the repo.

## Results (`.../bench/results/results.jsonl`, append-only)
One JSON line per (task, model) run: run id, provider, model name + digest/
version (Ollama `/api/show`/tags digest), task id + input hash, prompt-header
hash, config snapshot (ctx, num_predict, keep_alive), start/end timestamps,
generation ms, compile ms, repair rounds, compile status, per-test results,
requirement coverage, final status, error text, answer file path.

## Scoring (100 points, shown per component)
| Component | Pts | Rule |
|---|---|---|
| Functional correctness | 40 | passed/total tests. **Tests not run → 0 and flagged "not measured".** |
| Requirement coverage | 20 | requirements whose linked tests all pass / total |
| Compilation | 15 | 15 first try; −3 per repair round (min 3); 0 if never compiles |
| Code quality | 15 | automated simplicity checks (extra types beyond the task, long methods, unused code), report lists each deduction |
| Efficiency | 10 | speed rank scaled by the functional fraction, so speed alone cannot score |
Code length is not scored directly; over-engineering shows only via quality.
Ranking is correctness-first (as built): models are ordered by functional + coverage points (60); Overall, then speed,
only break ties — so speed and quality can never lift a less correct model above a more correct one.
Requirement kinds: automated / manual / untestable (missing source or ambiguous) — only automated can be "verified".
Compiling alone caps a run at 15 + quality + 0 efficiency.

## Report
Markdown (and HTML) from `results.jsonl`: overall ranking, per-component scores,
compile and test success rates, average generation/compile time, repairs,
strengths/weaknesses per model, with the formulas above stated in the report.

## Build sequence
1. Baseline harness (mock Ollama + scripted responses) records current behavior.
2. Extract pipeline; rerun harness; outputs must be byte-identical.
3. Benchmark window, task/model pickers, recording, tests, report.
4. Regression + OpenCode integrity check. 5. Windows plan after macOS verified.
