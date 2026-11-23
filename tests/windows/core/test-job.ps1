# Background-runspace plumbing (what Drop.ps1's timer uses): an OOP run and an ACD run through Start-DropJob against the mock.
#   pwsh -NoProfile -File tests/windows/core/test-job.ps1
. (Join-Path $PSScriptRoot 'lib.ps1')
$work = Join-Path $script:TestData 'in'
New-Item -ItemType Directory -Path $work -Force | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $script:RepoRoot 'SAMPLE/01_SIMPLE_Parking/SIMPLE_Starter_Project.zip'), $work)
@'
Task 1 Implement HourlyPass.priceCents: round up partial hours, one hour minimum, reject negative stays.
Task 2 Create WeekendPass with a flat price and seed it in the repository; allQuotes sorts by price then id.
Task 3 Validate input and map IllegalArgumentException to 400 and PassNotFoundException to 404 with ApiError.
Task 4 Controller endpoints: GET quote, GET quotes and POST hourly returning HTTP 201.
'@ | Set-Content -LiteralPath (Join-Path $work 'paper.txt') -Encoding UTF8
$col = Collect-Input @($work)
$mock = Start-MockOllama 'pass' (Join-Path $script:TestData 'job.jsonl')
try {
    $p = @{ Paper = [string]$col[0]; Starter = $col[2]; Model = 'qwen-mock:1b'; Base = $mock.Base; ManualCtx = 0; PerTask = $false; Careful = $false; RamBytes = 8GB }
    $job = Start-DropJob 'oop' $p
    $sw = [Diagnostics.Stopwatch]::StartNew(); $sawStatus = $false
    while (-not (Test-DropJobDone $job) -and $sw.Elapsed.TotalSeconds -lt 120) { if ($job.Sync.Status) { $sawStatus = $true }; Start-Sleep -Milliseconds 100 }
    $r = Receive-DropJob $job
    Check 'oop job: finishes on a background runspace and returns the result hashtable' ($r.Ok -eq $true -and $r.Compiled -eq $true -and $r.Answer.Contains('HOW TO TEST')) ($r.Error)
    Check 'oop job: status text was published while it ran' $sawStatus
    # ACD through the same plumbing (mock answers objective questions; free ones get the mock text)
    $acdDir = Join-Path $script:TestData 'acdin'; New-Item -ItemType Directory -Path $acdDir -Force | Out-Null
    Copy-Item (Join-Path $script:RepoRoot 'bench-tasks/acd-mock-ict/inputs/*') $acdDir -Recurse
    $mock2 = Start-MockOllama 'acd_pass' (Join-Path $script:TestData 'job2.jsonl')
    try {
        $pa = @{ Paths = @($acdDir); Provider = 'ollama'; Model = 'qwen-mock:1b'; Base = $mock2.Base; ManualCtx = 0; RamBytes = 8GB; Careful = $false; OpenCode = $null }
        $j2 = Start-DropJob 'acd' $pa
        $sw.Restart()
        while (-not (Test-DropJobDone $j2) -and $sw.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 200 }
        $r2 = Receive-DropJob $j2
        Check 'acd job: runs in the background and returns an answer with Task / Q markers and a validation summary' ($r2.Ok -eq $true -and $r2.Result.Answer.Contains('// ===== Task 1 =====') -and (Get-AcdValidationSummary $r2.Result.Validation).Contains('Syntax')) ($r2.Error)
    } finally { Stop-MockOllama $mock2 }
    $bad = Start-DropJob 'nonsense' @{}
    $sw.Restart(); while (-not (Test-DropJobDone $bad) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    $rb = Receive-DropJob $bad
    Check 'a job that returns nothing is reported as an error, never as an empty success' ($rb.Ok -eq $false -and $rb.Error)
} finally { Stop-MockOllama $mock }
Finish-Tests
