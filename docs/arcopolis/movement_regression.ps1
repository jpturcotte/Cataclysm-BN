<#
.SYNOPSIS
  Arcopolis movement regression scenario (the run-script / "RNS" integration layer).

.DESCRIPTION
  Drives the headless backend over the ArcopolisTest fixture and asserts that an UNOBSTRUCTED move
  (a cardinal AND a diagonal) actually moves the avatar -- so a movement no-op (like the
  move_n-into-NPC case in 15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md) fails LOUDLY instead of passing silently,
  and so the 8-way move fix is witnessed end-to-end (a diagonal step advances pos_abs diagonally).

  Why this is a fixture-driven script and not a CI catch2 test:
    * It needs a fully loaded world. The pure command/script parsing is already covered by the
      world-independent [arcopolis] unit suite (tests/arcopolis_*_test.cpp, incl. the command_to_action
      cardinal-mapping cases). A fully automated, in-CI world-driven movement assertion still depends on
      the deferred `--arcopolis-new-world` generator (ARCOPOLIS_STATE.md backlog). Until that lands we
      drive the EXTERNAL ArcopolisTest fixture here and DO NOT fake world state.

  What it asserts (robust, build-verifiable signals only):
    * move_s from spawn (known-walkable: (85,86) is open t_floor, no creature) MUST advance
      avatar.pos_abs by +1 in y, and MUST advance backend.turn (the turn completed / world ticked).
      A complete no-op leaves both unchanged -> the script exits non-zero.
    * It deliberately keys on pos_abs + backend.turn, NOT on a specific avatar.moves value: the "after"
      snapshot is taken at the next turn's input rest, where Creature::process_turn has refilled moves, so
      the snapshot moves is not a reliable "AP consumed" readout. pos_abs advancing + the turn ticking are
      the unambiguous "the move happened" signals (the same "judge a move by pos_abs delta, not the
      move() bool" idiom the spikes use).

  It also drives move_n and REPORTS the result: with the stock shelter NPC (Edwardo Stovall) on (85,84),
  SPIKE 21 makes this FAIL LOUD -- move_n bumps the NPC and reaches game::npc_menu's unarmed uilist, which
  the backend reports as unexpected_prompt (exit 14), no longer a silent no-op. That arm is informational
  (it depends on fixture NPC placement), not a hard gate -- see 15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md (root
  cause) and 43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md (the fail-loud). The genuine terrain
  blocked_no_op witness now lives in client_harness_regression.ps1 (ArcopolisWallTest).

.NOTES
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions (AGENTS.md
  fixture section); kept verbatim so the commands stay copy-pasteable. No usernames/secrets.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_move_regress"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot\arco_fixture_root.ps1"
if( $FixtureSrc ) { } else { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

if( -not (Test-Path $Exe) ) {
    Write-Error "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)"
    exit 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Write-Error "Fixture source directory not found: $FixtureSrc  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)"
    exit 4
}

# Refresh the gitignored sandbox world from the external fixture. NOTE: `Copy-Item -Recurse` copies the
# source dir INSIDE the destination when the destination already exists (a 2nd run would nest into
# arcopolis_user\arcopolis_user); delete any existing sandbox first so every run gets a clean, non-nested
# userdir whose contents sit directly under $UserDir.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

function Invoke-Scenario {
    param([string]$Name, [string]$Direction)

    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    $scriptPath = Join-Path $dir "script.json"
    @"
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "$Direction" },
  { "op": "export",  "name": "after" }
] }
"@ | Set-Content -Encoding ascii $scriptPath

    # cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and
    # leaves $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code
    # (the pattern the spike validations use), with stdout/stderr redirected into the scenario dir.
    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $World,
        '--arcopolis-run-script', $scriptPath,
        '--arcopolis-export-dir', $dir,
        '--userdir', $UserDir
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")
    $code = $p.ExitCode
    if( $code -ne 0 ) { throw "run for $Name exited $code (expected 0): $(Get-Content (Join-Path $dir 'stderr.txt') -Raw)" }

    $beforeFile = Get-ChildItem $dir -Filter "*_before.json" | Select-Object -First 1
    $afterFile  = Get-ChildItem $dir -Filter "*_after.json"  | Select-Object -First 1
    if( -not $beforeFile -or -not $afterFile ) { throw "missing before/after snapshot in $dir" }

    $b = Get-Content $beforeFile.FullName -Raw | ConvertFrom-Json
    $a = Get-Content $afterFile.FullName  -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        Name      = $Name
        Dir       = $Direction
        BeforePos = $b.avatar.pos_abs
        AfterPos  = $a.avatar.pos_abs
        BeforeTurn= $b.backend.turn
        AfterTurn = $a.backend.turn
        BeforeMov = $b.avatar.moves
        AfterMov  = $a.avatar.moves
    }
}

$fail = 0

# --- Hard gate: a known-walkable cardinal MUST move the avatar and tick the world. ---
$s = Invoke-Scenario -Name "move_s_walkable" -Direction "move_s"
$dy = $s.AfterPos[1] - $s.BeforePos[1]
$dturn = $s.AfterTurn - $s.BeforeTurn
Write-Host ("[move_s] pos {0} -> {1} (dy={2})  turn {3} -> {4} (d={5})  moves {6} -> {7}" -f `
    ($s.BeforePos -join ','), ($s.AfterPos -join ','), $dy, $s.BeforeTurn, $s.AfterTurn, $dturn, $s.BeforeMov, $s.AfterMov)
if( $dy -ne 1 ) { Write-Host "  FAIL: move_s did not advance pos_abs.y by 1 (movement no-op regression!)" -ForegroundColor Red; $fail++ }
if( $dturn -le 0 ) { Write-Host "  FAIL: move_s did not advance backend.turn (the action did not complete!)" -ForegroundColor Red; $fail++ }
if( $dy -eq 1 -and $dturn -gt 0 ) { Write-Host "  PASS: unobstructed move_s advanced the avatar and ticked the world." -ForegroundColor Green }

# --- Hard gate: an unobstructed DIAGONAL move must advance the avatar diagonally and tick the world --
# the end-to-end witness for the 8-way move fix. At spawn the SE tile (86,86) and both orthogonal
# neighbors E (86,85) and S (85,86) are open t_floor, so the diagonal step is unobstructed (no
# squeeze-through-a-corner block). move_se -> ACTION_MOVE_BACK_RIGHT -> +x,+y. ---
$se = Invoke-Scenario -Name "move_se_walkable" -Direction "move_se"
$sedx = $se.AfterPos[0] - $se.BeforePos[0]
$sedy = $se.AfterPos[1] - $se.BeforePos[1]
$sedturn = $se.AfterTurn - $se.BeforeTurn
Write-Host ("[move_se] pos {0} -> {1} (dx={2},dy={3})  turn {4} -> {5} (d={6})" -f `
    ($se.BeforePos -join ','), ($se.AfterPos -join ','), $sedx, $sedy, $se.BeforeTurn, $se.AfterTurn, $sedturn)
if( $sedx -eq 1 -and $sedy -eq 1 -and $sedturn -gt 0 ) {
    Write-Host "  PASS: unobstructed move_se advanced the avatar DIAGONALLY (+1,+1) and ticked -- 8-way move is GUI-faithful end-to-end." -ForegroundColor Green
} else {
    Write-Host "  FAIL: move_se did not advance pos_abs by (+1,+1) (the SE diagonal step did not happen)." -ForegroundColor Red
    $fail++
}

# --- Informational (Spike 21): move_n into the stock shelter NPC now FAILS LOUD. ---
# move_n bumps NPC Edwardo and reaches game::npc_menu's UNARMED uilist, which the backend reports as
# unexpected_prompt (exit 14) instead of the old silent no-op. This run is driven inline (NOT via
# Invoke-Scenario, which throws on a nonzero exit) and is informational -- it depends on fixture NPC
# placement, so it is not a hard gate. The genuine terrain blocked_no_op witness now lives in
# client_harness_regression.ps1 (ArcopolisWallTest). See doc 15 (root cause) and
# docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md (the fail-loud).
$nDir = Join-Path $OutRoot "move_n_npc"
if( Test-Path $nDir ) { Remove-Item $nDir -Recurse -Force }
New-Item -ItemType Directory -Force $nDir | Out-Null
$nScript = Join-Path $nDir "script.json"
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "move_n" },
  { "op": "export",  "name": "after" }
] }
'@ | Set-Content -Encoding ascii $nScript
$np = Start-Process -FilePath $Exe -ArgumentList @(
    '--world', $World, '--arcopolis-run-script', $nScript, '--arcopolis-export-dir', $nDir, '--userdir', $UserDir
) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $nDir "stdout.txt") -RedirectStandardError (Join-Path $nDir "stderr.txt")
$nAfter = Get-ChildItem $nDir -Filter "*_after.json" -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ("[move_n] exit={0}  after_snapshot={1}" -f $np.ExitCode, [bool]$nAfter)
if( $np.ExitCode -eq 14 -and -not $nAfter ) {
    Write-Host "  INFO: move_n into NPC Edwardo fails loud (exit 14 / unexpected_prompt, no success snapshot) -- the old silent no-op was a tolerated artifact, not a true equivalence witness. See doc 43." -ForegroundColor Yellow
} else {
    Write-Host "  INFO: move_n exit $($np.ExitCode) (expected 14 / unexpected_prompt). The fixture NPC may have moved, or an NPC-interaction command now exists -- re-check doc 15/43." -ForegroundColor Yellow
}

if( $fail -gt 0 ) { Write-Host "MOVEMENT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "MOVEMENT REGRESSION: ok." -ForegroundColor Green
exit 0
