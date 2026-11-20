# Ollama Student-Level Code Quality — Design (2026-11-19)

Status: draft, awaiting approval. Scope: **Ollama provider only, macOS + Windows** (confirmed with partner). OpenCode Go: untouched, byte-locked.

## Intent

Drop is used by students completing programming coursework and timed lab exams. Ollama-generated solutions have been unnecessarily large and over-engineered: slow to generate, slow to compile, harder to read than a good student's answer. This change makes every discovered Qwen model (Ollama) produce the **simplest complete correct solution at student level** — and when javac complains, repair surgically instead of rewriting — without touching OpenCode Go in any way.

## Goals

1. **Student-level Java**: correctness first, then passing specified/likely-hidden tests, then matching the question and starter project, then concepts at the student's expected level, then concision. Target: simplest complete solution, not minimum lines.
2. **Silent pre-generation self-check**: requirement coverage, worked examples recomputed, boundary cases, starter compatibility, names/imports exist — checked internally, never written out. Never claim hidden (or any) tests pass unless they were actually run.
3. **Targeted repair**: compiler error + relevant source only; preserve working code; concise, limited to affected sections (macOS, where the compile/repair loop exists).
4. **Output economy**: only the files/code the question requires; no explanations, no alternative implementations, no boilerplate; the parser's output-format contract stays unchanged.
5. **Output-token limit** sized to task complexity; never truncates a required solution (measurement-guarded).
6. **Compile efficiency** (macOS): compile only what needs compiling across repair rounds; no unnecessary compilation attempts; existing compiler validation and automatic repair preserved.
7. **Model independence**: identical behaviour for every discovered Qwen model, any device/model size; settings scale with task and hardware, never with model names.
8. **Measured**: before/after on representative coursework — generated lines, generation time, compilation time, compile attempts, compile success, test results.

## Non-goals

- Any OpenCode Go change — its prompt text stays **byte-identical, quirks included** (it rides in the request payload the lock pins).
- Porting the javac compile/repair loop to Windows (Windows keeps today's flow; it has no compiler check).
- Changing the answer output format (`// ===== Task N =====` / `// ===== FILE: … =====` contract used by `Get-TaskSection`, `parseAnswerFiles`, `mergeFixes`).
- Line-count golf, removing required functionality, model downloads, new dependencies.
- Enabling the currently-disabled DoubleCheck review pass on either platform.

## Anti-goals (failure even if it "works")

- Code truncated by the new output cap.
- A "repair" that rewrites the whole answer and breaks working parts.
- "Student-level" that strips OOP constructs the question actually requires.
- Slower or less correct answers than today.

## Constraints

- **OpenCode Go lock (verbatim)**: "The existing OpenCode Go integration works perfectly. **Do not modify its implementation.** Do not change its: Endpoint, Authentication, API key handling, Headers, Request payload, Streaming, Error handling, Retry behavior, Configuration format, Credential storage, Connection test, Provider-specific UI, Any other existing integration logic." Enforced by `opencode-gate.py d1ee02f` (byte-identical `OpenCodeGoProvider` + Send-Prompt opencode branch; no sensitive tokens in added lines).
- Standing security constraints unchanged: credentials local only (no Keychain/Credential Manager), never in logs or error messages, never overwrite a valid key on update, no fallback by default, no guessed API contracts, no sending project files to another provider.
- No new dependencies (javac discovery, Spring-jar classpath, pdftotext note all as today).
- The student-level layer (S1–S5) is shared wording on both platforms, but each platform keeps its own established output-format contract (mac keeps its HOW TO TEST block, Windows keeps "no test commands") — changing either is a non-goal.
- Everything new is gated to the Ollama path.

## Current state (recon)

- Prompts are **shared across providers today**: win `$PromptHeader` (Drop.ps1:112), `$ReviewHeader` (:176); mac `PROMPT_HEADER`, `REPAIR_HEADER` (install-drop.sh:~60–136; `REVIEW_HEADER` is empty). Prompt text is part of the request payload → any change must fork per provider.
- macOS has the compile-repair loop (install-drop.sh:1507–1536): `compileErrors` → `runJavac` (JDK via java_home/JVMs/IntelliJ JBR/homebrew; Spring jars from ~/.m2; compiles starter + answer files together), max 2 rounds, `fixPrompt = PROMPT_HEADER + full paper + full previous answer + JAVAC ERRORS (6000 chars) + REPAIR_HEADER`, `mergeFixes`, stops when merge is a no-op. **Windows has no compile step at all.**
- DoubleCheck review is disabled on both platforms (mac `let check = false`; win `$script:DoubleCheck = $false`) → single generation per run already (satisfies "avoid repeated full-solution generation" as-is).
- Ollama requests: `options` = `num_ctx` (RAM-aware ceiling) + `temperature 0.2`; no `num_predict` (Drop.ps1:1008, install-drop.sh:390).
- Existing RULES 1–10 are correctness/test-passing rules — kept. RULE 1 ("write an inventory as // comments") contradicts OUTPUT ("no inventory"); the Ollama fork resolves it by making name-checking **silent** (like RULE 8). OpenCode text unchanged.

## Approaches

**A. Provider-forked prompts + Ollama-gated loop tuning (chosen).** New Ollama prompt constants; OpenCode keeps today's constants byte-identical; provider selection at the prompt-assembly points (win Start-Answer:924, review:1093; mac handle:1488, review:1499, fixPrompt:1518). Repair targeting, compile targeting and `num_predict` gated to `provider == "ollama"`. Cost: two prompt texts to maintain, a few provider branches. Benefit: zero OpenCode risk; strictest reading of "exclusively Ollama".

**B. Rewrite the shared prompts for both providers — rejected**: would change OpenCode's request payload (explicitly forbidden).

**C. Prompt-text only, no options/loop work — rejected**: misses §5 output limits, §8 compile efficiency and the measurement requirement.

Sub-decision: javac targeting is Drop-side post-processing, not OpenCode integration, so it *could* be shared; chosen **strictly gated anyway** ("Keep this implementation strictly within the Ollama integration"). Cost if wrong: OpenCode users keep a slightly slower compile check — no correctness impact.

## The design

### 1. New Ollama prompt set (shared S-layer on both platforms)

Layered on the existing correctness rules (RULES 1–10 semantics preserved: exact starter names, keep what the paper says to keep, validation→400, error-handler codes, OOP via parent type, mark-bullet literalism, thin controller, common traps, hard-paper patterns). Added for Ollama:

- **S1 — Simplest complete solution.** Priority order: correctness → passing specified and likely hidden tests → matching requirements and starter → student-level concepts → concision. Never sacrifice required functionality to shorten code.
- **S2 — Student-level Java.** Straightforward implementations using the OOP concepts the question exercises; no design patterns, extra abstractions/interfaces, streams/lambdas/advanced APIs unless the question requires them; no extra dependencies/frameworks; no extra classes or files without genuine need; minimal comments (no boilerplate, no duplication); no unnecessary imports, helper methods or utility classes; **do not invent requirements**.
- **S3 — Silent pre-check (replaces RULE 1's inventory-in-comments).** Before writing: every requirement addressed, example numbers recomputed, boundary/edge cases considered, starter tests and interfaces compatible, every name/import exists. Do NOT write the checks out. **Never claim tests pass that were not executed.**
- **S4 — Output economy.** Only files the question needs, each complete; reuse starter code instead of rewriting it; no explanations, summaries or alternative implementations; unchanged files not re-emitted (except the established cross-task last-copy rule the parser needs); format contract (Task/File headers, mac HOW TO TEST block, Windows "no test commands") unchanged. *(My call: the mac HOW TO TEST block stays — terse, part of the established contract, useful mid-exam; §8's "no lengthy explanations" targets prose, not these commands.)*
- **S5 — Surgical repair wording** (mac repair-header fork): fix only what the JAVAC ERRORS implicate; keep everything that already works; output only the files you must change, each complete with its FILE header; no explanations, no unchanged files.

Windows' review fork (`$OllamaReviewHeader`) mirrors: strict exam-marker pass + S1–S4, corrections surgical, same output contract.

### 2. Prompt fork mechanics

Old constants stay in the file, referenced by the non-Ollama path only — OpenCode request payloads byte-identical. New constants: `$OllamaPromptHeader`, `$OllamaReviewHeader` (win); `OLLAMA_PROMPT_HEADER`, `OLLAMA_REPAIR_HEADER` (mac). Selection at assembly points by `provider == "ollama"`.

### 3. Targeted repair (macOS, Ollama only)

`fixPrompt` = terse repair header + `JAVAC ERRORS` (6000-char cap kept) + **only the affected answer files** (file/class names parsed from the error lines) + the starter files those files reference (simple-name matching) — never the full paper, never unchanged answer files. The repair header itself carries a condensed reminder (keep working code, stay student-level, fix only what the errors implicate, complete files with FILE headers, no explanations) instead of the full rules *(my call — §4 says send "the compiler error message and the relevant source code", not the whole prompt)*. Still bounded by the existing context ceiling/oversize block. Max 2 rounds, `mergeFixes`, no-op-merge break — all unchanged. OpenCode keeps today's full-context fixPrompt verbatim.

### 4. Compile efficiency (macOS, Ollama only)

`runJavac` gains an optional compile-set: round 1 compiles starter + answer as today; repair rounds compile the union of files changed by the merge, files with errors in the previous round, and files referencing a changed class (simple-name matching), with the rest on `-sourcepath` for whatever those pull in ("compile only the files that need to be compiled, together with any necessary dependent source files"). **Soundness rule: Drop never reports a clean compile while a file that could still be broken was skipped — when the dependency set can't be determined confidently, compile everything** *(my call — "changed files only" would let a still-broken unchanged file, or a dependent broken by the change, go uncompiled, and Drop would falsely report a clean compile)*. Existing no-waste behaviour kept: no compile without starter/JDK, no round after a clean compile, no round when the merge changes nothing. OpenCode compiles everything every round as today.

### 5. Output-token limit (both platforms, Ollama requests only)

`options` gains `num_predict = min(8192, max(4096, 1536 + 768 × taskCount))`, `taskCount` = distinct "Task N" headers found in the paper (≥1). A safety valve against runaway verbosity, sized from task complexity. The same ceiling applies to draft and repair requests alike — `num_predict` is a ceiling, not a target, so a smaller repair cap would only add truncation risk *(my call)*. The A/B measurement gates the final numbers (raise if any fixture truncates — truncation is an anti-goal).

### 6. Model independence

No model names or size assumptions anywhere in prompts or logic. Behaviour identical for every discovered Qwen. Hardware adaptation stays where it is (RAM-aware `num_ctx` ceilings); `num_predict` scales with the paper only.

## Verification & measurement

1. **Structural pins (RED→GREEN)** + existing suites (ollama-mac, ollama-win, readme) + `swiftc -typecheck` + `bash -n` + **opencode-gate GATE OPEN**. Pins: OpenCode still receives byte-identical old headers (old constants unchanged, referenced by non-Ollama path); Ollama branch references the new constants; `num_predict` present in Ollama options and absent from the OpenCode branch; S1–S5 markers present; repair-targeting and changed-files markers present; format-contract strings unchanged.
2. **Measurement harness** (scratch, not shipped): 6 fixtures — (1) simple Java exercise, (2) OOP class/object, (3) inheritance/polymorphism, (4) collections + file handling, (5) starter project with fixed method signatures, (6) multi-requirement + edge cases — written synthetically to those categories *(my call: reproducible, and no real exam papers embedded in the repo; real-paper sanity runs stay optional)*. Harness runs BEFORE (today's exact behaviour: shared prompts, no `num_predict`, full-context repair) vs AFTER (the full new behaviour) against the same installed Qwen via local Ollama, emulating the mac flow (generate → javac → ≤2 repair rounds), recording per fixture: generated code lines, generation time, javac wall time, compile attempts, compile success, test results (expected-output checks where available). One report table committed to `docs/superpowers/measurements/2026-11-19-ollama-student-quality.md`.
   **Acceptance**: no drop in compile success or test results vs before; generated lines and generation time reduced or equal; no truncation; answers read as student-appropriate on manual inspection.
3. Manual sanity on real `Desktop/OOP` papers — optional, user-driven.

## Left to the builder

Exact wording of S1–S5 within this spec (format-contract strings verbatim); fixture authoring; harness scripts; final `num_predict` values from measurement; the error-line → affected-file matching heuristic.
