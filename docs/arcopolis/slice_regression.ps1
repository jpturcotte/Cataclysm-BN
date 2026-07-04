<#
.SYNOPSIS
  Arcopolis folded-Spike-29 vertical-slice regression: the four-gate ladder over the slice fixtures
  (docs/arcopolis/61). G1 fixture determinism per floor pair + generator content-identity; G2 a
  6-floor descent->ascent round trip (run-script); G3 the former-Spike-28 two-floor composite
  (live); G4 the 6-floor composite with the package on the deepest floor (live).

.DESCRIPTION
  The ladder preserves failure attribution inside the one folded spike (the doc 48 section 20
  lesson): each gate group fails independently, in order --

    G1 (fixture machinery, no session):
      a. generator --check-only over ArcopolisSliceTest (source preconditions + dest read-back);
      b. generator --check-only over ArcopolisTowerTest (incl. the synthesized z=-2..-5 floors);
      c. DEFAULT-invocation content-identity: regenerating the Spike 23 ArcopolisStairsTest from
         ArcopolisTest with no new flags produces a content-identical world (same file set, same
         bytes, map.sqlite3 compared row-wise on decompressed payloads) -- the ratified non-goal
         that the Spike 29 parameterization must not disturb the witnessed default;
      d. loaded z=0 read-back per slice world: a single-export run-script shows the avatar standing
         on t_stairs_down (the loaded-state transposed-index catcher; per-floor loaded validation
         is G2/G4's per-leg asserts).
    G2 (traversal, run-script, no package): the full 6-floor round trip on ArcopolisTowerTest --
       18 legs, each asserted on pos_abs trajectory + avatar-tile stair terrain + strictly
       advancing turn, with zero monsters/NPCs in every synthesized-floor window and
       avatar.damage_taken[] empty in every snapshot; exit 0 + session_end ok (any engine
       sub-prompt would be unexpected_prompt, exit 14 -- never a silent success).
    G3 (2-floor composite, live): slice_live_driver.py on ArcopolisSliceTest -- the former Spike 28
       verbatim, incl. the pinned z-changed off-contact guard and the doc-53 false-green set.
    G4 (6-floor composite, live): the same driver on ArcopolisTowerTest, package on z=-5 --
       Stage A's traversal core (doc 60 section 3).

  Claims (doc 61; no composite headline): per-verb levels as recorded -- vertical_move/move 2/3,
  pickup level 4 at its witnessed site, has_item class C, position class S; the slice is an
  Arcopolis-layer L1 composite (docs 53/55). G3/G4 are also the FIRST live-transport
  vertical_move witnesses (doc 49 added no live probe). NOT proven: mission completion,
  crafting_inventory() scope, NPC turn-in, L4 vertical, multi-z snapshots, any floor count
  other than the witnessed 2 and 6, stealth/perception.

.NOTES
  Build the fixtures first (see TEST_FIXTURES.md):
    python docs/arcopolis/make_stairs_fixture.py --source-world ArcopolisBackpackTest `
        --dest-world ArcopolisSliceTest --package-typeid box_small --package-offset 0,2,-1
    python docs/arcopolis/make_stairs_fixture.py --source-world ArcopolisBackpackTest `
        --dest-world ArcopolisTowerTest --floors 6 --package-typeid box_small --package-offset 0,6,-5
  Run with `pwsh` (PowerShell 7), not `powershell` (5.1) -- 5.1 misreads BOM-less UTF-8 snapshots
  (fixtures/README.md).
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$OutRoot    = ".\out\arco_slice_regress",
    [string]$Generator  = "docs\arcopolis\make_stairs_fixture.py",
    [string]$Driver     = "docs\arcopolis\slice_live_driver.py"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper: print to stderr and exit with a SPECIFIC code. A bare `Write-Error; exit N` does NOT
# work under `$ErrorActionPreference = "Stop"`: Write-Error throws a terminating error that unwinds BEFORE
# `exit` runs, collapsing every guard to exit 1. `-ErrorAction Continue` keeps it non-terminating so the
# labeled code is actually returned (see 16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=worlds, 6=python, 7=generator,
# 8=driver, 9=sandbox-path-too-long -- the MAX_PATH guard below the block). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
foreach( $w in @("ArcopolisSliceTest", "ArcopolisTowerTest", "ArcopolisStairsTest", "ArcopolisBackpackTest", "ArcopolisTest") ) {
    if( -not (Test-Path (Join-Path $FixtureSrc (Join-Path "save" $w))) ) {
        Stop-WithCode "Fixture world '$w' not found under $(Format-ArcoPath $FixtureSrc) -- build the slice fixtures first (see .NOTES / TEST_FIXTURES.md)." 5
    }
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed for the generator and driver gates). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Generator) ) { Stop-WithCode "Fixture generator not found: $(Format-ArcoPath $Generator)" 7 }
if( -not (Test-Path $Driver) )    { Stop-WithCode "Slice live driver not found: $(Format-ArcoPath $Driver)" 8 }

# MAX_PATH guard (exit 9): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $UserDir))
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 9
}

# Refresh the gitignored sandbox userdir from the fixture pack (same rationale as the sibling regressions).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

$fail = 0

function Invoke-Backend {
    param([string[]]$BackendArgs, [string]$Dir)
    # cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and
    # leaves $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code.
    $p = Start-Process -FilePath $Exe -ArgumentList $BackendArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $Dir "stdout.txt") -RedirectStandardError (Join-Path $Dir "stderr.txt")
    return $p.ExitCode
}

# The fixture-pinned geometry (make_stairs_fixture.py south-offset wells; TEST_FIXTURES.md).
$ax = 6301; $ay = 6421

# ---------------------------------------------------------------------------------------------------
# G1a / G1b: generator --check-only over each slice world (source preconditions + dest read-back,
# incl. every stair pair and the package -- the per-floor-pair determinism conditions of doc 47 §4).
# ---------------------------------------------------------------------------------------------------
$g1 = Join-Path $OutRoot "g1"
if( Test-Path $g1 ) { Remove-Item $g1 -Recurse -Force }
New-Item -ItemType Directory -Force $g1 | Out-Null
$checks = @(
    @{ name = "G1a SliceTest check-only"; args = @("`"$Generator`"", '--check-only', '--fixture-root', "`"$UserDir`"",
            '--source-world', 'ArcopolisBackpackTest', '--dest-world', 'ArcopolisSliceTest',
            '--package-typeid', 'box_small', '--package-offset', '0,2,-1') },
    @{ name = "G1b TowerTest check-only"; args = @("`"$Generator`"", '--check-only', '--fixture-root', "`"$UserDir`"",
            '--source-world', 'ArcopolisBackpackTest', '--dest-world', 'ArcopolisTowerTest', '--floors', '6',
            '--package-typeid', 'box_small', '--package-offset', '0,6,-5') }
)
foreach( $c in $checks ) {
    $log = Join-Path $g1 (($c.name -replace '[^A-Za-z0-9]', '_') + ".txt")
    $pg = Start-Process -FilePath "python" -ArgumentList $c.args -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError ($log + ".err")
    if( $pg.ExitCode -ne 0 ) {
        Write-Host "  FAIL: $($c.name) exited $($pg.ExitCode): $(Get-Content ($log + '.err') -Raw)" -ForegroundColor Red
        $fail++
    } elseif( -not (Select-String -Path $log -Pattern 'dest read-back both pass' -Quiet) ) {
        Write-Host "  FAIL: $($c.name) did not confirm the dest read-back. Raw: $(Get-Content $log -Raw)" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: $($c.name) (preconditions + dest read-back)." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------------------------------
# G1c: DEFAULT-invocation content-identity (the ratified non-goal). Regenerate the Spike 23 fixture
# from ArcopolisTest under a scratch name and compare content with the committed ArcopolisStairsTest.
# ---------------------------------------------------------------------------------------------------
$log = Join-Path $g1 "g1c_default_regen.txt"
$pg = Start-Process -FilePath "python" -ArgumentList @(
    "`"$Generator`"", '--fixture-root', "`"$UserDir`"", '--dest-world', 'ArcopolisStairsCheck', '--force'
) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError ($log + ".err")
if( $pg.ExitCode -ne 0 ) {
    Write-Host "  FAIL: G1c default regen exited $($pg.ExitCode): $(Get-Content ($log + '.err') -Raw)" -ForegroundColor Red
    $fail++
} else {
    $cmpPy = Join-Path $g1 "compare_worlds.py"
    @'
import json, os, sqlite3, sys, zlib
a_dir, b_dir = sys.argv[1], sys.argv[2]
fail = 0
def listing(d):
    out = {}
    for root, _dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            out[os.path.relpath(p, d)] = p
    return out
la, lb = listing(a_dir), listing(b_dir)
if set(la) != set(lb):
    print("DIFF: file sets differ:", sorted(set(la) ^ set(lb))[:10]); fail += 1
for rel in sorted(set(la) & set(lb)):
    if rel.endswith("map.sqlite3"):
        ca, cb = sqlite3.connect(la[rel]), sqlite3.connect(lb[rel])
        ra = {p: (par, c, bytes(d)) for p, par, c, d in ca.execute("SELECT path,parent,compression,data FROM files")}
        rb = {p: (par, c, bytes(d)) for p, par, c, d in cb.execute("SELECT path,parent,compression,data FROM files")}
        ca.close(); cb.close()
        if set(ra) != set(rb):
            print("DIFF:", rel, "row sets differ:", sorted(set(ra) ^ set(rb))[:5]); fail += 1; continue
        for p in ra:
            (pa, cmpa, da), (pb, cmpb, db) = ra[p], rb[p]
            pay = lambda c, d: zlib.decompress(d) if c == "zlib" else d
            if (pa, cmpa) != (pb, cmpb) or pay(cmpa, da) != pay(cmpb, db):
                print("DIFF:", rel, "row", p); fail += 1
    else:
        if open(la[rel], "rb").read() != open(lb[rel], "rb").read():
            print("DIFF:", rel, "bytes differ"); fail += 1
print("CONTENT-IDENTICAL" if fail == 0 else "CONTENT-DIFFERS (%d)" % fail)
sys.exit(0 if fail == 0 else 1)
'@ | Set-Content -Encoding ascii $cmpPy
    $cmpLog = Join-Path $g1 "g1c_compare.txt"
    $pc = Start-Process -FilePath "python" -ArgumentList @(
        "`"$cmpPy`"", "`"$(Join-Path $UserDir 'save\ArcopolisStairsCheck')`"",
        "`"$(Join-Path $UserDir 'save\ArcopolisStairsTest')`""
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $cmpLog -RedirectStandardError ($cmpLog + ".err")
    if( $pc.ExitCode -ne 0 -or -not (Select-String -Path $cmpLog -Pattern 'CONTENT-IDENTICAL' -Quiet) ) {
        Write-Host "  FAIL: G1c default output is NOT content-identical to the committed ArcopolisStairsTest (ratified non-goal violated). Raw: $(Get-Content $cmpLog -Raw)" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: G1c default invocation content-identical to committed ArcopolisStairsTest." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------------------------------
# G1d: loaded z=0 read-back per slice world (transposed-index catcher at load level).
# ---------------------------------------------------------------------------------------------------
foreach( $w in @("ArcopolisSliceTest", "ArcopolisTowerTest") ) {
    $dir = Join-Path $OutRoot ("g1d_" + $w)
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $scriptPath = Join-Path $dir "script.json"
    '{ "schema_version": 1, "steps": [ { "op": "export", "name": "load" } ] }' |
        Set-Content -Encoding ascii $scriptPath
    $code = Invoke-Backend -Dir $dir -BackendArgs @(
        '--world', $w, '--arcopolis-run-script', "`"$scriptPath`"",
        '--arcopolis-export-dir', "`"$dir`"", '--userdir', "`"$UserDir`"")
    $snapFile = Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | Sort-Object Name | Select-Object -First 1
    $ok = $false
    if( $code -eq 0 -and $snapFile ) {
        $snap = Get-Content $snapFile.FullName -Raw | ConvertFrom-Json
        $at = @($snap.tiles | Where-Object { $_ -and $_.is_avatar -eq $true })
        $ok = ( $at.Count -eq 1 -and $at[0].ter -eq "t_stairs_down" -and
                $snap.avatar.pos_abs[0] -eq $ax -and $snap.avatar.pos_abs[1] -eq $ay -and $snap.avatar.pos_abs[2] -eq 0 )
    }
    if( $ok ) {
        Write-Host "  PASS: G1d $w loads with the avatar on t_stairs_down at [$ax,$ay,0]." -ForegroundColor Green
    } else {
        Write-Host "  FAIL: G1d $w load read-back (exit $code)." -ForegroundColor Red
        $fail++
    }
}

# ---------------------------------------------------------------------------------------------------
# G2: the 6-floor round trip on ArcopolisTowerTest (run-script; per-leg pos/ter/turn asserts).
# ---------------------------------------------------------------------------------------------------
$dir = Join-Path $OutRoot "g2_tower_roundtrip"
if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null

# Leg table: pair k joins z=-k to z=-k-1 at well (ax, ay+k); wells offset one tile SOUTH per pair.
$legs = @()
foreach( $k in 0..4 ) {
    $legs += , @{ cmd = "vertical_move"; dir = "down"; pos = @($ax, ($ay + $k), (-( $k + 1 ))); ter = "t_stairs_up" }
    if( $k -lt 4 ) {
        $legs += , @{ cmd = "move"; dir = "move_s"; pos = @($ax, ($ay + $k + 1), (-( $k + 1 ))); ter = "t_stairs_down" }
    }
}
foreach( $k in 4..0 ) {
    $legs += , @{ cmd = "vertical_move"; dir = "up"; pos = @($ax, ($ay + $k), (-$k)); ter = "t_stairs_down" }
    if( $k -gt 0 ) {
        $legs += , @{ cmd = "move"; dir = "move_n"; pos = @($ax, ($ay + $k - 1), (-$k)); ter = "t_stairs_up" }
    }
}
$steps = @( @{ op = "export"; name = "t0" } )
for( $i = 0; $i -lt $legs.Count; $i++ ) {
    $steps += @{ op = "command"; command = $legs[$i].cmd; direction = $legs[$i].dir }
    $steps += @{ op = "export"; name = ("leg{0:d2}" -f $i) }
}
$scriptPath = Join-Path $dir "script.json"
@{ schema_version = 1; steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii $scriptPath

$code = Invoke-Backend -Dir $dir -BackendArgs @(
    '--world', 'ArcopolisTowerTest', '--arcopolis-run-script', "`"$scriptPath`"",
    '--arcopolis-export-dir', "`"$dir`"", '--userdir', "`"$UserDir`"")
if( $code -ne 0 ) {
    Write-Host "  FAIL: G2 tower round trip exited $code (a sub-prompt would be unexpected_prompt/14): $(Get-Content (Join-Path $dir 'stderr.txt') -Raw)" -ForegroundColor Red
    $fail++
} else {
    $endLine = Get-Content (Join-Path $dir "session.jsonl") | Where-Object { $_ -match '"session_end"' } | Select-Object -Last 1
    $endEvt = if( $endLine ) { $endLine | ConvertFrom-Json } else { $null }
    if( -not $endEvt -or $endEvt.status -ne "ok" ) {
        Write-Host "  FAIL: G2 session_end status='$($endEvt.status)' (expected ok)." -ForegroundColor Red
        $fail++
    } else {
        # Index snapshots by export name and walk the leg table.
        $byName = @{}
        Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | ForEach-Object {
            $s = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $byName[$s.session.export_name] = $s
        }
        $legFail = 0
        # t0 is damage-checked too, so "damage_taken[] empty in every snapshot" covers all 19, not 18/19.
        if( @($byName["t0"].avatar.damage_taken).Count -ne 0 ) {
            Write-Host "  FAIL: G2 t0 snapshot carries damage_taken entries (load-instant interference)." -ForegroundColor Red
            $legFail++
        }
        $prevTurn = $byName["t0"].backend.turn
        for( $i = 0; $i -lt $legs.Count; $i++ ) {
            $s = $byName[("leg{0:d2}" -f $i)]
            $want = $legs[$i]
            if( -not $s ) { Write-Host "  FAIL: G2 leg $i snapshot missing." -ForegroundColor Red; $legFail++; continue }
            $pos = @($s.avatar.pos_abs)
            $at = @($s.tiles | Where-Object { $_ -and $_.is_avatar -eq $true })
            $posOk = ($pos[0] -eq $want.pos[0] -and $pos[1] -eq $want.pos[1] -and $pos[2] -eq $want.pos[2])
            $terOk = ($at.Count -eq 1 -and $at[0].ter -eq $want.ter)
            $turnOk = ($s.backend.turn -gt $prevTurn)
            $dmgOk = (@($s.avatar.damage_taken).Count -eq 0)
            $hermOk = $true
            if( $pos[2] -le -2 ) {
                $hermOk = (@($s.entities.monsters).Count -eq 0 -and @($s.entities.npcs).Count -eq 0)
            }
            if( -not ($posOk -and $terOk -and $turnOk -and $dmgOk -and $hermOk) ) {
                Write-Host "  FAIL: G2 leg $i ($($want.cmd) $($want.dir)): pos=[$($pos -join ',')] want=[$($want.pos -join ',')] ter='$($at[0].ter)' want='$($want.ter)' turnOk=$turnOk dmgOk=$dmgOk hermOk=$hermOk" -ForegroundColor Red
                $legFail++
            }
            $prevTurn = $s.backend.turn
        }
        if( $legFail -eq 0 ) {
            Write-Host "  PASS: G2 6-floor round trip -- all $($legs.Count) legs on trajectory (pos/ter/turn), synthesized floors hermetic, damage_taken empty." -ForegroundColor Green
        } else {
            Write-Host "  FAIL: G2 -- $legFail leg assertion(s) failed." -ForegroundColor Red
            $fail++
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# G3 / G4: the live composites (slice_live_driver.py). The driver writes a result JSON whose gates
# this wrapper re-asserts individually (never trusting the aggregate alone).
# ---------------------------------------------------------------------------------------------------
$driverCases = @(
    @{ name = "G3"; world = "ArcopolisSliceTest"; floors = 2 },
    @{ name = "G4"; world = "ArcopolisTowerTest"; floors = 6 }
)
foreach( $c in $driverCases ) {
    $dir = Join-Path $OutRoot ("{0}_{1}" -f $c.name.ToLower(), $c.world)
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $resultPath = Join-Path $dir "result.json"
    $pd = Start-Process -FilePath "python" -ArgumentList @(
        "`"$Driver`"", '--exe', "`"$Exe`"", '--world', $c.world, '--floors', $c.floors,
        '--userdir', "`"$UserDir`"", '--export-dir', "`"$dir`"", '--out', "`"$resultPath`""
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $dir "driver_stdout.txt") `
        -RedirectStandardError (Join-Path $dir "driver_stderr.txt")
    if( $pd.ExitCode -ne 0 -or -not (Test-Path $resultPath) ) {
        Write-Host "  FAIL: $($c.name) driver exited $($pd.ExitCode) on $($c.world): $(Get-Content (Join-Path $dir 'driver_stderr.txt') -Raw)" -ForegroundColor Red
        $fail++
        continue
    }
    $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    # Re-assert each load-bearing gate individually (the wrapper never trusts result.ok alone).
    $required = @(
        "possession_false_at_start", "descent_trajectory", "floor_provenance_before",
        "walk_to_package", "pickup_l4_transaction", "floor_provenance_after",
        "return_to_landing", "z_changed_off_contact_pinned", "final_ascent",
        "composite_green_at_contact", "off_contact_displacement",
        "no_damage_interference", "scope_label_guard"
    )
    # hermetic_lower_floors exists only when the fixture has z<=-2 floors (at floors=2 it would be a
    # gate that cannot fail -- vacuously green -- so the driver does not record it there).
    if( $c.floors -gt 2 ) { $required += @("ascent_trajectory", "hermetic_lower_floors") }
    $gateFail = 0
    foreach( $g in $required ) {
        $gate = $result.gates.$g
        if( -not $gate -or $gate.pass -ne $true ) {
            Write-Host "  FAIL: $($c.name) gate '$g' did not pass: $($gate | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Red
            $gateFail++
        }
    }
    if( $result.ok -ne $true -or $result.process_exit_code -ne 0 ) {
        Write-Host "  FAIL: $($c.name) driver summary ok=$($result.ok) exit=$($result.process_exit_code)." -ForegroundColor Red
        $gateFail++
    }
    if( $gateFail -eq 0 ) {
        Write-Host "  PASS: $($c.name) composite on $($c.world) -- all $($required.Count) gates + clean backend exit." -ForegroundColor Green
    } else {
        $fail++
    }
}

if( $fail -gt 0 ) { Write-Host "SLICE REGRESSION: $fail hard gate group(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "SLICE REGRESSION: ok (G1 fixture determinism + content-identity, G2 6-floor round trip, G3 2-floor composite, G4 6-floor composite)." -ForegroundColor Green
exit 0
