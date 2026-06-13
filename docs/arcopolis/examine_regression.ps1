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
#   - the existing move/wait behavior is unchanged (move_n blocked by the shelter NPC, move_s moves,
#     wait ticks), no stale nested answer leaks into a later command, and the session ends with a
#     quit response + final snapshot + session_end "ok" + process exit 0,
#   - under the deployment default AUTOSELECT_SINGLE_VALID_TARGET=true (scenario B) the same examine
#     stays hang-free and the armed answer is accounted for (served or force-cleared as
#     `nested_input_unconsumed` -- the engine may skip its chooser entirely).
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
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_examine_regress",
    [string]$Driver     = "docs\arcopolis\examine_live_driver.py",
    [string]$HarnessDir = "tools\arcopolis_client",
    [double]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"

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
    Stop-WithCode "Fixture source directory not found: $FixtureSrc" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
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

function Read-Snapshot {
    param([string]$Dir, [string]$Name)
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
    '{"id":10,"op":"quit"}'
)
$A = Invoke-LiveScenario -Name "autoselect_off" -RequestLines $reqA

# --- Gate 1: no deadlock -- every response arrived in time, backend exited 0. ---
$g1 = ($A.ExitCode -eq 0) -and $A.Result -and $A.Result.ok -and $A.Result.ready_seen -and
      ($A.Result.protocol_version -eq 1) -and ($A.Result.exit_code -eq 0) -and
      (@($A.Result.responses).Count -eq 10)
if( $g1 ) {
    Write-Host "  PASS: scenario A -- 10 responses under the $TimeoutSec s per-response timeout, ready seen, backend exit 0." -ForegroundColor Green
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

# --- Gate 3: examine toward the NPC -- ok response, command event action_id "examine", the armed
# answer served to the DEFAULTMODE chooser, the NPC menu auto-cancelled (no guard event needed),
# avatar did not move, no time passed (a zero-cost cancelled interaction). ---
$w2 = Get-DispatchWindow -Events $evA -StepIndex 1
$snapStart = Read-Snapshot -Dir $A.Dir -Name $respA[1].snapshot
$snapNpc = Read-Snapshot -Dir $A.Dir -Name $respA[2].snapshot
$answers2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_answer' })
$guards2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_guard' })
$unconsumed2 = @($w2.Between | Where-Object { $_.event -eq 'nested_input_unconsumed' })
$g3 = ($respA[2].ok -eq $true) -and $w2 -and ($w2.Command.command -eq 'examine') -and
      ($w2.Command.direction -eq 'move_n') -and ($w2.Command.action_id -eq 'examine') -and
      ($answers2.Count -eq 1) -and ($answers2[0].context -eq 'DEFAULTMODE') -and
      ($answers2[0].direction -eq 'move_n') -and ($answers2[0].action -eq 'UP') -and
      ($guards2.Count -eq 0) -and ($unconsumed2.Count -eq 0) -and
      $snapStart -and $snapNpc -and
      (($snapNpc.avatar.pos_abs -join ',') -eq ($snapStart.avatar.pos_abs -join ',')) -and
      ($snapNpc.backend.turn -eq $snapStart.backend.turn)
if( $g3 ) {
    Write-Host "  PASS: examine move_n (NPC) -- action_id examine, answer UP served to DEFAULTMODE, npc menu auto-cancelled, no move, no tick." -ForegroundColor Green
} else {
    Write-Host "  FAIL: examine move_n (NPC) -- resp=$($respA[2] | ConvertTo-Json -Compress) window=$($w2 | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
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
      ($respA[6].ok -eq $true)
if( $g5 ) {
    Write-Host "  PASS: bad examine probes -- missing direction and move_up both ok:false unsupported_command; next command still served." -ForegroundColor Green
} else {
    Write-Host "  FAIL: bad examine probes -- missing=$($respA[4] | ConvertTo-Json -Compress) vertical=$($respA[5] | ConvertTo-Json -Compress) next=$($respA[6].ok)" -ForegroundColor Red
    $fail++
}

# --- Gate 6: existing move/wait behavior unchanged -- move_n blocked (NPC), move_s moved [0,1,0]. ---
$snapBlocked = Read-Snapshot -Dir $A.Dir -Name $respA[6].snapshot
$snapMoved = Read-Snapshot -Dir $A.Dir -Name $respA[7].snapshot
$deltaMove = @(0, 0, 0)
if( $snapBlocked -and $snapMoved ) {
    $deltaMove = @(0, 1) | ForEach-Object { $snapMoved.avatar.pos_abs[$_] - $snapBlocked.avatar.pos_abs[$_] }
}
$g6 = $snapBlocked -and $snapMoved -and
      (($snapBlocked.avatar.pos_abs -join ',') -eq ($snapNpc.avatar.pos_abs -join ',')) -and
      (($deltaMove -join ',') -eq '0,1')
if( $g6 ) {
    Write-Host "  PASS: baseline unchanged -- move_n blocked by the shelter NPC (no move), move_s moved [0,1]." -ForegroundColor Green
} else {
    Write-Host "  FAIL: baseline -- blocked_pos=$($snapBlocked.avatar.pos_abs -join ',') moved_pos=$($snapMoved.avatar.pos_abs -join ',') (vs npc_pos=$($snapNpc.avatar.pos_abs -join ','))" -ForegroundColor Red
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
$g8 = ($respA[9].ok -eq $true) -and $snapWait2 -and ($snapWait2.backend.turn -gt $snapNpc.backend.turn) -and
      ($quitResp.op -eq 'quit') -and ($quitResp.status -eq 'session_end') -and
      ($null -ne $finalSnap) -and (Test-Path (Join-Path $A.Dir "session.jsonl"))
if( $g8 ) {
    Write-Host "  PASS: post-guard wait ticked (turn $($snapWait2.backend.turn)), quit answered, final snapshot + transcript present." -ForegroundColor Green
} else {
    Write-Host "  FAIL: tail -- wait=$($respA[9] | ConvertTo-Json -Compress) quit=$($quitResp | ConvertTo-Json -Compress) final=$($null -ne $finalSnap)" -ForegroundColor Red
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

# --- Gate 10: the armed answer is accounted for under autoselect. PINNED from observed fixture
# truth (first validated run, 2026-06-12): at spawn the shelter NPC's tile is the ONLY valid
# adjacent examine target, so the engine auto-selects it, the chooser never asks, and the armed
# answer is force-cleared as `nested_input_unconsumed` -- the doc-25 stale-slot class, witnessed
# live. (If the fixture world changes this gate documents what to re-pin.) ---
$g10 = $false
$respB2 = $null
$wB = $null
if( $B.Result -and (@($B.Result.responses).Count -ge 2) ) {
    $respB2 = @($B.Result.responses) | Where-Object { $_.id -eq 2 } | Select-Object -First 1
    $wB = Get-DispatchWindow -Events $evB -StepIndex 1
    $aB = @($wB.Between | Where-Object { $_.event -eq 'nested_input_answer' })
    $uB = @($wB.Between | Where-Object { $_.event -eq 'nested_input_unconsumed' })
    $g10 = ($respB2.ok -eq $true) -and $wB -and ($aB.Count -eq 0) -and ($uB.Count -eq 1) -and
           ($uB[0].reason -eq 'command_completed') -and ($uB[0].direction -eq 'move_n') -and
           ($uB[0].action -eq 'UP')
    if( $g10 ) {
        Write-Host "  PASS: examine under autoselect=true -- ok, no hang, engine auto-selected (prompt skipped) and the armed answer was force-cleared as nested_input_unconsumed." -ForegroundColor Green
    }
}
if( -not $g10 ) {
    Write-Host "  FAIL: examine under autoselect=true -- resp=$($respB2 | ConvertTo-Json -Compress) window=$($wB | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
    $fail++
}

if( $fail -gt 0 ) { Write-Host "EXAMINE REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "EXAMINE REGRESSION: ok." -ForegroundColor Green
exit 0
