<#
.SYNOPSIS
  Arcopolis ONE-SHOT attacker-damage SMOKE witness (one-shot session-serialization fix).

.DESCRIPTION
  Proves the FIX end-to-end: the one-shot `--arcopolis-export-current-view` path now emits a POPULATED,
  correctly-attributed avatar.damage_taken[] when the single bootstrap do_turn lands a melee hit. BEFORE the
  fix this array was STRUCTURALLY ALWAYS EMPTY in one-shot mode -- end_backend_session() wiped the session
  before write_current_view drained it. The run-script path is the faithful reference
  (attacker_damage_regression.ps1); this is the one-shot sibling.

  *** EMPIRICAL SMOKE, FLAKY-RED-PRONE -- NOT the deterministic seal. *** One-shot runs exactly ONE do_turn,
  so the avatar gets the FEWEST melee rolls of any witness in the suite (one adjacent attacker, one tick). A
  landed hit is RNG-dependent (a miss records nothing) AND headless BN is not byte-deterministic even with
  --seed (worker-thread RNG + ASLR -- doc 56). So we run K one-shot runs and require >=1 to land an
  attributed hit: that closes vacuous-green (an all-miss across K runs FAILS LOUD, never a false green) but
  it does NOT make the witness deterministic. The DETERMINISTIC seal of the fix is the RNG-FREE Catch2
  tripwire (tests/arcopolis_backend_input_test.cpp, backend_assert_event_buffers_drained) plus the lexical
  serializer-purity test (.agents/arcopolis_serializer_purity_test.ts) -- this smoke is only the end-to-end
  empirical witness.

  FIXTURE: a hostile mon_zombie placed ADJACENT (offset 0,1,0, Chebyshev 1) to the avatar, GENERATED AT
  RUNTIME into the gitignored sandbox by cloning the committed ArcopolisTest (nothing new is committed). An
  adjacent attacker melee-attacks on the single bootstrap tick (the `wait` -> do_pause sets moves=0 ->
  do_turn's bottom half runs monmove -> the adjacent hostile attacks); the 2-south liveness placement only
  MOVES closer and never attacks in one tick, so it cannot witness one-shot damage.

  SOURCE SPECIFICITY: the asserted entry must be source_kind=="monster" AND source_type_id=="mon_zombie"
  AND amount>0 (the fixture's only hostile is the zombie; the stock NPC is a stationary ally and an npc).

  Run with `pwsh` (PowerShell 7), not `powershell` 5.1 (BOM-less UTF-8 / options.json BOM => phantom failures).
#>
[CmdletBinding()]
param(
    [string]$Exe         = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc  = "",
    [string]$UserDir     = ".\arcopolis_user",
    [string]$SourceWorld = "ArcopolisTest",
    [string]$World       = "ArcopolisAdjacentAttackerTest",
    [string]$Offset      = "0,1,0",
    [string]$OutRoot     = ".\out\arco_oneshot_damage",
    [string[]]$Seeds     = @("os-01", "os-02", "os-03", "os-04", "os-05", "os-06",
        "os-07", "os-08", "os-09", "os-10", "os-11", "os-12")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper (a bare `Write-Error; exit N` collapses to exit 1 under $ErrorActionPreference=Stop).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (3=exe, 4=fixture-root, 5=source world, 6=python, 8=sandbox-path-too-long -- the MAX_PATH
# guard below the block; 7 is the fixture-generation failure after the sandbox refresh). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore docs\arcopolis\fixtures\arcopolis_user)" 4
}
$srcWorld = Join-Path $FixtureSrc (Join-Path "save" $SourceWorld)
if( -not (Test-Path $srcWorld) ) {
    Stop-WithCode "Source world '$SourceWorld' not found at $(Format-ArcoPath $srcWorld)" 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to generate the adjacent-attacker fixture from ArcopolisTest)" 6
}

# MAX_PATH guard (exit 8): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).ProviderPath)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 8
}

# Refresh the gitignored sandbox from the committed pack, then GENERATE the adjacent-attacker fixture INSIDE
# it (clones the sandbox's ArcopolisTest -> ArcopolisAdjacentAttackerTest). Nothing new is committed; the
# headless backend exits via std::_Exit and never writes the world back, so every run loads identical state.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

$gen = Join-Path $PSScriptRoot "make_monster_fixture.py"
& python $gen --fixture-root $UserDir --source-world $SourceWorld --dest-world $World `
    --monster mon_zombie --offset $Offset --anger 100 --morale 100 --aggro-character --force
if( $LASTEXITCODE -ne 0 ) { Stop-WithCode "adjacent-attacker fixture generation failed (exit $LASTEXITCODE)" 7 }

# One-shot command: a single 'wait' (ACTION_PAUSE) -> one bootstrap do_turn -> monmove -> adjacent attack.
$cmdFile = Join-Path $OutRoot "wait.json"
'{ "schema_version": 1, "command": "wait" }' | Set-Content -Encoding ascii $cmdFile

$hitRuns = 0
$run = 0
foreach( $seed in $Seeds ) {
    $run++
    $out = Join-Path $OutRoot ("snap_{0}.json" -f $seed)
    $err = Join-Path $OutRoot ("stderr_{0}.txt" -f $seed)
    if( Test-Path $out ) { Remove-Item $out -Force }
    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $World, '--seed', $seed,
        '--arcopolis-export-current-view', "`"$out`"",
        '--arcopolis-command', "`"$cmdFile`"",
        '--userdir', "`"$UserDir`""
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $OutRoot ("stdout_{0}.txt" -f $seed)) -RedirectStandardError $err
    if( $p.ExitCode -ne 0 ) {
        throw "one-shot run (seed '$seed') exited $($p.ExitCode) (expected 0): $(Format-ArcoPath (Get-Content $err -Raw))"
    }
    if( -not (Test-Path $out) ) { throw "one-shot run (seed '$seed') wrote no snapshot at $(Format-ArcoPath $out)" }

    $snap = Get-Content $out -Raw | ConvertFrom-Json
    $attributed = @($snap.avatar.damage_taken | Where-Object {
            $_ -and $_.source_kind -eq 'monster' -and $_.source_type_id -eq 'mon_zombie' -and $_.amount -gt 0
        })
    if( $attributed.Count -ge 1 ) {
        $hitRuns++
        $amt = ($attributed | Measure-Object -Property amount -Sum).Sum
        Write-Host ("  [run $run/$($Seeds.Count) seed $seed] HIT   damage_taken entries: {0}  amount: {1}" -f `
                $attributed.Count, $amt) -ForegroundColor Green
    } else {
        Write-Host ("  [run $run/$($Seeds.Count) seed $seed] miss  (no attributed mon_zombie damage this single tick -- RNG)") `
            -ForegroundColor DarkGray
    }
}

if( $hitRuns -lt 1 ) {
    Write-Host ("ONE-SHOT DAMAGE SMOKE: FAIL -- 0 of $($Seeds.Count) one-shot runs recorded an attributed mon_zombie hit.") -ForegroundColor Red
    Write-Host ("  RNG-dependent (single bootstrap tick = fewest melee rolls in the suite) and must be RARE. The more") -ForegroundColor Red
    Write-Host ("  likely cause of a FIRST-run all-miss is a re-broken one-shot capture (avatar.damage_taken[] structurally") -ForegroundColor Red
    Write-Host ("  empty again) -- the DETERMINISTIC gate is the Catch2 tripwire: run cata_test-tiles `"[arcopolis]`". If that") -ForegroundColor Red
    Write-Host ("  gate is green and this persists, raise -Seeds count or use a denser adjacent placement.") -ForegroundColor Red
    exit 1
}
Write-Host ("ONE-SHOT DAMAGE SMOKE: ok -- $hitRuns of $($Seeds.Count) one-shot runs emitted a populated, mon_zombie-attributed") -ForegroundColor Green
Write-Host ("avatar.damage_taken[] (one-shot capture-before-teardown works; empty runs are RNG misses, not the structural bug).") -ForegroundColor Green
exit 0
