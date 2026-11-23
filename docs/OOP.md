# OOP on Ollama: fast no-thinking request by default

**Default (all OOP runs on Ollama, hotkeys included):** one request for the whole paper WITHOUT thinking, through the small-context, memory-aware session
(the model is unloaded when it grows and always at the end). Measured on `qwen3.5:4b`, 8 GB M1 Air, MODERATE practice paper: **~270 s** and, after Drop's
deterministic fixes, **29/36** tests; the original thinking-on request took **~605 s and did not compile**, and sometimes spends its whole token budget thinking and returns
nothing ("context limit reached – no answer produced"). Tray menu → *ACD careful mode (thinking, slower)* turns the original thinking request back on for OOP and ACD
(byte-identical to the original; if it still returns nothing, Drop retries once without thinking, then writes the answer task by task). OpenCode Go is unchanged.

# OOP in the popup: one request per task (experimental, OFF by default)

The **hotkeys (⌃⌥R/C/D/1…0) and the headless run are unchanged**: one request for the whole paper through the original pipeline, as before.
The **visible popup run** (drop files / file picker / ▶ Run folder with OOP selected) and the benchmark can use a per-task path for **Ollama**:

* Drop splits the paper into its tasks (`Task N – … [N marks]` headings; plain `Task N` papers work too) and sends **one request per task**.
  Each request starts with the **unchanged Ollama prompt header** (so the student-level rules are identical), then the paper's scenario, the starter
  project (a file already rewritten by an earlier task replaces its starter copy), the paper's worked examples, the files written so far, and "Write ONLY Task N now".
* The stable prefix comes first, so Ollama's prefix cache reuses it between tasks.
* Thinking is off by default (tray menu → *ACD careful mode* turns it on for both subjects; an empty thinking reply falls back to no thinking).
* Memory: the model stays loaded during the run, is unloaded if it grows past 60 % of RAM, and always unloaded at the end (quiet laptop).
* After generation the **same pipeline as before** runs: Ollama fixers → javac compile → targeted repair (repairs also go through the small-context session, no thinking)
  → HOW TO TEST block. A task that fails to generate is skipped (the compile/repair step can still complete the answer); if every task fails you get an error, never an empty copy.
* Papers with no recognisable task structure, and OpenCode Go, keep the original single request.

## Why it is off by default
Measured on `qwen3.5:4b` on an 8 GB M1 Air with the MODERATE practice paper (real runs, `tests/bench/run-real.sh`): the original single request took ~10 min and
ended with code that did not compile; per-task took ~23 min (3–6 min per task, decode-bound at ~6–10 tokens/s with Ollama's memory peaking at 7 GiB) and also did not
compile. The model writes the same amount of code either way, and repeating the long Ollama prompt header per task costs more than it saves on this machine.
Enable it from the tray menu (*OOP per-task generation (experimental)*) if you want to try it on a bigger machine or a larger model.

## Making the Ollama answer compile and behave (all OOP runs, Ollama only)
Before any model repair, Drop fixes what javac names exactly, with no model call (`javacFixes`): a missing import (JDK/Spring names and classes the project defines),
a method that does not exist (`getType()` → `getClass().getSimpleName()`), and a generic mismatch (`List<Long>` built as strings). Static fixers also remove a query string
copied into a mapping path (`@GetMapping("/plan?capacity=…")` → `"/plan"`), put a skipped-id add into the "does not fit" branch instead of an unconditional loop, and — using the
paper's wording — make a field the paper calls "positive" reject 0 (`< 0` → `<= 0`). The **HOW TO TEST** block now uses the starter's real `server.port`, the paper's own
"REST operations to demonstrate" calls (real ids and JSON) and, without those, sample JSON built from the starter's records. OpenCode Go output is not touched by any of this.
Tested on a real answer that did not compile and then had logic slips: javac-clean after the first rules, 36/36 of the MODERATE tests after the second.
