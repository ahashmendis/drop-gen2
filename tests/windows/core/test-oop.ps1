# OOP tests for the Windows core (DropOop.ps1): port of the OOP cases of tests/acd/driver_unit.swift, same fixtures.
#   pwsh -NoProfile -File tests/windows/core/test-oop.ps1        (needs a JDK 17+ and Spring/Jackson jars in ~/.m2 for the javac cases)
. (Join-Path $PSScriptRoot 'lib.ps1')

# ===== OOP per-task planner =====
$oopPaper = "`n######## EXAM PAPER / INSTRUCTIONS ########`n===== FILE: MODERATE.docx =====`nMODERATE PRACTICE EXAM`nScenario`nAn emergency team allocates deliveries.`nAssessment and marking`nTask 1 $([char]0x2013) First subclass`n18`nLO1`nTask 2 $([char]0x2013) New subclass + object processing`n22`nLO1`nSection B $([char]0x2013) Functional testing`n20`nTask 1 $([char]0x2013) Implement GroundMission [18 marks, LO1]`n4 marks: extend DispatchMission.`n8 marks: energyUnits() = 2x distanceKm + 5x loadKg.`nTask 2 $([char]0x2013) Add AirMission and implement dispatch planning [22 marks, LO1]`n7 marks: implement AirMission.`nTask 3 $([char]0x2013) Validation [20 marks, LO2]`n6 marks: energy(id) raises MissionNotFoundException.`nIllustrative calculations and input`nEnergy: GroundMission(101) = 39.`nREST operations to demonstrate`nGET /api/missions`nSection B $([char]0x2013) Six functional checks [20 marks, LO3]`n3 $([char]0x2013) GroundMission(101) consumes 39 energy units.`nSubmission and final checks`nZip the project.`n`n######## STARTER PROJECT FILES ########`n===== FILE: src/main/java/x/GroundMission.java =====`npublic class GroundMission {}`n===== FILE: src/main/java/x/DispatchMission.java =====`npublic abstract class DispatchMission {}"
$op = New-DropOopPlan $oopPaper
Check 'oop planner: real task headings only, in order, with marks' (($op.Tasks | ForEach-Object { $_.N }) -join ',' -eq '1,2,3' -and ($op.Tasks | ForEach-Object { $_.Marks }) -join ',' -eq '18,22,20') (($op.Tasks | ForEach-Object { "$($_.N):$($_.Marks)" }) -join ' ')
Check 'oop planner: each task text stops at the next task or the worked-examples heading' ($op.Tasks[0].Text.Contains('2x distanceKm') -and -not $op.Tasks[0].Text.Contains('AirMission') -and -not $op.Tasks[2].Text.Contains('Energy: GroundMission(101)'))
Check 'oop planner: scenario preamble, worked-example postamble, starter split off' ($op.Preamble.Contains('emergency team') -and $op.Postamble.Contains('GroundMission(101) = 39') -and $op.StarterText.Contains('DispatchMission.java'))
$plain = New-DropOopPlan "`n######## EXAM PAPER / INSTRUCTIONS ########`nTask 1 Build A.`nTask 2 Build B.`nTask 3 Build C.`n"
Check "oop planner: plain 'Task N' papers use the last heading of each number" ((($plain.Tasks | ForEach-Object { $_.N }) -join ',') -eq '1,2,3')
Check 'oop planner: no task structure -> $null (the single request is used)' ($null -eq (New-DropOopPlan "`n######## EXAM PAPER / INSTRUCTIONS ########`nWrite a program that prints hello.`n"))
$first = Get-DropOopTaskPrompt $op $op.Tasks[0] @{}
$second = Get-DropOopTaskPrompt $op $op.Tasks[1] @{ 'src/main/java/x/GroundMission.java' = 'public class GroundMission { int e(){return 1;} }' }
Check 'oop prompt: the ORIGINAL Ollama header comes first, unchanged' ($first.StartsWith($OllamaPromptHeader))
$n = $OllamaPromptHeader.Length + 400
Check 'oop prompt: only the requested task is asked for; stable prefix identical between tasks' ($first.Contains('Write ONLY Task 1 now') -and -not $first.Contains("Task 2 $([char]0x2013) Add AirMission and implement") -and $second.Contains('Write ONLY Task 2 now') -and $first.Substring(0, $n) -eq $second.Substring(0, $n))
Check 'oop prompt: files written for earlier tasks are included and replace the starter copy' ($second.Contains('FILES YOU HAVE ALREADY WRITTEN') -and $second.Contains('int e(){return 1;}') -and -not $second.Contains('public class GroundMission {}'))
Check 'oop prompt: no HOW TO TEST in the request, worked examples included' ($second.Contains('do not write a HOW TO TEST section') -and $second.Contains('GroundMission(101) = 39'))
$script:reqs = New-Object System.Collections.Generic.List[object]
$gen = {
    param($r)
    $script:reqs.Add($r)
    if ($r.Label -eq 'Task 2') { return $null }
    if ($r.Label -eq 'Task 3') { return "// ===== Task 3 =====`n// ===== FILE: src/main/java/x/Svc.java =====`npackage x;`npublic class Svc {}" }
    return "// ===== FILE: src/main/java/x/GroundMission.java =====`npackage x;`npublic class GroundMission {}"
}
$w = Invoke-DropOopPerTask $op $false $gen { param($s) }
Check 'oop per-task: one request per task, thinking off, budget scales with marks' ($script:reqs.Count -eq 3 -and -not ($script:reqs | Where-Object { $_.Think }) -and $script:reqs[1].NumPredict -gt $script:reqs[0].NumPredict) (($script:reqs | ForEach-Object { $_.NumPredict }) -join ',')
Check 'oop per-task: a missing Task header is added; a failed task is skipped, not fatal' ($w.StartsWith('// ===== Task 1 =====') -and $w.Contains('// ===== Task 3 =====') -and -not $w.Contains('Task 2'))
Check 'oop per-task: later prompts carry the earlier answer files' ($script:reqs[2].Prompt.Contains('FILES YOU HAVE ALREADY WRITTEN') -and $script:reqs[2].Prompt.Contains('public class GroundMission'))
Check 'oop per-task: every task failing -> $null' ($null -eq (Invoke-DropOopPerTask $op $false { param($r) return $null } { param($s) }))
$script:cs = New-Object System.Collections.Generic.List[object]
[void](Invoke-DropOopPerTask $op $true { param($r) $script:cs.Add($r); if ($r.Think) { return $null }; return "// ===== FILE: a.java =====`nclass A{}" } { param($s) })
Check 'oop per-task careful: thinking first, empty thinking reply falls back to no-thinking' (@($script:cs | Where-Object { $_.Think }).Count -eq 3 -and @($script:cs | Where-Object { -not $_.Think }).Count -eq 3)

# ===== mapping query strings, skipped loop (pure text rules) =====
Check 'oop: a query string inside a mapping path is removed; clean mappings untouched' ((Fix-DropMappingQueryStrings '@GetMapping("/plan?capacity=...&urgentOnly=false") public X plan()') -eq '@GetMapping("/plan") public X plan()' -and (Fix-DropMappingQueryStrings '@GetMapping("/{id}/energy") @PostMapping("/air")') -eq '@GetMapping("/{id}/energy") @PostMapping("/air")')
$ok = 'for (X m : l) { if (a > b) { skipped.add(m.getId()); continue; } }'
Check 'oop logic: an answer whose skip branch is already right is left alone' ((Fix-DropSkippedLoop $ok) -eq $ok)
Check 'oop: placeholders are reported' ((Get-DropSemanticFindings "// ===== FILE: src/main/java/x/A.java =====`npackage x;`nclass A { void f(){ throw new UnsupportedOperationException(); } }").Contains('placeholder'))

# ===== real-answer fixtures (compile with javac) =====
$m = Get-ModerateInput
$starter = $m.Starter
Check 'moderate starter + paper collected' ($starter.Count -gt 5 -and $m.Paper.Contains('STARTER PROJECT FILES')) "starter=$($starter.Count)"
$script:StarterFiles = $starter
$failed = Read-Fixture 'tests/acd/fixtures/oop_moderate_failed_answer.txt'
$errs0 = Get-DropCompileErrors $failed
if ($null -eq $errs0) {
    Check 'oop: JDK/Spring jars available for the javac tests' $false 'Get-DropCompileErrors returned $null (no javac or ~/.m2 Spring jars)'
} else {
    Check 'oop: the real failed answer does not compile (getType / Collectors / generic mismatch)' ($errs0 -ne '' -and ($errs0.Contains('getType') -or $errs0.Contains('Collectors'))) $errs0
    $fixedA = Invoke-DropJavacFixes $failed $starter $errs0
    $e1 = Get-DropCompileErrors $fixedA
    Check 'oop: javacFixes turns it into code that compiles - no model call' ($e1 -eq '') $e1
    Check 'oop: getType() became the class name and the String list became the List<Long>' ($fixedA.Contains('.getClass().getSimpleName()') -and -not $fixedA.Contains('getType()') -and -not $fixedA.Contains('Long::toString'))
    $pf = Get-DropParsedFiles $fixedA; $po = Get-DropParsedFiles $failed
    $gm = 'src/main/java/edu/practice/dispatch/model/GroundMission.java'
    Check 'oop: files javac did not complain about are untouched' ($pf[$gm] -eq $po[$gm])
    $gens = 0
    $hooks = @{ Generate = { param($p, $l) $script:gens++; return $failed }; Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    $script:gens = 0
    $pr = Invoke-DropOopPipeline "`n######## EXAM PAPER / INSTRUCTIONS ########`nTask 1 x. Task 2 y.`n######## STARTER PROJECT FILES ########`n===== FILE: src/main/java/x.java =====`n" 'ollama' $starter $hooks
    Check 'oop pipeline: compiles with ZERO repair rounds and one model call' ($pr.Compiled -eq $true -and $pr.RepairRounds -eq 0 -and $script:gens -eq 1) "compiled=$($pr.Compiled) rounds=$($pr.RepairRounds) gens=$script:gens"
    $script:gens = 0
    $pr2 = Invoke-DropOopPipeline 'x' 'opencode_go' $starter @{ Generate = { param($p, $l) $script:gens++; return $failed }; Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    Check 'OpenCode Go path is untouched: no deterministic fixing (it still needs its own repair rounds)' ($pr2.Compiled -eq $false -or $pr2.RepairRounds -gt 0) "compiled=$($pr2.Compiled) rounds=$($pr2.RepairRounds)"
    $noImport = (Invoke-DropJavacFixes $failed $starter $errs0).Replace('import edu.practice.dispatch.service.*;import edu.practice.dispatch.model.*;import edu.practice.dispatch.dto.*;', 'import edu.practice.dispatch.service.*;import edu.practice.dispatch.dto.*;')
    $e2 = Get-DropCompileErrors $noImport
    if ($e2) {
        $fx = Invoke-DropJavacFixes $noImport $starter $e2
        Check 'oop: a missing import of a class the project defines is added (DispatchMission)' ($fx.Contains('import edu.practice.dispatch.model.DispatchMission;') -and (Get-DropCompileErrors $fx) -eq '') $e2
    } else { Check 'oop: project-class import case set up' $false 'the import removal produced no javac error' }
    $unrelated = "// ===== Task 1 =====`n// ===== FILE: src/main/java/edu/practice/dispatch/model/GroundMission.java =====`npackage edu.practice.dispatch.model;`npublic class GroundMission extends DispatchMission { int x = ""one""; }`n"
    Check 'oop: an error no rule knows is left for the model (answer unchanged)' ((Invoke-DropJavacFixes $unrelated $starter "src/main/java/edu/practice/dispatch/model/GroundMission.java:3: error: incompatible types: String cannot be converted to int`n x`n  ^") -eq $unrelated)

    # ===== paper-aware fixes + HOW TO TEST on the answer that compiled but had logic slips =====
    $logic = Read-Fixture 'tests/acd/fixtures/oop_moderate_logic_bugs_answer.txt'
    $fx = Invoke-DropPaperFixes (Invoke-DropStaticFixes $logic $starter) $m.Paper
    $bt = Get-DropBenchTask (Join-Path $script:RepoRoot 'bench-tasks/moderate-dispatch')
    $before = Invoke-DropBenchTests $bt $logic $starter
    $after = Invoke-DropBenchTests $bt $fx $starter
    Check 'oop logic: the unfixed answer (compiles) fails 7 of 36 tests' ($before.Ran -and $before.Results.Count -eq 36 -and @($before.Results | Where-Object { $_.Passed }).Count -eq 29) "$(@($before.Results | Where-Object { $_.Passed }).Count)/$($before.Results.Count) $($before.Reason)"
    Check 'oop logic: after the paper-aware fixes all 36 tests pass' ($after.Ran -and $after.Results.Count -eq 36 -and @($after.Results | Where-Object { $_.Passed }).Count -eq 36) "$(@($after.Results | Where-Object { -not $_.Passed } | ForEach-Object { $_.Id }) -join ',') $($after.Reason)"
    Check "oop logic: 'positive distance' (paper wording) makes both distance checks '<= 0'; load stays '< 0'" (([regex]::Matches($fx, [regex]::Escape('request.distanceKm() <= 0'))).Count -eq 2 -and $fx.Contains('request.loadKg() < 0'))
    Check 'oop logic: skipped ids are recorded only when a mission does not fit' ($fx.Contains('skipped.add(m.getId()); continue;') -and -not $fx.Contains('for (DispatchMission m : missions) { skipped.add(m.getId()); }'))
    $ht = Add-DropHowToTest $fx $starter $m.Paper
    Check "HOW TO TEST uses the starter's port and the paper's own example calls" ($ht.Contains('localhost:8082/api/missions/101/energy') -and $ht.Contains('capacity=60&urgentOnly=false') -and $ht.Contains('"id":104') -and -not $ht.Contains(':8080') -and -not $ht.Contains('missions/1/energy')) $ht
    $htf = Add-DropHowToTest $fx $starter 'no examples here'
    Check "HOW TO TEST without paper examples: JSON body comes from the starter's record, not {}" ($htf.Contains('"distanceKm": 1') -and $htf.Contains('"critical": true')) $htf

    # ===== stubs that compile (ApiError as a success response, "not implemented") =====
    $stub = Read-Fixture 'tests/acd/fixtures/oop_moderate_stub_controller_answer.txt'
    $findings = Get-DropSemanticFindings $stub
    Check 'lint: the stub controller is reported (getEnergy / getPlan return ApiError as a normal response)' ($findings.Contains('getEnergy()') -and $findings.Contains('getPlan()') -and $findings.Contains('DispatchController.java:1: error:')) $findings
    Check 'lint: a real answer and an @ExceptionHandler returning ApiError are NOT reported' ((Get-DropSemanticFindings $logic) -eq '')
    $realController = (Get-DropParsedFiles $logic)['src/main/java/edu/practice/dispatch/controller/DispatchController.java']
    $repaired = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====`n" + $realController
    $script:prompts = New-Object System.Collections.Generic.List[string]
    $lh = @{ Generate = { param($p, $l) $script:prompts.Add($p); if ($script:prompts.Count -eq 1) { return $stub } else { return $repaired } }
             Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    $lr = Invoke-DropOopPipeline "`n######## EXAM PAPER / INSTRUCTIONS ########`nTask 1 a. Task 2 b.`n" 'ollama' $starter $lh
    Check 'lint pipeline: compile-clean stubs trigger a repair round that names the file and the problem' ($script:prompts.Count -eq 2 -and $script:prompts[1].Contains('returns ApiError as a normal response') -and $script:prompts[1].Contains('DispatchController.java')) "$($script:prompts.Count)"
    Check 'lint pipeline: after the repair the controller returns real results and the answer is clean' ($lr.Compiled -eq $true -and $lr.RepairRounds -eq 1 -and (Get-DropSemanticFindings $lr.Answer) -eq '') "rounds=$($lr.RepairRounds)"
    $script:n2 = 0
    $stubController = (Get-DropParsedFiles $stub)['src/main/java/edu/practice/dispatch/controller/DispatchController.java']
    $worse = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====`n" + $stubController + "`n// TODO fix later, plan not implemented"
    $gr = Invoke-DropOopPipeline 'x' 'ollama' $starter @{ Generate = { param($p, $l) $script:n2++; if ($script:n2 -eq 1) { return $stub } else { return $worse } }; Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    Check 'stub guard: a repair that adds a placeholder is discarded, not accepted just because it compiles' (-not $gr.Answer.Contains('TODO fix later') -and $script:n2 -eq 2) "calls=$($script:n2)"
    $guarded = Invoke-DropPaperFixes (Invoke-DropStaticFixes $stub $starter) $m.Paper
    $merged2 = Merge-DropFixes $guarded $repaired
    $t2 = Invoke-DropBenchTests $bt $merged2 $starter
    $failedIds = @($t2.Results | Where-Object { -not $_.Passed } | ForEach-Object { $_.Id })
    Check 'stub answer + paper guard + repaired controller: the capacity tests pass (only the 10,000 limit is still missing)' ($t2.Ran -and $t2.Results.Count -eq 36 -and ($failedIds -join ',') -eq 'M-SV-08') ($failedIds -join ',')
    Check "paper guard: 'reject non-positive plan capacity' puts a capacity check at the top of plan() (once)" ($guarded.Contains('if (capacity <= 0) { throw new IllegalArgumentException("capacity must be positive"); }') -and ([regex]::Matches($guarded, 'capacity <= 0')).Count -eq 1 -and (Invoke-DropPaperFixes $guarded $m.Paper) -eq $guarded)
    Check 'paper guard: an answer that already checks the parameter is left alone' (([regex]::Matches((Invoke-DropPaperFixes $logic $m.Paper), 'capacity <= 0')).Count -eq 1)

    # ===== invented wrapper classes + undeclared fields + null on a primitive =====
    $wrapper = Read-Fixture 'tests/acd/fixtures/oop_moderate_wrapper_answer.txt'
    $rawErrs = Get-DropCompileErrors $wrapper
    Check 'wrapper: the real answer fails javac (null compared with a primitive long, undeclared fields)' ($rawErrs.Contains('bad operand types') -or $rawErrs.Contains('variable code')) $rawErrs
    $direct = Invoke-DropPaperFixes (Invoke-DropStaticFixes $wrapper $starter) $m.Paper $starter
    $directCtl = (Get-DropParsedFiles $direct)['src/main/java/edu/practice/dispatch/controller/DispatchController.java']
    Check 'wrapper (direct, no model): static + paper fixes rewrite ALL wrapped controller methods' ($directCtl.Contains('Map.of("energyUnits", service.energy(id))') -and $directCtl.Contains('return service.plan(capacity,urgent);') -and -not $directCtl.Contains('ApiError("OK"')) $directCtl
    $script:c3 = 0
    $pr3 = Invoke-DropOopPipeline $m.Paper 'ollama' $starter @{ Generate = { param($p, $l) $script:c3++; return $wrapper }; Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    Check 'wrapper pipeline: compiles with ZERO repair rounds and ONE model call' ($pr3.Compiled -eq $true -and $pr3.RepairRounds -eq 0 -and $script:c3 -eq 1) "compiled=$($pr3.Compiled) rounds=$($pr3.RepairRounds) calls=$script:c3"
    $f3 = Get-DropParsedFiles $pr3.Answer
    $t3 = Invoke-DropBenchTests $bt $pr3.Answer $starter
    Check 'wrapper: the result passes all 36 MODERATE tests' ($t3.Ran -and @($t3.Results | Where-Object { $_.Passed }).Count -eq 36 -and $t3.Results.Count -eq 36) (@($t3.Results | Where-Object { -not $_.Passed } | ForEach-Object { $_.Id }) -join ',')
    $handler = [string]$f3['src/main/java/edu/practice/dispatch/error/ApiExceptionHandler.java']; $ctl = [string]$f3['src/main/java/edu/practice/dispatch/controller/DispatchController.java']
    Check "wrapper: the invented ApiResponse class is replaced by the starter's ApiError everywhere" (-not $handler.Contains('ApiResponse') -and $handler.Contains('new ApiError("NOT_FOUND"') -and -not $ctl.Contains('ApiResponse')) $handler
    Check 'wrapper: the controller delegates - map with the paper key, the plan, POST 201 with the service result' ($ctl.Contains('Map.of("energyUnits", service.energy(id))') -and $ctl.Contains('return service.plan(capacity,urgent);') -and $ctl.Contains('ResponseEntity.status(HttpStatus.CREATED).body(service.addAir(request))') -and -not $ctl.Contains('id required')) $ctl
    Check 'wrapper: no placeholders or ApiError-as-success are left' ((Get-DropSemanticFindings $pr3.Answer) -eq '')
    $nullOnly = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====`npackage edu.practice.dispatch.controller;`nimport edu.practice.dispatch.dto.*;`npublic class DispatchController {`n int f(NewAirMission r){`n  if (r.id() == null || r.id() <= 0L) { return 1; }`n  return 0;`n }`n}`n"
    $e = Get-DropCompileErrors $nullOnly
    if ($e) {
        $fx2 = Invoke-DropJavacFixes $nullOnly $starter $e
        Check 'javac fix: a primitive compared with null loses that comparison on the reported line' ($fx2.Contains('if (r.id() <= 0L)') -and (Get-DropCompileErrors $fx2) -eq '') $fx2
    } else { Check 'javac fix: null-compare case fails raw' $false 'expected an error' }
    $fieldOnly = "// ===== FILE: src/main/java/edu/practice/dispatch/dto/Box.java =====`npackage edu.practice.dispatch.dto;`npublic class Box {`n public Box(String code, int size){this.code=code;this.size=size;}`n public String getCode(){return code;}`n public int getSize(){return size;}`n}`n"
    $e = Get-DropCompileErrors $fieldOnly
    if ($e) {
        $fx3 = Invoke-DropJavacFixes $fieldOnly $starter $e
        $ok3 = Get-DropCompileErrors $fx3
        Check 'javac fix: fields a constructor assigns but never declared are declared with the parameter types (two passes)' ($fx3.Contains('private final String code;') -and ($ok3 -eq '' -or (Get-DropCompileErrors (Invoke-DropJavacFixes $fx3 $starter $ok3)) -eq '')) ($fx3 + $ok3)
    } else { Check 'javac fix: undeclared-field case fails raw' $false 'expected an error' }
    Check 'wrapper rule: an invented class whose constructor matches no starter record is left alone' ((Fix-DropInventedWrapper "// ===== FILE: src/main/java/x/C.java =====`npackage x;`npublic class C {`n private static class Odd {`n  public Odd(double a, double b){}`n }`n}`n" $starter).Contains('class Odd'))

    # ===== the real no-thinking MODERATE answer =====
    $nt = Read-Fixture 'tests/acd/fixtures/oop_moderate_nothink_answer.txt'
    $rawNT = Get-DropCompileErrors $nt
    Check 'no-think answer: it really fails javac (Collection->List and the !int errors)' ($rawNT.Contains('Collection<DispatchMission> cannot be converted to List<DispatchMission>') -and $rawNT.Contains("unary operator '!'")) $rawNT
    $script:cnt = 0
    $prNT = Invoke-DropOopPipeline $m.Paper 'ollama' $starter @{ Generate = { param($p, $l) $script:cnt++; return $nt }; Compile = { param($a) Get-DropCompileErrors $a }; Status = { param($s) } }
    Check 'no-think answer: compiles with zero repair rounds and one model call' ($prNT.Compiled -eq $true -and $prNT.RepairRounds -eq 0 -and $script:cnt -eq 1) "compiled=$($prNT.Compiled) rounds=$($prNT.RepairRounds) calls=$script:cnt"
}
Finish-Tests
