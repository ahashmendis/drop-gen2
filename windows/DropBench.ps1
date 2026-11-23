# DropBench.ps1 - benchmark mode of Drop for Windows (UI-free engine). Port of the macOS BenchTask / BenchRunner /
# BenchStore / BenchTestRunner / BenchACDCheck / BenchReport code. Runs the SAME pipelines the app uses (OOP: generate ->
# fixers -> javac -> repair; ACD: plan -> per-question -> fixers -> validate -> repair) over fixed tasks and several
# models, records one JSON line per (task, model) run in results.jsonl and ranks the models (correctness first).
# Isolation: never writes the clipboard, config.json, the popup's saved model/provider or any normal-mode state; a failed
# run is recorded, never rerouted to another provider. Dot-sourced by DropCore.ps1. Definitions only.
#
# results.jsonl is the contract with the macOS report builder: same schema (schema 1 = OOP, schema 2 = ACD), same keys.

function Get-DropBenchDir {
    if ($env:DROP_BENCH_DIR) { return $env:DROP_BENCH_DIR }
    return (Join-Path (Get-DropDataDir) 'bench')
}
function Get-DropBenchHash($data) {
    if ($data -is [string]) { $data = [System.Text.Encoding]::UTF8.GetBytes($data) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([byte[]]$data) } finally { $sha.Dispose() }
    return ((($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16))
}
function Get-DropBenchISO { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }

# PowerShell 5.1 has no ConvertFrom-Json -AsHashtable: convert PSCustomObject trees into hashtables / arrays.
function ConvertTo-DropHashtable($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-DropHashtable $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IList]) { return @($o | ForEach-Object { ConvertTo-DropHashtable $_ }) }
    return $o
}

# ---- tasks (<bench>/tasks/<id>/task.json + inputs/ + tests/) -------------------------------------------------------
function Get-DropBenchTask([string]$dir) {
    $tj = Join-Path $dir 'task.json'
    if (-not (Test-Path -LiteralPath $tj)) { return $null }
    try { $o = ConvertTo-DropHashtable (Get-Content -LiteralPath $tj -Raw | ConvertFrom-Json) } catch { return $null }
    if (-not $o.Contains('id')) { return $null }
    $inputs = if ($o.Contains('inputs') -and $o['inputs']) { $o['inputs'] } else { @{} }
    $tests = if ($o.Contains('tests') -and $o['tests']) { $o['tests'] } else { @{} }
    $reqs = @()
    foreach ($r in @($o['requirements'])) {
        if ($null -eq $r) { continue }
        $reqs += @{ Id = $(if ($r['id']) { [string]$r['id'] } else { '?' }); Text = [string]$r['text']; Marks = [double]$(if ($r['marks']) { $r['marks'] } else { 0 })
                    Kind = $(if ($r['kind']) { [string]$r['kind'] } else { 'automated' }); Tests = @($r['tests'] | Where-Object { $_ }); Note = [string]$r['note']
                    Question = [string]$r['question']; Answer = [string]$r['answer']; Rubric = [string]$r['rubric']; Check = $(if ($r['check']) { $r['check'] } else { @{} }) }
    }
    $t = @{ Id = [string]$o['id']; Title = $(if ($o['title']) { [string]$o['title'] } else { [string]$o['id'] }); Level = [string]$o['level']; Dir = $dir
            PaperFile = [string]$inputs['paper']; StarterFile = [string]$inputs['starter']
            TestMain = [string]$tests['main']; TestsDir = $(if ($tests['dir']) { [string]$tests['dir'] } else { 'tests' }); SupportDir = $(if ($tests['support']) { [string]$tests['support'] } else { '../_support' })
            ExpectedNewFiles = @($o['expectedNewFiles'] | Where-Object { $_ }); Requirements = $reqs; DeclaredTests = 0
            Subject = $(if ($o['subject']) { [string]$o['subject'] } else { 'oop' }) }
    $tdir = Join-Path $dir $t.TestsDir
    if (Test-Path -LiteralPath $tdir) {
        foreach ($f in (Get-ChildItem -LiteralPath $tdir -Filter *.java -File)) {
            $src = [System.IO.File]::ReadAllText($f.FullName)
            $t.DeclaredTests += ([regex]::Matches($src, 'test\("')).Count
        }
    }
    if ($t.Subject -eq 'acd') { $t.DeclaredTests = @($reqs | Where-Object { $_.Kind -eq 'objective' -or $_.Kind -eq 'automated' }).Count }
    return $t
}
function Get-DropBenchTasks {
    $root = Join-Path (Get-DropBenchDir) 'tasks'
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        if ($d.Name.StartsWith('_') -or $d.Name.StartsWith('.')) { continue }
        $t = Get-DropBenchTask $d.FullName
        if ($t) { $out += $t }
    }
    return $out
}
# Copies the shipped bench-tasks folder (next to the installer / repo) into the bench tasks folder, never overwriting edits.
function Copy-DropBenchSampleTasks([string]$sourceDir) {
    if (-not (Test-Path -LiteralPath $sourceDir)) { return }
    $dest = Join-Path (Get-DropBenchDir) 'tasks'
    [void](New-Item -ItemType Directory -Path $dest -Force)
    foreach ($f in (Get-ChildItem -LiteralPath $sourceDir -Recurse -File)) {
        $rel = $f.FullName.Substring($sourceDir.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $target = Join-Path $dest $rel
        if (Test-Path -LiteralPath $target) { continue }
        $td = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $td)) { [void](New-Item -ItemType Directory -Path $td -Force) }
        Copy-Item -LiteralPath $f.FullName -Destination $target
    }
}
function Copy-DropAcdNotes([string]$sourceDir) {
    if (-not (Test-Path -LiteralPath $sourceDir)) { return }
    $dest = Get-AcdNotesInstalledDir
    [void](New-Item -ItemType Directory -Path $dest -Force)
    foreach ($f in (Get-ChildItem -LiteralPath $sourceDir -File)) {
        $target = Join-Path $dest $f.Name
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $f.FullName -Destination $target }
    }
}

# Identical inputs for every model: the paper and the UNZIPPED starter, laid out like Desktop/OOP. -> @{ Dir; Hash } or $null
function New-DropBenchInput($task, [string]$work) {
    $input2 = Join-Path $work 'input'
    if (Test-Path -LiteralPath $input2) { Remove-Item -LiteralPath $input2 -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $input2 -Force)
    $bytes = New-Object System.Collections.Generic.List[byte]
    if ($task.PaperFile) {
        $paper = Join-Path $task.Dir $task.PaperFile
        if (Test-Path -LiteralPath $paper) { $bytes.AddRange([System.IO.File]::ReadAllBytes($paper)); Copy-Item -LiteralPath $paper -Destination $input2 }
    }
    if ($task.StarterFile) {
        $zip = Join-Path $task.Dir $task.StarterFile
        if (Test-Path -LiteralPath $zip) {
            $bytes.AddRange([System.IO.File]::ReadAllBytes($zip))
            try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $input2) } catch { return $null }
        }
    }
    if ($bytes.Count -eq 0) { return $null }
    return @{ Dir = $input2; Hash = (Get-DropBenchHash $bytes.ToArray()) }
}

# ---- functional tests (Java checks against the generated solution) ---------------------------------------------------
function Get-DropBenchJdkBin {
    $javac = Find-DropJavac
    if (-not $javac) { return $null }
    $bin = Split-Path -Parent $javac
    foreach ($j in @('java.exe', 'java')) { if (Test-Path -LiteralPath (Join-Path $bin $j)) { return $bin } }
    return $null
}
# One newest version of each artifact the test support needs (mixed versions in ~/.m2 would not run).
function Get-DropBenchRuntimeClasspath {
    $m2 = Join-Path $env:USERPROFILE '.m2/repository'
    $arts = @('org/springframework/spring-web', 'org/springframework/spring-core', 'org/springframework/spring-context', 'org/springframework/spring-beans',
              'org/springframework/spring-aop', 'org/springframework/spring-expression', 'com/fasterxml/jackson/core/jackson-databind',
              'com/fasterxml/jackson/core/jackson-core', 'com/fasterxml/jackson/core/jackson-annotations', 'org/jspecify/jspecify',
              'io/micrometer/micrometer-commons', 'io/micrometer/micrometer-observation')
    $jars = @()
    foreach ($a in $arts) {
        $base = Join-Path $m2 $a
        $name = Split-Path -Leaf $a
        $found = $null
        if (Test-Path -LiteralPath $base) {
            $vers = @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object { try { [version]($_.Name -replace '[^\d.].*$', '') } catch { [version]'0.0' } } -Descending)
            foreach ($v in $vers) {
                $jar = Join-Path $v.FullName "$name-$($v.Name).jar"
                if (Test-Path -LiteralPath $jar) { $found = $jar; break }
            }
        }
        if ($found) { $jars += $found } elseif ($a.Contains('spring-web') -or $a.Contains('jackson-databind')) { return $null }
    }
    return ($jars -join [System.IO.Path]::PathSeparator)
}
# -> @{ Ran = $false; Reason } or @{ Ran = $true; Results = @(@{Id;Title;Passed;Message}) }
function Invoke-DropBenchTests($task, [string]$answer, $starter) {
    $bin = Get-DropBenchJdkBin
    if (-not $bin) { return @{ Ran = $false; Reason = 'no JDK found' } }
    $cp = Get-DropBenchRuntimeClasspath
    if (-not $cp) { return @{ Ran = $false; Reason = 'Spring/Jackson jars not found in ~/.m2' } }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dropbench-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $sources = @{}
        if ($starter) { foreach ($k in @($starter.Keys)) { $sources[[string]$k] = [string]$starter[$k] } }
        $parsed = Get-DropParsedFiles $answer
        foreach ($k in @($parsed.Keys)) { $sources[[string]$k] = Add-DropUtilImport ([string]$parsed[$k]) }
        $paths = @()
        foreach ($k in (Get-DropSortedKeys $sources.Keys)) {
            if ($k.EndsWith('Application.java')) { continue }
            $u = Join-Path $tmp $k
            $d = Split-Path -Parent $u
            if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
            [System.IO.File]::WriteAllText($u, [string]$sources[$k], $utf8)
            $paths += $u
        }
        $support = [System.IO.Path]::GetFullPath((Join-Path $task.Dir $task.SupportDir))
        $tests = Join-Path $task.Dir $task.TestsDir
        foreach ($d in @($support, $tests)) {
            if (Test-Path -LiteralPath $d) { foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.java -File | Sort-Object Name)) { $paths += $f.FullName } }
        }
        $out = Join-Path $tmp 'out'
        [void](New-Item -ItemType Directory -Path $out -Force)
        $javac = Join-Path $bin $(if (Test-DropWindows) { 'javac.exe' } else { 'javac' })
        $java = Join-Path $bin $(if (Test-DropWindows) { 'java.exe' } else { 'java' })
        $c = Invoke-DropProcess $javac (@('--release', '17', '-parameters', '-proc:none', '-nowarn', '-encoding', 'UTF-8', '-d', $out, '-cp', $cp) + $paths) $tmp 180
        if ($c.Status -ne 0) {
            $first = (($c.Output -replace [regex]::Escape($tmp + '/'), '' -replace [regex]::Escape($tmp + '\'), '') -split "`n" | Where-Object { $_.Contains('error:') } | Select-Object -First 3) -join ' | '
            return @{ Ran = $false; Reason = "tests could not be compiled against this solution (missing or incompatible API): $first" }
        }
        $r = Invoke-DropProcess $java @("-Dbench.src=$(Join-Path $tmp 'src/main/java')", '-cp', ($out + [System.IO.Path]::PathSeparator + $cp), $task.TestMain) $tmp 120
        if ($r.TimedOut) { return @{ Ran = $false; Reason = 'tests timed out after 120 s (possible infinite loop in the solution)' } }
        $results = @()
        foreach ($line in ($r.Output -split "`n")) {
            $line = $line.TrimEnd("`r")
            if (-not $line.StartsWith("TEST`t")) { continue }
            $f = $line -split "`t"
            if ($f.Count -lt 3) { continue }
            $name = $f[1]
            $id = ($name -split ' ')[0]
            $title = $name.Substring($id.Length).Trim()
            $results += @{ Id = $id; Title = $title; Passed = ($f[2] -eq 'PASS'); Message = $(if ($f.Count -gt 3) { $f[3] } else { '' }) }
        }
        if ($results.Count -eq 0) { return @{ Ran = $false; Reason = 'test program produced no results: ' + $r.Output.Substring(0, [Math]::Min(300, $r.Output.Length)) } }
        return @{ Ran = $true; Results = $results }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- code quality (10 automated points; every deduction listed) -------------------------------------------------------
function Get-DropBenchQuality([string]$answer, $starter, $expectedNew) {
    $files = Get-DropParsedFiles $answer
    $pts = 10.0
    $notes = @()
    $newFiles = @($files.Keys | Where-Object { -not $starter -or -not $starter.ContainsKey($_) })
    $extra = @($newFiles | Where-Object { $f = $_; -not (@($expectedNew) | Where-Object { $f.EndsWith([string]$_) }) })
    if ($extra.Count -gt 0) {
        $d = [Math]::Min(6.0, 2.0 * $extra.Count); $pts -= $d
        $notes += ("-" + [int]$d + ': ' + $extra.Count + ' extra file(s) the task did not ask for: ' + ((@($extra | ForEach-Object { [System.IO.Path]::GetFileName($_) })) -join ', '))
    }
    $abstractions = @()
    foreach ($f in $newFiles) {
        $body = [string]$files[$f]
        foreach ($pat in @('\binterface\s+\w+', '\babstract\s+class\s+\w+', '\benum\s+\w+')) {
            if ([regex]::IsMatch($body, $pat)) { $abstractions += [System.IO.Path]::GetFileName($f); break }
        }
    }
    if ($abstractions.Count -gt 0) {
        $d = [Math]::Min(4.0, 2.0 * $abstractions.Count); $pts -= $d
        $notes += ("-" + [int]$d + ': extra abstractions (interface/abstract class/enum): ' + ($abstractions -join ', '))
    }
    $longMethods = 0
    foreach ($k in @($files.Keys)) {
        $depth = 0; $start = -1; $lineNo = 0
        foreach ($line in ([string]$files[$k] -split "`n")) {
            $lineNo++
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq '{') { $depth++; if ($depth -eq 2) { $start = $lineNo } }
                elseif ($ch -eq '}') { if ($depth -eq 2 -and $start -gt 0 -and ($lineNo - $start) -gt 40) { $longMethods++ }; $depth-- }
            }
        }
    }
    if ($longMethods -gt 0) { $d = [Math]::Min(3.0, [double]$longMethods); $pts -= $d; $notes += ("-" + [int]$d + ": $longMethods method(s) longer than 40 lines") }
    $all = (@($files.Values) -join "`n")
    if ($all.Contains('TODO') -or $all.Contains('UnsupportedOperationException')) { $pts -= 3; $notes += '-3: leftover TODO / UnsupportedOperationException' }
    if ($files.Count -eq 0) { $pts = 0; $notes = @('no Java files found in the answer') }
    return @{ Points = [Math]::Max(0.0, $pts); Notes = $notes }
}

# ---- ACD checks: executed / static, each kept apart ---------------------------------------------------------------------
function Get-DropBenchCodeCandidates([string]$text) {
    $fenced = New-Object System.Collections.Generic.List[string]
    $cur = $null
    foreach ($line in ($text -split "`n")) {
        if ($line.Trim().StartsWith('```')) {
            if ($null -ne $cur) { $fenced.Add(($cur -join "`n")); $cur = $null } else { $cur = New-Object System.Collections.Generic.List[string] }
        } elseif ($null -ne $cur) { $cur.Add($line) }
    }
    $out = @()
    if ($fenced.Count -gt 0) { $out += ($fenced -join "`n") }
    $out += $text
    return $out
}
function New-DropBenchTemp { $d = Join-Path ([System.IO.Path]::GetTempPath()) ('dropacd-c-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $d -Force); return (Get-AcdRealPath $d) }
# status: verified | failed | not_run (tool missing / no sandbox) | static_pass | static_fail
function Invoke-DropBenchAcdCheck($check, [string]$text) {
    $type = [string]$check['type']
    if ($type -eq 'regex-all') {
        $missing = @()
        foreach ($p in @($check['patterns'])) { if ($p -and -not [regex]::IsMatch($text, [string]$p, 'IgnoreCase')) { $missing += [string]$p } }
        $any = @($check['anyOf'] | Where-Object { $_ })
        if ($any.Count -gt 0 -and -not ($any | Where-Object { [regex]::IsMatch($text, [string]$_, 'IgnoreCase') })) { $missing += 'one of: ' + ($any -join ' | ') }
        if ($missing.Count -eq 0) { return @{ Status = 'static_pass'; Detail = 'all patterns present' } }
        return @{ Status = 'static_fail'; Detail = 'missing: ' + ($missing -join '; ') }
    }
    if ($type -eq 'node-eval') {
        $node = Find-AcdTool 'node'
        if (-not $node) { return @{ Status = 'not_run'; Detail = 'node not found' } }
        $setup = [string]$check['setup']; $declares = [string]$check['declares']; $expr = [string]$check['expr']; $expect = [string]$check['expect']
        $lastErr = 'no runnable code found'
        foreach ($cand in (Get-DropBenchCodeCandidates $text)) {
            $tmp = New-DropBenchTemp
            try {
                $declared = ($declares -ne '') -and [regex]::IsMatch($cand, '\b(const|let|var)\s+' + [regex]::Escape($declares) + '\b')
                $script = $(if ($declared) { '' } else { $setup + "`n" }) + $cand + "`n;process.stdout.write('\n__RESULT__' + JSON.stringify(" + $expr + "));`n"
                $f = Join-Path $tmp 'answer.cjs'
                [System.IO.File]::WriteAllText($f, $script, (New-Object System.Text.UTF8Encoding($false)))
                $r = Invoke-AcdTool $node @($f) $tmp @($tmp) 20 $true
                if ($r.Unavailable) { return @{ Status = 'not_run'; Detail = $r.Output } }
                $i = $r.Output.IndexOf('__RESULT__')
                if ($i -ge 0) {
                    $got = $r.Output.Substring($i + 10).Trim()
                    if ($got -ceq $expect) { return @{ Status = 'verified'; Detail = "result $got" } }
                    return @{ Status = 'failed'; Detail = "expected $expect but the code produced $got" }
                }
                $o = ($r.Output -replace [regex]::Escape($tmp + '/'), '' -replace [regex]::Escape($tmp + '\'), '')
                $lastErr = $o.Substring(0, [Math]::Min(200, $o.Length))
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        return @{ Status = 'failed'; Detail = $lastErr }
    }
    if ($type -eq 'ts-compile') {
        $node = Find-AcdTool 'node'
        if (-not $node) { return @{ Status = 'not_run'; Detail = 'node not found' } }
        $nm = Get-AcdToolchainNM
        if (-not $nm -or -not (Test-Path -LiteralPath (Join-Path $nm 'typescript/bin/tsc'))) { return @{ Status = 'not_run'; Detail = 'TypeScript is not installed (Prepare ACD toolchain)' } }
        $suffix = [string]$check['suffix']
        $lastErr = 'no code found'
        foreach ($cand in (Get-DropBenchCodeCandidates $text)) {
            $tmp = New-DropBenchTemp
            try {
                [System.IO.File]::WriteAllText((Join-Path $tmp 'answer.ts'), ($cand + "`n" + $suffix), (New-Object System.Text.UTF8Encoding($false)))
                $r = Invoke-AcdTool $node @((Join-Path (Get-AcdRealPath $nm) 'typescript/bin/tsc'), '--noEmit', '--strict', '--target', 'es2022', '--skipLibCheck', 'answer.ts') $tmp @($tmp) 60 $false
                if ($r.Status -eq 0) { return @{ Status = 'verified'; Detail = 'compiles under tsc --strict and rejects the invalid objects' } }
                $o = ((($r.Output -replace [regex]::Escape($tmp + '/'), '' -replace [regex]::Escape($tmp + '\'), '') -split "`n") | Select-Object -First 3) -join ' | '
                $lastErr = $o.Substring(0, [Math]::Min(250, $o.Length))
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        return @{ Status = 'failed'; Detail = $lastErr }
    }
    return @{ Status = 'not_run'; Detail = 'unknown check type' }
}

# ---- results store (append-only JSON lines) --------------------------------------------------------------------------------
function Get-DropBenchResultsPath { return (Join-Path (Join-Path (Get-DropBenchDir) 'results') 'results.jsonl') }
function Initialize-DropBenchDirs { foreach ($d in @('tasks', 'results', 'runs', 'reports')) { [void](New-Item -ItemType Directory -Path (Join-Path (Get-DropBenchDir) $d) -Force) } }
function Add-DropBenchRecord($rec) {
    Initialize-DropBenchDirs
    $line = ($rec | ConvertTo-Json -Depth 12 -Compress)
    [System.IO.File]::AppendAllText((Get-DropBenchResultsPath), $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Get-DropBenchRecords {
    $p = Get-DropBenchResultsPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $out = @()
    foreach ($l in [System.IO.File]::ReadAllLines($p)) {
        if (-not $l) { continue }
        try { $out += ,(ConvertTo-DropHashtable ($l | ConvertFrom-Json)) } catch { }
    }
    return $out
}
# digest / size / family of every installed Ollama model, recorded with each run so scores stay reproducible
function Get-DropBenchOllamaInfo([string]$base) {
    $out = @{}
    try {
        $o = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/api/tags') -TimeoutSec 5
        foreach ($m in @($o.models)) {
            $d = $m.details
            $out[[string]$m.name] = @{ digest = [string]$m.digest; size_bytes = $(if ($m.size) { [int64]$m.size } else { 0 }); modified_at = [string]$m.modified_at
                                       family = $(if ($d) { [string]$d.family } else { '' }); parameter_size = $(if ($d) { [string]$d.parameter_size } else { '' })
                                       quantization = $(if ($d) { [string]$d.quantization_level } else { '' }) }
        }
    } catch { }
    return $out
}

# ---- generation helpers for the benchmark (no UI, no fallback) -----------------------------------------------------------------
# The ORIGINAL thinking request (OOP "original" mode): think on, keep_alive 0, bounded output. -> @{ Text; Error }
function Invoke-DropBenchOriginalGenerate($ctx, [string]$model, [string]$prompt, [int]$numPredict) {
    $manual = [int]$ctx.ManualCtx
    $ram = [int64]$ctx.RamBytes
    $need = [int]($prompt.Length / 3) + 8000
    $c = 8192
    while ($c -lt $need -and $c -lt 65536) { $c *= 2 }
    $target = if ($manual -gt 0) { [Math]::Min($manual, 65536) } else { $gb = [int](($ram + 536870912) / 1GB); if ($gb -lt 16) { 8192 } elseif ($gb -lt 64) { 16384 } else { 32768 } }
    if ($c -lt $target) { $c = $target }
    if ($c -gt 65536) { $c = 65536 }
    $ceil = Get-DropCtxCeiling $manual $ram
    if ($c -gt $ceil) { $c = $ceil }
    if ($manual -le 0 -and [int]($prompt.Length / 3) -gt $c) {
        return @{ Text = ''; Error = "prompt needs ~$([int]($prompt.Length / 3)) tokens, above the automatic context ceiling ($c); raise Qwen ctx in Settings" }
    }
    if (-not (Prepare-DropOllama $ctx.Base)) { return @{ Text = ''; Error = 'Ollama could not be started' } }
    $body = @{ model = $model; prompt = $prompt; stream = $false; think = $true; keep_alive = 0; options = @{ num_ctx = $c; temperature = 0.2; num_predict = $numPredict } }
    $resp = Send-DropJson ($ctx.Base.TrimEnd('/') + '/api/generate') $body 2700
    if ($resp.Status -eq 0) { return @{ Text = ''; Error = $resp.Text } }
    if ($resp.Status -ne 200) { return @{ Text = ''; Error = (Format-DropHttpError $resp.Status $resp.Text) } }
    $o = $resp.Text | ConvertFrom-Json
    $ans = [string]$o.response
    if ([string]::IsNullOrWhiteSpace($ans)) {
        if ([string]$o.done_reason -eq 'length') { return @{ Text = ''; Error = 'context limit reached - no answer produced; raise Qwen ctx in Settings' } }
        return @{ Text = ''; Error = 'empty response from provider' }
    }
    if ([string]$o.done_reason -eq 'length') { return @{ Text = $ans; Error = 'answer cut short by the context (partial answer kept)' } }
    return @{ Text = $ans; Error = $null }
}
# Probe the local Ollama API; start the official app only when it is not up (never kill it).
function Prepare-DropOllama([string]$base) {
    if ($base -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])') { return $true }
    try { $null = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/api/tags') -TimeoutSec 2; return $true } catch { }
    if (-not (Get-Command Start-OllamaApp -ErrorAction SilentlyContinue)) { return $false }   # Start-OllamaApp lives in the app file
    $env:OLLAMA_NUM_PARALLEL = '1'; $env:OLLAMA_MAX_LOADED_MODELS = '1'
    if (-not (Start-OllamaApp)) { return $false }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try { $null = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/api/tags') -TimeoutSec 2; return $true } catch { }
    }
    return $false
}

# ---- one run ---------------------------------------------------------------------------------------------------------------------
# $ctx: RunId, Base, ManualCtx, RamBytes, OopPerTask, OopMode (auto|original|nothink), Careful, OpenCode (@{BaseUrl;ApiKey}), Log (scriptblock), Cancelled (scriptblock -> bool)
# $model: @{ Provider; Name; Info }
function Invoke-DropBenchRunOne($ctx, $model, $task) {
    $log = $ctx.Log
    if ($task.Subject -eq 'acd') { Invoke-DropBenchRunOneAcd $ctx $model $task; return }
    $started = [DateTime]::UtcNow
    $safe = $model.Name.Replace('/', '_').Replace(':', '_')
    $runDir = Join-Path (Get-DropBenchDir) "runs/$($ctx.RunId)/$($model.Provider)_$safe/$($task.Id)"
    [void](New-Item -ItemType Directory -Path $runDir -Force)
    $rec = [ordered]@{ schema = 1; run_id = $ctx.RunId; started_at = (Get-DropBenchISO); provider = $model.Provider; model = $model.Name; model_info = $model.Info
                       task = $task.Id; task_title = $task.Title; run_dir = $runDir }
    $inp = New-DropBenchInput $task $runDir
    if (-not $inp) { $rec.final_status = 'error'; $rec.error = 'could not prepare task input'; $rec.finished_at = (Get-DropBenchISO); Add-DropBenchRecord $rec; & $log '  ! could not prepare task input'; return }
    $rec.input_hash = $inp.Hash
    $col = Collect-Input @($inp.Dir)
    $paper = [string]$col[0]; $fileCount = $col[1]; $starter = $col[2]
    if ($null -eq $starter) { $starter = @{} }
    if (@($paper -split '\s+' | Where-Object { $_ -ne '' }).Count -lt 15) { $rec.final_status = 'error'; $rec.error = 'no readable task text'; $rec.finished_at = (Get-DropBenchISO); Add-DropBenchRecord $rec; & $log '  ! no readable task text'; return }
    $isOllama = ($model.Provider -eq 'ollama')
    $numPredict = Get-OllamaNumPredict $paper
    $header = if ($isOllama) { $OllamaPromptHeader } else { $PromptHeader }
    $fastOop = ($ctx.OopMode -eq 'nothink') -or ($ctx.OopMode -eq 'auto' -and -not $ctx.Careful)
    $cond = [ordered]@{ files_read = $fileCount; starter_files = $starter.Count; num_predict = $numPredict; ollama_context_setting = [int]$ctx.ManualCtx; temperature = 0.2; keep_alive = 0; think = $true
                        prompt_header_hash = (Get-DropBenchHash $header); repair_header_hash = (Get-DropBenchHash $(if ($isOllama) { $OllamaRepairHeader } else { $script:DropOpenCodeRepairHeader }))
                        deterministic_fixers = $isOllama; max_repair_rounds = 4 }
    $script:BenchFailure = $null
    $session = $null; $plan = $null
    if ($isOllama -and $ctx.OopPerTask) {
        $plan = New-DropOopPlan $paper
        if ($plan -and (Prepare-DropOllama $ctx.Base)) { $session = New-DropSession $ctx.Base $model.Name ([int]$ctx.ManualCtx) ([int64]$ctx.RamBytes) } else { $plan = $null }
    }
    if (-not $session -and $isOllama -and $fastOop -and (Prepare-DropOllama $ctx.Base)) { $session = New-DropSession $ctx.Base $model.Name ([int]$ctx.ManualCtx) ([int64]$ctx.RamBytes) }
    $rec.oop_per_task = [bool]($session -and $plan)
    $cond.oop_per_task = [bool]($session -and $plan)
    $cond.oop_request = if ($plan) { 'one request per task, thinking off' } elseif ($session) { 'single request, thinking off, small context' } else { 'single request, thinking on (original)' }
    $rec.conditions = $cond
    $ask = {
        param($req)
        $res = Invoke-DropSessionGenerate $session $req
        if ($res.Error) { $script:BenchFailure = "$($req.Label): $($res.Error)"; & $log ("  ! " + $script:BenchFailure); if ([string]::IsNullOrEmpty($res.Text)) { return $null } }
        return $res.Text
    }
    $hooks = @{
        Generate = {
            param($prompt, $label)
            & $log "  $label..."
            $first = ($label -eq 'Writing')
            if ($session -and -not $plan -and $fastOop) {
                return (& $ask (New-DropRequest $prompt $label $(if ($first) { 'whole' } else { 'repair' }) $(if ($first) { [Math]::Max($numPredict, 4096) } else { 4000 }) 0.2 $false))
            }
            if ($session -and $plan) {
                if ($first) { return (Invoke-DropOopPerTask $plan ([bool]$ctx.Careful) $ask { param($s) }) }
                return (& $ask (New-DropRequest $prompt $label 'repair' 4000 0.2 $false))
            }
            if ($isOllama) {
                $res = Invoke-DropBenchOriginalGenerate $ctx $model.Name $prompt $numPredict
            } else {
                $res = Invoke-DropOpenCodeRequest @{ BaseUrl = $ctx.OpenCode.BaseUrl; ApiKey = $ctx.OpenCode.ApiKey; Model = $model.Name; SessionId = [guid]::NewGuid().ToString() } $prompt
            }
            if ($res.Error) { $script:BenchFailure = [string]$res.Error; & $log ("  ! " + $res.Error) }
            if ([string]::IsNullOrWhiteSpace($res.Text)) { return $null }
            return $res.Text
        }
        Compile = { param($answer) $script:StarterFiles = $starter; if ($starter.Count -eq 0) { return $null }; return (Get-DropCompileErrors $answer) }
        Status = { param($s) }
    }
    $res = Invoke-DropOopPipeline $paper $model.Provider $starter $hooks
    if ($session) { Close-DropSession $session }
    if (& $ctx.Cancelled) { & $log '  stopped - this run is not recorded'; return }
    $rec.finished_at = (Get-DropBenchISO)
    if ($null -eq $res) {
        $rec.final_status = 'generation_failed'; $rec.error = $(if ($script:BenchFailure) { $script:BenchFailure } else { 'no answer' })
        $rec.generation_ms = [int](([DateTime]::UtcNow - $started).TotalMilliseconds)
        Add-DropBenchRecord $rec; & $log ("  generation failed: " + $rec.error); return
    }
    $ansPath = Join-Path $runDir 'answer.txt'
    [System.IO.File]::WriteAllText($ansPath, [string]$res.Answer, (New-Object System.Text.UTF8Encoding($false)))
    $rec.answer_path = $ansPath
    $rec.generation_ms = $res.GenerationMs; $rec.compile_ms = $res.CompileMs; $rec.repair_rounds = $res.RepairRounds
    $compileStatus = if ($null -eq $res.Compiled) { 'unchecked' } elseif ($res.Compiled) { 'compiled' } else { 'failed' }
    $rec.compile_status = $compileStatus
    if ($res.LastErrors) { $rec.compile_errors = $res.LastErrors.Substring(0, [Math]::Min(1500, $res.LastErrors.Length)) }
    # functional tests: only when the solution compiles (never awarded when not executed)
    $functional = [ordered]@{ declared = $task.DeclaredTests }
    $verdict = @{}
    if ($compileStatus -eq 'failed') { $functional.ran = $false; $functional.reason = 'solution does not compile' }
    else {
        & $log "  running $($task.DeclaredTests) functional tests..."
        $t = Invoke-DropBenchTests $task $res.Answer $starter
        if (-not $t.Ran) { $functional.ran = $false; $functional.reason = $t.Reason }
        else {
            $functional.ran = $true
            $functional.total = $t.Results.Count
            $functional.passed = @($t.Results | Where-Object { $_.Passed }).Count
            $functional.failed = @($t.Results | Where-Object { -not $_.Passed } | ForEach-Object { @{ id = $_.Id; title = $_.Title; message = $_.Message } })
            foreach ($r in $t.Results) { $verdict[$r.Id] = $r }
        }
    }
    $rec.functional = $functional
    $ran = ($functional.ran -eq $true)
    $reqs = @()
    foreach ($r in $task.Requirements) {
        $failedT = @()
        if ($r.Kind -eq 'manual') { $status = 'manual_unassessed' }
        elseif ($r.Kind -eq 'untestable') { $status = 'untestable' }
        elseif (-not $ran) { $status = 'not_run' }
        else {
            $missing = @($r.Tests | Where-Object { -not $verdict.ContainsKey($_) })
            $failedT = @($r.Tests | Where-Object { $verdict.ContainsKey($_) -and -not $verdict[$_].Passed }) + $missing
            $status = if ($failedT.Count -eq 0 -and $r.Tests.Count -gt 0) { 'verified' } else { 'failed' }
        }
        $d = [ordered]@{ id = $r.Id; marks = $r.Marks; kind = $r.Kind; status = $status; text = $r.Text }
        if ($failedT.Count -gt 0) { $d.failed_tests = $failedT }
        $reqs += $d
    }
    $rec.requirements = $reqs
    $q = Get-DropBenchQuality $res.Answer $starter $task.ExpectedNewFiles
    $rec.quality = [ordered]@{ auto_points = $q.Points; auto_max = 10; notes = $q.Notes }
    $rec.final_status = if (-not $ran) { 'tests_not_run' } elseif ($functional.passed -eq $functional.total) { 'all_tests_passed' } else { 'some_tests_failed' }
    Add-DropBenchRecord $rec
    $secs = ($res.GenerationMs + $res.CompileMs) / 1000.0
    $tline = if ($ran) { "tests $($functional.passed)/$($functional.total)" } else { "tests NOT RUN ($($functional.reason))" }
    $cl = if ($compileStatus -eq 'compiled') { 'compiles' } elseif ($compileStatus -eq 'failed') { 'compile errors' } else { 'compile unchecked' }
    & $log ("  -> $cl, $($res.RepairRounds) repair(s), $tline, $([Math]::Round($secs)) s")
}

function Invoke-DropBenchRunOneAcd($ctx, $model, $task) {
    $log = $ctx.Log
    $started = [DateTime]::UtcNow
    $safe = $model.Name.Replace('/', '_').Replace(':', '_')
    $runDir = Join-Path (Get-DropBenchDir) "runs/$($ctx.RunId)/$($model.Provider)_$safe/$($task.Id)"
    [void](New-Item -ItemType Directory -Path $runDir -Force)
    $rec = [ordered]@{ schema = 2; subject = 'acd'; run_id = $ctx.RunId; started_at = (Get-DropBenchISO); provider = $model.Provider; model = $model.Name; model_info = $model.Info
                       task = $task.Id; task_title = $task.Title; run_dir = $runDir }
    $inp = New-DropBenchInput $task $runDir
    if (-not $inp) { $rec.final_status = 'error'; $rec.error = 'could not prepare task input'; $rec.finished_at = (Get-DropBenchISO); Add-DropBenchRecord $rec; & $log '  ! could not prepare task input'; return }
    $rec.input_hash = $inp.Hash
    $in2 = Get-AcdInput $inp.Dir
    if (@($in2.TaskOnly -split '\s+' | Where-Object { $_ -ne '' }).Count -lt 15) { $rec.final_status = 'error'; $rec.error = 'no readable task text'; $rec.finished_at = (Get-DropBenchISO); Add-DropBenchRecord $rec; & $log '  ! no readable task text'; return }
    $isOllama = ($model.Provider -eq 'ollama')
    $manual = [int]$ctx.ManualCtx; $ram = [int64]$ctx.RamBytes
    $ceiling = if ($isOllama) { if ($manual -gt 0) { [Math]::Min($manual, 65536) } else { Get-DropCtxCeiling 0 $ram } } else { 32768 }
    $chunks = Get-AcdNoteChunks @((Get-AcdNotesInstalledDir), (Get-AcdNotesDesktopDir))
    $careful = [bool]$ctx.Careful
    $plan = New-AcdPlan $in2.TaskOnly
    $notesChars = 0; foreach ($c in $chunks) { $notesChars += $c.Text.Length }
    $rec.conditions = [ordered]@{ files_read = $in2.FileCount; starter_files = $in2.Starter.Count; mode = $(if (@($plan.Units).Count -ge 2) { 'units' } else { 'whole' }); units = @($plan.Units).Count
        careful_mode = $careful; think = $(if ($careful) { 'free questions only' } else { 'off' }); ollama_context_setting = $manual; temperature = '0 objective / 0.2 free'
        keep_alive = '2m during the run, unloaded when it ends or grows past 60% of RAM'; prompt_header_hash = (Get-DropBenchHash ($script:AcdPromptHeader + $script:AcdModule))
        repair_header_hash = (Get-DropBenchHash $script:AcdRepairHeader); deterministic_fixers = $true; max_repair_rounds = 3; notes_chars_available = $notesChars }
    $script:BenchFailure = $null
    $session = $null
    if ($isOllama) {
        if (-not (Prepare-DropOllama $ctx.Base)) {
            $rec.final_status = 'generation_failed'; $rec.error = 'Ollama could not be started'; $rec.finished_at = (Get-DropBenchISO); Add-DropBenchRecord $rec; & $log '  ! Ollama could not be started'; return
        }
        $session = New-DropSession $ctx.Base $model.Name $manual $ram
        $generate = {
            param($req)
            if ($req.Kind -ne 'objective') { & $log "  $($req.Label)..." }
            $res = Invoke-DropSessionGenerate $session $req
            if ($res.Error) { $script:BenchFailure = "$($req.Label): $($res.Error)"; & $log ("  ! " + $script:BenchFailure); if ([string]::IsNullOrEmpty($res.Text)) { return $null } }
            return $res.Text
        }
    } else {
        $generate = {
            param($req)
            if ($req.Kind -ne 'objective') { & $log "  $($req.Label)..." }
            $res = Invoke-DropOpenCodeRequest @{ BaseUrl = $ctx.OpenCode.BaseUrl; ApiKey = $ctx.OpenCode.ApiKey; Model = $model.Name; SessionId = [guid]::NewGuid().ToString() } $req.Prompt
            if ($res.Error) { $script:BenchFailure = "$($req.Label): $($res.Error)"; & $log ("  ! " + $script:BenchFailure); return $null }
            return $res.Text
        }
    }
    $starter = $in2.Starter; $root = $in2.ProjectRoot
    $hooks = @{ Generate = $generate; Validate = { param($files) return (Invoke-AcdValidate $files $starter $root) }; Status = { param($s) } }
    $runIn = @{ TaskText = $in2.TaskOnly; PaperBlock = $in2.Paper; Starter = $starter; Chunks = $chunks; Careful = $careful; CeilingTokens = $ceiling; QuestionCount = $in2.QuestionCount }
    $res = Invoke-AcdPipeline $runIn $hooks
    if ($session) { Close-DropSession $session; $reqCount = $session.RequestCount; $unloads = $session.UnloadCount } else { $reqCount = 0; $unloads = 0 }   # counted after the final unload (macOS parity)
    if (& $ctx.Cancelled) { & $log '  stopped - this run is not recorded'; return }
    $rec.finished_at = (Get-DropBenchISO)
    if ($null -eq $res) {
        $rec.final_status = 'generation_failed'; $rec.error = $(if ($script:BenchFailure) { $script:BenchFailure } else { 'no answer' })
        $rec.generation_ms = [int](([DateTime]::UtcNow - $started).TotalMilliseconds)
        Add-DropBenchRecord $rec; & $log ("  generation failed: " + $rec.error); return
    }
    $ansPath = Join-Path $runDir 'answer.txt'
    [System.IO.File]::WriteAllText($ansPath, [string]$res.Answer, (New-Object System.Text.UTF8Encoding($false)))
    $rec.answer_path = $ansPath
    $rec.generation_ms = $res.GenerationMs; $rec.compile_ms = $res.ValidationMs; $rec.repair_rounds = $res.RepairRounds
    if ($res.RepairNote) { $rec.repair_note = $res.RepairNote }
    $rec.acd_run = [ordered]@{ mode = $res.Mode; units = $res.UnitCount; unanswered = @($res.Unanswered); unit_ms = $res.UnitMs; notes_used = @($res.NotesUsed); requests = $reqCount; unloads = $unloads }
    # ---- grade: each kind of evidence is kept separate ----
    $doc = ConvertFrom-AcdText $res.Answer
    $qtext = Get-AcdQuestionText $doc
    $reqs = @(); $failedList = @()
    $objCorrect = 0; $objTotal = 0; $execPass = 0; $execTotal = 0; $staticPass = 0; $staticTotal = 0
    $sections = @{}
    $expectedQ = @{}
    foreach ($r in $task.Requirements) {
        if ($r.Question) { $expectedQ[$r.Question] = $true }
        $d = [ordered]@{ id = $r.Id; marks = $r.Marks; kind = $r.Kind; text = $r.Text }
        $qt = if ($r.Question -and $qtext.Contains($r.Question)) { [string]$qtext[$r.Question] } else { '' }
        switch ($r.Kind) {
            'objective' {
                $objTotal++
                $got = if ($qt) { ConvertTo-AcdObjective $qt } else { $null }
                $ok = ($got -ceq $r.Answer)
                $sec = $r.Question.Substring(0, 1)
                if (-not $sections.ContainsKey($sec)) { $sections[$sec] = @(0, 0) }
                $sections[$sec][1]++
                if ($ok) { $objCorrect++; $sections[$sec][0]++; $d.status = 'verified' }
                else {
                    $d.status = 'failed'; $d.failed_tests = @($r.Id); $d.expected = $r.Answer; $d.got = $(if ($got) { $got } else { '(no readable answer)' })
                    $failedList += @{ id = $r.Id; title = 'objective'; message = "expected $($r.Answer) but got $(if ($got) { $got } else { 'no readable answer' })" }
                }
            }
            'automated' {
                $execTotal++
                $c = Invoke-DropBenchAcdCheck $r.Check $qt
                $d.status = if ($c.Status -eq 'verified') { 'verified' } elseif ($c.Status -eq 'not_run') { 'not_run' } else { 'failed' }
                $d.detail = $c.Detail
                if ($c.Status -eq 'verified') { $execPass++ } else { $d.failed_tests = @($r.Id); $failedList += @{ id = $r.Id; title = 'executed check'; message = $c.Detail } }
            }
            'static' {
                $staticTotal++
                $c = Invoke-DropBenchAcdCheck $r.Check $qt
                $d.status = $c.Status; $d.detail = $c.Detail
                if ($c.Status -eq 'static_pass') { $staticPass++ }
            }
            'manual' { $d.status = 'manual_unassessed'; $d.rubric = $r.Rubric }
            default { $d.status = 'untestable' }
        }
        $reqs += $d
    }
    $answered = @($expectedQ.Keys | Where-Object { $qq = $_; ($qtext.Contains($qq) -and ([string]$qtext[$qq]).Trim() -ne '') -or ($null -ne (Get-AcdPart $doc $qq)) })
    $rec.requirements = $reqs
    $rec.functional = [ordered]@{ ran = $true; declared = $objTotal + $execTotal; total = $objTotal + $execTotal; passed = $objCorrect + $execPass; failed = $failedList }
    $secOut = [ordered]@{}; foreach ($k in (Get-DropSortedKeys $sections.Keys)) { $secOut[$k] = $sections[$k] }
    $rec.acd = [ordered]@{ objective = @{ correct = $objCorrect; total = $objTotal }; objective_by_section = $secOut; executed = @{ passed = $execPass; total = $execTotal }
        static = @{ passed = $staticPass; total = $staticTotal }; answered = $answered.Count; expected_questions = $expectedQ.Count
        validation = (ConvertTo-AcdValidationJson $res.Validation); validation_summary = (Get-AcdValidationSummary $res.Validation); validation_failures = (Get-AcdFailureCount $res.Validation)
        rejected_paths = @(Get-AcdRejectedPaths $doc) }
    $qpts = 10.0; $qnotes = @()
    $rej = @(Get-AcdRejectedPaths $doc)
    if ($rej.Count -gt 0) { $dd = [Math]::Min(6.0, 2.0 * $rej.Count); $qpts -= $dd; $qnotes += ("-" + [int]$dd + ': file path(s) outside the project rejected: ' + ($rej -join ', ')) }
    $placeholders = @($qtext.Values | Where-Object { ([string]$_).Contains('TODO') -or ([string]$_).Contains('...') }).Count
    if ($placeholders -gt 0) { $dd = [Math]::Min(4.0, [double]$placeholders); $qpts -= $dd; $qnotes += ("-" + [int]$dd + ": $placeholders answer(s) contain TODO/placeholders") }
    $rec.quality = [ordered]@{ auto_points = $qpts; auto_max = 10; notes = $qnotes }
    $rec.compile_status = 'n/a'
    $rec.final_status = if (($objCorrect + $execPass) -eq ($objTotal + $execTotal)) { 'all_automated_passed' } else { 'some_automated_failed' }
    Add-DropBenchRecord $rec
    $secs = ($res.GenerationMs + $res.ValidationMs) / 1000.0
    & $log ("  -> objective $objCorrect/$objTotal, executed $execPass/$execTotal, static $staticPass/$staticTotal, answered $($answered.Count)/$($expectedQ.Count), manual items pending, $([Math]::Round($secs)) s")
}

# $models: @(@{ Provider; Name; Info }), $tasks: task hashtables. Sequential; stop is checked between runs.
function Invoke-DropBenchRunAll($ctx, $models, $tasks) {
    Initialize-DropBenchDirs
    $total = @($tasks).Count * @($models).Count
    $n = 0
    foreach ($m in $models) {
        foreach ($t in $tasks) {
            if (& $ctx.Cancelled) { & $ctx.Log 'Stopped.'; return }
            $n++
            & $ctx.Log ("`n[$n/$total] $($m.Provider) $($m.Name) | $($t.Id)")
            try { Invoke-DropBenchRunOne $ctx $m $t } catch { & $ctx.Log ("  ! run failed: " + $_.Exception.Message) }
        }
    }
    & $ctx.Log "`nBenchmark finished: $total run(s) recorded in results.jsonl"
}

# ---- scoring + ranked report (methodology as in the macOS report; strengths/weaknesses and the source-coverage tables are
#      produced by the macOS report builder over the same results.jsonl) -------------------------------------------------------
function Get-DropBenchScores($results, $manual) {
    $latest = [ordered]@{}
    foreach ($r in $results) {
        if (-not ($r['provider'] -and $r['model'] -and $r['task'])) { continue }
        $latest["$($r['provider'])|$($r['model'])|$($r['task'])"] = $r
    }
    $out = @()
    foreach ($k in $latest.Keys) {
        $r = $latest[$k]
        $mk = "$($r['provider']):$($r['model']) | $($r['task'])"
        $s = @{ Provider = [string]$r['provider']; Model = [string]$r['model']; Task = [string]$r['task']; Subject = $(if ($r['subject']) { [string]$r['subject'] } else { 'oop' })
                Functional = 0.0; Coverage = 0.0; Compilation = 0.0; QualityAuto = 0.0; QualityManual = 0.0; Efficiency = 0.0; TestsRan = $false; Passed = 0; Total = 0
                Compiled = $false; CompileStatus = 'unchecked'; Repairs = 0; GenMs = 0; CompMs = 0; VerifiedMarks = 0.0; AutoMarks = 0.0; PaperMarks = 0.0; NotRunReason = ''; FinalStatus = [string]$r['final_status']
                Info = $r['model_info']; InputHash = [string]$r['input_hash']; Conditions = $r['conditions']; ObjCorrect = 0; ObjTotal = 0; ExecPass = 0; ExecTotal = 0; StaticPass = 0; StaticTotal = 0
                Answered = 0; ExpectedQ = 0; ValidationSummary = ''; FailedReqs = @(); FailedTests = @() }
        if ($r['generation_ms']) { $s.GenMs = [int]$r['generation_ms'] }
        if ($r['compile_ms']) { $s.CompMs = [int]$r['compile_ms'] }
        if ($r['repair_rounds']) { $s.Repairs = [int]$r['repair_rounds'] }
        $s.CompileStatus = if ($r['compile_status']) { [string]$r['compile_status'] } else { 'none' }
        $s.Compiled = ($s.CompileStatus -eq 'compiled')
        if ($s.Compiled) { $s.Compilation = [Math]::Max(3, 15 - 3 * [double]$s.Repairs) }
        if ($s.Subject -eq 'acd') {
            $a = if ($r['acd']) { $r['acd'] } else { @{} }
            $s.Answered = [int]$a['answered']; $s.ExpectedQ = [int]$a['expected_questions']
            $fails = [int]$a['validation_failures']
            $s.Compilation = if ($s.ExpectedQ -gt 0) { 15.0 * $s.Answered / $s.ExpectedQ * $(if ($fails -gt 0) { 0.5 } else { 1.0 }) } else { 0.0 }
            $s.Compiled = ($s.ExpectedQ -gt 0 -and $s.Answered -eq $s.ExpectedQ)
            $s.CompileStatus = "answered $($s.Answered)/$($s.ExpectedQ)"
            $s.ValidationSummary = [string]$a['validation_summary']
            if ($a['objective']) { $s.ObjCorrect = [int]$a['objective']['correct']; $s.ObjTotal = [int]$a['objective']['total'] }
            if ($a['executed']) { $s.ExecPass = [int]$a['executed']['passed']; $s.ExecTotal = [int]$a['executed']['total'] }
            if ($a['static']) { $s.StaticPass = [int]$a['static']['passed']; $s.StaticTotal = [int]$a['static']['total'] }
        }
        $f = if ($r['functional']) { $r['functional'] } else { @{} }
        $s.TestsRan = ($f['ran'] -eq $true)
        $s.Total = $(if ($f['total']) { [int]$f['total'] } elseif ($f['declared']) { [int]$f['declared'] } else { 0 })
        $s.Passed = [int]$f['passed']
        $s.NotRunReason = [string]$f['reason']
        foreach ($x in @($f['failed'])) { if ($x) { $s.FailedTests += ,@([string]$x['id'], [string]$x['message']) } }
        if ($s.TestsRan -and $s.Total -gt 0) { $s.Functional = 40.0 * $s.Passed / $s.Total }
        foreach ($q in @($r['requirements'])) {
            if (-not $q) { continue }
            $marks = [double]$q['marks']
            $s.PaperMarks += $marks
            $kind = [string]$q['kind']
            if ($kind -eq 'manual' -or $kind -eq 'static' -or $kind -eq 'untestable') { continue }   # reported, never counted as passed
            $s.AutoMarks += $marks
            if ([string]$q['status'] -eq 'verified') { $s.VerifiedMarks += $marks } elseif ([string]$q['status'] -eq 'failed') { $s.FailedReqs += [string]$q['id'] }
        }
        if ($s.AutoMarks -gt 0) { $s.Coverage = 20.0 * $s.VerifiedMarks / $s.AutoMarks }
        if ($r['quality']) { $s.QualityAuto = [double]$r['quality']['auto_points'] }
        if ($manual -and $manual.Contains($mk) -and $manual[$mk] -and $manual[$mk].Contains('quality')) { $s.QualityManual = [Math]::Max(0.0, [Math]::Min(5.0, [double]$manual[$mk]['quality'])) }
        $out += $s
    }
    # efficiency: relative to the fastest run on the same task, gated by correctness
    $fastest = @{}
    foreach ($s in $out) { $tm = $s.GenMs + $s.CompMs; if ($tm -gt 0 -and (-not $fastest.ContainsKey($s.Task) -or $tm -lt $fastest[$s.Task])) { $fastest[$s.Task] = $tm } }
    foreach ($s in $out) {
        $tm = $s.GenMs + $s.CompMs
        $frac = if ($s.TestsRan -and $s.Total -gt 0) { [double]$s.Passed / $s.Total } else { 0.0 }
        if ($fastest.ContainsKey($s.Task) -and $tm -gt 0) { $s.Efficiency = 10.0 * [Math]::Min(1.0, [double]$fastest[$s.Task] / $tm) * $frac }
    }
    return $out
}
function Get-DropBenchOverall($s) { return ($s.Functional + $s.Coverage + $s.Compilation + $s.QualityAuto + $s.QualityManual + $s.Efficiency) }

function Build-DropBenchReport($results, $manual) {
    $sc = @(Get-DropBenchScores $results $manual)
    $f1 = { param($d) ([double]$d).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }
    $pct = { param($d) (([double]$d) * 100).ToString('0', [Globalization.CultureInfo]::InvariantCulture) + '%' }
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('# Drop model benchmark report (Windows)')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("Generated $(Get-DropBenchISO). Source: results.jsonl - latest run per model and task. All models received identical task files and the same Drop pipeline.")
    [void]$md.AppendLine('')
    if ($sc.Count -eq 0) { [void]$md.AppendLine('No benchmark results recorded yet.'); return $md.ToString() }
    [void]$md.AppendLine('## Scoring methodology')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Component | Points | How it is computed |')
    [void]$md.AppendLine('|---|---|---|')
    [void]$md.AppendLine('| Functional correctness | 40 | passed tests / declared tests (0 and flagged when the tests did not run - never a pass) |')
    [void]$md.AppendLine('| Requirement coverage | 20 | marks of AUTOMATED requirements whose linked tests all passed / automated marks |')
    [void]$md.AppendLine('| Compilation (ACD: validity) | 15 | 15 first try, -3 per repair round (min 3), 0 if never compiles; ACD: 15 x answered / questions, halved when generated code fails validation |')
    [void]$md.AppendLine('| Code quality | 15 | 10 automated (deductions listed per run) + 5 manual rating from results/manual.json (0 if unassessed) |')
    [void]$md.AppendLine('| Efficiency | 10 | 10 x speed x functional fraction (speed alone scores nothing) |')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('Ranking is correctness-first: models are ordered by Correctness (functional + coverage, 60 points); only equal correctness is ordered by Overall, then speed. Manual and untestable requirements and static pattern checks are never counted as passed.')
    [void]$md.AppendLine('')
    foreach ($subj in @('oop', 'acd')) {
        $part = @($sc | Where-Object { $_.Subject -eq $subj })
        if ($part.Count -eq 0) { continue }
        [void]$md.AppendLine("## " + $(if ($subj -eq 'acd') { 'ACD (web: React, TypeScript, HTML/CSS)' } else { 'OOP (Java)' }))
        [void]$md.AppendLine('')
        $groups = [ordered]@{}
        foreach ($s in $part) { $k = "$($s.Provider)|$($s.Model)"; if (-not $groups.Contains($k)) { $groups[$k] = @() }; $groups[$k] += $s }
        $aggs = @()
        foreach ($k in $groups.Keys) {
            $rows = @($groups[$k])
            $avg = { param($fn) ($rows | ForEach-Object { & $fn $_ } | Measure-Object -Average).Average }
            $aggs += @{ Provider = $rows[0].Provider; Model = $rows[0].Model; Rows = $rows
                        Correctness = (& $avg { param($s) $s.Functional + $s.Coverage }); Overall = (& $avg { param($s) Get-DropBenchOverall $s }); AvgMs = (& $avg { param($s) [double]($s.GenMs + $s.CompMs) })
                        Passed = ($rows | Measure-Object -Property Passed -Sum).Sum; Total = ($rows | Measure-Object -Property Total -Sum).Sum
                        CompileRate = [double]@($rows | Where-Object { $_.Compiled }).Count / $rows.Count }
        }
        $ordered = @($aggs | Sort-Object @{ Expression = { [Math]::Round($_.Correctness, 1) }; Descending = $true }, @{ Expression = { [Math]::Round($_.Overall, 2) }; Descending = $true }, @{ Expression = { $_.AvgMs } })
        $allTasks = @($part | ForEach-Object { $_.Task } | Sort-Object -Unique)
        [void]$md.AppendLine('### Overall ranking')
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| # | Model | Correctness /60 | Overall /100 | ' + $(if ($subj -eq 'acd') { 'Automated results' } else { 'Functional tests' }) + ' | Paper marks verified | ' + $(if ($subj -eq 'acd') { 'Complete answers' } else { 'Compile success' }) + ' | Avg generation s | Avg repairs |')
        [void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|')
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            $a = $ordered[$i]
            $partial = if ($a.Rows.Count -lt $allTasks.Count) { " (!) $($a.Rows.Count)/$($allTasks.Count) tasks" } else { '' }
            $notRun = @($a.Rows | Where-Object { -not $_.TestsRan }).Count
            $verified = ($a.Rows | Measure-Object -Property VerifiedMarks -Sum).Sum; $paperM = ($a.Rows | Measure-Object -Property PaperMarks -Sum).Sum
            $tests = if ($a.Total -eq 0) { 'not run' } else { "$($a.Passed)/$($a.Total) ($(& $pct ([double]$a.Passed / $a.Total)))" + $(if ($notRun -gt 0) { " - $notRun task(s) not run" } else { '' }) }
            $gen = (($a.Rows | ForEach-Object { $_.GenMs } | Measure-Object -Average).Average) / 1000
            $rep = ($a.Rows | ForEach-Object { $_.Repairs } | Measure-Object -Average).Average
            [void]$md.AppendLine("| $($i + 1) | $($a.Model)$(if ($a.Provider -eq 'opencode_go') { ' (cloud)' } else { '' }) | $(& $f1 $a.Correctness) / 60 | $(& $f1 $a.Overall)$partial | $tests | $(if ($paperM -eq 0) { '-' } else { & $pct ($verified / $paperM) }) | $(& $pct $a.CompileRate) | $(& $f1 $gen) | $(& $f1 $rep) |")
        }
        [void]$md.AppendLine('')
        [void]$md.AppendLine('### Per-task results')
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Task | Model | Score | ' + $(if ($subj -eq 'acd') { 'Answers present' } else { 'Compilation' }) + ' | Tests passed | Gen s | Note |')
        [void]$md.AppendLine('|---|---|---|---|---|---|---|')
        foreach ($t in $allTasks) {
            foreach ($a in $ordered) {
                $s = $a.Rows | Where-Object { $_.Task -eq $t } | Select-Object -First 1
                if (-not $s) { continue }
                $tests = if ($s.TestsRan) { "$($s.Passed)/$($s.Total)" } else { 'NOT RUN' }
                [void]$md.AppendLine("| $t | $($a.Model) | $(& $f1 (Get-DropBenchOverall $s)) | $($s.CompileStatus)$(if ($s.Repairs -gt 0) { " ($($s.Repairs) repair)" } else { '' }) | $tests | $(& $f1 ($s.GenMs / 1000)) | $(if ($s.TestsRan) { '' } else { $s.NotRunReason.Replace('|', '/') }) |")
            }
        }
        [void]$md.AppendLine('')
        if ($subj -eq 'acd') {
            [void]$md.AppendLine('### ACD evidence, kept separate')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('Objective answers are graded against the key; executed checks were actually run; static checks are pattern checks and are NOT tests; manual rubric marks come only from manual.json. A syntax/static pass of generated code is not proof it behaves correctly.')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Model | Task | Objective (auto-graded) | Executed checks | Static checks (not tests) | Generated-code validation | Answers present |')
            [void]$md.AppendLine('|---|---|---|---|---|---|---|')
            foreach ($a in $ordered) { foreach ($s in $a.Rows) { [void]$md.AppendLine("| $($a.Model) | $($s.Task) | $($s.ObjCorrect)/$($s.ObjTotal) | $($s.ExecPass)/$($s.ExecTotal) | $($s.StaticPass)/$($s.StaticTotal) | $(if ($s.ValidationSummary) { $s.ValidationSummary } else { '-' }) | $($s.Answered)/$($s.ExpectedQ) |") } }
            [void]$md.AppendLine('')
        }
        [void]$md.AppendLine('### Failed requirements and tests')
        [void]$md.AppendLine('')
        $any = $false
        foreach ($a in $ordered) {
            foreach ($s in $a.Rows) {
                if ($s.FailedReqs.Count -eq 0 -and $s.FailedTests.Count -eq 0) { continue }
                $any = $true
                $ft = (@($s.FailedTests | Select-Object -First 6 | ForEach-Object { "$($_[0]): $($_[1])" })) -join ' | '
                [void]$md.AppendLine("- $($a.Model) / $($s.Task): requirements $(if ($s.FailedReqs.Count -eq 0) { '-' } else { $s.FailedReqs -join ', ' }), $($s.FailedTests.Count) failing test(s)$(if ($ft) { ' - ' + $ft } else { '' })")
            }
        }
        if (-not $any) { [void]$md.AppendLine('No failing tests recorded.') }
        [void]$md.AppendLine('')
    }
    [void]$md.AppendLine('## Conditions')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('Ollama runs include Drop''s deterministic code fixers, so scores describe model + Drop pipeline, not the raw model. Task input hashes must be identical across models:')
    [void]$md.AppendLine('')
    foreach ($t in @($sc | ForEach-Object { $_.Task } | Sort-Object -Unique)) {
        [void]$md.AppendLine("- ${t}: " + ((@($sc | Where-Object { $_.Task -eq $t } | ForEach-Object { $_.InputHash } | Sort-Object -Unique)) -join ', '))
    }
    return $md.ToString()
}
function Write-DropBenchReport {
    Initialize-DropBenchDirs
    $manual = $null
    $mp = Join-Path (Join-Path (Get-DropBenchDir) 'results') 'manual.json'
    if (Test-Path -LiteralPath $mp) { try { $manual = ConvertTo-DropHashtable (Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json) } catch { } }
    $md = Build-DropBenchReport (Get-DropBenchRecords) $manual
    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ssZ')
    $path = Join-Path (Join-Path (Get-DropBenchDir) 'reports') "report-$stamp.md"
    [System.IO.File]::WriteAllText($path, $md, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Background entry point for the benchmark window. P: RunId, Base, ManualCtx, RamBytes, OopPerTask, OopMode, Careful, OpenCode,
# TaskIds, Models (@{Provider;Name}). Log lines go to Sync.Log (read by the UI timer); Sync.Cancel stops between runs.
function Invoke-DropBenchJob($P, $Sync) {
    $infos = @{}
    if (@($P.Models | Where-Object { $_.Provider -eq 'ollama' }).Count -gt 0) { $infos = Get-DropBenchOllamaInfo $P.Base }
    $models = @($P.Models | ForEach-Object { @{ Provider = $_.Provider; Name = $_.Name; Info = $(if ($_.Provider -eq 'ollama' -and $infos.ContainsKey($_.Name)) { $infos[$_.Name] } else { @{} }) } })
    $tasks = @(Get-DropBenchTasks | Where-Object { @($P.TaskIds) -contains $_.Id })
    $ctx = @{ RunId = $P.RunId; Base = $P.Base; ManualCtx = [int]$P.ManualCtx; RamBytes = [int64]$P.RamBytes; OopPerTask = [bool]$P.OopPerTask; OopMode = [string]$P.OopMode; Careful = [bool]$P.Careful
              OpenCode = $P.OpenCode
              Log = { param($m) [void]$Sync.Log.Add([string]$m) }
              Cancelled = { return [bool]$Sync.Cancel } }
    try { Invoke-DropBenchRunAll $ctx $models $tasks } catch { [void]$Sync.Log.Add('! benchmark failed: ' + $_.Exception.Message) }
    return @{ Ok = $true }
}

# installed Qwen-family models (same rule as the popup: details.family / families first, then the name; cloud models skipped)
function Get-DropBenchOllamaModels([string]$base) {
    $out = @()
    try {
        $o = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/api/tags') -TimeoutSec 5
        foreach ($m in @($o.models)) {
            $n = [string]$m.name
            if (-not $n -or $n -match 'cloud') { continue }
            $fam = @()
            if ($m.details) { if ($m.details.family) { $fam += [string]$m.details.family }; if ($m.details.families) { $fam += @($m.details.families) } }
            if ((($fam -join ' ') -match 'qwen') -or ($n -match 'qwen')) { $out += $n }
        }
    } catch { }
    return ($out | Sort-Object)
}
