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
    5. FAIL LOUD (Spike 21): move_n into the NPC now reaches game::npc_menu's UNARMED uilist, which the
       backend reports as unexpected_prompt instead of silently auto-cancelling it. A separate run
       (export before -> move_n -> export after_move_n) must EXIT 14, write the "before" snapshot but NO
       "after_move_n" snapshot, and record EXACTLY ONE transcript `error` event kind=unexpected_prompt
       (one report from query(), none from init()). This replaces the old "faithful no-op" gate: the old
       blocked_no_op baseline was a tolerated historical artifact, not a true equivalence witness. See
       docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md.
    6. The offline viewer (make_report.py) runs on a CLEAN witness session (export only, exit 0), exits 0,
       AND prints npcs_off_window=0.
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
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_npc_regress",
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

# Lower-cased bool for the report/PASS lines ("true"/"false", matching the JSON + viewer wording).
function Flag { param($v) if( $v ) { "true" } else { "false" } }

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=viewer,
# 8=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
# ArcopolisTest ships in the canonical fixture userdir (it is the base world). Use $World in the path so a
# rename stays correct; the layout is ...\arcopolis_user\save\<World>\.
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
}
# The viewer is a HARD gate here, so its two prerequisites get their own codes.
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the offline viewer make_report.py). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Viewer) ) {
    Stop-WithCode "Offline viewer not found: $(Format-ArcoPath $Viewer)" 7
}

# MAX_PATH guard (exit 8): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).ProviderPath)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 8
}

# Refresh the gitignored sandbox world from the external fixture. `Copy-Item -Recurse` nests the source
# INSIDE the destination when the destination already exists, so delete any existing sandbox first (same
# rationale as the sibling regression scripts).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

function Invoke-NpcScenario {
    param([string]$Name, [string]$ScriptBody)

    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    $scriptPath = Join-Path $dir "script.json"
    $ScriptBody | Set-Content -Encoding ascii $scriptPath

    # cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and
    # leaves $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code.
    # Spike 21: do NOT throw on a nonzero exit -- the fail-loud scenario is EXPECTED to exit 14. The caller
    # asserts the exit code.
    # Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
    # a space (a spaced checkout/binary) would otherwise reach the exe's arg parser split into broken tokens.
    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $World,
        '--arcopolis-run-script', "`"$scriptPath`"",
        '--arcopolis-export-dir', "`"$dir`"",
        '--userdir', "`"$UserDir`""
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")

    # Select snapshots by the NNN_ prefix so we pick only NNN_<name>.json (excludes script.json); the
    # numeric prefix orders them. session.jsonl is .jsonl, not matched.
    $snapFiles = Get-ChildItem $dir -Filter "*.json" |
                 Where-Object { $_.Name -match '^\d+_' } |
                 Sort-Object Name
    $snaps = foreach( $f in $snapFiles ) {
        [pscustomobject]@{ File = $f.Name; Snap = (Get-Content $f.FullName -Raw | ConvertFrom-Json) }
    }
    # Parse the transcript events (one JSON object per line) so the fail-loud gate can assert the error event.
    $logPath = Join-Path $dir "session.jsonl"
    $events = @()
    if( Test-Path $logPath ) {
        $events = @(Get-Content $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{ Name = $Name; Dir = $dir; Snaps = $snaps; ExitCode = $p.ExitCode; Events = $events }
}

$fail = 0

# Witness scenario (CLEAN, exit 0): export the NPC blocker only. The "before" frame shows Edwardo one tile
# north of the avatar. This is the NPC-export witness (gates 1-4) and the viewer cross-check (gate 6) -- it
# carries NO failing command, so its transcript is clean and the viewer accepts it.
$witnessScript = @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" }
] }
'@
$scn = Invoke-NpcScenario -Name "npc_witness" -ScriptBody $witnessScript
if( $scn.ExitCode -ne 0 ) {
    Write-Host "  FAIL: witness run exited $($scn.ExitCode) (expected 0): $(Format-ArcoPath (Get-Content (Join-Path $scn.Dir 'stderr.txt') -Raw))" -ForegroundColor Red
    Write-Host "NPC EXPORT REGRESSION: aborting (witness run did not export cleanly)." -ForegroundColor Red
    exit 1
}

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

# Locate the before snapshot by its NNN_<name>.json suffix (the witness scenario's blocker frame).
$before = ($scn.Snaps | Where-Object { $_.File -like '*_before.json' } | Select-Object -First 1)

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

# --- Hard gate 5: move_n into the NPC FAILS LOUD (Spike 21). ---
# A separate run drives `export before -> move_n -> export after_move_n`. move_n bumps Edwardo, reaching
# game::npc_menu's UNARMED uilist; the backend now reports unexpected_prompt (exit 14) instead of silently
# auto-cancelling it. The `before` snapshot is still written (export ran before the failure); the run aborts
# at move_n, so NO `after_move_n` snapshot exists and the transcript carries EXACTLY ONE error event
# (kind=unexpected_prompt) -- one report from query(), none from init(). This replaces the old
# "faithful no-op" gate: the old blocked_no_op baseline was a tolerated historical artifact, not a true
# equivalence witness (docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md).
$failloudScript = @'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "move_n" },
  { "op": "export",  "name": "after_move_n" }
] }
'@
$fl = Invoke-NpcScenario -Name "npc_failloud" -ScriptBody $failloudScript
$flBefore = ($fl.Snaps | Where-Object { $_.File -like '*_before.json' }       | Select-Object -First 1)
$flAfter  = ($fl.Snaps | Where-Object { $_.File -like '*_after_move_n.json' } | Select-Object -First 1)
$errEvents = @($fl.Events | Where-Object { $_.event -eq 'error' })
$unexpected = @($errEvents | Where-Object { $_.kind -eq 'unexpected_prompt' })
Write-Host ("[move_n fail-loud] exit={0}  before={1}  after_move_n={2}  error_events={3}  unexpected_prompt={4}" -f `
    $fl.ExitCode, [bool]$flBefore, [bool]$flAfter, $errEvents.Count, $unexpected.Count)
$g5 = ($fl.ExitCode -eq 14) -and $flBefore -and (-not $flAfter) -and
      ($errEvents.Count -eq 1) -and ($unexpected.Count -eq 1)
if( $g5 ) {
    Write-Host "  PASS: move_n into the NPC fails loud -- exit 14, 'before' written, NO 'after_move_n' snapshot, exactly one unexpected_prompt error event (no init()+query() double report). See doc 43." -ForegroundColor Green
} else {
    if( $fl.ExitCode -ne 14 ) { Write-Host "  FAIL: move_n run exited $($fl.ExitCode) (expected 14 / unexpected_prompt). stderr: $(Format-ArcoPath (Get-Content (Join-Path $fl.Dir 'stderr.txt') -Raw -ErrorAction SilentlyContinue))" -ForegroundColor Red }
    if( -not $flBefore )       { Write-Host "  FAIL: no 'before' snapshot in the fail-loud run (it should be written before move_n fails)." -ForegroundColor Red }
    if( $flAfter )             { Write-Host "  FAIL: an 'after_move_n' snapshot exists (the failed command must not produce a success snapshot)." -ForegroundColor Red }
    if( $errEvents.Count -ne 1 -or $unexpected.Count -ne 1 ) { Write-Host "  FAIL: expected exactly ONE error event (kind=unexpected_prompt); got $($errEvents.Count) error event(s), $($unexpected.Count) unexpected_prompt." -ForegroundColor Red }
    $fail++
}

# --- Hard gate 6: the offline viewer agrees (exit 0 AND npcs_off_window=0). ---
# Viewer exit 0 already ANDs npcs_off_window==0 into overall_pass (make_report.py build_model), but it does
# NOT require count>0 -- gates 3/4 cover that. We also parse the printed count so a future viewer change
# that exits 0 while regressing the field is still caught.
$report = Join-Path $scn.Dir "report.html"
$vout   = Join-Path $scn.Dir "viewer_stdout.txt"
$verr   = Join-Path $scn.Dir "viewer_stderr.txt"
# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach python's argparse split into broken tokens.
$pv = Start-Process -FilePath "python" -ArgumentList @(
    "`"$Viewer`"", '--session-dir', "`"$($scn.Dir)`"", '--output', "`"$report`""
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $vout -RedirectStandardError $verr
$viewerExit = $pv.ExitCode
$viewerOut  = Get-Content $vout -Raw
$nw = [regex]::Match($viewerOut, 'npcs_off_window=(\d+)')

Write-Host ("[viewer] exit=$viewerExit  " + ($viewerOut.Trim()))
if( $viewerExit -ne 0 ) {
    Write-Host "  FAIL: viewer exited $viewerExit (0=clean; 2=discrepancies incl. off-window npcs; 1=fatal). See $(Format-ArcoPath $verr) / $(Format-ArcoPath $report)." -ForegroundColor Red
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
