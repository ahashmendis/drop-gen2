# DropAcdRun.ps1 - the ACD pipeline (plan -> one small request per question -> fixers -> validate -> bounded repair),
# the background-runspace entry points for ACD, and a blocking OpenCode Go request used ONLY by ACD and the benchmark.
# Dot-sourced by DropCore.ps1. Definitions only. The app's own OpenCode request code in Drop.ps1 is not touched.

function Get-AcdStarterBlock($starter, [int]$limit = 7000) {
    $out = ''; $omitted = @()
    foreach ($k in (Get-DropSortedKeys $starter.Keys)) {
        $piece = "===== FILE: $k =====`n" + $starter[$k] + "`n"
        if (($out.Length + $piece.Length) -gt $limit) { $omitted += $k; continue }
        $out += $piece
    }
    if ($omitted.Count -gt 0) { $out += '(not shown: ' + ($omitted -join ', ') + ")`n" }
    return $out
}

# Input: @{ TaskText; PaperBlock; Starter; Chunks; Careful; CeilingTokens; QuestionCount }
# Hooks: @{ Generate = {param($req)} -> text/$null; Validate = {param($files)} -> validation; Status = {param($s)} }
# -> @{ Answer; Validation; RepairRounds; GenerationMs; ValidationMs; RepairNote; Mode; UnitCount; Unanswered; NotesUsed; UnitMs } or $null
function Invoke-AcdPipeline($in, $hooks) {
    $nowMs = { [int64]([DateTime]::UtcNow.Ticks / 10000) }
    $maxRepairs = 3
    $genMs = 0; $valMs = 0
    $plan = New-AcdPlan $in.TaskText
    $answerText = ''
    $owners = @{}
    $unanswered = New-Object System.Collections.Generic.List[string]
    $notesUsed = New-Object System.Collections.Generic.List[string]
    $unitMs = @{}
    $mode = if (@($plan.Units).Count -ge 2) { 'units' } else { 'whole' }
    $starterText = Get-AcdStarterBlock $in.Starter
    $units = @($plan.Units)
    if ($mode -eq 'units') {
        $texts = @{}
        for ($i = 0; $i -lt $units.Count; $i++) {
            $u = $units[$i]
            & $hooks.Status "ACD $($i + 1)/$($units.Count) $($u.Id)"
            $t0 = & $nowMs
            if ($u.Kind -ne 'free') {
                $tf = ($u.Kind -eq 'tf')
                $reply = & $hooks.Generate (New-DropRequest (Get-AcdObjectivePrompt $u) $u.Id 'objective' 24 0 $false)
                $v = $null
                if ($null -ne $reply) { $v = Get-AcdObjectiveFromReply $reply $u.Id $tf }
                if ($null -eq $v) {          # one stricter retry for an unreadable reply
                    $r2 = & $hooks.Generate (New-DropRequest (Get-AcdObjectivePrompt $u $true) "$($u.Id) retry" 'objective' 16 0 $false)
                    if ($null -ne $r2) { $v = Get-AcdObjectiveFromReply $r2 $u.Id $tf }
                }
                if ($null -ne $v) { $texts[$u.Id] = $v } else { $unanswered.Add($u.Id) }
            } else {
                $base = [Math]::Min(3000, 500 + 180 * [Math]::Max([int]$u.Marks, 3))
                $budget = [int][Math]::Floor((Get-AcdNotesBudget ([int]$in.CeilingTokens) ($u.Text.Length + $starterText.Length + 1800 + $base * 3)) / 6)   # small, targeted
                $notes = Select-AcdNotes $u.Text $in.Chunks ([Math]::Min(1500, $budget))
                foreach ($x in $notes.Used) { $notesUsed.Add($x) }
                $prompt = Get-AcdFreePrompt $u $plan.Preamble $notes.Text $starterText
                $np = if ($in.Careful) { [Math]::Min(6000, $base * 2 + 1500) } else { $base }
                $reply = & $hooks.Generate (New-DropRequest $prompt $u.Id 'free' $np 0.2 ([bool]$in.Careful))
                if ([string]::IsNullOrWhiteSpace($reply) -and $in.Careful) {   # thinking ate the budget: answer without it
                    $reply = & $hooks.Generate (New-DropRequest $prompt "$($u.Id) (no thinking)" 'free' $base 0.2 $false)
                }
                if (-not [string]::IsNullOrWhiteSpace($reply)) {
                    $r = Invoke-AcdFixers $reply $u.Text      # deterministic slips: names, hosts, strict-TS catch, abort, layout
                    $texts[$u.Id] = $r
                    foreach ($p in (Get-AcdFiles (ConvertFrom-AcdText $r)).Keys) { $owners[[string]$p] = $u.Id }
                } else { $unanswered.Add($u.Id) }
            }
            $el = (& $nowMs) - $t0
            $unitMs[$u.Id] = $el
            $genMs += $el
        }
        if ($texts.Count -eq 0) { return $null }
        $out = New-Object System.Collections.Generic.List[string]
        $lastTask = -1
        foreach ($u in $units) {
            if (-not $texts.ContainsKey($u.Id)) { continue }
            if ($u.Task -ne $lastTask) { $out.Add("// ===== Task $($u.Task) ====="); $lastTask = $u.Task }
            $out.Add("// ===== Q $($u.Id) =====`n" + ([string]$texts[$u.Id]).Trim())
        }
        $answerText = ($out -join "`n")
    } else {
        # no recognisable questions: one request for the whole task (small notes, no thinking unless Careful mode)
        & $hooks.Status 'ACD writing the answer...'
        $sizing = [Math]::Min(6000, [Math]::Max(2500, 1200 + 400 * [int]$in.QuestionCount))
        $budget = Get-AcdNotesBudget ([int]$in.CeilingTokens) ($script:AcdPromptHeader.Length + $in.PaperBlock.Length + $sizing * 3)
        $notes = Select-AcdNotes $in.TaskText $in.Chunks ([Math]::Min($budget, 4500))
        foreach ($x in $notes.Used) { $notesUsed.Add($x) }
        $t0 = & $nowMs
        $np = if ($in.Careful) { $sizing * 2 } else { $sizing }
        $first = & $hooks.Generate (New-DropRequest (Get-AcdWholePrompt $notes.Text $in.PaperBlock) 'Writing' 'whole' $np 0.2 ([bool]$in.Careful))
        if ($null -eq $first) { return $null }
        $genMs += (& $nowMs) - $t0
        $answerText = $first
    }
    $current = ConvertFrom-AcdText $answerText
    & $hooks.Status 'Validating...'
    $t0 = & $nowMs
    $val = & $hooks.Validate (Get-AcdFiles $current)
    $valMs += (& $nowMs) - $t0
    $best = @{ Doc = $current; Val = $val }
    $rounds = 0
    $note = ''
    while ((Get-AcdFailureCount $best.Val) -gt 0 -and $rounds -lt $maxRepairs -and (Get-AcdFiles $best.Doc).Count -gt 0) {
        $rounds++
        $files = Get-AcdFiles $best.Doc
        $errors = Get-AcdErrorText $best.Val
        $affected = @()
        foreach ($k in @($files.Keys)) { if ($errors.Contains([string]$k) -or $errors.Contains([System.IO.Path]::GetFileName([string]$k))) { $affected += [string]$k } }
        # the ORIGINAL requirements stay in the prompt: the questions that own the failing files (or the whole task)
        $ownerIds = @{}
        foreach ($a in $affected) { if ($owners.ContainsKey($a)) { $ownerIds[$owners[$a]] = $true } }
        $requirements = $in.PaperBlock
        if ($mode -eq 'units' -and $ownerIds.Count -gt 0) {
            $requirements = $(if ($plan.Preamble) { $plan.Preamble + "`n`n" } else { '' }) + ((@($units | Where-Object { $ownerIds.ContainsKey($_.Id) } | ForEach-Object { $_.Text })) -join "`n`n")
            if ($starterText) { $requirements += "`n`nSTARTER PROJECT FILES`n" + $starterText }
        }
        $prompt = Get-AcdRepairPrompt $requirements $files $errors $affected
        $t0 = & $nowMs
        $nfail = Get-AcdFailureCount $best.Val
        $fixesText = & $hooks.Generate (New-DropRequest $prompt "Fixing $nfail problem(s)" 'repair' 3000 0.2 $false)
        $genMs += (& $nowMs) - $t0
        if ($null -eq $fixesText) { $note = 'repair request failed - best answer kept'; break }
        $merged = Merge-AcdDoc $best.Doc (ConvertFrom-AcdText $fixesText)
        if ((Format-AcdDoc $merged) -eq (Format-AcdDoc $best.Doc)) { $note = 'repair changed nothing - best answer kept'; break }
        & $hooks.Status 'Validating...'
        $t0 = & $nowMs
        $v2 = & $hooks.Validate (Get-AcdFiles $merged)
        $valMs += (& $nowMs) - $t0
        $f2 = Get-AcdFailureCount $v2
        $fb = Get-AcdFailureCount $best.Val
        if ($f2 -lt $fb -or ($f2 -eq $fb -and $f2 -eq 0)) { $best = @{ Doc = $merged; Val = $v2 } }
        else { $note = "repair round $rounds did not improve ($f2 vs $fb problems) - best earlier answer kept"; break }
    }
    if ((Get-AcdFailureCount $best.Val) -gt 0 -and $note -eq '') { $note = "problems remain after $rounds repair round(s)" }
    return @{ Answer = (Format-AcdDoc $best.Doc); Validation = $best.Val; RepairRounds = $rounds; GenerationMs = $genMs; ValidationMs = $valMs; RepairNote = $note
              Mode = $mode; UnitCount = $units.Count; Unanswered = $unanswered.ToArray(); NotesUsed = $notesUsed.ToArray(); UnitMs = $unitMs }
}

# ---- blocking OpenCode Go request (ACD + benchmark only; same request shape as Drop.ps1 Send-Prompt) ------------------
# $cfg = @{ BaseUrl; ApiKey; Model; SessionId }. Transient errors (408/429/5xx, transport) are retried up to 3 times with
# backoff; there is NO fallback to another provider. -> @{ Text; Error }
function Invoke-DropOpenCodeRequest($cfg, [string]$prompt) {
    if ([string]::IsNullOrWhiteSpace($cfg.ApiKey)) { return @{ Text = ''; Error = 'No OpenCode API key - open Settings from the tray' } }
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(20)
    $base = ([string]$cfg.BaseUrl).TrimEnd('/')
    $json = @{ model = $cfg.Model; messages = @(@{ role = 'user'; content = $prompt }); stream = $false } | ConvertTo-Json -Depth 5 -Compress
    $last = ''
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$base/chat/completions")
            $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $cfg.ApiKey)
            [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'Drop/1.0')
            [void]$req.Headers.TryAddWithoutValidation('x-opencode-session', [string]$cfg.SessionId)
            $req.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
            $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $st = [int]$resp.StatusCode
            if ($resp.IsSuccessStatusCode) {
                $o = $txt | ConvertFrom-Json
                $a = ''
                if ($o.choices -and $o.choices.Count -gt 0) { $a = [string]$o.choices[0].message.content }
                if ([string]::IsNullOrWhiteSpace($a)) { return @{ Text = ''; Error = 'OpenCode error: empty response' } }
                return @{ Text = $a; Error = $null }
            }
            $last = Format-DropHttpError $st $txt
            if (-not ($st -eq 408 -or $st -eq 429 -or ($st -ge 500 -and $st -le 599))) { return @{ Text = ''; Error = $last } }
        } catch {
            $last = 'Network error: ' + $_.Exception.Message
        }
        if ($attempt -lt 2) { Start-Sleep -Seconds ([Math]::Pow(2, $attempt)) }
    }
    return @{ Text = ''; Error = $last }
}

# ---- ACD run for the background runspace (handleACD's Task block) -----------------------------------------------------------
# P: Paths, Provider ('ollama' | 'opencode_go'), Model, Base, ManualCtx, RamBytes, Careful, OpenCode (@{BaseUrl;ApiKey;Model;SessionId})
# -> @{ Ok; Error; Result; Unanswered; LastError; FileCount }
function Invoke-DropAcdRun($P, $Sync) {
    $r = @{ Ok = $false; Error = ''; Result = $null; LastError = ''; FileCount = 0 }
    $session = $null
    try {
        $input2 = Get-AcdInputMany @($P.Paths)
        $r.FileCount = $input2.FileCount
        $words = @($input2.TaskOnly -split '\s+' | Where-Object { $_ -ne '' }).Count
        if ($words -lt 15 -and $input2.Starter.Count -eq 0) {
            $r.Error = $(if ($input2.FileCount -eq 0) { 'Nothing readable found for ACD' } else { 'No readable task text (scanned PDF? PDF papers need pdftotext)' })
            return $r
        }
        $isOllama = ($P.Provider -eq 'ollama')
        $manual = [int]$P.ManualCtx
        $ram = [int64]$P.RamBytes; if ($ram -le 0) { $ram = Get-DropRamBytes }
        $ceiling = if ($isOllama) { if ($manual -gt 0) { [Math]::Min($manual, 65536) } else { Get-DropCtxCeiling 0 $ram } } else { 32768 }
        $chunks = Get-AcdNoteChunks @((Get-AcdNotesInstalledDir), (Get-AcdNotesDesktopDir))
        $Sync.Status = "ACD read $($input2.FileCount) file(s) - planning..."
        $script:LastGenError = ''
        if ($isOllama) {
            $session = New-DropSession $P.Base $P.Model $manual $ram
            $session.OnProgress = { param($label) $Sync.Status = ('ACD ' + $label) }
            $generate = {
                param($req)
                $res = Invoke-DropSessionGenerate $session $req
                if ($res.Error) { $script:LastGenError = "$($req.Label): $($res.Error)"; $Sync.Status = '! ' + $script:LastGenError; if ([string]::IsNullOrEmpty($res.Text)) { return $null } }
                return $res.Text
            }
        } else {
            $generate = {
                param($req)
                $Sync.Status = 'ACD ' + $req.Label
                $res = Invoke-DropOpenCodeRequest $P.OpenCode $req.Prompt
                if ($res.Error) { $script:LastGenError = "$($req.Label): $($res.Error)"; $Sync.Status = '! ' + $script:LastGenError; return $null }
                return $res.Text
            }
        }
        $starter = $input2.Starter; $root = $input2.ProjectRoot
        $hooks = @{ Generate = $generate
                    Validate = { param($files) return (Invoke-AcdValidate $files $starter $root) }
                    Status = { param($s) $Sync.Status = [string]$s } }
        $runIn = @{ TaskText = $input2.TaskOnly; PaperBlock = $input2.Paper; Starter = $starter; Chunks = $chunks; Careful = [bool]$P.Careful; CeilingTokens = $ceiling; QuestionCount = $input2.QuestionCount }
        $res2 = Invoke-AcdPipeline $runIn $hooks
        $r.LastError = $script:LastGenError
        if ($null -eq $res2) { $r.Error = 'no answer produced' + $(if ($script:LastGenError) { ' - ' + $script:LastGenError } else { '' }); return $r }
        $r.Ok = $true; $r.Result = $res2
    } catch {
        $r.Error = [string]$_.Exception.Message
    } finally {
        if ($session) { Close-DropSession $session }        # quiet laptop: nothing stays loaded
    }
    return $r
}
