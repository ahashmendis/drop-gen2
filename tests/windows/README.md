# Windows port tests

Everything here runs on Windows PowerShell 5.1, PowerShell 7 (Windows) and PowerShell 7 on macOS/Linux, against the scripted mock Ollama
(`../baseline/mock_ollama.py`; it also answers `stream:false` for the Windows requests). Nothing touches the real Drop settings, clipboard or models.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run-all.ps1      # on Windows
    pwsh -NoProfile -File tests/windows/run-all.ps1                                     # on a Mac

Needs python3 (set `$env:PYTHON_EXE` if it is `python`), JDK 17+, Spring/Jackson jars in `~/.m2` (same as the macOS harness), node, and
`$env:ACD_TEST_NODE_MODULES` = a node_modules with react/vite/typescript for the build cases (skipped without it).

| Script | Covers |
|---|---|
| `core/test-oop.ps1` | planner, per-task, javac fixers, paper fixers, lint, wrapper fix, HOW TO TEST, MODERATE 29/36 -> 36/36 (port of the OOP cases of `tests/acd/driver_unit.swift`, same fixtures) |
| `core/test-session.ps1` | no-thinking single request, ctx sizing, unload at memory pressure, one 5xx retry, per-task run, oversized prompt |
| `core/test-acd.ps1` | answer parser, part copy, notes, planner, objective parsing, AcdFixers, validators (real tsc/vite), sandbox, repair pipeline, toolchain/notes/task-copy safety |
| `core/test-job.ps1` | the background-runspace plumbing the popup's timer uses (OOP and ACD through it) |
| `bench/run-bench-e2e.ps1` | benchmark: ref / mutant / broken mock models x 3 OOP tasks + ACD mock ICT, real Java tests, results.jsonl, report |
| `baseline/` | characterization of the request pipeline (below) |

## Baseline harness (the "original request path is untouched" proof)
`baseline/harness.ps1` extracts functions, prompt headers and the generation timer's tick block from a Drop.ps1 by AST, stubs the UI/clipboard, calls
`Start-Answer` and ticks the timer until the run ends. `baseline/run-baseline.ps1 -Script <Drop.ps1> -Label <name> [-Careful]` runs the 5 scenarios
(pass, repair, truncated, never_fixed, http500) and writes answer/status/clipboard + every request to `baseline/out/<label>/`.

    git show <original-rev>:windows/Drop.ps1 > orig/Drop.ps1
    pwsh -File baseline/run-baseline.ps1 -Script orig/Drop.ps1 -Label win_orig
    pwsh -File baseline/run-baseline.ps1 -Script ../../windows/Drop.ps1 -Label win_new_careful -Careful
    diff -r baseline/out/win_orig baseline/out/win_new_careful      # only the javac temp-path prefix in repair prompts differs on non-Windows hosts

Without `-Careful` the ported build runs its new default (one no-thinking request through the session, via the background job): `win_new_default`.
`out/win_orig` is the recorded baseline of the original script (git HEAD 5daf8b2).
