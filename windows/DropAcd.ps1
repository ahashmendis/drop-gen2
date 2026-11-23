# DropAcd.ps1 - UI-free ACD (Advanced Client-Side Development) subject of Drop for Windows.
# Port of the macOS ACD code in install-drop.sh: answer document (tasks / questions / files), lecture-note selection,
# paper planner (one small request per question), deterministic AcdFixers, validation reported separately
# (syntax / static / build / tests), bounded requirement-preserving repair, toolchain preparation.
# Dot-sourced by DropCore.ps1. Definitions only. Windows PowerShell 5.1 compatible; ASCII only.
#
# Sandbox note (differs from macOS): macOS runs generated code under sandbox-exec (no network, writes only to a temp
# folder). Windows has no equivalent. Code that EXECUTES model output (the starter's `npm test`, benchmark node-eval)
# therefore runs only where a sandbox exists: Node's permission model (Node 22+, blocks file writes outside the temp
# folder and child processes; it does NOT block the network before Node 25) - otherwise the check is reported as
# "unavailable"/"not_run", never as a pass. tsc / vite / node --check do not execute model code and run plainly.

function Get-DropAcdDir {
    if ($env:DROP_ACD_DIR) { return $env:DROP_ACD_DIR }
    return (Join-Path (Get-DropDataDir) 'acd')
}

# ---- prompts (ACD only; the OOP/Java prompts are separate constants and unchanged) ------------------------------
$script:AcdPromptHeader = @'
You are completing a task for the university module Advanced Client-Side Development (ACD): HTML5, CSS3, Bootstrap,
JavaScript (ES6+), TypeScript, React (hooks, React Router, forms and validation, REST API consumption, TanStack Query,
Zustand, JWT-protected routes) and responsive, accessible UI. All work is client-side; never write a backend.

PRIORITY: the TASK section below is the specification. Follow its requirements exactly: the language (TypeScript or
JavaScript), file and component names, routes, props, API endpoints, marks and wording. The REFERENCE NOTES are course
material for conventions and terminology only. If the notes and the task disagree, the task wins. Answer every question and
every part of every task; never skip one and never invent requirements.

STYLE: simple, readable, student-level code that a second-year student could write. No over-engineering, no extra
abstractions, no libraries the task or the starter project does not already use. Keep every import and structure the
starter files already have and change only what the task requires. Complete files only, never placeholders or "...".

OUTPUT FORMAT (exactly; no introduction, no summary, no markdown fences):
Group the answer under task headers in the paper's order. A paper with numbered tasks or exercises uses its own numbers.
A paper with lettered sections uses Task 1 for section A, Task 2 for section B, and so on.
// ===== Task 1 =====
Under each task give one block per question, headed with the paper's own question identifier exactly as written (A1, B7, C3, D2):
// ===== Q A1 =====
For a multiple-choice question the first line is ONLY the letter (B). For true/false the first line is ONLY True or False.
An optional one-line reason may follow. For a short answer write the answer text. If a question has sub-parts, answer them
inside the same block using the paper's own labels (a., b., c.).
For code, give every file the question adds or changes, COMPLETE, each under its own header:
// ===== FILE: src/pages/Students.tsx =====
(Directly under a FILE header put that file's full code, nothing else. A file given again later replaces the earlier copy.)
For a task without question identifiers, use only the Task header and FILE headers.
'@
$script:AcdRepairHeader = @'
The code you wrote for the TASK failed validation. The ORIGINAL TASK REQUIREMENTS below still apply in full: do not drop,
weaken or reinterpret any of them. VALIDATION ERRORS lists exactly what failed and CURRENT FILES shows the code as it stands.
Fix the reported problems and keep everything that already works unchanged. Output ONLY the files you change, each COMPLETE,
each under its own header line:
// ===== FILE: src/path/File.tsx =====
No explanations, no markdown fences, no unchanged files, no question blocks.
'@
$script:AcdModule = 'You are answering a question of a university exam for the module Advanced Client-Side Development (HTML5, CSS3, Bootstrap, JavaScript, TypeScript, React, React Router, TanStack Query, Zustand, JWT and front-end security). All code is client-side.'

# ---- answer document: tasks, questions, files ---------------------------------------------------------------
# A doc is @{ Segments = List of @{ Kind; Key; Header; Body = string[] } }, Kind = preamble | task | question | file.
$script:AcdTaskRe = New-Object System.Text.RegularExpressions.Regex '^//\s*=====\s*Task\s+(\d+)\s*=====\s*$'
$script:AcdQuestionRe = New-Object System.Text.RegularExpressions.Regex '^//\s*=====\s*Q\s+([A-Za-z]{1,3}\d{1,3}(?:\.[A-Za-z0-9]+)?)\s*=====\s*$'
$script:AcdFileRe = New-Object System.Text.RegularExpressions.Regex '^//\s*=====\s*FILE:\s*(.+?)\s*=====\s*$'

# Only a path that stays inside the project is accepted (no absolute paths, no "..", no control chars).
function ConvertTo-AcdSafePath([string]$raw) {
    $p = $raw.Trim(@(' ', '`', "'", '"', '*'))
    if ($p.StartsWith('./')) { $p = $p.Substring(2) }
    if ($p -eq '' -or $p.StartsWith('/') -or $p.StartsWith('~') -or $p.Contains('\') -or $p.Contains([string][char]0)) { return $null }
    foreach ($seg in $p.Split('/')) { if ($seg -eq '..' -or $seg -eq '.' -or $seg -eq '') { return $null } }
    return $p
}

function ConvertFrom-AcdText([string]$text) {
    $segs = New-Object System.Collections.Generic.List[object]
    $cur = @{ Kind = 'preamble'; Key = ''; Header = ''; Body = (New-Object System.Collections.Generic.List[string]) }
    $flush = {
        param($c)
        if ($c.Kind -eq 'preamble') {
            $blank = $true
            foreach ($l in $c.Body) { if ($l.Trim() -ne '') { $blank = $false; break } }
            if ($blank) { return }
        }
        $segs.Add($c)
    }
    foreach ($line in ($text.Replace("`r`n", "`n") -split "`n")) {
        $t = $line.Trim()
        $m = $script:AcdTaskRe.Match($t)
        if ($m.Success) { & $flush $cur; $cur = @{ Kind = 'task'; Key = [int]$m.Groups[1].Value; Header = $line; Body = (New-Object System.Collections.Generic.List[string]) }; continue }
        $m = $script:AcdQuestionRe.Match($t)
        if ($m.Success) { & $flush $cur; $cur = @{ Kind = 'question'; Key = $m.Groups[1].Value.ToUpperInvariant(); Header = $line; Body = (New-Object System.Collections.Generic.List[string]) }; continue }
        $m = $script:AcdFileRe.Match($t)
        if ($m.Success) {
            & $flush $cur
            $sp = ConvertTo-AcdSafePath $m.Groups[1].Value
            $key = if ($sp) { $sp } else { '!' + $m.Groups[1].Value }
            $cur = @{ Kind = 'file'; Key = $key; Header = $line; Body = (New-Object System.Collections.Generic.List[string]) }
            continue
        }
        $cur.Body.Add($line)
    }
    & $flush $cur
    return @{ Segments = $segs }
}

function Format-AcdDoc($doc) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in $doc.Segments) {
        if ($s.Kind -ne 'preamble') { $out.Add($s.Header) }
        foreach ($l in $s.Body) { $out.Add($l) }
    }
    return (($out -join "`n").Trim())
}

# File content without the marker line; surrounding blank lines and ONE wrapping fence pair are removed.
function Get-AcdClean($lines) {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($x in $lines) { $l.Add([string]$x) }
    while ($l.Count -gt 0 -and $l[0].Trim() -eq '') { $l.RemoveAt(0) }
    while ($l.Count -gt 0 -and $l[$l.Count - 1].Trim() -eq '') { $l.RemoveAt($l.Count - 1) }
    if ($l.Count -ge 2) {
        $f = $l[0].Trim()
        if ($f.StartsWith('```') -and -not $f.Substring(3).Contains('`') -and $l[$l.Count - 1].Trim() -eq '```') {
            $l.RemoveAt(0); $l.RemoveAt($l.Count - 1)
            while ($l.Count -gt 0 -and $l[0].Trim() -eq '') { $l.RemoveAt(0) }
            while ($l.Count -gt 0 -and $l[$l.Count - 1].Trim() -eq '') { $l.RemoveAt($l.Count - 1) }
        }
    }
    if ($l.Count -gt 0 -and $l[0].Length -gt 0 -and $l[0][0] -eq [char]0xFEFF) { $l[0] = $l[0].Substring(1) }   # ordinal test: culture-aware StartsWith ignores U+FEFF
    if ($l.Count -eq 0) { return '' }
    return (($l -join "`n") + "`n")
}

# path -> clean code (last copy of a file wins); invalid paths are dropped and listed by Get-AcdRejectedPaths
function Get-AcdFiles($doc) {
    $out = [ordered]@{}
    foreach ($s in $doc.Segments) { if ($s.Kind -eq 'file' -and -not ([string]$s.Key).StartsWith('!')) { $out[[string]$s.Key] = Get-AcdClean $s.Body } }
    return $out
}
function Get-AcdRejectedPaths($doc) {
    $o = @(); foreach ($s in $doc.Segments) { if ($s.Kind -eq 'file' -and ([string]$s.Key).StartsWith('!')) { $o += ([string]$s.Key).Substring(1) } }
    return $o
}
function Get-AcdQuestionIds($doc) {
    $o = @(); foreach ($s in $doc.Segments) { if ($s.Kind -eq 'question') { $o += [string]$s.Key } }
    return $o
}
# text under each Q marker (objective answers) - files excluded; first block of an id wins
function Get-AcdQuestionText($doc) {
    $out = [ordered]@{}
    foreach ($s in $doc.Segments) { if ($s.Kind -eq 'question' -and -not $out.Contains([string]$s.Key)) { $out[[string]$s.Key] = Get-AcdClean $s.Body } }
    return $out
}

# Replace files (and questions) from $fixes; everything else is preserved in place. New files are appended.
function Merge-AcdDoc($doc, $fixes) {
    $segs = New-Object System.Collections.Generic.List[object]
    foreach ($s in $doc.Segments) { $segs.Add(@{ Kind = $s.Kind; Key = $s.Key; Header = $s.Header; Body = (New-Object System.Collections.Generic.List[string](,[string[]]@($s.Body))) }) }
    foreach ($f in $fixes.Segments) {
        if ($f.Kind -eq 'file' -and -not ([string]$f.Key).StartsWith('!')) {
            $idx = -1
            for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Kind -eq 'file' -and $segs[$i].Key -eq $f.Key) { $idx = $i } }
            if ($idx -ge 0) { $segs[$idx].Body = (New-Object System.Collections.Generic.List[string](,[string[]]@($f.Body))) }
            else { $segs.Add(@{ Kind = $f.Kind; Key = $f.Key; Header = $f.Header; Body = (New-Object System.Collections.Generic.List[string](,[string[]]@($f.Body))) }) }
        } elseif ($f.Kind -eq 'question') {
            $idx = -1
            for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Kind -eq 'question' -and $segs[$i].Key -eq $f.Key) { $idx = $i } }
            if ($idx -ge 0) { $segs[$idx].Body = (New-Object System.Collections.Generic.List[string](,[string[]]@($f.Body))) }
        }
    }
    return @{ Segments = $segs }
}

# Copy target: "2" = Task 2, "A1" = question, "Events.tsx" = file. A single-file result comes back as clean code only.
function Get-AcdPart($doc, [string]$keyRaw) {
    $key = $keyRaw.Trim()
    if ($key -eq '') { return $null }
    $segs = $doc.Segments
    $slice = {
        param([int]$from, [string]$stopKinds)
        $idx = New-Object System.Collections.Generic.List[int]
        $idx.Add($from)
        $j = $from + 1
        while ($j -lt $segs.Count -and -not ($stopKinds.Split(',') -contains $segs[$j].Kind)) { $idx.Add($j); $j++ }
        $parts = @($idx | ForEach-Object { $segs[$_] })
        $nonFile = @($parts | Where-Object { $_.Kind -ne 'file' })
        $files = @($parts | Where-Object { $_.Kind -eq 'file' })
        $loose = $false
        foreach ($s in $nonFile) { foreach ($l in $s.Body) { if ($l.Trim() -ne '') { $loose = $true } } }
        if ($files.Count -eq 1 -and -not $loose) { return (Get-AcdClean $files[0].Body).Trim("`n", "`r") }
        $t = Format-AcdDoc @{ Segments = $parts }
        if ($t -eq '') { return $null }
        return $t
    }
    $n = 0
    if ([int]::TryParse($key, [ref]$n)) {
        for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Kind -eq 'task' -and $segs[$i].Key -eq $n) { return (& $slice $i 'task') } }
        return $null
    }
    if ($script:AcdQuestionRe.IsMatch("// ===== Q $($key.ToUpperInvariant()) =====") -and -not $key.Contains('/')) {
        $id = $key.ToUpperInvariant()
        for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Kind -eq 'question' -and $segs[$i].Key -eq $id) { return (& $slice $i 'task,question') } }
        return $null
    }
    $files = Get-AcdFiles $doc
    foreach ($p in (Get-DropSortedKeys $files.Keys)) {
        if ($p -eq $key -or $p.EndsWith('/' + $key)) { return ([string]$files[$p]).Trim("`n", "`r") }
    }
    return $null
}

# ---- objective answers (multiple choice / true-false) ---------------------------------------------------------
# Normalised answer of a question block: "A".."D", "True" or "False"; $null when it cannot be read.
function ConvertTo-AcdObjective([string]$blockText) {
    $first = ''
    foreach ($l in ($blockText -split "`n")) { if ($l.Trim() -ne '') { $first = $l.Trim(@(' ', '*', '`', '_', "`t")); break } }
    $l = $first.ToLowerInvariant()
    foreach ($pair in @(@('true', 'True'), @('false', 'False'))) {
        $w = $pair[0]
        if ($l -eq $w -or $l.StartsWith($w + ' ') -or $l.StartsWith($w + '.') -or $l.StartsWith($w + ',') -or $l.StartsWith($w + '-') -or $l.StartsWith($w + ':') -or $l.StartsWith($w + ')')) { return $pair[1] }
    }
    $m = [regex]::Match($first, '^\(?([A-Da-d])(?:[\)\.\:\-\u2013 ]|$)')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return $null
}
# Reads a one-question reply: tolerates "B", "B.", "(b) reduce()", "A1: B", "Answer: B" and True/False variants.
function Get-AcdObjectiveFromReply([string]$reply, [string]$id, [bool]$tf) {
    $t = $reply.Trim()
    $m = [regex]::Match($t, '^\W*' + [regex]::Escape($id) + '\W+', 'IgnoreCase')
    if ($m.Success) { $t = $t.Substring($m.Length) }
    $m = [regex]::Match($t, '^\W*(answer|correct answer)\s*[:\-]?\s*', 'IgnoreCase')
    if ($m.Success) { $t = $t.Substring($m.Length) }
    $v = ConvertTo-AcdObjective $t
    if ($null -eq $v) { return $null }
    if ($tf) { if ($v -eq 'True' -or $v -eq 'False') { return $v } else { return $null } }
    if (@('A', 'B', 'C', 'D') -contains $v) { return $v } else { return $null }
}

# ---- reading text out of office files without new dependencies -------------------------------------------------
function ConvertFrom-AcdXmlText([string]$s) {
    return $s.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&apos;', "'").Replace('&amp;', '&')
}
# One block per slide, text runs joined per paragraph.
function Get-AcdPptxSlides([string]$path) {
    $out = New-Object System.Collections.Generic.List[string]
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -match '^ppt/slides/slide\d+\.xml$' } |
                         Sort-Object { [int]([regex]::Match($_.FullName, '(\d+)\.xml$').Groups[1].Value) })
            foreach ($e in $entries) {
                $sr = New-Object System.IO.StreamReader($e.Open())
                $xml = $sr.ReadToEnd(); $sr.Close()
                $paras = @()
                foreach ($p in ($xml -split '</a:p>')) {
                    $t = (([regex]::Matches($p, '<a:t>([^<]*)</a:t>') | ForEach-Object { ConvertFrom-AcdXmlText $_.Groups[1].Value }) -join '')
                    if ($t.Trim() -ne '') { $paras += $t }
                }
                if ($paras.Count -gt 0) { $out.Add(($paras -join "`n")) }
            }
        } finally { $zip.Dispose() }
    } catch { }
    return $out.ToArray()
}
# docx -> text with paragraph, line-break and tab handling (Drop.ps1's Get-DocxText ignores <w:br/>, which glues multiple-choice
# options together: "...appropriateB. To hide..."). The OOP path keeps using Get-DocxText unchanged.
function Get-AcdDocxText([string]$path) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entry = $zip.GetEntry('word/document.xml')
            if ($null -eq $entry) { return '' }
            $sr = New-Object System.IO.StreamReader($entry.Open())
            $xml = $sr.ReadToEnd(); $sr.Close()
        } finally { $zip.Dispose() }
        $xml = $xml -replace '</w:p>', "`n" -replace '<w:br\b[^>]*/>', "`n" -replace '<w:cr\s*/>', "`n" -replace '<w:tab\s*/>', "`t" -replace '</w:tc>', "`t" -replace '<[^>]+>', ''
        return [System.Net.WebUtility]::HtmlDecode($xml)
    } catch { return '' }
}
function Get-AcdDocText([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.docx') { return (Get-AcdDocxText $path) }
    if ($ext -eq '.pdf') {
        if (Get-Command pdftotext -ErrorAction SilentlyContinue) { try { return ((& pdftotext -layout $path - 2>$null) -join "`n") } catch { return '' } }
        return ''
    }
    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
}

# ---- ACD input: paper + starter project, no Java assumptions -----------------------------------------------------
$script:AcdDocExt = @('docx', 'doc', 'rtf', 'pdf', 'pptx')
$script:AcdTextDocExt = @('md', 'txt')
$script:AcdCodeExt = @('html', 'htm', 'css', 'scss', 'js', 'jsx', 'mjs', 'cjs', 'ts', 'tsx', 'json')
$script:AcdSkipDirs = @('node_modules', 'dist', 'build', '.git', '.vite', '.idea', '.vscode', 'coverage', 'notes', '.next', 'out')
$script:AcdSkipFiles = @('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', '.DS_Store')

function Get-AcdQuestionCount([string]$text) {
    $ids = @{}
    foreach ($m in [regex]::Matches($text, '(?m)^\s*([A-E]\d{1,2})[.):]\s')) { $ids[$m.Groups[1].Value] = $true }
    $tasks = @{}
    foreach ($m in [regex]::Matches($text, '\b(?:Task|Exercise)\s+(\d+)\b')) { $tasks[$m.Groups[1].Value] = $true }
    return [Math]::Max([Math]::Max($ids.Count, $tasks.Count), 1)
}

# @{ Paper; TaskOnly; Starter; ProjectRoot; FileCount; QuestionCount }
function Get-AcdInput([string]$dir) {
    $base = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\', '/')
    $docs = New-Object System.Text.StringBuilder
    $code = New-Object System.Text.StringBuilder
    $starter = @{}
    $zips = New-Object System.Collections.Generic.List[string]
    $count = 0; $total = 0
    $rootCandidates = New-Object System.Collections.Generic.List[string]
    $files = Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
        $segs = $rel.Split('/')
        $skip = $false
        for ($i = 0; $i -lt $segs.Length - 1; $i++) { if ($script:AcdSkipDirs -contains $segs[$i] -or $segs[$i].StartsWith('.')) { $skip = $true; break } }
        if ($skip -or $f.Name.StartsWith('.')) { continue }
        if ($f.Length -gt 150000 -or ($script:AcdSkipFiles -contains $f.Name) -or $f.Name.StartsWith('~$')) { continue }
        $ext = $f.Extension.TrimStart('.').ToLowerInvariant()
        if ($ext -eq 'zip') { $zips.Add($f.FullName); continue }
        if ($script:AcdDocExt -contains $ext) {
            if ($ext -eq 'pptx') {
                $sl = Get-AcdPptxSlides $f.FullName
                $text = (@(for ($i = 0; $i -lt $sl.Count; $i++) { "--- slide $($i + 1) ---`n" + $sl[$i] }) -join "`n")
            } else { $text = Get-AcdDocText $f.FullName }
            if ($text) { [void]$docs.Append("`n===== FILE: $rel =====`n" + $text); $count++ }
        } elseif (($script:AcdTextDocExt -contains $ext) -and -not $rel.Contains('/src/') -and -not $rel.StartsWith('src/')) {
            try { $t = [System.IO.File]::ReadAllText($f.FullName) } catch { $t = '' }
            if ($t) { [void]$docs.Append("`n===== FILE: $rel =====`n" + $t); $count++ }
        } elseif ($script:AcdCodeExt -contains $ext) {
            try { $t = [System.IO.File]::ReadAllText($f.FullName) } catch { $t = '' }
            if (-not $t) { continue }
            $total += $t.Length
            if ($total -gt 300000) { [void]$code.Append("`n[... more files skipped: project too large ...]`n"); break }
            if ($f.Name -eq 'package.json' -or $f.Name -eq 'index.html') { $rootCandidates.Add($f.DirectoryName) }
            $starter[$rel] = $t; $count++
        }
    }
    if ($starter.Count -eq 0 -and $zips.Count -gt 0) {          # starter given as a zip: unpack to a temp folder
        foreach ($z in $zips) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dropacd-' + [guid]::NewGuid().ToString('N'))
            try {
                [System.IO.Compression.ZipFile]::ExtractToDirectory($z, $tmp)
                $sub = Get-AcdInput $tmp
                if ($sub.TaskOnly) { [void]$docs.Append("`n" + $sub.TaskOnly) }
                foreach ($k in @($sub.Starter.Keys)) { $starter[$k] = $sub.Starter[$k] }
                $count += $sub.FileCount
            } catch { } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    # starter paths relative to the project root (the folder with package.json), so "src/App.tsx" means the same everywhere
    $root = $null
    if ($rootCandidates.Count -gt 0) { $root = ($rootCandidates | Sort-Object { $_.Length } | Select-Object -First 1) }
    if (-not $root -and $starter.Count -gt 0) { $root = $base }
    $rebased = @{}
    if ($root -and $root -ne $base -and $root.Replace('\', '/').StartsWith($base.Replace('\', '/') + '/')) {
        $prefix = $root.Replace('\', '/').Substring($base.Length + 1) + '/'
        foreach ($k in @($starter.Keys)) { $nk = if ($k.StartsWith($prefix)) { $k.Substring($prefix.Length) } else { $k }; $rebased[$nk] = $starter[$k] }
    } else { $rebased = $starter }
    foreach ($k in (Get-DropSortedKeys $rebased.Keys)) { [void]$code.Append("`n===== FILE: $k =====`n" + $rebased[$k]) }
    $paper = ''
    if ($docs.Length -gt 0) { $paper += "`n######## TASK / PAPER ########`n" + $docs.ToString() }
    if ($code.Length -gt 0) { $paper += "`n######## STARTER PROJECT FILES ########`n" + $code.ToString() }
    return @{ Paper = $paper; TaskOnly = $docs.ToString(); Starter = $rebased; ProjectRoot = $root; FileCount = $count; QuestionCount = (Get-AcdQuestionCount $docs.ToString()) }
}

# One folder is read in place (its own node_modules can be reused); other drops are merged.
function Get-AcdInputMany([string[]]$paths) {
    $m = @{ Paper = ''; TaskOnly = ''; Starter = @{}; ProjectRoot = $null; FileCount = 0; QuestionCount = 1 }
    foreach ($p in $paths) {
        $dir = $p; $tmp = $null
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dropacd-f-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $tmp -Force)
            Copy-Item -LiteralPath $p -Destination $tmp
            $dir = $tmp
        }
        $one = Get-AcdInput $dir
        $m.Paper += $one.Paper; $m.TaskOnly += $one.TaskOnly
        foreach ($k in @($one.Starter.Keys)) { $m.Starter[$k] = $one.Starter[$k] }
        if (-not $m.ProjectRoot -and -not $tmp) { $m.ProjectRoot = $one.ProjectRoot }
        $m.FileCount += $one.FileCount
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $m.QuestionCount = Get-AcdQuestionCount $m.TaskOnly
    return $m
}

# ---- lecture notes: selected by relevance, always lower priority than the task -----------------------------------
function Get-AcdNotesInstalledDir { return (Join-Path (Get-DropAcdDir) 'notes') }
function Get-AcdNotesDesktopDir { return (Join-Path (Join-Path (Get-DropDesktopDir) 'ACD') 'notes') }
$script:AcdStop = @('the', 'and', 'for', 'that', 'this', 'with', 'from', 'are', 'was', 'will', 'you', 'your', 'can', 'all', 'any', 'not', 'use', 'using', 'each', 'which', 'when', 'write', 'following', 'should', 'must', 'marks', 'mark', 'question', 'task', 'what')
$script:AcdTech = @('react', 'router', 'useparams', 'usenavigate', 'usestate', 'useeffect', 'usememo', 'usecallback', 'context', 'zustand', 'tanstack', 'query', 'bootstrap', 'grid', 'flex', 'flexbox', 'typescript', 'interface', 'jwt', 'form', 'validation', 'fetch', 'axios', 'promise', 'async', 'await', 'css', 'html', 'accessibility', 'aria', 'responsive', 'media', 'clamp', 'outlet', 'navigate', 'protected', 'token', 'reduce', 'optional', 'union', 'hook', 'hooks', 'props', 'state')

function Get-AcdNoteChunks([string[]]$dirs) {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $ext = $f.Extension.TrimStart('.').ToLowerInvariant()
            if (@('md', 'txt', 'docx', 'pdf', 'pptx') -notcontains $ext) { continue }
            if ($f.Name.StartsWith('.')) { continue }
            $sk = $f.Name + $ext
            if ($seen.ContainsKey($sk)) { continue }
            $seen[$sk] = $true
            $units = New-Object System.Collections.Generic.List[object]
            if ($ext -eq 'pptx') {
                $sl = Get-AcdPptxSlides $f.FullName
                for ($i = 0; $i -lt $sl.Count; $i++) { $units.Add(@{ Title = ('slide ' + ($i + 1) + ': ' + ($sl[$i] -split "`n")[0]); Text = $sl[$i] }) }
            } else {
                $text = Get-AcdDocText $f.FullName
                $title = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $buf = New-Object System.Collections.Generic.List[string]
                $flush = { if ((($buf -join '').Trim()) -ne '') { $units.Add(@{ Title = $title; Text = ($buf -join "`n") }) }; $buf.Clear() }
                foreach ($line in ($text -split "`n")) {
                    if ($line.StartsWith('#')) { & $flush; $title = $line.Trim(@('#', ' ')) }
                    $buf.Add($line)
                }
                & $flush
            }
            foreach ($u in $units) {                                   # keep chunks small so selection can be precise
                $cur = ''
                foreach ($para in ($u.Text -split "`n`n")) {
                    if (($cur.Length + $para.Length) -gt 900 -and $cur -ne '') { $out.Add(@{ Source = $f.Name; Title = $u.Title; Text = $cur }); $cur = '' }
                    $cur += $(if ($cur -eq '') { '' } else { "`n`n" }) + $para
                }
                if ($cur.Trim() -ne '') { $out.Add(@{ Source = $f.Name; Title = $u.Title; Text = $cur }) }
            }
        }
    }
    return $out.ToArray()
}

function Get-AcdTokens([string]$s) {
    $out = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToLowerInvariant().ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch) -or $ch -eq '_') { [void]$cur.Append($ch) }
        else {
            if ($cur.Length -ge 3 -and ($script:AcdStop -notcontains $cur.ToString())) { $out.Add($cur.ToString()) }
            [void]$cur.Clear()
        }
    }
    if ($cur.Length -ge 3 -and ($script:AcdStop -notcontains $cur.ToString())) { $out.Add($cur.ToString()) }
    return $out.ToArray()
}

# Top-ranked chunks within $budgetChars. Convention files (00-*) always come first. -> @{ Text; Used }
function Select-AcdNotes([string]$task, $chunks, [int]$budgetChars) {
    $chunks = @($chunks)
    if ($budgetChars -lt 400 -or $chunks.Count -eq 0) { return @{ Text = ''; Used = @() } }
    $taskTokens = @{}; foreach ($t in (Get-AcdTokens $task)) { $taskTokens[$t] = $true }
    $df = @{}
    $chunkTokens = @()
    foreach ($c in $chunks) {
        $set = @{}; foreach ($t in (Get-AcdTokens ($c.Title + ' ' + $c.Text))) { $set[$t] = $true }
        $chunkTokens += ,$set
        foreach ($t in $set.Keys) { $df[$t] = 1 + [int]$df[$t] }
    }
    $n = [double]$chunks.Count
    $scored = New-Object System.Collections.Generic.List[object]
    $convFirst = ($budgetChars -ge 4000)
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        if ($convFirst -and ([string]$chunks[$i].Source).StartsWith('00-')) { continue }
        $score = 0.0
        foreach ($t in $chunkTokens[$i].Keys) {
            if ($taskTokens.ContainsKey($t)) {
                $score += [Math]::Log(1 + $n / [double]$df[$t])
                if ($script:AcdTech -contains $t) { $score += 2.0 }
            }
        }
        if ($score -gt 0) { $scored.Add(@{ Score = $score; Idx = $i }) }
    }
    $order = @($scored | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Idx }; Descending = $false })
    $dot = [string][char]0x00B7
    $text = New-Object System.Text.StringBuilder
    $used = New-Object System.Collections.Generic.List[string]
    $add = {
        param($c)
        $piece = "[$($c.Source) $dot $($c.Title)]`n$($c.Text.Trim())`n`n"
        if (($text.Length + $piece.Length) -gt $budgetChars) { return }
        [void]$text.Append($piece); $used.Add("$($c.Source) $dot $($c.Title)")
    }
    if ($convFirst) { foreach ($c in $chunks) { if (([string]$c.Source).StartsWith('00-') -and $text.Length -lt 3500) { & $add $c } } }
    foreach ($s in $order) { & $add $chunks[$s.Idx] }
    return @{ Text = $text.ToString().Trim(); Used = $used.ToArray() }
}

function Get-AcdNotesBudget([int]$ceilingTokens, [int]$headerAndTaskChars) {
    $free = ($ceilingTokens - 8000) * 3 - $headerAndTaskChars - 1500
    return [Math]::Max(0, [Math]::Min(9000, $free))
}
function Get-AcdWholePrompt([string]$notes, [string]$paper) {
    $p = $script:AcdPromptHeader + "`n`n"
    if ($notes) { $p += "######## REFERENCE NOTES (course material; lower priority than the task) ########`n" + $notes + "`n`n" }
    return $p + $paper
}
function Get-AcdRepairPrompt([string]$paper, $files, [string]$errors, $affected) {
    $cur = ''
    $aff = @($affected)
    $keys = Get-DropSortedKeys $files.Keys
    $omitted = @($keys | Where-Object { $aff.Count -gt 0 -and ($aff -notcontains $_) })
    foreach ($k in $keys) { if ($aff.Count -eq 0 -or ($aff -contains $k)) { $cur += "`n===== FILE: $k =====`n" + $files[$k] } }
    if ($omitted.Count -gt 0) { $cur += "`n(unchanged files not shown: " + ($omitted -join ', ') + ")`n" }
    $e = if ($errors.Length -gt 4000) { $errors.Substring(0, 4000) } else { $errors }
    return $script:AcdRepairHeader + "`n`n######## ORIGINAL TASK REQUIREMENTS ########`n" + $paper + "`n`n######## CURRENT FILES ########`n" + $cur + "`n`n######## VALIDATION ERRORS ########`n" + $e
}
function Get-AcdObjectivePrompt($u, [bool]$strict = $false) {
    $reply = if ($u.Kind -eq 'tf') { 'True or False' } else { 'the letter of the correct option (A, B, C or D)' }
    $only = if ($u.Kind -eq 'tf') { 'a single word: True or False.' } else { 'a single letter: A, B, C or D.' }
    $p = $script:AcdModule + "`nReply with ONLY " + $reply + ". No explanation, no other words."
    if ($strict) { $p += "`nYour whole reply must be " + $only }
    return $p + "`n`nQUESTION`n" + $u.Text + "`n"
}
function Get-AcdFreePrompt($u, [string]$preamble, [string]$notes, [string]$starter) {
    $p = $script:AcdModule + "`nWrite exactly what the question asks for and nothing else:`n"
    $p += "- Code: complete, correct code in a fenced block (``````tsx, ``````ts or ``````js). Use the language the question or the exam instructions name, otherwise TypeScript. Import everything you use.`n"
    $p += "- Explanations: short, plain sentences with one clear point per mark shown.`n"
    $p += "- Answer every part (a, b, c, ...) using the question's own labels. Do not repeat the question. No introduction or summary.`n"
    $p += "- Satisfy every requirement exactly as stated (structure, names, routes, layout, behaviour). Do not omit, move or rename anything the question lists.`n"
    $p += "- Use the exact names the question gives: route paths and parameter names (a route /students/:studentId is read as studentId), endpoints (write /api/events, never invent a host), components, props and files.`n"
    $p += "- Use only the libraries the question or the exam instructions name (for example no Zustand in a data-fetching question). A custom hook you write must be called by the component you show. Never declare a type that you also import.`n"
    $p += "- If the question says pages share a layout, every listed page is a child route of that layout. In TypeScript a catch variable is ``unknown``: narrow it with ``instanceof Error`` before reading .message. In React effects that use an AbortController, never set state after the request was aborted.`n"
    if ($starter) { $p += "- The starter project files are shown below. When the question asks you to create or change a file, give the COMPLETE file under its own header line ``// ===== FILE: src/path/File.tsx =====`` (no fences around it), keeping all existing imports and structure.`n" }
    if ([int]$u.Marks -gt 0) { $p += "- This question is worth $($u.Marks) marks.`n" }
    if ($preamble) { $p += "`nEXAM INSTRUCTIONS`n" + $preamble + "`n" }
    if ($notes) { $p += "`nREFERENCE NOTES (course material; the question wins if they disagree)`n" + $notes + "`n" }
    if ($starter) { $p += "`nSTARTER PROJECT FILES`n" + $starter + "`n" }
    return $p + "`nQUESTION`n" + $u.Text + "`n"
}

# ---- the planner: the paper becomes questions ---------------------------------------------------------------------
# -> @{ Preamble; Units = @(@{ Id; Task; Kind (mcq|tf|free); Text; Marks }) }
function New-AcdPlan([string]$text) {
    $pre = New-Object System.Collections.Generic.List[string]
    $raw = New-Object System.Collections.Generic.List[object]
    $sec = ''; $tfSection = $false
    $lines = $text.Replace("`r`n", "`n") -split "`n"
    foreach ($line in $lines) {
        if ($line.StartsWith('===== FILE:') -and $raw.Count -eq 0) { continue }          # file wrapper lines of the extractor
        $sm = [regex]::Match($line, '^\s*Section\s+([A-Z])\b(.*)$')
        if ($sm.Success) {
            $sec = $sm.Groups[1].Value
            $lo = $line.ToLowerInvariant(); $tfSection = ($lo.Contains('true') -and $lo.Contains('false'))
            if ($raw.Count -gt 0) { $raw[$raw.Count - 1].Lines.Add('') }
            continue
        }
        $um = [regex]::Match($line, '^\s*([A-Z]{1,2}\d{1,3})[.)]\s')
        if ($um.Success) {
            $l = New-Object System.Collections.Generic.List[string]; $l.Add($line)
            $raw.Add(@{ Id = $um.Groups[1].Value; Sec = $sec; Tf = $tfSection; Lines = $l }); continue
        }
        if ($raw.Count -eq 0) { $pre.Add($line) } elseif (-not $line.StartsWith('END OF')) { $raw[$raw.Count - 1].Lines.Add($line) }
    }
    $marks = { param($s) $m = [regex]::Match($s, '\((\d+)\s*marks?\)', 'IgnoreCase'); if ($m.Success) { return [int]$m.Groups[1].Value } else { return 0 } }
    $cut = { param($s) $t = $s.Trim(); if ($t.Length -gt 900) { $t = $t.Substring(0, 900) }; return $t }
    $units = New-Object System.Collections.Generic.List[object]
    if ($raw.Count -ge 2) {
        foreach ($r in $raw) {
            $t = ($r.Lines -join "`n").Trim()
            $hasOptions = [regex]::IsMatch($t, '(?s)(^|\s)\(?A[.)]\s.+\s\(?B[.)]\s')
            $lo = $t.ToLowerInvariant()
            $tf = (-not $hasOptions) -and ($r.Tf -or $lo.Contains('true or false') -or $lo.Contains('true/false'))
            $kind = if ($hasOptions) { 'mcq' } elseif ($tf) { 'tf' } else { 'free' }
            $letter = [int][char]$r.Id[0] - 64
            $units.Add(@{ Id = $r.Id.ToUpperInvariant(); Task = $letter; Kind = $kind; Text = $t; Marks = (& $marks $t) })
        }
        return @{ Preamble = (& $cut ($pre -join "`n")); Units = $units.ToArray() }
    }
    # no lettered questions: split by "Task N" / "Exercise N" / "Question N"
    $tasks = New-Object System.Collections.Generic.List[object]
    $pre2 = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`n")) {
        $m = [regex]::Match($line, '^\s*(?:Task|Exercise|Question)\s+(\d{1,2})\b')
        if ($m.Success) { $l = New-Object System.Collections.Generic.List[string]; $l.Add($line); $tasks.Add(@{ N = [int]$m.Groups[1].Value; Lines = $l }); continue }
        if ($tasks.Count -eq 0) { $pre2.Add($line) } else { $tasks[$tasks.Count - 1].Lines.Add($line) }
    }
    if ($tasks.Count -ge 2) {
        foreach ($t in $tasks) {
            $body = ($t.Lines -join "`n").Trim()
            $units.Add(@{ Id = "T$($t.N)"; Task = $t.N; Kind = 'free'; Text = $body; Marks = (& $marks $body) })
        }
        return @{ Preamble = (& $cut ($pre2 -join "`n")); Units = $units.ToArray() }
    }
    return @{ Preamble = ''; Units = @() }
}

# ---- ACD deterministic fixers (ACD answers only; OOP's fixers are separate) ----------------------------------------
# Each rule changes nothing unless its exact pattern is present. They target patterns seen in practice papers, so a
# benchmark score describes model + fixers.
$script:AcdAttrPath = @'
path\s*=\s*[{"'`]([^"'`}]*)
'@.Trim()
$script:AcdAttrPathFull = @'
path\s*=\s*[{"'`][^"'`}]*
'@.Trim()
$script:AcdFenceRe = New-Object System.Text.RegularExpressions.Regex '(```[a-zA-Z]*\n)([\s\S]*?)(```)'

function Invoke-AcdFixers([string]$text, [string]$question) {
    $t = $text
    $t = Fix-AcdInventedHosts $t $question
    $t = Fix-AcdAlignRouteParams $t $question
    $t = Fix-AcdRouteParamNames $t
    $t = Fix-AcdUnknownCatch $t
    $t = Fix-AcdStateAfterAbort $t
    $t = Fix-AcdLayoutRoutes $t $question
    $t = Fix-AcdDuplicateTypeImports $t
    $t = Fix-AcdMissingImports $t
    return $t
}

# "https://made-up.example/api/events" -> "/api/events" when the question names the path but not that host.
function Fix-AcdInventedHosts([string]$t, [string]$question) {
    $out = $t
    $ms = [regex]::Matches($t, 'https?://([A-Za-z0-9.-]+)(/api/[A-Za-z0-9/_\-.{}$]*)')
    for ($i = $ms.Count - 1; $i -ge 0; $i--) {
        $m = $ms[$i]
        $host2 = $m.Groups[1].Value; $path = $m.Groups[2].Value
        if (-not $question.Contains($host2) -and $question.Contains($path)) { $out = $out.Substring(0, $m.Index) + $path + $out.Substring($m.Index + $m.Length) }
    }
    return $out
}

# The question names the route parameter (/students/:studentId) but the answer used another (:id).
function Fix-AcdAlignRouteParams([string]$t, [string]$question) {
    $qp = @{}
    foreach ($m in [regex]::Matches($question, '/\w[\w\-/]*/:(\w+)')) { $qp[$m.Groups[1].Value] = $true }
    $ap = @{}
    foreach ($m in [regex]::Matches($t, $script:AcdAttrPath)) {
        foreach ($pm in [regex]::Matches($m.Groups[1].Value, ':(\w+)')) { $ap[$pm.Groups[1].Value] = $true }
    }
    if ($qp.Count -ne 1 -or $ap.Count -ne 1) { return $t }
    $q = @($qp.Keys)[0]; $a = @($ap.Keys)[0]
    if ($q -eq $a) { return $t }
    $out = $t
    $ms = [regex]::Matches($t, $script:AcdAttrPathFull)
    for ($i = $ms.Count - 1; $i -ge 0; $i--) {
        $m = $ms[$i]
        $piece = $m.Value
        $fixed = [regex]::Replace($piece, ':' + [regex]::Escape($a) + '\b', (':' + $q))
        if ($fixed -ne $piece) { $out = $out.Substring(0, $m.Index) + $fixed + $out.Substring($m.Index + $m.Length) }
    }
    return $out
}

# A route "/students/:studentId" read as `const { id } = useParams()` -> `{ studentId }` (exactly one route parameter).
function Fix-AcdRouteParamNames([string]$t) {
    $params = @{}
    foreach ($m in [regex]::Matches($t, $script:AcdAttrPath)) {
        foreach ($pm in [regex]::Matches($m.Groups[1].Value, ':(\w+)')) { $params[$pm.Groups[1].Value] = $true }
    }
    if ($params.Count -ne 1) { return $t }
    $p = @($params.Keys)[0]
    $out = $t
    $ms = [regex]::Matches($t, 'const\s*\{\s*(\w+)\s*\}\s*=\s*useParams(?:<[^>]*>)?\(\)')
    for ($i = $ms.Count - 1; $i -ge 0; $i--) {
        $m = $ms[$i]
        $x = $m.Groups[1].Value
        if ($x -eq $p) { continue }
        $head = $out.Substring(0, $m.Index)
        $tail = $out.Substring($m.Index)
        $scope = $tail; $rest = ''
        $e = $tail.IndexOf("`n}")
        if ($e -ge 0) { $scope = $tail.Substring(0, $e + 2); $rest = $tail.Substring($e + 2) }
        $scope = [regex]::Replace($scope, '(?<![.\w"''`])' + [regex]::Escape($x) + '(?![\w:"''`])', $p)
        $out = $head + $scope + $rest
    }
    return $out
}

# `catch (err) { ... err.name ... }`: err is `unknown` under strict TypeScript, so cast before reading name/message.
function Fix-AcdUnknownCatch([string]$t) {
    $out = $t
    $ms = [regex]::Matches($t, 'catch\s*\((\w+)\)\s*\{')
    for ($k = $ms.Count - 1; $k -ge 0; $k--) {
        $m = $ms[$k]
        $name = $m.Groups[1].Value
        $depth = 1; $i = $m.Index + $m.Length
        while ($i -lt $out.Length -and $depth -gt 0) { $c = $out[$i]; if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { $depth-- }; $i++ }
        $start = $m.Index + $m.Length
        $len = [Math]::Max(0, $i - 1 - $start)
        $block = $out.Substring($start, $len)
        if ($block.Contains("${name}: Error")) { continue }
        $fixed = [regex]::Replace($block, '(?<![.\w])(?<!instanceof Error \? )(?<!instanceof Error && )' + [regex]::Escape($name) + '\.(name|message)\b', ('(' + $name + ' as Error).$1'))
        if ($fixed -ne $block) { $out = $out.Substring(0, $start) + $fixed + $out.Substring($start + $len) }
    }
    return $out
}

# `finally { setLoading(false); }` next to an AbortController updates state after an abort/unmount: guard it.
function Fix-AcdStateAfterAbort([string]$t) {
    if (-not $t.Contains('new AbortController()')) { return $t }
    $nm = [regex]::Match($t, '(?:(?:const|let|var)\s+(\w+)\s*(?::[^=;]+)?=\s*new AbortController\(\)|(\w+)\s*=\s*new AbortController\(\))')
    if (-not $nm.Success) { return $t }
    $name = if ($nm.Groups[1].Success) { $nm.Groups[1].Value } else { $nm.Groups[2].Value }
    $out = $t
    $ms = [regex]::Matches($t, 'finally\s*\{\s*(set\w+\([^;{}]*\));?\s*\}')
    for ($i = $ms.Count - 1; $i -ge 0; $i--) {
        $m = $ms[$i]
        if ($m.Value.Contains('aborted')) { continue }
        $stmt = $m.Groups[1].Value
        $repl = "finally {`n        if (!${name}?.signal.aborted) {`n          $stmt;`n        }`n      }"
        $out = $out.Substring(0, $m.Index) + $repl + $out.Substring($m.Index + $m.Length)
    }
    return $out
}

$script:AcdImportRules = @(
    @{ Names = @('useState', 'useEffect', 'useRef', 'useMemo', 'useCallback', 'useContext', 'useReducer', 'useLayoutEffect'); Pkgs = @('react') }
    @{ Names = @('useParams', 'useNavigate', 'useLocation', 'useSearchParams', 'Outlet', 'Link', 'NavLink', 'Navigate', 'createBrowserRouter', 'RouterProvider', 'BrowserRouter', 'Routes', 'Route'); Pkgs = @('react-router', 'react-router-dom') }
    @{ Names = @('useQuery', 'useMutation', 'useQueryClient', 'QueryClient', 'QueryClientProvider'); Pkgs = @('@tanstack/react-query') }
)
function Test-AcdNameUsedNotImported([string]$src, [string]$n) {
    $en = [regex]::Escape($n)
    $used = [regex]::IsMatch($src, "\b$en\s*\(") -or [regex]::IsMatch($src, "<$en[\s/>]")
    if (-not $used) { return $false }
    $imported = [regex]::IsMatch($src, "import[^;]*\b$en\b[^;]*from") -or [regex]::IsMatch($src, "(const|let|var)\s*\{[^}]*\b$en\b[^}]*\}")
    $defined = [regex]::IsMatch($src, "(function|const|let|var|class)\s+$en\b")
    $qualified = $src.Contains("React.$n")
    return (-not $imported -and -not $defined -and -not $qualified)
}

# Names used but not imported (React hooks, React Router, TanStack Query) get added to the block's import line, or a new one.
function Fix-AcdMissingImports([string]$t) {
    $out = $t
    $ms = $script:AcdFenceRe.Matches($t)
    for ($k = $ms.Count - 1; $k -ge 0; $k--) {
        $m = $ms[$k]
        $g = $m.Groups[2]
        $code = $g.Value
        $changed = $false
        foreach ($rule in $script:AcdImportRules) {
            $missing = @()
            foreach ($n in $rule.Names) {
                $en = [regex]::Escape($n)
                $used = [regex]::IsMatch($code, "\b$en\s*\(") -or [regex]::IsMatch($code, "<$en[\s/>]")
                if (-not $used) { continue }
                $imported = [regex]::IsMatch($code, "import[^;]*\b$en\b[^;]*from") -or [regex]::IsMatch($code, "(const|let|var)\s*\{[^}]*\b$en\b[^}]*\}")
                $defined = [regex]::IsMatch($code, "(function|const|let|var|class)\s+$en\b")
                if (-not $imported -and -not $defined -and -not $code.Contains("React.$n")) { $missing += $n }
            }
            if ($missing.Count -eq 0) { continue }
            $pkg = $null
            foreach ($pk in $rule.Pkgs) { if ($code.Contains("from '$pk'") -or $code.Contains("from ""$pk""")) { $pkg = $pk; break } }
            if (-not $pkg) { $pkg = $rule.Pkgs[$rule.Pkgs.Count - 1] }
            $existing = [regex]::Match($code, 'import\s*\{([^}]*)\}\s*from\s*([''"])' + [regex]::Escape($pkg) + '\2')
            if ($existing.Success) {
                $have = $existing.Groups[1].Value.Trim()
                $quote = $existing.Groups[2].Value
                $code = $code.Substring(0, $existing.Index) + 'import { ' + ((@($have) + $missing) -join ', ') + ' } from ' + $quote + $pkg + $quote + $code.Substring($existing.Index + $existing.Length)
            } else {
                $code = 'import { ' + ($missing -join ', ') + " } from '$pkg';`n" + $code
            }
            $changed = $true
        }
        if ($changed) { $out = $out.Substring(0, $g.Index) + $code + $out.Substring($g.Index + $g.Length) }
    }
    return $out
}

# `import type { A } from '../types/x'` next to a local `interface A {...}`: the import clashes with the declaration.
function Fix-AcdDuplicateTypeImports([string]$t) {
    $out = $t
    $ms = $script:AcdFenceRe.Matches($t)
    for ($k = $ms.Count - 1; $k -ge 0; $k--) {
        $m = $ms[$k]
        $g = $m.Groups[2]
        $code = $g.Value
        $imps = [regex]::Matches($code, 'import\s+(?:type\s+)?\{([^}]*)\}\s*from\s*[''"](\.{1,2}/[^''"]*)[''"];?[ \t]*\n?')
        for ($i = $imps.Count - 1; $i -ge 0; $i--) {
            $im = $imps[$i]
            $names = @($im.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $local = @($names | Where-Object { [regex]::IsMatch($code, '\b(interface|type|class|enum)\s+' + [regex]::Escape($_) + '\b') })
            if ($local.Count -eq 0) { continue }
            $rest = @($names | Where-Object { $local -notcontains $_ })
            $whole = $im.Value
            $repl = ''
            if ($rest.Count -gt 0) { $repl = $whole.Replace($im.Groups[1].Value, ' ' + ($rest -join ', ') + ' ') }
            $code = $code.Substring(0, $im.Index) + $repl + $code.Substring($im.Index + $im.Length)
        }
        if ($code -ne $g.Value) { $out = $out.Substring(0, $g.Index) + $code + $out.Substring($g.Index + $g.Length) }
    }
    return $out
}

# A top-level <Route path="/settings" .../> placed after the shared layout route although the question lists that page: move it inside.
function Fix-AcdLayoutRoutes([string]$t, [string]$question) {
    if (-not $question.ToLowerInvariant().Contains('layout')) { return $t }
    $tags = New-Object System.Collections.Generic.List[object]   # Loc, Len, Kind (0 open, 1 self-closing, 2 close), Path
    foreach ($m in [regex]::Matches($t, '<Route\b|</Route>')) {
        if ($m.Value -eq '</Route>') { $tags.Add(@{ Loc = $m.Index; Len = $m.Length; Kind = 2; Path = '' }); continue }
        $i = $m.Index + $m.Length; $braces = 0
        while ($i -lt $t.Length) {                                  # the tag ends at the first '>' outside {...}
            $c = $t[$i]
            if ($c -eq '{') { $braces++ } elseif ($c -eq '}') { $braces-- } elseif ($c -eq '>' -and $braces -eq 0) { break }
            $i++
        }
        if ($i -ge $t.Length) { return $t }
        $len = $i + 1 - $m.Index
        $text = $t.Substring($m.Index, $len)
        $path = ''
        $pm = [regex]::Match($text, 'path\s*=\s*"([^"]*)"')
        if ($pm.Success) { $path = $pm.Groups[1].Value }
        $tags.Add(@{ Loc = $m.Index; Len = $len; Kind = $(if ($text.EndsWith('/>')) { 1 } else { 0 }); Path = $path })
    }
    $li = -1
    for ($i = 0; $i -lt $tags.Count; $i++) { if ($tags[$i].Kind -eq 0 -and $tags[$i].Path -eq '/') { $li = $i; break } }
    if ($li -lt 0) { return $t }
    $layoutElement = ''
    $lt = $t.Substring($tags[$li].Loc, $tags[$li].Len)
    $em = [regex]::Match($lt, 'element\s*=\s*\{\s*(<\w+\s*/>)\s*\}')
    if ($em.Success) { $layoutElement = $em.Groups[1].Value.Replace(' ', '') }
    $depth = 1; $closeIdx = -1
    for ($k = $li + 1; $k -lt $tags.Count; $k++) {
        if ($tags[$k].Kind -eq 0) { $depth++ } elseif ($tags[$k].Kind -eq 2) { $depth--; if ($depth -eq 0) { $closeIdx = $k; break } }
    }
    if ($closeIdx -lt 0) { return $t }
    $removals = New-Object System.Collections.Generic.List[object]   # @(Loc, Len)
    $moved = New-Object System.Collections.Generic.List[string]
    # a second route that wraps the SAME layout around a listed page (with one `index` child): that page becomes a child of the first layout
    if ($layoutElement -ne '') {
        $k = $closeIdx + 1
        while ($k -lt $tags.Count) {
            $tg = $tags[$k]
            if ($tg.Kind -eq 0 -and $tg.Path.StartsWith('/') -and $tg.Path -ne '/' -and $question.Contains($tg.Path)) {
                $openTxt = $t.Substring($tg.Loc, $tg.Len).Replace(' ', '')
                $d = 1; $j = $k + 1; $closeJ = -1
                while ($j -lt $tags.Count) {
                    if ($tags[$j].Kind -eq 0) { $d++ } elseif ($tags[$j].Kind -eq 2) { $d--; if ($d -eq 0) { $closeJ = $j; break } }
                    $j++
                }
                if ($openTxt.Contains('element={' + $layoutElement + '}') -and $closeJ -ge 0) {
                    $iStart = $tg.Loc + $tg.Len
                    $inner = $t.Substring($iStart, $tags[$closeJ].Loc - $iStart)
                    $im = [regex]::Match($inner, '<Route\s+index\s+element\s*=\s*(\{(?:[^{}]|\{[^{}]*\})*\})\s*/>')
                    if ($im.Success) {
                        $element = $im.Groups[1].Value
                        $start = $tg.Loc
                        while ($start -gt 0 -and ($t[$start - 1] -eq ' ' -or $t[$start - 1] -eq "`t")) { $start-- }
                        $end = $tags[$closeJ].Loc + $tags[$closeJ].Len
                        $removals.Add(@($start, ($end - $start)))
                        $moved.Add('<Route path="' + $tg.Path + '" element=' + $element + ' />')
                    }
                }
                $k = $(if ($closeJ -ge 0) { $closeJ } else { $k }) + 1
                continue
            }
            $k++
        }
    }
    for ($k = $closeIdx + 1; $k -lt $tags.Count; $k++) {
        $tg = $tags[$k]
        if (-not ($tg.Kind -eq 1 -and $tg.Path.StartsWith('/') -and $tg.Path -ne '/*' -and $question.Contains($tg.Path))) { continue }
        $start = $tg.Loc
        # swallow the route's own line (indentation) and a comment line directly above it
        while ($start -gt 0 -and ($t[$start - 1] -eq ' ' -or $t[$start - 1] -eq "`t")) { $start-- }
        $rLoc = $start; $rLen = $tg.Loc + $tg.Len - $start
        $before = $t.Substring(0, $start)
        $cms = [regex]::Matches($before, '\n[ \t]*\{/\*[^*]*\*/\}[ \t]*\n$')
        if ($cms.Count -gt 0) {
            $cm = $cms[0]
            if ($before.Substring($cm.Index).IndexOf('outside', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $newLoc = $cm.Index + 1
                $rLen = ($rLoc + $rLen) - $newLoc; $rLoc = $newLoc
            }
        }
        $removals.Add(@($rLoc, $rLen))
        $moved.Add($t.Substring($tg.Loc, $tg.Len))
    }
    if ($moved.Count -eq 0) { return $t }
    $out = $t
    foreach ($r in @($removals | Sort-Object { $_[0] } -Descending)) { $out = $out.Remove($r[0], $r[1]) }
    # insert before the layout's closing tag (its location is unaffected: removals are all after it)
    $closeLoc = $tags[$closeIdx].Loc
    $lineStart = $closeLoc
    while ($lineStart -gt 0 -and ($out[$lineStart - 1] -eq ' ' -or $out[$lineStart - 1] -eq "`t")) { $lineStart-- }
    $indent = $out.Substring($lineStart, $closeLoc - $lineStart) + '  '
    $ins = ''
    foreach ($mv in $moved) { $ins += $indent + $mv + "`n" }
    return $out.Substring(0, $lineStart) + $ins + $out.Substring($lineStart)
}
