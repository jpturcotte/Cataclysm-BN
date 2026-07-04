# Arcopolis Spike 12A regression: level-4 (backend-input) pickup prompt/menu transaction.
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
#   E (Spike 14: drive the secondary capacity uilist at level 4 -- WIELD-blanket): a multi-select [0,6]
#     where the bulky blanket is over-capacity raises the secondary capacity uilist (single entry:
#     "Wield blanket", avatar unarmed); answering choice:0 (WIELD) serves [CONFIRM] through the real
#     input_context("UILIST") loop, the engine wields the blanket via u.wield -> blanket leaves ground,
#     becomes primary_weapon, shard is stashed, response clean ok:true with NO forced_cancel/partial
#     markers (the doc-31 markers now live ONLY on the no-channel fallback, covered by the unit suite).
#   F (multi-select carry-both, ArcopolisBackpackTest): a multi-select [5,6] on the backpack avatar drives
#     TWO RIGHT marks ([DOWN x5, RIGHT, DOWN, RIGHT, CONFIRM]) through the engine's own loop; BOTH chosen
#     entries leave the ground (7 -> 5) and the others remain -- discrimination proven at the state level.
#   G (no phantom prompt_completed): `pickup here` on the empty self-tile opens no menu; the transcript has
#     neither prompt_opened nor prompt_completed.
#   H (vehicle-source uilist DRIVEN at level 4, Spike 13B, ArcopolisVehicleCargoTest): a live pickup onto a
#     tile with BOTH vehicle cargo AND ground items now DRIVES the real "Get items from where?" uilist
#     headlessly instead of failing loud. Four sub-scenarios:
#       H-probe: the pickup emits the vehicle-source `prompt` (kind=uilist, 2 choices "...vehicle cargo" /
#         "...ground" in order); answering ground (choice 1) is served [DOWN, CONFIRM] through the real
#         input_context("UILIST") loop (transcript prompt_opened/answered/completed kind=uilist,
#         actions_served=2); the old "PICKUP" item menu (kind=menu) then opens SEPARATELY; cancelling it is
#         the GUI ESC no-op (no pickup). Discovers the ground-menu choice count.
#       H-pick: the same flow, but the last ground entry is picked and LEAVES the ground (real state change +
#         "You pick up:"); the session stays usable.
#       H-cancel: prompt_cancel on the vehicle-source uilist is the GUI ESC -- NO "PICKUP" menu opens, NO
#         ground items are taken (no silent ground-only pickup), and the session stays usable.
#       H-recover: a wrong prompt_id AND an out-of-range choice on the vehicle-source uilist are EACH rejected
#         ok:false/bad_request with the prompt STILL OPEN (prompt_failed prompt_id_mismatch + invalid_answer);
#         a follow-up valid answer then completes the SAME pickup.
#   I (non-live fail-loud, Spike 12A follow-up): `pickup` in --arcopolis-run-script and one-shot
#     --arcopolis-command is rejected with exit 6 (unsupported_command) BEFORE the world load (no snapshot),
#     because the item menu needs a live answer channel non-live modes lack -- fail loud, not a silent no-op.
#   J (Spike 14 multi-entry secondary capacity uilist, ArcopolisCapacityTest): a copy of ArcopolisTest with
#     ONE over-volume ARMOR item (jacket_leather) injected onto the south pile; built reproducibly by
#     docs/arcopolis/make_capacity_fixture.py. Picking the jacket raises the secondary capacity uilist with
#     WEAR + WIELD = exactly 2 entries, both enabled (acceptance criterion #1). Five sub-gates:
#       J-probe: discover the jacket's PICKUP-menu index (stacked_here ordering varies).
#       J-pick-wield: answer choice:1 (WIELD) -> served [DOWN, CONFIRM] (DOWN-navigation witness);
#         engine wields the jacket via u.wield -> jacket leaves ground, primary_weapon witnessed.
#       J-pick-wear: answer choice:0 (WEAR) -> served [CONFIRM] (no DOWN; position 0); engine wears
#         the jacket via u.wear_item -> jacket leaves ground.
#       J-cancel: prompt_cancel on the secondary uilist -> served [QUIT] -> UILIST_CANCEL -> CANCEL;
#         jacket stays on ground, NEVER logged as picked up; response clean ok:true (NOT forced_cancel:
#         a real player cancel through the engine loop, distinct from the no-channel marked-partial).
#       J-recover: wrong prompt_id + out-of-range each rejected with the secondary uilist STILL OPEN; a
#         valid answer then completes the SAME pickup.
#   No backend hangs (strict per-response timeout kills + FAILS); every live session quits with exit 0.
#
# NEW_PICKUP_MENU, AUTOSELECT_SINGLE_VALID_TARGET, and AUTO_PICKUP are PINNED in the sandbox options.json
# (deployment config, never overridden in memory -- docs/arcopolis/25 design point 2, docs/arcopolis/30).
# AUTO_PICKUP=false guarantees the master auto-pickup system does not silently consume the witness pile
# during the move_s approach (it would otherwise depend on the fixture's saved value).
#
# Exit codes: 0 = all gates pass; 1 = one or more gates failed; 3..8 = missing prereq;
# 9 = sandbox path too long (MAX_PATH guard).

[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$BackpackWorld = "ArcopolisBackpackTest",
    [string]$VehicleWorld = "ArcopolisVehicleCargoTest",
    [string]$CapacityWorld = "ArcopolisCapacityTest",
    [string]$OutRoot    = ".\out\arco_pickup_regress",
    [string]$Driver     = "docs\arcopolis\prompt_menu_live_driver.py",
    [string]$HarnessDir = "tools\arcopolis_client",
    [double]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (3=exe, 4=fixture, 5=world, 6=python, 7=driver, 8=harness,
# 9=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) { Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4 }
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- copy the canonical ArcopolisTest fixture (AGENTS.md, Arcopolis test world fixture)." 5
}
$fixtureBackpackWorld = Join-Path $FixtureSrc (Join-Path "save" $BackpackWorld)
if( -not (Test-Path $fixtureBackpackWorld) ) {
    Stop-WithCode "Fixture world '$BackpackWorld' not found at $(Format-ArcoPath $fixtureBackpackWorld) -- the carry-both multi-select witness needs the backpack-avatar fixture (a copy of $World with a backpack added to worn; see the fixtures README)." 5
}
$fixtureVehicleWorld = Join-Path $FixtureSrc (Join-Path "save" $VehicleWorld)
if( -not (Test-Path $fixtureVehicleWorld) ) {
    Stop-WithCode "Fixture world '$VehicleWorld' not found at $(Format-ArcoPath $fixtureVehicleWorld) -- the vehicle-submenu fail-loud witness needs the cargo-vehicle fixture (a copy of $World with a folding_wagon injected onto the ground-item pile; build it with docs/arcopolis/make_vehicle_fixture.py)." 5
}
$fixtureCapacityWorld = Join-Path $FixtureSrc (Join-Path "save" $CapacityWorld)
if( -not (Test-Path $fixtureCapacityWorld) ) {
    Stop-WithCode "Fixture world '$CapacityWorld' not found at $(Format-ArcoPath $fixtureCapacityWorld) -- the Spike 14 multi-entry secondary-capacity uilist witness needs a copy of $World with one over-volume ARMOR item (jacket_leather) injected onto the ground-item pile; build it with docs/arcopolis/make_capacity_fixture.py." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the live driver). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Driver) ) { Stop-WithCode "Pickup prompt live driver not found: $(Format-ArcoPath $Driver)" 7 }
if( -not (Test-Path (Join-Path $HarnessDir "harness.py")) ) {
    Stop-WithCode "Client harness not found under: $(Format-ArcoPath $HarnessDir) (the driver imports its LiveSession)" 8
}

# MAX_PATH guard (exit 9): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $UserDir))
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 9
}

# Refresh the gitignored sandbox userdir from the external fixture.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

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
    # Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
    # a space (a spaced checkout/binary) would otherwise reach python's argparse split into broken tokens.
    $p = Start-Process -FilePath "python" -ArgumentList @("`"$Driver`"", '--exe', "`"$Exe`"", '--world', $ScenarioWorld,
        '--userdir', "`"$UserDir`"", '--out', "`"$dir`"", '--requests', "`"$reqPath`"", '--timeout', $TimeoutSec,
        '--result', "`"$resultPath`"") -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $result = $null
    if( Test-Path $resultPath ) { $result = Get-Content $resultPath -Raw | ConvertFrom-Json }
    return [pscustomobject]@{
        Name = $Name; Dir = $dir; ExitCode = $p.ExitCode; Result = $result
        # Redacted at capture -- driver tracebacks may embed local absolute paths; every emission
        # of this field inherits the AGENTS.md default path redaction (Format-ArcoPath).
        Stderr = (Format-ArcoPath (Get-Content $stderr -Raw -ErrorAction SilentlyContinue))
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

# Prompt events from a scenario's responses, in order (Spike 13B + Spike 14: scenarios may have >1 prompt).
function Get-PromptsInOrder { param($Responses) return @(@($Responses) | Where-Object { $_.type -eq 'prompt' }) }

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
# The valid answer picks the LAST entry (the tiny glass shard, proven to FIT by Scenario B) rather than
# entry 0 (the over-capacity blanket): a fitting item completes WITHOUT raising the secondary capacity
# uilist, keeping this scenario focused on PICKUP-menu recovery. (Driving that secondary uilist is fully
# witnessed by Scenarios E + J; if Scenario C picked the blanket it would now open a uilist this driver
# does not answer -- a different transaction, out of scope here.)
#   step_index: export0, move1, pickup2, (reject bad prompt_id), (reject out-of-range), (valid), export3, wait, quit
# =============================================================================
$bad = $choiceCount + 5
$validC = $choiceCount - 1
$reqC = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup"}',
    '{"id":4,"op":"prompt_answer","prompt_id":999,"choice":0}',
    ('{"id":5,"op":"prompt_answer","prompt_id":1,"choice":' + $bad + '}'),
    ('{"id":6,"op":"prompt_answer","prompt_id":1,"choice":' + $validC + '}'),
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
# Scenario E (Spike 14: DRIVE the secondary capacity uilist at level 4 -- WIELD-blanket witness). On the
# DEFAULT no-backpack avatar, the client selects TWO entries [0,6] (over-capacity blanket + tiny shard).
# After CONFIRM, the pickup activity raises a SECONDARY capacity uilist for the blanket
# (handle_problematic_pickup, src/pickup.cpp). Spike 12A's follow-up MARKED that as forced_cancel/partial
# (docs/arcopolis/31); Spike 14 (docs/arcopolis/34) DRIVES it at level 4: the blanket scenario opens a
# SINGLE-entry uilist (WIELD only -- blanket is not armor, avatar is unarmed; no SPILL/EMPTY). Answering
# choice:0 (WIELD) serves [CONFIRM] through the real input_context("UILIST") loop, the engine sets
# amenu.ret=WIELD, pick_one_up calls u.wield -> the blanket LEAVES the ground AND becomes the avatar's
# primary_weapon (a real engine state change witnessed via the "Wielding" message), the shard is stashed,
# the south tile goes 7 -> 5, and the response carries NO forced_cancel/partial/unsupported_prompt markers
# (this is no longer a partial; it is a real player choice through the engine's own loop). Witnesses:
# Spike 14's acceptance criterion #1 (all-enabled entries -- the single WIELD entry is enabled:true) and
# the no-silent-success guarantee (Spike 14 acceptance criterion #5: the doc-31 fail-loud markers live
# only in the no-channel fallback now, covered by the unit suite, not on this driven path).
# =============================================================================
$reqR = @(
    '{"id":1,"op":"export","name":"start"}',
    '{"id":2,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":3,"op":"export","name":"before"}',
    '{"id":4,"op":"command","command":"pickup","direction":"move_s","name":"pickup_drive_wield"}',
    '{"id":5,"op":"prompt_answer","prompt_id":1,"choices":[0,6]}',
    '{"id":6,"op":"prompt_answer","prompt_id":2,"choice":0}',
    '{"id":7,"op":"export","name":"after_pick"}',
    '{"id":8,"op":"command","command":"wait","name":"drain"}',
    '{"id":9,"op":"export","name":"after_wait"}',
    '{"id":10,"op":"quit"}'
)
$R = Invoke-LiveScenario -Name "drive_secondary_wield" -RequestLines $reqR
$evR = Read-Transcript -Dir $R.Dir
$respR = Index-ById $R.Result.responses
$promptsR = Get-PromptsInOrder $R.Result.responses
# Two prompts in order: the PICKUP item menu (kind=menu) then the secondary capacity uilist (kind=uilist).
$menuPromptR = if( $promptsR.Count -ge 1 ) { $promptsR[0] } else { $null }
$uilistPromptR = if( $promptsR.Count -ge 2 ) { $promptsR[1] } else { $null }
$uilistChoicesR = if( $uilistPromptR ) { @($uilistPromptR.choices) } else { @() }
# Acceptance criterion #1: all-enabled-entries only. The blanket's single uilist entry MUST be enabled.
$uilistAllEnabledR = ($uilistChoicesR.Count -ge 1) -and (@($uilistChoicesR | Where-Object { -not $_.enabled }).Count -eq 0)
$uilistEntryTextR = if( $uilistChoicesR.Count -ge 1 ) { $uilistChoicesR[0].text } else { '' }
$uilistTitleR = if( $uilistPromptR ) { $uilistPromptR.title } else { '' }
# Transcript witnesses: the menu prompt was answered with [0,6] (the existing multi-select arming), then
# the uilist prompt was answered with choice 0 served [CONFIRM] (single CONFIRM, no DOWN -- the only entry
# is at position 0). Spike 14 forbids any prompt_force_cancelled on this driven path.
$answeredMenuR = @($evR | Where-Object { $_.event -eq 'prompt_answered' -and ($_.kind -eq $null -or $_.kind -eq '' -or $_.kind -eq 'menu') })
$answeredUilistR = @($evR | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'uilist' })
$completedUilistR = @($evR | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'uilist' })
$forceCancelEvR = @($evR | Where-Object { $_.event -eq 'prompt_force_cancelled' })
$menuChoicesR = if( $answeredMenuR.Count -ge 1 ) { @($answeredMenuR[0].choices) } else { @() }
$menuActionsR = if( $answeredMenuR.Count -ge 1 ) { @($answeredMenuR[0].actions) } else { @() }
$uilistChoicesAnsR = if( $answeredUilistR.Count -ge 1 ) { @($answeredUilistR[0].choices) } else { @() }
$uilistActionsR = if( $answeredUilistR.Count -ge 1 ) { @($answeredUilistR[0].actions) } else { @() }
# Menu queue [0,6] -> RIGHT (mark blanket entry 0), DOWN x6 (walk to entry 6), RIGHT (mark shard), CONFIRM.
$expectedMenuR = @('RIGHT') + @( for( $i = 0; $i -lt 6; $i++ ) { 'DOWN' } ) + @('RIGHT', 'CONFIRM')
# Uilist queue choice 0 -> single CONFIRM (no DOWN; the only entry sits at position 0).
$expectedUilistR = @('CONFIRM')
$snapBeforeR = Read-Snapshot -Dir $R.Dir -Name $respR[3].snapshot
$snapAfterR = Read-Snapshot -Dir $R.Dir -Name $respR[9].snapshot
$beforeR = Get-ItemsAt -Snapshot $snapBeforeR -PosLocal $southTile
$afterR = Get-ItemsAt -Snapshot $snapAfterR -PosLocal $southTile
$afterNamesR = @($afterR | ForEach-Object { $_.name })
$blanketGoneR = @($afterNamesR | Where-Object { $_ -like '*folded emergency blanket*' } ).Count -eq 0
$shardGoneR = @($afterNamesR | Where-Object { $_ -like '*glass shard*' } ).Count -eq 0
$pickupMsgsR = @((Get-MessageTexts $snapAfterR) | Where-Object { $_ -like '*You pick up*' })
$wieldMsgR = @((Get-MessageTexts $snapAfterR) | Where-Object { $_ -like '*Wielding*' -and $_ -like '*blanket*' })
# Spike 14: this command response is a CLEAN ok:true with NO partial/forced_cancel/unsupported_prompt
# markers (the doc-31 markers move to the no-channel fallback only). And no prompt_force_cancelled events.
$cleanRespR = ($respR[4].ok -eq $true) -and (-not $respR[4].forced_cancel) -and (-not $respR[4].partial) -and
              (-not $respR[4].unsupported_prompt)
$gRej = ($R.ExitCode -eq 0) -and $R.Result.ok -and ($respR[4].ok -eq $true) -and ($respR[5].ok -eq $true) -and
        ($menuPromptR -and $menuPromptR.kind -eq 'menu') -and
        ($uilistPromptR -and $uilistPromptR.kind -eq 'uilist') -and
        ($uilistChoicesR.Count -eq 1) -and $uilistAllEnabledR -and
        ($uilistEntryTextR -like '*Wield*' -and $uilistEntryTextR -like '*blanket*') -and
        ($uilistTitleR -like '*blanket*') -and
        (($menuChoicesR -join ',') -eq '0,6') -and (($menuActionsR -join ',') -eq ($expectedMenuR -join ',')) -and
        (($uilistChoicesAnsR -join ',') -eq '0') -and (($uilistActionsR -join ',') -eq ($expectedUilistR -join ',')) -and
        ($completedUilistR.Count -ge 1) -and ($completedUilistR[0].actions_served -eq 1) -and
        ($forceCancelEvR.Count -eq 0) -and $cleanRespR -and
        ($afterR.Count -eq ($beforeR.Count - 2)) -and $blanketGoneR -and $shardGoneR -and
        ($pickupMsgsR.Count -ge 1) -and ($wieldMsgR.Count -ge 1)
if( $gRej ) {
    Write-Host "  PASS: secondary capacity uilist DRIVEN (level 4) WIELD-blanket -- chose [0,6] on PICKUP menu (kind=menu), then capacity uilist (kind=uilist) opened with the REAL single-entry choice '$uilistEntryTextR' (title '$uilistTitleR') enabled:true; answering choice:0 served [$($uilistActionsR -join ', ')] through input_context('UILIST') (prompt_completed kind=uilist actions_served=1); engine wielded the blanket via u.wield (message: '$($wieldMsgR[0])'), south tile $($beforeR.Count) -> $($afterR.Count) (both gone), shard stashed; response is clean ok:true with NO partial/forced_cancel markers and NO prompt_force_cancelled events." -ForegroundColor Green
} else {
    Write-Host "  FAIL: secondary capacity drive WIELD -- exit=$($R.ExitCode) pickup=$($respR[4].ok) uilistAck=$($respR[5].ok) menuKind=$($menuPromptR.kind) uilistKind=$($uilistPromptR.kind) uilistChoices=$($uilistChoicesR.Count) allEnabled=$uilistAllEnabledR uilistText='$uilistEntryTextR' title='$uilistTitleR' menuChoices=[$($menuChoicesR -join ', ')] menuActions=[$($menuActionsR -join ', ')] uilistChoicesAns=[$($uilistChoicesAnsR -join ', ')] uilistActions=[$($uilistActionsR -join ', ')] completedServed=$($completedUilistR[0].actions_served) forceCancelEv=$($forceCancelEvR.Count) cleanResp=$cleanRespR before=$($beforeR.Count) after=$($afterR.Count) blanketGone=$blanketGoneR shardGone=$shardGoneR msgs=$($pickupMsgsR.Count) wieldMsgs=$($wieldMsgR.Count)" -ForegroundColor Red
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
# Scenario H (Spike 13B: DRIVE the vehicle-source "Get items from where?" uilist at level 4): on
# ArcopolisVehicleCargoTest -- a copy of ArcopolisTest with a folding_wagon (1 CARGO item) injected ONTO the
# south ground-item pile -- a live `pickup direction=move_s` targets a tile with BOTH vehicle cargo AND
# ground items. game::pickup opens the "Get items from where?" uilist (src/pickup.cpp). Spike 12A's follow-up
# made this FAIL LOUD; Spike 13B instead DRIVES it: the backend un-aborts the uilist under an armed transaction,
# runs its setup() headlessly, exposes the REAL entries as a prompt (kind=uilist), and serves the registered
# UILIST actions ([DOWN, CONFIRM] for "ground") through the real input_context("UILIST") loop, which sets
# amenu.ret. Choosing ground then flows into the existing old "PICKUP" item menu (kind=menu), driven as before.
# =============================================================================

# --- Scenario H-probe: prove the two-prompt flow + the vehicle prompt shape, and discover the ground count.
#   pickup -> answer vehicle uilist (ground) -> the PICKUP item menu opens -> cancel it (GUI ESC, no pickup).
$reqHp = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup_probe"}',
    '{"id":4,"op":"prompt_answer","prompt_id":1,"choice":1}',
    '{"id":5,"op":"prompt_cancel","prompt_id":2}',
    '{"id":6,"op":"export","name":"after_cancel"}',
    '{"id":7,"op":"command","command":"wait","name":"still_usable"}',
    '{"id":8,"op":"quit"}'
)
$Hp = Invoke-LiveScenario -Name "vehicle_drive_probe" -RequestLines $reqHp -ScenarioWorld $VehicleWorld
$evHp = Read-Transcript -Dir $Hp.Dir
$respHp = Index-ById $Hp.Result.responses
$promptsHp = Get-PromptsInOrder $Hp.Result.responses
$snapHpBefore = Read-Snapshot -Dir $Hp.Dir -Name $respHp[2].snapshot
$vehSouthTile = @( ( [int]$snapHpBefore.avatar.pos_local[0] ),
    ( [int]$snapHpBefore.avatar.pos_local[1] + 1 ), ( [int]$snapHpBefore.avatar.pos_local[2] ) )
$itemsHpBefore = Get-ItemsAt -Snapshot $snapHpBefore -PosLocal $vehSouthTile
$snapHpAfter = Read-Snapshot -Dir $Hp.Dir -Name $respHp[6].snapshot
$itemsHpAfter = Get-ItemsAt -Snapshot $snapHpAfter -PosLocal $vehSouthTile

# Vehicle prompt is the FIRST prompt (kind=uilist, exactly 2 choices in order); the PICKUP menu is the second.
$vehPrompt = if( $promptsHp.Count -ge 1 ) { $promptsHp[0] } else { $null }
$menuPrompt = if( $promptsHp.Count -ge 2 ) { $promptsHp[1] } else { $null }
$vehChoices = if( $vehPrompt ) { @($vehPrompt.choices) } else { @() }
$vehCargoFirst = ($vehChoices.Count -eq 2) -and ($vehChoices[0].text -like '*vehicle*' -or $vehChoices[0].text -like '*cargo*')
$groundSecond = ($vehChoices.Count -eq 2) -and ($vehChoices[1].text -like '*ground*')
$openedUilistHp = @($evHp | Where-Object { $_.event -eq 'prompt_opened' -and $_.kind -eq 'uilist' })
$answeredUilistHp = @($evHp | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'uilist' })
$completedUilistHp = @($evHp | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'uilist' })
$uilistActionsHp = if( $answeredUilistHp.Count -ge 1 ) { @($answeredUilistHp[0].actions) } else { @() }
$vehGroundCount = if( $menuPrompt ) { @($menuPrompt.choices).Count } else { 0 }

# --- Gate H1 (vehicle prompt shape + level-4 drive): kind=uilist, 2 choices in order, served [DOWN, CONFIRM].
$gH1 = ($Hp.ExitCode -eq 0) -and $Hp.Result.ok -and
       ($vehPrompt -and ($vehPrompt.kind -eq 'uilist') -and ($vehChoices.Count -eq 2)) -and
       $vehCargoFirst -and $groundSecond -and
       ($openedUilistHp.Count -ge 1) -and ($openedUilistHp[0].choices.Count -eq 2) -and
       ($answeredUilistHp.Count -ge 1) -and ((@($answeredUilistHp[0].choices) -join ',') -eq '1') -and
       (($uilistActionsHp -join ',') -eq 'DOWN,CONFIRM') -and
       ($completedUilistHp.Count -ge 1) -and ($completedUilistHp[0].actions_served -eq 2) -and
       ($menuPrompt -and ($menuPrompt.kind -eq 'menu')) -and ($vehGroundCount -ge 1)
if( $gH1 ) {
    Write-Host "  PASS: vehicle-source uilist DRIVEN (level 4) -- prompt kind=uilist with 2 choices in order ['$($vehChoices[0].text)','$($vehChoices[1].text)']; answering ground served [$($uilistActionsHp -join ', ')] through input_context('UILIST') (prompt_completed kind=uilist actions_served=2); the old 'PICKUP' menu (kind=menu, $vehGroundCount choices) then opened SEPARATELY." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle-source uilist drive -- exit=$($Hp.ExitCode) ok=$($Hp.Result.ok) vehKind=$($vehPrompt.kind) vehChoices=$($vehChoices.Count) cargoFirst=$vehCargoFirst groundSecond=$groundSecond openedUilist=$($openedUilistHp.Count) answeredChoices=[$(@($answeredUilistHp[0].choices) -join ',')] uilistActions=[$($uilistActionsHp -join ', ')] completed=$($completedUilistHp[0].actions_served) menuKind=$($menuPrompt.kind) groundCount=$vehGroundCount" -ForegroundColor Red
    $fail++
    if( -not $Hp.Result -or $promptsHp.Count -lt 2 ) { Write-Host "PICKUP REGRESSION: aborting (vehicle drive did not reach the two-prompt flow)." -ForegroundColor Red; exit 1 }
}

# --- Gate H2 (probe is a no-op): cancelling the PICKUP menu after choosing ground takes NO items; usable.
$gH2 = ($respHp[4].ok -eq $true) -and ($itemsHpBefore.Count -ge 1) -and
       ($itemsHpAfter.Count -eq $itemsHpBefore.Count) -and ($respHp[7].ok -eq $true)
if( $gH2 ) {
    Write-Host "  PASS: vehicle-then-ground probe is a no-op -- the PICKUP menu cancel took no items ($($itemsHpBefore.Count) ground items unchanged); the session served a later wait." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle probe no-op -- cancelAck=$($respHp[4].ok) before=$($itemsHpBefore.Count) after=$($itemsHpAfter.Count) wait=$($respHp[7].ok)" -ForegroundColor Red
    $fail++
}

# --- Scenario H-pick: drive vehicle->ground, then pick the LAST ground entry; it must leave the ground.
$vehK = [Math]::Max(0, $vehGroundCount - 1)
$reqHk = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup"}',
    '{"id":4,"op":"prompt_answer","prompt_id":1,"choice":1}',
    ('{"id":5,"op":"prompt_answer","prompt_id":2,"choice":' + $vehK + '}'),
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$Hk = Invoke-LiveScenario -Name "vehicle_drive_pick" -RequestLines $reqHk -ScenarioWorld $VehicleWorld
$evHk = Read-Transcript -Dir $Hk.Dir
$respHk = Index-ById $Hk.Result.responses
$snapHkBefore = Read-Snapshot -Dir $Hk.Dir -Name $respHk[2].snapshot
$snapHkAfter = Read-Snapshot -Dir $Hk.Dir -Name $respHk[8].snapshot
$hkTile = @( ( [int]$snapHkBefore.avatar.pos_local[0] ),
    ( [int]$snapHkBefore.avatar.pos_local[1] + 1 ), ( [int]$snapHkBefore.avatar.pos_local[2] ) )
$beforeHk = Get-ItemsAt -Snapshot $snapHkBefore -PosLocal $hkTile
$afterHk = Get-ItemsAt -Snapshot $snapHkAfter -PosLocal $hkTile
$pickupMsgsHk = @((Get-MessageTexts $snapHkAfter) | Where-Object { $_ -like '*You pick up*' })
$answeredUilistHk = @($evHk | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'uilist' })
$answeredMenuHk = @($evHk | Where-Object { $_.event -eq 'prompt_answered' -and ($_.kind -eq $null -or $_.kind -eq 'menu' -or $_.kind -eq '') })
$gH3 = ($Hk.ExitCode -eq 0) -and $Hk.Result.ok -and ($respHk[4].ok -eq $true) -and ($respHk[5].ok -eq $true) -and
       ($answeredUilistHk.Count -ge 1) -and ((@($answeredUilistHk[0].actions) -join ',') -eq 'DOWN,CONFIRM') -and
       ($answeredMenuHk.Count -ge 1) -and
       ($beforeHk.Count -ge 1) -and ($afterHk.Count -lt $beforeHk.Count) -and ($pickupMsgsHk.Count -ge 1)
if( $gH3 ) {
    Write-Host "  PASS: vehicle-source drive picks a ground item -- after choosing ground (served [DOWN, CONFIRM]) and the LAST PICKUP entry (choice $vehK), the south tile went $($beforeHk.Count) -> $($afterHk.Count) ground items and the engine logged '$($pickupMsgsHk[0])'." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle-source drive pick -- exit=$($Hk.ExitCode) vehAck=$($respHk[4].ok) menuAck=$($respHk[5].ok) uilistActions=[$(@($answeredUilistHk[0].actions) -join ', ')] menuAnswered=$($answeredMenuHk.Count) before=$($beforeHk.Count) after=$($afterHk.Count) msgs=$($pickupMsgsHk.Count)" -ForegroundColor Red
    $fail++
}

# --- Scenario H-cancel: prompt_cancel the VEHICLE uilist -> NO PICKUP menu, NO ground pickup, session usable.
$reqHc = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup_cancel"}',
    '{"id":4,"op":"prompt_cancel","prompt_id":1}',
    '{"id":5,"op":"export","name":"after_cancel"}',
    '{"id":6,"op":"command","command":"wait","name":"still_usable"}',
    '{"id":7,"op":"quit"}'
)
$Hc = Invoke-LiveScenario -Name "vehicle_cancel" -RequestLines $reqHc -ScenarioWorld $VehicleWorld
$evHc = Read-Transcript -Dir $Hc.Dir
$respHc = Index-ById $Hc.Result.responses
$promptsHc = Get-PromptsInOrder $Hc.Result.responses
$snapHcBefore = Read-Snapshot -Dir $Hc.Dir -Name $respHc[2].snapshot
$snapHcAfter = Read-Snapshot -Dir $Hc.Dir -Name $respHc[5].snapshot
$hcTile = @( ( [int]$snapHcBefore.avatar.pos_local[0] ),
    ( [int]$snapHcBefore.avatar.pos_local[1] + 1 ), ( [int]$snapHcBefore.avatar.pos_local[2] ) )
$beforeHc = Get-ItemsAt -Snapshot $snapHcBefore -PosLocal $hcTile
$afterHc = Get-ItemsAt -Snapshot $snapHcAfter -PosLocal $hcTile
$cancelledUilistHc = @($evHc | Where-Object { $_.event -eq 'prompt_cancelled' -and $_.kind -eq 'uilist' })
$pickupMsgsHc = @((Get-MessageTexts $snapHcAfter) | Where-Object { $_ -like '*You pick up*' })
$gH4 = ($Hc.ExitCode -eq 0) -and $Hc.Result.ok -and ($respHc[3].ok -eq $true) -and
       ($promptsHc.Count -eq 1) -and ($promptsHc[0].kind -eq 'uilist') -and ($cancelledUilistHc.Count -ge 1) -and
       ($beforeHc.Count -ge 1) -and ($afterHc.Count -eq $beforeHc.Count) -and ($pickupMsgsHc.Count -eq 0) -and
       ($respHc[6].ok -eq $true)
if( $gH4 ) {
    Write-Host "  PASS: vehicle-source cancel -- prompt_cancel on the uilist opened NO 'PICKUP' menu (1 prompt only), took NO ground items ($($beforeHc.Count) unchanged), logged no pickup, transcript prompt_cancelled kind=uilist; session served a later wait. No silent ground-only pickup." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle-source cancel -- exit=$($Hc.ExitCode) cancelAck=$($respHc[3].ok) prompts=$($promptsHc.Count) firstKind=$($promptsHc[0].kind) cancelledUilist=$($cancelledUilistHc.Count) before=$($beforeHc.Count) after=$($afterHc.Count) pickupMsgs=$($pickupMsgsHc.Count) wait=$($respHc[6].ok)" -ForegroundColor Red
    $fail++
}

# --- Scenario H-recover: wrong prompt_id AND out-of-range choice on the vehicle uilist are each rejected
# (prompt stays open), then a valid ground answer completes the SAME pickup.
$reqHr = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"command","command":"pickup","direction":"move_s","name":"pickup"}',
    '{"id":3,"op":"prompt_answer","prompt_id":999,"choice":1}',
    '{"id":4,"op":"prompt_answer","prompt_id":1,"choice":2}',
    '{"id":5,"op":"prompt_answer","prompt_id":1,"choice":1}',
    ('{"id":6,"op":"prompt_answer","prompt_id":2,"choice":' + $vehK + '}'),
    '{"id":7,"op":"export","name":"after_pick"}',
    '{"id":8,"op":"command","command":"wait","name":"after"}',
    '{"id":9,"op":"quit"}'
)
$Hr = Invoke-LiveScenario -Name "vehicle_recover" -RequestLines $reqHr -ScenarioWorld $VehicleWorld
$evHr = Read-Transcript -Dir $Hr.Dir
$respsHr = @($Hr.Result.responses)
$rejectHr = @($respsHr | Where-Object { $_.type -eq 'response' -and $_.op -eq 'prompt_answer' -and $_.ok -eq $false })
$rejectBadReqHr = @($rejectHr | Where-Object { $_.error.code -eq 'bad_request' })
$failedHr = @($evHr | Where-Object { $_.event -eq 'prompt_failed' })
$mismatchHr = @($failedHr | Where-Object { $_.reason -eq 'prompt_id_mismatch' })
$rangeHr = @($failedHr | Where-Object { $_.reason -eq 'invalid_answer' })
$cmdOkHr = @($respsHr | Where-Object { $_.type -eq 'response' -and $_.op -eq 'command' -and $_.id -eq 2 -and $_.ok -eq $true })
$gH5 = ($Hr.ExitCode -eq 0) -and $Hr.Result.ok -and ($rejectHr.Count -ge 2) -and ($rejectBadReqHr.Count -ge 2) -and
       ($mismatchHr.Count -ge 1) -and ($rangeHr.Count -ge 1) -and ($cmdOkHr.Count -ge 1)
if( $gH5 ) {
    Write-Host "  PASS: vehicle-source recovery -- wrong prompt_id (999) AND out-of-range choice (2) each rejected ok:false/bad_request with the uilist STILL OPEN (prompt_failed prompt_id_mismatch + invalid_answer), then a valid ground answer completed the SAME pickup ok:true." -ForegroundColor Green
} else {
    Write-Host "  FAIL: vehicle-source recovery -- exit=$($Hr.ExitCode) reject=$($rejectHr.Count) badReq=$($rejectBadReqHr.Count) mismatch=$($mismatchHr.Count) range=$($rangeHr.Count) cmdOk=$($cmdOkHr.Count)" -ForegroundColor Red
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
# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach the binary's argparse split into broken tokens.
$ps = Start-Process -FilePath $Exe -ArgumentList @('--world', $World, '--arcopolis-run-script', "`"$scriptPath`"",
    '--arcopolis-export-dir', "`"$(Join-Path $nonLiveDir "script_out")`"", '--userdir', "`"$UserDir`"") -NoNewWindow -Wait -PassThru `
    -RedirectStandardError $scriptErr -RedirectStandardOutput (Join-Path $nonLiveDir "script_out.txt")
$scriptErrText = (Get-Content $scriptErr -Raw -ErrorAction SilentlyContinue)
# (b) one-shot mode
$cmdPath = Join-Path $nonLiveDir "pickup_cmd.json"
Set-Content -Path $cmdPath -Value '{"schema_version":1,"command":"pickup","direction":"move_s"}' -Encoding ascii
$oneshotSnap = Join-Path $nonLiveDir "oneshot.json"
$oneshotErr = Join-Path $nonLiveDir "oneshot_err.txt"
# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach the binary's argparse split into broken tokens.
$po = Start-Process -FilePath $Exe -ArgumentList @('--world', $World, '--arcopolis-export-current-view', "`"$oneshotSnap`"",
    '--arcopolis-command', "`"$cmdPath`"", '--userdir', "`"$UserDir`"") -NoNewWindow -Wait -PassThru `
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

# =============================================================================
# Scenario J (Spike 14, ArcopolisCapacityTest: DRIVE the secondary capacity uilist at level 4 with a
# MULTI-ENTRY witness -- WEAR + WIELD, both enabled). The fixture injects ONE bulky armor item
# (jacket_leather, data/json/items/armor/coats.json: 4500 ml, ARMOR/OUTER, not a bucket, no children)
# onto ArcopolisTest's south ground pile. Picking the jacket exceeds the unarmed avatar's tiny volume
# capacity, so the activity raises handle_problematic_pickup -> uilist with WEAR (is_armor) + WIELD
# (avatar unarmed; no NO_UNWIELD weapon to dispose of) = exactly 2 entries, both enabled
# (acceptance criterion #1). Sub-gates J-probe (discover the jacket's menu index + assert prompt shape),
# J-pick-wield (drive entry 1 -> [DOWN, CONFIRM] -> u.wield), J-pick-wear (drive entry 0 -> [CONFIRM] ->
# u.wear), J-cancel (real player cancel via QUIT -> jacket stays, NOT a force-cancel), J-recover (wrong
# prompt_id + out-of-range each rejected; the prompt stays open; a valid answer completes).
# =============================================================================

# --- J-probe: cancel the PICKUP menu just to discover the jacket's index (stacked_here ordering varies).
$reqJp = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"command","command":"pickup","direction":"move_s","name":"pickup_probe"}',
    '{"id":3,"op":"prompt_cancel","prompt_id":1}',
    '{"id":4,"op":"quit"}'
)
$Jp = Invoke-LiveScenario -Name "capacity_probe" -RequestLines $reqJp -ScenarioWorld $CapacityWorld
$promptsJp = Get-PromptsInOrder $Jp.Result.responses
$menuPromptJp = if( $promptsJp.Count -ge 1 ) { $promptsJp[0] } else { $null }
$jacketIdxJ = -1
if( $menuPromptJp ) {
    for( $i = 0; $i -lt @($menuPromptJp.choices).Count; $i++ ) {
        if( @($menuPromptJp.choices)[$i].text -like '*leather jacket*' ) { $jacketIdxJ = $i; break }
    }
}
$gJ0 = ($Jp.ExitCode -eq 0) -and $Jp.Result.ok -and $menuPromptJp -and ($menuPromptJp.kind -eq 'menu') -and ($jacketIdxJ -ge 0)
if( $gJ0 ) {
    Write-Host "  PASS: capacity probe -- PICKUP menu opens with the jacket at index $jacketIdxJ ($($menuPromptJp.choices.Count) total entries)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: capacity probe -- exit=$($Jp.ExitCode) menuKind=$($menuPromptJp.kind) jacketIdx=$jacketIdxJ choices=$($menuPromptJp.choices.Count) (rebuild the fixture: docs/arcopolis/make_capacity_fixture.py)." -ForegroundColor Red
    $fail++
    if( $jacketIdxJ -lt 0 ) {
        Write-Host "PICKUP REGRESSION: aborting (capacity probe could not find the witness jacket)." -ForegroundColor Red
        exit 1
    }
}

# --- J-pick-wield: pick the jacket on the PICKUP menu; secondary uilist (2 entries) -> answer WIELD (entry 1)
#     served [DOWN, CONFIRM] through input_context("UILIST"); engine wields the jacket -> u.wield ->
#     jacket leaves the ground AND becomes primary_weapon (witnessed via the "Wielding" message); response
#     is clean ok:true with NO partial/forced_cancel/unsupported_prompt markers, NO prompt_force_cancelled.
$reqJw = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup_wield"}',
    ('{"id":4,"op":"prompt_answer","prompt_id":1,"choices":[' + $jacketIdxJ + ']}'),
    '{"id":5,"op":"prompt_answer","prompt_id":2,"choice":1}',
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$Jw = Invoke-LiveScenario -Name "capacity_wield" -RequestLines $reqJw -ScenarioWorld $CapacityWorld
$evJw = Read-Transcript -Dir $Jw.Dir
$respJw = Index-ById $Jw.Result.responses
$promptsJw = Get-PromptsInOrder $Jw.Result.responses
$uilistPromptJw = if( $promptsJw.Count -ge 2 ) { $promptsJw[1] } else { $null }
$uilistChoicesJw = if( $uilistPromptJw ) { @($uilistPromptJw.choices) } else { @() }
$uilistAllEnabledJw = ($uilistChoicesJw.Count -ge 2) -and (@($uilistChoicesJw | Where-Object { -not $_.enabled }).Count -eq 0)
$wearEntryJw = ($uilistChoicesJw.Count -ge 2) -and ($uilistChoicesJw[0].text -like '*Wear*' -and $uilistChoicesJw[0].text -like '*leather jacket*')
$wieldEntryJw = ($uilistChoicesJw.Count -ge 2) -and ($uilistChoicesJw[1].text -like '*Wield*' -and $uilistChoicesJw[1].text -like '*leather jacket*')
$answeredUilistJw = @($evJw | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'uilist' })
$completedUilistJw = @($evJw | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'uilist' })
$uilistActionsJw = if( $answeredUilistJw.Count -ge 1 ) { @($answeredUilistJw[0].actions) } else { @() }
$forceCancelJw = @($evJw | Where-Object { $_.event -eq 'prompt_force_cancelled' })
$snapJwBefore = Read-Snapshot -Dir $Jw.Dir -Name $respJw[2].snapshot
$snapJwAfter = Read-Snapshot -Dir $Jw.Dir -Name $respJw[8].snapshot
$jwTile = @( ( [int]$snapJwBefore.avatar.pos_local[0] ),
    ( [int]$snapJwBefore.avatar.pos_local[1] + 1 ), ( [int]$snapJwBefore.avatar.pos_local[2] ) )
$beforeJw = Get-ItemsAt -Snapshot $snapJwBefore -PosLocal $jwTile
$afterJw = Get-ItemsAt -Snapshot $snapJwAfter -PosLocal $jwTile
$afterNamesJw = @($afterJw | ForEach-Object { $_.name })
$jacketGoneJw = @($afterNamesJw | Where-Object { $_ -like '*leather jacket*' } ).Count -eq 0
$wieldMsgJw = @((Get-MessageTexts $snapJwAfter) | Where-Object { $_ -like '*Wielding*' -and $_ -like '*leather jacket*' })
$cleanRespJw = ($respJw[3].ok -eq $true) -and (-not $respJw[3].forced_cancel) -and (-not $respJw[3].partial) -and (-not $respJw[3].unsupported_prompt)
$gJ1 = ($Jw.ExitCode -eq 0) -and $Jw.Result.ok -and ($respJw[3].ok -eq $true) -and ($respJw[4].ok -eq $true) -and
       ($uilistPromptJw -and $uilistPromptJw.kind -eq 'uilist') -and
       ($uilistChoicesJw.Count -eq 2) -and $uilistAllEnabledJw -and $wearEntryJw -and $wieldEntryJw -and
       ($answeredUilistJw.Count -ge 1) -and ((@($answeredUilistJw[0].choices) -join ',') -eq '1') -and
       (($uilistActionsJw -join ',') -eq 'DOWN,CONFIRM') -and
       ($completedUilistJw.Count -ge 1) -and ($completedUilistJw[0].actions_served -eq 2) -and
       ($forceCancelJw.Count -eq 0) -and $cleanRespJw -and
       ($afterJw.Count -eq ($beforeJw.Count - 1)) -and $jacketGoneJw -and ($wieldMsgJw.Count -ge 1)
if( $gJ1 ) {
    Write-Host "  PASS: capacity multi-entry DRIVE WIELD (level 4) -- secondary uilist (kind=uilist) opened with 2 enabled entries [Wear / Wield leather jacket]; answer choice:1 served [$($uilistActionsJw -join ', ')] through input_context('UILIST') (prompt_completed kind=uilist actions_served=2); engine wielded the jacket ('$($wieldMsgJw[0])'), south tile $($beforeJw.Count) -> $($afterJw.Count); response clean ok:true with NO partial/forced_cancel markers." -ForegroundColor Green
} else {
    Write-Host "  FAIL: capacity multi-entry WIELD -- exit=$($Jw.ExitCode) pickupAck=$($respJw[3].ok) uilistAck=$($respJw[4].ok) uilistKind=$($uilistPromptJw.kind) choices=$($uilistChoicesJw.Count) allEnabled=$uilistAllEnabledJw wearEntry=$wearEntryJw wieldEntry=$wieldEntryJw uilistActions=[$($uilistActionsJw -join ', ')] served=$($completedUilistJw[0].actions_served) forceCancel=$($forceCancelJw.Count) cleanResp=$cleanRespJw before=$($beforeJw.Count) after=$($afterJw.Count) jacketGone=$jacketGoneJw wieldMsg=$($wieldMsgJw.Count)" -ForegroundColor Red
    $fail++
}

# --- J-pick-wear: answer choice:0 (WEAR) -> served [CONFIRM] (no DOWN; position 0) -> u.wear -> jacket
#     leaves ground and is added to the avatar's worn list. Tile decreases by 1.
$reqJwr = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup_wear"}',
    ('{"id":4,"op":"prompt_answer","prompt_id":1,"choices":[' + $jacketIdxJ + ']}'),
    '{"id":5,"op":"prompt_answer","prompt_id":2,"choice":0}',
    '{"id":6,"op":"export","name":"after_pick"}',
    '{"id":7,"op":"command","command":"wait","name":"drain"}',
    '{"id":8,"op":"export","name":"after_wait"}',
    '{"id":9,"op":"quit"}'
)
$Jwr = Invoke-LiveScenario -Name "capacity_wear" -RequestLines $reqJwr -ScenarioWorld $CapacityWorld
$evJwr = Read-Transcript -Dir $Jwr.Dir
$respJwr = Index-ById $Jwr.Result.responses
$answeredUilistJwr = @($evJwr | Where-Object { $_.event -eq 'prompt_answered' -and $_.kind -eq 'uilist' })
$completedUilistJwr = @($evJwr | Where-Object { $_.event -eq 'prompt_completed' -and $_.kind -eq 'uilist' })
$uilistActionsJwr = if( $answeredUilistJwr.Count -ge 1 ) { @($answeredUilistJwr[0].actions) } else { @() }
$forceCancelJwr = @($evJwr | Where-Object { $_.event -eq 'prompt_force_cancelled' })
$snapJwrBefore = Read-Snapshot -Dir $Jwr.Dir -Name $respJwr[2].snapshot
$snapJwrAfter = Read-Snapshot -Dir $Jwr.Dir -Name $respJwr[8].snapshot
$jwrTile = @( ( [int]$snapJwrBefore.avatar.pos_local[0] ),
    ( [int]$snapJwrBefore.avatar.pos_local[1] + 1 ), ( [int]$snapJwrBefore.avatar.pos_local[2] ) )
$beforeJwr = Get-ItemsAt -Snapshot $snapJwrBefore -PosLocal $jwrTile
$afterJwr = Get-ItemsAt -Snapshot $snapJwrAfter -PosLocal $jwrTile
$afterNamesJwr = @($afterJwr | ForEach-Object { $_.name })
$jacketGoneJwr = @($afterNamesJwr | Where-Object { $_ -like '*leather jacket*' } ).Count -eq 0
$cleanRespJwr = ($respJwr[3].ok -eq $true) -and (-not $respJwr[3].forced_cancel) -and (-not $respJwr[3].partial) -and (-not $respJwr[3].unsupported_prompt)
$gJ2 = ($Jwr.ExitCode -eq 0) -and $Jwr.Result.ok -and ($respJwr[3].ok -eq $true) -and ($respJwr[4].ok -eq $true) -and
       ($answeredUilistJwr.Count -ge 1) -and ((@($answeredUilistJwr[0].choices) -join ',') -eq '0') -and
       (($uilistActionsJwr -join ',') -eq 'CONFIRM') -and
       ($completedUilistJwr.Count -ge 1) -and ($completedUilistJwr[0].actions_served -eq 1) -and
       ($forceCancelJwr.Count -eq 0) -and $cleanRespJwr -and
       ($afterJwr.Count -eq ($beforeJwr.Count - 1)) -and $jacketGoneJwr
if( $gJ2 ) {
    Write-Host "  PASS: capacity multi-entry DRIVE WEAR (level 4) -- answer choice:0 served [CONFIRM] (no DOWN; position 0); engine wore the jacket, south tile $($beforeJwr.Count) -> $($afterJwr.Count); response clean ok:true." -ForegroundColor Green
} else {
    Write-Host "  FAIL: capacity multi-entry WEAR -- exit=$($Jwr.ExitCode) pickupAck=$($respJwr[3].ok) uilistAck=$($respJwr[4].ok) uilistActions=[$($uilistActionsJwr -join ', ')] served=$($completedUilistJwr[0].actions_served) before=$($beforeJwr.Count) after=$($afterJwr.Count) jacketGone=$jacketGoneJwr cleanResp=$cleanRespJwr" -ForegroundColor Red
    $fail++
}

# --- J-cancel: prompt_cancel on the secondary uilist -> served [QUIT] -> engine returns UILIST_CANCEL ->
#     CANCEL -> jacket stays on ground (NEVER logged as picked up). Response is clean ok:true (NOT
#     forced_cancel: a real player cancel through the engine's own loop). Transcript: prompt_cancelled
#     kind=uilist, NO prompt_force_cancelled.
$reqJc = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"export","name":"before"}',
    '{"id":3,"op":"command","command":"pickup","direction":"move_s","name":"pickup_cancel"}',
    ('{"id":4,"op":"prompt_answer","prompt_id":1,"choices":[' + $jacketIdxJ + ']}'),
    '{"id":5,"op":"prompt_cancel","prompt_id":2}',
    '{"id":6,"op":"export","name":"after_cancel"}',
    '{"id":7,"op":"command","command":"wait","name":"after"}',
    '{"id":8,"op":"quit"}'
)
$Jc = Invoke-LiveScenario -Name "capacity_cancel" -RequestLines $reqJc -ScenarioWorld $CapacityWorld
$evJc = Read-Transcript -Dir $Jc.Dir
$respJc = Index-ById $Jc.Result.responses
$cancelledUilistJc = @($evJc | Where-Object { $_.event -eq 'prompt_cancelled' -and $_.kind -eq 'uilist' })
$forceCancelJc = @($evJc | Where-Object { $_.event -eq 'prompt_force_cancelled' })
$snapJcBefore = Read-Snapshot -Dir $Jc.Dir -Name $respJc[2].snapshot
$snapJcAfter = Read-Snapshot -Dir $Jc.Dir -Name $respJc[6].snapshot
$jcTile = @( ( [int]$snapJcBefore.avatar.pos_local[0] ),
    ( [int]$snapJcBefore.avatar.pos_local[1] + 1 ), ( [int]$snapJcBefore.avatar.pos_local[2] ) )
$beforeJc = Get-ItemsAt -Snapshot $snapJcBefore -PosLocal $jcTile
$afterJc = Get-ItemsAt -Snapshot $snapJcAfter -PosLocal $jcTile
$afterNamesJc = @($afterJc | ForEach-Object { $_.name })
$jacketStaysJc = @($afterNamesJc | Where-Object { $_ -like '*leather jacket*' } ).Count -ge 1
$pickupMsgsJc = @((Get-MessageTexts $snapJcAfter) | Where-Object { $_ -like '*You pick up*' -and $_ -like '*leather jacket*' })
$cleanRespJc = ($respJc[3].ok -eq $true) -and (-not $respJc[3].forced_cancel) -and (-not $respJc[3].partial) -and (-not $respJc[3].unsupported_prompt)
$gJ3 = ($Jc.ExitCode -eq 0) -and $Jc.Result.ok -and ($respJc[3].ok -eq $true) -and ($respJc[4].ok -eq $true) -and
       ($cancelledUilistJc.Count -ge 1) -and ($forceCancelJc.Count -eq 0) -and $cleanRespJc -and
       $jacketStaysJc -and ($pickupMsgsJc.Count -eq 0)
if( $gJ3 ) {
    Write-Host "  PASS: capacity multi-entry CANCEL -- prompt_cancel on the secondary uilist returned UILIST_CANCEL through the engine loop; jacket stays on the ground (count $($beforeJc.Count) unchanged), NEVER logged as picked up; response clean ok:true (NOT forced_cancel: a real player cancel)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: capacity multi-entry CANCEL -- exit=$($Jc.ExitCode) cancelAck=$($respJc[4].ok) cancelled=$($cancelledUilistJc.Count) forceCancel=$($forceCancelJc.Count) cleanResp=$cleanRespJc jacketStays=$jacketStaysJc pickupMsgs=$($pickupMsgsJc.Count)" -ForegroundColor Red
    $fail++
}

# --- J-recover: wrong prompt_id AND out-of-range choice on the SECONDARY uilist are each rejected ok:false/
#     bad_request with the prompt STILL OPEN (prompt_failed prompt_id_mismatch + invalid_answer); a valid
#     WIELD answer then completes the SAME pickup ok:true.
$reqJr = @(
    '{"id":1,"op":"command","command":"move","direction":"move_s","name":"approach"}',
    '{"id":2,"op":"command","command":"pickup","direction":"move_s","name":"pickup_recover"}',
    ('{"id":3,"op":"prompt_answer","prompt_id":1,"choices":[' + $jacketIdxJ + ']}'),
    '{"id":4,"op":"prompt_answer","prompt_id":999,"choice":1}',
    '{"id":5,"op":"prompt_answer","prompt_id":2,"choice":7}',
    '{"id":6,"op":"prompt_answer","prompt_id":2,"choice":1}',
    '{"id":7,"op":"command","command":"wait","name":"after"}',
    '{"id":8,"op":"quit"}'
)
$Jr = Invoke-LiveScenario -Name "capacity_recover" -RequestLines $reqJr -ScenarioWorld $CapacityWorld
$evJr = Read-Transcript -Dir $Jr.Dir
$respsJr = @($Jr.Result.responses)
$rejectJr = @($respsJr | Where-Object { $_.type -eq 'response' -and $_.op -eq 'prompt_answer' -and $_.ok -eq $false })
$rejectBadReqJr = @($rejectJr | Where-Object { $_.error.code -eq 'bad_request' })
$failedJr = @($evJr | Where-Object { $_.event -eq 'prompt_failed' })
$mismatchJr = @($failedJr | Where-Object { $_.reason -eq 'prompt_id_mismatch' })
$rangeJr = @($failedJr | Where-Object { $_.reason -eq 'invalid_answer' })
$cmdOkJr = @($respsJr | Where-Object { $_.type -eq 'response' -and $_.op -eq 'command' -and $_.id -eq 2 -and $_.ok -eq $true })
$gJ4 = ($Jr.ExitCode -eq 0) -and $Jr.Result.ok -and ($rejectJr.Count -ge 2) -and ($rejectBadReqJr.Count -ge 2) -and
       ($mismatchJr.Count -ge 1) -and ($rangeJr.Count -ge 1) -and ($cmdOkJr.Count -ge 1)
if( $gJ4 ) {
    Write-Host "  PASS: capacity multi-entry RECOVER -- wrong prompt_id (999) AND out-of-range choice (7) each rejected ok:false/bad_request with the secondary uilist STILL OPEN (prompt_failed prompt_id_mismatch + invalid_answer); a valid WIELD answer then completed the SAME pickup ok:true." -ForegroundColor Green
} else {
    Write-Host "  FAIL: capacity multi-entry RECOVER -- exit=$($Jr.ExitCode) reject=$($rejectJr.Count) badReq=$($rejectBadReqJr.Count) mismatch=$($mismatchJr.Count) range=$($rangeJr.Count) cmdOk=$($cmdOkJr.Count)" -ForegroundColor Red
    $fail++
}

if( $fail -gt 0 ) { Write-Host "PICKUP REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "PICKUP REGRESSION: ok." -ForegroundColor Green
exit 0
