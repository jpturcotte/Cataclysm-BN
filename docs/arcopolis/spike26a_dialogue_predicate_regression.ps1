<#
.SYNOPSIS
  Arcopolis Spike 26A regression scenario — L1 on-person dialogue-predicate query.

.DESCRIPTION
  Drives ONE persistent --arcopolis-live backend over the ArcopolisCarriedNestedTest fixture and asserts
  every Spike 26A witness case (the four predicate cases + fail-loud bad_request + count > 1 + recovery)
  through the new wire op `op:"query", kind:"has_item"`. The op forwards verbatim to BN's dialogue-
  predicate disjunction `has_charges(id, count) || has_amount(id, count)` (`condition.cpp`
  `set_has_items`) on `get_avatar()` and returns the boolean as `{ok:true, op:"query", kind:"has_item",
  has:<bool>, scope:"on_person_dialogue_predicate"}`. The literal scope string is the LOAD-BEARING
  LABELING GUARD (repeated verbatim in doc 52, the ARCOPOLIS_STATE row, the Catch2 test name, and this
  regression's per-case PASS line) -- a future doc/code drift cannot silently re-claim mission-completion
  scope without changing every coordinated site.

  Equivalence claim: L1 observation of the on-person dialogue predicate. This regression does NOT prove
  MGOAL_FIND_ITEM mission completion (Spike 26B's broader `crafting_inventory()`-scope predicate) and
  does NOT drive any NPC dialogue or turn loop (Spike 26C's L4 mission completion).

  Witness fixture: ArcopolisCarriedNestedTest, built by `make_carried_nested_fixture.py` by cloning
  ArcopolisBackpackTest (GUI-created; not regenerated). The clone save-edits FOUR witness items:
    * glass_shard nested inside the worn backpack's pocket (the visit_internal-recursion witness)
    * rock as player.weapon (the wielded source)
    * feather on the AVATAR'S OWN TILE in the .map (the scope-pinning ground witness)
  Plus wooden_kitchen_spoon as the absent id (queried directly; not placed in the fixture).

  Gates (hard assertions):
    1. Prereqs (binary / fixture root / world / python / driver / fixture-generator).
    2. Sandbox refresh (memory doc 26 hygiene: pwsh-only; the Copy-Item nesting gotcha).
    3. Driver exits 0 with ok=true on the result JSON; backend exits 0; session_end seen.
    4. All seven query cases pass (worn_nested / wielded / absent / ground / garbage_unknown_id /
       worn_nested_count_2 / recovery_glass_shard).
    5. Every successful query response carries scope="on_person_dialogue_predicate" verbatim.
    6. The ground case (4) is has:false (load-bearing anti-`crafting_inventory()` assertion).
    7. The garbage_unknown_id case is ok:false with code:bad_request and the session keeps serving
       (the recovery_glass_shard case passes AFTER the rejection -- recoverable invariant).
    8. TRANSCRIPT-LEVEL mid-prompt query rejection: a live `pickup direction=here` opens the Spike 12A
       PICKUP menu; mid-prompt `op:"query"` is rejected as bad_request (prompt stays open); a clean
       prompt_cancel acks and finalizes the command; a final query after the cancel still succeeds
       (the session is recoverable). Companion to the Catch2 parser-level case.

.NOTES
  Run with `pwsh` (PowerShell 7), NOT `powershell` (5.1) -- 5.1 mishandles BOM-less UTF-8 / writes
  a BOM in options.json, causing spurious gate failures on unchanged code (memory doc 26).
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisCarriedNestedTest",
    [string]$OutRoot    = ".\out\arco_spike26a_regress",
    [string]$Driver     = "docs\arcopolis\spike26a_query_driver.py",
    [string]$FixtureGen = "docs\arcopolis\make_carried_nested_fixture.py"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback.
. "$PSScriptRoot/arco_fixture_root.ps1"
if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

# Fatal-prereq helper (memory doc 25: Write-Error with -ErrorAction Continue, else $ErrorActionPreference=Stop
# unwinds before `exit` runs and collapses every guard to exit 1).
function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=driver, 8=fixture-gen,
# 10=sandbox-path-too-long -- the MAX_PATH guard below the block; 9 is the missing-driver-result guard later). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) {
    Stop-WithCode "Fixture source directory not found: $(Format-ArcoPath $FixtureSrc)  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $(Format-ArcoPath $fixtureWorld) -- run 'python $(Format-ArcoPath $FixtureGen)' to build it from ArcopolisBackpackTest." 5
}
if( -not (Get-Command python -ErrorAction SilentlyContinue) ) {
    Stop-WithCode "python not found on PATH (needed to run the live driver). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Driver) ) {
    Stop-WithCode "Driver not found: $(Format-ArcoPath $Driver)" 7
}
if( -not (Test-Path $FixtureGen) ) {
    Stop-WithCode "Fixture generator not found: $(Format-ArcoPath $FixtureGen)" 8
}

# MAX_PATH guard (exit 10): a long sandbox root makes the ENGINE fail with an opaque
# "failed to load world" (witnessed 2026-07-01 from a ~150-char checkout path; the world's
# deepest save paths exceed the Win32 path limit). Fail loud with attribution instead.
$userDirAbs = [System.IO.Path]::GetFullPath($UserDir, (Get-Location).Path)
if( $userDirAbs.Length -gt 120 ) {
    Stop-WithCode "Sandbox userdir path is too long for the engine ($($userDirAbs.Length) chars > 120): run this regression from a SHORT checkout root (e.g. under C:\tmp) or pass a short -UserDir/-OutRoot; a long userdir fails at world load with an unattributed 'failed to load world'." 10
}

# Refresh the gitignored sandbox world from the fixture root.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run provenance (cross-machine dispute discriminators: WHICH binary and WHICH fixture pack ran).
$exeItem = Get-Item $Exe
Write-Host ("  provenance: exe {0}  (modified {1:yyyy-MM-dd HH:mm:ss}, {2} bytes)" -f (Format-ArcoPath $Exe), $exeItem.LastWriteTime, $exeItem.Length)
Write-Host ("  provenance: fixture root {0}; sandbox {1}" -f (Format-ArcoPath $FixtureSrc), (Format-ArcoPath $userDirAbs))
if( $env:ARCO_FIXTURE_ROOT ) { Write-Host "  provenance: ARCO_FIXTURE_ROOT is SET (fixture resolution may bypass the repo pack)" -ForegroundColor Yellow }

# Run the driver.
$resultPath = Join-Path $OutRoot "spike26a_result.json"
$stderrPath = Join-Path $OutRoot "spike26a_stderr.txt"
$exportDir  = Join-Path $OutRoot "live_session"
if( Test-Path $exportDir ) { Remove-Item $exportDir -Recurse -Force }

# Quote path-valued args: Start-Process -ArgumentList joins the array space-separated, so a path containing
# a space (a spaced checkout/binary) would otherwise reach python's argparse split into broken tokens.
$argList = @("`"$Driver`"", '--exe', "`"$Exe`"", '--world', $World, '--userdir', "`"$UserDir`"",
             '--export-dir', "`"$exportDir`"", '--out', "`"$resultPath`"")
$p = Start-Process -FilePath "python" -ArgumentList $argList -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $OutRoot "driver_stdout.txt") `
    -RedirectStandardError $stderrPath

$fail = 0

# --- Hard gate 1: driver exits 0. ---
if( $p.ExitCode -ne 0 ) {
    Write-Host "  FAIL: driver exited $($p.ExitCode) (expected 0). stderr: $(Format-ArcoPath (Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue))" -ForegroundColor Red
    Write-Host "SPIKE 26A DIALOGUE PREDICATE REGRESSION: driver failed, abandoning gates." -ForegroundColor Red
    exit 1
}
if( -not (Test-Path $resultPath) ) {
    Stop-WithCode "Driver did not write a result JSON at $(Format-ArcoPath $resultPath)" 9
}
$result = Get-Content $resultPath -Raw | ConvertFrom-Json

# --- Hard gate 2: backend exited 0; session_end seen. ---
if( $result.process_exit_code -ne 0 ) {
    Write-Host "  FAIL: backend exited $($result.process_exit_code) (expected 0)." -ForegroundColor Red
    $fail++
} elseif( -not $result.quit_ok ) {
    Write-Host "  FAIL: session_end not observed (driver did not see ok=true / status=session_end on quit)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: backend exit 0, session_end observed." -ForegroundColor Green
}

# --- Hard gate 3: ready event reports protocol_version 1 and the requested world. ---
if( $result.ready.protocol_version -ne 1 -or $result.ready.world -ne $World ) {
    Write-Host "  FAIL: ready -- protocol_version=$($result.ready.protocol_version) world='$($result.ready.world)' (expected 1 / '$World')." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: ready event -- protocol_version 1, world '$($result.ready.world)'." -ForegroundColor Green
}

# --- Hard gate 4: every case passes its individual predicate check. ---
$cases = @($result.cases | Where-Object { $null -ne $_ })
if( $cases.Count -ne 7 ) {
    Write-Host "  FAIL: case count = $($cases.Count) (expected 7)." -ForegroundColor Red
    $fail++
} else {
    foreach( $c in $cases ) {
        if( -not $c.pass ) {
            Write-Host "  FAIL: case '$($c.label)' -- ok=$($c.resp_ok) has=$($c.resp_has) scope='$($c.resp_scope)' code='$($c.resp_error_code)' msg='$($c.resp_error_message)'." -ForegroundColor Red
            $fail++
        } else {
            $detail = if( $null -ne $c.resp_has ) { "has=$($c.resp_has) scope=`"$($c.resp_scope)`"" } else { "code='$($c.resp_error_code)'" }
            Write-Host "  PASS: case '$($c.label)' -- $detail" -ForegroundColor Green
        }
    }
}

# --- Hard gate 5: every successful query response carries the labeling guard verbatim. ---
$labelMismatches = @($cases | Where-Object { $_.resp_ok -eq $true -and $_.resp_scope -ne 'on_person_dialogue_predicate' })
if( $labelMismatches.Count -gt 0 ) {
    Write-Host "  FAIL: labeling guard violated -- $($labelMismatches.Count) successful response(s) did NOT carry scope='on_person_dialogue_predicate'." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: every successful query response carries scope='on_person_dialogue_predicate' (labeling guard)." -ForegroundColor Green
}

# --- Hard gate 6: the ground case is has:false (LOAD-BEARING anti-crafting_inventory assertion). ---
$ground = $cases | Where-Object { $_.label -eq 'ground_feather' } | Select-Object -First 1
if( $null -eq $ground -or $ground.resp_has -ne $false ) {
    Write-Host "  FAIL: ground_feather case -- expected has:false (scope-pinning anti-crafting_inventory()); got has=$($ground.resp_has)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: ground_feather has:false -- the on-person predicate excludes the avatar's own tile (Spike 26B's broader crafting_inventory scope would flip this)." -ForegroundColor Green
}

# --- Hard gate 7: the unknown id is rejected as bad_request AND the session keeps serving. ---
$garbage = $cases | Where-Object { $_.label -eq 'garbage_unknown_id' } | Select-Object -First 1
$recovery = $cases | Where-Object { $_.label -eq 'recovery_glass_shard' } | Select-Object -First 1
$garbageOk = $null -ne $garbage -and $garbage.resp_ok -eq $false -and $garbage.resp_error_code -eq 'bad_request'
$recoveryOk = $null -ne $recovery -and $recovery.resp_ok -eq $true -and $recovery.resp_has -eq $true
if( -not $garbageOk -or -not $recoveryOk ) {
    Write-Host "  FAIL: fail-loud + recovery -- garbage ok=$($garbage.resp_ok) code='$($garbage.resp_error_code)'; recovery ok=$($recovery.resp_ok) has=$($recovery.resp_has)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: unknown itype_id -> bad_request (recoverable); the next valid query still returns has:true." -ForegroundColor Green
}

# --- Hard gate 8: TRANSCRIPT-LEVEL mid-prompt query rejection. A live `pickup direction=here` opens
# the Spike 12A PICKUP menu (the avatar's tile holds the ground feather from the fixture); the driver
# then submits `op:"query"` mid-prompt, which the prompt-source reader's parse_prompt_answer rejects
# as bad_request (the prompt stays OPEN); a subsequent prompt_cancel closes it cleanly. This is the
# transcript-level companion to the Catch2 parser-level case in tests/arcopolis_live_test.cpp -- the
# two together pin the mid-prompt input-ordering invariant at both the parser and the live levels
# (doc 52: "Where the mid-prompt witness lives"). A final query after the cancel confirms the session
# is still alive (recoverable). ---
$mp = $result.mid_prompt
$mpOk = $null -ne $mp -and $mp.pass -eq $true -and $mp.prompt_kind -eq 'menu' -and
        $mp.mid_query_resp_ok -eq $false -and $mp.mid_query_error_code -eq 'bad_request' -and
        $mp.cancel_ack_ok -eq $true -and $mp.command_resp_ok -eq $true -and
        $result.post_mid_prompt_query_pass -eq $true
if( -not $mpOk ) {
    Write-Host "  FAIL: mid-prompt query gate -- prompt_kind='$($mp.prompt_kind)' mid_query_ok=$($mp.mid_query_resp_ok) mid_query_code='$($mp.mid_query_error_code)' cancel_ack=$($mp.cancel_ack_ok) cmd_resp=$($mp.command_resp_ok) post_query_pass=$($result.post_mid_prompt_query_pass) (expected menu/false/bad_request/true/true/true)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: mid-prompt query -- pickup PICKUP menu opens (kind=menu), mid-prompt op:'query' rejected as bad_request (prompt OPEN), prompt_cancel acks, command finalizes, post-cancel query succeeds (recoverable)." -ForegroundColor Green
}

if( $fail -gt 0 ) {
    Write-Host "SPIKE 26A DIALOGUE PREDICATE REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "SPIKE 26A DIALOGUE PREDICATE REGRESSION: ok." -ForegroundColor Green
exit 0
