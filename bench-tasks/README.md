# Drop benchmark tasks

Each folder is one fixed task. Drop's **Benchmark…** window (tray menu → Benchmark…) lists the folders it finds in
`~/Library/Application Support/Drop/bench/tasks/`. `install-drop.sh` copies a `bench-tasks` folder that sits next to it
into that location (`cp -n`: your own edits are never overwritten). To add a task, add a folder — the engine does not change.

```
my-task/
  task.json        id, title, requirements (with marks and kind), test runner settings
  inputs/          the paper (.docx/.pdf/.txt) and the starter project (.zip): what every model is given
  tests/           Java checks run against the generated solution (optional but needed for a "verified" result)
  reference/       optional: a staff solution used only to validate the tests (never shown to a model)
_support/          shared test helpers (Check = tiny runner, MiniMvc = in-process Spring MVC for controllers/handlers)
```

## Requirement kinds (task.json → `requirements[].kind`)
| kind | meaning | scored? |
|---|---|---|
| `automated` | `tests: ["S-HP-01", …]` (Java) or an executed `check` (ACD) — verified only if it ran **and** passed | yes (coverage + functional) |
| `objective` | ACD multiple-choice / true-false graded against `answer` | yes (counts as an automated result) |
| `static` | ACD pattern check on the answer text — **not a test** | reported separately, never scored as functional |
| `manual` | needs a person (e.g. "controller stays thin") | never counted as passed; shown as unassessed |
| `untestable` | source material missing or the rule is ambiguous; `note` says why | never counted; listed in the report |

When a paper arrives or an ambiguity is settled, change the requirement's `kind`, add its tests under `tests/`, done.

## Test conventions
* Test classes call `Check.test("ID title", () -> …)`; the ID (first word) is what `task.json` links to.
* Expected values must come from the paper, never from a solution. Tests build their own state (they do not rely on the
  solution's repository seed) except in tests that check the seed itself.
* Validate new tests with `_support/run-tests.sh <task-dir> <starter-dir> <solution-dir> <MainClass>` against `reference/`
  and against deliberately wrong solutions (mutants): the sample tasks' tests catch all 30 mutants tried.

## Manual ratings (optional)
`~/Library/Application Support/Drop/bench/results/manual.json`:
```json
{ "ollama:qwen3:4b | simple-parking": { "quality": 4 } }
```
`quality` is 0–5 and fills the 5 manual code-quality points; without it those points are 0 and flagged "unassessed".

## Sample tasks
`simple-parking`, `moderate-dispatch`, `extreme-scheduler` — practice papers (5COSC019W student release), tests derived from
their formulas, worked examples and the six functional checks of each paper. Ambiguities the papers leave open are recorded
as `untestable` requirements instead of being guessed.

## ACD tasks
`subject: "acd"` in `task.json`; the paper is `inputs/*.docx` (optionally a starter zip). Each question gets a requirement:
`kind: objective` + `answer`, `automated` + `check` (`node-eval` / `ts-compile`), `static` + `check` (`regex-all`), or `manual` + `rubric`.
`acd-mock-ict` is built from the mock paper and its answer document (key cross-checked against the document; 100 marks).
Manual rubric marks go in `results/manual.json` as `{"ollama:model | acd-mock-ict": {"requirements": {"D1.a": 3}}}`.
