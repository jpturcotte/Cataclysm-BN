<#
.SYNOPSIS
  Arcopolis Spike 24 vertical-movement regression: prove a matched-stair down -> up ROUND TRIP on the
  ArcopolisStairsTest fixture, driven by the `vertical_move` command through the real
  handle_action() / do_turn() seam.

.DESCRIPTION
  Drives the headless backend over ArcopolisStairsTest (built by docs/arcopolis/make_stairs_fixture.py,
  Spike 23) with a five-step run-script: export before -> vertical_move down -> export after_down ->
  vertical_move up -> export after_up. The avatar starts standing ON t_stairs_down (z=0) with a matched
  t_stairs_up directly below (z=-1), so find_stairs hits its deterministic fast path (no fabrication, no
  query_yn) in BOTH directions (docs/arcopolis/47 section 4). The `vertical_move` verb resolves to the
  native ACTION_MOVE_DOWN / ACTION_MOVE_UP, which handle_action() dispatches to game::vertical_move; the
  backend never calls vertical_move directly and never mutates the avatar's position.

  Equivalence level: 2/3 (engine action reached, NOT registered-input level 4) -- exactly like planar
  `move`. This is a MATCHED-STAIR round trip only; it proves NOTHING about ramps/elevators/ladders/ropes/
  climbing/falling/generic vertical, 5-6 floor traversal, or simultaneous multi-z export.

  Hard gates (on the three snapshots + the session transcript):
    1. The run exits 0 and session.jsonl reports session_end status="ok" (no unexpected_prompt was
       reached; no success-by-silent-default).
    before:     pos_abs [6301,6421,0],  avatar.z 0,  avatar tile ter t_stairs_down.
    after_down: pos_abs [6301,6421,-1], avatar.z -1, avatar tile ter t_stairs_up, x/y unchanged, and
                backend.turn advanced (the descend completed / world ticked). The avatar tile is read on
                the NEW z-level -- this is the per-floor-observation witness docs/arcopolis/47 section 4
                flagged as LIKELY-but-unwitnessed.
    after_up:   pos_abs [6301,6421,0],  avatar.z 0,  avatar tile ter t_stairs_down, x/y unchanged, and
                backend.turn advanced again (the ascend completed).

  Why a fixture-driven script and not a CI catch2 test (same reasoning as the sibling regressions):
    * It needs a fully loaded world. The world-independent command/script parsing + command_to_action
      vertical mapping are covered by the [arcopolis] unit suite. We drive the committed fixture and DO
      NOT fake world state or mutate the avatar position.

.NOTES
  Build the fixture first: python docs/arcopolis/make_stairs_fixture.py  (see TEST_FIXTURES.md). Run with
  `pwsh` (PowerShell 7), not `powershell` (5.1) -- 5.1 misreads BOM-less UTF-8 snapshots (fixtures/README.md).
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisStairsTest",
    [string]$OutRoot    = ".\out\arco_vertical_regress"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N` does NOT
# work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error that unwinds BEFORE
# `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps it non-terminating so the
# labeled code is actually returned (see 16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world,
# 6=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Stair fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- create it first: python docs/arcopolis/make_stairs_fixture.py (clones ArcopolisTest and writes a matched t_stairs_down/t_stairs_up pair). See docs/arcopolis/TEST_FIXTURES.md." 5
}

# MAX_PATH guard (exit 6): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).ProviderPath)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 6
}

# Refresh the gitignored sandbox userdir from the fixture. `Copy-Item -Recurse` nests the source INSIDE the
# destination when the destination already exists, so delete any existing sandbox first (same rationale as
# the sibling regressions). Copying the whole userdir brings every world along; we only run $World.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

$dir = Join-Path $OutRoot "roundtrip"
if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null

# The matched-stair round trip: down then up, with a snapshot before and after each leg.
$scriptPath = Join-Path $dir "script.json"
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "vertical_move", "direction": "down" },
  { "op": "export",  "name": "after_down" },
  { "op": "command", "command": "vertical_move", "direction": "up" },
  { "op": "export",  "name": "after_up" }
] }
'@ | Set-Content -Encoding ascii $scriptPath

# cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and leaves
# $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code.
# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach the exe's parser split into broken tokens.
$p = Start-Process -FilePath $Exe -ArgumentList @(
    '--world', $World,
    '--arcopolis-run-script', "`"$scriptPath`"",
    '--arcopolis-export-dir', "`"$dir`"",
    '--userdir', "`"$UserDir`""
) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")

$fail = 0

# Gate 1a: process exit 0 (a vertical_move sub-prompt would fail loud, exit 14 -- not 0).
if( $p.ExitCode -ne 0 ) {
    Write-Host "  FAIL: run exited $($p.ExitCode) (expected 0): $(Format-ArcoPath (Get-Content (Join-Path $dir 'stderr.txt') -Raw))" -ForegroundColor Red
    $fail++
}

# Gate 1b: session.jsonl session_end status == "ok" (no unexpected_prompt, no silent default).
$sessionLog = Join-Path $dir "session.jsonl"
if( -not (Test-Path $sessionLog) ) {
    Write-Host "  FAIL: no session.jsonl produced in $(Format-ArcoPath $dir)." -ForegroundColor Red
    $fail++
} else {
    $endLine = Get-Content $sessionLog | Where-Object { $_ -match '"session_end"' } | Select-Object -Last 1
    if( -not $endLine ) {
        Write-Host "  FAIL: session.jsonl has no session_end event." -ForegroundColor Red
        $fail++
    } else {
        $endEvt = $endLine | ConvertFrom-Json
        if( $endEvt.status -ne "ok" ) {
            Write-Host "  FAIL: session_end status='$($endEvt.status)' (expected 'ok' -- a vertical_move sub-prompt or load error)." -ForegroundColor Red
            $fail++
        } else {
            Write-Host "  PASS: clean run (exit 0, session_end ok -- no unexpected prompt)." -ForegroundColor Green
        }
    }
}

# Load a named snapshot (NNN_<name>.json; the final-on-exit snapshot is NNN_final.json, so these suffixes
# never collide) and extract the avatar scalars + the single is_avatar tile's terrain/z.
function Get-Snapshot {
    param([string]$NameSuffix)
    $f = Get-ChildItem $dir -Filter "*_$NameSuffix.json" | Select-Object -First 1
    if( -not $f ) { return $null }
    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
    # Filter $null (a missing tiles property coerces to @($null), whose .Count is 1, bypassing guards).
    $tiles = @($s.tiles | Where-Object { $null -ne $_ })
    $avatarTiles = @($tiles | Where-Object { $_.is_avatar -eq $true })
    $aTer = $null
    $aZ = $null
    if( $avatarTiles.Count -eq 1 ) { $aTer = $avatarTiles[0].ter; $aZ = $avatarTiles[0].z }
    return [pscustomobject]@{
        PosAbs      = @($s.avatar.pos_abs)
        Z           = $s.avatar.z
        Turn        = $s.backend.turn
        AvatarTileN = $avatarTiles.Count
        AvatarTer   = $aTer
        AvatarTileZ = $aZ
    }
}

# Assert one stage's full tuple: pos_abs == [EX,EY,EZ], avatar.z == EZ, exactly one is_avatar tile whose
# ter == ETer on z EZ. Uses $script:fail so failures aggregate across stages.
function Assert-Stage {
    param([string]$Label, $Snap, [int]$EX, [int]$EY, [int]$EZ, [string]$ETer)
    $ok = $true
    $abs = $Snap.PosAbs
    if( $abs.Count -lt 3 -or $abs[0] -ne $EX -or $abs[1] -ne $EY -or $abs[2] -ne $EZ ) {
        Write-Host "  FAIL [$Label]: pos_abs = [$($abs -join ',')] (expected [$EX,$EY,$EZ])." -ForegroundColor Red; $script:fail++; $ok = $false
    }
    if( $Snap.Z -ne $EZ ) {
        Write-Host "  FAIL [$Label]: avatar.z = $($Snap.Z) (expected $EZ)." -ForegroundColor Red; $script:fail++; $ok = $false
    }
    if( $Snap.AvatarTileN -ne 1 ) {
        Write-Host "  FAIL [$Label]: $($Snap.AvatarTileN) tile(s) with is_avatar==true (expected exactly 1)." -ForegroundColor Red; $script:fail++; $ok = $false
    } else {
        if( $Snap.AvatarTer -ne $ETer ) {
            Write-Host "  FAIL [$Label]: avatar tile ter = '$($Snap.AvatarTer)' (expected '$ETer')." -ForegroundColor Red; $script:fail++; $ok = $false
        }
        if( $Snap.AvatarTileZ -ne $EZ ) {
            Write-Host "  FAIL [$Label]: avatar tile z = $($Snap.AvatarTileZ) (expected $EZ)." -ForegroundColor Red; $script:fail++; $ok = $false
        }
    }
    if( $ok ) { Write-Host "  PASS [$Label]: pos_abs [$EX,$EY,$EZ], avatar.z $EZ, avatar tile '$ETer' on z $EZ." -ForegroundColor Green }
}

$before    = Get-Snapshot "before"
$afterDown = Get-Snapshot "after_down"
$afterUp   = Get-Snapshot "after_up"

if( -not $before -or -not $afterDown -or -not $afterUp ) {
    Write-Host "  FAIL: missing one of the before/after_down/after_up snapshots in $(Format-ArcoPath $dir)." -ForegroundColor Red
    $fail++
} else {
    # before: standing ON the down-stair at z 0 (the Spike 23 fixture baseline).
    Assert-Stage -Label "before" -Snap $before -EX 6301 -EY 6421 -EZ 0 -ETer "t_stairs_down"

    # after_down: descended one z to the matched up-stair; x/y unchanged; the world ticked.
    Assert-Stage -Label "after_down" -Snap $afterDown -EX 6301 -EY 6421 -EZ -1 -ETer "t_stairs_up"
    if( ($afterDown.Turn - $before.Turn) -le 0 ) {
        Write-Host "  FAIL: backend.turn did not advance on vertical_move down ($($before.Turn) -> $($afterDown.Turn))." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: backend.turn advanced on vertical_move down ($($before.Turn) -> $($afterDown.Turn))." -ForegroundColor Green
    }

    # after_up: ascended back to the original floor and tile; x/y unchanged; the world ticked again.
    Assert-Stage -Label "after_up" -Snap $afterUp -EX 6301 -EY 6421 -EZ 0 -ETer "t_stairs_down"
    if( ($afterUp.Turn - $afterDown.Turn) -le 0 ) {
        Write-Host "  FAIL: backend.turn did not advance on vertical_move up ($($afterDown.Turn) -> $($afterUp.Turn))." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: backend.turn advanced on vertical_move up ($($afterDown.Turn) -> $($afterUp.Turn))." -ForegroundColor Green
    }
}

if( $fail -gt 0 ) { Write-Host "VERTICAL MOVEMENT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "VERTICAL MOVEMENT REGRESSION: ok." -ForegroundColor Green
exit 0
