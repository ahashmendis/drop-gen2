# End-to-end check of the Windows benchmark engine against the scripted mock Ollama (same scenario as tests/bench/run-bench-e2e.sh):
#   qwen-ref returns the staff reference solutions -> everything passes; qwen-mutant a subtly wrong solution per task;
#   qwen-broken code with a compile error, then the fix on the repair round. Plus the ACD mock ICT paper.
#   pwsh -NoProfile -File tests/windows/bench/run-bench-e2e.ps1     (needs python3, JDK 17+, Spring jars in ~/.m2, node; ACD_TEST_NODE_MODULES for tsc)
. (Join-Path $PSScriptRoot '../core/lib.ps1')
$work = Join-Path $script:TestData 'e2e'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item -Path (Join-Path $script:RepoRoot 'bench-tasks') -Destination (Join-Path $env:DROP_BENCH_DIR 'tasks') -Recurse
# ACD support dir: notes + a TypeScript toolchain so the tsc-based check can run
$notes = Join-Path $env:DROP_ACD_DIR 'notes'; New-Item -ItemType Directory -Path $notes -Force | Out-Null
Copy-DropAcdNotes (Join-Path $script:RepoRoot 'acd-notes')
$nm = if ($env:ACD_TEST_NODE_MODULES) { $env:ACD_TEST_NODE_MODULES } else { Join-Path $HOME 'Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules' }
if (Test-Path $nm) { $tc = Join-Path $env:DROP_ACD_DIR 'toolchain'; New-Item -ItemType Directory -Path $tc -Force | Out-Null; [void](New-Item -ItemType SymbolicLink -Path (Join-Path $tc 'node_modules') -Target $nm) }
$sol = Join-Path $work 'sol'
@'
import sys, os, shutil
bt, sol = sys.argv[1:]
mut = {"simple-parking": ("model/WeekendPass.java", "(stayMinutes-480L+59)/60", "(stayMinutes-480L)/60", "edu/practice/parking"),
 "moderate-dispatch": ("service/DispatchService.java", ".thenComparingInt(DispatchMission::energyUnits)", ".thenComparingInt(m->-m.energyUnits())", "edu/practice/dispatch"),
 "extreme-scheduler": ("service/SchedulerService.java", "for(int t=s;t<s+w.getDurationTicks()&&fits;t++){", "for(int t=s;t<s+1&&fits;t++){", "edu/practice/scheduler")}
brk = {"simple-parking": ("model/HourlyPass.java", "long hours=(stayMinutes+59L)/60;", 'long hours="x";'),
 "moderate-dispatch": ("model/GroundMission.java", "long e=2L*getDistanceKm()+5L*getLoadKg();", 'long e="x";'),
 "extreme-scheduler": ("model/BatchWorkload.java", "long age=Math.max(0L,(long)nowTick-getReleaseTick());", 'long age="x";')}
for t,(f,a,b,pkg) in mut.items():
    ref = os.path.join(bt, t, "reference")
    for who in ("ref", "mutant", "broken"): shutil.copytree(ref, os.path.join(sol, who, t))
    p = os.path.join(sol, "mutant", t, "src/main/java", pkg, f); s = open(p).read(); assert a in s, (t, a); open(p, "w").write(s.replace(a, b, 1))
    f2, a2, b2 = brk[t]
    p = os.path.join(sol, "broken", t, "src/main/java", pkg, f2); s = open(p).read(); assert a2 in s, (t, a2); open(p, "w").write(s.replace(a2, b2, 1))
    fixdir = os.path.join(sol, "broken", t + "_fix", "src/main/java", pkg, os.path.dirname(f2)); os.makedirs(fixdir)
    shutil.copy(os.path.join(ref, "src/main/java", pkg, f2), fixdir)
'@ | & python3 - (Join-Path $script:RepoRoot 'bench-tasks') $sol
$mock = Start-MockOllama 'bench' (Join-Path $work 'requests.jsonl') @{ BENCH_TASKS_DIR = (Join-Path $script:RepoRoot 'bench-tasks'); BENCH_SOL_DIR = $sol; MOCK_MODELS = 'qwen-ref:1b,qwen-mutant:1b,qwen-broken:1b' }
try {
    $tasks = @(Get-DropBenchTasks)
    Check 'bench tasks load from the bench folder (3 OOP + 1 ACD)' ($tasks.Count -eq 4 -and @($tasks | Where-Object { $_.Subject -eq 'acd' }).Count -eq 1) "$($tasks.Count)"
    $infos = Get-DropBenchOllamaInfo $mock.Base
    $models = @('qwen-ref:1b', 'qwen-mutant:1b', 'qwen-broken:1b' | ForEach-Object { @{ Provider = 'ollama'; Name = $_; Info = $infos[$_] } })
    $lines = New-Object System.Collections.Generic.List[string]
    $ctx = @{ RunId = 'e2e'; Base = $mock.Base; ManualCtx = 0; RamBytes = 8GB; OopPerTask = $false; OopMode = 'auto'; Careful = $false; OpenCode = @{ BaseUrl = ''; ApiKey = '' }
              Log = { param($m) $lines.Add($m); Write-Host $m }.GetNewClosure(); Cancelled = { $false } }
    Invoke-DropBenchRunAll $ctx $models $tasks
    $rows = @(Get-DropBenchRecords)
    Check 'results.jsonl: 12 runs recorded (4 tasks x 3 models)' ($rows.Count -eq 12) "$($rows.Count)"
    $oop = @{}; foreach ($r in $rows) { if ($r['subject'] -ne 'acd') { $oop["$($r['model'])|$($r['task'])"] = $r } }
    foreach ($t in @('simple-parking', 'moderate-dispatch', 'extreme-scheduler')) {
        $ref = $oop["qwen-ref:1b|$t"]; $mu = $oop["qwen-mutant:1b|$t"]; $br = $oop["qwen-broken:1b|$t"]
        Check "$t ref: compiles and every test passes" ($ref['compile_status'] -eq 'compiled' -and $ref['functional']['ran'] -eq $true -and $ref['functional']['passed'] -eq $ref['functional']['total'] -and $ref['final_status'] -eq 'all_tests_passed') ($ref | ConvertTo-Json -Depth 4 -Compress)
        Check "$t mutant: compiles but at least one test fails (the subtle bug is caught)" ($mu['compile_status'] -eq 'compiled' -and $mu['functional']['passed'] -lt $mu['functional']['total']) "$($mu['functional']['passed'])/$($mu['functional']['total'])"
        Check "$t broken: the compile error is repaired in a model round, then everything passes" ($br['repair_rounds'] -ge 1 -and $br['compile_status'] -eq 'compiled' -and $br['functional']['passed'] -eq $br['functional']['total']) "rounds=$($br['repair_rounds']) status=$($br['compile_status'])"
        Check "$t records conditions, input hash, model digest, answer file" ($ref['conditions']['prompt_header_hash'] -and $ref['input_hash'] -and $ref['model_info']['digest'] -and (Test-Path $ref['answer_path']))
    }
    $acd = @{}; foreach ($r in $rows) { if ($r['subject'] -eq 'acd') { $acd[$r['model']] = $r } }
    $r0 = $acd['qwen-ref:1b']['acd']; $m0 = $acd['qwen-mutant:1b']['acd']; $b0 = $acd['qwen-broken:1b']['acd']
    Check 'ACD ref: objective 40/40, executed 2/2, static 2/2, all 49 answered' ($r0['objective']['correct'] -eq 40 -and $r0['objective']['total'] -eq 40 -and $r0['executed']['passed'] -eq 2 -and $r0['static']['passed'] -eq 2 -and $r0['answered'] -eq 49) ($r0 | ConvertTo-Json -Depth 4 -Compress)
    Check 'ACD mutant: A3/B3/E2 wrong, both executed checks fail, one static fails' ($m0['objective']['correct'] -eq 37 -and $m0['executed']['passed'] -eq 0 -and $m0['static']['passed'] -eq 1) ($m0 | ConvertTo-Json -Depth 4 -Compress)
    Check 'ACD broken: unanswered sections count as failures, never as passes' ($b0['objective']['correct'] -eq 20 -and $b0['answered'] -eq 29) ($b0 | ConvertTo-Json -Depth 4 -Compress)
    Check 'ACD manual items are never auto-assessed' (-not (@($acd['qwen-ref:1b']['requirements'] | Where-Object { $_['kind'] -eq 'manual' -and $_['status'] -ne 'manual_unassessed' })).Count)
    Check 'ACD static results are not counted as tests (functional total = objective + executed only)' ($acd['qwen-ref:1b']['functional']['total'] -eq 42)
    Check 'ACD records the plan, the per-question timings and the notes used' ($acd['qwen-ref:1b']['acd_run']['mode'] -eq 'units' -and $acd['qwen-ref:1b']['acd_run']['units'] -eq 49 -and $acd['qwen-ref:1b']['acd_run']['unit_ms'].Count -eq 49 -and $acd['qwen-ref:1b']['conditions']['notes_chars_available'] -gt 0)
    Check 'ACD runs record that thinking was off and the model was unloaded' ($acd['qwen-ref:1b']['conditions']['think'] -eq 'off' -and $acd['qwen-ref:1b']['acd_run']['unloads'] -ge 1 -and $acd['qwen-ref:1b']['acd_run']['requests'] -ge 49)
    $rp = Write-DropBenchReport
    $md = [System.IO.File]::ReadAllText($rp)
    Check 'report written: ranking puts the reference model first, mutant/broken below, ACD kept in its own section' ($md.Contains('## OOP (Java)') -and $md.Contains('## ACD') -and $md.IndexOf('qwen-ref:1b') -lt $md.IndexOf('qwen-mutant:1b')) $rp
    Copy-Item -LiteralPath $rp -Destination (Join-Path $PSScriptRoot 'last-report.md') -Force
    Copy-Item -LiteralPath (Get-DropBenchResultsPath) -Destination (Join-Path $PSScriptRoot 'last-results.jsonl') -Force
} finally { Stop-MockOllama $mock }
Finish-Tests
