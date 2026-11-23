# Runs the 5 baseline scenarios (pass, repair, truncated, never_fixed, http500) of the Windows pipeline against the
# scripted mock Ollama and stores answer/status/clipboard + every request in out/<label>/.
#   pwsh -NoProfile -File run-baseline.ps1 -Script <Drop.ps1> -Label <name> [-Careful] [-PythonExe python3]
# Compare two builds:  diff -r out/<a> out/<b>
# Needs python3, a JDK 17+ (javac) and the Spring/Jackson jars in %USERPROFILE%\.m2 (same as the macOS harness).
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Label,
    [switch]$Careful,
    [string]$PythonExe = 'python3',
    [string]$Starter = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '../../..')).Path
$mock = Join-Path $repo 'tests/baseline/mock_ollama.py'
if (-not $Starter) { $Starter = Join-Path $repo 'SAMPLE/01_SIMPLE_Parking/SIMPLE_Starter_Project.zip' }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('dropwin-' + [guid]::NewGuid().ToString('N'))
$in = Join-Path $work 'in'
New-Item -ItemType Directory -Path $in -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($Starter, $in)
@'
Task 1 Implement HourlyPass.priceCents: round up partial hours, one hour minimum, reject negative stays.
Task 2 Create WeekendPass with a flat price and seed it in the repository; allQuotes sorts by price then id.
Task 3 Validate input and map IllegalArgumentException to 400 and PassNotFoundException to 404 with ApiError.
Task 4 Controller endpoints: GET quote, GET quotes and POST hourly returning HTTP 201.
'@ | Set-Content -LiteralPath (Join-Path $in 'paper.txt') -Encoding UTF8
$out = Join-Path $here "out/$Label"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$port = Get-Random -Minimum 20000 -Maximum 40000
foreach ($sc in @('pass', 'repair', 'truncated', 'never_fixed', 'http500')) {
    $log = Join-Path $out "$sc.requests.jsonl"
    $spArgs = @{ FilePath = $PythonExe; ArgumentList = @($mock, $port, $sc, $log); PassThru = $true }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    $mp = Start-Process @spArgs
    Start-Sleep -Milliseconds 800
    try {
        $args2 = @('-NoProfile', '-File', (Join-Path $here 'harness.ps1'), '-Script', $Script, '-InputDir', $in,
                   '-Base', "http://127.0.0.1:$port", '-Out', (Join-Path $out "$sc.json"))
        if ($Careful) { $args2 += '-Careful' }
        $self = (Get-Process -Id $PID).Path
        & $self @args2
    } finally { Stop-Process -Id $mp.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "ran $sc"
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
