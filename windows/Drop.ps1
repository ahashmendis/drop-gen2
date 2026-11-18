# Drop for Windows - small always-on-top popup.
# Drop papers / project folders -> local Ollama model answers -> result copied to the clipboard.
# Requires: Ollama for Windows running, with at least one local Qwen model downloaded.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

# ---- single instance -------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\DropPopupApp')
if (-not $mutex.WaitOne(0)) { exit }

# ---- settings ----------------------------------------------------------------
$OllamaUrl    = 'http://127.0.0.1:11434'
$SkipDirs     = '\\(target|\.idea|\.git|node_modules|build|out|\.mvn|\.gradle|\.vscode|bin|obj)\\'
$TextExt      = @('.java','.xml','.md','.properties','.yml','.yaml','.json','.txt','.sql','.gradle','.kts','.html','.csv','.cs','.py','.js','.ts')
$DocExt       = @('.pdf','.docx','.md','.txt')

# ---- local configuration (Phase 3: file storage, no Credential Manager) -----
$ConfigDir  = Join-Path $env:APPDATA 'Drop'
$ConfigPath = Join-Path $ConfigDir 'config.json'
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

function Read-DropConfig {
    $defaults = @{
        provider    = 'ollama'
        ollama      = @{ base_url = $OllamaUrl; default_model = ''; context = 0 }
        opencode_go = @{ base_url = 'https://opencode.ai/zen/go/v1'; api_key = ''; model = 'mimo-v2.6-flash' }
        network     = @{ connect_timeout = 20; stream_idle_timeout = 120; retry_attempts = 3; retry_backoff = $true }
        preferences = @{ remember_provider = $true; allow_fallback = $false }
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]$defaults[$k]) }
            }
            return $j
        } catch { }
    }
    # First launch: write defaults (never overwrites an existing file above)
    $json = $defaults | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8
    try { icacls $ConfigPath /inheritance:r /grant:r "${env:USERNAME}:M" | Out-Null } catch { }
    return ($defaults | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
}

function Write-DropConfig($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    # Re-assert user-only access every save
    try { icacls $ConfigPath /inheritance:r /grant:r "${env:USERNAME}:M" | Out-Null } catch { }
}

$script:Config = Read-DropConfig
$script:Provider = if ($script:Config.provider -eq 'opencode_go') { 'opencode_go' } else { 'ollama' }
# x-opencode-session: stable for one conversation (prompt + retries reuse it),
# rotated when a new drop starts. Runtime-only, never written to config.json.
$script:SessionId = [guid]::NewGuid().ToString()
$OllamaUrl = $script:Config.ollama.base_url

# Hardware-aware Ollama context target (conservative presets by system RAM;
# a manual ollama.context > 0 wins). Mirrors the macOS implementation.
$script:RamGB = $null
function Get-OllamaContextTarget([int]$manual) {
    if ($manual -gt 0) { return [Math]::Min($manual, 65536) }
    if ($null -eq $script:RamGB) {
        $script:RamGB = 8
        try {
            $b = [int64]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory)
            $script:RamGB = [int](($b + 536870912) / 1GB)   # round to nearest GiB
        } catch { }
    }
    if ($script:RamGB -lt 16) { return 8192 }     # 8 GB class -> 8192
    if ($script:RamGB -lt 32) { return 16384 }    # 16 GB      -> 8192-16384
    if ($script:RamGB -lt 64) { return 16384 }    # 32 GB      -> 16384-32768 (conservative low)
    return 32768                                  # 64 GB+     -> 32768-65536 (conservative low)
}
function Get-OllamaManualContext {
    if ($null -eq $script:Config.ollama.context) { return 0 }
    try { return [int]$script:Config.ollama.context } catch { return 0 }
}

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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    public event EventHandler HotKey;
    public int LastHotKeyId;   // WM_HOTKEY id, read by the PowerShell dispatcher
    public DropNative() { CreateHandle(new CreateParams()); }
    public static bool IsIntelliJForeground() {
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try {
            var p = System.Diagnostics.Process.GetProcessById(pid);
            var n = p.ProcessName.ToLowerInvariant();
            return n == "idea64" || n == "idea";   // process name only - no title match (fails closed)
        } catch { return false; }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) {
            LastHotKeyId = m.WParam.ToInt32();
            if (HotKey != null) { HotKey(this, EventArgs.Empty); }
        }
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

# ---- model choice (provider-aware: no localhost:11434 traffic when OpenCode selected) ----
# Qwen-family discovery from GET /api/tags: model metadata first
# (details.family / details.families), falling back to the model name.
# All installed Qwen variants are offered - never a single hardcoded model.
$script:QwenModels    = @()
$script:MissingSaved  = $null
$script:ModelCombo    = $null

function Sync-ModelCombo {
    $c = $script:ModelCombo
    if ($null -eq $c) { return }
    $c.Items.Clear()
    foreach ($m in $script:QwenModels) { [void]$c.Items.Add($m) }
    if ($script:Model -and ($script:QwenModels -contains $script:Model)) {
        $c.SelectedItem = $script:Model
    } elseif ($c.Items.Count -gt 0) {
        $c.SelectedIndex = 0
    }
}

# Returns $true when Ollama is reachable. Never selects a model that does
# not exist: the saved selection is used only if it is still installed.
function Update-OllamaModels {
    try {
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 3
        $script:QwenModels = @($tags.models | Where-Object {
            $n = [string]$_.name
            if ([string]::IsNullOrEmpty($n) -or $n -match 'cloud') { return $false }
            $fam = @()
            if ($null -ne $_.details) {
                if ($_.details.family)   { $fam += [string]$_.details.family }
                if ($_.details.families) { $fam += @($_.details.families) }
            }
            if (($fam -join ' ') -match 'qwen') { return $true }
            return ($n -match 'qwen')
        } | ForEach-Object { [string]$_.name } | Sort-Object)
        $script:OllamaOk = $true
        $script:MissingSaved = $null
        $saved = [string]$script:Config.ollama.default_model
        if ($script:QwenModels.Count -gt 0) {
            if ($saved -and ($script:QwenModels -contains $saved)) {
                $script:Model = $saved
            } else {
                if ($saved) { $script:MissingSaved = $saved }
                $script:Model = $script:QwenModels[0]
            }
        } else {
            $script:Model = ''
        }
        Sync-ModelCombo
        return $true
    } catch {
        $script:OllamaOk = $false
        $script:QwenModels = @()
        $script:MissingSaved = $null
        $script:Model = ''
        Sync-ModelCombo
        return $false
    }
}

$script:Model = ''
$script:CloudOk = $false
if ($script:Provider -eq 'opencode_go') {
    $script:Model = $script:Config.opencode_go.model
    $script:OllamaOk = $false
    $script:CloudOk = -not [string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)
} else {
    [void](Update-OllamaModels)
}

# ---- UI ----------------------------------------------------------------------
$W = 240; $CompactH = 90; $AnswerH = 240   # 90 = drop + model dropdown + buttons
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
    $b.Location = New-Object System.Drawing.Point($x, 66)
    $b.Size = New-Object System.Drawing.Size($w, 18)
    $b.TabStop = $false
    return $b
}
$btnCopy  = New-SmallButton 'Copy'  ($W - 152) 50
$btnShare = New-SmallButton 'Share' ($W - 98)  56
$btnHide  = New-SmallButton 'x'     ($W - 38)  30
$btnProv  = New-SmallButton 'Ollama' 8 74
$btnProv.Add_Click({ Switch-Provider ($(if ($script:Provider -eq 'ollama') { 'opencode_go' } else { 'ollama' })) })

# Dynamic model selector: every installed Qwen model, discovered from Ollama.
$cmbModel = New-Object System.Windows.Forms.ComboBox
$cmbModel.DropDownStyle = 'DropDownList'
$cmbModel.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$cmbModel.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$cmbModel.ForeColor = $fg
$cmbModel.Location = New-Object System.Drawing.Point(8, 44)
$cmbModel.Size = New-Object System.Drawing.Size(($W - 16), 20)
$cmbModel.TabStop = $false
$script:ModelCombo = $cmbModel
$cmbModel.Add_SelectedIndexChanged({
    if ($script:Provider -ne 'ollama') { return }
    $sel = [string]$script:ModelCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if ($script:Model -ne $sel) {
        # Remember the selected model locally (config file, user-only access).
        $script:Model = $sel
        $script:Config.ollama | Add-Member -NotePropertyName default_model -NotePropertyValue $sel -Force
        Write-DropConfig $script:Config
    }
})
Sync-ModelCombo

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$box.ForeColor = $fg
$box.BorderStyle = 'None'
$box.Font = New-Object System.Drawing.Font('Consolas', 8)
$box.Location = New-Object System.Drawing.Point(8, 88)
$box.Size = New-Object System.Drawing.Size(($W - 16), ($AnswerH - 8))
$box.Visible = $false

$form.Controls.AddRange(@($drop, $cmbModel, $btnProv, $btnCopy, $btnShare, $btnHide, $box))

function Set-Status([string]$s) { $status.Text = $s }
# Ollama-only status (never called while OpenCode is selected, so the
# OpenCode status flow is untouched).
function Set-OllamaStatus {
    if ($script:Provider -ne 'ollama') { return }
    if (-not $script:OllamaOk) { Set-Status 'Ollama not running - open Ollama' }
    elseif ($script:QwenModels.Count -eq 0) { Set-Status 'No Qwen models installed - ollama pull a Qwen model first' }
    elseif ($script:MissingSaved) { Set-Status "Saved model '$($script:MissingSaved)' not installed - using '$($script:Model)'" }
    else { Set-Status 'Ready - click to choose files' }
}
if ($script:Provider -eq 'opencode_go') {
    if ($script:CloudOk) { Set-Status 'OpenCode Go ready - click to choose files' }
    else { Set-Status 'No OpenCode API key - open Settings (tray)' }
} else { Set-OllamaStatus }

# ---- provider switching (never silent: only via button/tray/settings) ---------
function Switch-Provider([string]$which) {
    if ($script:Running) { Set-Status 'Busy - wait before switching'; return }
    $script:Provider = $which
    $script:Config.provider = $which
    if ($script:Config.preferences.remember_provider) { Write-DropConfig $script:Config }
    $btnProv.Text = if ($which -eq 'ollama') { 'Ollama' } else { 'OpenCode' }
    $script:Attempt = 0
    if ($which -eq 'opencode_go') {
        $script:Model = $script:Config.opencode_go.model
        $script:CloudOk = -not [string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)
        # Phase 5: no localhost:11434 traffic while OpenCode is selected
        Set-Status $(if ($script:CloudOk) { 'OpenCode Go selected - cloud' } else { 'No OpenCode API key - open Settings (tray)' })
    } else {
        if (Update-OllamaModels) {
            if ($script:QwenModels.Count -eq 0) {
                Set-Status 'No Qwen models installed - ollama pull a Qwen model first'
            } elseif ($script:MissingSaved) {
                Set-Status "Saved model '$($script:MissingSaved)' not installed - using '$($script:Model)'"
            } else {
                Set-Status 'Ollama selected - local only'
            }
        } else {
            Set-Status 'Ollama selected - not running'
        }
    }
}

# ---- settings dialog (Phase 6) ------------------------------------------------
function Show-DropSettings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Drop Settings'
    $dlg.Size = New-Object System.Drawing.Size(430, 322)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'

    $lblP = New-Object System.Windows.Forms.Label; $lblP.Text = 'Provider:'; $lblP.Location = New-Object System.Drawing.Point(12, 15); $lblP.AutoSize = $true
    $cmbP = New-Object System.Windows.Forms.ComboBox; $cmbP.DropDownStyle = 'DropDownList'; $cmbP.Location = New-Object System.Drawing.Point(100, 12); $cmbP.Size = New-Object System.Drawing.Size(290, 24)
    [void]$cmbP.Items.AddRange(@('Ollama', 'OpenCode Go'))
    $cmbP.SelectedIndex = if ($script:Provider -eq 'opencode_go') { 1 } else { 0 }
    # Keep Base URL showing the selected provider's own value, so Save can never
    # write the Ollama URL into opencode_go.base_url (or vice versa).
    $cmbP.Add_SelectedIndexChanged({
        $txtB.Text = if ($cmbP.SelectedIndex -eq 1) { $script:Config.opencode_go.base_url } else { $script:Config.ollama.base_url }
    })

    $lblB = New-Object System.Windows.Forms.Label; $lblB.Text = 'Base URL:'; $lblB.Location = New-Object System.Drawing.Point(12, 48); $lblB.AutoSize = $true
    $txtB = New-Object System.Windows.Forms.TextBox; $txtB.Location = New-Object System.Drawing.Point(100, 45); $txtB.Size = New-Object System.Drawing.Size(290, 24)
    $txtB.Text = if ($script:Provider -eq 'opencode_go') { $script:Config.opencode_go.base_url } else { $script:Config.ollama.base_url }

    $lblK = New-Object System.Windows.Forms.Label; $lblK.Text = 'API key:'; $lblK.Location = New-Object System.Drawing.Point(12, 81); $lblK.AutoSize = $true
    $txtK = New-Object System.Windows.Forms.TextBox; $txtK.Location = New-Object System.Drawing.Point(100, 78); $txtK.Size = New-Object System.Drawing.Size(290, 24)
    $txtK.UseSystemPasswordChar = $true
    $txtK.Text = $script:Config.opencode_go.api_key   # local edit only; never logged

    $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = 'Model:'; $lblM.Location = New-Object System.Drawing.Point(12, 114); $lblM.AutoSize = $true
    $txtM = New-Object System.Windows.Forms.TextBox; $txtM.Location = New-Object System.Drawing.Point(100, 111); $txtM.Size = New-Object System.Drawing.Size(290, 24)
    $txtM.Text = $script:Config.opencode_go.model

    # Ollama-only context override (0 = hardware preset); OpenCode Go unaffected.
    $lblC = New-Object System.Windows.Forms.Label; $lblC.Text = 'Qwen ctx:'; $lblC.Location = New-Object System.Drawing.Point(12, 148); $lblC.AutoSize = $true
    $txtC = New-Object System.Windows.Forms.TextBox; $txtC.Location = New-Object System.Drawing.Point(100, 145); $txtC.Size = New-Object System.Drawing.Size(290, 24)
    $txtC.Text = [string](Get-OllamaManualContext)

    $chkR = New-Object System.Windows.Forms.CheckBox; $chkR.Text = 'Remember selected provider'; $chkR.Location = New-Object System.Drawing.Point(100, 175); $chkR.AutoSize = $true
    $chkR.Checked = [bool]$script:Config.preferences.remember_provider
    $chkF = New-Object System.Windows.Forms.CheckBox; $chkF.Text = 'Offer Ollama fallback if OpenCode fails (explicit approval)'; $chkF.Location = New-Object System.Drawing.Point(100, 200); $chkF.AutoSize = $true
    $chkF.Checked = [bool]$script:Config.preferences.allow_fallback

    $lblS = New-Object System.Windows.Forms.Label; $lblS.Location = New-Object System.Drawing.Point(12, 258); $lblS.Size = New-Object System.Drawing.Size(300, 30); $lblS.AutoSize = $false

    $btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = 'Test Connection'; $btnTest.Location = New-Object System.Drawing.Point(100, 228); $btnTest.Size = New-Object System.Drawing.Size(120, 26)
    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = 'Save'; $btnSave.Location = New-Object System.Drawing.Point(230, 228); $btnSave.Size = New-Object System.Drawing.Size(80, 26)

    $btnTest.Add_Click({
        $lblS.Text = 'Testing...'
        [System.Windows.Forms.Application]::DoEvents()
        $b = $txtB.Text.TrimEnd('/')
        if ($cmbP.SelectedIndex -eq 1) {
            if ([string]::IsNullOrWhiteSpace($txtK.Text)) { $lblS.Text = 'Enter an API key first'; return }
            try {
                # Real authenticated chat ping: proves endpoint + key + model together.
                # (GET /models is public, so it cannot verify the key.)
                # Body + headers exactly match the verified 200-OK baseline request.
                $mName = if ([string]::IsNullOrWhiteSpace($txtM.Text)) { $script:Config.opencode_go.model } else { $txtM.Text.Trim() }
                $mb = @{
                    model    = $mName
                    messages = @(@{ role = 'user'; content = 'Reply with exactly: Drop connection successful' })
                    stream   = $false
                } | ConvertTo-Json -Depth 5 -Compress
                $hc = New-Object System.Net.Http.HttpClient
                $hc.Timeout = [TimeSpan]::FromSeconds(30)
                $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$b/chat/completions")
                $rq.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $txtK.Text)
                $rq.Headers.TryAddWithoutValidation('User-Agent', 'Drop/1.0') | Out-Null
                $rq.Headers.TryAddWithoutValidation('x-opencode-session', [guid]::NewGuid().ToString()) | Out-Null
                $rq.Content = New-Object System.Net.Http.StringContent($mb, [System.Text.Encoding]::UTF8, 'application/json')
                $rs = $hc.SendAsync($rq).Result
                if ($rs.IsSuccessStatusCode) {
                    $j = $rs.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                    $word = ([string]$j.choices[0].message.content).Trim()
                    if ($word) { $lblS.Text = 'OK - OpenCode Go answered: ' + $word.Substring(0, [math]::Min(30, $word.Length)) }
                    else { $lblS.Text = 'Endpoint OK but response was empty' }
                }
                elseif ([int]$rs.StatusCode -in 401,403) { $lblS.Text = 'Invalid API key (401/403)' }
                else { $lblS.Text = Get-DropErrorKind ([int]$rs.StatusCode) ($rs.Content.ReadAsStringAsync().Result) }
            } catch {
                $ex = $_.Exception
                while ($ex.InnerException) { $ex = $ex.InnerException }
                $lblS.Text = if ($ex -is [System.Security.Authentication.AuthenticationException]) { 'TLS certificate error' }
                             elseif ($ex -is [System.Net.Sockets.SocketException]) { 'Cannot reach endpoint (network/DNS)' }
                             else { "Cannot reach endpoint: $($ex.Message)" }
            }
        } else {
            try {
                $null = Invoke-RestMethod -Uri "$b/api/tags" -TimeoutSec 5
                $lblS.Text = 'OK - Ollama reachable'
            } catch { $lblS.Text = 'Ollama not reachable at that URL' }
        }
    })
    $btnSave.Add_Click({
        if ($cmbP.SelectedIndex -eq 1) {
            $script:Config.opencode_go.base_url = $txtB.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($txtK.Text)) { $script:Config.opencode_go.api_key = $txtK.Text }
            if (-not [string]::IsNullOrWhiteSpace($txtM.Text)) { $script:Config.opencode_go.model = $txtM.Text.Trim() }
        } else {
            $script:Config.ollama.base_url = $txtB.Text.Trim()
            Set-Variable -Name OllamaUrl -Value $script:Config.ollama.base_url -Scope Script
        }
        # Ollama context override (0 = hardware preset); stored in the ollama
        # section only - the opencode_go config format is untouched.
        $ctxIn = 0
        if ([int]::TryParse($txtC.Text.Trim(), [ref]$ctxIn) -and $ctxIn -ge 0) {
            $script:Config.ollama | Add-Member -NotePropertyName context -NotePropertyValue $ctxIn -Force
        }
        $script:Config.preferences.remember_provider = $chkR.Checked
        $script:Config.preferences.allow_fallback = $chkF.Checked
        Write-DropConfig $script:Config
        $lblS.Text = 'Saved (key stored locally, user-only access)'
        $dlg.Close()
        Switch-Provider $(if ($cmbP.SelectedIndex -eq 1) { 'opencode_go' } else { 'ollama' })
    })

    $dlg.Controls.AddRange(@($lblP, $cmbP, $lblB, $txtB, $lblK, $txtK, $lblM, $txtM, $lblC, $txtC, $chkR, $chkF, $btnTest, $btnSave, $lblS))
    [void]$dlg.ShowDialog()
}

# drag the window by its background
$native = New-Object DropNative
$form.Add_MouseDown({
    if ($_.Button -eq 'Left') { [void][DropNative]::ReleaseCapture(); [void][DropNative]::SendMessage($form.Handle, 0xA1, 2, 0) }
})

function Toggle-Popup {
    if ($form.Visible) {
        $form.Hide()
    } else {
        $form.Show(); $form.Activate()
        # Refresh the Qwen list when shown (newly installed / removed models are
        # picked up). Ollama-only: OpenCode Go never gets extra traffic here.
        if ($script:Provider -eq 'ollama' -and -not $script:Running) {
            [void](Update-OllamaModels)
            Set-OllamaStatus
        }
    }
}

# Frontmost gate for the IntelliJ-workflow hotkeys (Ctrl+Alt+R/C/1-0): they
# act only while IntelliJ or Drop itself is frontmost; presses elsewhere are
# ignored. Ctrl+Alt+D stays global and ungated.
function Test-DropHotkeyGate {
    if ([DropNative]::IsIntelliJForeground()) { return $true }
    return ([DropNative]::GetForegroundWindow() -eq $form.Handle)  # Drop itself frontmost
}

# Ctrl+Alt+R: read Desktop/OOP and start the run - headless, never opens the
# popup (the user opens it manually with Ctrl+Alt+D to watch progress).
function Start-OopRun {
    if (-not (Test-DropHotkeyGate)) { return }
    if ($script:Running) { Set-Status 'Busy - wait for the current result'; return }
    $oop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OOP'
    if (-not (Test-Path -LiteralPath $oop -PathType Container)) {
        Set-Status 'OOP folder not found on Desktop'; return
    }
    Start-Answer @($oop)   # headless: never calls Toggle-Popup
}

# Slice "…===== Task N ===== …" up to (excluding) the next Task header.
# The model emits headers as "// ===== Task N =====" (per $PromptHeader), so
# each line is TrimStart'ed and an optional leading '//' stripped BEFORE the
# comparison. StartsWith("===== Task $n =====") pins the trailing header text,
# so Task 1 can never match a Task 10 line. Returns $null when absent.
function Get-TaskSection([string]$answer, [int]$n) {
    $lines = $answer -split "`r?`n"
    $header = "===== Task $n ====="
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimStart()
        if ($t.StartsWith('//')) { $t = $t.Substring(2).TrimStart() }
        if ($t.StartsWith($header)) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimStart()
        if ($t.StartsWith('//')) { $t = $t.Substring(2).TrimStart() }
        if ($t.StartsWith("===== Task ")) { $end = $i; break }
    }
    $slice = ($lines[$start..($end - 1)] -join "`r`n").Trim()
    if ([string]::IsNullOrWhiteSpace($slice)) { return $null }
    return $slice
}

# Ctrl+Alt+C: copy the full last answer (same path as the Copy button).
function Copy-AllAnswer {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Set-Status 'No answer yet'; return }
    [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
    Set-Status 'Copied - paste with Ctrl+V'
}

# Ctrl+Alt+1..0: copy just Task N's section of the last answer.
function Copy-TaskAnswer([int]$n) {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Set-Status 'No answer yet'; return }
    $s = Get-TaskSection $script:LastAnswer $n
    if ($null -eq $s) { Set-Status "Task $n not found in answer"; return }
    [System.Windows.Forms.Clipboard]::SetText($s)
    Set-Status "Task $n copied - paste with Ctrl+V"
}

# Hotkeys: id 1 = Ctrl+Alt+D (global), 2 = R (OOP run), 3 = C (copy-all,
# Task 4), 4..13 = 1..9,0 (task copy, Task 4). Dispatch by WndProc-recorded id.
$mods = (0x0001 -bor 0x0002 -bor 0x4000)   # Ctrl + Alt + no-repeat
[void][DropNative]::RegisterHotKey($native.Handle, 1, $mods, 0x44)   # D
$vkMap = [ordered]@{ 2 = 0x52; 3 = 0x43; 4 = 0x31; 5 = 0x32; 6 = 0x33; 7 = 0x34
                     8 = 0x35; 9 = 0x36; 10 = 0x37; 11 = 0x38; 12 = 0x39; 13 = 0x30 }
foreach ($id in $vkMap.Keys) {
    [void][DropNative]::RegisterHotKey($native.Handle, $id, $mods, $vkMap[$id])
}
$native.add_HotKey({
    switch ($native.LastHotKeyId) {
        1 { Toggle-Popup }
        2 { Start-OopRun }
        3 { Copy-AllAnswer }
        { $_ -ge 4 -and $_ -le 13 } { Copy-TaskAnswer ($_ - 3) }
        default { }
    }
})

# tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
if ($form.Icon) { $tray.Icon = $form.Icon } else { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = 'Drop (Ctrl+Alt+D)'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / Hide', $null, { Toggle-Popup })
[void]$menu.Items.Add('Copy last result', $null, { Copy-Again })
[void]$menu.Items.Add('Settings...', $null, { Show-DropSettings })
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
    if ($script:Provider -eq 'ollama' -and [string]::IsNullOrWhiteSpace($script:Model)) {
        # Never send a request for a model that does not exist.
        Set-Status 'No Qwen model installed - ollama pull a Qwen model first'
        return
    }
    $script:Paper = $paper
    $script:Files = $n
    $script:Phase = 1
    $script:Attempt = 0
    $script:SessionId = [guid]::NewGuid().ToString()   # new conversation → new session id
    $box.Text = ''
    $script:Running = $true
    Send-Prompt ($PromptHeader + "`n`n" + $paper)
    Set-Status "Read $n file(s) - thinking..."
}

# ---- provider adapters (Phase 4/5) -------------------------------------------
# Error classification (Phase 7A): distinct conditions, never one generic blob.
function Get-DropErrorKind([int]$Status, [string]$Body) {
    # The provider's own explanation of WHY the request was rejected - this is
    # what turns a bare "Invalid request (400)" into an actionable message.
    # Parsed defensively; capped; never contains the API key.
    $extra = ''
    if ($Body) {
        if ($Body -match '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        elseif ($Body -match '"error"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        elseif ($Body -match '"detail"\s*:\s*"((?:[^"\\]|\\.)*)"') { $extra = $Matches[1] }
        if ($extra) {
            $extra = $extra -replace '\\n', ' ' -replace '\\r', ' ' -replace '\\"', '"' -replace '\\/', '/'
            if ($extra.Length -gt 160) { $extra = $extra.Substring(0, 160) }
            $extra = ' - ' + $extra
        }
    }
    switch ($Status) {
        400 { return "Invalid request (400)$extra" }
        401 { return "Invalid API key (401)$extra" }
        403 { return "Access denied (403)$extra" }
        404 { return "Endpoint or model not found (404)$extra" }
        408 { return "Request timeout (408)$extra" }
        429 { return "Rate limited (429)$extra" }
        { $_ -ge 500 -and $_ -le 599 } { return "Provider server error ($Status)$extra" }
        default {
            if ($extra) { return "HTTP $Status$extra" }
            return "HTTP $Status"
        }
    }
}

function Test-DropTransient([int]$Status) {
    # Retry only transient conditions; never auth/400/404.
    return ($Status -eq 408 -or $Status -eq 429 -or ($Status -ge 500 -and $Status -le 599))
}

$script:Attempt = 0

function Send-Prompt([string]$prompt) {
    $script:Started = Get-Date
    $script:LastPrompt = $prompt
    if ($script:Provider -eq 'opencode_go') {
        $cfg = $script:Config
        if ([string]::IsNullOrWhiteSpace($cfg.opencode_go.api_key)) {
            $script:Running = $false
            Set-Status 'No OpenCode API key - open Settings from the tray'
            return
        }
        $base = $cfg.opencode_go.base_url.TrimEnd('/')
        # Phase 7D: bounded retries with exponential backoff + jitter (Windows side
        # retries at the Send-Prompt level via the timer's transient classification).
        # Exact shape of the verified (200 OK) baseline request — no extra fields.
        $body = @{
            model    = $cfg.opencode_go.model
            messages = @(@{ role = 'user'; content = $prompt })
            stream   = $false            # Phase 10: Windows keeps non-streaming for now
        } | ConvertTo-Json -Depth 5 -Compress
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$base/chat/completions")
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $cfg.opencode_go.api_key)
        $req.Headers.TryAddWithoutValidation('User-Agent', 'Drop/1.0') | Out-Null
        $req.Headers.TryAddWithoutValidation('x-opencode-session', $script:SessionId) | Out-Null
        $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $script:Task = $client.SendAsync($req)
        return
    }
    # Ollama path (stream:false, keep_alive, num_ctx). Prompt-size sizing as
    # before, with the hardware-aware target (RAM preset or manual override)
    # applied as a floor; the existing 65536 hard cap is unchanged.
    $need = [int]($prompt.Length / 3) + 8000
    $ctx = 8192
    while ($ctx -lt $need -and $ctx -lt 65536) { $ctx *= 2 }
    $target = Get-OllamaContextTarget (Get-OllamaManualContext)
    if ($ctx -lt $target) { $ctx = $target }
    if ($ctx -gt 65536) { $ctx = 65536 }
    $body = @{ model = $script:Model; prompt = $prompt; stream = $false; keep_alive = '30m'; options = @{ num_ctx = $ctx; temperature = 0.2 } } | ConvertTo-Json -Depth 5 -Compress
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
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
        if (-not $resp.IsSuccessStatusCode) {
            $status = [int]$resp.StatusCode
            $kind = Get-DropErrorKind $status $text
            # Phase 7D: retry transient errors with exponential backoff + jitter.
            # Never retry auth/400/404. Retry-After honoured when present.
            $maxAttempts = [int]$script:Config.network.retry_attempts
            if ((Test-DropTransient $status) -and $script:Attempt -lt ($maxAttempts - 1) -and $script:Config.network.retry_backoff) {
                $script:Attempt++
                $delay = [math]::Pow(2, $script:Attempt - 1) + (Get-Random -Minimum 0 -Maximum 500) / 1000.0
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $delay = [math]::Max($delay, $ra.Delta.TotalSeconds) }
                Set-Status ("{0} - retry {1}/{2} in {3:N1}s..." -f $kind, $script:Attempt, ($maxAttempts - 1), $delay)
                Start-Sleep -Seconds $delay
                Send-Prompt $script:LastPrompt
                return
            }
            # Phase 7F: endpoint unreachable on this network? Offer Ollama only with approval.
            $msg = $kind
            if ($script:Provider -eq 'opencode_go' -and ($status -in 408,429 -or $status -ge 500 -or $kind -match 'unreachable|timeout')) {
                if ($script:Config.preferences.allow_fallback) {
                    $r = [System.Windows.Forms.MessageBox]::Show(
                        "$kind`n`nSwitch to Ollama (local) for this answer?",
                        'OpenCode Go unavailable', 'YesNo', 'Warning')
                    if ($r -eq 'Yes') {
                        Switch-Provider 'ollama'
                        # Re-send the exact same request through the approved
                        # provider; timer keeps running (Running stays true).
                        # If Ollama also fails, its error path stops cleanly -
                        # no fallback loop (retry is OpenCode-only).
                        Send-Prompt $script:LastPrompt
                        return
                    }
                } else {
                    $msg = "$kind - this network may restrict access (Ollama fallback is off in Settings)"
                }
            }
            $script:Running = $false
            Set-Status $msg
            $box.Text = $text.Substring(0, [math]::Min(500, $text.Length))
            return
        }
        $obj = $text | ConvertFrom-Json
        if ($script:Provider -eq 'opencode_go') {
            # OpenAI-compatible: choices[0].message.content (defensive parse)
            $answer = ''
            if ($obj.choices -and $obj.choices.Count -gt 0) { $answer = [string]$obj.choices[0].message.content }
            if ([string]::IsNullOrWhiteSpace($answer)) {
                $script:Running = $false
                $errTxt = if ($obj.error.message) { [string]$obj.error.message } else { 'empty response' }
                Set-Status "OpenCode error: $errTxt"
                $box.Text = $text.Substring(0, [math]::Min(500, $text.Length))
                return
            }
        } else {
            $answer = [string]$obj.response
        }
        $script:Attempt = 0
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
            return
        }
        # Phase 7A: classify the transport failure instead of one generic message.
        $inner = $script:Task.Exception
        while ($inner -and $inner.InnerException) { $inner = $inner.InnerException }
        $msg = 'Error'
        if ($inner -is [System.Net.Sockets.SocketException]) {
            $msg = switch ($inner.SocketErrorCode) {
                ([System.Net.Sockets.SocketError]::HostNotFound) { 'DNS lookup failed' }
                ([System.Net.Sockets.SocketError]::TryAgain)    { 'DNS lookup failed' }
                ([System.Net.Sockets.SocketError]::ConnectionRefused) { 'Connection refused - server not running or blocked' }
                ([System.Net.Sockets.SocketError]::TimedOut)    { 'Connection timed out' }
                default { "Network error: $($inner.SocketErrorCode)" }
            }
        } elseif ($inner -is [System.Security.Authentication.AuthenticationException]) {
            $msg = 'TLS certificate error'
        } elseif ($inner -is [System.Net.Http.HttpRequestException]) {
            $msg = "Cannot reach endpoint - this network may restrict access ($($inner.Message))"
        } elseif ($inner -is [System.Threading.Tasks.TaskCanceledException] -or $inner -is [System.TimeoutException]) {
            $msg = 'Request timed out'
        } elseif ($inner) {
            $msg = $inner.Message
        }
        # Phase 7D: transient transport failures retry with backoff too (OpenCode Go
        # only - Ollama keeps its original no-retry behaviour). TLS errors never retry.
        $transient = ($inner -is [System.Threading.Tasks.TaskCanceledException]) -or
            ($inner -is [System.TimeoutException]) -or
            ($inner -is [System.Net.Http.HttpRequestException]) -or
            ($inner -is [System.Net.Sockets.SocketException])
        $maxAttempts = [int]$script:Config.network.retry_attempts
        if ($script:Provider -eq 'opencode_go' -and $transient -and
            $script:Config.network.retry_backoff -and $script:Attempt -lt ($maxAttempts - 1)) {
            $script:Attempt++
            $delay = [math]::Pow(2, $script:Attempt - 1) + (Get-Random -Minimum 0 -Maximum 500) / 1000.0
            Set-Status ("{0} - retry {1}/{2} in {3:N1}s..." -f $msg, $script:Attempt, ($maxAttempts - 1), $delay)
            Start-Sleep -Seconds $delay
            Send-Prompt $script:LastPrompt
            return
        }
        $script:Running = $false
        if ($script:Provider -eq 'ollama' -and $msg -notmatch 'DNS') { $msg += ' - is the Ollama app running?' }
        Set-Status $msg
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
