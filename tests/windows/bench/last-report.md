# Drop model benchmark report (Windows)

Generated 2026-11-23T16:59:03.302Z. Source: results.jsonl - latest run per model and task. All models received identical task files and the same Drop pipeline.

## Scoring methodology

| Component | Points | How it is computed |
|---|---|---|
| Functional correctness | 40 | passed tests / declared tests (0 and flagged when the tests did not run - never a pass) |
| Requirement coverage | 20 | marks of AUTOMATED requirements whose linked tests all passed / automated marks |
| Compilation (ACD: validity) | 15 | 15 first try, -3 per repair round (min 3), 0 if never compiles; ACD: 15 x answered / questions, halved when generated code fails validation |
| Code quality | 15 | 10 automated (deductions listed per run) + 5 manual rating from results/manual.json (0 if unassessed) |
| Efficiency | 10 | 10 x speed x functional fraction (speed alone scores nothing) |

Ranking is correctness-first: models are ordered by Correctness (functional + coverage, 60 points); only equal correctness is ordered by Overall, then speed. Manual and untestable requirements and static pattern checks are never counted as passed.

## OOP (Java)

### Overall ranking

| # | Model | Correctness /60 | Overall /100 | Functional tests | Paper marks verified | Compile success | Avg generation s | Avg repairs |
|---|---|---|---|---|---|---|---|---|
| 1 | qwen-ref:1b | 60.0 / 60 | 94.1 | 117/117 (100%) | 99% | 100% | 0.0 | 0.0 |
| 2 | qwen-broken:1b | 60.0 / 60 | 86.9 | 117/117 (100%) | 99% | 100% | 0.0 | 1.0 |
| 3 | qwen-mutant:1b | 55.5 / 60 | 90.0 | 112/117 (96%) | 86% | 100% | 0.0 | 0.0 |

### Per-task results

| Task | Model | Score | Compilation | Tests passed | Gen s | Note |
|---|---|---|---|---|---|---|
| extreme-scheduler | qwen-ref:1b | 94.6 | compiled | 47/47 | 0.0 |  |
| extreme-scheduler | qwen-broken:1b | 86.6 | compiled (1 repair) | 47/47 | 0.0 |  |
| extreme-scheduler | qwen-mutant:1b | 92.3 | compiled | 46/47 | 0.0 |  |
| moderate-dispatch | qwen-ref:1b | 94.3 | compiled | 36/36 | 0.0 |  |
| moderate-dispatch | qwen-broken:1b | 86.8 | compiled (1 repair) | 36/36 | 0.0 |  |
| moderate-dispatch | qwen-mutant:1b | 92.0 | compiled | 35/36 | 0.0 |  |
| simple-parking | qwen-ref:1b | 93.5 | compiled | 34/34 | 0.0 |  |
| simple-parking | qwen-broken:1b | 87.3 | compiled (1 repair) | 34/34 | 0.0 |  |
| simple-parking | qwen-mutant:1b | 85.7 | compiled | 31/34 | 0.0 |  |

### Failed requirements and tests

- qwen-mutant:1b / extreme-scheduler: requirements A3.3, B.3, 1 failing test(s) - E-PV-06: AssertionError: job 1 must not be placed at tick 0 where it would overlap job 4: expected <4[1,4) 3[4,6)> but was <4[1,4) 1[0,3) 3[4,6)>
- qwen-mutant:1b / moderate-dispatch: requirements A2.3, 1 failing test(s) - M-PL-07: AssertionError: 101(p3), then p1 by energy asc (6=7) then id asc among energy 18: 5, 7, 102: expected <[101, 6, 5, 7, 102]> but was <[101, 5, 7, 102, 6]>
- qwen-mutant:1b / simple-parking: requirements A2.2, A2.3, A4.2, B.2, 3 failing test(s) - S-WP-03: AssertionError: 481: expected <950> but was <800> | S-Q-01: AssertionError: first price: expected <950> but was <800> | S-HT-02: AssertionError: first price: expected <950> but was <800>

## ACD (web: React, TypeScript, HTML/CSS)

### Overall ranking

| # | Model | Correctness /60 | Overall /100 | Automated results | Paper marks verified | Complete answers | Avg generation s | Avg repairs |
|---|---|---|---|---|---|---|---|---|
| 1 | qwen-ref:1b | 60.0 / 60 | 88.2 | 42/42 (100%) | 51% | 100% | 0.4 | 0.0 |
| 2 | qwen-mutant:1b | 51.3 / 60 | 85.1 | 37/42 (88%) | 41% | 100% | 0.1 | 0.0 |
| 3 | qwen-broken:1b | 31.1 / 60 | 55.1 | 22/42 (52%) | 26% | 0% | 0.1 | 0.0 |

### Per-task results

| Task | Model | Score | Answers present | Tests passed | Gen s | Note |
|---|---|---|---|---|---|---|
| acd-mock-ict | qwen-ref:1b | 88.2 | answered 49/49 | 42/42 | 0.4 |  |
| acd-mock-ict | qwen-mutant:1b | 85.1 | answered 49/49 | 37/42 | 0.1 |  |
| acd-mock-ict | qwen-broken:1b | 55.1 | answered 29/49 | 22/42 | 0.1 |  |

### ACD evidence, kept separate

Objective answers are graded against the key; executed checks were actually run; static checks are pattern checks and are NOT tests; manual rubric marks come only from manual.json. A syntax/static pass of generated code is not proof it behaves correctly.

| Model | Task | Objective (auto-graded) | Executed checks | Static checks (not tests) | Generated-code validation | Answers present |
|---|---|---|---|---|---|---|
| qwen-ref:1b | acd-mock-ict | 40/40 | 2/2 | 2/2 | no code files to validate | 49/49 |
| qwen-mutant:1b | acd-mock-ict | 37/40 | 0/2 | 1/2 | no code files to validate | 49/49 |
| qwen-broken:1b | acd-mock-ict | 20/40 | 2/2 | 2/2 | no code files to validate | 29/49 |

### Failed requirements and tests

- qwen-mutant:1b / acd-mock-ict: requirements A3, B3, C1, C2, E2, 5 failing test(s) - A3: expected B but got C | B3: expected False but got True | C1: expected 80 but the code produced 112500 | C2: answer.ts(6,1): error TS2578: Unused '@ts-expect-error' directive. |  | E2: expected A but got B
- qwen-broken:1b / acd-mock-ict: requirements B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15, E1, E2, E3, E4, E5, 20 failing test(s) - B1: expected True but got no readable answer | B2: expected True but got no readable answer | B3: expected False but got no readable answer | B4: expected True but got no readable answer | B5: expected True but got no readable answer | B6: expected True but got no readable answer

## Conditions

Ollama runs include Drop's deterministic code fixers, so scores describe model + Drop pipeline, not the raw model. Task input hashes must be identical across models:

- acd-mock-ict: fd78e63011ce801a
- extreme-scheduler: b89c8152a369ee79
- moderate-dispatch: 213976d5cedfa7e6
- simple-parking: 5ddecee010ad9d8f
