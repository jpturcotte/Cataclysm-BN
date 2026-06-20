<#
.SYNOPSIS
  Arcopolis client-harness regression scenario (Spike 9A, the external player-loop proof).

.DESCRIPTION
  Drives the headless backend over the Arcopolis fixtures through the EXTERNAL consumer harness
  (tools/arcopolis_client/harness.py) and asserts it can run commands through the backend, classify
  every outcome, and build a local view from the Spikes 0-8A contract alone.

  SPIKE 21 RECLASSIFICATION: move_n into the shelter NPC Edwardo is NO LONGER a blocked_no_op. It bumps
  the NPC and reaches game::npc_menu's UNARMED uilist, which the backend now FAILS LOUD on
  (unexpected_prompt, exit 14) instead of silently auto-cancelling the menu. The old blocked_no_op baseline
  was a tolerated historical artifact (a hidden player-visible menu cancellation), not a true equivalence
  witness. So:
    * move_n into Edwardo (run mode) -> the harness surfaces run.exit_meaning="unexpected_prompt" (exit 14),
      classified DISTINCTLY -- not blocked_no_op, not success. The 'start' snapshot still shows Edwardo
      north; no success snapshot for the failed command.
    * the NORMAL outcomes (moved/waited/no_command) are witnessed by a separate move_s,wait run.
    * the blocked_no_op / blocked_by=terrain witness moves to a GENUINE terrain block: move_e into a
      t_wall on ArcopolisWallTest (built by make_wall_fixture.py), a real no-prompt no-op.
  See docs/arcopolis/43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md.

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as the sibling
  scripts): it needs a fully loaded world; the harness's own load/classify logic is exercised
  offline against recorded sessions during development, and this script is the live end-to-end
  gate. Outcome labels are DATA the harness reports - the gates assert the harness derives the RIGHT
  labels, while the backend behavior itself stays gated by movement_regression.ps1 / npc_export_regression.ps1.

  What it asserts (hard gates):
    1. FAIL LOUD: `harness.py run --commands move_n` exits 1 with run.exit_code=14,
       run.exit_meaning="unexpected_prompt"; the 'start' snapshot exists (Edwardo visible) and NO
       after-snapshot is written for the failed command. Not blocked_no_op, not success.
    2. NORMAL OUTCOMES: `harness.py run --commands move_s,wait` exits 0 with outcome_sequence exactly
       moved,waited,no_command and contract_check.ok.
    3. TERRAIN BLOCKED_NO_OP: `harness.py run --commands move_e --world ArcopolisWallTest` exits 0 with
       outcome_sequence blocked_no_op,no_command; pair 0 outcome blocked_no_op, destination.ter t_wall,
       turn_delta 0, pos_abs_delta 0,0,0 -- a GENUINE no-prompt block (the replacement witness). NOTE:
       blocked_by is NOT asserted to be "terrain" -- that harness branch needs dest.seen=true, but a
       headless run never populates LOS so every tile exports seen=false; the witness is the blocked_no_op
       classification (distinct from the move-into-NPC unexpected_prompt) on a real t_wall, not the
       seen-gated attribution (doc 43).
    4. VIEW: `harness.py view --at <north tile>` on the fail-loud run's 'start' snapshot exits 0 and the
       HTML carries the inspector markers (the NPC's name, t_floor, the move_n "one command away" hint).
       The blocker stays visible even though move_n now fails loud. Presence-only checks.
    5. DIAGONAL RUN MODE: `harness.py run --commands move_se` exits 0 as moved,no_command with
       pos_abs_delta 1,1,0 - 8-way movement is drivable through the contract consumer.
    6. The Spike 4 viewer agrees: make_report.py exits 0 on the clean normal-sequence session (two
       independent consumers accept the same contract artifacts).
    7. MONSTER FIXTURE: run mode over ArcopolisNearMonsterTest (the Spike 6B immobile-monster
       witness, built by make_monster_fixture.py) exits 0 as waited,no_command with
       contract_check.ok, the start snapshot carries >= 1 exported monster, and the HTML view of
       the monster's own tile (computed from the snapshot, not hardcoded) renders the 'M' monster
       cell with the inspector listing it -- the harness's monster path proven against a REAL
       monster, not just empty entities.monsters[] arrays.

.NOTES
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions
  (AGENTS.md fixture section); kept verbatim so the commands stay copy-pasteable. No
  usernames/secrets.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$MonsterWorld = "ArcopolisNearMonsterTest",
    [string]$WallWorld  = "ArcopolisWallTest",
    [string]$OutRoot    = ".\out\arco_client_regress",
    [string]$Harness    = "tools\arcopolis_client\harness.py",
    [string]$Viewer     = "tools\arcopolis_viewer\make_report.py"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N`
# does NOT work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error
# that unwinds BEFORE `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps
# it non-terminating so the labeled code is actually returned (see 16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=harness, 8=viewer). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $FixtureSrc  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
}
$monsterFixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $MonsterWorld)
if( -not (Test-Path $monsterFixtureWorld) ) {
    Stop-WithCode "Monster fixture world '$MonsterWorld' not found at $monsterFixtureWorld -- build it with docs/arcopolis/make_monster_fixture.py (see 16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md)." 5
}
$wallFixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $WallWorld)
if( -not (Test-Path $wallFixtureWorld) ) {
    Stop-WithCode "Wall fixture world '$WallWorld' not found at $wallFixtureWorld -- build it with docs/arcopolis/make_wall_fixture.py (the Spike 21 terrain blocked_no_op witness; see 43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md)." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the client harness and the offline viewer). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Harness) ) {
    Stop-WithCode "Client harness not found: $Harness" 7
}
if( -not (Test-Path $Viewer) ) {
    Stop-WithCode "Offline viewer not found: $Viewer (needed for the consumer cross-check gate)" 8
}

# Refresh the gitignored sandbox world from the external fixture. `Copy-Item -Recurse` nests the
# source INSIDE the destination when the destination already exists, so delete any existing
# sandbox first (same rationale as the sibling regression scripts).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run a python tool via Start-Process (captures the real exit code; `& python` of a long-running
# child plus redirection is fine too, but this matches the sibling scripts' idiom) and return
# exit code + stdout text.
function Invoke-PyTool {
    param([string[]]$ToolArgs, [string]$StdoutPath, [string]$StderrPath)
    $p = Start-Process -FilePath "python" -ArgumentList $ToolArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        Stdout   = (Get-Content $StdoutPath -Raw -ErrorAction SilentlyContinue)
    }
}

$fail = 0

# =============================================================================
# Gate 1 (Spike 21 headline): move_n into Edwardo FAILS LOUD, classified DISTINCTLY (not blocked_no_op).
# The harness `run` drives the backend; move_n bumps the NPC and reaches game::npc_menu's UNARMED uilist,
# so the backend exits 14 (unexpected_prompt) instead of silently auto-cancelling the menu. The harness
# surfaces this distinctly: harness exits 1 (fatal backend exit), run.exit_code=14,
# run.exit_meaning="unexpected_prompt" (NOT "blocked_no_op", NOT success). The `start` export still lands
# (Edwardo visible), but the failed command produces NO after-snapshot. The old single-run
# blocked_no_op,moved,waited,no_command sequence is gone -- move_n first now aborts the whole run -- so the
# normal outcomes move to Gate 2 and the blocked_no_op witness moves to the terrain Gate 3.
# =============================================================================
$failDir = Join-Path $OutRoot "run_failloud"
if( Test-Path $failDir ) { Remove-Item $failDir -Recurse -Force }
$failJson = Join-Path $OutRoot "run_failloud_result.json"
$pf = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $failDir, '--commands', 'move_n', '--json') `
    -StdoutPath $failJson -StderrPath (Join-Path $OutRoot "run_failloud_stderr.txt")
$fj = $null
try { $fj = $pf.Stdout | ConvertFrom-Json } catch {}
$startSnap = Get-ChildItem $failDir -Filter "*_start.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$afterSnap = Get-ChildItem $failDir -Filter "*_after_*move_n*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$failOk = $false
if( $fj -and $fj.run ) {
    $failOk = ($pf.ExitCode -eq 1) -and ($fj.run.exit_code -eq 14) -and
              ($fj.run.exit_meaning -eq 'unexpected_prompt') -and $startSnap -and (-not $afterSnap)
    if( -not $failOk ) {
        Write-Host "  FAIL: fail-loud move_n -- harness_exit=$($pf.ExitCode) run.exit_code=$($fj.run.exit_code) run.exit_meaning=$($fj.run.exit_meaning) start=$([bool]$startSnap) after=$([bool]$afterSnap) (expected 1 / 14 / unexpected_prompt / start present / no after)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: fail-loud move_n -- harness run produced no parseable run block. stdout: $($pf.Stdout)" -ForegroundColor Red
}
if( $failOk ) {
    Write-Host "  PASS: move_n into Edwardo fails loud via run mode -- run.exit_meaning=unexpected_prompt (exit 14), 'start' snapshot present (NPC visible), no success snapshot. Not blocked_no_op. See doc 43." -ForegroundColor Green
} else {
    $fail++
}

# =============================================================================
# Gate 2: the NORMAL outcomes still classify correctly (run mode: move_s then wait, on ArcopolisTest).
# move_s walks south (the start tile is clear), wait ticks, then the final-on-exit pair is no_command.
# =============================================================================
$normalDir = Join-Path $OutRoot "run_normal"
if( Test-Path $normalDir ) { Remove-Item $normalDir -Recurse -Force }
$normalJson = Join-Path $OutRoot "run_normal_result.json"
$pn = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $normalDir, '--commands', 'move_s,wait', '--json') `
    -StdoutPath $normalJson -StderrPath (Join-Path $OutRoot "run_normal_stderr.txt")
$normalOk = $false
if( $pn.ExitCode -eq 0 ) {
    $nj = $pn.Stdout | ConvertFrom-Json
    $nseq = (@($nj.summary.outcome_sequence) -join ',')
    $normalOk = ($nj.run.exit_code -eq 0) -and ($nseq -eq 'moved,waited,no_command') -and $nj.contract_check.ok
    if( -not $normalOk ) {
        Write-Host "  FAIL: normal run -- run.exit_code=$($nj.run.exit_code) outcomes='$nseq' contract_ok=$($nj.contract_check.ok) (expected 0 / moved,waited,no_command / true)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness run --commands move_s,wait exited $($pn.ExitCode) (expected 0). See $(Join-Path $OutRoot 'run_normal_stderr.txt')." -ForegroundColor Red
}
if( $normalOk ) {
    Write-Host "  PASS: normal sequence -- moved,waited,no_command (run.exit_code=0, contract ok)." -ForegroundColor Green
} else {
    $fail++
}

# =============================================================================
# Gate 3 (Spike 21 replacement blocked_no_op witness): a GENUINE terrain block. move_e into a t_wall on
# ArcopolisWallTest is rejected by the real avatar_action::move leaf with no move, no tick, and NO prompt
# (auto-bash needs the smash command; auto-mine needs a dig tool the avatar lacks). The harness keeps a
# live blocked_no_op / blocked_by=terrain witness even though move-into-NPC now fails loud. The fixture is
# built by docs/arcopolis/make_wall_fixture.py.
# =============================================================================
$wallDir = Join-Path $OutRoot "run_wall"
if( Test-Path $wallDir ) { Remove-Item $wallDir -Recurse -Force }
$wallJson = Join-Path $OutRoot "run_wall_result.json"
$pw = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $WallWorld, '--userdir', $UserDir,
    '--out', $wallDir, '--commands', 'move_e', '--json') `
    -StdoutPath $wallJson -StderrPath (Join-Path $OutRoot "run_wall_stderr.txt")
$wallOk = $false
if( $pw.ExitCode -eq 0 ) {
    $wj = $pw.Stdout | ConvertFrom-Json
    $wseq = (@($wj.summary.outcome_sequence) -join ',')
    $wpairs = @($wj.pairs | Where-Object { $null -ne $_ })
    $w0 = if( $wpairs.Count -ge 1 ) { $wpairs[0] } else { $null }
    # The essential witness is the OUTCOME blocked_no_op (genuine no-prompt block: no move, no tick) plus the
    # harness's destination analysis reading the real t_wall terrain from the authoritative export. We do NOT
    # require blocked_by=terrain: that branch needs dest.seen=true, but a HEADLESS run never populates the
    # player's LOS/map-memory, so EVERY tile exports seen=false at this point (the old NPC witness used
    # blocked_by=npc, which is seen-agnostic). Forcing terrain attribution would mean dropping the harness's
    # seen guard -- an external-consumer divergence from its own contract field, deliberately NOT done. So the
    # harness honestly reports "no obvious blocker" here; the witness is the blocked_no_op classification
    # itself (distinct from the move-into-NPC unexpected_prompt) on a genuine terrain block. See doc 43.
    $wallOk = ($wj.run.exit_code -eq 0) -and ($wseq -eq 'blocked_no_op,no_command') -and $wj.contract_check.ok -and
              $w0 -and ($w0.outcome -eq 'blocked_no_op') -and ($w0.destination.ter -eq 't_wall') -and
              ($w0.turn_delta -eq 0) -and ((@($w0.pos_abs_delta) -join ',') -eq '0,0,0')
    if( -not $wallOk ) {
        Write-Host "  FAIL: wall run -- run.exit_code=$($wj.run.exit_code) outcomes='$wseq' pair0.outcome=$($w0.outcome) dest.ter=$($w0.destination.ter) turn_delta=$($w0.turn_delta) pos_delta=$(@($w0.pos_abs_delta) -join ',') (expected 0 / blocked_no_op,no_command / blocked_no_op / t_wall / 0 / 0,0,0)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness run --commands move_e --world $WallWorld exited $($pw.ExitCode) (expected 0). See $(Join-Path $OutRoot 'run_wall_stderr.txt')." -ForegroundColor Red
}
if( $wallOk ) {
    Write-Host "  PASS: terrain blocked_no_op witness -- move_e into t_wall classified blocked_no_op (no move, no tick); harness reads the t_wall destination. blocked_by attribution withheld (tile exports seen=false headlessly; not bent). $($w0.explanation)" -ForegroundColor Green
} else {
    $fail++
}

# =============================================================================
# Gate 4: the HTML view + tile inspector still carries the NPC blocker (presence-only markers, not layout)
# -- even though move_n now fails loud, the start snapshot still shows Edwardo one tile north. Compute the
# north tile + blocker name directly from the fail-loud run's start snapshot (that run produced no pairs).
# =============================================================================
$viewOk = $false
if( $startSnap ) {
    $sjson = Get-Content $startSnap.FullName -Raw | ConvertFrom-Json
    $apl = @($sjson.avatar.pos_local)
    if( $apl.Count -ge 2 ) {
        $northAt = "$($apl[0]),$($apl[1] - 1)"
        $npcs = @($sjson.entities.npcs | Where-Object { $null -ne $_ })
        $northNpc = $npcs | Where-Object {
            @($_.pos_local).Count -ge 2 -and $_.pos_local[0] -eq $apl[0] -and $_.pos_local[1] -eq ($apl[1] - 1)
        } | Select-Object -First 1
        $blockerName = if( $northNpc ) { $northNpc.name } else { "Edwardo Stovall" }
        $viewHtml = Join-Path $failDir "view.html"
        $pv = Invoke-PyTool -ToolArgs @($Harness, 'view', '--session-dir', $failDir, '--output', $viewHtml, '--snapshot', 'start', '--at', $northAt) `
            -StdoutPath (Join-Path $failDir "view_stdout.txt") -StderrPath (Join-Path $failDir "view_stderr.txt")
        if( ($pv.ExitCode -eq 0) -and (Test-Path $viewHtml) ) {
            $htmlRaw = Get-Content $viewHtml -Raw
            $viewOk = $htmlRaw.Contains($blockerName) -and $htmlRaw.Contains('t_floor') -and
                      $htmlRaw.Contains('move_n') -and $htmlRaw.Contains('Tile inspector')
        }
    }
}
if( $viewOk ) {
    Write-Host "  PASS: view --at the north tile carries the NPC blocker + inspector markers (the blocker stays visible even though move_n fails loud)." -ForegroundColor Green
} else {
    Write-Host "  FAIL: view gate -- the start snapshot's north-tile HTML lacks the NPC name / t_floor / move_n / inspector markers (or view failed)." -ForegroundColor Red
    $fail++
}

# --- Hard gate 5: run mode drives a DIAGONAL move end-to-end. The 8-way move fix is only usable if
# the official client harness can express it -- the harness whitelists COMMAND_TOKENS and rejects
# unknown tokens BEFORE launching the backend, so a diagonal that the backend accepts but the harness
# rejects would be undrivable through the contract consumer. move_se from spawn (SE tile (86,86) and
# both orthogonal neighbors are open t_floor, so the diagonal is unobstructed) must be accepted, drive
# the backend, and classify as 'moved'. ---
$diagDir = Join-Path $OutRoot "run_diag"
if( Test-Path $diagDir ) { Remove-Item $diagDir -Recurse -Force }
$diagJson = Join-Path $OutRoot "run_diag_result.json"
$pd = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $diagDir, '--commands', 'move_se', '--json') `
    -StdoutPath $diagJson -StderrPath (Join-Path $OutRoot "run_diag_stderr.txt")
$diagOk = $false
if( $pd.ExitCode -eq 0 ) {
    $dj = $pd.Stdout | ConvertFrom-Json
    $dseq = (@($dj.summary.outcome_sequence) -join ',')
    $movedPair = @($dj.pairs | Where-Object { $_.outcome -eq 'moved' }) | Select-Object -First 1
    $ddelta = if( $movedPair ) { (@($movedPair.pos_abs_delta) -join ',') } else { '' }
    $diagOk = ($dj.run.exit_code -eq 0) -and ($dseq -eq 'moved,no_command') -and ($ddelta -eq '1,1,0') -and $dj.contract_check.ok
    if( -not $diagOk ) {
        Write-Host "  FAIL: run-mode diagonal -- run.exit_code=$($dj.run.exit_code) outcomes='$dseq' moved_delta='$ddelta' contract_ok=$($dj.contract_check.ok) (expected moved,no_command / 1,1,0)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness run --commands move_se exited $($pd.ExitCode) (expected 0 -- the diagonal token must NOT be rejected pre-launch). stderr: $(Get-Content (Join-Path $OutRoot 'run_diag_stderr.txt') -Raw -ErrorAction SilentlyContinue)" -ForegroundColor Red
}
if( $diagOk ) {
    Write-Host "  PASS: run mode (diagonal) -- harness accepted move_se, drove the backend, classified 'moved' with pos_abs delta (1,1,0): 8-way movement is drivable through the contract consumer." -ForegroundColor Green
} else {
    $fail++
}

# --- Hard gate 6: the Spike 4 viewer agrees (two independent consumers, one contract). Run it on the CLEAN
# normal-sequence session (Gate 2) -- the fail-loud run's transcript carries an error event the viewer would
# (correctly) flag as a discrepancy. ---
$report = Join-Path $normalDir "report.html"
$pview = Invoke-PyTool -ToolArgs @($Viewer, '--session-dir', $normalDir, '--output', $report) `
    -StdoutPath (Join-Path $normalDir "viewer_stdout.txt") -StderrPath (Join-Path $normalDir "viewer_stderr.txt")
Write-Host ("[viewer] exit=$($pview.ExitCode)  " + $pview.Stdout.Trim())
if( $pview.ExitCode -ne 0 ) {
    Write-Host "  FAIL: viewer exited $($pview.ExitCode) (0=clean; 2=discrepancies; 1=fatal) on the normal-sequence session." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 on the normal-sequence session (consumer cross-check)." -ForegroundColor Green
}

# --- Hard gate 7: the monster fixture (ArcopolisNearMonsterTest, the Spike 6B immobile witness). ---
# A second run-mode session proves the harness's monster path (cell bundles, 'M' overlay, inspector)
# against a REAL exported monster -- every ArcopolisTest session above carries an EMPTY
# entities.monsters[]. The sandbox $UserDir already holds this world (the fixture copy includes
# every save). The move-INTO-monster classifications (blocked_by=monster / bump-attack
# acted_in_place) stay unwitnessed: the witness sits 8 tiles out by design (doc 16/17).
$monDir  = Join-Path $OutRoot "monster_run"
if( Test-Path $monDir ) { Remove-Item $monDir -Recurse -Force }
$monJson = Join-Path $OutRoot "monster_run_result.json"
$pm = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $MonsterWorld, '--userdir', $UserDir,
    '--out', $monDir, '--commands', 'wait', '--json') `
    -StdoutPath $monJson -StderrPath (Join-Path $OutRoot "monster_run_stderr.txt")
$monOk = $false
$monsters = @()
$monWaitDelta = $null
if( $pm.ExitCode -eq 0 ) {
    $mj = $pm.Stdout | ConvertFrom-Json
    $mseq = (@($mj.summary.outcome_sequence) -join ',')
    # 'waited' alone no longer witnesses the tick: the classifier tolerates a zero-advance wait
    # (the bootstrap shape of pre-seam recorded sessions; doc 20 honesty notes), so the live
    # seam-timed path is asserted explicitly -- the wait pair must ADVANCE the turn.
    $mpairs = @($mj.pairs | Where-Object { $null -ne $_ })
    if( $mpairs.Count -ge 1 ) { $monWaitDelta = $mpairs[0].turn_delta }
    # Monster presence comes from the produced start snapshot (property-bag test + $null filter,
    # the house gotchas) -- the explain JSON's wait pair has no destination block to carry entities.
    $startSnapFile = Get-ChildItem $monDir -Filter "*.json" |
                     Where-Object { $_.Name -match '^\d+_start\.json$' } | Select-Object -First 1
    if( $startSnapFile ) {
        $startSnap = Get-Content $startSnapFile.FullName -Raw | ConvertFrom-Json
        $hasMon = ($null -ne $startSnap.PSObject.Properties['entities']) -and
                  ($null -ne $startSnap.entities.PSObject.Properties['monsters'])
        if( $hasMon ) { $monsters = @($startSnap.entities.monsters | Where-Object { $null -ne $_ }) }
    }
    $monOk = ($mj.run.exit_code -eq 0) -and ($mseq -eq 'waited,no_command') -and
             $mj.contract_check.ok -and ($monsters.Count -ge 1) -and
             ($null -ne $monWaitDelta) -and ($monWaitDelta -ge 1)
    if( -not $monOk ) {
        Write-Host "  FAIL: monster run-mode -- run.exit_code=$($mj.run.exit_code) outcomes='$mseq' contract_ok=$($mj.contract_check.ok) monsters=$($monsters.Count) wait_turn_delta=$monWaitDelta (expected 0 / waited,no_command / true / >=1 / >=1)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness run (monster fixture) exited $($pm.ExitCode) (expected 0). See $(Join-Path $OutRoot 'monster_run_stderr.txt')." -ForegroundColor Red
}
if( $monOk ) {
    # The HTML view must render the monster: inspect the monster's own tile (computed from the
    # snapshot, never hardcoded) and require the monster cell + its type_id in the inspector list.
    $mpl = @($monsters[0].pos_local)
    if( $mpl.Count -lt 3 ) {
        Write-Host "  FAIL: monster[0].pos_local missing/short -- cannot aim the view inspector." -ForegroundColor Red
        $fail++
    } else {
        $monAt   = "$($mpl[0]),$($mpl[1])"
        $monHtml = Join-Path $monDir "monster_view.html"
        $pmv = Invoke-PyTool -ToolArgs @($Harness, 'view', '--session-dir', $monDir, '--snapshot', 'start', '--output', $monHtml, '--at', $monAt) `
            -StdoutPath (Join-Path $monDir "view_stdout.txt") -StderrPath (Join-Path $monDir "view_stderr.txt")
        $monViewOk = $false
        if( ($pmv.ExitCode -eq 0) -and (Test-Path $monHtml) ) {
            $monRaw = Get-Content $monHtml -Raw
            $monViewOk = $monRaw.Contains("class='cell monster") -and
                         $monRaw.Contains($monsters[0].type_id) -and
                         $monRaw.Contains('Monsters on this tile (')
        }
        if( $monViewOk ) {
            Write-Host ("  PASS: monster fixture -- run mode waited (turn_delta +{2}),no_command with {0} @ [{1}]; view renders 'M' and the inspector lists it." -f $monsters[0].type_id, ($mpl -join ','), $monWaitDelta) -ForegroundColor Green
        } else {
            Write-Host "  FAIL: monster view gate -- exit=$($pmv.ExitCode), or monster_view.html lacks the monster cell / type_id / inspector list." -ForegroundColor Red
            $fail++
        }
    }
} else {
    $fail++
}

if( $fail -gt 0 ) { Write-Host "CLIENT HARNESS REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "CLIENT HARNESS REGRESSION: ok." -ForegroundColor Green
exit 0
