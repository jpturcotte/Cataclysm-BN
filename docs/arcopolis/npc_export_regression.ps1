<#
.SYNOPSIS
  Arcopolis NPC-export regression scenario (the run-script / "RNS" integration layer).

.DESCRIPTION
  Drives the headless backend over the ArcopolisTest fixture and asserts the Spike 7A entities.npcs[]
  contract end-to-end: that a snapshot taken with an NPC inside the radius-12 export window actually
  CARRIES that NPC, on an exported tile, and that the NPC standing one tile north of the avatar is the
  documented move_n blocker (Edwardo Stovall in the canonical fixture). It also re-asserts that move_n is
  a faithful no-op (avatar does not move, world does not tick) -- now EXPLAINED by the exported NPC rather
  than invisible (see docs/arcopolis/15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md and 18_SPIKE7A_NPC_EXPORT.md).

  Why ArcopolisTest (and not a new fixture): the stock evac-shelter NPC Edwardo Stovall spawns one tile
  north of the avatar (local [85,84,0]), inside the radius-12 window, so entities.npcs[] is non-empty and
  the north-blocker gate is deterministic with NO save edit. ArcopolisTest is therefore now BOTH the
  movement/NPC-blocker fixture (gated by movement_regression.ps1) AND the NPC-export witness (this script);
  ArcopolisNearMonsterTest stays the monster-export witness (monster_export_regression.ps1).

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as the sibling scripts):
    * It needs a fully loaded world. The pure command/script parsing is already covered by the
      world-independent [arcopolis] unit suite (tests/arcopolis_*_test.cpp). A fully automated, in-CI
      world-driven assertion still depends on the deferred `--arcopolis-new-world` generator
      (ARCOPOLIS_STATE.md backlog). Until that lands we drive the EXTERNAL fixture here and DO NOT fake
      world state.

  What it asserts (hard gates):
    1. entities.npcs is PRESENT on every exported snapshot (property-bag test -- an old binary / export
       regression fails loudly, not silently as $null).
    2. off-window == 0 on every snapshot: every NPC's pos_local equals some exported tile's (x,y,z) on the
       tiles' z (the window-equivalence invariant, computed locally; the same check the monster script does).
    3. The "before" snapshot has entities.npcs count > 0.
    4. NORTH BLOCKER: from before.avatar.pos_local = [ax,ay,az], at least one NPC sits at [ax, ay-1, az].
       On success a clear PASS line names that NPC with its position and relationship flags.
    5. FAITHFUL NO-OP: after move_n, the "after" snapshot's avatar.pos_abs equals the "before" one's AND
       backend.turn is unchanged (the turn did not complete -> clean-park, world not ticked). avatar.moves
       is REPORTED but is NOT the primary signal (the "after" snapshot is at the next input rest where
       Creature::process_turn may have refilled moves -- the same idiom movement_regression.ps1 uses).
    6. The offline viewer (make_report.py) runs, exits 0, AND prints npcs_off_window=0.
  It also REPORTS (soft, non-fatal) every NPC's name + enemy/following/ally/stationary/halluc flags.

  Negative check (documented, NOT enforced here): running against a fixture WITHOUT the shelter NPC would
  fail gate 4 (no north blocker). This script is the positive witness; the negative is left to manual runs.

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
    [string]$OutRoot    = ".\out\arco_npc_regress",
    [string]$Viewer     = "tools\arcopolis_viewer\make_report.py"
)

$ErrorActionPreference = "Stop"

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N` does NOT
# work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error that unwinds BEFORE
# `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps it non-terminating so the
# labeled code is actually returned (see docs/arcopolis/16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# Lower-cased bool for the report/PASS lines ("true"/"false", matching the JSON + viewer wording).
function Flag { param($v) if( $v ) { "true" } else { "false" } }

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=viewer). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $FixtureSrc" 4
}
# ArcopolisTest ships in the canonical fixture userdir (it is the base world). Use $World in the path so a
# rename stays correct; the layout is ...\arcopolis_user\save\<World>\.
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
}
# The viewer is a HARD gate here, so its two prerequisites get their own codes.
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the offline viewer make_report.py). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Viewer) ) {
    Stop-WithCode "Offline viewer not found: $Viewer" 7
}

# Refresh the gitignored sandbox world from the external fixture. `Copy-Item -Recurse` nests the source
# INSIDE the destination when the destination already exists, so delete any existing sandbox first (same
# rationale as the sibling regression scripts).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

function Invoke-NpcScenario {
    param([string]$Name)

    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export the NPC blocker before the move, drive move_n (the documented no-op into Edwardo), then export
    # again. Both frames show the NPC on the tile immediately north of the avatar.
    $scriptPath = Join-Path $dir "script.json"
    @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "move_n" },
  { "op": "export",  "name": "after_move_n" }
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

    # Select snapshots by the NNN_ prefix so we pick only NNN_<name>.json (excludes script.json); the
    # numeric prefix orders them. session.jsonl is .jsonl, not matched.
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
$scn  = Invoke-NpcScenario -Name "npc_blocker"

# --- Hard gates 1 & 2, per exported snapshot. ---
foreach( $entry in $scn.Snaps ) {
    $file = $entry.File
    $snap = $entry.Snap

    # Gate 1: entities.npcs PRESENT. Test the property bag (not truthiness) so a missing block fails
    # loudly instead of slipping through as $null on a pre-Spike-7A / regressed snapshot.
    $hasEntities = $null -ne $snap.PSObject.Properties['entities']
    $hasNpcs     = $hasEntities -and ($null -ne $snap.entities.PSObject.Properties['npcs'])
    if( -not $hasNpcs ) {
        Write-Host "  [$file] FAIL: snapshot has no entities.npcs block (old binary or export regression)." -ForegroundColor Red
        $fail++
        continue
    }

    # Gate 2: off-window == 0. Build the (x,y,z) set from tiles[], take the tiles' z, assert each NPC's
    # pos_local is in the set and on that z. Wrap with @() FIRST -- a single NPC deserializes as a scalar.
    # Also filter $null elements: a MISSING/null property coerces to @($null), whose .Count is 1 (not 0),
    # which would silently defeat the `.Count -lt 1` guards below on a malformed/regressed snapshot.
    $npcs  = @($snap.entities.npcs | Where-Object { $null -ne $_ })
    $tiles = @($snap.tiles         | Where-Object { $null -ne $_ })
    if( $tiles.Count -lt 1 ) {
        Write-Host "  [$file] FAIL: tiles[] is empty (window-equivalence cannot hold)." -ForegroundColor Red
        $fail++
        continue
    }
    $tz  = $tiles[0].z
    $set = @{}
    foreach( $t in $tiles ) { $set["$($t.x),$($t.y),$($t.z)"] = $true }
    $off = 0
    foreach( $n in $npcs ) {
        # Guard a malformed/regressed export with a missing or short pos_local: under
        # $ErrorActionPreference=Stop, indexing $null (e.g. $n.pos_local[0]) throws and terminates.
        if( $null -eq $n.pos_local -or @($n.pos_local).Count -lt 3 ) { $off++; continue }
        $k = "$($n.pos_local[0]),$($n.pos_local[1]),$($n.pos_local[2])"
        if( $n.pos_local[2] -ne $tz -or -not $set.ContainsKey($k) ) { $off++ }
    }
    if( $off -ne 0 ) {
        Write-Host "  [$file] FAIL: $off npc(s) off the tile window (window-equivalence invariant broken)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  [$file] PASS: {0} npc(s), all in-window (off=0)." -f $npcs.Count) -ForegroundColor Green
    }

    # Soft (report-only): every NPC's name + relationship flags.
    foreach( $n in $npcs ) {
        Write-Host ("      npc[{0}] {1} @ {2}  enemy={3} following={4} ally={5} stationary={6} halluc={7}" -f `
            $n.index, $n.name, ($n.pos_local -join ','), (Flag $n.is_enemy), (Flag $n.is_following), `
            (Flag $n.is_player_ally), (Flag $n.is_stationary), (Flag $n.hallucination)) -ForegroundColor DarkGray
    }
}

# Locate the before / after snapshots by their NNN_<name>.json suffix.
$before = ($scn.Snaps | Where-Object { $_.File -like '*_before.json' }       | Select-Object -First 1)
$after  = ($scn.Snaps | Where-Object { $_.File -like '*_after_move_n.json' } | Select-Object -First 1)

# --- Hard gates 3 & 4: count > 0 and the north blocker, on the "before" snapshot. ---
if( -not $before ) {
    Write-Host "  FAIL: no 'before' snapshot produced (expected NNN_before.json)." -ForegroundColor Red
    $fail++
} else {
    # Filter $null (see Gate 2): a missing/null npcs property coerces to @($null) (.Count 1), which would
    # otherwise bypass the count-0 check below and mis-report a missing block as "1 npc".
    $bnpcs = @($before.Snap.entities.npcs | Where-Object { $null -ne $_ })
    if( $bnpcs.Count -lt 1 ) {
        Write-Host "  FAIL: before snapshot has entities.npcs present but EMPTY (count 0). Expected the shelter NPC in the radius-12 window." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  PASS: before snapshot has {0} npc(s) in the radius-12 window." -f $bnpcs.Count) -ForegroundColor Green
    }

    # Gate 4: north blocker. expected NPC tile = [ax, ay-1, az] from before.avatar.pos_local.
    $apl = $before.Snap.avatar.pos_local
    if( $null -eq $apl -or @($apl).Count -lt 3 ) {
        Write-Host "  FAIL: before snapshot avatar.pos_local missing/short -- cannot compute the north tile." -ForegroundColor Red
        $fail++
    } else {
        $nx = $apl[0]; $ny = $apl[1] - 1; $nz = $apl[2]
        $blocker = $bnpcs | Where-Object {
            $_.pos_local -and @($_.pos_local).Count -ge 3 -and
            $_.pos_local[0] -eq $nx -and $_.pos_local[1] -eq $ny -and $_.pos_local[2] -eq $nz
        } | Select-Object -First 1
        if( $blocker ) {
            Write-Host ("  PASS: north blocker = {0} @ [{1},{2},{3}] enemy={4} following={5} ally={6} stationary={7} halluc={8}" -f `
                $blocker.name, $nx, $ny, $nz, (Flag $blocker.is_enemy), (Flag $blocker.is_following), `
                (Flag $blocker.is_player_ally), (Flag $blocker.is_stationary), (Flag $blocker.hallucination)) -ForegroundColor Green
        } else {
            Write-Host ("  FAIL: no NPC on the tile immediately north of the avatar ([{0},{1},{2}]). The move_n blocker is not exported (or the fixture NPC moved)." -f $nx, $ny, $nz) -ForegroundColor Red
            $fail++
        }
    }
}

# --- Hard gate 5: move_n is a faithful no-op (avatar did not move, world did not tick). ---
if( -not $before -or -not $after ) {
    Write-Host "  FAIL: missing before/after snapshot -- cannot check the move_n no-op." -ForegroundColor Red
    $fail++
} else {
    $bpos = $before.Snap.avatar.pos_abs; $apos = $after.Snap.avatar.pos_abs
    $bturn = $before.Snap.backend.turn;  $aturn = $after.Snap.backend.turn
    $posSame  = ($bpos -join ',') -eq ($apos -join ',')
    $turnSame = $bturn -eq $aturn
    Write-Host ("[move_n] pos {0} -> {1}   turn {2} -> {3}   moves {4} -> {5}" -f `
        ($bpos -join ','), ($apos -join ','), $bturn, $aturn, $before.Snap.avatar.moves, $after.Snap.avatar.moves)
    if( -not $posSame )  { Write-Host "  FAIL: avatar.pos_abs changed across move_n (expected a no-op into the NPC)." -ForegroundColor Red; $fail++ }
    if( -not $turnSame ) { Write-Host "  FAIL: backend.turn advanced across move_n (expected no tick on the clean-park no-op)." -ForegroundColor Red; $fail++ }
    if( $posSame -and $turnSame ) {
        Write-Host "  PASS: move_n is a faithful no-op (pos_abs and backend.turn unchanged) -- the exported NPC explains why. See doc 15/18." -ForegroundColor Green
    }
}

# --- Hard gate 6: the offline viewer agrees (exit 0 AND npcs_off_window=0). ---
# Viewer exit 0 already ANDs npcs_off_window==0 into overall_pass (make_report.py build_model), but it does
# NOT require count>0 -- gates 3/4 cover that. We also parse the printed count so a future viewer change
# that exits 0 while regressing the field is still caught.
$report = Join-Path $scn.Dir "report.html"
$vout   = Join-Path $scn.Dir "viewer_stdout.txt"
$verr   = Join-Path $scn.Dir "viewer_stderr.txt"
$pv = Start-Process -FilePath "python" -ArgumentList @(
    $Viewer, '--session-dir', $scn.Dir, '--output', $report
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $vout -RedirectStandardError $verr
$viewerExit = $pv.ExitCode
$viewerOut  = Get-Content $vout -Raw
$nw = [regex]::Match($viewerOut, 'npcs_off_window=(\d+)')

Write-Host ("[viewer] exit=$viewerExit  " + ($viewerOut.Trim()))
if( $viewerExit -ne 0 ) {
    Write-Host "  FAIL: viewer exited $viewerExit (0=clean; 2=discrepancies incl. off-window npcs; 1=fatal). See $verr / $report." -ForegroundColor Red
    $fail++
}
if( -not $nw.Success ) {
    Write-Host "  FAIL: could not parse 'npcs_off_window=' from viewer stdout (output format changed?). Raw: $($viewerOut.Trim())" -ForegroundColor Red
    $fail++
} elseif( [int]$nw.Groups[1].Value -ne 0 ) {
    Write-Host "  FAIL: viewer reports npcs_off_window=$($nw.Groups[1].Value) (expected 0)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 and npcs_off_window=0." -ForegroundColor Green
}

if( $fail -gt 0 ) { Write-Host "NPC EXPORT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "NPC EXPORT REGRESSION: ok." -ForegroundColor Green
exit 0
