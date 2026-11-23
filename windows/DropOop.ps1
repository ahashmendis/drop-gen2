# DropOop.ps1 - UI-free OOP code of Drop for Windows: small-context Ollama session, no-thinking single request,
# per-task generation, deterministic javac / paper fixers, the shared generate -> fix -> compile -> repair pipeline.
# Port of the macOS Swift code in install-drop.sh (AcdOllamaSession, OopPerTask, AppDelegate.javacFixes/paperFixes/
# semanticFindings/howToTestBlock, DropPipeline). Dot-sourced by DropCore.ps1. Definitions only; no WinForms.
# Windows PowerShell 5.1 compatible (no ?: ?? -Parallel ForEach-Object -Parallel); ASCII only.

# ---- data locations (test hooks: DROP_DATA_DIR / DROP_ACD_DIR / DROP_BENCH_DIR / DROP_RAM_BYTES) ----------------
function Get-DropDataDir {
    if ($env:DROP_DATA_DIR) { return $env:DROP_DATA_DIR }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'Drop') }
    return (Join-Path $HOME '.config/Drop')
}
function Get-DropDesktopDir {
    if ($env:DROP_DESKTOP_DIR) { return $env:DROP_DESKTOP_DIR }
    try { $d = [Environment]::GetFolderPath('Desktop'); if ($d) { return $d } } catch { }
    return (Join-Path $HOME 'Desktop')
}

# ---- settings (its own file, never config.json: subject, careful mode, per-task) -------------------------------
function Get-DropSettingsPath { return (Join-Path (Get-DropDataDir) 'settings.json') }
function Get-DropSetting([string]$name, $default) {
    $p = Get-DropSettingsPath
    if (-not (Test-Path -LiteralPath $p)) { return $default }
    try {
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        if ($null -ne $j.$name) { return $j.$name }
    } catch { }
    return $default
}
function Set-DropSetting([string]$name, $value) {
    $p = Get-DropSettingsPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $p) {
        try {
            $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        } catch { }
    }
    $o[$name] = $value
    ($o | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding UTF8
}
function Get-DropSubject { $s = [string](Get-DropSetting 'subject' 'oop'); if ($s -eq 'acd') { return 'acd' } else { return 'oop' } }
function Set-DropSubject([string]$s) { if ($s -ne 'acd') { $s = 'oop' }; Set-DropSetting 'subject' $s }
function Get-DropCareful { return [bool](Get-DropSetting 'acdCareful' $false) }
function Get-DropOopPerTask { return [bool](Get-DropSetting 'oopPerTask' $false) }

# ---- memory / context sizing for the small-context session --------------------------------------------------
function Get-DropRamBytes {
    if ($env:DROP_RAM_BYTES) { try { return [int64]$env:DROP_RAM_BYTES } catch { } }
    try { return [int64]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory) } catch { }
    return [int64]8GB
}
# Same policy as Drop.ps1 Get-OllamaContextCeiling, but parameterised (the runspace has no $script:Config).
function Get-DropCtxCeiling([int]$manual, [int64]$ramBytes) {
    if ($manual -gt 0) { return 65536 }
    $gb = [int](($ramBytes + 536870912) / 1GB)
    if ($gb -lt 16) { return 16384 }
    if ($gb -lt 32) { return 16384 }
    return 65536
}

# ---- Ollama session: small contexts, per-request thinking, unload under memory pressure, one retry on 5xx ------
# Port of AcdOllamaSession. Hashtable with: Base, Model, Manual, RamBytes, OnProgress, RequestCount, UnloadCount.
function New-DropSession([string]$base, [string]$model, [int]$manualCtx = 0, [int64]$ramBytes = 0) {
    if ($ramBytes -le 0) { $ramBytes = Get-DropRamBytes }
    return @{ Base = $base.TrimEnd('/'); Model = $model; Manual = $manualCtx; RamBytes = $ramBytes
              OnProgress = $null; RequestCount = 0; UnloadCount = 0; Cancel = $null }
}

$script:DropHttp = $null
function Get-DropHttpClient {
    if ($null -eq $script:DropHttp) {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $script:DropHttp = New-Object System.Net.Http.HttpClient
        $script:DropHttp.Timeout = [TimeSpan]::FromSeconds(900)
    }
    return $script:DropHttp
}

function Send-DropJson([string]$url, $bodyObj, [int]$timeoutSec = 900) {
    # -> @{ Status = int; Text = string }; Status 0 + Text = transport error message
    $json = $bodyObj | ConvertTo-Json -Depth 6 -Compress
    $c = Get-DropHttpClient
    try {
        $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
        $cts = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds($timeoutSec))
        $resp = $c.PostAsync($url, $content, $cts.Token).GetAwaiter().GetResult()
        $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return @{ Status = [int]$resp.StatusCode; Text = $txt }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.Threading.Tasks.TaskCanceledException] -or $e -is [System.OperationCanceledException]) { return @{ Status = 0; Text = 'Request timed out' } }
        if ($e -is [System.Net.Sockets.SocketException] -and $e.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
            return @{ Status = 0; Text = 'Connection refused - is the Ollama app running?' }
        }
        return @{ Status = 0; Text = ('Network error: ' + $e.Message) }
    }
}

function Format-DropHttpError([int]$status, [string]$body) {
    $extra = ''
    if ($body) {
        $m = [regex]::Match($body, '"error"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if (-not $m.Success) { $m = [regex]::Match($body, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') }
        if ($m.Success) { $extra = ' - ' + (($m.Groups[1].Value -replace '\\n', ' ' -replace '\\"', '"')) }
        if ($extra.Length -gt 160) { $extra = $extra.Substring(0, 160) }
    }
    if ($status -ge 500) { return "Provider server error ($status)$extra" }
    if ($status -eq 404) { return "Endpoint or model not found (404)$extra" }
    if ($status -eq 400) { return "Invalid request (400)$extra" }
    return "HTTP $status$extra"
}

# size in bytes of the loaded model (/api/ps); $null when unknown
function Get-DropResidentBytes($s) {
    try {
        $o = Invoke-RestMethod -Uri ($s.Base + '/api/ps') -TimeoutSec 5
        $ms = @($o.models)
        if ($ms.Count -eq 0) { return $null }
        $m = $ms | Where-Object { $_.name -eq $s.Model -or $_.model -eq $s.Model } | Select-Object -First 1
        if (-not $m) { $m = $ms[0] }
        if ($null -ne $m.size) { return [int64]$m.size }
    } catch { }
    return $null
}

# Ollama unload request (keep_alive 0, no prompt). Counted; failures ignored (quiet laptop is best effort).
function Invoke-DropUnload($s) {
    try { [void](Send-DropJson ($s.Base + '/api/generate') @{ model = $s.Model; keep_alive = 0 } 30) } catch { }
    $s.UnloadCount = [int]$s.UnloadCount + 1
}
# Always call when the run ends (success or failure): nothing stays loaded.
function Close-DropSession($s) { Invoke-DropUnload $s }

# request: @{ Prompt; Label; Kind; NumPredict; Temperature; Think } -> @{ Text; Error }
function Invoke-DropSessionGenerate($s, $r) {
    $limit = [int64]([double]$s.RamBytes * 0.6)
    $res = Get-DropResidentBytes $s
    if ($null -ne $res -and $res -gt $limit) { Invoke-DropUnload $s }
    $cap = [Math]::Min(32768, $(if ([int]$s.Manual -gt 0) { [int]$s.Manual } else { Get-DropCtxCeiling 0 $s.RamBytes }))
    $promptTokens = [int]($r.Prompt.Length / 3)
    $ctx = 2048
    while ($ctx -lt ($promptTokens + $r.NumPredict + 300) -and $ctx -lt $cap) { $ctx *= 2 }
    $ctx = [Math]::Min($ctx, $cap)
    if (($promptTokens + 300 + 256) -gt $ctx) {
        return @{ Text = ''; Error = "this request needs about $promptTokens tokens, above the context limit ($ctx); raise Qwen ctx in Settings" }
    }
    $np = [Math]::Min([int]$r.NumPredict, [Math]::Max(256, $ctx - $promptTokens - 300))
    $attempt = 0
    while ($true) {
        $attempt++
        $s.RequestCount = [int]$s.RequestCount + 1
        if ($s.OnProgress) { & $s.OnProgress ($r.Label) }
        $body = @{ model = $s.Model; prompt = $r.Prompt; stream = $false; think = [bool]$r.Think; keep_alive = '2m'
                   options = @{ num_ctx = $ctx; temperature = $r.Temperature; num_predict = $np } }
        $resp = Send-DropJson ($s.Base + '/api/generate') $body
        if ($resp.Status -eq 0) { return @{ Text = ''; Error = $resp.Text } }
        if ($resp.Status -ne 200) {
            if ($resp.Status -ge 500 -and $attempt -eq 1) {   # memory pressure: unload, wait, reload once
                Invoke-DropUnload $s
                Start-Sleep -Seconds 3
                continue
            }
            $raw = $resp.Text; if ($raw.Length -gt 600) { $raw = $raw.Substring(0, 600) }
            return @{ Text = ''; Error = (Format-DropHttpError $resp.Status $raw) }
        }
        try { $o = $resp.Text | ConvertFrom-Json } catch { return @{ Text = ''; Error = 'unreadable Ollama response' } }
        if ($o.error) { return @{ Text = ''; Error = ('Ollama: ' + [string]$o.error) } }
        $answer = [string]$o.response
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ([string]$o.done_reason -eq 'length') {
                $why = "no answer within the $np-token budget"
                if ($r.Think) { $why += ' (the model spent it thinking; turn Careful mode off)' }
                return @{ Text = ''; Error = $why }
            }
            return @{ Text = ''; Error = 'empty response' }
        }
        return @{ Text = $answer; Error = $null }
    }
}

function New-DropRequest([string]$prompt, [string]$label, [string]$kind, [int]$numPredict, [double]$temperature, [bool]$think) {
    return @{ Prompt = $prompt; Label = $label; Kind = $kind; NumPredict = $numPredict; Temperature = $temperature; Think = $think }
}

# ---- text helpers ---------------------------------------------------------------------------------------------
function Get-DropSortedKeys($keys) {
    $a = [string[]]@($keys | ForEach-Object { [string]$_ })
    [Array]::Sort($a, [StringComparer]::Ordinal)
    return $a
}
function Get-DropPackageName([string]$body) {
    foreach ($l in ($body -split "`r?`n")) {
        $t = $l.Trim()
        if ($t.StartsWith('package ')) { return $t.Substring(8).Replace(';', '').Trim() }
    }
    return $null
}
function Find-DropMatchingBrace([string]$s, [int]$open) {
    $depth = 0
    for ($i = $open; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $i } }
    }
    return -1
}
function ConvertTo-DropFixBlock($edited) {
    # "// ===== FILE: path =====\nbody" joined with "\n", keys sorted (mac parity)
    $parts = @()
    foreach ($k in (Get-DropSortedKeys $edited.Keys)) { $parts += ("// ===== FILE: $k =====`n" + [string]$edited[$k]) }
    return ($parts -join "`n")
}

# ---- javac-driven fixes (Ollama only) -------------------------------------------------------------------------
$script:DropWellKnownImports = @{
    'Collectors' = 'java.util.stream.Collectors'; 'Stream' = 'java.util.stream.Stream'; 'IntStream' = 'java.util.stream.IntStream'
    'ConcurrentHashMap' = 'java.util.concurrent.ConcurrentHashMap'; 'CopyOnWriteArrayList' = 'java.util.concurrent.CopyOnWriteArrayList'
    'AtomicLong' = 'java.util.concurrent.atomic.AtomicLong'; 'AtomicInteger' = 'java.util.concurrent.atomic.AtomicInteger'
    'LocalDate' = 'java.time.LocalDate'; 'LocalDateTime' = 'java.time.LocalDateTime'; 'Duration' = 'java.time.Duration'; 'Instant' = 'java.time.Instant'
    'BigDecimal' = 'java.math.BigDecimal'; 'BigInteger' = 'java.math.BigInteger'
    'List' = 'java.util.List'; 'Map' = 'java.util.Map'; 'Set' = 'java.util.Set'; 'ArrayList' = 'java.util.ArrayList'; 'HashMap' = 'java.util.HashMap'
    'HashSet' = 'java.util.HashSet'; 'LinkedList' = 'java.util.LinkedList'; 'TreeMap' = 'java.util.TreeMap'; 'LinkedHashMap' = 'java.util.LinkedHashMap'
    'Collection' = 'java.util.Collection'; 'Collections' = 'java.util.Collections'; 'Comparator' = 'java.util.Comparator'; 'Optional' = 'java.util.Optional'
    'Objects' = 'java.util.Objects'; 'Arrays' = 'java.util.Arrays'; 'Iterator' = 'java.util.Iterator'; 'Deque' = 'java.util.Deque'; 'ArrayDeque' = 'java.util.ArrayDeque'
    'ResponseEntity' = 'org.springframework.http.ResponseEntity'; 'HttpStatus' = 'org.springframework.http.HttpStatus'; 'MediaType' = 'org.springframework.http.MediaType'
    'RestController' = 'org.springframework.web.bind.annotation.RestController'; 'RequestMapping' = 'org.springframework.web.bind.annotation.RequestMapping'
    'GetMapping' = 'org.springframework.web.bind.annotation.GetMapping'; 'PostMapping' = 'org.springframework.web.bind.annotation.PostMapping'
    'PutMapping' = 'org.springframework.web.bind.annotation.PutMapping'; 'DeleteMapping' = 'org.springframework.web.bind.annotation.DeleteMapping'
    'RequestBody' = 'org.springframework.web.bind.annotation.RequestBody'; 'RequestParam' = 'org.springframework.web.bind.annotation.RequestParam'
    'PathVariable' = 'org.springframework.web.bind.annotation.PathVariable'; 'ExceptionHandler' = 'org.springframework.web.bind.annotation.ExceptionHandler'
    'RestControllerAdvice' = 'org.springframework.web.bind.annotation.RestControllerAdvice'; 'ResponseStatus' = 'org.springframework.web.bind.annotation.ResponseStatus'
    'Service' = 'org.springframework.stereotype.Service'; 'Repository' = 'org.springframework.stereotype.Repository'; 'Component' = 'org.springframework.stereotype.Component'
}

# Fixes what javac names exactly (missing import, non-existent getType(), generic mismatch, ...) without a model call.
function Invoke-DropJavacFixes([string]$answer, $starter, [string]$errs) {
    $files = Get-DropParsedFiles $answer
    if ($files.Count -eq 0) { return $answer }
    $merged = @{}
    $allText = New-Object System.Text.StringBuilder
    if ($starter) { foreach ($k in @($starter.Keys)) { $merged[[string]$k] = [string]$starter[$k]; [void]$allText.Append([string]$starter[$k]).Append("`n") } }
    foreach ($k in @($files.Keys)) { $merged[[string]$k] = [string]$files[$k]; [void]$allText.Append([string]$files[$k]).Append("`n") }
    $all = $allText.ToString()
    $project = @{}
    foreach ($k in @($merged.Keys)) {
        if (-not $k.EndsWith('.java')) { continue }
        $pkg = Get-DropPackageName $merged[$k]
        if (-not $pkg) { continue }
        $simple = [System.IO.Path]::GetFileNameWithoutExtension($k)
        $project[$simple] = "$pkg.$simple"
    }
    $blocks = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($errs -split "`r?`n")) {
        $m = [regex]::Match($line, '^(\S+\.java):(\d+): error: (.*)$')
        if ($m.Success) {
            $blocks.Add(@{ File = $m.Groups[1].Value.Replace('\', '/'); Line = [int]$m.Groups[2].Value; Msg = $m.Groups[3].Value; Text = $line })
        } elseif ($blocks.Count -gt 0) { $blocks[$blocks.Count - 1].Text += "`n" + $line }
    }
    $edited = @{}
    $listLong = $all.Contains('List<Long>')
    foreach ($b in $blocks) {
        if (-not $files.ContainsKey($b.File)) { continue }            # only files the answer wrote can be edited
        $kind = ''; $name = ''
        $sm = [regex]::Match($b.Text, 'symbol:\s+(class|method|variable)\s+(\w+)')
        if ($sm.Success) { $kind = $sm.Groups[1].Value; $name = $sm.Groups[2].Value }
        $body = if ($edited.ContainsKey($b.File)) { [string]$edited[$b.File] } else { [string]$files[$b.File] }
        $before = $body
        $done = $false
        $msg = [string]$b.Msg
        $ln = [int]$b.Line
        # a) missing import of a JDK / Spring name or a class the project defines
        if ($msg -eq 'cannot find symbol' -and $kind -eq 'class') {
            $fq = $null
            if ($script:DropWellKnownImports.ContainsKey($name)) { $fq = $script:DropWellKnownImports[$name] }
            elseif ($project.ContainsKey($name)) { $fq = $project[$name] }
            if ($fq) {
                $done = $true
                $pkgOfFq = $fq.Substring(0, $fq.LastIndexOf('.'))
                if ((Get-DropPackageName $body) -ne $pkgOfFq -and -not $body.Contains("import $fq;") -and -not $body.Contains("import $pkgOfFq.*;")) {
                    $lines = New-Object System.Collections.Generic.List[string]
                    $lines.AddRange([string[]]($body -split "`n"))
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i].Trim().StartsWith('package ')) { $lines.Insert($i + 1, "import $fq;"); $body = ($lines -join "`n"); break }
                    }
                }
            }
        }
        # b) getType(): no such accessor, the simple class name is the type
        if (-not $done -and $msg -eq 'cannot find symbol' -and $kind -eq 'method' -and $name -eq 'getType' -and -not [regex]::IsMatch($all, '\bgetType\s*\(\s*\)\s*\{')) {
            $done = $true
            $body = $body.Replace('.getType()', '.getClass().getSimpleName()')
        }
        # c) a primitive compared with null can never be null: drop that comparison on the reported line
        if (-not $done -and $msg.StartsWith('bad operand types') -and $b.Text.Contains('<null>') -and $ln -ge 1) {
            $done = $true
            $lines = (Add-DropUtilImport $body) -split "`r?`n"
            if ($ln -le $lines.Count) {
                $l = $lines[$ln - 1]
                foreach ($pat in @('\b[\w.]+(?:\(\))?\s*==\s*null\s*\|\|\s*', '\s*\|\|\s*[\w.]+(?:\(\))?\s*==\s*null', '\b[\w.]+(?:\(\))?\s*!=\s*null\s*&&\s*', '\s*&&\s*[\w.]+(?:\(\))?\s*!=\s*null')) {
                    $l = [regex]::Replace($l, $pat, '')
                }
                $lines[$ln - 1] = $l
                $body = ($lines -join "`n")
            }
        }
        # d) a Collection assigned to a List/Set variable: copy it into the declared type
        if (-not $done -and [regex]::IsMatch($msg, '^incompatible types: (Collection|Set)<(\w+)> cannot be converted to (List|Set)<') -and $ln -ge 1) {
            $done = $true
            $lines = (Add-DropUtilImport $body) -split "`r?`n"
            if ($ln -le $lines.Count) {
                $target = if ($msg.Contains('converted to Set<')) { 'HashSet' } else { 'ArrayList' }
                $re = New-Object System.Text.RegularExpressions.Regex '=\s*(?!new\s)(.+?);'
                $lines[$ln - 1] = $re.Replace($lines[$ln - 1], ('= new ' + $target + '<>($1);'), 1)
                $body = ($lines -join "`n")
            }
        }
        # e) if (!Math.toIntExact(x)) { ... }: toIntExact already throws on overflow
        if (-not $done -and $msg.StartsWith("bad operand type int for unary operator '!'") -and $ln -ge 1) {
            $done = $true
            $lines = (Add-DropUtilImport $body) -split "`r?`n"
            if ($ln -le $lines.Count) {
                $re = New-Object System.Text.RegularExpressions.Regex 'if\s*\(\s*!\s*(Math\.toIntExact\([^)]*\))\s*\)\s*\{[^{}]*\}'
                $lines[$ln - 1] = $re.Replace($lines[$ln - 1], '$1;', 1)
                $body = ($lines -join "`n")
            }
        }
        # f) a constructor assigns this.<name> but the field was never declared
        if (-not $done -and $msg -eq 'cannot find symbol' -and $kind -eq 'variable') {
            $cm = [regex]::Match($body, '\(([^)]*\b([\w<>\[\]]+)\s+' + [regex]::Escape($name) + '\b[^)]*)\)\s*\{[^}]*this\.' + [regex]::Escape($name) + '\s*=')
            if ($cm.Success -and -not $body.Contains('private final ' + $cm.Groups[2].Value + ' ' + $name + ';')) {
                $done = $true
                $type = $cm.Groups[2].Value
                $head = $body.Substring(0, $cm.Index)
                $cls = [regex]::Matches($head, 'class\s+\w+[^{]*\{')
                if ($cls.Count -gt 0) {
                    $last = $cls[$cls.Count - 1]
                    $at = $last.Index + $last.Length
                    $body = $body.Substring(0, $at) + "`n  private final $type $name;" + $body.Substring($at)
                }
            }
        }
        # g) a List<Long> field built as strings: pass the list itself
        if (-not $done -and ($msg.StartsWith('incompatible types') -or $msg.Contains('cannot infer type-variable')) -and $listLong) {
            $done = $true
            $body = [regex]::Replace($body, '(\w+)\.stream\(\)\.map\((?:Long::toString|String::valueOf)\)\.collect\(Collectors\.toList\(\)\)', '$1')
        }
        if ($body -ne $before) { $edited[$b.File] = $body }
    }
    if ($edited.Count -eq 0) { return $answer }
    return (Merge-DropFixes $answer (ConvertTo-DropFixBlock $edited))
}

# @GetMapping("/plan?capacity=...&urgentOnly=false") copies a query string into the path: keep only the path.
function Fix-DropMappingQueryStrings([string]$answer) {
    return [regex]::Replace($answer, '(@(?:Get|Post|Put|Delete|Patch|Request)Mapping\(\s*(?:value\s*=\s*)?")(/[^"?]*)\?[^"]*(")', '$1$2$3')
}

# `for (X m : missions) { skipped.add(m.getId()); }` after a selection loop adds EVERY mission as skipped.
function Fix-DropSkippedLoop([string]$answer) {
    $lone = New-Object System.Text.RegularExpressions.Regex '\n[ \t]*for\s*\(\s*[\w<>]+\s+(\w+)\s*:\s*(\w+)\s*\)\s*\{\s*skipped\.add\(\1\.getId\(\)\);\s*\}[ \t]*(?=\n)'
    $lm = $lone.Match($answer)
    if (-not $lm.Success) { return $answer }
    $listVar = $lm.Groups[2].Value
    $head = $answer.Substring(0, $lm.Index)
    if ($head.Contains('skipped.add(')) { return $answer }        # a real skip branch already exists
    $sel = New-Object System.Text.RegularExpressions.Regex ('for\s*\(\s*[\w<>]+\s+(\w+)\s*:\s*' + [regex]::Escape($listVar) + '\s*\)\s*\{[\s\S]*?if\s*\([^\n{]*\)\s*\{\s*continue;\s*\}')
    $sm = $sel.Match($head)
    if (-not $sm.Success) { return $answer }
    $v = $sm.Groups[1].Value
    $fixedHead = $sm.Value
    $i = $fixedHead.LastIndexOf('{ continue; }')
    $len = '{ continue; }'.Length
    if ($i -lt 0) { $i = $fixedHead.LastIndexOf('{continue;}'); $len = '{continue;}'.Length }
    if ($i -lt 0) { return $answer }
    $fixedHead = $fixedHead.Substring(0, $i) + "{ skipped.add($v.getId()); continue; }" + $fixedHead.Substring($i + $len)
    $newHead = $head.Substring(0, $sm.Index) + $fixedHead + $head.Substring($sm.Index + $sm.Length)
    return $newHead + $answer.Substring($lm.Index + $lm.Length)
}

# private static class ApiResponse { ApiResponse(String code, String message) } duplicates the starter's ApiError record.
function Fix-DropInventedWrapper([string]$answer, $starter) {
    $files = Get-DropParsedFiles $answer
    $records = @{}
    $recRe = New-Object System.Text.RegularExpressions.Regex 'record\s+(\w+)\s*\(([^)]*)\)'
    if ($starter) {
        foreach ($sk in (Get-DropSortedKeys $starter.Keys)) {
            foreach ($m in $recRe.Matches([string]$starter[$sk])) {
                $types = @()
                foreach ($c in ($m.Groups[2].Value -split ',')) { $t = ($c.Trim() -split ' ' | Where-Object { $_ -ne '' } | Select-Object -First 1); $types += [string]$t }
                $records[$m.Groups[1].Value] = $types
            }
        }
    }
    if ($records.Count -eq 0) { return $answer }
    $edited = @{}
    $clsRe = New-Object System.Text.RegularExpressions.Regex '\n[ \t]*private\s+static\s+class\s+(\w+)\s*\{'
    foreach ($path in (Get-DropSortedKeys $files.Keys)) {
        $body = [string]$files[$path]
        $b = $body
        $ms = $clsRe.Matches($body)
        for ($i = $ms.Count - 1; $i -ge 0; $i--) {
            $m = $ms[$i]
            $name = $m.Groups[1].Value
            $close = Find-DropMatchingBrace $b ($m.Index + $m.Length - 1)
            if ($close -lt 0) { continue }
            $cls = $b.Substring($m.Index, $close + 1 - $m.Index)
            $cm = [regex]::Match($cls, '(?:public\s+)?' + [regex]::Escape($name) + '\s*\(([^)]*)\)')
            if (-not $cm.Success) { continue }
            $types = @()
            foreach ($c in ($cm.Groups[1].Value -split ',')) { $t = ($c.Trim() -split ' ' | Where-Object { $_ -ne '' } | Select-Object -First 1); $types += [string]$t }
            $rec = $null
            foreach ($rk in (Get-DropSortedKeys $records.Keys)) {
                if ($records[$rk].Count -gt 0 -and (($records[$rk] -join '|') -eq ($types -join '|'))) { $rec = $rk; break }
            }
            if (-not $rec) { continue }
            $nb = $b.Remove($m.Index, $close + 1 - $m.Index)
            $nb = [regex]::Replace($nb, '\b' + [regex]::Escape($name) + '\b', $rec)
            $b = $nb
        }
        if ($b -ne $body) { $edited[$path] = $b }
    }
    if ($edited.Count -eq 0) { return $answer }
    return (Merge-DropFixes $answer (ConvertTo-DropFixBlock $edited))
}

# A controller method that returns ApiError as a success response (the model wrapped the result) delegates to the service.
function Fix-DropControllerDelegation([string]$answer, $starter, [string]$paper) {
    $files = Get-DropParsedFiles $answer
    $svc = @{}
    $sigRe = New-Object System.Text.RegularExpressions.Regex 'public\s+([\w<>,?\[\] ]+?)\s+(\w+)\s*\((?:[^()]|\([^()]*\))*\)\s*\{'
    $src = @{}
    if ($starter) { foreach ($k in @($starter.Keys)) { $src[[string]$k] = [string]$starter[$k] } }
    foreach ($k in @($files.Keys)) { $src[[string]$k] = [string]$files[$k] }
    foreach ($path in (Get-DropSortedKeys $src.Keys)) {
        if (-not $path.EndsWith('Service.java')) { continue }
        foreach ($m in $sigRe.Matches($src[$path])) { $svc[$m.Groups[2].Value] = $m.Groups[1].Value.Trim() }
    }
    if ($svc.Count -eq 0) { return $answer }
    $key = ''
    $km = [regex]::Match($paper, '(?i)object containing (\w+)')
    if ($km.Success) { $key = $km.Groups[1].Value }
    $methRe = New-Object System.Text.RegularExpressions.Regex '(@(?:Get|Post|Put|Delete)Mapping(?:\([^)]*\))?)\s+public\s+([\w<>,?\[\] ]+?)\s+(\w+)\s*\(((?:[^()]|\([^()]*\))*)\)\s*\{'
    $edited = @{}
    foreach ($path in (Get-DropSortedKeys $files.Keys)) {
        $body = [string]$files[$path]
        if (-not [regex]::IsMatch($body, '@RestController\b(?!Advice)')) { continue }
        $b = $body
        $ms = $methRe.Matches($body)
        for ($i = $ms.Count - 1; $i -ge 0; $i--) {
            $m = $ms[$i]
            $annotation = $m.Groups[1].Value; $retType = $m.Groups[2].Value; $name = $m.Groups[3].Value; $params = $m.Groups[4].Value
            if (-not $retType.Contains('ApiError')) { continue }
            $close = Find-DropMatchingBrace $b ($m.Index + $m.Length - 1)
            if ($close -lt 0) { continue }
            $innerStart = $m.Index + $m.Length
            $inner = $b.Substring($innerStart, $close - $innerStart)
            $cm = [regex]::Match($inner, 'service\.(\w+)\(([^)]*)\)')
            if (-not $cm.Success) { continue }
            $call = $cm.Groups[1].Value
            if (-not $svc.ContainsKey($call)) { continue }
            $ret = $svc[$call]
            $args0 = $cm.Groups[2].Value
            $args = $args0
            if ($annotation.StartsWith('@PostMapping')) {
                $rb = [regex]::Match($params, '@RequestBody\s+[\w<>]+\s+(\w+)')
                if ($rb.Success) { $args = $rb.Groups[1].Value }
            }
            $primitive = @('int', 'long', 'Integer', 'Long', 'double', 'boolean', 'String') -contains $ret
            if ($annotation.StartsWith('@PostMapping')) {
                $rtype = "ResponseEntity<$ret>"; $stmt = "return ResponseEntity.status(HttpStatus.CREATED).body(service.$call($args));"
            } elseif ($primitive) {
                $k = if ($key) { $key } else { $name }
                $boxed = if ($ret -eq 'int') { 'Integer' } elseif ($ret -eq 'long') { 'Long' } else { 'Object' }
                $rtype = "Map<String, $boxed>"; $stmt = "return Map.of(""$k"", service.$call($args));"
            } else { $rtype = $ret; $stmt = "return service.$call($args);" }
            $repl = "$annotation public $rtype $name($params) {`n  $stmt`n }"
            $b = $b.Substring(0, $m.Index) + $repl + $b.Substring($close + 1)
        }
        if ($b -ne $body) { $edited[$path] = $b }
    }
    if ($edited.Count -eq 0) { return $answer }
    return (Merge-DropFixes $answer (ConvertTo-DropFixBlock $edited))
}

# Rules that need the paper's wording: a field the paper calls "positive" must be rejected at 0.
function Invoke-DropPaperFixes([string]$answer, [string]$paper, $starter = $null) {
    $out = Fix-DropControllerDelegation $answer $starter $paper
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($paper, '(?i)\bpositive\s+([A-Za-z ]+?)(?=[,.;:\n]|$)')) {
        foreach ($part in ($m.Groups[1].Value -split ' and ')) {
            $words = @($part -split ' ' | Where-Object { $_ -ne '' })
            if ($words.Count -gt 0) {
                $w = $words[$words.Count - 1].ToLowerInvariant()
                if (-not $tokens.Contains($w)) { $tokens.Add($w) }
            }
        }
    }
    $sorted = Get-DropSortedKeys $tokens
    $skipA = @('integer', 'number', 'value', 'values', 'int', 'long', 'id', 'distance', 'stays', 'stay')
    foreach ($tkn in $sorted) {
        if ($tkn.Length -lt 3 -or ($skipA -contains $tkn)) { continue }
        $sig = New-Object System.Text.RegularExpressions.Regex ('(public\s+[\w<>\[\], ?]+\s+\w+\s*\([^)]*\b(?:int|long|double)\s+' + [regex]::Escape($tkn) + '\b[^)]*\)\s*\{)')
        $ms = $sig.Matches($out)
        for ($i = $ms.Count - 1; $i -ge 0; $i--) {
            $m = $ms[$i]
            $at = $m.Index + $m.Length
            $after = $out.Substring($at)
            $bodyStart = if ($after.Length -gt 400) { $after.Substring(0, 400) } else { $after }
            if ([regex]::IsMatch($bodyStart, [regex]::Escape($tkn) + '\s*(<=|<)\s*[01]L?\b')) { continue }
            $out = $out.Substring(0, $at) + "`n  if ($tkn <= 0) { throw new IllegalArgumentException(""$tkn must be positive""); }" + $out.Substring($at)
        }
    }
    $skipB = @('integer', 'number', 'value', 'values', 'int', 'long')
    foreach ($tkn in $sorted) {
        if ($tkn.Length -lt 2 -or ($skipB -contains $tkn)) { continue }
        $out = [regex]::Replace($out, '(?i)(\.(?:get)?' + [regex]::Escape($tkn) + '\w*\(\)\s*)<(\s*0L?\b)', '$1<=$2')
    }
    return $out
}

# Findings for code that COMPILES but is not a real answer. Formatted like javac errors so the repair prompt names the file.
function Get-DropSemanticFindings([string]$answer) {
    $out = New-Object System.Collections.Generic.List[string]
    $files = Get-DropParsedFiles $answer
    foreach ($path in (Get-DropSortedKeys $files.Keys)) {
        $body = [string]$files[$path]
        if ([regex]::IsMatch($body, '@RestController\b(?!Advice)')) {
            foreach ($m in [regex]::Matches($body, 'public\s+(?:ResponseEntity<ApiError>|ApiError)\s+(\w+)\s*\(')) {
                $from = [Math]::Max(0, $m.Index - 90)
                $len = [Math]::Min(90, $m.Index)
                $back = $body.Substring($from, $len)
                if ($back.Contains('@ExceptionHandler')) { continue }
                $out.Add("${path}:1: error: controller method $($m.Groups[1].Value)() returns ApiError as a normal response; ApiError is only for error responses. Return what the service method returns (a DTO or a map holding the value).")
            }
        }
        foreach ($marker in @('not implemented', 'UnsupportedOperationException', 'TODO')) {
            if ($body.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out.Add("${path}:1: error: contains a placeholder ($marker); write the real implementation.") }
        }
    }
    return ($out -join "`n")
}
function Test-DropIntroducesPlaceholders([string]$old, [string]$new) {
    $c = { param($a) @((Get-DropSemanticFindings $a) -split "`n" | Where-Object { $_ -ne '' }).Count }
    return ((& $c $new) -gt (& $c $old))
}

# every FILE section of the answer gets the java.util import (so what you paste matches what compiled)
function Apply-DropImportFix([string]$answer) {
    $out = New-Object System.Collections.Generic.List[string]
    $inFile = $false
    $buf = New-Object System.Collections.Generic.List[string]
    $flush = {
        if ($inFile) { $out.AddRange([string[]]((Add-DropUtilImport ($buf -join "`n")) -split "`r?`n")) } else { $out.AddRange($buf) }
        $buf.Clear()
    }
    foreach ($line in ($answer -split "`n")) {
        $t = $line.Trim()
        if ($t.StartsWith('// =====')) {
            & $flush
            $out.Add($line)
            $inFile = $t.StartsWith('// ===== FILE:')
        } else { $buf.Add($line) }
    }
    & $flush
    return ($out -join "`n")
}

# Applies every deterministic fixer in the right order (Ollama path only).
function Invoke-DropStaticFixes([string]$answer, $starter = $null) {
    if ($null -eq $starter) { $starter = $script:StarterFiles }
    $a = Fix-DropInventedWrapper $answer $starter
    $a = Fix-DropNameRequestParams $a
    $a = Fix-DropReasonOrder $a
    $a = Fix-DropControllerReturns $a $starter
    $a = Fix-DropMappingQueryStrings $a
    $a = Fix-DropSkippedLoop $a
    return $a
}

# "GET /api/missions/101/energy" / "POST /api/missions/air  JSON {...}" lines under the paper's REST-operations heading.
function Get-DropPaperDemoCalls([string]$paper) {
    $i = $paper.IndexOf('REST operations', [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return @() }
    $text = $paper.Substring($i)
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $re = New-Object System.Text.RegularExpressions.Regex '(?m)^\s*(GET|POST|PUT|PATCH|DELETE)\s+(/\S*)(?:\s+(?:JSON\s+)?(\{.*\}))?\s*$'
    foreach ($m in $re.Matches($text)) {
        $verb = $m.Groups[1].Value; $path = $m.Groups[2].Value
        $json = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '' }
        $k = $verb + $path + $json
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out.Add(@($verb, $path, $json)) }
        if ($out.Count -ge 8) { break }
    }
    return $out.ToArray()
}

# ---- OOP: one request per task (experimental, opt-in) ----------------------------------------------------------
$script:DropStarterMarker = '######## STARTER PROJECT FILES ########'
function New-DropOopPlan([string]$paperBlock) {
    $docs = $paperBlock; $starter = ''
    $mi = $paperBlock.IndexOf($script:DropStarterMarker)
    if ($mi -ge 0) { $docs = $paperBlock.Substring(0, $mi); $starter = $paperBlock.Substring($mi + $script:DropStarterMarker.Length) }
    $lines = $docs -split "`n"
    $heads = {
        param($pattern)
        $o = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], $pattern)
            if ($m.Success) {
                $marks = 0
                if ($m.Groups.Count -gt 2 -and $m.Groups[2].Success) { $marks = [int]$m.Groups[2].Value }
                $o.Add(@{ Idx = $i; N = [int]$m.Groups[1].Value; Marks = $marks })
            }
        }
        return ,$o
    }
    $hs = & $heads '^\s*Task\s+(\d+)\s*[\u2013\-:].*\[\s*(\d+)\s*marks'
    $distinct = @{}; foreach ($h in $hs) { $distinct[$h.N] = $true }
    if ($distinct.Count -lt 2) { $hs = & $heads '^\s*Task\s+(\d+)\b' }
    # one heading per task number: with marks the match is the real heading; otherwise the LAST one (earlier ones are marks-table rows)
    $lastIdx = @{}
    for ($k = 0; $k -lt $hs.Count; $k++) { $lastIdx[$hs[$k].N] = $k }
    $uniq = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $hs.Count; $k++) { if ($lastIdx[$hs[$k].N] -eq $k) { $uniq.Add($hs[$k]) } }
    $hs = @($uniq | Sort-Object { $_.Idx })
    if ($hs.Count -lt 2) { return $null }
    $stops = @('illustrative calculations', 'rest operations', 'section b', 'submission and final')
    $isStop = { param($l) $t = $l.ToLowerInvariant().Trim(); foreach ($s in $stops) { if ($t.StartsWith($s)) { return $true } }; return $false }
    $parts = New-Object System.Collections.Generic.List[object]
    $endOfTasks = $lines.Count
    for ($k = 0; $k -lt $hs.Count; $k++) {
        $h = $hs[$k]
        $end = if ($k + 1 -lt $hs.Count) { $hs[$k + 1].Idx } else { $lines.Count }
        for ($j = $h.Idx + 1; $j -lt $end; $j++) {
            if (& $isStop $lines[$j]) { $end = $j; if ($k -eq $hs.Count - 1) { $endOfTasks = $j }; break }
        }
        $text = (($lines[$h.Idx..($end - 1)]) -join "`n").Trim()
        $parts.Add(@{ N = $h.N; Text = $text; Marks = $h.Marks })
    }
    $pre = (($lines[0..($hs[0].Idx - 1)]) -join "`n").Trim()
    if ($hs[0].Idx -eq 0) { $pre = '' }
    $post = ''
    if ($endOfTasks -lt $lines.Count) { $post = (($lines[$endOfTasks..($lines.Count - 1)]) -join "`n").Trim() }
    if ($pre.Length -gt 3500) { $pre = $pre.Substring($pre.Length - 3500) }
    if ($post.Length -gt 3000) { $post = $post.Substring(0, 3000) }
    return @{ Preamble = $pre; Tasks = $parts.ToArray(); Postamble = $post; StarterText = $starter.Trim() }
}

function Get-DropOopTaskPrompt($plan, $part, $written) {
    $starter = [string]$plan.StarterText
    if ($written -and $written.Count -gt 0) {   # a file already rewritten by an earlier task replaces the starter copy
        $keep = ("`n" + $starter) -split "`n===== FILE: "
        $rebuilt = $keep[0]
        for ($i = 1; $i -lt $keep.Count; $i++) {
            $name = ($keep[$i] -split ' =====')[0]
            $hit = $false
            foreach ($wk in @($written.Keys)) { if (([string]$wk).EndsWith($name)) { $hit = $true; break } }
            if (-not $hit) { $rebuilt += "`n===== FILE: " + $keep[$i] }
        }
        $starter = $rebuilt.Trim()
    }
    $p = $OllamaPromptHeader + "`n`n######## EXAM PAPER / INSTRUCTIONS ########`n" + $plan.Preamble + "`n`n######## STARTER PROJECT FILES ########`n" + $starter
    if ($plan.Postamble) { $p += "`n`n######## WORKED EXAMPLES AND CHECKS FROM THE PAPER ########`n" + $plan.Postamble }
    if ($written -and $written.Count -gt 0) {
        $p += "`n`n######## FILES YOU HAVE ALREADY WRITTEN FOR EARLIER TASKS (keep them compatible) ########"
        foreach ($k in (Get-DropSortedKeys $written.Keys)) { $p += "`n// ===== FILE: $k =====`n" + [string]$written[$k] }
    }
    $n = $part.N
    $p += "`n`n######## THIS REQUEST ########`nWrite ONLY Task $n now. Output the header line // ===== Task $n ===== and then every Java file that Task $n adds or changes, each COMPLETE, each under its own // ===== FILE: ... ===== header line. "
    $p += "If Task $n changes a file written for an earlier task, give that file again in full including the earlier code. Do not write any other task and do not write a HOW TO TEST section.`n`n######## TASK $n ########`n" + $part.Text + "`n"
    return $p
}

# One request per task; the combined answer has the usual "// ===== Task N =====" + FILE layout the pipeline expects.
# $generate = scriptblock taking one request hashtable, returning text or $null; $status = scriptblock taking a string.
function Invoke-DropOopPerTask($plan, [bool]$careful, $generate, $status) {
    $combined = ''
    $written = @{}
    $produced = 0
    $tasks = @($plan.Tasks)
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $part = $tasks[$i]
        & $status ("Task $($part.N) ($($i + 1)/$($tasks.Count))")
        $prompt = Get-DropOopTaskPrompt $plan $part $written
        $m = [Math]::Max([int]$part.Marks, 10)
        $budget = [Math]::Min(6000, 1500 + 120 * $m)
        $np = if ($careful) { [Math]::Min(8000, $budget * 2) } else { $budget }
        $reply = & $generate (New-DropRequest $prompt "Task $($part.N)" 'free' $np 0.2 $careful)
        if ([string]::IsNullOrWhiteSpace($reply) -and $careful) {
            $reply = & $generate (New-DropRequest $prompt "Task $($part.N) (no thinking)" 'free' $budget 0.2 $false)
        }
        if ([string]::IsNullOrWhiteSpace($reply)) { continue }
        $r = $reply.Trim()
        if (-not $r.Contains("// ===== Task $($part.N) =====")) { $r = "// ===== Task $($part.N) =====`n" + $r }
        $combined += $(if ($combined -eq '') { '' } else { "`n" }) + $r
        $written = Get-DropParsedFiles $combined
        $produced++
    }
    if ($produced -eq 0) { return $null }
    return $combined
}

# ---- the shared pipeline: generate -> fixers -> javac -> repair -> finalize (DropPipeline.run) ------------------
# $hooks = @{ Generate = {param($prompt,$label)}; Compile = {param($answer)}; Status = {param($s)} }
# Compile returns $null (cannot check), '' (compiles) or javac's error text. Returns $null when generation failed.
function Invoke-DropOopPipeline([string]$paper, [string]$provider, $starter, $hooks) {
    $nowMs = { [int64]([DateTime]::UtcNow.Ticks / 10000) }
    $genMs = 0; $compMs = 0
    $isOllama = ($provider -eq 'ollama')
    if ($null -eq $starter) { $starter = @{} }
    $script:StarterFiles = $starter
    $header = if ($isOllama) { $OllamaPromptHeader } else { $PromptHeader }
    $prompt = $header + "`n`n" + $paper
    $t0 = & $nowMs
    $answer = & $hooks.Generate $prompt 'Writing'
    if ($null -eq $answer) { return $null }
    $genMs += (& $nowMs) - $t0
    $compiled = $null
    $rounds = 0
    $lastErrs = ''
    $detPasses = 0
    while ($true) {
        if ($isOllama) {
            $answer = Invoke-DropPaperFixes (Invoke-DropStaticFixes $answer $starter) $paper $starter
        }
        & $hooks.Status 'Compiling...'
        $t0 = & $nowMs
        $errsOpt = & $hooks.Compile $answer
        $compMs += (& $nowMs) - $t0
        if ($null -eq $errsOpt) { $compiled = $null; break }
        $errs = [string]$errsOpt
        $lintOnly = $false
        if ($errs -eq '') {
            if ($isOllama -and $rounds -lt 4) {
                $lint = Get-DropSemanticFindings $answer
                if ($lint -ne '') { $errs = $lint; $lintOnly = $true }
            }
            if ($errs -eq '') { $compiled = $true; $lastErrs = ''; break }
        }
        $compiled = if ($lintOnly) { $true } else { $false }
        $lastErrs = if ($lintOnly) { '' } else { $errs }
        if ($isOllama -and $detPasses -lt 3) {
            $det = Invoke-DropJavacFixes $answer $starter $errs
            if ($det -ne $answer) { $detPasses++; $answer = $det; continue }
        }
        if ($rounds -ge 4) { break }
        $rounds++
        $n = ([regex]::Matches($errs, 'error:')).Count
        $cap = if ($errs.Length -gt 6000) { $errs.Substring(0, 6000) } else { $errs }
        if ($isOllama) {
            $fixPrompt = $OllamaRepairHeader + "`n`n######## JAVAC ERRORS ########`n" + $cap + "`n`n######## AFFECTED FILES ########`n" + (Get-DropRepairContext $answer $errs)
        } else {
            $fixPrompt = $PromptHeader + "`n`n" + $paper + "`n`n######## YOUR PREVIOUS ANSWER ########`n" + $answer + "`n`n######## JAVAC ERRORS ########`n" + $cap + "`n`n" + $script:DropOpenCodeRepairHeader
        }
        $t0 = & $nowMs
        $fixes = & $hooks.Generate $fixPrompt "Fixing $n compile error(s)"
        $genMs += (& $nowMs) - $t0
        if ($null -eq $fixes) { break }
        $mergedAns = Merge-DropFixes $answer $fixes
        if ($mergedAns -eq $answer) { break }
        if ($isOllama -and (Test-DropIntroducesPlaceholders $answer $mergedAns)) { break }   # never accept a stub just to compile
        $answer = $mergedAns
    }
    $final = Apply-DropImportFix (Remove-DropFences $answer).Trim()
    if ($isOllama) {
        $final = Invoke-DropPaperFixes (Invoke-DropStaticFixes $final $starter) $paper $starter
        $final = Add-DropHowToTest $final $starter $paper
    }
    return @{ Answer = $final; Compiled = $compiled; RepairRounds = $rounds; GenerationMs = $genMs; CompileMs = $compMs; LastErrors = $lastErrs }
}
# REPAIR_HEADER (OpenCode Go repair prompt, used only by the benchmark's OpenCode path; the app's own OpenCode flow is untouched)
$script:DropOpenCodeRepairHeader = @'
Your previous answer above does NOT compile. The JAVAC ERRORS section shows the exact errors.
Fix every error. Use only classes, methods, record fields and constructors that exist in the starter
files (or that you create yourself). Keep everything that was already correct.
Output ONLY the files you change to fix the errors, each one COMPLETE and starting with its
// ===== FILE: src/main/java/.../ClassName.java ===== header line.
No task list, no explanations, no test commands, no unchanged files.
'@

# ---- OOP run orchestration for the background runspace (handleOOP's Task block) --------------------------------
# P: Paper, FileCount, Starter, Model, Base, ManualCtx, ConnectTimeout, PerTask, RamBytes.  Sync: synchronized hashtable.
# Ollama only; careful mode (original thinking request) and OpenCode Go stay on Drop.ps1's original code path.
function Invoke-DropOopRun($P, $Sync) {
    $setStatus = { param($s) $Sync.Status = [string]$s }
    $r = @{ Ok = $false; Error = ''; Answer = ''; Compiled = $null; RepairRounds = 0 }
    try {
        $session = New-DropSession $P.Base $P.Model ([int]$P.ManualCtx) ([int64]$P.RamBytes)
        $session.OnProgress = { param($label) $Sync.Status = ('Ollama: ' + $label) }
        $plan = $null
        if ($P.PerTask) { $plan = New-DropOopPlan $P.Paper }
        $script:LastSessionError = ''
        $ask = {
            param($req)
            $res = Invoke-DropSessionGenerate $session $req
            if ($res.Error) { $script:LastSessionError = "$($req.Label): $($res.Error)"; & $setStatus ('! ' + $script:LastSessionError); if ([string]::IsNullOrEmpty($res.Text)) { return $null } }
            return $res.Text
        }
        $np = Get-OllamaNumPredict $P.Paper
        $hooks = @{
            Generate = {
                param($prompt, $label)
                $first = ($label -eq 'Writing')
                if ($first -and $plan) {
                    return (Invoke-DropOopPerTask $plan ([bool]$P.Careful) $ask $setStatus)
                }
                $kind = if ($first) { 'whole' } else { 'repair' }
                $budget = if ($first) { [Math]::Max($np, 4096) } else { 4000 }
                $out = & $ask (New-DropRequest $prompt $label $kind $budget 0.2 $false)
                if ($first -and [string]::IsNullOrWhiteSpace($out)) {
                    $pl2 = New-DropOopPlan $P.Paper
                    if ($pl2) { $out = Invoke-DropOopPerTask $pl2 $false $ask $setStatus }
                }
                return $out
            }
            Compile = { param($answer) return (Get-DropCompileErrors $answer) }
            Status  = $setStatus
        }
        $res = Invoke-DropOopPipeline $P.Paper 'ollama' $P.Starter $hooks
        Close-DropSession $session
        if ($null -eq $res) { $r.Error = if ($script:LastSessionError) { $script:LastSessionError } else { 'no answer' }; return $r }
        $r.Ok = $true; $r.Answer = [string]$res.Answer; $r.Compiled = $res.Compiled; $r.RepairRounds = $res.RepairRounds
    } catch {
        $r.Error = [string]$_.Exception.Message
    }
    return $r
}
