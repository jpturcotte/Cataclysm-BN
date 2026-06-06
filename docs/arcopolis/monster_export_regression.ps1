<#
.SYNOPSIS
  Arcopolis monster-export regression scenario (the run-script / "RNS" integration layer).

.DESCRIPTION
  Drives the headless backend over the ArcopolisNearMonsterTest fixture and asserts the Spike 6A
  entities.monsters[] contract end-to-end: that a snapshot taken with a monster inside the radius-12
  export window actually CARRIES that monster, on an exported tile, and that the offline viewer agrees.

  Why a SECOND fixture (and a second script) instead of reusing ArcopolisTest:
    * In ArcopolisTest the nearest of the world's 14 monsters is Chebyshev 31 tiles away (see
      14_SPIKE6_MONSTER_EXPORT.md), so at the shipped radius 12 its entities.monsters[] is correctly
      present-but-EMPTY -- that fixture can never satisfy a `count > 0` gate. ArcopolisNearMonsterTest
      places ONE immobile monster (mon_fungal_wall) a few tiles from the avatar, INSIDE the window, so
      count>0 and off-window==0 are deterministic. movement_regression.ps1 stays the movement/NPC gate on
      ArcopolisTest, unchanged; this script is the monster-export witness on ArcopolisNearMonsterTest.

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as movement_regression.ps1):
    * It needs a fully loaded world. The pure command/script parsing is already covered by the
      world-independent [arcopolis] unit suite (tests/arcopolis_*_test.cpp). A fully automated, in-CI
      world-driven monster assertion still depends on the deferred `--arcopolis-new-world` generator
      (ARCOPOLIS_STATE.md backlog). Until that lands we drive the EXTERNAL fixture here and DO NOT fake
      world state.

  What it asserts (hard gates, on every exported snapshot):
    1. entities.monsters is PRESENT (the block exists -- an old binary / export regression fails loudly).
    2. entities.monsters count > 0 (the witness monster is in the radius-12 window).
    3. off-window == 0: every monster's pos_local equals some exported tile's (x,y,z) on the tiles' z
       (the window-equivalence invariant, computed locally -- the same check doc 14 spells out).
    4. The offline viewer (make_report.py) runs, exits 0, AND prints monsters_off_window=0.
  It also REPORTS (soft, non-fatal) whether each monster carries the 10-field contract
  (type_id/pos_local/pos_abs/hp/hp_max/moves/hallucination tested by PRESENCE, since hallucination is a
  bool that may legitimately be false). Flip the marked `$fail++` to make that a hard gate.

  Determinism note: mon_fungal_wall is an IMMOBILE-flagged type (src/mtype.h:123), so it does NOT wander
  turn-to-turn. make_monster_fixture.py places it on PASSABLE terrain (default grass), so it is EXACTLY
  stationary -- pos_abs/pos_local identical on every frame, every run, no --seed (validated [6301,6429]).
  (An in-wall placement instead drifts once via the game::monmove impassable-eject; root-caused in
  docs/arcopolis/17_MONSTER_LOAD_AND_WALL_EJECT.md.) The gate asserts in-window PRESENCE, which holds.

.NOTES
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions (AGENTS.md
  fixture section); kept verbatim so the commands stay copy-pasteable. No usernames/secrets.

  Create the fixture first: see docs/arcopolis/16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md. If the fixture world
  is missing this script exits 5 with a pointer to that doc.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisNearMonsterTest",
    [string]$OutRoot    = ".\out\arco_monster_regress",
    [string]$Viewer     = "tools\arcopolis_viewer\make_report.py"
)

$ErrorActionPreference = "Stop"

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N` does NOT
# work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error that unwinds BEFORE
# `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps it non-terminating so the
# labeled code is actually returned. (movement_regression.ps1's guards have the bare form and so collapse to
# exit 1 -- harmless there since its only other exit is 1, but this script's 3..7 scheme needs the real code.)
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=viewer). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $FixtureSrc" 4
}
# The monster fixture world must already exist inside the fixture userdir (doc 16 creates it). Use $World
# in the path so a rename stays correct; the layout is ...\arcopolis_user\save\<World>\.
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Monster fixture world '$World' not found at $fixtureWorld -- create it first: one IMMOBILE monster (e.g. mon_fungal_wall) a few tiles from the avatar, inside the radius-12 window. See docs/arcopolis/16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md." 5
}
# The viewer is a HARD gate here (unlike movement_regression.ps1, which never runs it), so its two
# prerequisites get their own codes.
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the offline viewer make_report.py). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Viewer) ) {
    Stop-WithCode "Offline viewer not found: $Viewer" 7
}

# Refresh the gitignored sandbox world from the external fixture. `Copy-Item -Recurse` nests the source
# INSIDE the destination when the destination already exists, so delete any existing sandbox first (same
# rationale as movement_regression.ps1). Copying the whole userdir brings BOTH worlds along; we only run
# $World, so the extra ArcopolisTest world is harmless.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

function Invoke-MonsterScenario {
    param([string]$Name)

    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export the witness at load, tick the world one turn (`wait`), then export again. On passable terrain
    # the IMMOBILE witness is stationary, so both frames show it at the same in-window tile (see doc 16/17).
    $scriptPath = Join-Path $dir "script.json"
    @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "witness_load" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "witness_after_tick" }
] }
'@ | Set-Content -Encoding ascii $scriptPath

    # cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and
    # leaves $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code.
    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $World,
        '--arcopolis-run-script', $scriptPath,
        '--arcopolis-export-dir', $dir,
        '--userdir', $UserDir
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")
    if( $p.ExitCode -ne 0 ) { throw "run for $Name exited $($p.ExitCode) (expected 0): $(Get-Content (Join-Path $dir 'stderr.txt') -Raw)" }

    # Select snapshots by the NNN_ prefix so we pick only NNN_<name>.json (excludes script.json, which is
    # also *.json); the numeric prefix orders them. session.jsonl is .jsonl, not matched.
    $snapFiles = Get-ChildItem $dir -Filter "*.json" |
                 Where-Object { $_.Name -match '^\d+_' } |
                 Sort-Object Name
    if( $snapFiles.Count -lt 1 ) { throw "no snapshot files produced in $dir" }
    $snaps = foreach( $f in $snapFiles ) {
        [pscustomobject]@{ File = $f.Name; Snap = (Get-Content $f.FullName -Raw | ConvertFrom-Json) }
    }
    return [pscustomobject]@{ Name = $Name; Dir = $dir; Snaps = $snaps }
}

$fail = 0
$scn  = Invoke-MonsterScenario -Name "witness"

# --- Hard gates 1..3, per exported snapshot. ---
foreach( $entry in $scn.Snaps ) {
    $file = $entry.File
    $snap = $entry.Snap

    # Gate 1: entities.monsters PRESENT. Test the property bag (not truthiness) so a missing block fails
    # loudly instead of slipping through as $null on a pre-Spike-6 / regressed snapshot.
    $hasEntities = $null -ne $snap.PSObject.Properties['entities']
    $hasMonsters = $hasEntities -and ($null -ne $snap.entities.PSObject.Properties['monsters'])
    if( -not $hasMonsters ) {
        Write-Host "  [$file] FAIL: snapshot has no entities.monsters block (old binary or export regression)." -ForegroundColor Red
        $fail++
        continue
    }

    # Gate 2: count > 0. Wrap with @() FIRST -- a single monster deserializes as a scalar, not an array.
    $mons = @($snap.entities.monsters)
    if( $mons.Count -lt 1 ) {
        Write-Host "  [$file] FAIL: entities.monsters present but EMPTY (count 0). The fixture monster is outside the radius-12 window -- re-place it within <=12 Chebyshev of the avatar." -ForegroundColor Red
        $fail++
        continue
    }

    # Gate 3: off-window == 0. Build the (x,y,z) set from tiles[], take the tiles' z, assert each monster's
    # pos_local is in the set and on that z (the doc-14 local pattern). Guard empty tiles[].
    $tiles = @($snap.tiles)
    if( $tiles.Count -lt 1 ) {
        Write-Host "  [$file] FAIL: monsters present but tiles[] is empty (window-equivalence cannot hold)." -ForegroundColor Red
        $fail++
        continue
    }
    $tz  = $tiles[0].z
    $set = @{}
    foreach( $t in $tiles ) { $set["$($t.x),$($t.y),$($t.z)"] = $true }
    $off = 0
    foreach( $m in $mons ) {
        # Guard: a malformed/regressed export with a missing or short pos_local must FAIL the gate cleanly,
        # not crash the runner -- under $ErrorActionPreference=Stop, indexing $null (e.g. $m.pos_local[0])
        # throws "Cannot index into a null array" and terminates the script.
        if( $null -eq $m.pos_local -or @($m.pos_local).Count -lt 3 ) { $off++; continue }
        $k = "$($m.pos_local[0]),$($m.pos_local[1]),$($m.pos_local[2])"
        if( $m.pos_local[2] -ne $tz -or -not $set.ContainsKey($k) ) { $off++ }
    }
    if( $off -ne 0 ) {
        Write-Host "  [$file] FAIL: $off monster(s) off the tile window (window-equivalence invariant broken)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  [$file] PASS: {0} monster(s), all in-window (off=0). e.g. {1} @ {2}" -f `
            $mons.Count, $mons[0].type_id, ($mons[0].pos_local -join ',')) -ForegroundColor Green
    }

    # Soft (report-only): every monster carries the 10-field contract. Test PRESENCE, not value, because
    # `hallucination` is a bool that can be $false. Add `$fail++` below to make this a hard gate.
    $required = 'type_id','pos_local','pos_abs','hp','hp_max','moves','hallucination'
    foreach( $m in $mons ) {
        $names   = $m.PSObject.Properties.Name
        $missing = $required | Where-Object { $_ -notin $names }
        if( $missing ) {
            Write-Host ("  [$file] WARN: monster index $($m.index) missing field(s): {0}" -f ($missing -join ', ')) -ForegroundColor Yellow
            # $fail++   # uncomment to make per-monster field presence a hard gate
        }
    }
}

# --- Hard gate 4: the offline viewer agrees (exit 0 AND monsters_off_window=0). ---
# Viewer exit 0 already ANDs monsters_off_window==0 into overall_pass (make_report.py build_model), but it
# does NOT require count>0 -- gates 2/3 above cover that. We also parse the printed count so a future viewer
# change that exits 0 while regressing the field is still caught.
$report = Join-Path $scn.Dir "report.html"
$vout   = Join-Path $scn.Dir "viewer_stdout.txt"
$verr   = Join-Path $scn.Dir "viewer_stderr.txt"
$pv = Start-Process -FilePath "python" -ArgumentList @(
    $Viewer, '--session-dir', $scn.Dir, '--output', $report
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $vout -RedirectStandardError $verr
$viewerExit = $pv.ExitCode
$viewerOut  = Get-Content $vout -Raw
$mw = [regex]::Match($viewerOut, 'monsters_off_window=(\d+)')

Write-Host ("[viewer] exit=$viewerExit  " + ($viewerOut.Trim()))
if( $viewerExit -ne 0 ) {
    Write-Host "  FAIL: viewer exited $viewerExit (0=clean; 2=discrepancies incl. off-window monsters; 1=fatal). See $verr / $report." -ForegroundColor Red
    $fail++
}
if( -not $mw.Success ) {
    Write-Host "  FAIL: could not parse 'monsters_off_window=' from viewer stdout (output format changed?). Raw: $($viewerOut.Trim())" -ForegroundColor Red
    $fail++
} elseif( [int]$mw.Groups[1].Value -ne 0 ) {
    Write-Host "  FAIL: viewer reports monsters_off_window=$($mw.Groups[1].Value) (expected 0)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 and monsters_off_window=0." -ForegroundColor Green
}

if( $fail -gt 0 ) { Write-Host "MONSTER EXPORT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "MONSTER EXPORT REGRESSION: ok." -ForegroundColor Green
exit 0
