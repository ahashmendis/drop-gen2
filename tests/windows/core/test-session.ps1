# Session + OOP run orchestration against the scripted mock Ollama (tests/baseline/mock_ollama.py).
#   pwsh -NoProfile -File tests/windows/core/test-session.ps1
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
$paper = [string]$col[0]; $starter = $col[2]
function Read-Log($p) { if (Test-Path $p) { return @(Get-Content $p | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { return @() } }
function Run-Scenario([string]$sc, [bool]$perTask = $false, [int64]$ram = 0) {
    $log = Join-Path $script:TestData "$sc.jsonl"
    $mock = Start-MockOllama $sc $log
    try {
        $sync = [hashtable]::Synchronized(@{ Status = '' })
        $p = @{ Paper = $paper; Starter = $starter; Model = 'qwen-mock:1b'; Base = $mock.Base; ManualCtx = 0; PerTask = $perTask; RamBytes = $(if ($ram -gt 0) { $ram } else { 8GB }) }
        $r = Invoke-DropOopRun $p $sync
        return @{ R = $r; Log = (Read-Log $log); Sync = $sync }
    } finally { Stop-MockOllama $mock }
}

# default: ONE request without thinking through the small-context session, unloaded at the end
$x = Run-Scenario 'pass'
$gen = @($x.Log | Where-Object { $_.path -eq '/api/generate' -and $_.prompt })
$unl = @($x.Log | Where-Object { $_.unload })
Check 'default OOP run: ok, compiles, no repair' ($x.R.Ok -and $x.R.Compiled -eq $true -and $x.R.RepairRounds -eq 0) ($x.R.Error)
Check 'default OOP run: ONE request, thinking OFF, keep_alive 2m during the run, stream false' ($gen.Count -eq 1 -and $gen[0].think -eq $false -and $gen[0].keep_alive -eq '2m' -and $gen[0].stream -eq $false) ($gen | ConvertTo-Json -Depth 4 -Compress)
Check 'default OOP run: context sized to prompt + numPredict (small, power of two), num_predict >= 4096' ($gen[0].options.num_ctx -le 16384 -and $gen[0].options.num_predict -ge 4096) ($gen[0].options | ConvertTo-Json -Compress)
Check 'default OOP run: the model is unloaded when the run ends (quiet laptop)' ($unl.Count -ge 1)
Check 'default OOP run: HOW TO TEST appended, answer has the Task header' ($x.R.Answer.Contains('// ===== HOW TO TEST =====') -and $x.R.Answer.Contains('// ===== Task 1 ====='))
Check 'default OOP run: the prompt starts with the unchanged Ollama header' ($gen[0].prompt.StartsWith($OllamaPromptHeader.Substring(0, 200)))

$x = Run-Scenario 'repair'
$gen = @($x.Log | Where-Object { $_.path -eq '/api/generate' -and $_.prompt })
Check 'repair scenario: one targeted repair request (no thinking, <= 4000 tokens) and it compiles' ($x.R.Compiled -eq $true -and $x.R.RepairRounds -eq 1 -and $gen.Count -eq 2 -and $gen[1].think -eq $false -and $gen[1].options.num_predict -le 4000 -and $gen[1].prompt.Contains('JAVAC ERRORS'))

$x = Run-Scenario 'never_fixed'
Check 'never_fixed: stops at the 4-round cap and reports honestly' ($x.R.Ok -and $x.R.Compiled -eq $false -and $x.R.RepairRounds -le 4 -and $x.R.RepairRounds -ge 1) "rounds=$($x.R.RepairRounds)"

# one retry on 5xx after an unload; then a clear error (never an empty answer)
$x = Run-Scenario 'http500'
$gen = @($x.Log | Where-Object { $_.path -eq '/api/generate' -and $_.prompt })
$unl = @($x.Log | Where-Object { $_.unload })
Check 'http500: the whole-paper request is retried ONCE after an unload (same prompt), then the per-task fallback also fails -> clear error, no answer' (-not $x.R.Ok -and $gen.Count -ge 2 -and $gen[0].prompt -eq $gen[1].prompt -and $gen[2].prompt -ne $gen[0].prompt -and $unl.Count -ge 2 -and $x.R.Error -match '500') "gen=$($gen.Count) unl=$($unl.Count) err=$($x.R.Error)"

# unload at memory pressure: resident size from /api/ps (mock reports 1234 bytes) above 60% of RAM
$x = Run-Scenario 'pass' $false 1000
$unl = @($x.Log | Where-Object { $_.unload })
Check 'memory pressure: model unloaded BEFORE the request when it outgrew 60% of RAM (plus the final unload)' ($unl.Count -ge 2) "unloads=$($unl.Count)"

# per-task path (opt-in): one request per task, thinking off, same pipeline after
$x = Run-Scenario 'pertask' $true
$gen = @($x.Log | Where-Object { $_.path -eq '/api/generate' -and $_.prompt })
Check 'per-task run: one request per task (4), thinking off, compiles' ($x.R.Ok -and $gen.Count -eq 4 -and -not ($gen | Where-Object { $_.think }) -and $x.R.Compiled -eq $true) "gen=$($gen.Count) compiled=$($x.R.Compiled) err=$($x.R.Error)"

# oversized request: blocked with a pointer to Settings, never truncated
$s = New-DropSession 'http://127.0.0.1:1' 'm' 0 (8GB)
$big = Invoke-DropSessionGenerate $s (New-DropRequest ('x' * 200000) 'big' 'whole' 4096 0.2 $false)
Check 'oversized prompt: blocked with a Settings hint, no request sent' ($big.Error -and $big.Error.Contains('raise Qwen ctx in Settings') -and $s.RequestCount -eq 0) $big.Error
Finish-Tests
