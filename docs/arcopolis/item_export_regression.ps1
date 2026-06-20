<#
.SYNOPSIS
  Arcopolis ground-item-export regression scenario (the run-script / "RNS" integration layer).

.DESCRIPTION
  Drives the headless backend over the ArcopolisTest fixture and asserts the Spike 8A entities.items[]
  contract end-to-end: that a snapshot taken with ground items inside the radius-12 export window actually
  CARRIES those items, each on an exported tile, and that the export survives a world tick (a `wait`).

  Why ArcopolisTest (and not a new fixture): ArcopolisTest is a *saved* world, so its evac-shelter mapgen
  rolls are frozen into concrete data. A read-only scan of its map.sqlite3 found 27 deterministic ground
  items within the radius-12 window (closest: evac_pamphlet at abs [6301,6423,0], i.e. (0,+2) from the
  avatar at abs [6301,6421,0]), so entities.items[] is non-empty with NO save edit. ArcopolisTest is
  therefore the item-export witness, exactly as it is the NPC-export witness (npc_export_regression.ps1).
  This script asserts tile/window invariants, not the specific witness item; see
  docs/arcopolis/19_SPIKE8A_ITEM_EXPORT.md.

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as the sibling scripts):
    * It needs a fully loaded world. The pure command/script parsing is already covered by the
      world-independent [arcopolis] unit suite (tests/arcopolis_*_test.cpp). A fully automated, in-CI
      world-driven assertion still depends on the deferred `--arcopolis-new-world` generator
      (ARCOPOLIS_STATE.md backlog). Until that lands we drive the EXTERNAL fixture here and DO NOT fake
      world state.

  What it asserts (hard gates):
    1. entities.items is PRESENT on every exported snapshot (property-bag test -- an old binary / export
       regression fails loudly, not silently as $null).
    2. off-window == 0 on every snapshot: every item's pos_local equals some exported tile's (x,y,z) on the
       tiles' z (the window-equivalence invariant, computed locally; the same check the npc/monster scripts
       do). A malformed item (missing/short pos_local) counts as off-window.
    3. The "items_before" snapshot has entities.items count > 0 (the deterministic in-window witness).
    4. The "items_after_wait" snapshot still has entities.items PRESENT and all in-window (the export
       survives a world tick).
    5. The offline viewer (make_report.py) runs, exits 0, AND prints items_off_window=0.
  It also REPORTS (soft, non-fatal) the item count and the nearest item to the avatar per snapshot.

  Deliberately NOT gated (per the spike's "prefer tile/window invariants over fragile item metadata"):
    * exact item count across the wait (items may rot/settle over ticks);
    * specific item names or tiles (the witness is documented, not asserted).

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
    [string]$OutRoot    = ".\out\arco_item_regress",
    [string]$Viewer     = "tools\arcopolis_viewer\make_report.py"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N` does NOT
# work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error that unwinds BEFORE
# `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps it non-terminating so the
# labeled code is actually returned (see docs/arcopolis/16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# Lower-cased bool for the report lines ("true"/"false", matching the JSON + viewer wording).
function Flag { param($v) if( $v ) { "true" } else { "false" } }

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=viewer). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $FixtureSrc  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
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

function Invoke-ItemScenario {
    param([string]$Name)

    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export the ground items, drive one `wait` (a world tick), then export again. Items are static map
    # contents, so both frames should carry the same in-window loot (we do NOT assert exact equality).
    $scriptPath = Join-Path $dir "script.json"
    @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "items_before" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "items_after_wait" }
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
$scn  = Invoke-ItemScenario -Name "item_export"

# --- Hard gates 1 & 2, per exported snapshot. ---
foreach( $entry in $scn.Snaps ) {
    $file = $entry.File
    $snap = $entry.Snap

    # Gate 1: entities.items PRESENT. Test the property bag (not truthiness) so a missing block fails
    # loudly instead of slipping through as $null on a pre-Spike-8A / regressed snapshot.
    $hasEntities = $null -ne $snap.PSObject.Properties['entities']
    $hasItems    = $hasEntities -and ($null -ne $snap.entities.PSObject.Properties['items'])
    if( -not $hasItems ) {
        Write-Host "  [$file] FAIL: snapshot has no entities.items block (old binary or export regression)." -ForegroundColor Red
        $fail++
        continue
    }

    # Gate 2: off-window == 0. Build the (x,y,z) set from tiles[], take the tiles' z, assert each item's
    # pos_local is in the set and on that z. Wrap with @() FIRST -- a single item deserializes as a scalar.
    # Also filter $null elements: a MISSING/null property coerces to @($null), whose .Count is 1 (not 0),
    # which would silently defeat the `.Count -lt 1` guards below on a malformed/regressed snapshot.
    $items = @($snap.entities.items | Where-Object { $null -ne $_ })
    $tiles = @($snap.tiles          | Where-Object { $null -ne $_ })
    if( $tiles.Count -lt 1 ) {
        Write-Host "  [$file] FAIL: tiles[] is empty (window-equivalence cannot hold)." -ForegroundColor Red
        $fail++
        continue
    }
    $tz  = $tiles[0].z
    $set = @{}
    foreach( $t in $tiles ) { $set["$($t.x),$($t.y),$($t.z)"] = $true }
    $off = 0
    foreach( $it in $items ) {
        # Guard a malformed/regressed export with a missing or short pos_local: under
        # $ErrorActionPreference=Stop, indexing $null (e.g. $it.pos_local[0]) throws and terminates.
        if( $null -eq $it.pos_local -or @($it.pos_local).Count -lt 3 ) { $off++; continue }
        $k = "$($it.pos_local[0]),$($it.pos_local[1]),$($it.pos_local[2])"
        if( $it.pos_local[2] -ne $tz -or -not $set.ContainsKey($k) ) { $off++ }
    }
    if( $off -ne 0 ) {
        Write-Host "  [$file] FAIL: $off item(s) off the tile window (window-equivalence invariant broken)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  [$file] PASS: {0} item(s), all in-window (off=0)." -f $items.Count) -ForegroundColor Green
    }

    # Soft (report-only): nearest item to the avatar (Chebyshev), to surface the witness for human eyes.
    $apl = $snap.avatar.pos_local
    if( $items.Count -ge 1 -and $null -ne $apl -and @($apl).Count -ge 3 ) {
        $nearest = $items |
            Where-Object { $_.pos_local -and @($_.pos_local).Count -ge 3 } |
            Sort-Object { [Math]::Max([Math]::Abs($_.pos_local[0] - $apl[0]), [Math]::Abs($_.pos_local[1] - $apl[1])) } |
            Select-Object -First 1
        if( $nearest ) {
            $d = [Math]::Max([Math]::Abs($nearest.pos_local[0] - $apl[0]), [Math]::Abs($nearest.pos_local[1] - $apl[1]))
            Write-Host ("      nearest item: {0} @ {1} (dist {2}) charges={3} count_by_charges={4}" -f `
                $nearest.type_id, ($nearest.pos_local -join ','), $d, $nearest.charges, (Flag $nearest.count_by_charges)) -ForegroundColor DarkGray
        }
    }
}

# Locate the before / after snapshots by their NNN_<name>.json suffix.
$before = ($scn.Snaps | Where-Object { $_.File -like '*_items_before.json' }     | Select-Object -First 1)
$after  = ($scn.Snaps | Where-Object { $_.File -like '*_items_after_wait.json' } | Select-Object -First 1)

# --- Hard gate 3: count > 0 on the "items_before" snapshot. ---
if( -not $before ) {
    Write-Host "  FAIL: no 'items_before' snapshot produced (expected NNN_items_before.json)." -ForegroundColor Red
    $fail++
} else {
    # Filter $null (see Gate 2): a missing/null items property coerces to @($null) (.Count 1), which would
    # otherwise bypass the count-0 check below and mis-report a missing block as "1 item".
    $bitems = @($before.Snap.entities.items | Where-Object { $null -ne $_ })
    if( $bitems.Count -lt 1 ) {
        Write-Host "  FAIL: items_before snapshot has entities.items present but EMPTY (count 0). Expected the evac-shelter loot in the radius-12 window." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  PASS: items_before snapshot has {0} ground item(s) in the radius-12 window." -f $bitems.Count) -ForegroundColor Green
    }
}

# --- Hard gate 4: items_after_wait still has entities.items present and all in-window. ---
# (Gates 1 & 2 already ran on every snapshot incl. after_wait; this makes the "export survives a tick"
# expectation explicit and named.)
if( -not $after ) {
    Write-Host "  FAIL: no 'items_after_wait' snapshot produced (expected NNN_items_after_wait.json)." -ForegroundColor Red
    $fail++
} else {
    $hasAfterItems = ($null -ne $after.Snap.PSObject.Properties['entities']) -and `
                     ($null -ne $after.Snap.entities.PSObject.Properties['items'])
    $aitems = @($after.Snap.entities.items | Where-Object { $null -ne $_ })
    if( -not $hasAfterItems ) {
        Write-Host "  FAIL: items_after_wait dropped the entities.items block after a world tick." -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("  PASS: items_after_wait still exports entities.items ({0} item(s)); per-snapshot gate 2 already asserted all in-window." -f $aitems.Count) -ForegroundColor Green
    }
}

# --- Hard gate 5: the offline viewer agrees (exit 0 AND items_off_window=0). ---
# Viewer exit 0 already ANDs items_off_window==0 into overall_pass (make_report.py build_model), but it does
# NOT require count>0 -- gate 3 covers that. We also parse the printed count so a future viewer change that
# exits 0 while regressing the field is still caught.
$report = Join-Path $scn.Dir "report.html"
$vout   = Join-Path $scn.Dir "viewer_stdout.txt"
$verr   = Join-Path $scn.Dir "viewer_stderr.txt"
$pv = Start-Process -FilePath "python" -ArgumentList @(
    $Viewer, '--session-dir', $scn.Dir, '--output', $report
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $vout -RedirectStandardError $verr
$viewerExit = $pv.ExitCode
$viewerOut  = Get-Content $vout -Raw
$iw = [regex]::Match($viewerOut, 'items_off_window=(\d+)')

Write-Host ("[viewer] exit=$viewerExit  " + ($viewerOut.Trim()))
if( $viewerExit -ne 0 ) {
    Write-Host "  FAIL: viewer exited $viewerExit (0=clean; 2=discrepancies incl. off-window items; 1=fatal). See $verr / $report." -ForegroundColor Red
    $fail++
}
if( -not $iw.Success ) {
    Write-Host "  FAIL: could not parse 'items_off_window=' from viewer stdout (output format changed?). Raw: $($viewerOut.Trim())" -ForegroundColor Red
    $fail++
} elseif( [int]$iw.Groups[1].Value -ne 0 ) {
    Write-Host "  FAIL: viewer reports items_off_window=$($iw.Groups[1].Value) (expected 0)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 and items_off_window=0." -ForegroundColor Green
}

if( $fail -gt 0 ) { Write-Host "ITEM EXPORT REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "ITEM EXPORT REGRESSION: ok." -ForegroundColor Green
exit 0
