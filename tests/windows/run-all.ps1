# Runs every Windows-port test. Works on Windows PowerShell 5.1, PowerShell 7 (Windows) and PowerShell 7 on macOS/Linux.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run-all.ps1
#   pwsh -NoProfile -File tests/windows/run-all.ps1
# Needs: python3 (mock Ollama; set $env:PYTHON_EXE on Windows if it is `python`), a JDK 17+ and the Spring/Jackson jars in
# %USERPROFILE%\.m2 (javac + Java checks), node (ACD checks). $env:ACD_TEST_NODE_MODULES = a node_modules with react/vite/typescript
# (the build/type-check cases are skipped without it). Nothing touches the real Drop settings, clipboard or Ollama models.
param([string]$Only = '')
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$self = (Get-Process -Id $PID).Path
$repo = (Resolve-Path (Join-Path $here '../..')).Path
$ps1 = Join-Path $repo 'windows/Drop.ps1'
$suites = @(
    @{ Name = 'parse (all ported files, no syntax errors)'; Run = {
        $bad = 0
        foreach ($f in (Get-ChildItem (Join-Path $repo 'windows') -Filter *.ps1)) {
            $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            if ($e.Count -gt 0) { $bad++; Write-Host "FAIL $($f.Name): $($e[0].Message)" } else { Write-Host "ok   $($f.Name)" }
        }
        exit $bad } }
    @{ Name = 'oop (fixers, javac, pipeline, per-task, MODERATE 29/36 -> 36/36)'; File = 'core/test-oop.ps1' }
    @{ Name = 'session (small-context Ollama session, unload, 5xx retry, run orchestration)'; File = 'core/test-session.ps1' }
    @{ Name = 'acd (parser, notes, planner, fixers, validators, pipeline, safety)'; File = 'core/test-acd.ps1' }
    @{ Name = 'background jobs (runspace plumbing used by the timer)'; File = 'core/test-job.ps1' }
    @{ Name = 'benchmark end-to-end (3 mock models x 3 OOP tasks + ACD mock ICT, report)'; File = 'bench/run-bench-e2e.ps1' }
)
$fails = 0
foreach ($s in $suites) {
    if ($Only -and $s.Name -notlike "*$Only*") { continue }
    Write-Host "`n=== $($s.Name) ===" -ForegroundColor Cyan
    if ($s.Run) { & $self -NoProfile -Command (' & { ' + $s.Run.ToString().Replace('$repo', "'" + $repo + "'").Replace('$here', "'" + $here + "'") + ' }') }
    else { & $self -NoProfile -File (Join-Path $here $s.File) }
    if ($LASTEXITCODE -ne 0) { $fails++; Write-Host "SUITE FAILED: $($s.Name)" -ForegroundColor Red }
}
# characterization: the ORIGINAL thinking request (Careful mode) must stay identical to the original Drop.ps1 (git show <rev>:windows/Drop.ps1)
Write-Host "`n=== baseline harness: see tests/windows/README.md (needs the original Drop.ps1 for the diff) ===" -ForegroundColor Cyan
if ($fails -gt 0) { Write-Host "`n$fails suite(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall suites passed" -ForegroundColor Green
