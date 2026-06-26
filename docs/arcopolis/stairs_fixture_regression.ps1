<#
.SYNOPSIS
  Arcopolis Spike 23 stair-fixture regression: prove the ArcopolisStairsTest aligned two-floor stair
  fixture loads cleanly and the avatar starts standing ON t_stairs_down.

.DESCRIPTION
  Drives the headless backend over the ArcopolisStairsTest fixture (built by
  docs/arcopolis/make_stairs_fixture.py) with a single load-time `export`, and asserts that the
  pre-movement snapshot coherently reports the avatar's floor and stair tile. This is a FIXTURE-ONLY
  spike: it proves the SETUP for a later vertical-movement witness (Spike 24), NOT vertical movement
  itself. No `move_up` / `move_down` command is driven here.

  Why these gates (the matched-pair determinism of docs/arcopolis/47 section 4):
    * The fixture writes t_stairs_down on the avatar's own z=0 tile and t_stairs_up directly below at
      z=-1 (same x,y). A later `move_down` then hits find_stairs's deterministic fast path with no
      fabrication and no query_yn. This script proves the z=0 half of that setup THROUGH the engine
      (the single-z radius-12 export window cannot see the z=-1 tile); the z=-1 half is proven by the
      generator's own read-back, re-run here as gate 5 (`make_stairs_fixture.py --check-only`).

  Hard gates (on the load-time snapshot + the session transcript):
    1. The run exits 0 and session.jsonl reports session_end status="ok" (the world loaded cleanly).
    2. avatar.z == 0.
    3. avatar.pos_abs == [6301, 6421, 0] (the avatar did NOT move; the fixture only edits terrain).
    4. Exactly ONE tile carries is_avatar==true, and that tile's ter == "t_stairs_down" on z 0 (the
       avatar stands on the down-stair).
    5. The generator's --check-only re-asserts BOTH stair tiles in the sandbox world, including the
       z=-1 t_stairs_up the single-z snapshot cannot observe.

  Why a fixture-driven script and not a CI catch2 test (same reasoning as the sibling regressions):
    * It needs a fully loaded world. The world-independent command/script parsing is already covered
      by the [arcopolis] unit suite. We drive the committed fixture and DO NOT fake world state.

.NOTES
  Build the fixture first: python docs/arcopolis/make_stairs_fixture.py  (see TEST_FIXTURES.md). If the
  fixture world is missing this script exits 5 with a pointer. Run with `pwsh` (PowerShell 7), not
  `powershell` (5.1) -- 5.1 misreads BOM-less UTF-8 snapshots (see fixtures/README.md).
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisStairsTest",
    [string]$OutRoot    = ".\out\arco_stairs_regress",
    [string]$Generator  = "docs\arcopolis\make_stairs_fixture.py"
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

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=generator). ---
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
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed for the generator --check-only gate). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Generator) ) {
    Stop-WithCode "Stair fixture generator not found: $(Format-ArcoPath $Generator)" 7
}

# Refresh the gitignored sandbox userdir from the fixture. `Copy-Item -Recurse` nests the source INSIDE the
# destination when the destination already exists, so delete any existing sandbox first (same rationale as
# the sibling regressions). Copying the whole userdir brings every world along; we only run $World.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

$fail = 0

# --- Drive a single load-time export over the fixture. ---
$dir = Join-Path $OutRoot "witness"
if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null

$scriptPath = Join-Path $dir "script.json"
@'
{ "schema_version": 1, "steps": [
  { "op": "export", "name": "stairs_load" }
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

# Gate 1a: process exit 0.
if( $p.ExitCode -ne 0 ) {
    Write-Host "  FAIL: run exited $($p.ExitCode) (expected 0): $(Get-Content (Join-Path $dir 'stderr.txt') -Raw)" -ForegroundColor Red
    $fail++
}

# Gate 1b: session.jsonl session_end status == "ok".
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
            Write-Host "  FAIL: session_end status='$($endEvt.status)' (expected 'ok' -- world load/export error)." -ForegroundColor Red
            $fail++
        } else {
            Write-Host "  PASS: clean load (exit 0, session_end ok)." -ForegroundColor Green
        }
    }
}

# Locate the load-time snapshot (NNN_<name>.json; excludes script.json and session.jsonl).
$snapFiles = Get-ChildItem $dir -Filter "*.json" |
             Where-Object { $_.Name -match '^\d+_' } |
             Sort-Object Name
if( $snapFiles.Count -lt 1 ) {
    Write-Host "  FAIL: no snapshot file produced in $(Format-ArcoPath $dir)." -ForegroundColor Red
    $fail++
} else {
    $snap = Get-Content $snapFiles[0].FullName -Raw | ConvertFrom-Json

    # Gate 2: avatar.z == 0.
    if( $snap.avatar.z -ne 0 ) {
        Write-Host "  FAIL: avatar.z = $($snap.avatar.z) (expected 0)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: avatar.z == 0." -ForegroundColor Green
    }

    # Gate 3: avatar.pos_abs == [6301, 6421, 0] (the avatar did not move; the fixture only edits terrain).
    $expectedAbs = @(6301, 6421, 0)
    $abs = @($snap.avatar.pos_abs)
    if( $abs.Count -lt 3 -or $abs[0] -ne $expectedAbs[0] -or $abs[1] -ne $expectedAbs[1] -or $abs[2] -ne $expectedAbs[2] ) {
        Write-Host "  FAIL: avatar.pos_abs = [$($abs -join ',')] (expected [$($expectedAbs -join ',')] -- avatar moved or fixture drift)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: avatar.pos_abs == [6301, 6421, 0] (unmoved)." -ForegroundColor Green
    }

    # Gate 4: exactly one is_avatar tile, ter == t_stairs_down, on z 0.
    # Filter $null (a missing tiles property coerces to @($null), whose .Count is 1, bypassing guards).
    $tiles = @($snap.tiles | Where-Object { $null -ne $_ })
    $avatarTiles = @($tiles | Where-Object { $_.is_avatar -eq $true })
    if( $avatarTiles.Count -ne 1 ) {
        Write-Host "  FAIL: found $($avatarTiles.Count) tile(s) with is_avatar==true (expected exactly 1)." -ForegroundColor Red
        $fail++
    } else {
        $at = $avatarTiles[0]
        if( $at.ter -ne "t_stairs_down" ) {
            Write-Host "  FAIL: avatar tile ter = '$($at.ter)' (expected 't_stairs_down' -- the avatar is not standing on the down-stair)." -ForegroundColor Red
            $fail++
        } elseif( $at.z -ne 0 ) {
            Write-Host "  FAIL: avatar tile z = $($at.z) (expected 0)." -ForegroundColor Red
            $fail++
        } else {
            Write-Host "  PASS: avatar tile is t_stairs_down on z 0." -ForegroundColor Green
        }
    }
}

# --- Gate 5: the generator re-asserts BOTH stair tiles (incl. the z=-1 t_stairs_up the snapshot can't see). ---
# Run --check-only against the SANDBOX userdir: it asserts ArcopolisTest's source preconditions AND reads
# back ArcopolisStairsTest's matched pair (t_stairs_down at z=0, t_stairs_up at z=-1).
$gv = Join-Path $dir "generator_check.txt"
# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach python's argparse split into broken tokens.
$pg = Start-Process -FilePath "python" -ArgumentList @(
    "`"$Generator`"", '--check-only', '--fixture-root', "`"$UserDir`"", '--dest-world', $World
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $gv -RedirectStandardError (Join-Path $dir "generator_check_err.txt")
if( $pg.ExitCode -ne 0 ) {
    Write-Host "  FAIL: generator --check-only exited $($pg.ExitCode): $(Get-Content (Join-Path $dir 'generator_check_err.txt') -Raw)" -ForegroundColor Red
    $fail++
} elseif( -not (Select-String -Path $gv -Pattern 't_stairs_up' -Quiet) ) {
    Write-Host "  FAIL: generator --check-only did not confirm the z=-1 t_stairs_up read-back. Raw: $(Get-Content $gv -Raw)" -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: generator --check-only confirms both stair tiles (incl. z=-1 t_stairs_up)." -ForegroundColor Green
}

if( $fail -gt 0 ) { Write-Host "STAIRS FIXTURE REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "STAIRS FIXTURE REGRESSION: ok." -ForegroundColor Green
exit 0
