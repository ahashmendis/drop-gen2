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
        provider    = 'opencode_go'
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
function Ensure-OllamaRamGB {
    if ($null -eq $script:RamGB) {
        $script:RamGB = 8
        try {
            $b = [int64]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory)
            $script:RamGB = [int](($b + 536870912) / 1GB)   # round to nearest GiB
        } catch { }
    }
}
function Get-OllamaContextTarget([int]$manual) {
    if ($manual -gt 0) { return [Math]::Min($manual, 65536) }
    Ensure-OllamaRamGB
    if ($script:RamGB -lt 16) { return 8192 }     # 8 GB class -> 8192
    if ($script:RamGB -lt 32) { return 16384 }    # 16 GB      -> 8192-16384
    if ($script:RamGB -lt 64) { return 16384 }    # 32 GB      -> 16384-32768 (conservative low)
    return 32768                                  # 64 GB+     -> 32768-65536 (conservative low)
}
function Get-OllamaManualContext {
    if ($null -eq $script:Config.ollama.context) { return 0 }
    try { return [int]$script:Config.ollama.context } catch { return 0 }
}
# Automatic context ceiling (final policy): when no manual context is set,
# never allocate more than a conservative share of RAM. A manual override is
# exempt (the 65536 hard cap still applies).
# ---- shared, UI-free pipeline code (prompts, fixers, javac, HOW TO TEST, ACD, benchmark) ----
. (Join-Path $PSScriptRoot 'DropCore.ps1')


function Get-OllamaContextCeiling([int]$manual) {
    if ($manual -gt 0) { return 65536 }
    Ensure-OllamaRamGB
    if ($script:RamGB -lt 16) { return 16384 }  # 8 GB class -> 16384 (full papers need >8192)
    if ($script:RamGB -lt 32) { return 16384 }
    return 65536
}
# Final automatic context for one request: growth + floor + hard cap + ceiling
# clamp. Never grows past the ceiling on its own - an oversized prompt is
# blocked (never truncated) with a pointer to the manual Qwen ctx setting.
function Get-OllamaFinalContext([string]$prompt) {
    $manual = Get-OllamaManualContext
    $need = [int]($prompt.Length / 3) + 8000
    $ctx = 8192
    while ($ctx -lt $need -and $ctx -lt 65536) { $ctx *= 2 }
    $target = Get-OllamaContextTarget $manual
    if ($ctx -lt $target) { $ctx = $target }
    if ($ctx -gt 65536) { $ctx = 65536 }
    $ceil = Get-OllamaContextCeiling $manual
    if ($ctx -gt $ceil) { $ctx = $ceil }
    return $ctx
}


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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int c);
    public event EventHandler HotKey;
    public int LastHotKeyId;   // WM_HOTKEY id, read by the PowerShell dispatcher
    public DropNative() { CreateHandle(new CreateParams()); }
    public static bool IsIntelliJForeground() {
        var fg = GetForegroundWindow();
        int pid; GetWindowThreadProcessId(fg, out pid);
        try {
            var p = System.Diagnostics.Process.GetProcessById(pid);
            var n = p.ProcessName.ToLowerInvariant();
            if (n.StartsWith("idea")) { return true; }   // idea / idea64 (any version)
        } catch { }
        // Title fallback (macOS checks the localized name too): IntelliJ
        // windows carry "IntelliJ" in the title bar even when renamed/packaged.
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(fg, sb, sb.Capacity);
        return sb.ToString().Contains("IntelliJ");
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

# ---- model choice (provider-aware: no localhost:11434 traffic when OpenCode selected) ----
# Qwen-family discovery from GET /api/tags: model metadata first
# (details.family / details.families), falling back to the model name.
# All installed Qwen variants are offered - never a single hardcoded model.
$script:QwenModels    = @()
$script:MissingSaved  = $null
$script:ModelCombo    = $null
# Model metadata for the dropdown: entries are @{Name=<plain name>; Label=<name · size · quant>}.
# $script:QwenModels and $script:Model always hold plain names.
$script:QwenModelDetails = @()

function Sync-ModelCombo {
    $c = $script:ModelCombo
    if ($null -eq $c) { return }
    $c.Items.Clear()
    foreach ($d in $script:QwenModelDetails) { [void]$c.Items.Add($d.Label) }
    if ($script:Model) {
        $i = -1
        for ($k = 0; $k -lt $script:QwenModelDetails.Count; $k++) {
            if ($script:QwenModelDetails[$k].Name -eq $script:Model) { $i = $k; break }
        }
        if ($i -ge 0) { $c.SelectedIndex = $i }
        elseif ($c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    } elseif ($c.Items.Count -gt 0) {
        $c.SelectedIndex = 0
    }
}

# ---- Ollama on-demand lifecycle (quiet laptop): start only when needed -----
# $true when the local Ollama API answers GET /api/tags within $TimeoutSec.
function Test-OllamaApi([int]$TimeoutSec) {
    try {
        $null = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec $TimeoutSec
        return $true
    } catch { return $false }
}

# Resolve the official Ollama install (Start Menu shortcut first, then the
# known install dirs). The bare CLI server ('serve') is a last resort only.
function Start-OllamaApp {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ollama.lnk'
    if (Test-Path -LiteralPath $lnk) {
        try { Start-Process -FilePath $lnk; return $true } catch { }
    }
    foreach ($exe in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\ollama app.exe'))) {
        if (Test-Path -LiteralPath $exe) {
            try { Start-Process -FilePath $exe; return $true } catch { }
        }
    }
    $cli = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (-not (Test-Path -LiteralPath $cli)) {
        $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($cmd) { $cli = $cmd.Source }
    }
    if (Test-Path -LiteralPath $cli) {
        try { Start-Process -FilePath $cli -ArgumentList 'serve'; return $true } catch { }
    }
    return $false
}

# Best-effort one-time CPU demotion of the local Ollama server(s).
# Flag set only when at least one process was actually demoted.
$script:OllamaDemoted = $false
function Set-OllamaLowPriority {
    if ($script:OllamaDemoted) { return }
    try {
        $procs = @(Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue)
        foreach ($p in $procs) { try { $p.PriorityClass = 'BelowNormal' } catch { } }
        if ($procs.Count -gt 0) { $script:OllamaDemoted = $true }
    } catch { }
}

# On-demand start: probe first; when unreachable and asked to start, launch the
# official Ollama app and poll within the connect-timeout budget. Env knobs are
# set on the start path only (best-effort). The server is NEVER killed -
# keep_alive 0 lets it unload models between requests instead.
function Prepare-Ollama([bool]$StartIfNeeded) {
    if ($OllamaUrl -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])') { return $true }  # remote: not ours to manage
    if (Test-OllamaApi 1) {
        Set-OllamaLowPriority
        return $true
    }
    if (-not $StartIfNeeded) { return $false }
    Set-Status 'Starting Ollama...'
    $env:OLLAMA_NUM_PARALLEL = '1'
    $env:OLLAMA_MAX_LOADED_MODELS = '1'
    if (-not (Start-OllamaApp)) { return $false }
    Start-Sleep -Milliseconds 300
    $deadline = (Get-Date).AddSeconds([double]$script:Config.network.connect_timeout)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaApi 1) {
            Set-OllamaLowPriority
            Set-Status 'Ollama ready'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Returns $true when Ollama is reachable (started first when asked). Never
# selects a model that does not exist: the saved selection is used only if it
# is still installed. The combo shows labels (name · size · quant);
# $script:QwenModels / $script:Model always hold plain names.
function Update-OllamaModels([bool]$StartIfNeeded = $false) {
    if (-not (Prepare-Ollama -StartIfNeeded $StartIfNeeded)) { return $false }
    try {
        $script:QwenModelDetails = @()
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 3
        foreach ($m in $tags.models) {
            $n = [string]$m.name
            if ([string]::IsNullOrEmpty($n) -or $n -match 'cloud') { continue }
            $fam = @()
            if ($null -ne $m.details) {
                if ($m.details.family)   { $fam += [string]$m.details.family }
                if ($m.details.families) { $fam += @($m.details.families) }
            }
            if ((($fam -join ' ') -match 'qwen') -or ($n -match 'qwen')) {
                $label = $n
                if ($m.details.parameter_size)     { $label += ' · ' + [string]$m.details.parameter_size }
                if ($m.details.quantization_level) { $label += ' · ' + [string]$m.details.quantization_level }
                $script:QwenModelDetails += @{ Name = $n; Label = $label }
            }
        }
        $script:QwenModelDetails = @($script:QwenModelDetails | Sort-Object { $_.Name })
        $script:QwenModels = @($script:QwenModelDetails | ForEach-Object { [string]$_.Name })
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
        $script:QwenModelDetails = @()
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
$W = 240; $CompactH = 112; $AnswerH = 240   # 112 = drop + model dropdown + subject row + buttons
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

function New-SmallButton([string]$text, [int]$x, [int]$w, [int]$y = 88) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 64)
    $b.ForeColor = $fg
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 7)
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 18)
    $b.TabStop = $false
    return $b
}
$btnCopy  = New-SmallButton 'Copy'  ($W - 152) 50
$btnShare = New-SmallButton 'Share' ($W - 98)  56
$btnHide  = New-SmallButton 'x'     ($W - 38)  30
$btnProv  = New-SmallButton 'Ollama' 8 74
# Subject row (OOP / ACD toggle + Run folder) and the Copy part row of the expanded pane.
$btnOop = New-SmallButton 'OOP' 8 50 66
$btnAcd = New-SmallButton 'ACD' 60 50 66
$btnRun = New-SmallButton '> Run folder' 112 120 66
$txtPart = New-Object System.Windows.Forms.TextBox
$txtPart.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$txtPart.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$txtPart.ForeColor = $fg
$txtPart.BorderStyle = 'FixedSingle'
$txtPart.Location = New-Object System.Drawing.Point(8, 112)
$txtPart.Size = New-Object System.Drawing.Size(150, 20)
$txtPart.Visible = $false
$btnPart = New-SmallButton 'Copy part' 162 70 112
$btnPart.Height = 20
$btnPart.Visible = $false
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
    # The dropdown shows labels; the saved value is the plain model name.
    $name = $sel
    foreach ($d in $script:QwenModelDetails) { if ($d.Label -eq $sel) { $name = [string]$d.Name; break } }
    if ($script:Model -ne $name) {
        # Remember the selected model locally (config file, user-only access).
        $script:Model = $name
        $script:Config.ollama | Add-Member -NotePropertyName default_model -NotePropertyValue $name -Force
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
$box.Location = New-Object System.Drawing.Point(8, 136)
$box.Size = New-Object System.Drawing.Size(($W - 16), ($AnswerH - 32))
$box.Visible = $false

$form.Controls.AddRange(@($drop, $cmbModel, $btnProv, $btnOop, $btnAcd, $btnRun, $btnCopy, $btnShare, $btnHide, $txtPart, $btnPart, $box))

function Set-Status([string]$s) { $status.Text = $s }
# Terminal feedback that must reach the user even when the popup is hidden
# (the hotkey runs are headless): status line when visible, tray balloon when
# not. Never used for per-chunk streaming progress - outcomes only.
function Show-Notice([string]$msg) {
    Set-Status $msg
    if (-not $form.Visible) {
        try { $tray.ShowBalloonTip(5000, 'Drop', $msg, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}
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
        if (Update-OllamaModels $true) {
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
                if (-not (Prepare-Ollama -StartIfNeeded $true)) { $lblS.Text = 'Ollama could not be started'; return }
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
            [void](Update-OllamaModels $true)
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
    if (-not (Test-DropHotkeyGate)) { Show-Notice 'Ctrl+Alt+R ignored - front window must be IntelliJ or Drop'; return }
    if ($script:Running) { Show-Notice 'Busy - wait for the current result'; return }
    $oop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OOP'
    if (-not (Test-Path -LiteralPath $oop -PathType Container)) {
        Show-Notice 'OOP folder not found on Desktop'; return
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
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Show-Notice 'No answer yet'; return }
    [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
    Show-Notice 'Copied - paste with Ctrl+V'
}

# Ctrl+Alt+1..0: copy just Task N's section of the last answer.
function Copy-TaskAnswer([int]$n) {
    if (-not (Test-DropHotkeyGate)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastAnswer)) { Show-Notice 'No answer yet'; return }
    $s = Get-TaskSection $script:LastAnswer $n
    if ($null -eq $s) { Show-Notice "Task $n not found in answer"; return }
    [System.Windows.Forms.Clipboard]::SetText($s)
    Show-Notice "Task $n copied - paste with Ctrl+V"
}

# Hotkeys: id 1 = Ctrl+Alt+D (global), 2 = R (OOP run), 3 = C (copy-all,
# Task 4), 4..13 = 1..9,0 (task copy, Task 4). Dispatch by WndProc-recorded id.
$mods = (0x0001 -bor 0x0002 -bor 0x4000)   # Ctrl + Alt + no-repeat
# Registration can fail when another app owns a combo - collect instead of
# discarding, and tell the user after the tray exists (never fail silently).
$hotkeyFails = @()
if (-not [DropNative]::RegisterHotKey($native.Handle, 1, $mods, 0x44)) { $hotkeyFails += 'Ctrl+Alt+D' }   # D
$vkMap = [ordered]@{ 2 = 0x52; 3 = 0x43; 4 = 0x31; 5 = 0x32; 6 = 0x33; 7 = 0x34
                     8 = 0x35; 9 = 0x36; 10 = 0x37; 11 = 0x38; 12 = 0x39; 13 = 0x30 }
foreach ($id in $vkMap.Keys) {
    if (-not [DropNative]::RegisterHotKey($native.Handle, $id, $mods, $vkMap[$id])) {
        $hotkeyFails += ('Ctrl+Alt+' + [char]$vkMap[$id])
    }
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
if ($hotkeyFails.Count -gt 0) {
    Show-Notice ('Drop hotkeys already used by another app: ' + ($hotkeyFails -join ', ') + ' - those keys will not work')
}
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / Hide', $null, { Toggle-Popup })
[void]$menu.Items.Add('Copy last result', $null, { Copy-Again })
[void]$menu.Items.Add('-')
$miCareful = New-Object System.Windows.Forms.ToolStripMenuItem('ACD careful mode (thinking, slower)')
$miCareful.CheckOnClick = $true
$miCareful.Checked = (Get-DropCareful)
$miCareful.Add_Click({
    Set-DropSetting 'acdCareful' ([bool]$miCareful.Checked)
    Set-Status $(if ($miCareful.Checked) { 'Careful mode on (thinking, slower)' } else { 'Fast mode (default): no thinking' })
})
[void]$menu.Items.Add($miCareful)
$miPerTask = New-Object System.Windows.Forms.ToolStripMenuItem('OOP per-task generation (experimental)')
$miPerTask.CheckOnClick = $true
$miPerTask.Checked = (Get-DropOopPerTask)
$miPerTask.Add_Click({
    Set-DropSetting 'oopPerTask' ([bool]$miPerTask.Checked)
    Set-Status $(if ($miPerTask.Checked) { 'OOP per-task generation on (experimental)' } else { 'OOP popup run: single request (default)' })
})
[void]$menu.Items.Add($miPerTask)
[void]$menu.Items.Add('Prepare ACD toolchain...', $null, { Start-PrepareToolchain })
[void]$menu.Items.Add('Benchmark...', $null, { Show-DropBenchmark })
[void]$menu.Items.Add('-')
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
# Ollama generate gets its own client: a truncation retry can legitimately run
# past 20 minutes (16384 tokens at ~8.7 tok/s ≈ 31 min). OpenCode keeps $client.
$ollamaClient = New-Object System.Net.Http.HttpClient
$ollamaClient.Timeout = [TimeSpan]::FromMinutes(45)

function Copy-Again {
    if ($script:LastAnswer) { [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer); Set-Status 'Copied again - paste with Ctrl+V' }
}

# ---- subjects: OOP / ACD toggle, background jobs, part copy, toolchain, benchmark (DropOop/DropAcd/DropBench.ps1) -------
$script:Subject = Get-DropSubject          # its own settings.json key; never touches config.json, the provider or the model
$script:LastAnswerACD = ''
$script:Job = $null

function Get-SubjectFolder([string]$s) { return (Join-Path ([Environment]::GetFolderPath('Desktop')) $(if ($s -eq 'acd') { 'ACD' } else { 'OOP' })) }
function Update-SubjectUi {
    $on = [System.Drawing.Color]::FromArgb(0, 110, 130)
    $off = [System.Drawing.Color]::FromArgb(55, 55, 64)
    if ($script:Subject -eq 'acd') { $btnAcd.BackColor = $on; $btnOop.BackColor = $off } else { $btnOop.BackColor = [System.Drawing.Color]::FromArgb(60, 80, 170); $btnAcd.BackColor = $off }
    if (-not $script:Running -and -not $script:Job) {
        $label = if ($script:Subject -eq 'acd') { 'ACD' } else { 'OOP' }
        Set-Status ("$label - reads Desktop\$label")
    }
}
function Set-Subject([string]$s) {
    $script:Subject = $s
    Set-DropSubject $s
    Update-SubjectUi
    # a running run keeps streaming into the view untouched; otherwise show the selected subject's answer
    if (-not $script:Running -and -not $script:Job) { $box.Text = $(if ($s -eq 'acd') { $script:LastAnswerACD } else { $script:LastAnswer }) }
}
function Get-CurrentAnswer { if ($script:Subject -eq 'acd') { return $script:LastAnswerACD } else { return $script:LastAnswer } }

# Popup entry point for dropped files, the file picker and Run folder. The OOP hotkeys never come through here:
# Start-OopRun calls Start-Answer directly, so they stay OOP whatever the toggle says.
function Start-SubjectRun([string[]]$paths) {
    if ($script:Subject -eq 'acd') { Start-AcdRun $paths }
    else { Start-Answer $paths ((Get-DropOopPerTask) -and $script:Provider -eq 'ollama') }
}
function Start-SubjectFolder {
    if ($script:Running -or $script:Job) { Show-Notice 'Busy - wait for the current result'; return }
    $dir = Get-SubjectFolder $script:Subject
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Show-Notice ("{0} folder not found on Desktop" -f $(if ($script:Subject -eq 'acd') { 'ACD' } else { 'OOP' })); return }
    Start-SubjectRun @($dir)
}

# OOP on Ollama: background runspace (never blocks the UI thread). $noThink = fallback after an empty thinking reply.
function Start-DropOopJob($paper, $starter, $n, [bool]$perTask, [bool]$noThink) {
    if (-not (Prepare-Ollama -StartIfNeeded $true)) { $script:Running = $false; Set-Status 'Ollama not running and could not be started'; return }
    $script:Paper = $paper; $script:Files = $n; $script:StarterFiles = $starter
    $box.Text = ''
    $script:Running = $true
    $careful = (Get-DropCareful) -and -not $noThink
    $p = @{ Paper = $paper; Starter = $starter; Model = $script:Model; Base = $OllamaUrl; ManualCtx = (Get-OllamaManualContext); PerTask = $perTask; Careful = $careful; RamBytes = (Get-DropRamBytes) }
    $script:Job = Start-DropJob 'oop' $p
    Show-Notice "Read $n file(s) - writing..."
}

function Start-AcdRun([string[]]$paths) {
    if ($script:Running -or $script:Job) { Show-Notice 'Busy - wait for the current result'; return }
    if ($script:Provider -eq 'ollama') {
        if ([string]::IsNullOrWhiteSpace($script:Model)) { Show-Notice 'No Qwen model installed - ollama pull a Qwen model first'; return }
        if (-not (Prepare-Ollama -StartIfNeeded $true)) { Set-Status 'Ollama not running and could not be started'; return }
    } elseif ([string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)) { Show-Notice 'No OpenCode API key - open Settings (tray)'; return }
    # Everything the run needs is captured NOW; toggling the subject afterwards cannot change any of it.
    $oc = @{ BaseUrl = [string]$script:Config.opencode_go.base_url; ApiKey = [string]$script:Config.opencode_go.api_key; Model = [string]$script:Config.opencode_go.model; SessionId = [guid]::NewGuid().ToString() }
    $p = @{ Paths = $paths; Provider = $script:Provider; Model = $script:Model; Base = $OllamaUrl; ManualCtx = (Get-OllamaManualContext); RamBytes = (Get-DropRamBytes); Careful = (Get-DropCareful); OpenCode = $oc }
    $box.Text = ''
    $script:RunSubject = 'acd'
    $script:Running = $true            # hotkeys / provider switch stay blocked while the run is in flight (macOS parity)
    $script:Job = Start-DropJob 'acd' $p
    Set-Status 'ACD - reading the paper...'
}

function Complete-DropJob($j) {
    $r = Receive-DropJob $j
    if ($j.Kind -eq 'toolchain') {
        if ($r.Ok) { Show-Notice 'ACD toolchain ready' }
        else {
            Show-Notice 'Toolchain install failed'
            $o = [string]$r.Output; if ($o.Length -gt 800) { $o = $o.Substring($o.Length - 800) }
            [void][System.Windows.Forms.MessageBox]::Show($o, 'Toolchain install failed', 'OK', 'Warning')
        }
        return
    }
    $script:Running = $false
    if ($j.Kind -eq 'oop') {
        if (-not $r.Ok) { Show-Notice ('No answer produced - ' + $r.Error); return }
        $answer = ([string]$r.Answer).Trim()
        $script:LastAnswer = $answer
        if ($script:Subject -eq 'oop') { $box.Text = $answer }
        [System.Windows.Forms.Clipboard]::SetText($answer)
        [System.Media.SystemSounds]::Asterisk.Play()
        if ($r.Compiled -eq $true) { Show-Notice 'Done! Copied - compiles' }
        elseif ($r.Compiled -eq $false) { Show-Notice 'Done! Copied - but still has compile errors - check IntelliJ' }
        elseif (-not $script:StarterFiles -or $script:StarterFiles.Count -eq 0) { Show-Notice 'Done! Copied (no starter to compile-check)' }
        else { Show-Notice 'Done! Copied (no JDK/Spring found to compile-check)' }
        return
    }
    if ($j.Kind -eq 'acd') {
        if (-not $r.Ok) { Show-Notice ('ACD: ' + $r.Error); return }
        $res = $r.Result
        $script:LastAnswerACD = $res.Answer                       # the ACD slot - never the OOP one the hotkeys copy
        $summary = Get-AcdValidationSummary $res.Validation
        $missing = ''
        if (@($res.Unanswered).Count -gt 0) { $missing = "`r`nUNANSWERED: " + (@($res.Unanswered) -join ', ') + $(if ($r.LastError) { ' (' + $r.LastError + ')' } else { '' }) }
        if ($script:Subject -eq 'acd') {
            $box.Text = ("-- Validation --`r`n" + $summary + $(if ($res.RepairNote) { "`r`n" + $res.RepairNote } else { '' }) + $missing + "`r`n`r`n" + $res.Answer).Replace("`r`n", "`n").Replace("`n", "`r`n")
        }
        [System.Windows.Forms.Clipboard]::SetText([string]$res.Answer)
        [System.Media.SystemSounds]::Asterisk.Play()
        $bad = (Get-AcdFailureCount $res.Validation)
        $nUn = @($res.Unanswered).Count
        $head = if ($bad -eq 0 -and $nUn -eq 0) { 'ACD answer copied' } else { "ACD answer copied, $($bad + $nUn) problem(s)" }
        Show-Notice ($head + ' - ' + $summary + $(if ($nUn -gt 0) { ' - unanswered ' + (@($res.Unanswered) -join ',') } else { '' }) + $(if ($res.RepairNote) { ' - ' + $res.RepairNote } else { '' }))
    }
}

# Copy a part of the selected subject's answer: "2" = Task 2, "A1" = question A1, "Events.tsx" = that file.
function Copy-Part {
    $key = $txtPart.Text.Trim()
    $label = if ($script:Subject -eq 'acd') { 'ACD' } else { 'OOP' }
    $answer = Get-CurrentAnswer
    if ([string]::IsNullOrWhiteSpace($answer)) { Set-Status "No $label answer yet"; return }
    if ($key -eq '') { Set-Status 'Type a task number, question id or file name'; return }
    $slice = $null
    if ($script:Subject -eq 'acd') { $slice = Get-AcdPart (ConvertFrom-AcdText $answer) $key }
    else { $n = 0; if ([int]::TryParse($key, [ref]$n)) { $slice = Get-TaskSection $answer $n } }
    if ($null -eq $slice) { Set-Status ('"{0}" not found in the {1} answer' -f $key, $label); return }
    [System.Windows.Forms.Clipboard]::SetText($slice)
    Set-Status ("{0} copied - paste with Ctrl+V" -f $key)
}

# Optional, explicitly user-triggered: nothing is ever installed automatically.
function Start-PrepareToolchain {
    if ($script:Running -or $script:Job) { Show-Notice 'Busy - wait for the current result'; return }
    $pj = Find-AcdPackageJson
    if (-not $pj) {
        [void][System.Windows.Forms.MessageBox]::Show("Put the course starter project (with its package.json) in Desktop\ACD first; its dependencies define the toolchain.", 'No starter project found', 'OK', 'Information')
        return
    }
    $dest = Join-Path (Get-DropAcdDir) 'toolchain'
    $r = [System.Windows.Forms.MessageBox]::Show("This runs npm to download the dependencies listed in`n$pj`ninto $dest. It needs internet and may take a few minutes. Nothing is installed unless you click Yes.", 'Prepare ACD toolchain?', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Set-Status 'Installing ACD toolchain...'
    $script:Job = Start-DropJob 'toolchain' @{ PackageJson = $pj }
}


# One targeted repair round (mac parity): errors + implicated sources only,
# never the full question and previous answer. $true = repair dispatched.
function Start-DropRepairRound([string]$answer, [string]$errs) {
    if ($script:RepairRounds -ge 4) { return $false }
    $script:RepairRounds++
    $script:RepairBase = $answer
    $cap = [string]$errs
    if ($cap.Length -gt 6000) { $cap = $cap.Substring(0, 6000) }
    $n = ([regex]::Matches($errs, 'error:')).Count
    $prompt = $OllamaRepairHeader + "`n`n######## JAVAC ERRORS ########`n" + $cap + "`n`n######## AFFECTED FILES ########`n" + (Get-DropRepairContext $answer $errs)
    $script:Phase = 3
    Set-Status ("Fixing {0} compile error(s)..." -f $n)
    Send-Prompt $prompt
    return $true
}

# Ollama pipeline entry: deterministic fixers first, then compile + repair rounds.
function Start-DropOllamaPipeline([string]$answer) {
    $answer = Remove-DropFences $answer
    $answer = Invoke-DropStaticFixes $answer
    $script:RepairRounds = 0
    Set-Status 'Compiling...'
    $errs = Get-DropCompileErrors $answer
    if ($null -eq $errs) { Complete-DropAnswer $answer $null; return }    # cannot check
    if ($errs -eq '') { Complete-DropAnswer $answer $true; return }        # compiles
    if (Start-DropRepairRound $answer $errs) { return }                    # repair in flight
    Complete-DropAnswer $answer $false                                     # rounds exhausted
}

# Repair response arrived: merge what changed, fix, recompile, loop (mac parity,
# including the no-op stop when the model changed nothing usable).
function Complete-DropPhase3([string]$answer) {
    $fixes = Remove-DropFences $answer
    $merged = Merge-DropFixes $script:RepairBase $fixes
    if ($merged -eq $script:RepairBase) {
        Complete-DropAnswer $script:RepairBase $false
        return
    }
    $answer = Invoke-DropStaticFixes $merged
    Set-Status 'Compiling...'
    $errs = Get-DropCompileErrors $answer
    if ($null -eq $errs) { Complete-DropAnswer $answer $null; return }
    if ($errs -eq '') { Complete-DropAnswer $answer $true; return }
    if (Start-DropRepairRound $answer $errs) { return }
    Complete-DropAnswer $answer $false
}

# Finalize: HOW TO TEST block, clipboard, honest compile-state notice (mac parity).
function Complete-DropAnswer([string]$answer, $compiled) {
    $answer = Add-DropHowToTest $answer
    $script:Running = $false
    $answer = $answer.Trim()
    $script:LastAnswer = $answer
    $box.Text = $answer
    [System.Windows.Forms.Clipboard]::SetText($answer)
    [System.Media.SystemSounds]::Asterisk.Play()
    if ($compiled -eq $true) {
        Show-Notice 'Done! Copied - compiles'
    } elseif ($compiled -eq $false) {
        Show-Notice 'Done! Copied - but still has compile errors - check IntelliJ'
    } elseif (-not $script:StarterFiles -or $script:StarterFiles.Count -eq 0) {
        Show-Notice 'Done! Copied (no starter to compile-check)'
    } else {
        Show-Notice 'Done! Copied (no JDK/Spring found to compile-check)'
    }
}


function Start-Answer([string[]]$paths, [bool]$perTask = $false) {
    if ($script:Running) { Show-Notice 'Busy - wait for the current result'; return }
    $res = Collect-Input $paths
    $paper = $res[0]; $n = $res[1]
    $script:StarterFiles = $res[2]
    if (($paper -split '\s+').Count -lt 15) {
        if ($n -eq 0) {
            # Windows has no built-in PDF text extraction (macOS uses PDFKit):
            # point at the one dependency instead of failing invisibly.
            Show-Notice 'No readable files - PDF papers need pdftotext (install Poppler: winget install oschwartz10612.Poppler)'
        } else { Show-Notice 'No readable text found' }
        return
    }
    if ($script:Provider -eq 'ollama' -and [string]::IsNullOrWhiteSpace($script:Model)) {
        # Never send a request for a model that does not exist.
        Show-Notice 'No Qwen model installed - ollama pull a Qwen model first'
        return
    }
    # Ollama default (every OOP run, hotkeys included): ONE request WITHOUT thinking through the small-context, memory-aware
    # session on a background runspace (DropOop.ps1). Careful mode (tray) keeps the original thinking request below, and
    # OpenCode Go is untouched. perTask (tray, experimental) writes the answer task by task instead.
    if ($script:Provider -eq 'ollama' -and ($perTask -or -not (Get-DropCareful))) {
        Start-DropOopJob $paper $res[2] $n $perTask $false
        return
    }
    $script:Paper = $paper
    $script:Files = $n
    $script:Phase = 1
    $script:Attempt = 0
    $script:SessionId = [guid]::NewGuid().ToString()   # new conversation → new session id
    $box.Text = ''
    $script:Running = $true
    # Prompt fork: Ollama gets the student-level rules (silent checks); OpenCode
    # keeps its pinned $PromptHeader byte-for-byte.
    $hdr = $PromptHeader
    if ($script:Provider -eq 'ollama') { $hdr = $OllamaPromptHeader }
    Send-Prompt ($hdr + "`n`n" + $paper)
    Show-Notice "Read $n file(s) - thinking..."
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
    # Ollama path (stream:false, keep_alive 0, num_ctx). Final context =
    # growth + floor + hard cap + automatic ceiling. On the automatic path a
    # request whose prompt alone exceeds the ceiling is blocked (never
    # truncated) and pointed at Settings.
    $ctx = Get-OllamaFinalContext $prompt
    if ((Get-OllamaManualContext) -le 0 -and [int]($prompt.Length / 3) -gt $ctx) {
        Set-Status "Prompt too large for automatic context ceiling ($ctx tokens) - raise Qwen ctx in Settings (large contexts use more memory)"
        $script:Running = $false
        return
    }
    if (-not (Prepare-Ollama -StartIfNeeded $true)) {
        Set-Status 'Ollama not running and could not be started'
        $script:Running = $false
        return
    }
    # think = $true matches the backup branch (no think key sent there; qwen3
    # defaults to thinking) - that reasoning keeps the code faithful to the
    # paper's spec. Ollama returns it in its own "thinking" field; the parser
    # reads .response only, so the answer stays pure code. Thinking tokens
    # share the context window; a cut answer is completed by the compile-
    # repair pipeline. Ignored by models without a thinking mode. Ollama
    # request only. num_predict = task-scaled output cap (4096-8192) so one
    # request can never grind for hours; the compile-repair pipeline
    # completes anything it cuts.
    $body = @{ model = $script:Model; prompt = $prompt; stream = $false; think = $true; keep_alive = 0; options = @{ num_ctx = $ctx; temperature = 0.2; num_predict = (Get-OllamaNumPredict $script:Paper) } } | ConvertTo-Json -Depth 5 -Compress
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    $script:Task = $ollamaClient.PostAsync("$OllamaUrl/api/generate", $content)
}

$script:DoubleCheck = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:Job) {
        $j = $script:Job
        if (-not (Test-DropJobDone $j)) {
            $secs = [int]([DateTime]::UtcNow - $j.Started).TotalSeconds
            if ($j.Kind -eq 'toolchain') { Set-Status ("Installing ACD toolchain... {0}s" -f $secs) }
            else { Set-Status ("{0} {1}s" -f $j.Sync.Status, $secs) }
            return
        }
        $script:Job = $null
        Complete-DropJob $j
        return
    }
    if (-not $script:Running -or $null -eq $script:Task) { return }
    if (-not $script:Task.IsCompleted) {
        $secs = [int]((Get-Date) - $script:Started).TotalSeconds
        if ($script:Phase -eq 1) { $label = 'thinking' } elseif ($script:Phase -eq 3) { $label = 'fixing compile errors' } else { $label = 'double-checking' }
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
            # Ollama context rejections: point at the manual Qwen ctx setting.
            if ($script:Provider -eq 'ollama' -and $text -match 'context') {
                $msg += ' - raise Qwen ctx in Settings'
            }
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
            # Cut-answer guard (Ollama only): a cut answer is NEVER discarded
            # and never regenerated from scratch - it falls through to the
            # javac compile-repair pipeline below, which completes it (fixers +
            # up to 4 repair rounds) and copies the honest result. Only an
            # empty answer is a failure.
            if ($script:Provider -eq 'ollama' -and (Test-OllamaTruncated $obj)) {
                if ([string]::IsNullOrWhiteSpace($answer)) {
                    # The model spent its whole token budget THINKING and wrote nothing: retry once without thinking through the
                    # small-context session (macOS parity); only when that cannot be done is it reported as a failure.
                    if ($script:Phase -eq 1 -and (Get-Command Start-DropOopJob -ErrorAction SilentlyContinue)) {
                        Set-Status 'The model used its token budget thinking - retrying without thinking...'
                        Start-DropOopJob $script:Paper $script:StarterFiles $script:Files $false $true
                        return
                    }
                    $script:Running = $false
                    Show-Notice 'Context limit reached - no answer produced - raise Qwen ctx in Settings'
                    return
                }
                Set-Status 'Answer cut short by the context - completing via compile repair...'
            }
        }
        $script:Attempt = 0
        if ($script:Phase -eq 1 -and $script:DoubleCheck) {
            $script:Draft = $answer
            $script:Phase = 2
            $rulesHdr = $PromptHeader
            $revHdr = $ReviewHeader
            if ($script:Provider -eq 'ollama') { $rulesHdr = $OllamaPromptHeader; $revHdr = $OllamaReviewHeader }
            Send-Prompt ($revHdr + "`n`n######## RULES ########`n" + $rulesHdr + "`n`n" + $script:Paper + "`n`n######## DRAFT SOLUTION ########`n" + $answer)
            return
        }
        if ($script:Phase -eq 2 -and $answer.Length -lt ($script:Draft.Length / 3)) { $answer = $script:Draft }
        if ($script:Provider -eq 'ollama') {
            # Ollama-only pipeline: deterministic fixers + javac repair rounds +
            # deterministic HOW TO TEST. OpenCode keeps the plain finalize below.
            if ($script:Phase -eq 3) { Complete-DropPhase3 $answer } else { Start-DropOllamaPipeline $answer }
            return
        }
        $script:Running = $false
        $answer = ($answer -split "`n" | Where-Object { -not $_.TrimStart().StartsWith('```') }) -join "`r`n"
        $answer = $answer.Trim()
        $script:LastAnswer = $answer
        $box.Text = $answer
        [System.Windows.Forms.Clipboard]::SetText($answer)
        [System.Media.SystemSounds]::Asterisk.Play()
        Show-Notice 'Done! Copied - paste with Ctrl+V'
    } catch {
        if ($script:Phase -eq 2 -and $script:Draft) {
            $script:Running = $false
            $script:LastAnswer = $script:Draft.Trim(); $box.Text = $script:LastAnswer
            [System.Windows.Forms.Clipboard]::SetText($script:LastAnswer)
            Show-Notice 'Check failed - draft copied (Ctrl+V)'
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

# ---- Benchmark window (tray menu: Benchmark...) --------------------------------------------------------------------
# Runs the SAME pipelines over fixed tasks and several models on a background runspace and records results.jsonl
# (%APPDATA%\Drop\bench\results). It never touches the popup's answer slots, the clipboard, config.json or the saved
# model/provider, and never falls back to another provider. Stop takes effect between runs.
function Show-DropBenchmark {
    if ($script:Running -or $script:Job) { Show-Notice 'Busy - finish the current run before starting the benchmark'; return }
    try { Copy-DropBenchSampleTasks (Join-Path $PSScriptRoot 'bench-tasks') } catch { }
    $tasks = @(Get-DropBenchTasks)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Drop Benchmark'
    $dlg.Size = New-Object System.Drawing.Size(780, 640)
    $dlg.StartPosition = 'CenterScreen'
    $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = 'Tasks (folders in the bench tasks folder)'; $lblT.Location = New-Object System.Drawing.Point(12, 10); $lblT.AutoSize = $true
    $lstT = New-Object System.Windows.Forms.CheckedListBox; $lstT.Location = New-Object System.Drawing.Point(12, 30); $lstT.Size = New-Object System.Drawing.Size(360, 130); $lstT.CheckOnClick = $true
    foreach ($t in $tasks) { [void]$lstT.Items.Add(("{0} [{1}] - {2}" -f $t.Id, $t.Subject, $t.Title), $true) }
    $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = 'Models'; $lblM.Location = New-Object System.Drawing.Point(390, 10); $lblM.AutoSize = $true
    $lstM = New-Object System.Windows.Forms.CheckedListBox; $lstM.Location = New-Object System.Drawing.Point(390, 30); $lstM.Size = New-Object System.Drawing.Size(360, 130); $lstM.CheckOnClick = $true
    $modelRefs = New-Object System.Collections.Generic.List[object]
    if (Prepare-Ollama -StartIfNeeded $false) {
        foreach ($n in (Get-DropBenchOllamaModels $OllamaUrl)) { $modelRefs.Add(@{ Provider = 'ollama'; Name = $n }); [void]$lstM.Items.Add("ollama: $n") }
    } else { [void]$lstM.Items.Add('(Ollama is not running - start it, then reopen this window)') }
    if (-not [string]::IsNullOrWhiteSpace($script:Config.opencode_go.api_key)) {
        $modelRefs.Add(@{ Provider = 'opencode_go'; Name = [string]$script:Config.opencode_go.model })
        [void]$lstM.Items.Add("opencode_go: $($script:Config.opencode_go.model) (cloud)")
    }
    for ($i = 0; $i -lt $modelRefs.Count; $i++) { if ($modelRefs[$i].Provider -eq 'ollama' -and $modelRefs[$i].Name -eq $script:Model) { $lstM.SetItemChecked($i, $true) } }
    $chkPer = New-Object System.Windows.Forms.CheckBox; $chkPer.Text = 'OOP: one request per task (Ollama, experimental)'; $chkPer.Location = New-Object System.Drawing.Point(12, 170); $chkPer.AutoSize = $true
    $chkPer.Checked = (Get-DropOopPerTask)
    $chkCare = New-Object System.Windows.Forms.CheckBox; $chkCare.Text = 'Careful mode (thinking, slower)'; $chkCare.Location = New-Object System.Drawing.Point(390, 170); $chkCare.AutoSize = $true
    $chkCare.Checked = (Get-DropCareful)
    $lblMode = New-Object System.Windows.Forms.Label; $lblMode.Text = 'OOP request:'; $lblMode.Location = New-Object System.Drawing.Point(12, 198); $lblMode.AutoSize = $true
    $cmbMode = New-Object System.Windows.Forms.ComboBox; $cmbMode.DropDownStyle = 'DropDownList'; $cmbMode.Location = New-Object System.Drawing.Point(100, 195); $cmbMode.Size = New-Object System.Drawing.Size(270, 24)
    [void]$cmbMode.Items.AddRange(@('auto (same as the app)', 'original (thinking request)', 'nothink (force no thinking)')); $cmbMode.SelectedIndex = 0
    $btnRunB = New-Object System.Windows.Forms.Button; $btnRunB.Text = 'Run'; $btnRunB.Location = New-Object System.Drawing.Point(12, 228); $btnRunB.Size = New-Object System.Drawing.Size(90, 28)
    $btnStopB = New-Object System.Windows.Forms.Button; $btnStopB.Text = 'Stop'; $btnStopB.Location = New-Object System.Drawing.Point(110, 228); $btnStopB.Size = New-Object System.Drawing.Size(90, 28); $btnStopB.Enabled = $false
    $btnRep = New-Object System.Windows.Forms.Button; $btnRep.Text = 'Open report'; $btnRep.Location = New-Object System.Drawing.Point(208, 228); $btnRep.Size = New-Object System.Drawing.Size(110, 28)
    $btnDir = New-Object System.Windows.Forms.Button; $btnDir.Text = 'Open folder'; $btnDir.Location = New-Object System.Drawing.Point(326, 228); $btnDir.Size = New-Object System.Drawing.Size(110, 28)
    $logB = New-Object System.Windows.Forms.TextBox; $logB.Multiline = $true; $logB.ReadOnly = $true; $logB.ScrollBars = 'Vertical'; $logB.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $logB.Location = New-Object System.Drawing.Point(12, 266); $logB.Size = New-Object System.Drawing.Size(738, 330)
    $dlg.Controls.AddRange(@($lblT, $lstT, $lblM, $lstM, $chkPer, $chkCare, $lblMode, $cmbMode, $btnRunB, $btnStopB, $btnRep, $btnDir, $logB))
    $state = @{ Job = $null; Shown = 0 }
    $bt = New-Object System.Windows.Forms.Timer; $bt.Interval = 700
    $bt.Add_Tick({
        $j = $state.Job
        if ($null -eq $j) { return }
        $lines = $j.Sync.Log
        if ($lines.Count -gt $state.Shown) {
            $new = @($lines.ToArray())[$state.Shown..($lines.Count - 1)]
            $state.Shown = $lines.Count
            $logB.AppendText((($new -join "`r`n") + "`r`n"))
        }
        if (Test-DropJobDone $j) {
            [void](Receive-DropJob $j)
            $state.Job = $null; $btnRunB.Enabled = $true; $btnStopB.Enabled = $false
            $logB.AppendText("`r`n(done)`r`n")
        }
    })
    $bt.Start()
    $btnRunB.Add_Click({
        $selT = @(); for ($i = 0; $i -lt $tasks.Count; $i++) { if ($lstT.GetItemChecked($i)) { $selT += $tasks[$i].Id } }
        $selM = @(); for ($i = 0; $i -lt $modelRefs.Count; $i++) { if ($lstM.GetItemChecked($i)) { $selM += $modelRefs[$i] } }
        if ($selT.Count -eq 0 -or $selM.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Select at least one task and one model.', 'Drop Benchmark'); return }
        if ($script:Running -or $script:Job) { [void][System.Windows.Forms.MessageBox]::Show('A normal run is in progress - wait for it first.', 'Drop Benchmark'); return }
        Set-DropSetting 'acdCareful' ([bool]$chkCare.Checked)
        $mode = @('auto', 'original', 'nothink')[[Math]::Max(0, $cmbMode.SelectedIndex)]
        $oc = @{ BaseUrl = [string]$script:Config.opencode_go.base_url; ApiKey = [string]$script:Config.opencode_go.api_key }
        $p = @{ RunId = ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')); Base = $OllamaUrl; ManualCtx = (Get-OllamaManualContext); RamBytes = (Get-DropRamBytes)
                OopPerTask = [bool]$chkPer.Checked; OopMode = $mode; Careful = [bool]$chkCare.Checked; OpenCode = $oc; TaskIds = $selT; Models = $selM }
        $logB.Text = ''
        $state.Shown = 0
        $state.Job = Start-DropJob 'bench' $p
        $btnRunB.Enabled = $false; $btnStopB.Enabled = $true
    })
    $btnStopB.Add_Click({ if ($state.Job) { $state.Job.Sync.Cancel = $true; $logB.AppendText("Stopping after the current run...`r`n") } })
    $btnRep.Add_Click({ try { $rp = Write-DropBenchReport; Start-Process $rp } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Drop Benchmark') } })
    $btnDir.Add_Click({ try { Initialize-DropBenchDirs; Start-Process (Get-DropBenchDir) } catch { } })
    $dlg.Add_FormClosing({
        if ($state.Job) {
            $a = [System.Windows.Forms.MessageBox]::Show('A benchmark is running. Stop it and close?', 'Drop Benchmark', 'YesNo', 'Question')
            if ($a -ne 'Yes') { $_.Cancel = $true; return }
            Stop-DropJob $state.Job
        }
        $bt.Stop()
    })
    [void]$dlg.ShowDialog()
}

# ---- events ------------------------------------------------------------------
$onEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy'; $drop.BackColor = $hi }
}
$onLeave = { $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52) }
$onDrop = {
    $drop.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
    $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($paths) { Start-SubjectRun $paths }
}
foreach ($c in @($form, $drop, $title, $status)) {
    $c.Add_DragEnter($onEnter); $c.Add_DragLeave($onLeave); $c.Add_DragDrop($onDrop)
}
$pick = {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Choose files'
    if ($dlg.ShowDialog($form) -eq 'OK') { Start-SubjectRun $dlg.FileNames }
}
foreach ($c in @($drop, $title, $status)) { $c.Add_Click($pick) }

$btnCopy.Add_Click({ Copy-Again })
$btnHide.Add_Click({ $form.Hide() })
$btnShare.Add_Click({
    $box.Visible = -not $box.Visible
    $txtPart.Visible = $box.Visible; $btnPart.Visible = $box.Visible
    if ($box.Visible) { $form.Height = $CompactH + $AnswerH } else { $form.Height = $CompactH }
    Set-Rounded
})
$btnOop.Add_Click({ Set-Subject 'oop' })
$btnAcd.Add_Click({ Set-Subject 'acd' })
$btnRun.Add_Click({ Start-SubjectFolder })
$btnPart.Add_Click({ Copy-Part })
$txtPart.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Copy-Part } })
Update-SubjectUi

try { Copy-DropAcdNotes (Join-Path $PSScriptRoot 'acd-notes'); Copy-DropBenchSampleTasks (Join-Path $PSScriptRoot 'bench-tasks') } catch { }
Set-Rounded
$form.Show()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$mutex.ReleaseMutex()
