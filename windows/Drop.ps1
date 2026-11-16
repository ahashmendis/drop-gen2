# Drop for Windows - small always-on-top popup.
# Drop papers / project folders -> local Ollama model answers -> result copied to the clipboard.
# Requires: Ollama for Windows running, with a local model downloaded (e.g. qwen3-coder).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

# ---- single instance -------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\DropPopupApp')
if (-not $mutex.WaitOne(0)) { exit }

# ---- settings ----------------------------------------------------------------
$DefaultModel = 'qwen3-coder'
$OllamaUrl    = 'http://127.0.0.1:11434'
$SkipDirs     = '\\(target|\.idea|\.git|node_modules|build|out|\.mvn|\.gradle|\.vscode|bin|obj)\\'
$TextExt      = @('.java','.xml','.md','.properties','.yml','.yaml','.json','.txt','.sql','.gradle','.kts','.html','.csv','.cs','.py','.js','.ts')
$DocExt       = @('.pdf','.docx','.md','.txt')

$PromptHeader = @'
You are an expert Java 17 / Spring Boot developer solving a timed 5COSC019W OOP lab exam paper.
Below is the question paper, then the COMPLETE starter project. Aim for full marks.

RULE 1 - USE THE STARTER'S EXACT NAMES. First write, as // comments, an inventory of every class,
method signature, record (with all fields in order), repository method and exception constructor in
the starter. Use ONLY those names. Never invent methods (no findById, findAll, Optional.orElseThrow,
or save() returning a value unless the starter really has them). Copy exception constructor
parameters exactly (if the starter's exception takes a long id, pass the long id, not a String). Use the starter's DTO records
with ALL fields in the right order; never create your own DTO when the starter already has one.
RULE 2 - KEEP WHAT THE PAPER SAYS TO KEEP. Do not change pom.xml, the abstract parent class, DTO
records, the repository API, existing method signatures, package names or annotations such as
@RestControllerAdvice. Replace each "// TODO" and "throw new UnsupportedOperationException(...)"
with real code and leave everything else as given. Create the new classes the paper asks for and
uncomment seed lines when told to.
RULE 3 - VALIDATION GIVES 400, NEVER 500. Null-check before calling methods on a value
(if (x == null || x.isBlank()) throw new IllegalArgumentException(...); only then x.trim()).
Validate every value the paper lists (positive, unique, non-blank, ranges) and save only after all
checks pass. Do arithmetic in long with Math.multiplyExact / Math.addExact / Math.toIntExact, catch
ArithmeticException and rethrow it as IllegalArgumentException. Never divide by a value that could be 0.
RULE 4 - ERROR HANDLER. IllegalArgumentException -> 400 ApiError("BAD_REQUEST", message);
not-found exception -> 404 ApiError("NOT_FOUND", message); conflict exception (if any) -> 409
ApiError("CONFLICT", message). Use the exact codes the paper gives.
RULE 5 - OOP. Put @Override on every overridden method. Process objects through the PARENT type;
never use instanceof or type checks. Sort exactly as the paper says (direction and tie-breaks),
e.g. Comparator.comparingInt(...).thenComparingLong(...) on the parent type's getters.
RULE 6 - FOLLOW EVERY MARK BULLET LITERALLY. Go through each bullet one by one and make the code
do all of it, including every listed rejection reason or code in the right situation.
Idempotency: store the ORIGINAL request per key and compare requests with equals();
same key + same request returns the same result, same key + different request -> 409.
RULE 7 - THIN CONTROLLER. Each handler only calls the service. Name parameters explicitly:
@PathVariable("id"), @RequestParam("minutes"). A POST that creates something returns 201 via
ResponseEntity.status(HttpStatus.CREATED).
RULE 9 - COMMON TRAPS. Keep every annotation already in the starter. Keep ALL the starter's existing import lines
exactly (e.g. keep import java.util.*;); never replace a wildcard import, only ADD imports you need. Variable and return types must
match the starter's method return types exactly. If the paper says an endpoint "returns a JSON object
containing X", return Map.of("X", value), never a bare number.
Controller methods only call the service: no try/catch there; the @RestControllerAdvice handler makes
the 400/404 ApiError responses. Before finishing, re-read every file and fix anything that would not
compile: wrong types, missing imports, methods or constructors that do not exist in the starter.
RULE 10 - HARD PAPERS. Build comparators as a variable, then list.sort(c); never call thenComparing
on a Stream. Never write !x == y; write x != y. Preview/plan methods never change stored state; only
commit persists. For capacity checks build a Map<Integer, int[]> of usage from confirmed reservations
PLUS what this run selected and check EVERY tick of [start, start + duration). Rejection reasons, in
order: larger than capacity -> EXCEEDS_CAPACITY; latestStartTick() < earliest start -> DEADLINE; window
ends before earliest start -> RELEASE_OUTSIDE_WINDOW; nothing fits -> NO_SLOT. Decide reasons with the
parent type's methods, never instanceof. GET lists must be sorted deterministically.
RULE 8 - CHECK SILENTLY. Before you write, work out every example number in the paper against your
code and make sure every name you use exists in the starter and every import is present. Do NOT
write out these checks.

OUTPUT - Java code only. No markdown, no explanations, no inventory, no test commands.
Organise the answer BY TASK, in order. Start each task with its own header line, then give every
Java file that task adds or changes, each one COMPLETE, with a FILE header naming the file to put it in:
// ===== Task 1 =====
// ===== FILE: src/main/java/.../GroundMission.java =====
// ===== Task 2 =====
// ===== FILE: src/main/java/.../AirMission.java =====
// ===== FILE: src/main/java/.../DispatchService.java =====
(Directly under each FILE header write that file's full Java code. Never write placeholders.)
If a file was already given under an earlier task and this task changes it, give it AGAIN, complete,
including the earlier tasks' code (so the last copy of each file is the final version).
For plain Java tasks with no starter project, give each task's code under its // ===== Task N ===== header with a main method.
'@
$ReviewHeader = @'
You are now a strict exam marker AND a senior Java 17 / Spring Boot developer.
Below are the RULES, the exam paper, the starter project, and a DRAFT solution.
Check the draft against every rule and every mark bullet, one by one. Look especially for:
invented methods or names not in the starter, wrong exception constructor parameters, DTO records
with missing or reordered fields, changed signatures or changed protected files, missing validation,
anything that could throw a 500 instead of a 400, unchecked overflow, missing or wrong error-handler
codes, missing @Override, instanceof or type checks, wrong sort direction or tie-break, logic inside
the controller, a POST not returning 201, missing imports, and anything that would not compile.
Recalculate every example number from the paper with the draft's code.
Then output the FINAL corrected solution in exactly the same OUTPUT format as the rules ask
(inventory, tasks, every changed or created file COMPLETE, verification, how to test).
Output only the final solution - code and // comments, no markdown.
'@

# ---- native helpers (hotkey + window dragging) -------------------------------
$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DropNative : NativeWindow {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    public event EventHandler HotKey;
    public DropNative() { CreateHandle(new CreateParams()); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && HotKey != null) { HotKey(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms

# ---- text extraction ---------------------------------------------------------
function Get-DocxText([string]$path) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $entry = $zip.GetEntry('word/document.xml')
        if ($null -eq $entry) { $zip.Dispose(); return '' }
        $sr = New-Object System.IO.StreamReader($entry.Open())
        $xml = $sr.ReadToEnd(); $sr.Close(); $zip.Dispose()
        $xml = $xml -replace '</w:p>', "`n" -replace '<w:tab/>', "`t" -replace '<[^>]+>', ''
        return [System.Net.WebUtility]::HtmlDecode($xml)
    } catch { return '' }
}

function Get-FileText([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if ($ext -eq '.docx') { return Get-DocxText $path }
    if ($ext -eq '.pdf') {
        if (Get-Command pdftotext -ErrorAction SilentlyContinue) {
            try { return ((& pdftotext -layout $path - 2>$null) -join "`n") } catch { return '' }
        }
        return ''
    }
    if ($TextExt -contains $ext) {
        try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
    }
    return ''
}

function Expand-ZipTemp([string]$zip) {
    try {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('drop-' + [guid]::NewGuid().ToString())
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        return $tmp
    } catch { return $null }
}

# Returns @(text, fileCount). Paper/docs first, then code.
function Collect-Input([string[]]$paths) {
    $docs = New-Object System.Text.StringBuilder
    $code = New-Object System.Text.StringBuilder
    $count = 0; $total = 0
    foreach ($p in $paths) {
        if ((-not (Test-Path -LiteralPath $p -PathType Container)) -and $p.ToLower().EndsWith('.zip')) {
            $z = Expand-ZipTemp $p
            if ($z) { $r = Collect-Input @($z); [void]$code.Append($r[0]); $count += $r[1]; Remove-Item -LiteralPath $z -Recurse -Force -ErrorAction SilentlyContinue }
            continue
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            $root = (Get-Item -LiteralPath $p).FullName.TrimEnd('\')
            $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { ($_.FullName -notmatch $SkipDirs) -and (-not $_.Name.StartsWith('~$')) -and ($_.Length -lt 150000) }
        } else {
            $root = Split-Path -Parent (Get-Item -LiteralPath $p).FullName
            $files = @(Get-Item -LiteralPath $p)
        }
        foreach ($f in $files) {
            $t = Get-FileText $f.FullName
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $total += $t.Length
            if ($total -gt 400000) { [void]$code.Append("`n[... more files skipped: too large ...]`n"); break }
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            $chunk = "`n===== FILE: $rel =====`n$t"
            if ($DocExt -contains $f.Extension.ToLower()) { [void]$docs.Append($chunk) } else { [void]$code.Append($chunk) }
            $count++
        }
    }
    # No unzipped project in the folder? Read the starter ZIP instead.
    if ($code.Length -eq 0) {
        foreach ($p in $paths) {
            if (Test-Path -LiteralPath $p -PathType Container) {
                foreach ($zf in (Get-ChildItem -LiteralPath $p -Recurse -File -Filter *.zip -ErrorAction SilentlyContinue)) {
                    $z = Expand-ZipTemp $zf.FullName
                    if ($z) { $r = Collect-Input @($z); [void]$code.Append($r[0]); $count += $r[1]; Remove-Item -LiteralPath $z -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
    $out = ''
    if ($docs.Length -gt 0) { $out += "`n######## EXAM PAPER / INSTRUCTIONS ########`n" + $docs.ToString() }
    if ($code.Length -gt 0) { $out += "`n######## STARTER PROJECT FILES ########`n" + $code.ToString() }
    return @($out, $count)
}

# ---- model choice ------------------------------------------------------------
$script:Model = $DefaultModel
try {
    $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 3
    $names = @($tags.models | ForEach-Object { $_.name } | Where-Object { $_ -notmatch 'cloud' })
    $pick = $names | Where-Object { $_ -like "$DefaultModel*" } | Select-Object -First 1
    if ($pick) { $script:Model = $pick } elseif ($names.Count -gt 0) { $script:Model = $names[0] }
    $script:OllamaOk = $true
} catch { $script:OllamaOk = $false }

# ---- UI ----------------------------------------------------------------------
$W = 240; $CompactH = 70; $AnswerH = 240
$bg   = [System.Drawing.Color]::FromArgb(32, 32, 38)
$fg   = [System.Drawing.Color]::FromArgb(235, 235, 240)
$dim  = [System.Drawing.Color]::FromArgb(150, 150, 165)
$hi   = [System.Drawing.Color]::FromArgb(70, 60, 140)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.BackColor = $bg
$form.Size = New-Object System.Drawing.Size($W, $CompactH)
$form.AllowDrop = $true
$icoPath = Join-Path $PSScriptRoot 'Drop.ico'
if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $W) / 2)), ($wa.Top + 6))

function Set-Rounded {
    $r = 12
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $r, $r, 180, 90)
    $gp.AddArc($form.Width - $r, 0, $r, $r, 270, 90)
    $gp.AddArc($form.Width - $r, $form.Height - $r, $r, $r, 0, 90)
    $gp.AddArc(0, $form.Height - $r, $r, $r, 90, 90)
    $gp.CloseFigure()
    $form.Region = New-Object System.Drawing.Region($gp)
}

$drop = New-Object System.Windows.Forms.Panel
$drop.Location = New-Object System.Drawing.Point(8, 6)
$drop.Size = New-Object System.Drawing.Size(($W - 16), 34)
$drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$drop.AllowDrop = $true
$drop.Cursor = 'Hand'

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Drop to share'
$title.ForeColor = $fg
$title.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$title.TextAlign = 'MiddleCenter'
$title.Dock = 'Top'; $title.Height = 17
$title.AllowDrop = $true

$status = New-Object System.Windows.Forms.Label
$status.ForeColor = $dim
$status.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$status.TextAlign = 'MiddleCenter'
$status.Dock = 'Fill'
$status.AllowDrop = $true
$drop.Controls.Add($status); $drop.Controls.Add($title)

function New-SmallButton([string]$text, [int]$x, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 64)
    $b.ForeColor = $fg
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 7)
    $b.Location = New-Object System.Drawing.Point($x, 44)
    $b.Size = New-Object System.Drawing.Size($w, 18)
    $b.TabStop = $false
    return $b
}
$btnCopy  = New-SmallButton 'Copy'  ($W - 152) 50
$btnShare = New-SmallButton 'Share' ($W - 98)  56
$btnHide  = New-SmallButton 'x'     ($W - 38)  30

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$box.ForeColor = $fg
$box.BorderStyle = 'None'
$box.Font = New-Object System.Drawing.Font('Consolas', 8)
$box.Location = New-Object System.Drawing.Point(8, 68)
$box.Size = New-Object System.Drawing.Size(($W - 16), ($AnswerH - 8))
$box.Visible = $false

$form.Controls.AddRange(@($drop, $btnCopy, $btnShare, $btnHide, $box))

function Set-Status([string]$s) { $status.Text = $s }
if ($script:OllamaOk) { Set-Status 'Ready - click to choose files' } else { Set-Status 'Ollama not running - open Ollama' }

# drag the window by its background
$native = New-Object DropNative
$form.Add_MouseDown({
    if ($_.Button -eq 'Left') { [void][DropNative]::ReleaseCapture(); [void][DropNative]::SendMessage($form.Handle, 0xA1, 2, 0) }
})

function Toggle-Popup {
    if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.Activate() }
}

# Ctrl + Alt + D shows / hides the popup
[void][DropNative]::RegisterHotKey($native.Handle, 1, (0x0001 -bor 0x0002 -bor 0x4000), 0x44)
$native.add_HotKey({ Toggle-Popup })

# tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
if ($form.Icon) { $tray.Icon = $form.Icon } else { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = 'Drop (Ctrl+Alt+D)'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / Hide', $null, { Toggle-Popup })
[void]$menu.Items.Add('Copy last result', $null, { Copy-Again })
[void]$menu.Items.Add('Quit Drop', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Toggle-Popup } })

# ---- generation --------------------------------------------------------------
$script:Running = $false
$script:LastAnswer = ''
$script:Task = $null
$script:Started = $null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(20)

function Copy-Again {
    if ($script:LastAnswer) { [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer); Set-Status 'Copied again - paste with Ctrl+V' }
}

function Start-Answer([string[]]$paths) {
    if ($script:Running) { Set-Status 'Busy - wait for the current result'; return }
    $res = Collect-Input $paths
    $paper = $res[0]; $n = $res[1]
    if (($paper -split '\s+').Count -lt 15) {
        if ($n -eq 0) { Set-Status 'No readable files (PDF needs pdftotext)' } else { Set-Status 'No readable text found' }
        return
    }
    $script:Paper = $paper
    $script:Files = $n
    $script:Phase = 1
    $box.Text = ''
    $script:Running = $true
    Send-Prompt ($PromptHeader + "`n`n" + $paper)
    Set-Status "Read $n file(s) - thinking..."
}

function Send-Prompt([string]$prompt) {
    $need = [int]($prompt.Length / 3) + 8000
    $ctx = 8192
    while ($ctx -lt $need -and $ctx -lt 65536) { $ctx *= 2 }
    $body = @{ model = $script:Model; prompt = $prompt; stream = $false; keep_alive = '30m'; options = @{ num_ctx = $ctx; temperature = 0.2 } } | ConvertTo-Json -Depth 5 -Compress
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    $script:Started = Get-Date
    $script:Task = $client.PostAsync("$OllamaUrl/api/generate", $content)
}

$script:DoubleCheck = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if (-not $script:Running -or $null -eq $script:Task) { return }
    if (-not $script:Task.IsCompleted) {
        $secs = [int]((Get-Date) - $script:Started).TotalSeconds
        if ($script:Phase -eq 1) { $label = 'thinking' } else { $label = 'double-checking' }
        Set-Status ("{0} file(s) - {1}... {2}s" -f $script:Files, $label, $secs)
        return
    }
    try {
        if ($script:Task.IsFaulted) { throw $script:Task.Exception.InnerException }
        $resp = $script:Task.Result
        $text = $resp.Content.ReadAsStringAsync().Result
        if (-not $resp.IsSuccessStatusCode) { $script:Running = $false; Set-Status ("Ollama error " + [int]$resp.StatusCode); $box.Text = $text; return }
        $obj = $text | ConvertFrom-Json
        $answer = [string]$obj.response
        if ($script:Phase -eq 1 -and $script:DoubleCheck) {
            $script:Draft = $answer
            $script:Phase = 2
            Send-Prompt ($ReviewHeader + "`n`n######## RULES ########`n" + $PromptHeader + "`n`n" + $script:Paper + "`n`n######## DRAFT SOLUTION ########`n" + $answer)
            return
        }
        if ($script:Phase -eq 2 -and $answer.Length -lt ($script:Draft.Length / 3)) { $answer = $script:Draft }
        $script:Running = $false
        $answer = ($answer -split "`n" | Where-Object { -not $_.TrimStart().StartsWith('```') }) -join "`r`n"
        $answer = $answer.Trim()
        $script:LastAnswer = $answer
        $box.Text = $answer
        [System.Windows.Forms.Clipboard]::SetText($answer)
        [System.Media.SystemSounds]::Asterisk.Play()
        Set-Status 'Done! Copied - paste with Ctrl+V'
    } catch {
        if ($script:Phase -eq 2 -and $script:Draft) {
            $script:Running = $false
            $script:LastAnswer = $script:Draft.Trim(); $box.Text = $script:LastAnswer
            [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
            Set-Status 'Check failed - draft copied (Ctrl+V)'
        } else {
            $script:Running = $false
            Set-Status 'Error - is the Ollama app running?'
        }
    }
})
$timer.Start()

# ---- events ------------------------------------------------------------------
$onEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy'; $drop.BackColor = $hi }
}
$onLeave = { $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52) }
$onDrop = {
    $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
    $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($paths) { Start-Answer $paths }
}
foreach ($c in @($form, $drop, $title, $status)) {
    $c.Add_DragEnter($onEnter); $c.Add_DragLeave($onLeave); $c.Add_DragDrop($onDrop)
}
$pick = {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Choose files'
    if ($dlg.ShowDialog($form) -eq 'OK') { Start-Answer $dlg.FileNames }
}
foreach ($c in @($drop, $title, $status)) { $c.Add_Click($pick) }

$btnCopy.Add_Click({ Copy-Again })
$btnHide.Add_Click({ $form.Hide() })
$btnShare.Add_Click({
    $box.Visible = -not $box.Visible
    if ($box.Visible) { $form.Height = $CompactH + $AnswerH } else { $form.Height = $CompactH }
    Set-Rounded
})

Set-Rounded
$form.Show()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$mutex.ReleaseMutex()
