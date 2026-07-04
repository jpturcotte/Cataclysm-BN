<#
.SYNOPSIS
  Arcopolis STAGE-1 SHADOW-TEST: attacker per-instance AMBIGUITY witness (deferred "Codex Claim 4", doc 59).

.DESCRIPTION
  This is a GAP DEMONSTRATION, not a capability proof. It exercises the divergence that the deferred
  stable-per-instance-attacker-id would close: with TWO hostile mon_zombie both attacking the avatar, the
  Spike-27B avatar.damage_taken[] surface (source_kind/source_type_id/amount/bodypart/hp_part/turn) CANNOT
  say WHICH of the two exported mon_zombie dealt a given hit -- source_type_id ("mon_zombie") is shared, and
  no per-instance join key exists on either side (the export keys entities by a volatile windowed index; BN
  gives monsters no stable id -- see doc 59). It makes NO new equivalence claim and drives NO input: it
  observes the EXISTING 27B field over a two-attacker fixture and asserts the ambiguity is real and
  unresolvable with today's surface.

  CLAIM: equivalence level 1 (OBSERVATION ONLY). NO src/ change -- fixture + regression + docs only. It runs
  against ANY exe carrying the shipped 27B surface (no rebuild needed).

  Fixture ArcopolisTwoZombieTest: a clone of ArcopolisTest with TWO hostile mon_zombie (offsets 0,2,0 and
  1,2,0 -- both t_floor, in dark-shelter detection range), built by make_monster_fixture.py's --extra-offset.
  The stationary avatar only `wait`s (takes no attack action), so it kills neither zombie: both persist, so
  the ambiguity is stable across the run.

  *** RNG-DEPENDENT (like 27B, its sibling), NOT RNG-INVARIANT. *** The funnel fires only on a LANDED HIT, so
  "a hit landed while >=2 mon_zombie are present" needs >=1 hit in N waits. With N generous and TWO attackers
  a hit is EMPIRICALLY RELIABLE across seeds, but not guaranteed by construction -- a pathological all-miss
  run FAILS LOUD (never a false green). Runs THREE seeds; each must land >=1 attributed hit under ambiguity.

  The gates, and why each exercises the divergence rather than a happy path:
    two_zombies_present   : >=1 snapshot exports >=2 mon_zombie at once -- the ambiguity is REAL, not
                            hypothetical (a one-zombie fixture, like 27B's, is the happy path this avoids).
    zombies_distinct      : those >=2 mon_zombie sit on DISTINCT pos_abs -- genuinely two different creatures
                            the surface conflates, not one double-counted.
    hit_under_ambiguity   : >=1 snapshot has a mon_zombie damage entry AND >=2 mon_zombie present in the SAME
                            snapshot -- a hit landed while the attacker was genuinely ambiguous.
    no_instance_join_key  : NO damage_taken entry carries any per-instance discriminator (no id / index / pos
                            / instance / unique_name field) -- STRUCTURAL, RNG-independent: source_type_id is
                            the only cross-surface field and it is shared, so the event cannot be pinned to a
                            specific entities.monsters[] entry. (If a stable-id field is ever added this gate
                            FLIPS -- correctly signalling the gap has closed and this shadow-test is stale.)
    attacker_position_moves: the multiset of mon_zombie pos_abs is NOT constant across the sequence (they
                            pathfind) -- so "just stamp the attacker's position" is a MOVING TARGET, not a
                            stable per-instance key. (The windowed export index is likewise unstable on
                            spawn/death -- BN's cleanup_dead/remove_dead reindexes monsters_list mid-do_turn,
                            src/game.cpp -- but forcing a death is non-deterministic, so that hazard is
                            source-cited in doc 59, not gated here.)
    load_export_no_damage : t0 (load) carries no damage -- no phantom record (same false-green guard as 27B).

  WHAT THIS DOES NOT PROVE (scope; do not let docs widen it): it proves a GAP, not a fix. It does not build
  or witness any correlation key, stable id, or resolve-at-serialize handle; it does not cover ranged / NPC
  attackers, hit/miss, damage type, or the reindex-on-death hazard (source-cited only). Run with `pwsh`
  (PowerShell 7), not `powershell` 5.1 (BOM-less UTF-8 / options.json BOM => phantom failures).

.NOTES
  Create the fixture first (one python invocation, no build):
    python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisTwoZombieTest `
        --monster mon_zombie --offset 0,2,0 --extra-offset 1,2,0 --anger 100 --morale 100 --aggro-character --force
  If the fixture world is missing this script exits 5 with that pointer.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTwoZombieTest",
    [string]$OutRoot    = ".\out\arco_ambig_regress",
    [int]   $Waits      = 8,
    [string[]]$Seeds    = @("ambig-alpha", "ambig-bravo", "ambig-charlie")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: a bare `Write-Error; exit N` collapses to exit 1 under $ErrorActionPreference=Stop;
# -ErrorAction Continue keeps the labeled code (see world_tick_liveness_regression.ps1).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# The six fields the 27B avatar.damage_taken[] schema carries today. Any OTHER member on a damage entry
# would be a candidate per-instance discriminator -- the whole point is that none exists.
$KnownDamageFields = @('source_kind', 'source_type_id', 'amount', 'bodypart', 'hp_part', 'turn')

# --- Prereqs (3=exe, 4=fixture, 5=world, 6=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb, or point -Exe at any exe carrying the shipped 27B surface; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Two-zombie fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- create it: python docs/arcopolis/make_monster_fixture.py --dest-world $World --monster mon_zombie --offset 0,2,0 --extra-offset 1,2,0 --anger 100 --morale 100 --aggro-character --force" 5
}

# MAX_PATH guard (exit 6): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).Path)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 6
}

# Refresh the gitignored sandbox from the committed pack (delete first: Copy-Item -Recurse nests the source
# INSIDE an existing destination). One pristine copy serves all seeds -- the headless backend exits via
# std::_Exit and never writes the world back, so each run loads identical state.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

function Invoke-AmbigRun {
    param([string]$Seed)

    $dir = Join-Path $OutRoot $Seed
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    # export at load, then (wait, export) x N -> per-turn damage windows AND per-turn entity snapshots.
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

function Get-ZombiePositions {
    param($Snap)
    # sorted "x,y,z" strings for every exported mon_zombie in this snapshot (identity-free by design).
    @($Snap.entities.monsters | Where-Object { $_.type_id -eq 'mon_zombie' } |
        ForEach-Object { '{0},{1},{2}' -f $_.pos_abs[0], $_.pos_abs[1], $_.pos_abs[2] } | Sort-Object)
}

$fail = 0
foreach( $seed in $Seeds ) {
    $snaps = Invoke-AmbigRun -Seed $seed

    $attributed          = 0    # mon_zombie hits total
    $hitUnderAmbiguity   = $false
    $maxZombies          = 0
    $sawDistinctZombies  = $false
    $extraFieldSeen      = $null
    $posSequence         = New-Object System.Collections.Generic.List[string]

    foreach( $sn in $snaps ) {
        $zPos   = @(Get-ZombiePositions -Snap $sn)
        $zCount = $zPos.Count
        if( $zCount -gt $maxZombies ) { $maxZombies = $zCount }
        if( ($zPos | Select-Object -Unique).Count -ge 2 ) { $sawDistinctZombies = $true }
        $posSequence.Add( ($zPos -join '|') )

        $zHitThisSnap = $false
        foreach( $d in @($sn.avatar.damage_taken | Where-Object { $_ }) ) {
            # STRUCTURAL: flag any member outside the known six -> a per-instance discriminator would show here.
            foreach( $prop in $d.PSObject.Properties.Name ) {
                if( $KnownDamageFields -notcontains $prop -and $null -eq $extraFieldSeen ) { $extraFieldSeen = $prop }
            }
            if( $d.source_kind -eq 'monster' -and $d.source_type_id -eq 'mon_zombie' -and $d.amount -gt 0 ) {
                $attributed++; $zHitThisSnap = $true
            }
        }
        if( $zHitThisSnap -and $zCount -ge 2 ) { $hitUnderAmbiguity = $true }
    }

    # The multiset of zombie positions must change at least once across the sequence (they pathfind), so a
    # position captured at one instant does not stably identify a creature at another.
    $positionMoves = (($posSequence | Select-Object -Unique).Count -ge 2)

    # t0 (load) export must carry NO damage -- no phantom record (a real false-green vector).
    $t0Damage = @($snaps[0].avatar.damage_taken | Where-Object { $_ }).Count

    $g = [ordered]@{}
    $g['two_zombies_present']    = ($maxZombies -ge 2)        # ambiguity is real (RNG-reliable: both in-window)
    $g['zombies_distinct']       = $sawDistinctZombies        # genuinely two creatures (distinct pos_abs)
    $g['hit_under_ambiguity']    = $hitUnderAmbiguity         # a hit landed while >=2 present (RNG-dependent)
    $g['no_instance_join_key']   = ($null -eq $extraFieldSeen) # STRUCTURAL: no per-instance discriminator field
    $g['attacker_position_moves']= $positionMoves             # position is a moving target, not a stable key
    $g['load_export_no_damage']  = ($t0Damage -eq 0)          # no phantom record at load

    $seedFail = @($g.GetEnumerator() | Where-Object { -not $_.Value })
    if( $seedFail.Count -eq 0 ) {
        Write-Host ("  [seed $seed] PASS  mon_zombie hits: {0}  max zombies in a snapshot: {1}  (ambiguity real + unresolvable; RNG-dependent hit count)" -f `
            $attributed, $maxZombies) -ForegroundColor Green
    } else {
        $fail++
        $detail = if( $extraFieldSeen ) { " (unexpected damage field '$extraFieldSeen' -- gap may have CLOSED; revisit doc 59)" } else { "" }
        Write-Host ("  [seed $seed] FAIL  mon_zombie hits: {0}  max zombies: {1}  failed gates: {2}{3}" -f `
            $attributed, $maxZombies, (($seedFail | ForEach-Object { $_.Key }) -join ', '), $detail) -ForegroundColor Red
    }
}

if( $fail -gt 0 ) {
    Write-Host "ATTACKER-INSTANCE-AMBIGUITY REGRESSION: $fail of $($Seeds.Count) seed(s) failed (an all-miss run is RNG-dependent but must be rare; re-run, and if persistent raise -Waits). A no_instance_join_key failure instead means the surface gained a discriminator -- the gap closed; revisit doc 59." -ForegroundColor Red
    exit 1
}
Write-Host "ATTACKER-INSTANCE-AMBIGUITY REGRESSION: ok ($($Seeds.Count) seeds). Two same-type mon_zombie both attack; avatar.damage_taken[] carries no per-instance join key, so a hit cannot be pinned to a specific entities.monsters[] entry (the deferred stable-attacker-id gap, doc 59)." -ForegroundColor Green
exit 0
