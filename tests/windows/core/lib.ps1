# Shared helpers for the Windows core tests (PowerShell 5.1 / 7). Dot-source from a test script.
$ErrorActionPreference = 'Stop'
$script:TFails = 0; $script:TTotal = 0
function Check([string]$name, $cond, $extra = '') {
    $script:TTotal++
    if (-not [bool]$cond) { $script:TFails++; Write-Host ("FAIL " + $name + " " + $extra) -ForegroundColor Red } else { Write-Host ("ok   " + $name) }
}
function Finish-Tests { Write-Host ("`n{0}/{1} passed" -f ($script:TTotal - $script:TFails), $script:TTotal); exit $(if ($script:TFails -eq 0) { 0 } else { 1 }) }
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (-not $env:USERPROFILE) { $env:USERPROFILE = $HOME }
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $script:RepoRoot 'windows/DropCore.ps1')
# the tests never touch the real app data: settings / acd / bench go to a scratch dir
$script:TestData = Join-Path ([System.IO.Path]::GetTempPath()) ('dropwin-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestData -Force | Out-Null
$env:DROP_DATA_DIR = $script:TestData
$env:DROP_ACD_DIR = Join-Path $script:TestData 'acd'
$env:DROP_BENCH_DIR = Join-Path $script:TestData 'bench'
$env:DROP_DESKTOP_DIR = Join-Path $script:TestData 'Desktop'
function Read-Fixture([string]$rel) { return [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $rel)) }
function Get-ModerateInput {
    # paper block + starter map exactly as the app builds them (Collect-Input over the task's inputs folder)
    $r = Collect-Input @((Join-Path $script:RepoRoot 'bench-tasks/moderate-dispatch/inputs'))
    return @{ Paper = [string]$r[0]; Starter = $r[2]; Count = $r[1] }
}
function Start-MockOllama([string]$scenario, [string]$log, [hashtable]$env2 = @{}) {
    $port = Get-Random -Minimum 20000 -Maximum 40000
    foreach ($k in $env2.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$env2[$k]) }
    $py = if ($env:PYTHON_EXE) { $env:PYTHON_EXE } else { 'python3' }
    $mock = Join-Path $script:RepoRoot 'tests/baseline/mock_ollama.py'
    $spArgs = @{ FilePath = $py; ArgumentList = @($mock, $port, $scenario, $log); PassThru = $true }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    $p = Start-Process @spArgs
    Start-Sleep -Milliseconds 800
    return @{ Proc = $p; Base = "http://127.0.0.1:$port"; Log = $log }
}
function Stop-MockOllama($m) { Stop-Process -Id $m.Proc.Id -Force -ErrorAction SilentlyContinue }
