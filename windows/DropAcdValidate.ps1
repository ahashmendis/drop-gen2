# DropAcdValidate.ps1 - ACD validation (syntax / static / build / tests, reported separately), tool discovery, process
# running and the user-triggered toolchain preparation. Dot-sourced by DropCore.ps1. Definitions only.
# syntax = it parses (node --check, TypeScript syntactic diagnostics, JSON); static = rule-based inspection (HTML
# structure/accessibility, Bootstrap structure, CSS balance, missing hook/router imports); build = tsc --noEmit +
# vite build on the STARTER's own configuration (needs dependencies); tests = the starter's own `test` script.
# A syntax or static pass is never functional correctness; the summary always says what was NOT verified.

function Test-DropWindows { if ($PSVersionTable.PSEdition -eq 'Core') { return [bool]$IsWindows } else { return $true } }
function Test-DropMac { if ($PSVersionTable.PSEdition -eq 'Core') { return [bool]$IsMacOS } else { return $false } }

# canonical path (no symlinks): a macOS sandbox rule would not match /var vs /private/var
function Get-AcdRealPath([string]$p) {
    if (Test-DropMac) {
        try { $r = (& /bin/realpath $p 2>$null); if ($r) { return [string]$r } } catch { }
    }
    return $p
}

function Find-AcdTool([string]$name) {
    $dirs = @()
    if (Test-DropWindows) {
        $dirs += @("$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\nodejs", "$env:APPDATA\npm", "$env:LOCALAPPDATA\Volta\bin", $env:NVM_SYMLINK)
        if ($env:APPDATA -and (Test-Path "$env:APPDATA\nvm")) {
            foreach ($d in (Get-ChildItem "$env:APPDATA\nvm" -Directory -Filter 'v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) { $dirs += $d.FullName }
        }
        $exts = @('.exe', '.cmd', '.bat', '')
    } else {
        $h = $HOME
        $dirs += @('/usr/local/bin', '/opt/homebrew/bin', '/usr/bin', "$h/.volta/bin")
        if (Test-Path "$h/.nvm/versions/node") { foreach ($d in (Get-ChildItem "$h/.nvm/versions/node" -Directory | Sort-Object Name -Descending)) { $dirs += "$($d.FullName)/bin" } }
        $exts = @('')
    }
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        foreach ($e in $exts) { $c = Join-Path $d ($name + $e); if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
function Get-AcdToolchainNM {
    $u = Join-Path (Join-Path (Get-DropAcdDir) 'toolchain') 'node_modules'
    if (Test-Path -LiteralPath $u -PathType Container) { return $u }
    return $null
}

function ConvertTo-DropArgString([string[]]$a) {
    return (($a | ForEach-Object {
        $s = [string]$_
        if ($s -eq '') { '""' }
        elseif ($s -match '[\s"]') { '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
        else { $s }
    }) -join ' ')
}

# Runs a process with a timeout. -> @{ Status; Output (stdout+stderr); TimedOut }
function Invoke-DropProcess([string]$exe, [string[]]$argList, [string]$cwd, [int]$timeoutSec = 60, $envVars = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -match '\.(cmd|bat)$') {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/d /s /c "' + (ConvertTo-DropArgString (@($exe) + $argList)) + '"'
    } else {
        $psi.FileName = $exe
        $psi.Arguments = ConvertTo-DropArgString $argList
    }
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in @($envVars.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$envVars[$k] }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch { return @{ Status = -1; Output = "cannot start ${exe}: $($_.Exception.Message)"; TimedOut = $false } }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        $timedOut = $true
        try {
            if (Test-DropWindows) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } else { $p.Kill() }
        } catch { try { $p.Kill() } catch { } }
        [void]$p.WaitForExit(5000)
    } else { $p.WaitForExit() }
    return @{ Status = $(if ($timedOut) { -1 } else { $p.ExitCode }); Output = ($o.Result + $e.Result); TimedOut = $timedOut }
}

# Node major version (for the permission-model sandbox on Windows); 0 when unknown.
function Get-AcdNodeMajor([string]$node) {
    try { $r = Invoke-DropProcess $node @('--version') '' 15; $m = [regex]::Match($r.Output, 'v(\d+)\.'); if ($m.Success) { return [int]$m.Groups[1].Value } } catch { }
    return 0
}

# Runs a tool with limited blast radius. macOS: sandbox-exec (no network, writes only to -Writable). Windows: if the
# tool is node and the permission model exists (Node 22+; 20 with the experimental flag), file writes outside the temp
# folder and child processes are denied (the network is NOT blocked before Node 25); otherwise @{ Unavailable = $true }.
# Calls that do not execute model code pass -ExecutesModelCode:$false and run plainly on Windows.
function Invoke-AcdTool([string]$exe, [string[]]$argList, [string]$cwd, [string[]]$writable, [int]$timeoutSec, [bool]$executesModelCode = $true, $extraEnv = @{}) {
    $envVars = @{ CI = '1'; NO_COLOR = '1'; FORCE_COLOR = '0'; npm_config_update_notifier = 'false' }
    $tmpDir = Join-Path $cwd '.tmp'
    [void](New-Item -ItemType Directory -Path $tmpDir -Force)
    $envVars['TMPDIR'] = $tmpDir; $envVars['TEMP'] = $tmpDir; $envVars['TMP'] = $tmpDir
    $envVars['npm_config_cache'] = (Join-Path $cwd '.npm')
    foreach ($k in @($extraEnv.Keys)) { $envVars[$k] = $extraEnv[$k] }
    if (Test-DropMac) {
        $rules = '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper")'
        foreach ($w in $writable) { if ($w -and -not $w.Contains('"')) { $rules += " (subpath ""$w"")" } }
        $rules += ')'
        $profile = '(version 1)(allow default)(deny network*)(deny file-write*)' + $rules
        $node = Find-AcdTool 'node'
        if ($node) { $envVars['PATH'] = (Split-Path -Parent $node) + ':/usr/bin:/bin' }
        return (Invoke-DropProcess '/usr/bin/sandbox-exec' (@('-p', $profile, $exe) + $argList) $cwd $timeoutSec $envVars)
    }
    if (-not $executesModelCode) { return (Invoke-DropProcess $exe $argList $cwd $timeoutSec $envVars) }
    $isNode = ([System.IO.Path]::GetFileNameWithoutExtension($exe) -eq 'node')
    if ($isNode -and -not ($env:DROP_ACD_NO_NODE_SANDBOX)) {
        $major = Get-AcdNodeMajor $exe
        if ($major -ge 20) {
            $flag = if ($major -ge 22) { '--permission' } else { '--experimental-permission' }
            $perm = @($flag, "--allow-fs-read=$cwd", "--allow-fs-write=$cwd")
            foreach ($w in $writable) { if ($w -and $w -ne $cwd) { $perm += "--allow-fs-write=$w" } }
            return (Invoke-DropProcess $exe ($perm + $argList) $cwd $timeoutSec $envVars)
        }
    }
    return @{ Status = -1; Output = 'no sandbox available on this machine (Node 22+ permission model needed)'; TimedOut = $false; Unavailable = $true }
}

# ---- static: HTML --------------------------------------------------------------------------------------------------
$script:AcdVoidTags = @('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr', '!doctype')
$script:AcdOptionalEnd = @('p', 'li', 'td', 'th', 'tr', 'thead', 'tbody', 'tfoot', 'option', 'dt', 'dd', 'html', 'body', 'head')
function Get-AcdHtmlFindings([string]$src) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.List[string]
    $headings = New-Object System.Collections.Generic.List[int]
    $skipUntil = $null
    $inputs = 0; $labels = 0; $imgNoAlt = 0
    foreach ($m in [regex]::Matches($src, '<(!--[\s\S]*?--|/?([a-zA-Z][a-zA-Z0-9-]*)([^>]*?)(/?))>')) {
        $whole = $m.Value
        if ($whole.StartsWith('<!--')) { continue }
        $closing = $whole.StartsWith('</')
        $name = if ($m.Groups[2].Success) { $m.Groups[2].Value.ToLowerInvariant() } else { '' }
        if ($null -ne $skipUntil) {
            if ($closing -and $name -eq $skipUntil) { $skipUntil = $null; if ($stack.Count -gt 0 -and $stack[$stack.Count - 1] -eq $name) { $stack.RemoveAt($stack.Count - 1) } }
            continue
        }
        if ($name -eq '') { continue }
        if (-not $closing -and ($name -eq 'script' -or $name -eq 'style') -and -not $whole.EndsWith('/>')) { $skipUntil = $name; $stack.Add($name); continue }
        $lw = $whole.ToLowerInvariant()
        if ($name -eq 'input') { if (-not $lw.Contains('type="hidden"') -and -not $lw.Contains('type="submit"') -and -not $lw.Contains('type="button"')) { $inputs++ } }
        if ($name -eq 'img' -and -not $closing -and -not $whole.Contains('alt=')) { $imgNoAlt++ }
        if ($name -eq 'label' -and -not $closing) { $labels++ }
        if (-not $closing -and $whole.Contains('aria-label')) { $labels++ }
        if (-not $closing -and $name.Length -eq 2 -and $name.StartsWith('h') -and [char]::IsDigit($name[1]) -and [int]$name.Substring(1) -ge 1 -and [int]$name.Substring(1) -le 6) { $headings.Add([int]$name.Substring(1)) }
        if (($script:AcdVoidTags -contains $name) -or $whole.EndsWith('/>')) { continue }
        if ($closing) {
            $i = $stack.LastIndexOf($name)
            if ($i -ge 0) {
                for ($j = $i + 1; $j -lt $stack.Count; $j++) { if ($script:AcdOptionalEnd -notcontains $stack[$j]) { $errors.Add("<$($stack[$j])> is not closed before </$name>") } }
                $stack.RemoveRange($i, $stack.Count - $i)
            } else { $errors.Add("unexpected closing tag </$name>") }
        } else { $stack.Add($name) }
    }
    foreach ($s in $stack) { if ($script:AcdOptionalEnd -notcontains $s) { $errors.Add("<$s> is never closed") } }
    $lower = $src.ToLowerInvariant()
    if ($lower.Contains('<html')) {
        if (-not $lower.Contains('<!doctype html')) { $warnings.Add('missing <!DOCTYPE html>') }
        if (-not $lower.Contains('lang=')) { $warnings.Add('<html> has no lang attribute') }
        if (-not $lower.Contains('<title')) { $warnings.Add('missing <title>') }
    }
    if ($imgNoAlt -gt 0) { $warnings.Add("$imgNoAlt <img> without alt") }
    if ($inputs -gt 0 -and $labels -eq 0) { $warnings.Add('form inputs without any <label> or aria-label') }
    $prev = 0
    foreach ($h in $headings) { if ($prev -gt 0 -and $h -gt $prev + 1) { $warnings.Add("heading level jumps from h$prev to h$h"); break }; $prev = $h }
    if ($lower.Contains('data-bs-') -and -not $lower.Contains('bootstrap')) { $warnings.Add('data-bs-* attributes used but Bootstrap JS is not loaded') }
    if ($lower.Contains('class="col') -and -not $lower.Contains('class="row') -and -not $lower.Contains('class="container')) { $warnings.Add('Bootstrap .col used outside a .row/.container') }
    return @{ Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
}
function Get-AcdCssFindings([string]$src) {
    $errors = @()
    $s = $src
    while ($true) {
        $a = $s.IndexOf('/*')
        if ($a -lt 0) { break }
        $b = $s.IndexOf('*/', $a + 2)
        if ($b -lt 0) { $errors += 'unterminated /* comment'; $s = $s.Substring(0, $a); break }
        $s = $s.Remove($a, $b + 2 - $a)
    }
    $open = ($s.ToCharArray() | Where-Object { $_ -eq '{' }).Count
    $close = ($s.ToCharArray() | Where-Object { $_ -eq '}' }).Count
    if ($open -ne $close) { $errors += "unbalanced braces: $open '{' vs $close '}'" }
    return $errors
}
function Get-AcdImportFindings([string]$src) {
    $out = @()
    foreach ($rule in $script:AcdImportRules) {
        foreach ($n in $rule.Names) { if (Test-AcdNameUsedNotImported $src $n) { $out += "$n is used but not imported from $($rule.Pkgs[0])" } }
    }
    return $out
}

# ---- validation result helpers ---------------------------------------------------------------------------------------
function New-AcdCheck([string]$name, [string]$status, [string]$detail, [int]$failures = 0, [int]$warnings = 0, [int]$ms = 0) {
    return @{ Name = $name; Status = $status; Detail = $detail; Failures = $failures; Warnings = $warnings; Ms = $ms }
}
function Get-AcdCheck($v, [string]$name) { foreach ($c in $v.Checks) { if ($c.Name -eq $name) { return $c } }; return $null }
function Get-AcdFailureCount($v) { $n = 0; foreach ($c in $v.Checks) { $n += [int]$c.Failures }; return $n }
function Get-AcdErrorText($v) { return ((@($v.Checks | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { "[$($_.Name)]`n" + $_.Detail })) -join "`n`n") }
function Get-AcdValidationSummary($v) {
    if (-not (@($v.Checks | Where-Object { $_.Status -ne 'not_run' }).Count)) { return 'no code files to validate' }
    $mark = {
        param($c)
        if ($null -eq $c) { return '-' }
        switch ($c.Status) {
            'pass' { if ($c.Warnings -gt 0) { return "ok ($($c.Warnings) warning$(if ($c.Warnings -eq 1) { '' } else { 's' }))" } else { return 'ok' } }
            'fail' { return "FAIL ($($c.Failures))" }
            'unavailable' { return 'n/a' }
            default { return '-' }
        }
    }
    $dot = ' ' + [char]0x00B7 + ' '
    $s = ('Syntax ' + (& $mark (Get-AcdCheck $v 'syntax')) + $dot + 'Static ' + (& $mark (Get-AcdCheck $v 'static')) + $dot + 'Build ' + (& $mark (Get-AcdCheck $v 'build')) + $dot + 'Tests ' + (& $mark (Get-AcdCheck $v 'tests')))
    $tc = Get-AcdCheck $v 'tests'
    if ($tc -and $tc.Status -eq 'pass') { return $s }
    return $s + ' - behaviour NOT verified (no functional tests ran)'
}
function ConvertTo-AcdValidationJson($v) {
    return @($v.Checks | ForEach-Object { @{ name = $_.Name; status = $_.Status; failures = $_.Failures; warnings = $_.Warnings; ms = $_.Ms; detail = $(if ($_.Detail.Length -gt 1500) { $_.Detail.Substring(0, 1500) } else { $_.Detail }) } })
}

$script:AcdProtectedNames = @('package.json', 'package-lock.json', 'tsconfig', 'vite.config', 'eslint.config', '.env', 'vitest.config')

# $files = the answer's files (path -> code). $starter = the starter project's files. -> @{ Checks }
function Invoke-AcdValidate($files, $starter, [string]$projectRoot) {
    $nowMs = { [int64]([DateTime]::UtcNow.Ticks / 10000) }
    if ($null -eq $starter) { $starter = @{} }
    $tmpRaw = Join-Path ([System.IO.Path]::GetTempPath()) ('dropacd-v-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmpRaw -Force)
    $tmp = Get-AcdRealPath $tmpRaw
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $linked = $false
    try {
        $hasPkg = $starter.ContainsKey('package.json')
        $ignored = @()
        $write = {
            param($rel, $text)
            $u = Join-Path $tmp $rel
            $dir = Split-Path -Parent $u
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [System.IO.File]::WriteAllText($u, [string]$text, $utf8)
        }
        foreach ($k in @($starter.Keys)) { & $write $k $starter[$k] }
        foreach ($k in @($files.Keys)) {
            $leaf = [System.IO.Path]::GetFileName([string]$k)
            $isProt = $false
            foreach ($pn in $script:AcdProtectedNames) { if ($leaf.StartsWith($pn)) { $isProt = $true; break } }
            if ($hasPkg -and $isProt) { $ignored += [string]$k; continue }
            & $write $k $files[$k]
        }
        $node = Find-AcdTool 'node'
        $nm = $null
        if ($projectRoot -and (Test-Path -LiteralPath (Join-Path $projectRoot 'node_modules') -PathType Container)) { $nm = Get-AcdRealPath (Join-Path $projectRoot 'node_modules') }
        else { $t = Get-AcdToolchainNM; if ($t) { $nm = Get-AcdRealPath $t } }
        if ($nm) {
            $link = Join-Path $tmp 'node_modules'
            try {
                if (Test-DropWindows) { [void](New-Item -ItemType Junction -Path $link -Target $nm) } else { [void](New-Item -ItemType SymbolicLink -Path $link -Target $nm) }
                $linked = $true
            } catch { $nm = $null }
        }
        $checks = New-Object System.Collections.Generic.List[object]
        $paths = Get-DropSortedKeys $files.Keys
        $strip = { param($s) return (($s -replace [regex]::Escape($tmp + '/'), '') -replace [regex]::Escape($tmp + '\'), '') }

        # ===== syntax =====
        $t0 = & $nowMs
        $synErr = @(); $synUnavail = @(); $synChecked = 0; $tsFiles = @()
        $tsPath = if ($nm) { Join-Path $nm 'typescript/lib/typescript.js' } else { $null }
        foreach ($p in $paths) {
            $ext = [System.IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()
            $full = Join-Path $tmp $p
            if (@('js', 'mjs', 'cjs') -contains $ext) {
                if (-not $node) { $synUnavail += "$p (node not found)"; continue }
                $r = Invoke-AcdTool $node @('--check', $full) $tmp @($tmp) 30 $false
                $synChecked++
                if ($r.Status -ne 0) { $synErr += ($p + ': ' + ((((& $strip $r.Output) -split "`n") | Select-Object -First 6) -join ' | ')) }
            } elseif (@('ts', 'tsx', 'jsx') -contains $ext) { $tsFiles += $p }
            elseif ($ext -eq 'json') {
                $synChecked++
                try { $null = ([string]$files[$p]) | ConvertFrom-Json -ErrorAction Stop } catch { $synErr += "${p}: invalid JSON" }
            }
        }
        if ($tsFiles.Count -gt 0) {
            if ($node -and $tsPath -and (Test-Path -LiteralPath $tsPath)) {
                $script = @'
const ts = require(process.argv[2]); const fs = require('fs'); let bad = 0;
for (const f of process.argv.slice(3)) {
  const r = ts.transpileModule(fs.readFileSync(f, 'utf8'), { reportDiagnostics: true, fileName: f,
    compilerOptions: { jsx: ts.JsxEmit.Preserve, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } });
  for (const d of (r.diagnostics || [])) {
    const pos = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : { line: 0, character: 0 };
    console.log(f + ':' + (pos.line + 1) + ':' + (pos.character + 1) + ' ' + ts.flattenDiagnosticMessageText(d.messageText, ' ')); bad++; } }
process.exit(bad ? 1 : 0);
'@
                & $write '.drop-syntax.cjs' $script
                $args2 = @((Join-Path $tmp '.drop-syntax.cjs'), $tsPath) + @($tsFiles | ForEach-Object { Join-Path $tmp $_ })
                $r = Invoke-AcdTool $node $args2 $tmp @($tmp) 60 $false
                $synChecked += $tsFiles.Count
                if ($r.Status -ne 0) { $synErr += @(((& $strip $r.Output) -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 12)) }
            } else { $synUnavail += (($tsFiles -join ', ') + ' (TypeScript is not installed: run Prepare ACD toolchain)') }
        }
        $ms = (& $nowMs) - $t0
        if ($synErr.Count -gt 0) { $checks.Add((New-AcdCheck 'syntax' 'fail' ($synErr -join "`n") $synErr.Count 0 $ms)) }
        elseif ($synUnavail.Count -gt 0) { $checks.Add((New-AcdCheck 'syntax' 'unavailable' ('not checked: ' + ($synUnavail -join '; ') + $(if ($synChecked -gt 0) { " $([char]0x00B7) $synChecked other file(s) parsed fine" } else { '' })) 0 0 $ms)) }
        elseif ($synChecked -eq 0) { $checks.Add((New-AcdCheck 'syntax' 'not_run' 'no JS/TS/JSON files in the answer')) }
        else { $checks.Add((New-AcdCheck 'syntax' 'pass' "$synChecked file(s) parse without syntax errors" 0 0 $ms)) }

        # ===== static =====
        $t0 = & $nowMs
        $stErr = @(); $stWarn = @(); $stChecked = 0
        foreach ($p in $paths) {
            $ext = [System.IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()
            $text = [string]$files[$p]
            if (@('html', 'htm') -contains $ext) { $stChecked++; $f = Get-AcdHtmlFindings $text; $stErr += @($f.Errors | ForEach-Object { "${p}: $_" }); $stWarn += @($f.Warnings | ForEach-Object { "${p}: $_" }) }
            elseif (@('css', 'scss') -contains $ext) { $stChecked++; $stErr += @(Get-AcdCssFindings $text | ForEach-Object { "${p}: $_" }) }
            elseif (@('js', 'jsx', 'ts', 'tsx', 'mjs') -contains $ext) { $stChecked++; $stErr += @(Get-AcdImportFindings $text | ForEach-Object { "${p}: $_" }) }
        }
        $stDetail = ((@($stErr) + @($stWarn | ForEach-Object { 'warning: ' + $_ })) -join "`n")
        if ($ignored.Count -gt 0) { $stDetail += "`nnote: ignored $($ignored -join ', ') (build configuration comes from the starter project)" }
        $ms = (& $nowMs) - $t0
        if ($stErr.Count -gt 0) { $checks.Add((New-AcdCheck 'static' 'fail' $stDetail $stErr.Count $stWarn.Count $ms)) }
        elseif ($stChecked -eq 0) { $checks.Add((New-AcdCheck 'static' 'not_run' 'no HTML/CSS/JS/TS files to inspect')) }
        else { $checks.Add((New-AcdCheck 'static' 'pass' $(if ($stDetail -eq '') { "$stChecked file(s) inspected, no findings" } else { $stDetail }) 0 $stWarn.Count $ms)) }

        # ===== build (starter project's own configuration) =====
        $t0 = & $nowMs
        $writableB = @($tmp)
        if ($nm) { foreach ($d in @('.vite', '.vite-temp', '.cache', '.tmp')) { $writableB += (Join-Path $nm $d) } }
        if (-not $hasPkg) {
            $checks.Add((New-AcdCheck 'build' 'not_run' 'no starter project (package.json) to build against'))
        } elseif (-not $node -or -not $nm -or -not $tsPath -or -not (Test-Path -LiteralPath $tsPath)) {
            $checks.Add((New-AcdCheck 'build' 'unavailable' 'dependencies not installed for this project (use Prepare ACD toolchain, or install them in the starter folder)'))
        } else {
            $log = ''; $failed = $false
            $tsc = Join-Path $nm 'typescript/bin/tsc'
            $cfg = if ($starter.ContainsKey('tsconfig.app.json')) { 'tsconfig.app.json' } elseif ($starter.ContainsKey('tsconfig.json')) { 'tsconfig.json' } else { $null }
            if ($cfg) {
                $r = Invoke-AcdTool $node @($tsc, '-p', $cfg, '--noEmit') $tmp $writableB 180 $false
                if ($r.Status -ne 0) { $failed = $true; $log += "tsc ($cfg):`n" + ((((& $strip $r.Output) -split "`n") | Select-Object -First 40) -join "`n") + "`n" }
            }
            $vite = Join-Path $nm 'vite/bin/vite.js'
            if (-not $failed -and (Test-Path -LiteralPath $vite) -and $starter.ContainsKey('index.html')) {
                $r = Invoke-AcdTool $node @($vite, 'build', '--outDir', (Join-Path $tmp '.out'), '--emptyOutDir') $tmp $writableB 240 $false
                if ($r.Status -ne 0) { $failed = $true; $log += "vite build:`n" + ((((& $strip $r.Output) -split "`n") | Select-Object -First 40) -join "`n") + "`n" }
            }
            $ms = (& $nowMs) - $t0
            if (-not $cfg -and -not (Test-Path -LiteralPath $vite)) { $checks.Add((New-AcdCheck 'build' 'not_run' 'the starter has neither a tsconfig nor Vite')) }
            else { $checks.Add((New-AcdCheck 'build' $(if ($failed) { 'fail' } else { 'pass' }) $(if ($failed) { $log } else { "type-check and bundle succeeded on the starter's configuration" }) $(if ($failed) { 1 } else { 0 }) 0 $ms)) }
        }

        # ===== tests (the starter's own test script) =====
        $t0 = & $nowMs
        $hasTest = $false
        if ($hasPkg) {
            try { $pj = $starter['package.json'] | ConvertFrom-Json; if ($pj.scripts -and $pj.scripts.test) { $hasTest = $true } } catch { }
        }
        if ($hasTest) {
            $npm = Find-AcdTool 'npm'
            if ($npm -and $nm) {
                $r = Invoke-AcdTool $npm @('test', '--silent') $tmp $writableB 240 $true
                if ($r.Unavailable) {
                    $checks.Add((New-AcdCheck 'tests' 'unavailable' ("the starter's tests execute generated code and this machine has no sandbox for that: " + $r.Output)))
                } else {
                    $out = ((& $strip $r.Output) -split "`n" | Select-Object -Last 40) -join "`n"
                    $okT = ($r.Status -eq 0 -and -not $r.TimedOut)
                    $checks.Add((New-AcdCheck 'tests' $(if ($okT) { 'pass' } else { 'fail' }) $(if ($r.TimedOut) { 'timed out' } else { $out }) $(if ($okT) { 0 } else { 1 }) 0 ((& $nowMs) - $t0)))
                }
            } else { $checks.Add((New-AcdCheck 'tests' 'unavailable' 'npm or project dependencies not available')) }
        } else {
            $checks.Add((New-AcdCheck 'tests' 'not_run' 'the starter project defines no test script'))
        }
        return @{ Checks = $checks.ToArray() }
    } finally {
        if ($linked) { try { [System.IO.Directory]::Delete((Join-Path $tmp 'node_modules')) } catch { } }   # remove the LINK only, never its target
        Remove-Item -LiteralPath $tmpRaw -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- user-triggered toolchain install (never automatic) ----------------------------------------------------------------
function Find-AcdPackageJson {
    $root = Join-Path (Get-DropDesktopDir) 'ACD'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $best = $null
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'package.json' -ErrorAction SilentlyContinue)) {
        if ($f.FullName -match '[\\/]node_modules[\\/]') { continue }
        if (-not $best -or $f.FullName.Length -lt $best.Length) { $best = $f.FullName }
    }
    return $best
}
# Runs `npm ci` / `npm install` in the toolchain folder. Only ever called after the user confirmed it.
function Install-AcdToolchain([string]$packageJson) {
    $npm = Find-AcdTool 'npm'
    if (-not $npm) { return @{ Ok = $false; Output = 'npm was not found (install Node.js first)' } }
    $dir = Join-Path (Get-DropAcdDir) 'toolchain'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    Copy-Item -LiteralPath $packageJson -Destination (Join-Path $dir 'package.json') -Force
    $lock = Join-Path (Split-Path -Parent $packageJson) 'package-lock.json'
    $hasLock = Test-Path -LiteralPath $lock
    if ($hasLock) { Copy-Item -LiteralPath $lock -Destination (Join-Path $dir 'package-lock.json') -Force }
    $a = if ($hasLock) { @('ci', '--no-audit', '--no-fund') } else { @('install', '--no-audit', '--no-fund') }
    $r = Invoke-DropProcess $npm $a $dir 1200
    return @{ Ok = ($r.Status -eq 0); Output = $r.Output }
}
