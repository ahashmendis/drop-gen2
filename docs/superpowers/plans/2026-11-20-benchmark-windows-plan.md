# Windows port of benchmark mode — plan (not started; macOS is verified first)

Windows is a separate PowerShell app (`windows/Drop.ps1`); its pipeline is `Start-Answer` → `Start-DropOllamaPipeline` →
`Complete-DropPhase3` / `Start-DropRepairRound`. Same approach as macOS:

1. **Baseline first**: a PowerShell harness + the same mock Ollama (`tests/baseline/mock_ollama.py`) that runs the five
   scenarios against the current `Drop.ps1` and records answers/prompts. Needs a Windows machine (not available here).
2. **Extract** the Start-Answer pipeline body into one function taking hooks (generate / compile / status), call it from
   the UI path unchanged, re-run the harness: outputs must be identical.
3. **Reuse unchanged**: `bench-tasks/` (task.json, tests, support), `results.jsonl` schema, the report format. The report
   builder is Swift today; on Windows either port ~200 lines to PowerShell or run the report from a Mac over the same
   `results.jsonl` (the file is the contract).
4. Windows-specific: javac/java discovery (`Find-DropJavac` exists), classpath from `%USERPROFILE%\.m2`, process timeouts,
   a WinForms Benchmark window opened from the tray menu, `%APPDATA%\Drop\bench\` storage.
5. Constraints carried over: no changes to OpenCode Go code, no silent fallback, no new dependencies.
