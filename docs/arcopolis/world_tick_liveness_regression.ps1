<#
.SYNOPSIS
  Arcopolis world-tick LIVENESS witness (Spike: prove BN simulates between inputs).

.DESCRIPTION
  Drives the headless backend over ArcopolisLivenessTest and witnesses that an AUTONOMOUS
  entity acts on its OWN engine turn during the world tick. Every prior Arcopolis witness
  asserts a static post-condition or a player-driven transaction; this one puts AUTONOMY on
  trial. A hostile mon_zombie is placed 2 tiles SOUTH of the stationary avatar (save fields
  anger=100, aggro_character=true — an authored INITIAL condition, exactly as the GUI debug
  spawn authors one; the engine simulates from there). Across [export, (wait,export) x N] the
  driven `wait` falls through do_turn's clean-park seam into the bottom-half tick
  (game::monmove, src/game.cpp), and the zombie pathfinds toward the avatar on its own turn.

  CLAIM: equivalence level 1 (OBSERVATION ONLY), native-authority class S (raw simulation
  state = the monster's authoritative position from game::all_monsters()). It does NOT drive a
  registered input and makes NO level-4 claim. The witness is ONE-DIRECTIONAL: a position
  delta PROVES an autonomous act (delta => act); a zero delta would NOT disprove liveness
  (a real tick can be spent attacking/blocked), so we never assert "no delta => no liveness".

  WHY THREE SEEDS (the RNG discipline). The headless sim is NOT byte-deterministic: --seed
  re-seeds only the MAIN engine (src/main.cpp), while parallel monster planning runs on
  worker threads whose RNG is time-seeded (src/thread_pool.cpp), and even MULTITHREADING off
  + a fixed seed still diverges in practice. So we do NOT gate exact positions/damage (those
  are RNG-dependent: the stumble tile and the hit/miss outcome vary per seed). Instead we gate
  only RNG-INVARIANT quantities and PROVE invariance by running THREE distinct seeds and
  requiring every hard gate to hold in all three realizations. (Validated: the zombie's exact
  landing tile and the avatar HP drop both vary by seed; the invariants below do not.)

  NPC NON-INTERFERENCE (proven from the export, no new field needed). The stock shelter NPC
  Edwardo Stovall sits 1 tile NORTH of the avatar — the OPPOSITE side from the zombie, with
  the (stationary) avatar between them — and the entities.npcs[] export reports him
  is_stationary=true (a guard: he cannot path). So he can neither reach nor be reached by the
  zombie. We make this a CHECKED invariant: assert is_stationary=true AND his pos_abs is
  identical across every export. The mover also survives to the final export (the avatar only
  waits and Edwardo is stationary, so nothing third-party can kill the zombie) — corroborating
  that the witnessed movement is the zombie's own, attributable to no other actor. The export
  cannot attribute a monster's hp loss to a source, so non-interference rests on geometry +
  is_stationary, not on hp accounting.

  HARD GATES (per seed; all must hold for all 3 seeds):
    1. single mover at load   — exactly one non-hallucination mon_zombie in the window.
    2. autonomous approach     — final Chebyshev(zombie,avatar) < load Chebyshev (it moved
                                 toward the avatar on its own turn). [the liveness signal]
    3. reached adjacency       — some post-load export has Chebyshev == 1 (it closed to the
                                 avatar; the stakes precondition).
    4. clock advanced = N      — backend.turn rose by exactly N across the waits (the world
                                 ticked; NOT a clean-park early return).
    5. avatar held             — avatar.pos_abs identical across every export (the avatar only
                                 waits; closes the "avatar moved and dragged the relative read" confound).
    6. NPC non-interference    — npcs[0].is_stationary=true AND npcs[0].pos_abs identical
                                 across every export.
    7. mover survived          — exactly one non-hallucination mon_zombie at the final export.
    8. autonomous step (no teleport) — the mover's Chebyshev displacement is <=1 between every
                                 consecutive export (the zombie is speed 100, so a move is <=1 tile/turn;
                                 the monmove impassable-eject does a multi-tile setpos). Converts an
                                 eject/teleport into a fail-loud and proves a step-by-step path.
    9. mover on passable terrain — the mover's LOAD tile ter shows no clear impassable signal (an
                                 impassable family token with NO passable one; the eject precondition is
                                 engine impassability, the generator only WARNS on bad terrain).
  SOFT REPORT (stakes, NOT gated — RNG-dependent): the avatar HP delta under attack.

  WHAT THIS DOES NOT PROVE (scope; do not let docs widen it): ambient/idle autonomy (this is a
  PROVOKED, avatar-targeting mover); multi-entity or world-wide simulation (fields, fires,
  vehicles, weather, spawns); sustained multi-tick liveness; any other z-level (single-z
  window); and the ATTACKER-IDENTITY attack fact (surfacing the engine's damage `source`) — a
  SEPARATE follow-up spike (27B), deliberately not in this PR.

  WHY a fixture-driven script and not a CI catch2 test (same reasoning as
  monster_export_regression.ps1): it needs a fully loaded world; the pure command/script
  parsing is already covered by the world-independent [arcopolis] unit suite. Run with `pwsh`
  (PowerShell 7), not `powershell` 5.1 (BOM-less UTF-8 / options.json BOM => phantom failures).

.NOTES
  Create the fixture first (one python invocation, no build):
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
    [string]$OutRoot    = ".\out\arco_liveness_regress",
    [int]   $Waits      = 4,
    [string[]]$Seeds    = @("liveness-alpha", "liveness-bravo", "liveness-charlie")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper (see monster_export_regression.ps1): a bare `Write-Error; exit N` collapses
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
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).ProviderPath)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 6
}

# Refresh the gitignored sandbox from the committed pack (delete first: Copy-Item -Recurse nests
# the source INSIDE an existing destination). One pristine copy serves all seeds -- the headless
# backend exits via std::_Exit and never writes the world back, so each run loads identical state.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

function Get-Cheb {
    # 2-D Chebyshev distance; the z axis is intentionally excluded (this witness is single-z by design).
    param($A, $B)
    return [Math]::Max([Math]::Abs($A[0] - $B[0]), [Math]::Abs($A[1] - $B[1]))
}

function Invoke-LivenessRun {
    param([string]$Seed)

    $dir = Join-Path $OutRoot $Seed
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export at load, then (wait, export) x N -> the per-turn trajectory.
    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('{ "op": "export", "name": "t0" }')
    foreach( $i in 1..$Waits ) {
        $steps.Add('{ "op": "command", "command": "wait" }')
        $steps.Add( '{ "op": "export", "name": "t' + $i + '" }' )
    }
    $scriptPath = Join-Path $dir "script.json"
    ('{ "schema_version": 1, "steps": [ ' + ($steps -join ", ") + ' ] }') | Set-Content -Encoding ascii $scriptPath

    # cataclysm-bn-tiles is a WINDOWS-subsystem exe; Start-Process -Wait -PassThru captures the
    # real exit code. Quote path args so spaced checkouts reach the child intact.
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
    $snaps = Invoke-LivenessRun -Seed $seed
    $load  = $snaps[0]
    $final = $snaps[-1]

    # Zombie (non-hallucination) per snapshot; @() so a single monster is still an array.
    $zombieAt = {
        param($snap)
        @($snap.entities.monsters | Where-Object { $_ -and $_.type_id -eq 'mon_zombie' -and -not $_.hallucination })
    }
    $loadZ  = & $zombieAt $load
    $finalZ = & $zombieAt $final

    $g = [ordered]@{}
    $g['single_mover_at_load'] = ($loadZ.Count -eq 1)
    $g['mover_survived']       = ($finalZ.Count -eq 1)

    if( $loadZ.Count -ge 1 -and $finalZ.Count -ge 1 ) {
        $loadCheb  = Get-Cheb $loadZ[0].pos_abs  $load.avatar.pos_abs
        $finalCheb = Get-Cheb $finalZ[0].pos_abs $final.avatar.pos_abs
        $g['autonomous_approach'] = ($finalCheb -lt $loadCheb)
        # reached adjacency at some post-load export
        $minCheb = ($snaps[1..($snaps.Count-1)] | ForEach-Object {
            $z = & $zombieAt $_
            if( $z.Count -ge 1 ) { Get-Cheb $z[0].pos_abs $_.avatar.pos_abs } else { 99 }
        } | Measure-Object -Minimum).Minimum
        $g['reached_adjacency'] = ($minCheb -eq 1)
    } else {
        $g['autonomous_approach'] = $false
        $g['reached_adjacency']   = $false
        $loadCheb = "?"; $finalCheb = "?"
    }

    # Anti-teleport / autonomous-step: a single monster move is <=1 tile/turn (the fixture zombie is
    # speed 100 -- well under the ~200 needed to step 2 tiles in one turn), but the
    # do_turn monmove impassable-eject ("Critters in impassable tiles get pushed away", src/game.cpp)
    # does a multi-tile setpos that could masquerade as an approach. Asserting the mover's Chebyshev
    # displacement is <=1 between consecutive exports converts an eject/teleport into a FAIL-LOUD, and
    # proves the approach is a step-by-step path, not a jump. (Closes the regenerated-onto-impassable
    # false-green: the generator's passability check is terrain-only and only warns.)
    $moverPos = New-Object System.Collections.Generic.List[object]
    foreach( $sn in $snaps ) {
        $z = & $zombieAt $sn
        $moverPos.Add( $(if( $z.Count -ge 1 ) { $z[0].pos_abs } else { $null }) )
    }
    $maxStep = 0
    for( $i = 1; $i -lt $moverPos.Count; $i++ ) {
        if( $null -eq $moverPos[$i] -or $null -eq $moverPos[$i - 1] ) { $maxStep = 99; break }
        $step = Get-Cheb $moverPos[$i] $moverPos[$i - 1]
        if( $step -gt $maxStep ) { $maxStep = $step }
    }
    $g['autonomous_step_no_teleport'] = ($maxStep -le 1)

    # Re-assert the mover LOADS on passable terrain: the eject precondition is engine impassability, so
    # impassable terrain under the mover is the false-green vector. (Furniture impassability is NOT fully
    # decidable from the exported ter/furn ids, so the no-teleport gate above is the belt to this braces.)
    $impassableHints = 'wall', 'rock', 'tree', 'bars', 'grate', '_door_c', 'door_locked', 'boulder'
    $passableHints   = 'floor', 'grass', 'dirt', 'sand', 'mud', 'gravel', 'underbrush', 'pavement', 'road', 'sidewalk', 'concrete', 'shrub'
    if( $loadZ.Count -ge 1 ) {
        $loadMp   = $loadZ[0].pos_local
        $loadTile = @($load.tiles | Where-Object { $_ -and $_.x -eq $loadMp[0] -and $_.y -eq $loadMp[1] -and $_.z -eq $loadMp[2] })
        $ter      = if( $loadTile.Count -ge 1 ) { "$($loadTile[0].ter)" } else { "" }
        # Flag ONLY on a clear impassable signal (an impassable family token AND no passable one), so a
        # passable id that merely CONTAINS an impassable substring (t_rock_floor -> "rock", but also "floor")
        # is not a false FAILURE (gemini PR #89). Erring toward PASS on ambiguity is correct -- gate 8
        # (no-teleport) is the robust anti-eject defense; this is the conservative belt to its braces.
        $hasImpassable = (@($impassableHints | Where-Object { $ter -like "*$_*" }).Count -gt 0) -and `
            (@($passableHints | Where-Object { $ter -like "*$_*" }).Count -eq 0)
        $g['mover_on_passable_terrain'] = ($loadTile.Count -ge 1) -and (-not $hasImpassable)
    } else {
        $g['mover_on_passable_terrain'] = $false
    }

    $g['clock_advanced'] = (($final.backend.turn - $load.backend.turn) -eq $Waits)
    $g['avatar_held']    = @($snaps | Where-Object { "$($_.avatar.pos_abs -join ',')" -ne "$($load.avatar.pos_abs -join ',')" }).Count -eq 0

    # NPC non-interference: stationary guard, pos identical across every export.
    $loadNpc = @($load.entities.npcs | Where-Object { $_ })
    if( $loadNpc.Count -ge 1 ) {
        $npcStationary = @($snaps | Where-Object {
            $n = @($_.entities.npcs | Where-Object { $_ }); $n.Count -lt 1 -or -not $n[0].is_stationary
        }).Count -eq 0
        $npcHeld = @($snaps | Where-Object {
            $n = @($_.entities.npcs | Where-Object { $_ })
            $n.Count -lt 1 -or "$($n[0].pos_abs -join ',')" -ne "$($loadNpc[0].pos_abs -join ',')"
        }).Count -eq 0
        $g['npc_non_interference'] = ($npcStationary -and $npcHeld)
    } else {
        # No NPC in window is also non-interference (nothing to interfere).
        $g['npc_non_interference'] = $true
    }

    $hpDrop = $load.avatar.hp - $final.avatar.hp   # SOFT, RNG-dependent: the attack stakes.

    $seedFail = @($g.GetEnumerator() | Where-Object { -not $_.Value })
    if( $seedFail.Count -eq 0 ) {
        Write-Host ("  [seed $seed] PASS  approach cheb {0}->{1}  reached_adjacency  clock+{2}  npc-held  (stakes: avatar hp -{3})" -f `
            $loadCheb, $finalCheb, $Waits, $hpDrop) -ForegroundColor Green
    } else {
        $fail++
        Write-Host ("  [seed $seed] FAIL  cheb {0}->{1}  failed gates: {2}" -f `
            $loadCheb, $finalCheb, (($seedFail | ForEach-Object { $_.Key }) -join ', ')) -ForegroundColor Red
    }
}

if( $fail -gt 0 ) {
    Write-Host "WORLD-TICK LIVENESS REGRESSION: $fail of $($Seeds.Count) seed(s) failed a hard gate." -ForegroundColor Red
    exit 1
}
Write-Host "WORLD-TICK LIVENESS REGRESSION: ok ($($Seeds.Count) seeds, all rng-invariant gates held)." -ForegroundColor Green
exit 0
