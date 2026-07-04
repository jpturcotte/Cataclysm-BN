<#
.SYNOPSIS
  Arcopolis ATTACKER-ATTRIBUTED DAMAGE witness (Spike 27B).

.DESCRIPTION
  Drives the headless backend over ArcopolisLivenessTest (the SAME fixture as 27A -- no fixture
  change) and witnesses that the engine's OWN damage funnel attributed avatar damage to the hostile
  mon_zombie. Across [export, (wait,export) x N] the zombie pathfinds to the avatar (27A's liveness)
  and, once adjacent, melee-attacks it; a landed hit reaches Character::apply_damage(source=zombie)
  (src/character.cpp), where the gated Arcopolis tap records {source_kind, source_type_id, amount,
  bodypart, turn} into avatar.damage_taken[].

  CLAIM: equivalence level 1 (OBSERVATION ONLY), native-authority class S (raw simulation state = the
  engine's own in-scope `source` at the apply_damage funnel, the SAME pointer the GUI "You were attacked
  by %s!" message is built from). It drives NO registered input and makes NO level-4 claim. It is the
  FUNNEL FACT, not message-equivalence: the funnel value is recorded BEFORE the GUI's display filters
  (perception masks the per-hit combat message to "Something hits your X" when !g->u.sees(attacker),
  src/monster.cpp; the on_hurt distraction message is gated by painkiller/narcosis/disturb) -- a frontend
  renders its own message from this ground truth.

  *** RNG-DEPENDENT, NOT RNG-INVARIANT (the key difference from 27A). *** 27A's position gates are
  RNG-INVARIANT (the zombie ALWAYS approaches). 27B's gate is RNG-DEPENDENT: the funnel fires only on
  a LANDED HIT (apply_damage is hit-only; a miss never reaches it), so "took damage from the zombie"
  requires >=1 hit to land in N waits. With a generous N the zombie gets ~N-2 melee attempts once
  adjacent and a hit is EMPIRICALLY RELIABLE every run across seeds -- but it is NOT guaranteed by
  construction. A pathological all-miss run FAILS LOUD (empty damage_taken[] across every export), never
  a false green. We run THREE distinct seeds and require each to land at least one attributed hit;
  exact amount/bodypart/turn are RNG-dependent and NOT gated.

  SOURCE SPECIFICITY (not merely non-null): the asserted entry must be source_kind=="monster" AND
  source_type_id=="mon_zombie". The fixture's only hostile is the zombie; the stock shelter NPC Edwardo
  is a STATIONARY ALLY 1 tile north who does not damage the avatar (and is an npc, not a monster, so even
  an ally hit would not match). Self/environmental sources are excluded at the tap (source != avatar;
  fields/suffer pass a null source).

  WHAT THIS DOES NOT PROVE (scope; do not let docs widen it): the perception-gated GUI message; hit/miss;
  damage type; ranged-vs-melee (the surface mechanically captures any apply_damage source, but only MELEE
  mon_zombie is witnessed here); NPC-attacker attribution (captured as kind="npc" but unwitnessed); LOS /
  perception; full combat resolution.

  WHY a sibling script and not folded into world_tick_liveness_regression.ps1: 27A asserts ONLY
  RNG-INVARIANT gates and documents that invariance as its discipline. Mixing this RNG-DEPENDENT gate in
  would muddy that claim. Keeping it separate isolates the one RNG-dependent witness and labels it as
  such. Run with `pwsh` (PowerShell 7), not `powershell` 5.1 (BOM-less UTF-8 / options.json BOM =>
  phantom failures).

.NOTES
  Reuses the 27A fixture (create it first, one python invocation, no build):
    python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisLivenessTest `
        --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force
  If the fixture world is missing this script exits 5 with that pointer.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisLivenessTest",
    [string]$OutRoot    = ".\out\arco_attack_regress",
    [int]   $Waits      = 8,
    [string[]]$Seeds    = @("attack-alpha", "attack-bravo", "attack-charlie")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper (see world_tick_liveness_regression.ps1): a bare `Write-Error; exit N` collapses
# to exit 1 under $ErrorActionPreference=Stop; -ErrorAction Continue keeps the labeled code.
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (3=exe, 4=fixture, 5=world, 6=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Liveness fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- create it: python docs/arcopolis/make_monster_fixture.py --dest-world $World --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force" 5
}

# MAX_PATH guard (exit 6): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).Path)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 6
}

# Refresh the gitignored sandbox from the committed pack (delete first: Copy-Item -Recurse nests the
# source INSIDE an existing destination). One pristine copy serves all seeds -- the headless backend
# exits via std::_Exit and never writes the world back, so each run loads identical state.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

function Invoke-AttackRun {
    param([string]$Seed)

    $dir = Join-Path $OutRoot $Seed
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export at load, then (wait, export) x N -> the per-turn trajectory and per-turn damage windows.
    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('{ "op": "export", "name": "t0" }')
    foreach( $i in 1..$Waits ) {
        $steps.Add('{ "op": "command", "command": "wait" }')
        $steps.Add( '{ "op": "export", "name": "t' + $i + '" }' )
    }
    $scriptPath = Join-Path $dir "script.json"
    ('{ "schema_version": 1, "steps": [ ' + ($steps -join ", ") + ' ] }') | Set-Content -Encoding ascii $scriptPath

    $p = Start-Process -FilePath $Exe -ArgumentList @(
        '--world', $World, '--seed', $Seed,
        '--arcopolis-run-script', "`"$scriptPath`"",
        '--arcopolis-export-dir', "`"$dir`"",
        '--userdir', "`"$UserDir`""
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")
    if( $p.ExitCode -ne 0 ) {
        throw "seed '$Seed' run exited $($p.ExitCode) (expected 0): $(Format-ArcoPath (Get-Content (Join-Path $dir 'stderr.txt') -Raw))"
    }

    $snapFiles = Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | Sort-Object Name
    if( $snapFiles.Count -lt ($Waits + 1) ) { throw "seed '$Seed' produced $($snapFiles.Count) snapshots (expected >= $($Waits + 1))" }
    return $snapFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
}

$fail = 0
foreach( $seed in $Seeds ) {
    $snaps = Invoke-AttackRun -Seed $seed

    # Scan EVERY exported avatar.damage_taken[] window for an attributed melee hit from the zombie. The
    # buffer DRAINS per snapshot, so each export carries only its own window -- gather across all of them.
    $attributed = New-Object System.Collections.Generic.List[object]
    foreach( $sn in $snaps ) {
        foreach( $d in @($sn.avatar.damage_taken | Where-Object { $_ }) ) {
            if( $d.source_kind -eq 'monster' -and $d.source_type_id -eq 'mon_zombie' -and $d.amount -gt 0 ) {
                $attributed.Add( $d )
            }
        }
    }

    # The t0 (load) export must carry NO damage yet -- the session arms after load and no tick has run,
    # so an entry there would mean a phantom record (a real false-green vector). Assert it is empty.
    $t0Damage = @($snaps[0].avatar.damage_taken | Where-Object { $_ }).Count

    $g = [ordered]@{}
    $g['attributed_hit_landed']  = ($attributed.Count -ge 1)        # >=1 hit attributed to mon_zombie
    $g['load_export_no_damage']  = ($t0Damage -eq 0)                # no phantom record at load

    $totalAmt = ($attributed | Measure-Object -Property amount -Sum).Sum
    if( -not $totalAmt ) { $totalAmt = 0 }

    $seedFail = @($g.GetEnumerator() | Where-Object { -not $_.Value })
    if( $seedFail.Count -eq 0 ) {
        Write-Host ("  [seed $seed] PASS  attributed hits: {0}  total amount: {1}  (RNG-dependent: hits/amount vary by seed)" -f `
            $attributed.Count, $totalAmt) -ForegroundColor Green
    } else {
        $fail++
        Write-Host ("  [seed $seed] FAIL  attributed hits: {0}  failed gates: {1}" -f `
            $attributed.Count, (($seedFail | ForEach-Object { $_.Key }) -join ', ')) -ForegroundColor Red
    }
}

if( $fail -gt 0 ) {
    Write-Host "ATTACKER-DAMAGE REGRESSION: $fail of $($Seeds.Count) seed(s) failed (an all-miss run is RNG-dependent but must be rare; re-run, and if persistent raise -Waits)." -ForegroundColor Red
    exit 1
}
Write-Host "ATTACKER-DAMAGE REGRESSION: ok ($($Seeds.Count) seeds, each landed >=1 mon_zombie-attributed hit at the apply_damage funnel)." -ForegroundColor Green
exit 0
