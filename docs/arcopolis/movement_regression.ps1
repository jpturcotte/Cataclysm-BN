<#
.SYNOPSIS
  Arcopolis movement regression scenario (the run-script / "RNS" integration layer).

.DESCRIPTION
  Drives the headless backend over the ArcopolisTest fixture and asserts that an UNOBSTRUCTED cardinal
  move actually moves the avatar -- so a movement no-op (like the move_n-into-NPC case in
  15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md) fails LOUDLY instead of passing silently.

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

  It also drives move_n and REPORTS the result: with the stock shelter NPC (Edwardo Stovall) on (85,84)
  this is the documented faithful no-op. That arm is informational (it depends on fixture NPC placement),
  not a hard gate -- see 15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md.

.NOTES
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions (AGENTS.md
  fixture section); kept verbatim so the commands stay copy-pasteable. No usernames/secrets.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_move_regress"
)

$ErrorActionPreference = "Stop"

if( -not (Test-Path $Exe) ) {
    Write-Error "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)"
    exit 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Write-Error "Fixture source directory not found: $FixtureSrc"
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

# --- Informational: move_n into the stock shelter NPC is the documented faithful no-op. ---
$n = Invoke-Scenario -Name "move_n_npc" -Direction "move_n"
$ndy = $n.AfterPos[1] - $n.BeforePos[1]
$ndturn = $n.AfterTurn - $n.BeforeTurn
Write-Host ("[move_n] pos {0} -> {1} (dy={2})  turn {3} -> {4} (d={5})  moves {6} -> {7}" -f `
    ($n.BeforePos -join ','), ($n.AfterPos -join ','), $ndy, $n.BeforeTurn, $n.AfterTurn, $ndturn, $n.BeforeMov, $n.AfterMov)
if( $ndy -eq 0 -and $ndturn -eq 0 ) {
    Write-Host "  INFO: move_n is a no-op here -- faithful: NPC Edwardo Stovall blocks (85,84). See doc 15." -ForegroundColor Yellow
} else {
    Write-Host "  INFO: move_n advanced -- the fixture NPC is not on (85,84) (regenerated world?), or an NPC-interaction command now exists. Re-check doc 15." -ForegroundColor Yellow
}

if( $fail -gt 0 ) { Write-Host "MOVEMENT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "MOVEMENT REGRESSION: ok." -ForegroundColor Green
exit 0
