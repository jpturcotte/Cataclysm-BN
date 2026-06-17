# Arcopolis Spike 15 regression: ONE backend-driven real query_popup (query_yn) path at level 4.
#
# Proves, against ONE persistent --arcopolis-live backend per scenario, that an `examine` command enters the
# REAL engine ACTION_EXAMINE path, reaches the deployed-furniture take-down query_yn
# (iexamine::deployed_furniture -> query_yn("Take down the %s?"), input_context "YESNO"), exposes its REAL
# YES/NO options to the external client, accepts the client's choice, drives the engine's OWN query_once
# loop with the SAME registered actions a player would press on the horizontal button row (LEFT/CONFIRM),
# and returns a truthful state change -- with no faked options, no direct result mutation, and no hidden
# auto-cancel-as-success. The un-abort is WITNESS-SCOPED (the guard at that one call site only), so no other
# query_yn is driven.
#
# Witness: ArcopolisDeployedFurnitureTest -- a copy of ArcopolisTest with ONE f_floor_mattress placed on the
# CLEAN floor tile one EAST of the avatar (built by docs/arcopolis/make_furniture_fixture.py). `examine
# direction=move_e` targets it. The avatar never moves; the only state change is the furniture take-down.
#
# Gates:
#   Y1 (accept probe): `examine move_e` opens a `prompt` kind="query_popup", title "Take down the mattress?",
#     EXACTLY 2 choices [0]=YES / [1]=NO in order, both enabled, cancelable:false (query_yn has no QUIT).
#   Y2 (LEVEL-4 transcript): answering choice:0 (YES) -> served [LEFT, CONFIRM] through the real
#     input_context("YESNO") loop; transcript prompt_opened (kind=query_popup, the 2 real choices) /
#     prompt_answered (choices [0], actions [LEFT, CONFIRM], kind=query_popup) / prompt_completed
#     (kind=query_popup, actions_served=2); NO prompt_force_cancelled.
#   Y3 (REAL state change, YES): the east tile's furniture was f_floor_mattress before and is gone (f_null)
#     after; a real `mattress` item now lies on that tile; the engine logged "You take down the mattress."
#   N (reject, NO): answering choice:1 (NO) -> served [CONFIRM] (no LEFT; the cursor starts on NO);
#     prompt_completed actions_served=1; the furniture STAYS f_floor_mattress and NO mattress item appears;
#     no take-down message. (Proves YES vs NO discriminate at the state level through the engine's own loop.)
#   R (invalid recovery + non-cancelable cancel): on the open query_popup, an out-of-range choice
#     (prompt_failed invalid_answer), a wrong prompt_id (prompt_failed prompt_id_mismatch), AND a
#     prompt_cancel (REJECTED as non-cancelable -- prompt_failed noncancelable, the query_yn-has-no-cancel
#     distinction) are EACH ok:false with the prompt STILL OPEN; a follow-up valid answer completes the SAME
#     examine. (No invented cancel: prompt_cancel never "succeeds" on a non-cancelable query_yn.)
#   No backend hangs (strict per-response timeout kills + FAILS); every live session quits with exit 0.
#
# AUTOSELECT_SINGLE_VALID_TARGET and AUTO_PICKUP are PINNED false in the sandbox options.json (deployment
# config, never overridden in memory -- docs/arcopolis/25 design point 2): AUTOSELECT=false makes "Examine
# where?" always prompt (so the Spike 11A direction one-shot is served toward the east tile); AUTO_PICKUP=
# false keeps the just-dropped mattress on the ground deterministically (the examine pickup tail auto-cancels
# the "PICKUP" menu via the existing nested-input guard regardless, but pinning stays robust across drift).
#
# Run with `pwsh` (PowerShell 7), NOT `powershell` 5.1 (which misreads BOM-less UTF-8 snapshots / writes an
# options.json BOM -> spurious failures on unchanged code; see the memory note + AGENTS.md fixture section).
#
# Exit codes: 0 = all gates pass; 1 = one or more gates failed; 3..8 = missing prereq.

[CmdletBinding()]
param(
    [string]$Exe         = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc  = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir     = ".\arcopolis_user",
    [string]$World       = "ArcopolisDeployedFurnitureTest",
    [string]$OutRoot     = ".\out\arco_query_popup_regress",
    [string]$Driver      = "docs\arcopolis\prompt_menu_live_driver.py",
    [string]$HarnessDir  = "tools\arcopolis_client",
    [double]$TimeoutSec  = 60
)

$ErrorActionPreference = "Stop"

function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (3=exe, 4=fixture, 5=world, 6=python, 7=driver, 8=harness). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) { Stop-WithCode "Fixture source directory not found: $FixtureSrc" 4 }
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- the query_popup witness needs a copy of ArcopolisTest with one f_floor_mattress placed one tile EAST of the avatar; build it with docs/arcopolis/make_furniture_fixture.py." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the live driver). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Driver) ) { Stop-WithCode "Prompt live driver not found: $Driver" 7 }
if( -not (Test-Path (Join-Path $HarnessDir "harness.py")) ) {
    Stop-WithCode "Client harness not found under: $HarnessDir (the driver imports its LiveSession)" 8
}

# Refresh the gitignored sandbox userdir from the external fixture.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Pin one boolean option in the SANDBOX copy's options.json (deployment config, never an in-memory override).
function Set-SandboxOption {
    param([string]$Name, [bool]$Value)
    $optPath = Join-Path $UserDir "config\options.json"
    $text = Get-Content $optPath -Raw
    $word = if( $Value ) { "true" } else { "false" }
    if( $text -match ('"name": "' + $Name + '", "value": "(true|false)"') ) {
        $patched = $text -replace ('("name": "' + $Name + '", "value": ")(true|false)(")'), "`${1}$word`${3}"
    } else {
        $entry = '{ "name": "' + $Name + '", "value": "' + $word + '" },'
        $patched = ([regex]'\[').Replace($text, ('[' + "`n  " + $entry), 1)
    }
    if( $patched -notmatch ('"name": "' + $Name + '", "value": "' + $word + '"') ) {
        Stop-WithCode "Could not set $Name=$word in the sandbox options.json" 4
    }
    Set-Content -Path $optPath -Value $patched -NoNewline -Encoding utf8
}

function Invoke-LiveScenario {
    param([string]$Name, [string[]]$RequestLines)
    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $reqPath = Join-Path $OutRoot "$Name.requests.jsonl"
    Set-Content -Path $reqPath -Value ($RequestLines -join "`n") -Encoding ascii
    $resultPath = Join-Path $OutRoot "$Name.result.json"
    $stdout = Join-Path $OutRoot "$Name.driver_stdout.txt"
    $stderr = Join-Path $OutRoot "$Name.driver_stderr.txt"
    $p = Start-Process -FilePath "python" -ArgumentList @($Driver, '--exe', $Exe, '--world', $World,
        '--userdir', $UserDir, '--out', $dir, '--requests', $reqPath, '--timeout', $TimeoutSec,
        '--result', $resultPath) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $result = $null
    if( Test-Path $resultPath ) { $result = Get-Content $resultPath -Raw | ConvertFrom-Json }
    return [pscustomobject]@{
        Name = $Name; Dir = $dir; ExitCode = $p.ExitCode; Result = $result
        Stderr = (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
    }
}

function Read-Transcript {
    param([string]$Dir)
    $path = Join-Path $Dir "session.jsonl"
    if( -not (Test-Path $path) ) { return $null }
    return @(Get-Content $path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Read-Snapshot {
    param([string]$Dir, [string]$Name)
    $path = Join-Path $Dir $Name
    if( -not (Test-Path $path) ) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

# Furniture id at one pos_local tile of a snapshot (tiles[] carries furn as the id string, e.g. "f_null").
function Get-FurnAt {
    param($Snapshot, [int[]]$Pos)
    if( -not $Snapshot ) { return $null }
    $tile = @($Snapshot.tiles | Where-Object {
            $_.x -eq $Pos[0] -and $_.y -eq $Pos[1] -and $_.z -eq $Pos[2] })
    if( $tile.Count -ge 1 ) { return $tile[0].furn }
    return $null
}

# Ground items at one pos_local tile of a snapshot (the raw ground stack).
function Get-ItemsAt {
    param($Snapshot, [int[]]$Pos)
    if( -not $Snapshot ) { return @() }
    return @($Snapshot.entities.items | Where-Object {
            $_.pos_local[0] -eq $Pos[0] -and $_.pos_local[1] -eq $Pos[1] -and $_.pos_local[2] -eq $Pos[2]
        })
}

function Get-MessageTexts {
    param($Snapshot)
    if( -not $Snapshot ) { return @() }
    return @($Snapshot.messages | ForEach-Object { $_.text })
}

function Index-ById { param($Responses) $h = @{}; foreach( $r in @($Responses) ) { if( $null -ne $r.id ) { $h[[int]$r.id] = $r } }; return $h }
function Get-PromptsInOrder { param($Responses) return @(@($Responses) | Where-Object { $_.type -eq 'prompt' }) }

$fail = 0
Set-SandboxOption -Name "AUTOSELECT_SINGLE_VALID_TARGET" -Value $false
Set-SandboxOption -Name "AUTO_PICKUP" -Value $false

# =============================================================================
# Scenario Y (accept / YES): examine the mattress east, answer YES, witness the take-down.
#   ids: export1=start, examine2, prompt_answer3 (YES), export4=after, quit5
# =============================================================================
$reqY = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_e","name":"examine_yes"}',
    '{"id":3,"op":"prompt_answer","prompt_id":1,"choice":0}',
    '{"id":4,"op":"export","name":"after"}',
    '{"id":5,"op":"quit"}'
)
$Y = Invoke-LiveScenario -Name "accept_yes" -RequestLines $reqY
$evY = Read-Transcript -Dir $Y.Dir
$respY = Index-ById $Y.Result.responses
$promptsY = Get-PromptsInOrder $Y.Result.responses

# --- Gate Y1: one prompt, kind=query_popup, the 2 real YES/NO choices in order, not cancelable. ---
$pY = if( $promptsY.Count -ge 1 ) { $promptsY[0] } else { $null }
$choicesY = if( $pY ) { @($pY.choices) } else { @() }
$g1 = ($Y.ExitCode -eq 0) -and $Y.Result -and $Y.Result.ok -and $Y.Result.ready_seen -and
      ($promptsY.Count -eq 1) -and $pY -and ($pY.kind -eq 'query_popup') -and ($pY.prompt_id -eq 1) -and
      ($pY.title -like '*Take down*mattress*') -and ($pY.cancelable -eq $false) -and
      ($choicesY.Count -eq 2) -and ($choicesY[0].index -eq 0) -and ($choicesY[0].text -eq 'YES') -and
      ($choicesY[1].index -eq 1) -and ($choicesY[1].text -eq 'NO') -and
      ($choicesY[0].enabled -eq $true) -and ($choicesY[1].enabled -eq $true)
if( $g1 ) {
    Write-Host "  PASS: Y1 -- examine opened ONE prompt kind=query_popup (title '$($pY.title)'), 2 choices [YES, NO] in order, both enabled, cancelable:false." -ForegroundColor Green
} else {
    Write-Host "  FAIL: Y1 -- exit=$($Y.ExitCode) ok=$($Y.Result.ok) prompts=$($promptsY.Count) kind=$($pY.kind) title='$($pY.title)' cancelable=$($pY.cancelable) choices=$(@($choicesY | ForEach-Object { $_.text }) -join ',') stderr: $($Y.Stderr)" -ForegroundColor Red
    $fail++
    if( -not $pY ) { Write-Host "QUERY_POPUP REGRESSION: aborting (no prompt to assert against)." -ForegroundColor Red; exit 1 }
}

# --- Gate Y2 (LEVEL-4 transcript): YES served [LEFT, CONFIRM]; opened/answered/completed kind=query_popup. ---
$openedY = @($evY | Where-Object { $_.event -eq 'prompt_opened' -and $_.kind -eq 'query_popup' })
$answeredY = @($evY | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'query_popup' })
$completedY = @($evY | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'query_popup' })
$forceCancelY = @($evY | Where-Object { $_.event -eq 'prompt_force_cancelled' })
$ansChoicesY = if( $answeredY.Count -ge 1 ) { @($answeredY[0].choices) } else { @() }
$ansActionsY = if( $answeredY.Count -ge 1 ) { @($answeredY[0].actions) } else { @() }
$g2 = ($respY[3].ok -eq $true) -and ($openedY.Count -ge 1) -and ($openedY[0].choices.Count -eq 2) -and
      ($answeredY.Count -ge 1) -and (($ansChoicesY -join ',') -eq '0') -and
      (($ansActionsY -join ',') -eq 'LEFT,CONFIRM') -and
      ($completedY.Count -ge 1) -and ($completedY[0].actions_served -eq 2) -and ($forceCancelY.Count -eq 0)
if( $g2 ) {
    Write-Host "  PASS: Y2 (level-4) -- prompt_opened (2 choices), prompt_answered choices [0] served [$($ansActionsY -join ', ')], prompt_completed kind=query_popup actions_served=2; no force-cancel." -ForegroundColor Green
} else {
    Write-Host "  FAIL: Y2 -- ansOk=$($respY[3].ok) opened=$($openedY.Count) answeredChoices=[$($ansChoicesY -join ', ')] actions=[$($ansActionsY -join ', ')] completedServed=$($completedY[0].actions_served) forceCancel=$($forceCancelY.Count)" -ForegroundColor Red
    $fail++
}

# --- Gate Y3 (REAL state change, YES): the east-tile furniture is gone + a mattress item dropped + message. ---
$snapStartY = Read-Snapshot -Dir $Y.Dir -Name $respY[1].snapshot
$snapAfterY = Read-Snapshot -Dir $Y.Dir -Name $respY[4].snapshot
$eastTile = @(
    ( [int]$snapStartY.avatar.pos_local[0] + 1 ),
    ( [int]$snapStartY.avatar.pos_local[1] ),
    ( [int]$snapStartY.avatar.pos_local[2] )
)
$furnBeforeY = Get-FurnAt -Snapshot $snapStartY -Pos $eastTile
$furnAfterY = Get-FurnAt -Snapshot $snapAfterY -Pos $eastTile
$itemsAfterY = Get-ItemsAt -Snapshot $snapAfterY -Pos $eastTile
$mattressDropped = @($itemsAfterY | Where-Object { $_.type_id -eq 'mattress' -or $_.name -like '*mattress*' }).Count -ge 1
$takeDownMsg = @((Get-MessageTexts $snapAfterY) | Where-Object { $_ -like '*take down*mattress*' })
$g3 = ($furnBeforeY -eq 'f_floor_mattress') -and ($furnAfterY -ne 'f_floor_mattress') -and
      $mattressDropped -and ($takeDownMsg.Count -ge 1)
if( $g3 ) {
    Write-Host "  PASS: Y3 -- east-tile furniture '$furnBeforeY' -> '$furnAfterY' (gone), a mattress item dropped on the tile, engine logged '$($takeDownMsg[0])'." -ForegroundColor Green
} else {
    Write-Host "  FAIL: Y3 -- furnBefore='$furnBeforeY' furnAfter='$furnAfterY' mattressDropped=$mattressDropped takeDownMsg=$($takeDownMsg.Count) itemsAfter=[$(@($itemsAfterY | ForEach-Object { $_.type_id }) -join ', ')]" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario N (reject / NO): examine the mattress east, answer NO, witness NOTHING changes.
#   ids: export1=start, examine2, prompt_answer3 (NO), export4=after, quit5
# =============================================================================
$reqN = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_e","name":"examine_no"}',
    '{"id":3,"op":"prompt_answer","prompt_id":1,"choice":1}',
    '{"id":4,"op":"export","name":"after"}',
    '{"id":5,"op":"quit"}'
)
$N = Invoke-LiveScenario -Name "reject_no" -RequestLines $reqN
$evN = Read-Transcript -Dir $N.Dir
$respN = Index-ById $N.Result.responses
$answeredN = @($evN | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'query_popup' })
$completedN = @($evN | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'query_popup' })
$ansActionsN = if( $answeredN.Count -ge 1 ) { @($answeredN[0].actions) } else { @() }
$snapStartN = Read-Snapshot -Dir $N.Dir -Name $respN[1].snapshot
$snapAfterN = Read-Snapshot -Dir $N.Dir -Name $respN[4].snapshot
$furnAfterN = Get-FurnAt -Snapshot $snapAfterN -Pos $eastTile
$itemsAfterN = Get-ItemsAt -Snapshot $snapAfterN -Pos $eastTile
$mattressN = @($itemsAfterN | Where-Object { $_.type_id -eq 'mattress' -or $_.name -like '*mattress*' }).Count
$takeDownMsgN = @((Get-MessageTexts $snapAfterN) | Where-Object { $_ -like '*take down*mattress*' })
$gN = ($N.ExitCode -eq 0) -and $N.Result.ok -and ($respN[3].ok -eq $true) -and
      ($answeredN.Count -ge 1) -and (($ansActionsN -join ',') -eq 'CONFIRM') -and
      ($completedN.Count -ge 1) -and ($completedN[0].actions_served -eq 1) -and
      ($furnAfterN -eq 'f_floor_mattress') -and ($mattressN -eq 0) -and ($takeDownMsgN.Count -eq 0)
if( $gN ) {
    Write-Host "  PASS: N (reject) -- choice:1 (NO) served [$($ansActionsN -join ', ')] (actions_served=1); furniture STAYS '$furnAfterN', no mattress item, no take-down message." -ForegroundColor Green
} else {
    Write-Host "  FAIL: N -- exit=$($N.ExitCode) ansOk=$($respN[3].ok) actions=[$($ansActionsN -join ', ')] completedServed=$($completedN[0].actions_served) furnAfter='$furnAfterN' mattress=$mattressN takeDownMsg=$($takeDownMsgN.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario R (invalid recovery + non-cancelable cancel): three rejections on the OPEN prompt, then a valid
# answer completes the SAME examine. The prompt_cancel rejection proves query_yn has NO cancel (not invented).
#   ids: export1=start, examine2, (out-of-range)3, (wrong prompt_id)4, (prompt_cancel)5, (valid NO)6, export7, quit8
# =============================================================================
$reqR = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_e","name":"examine_recover"}',
    '{"id":3,"op":"prompt_answer","prompt_id":1,"choice":9}',
    '{"id":4,"op":"prompt_answer","prompt_id":999,"choice":0}',
    '{"id":5,"op":"prompt_cancel","prompt_id":1}',
    '{"id":6,"op":"prompt_answer","prompt_id":1,"choice":1}',
    '{"id":7,"op":"export","name":"after"}',
    '{"id":8,"op":"quit"}'
)
$R = Invoke-LiveScenario -Name "invalid_recovery" -RequestLines $reqR
$evR = Read-Transcript -Dir $R.Dir
$respR = Index-ById $R.Result.responses
$cResR = @($R.Result.responses)
$rejectR = @($cResR | Where-Object { $_.type -eq 'response' -and $_.op -eq 'prompt_answer' -and $_.ok -eq $false })
$failedR = @($evR | Where-Object { $_.event -eq 'prompt_failed' })
$rangeR = @($failedR | Where-Object { $_.reason -eq 'invalid_answer' })
$mismatchR = @($failedR | Where-Object { $_.reason -eq 'prompt_id_mismatch' })
$noncancelR = @($failedR | Where-Object { $_.reason -eq 'noncancelable' })
$cmdOkR = @($cResR | Where-Object { $_.type -eq 'response' -and $_.op -eq 'command' -and $_.id -eq 2 -and $_.ok -eq $true })
$gR = ($R.ExitCode -eq 0) -and $R.Result.ok -and ($rejectR.Count -ge 3) -and
      ($rangeR.Count -ge 1) -and ($mismatchR.Count -ge 1) -and ($noncancelR.Count -ge 1) -and
      ($cmdOkR.Count -ge 1)
if( $gR ) {
    Write-Host "  PASS: R (recovery) -- out-of-range + wrong prompt_id + non-cancelable prompt_cancel each rejected ok:false with the prompt OPEN (prompt_failed: invalid_answer + prompt_id_mismatch + noncancelable), then a valid answer completed the SAME examine ok:true." -ForegroundColor Green
} else {
    Write-Host "  FAIL: R -- exit=$($R.ExitCode) rejects=$($rejectR.Count) range=$($rangeR.Count) mismatch=$($mismatchR.Count) noncancel=$($noncancelR.Count) cmdOk=$($cmdOkR.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario E (EOF / closed client mid-prompt): the client sends NO answer; the driver closes stdin once the
# prompt is open -> EOF mid-prompt. query_yn is NOT cancelable (no QUIT registered), so the backend serves
# CONFIRM (the popup's visible default, NO) to avoid a headless hang, marks it a CLOSED prompt
# (prompt_cancelled noncancelable_closed, NOT prompt_answered), completes the examine, and EXITS CLEAN
# (backend exit_code 0, NOT the nested-input hard-fail exit 12). This permanently pins the refutation of the
# "EOF -> empty-queue read -> guard hard-fail" hypothesis: a CONFIRM that drains the queue also sets
# wait_input=false, so query_once never issues a second blocking read (headless the inner do-while cannot
# repeat -- the served event's type is `error`, not mouse/keyboard).
#   ids: export1=start, examine2  (no answer, no quit -> driver closes stdin -> EOF)
$reqEo = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_e","name":"examine_eof"}'
)
$Eo = Invoke-LiveScenario -Name "eof_closed" -RequestLines $reqEo
$evEo = Read-Transcript -Dir $Eo.Dir
$openedEo = @($evEo | Where-Object { $_.event -eq 'prompt_opened' -and $_.kind -eq 'query_popup' })
$cancelledEo = @($evEo | Where-Object { $_.event -eq 'prompt_cancelled' -and $_.reason -eq 'noncancelable_closed' -and $_.kind -eq 'query_popup' })
$answeredEo = @($evEo | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'query_popup' })
$errEo = @($evEo | Where-Object { $_.event -eq 'error' })
$endEo = @($evEo | Where-Object { $_.event -eq 'session_end' -and $_.status -eq 'ok' })
$gEo = ($Eo.ExitCode -eq 0) -and $Eo.Result -and ($Eo.Result.exit_code -eq 0) -and
       ($openedEo.Count -ge 1) -and ($cancelledEo.Count -ge 1) -and ($answeredEo.Count -eq 0) -and
       ($errEo.Count -eq 0) -and ($endEo.Count -ge 1)
if( $gEo ) {
    Write-Host "  PASS: E (EOF/closed) -- examine opened the query_popup, the client closed stdin without answering; the backend served the visible default and EXITED CLEAN (backend exit_code 0, NOT hard-fail 12); transcript prompt_cancelled noncancelable_closed (NOT prompt_answered), no error event, session_end ok." -ForegroundColor Green
} else {
    Write-Host "  FAIL: E (EOF/closed) -- driverExit=$($Eo.ExitCode) backendExit=$($Eo.Result.exit_code) opened=$($openedEo.Count) cancelled=$($cancelledEo.Count) answered=$($answeredEo.Count) errors=$($errEo.Count) endOk=$($endEo.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
Write-Host ""
if( $fail -eq 0 ) {
    Write-Host "QUERY_POPUP REGRESSION: ALL GATES PASS." -ForegroundColor Green
    exit 0
} else {
    Write-Host "QUERY_POPUP REGRESSION: $fail gate(s) FAILED." -ForegroundColor Red
    exit 1
}
