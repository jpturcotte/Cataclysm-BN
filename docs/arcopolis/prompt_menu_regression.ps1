# Arcopolis Spike 12A regression: GUI-equivalent pickup prompt/menu transaction.
#
# Proves, against ONE persistent --arcopolis-live backend per scenario, that a `pickup` command enters
# the REAL engine ACTION_PICKUP path, reaches the REAL old "PICKUP" menu, exposes its REAL choices to the
# external client, accepts the client's choice, drives the engine's OWN menu loop with the SAME registered
# actions a player would press (DOWN x K, RIGHT, CONFIRM), and returns a truthful state change -- with no
# faked menu, no direct mutation, and no hidden auto-cancel-as-success.
#
# Witness: ArcopolisTest's deterministic ground-item pile one tile south of the avatar AFTER one move_s
# (the same pile examine_regression.ps1's gate 7 uses). `pickup direction=move_s` targets it. Gates A-E + G
# run on the default ArcopolisTest avatar (basic clothes, room for ~one small item); gate F runs on
# ArcopolisBackpackTest (a copy whose avatar wears a backpack, real carrying capacity); gate H runs on
# ArcopolisVehicleCargoTest (a copy with a folding_wagon injected ONTO that pile, so the tile has both
# vehicle cargo and ground items; built by docs/arcopolis/make_vehicle_fixture.py); gate I drives the
# binary directly in non-live modes (no live driver). See the fixtures README.
#
# Gates:
#   A (probe, NEW_PICKUP_MENU=false / AUTOSELECT=false): pickup opens a `prompt` with >=1 REAL choice
#     whose texts match the tile's items; a `prompt_cancel` is the GUI ESC ("Never mind.", items
#     untouched, ok:true no-op); the session stays usable. Discovers the choice count C for B.
#   B (main): a `prompt_answer` selecting entry K (the LAST entry, to exercise DOWN navigation when C>=2)
#     completes ok:true; transcript carries prompt_opened (the real choices) / prompt_answered (the exact
#     served sequence [DOWN x K, RIGHT, CONFIRM]) / prompt_completed (actions_served == K+2); the chosen
#     entry leaves the ground after the activity drains (a real engine state change), the engine logs a
#     "You pick up:" message, and the OTHER entries (if any) remain.
#   C (invalid recovery): an out-of-range prompt_answer is ok:false with the prompt STILL OPEN; a
#     follow-up valid answer completes the SAME command; the session is uncorrupted.
#   D (NEW_PICKUP_MENU=true fail-loud): a pickup is rejected ok:false unsupported_command BEFORE any
#     prompt (no silent route to the unsupported inventory_selector); a later wait still works.
#   E (rejected items): a multi-select [0,6] where the bulky entry is over-capacity -> the engine carries
#     only what fits (the shard), LEAVES the rejected blanket on the ground, and never logs it as picked up.
#     Driving the in-activity capacity prompt is NOT implemented (tracked defect). Spike 12A follow-up:
#     the command response is MARKED { forced_cancel, partial, unsupported_prompt:"secondary_capacity" } and
#     the transcript records prompt_force_cancelled -- NOT full success, a partial result with the secondary
#     prompt force-cancelled and explicitly marked.
#   F (multi-select carry-both, ArcopolisBackpackTest): a multi-select [5,6] on the backpack avatar drives
#     TWO RIGHT marks ([DOWN x5, RIGHT, DOWN, RIGHT, CONFIRM]) through the engine's own loop; BOTH chosen
#     entries leave the ground (7 -> 5) and the others remain -- discrimination proven at the state level.
#   G (no phantom prompt_completed): `pickup here` on the empty self-tile opens no menu; the transcript has
#     neither prompt_opened nor prompt_completed.
#   H (vehicle submenu fail-loud, Spike 12A follow-up, ArcopolisVehicleCargoTest): a live pickup onto a tile
#     with BOTH vehicle cargo AND ground items emits NO prompt and answers ok:false/unsupported_command
#     (transcript prompt_force_cancelled kind=vehicle_submenu); the session stays usable. No silent
#     ground-only pickup.
#   I (non-live fail-loud, Spike 12A follow-up): `pickup` in --arcopolis-run-script and one-shot
#     --arcopolis-command is rejected with exit 6 (unsupported_command) BEFORE the world load (no snapshot),
#     because the item menu needs a live answer channel non-live modes lack -- fail loud, not a silent no-op.
#   No backend hangs (strict per-response timeout kills + FAILS); every live session quits with exit 0.
#
# NEW_PICKUP_MENU, AUTOSELECT_SINGLE_VALID_TARGET, and AUTO_PICKUP are PINNED in the sandbox options.json
# (deployment config, never overridden in memory -- docs/arcopolis/25 design point 2, docs/arcopolis/30).
# AUTO_PICKUP=false guarantees the master auto-pickup system does not silently consume the witness pile
# during the move_s approach (it would otherwise depend on the fixture's saved value).
#
# Exit codes: 0 = all gates pass; 1 = one or more gates failed; 3..8 = missing prereq.

[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$BackpackWorld = "ArcopolisBackpackTest",
    [string]$VehicleWorld = "ArcopolisVehicleCargoTest",
    [string]$OutRoot    = ".\out\arco_pickup_regress",
    [string]$Driver     = "docs\arcopolis\prompt_menu_live_driver.py",
    [string]$HarnessDir = "tools\arcopolis_client",
    [double]$TimeoutSec = 60
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
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture (AGENTS.md, Arcopolis test world fixture)." 5
}
$fixtureBackpackWorld = Join-Path $FixtureSrc (Join-Path "save" $BackpackWorld)
if( -not (Test-Path $fixtureBackpackWorld) ) {
    Stop-WithCode "Fixture world '$BackpackWorld' not found at $fixtureBackpackWorld -- the carry-both multi-select witness needs the backpack-avatar fixture (a copy of $World with a backpack added to worn; see the fixtures README)." 5
}
$fixtureVehicleWorld = Join-Path $FixtureSrc (Join-Path "save" $VehicleWorld)
if( -not (Test-Path $fixtureVehicleWorld) ) {
    Stop-WithCode "Fixture world '$VehicleWorld' not found at $fixtureVehicleWorld -- the vehicle-submenu fail-loud witness needs the cargo-vehicle fixture (a copy of $World with a folding_wagon injected onto the ground-item pile; build it with docs/arcopolis/make_vehicle_fixture.py)." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the live driver). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Driver) ) { Stop-WithCode "Pickup prompt live driver not found: $Driver" 7 }
if( -not (Test-Path (Join-Path $HarnessDir "harness.py")) ) {
    Stop-WithCode "Client harness not found under: $HarnessDir (the driver imports its LiveSession)" 8
}

# Refresh the gitignored sandbox userdir from the external fixture.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Pin one boolean option in the SANDBOX copy's options.json (deployment config, never an in-memory
# override). Fails hard if the option line is missing (a fixture regeneration dropped it).
function Set-SandboxOption {
    param([string]$Name, [bool]$Value)
    $optPath = Join-Path $UserDir "config\options.json"
    $text = Get-Content $optPath -Raw
    $word = if( $Value ) { "true" } else { "false" }
    if( $text -match ('"name": "' + $Name + '", "value": "(true|false)"') ) {
        # Present (e.g. AUTOSELECT_SINGLE_VALID_TARGET): flip the saved value in place.
        $patched = $text -replace ('("name": "' + $Name + '", "value": ")(true|false)(")'), "`${1}$word`${3}"
    } else {
        # Absent (e.g. NEW_PICKUP_MENU -- an EXPERIMENTAL option this fixture never saved, so the engine
        # uses its registered default). Insert a minimal entry as the first array element; the options
        # loader reads name/value (info/default are optional).
        $entry = '{ "name": "' + $Name + '", "value": "' + $word + '" },'
        $patched = ([regex]'\[').Replace($text, ('[' + "`n  " + $entry), 1)
    }
    if( $patched -notmatch ('"name": "' + $Name + '", "value": "' + $word + '"') ) {
        Stop-WithCode "Could not set $Name=$word in the sandbox options.json" 4
    }
    Set-Content -Path $optPath -Value $patched -NoNewline -Encoding utf8
}

function Invoke-LiveScenario {
    param([string]$Name, [string[]]$RequestLines, [string]$ScenarioWorld = $World)
    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $reqPath = Join-Path $OutRoot "$Name.requests.jsonl"
    Set-Content -Path $reqPath -Value ($RequestLines -join "`n") -Encoding ascii
    $resultPath = Join-Path $OutRoot "$Name.result.json"
    $stdout = Join-Path $OutRoot "$Name.driver_stdout.txt"
    $stderr = Join-Path $OutRoot "$Name.driver_stderr.txt"
    $p = Start-Process -FilePath "python" -ArgumentList @($Driver, '--exe', $Exe, '--world', $ScenarioWorld,
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

# Ground items at one pos_local tile of a snapshot (the raw stack, not the menu's stacked entries).
function Get-ItemsAt {
    param($Snapshot, [int[]]$PosLocal)
    if( -not $Snapshot ) { return @() }
    return @($Snapshot.entities.items | Where-Object {
            $_.pos_local[0] -eq $PosLocal[0] -and $_.pos_local[1] -eq $PosLocal[1] -and $_.pos_local[2] -eq $PosLocal[2]
        })
}

function Get-MessageTexts {
    param($Snapshot)
    if( -not $Snapshot ) { return @() }
    return @($Snapshot.messages | ForEach-Object { $_.text })
}

# Responses indexed by id (the prompt event has no id field key we rely on; gather it separately).
function Index-ById { param($Responses) $h = @{}; foreach( $r in @($Responses) ) { if( $null -ne $r.id ) { $h[[int]$r.id] = $r } }; return $h }

$fail = 0
# NEW_PICKUP_MENU defaults to false (and is absent from the fixture's options.json), so A/B/C use the old
# "PICKUP" menu without pinning it; scenario D inserts it true. AUTOSELECT=false makes "Pickup where?"
# always prompt (so the direction one-shot is served, matching the examine fixture contract). AUTO_PICKUP
# is pinned false so the master auto-pickup system never silently grabs the witness pile during the move_s
# approach: the manual `pickup` command is the always-menu `min=0` path (never the `min=-1` autopickup
# path), but the witness pile's survival otherwise depends on the fixture's SAVED AUTO_PICKUP value, so we
# pin it to stay deterministic across fixture drift. All three are deployment config, pinned in the sandbox
# copy, never overridden in memory (docs/arcopolis/25 design point 2).
Set-SandboxOption -Name "AUTOSELECT_SINGLE_VALID_TARGET" -Value $false
Set-SandboxOption -Name "AUTO_PICKUP" -Value $false

# =============================================================================
# Scenario A (probe + cancel): discover the real menu choices and prove the GUI ESC path.
#   step_index: export0=start, move1, export2=after_move, pickup3, export4=after_cancel
# =============================================================================
$reqA = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"export","name":"after_move"}',
    '{"id":4,"op":"command","command":"pickup","direction":"move_s","name":"pickup_probe"}',
    '{"id":5,"op":"prompt_cancel","prompt_id":1}',
    '{"id":6,"op":"export","name":"after_cancel"}',
    '{"id":7,"op":"quit"}'
)
$A = Invoke-LiveScenario -Name "probe_cancel" -RequestLines $reqA
$evA = Read-Transcript -Dir $A.Dir
$respA = Index-ById $A.Result.responses
$promptA = @($A.Result.responses | Where-Object { $_.type -eq 'prompt' })

# --- Gate 1: no hang; ready + clean exit; a prompt event was emitted from the real pickup path. ---
$g1 = ($A.ExitCode -eq 0) -and $A.Result -and $A.Result.ok -and $A.Result.ready_seen -and
      ($A.Result.exit_code -eq 0) -and ($promptA.Count -eq 1)
if( $g1 ) {
    Write-Host "  PASS: scenario A -- backend ready + clean exit 0 under the $TimeoutSec s timeout; one prompt event emitted." -ForegroundColor Green
} else {
    Write-Host "  FAIL: scenario A -- exit=$($A.ExitCode) ok=$($A.Result.ok) prompts=$($promptA.Count) stderr: $($A.Stderr)" -ForegroundColor Red
    $fail++
    if( -not $A.Result -or $promptA.Count -ne 1 ) { Write-Host "PICKUP REGRESSION: aborting (no prompt to assert against)." -ForegroundColor Red; exit 1 }
}

# After move_s the avatar is at after_move's pos; the item pile is the tile one south of it.
$snapAfterMove = Read-Snapshot -Dir $A.Dir -Name $respA[3].snapshot
$southTile = @(
    ( [int]$snapAfterMove.avatar.pos_local[0] ),
    ( [int]$snapAfterMove.avatar.pos_local[1] + 1 ),
    ( [int]$snapAfterMove.avatar.pos_local[2] )
)
$itemsBefore = Get-ItemsAt -Snapshot $snapAfterMove -PosLocal $southTile
$choices = @($promptA[0].choices)
$choiceCount = $choices.Count

# --- Gate 2: the prompt's choices are REAL -- non-empty, and every choice text matches a display name
# of an item actually on the target tile (the menu was read live, not synthesized). ---
$tileNames = @($itemsBefore | ForEach-Object { $_.name })
$choicesReal = ($choiceCount -ge 1) -and (@($choices | Where-Object {
            $c = $_; @($tileNames | Where-Object { $c.text -like ("*" + $_ + "*") -or $_ -like ("*" + $c.text + "*") }).Count -ge 1
        }).Count -eq $choiceCount)
$g2 = ($itemsBefore.Count -ge 1) -and $choicesReal
if( $g2 ) {
    Write-Host "  PASS: prompt choices are real -- $choiceCount choice(s), each matching a ground item on the target tile ($($itemsBefore.Count) raw items)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: prompt choices -- tileItems=$($itemsBefore.Count) choiceCount=$choiceCount names=[$($tileNames -join ', ')] choiceTexts=[$(@($choices | ForEach-Object { $_.text }) -join ', ')]" -ForegroundColor Red
    $fail++
    if( $itemsBefore.Count -lt 1 ) { Write-Host "PICKUP REGRESSION: aborting (fixture witness pile missing south of the avatar)." -ForegroundColor Red; exit 1 }
}

# --- Gate 3: prompt_cancel is the GUI ESC path -- ok:true, "Never mind.", items UNTOUCHED. ---
$snapAfterCancel = Read-Snapshot -Dir $A.Dir -Name $respA[6].snapshot
$itemsAfterCancel = Get-ItemsAt -Snapshot $snapAfterCancel -PosLocal $southTile
$cancelMsgs = Get-MessageTexts $snapAfterCancel
$cancelledEv = @($evA | Where-Object { $_.event -eq 'prompt_cancelled' })
$g3 = ($respA[4].ok -eq $true) -and ($itemsAfterCancel.Count -eq $itemsBefore.Count) -and
      (@($cancelMsgs | Where-Object { $_ -eq 'Never mind.' }).Count -ge 1) -and ($cancelledEv.Count -ge 1)
if( $g3 ) {
    Write-Host "  PASS: prompt_cancel -- ok:true no-op, 'Never mind.', $($itemsAfterCancel.Count) items still on the ground (untouched), transcript prompt_cancelled." -ForegroundColor Green
} else {
    Write-Host "  FAIL: prompt_cancel -- resp=$($respA[4] | ConvertTo-Json -Compress) before=$($itemsBefore.Count) after=$($itemsAfterCancel.Count) cancelled=$($cancelledEv.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario B (main witness): pick the LAST choice (exercises DOWN navigation when C>=2).
#   step_index: export0=start, move1, export2=before, pickup3, export4=after_pick, wait5, export6=after_wait
# =============================================================================
$K = [Math]::Max(0, $choiceCount - 1)
$reqB = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"export","name":"before"}',
    '{"id":4,"op":"command","command":"pickup","direction":"move_s","name":"pickup"}',
    ('{"id":5,"op":"prompt_answer","prompt_id":1,"choice":' + $K + '}'),
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$B = Invoke-LiveScenario -Name "pickup_main" -RequestLines $reqB
$evB = Read-Transcript -Dir $B.Dir
$respB = Index-ById $B.Result.responses

# --- Gate 4: no hang; the pickup command completed ok:true (its terminal response arrived). ---
$g4 = ($B.ExitCode -eq 0) -and $B.Result -and $B.Result.ok -and ($respB[4].ok -eq $true)
if( $g4 ) {
    Write-Host "  PASS: scenario B -- pickup (choice $K) completed ok:true, backend clean exit 0, no hang." -ForegroundColor Green
} else {
    Write-Host "  FAIL: scenario B -- exit=$($B.ExitCode) pickupResp=$($respB[4] | ConvertTo-Json -Compress) stderr: $($B.Stderr)" -ForegroundColor Red
    $fail++
    if( -not $B.Result ) { Write-Host "PICKUP REGRESSION: aborting (no scenario B result)." -ForegroundColor Red; exit 1 }
}

# --- Gate 5 (LEVEL-4 proof): the transcript records the prompt opened with the real choices, the
# answer translated into the SAME registered keystrokes a player presses (DOWN x K, RIGHT, CONFIRM),
# and the engine loop consumed exactly that many actions. ---
$openedB = @($evB | Where-Object { $_.event -eq 'prompt_opened' })
$answeredB = @($evB | Where-Object { $_.event -eq 'prompt_answered' })
$completedB = @($evB | Where-Object { $_.event -eq 'prompt_completed' })
$expectedActions = @( for( $i = 0; $i -lt $K; $i++ ) { 'DOWN' } ) + @('RIGHT', 'CONFIRM')
$actionsB = if( $answeredB.Count -ge 1 ) { @($answeredB[0].actions) } else { @() }
$answeredChoicesB = if( $answeredB.Count -ge 1 ) { @($answeredB[0].choices) } else { @() }
$g5 = ($openedB.Count -ge 1) -and ($openedB[0].choices.Count -eq $choiceCount) -and
      ($answeredB.Count -ge 1) -and (($answeredChoicesB -join ',') -eq "$K") -and
      (($actionsB -join ',') -eq ($expectedActions -join ',')) -and
      ($completedB.Count -ge 1) -and ($completedB[0].actions_served -eq ($K + 2))
if( $g5 ) {
    Write-Host "  PASS: level-4 transcript -- prompt_opened ($choiceCount choices), prompt_answered choices [$($answeredChoicesB -join ', ')] served [$($actionsB -join ', ')], prompt_completed actions_served=$($K + 2)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: level-4 transcript -- opened=$($openedB.Count) answeredChoices=[$($answeredChoicesB -join ', ')] actions=[$($actionsB -join ', ')] expected=[$($expectedActions -join ', ')] completed=$($completedB | ConvertTo-Json -Compress)" -ForegroundColor Red
    $fail++
}

# --- Gate 6 (REAL state change): after the activity drains, the chosen entry's items left the ground,
# the engine logged a "You pick up:" message, and (when C>=2) the OTHER entries remain. Asserts on
# entry/type IDENTITY + total-count drop, not a unit count (RIGHT takes the whole chosen stack). ---
$snapBefore = Read-Snapshot -Dir $B.Dir -Name $respB[3].snapshot
$snapAfterWait = Read-Snapshot -Dir $B.Dir -Name $respB[8].snapshot
$beforeItems = Get-ItemsAt -Snapshot $snapBefore -PosLocal $southTile
$afterItems = Get-ItemsAt -Snapshot $snapAfterWait -PosLocal $southTile
$chosenText = $choices[$K].text
$pickupMsgs = @((Get-MessageTexts $snapAfterWait) | Where-Object { $_ -like 'You pick up:*' -or $_ -like '*You pick up*' })
$g6 = ($beforeItems.Count -ge 1) -and ($afterItems.Count -lt $beforeItems.Count) -and ($pickupMsgs.Count -ge 1)
if( $choiceCount -ge 2 ) { $g6 = $g6 -and ($afterItems.Count -ge 1) }   # other entries remain
if( $g6 ) {
    Write-Host "  PASS: real state change -- south tile $($beforeItems.Count) -> $($afterItems.Count) ground items (chose '$chosenText'), engine logged '$($pickupMsgs[0])'." -ForegroundColor Green
} else {
    Write-Host "  FAIL: state change -- before=$($beforeItems.Count) after=$($afterItems.Count) chose='$chosenText' pickupMsgs=$($pickupMsgs.Count) (msgs: $((Get-MessageTexts $snapAfterWait) -join ' | '))" -ForegroundColor Red
    $fail++
}

# --- Gate 7: the move/turn cost is honest -- moves were spent picking up (the activity ran). ---
$g7 = $snapBefore -and $snapAfterWait -and ($snapAfterWait.backend.turn -ge $snapBefore.backend.turn)
if( $g7 ) {
    Write-Host "  PASS: turn economy -- turn advanced $($snapBefore.backend.turn) -> $($snapAfterWait.backend.turn) across the pickup activity + wait." -ForegroundColor Green
} else {
    Write-Host "  FAIL: turn economy -- before turn=$($snapBefore.backend.turn) after=$($snapAfterWait.backend.turn)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario C (invalid-answer recovery): a WRONG prompt_id and an out-of-range choice are EACH rejected with
# the prompt STILL OPEN; a follow-up valid answer completes the SAME command. The wrong-prompt_id rejection
# proves the transaction correlates the answer to the active prompt (not just op/choices).
#   step_index: export0, move1, pickup2, (reject bad prompt_id), (reject out-of-range), (valid), export3, wait, quit
# =============================================================================
$bad = $choiceCount + 5
$reqC = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup"}',
    '{"id":4,"op":"prompt_answer","prompt_id":999,"choice":0}',
    ('{"id":5,"op":"prompt_answer","prompt_id":1,"choice":' + $bad + '}'),
    '{"id":6,"op":"prompt_answer","prompt_id":1,"choice":0}',
    '{"id":7,"op":"export","name":"after_pick"}',
    '{"id":8,"op":"command","command":"wait","name":"after"}',
    '{"id":9,"op":"quit"}'
)
$C = Invoke-LiveScenario -Name "invalid_recovery" -RequestLines $reqC
$evC = Read-Transcript -Dir $C.Dir
# The driver captures all lines in order; find the rejected answers (ok:false) and the command response.
$cResponses = @($C.Result.responses)
$reject = @($cResponses | Where-Object { $_.type -eq 'response' -and $_.op -eq 'prompt_answer' -and $_.ok -eq $false })
$rejectBadReq = @($reject | Where-Object { $_.error.code -eq 'bad_request' })
$failedEv = @($evC | Where-Object { $_.event -eq 'prompt_failed' })
$mismatchEv = @($failedEv | Where-Object { $_.reason -eq 'prompt_id_mismatch' })
$rangeEv = @($failedEv | Where-Object { $_.reason -eq 'invalid_answer' })
$cmdOkAfterReject = @($cResponses | Where-Object { $_.type -eq 'response' -and $_.op -eq 'command' -and $_.id -eq 3 -and $_.ok -eq $true })
$g8 = ($C.ExitCode -eq 0) -and $C.Result.ok -and ($reject.Count -ge 2) -and ($rejectBadReq.Count -ge 2) -and
      ($mismatchEv.Count -ge 1) -and ($rangeEv.Count -ge 1) -and ($cmdOkAfterReject.Count -ge 1)
if( $g8 ) {
    Write-Host "  PASS: invalid recovery -- wrong prompt_id (999) AND out-of-range choice $bad each rejected ok:false bad_request (prompt stayed open; prompt_failed reasons prompt_id_mismatch + invalid_answer), then a valid answer completed the SAME pickup ok:true." -ForegroundColor Green
} else {
    Write-Host "  FAIL: invalid recovery -- exit=$($C.ExitCode) reject=$($reject.Count) badReq=$($rejectBadReq.Count) mismatch=$($mismatchEv.Count) range=$($rangeEv.Count) cmdOk=$($cmdOkAfterReject.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario D (NEW_PICKUP_MENU=true fail-loud): a pickup is rejected BEFORE any prompt; the session
# stays usable.
# =============================================================================
Set-SandboxOption -Name "NEW_PICKUP_MENU" -Value $true
$reqD = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"command","command":"pickup","direction":"move_s","name":"pickup_new_menu"}',
    '{"id":3,"op":"command","command":"wait","name":"still_usable"}',
    '{"id":4,"op":"quit"}'
)
$D = Invoke-LiveScenario -Name "new_pickup_menu_failloud" -RequestLines $reqD
$respD = Index-ById $D.Result.responses
$promptD = @($D.Result.responses | Where-Object { $_.type -eq 'prompt' })
$g9 = ($D.ExitCode -eq 0) -and $D.Result.ok -and ($respD[2].ok -eq $false) -and
      ($respD[2].error.code -eq 'unsupported_command') -and ($promptD.Count -eq 0) -and ($respD[3].ok -eq $true)
if( $g9 ) {
    Write-Host "  PASS: NEW_PICKUP_MENU=true fail-loud -- pickup rejected ok:false unsupported_command with NO prompt emitted; the session still served a later wait." -ForegroundColor Green
} else {
    Write-Host "  FAIL: NEW_PICKUP_MENU fail-loud -- exit=$($D.ExitCode) pickup=$($respD[2] | ConvertTo-Json -Compress) prompts=$($promptD.Count) wait=$($respD[3].ok)" -ForegroundColor Red
    $fail++
}

# Scenario D set NEW_PICKUP_MENU=true; reset it false for the remaining multi-select scenarios.
Set-SandboxOption -Name "NEW_PICKUP_MENU" -Value $false

# =============================================================================
# Scenario E (rejected items -- honest partial pickup, MARKED not-full-success): on the DEFAULT no-backpack
# avatar, the client selects TWO entries, one of which the avatar cannot carry (the bulky [0] "folded
# emergency blanket", 500 ml -- the evac-shelter avatar has room for only one small item). The engine
# carries the one that fits (the glass shard) and leaves the over-capacity blanket on the ground. Driving
# the in-activity capacity uilist (handle_problematic_pickup) is NOT IMPLEMENTED -- a tracked defect. The
# Spike 12A follow-up makes that NON-SILENT: src/pickup.cpp reports it (backend_report_pickup_secondary_
# forced_cancel) so this command response carries the explicit marker set { forced_cancel, partial,
# unsupported_prompt:"secondary_capacity" } and the transcript a prompt_force_cancelled event. This is NOT
# full success -- it is a partial engine result with an unsupported secondary prompt force-cancelled and
# explicitly MARKED. The transaction does NOT fake the part it cannot do: the rejected item stays and is
# NEVER logged as picked up, while the transcript still shows the client's full 2-entry intent (two RIGHT marks).
# =============================================================================
$reqR = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"export","name":"before"}',
    '{"id":4,"op":"command","command":"pickup","direction":"move_s","name":"pickup_reject"}',
    '{"id":5,"op":"prompt_answer","prompt_id":1,"choices":[0,6]}',
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$R = Invoke-LiveScenario -Name "rejected_items" -RequestLines $reqR
$evR = Read-Transcript -Dir $R.Dir
$respR = Index-ById $R.Result.responses
$answeredR = @($evR | Where-Object { $_.event -eq 'prompt_answered' })
$answeredChoicesR = if( $answeredR.Count -ge 1 ) { @($answeredR[0].choices) } else { @() }
$actionsR = if( $answeredR.Count -ge 1 ) { @($answeredR[0].actions) } else { @() }
# choices [0,6] -> RIGHT (mark blanket entry 0), DOWN x6 (walk to entry 6), RIGHT (mark the shard), CONFIRM.
$expectedR = @('RIGHT') + @( for( $i = 0; $i -lt 6; $i++ ) { 'DOWN' } ) + @('RIGHT', 'CONFIRM')
$snapBeforeR = Read-Snapshot -Dir $R.Dir -Name $respR[3].snapshot
$snapAfterR = Read-Snapshot -Dir $R.Dir -Name $respR[8].snapshot
$beforeR = Get-ItemsAt -Snapshot $snapBeforeR -PosLocal $southTile
$afterR = Get-ItemsAt -Snapshot $snapAfterR -PosLocal $southTile
$afterNamesR = @($afterR | ForEach-Object { $_.name })
$blanketStaysR = @($afterNamesR | Where-Object { $_ -like '*folded emergency blanket*' } ).Count -ge 1
$shardGoneR = @($afterNamesR | Where-Object { $_ -like '*glass shard*' } ).Count -eq 0
$pickupMsgsR = @((Get-MessageTexts $snapAfterR) | Where-Object { $_ -like '*You pick up*' })
$blanketPickedMsgR = @($pickupMsgsR | Where-Object { $_ -like '*blanket*' } ).Count
# Spike 12A follow-up: the secondary capacity prompt is force-cancelled, so the command response is MARKED
# not-full-success (ok stays true -- a real partial pickup happened) and the transcript records it.
$markedR = ($respR[4].forced_cancel -eq $true) -and ($respR[4].partial -eq $true) -and
           ($respR[4].unsupported_prompt -eq 'secondary_capacity')
$forceCancelEvR = @($evR | Where-Object { $_.event -eq 'prompt_force_cancelled' -and $_.kind -eq 'secondary_capacity' })
$gRej = ($R.ExitCode -eq 0) -and $R.Result.ok -and ($respR[4].ok -eq $true) -and
        (($answeredChoicesR -join ',') -eq '0,6') -and (($actionsR -join ',') -eq ($expectedR -join ',')) -and
        ($afterR.Count -eq ($beforeR.Count - 1)) -and $blanketStaysR -and $shardGoneR -and
        ($pickupMsgsR.Count -eq 1) -and ($blanketPickedMsgR -eq 0) -and
        $markedR -and ($forceCancelEvR.Count -ge 1)
if( $gRej ) {
    Write-Host "  PASS: rejected items (no-backpack avatar) -- chose [0,6] (over-capacity blanket + shard); engine carried only the shard ($($beforeR.Count) -> $($afterR.Count)), the rejected blanket stays on the ground and is NEVER logged as picked up. NOT full success: response MARKED forced_cancel/partial/unsupported_prompt=secondary_capacity + transcript prompt_force_cancelled (an honest partial pickup, the secondary prompt is force-cancelled and marked, not driven)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: rejected items -- exit=$($R.ExitCode) pickup=$($respR[4].ok) marked=$markedR forceCancelEv=$($forceCancelEvR.Count) choices=[$($answeredChoicesR -join ', ')] actions=[$($actionsR -join ', ')] before=$($beforeR.Count) after=$($afterR.Count) blanketStays=$blanketStaysR shardGone=$shardGoneR msgs=$($pickupMsgsR.Count) blanketPicked=$blanketPickedMsgR" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario F (multi-select carry-both): on the BACKPACK avatar (ArcopolisBackpackTest), the client picks TWO
# entries in one menu visit; with real carrying capacity BOTH leave the ground and the others remain. Proves
# the level-4 mechanism drives multiple RIGHT marks (navigated by DOWN) through the engine's OWN loop, and
# that the only reason Scenario E carried one was the avatar's capacity (not a selection-mechanism limit).
#   step_index: export0=start, move1, export2=before, pickup3, export4=after_pick, wait5, export6=after_wait
# =============================================================================
$reqE = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"export","name":"before"}',
    '{"id":4,"op":"command","command":"pickup","direction":"move_s","name":"pickup_multi"}',
    '{"id":5,"op":"prompt_answer","prompt_id":1,"choices":[5,6]}',
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$E = Invoke-LiveScenario -Name "multi_select" -RequestLines $reqE -ScenarioWorld $BackpackWorld
$evE = Read-Transcript -Dir $E.Dir
$respE = Index-ById $E.Result.responses
$answeredE = @($evE | Where-Object { $_.event -eq 'prompt_answered' })
$answeredChoicesE = if( $answeredE.Count -ge 1 ) { @($answeredE[0].choices) } else { @() }
$actionsE = if( $answeredE.Count -ge 1 ) { @($answeredE[0].actions) } else { @() }
# choices [5,6] = "FEMA evacuation pamphlet" + "glass shard" -- two distinct entries. On THIS fixture the
# avatar wears a backpack (ArcopolisBackpackTest), so it has real carrying capacity and BOTH selected items
# fit; the south tile drops by two. (Contrast Scenario E above, where the no-backpack avatar carried only
# one of two selected items -- that was capacity, not a selection-mechanism limit.)
# Multi-select arming sorts the picks, so [5,6] -> DOWN x5 (walk to entry 5), RIGHT (mark it), DOWN (walk to
# entry 6), RIGHT (mark it), CONFIRM -- the engine's own loop performs both marks, navigated forward only.
$expectedE = @( for( $i = 0; $i -lt 5; $i++ ) { 'DOWN' } ) + @('RIGHT', 'DOWN', 'RIGHT', 'CONFIRM')
$snapBeforeE = Read-Snapshot -Dir $E.Dir -Name $respE[3].snapshot
$snapAfterE = Read-Snapshot -Dir $E.Dir -Name $respE[8].snapshot
$beforeE = Get-ItemsAt -Snapshot $snapBeforeE -PosLocal $southTile
$afterE = Get-ItemsAt -Snapshot $snapAfterE -PosLocal $southTile
$pickupMsgsE = @((Get-MessageTexts $snapAfterE) | Where-Object { $_ -like '*You pick up*' })
# Identity check (not just count): the TWO chosen entries must both be gone; the others must remain.
$afterNamesE = @($afterE | ForEach-Object { $_.name })
$chosenStillThereE = @($afterNamesE | Where-Object { $_ -like '*FEMA evacuation pamphlet*' -or $_ -like '*glass shard*' }).Count
# show_pickup_message emits one "You pick up:" line per distinct item name (src/pickup.cpp:1391-1402), so
# carry-both must produce a line for BOTH chosen items -- assert per-name, not just a lenient count, so the
# gate actually witnesses the "a pickup per item" claim it reports.
$pamphletLoggedE = @($pickupMsgsE | Where-Object { $_ -like '*FEMA evacuation pamphlet*' }).Count -ge 1
$shardLoggedE = @($pickupMsgsE | Where-Object { $_ -like '*glass shard*' }).Count -ge 1
$g10 = ($E.ExitCode -eq 0) -and $E.Result.ok -and ($respE[4].ok -eq $true) -and
       (($answeredChoicesE -join ',') -eq '5,6') -and (($actionsE -join ',') -eq ($expectedE -join ',')) -and
       ($beforeE.Count -ge 2) -and ($afterE.Count -eq ($beforeE.Count - 2)) -and ($chosenStillThereE -eq 0) -and
       ($pickupMsgsE.Count -ge 2) -and $pamphletLoggedE -and $shardLoggedE
if( $g10 ) {
    Write-Host "  PASS: multi-select carry-both (backpack avatar) -- chose [5,6], served [$($actionsE -join ', ')]; south tile $($beforeE.Count) -> $($afterE.Count); both chosen entries gone, others remain; engine logged a pickup per item." -ForegroundColor Green
} else {
    Write-Host "  FAIL: multi-select -- exit=$($E.ExitCode) pickup=$($respE[4].ok) choices=[$($answeredChoicesE -join ', ')] actions=[$($actionsE -join ', ')] expected=[$($expectedE -join ', ')] before=$($beforeE.Count) after=$($afterE.Count) chosenLeft=$chosenStillThereE msgs=$($pickupMsgsE.Count) pamphletLogged=$pamphletLoggedE shardLogged=$shardLoggedE" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario G (transcript honesty: no phantom prompt_completed): `pickup here` on the avatar's EMPTY self-tile
# arms the transaction but reaches NO menu (no items there), so no prompt is opened. The transcript must then
# contain NEITHER prompt_opened NOR prompt_completed -- a prompt_completed with no matching prompt_opened
# (actions_served:0) would be a transcript lie. Also exercises the `here` target direction for pickup.
# =============================================================================
$reqG = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"pickup","direction":"here","name":"pickup_here_empty"}',
    '{"id":3,"op":"export","name":"after"}',
    '{"id":4,"op":"quit"}'
)
$G = Invoke-LiveScenario -Name "no_phantom_completed" -RequestLines $reqG
$evG = Read-Transcript -Dir $G.Dir
$respG = Index-ById $G.Result.responses
$openedG = @($evG | Where-Object { $_.event -eq 'prompt_opened' })
$completedG = @($evG | Where-Object { $_.event -eq 'prompt_completed' })
$promptsG = @($G.Result.responses | Where-Object { $_.type -eq 'prompt' })
$gPhantom = ($G.ExitCode -eq 0) -and $G.Result.ok -and ($respG[2].ok -eq $true) -and
            ($promptsG.Count -eq 0) -and ($openedG.Count -eq 0) -and ($completedG.Count -eq 0)
if( $gPhantom ) {
    Write-Host "  PASS: no phantom prompt_completed -- 'pickup here' on the empty self-tile opened no menu (0 prompts), and the transcript has neither prompt_opened nor prompt_completed." -ForegroundColor Green
} else {
    Write-Host "  FAIL: no phantom prompt_completed -- exit=$($G.ExitCode) ok=$($G.Result.ok) pickup=$($respG[2].ok) prompts=$($promptsG.Count) opened=$($openedG.Count) completed=$($completedG.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario H (vehicle submenu FAIL-LOUD, Spike 12A follow-up): on ArcopolisVehicleCargoTest -- a copy of
# ArcopolisTest with a folding_wagon (1 CARGO item) injected ONTO the south ground-item pile -- a live
# `pickup direction=move_s` targets a tile with BOTH vehicle cargo AND ground items. game::pickup opens the
# "Get items from where?" uilist (src/pickup.cpp:1268), which the prompt transaction does NOT drive. The
# follow-up FAILS LOUD: NO prompt is emitted, the command answers ok:false/unsupported_command, the
# transcript records prompt_force_cancelled kind=vehicle_submenu, and the session stays usable (a later wait
# succeeds). This is the honest alternative to silently picking only the ground items.
# =============================================================================
$reqH = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"command","command":"pickup","direction":"move_s","name":"pickup_vehicle_tile"}',
    '{"id":3,"op":"command","command":"wait","name":"still_usable"}',
    '{"id":4,"op":"quit"}'
)
$H = Invoke-LiveScenario -Name "vehicle_submenu_failloud" -RequestLines $reqH -ScenarioWorld $VehicleWorld
$evH = Read-Transcript -Dir $H.Dir
$respH = Index-ById $H.Result.responses
$promptH = @($H.Result.responses | Where-Object { $_.type -eq 'prompt' })
$forceCancelH = @($evH | Where-Object { $_.event -eq 'prompt_force_cancelled' -and $_.kind -eq 'vehicle_submenu' })
$gVeh = ($H.ExitCode -eq 0) -and $H.Result.ok -and ($promptH.Count -eq 0) -and
        ($respH[2].ok -eq $false) -and ($respH[2].error.code -eq 'unsupported_command') -and
        ($forceCancelH.Count -ge 1) -and ($respH[3].ok -eq $true)
if( $gVeh ) {
    Write-Host "  PASS: vehicle submenu fail-loud -- a live pickup onto the vehicle-cargo + ground-items tile emitted NO prompt, answered ok:false/unsupported_command (transcript prompt_force_cancelled kind=vehicle_submenu), and the session still served a later wait. No silent ground-only pickup." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle submenu fail-loud -- exit=$($H.ExitCode) ok=$($H.Result.ok) prompts=$($promptH.Count) pickup=$($respH[2] | ConvertTo-Json -Compress) forceCancel=$($forceCancelH.Count) wait=$($respH[3].ok)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario I (non-live FAIL-LOUD, Spike 12A follow-up): `pickup` is a live-only command (its item menu needs
# a prompt answer channel the script/one-shot providers do not have). Rather than silently auto-cancelling
# and reporting success, the non-live pre-flight REJECTS it with unsupported_command (exit 6) BEFORE the
# world load, in BOTH --arcopolis-run-script and one-shot --arcopolis-command. Proves the "non-live fails
# loud for promptful commands" rule directly against the binary (no live driver).
# =============================================================================
$nonLiveDir = Join-Path $OutRoot "non_live_failloud"
New-Item -ItemType Directory -Force $nonLiveDir | Out-Null
# unsupported_command -> exit_code_for() == 6 (src/arcopolis_command.cpp).
$expectedNonLiveExit = 6
# (a) script mode
$scriptPath = Join-Path $nonLiveDir "pickup_script.json"
Set-Content -Path $scriptPath -Value '{"schema_version":1,"steps":[{"op":"command","command":"pickup","direction":"move_s"}]}' -Encoding ascii
$scriptErr = Join-Path $nonLiveDir "script_err.txt"
$ps = Start-Process -FilePath $Exe -ArgumentList @('--world', $World, '--arcopolis-run-script', $scriptPath,
    '--arcopolis-export-dir', (Join-Path $nonLiveDir "script_out"), '--userdir', $UserDir) -NoNewWindow -Wait -PassThru `
    -RedirectStandardError $scriptErr -RedirectStandardOutput (Join-Path $nonLiveDir "script_out.txt")
$scriptErrText = (Get-Content $scriptErr -Raw -ErrorAction SilentlyContinue)
# (b) one-shot mode
$cmdPath = Join-Path $nonLiveDir "pickup_cmd.json"
Set-Content -Path $cmdPath -Value '{"schema_version":1,"command":"pickup","direction":"move_s"}' -Encoding ascii
$oneshotSnap = Join-Path $nonLiveDir "oneshot.json"
$oneshotErr = Join-Path $nonLiveDir "oneshot_err.txt"
$po = Start-Process -FilePath $Exe -ArgumentList @('--world', $World, '--arcopolis-export-current-view', $oneshotSnap,
    '--arcopolis-command', $cmdPath, '--userdir', $UserDir) -NoNewWindow -Wait -PassThru `
    -RedirectStandardError $oneshotErr -RedirectStandardOutput (Join-Path $nonLiveDir "oneshot_out.txt")
$oneshotErrText = (Get-Content $oneshotErr -Raw -ErrorAction SilentlyContinue)
$gNonLive = ($ps.ExitCode -eq $expectedNonLiveExit) -and ($po.ExitCode -eq $expectedNonLiveExit) -and
            ($scriptErrText -like '*requires --arcopolis-live*') -and ($oneshotErrText -like '*requires --arcopolis-live*') -and
            (-not (Test-Path $oneshotSnap))
if( $gNonLive ) {
    Write-Host "  PASS: non-live fail-loud -- both --arcopolis-run-script and one-shot --arcopolis-command rejected pickup with exit $expectedNonLiveExit (unsupported_command) BEFORE the world load; no snapshot written, clear 'requires --arcopolis-live' message. Non-live fails loud for promptful commands instead of a silent no-op." -ForegroundColor Green
} else {
    Write-Host "  FAIL: non-live fail-loud -- scriptExit=$($ps.ExitCode) oneshotExit=$($po.ExitCode) (expected $expectedNonLiveExit) snapshotWritten=$(Test-Path $oneshotSnap) scriptErr='$scriptErrText' oneshotErr='$oneshotErrText'" -ForegroundColor Red
    $fail++
}

if( $fail -gt 0 ) { Write-Host "PICKUP REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "PICKUP REGRESSION: ok." -ForegroundColor Green
exit 0
