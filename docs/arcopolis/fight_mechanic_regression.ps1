<#
.SYNOPSIS
  Arcopolis FIGHT-MECHANIC witness (Spike 29A, doc 62): avatar bump-melee vs an adjacent hostile.

.DESCRIPTION
  Proves, at equivalence level 1 (OBSERVATION ONLY, native-authority class A-via-S), that a backend-driven
  `move` into an ADJACENT hostile mon_zombie routes through the engine's OWN bump-melee
  (avatar_action::move -> melee_attack_from_movement -> Character::melee_attack) and that the engine's own
  damage shows up as a raw `entities.monsters[].hp` decrement across snapshots. The melee half of doc 60
  step 5. It drives NO new input path (the move verb stays at its recorded level 2/3 injection) and makes
  NO level-4 claim for the attack.

  FIXTURE (runtime-sandbox, NOTHING COMMITTED): ArcopolisFightTest is generated at run start into the
  gitignored sandbox by cloning the sandbox's ArcopolisTest -- a hostile mon_zombie ADJACENT one south
  (offset 0,1,0) at the type-NATURAL hp 80 (`--hp 80`; a freshly-spawned zombie's pool). K=6 bumps is
  PROVABLY kill-safe: the fixture avatar's crit-inclusive worst case is 12/hit (str-10 skill-0 fists:
  stat roll caps at 10, melee.cpp:2025/:2128; bash_mul 0.8 at skill 0, :2110; x1.5 crit, :2140; zombie
  armor_bash 0), so even six consecutive max-roll crits total 72 < 80 -- doc 62 shows the arithmetic.
  The historical generator default hp=20 would make a mid-run KILL the expected outcome and break both
  the no-kill bound and the avatar-held falsifier (a vacated tile turns bump #k+1 into real movement);
  K=8 at hp 80 would allow a theoretical 96 > 80 (unprovable, however unlikely).

  SAFE-MODE PIN (load-bearing -- doc 62 records the render-coupling artifact): the committed pack ships
  SAFEMODE=true and the saves carry run_mode:1. Safe mode's STOP machinery is INERT in today's headless
  TILES build (mon_info_update early-returns on the CATA_SDL visibility-cache gate, game.cpp:5310-5326)
  but ACTIVE in a curses build -- where it would divert EVERY driven move at avatar_action.cpp:363 with
  zero moves consumed. This script pins SAFEMODE=false in the SANDBOX options.json (the GUI-equivalent of
  the player disabling safe mode; makes GUI and headless agree on every build flavor) and gates
  TURN/MOVES ADVANCE per driven step (a divert burns neither), so a regressed pin fails with attribution
  instead of masquerading as an all-miss.

  RNG-DEPENDENT (the 27B pattern): the hp drop needs >=1 landed hit across $Bumps attacks; each of 3 seeds
  must land one (an all-miss run FAILS LOUD, never a false green). Exact amounts/turns are NOT gated.

  WHAT THIS DOES NOT PROVE (do not let docs widen it): level 4 for the attack; a fight ROUTE (route
  composition is doc 60 step 6, OPEN) or the security-DRONE half of step 5 (doc 60's "Spike 30", OPEN; maintainer
  decision Q3 stays open); NPC/ranged targets; kill/death handling (out of scope by ratified bound);
  multi-monster attribution (monsters have no stable instance id -- single-monster fixture only); GUI
  display equivalence of hp (the GUI shows filtered health BANDS, not the raw number); behavior under
  SAFEMODE=true (deliberately pinned away, recorded artifact).

  Run with `pwsh` (PowerShell 7), not `powershell` 5.1 (BOM-less UTF-8 / options.json BOM => phantom failures).
#>
[CmdletBinding()]
param(
    [string]$Exe         = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc  = "",
    [string]$UserDir     = ".\arcopolis_user",
    [string]$SourceWorld = "ArcopolisTest",
    [string]$World       = "ArcopolisFightTest",
    [string]$Offset      = "0,1,0",
    [int]   $Hp          = 80,
    [int]   $Bumps       = 6,
    [string]$OutRoot     = ".\out\arco_fight_regress",
    [string[]]$Seeds     = @("fight-alpha", "fight-bravo", "fight-charlie")
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

# --- Prereqs (3=exe, 4=fixture-root/pin, 5=source world, 6=python, 7=fixture-generation, 8=path-too-long,
# 9=generator-default-identity, 10=preflight). ---
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
    Stop-WithCode "python not found on PATH (needed to generate the fight fixture from $SourceWorld)" 6
}

# MAX_PATH guard (exit 8): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).ProviderPath)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 8
}

# Refresh the gitignored sandbox from the committed pack. Nothing new is committed; the headless backend
# exits via std::_Exit and never writes the world back, so every run loads identical state.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

# Pin SAFEMODE=false in the SANDBOX copy's options.json (deployment config, never an in-memory override --
# the examine_regression AUTOSELECT pattern). Fails hard if the option line is missing.
$optPath = Join-Path $UserDir "config\options.json"
$optText = Get-Content $optPath -Raw
$optPatched = $optText -replace '("name": "SAFEMODE", "value": ")(true|false)(")', '${1}false${3}'
if( $optPatched -notmatch '"name": "SAFEMODE", "value": "false"' ) {
    Stop-WithCode "Could not pin SAFEMODE=false in the sandbox options.json (option line missing? fixture pack drifted)" 4
}
Set-Content -Path $optPath -Value $optPatched -NoNewline -Encoding utf8
Write-Host "  pinned: SAFEMODE=false in the sandbox options.json (doc 62 render-coupling artifact)"

$gen = Join-Path $PSScriptRoot "make_monster_fixture.py"

# --- G-ID: generator DEFAULT-output identity (the mechanical gate for the ratified fixture-isolation
# bound): a default-generation-flags regeneration (--fixture-root/--dest-world/--force are harness
# plumbing) must reproduce the reference ArcopolisNearMonsterTest .sav byte-for-byte. Scope: hashes the
# .sav only -- today the generator's sole content write; a future flag writing other world files needs a
# wider comparison. Catches any generator edit (e.g. the Spike-29A --hp flag) that perturbs defaults. ---
if( -not (Test-Path $gen) ) { Stop-WithCode "G-ID: generator not found: $(Format-ArcoPath $gen)" 9 }
& python $gen --fixture-root $UserDir --dest-world ArcopolisIdentityCheck --force | Out-Null
if( $LASTEXITCODE -ne 0 ) { Stop-WithCode "G-ID: default-invocation regeneration failed (exit $LASTEXITCODE)" 9 }
$refSav = Get-ChildItem (Join-Path $UserDir "save\ArcopolisNearMonsterTest") -Filter "*.sav" | Select-Object -First 1
$chkSav = Get-ChildItem (Join-Path $UserDir "save\ArcopolisIdentityCheck")   -Filter "*.sav" | Select-Object -First 1
if( -not $refSav -or -not $chkSav ) { Stop-WithCode "G-ID: could not locate reference/check .sav files" 9 }
$refHash = (Get-FileHash $refSav.FullName -Algorithm SHA256).Hash
$chkHash = (Get-FileHash $chkSav.FullName -Algorithm SHA256).Hash
if( $refHash -ne $chkHash ) {
    Stop-WithCode "G-ID FAIL: the generator's default invocation no longer reproduces the reference ArcopolisNearMonsterTest .sav byte-for-byte (either a generator change perturbed defaults -- the fixture-isolation bound's mechanical gate -- or the source/reference fixture worlds drifted out of step; the reference is the resolved fixture root's copy)." 9
}
Write-Host "  G-ID  PASS: generator default output is byte-identical to the reference ArcopolisNearMonsterTest .sav (resolved fixture root)" -ForegroundColor Green

# --- Generate the fight fixture INSIDE the sandbox (explicit --dest-world; never --force at the default
# destination -- the ratified isolation bound). ---
& python $gen --fixture-root $UserDir --source-world $SourceWorld --dest-world $World `
    --monster mon_zombie --offset $Offset --anger 100 --morale 100 --aggro-character --hp $Hp --force
if( $LASTEXITCODE -ne 0 ) { Stop-WithCode "fight fixture generation failed (exit $LASTEXITCODE)" 7 }

# --- G0: fixture pre-flight (textual .sav asserts; the authoritative state gates are t0-export-side). ---
$fightSav = Get-ChildItem (Join-Path $UserDir "save\$World") -Filter "*.sav" | Select-Object -First 1
if( -not $fightSav ) { Stop-WithCode "G0: generated fight world has no .sav" 10 }
$savText = Get-Content $fightSav.FullName -Raw
$g0 = [ordered]@{}
$g0['style_selected_style_none'] = ($savText -match '"style_selected":"style_none"')   # knockback pin (doc 62)
$g0['auto_travel_mode_false']    = ($savText -match '"auto_travel_mode":false')        # silent-divert pin
$g0['manual_combat_mode_absent'] = (-not ($savText -match '"manual_combat_mode"'))     # loader-defaults false (savegame.cpp:367-368)
$g0['witness_type_present']      = ($savText -match '"typeid":"mon_zombie"')
$g0['witness_hp_authored']       = ($savText -match ('"hp":' + $Hp))          # textual smoke; authoritative = t0 export gate
$g0['avatar_str_max_10']         = ($savText -match '"str_max":10')           # kill-safety premise (doc 62 s3)
$g0Fail = @($g0.GetEnumerator() | Where-Object { -not $_.Value })
if( $g0Fail.Count -gt 0 ) {
    Stop-WithCode ("G0 FAIL: fixture pre-flight gates failed: " + (($g0Fail | ForEach-Object { $_.Key }) -join ', ')) 10
}
Write-Host "  G0    PASS: fixture pins hold (style_none selected, auto_travel off, manual_combat absent, zombie authored at hp $Hp, avatar str_max 10)" -ForegroundColor Green

# --- G1: the witness -- [export t0, (move_s, export tN) x $Bumps] per seed, non-live run-script. ---
function Invoke-FightRun {
    param([string]$Seed)

    $dir = Join-Path $OutRoot $Seed
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('{ "op": "export", "name": "t0" }')
    foreach( $i in 1..$Bumps ) {
        $steps.Add('{ "op": "command", "command": "move", "direction": "move_s" }')
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

    # Named exports only (NNN_t<i>.json), in step order; excludes script.json and the final-on-exit snapshot.
    $snapFiles = Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_t\d+\.json$' } | Sort-Object Name
    if( $snapFiles.Count -ne ($Bumps + 1) ) { throw "seed '$Seed' produced $($snapFiles.Count) named exports (expected $($Bumps + 1))" }
    $snaps = $snapFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }

    $logPath = Join-Path $dir "session.jsonl"
    $events = @()
    if( Test-Path $logPath ) {
        $events = @(Get-Content $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{ Snaps = $snaps; Events = $events; HasLog = (Test-Path $logPath) }
}

function Get-TheMonster {
    param($Snap)
    $mons = @($Snap.entities.monsters | Where-Object { $_ })
    if( $mons.Count -ne 1 ) { return $null }
    return $mons[0]
}

$fail = 0
foreach( $seed in $Seeds ) {
    $run = Invoke-FightRun -Seed $seed
    $snaps = $run.Snaps

    $t0 = $snaps[0]
    $mon0 = Get-TheMonster $t0
    $avatar0 = $t0.avatar.pos_abs
    $expectSouth = @($avatar0[0], ($avatar0[1] + 1), $avatar0[2])

    $g = [ordered]@{}
    # Identity + geometry at load (the authoritative half of G0).
    $g['t0_single_monster']   = ($null -ne $mon0)
    $g['t0_zombie_identity']  = ($mon0 -and $mon0.type_id -eq 'mon_zombie' -and $mon0.hp -eq $Hp)
    $g['t0_adjacent_south']   = ($mon0 -and (@($mon0.pos_abs) -join ',') -eq ($expectSouth -join ','))

    # Per-export series gates.
    $monCountOk = $true; $avatarHeld = $true; $targetHeld = $true; $hpNonIncreasing = $true
    $advanceOk = $true; $npcHeld = $true
    $npc0 = @($t0.entities.npcs | Where-Object { $_ }) | Select-Object -First 1
    $prevMon = $mon0
    for( $i = 1; $i -lt $snaps.Count; $i++ ) {
        $s = $snaps[$i]
        $m = Get-TheMonster $s
        if( $null -eq $m ) { $monCountOk = $false; break }
        if( (@($s.avatar.pos_abs) -join ',') -ne (@($avatar0) -join ',') ) { $avatarHeld = $false }
        if( (@($m.pos_abs) -join ',') -ne ($expectSouth -join ',') ) { $targetHeld = $false }
        if( $m.hp -gt $prevMon.hp ) { $hpNonIncreasing = $false }
        # Divert discriminator: a driven move must burn engine time -- turn advanced OR moves decreased.
        # (A fist attack can cost less than a full turn, so consecutive exports may legally share a turn.)
        if( -not (($s.backend.turn -gt $snaps[$i-1].backend.turn) -or ($s.avatar.moves -lt $snaps[$i-1].avatar.moves)) ) { $advanceOk = $false }
        $npcNow = @($s.entities.npcs | Where-Object { $_ }) | Select-Object -First 1
        if( $npc0 -and ( -not $npcNow -or (@($npcNow.pos_abs) -join ',') -ne (@($npc0.pos_abs) -join ',') ) ) { $npcHeld = $false }
        $prevMon = $m
    }
    $monFinal = Get-TheMonster $snaps[-1]

    $g['monster_count_one_everywhere'] = $monCountOk        # join-by-elimination validity; a vanished entry
    $g['avatar_held']                  = $avatarHeld        # bump-attack, not displacement (knockback pinned)
    $g['target_held_south']            = $targetHeld        # engaged adjacent hostile holds its tile
    $g['every_step_advances']          = $advanceOk         # no zero-cost divert (safe-mode/auto-travel)
    $g['hp_non_increasing']            = $hpNonIncreasing   # single damage source; no regen
    $g['hp_dropped']                   = ($monFinal -and $monFinal.hp -lt $Hp)  # >=1 landed hit (RNG gate)
    $g['zombie_alive_at_end']          = ($monFinal -and $monFinal.hp -gt 0)    # kill-headroom held (no-kill bound)
    $g['npc_present_at_t0']            = ($null -ne $npc0)  # Edwardo must EXIST for the next gate to mean anything
    $g['npc_noninterference']          = $npcHeld           # Edwardo (stationary ally, 1 north) holds pos
    $g['turn_advanced_overall']        = ($snaps[-1].backend.turn -gt $t0.backend.turn)

    # Transcript: no error events at all (error events uniquely carry exit_code); specifically no
    # unexpected_prompt (any prompt on this path is an attack-path failure -- identity-keyed).
    $errEvents = @($run.Events | Where-Object { $_.PSObject.Properties.Name -contains 'exit_code' })
    $g['transcript_no_errors'] = ($run.HasLog -and $errEvents.Count -eq 0)   # a MISSING transcript is a failure, not a vacuous pass

    # Reported, NOT gated: the zombie's counter-attacks (expected, not a confound).
    $counterHits = 0
    foreach( $sn in $snaps ) {
        $counterHits += @($sn.avatar.damage_taken | Where-Object { $_ -and $_.source_type_id -eq 'mon_zombie' }).Count
    }

    $seedFail = @($g.GetEnumerator() | Where-Object { -not $_.Value })
    if( $seedFail.Count -eq 0 ) {
        Write-Host ("  [seed $seed] PASS  zombie hp {0} -> {1}  counter-hits on avatar: {2}  (amounts RNG-dependent)" -f `
            $Hp, $monFinal.hp, $counterHits) -ForegroundColor Green
    } else {
        $fail++
        $names = ($seedFail | ForEach-Object { $_.Key }) -join ', '
        Write-Host ("  [seed $seed] FAIL  gates: {0}" -f $names) -ForegroundColor Red
        if( -not $monCountOk ) {
            Write-Host "        (a VANISHED entities.monsters[] entry after a prior hp drop = kill-headroom/stop-rule failure -- overkill, NOT knockback; see doc 62)" -ForegroundColor Red
        }
        if( -not $advanceOk ) {
            Write-Host "        (a zero-cost step = a DIVERT before the monster branch -- check the SAFEMODE pin and auto_travel_mode, doc 62; NOT an RNG all-miss)" -ForegroundColor Red
        }
    }
}

if( $fail -gt 0 ) {
    Write-Host "FIGHT-MECHANIC REGRESSION: $fail of $($Seeds.Count) seed(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "FIGHT-MECHANIC REGRESSION: ok ($($Seeds.Count) seeds: G-ID + G0 pins + per-step advance, avatar/target held, hp dropped and stayed >0, transcript clean)." -ForegroundColor Green
exit 0
