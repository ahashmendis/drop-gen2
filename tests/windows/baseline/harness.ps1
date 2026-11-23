# Characterization harness for the Windows Drop pipeline (Drop.ps1), driven headless against mock_ollama.py.
# It does NOT start the WinForms app: it extracts (by AST) the functions, prompt headers, a few settings and the
# generation timer's tick block from the script under test, stubs the UI / clipboard, calls Start-Answer on an input
# folder and ticks the timer block until the run ends. The same harness therefore measures the ORIGINAL Drop.ps1
# (git show <rev>:windows/Drop.ps1) and the ported one, and their outputs can be diffed.
#
#   pwsh -NoProfile -File harness.ps1 -Script <Drop.ps1> -InputDir <dir> -Base http://127.0.0.1:PORT -Out out.json [-Careful]
#
# Runs on Windows PowerShell 5.1 and PowerShell 7 (also macOS/Linux pwsh: the only OS shim is the classpath separator).
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$InputDir,
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$Out,
    [switch]$Careful
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not $env:USERPROFILE) { $env:USERPROFILE = $HOME }     # non-Windows hosts

# text of a dot-sourced helper file; its own `. (Join-Path $PSScriptRoot 'x.ps1')` lines are inlined recursively
function Get-HarnessFileText([string]$path) {
    $dir = Split-Path -Parent $path
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllText($path).Split("`n")) {
        if ($line -match '^\.\s+\(Join-Path \$PSScriptRoot ''([^'']+\.ps1)''\)\s*$') { $out.Add((Get-HarnessFileText (Join-Path $dir $Matches[1]))) }
        else { $out.Add($line) }
    }
    return ($out -join "`n")
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script).Path, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) { throw ("parse errors in $Script : " + ($errors | ForEach-Object { $_.Message } | Select-Object -First 3) -join '; ') }

$keepVars = @('SkipDirs', 'TextExt', 'DocExt', 'PromptHeader', 'ReviewHeader', 'OllamaPromptHeader', 'OllamaReviewHeader', 'OllamaRepairHeader', 'RepairHeader')
$parts = New-Object System.Collections.Generic.List[string]
$tick = $null
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $parts.Add($st.Extent.Text); continue }
    if ($st -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $left = $st.Left.Extent.Text.TrimStart('$')
        if ($keepVars -contains $left) { $parts.Add($st.Extent.Text) }
        continue
    }
    if ($st -is [System.Management.Automation.Language.PipelineAst]) {
        $t = $st.Extent.Text
        if ($t -match '^\$timer\.Add_Tick') {
            $sb = $st.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
            if ($sb) { $tick = $sb.Extent.Text }
        }
        elseif ($t -match '^\.\s+\(Join-Path \$PSScriptRoot ''([^'']+\.ps1)''\)') {
            # dot-sourced helper file of the ported script: load its whole text (it is UI-free by contract)
            $parts.Add((Get-HarnessFileText (Join-Path (Split-Path -Parent (Resolve-Path $Script).Path) $Matches[1])))
        }
    }
}
if (-not $tick) { throw 'timer tick block not found' }
$body = ($parts -join "`n`n")
# shims: the UI calls the harness replaces, and the OS-specific classpath separator
$body = $body.Replace('[System.Windows.Forms.Clipboard]::SetText', 'Set-HarnessClipboard')
$body = $body.Replace('[System.Media.SystemSounds]::Asterisk.Play()', '$null')
$body = $body.Replace("-join ';'", "-join [System.IO.Path]::PathSeparator").Replace("+ ';' +", "+ [System.IO.Path]::PathSeparator +")
$tick = $tick.Replace('[System.Windows.Forms.Clipboard]::SetText', 'Set-HarnessClipboard').Replace('[System.Media.SystemSounds]::Asterisk.Play()', '$null')

$script:HarnessClip = ''
$script:HarnessStatus = ''
function Set-HarnessClipboard([string]$t) { $script:HarnessClip = $t }
# a dot-sourced helper next to the script under test (ported build): resolve relative to the script
$env:DROP_HARNESS_ROOT = (Split-Path -Parent (Resolve-Path $Script).Path)
$body = $body.Replace('$PSScriptRoot', "'" + $env:DROP_HARNESS_ROOT + "'")
$tick = $tick.Replace('$PSScriptRoot', "'" + $env:DROP_HARNESS_ROOT + "'")

. ([scriptblock]::Create($body))

# ---- stubs (defined AFTER the extracted functions so they win) ----
$script:Config = [pscustomobject]@{
    provider = 'ollama'
    ollama = [pscustomobject]@{ base_url = $Base; default_model = ''; context = 0 }
    opencode_go = [pscustomobject]@{ base_url = ''; api_key = ''; model = '' }
    network = [pscustomobject]@{ connect_timeout = 5; stream_idle_timeout = 120; retry_attempts = 3; retry_backoff = $true }
    preferences = [pscustomobject]@{ remember_provider = $true; allow_fallback = $false }
}
$OllamaUrl = $Base
$script:Provider = 'ollama'
$script:Model = 'qwen-mock:1b'
$script:Running = $false
$script:LastAnswer = ''
$script:Task = $null
$script:Attempt = 0
$script:RamGB = 8
$box = [pscustomobject]@{ Text = '' }
$form = [pscustomobject]@{ Visible = $true }
function Set-Status([string]$s) { $script:HarnessStatus = $s }
function Show-Notice([string]$msg) { $script:HarnessStatus = $msg }
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(5)
$ollamaClient = New-Object System.Net.Http.HttpClient
$ollamaClient.Timeout = [TimeSpan]::FromMinutes(5)
. ([scriptblock]::Create('$script:TickBlock = ' + $tick))
$script:Subject = 'oop'; $script:LastAnswerACD = ''; $script:Job = $null
# settings live in a scratch dir; -Careful turns the original (thinking) request on, otherwise the ported build runs its new default
$env:DROP_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ('dropwin-harness-' + [guid]::NewGuid().ToString('N'))
if (Get-Command Set-DropSetting -ErrorAction SilentlyContinue) { Set-DropSetting 'acdCareful' ([bool]$Careful) }

Start-Answer @((Resolve-Path $InputDir).Path)
$deadline = (Get-Date).AddMinutes(10)
while ($script:Running -and (Get-Date) -lt $deadline) {
    & $script:TickBlock
    Start-Sleep -Milliseconds 100
}
$o = [ordered]@{
    clipboard    = $script:HarnessClip
    lastAnswer   = $script:LastAnswer
    status       = $script:HarnessStatus
    stillRunning = [bool]$script:Running
}
$o | ConvertTo-Json | Set-Content -LiteralPath $Out -Encoding UTF8
