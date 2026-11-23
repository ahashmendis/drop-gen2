# Drop regression harnesses (macOS)

Both scripts compile the Swift source embedded in `install-drop.sh` against a **scripted mock Ollama**
(`baseline/mock_ollama.py`); nothing touches the real Drop app, config, clipboard history or Ollama.

* `baseline/run-baseline.sh <installer> <label>` — runs the normal-generation pipeline (`AppDelegate.handle`) through
  5 scenarios (compiles first time, repair round, truncated answer, never fixed, server error) and writes the final
  answer, status, clipboard and **every prompt sent** to `baseline/out/<label>/`. Compare two builds with
  `diff -r baseline/out/A baseline/out/B`.
* `bench/run-bench-e2e.sh <installer>` — runs benchmark mode over the 3 sample tasks with three mock models
  (reference / subtly wrong / compile-error-then-fixed) and keeps the results + report in `bench/out/last/`.
* Needs: swiftc, JDK 17+, Spring/Jackson jars in `~/.m2`, python3.

## ACD harnesses
* `integrity/check.sh <installer>` — OpenCode Go provider, Ollama provider, config struct, error classification and the four OOP prompt
  headers must be byte-identical to the original (hashes in `integrity/hashes.txt`).
* `acd/run-acd.sh <installer>` — popup logic: toggle default/persistence/isolation, ACD run + notes + repair + best-answer retention, toggling during a
  run, OOP path independence (hotkey path), copy paths, toolchain safety, notes copy. Mock Ollama; build cases need a `node_modules` (`ACD_TEST_NODE_MODULES`).
* `acd/run-unit.sh <installer>` — parser/extraction byte-exactness (HTML, CSS, SCSS, JS, JSX, TS, TSX, JSON), path safety, static checks,
  notes ranking, validators (real tsc/vite), sandbox, repair pipeline, benchmark check types.
* `bench/run-real.sh <installer> <model> [careful]` — runs the ACD mock task through the **real** pipeline against your real Ollama (uses the model, unloads it when done);
  prints per-question progress, timing and the graded result. Use it to check prompt/pipeline changes on your own hardware.

Note on `baseline/`: comparing a current build with `baseline_orig` (the original installer's output) now differs in exactly one place **on purpose** — the HOW TO TEST block
(real port from the starter, real JSON bodies, the paper's own example calls). Answers' code, statuses, clipboard and every prompt sent stay identical.

Baseline note (OOP default changed): the OOP default on Ollama is now a no-thinking single request, so `baseline/run-baseline.sh` without options produces the new default.
To prove the ORIGINAL thinking path is untouched, run it with Careful mode on: `DROP_CAREFUL=1 baseline/run-baseline.sh <installer> <label>` and diff against `baseline_orig`
(prompts, request options, statuses and answer code are identical; only the HOW TO TEST block differs, on purpose).
