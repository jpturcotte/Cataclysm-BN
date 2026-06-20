# Arcopolis Spike 11A regression: directed examine through the backend nested-input seam.
#
# Proves, against ONE persistent --arcopolis-live backend per scenario, that:
#   - an `examine` command with a `direction` completes WITHOUT hanging (every response is read
#     under a strict per-response timeout; a breach kills the backend and FAILS the run),
#   - the armed direction answer is served to the engine's own chooser (transcript
#     `nested_input_answer`, context DEFAULTMODE) and the top-level action is the engine's
#     ACTION_EXAMINE (`command` event action_id "examine"),
#   - the auto-cancel guard converts the examine pickup tail's raw "PICKUP" loop into the accepted
#     ESC class (transcript `nested_input_guard`, action QUIT) with NO items taken,
#   - malformed examine requests are recoverable rejections (ok:false unsupported_command) and the
#     session continues,
#   - SPIKE 21: examine move_n AND move move_n into the shelter NPC each reach game::npc_menu's UNARMED
#     uilist and now FAIL LOUD (ok:false unexpected_prompt, RECOVERABLE -- the chooser answer is still
#     served first); move_s moves, wait ticks; no stale nested answer leaks into a later command, and the
#     session ends with a quit response + final snapshot + session_end "ok" + process exit 0
#     (see docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md),
#   - under the deployment default AUTOSELECT_SINGLE_VALID_TARGET=true (scenario B) the same examine
#     stays hang-free: the engine auto-selects the NPC tile (chooser skipped, armed answer force-cleared
#     as `nested_input_unconsumed`) and then the unarmed npc_menu uilist FAILS LOUD recoverably (Spike 21);
#     the session keeps serving and quits cleanly.
#   - SPIKE 21 (vehicle, scenario C, ArcopolisVehicleCargoTest): `examine move_s` of a VEHICLE tile routes
#     via game::examine -> vehicle::interact_with (which RETURNS before the pickup tail) -> its OWN unarmed
#     "Select an action" uilist selectmenu (EXAMINE + TRACK are unconditional, so it is always >=2 entries
#     and calls query()). examine arms only the query_popup transaction, so this uilist is UNARMED and now
#     FAILS LOUD -- witnessed in BOTH modes: non-live run-script EXIT 14 (before written, no after_examine,
#     exactly one unexpected_prompt error event) and live RECOVERABLE ok=false/unexpected_prompt (the
#     chooser answer DOWN is still served, and there is NO pickup guard -- proving the vehicle branch, not
#     the item-pickup tail; the session keeps serving). Closes the doc 43 §10 ungated gap.
#
# The AUTOSELECT_SINGLE_VALID_TARGET option is PINNED IN THE SANDBOX COPY's options.json per
# scenario (false for A, true for B) so the gates stay deterministic regardless of fixture drift;
# the option is deployment config and is never overridden in memory (docs/arcopolis/25, design
# point 2 -- the transcript's session_start records the loaded value, asserted here).
#
# Requests are driven raw through docs/arcopolis/examine_live_driver.py (stdlib-only; reuses the
# client harness's LiveSession plumbing) because harness.py's `live --commands` vocabulary is a
# closed move/wait token list that cannot express examine.
#
# Exit codes: 0 = all gates pass; 1 = one or more gates failed; 3..8 = missing prereq (see below).

[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$VehicleWorld = "ArcopolisVehicleCargoTest",
    [string]$OutRoot    = ".\out\arco_examine_regress",
    [string]$Driver     = "docs\arcopolis\examine_live_driver.py",
    [string]$HarnessDir = "tools\arcopolis_client",
    [double]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N`
# does NOT work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error
# that unwinds BEFORE `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps
# it non-terminating so the labeled code is actually returned (see 16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=driver, 8=harness). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $FixtureSrc  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
}
$fixtureVehicleWorld = Join-Path $FixtureSrc (Join-Path "save" $VehicleWorld)
if( -not (Test-Path $fixtureVehicleWorld) ) {
    Stop-WithCode "Fixture world '$VehicleWorld' not found at $fixtureVehicleWorld -- the vehicle-examine fail-loud witness (scenario C) needs the cargo-vehicle fixture (a copy of $World with a folding_wagon injected onto the south ground-item pile; build it with docs/arcopolis/make_vehicle_fixture.py)." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the live driver). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Driver) ) {
    Stop-WithCode "Examine live driver not found: $Driver" 7
}
if( -not (Test-Path (Join-Path $HarnessDir "harness.py")) ) {
    Stop-WithCode "Client harness not found under: $HarnessDir (the driver imports its LiveSession)" 8
}

# Refresh the gitignored sandbox userdir from the external fixture. `Copy-Item -Recurse` nests the
# source INSIDE the destination when the destination already exists, so delete any existing
# sandbox first (same rationale as the sibling regression scripts).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Pin one option value in the SANDBOX copy's options.json (deployment config, never an in-memory
# override): the per-scenario examine gates must not silently depend on the external fixture's
# current value. Fails hard if the option line is missing (a fixture regeneration dropped it).
function Set-SandboxAutoselect {
    param([bool]$Value)
    $optPath = Join-Path $UserDir "config\options.json"
    $text = Get-Content $optPath -Raw
    $word = if( $Value ) { "true" } else { "false" }
    $patched = $text -replace '("name": "AUTOSELECT_SINGLE_VALID_TARGET", "value": ")(true|false)(")', "`${1}$word`${3}"
    if( $patched -notmatch '"name": "AUTOSELECT_SINGLE_VALID_TARGET", "value": "' + $word ) {
        Stop-WithCode "Could not pin AUTOSELECT_SINGLE_VALID_TARGET=$word in the sandbox options.json" 4
    }
    Set-Content -Path $optPath -Value $patched -NoNewline -Encoding utf8
}

# Run the raw-request driver for one scenario; returns the parsed result JSON (or fails the run).
# ScenarioWorld defaults to $World; scenario C overrides it to the vehicle-cargo fixture.
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

# Drive a NON-LIVE run-script against ONE world; returns its exit code + exported snapshots + transcript
# events. Mirrors npc_export_regression's runner. cataclysm-bn-tiles is a WINDOWS-subsystem exe, so a bare
# `& $exe` does NOT wait for it and leaves $LASTEXITCODE empty -- Start-Process -Wait -PassThru waits and
# captures the real exit code. A nonzero exit is NOT thrown: scenario C's fail-loud run is EXPECTED to exit
# 14, and the caller asserts the exit code itself.
function Invoke-ExamineRunScript {
    param([string]$Name, [string]$ScriptBody, [string]$ScenarioWorld = $World)
    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $scriptPath = Join-Path $dir "script.json"
    $ScriptBody | Set-Content -Encoding ascii $scriptPath
    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $ScenarioWorld,
        '--arcopolis-run-script', $scriptPath,
        '--arcopolis-export-dir', $dir,
        '--userdir', $UserDir
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")
    # Select snapshots by the NNN_ prefix so we pick only NNN_<name>.json (excludes script.json).
    $snapFiles = Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | Sort-Object Name
    $snaps = foreach( $f in $snapFiles ) {
        [pscustomobject]@{ File = $f.Name; Snap = (Get-Content $f.FullName -Raw | ConvertFrom-Json) }
    }
    $logPath = Join-Path $dir "session.jsonl"
    $events = @()
    if( Test-Path $logPath ) {
        $events = @(Get-Content $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{ Name = $Name; Dir = $dir; Snaps = $snaps; ExitCode = $p.ExitCode; Events = $events }
}

# Parse the session transcript into an ordered event list (index = line order).
function Read-Transcript {
    param([string]$Dir)
    $path = Join-Path $Dir "session.jsonl"
    if( -not (Test-Path $path) ) { return $null }
    return @(Get-Content $path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

# The transcript events belonging to one command's dispatch window: everything strictly between the
# `command` event with the given step_index and that step's `export` (response snapshot) event.
function Get-DispatchWindow {
    param($Events, [int]$StepIndex)
    $cmdIdx = -1
    $expIdx = -1
    for( $i = 0; $i -lt $Events.Count; $i++ ) {
        $ev = $Events[$i]
        if( $ev.event -eq 'command' -and $ev.step_index -eq $StepIndex ) { $cmdIdx = $i }
        if( $ev.event -eq 'export' -and $cmdIdx -ge 0 -and $ev.step_index -eq $StepIndex ) { $expIdx = $i; break }
    }
    if( $cmdIdx -lt 0 -or $expIdx -lt 0 ) { return $null }
    return [pscustomobject]@{
        Command = $Events[$cmdIdx]
        Export  = $Events[$expIdx]
        Between = @( if( $expIdx -gt $cmdIdx + 1 ) { $Events[($cmdIdx + 1)..($expIdx - 1)] } )
    }
}

# Like Get-DispatchWindow, but for a command that produced NO export -- a Spike 21 fail-loud command
# (examine/move into the NPC reaches game::npc_menu's unarmed uilist -> unexpected_prompt, no snapshot
# written). The window is the events strictly between this step's `command` event and the NEXT `command`
# event (or end of transcript). Rejected protocol requests never enter the transcript, so the next
# `command` event is the next ACCEPTED step.
function Get-CommandSpan {
    param($Events, [int]$StepIndex)
    $cmdIdx = -1
    for( $i = 0; $i -lt $Events.Count; $i++ ) {
        if( $Events[$i].event -eq 'command' -and $Events[$i].step_index -eq $StepIndex ) { $cmdIdx = $i; break }
    }
    if( $cmdIdx -lt 0 ) { return $null }
    $end = $Events.Count
    for( $j = $cmdIdx + 1; $j -lt $Events.Count; $j++ ) {
        if( $Events[$j].event -eq 'command' ) { $end = $j; break }
    }
    return [pscustomobject]@{
        Command = $Events[$cmdIdx]
        Between = @( if( $end -gt $cmdIdx + 1 ) { $Events[($cmdIdx + 1)..($end - 1)] } )
    }
}

function Read-Snapshot {
    param([string]$Dir, [string]$Name)
    # A fail-loud command (Spike 21 unexpected_prompt) writes no snapshot, so its response carries an
    # empty/null name -- guard so Join-Path doesn't resolve to the directory (Get-Content would then throw).
    if( [string]::IsNullOrEmpty($Name) ) { return $null }
    $path = Join-Path $Dir $Name
    if( -not (Test-Path $path) ) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

# Count ground items at one pos_local tile of a snapshot.
function Get-ItemCountAt {
    param($Snapshot, [int[]]$PosLocal)
    return @($Snapshot.entities.items | Where-Object {
        $_.pos_local[0] -eq $PosLocal[0] -and $_.pos_local[1] -eq $PosLocal[1] -and $_.pos_local[2] -eq $PosLocal[2]
    }).Count
}

# The engine's player-visible message texts at a snapshot instant (empty for a null snapshot).
function Get-MessageTexts {
    param($Snapshot)
    if( -not $Snapshot ) { return @() }
    return @($Snapshot.messages | ForEach-Object { $_.text })
}

$fail = 0

# =============================================================================
# Scenario A (AUTOSELECT=false -- the fixture's declared value): every serve/guard witness.
# Request ids/names line up with step_index 0..9 in the transcript.
# =============================================================================
Set-SandboxAutoselect -Value $false
$reqA = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_n","name":"examine_npc"}',
    '{"id":3,"op":"command","command":"wait","name":"after_examine_wait"}',
    '{"id":4,"op":"command","command":"examine","name":"bad_examine_missing"}',
    '{"id":5,"op":"command","command":"examine","direction":"move_up","name":"bad_examine_vertical"}',
    '{"id":6,"op":"command","command":"move","direction":"move_n","name":"move_n_blocked"}',
    '{"id":7,"op":"command","command":"move","direction":"move_s","name":"move_s_step"}',
    '{"id":8,"op":"command","command":"examine","direction":"move_s","name":"examine_items"}',
    '{"id":9,"op":"command","command":"wait","name":"after_items_wait"}',
    '{"id":10,"op":"command","command":"examine","direction":"move_sw","name":"examine_sw_diag"}',
    '{"id":11,"op":"quit"}'
)
$A = Invoke-LiveScenario -Name "autoselect_off" -RequestLines $reqA

# --- Gate 1: no deadlock -- every response arrived in time, backend exited 0. ---
$g1 = ($A.ExitCode -eq 0) -and $A.Result -and $A.Result.ok -and $A.Result.ready_seen -and
      ($A.Result.protocol_version -eq 1) -and ($A.Result.exit_code -eq 0) -and
      (@($A.Result.responses).Count -eq 11)
if( $g1 ) {
    Write-Host "  PASS: scenario A -- 11 responses under the $TimeoutSec s per-response timeout, ready seen, backend exit 0." -ForegroundColor Green
} else {
    Write-Host "  FAIL: scenario A driver -- exit=$($A.ExitCode) result=$($A.Result | ConvertTo-Json -Compress -Depth 3) stderr: $($A.Stderr)" -ForegroundColor Red
    $fail++
    if( -not $A.Result ) {
        Write-Host "EXAMINE REGRESSION: aborting (no scenario A result to assert against)." -ForegroundColor Red
        exit 1
    }
}

$evA = Read-Transcript -Dir $A.Dir
$respA = @{}
foreach( $r in @($A.Result.responses) ) { if( $null -ne $r.id ) { $respA[[int]$r.id] = $r } }

# --- Gate 2: session_start records the pinned autoselect=false; transcript is error-free. ---
$startEv = $evA | Where-Object { $_.event -eq 'session_start' } | Select-Object -First 1
$errEvs = @($evA | Where-Object { $_.event -eq 'error' })
$endEv = $evA | Where-Object { $_.event -eq 'session_end' } | Select-Object -First 1
$g2 = $startEv -and ($startEv.autoselect_single_valid_target -eq $false) -and ($errEvs.Count -eq 0) -and
      $endEv -and ($endEv.status -eq 'ok')
if( $g2 ) {
    Write-Host "  PASS: transcript -- session_start.autoselect_single_valid_target=false, zero error events, session_end ok." -ForegroundColor Green
} else {
    Write-Host "  FAIL: transcript -- start=$($startEv | ConvertTo-Json -Compress) errors=$($errEvs.Count) end=$($endEv | ConvertTo-Json -Compress)" -ForegroundColor Red
    $fail++
}

# --- Gate 3 (Spike 21): examine toward the NPC -- the armed chooser answer is STILL served to the
# DEFAULTMODE chooser (the level-4 chooser is unchanged), then the engine opens game::npc_menu's UNARMED
# uilist, which now FAILS LOUD: the response is ok=false / unexpected_prompt (RECOVERABLE -- the session
# keeps serving). The failed examine writes no snapshot. Previously the npc menu silently auto-cancelled
# and the examine looked successful (a hidden lost interaction); see
# docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md. ---
# Get-CommandSpan (NOT Get-DispatchWindow): the failed examine writes no export, so the window is bounded
# by the next command event. The transcript span is [nested_input_answer(DEFAULTMODE/UP), prompt_failed].
$w2 = Get-CommandSpan -Events $evA -StepIndex 1
$snapStart = Read-Snapshot -Dir $A.Dir -Name $respA[1].snapshot
$answers2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_answer' })
$guards2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_guard' })
$unconsumed2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_unconsumed' })
$pf2 = @($w2.Between | Where-Object { $_.event -eq 'prompt_failed' -and $_.reason -eq 'unexpected_prompt' })
$g3 = ($respA[2].ok -eq $false) -and ($respA[2].error.code -eq 'unexpected_prompt') -and
      $w2 -and ($w2.Command.command -eq 'examine') -and ($w2.Command.direction -eq 'move_n') -and
      ($w2.Command.action_id -eq 'examine') -and ($answers2.Count -eq 1) -and
      ($answers2[0].context -eq 'DEFAULTMODE') -and ($answers2[0].direction -eq 'move_n') -and
      ($answers2[0].action -eq 'UP') -and ($guards2.Count -eq 0) -and ($unconsumed2.Count -eq 0) -and
      ($pf2.Count -eq 1)
if( $g3 ) {
    Write-Host "  PASS: examine move_n (NPC) -- action_id examine, answer UP served to DEFAULTMODE chooser, then the unarmed NPC menu fails loud (ok=false / unexpected_prompt + prompt_failed, recoverable). See doc 43." -ForegroundColor Green
} else {
    Write-Host "  FAIL: examine move_n (NPC) -- resp=$($respA[2] | ConvertTo-Json -Compress) answers=$($answers2 | ConvertTo-Json -Compress) prompt_failed=$($pf2.Count) window=$($w2 | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
    $fail++
}

# --- Gate 4: wait after examine -- no stale nested answer (zero nested events in its window). ---
$w3 = Get-DispatchWindow -Events $evA -StepIndex 2
$nested3 = @($w3.Between | Where-Object { $_.event -like 'nested_input_*' })
$g4 = ($respA[3].ok -eq $true) -and $w3 -and ($w3.Command.command -eq 'wait') -and ($nested3.Count -eq 0)
if( $g4 ) {
    Write-Host "  PASS: wait after examine -- ok, zero nested_input events in its dispatch window (no stale answer)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: wait after examine -- resp=$($respA[3] | ConvertTo-Json -Compress) nested=$($nested3 | ConvertTo-Json -Compress)" -ForegroundColor Red
    $fail++
}

# --- Gate 5: malformed probes are recoverable -- ok:false unsupported_command, session continues.
# (Error responses nest the code under .error, protocol v1 shape.) ---
$g5 = ($respA[4].ok -eq $false) -and ($respA[4].error.code -eq 'unsupported_command') -and
      ($respA[5].ok -eq $false) -and ($respA[5].error.code -eq 'unsupported_command') -and
      ($respA[7].ok -eq $true)
if( $g5 ) {
    Write-Host "  PASS: bad examine probes -- missing direction and move_up both ok:false unsupported_command; the session keeps serving (move_s at id7 succeeds, even across the recoverable move_n fail-loud at id6)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: bad examine probes -- missing=$($respA[4] | ConvertTo-Json -Compress) vertical=$($respA[5] | ConvertTo-Json -Compress) move_s(id7)=$($respA[7].ok)" -ForegroundColor Red
    $fail++
}

# --- Gate 6 (Spike 21): move_n into the NPC now FAILS LOUD (ok=false / unexpected_prompt, recoverable);
# move_s still moves [0,1]. The failed move_n writes no snapshot, so move_s's delta is measured from the
# start snapshot (the avatar did not move across examine/wait/move_n -- only move_s does). ---
$snapMoved = Read-Snapshot -Dir $A.Dir -Name $respA[7].snapshot
$deltaMove = @(0, 0, 0)
if( $snapStart -and $snapMoved ) {
    $deltaMove = @(0, 1) | ForEach-Object { $snapMoved.avatar.pos_abs[$_] - $snapStart.avatar.pos_abs[$_] }
}
$g6 = ($respA[6].ok -eq $false) -and ($respA[6].error.code -eq 'unexpected_prompt') -and
      $snapStart -and $snapMoved -and (($deltaMove -join ',') -eq '0,1')
if( $g6 ) {
    Write-Host "  PASS: Spike 21 baseline -- move_n into the NPC fails loud (unexpected_prompt, recoverable, no snapshot); move_s moved [0,1] from start." -ForegroundColor Green
} else {
    Write-Host "  FAIL: baseline -- move_n.ok=$($respA[6].ok) move_n.code=$($respA[6].error.code) move_s_delta=$($deltaMove -join ',') (expected false / unexpected_prompt / 0,1)." -ForegroundColor Red
    $fail++
}

# --- Gate 7: the pickup-tail guard witness. Prereq FIRST: the tile one south of the avatar (after
# move_s) must actually hold ground items -- if the fixture changed, fail EXPLICITLY rather than
# silently testing something else. Then: examine move_s completes, the chooser consumed the answer,
# the raw PICKUP loop was guard-cancelled with QUIT, and NO items were taken. ---
# Each element fully parenthesized: an unparenthesized `[int]$x[1] + 1` inside @() mis-parses into
# extra array elements (observed: a 4-element "tile").
$southTile = @(
    ( [int]$snapMoved.avatar.pos_local[0] ),
    ( [int]$snapMoved.avatar.pos_local[1] + 1 ),
    ( [int]$snapMoved.avatar.pos_local[2] )
)
$itemsBefore = Get-ItemCountAt -Snapshot $snapMoved -PosLocal $southTile
if( $itemsBefore -lt 1 ) {
    Write-Host "  FAIL: fixture witness not found: no item pile adjacent south of the avatar after move_s (expected the doc-25 evac_pamphlet witness at pos_local $($southTile -join ','))." -ForegroundColor Red
    $fail++
} else {
    # step_index is the backend's ACCEPTED-request counter: the two rejected probes (ids 4/5) never
    # incremented it, so examine_items is step 5 (start=0, examine_npc=1, wait=2, move_n=3, move_s=4).
    $w8 = Get-DispatchWindow -Events $evA -StepIndex 5
    $snapItems = Read-Snapshot -Dir $A.Dir -Name $respA[8].snapshot
    $answers8 = @($w8.Between | Where-Object { $_.event -eq 'nested_input_answer' })
    $guards8 = @($w8.Between | Where-Object { $_.event -eq 'nested_input_guard' })
    $itemsAfter = Get-ItemCountAt -Snapshot $snapItems -PosLocal $southTile
    $g7 = ($respA[8].ok -eq $true) -and $w8 -and ($answers8.Count -eq 1) -and
          ($answers8[0].action -eq 'DOWN') -and ($answers8[0].context -eq 'DEFAULTMODE') -and
          ($guards8.Count -ge 1) -and ($guards8[0].context -eq 'PICKUP') -and
          ($guards8[0].action -eq 'QUIT') -and ($guards8[0].reason -eq 'no_answer') -and
          ($itemsAfter -eq $itemsBefore)
    if( $g7 ) {
        Write-Host "  PASS: examine move_s (item pile, $itemsBefore items) -- answer DOWN served, PICKUP loop guard-cancelled (QUIT/no_answer), items untouched." -ForegroundColor Green
    } else {
        Write-Host "  FAIL: examine move_s (items) -- resp=$($respA[8] | ConvertTo-Json -Compress) answers=$($answers8 | ConvertTo-Json -Compress) guards=$($guards8 | ConvertTo-Json -Compress) items_before=$itemsBefore items_after=$itemsAfter" -ForegroundColor Red
        $fail++
    }
}

# --- Gate 8: the session stays usable after the guard -- wait ticks the world, then a clean quit
# with a final snapshot. ---
$snapWait2 = Read-Snapshot -Dir $A.Dir -Name $respA[9].snapshot
$quitResp = @($A.Result.responses)[-1]
$finalSnap = Get-ChildItem $A.Dir -Filter "*_final.json" -ErrorAction SilentlyContinue
$g8 = ($respA[9].ok -eq $true) -and $snapWait2 -and ($snapWait2.backend.turn -gt $snapStart.backend.turn) -and
      ($quitResp.op -eq 'quit') -and ($quitResp.status -eq 'session_end') -and
      ($null -ne $finalSnap) -and (Test-Path (Join-Path $A.Dir "session.jsonl"))
if( $g8 ) {
    Write-Host "  PASS: post-guard wait ticked (turn $($snapWait2.backend.turn)), quit answered, final snapshot + transcript present." -ForegroundColor Green
} else {
    Write-Host "  FAIL: tail -- wait=$($respA[9] | ConvertTo-Json -Compress) quit=$($quitResp | ConvertTo-Json -Compress) final=$($null -ne $finalSnap)" -ForegroundColor Red
    $fail++
}

# --- Gate 8b (DIAGONAL): examine move_sw must serve the DIAGONAL chooser action string "LEFTDOWN"
# (south_west) to the engine's own DEFAULTMODE chooser -- proving the backend mirrors the FULL
# 8-direction GUI examine chooser, not a cardinal-only subset. SW of the avatar (after move_s) is an
# f_cupboard with no items (witness prereq asserted), so there is no pickup tail and no guard event;
# the served diagonal answer either examines the cupboard or is filtered as out-of-set, both a faithful
# no-state-change outcome. step_index 6 = accepted-request counter (export0, examine_npc1, wait2,
# move_n3, move_s4, examine_s5, wait6, examine_sw7) -> the diagonal is step 7. ---
$swTile = @(
    ( [int]$snapMoved.avatar.pos_local[0] - 1 ),
    ( [int]$snapMoved.avatar.pos_local[1] + 1 ),
    ( [int]$snapMoved.avatar.pos_local[2] )
)
$swFurn = ($snapMoved.tiles | Where-Object {
    $_.x -eq $swTile[0] -and $_.y -eq $swTile[1] -and $_.z -eq $swTile[2] } | Select-Object -First 1).furn
if( $swFurn -ne 'f_cupboard' ) {
    Write-Host "  FAIL: fixture witness not found: expected f_cupboard diagonally SW of the avatar at pos_local $($swTile -join ',') (got '$swFurn')." -ForegroundColor Red
    $fail++
} else {
    $wDiag = Get-DispatchWindow -Events $evA -StepIndex 7
    $ansDiag = @($wDiag.Between | Where-Object { $_.event -eq 'nested_input_answer' })
    $guardDiag = @($wDiag.Between | Where-Object { $_.event -eq 'nested_input_guard' })
    $gDiag = ($respA[10].ok -eq $true) -and $wDiag -and ($wDiag.Command.command -eq 'examine') -and
             ($wDiag.Command.direction -eq 'move_sw') -and ($wDiag.Command.action_id -eq 'examine') -and
             ($ansDiag.Count -eq 1) -and ($ansDiag[0].context -eq 'DEFAULTMODE') -and
             ($ansDiag[0].direction -eq 'move_sw') -and ($ansDiag[0].action -eq 'LEFTDOWN') -and
             ($guardDiag.Count -eq 0)
    if( $gDiag ) {
        Write-Host "  PASS: examine move_sw (diagonal) -- served 'LEFTDOWN' (south_west) to the DEFAULTMODE chooser; the full 8-direction vocabulary reaches the real engine chooser, no hang." -ForegroundColor Green
    } else {
        Write-Host "  FAIL: examine move_sw (diagonal) -- resp=$($respA[10] | ConvertTo-Json -Compress) cmd=$($wDiag.Command | ConvertTo-Json -Compress) answers=$($ansDiag | ConvertTo-Json -Compress) guards=$($guardDiag | ConvertTo-Json -Compress)" -ForegroundColor Red
        $fail++
    }
}

# --- Gate 11: the engine's own MESSAGE stream corroborates the item-examine path -- a second witness
# chain, independent of the backend's transcript events. The item examine adds EXACTLY two messages, in
# order: iexamine::none's "That is a %s." (iexamine.cpp:255 -- proof the examine actor really ran on the
# chosen tile) and the pickup UI's own cancel "Never mind." (pickup.cpp:1177 -- the engine's real ESC path
# answering the guard's QUIT). And "Never mind." appears NOWHERE before the item examine (no hidden chooser
# cancel) and nothing further after it. (Spike 21: the NPC-examine message witness is GONE -- examine
# move_n now fails loud and writes no snapshot; the only snapshots before the item examine are start /
# after_examine_wait / move_s, and the npc_menu uilist fail-loud is message-silent.) ---
$snapExWait = Read-Snapshot -Dir $A.Dir -Name $respA[3].snapshot
$msgMoved = Get-MessageTexts $snapMoved
$msgItems = Get-MessageTexts $snapItems
$msgWait2 = Get-MessageTexts $snapWait2
$newItemMsgs = @( if( $msgItems.Count -ge 2 ) { $msgItems[-2..-1] } )
$preItemNeverMind = @(((Get-MessageTexts $snapStart) + (Get-MessageTexts $snapExWait) + $msgMoved) |
    Where-Object { $_ -eq 'Never mind.' }).Count
$itemNeverMind = @($msgItems | Where-Object { $_ -eq 'Never mind.' }).Count
$g11 = ($msgItems.Count -eq ($msgMoved.Count + 2)) -and
       ($newItemMsgs.Count -eq 2) -and ($newItemMsgs[0] -like 'That is a *') -and
       ($newItemMsgs[1] -eq 'Never mind.') -and
       ($preItemNeverMind -eq 0) -and ($itemNeverMind -eq 1) -and
       ($msgWait2.Count -eq $msgItems.Count)
if( $g11 ) {
    Write-Host "  PASS: engine message stream -- item examine added exactly '$($newItemMsgs[0])' + 'Never mind.' (the pickup UI's own cancel); no 'Never mind.' anywhere earlier." -ForegroundColor Green
} else {
    Write-Host "  FAIL: engine message stream -- items=$($msgItems.Count)/$($msgMoved.Count)+2 new=$($newItemMsgs -join ' || ') preNeverMind=$preItemNeverMind itemNeverMind=$itemNeverMind wait=$($msgWait2.Count)" -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario B (AUTOSELECT=true -- the engine default): the same examine must stay hang-free, and the
# armed answer must be fully accounted for (served, or force-cleared as nested_input_unconsumed
# when the engine skips its chooser). The exact branch is fixture truth, pinned below from the
# observed run; both branches are correct engine behavior under this config.
# =============================================================================
Set-SandboxAutoselect -Value $true
$reqB = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"examine","direction":"move_n","name":"examine_npc_autoselect"}',
    '{"id":3,"op":"command","command":"wait","name":"after_wait"}',
    '{"id":4,"op":"quit"}'
)
$B = Invoke-LiveScenario -Name "autoselect_on" -RequestLines $reqB

# --- Gate 9: no deadlock under autoselect=true; session_start records true. ---
$evB = Read-Transcript -Dir $B.Dir
$startB = $evB | Where-Object { $_.event -eq 'session_start' } | Select-Object -First 1
$g9 = ($B.ExitCode -eq 0) -and $B.Result -and $B.Result.ok -and ($B.Result.exit_code -eq 0) -and
      (@($B.Result.responses).Count -eq 4) -and $startB -and
      ($startB.autoselect_single_valid_target -eq $true)
if( $g9 ) {
    Write-Host "  PASS: scenario B -- autoselect=true recorded, 4 responses in time, backend exit 0." -ForegroundColor Green
} else {
    Write-Host "  FAIL: scenario B driver -- exit=$($B.ExitCode) result=$($B.Result | ConvertTo-Json -Compress -Depth 3) stderr: $($B.Stderr)" -ForegroundColor Red
    $fail++
}

# --- Gate 10 (Spike 21): under autoselect=true the engine auto-selects the NPC tile (the ONLY valid
# adjacent examine target), so the chooser never asks and the armed answer is force-cleared as
# `nested_input_unconsumed` -- and the engine then opens game::npc_menu's UNARMED uilist, which now FAILS
# LOUD: ok=false / unexpected_prompt (RECOVERABLE). So the step's span carries BOTH a prompt_failed AND the
# force-cleared answer (the auto-select branch is what makes it unconsumed, not served). The failed examine
# writes no snapshot, so its window is found by Get-CommandSpan, not Get-DispatchWindow. ---
$g10 = $false
$respB2 = $null
$wB = $null
if( $B.Result -and (@($B.Result.responses).Count -ge 2) ) {
    $respB2 = @($B.Result.responses) | Where-Object { $_.id -eq 2 } | Select-Object -First 1
    $wB = Get-CommandSpan -Events $evB -StepIndex 1
    $aB = @($wB.Between | Where-Object { $_.event -eq 'nested_input_answer' })
    $uB = @($wB.Between | Where-Object { $_.event -eq 'nested_input_unconsumed' })
    $pfB = @($wB.Between | Where-Object { $_.event -eq 'prompt_failed' -and $_.reason -eq 'unexpected_prompt' })
    $g10 = ($respB2.ok -eq $false) -and ($respB2.error.code -eq 'unexpected_prompt') -and $wB -and
           ($aB.Count -eq 0) -and ($uB.Count -eq 1) -and ($uB[0].reason -eq 'command_completed') -and
           ($uB[0].direction -eq 'move_n') -and ($uB[0].action -eq 'UP') -and ($pfB.Count -eq 1)
    if( $g10 ) {
        Write-Host "  PASS: examine under autoselect=true -- engine auto-selected (chooser skipped, armed answer force-cleared as nested_input_unconsumed), then the unarmed NPC menu failed loud (ok=false / unexpected_prompt + prompt_failed). See doc 43." -ForegroundColor Green
    }
}
if( -not $g10 ) {
    Write-Host "  FAIL: examine under autoselect=true -- resp=$($respB2 | ConvertTo-Json -Compress) window=$($wB | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
    $fail++
}

# --- Gate 12 (Spike 21): the autoselect fail-loud examine is RECOVERABLE -- the session keeps serving (the
# follow-up wait succeeds) and quits cleanly with session_end ok. (The old message-stream check needed the
# examine's snapshot, which a fail-loud examine does not write.) ---
$respB3 = if( $B.Result ) { @($B.Result.responses) | Where-Object { $_.id -eq 3 } | Select-Object -First 1 } else { $null }
$quitB = if( $B.Result ) { @($B.Result.responses)[-1] } else { $null }
$endB = $evB | Where-Object { $_.event -eq 'session_end' } | Select-Object -First 1
$g12 = ($null -ne $respB3) -and ($respB3.ok -eq $true) -and ($quitB.op -eq 'quit') -and
       ($endB.status -eq 'ok')
if( $g12 ) {
    Write-Host "  PASS: autoselect fail-loud is recoverable -- the follow-up wait succeeded and the session quit cleanly (session_end ok)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: autoselect recoverability -- wait(id3)=$($respB3 | ConvertTo-Json -Compress) quit=$($quitB | ConvertTo-Json -Compress) end=$($endB | ConvertTo-Json -Compress)." -ForegroundColor Red
    $fail++
}

# =============================================================================
# Scenario C (SPIKE 21 -- vehicle "Select an action" uilist fails loud): `examine move_s` of the
# ArcopolisVehicleCargoTest cart tile (the folding_wagon one tile south of the post-move_s avatar; built by
# docs/arcopolis/make_vehicle_fixture.py). game::examine routes a vehicle tile to vehicle::interact_with,
# which RETURNS before the pickup tail and opens its OWN unarmed uilist selectmenu ("Select an action" --
# EXAMINE + TRACK are unconditional so it is always >=2 entries and calls query()). examine arms only the
# query_popup transaction, so this uilist is UNARMED and now FAILS LOUD (Spike 21). Witnessed in BOTH modes.
# Closes the doc 43 §10 "fail-loud-by-guard yet ungated" gap. AUTOSELECT=false so the live chooser is asked
# and the armed move_s answer (DOWN) is served (matching scenario A's served-chooser shape).
# =============================================================================
Set-SandboxAutoselect -Value $false

# --- Gate 13 (NON-LIVE, exit 14): a run-script `export before -> move_s -> examine move_s -> export
# after_examine` aborts AT the examine (the vehicle uilist fails loud): EXIT 14, `before` written, NO
# `after_examine` snapshot (the failed command writes none), and EXACTLY ONE transcript error event
# (kind=unexpected_prompt) -- one report from query(), none from init(). ---
$vehScript = @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move",    "direction": "move_s" },
  { "op": "command", "command": "examine", "direction": "move_s" },
  { "op": "export",  "name": "after_examine" }
] }
'@
$vc = Invoke-ExamineRunScript -Name "vehicle_examine_failloud" -ScriptBody $vehScript -ScenarioWorld $VehicleWorld
$vcBefore = ($vc.Snaps | Where-Object { $_.File -like '*_before.json' }        | Select-Object -First 1)
$vcAfter  = ($vc.Snaps | Where-Object { $_.File -like '*_after_examine.json' } | Select-Object -First 1)
$vcErr    = @($vc.Events | Where-Object { $_.event -eq 'error' })
$vcUnexp  = @($vcErr | Where-Object { $_.kind -eq 'unexpected_prompt' })
$g13 = ($vc.ExitCode -eq 14) -and $vcBefore -and (-not $vcAfter) -and
       ($vcErr.Count -eq 1) -and ($vcUnexp.Count -eq 1)
if( $g13 ) {
    Write-Host "  PASS: vehicle examine non-live fail-loud -- examine move_s on the cart tile exited 14, 'before' written, NO 'after_examine' snapshot, exactly one unexpected_prompt error event. See doc 43 §2/§10." -ForegroundColor Green
} else {
    if( $vc.ExitCode -ne 14 ) { Write-Host "  FAIL: vehicle examine run exited $($vc.ExitCode) (expected 14 / unexpected_prompt). stderr: $(Get-Content (Join-Path $vc.Dir 'stderr.txt') -Raw -ErrorAction SilentlyContinue)" -ForegroundColor Red }
    if( -not $vcBefore )       { Write-Host "  FAIL: no 'before' snapshot in the vehicle fail-loud run (it should be written before examine fails)." -ForegroundColor Red }
    if( $vcAfter )             { Write-Host "  FAIL: an 'after_examine' snapshot exists (the failed examine must not produce a success snapshot)." -ForegroundColor Red }
    if( $vcErr.Count -ne 1 -or $vcUnexp.Count -ne 1 ) { Write-Host "  FAIL: expected exactly ONE error event (kind=unexpected_prompt); got $($vcErr.Count) error event(s), $($vcUnexp.Count) unexpected_prompt." -ForegroundColor Red }
    $fail++
}

# --- Gate 14 (LIVE, recoverable ok=false): the SAME examine in a persistent --arcopolis-live session is a
# RECOVERABLE failure. The chooser answer (DOWN) is STILL served to the DEFAULTMODE chooser, then the
# vehicle uilist fails loud (ok=false / unexpected_prompt + prompt_failed) and NO snapshot is written;
# unlike the item-pile examine (gate 7) there is NO PICKUP guard (the vehicle branch returns before the
# pickup tail). The session keeps serving: the follow-up wait succeeds and the session quits cleanly. The
# failed examine writes no export, so its window is found by Get-CommandSpan (bounded by the next command). ---
$reqC = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"command","command":"examine","direction":"move_s","name":"examine_vehicle"}',
    '{"id":4,"op":"command","command":"wait","name":"still_usable"}',
    '{"id":5,"op":"quit"}'
)
$C = Invoke-LiveScenario -Name "vehicle_examine_live" -RequestLines $reqC -ScenarioWorld $VehicleWorld
$evC = Read-Transcript -Dir $C.Dir
$respC = @{}
foreach( $r in @($C.Result.responses) ) { if( $null -ne $r.id ) { $respC[[int]$r.id] = $r } }
# step_index 2 = the examine (accepted-request counter: start=0, move_s=1, examine=2).
$wC = Get-CommandSpan -Events $evC -StepIndex 2
$ansC = @($wC.Between | Where-Object { $_.event -eq 'nested_input_answer' })
$guardC = @($wC.Between | Where-Object { $_.event -eq 'nested_input_guard' })
$unconC = @($wC.Between | Where-Object { $_.event -eq 'nested_input_unconsumed' })
$pfC = @($wC.Between | Where-Object { $_.event -eq 'prompt_failed' -and $_.reason -eq 'unexpected_prompt' })
$endC = $evC | Where-Object { $_.event -eq 'session_end' } | Select-Object -First 1
$quitC = if( $C.Result ) { @($C.Result.responses)[-1] } else { $null }
$g14 = ($C.ExitCode -eq 0) -and $C.Result -and $C.Result.ok -and ($C.Result.exit_code -eq 0) -and
       ($respC[3].ok -eq $false) -and ($respC[3].error.code -eq 'unexpected_prompt') -and
       $wC -and ($wC.Command.command -eq 'examine') -and ($wC.Command.direction -eq 'move_s') -and
       ($wC.Command.action_id -eq 'examine') -and ($ansC.Count -eq 1) -and
       ($ansC[0].context -eq 'DEFAULTMODE') -and ($ansC[0].direction -eq 'move_s') -and
       ($ansC[0].action -eq 'DOWN') -and ($guardC.Count -eq 0) -and ($unconC.Count -eq 0) -and
       ($pfC.Count -eq 1) -and ($respC[4].ok -eq $true) -and ($quitC.op -eq 'quit') -and
       ($endC.status -eq 'ok')
if( $g14 ) {
    Write-Host "  PASS: vehicle examine live fail-loud -- examine move_s served DOWN to the DEFAULTMODE chooser, then the unarmed vehicle uilist failed loud (ok=false / unexpected_prompt + prompt_failed), NO pickup guard (vehicle branch returns before the pickup tail); recoverable -- the follow-up wait succeeded and the session quit cleanly. See doc 43 §2/§10." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle examine live -- exit=$($C.ExitCode) examineResp=$($respC[3] | ConvertTo-Json -Compress) answers=$($ansC | ConvertTo-Json -Compress) guards=$($guardC.Count) unconsumed=$($unconC.Count) prompt_failed=$($pfC.Count) wait=$($respC[4].ok) quit=$($quitC | ConvertTo-Json -Compress) end=$($endC | ConvertTo-Json -Compress)" -ForegroundColor Red
    $fail++
}

if( $fail -gt 0 ) { Write-Host "EXAMINE REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "EXAMINE REGRESSION: ok." -ForegroundColor Green
exit 0
