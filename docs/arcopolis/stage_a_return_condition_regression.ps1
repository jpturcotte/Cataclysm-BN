<#
.SYNOPSIS
  Arcopolis Stage A return-condition regression — L1 carried-at-contact composite witness.

.DESCRIPTION
  Drives ONE persistent --arcopolis-live backend over the ArcopolisCarriedNestedTest fixture and proves
  that a frontend/consumer can compute the chosen Stage A return signal

      carried_at_contact = avatar.pos_abs == contact_pos_abs
                          && query.has == true
                          && query.scope == "on_person_dialogue_predicate"

  PURELY from existing native observations — position via live `op:"export"` (native-authority class S:
  `avatar.pos_abs` = `ctx.u.abs_pos()`), possession via the Spike 26A live `op:"query", kind:"has_item"`
  (class C: BN's on-person dialogue predicate `has_charges(id,count) || has_amount(id,count)`, labelled
  `scope:"on_person_dialogue_predicate"`). The `command move` step is NOT the claim under test; it is
  existing level-2/3 movement machinery used only to manufacture the OFF-contact false-green case, and the
  driver PROVES the move landed (post-move `pos_abs != contact_pos_abs`) instead of trusting command success.

  Equivalence claim: L1 observation only. This regression does NOT prove MGOAL_FIND_ITEM,
  crafting_inventory(), NPC item checks, dialogue selection, mission completion, "package returned" in any
  BN engine-native objective sense, or L4 input equivalence. The conjunction stays CONSUMER-SIDE — the
  backend gains no "return condition" API and mutates no state. See
  docs/arcopolis/53_STAGE_A_RETURN_CONDITION_WITNESS.md for the proof boundary and false-green matrix.

  Witness fixture: ArcopolisCarriedNestedTest (Spike 26A; built by make_carried_nested_fixture.py by
  cloning ArcopolisBackpackTest). Relevant placements reused as-is (no fixture change): glass_shard nested
  inside the worn backpack pocket (the package), feather on the avatar's OWN ground tile (the
  anti-crafting_inventory() scope-pin), hairpin absent from the avatar (a valid-but-absent id).

  Setup (prereq / hygiene — fail with distinct exit codes, not the ten PASS/FAIL gates below):
    * Prereqs (binary / fixture root / world / python / driver / fixture-generator; codes 3-8).
    * Sandbox refresh (memory doc 26 hygiene: pwsh-only; the Copy-Item nesting gotcha).
    * Driver exits 0 and writes the result JSON (else exit 1 / code 9 — gates abandoned).

  Ten hard PASS/FAIL gates (each increments $fail; any failure -> exit 1):
    1. Backend exits 0; session_end (clean quit) observed.
    2. ready event matches ArcopolisCarriedNestedTest / protocol_version 1.
    3. Contact export exists and carries avatar.pos_abs.
    4. carried_at_contact_glass_shard: composite TRUE (AT contact + has:true).
    5. dropped_at_contact_feather: composite FALSE (has:false — anti-crafting_inventory()).
    6. wrong_position_glass_shard: composite FALSE, with PROVEN post-move pos_abs != contact_pos_abs
       (exact south delta [0,1,0]) and a clean move command.
    7. flat_carried_items_not_authority: the query returns has:true while the flat avatar.carried_items[]
       export lacks the nested glass_shard.
    8. scope_label_guard: every successful query response carries scope="on_person_dialogue_predicate".
    9. absent_hairpin: a valid-but-absent id is has:false / composite FALSE.
   10. unknown_id_fail_loud: a garbage itype_id is rejected ok:false / code:bad_request (not silent false).

.NOTES
  Run with `pwsh` (PowerShell 7), NOT `powershell` (5.1) — 5.1 mishandles BOM-less UTF-8 / writes a BOM
  in options.json, causing spurious gate failures on unchanged code (memory doc 26).
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisCarriedNestedTest",
    [string]$OutRoot    = ".\out\arco_stage_a_return_regress",
    [string]$Driver     = "docs\arcopolis\stage_a_return_condition_driver.py",
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

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python, 7=driver, 8=fixture-gen). ---
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

# Refresh the gitignored sandbox world from the fixture root.
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Run the driver.
$resultPath = Join-Path $OutRoot "stage_a_result.json"
$stderrPath = Join-Path $OutRoot "stage_a_stderr.txt"
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

# --- Setup check (NOT one of the ten PASS/FAIL gates): driver exits 0; else abandon the gates. ---
if( $p.ExitCode -ne 0 ) {
    Write-Host "  FAIL: driver exited $($p.ExitCode) (expected 0). stderr: $(Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue)" -ForegroundColor Red
    Write-Host "STAGE A RETURN-CONDITION REGRESSION: driver failed, abandoning gates." -ForegroundColor Red
    exit 1
}
if( -not (Test-Path $resultPath) ) {
    Stop-WithCode "Driver did not write a result JSON at $(Format-ArcoPath $resultPath)" 9
}
$result = Get-Content $resultPath -Raw | ConvertFrom-Json
$gates  = $result.gates

# --- Hard gate 1: backend exited 0; session_end seen. ---
if( $result.process_exit_code -ne 0 ) {
    Write-Host "  FAIL: backend exited $($result.process_exit_code) (expected 0)." -ForegroundColor Red
    $fail++
} elseif( -not $result.quit_ok ) {
    Write-Host "  FAIL: session_end not observed (driver did not see ok=true / status=session_end on quit)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: backend exit 0, session_end observed." -ForegroundColor Green
}

# --- Hard gate 2: ready event reports protocol_version 1 and the requested world. ---
if( $result.ready.protocol_version -ne 1 -or $result.ready.world -ne $World ) {
    Write-Host "  FAIL: ready -- protocol_version=$($result.ready.protocol_version) world='$($result.ready.world)' (expected 1 / '$World')." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: ready event -- protocol_version 1, world '$($result.ready.world)'." -ForegroundColor Green
}

# --- Hard gate 3: contact export exists and carries avatar.pos_abs. ---
if( $null -eq $result.contact_pos_abs -or @($result.contact_pos_abs).Count -ne 3 ) {
    Write-Host "  FAIL: contact export missing a 3-element avatar.pos_abs (got '$($result.contact_pos_abs)')." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: contact export carries avatar.pos_abs = [$($result.contact_pos_abs -join ',')]." -ForegroundColor Green
}

# --- Hard gate 4: carried_at_contact_glass_shard -- composite TRUE. ---
$g = $gates.carried_at_contact_glass_shard
if( $null -eq $g -or -not $g.pass -or $g.composite -ne $true ) {
    Write-Host "  FAIL: carried_at_contact_glass_shard -- pos_match=$($g.pos_match) has=$($g.query_has) scope='$($g.scope)' composite=$($g.composite) (expected composite TRUE)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: carried_at_contact_glass_shard -- AT contact + has:true -> composite TRUE." -ForegroundColor Green
}

# --- Hard gate 5: dropped_at_contact_feather -- composite FALSE (anti-crafting_inventory()). ---
$g = $gates.dropped_at_contact_feather
if( $null -eq $g -or -not $g.pass -or $g.query_has -ne $false -or $g.composite -ne $false ) {
    Write-Host "  FAIL: dropped_at_contact_feather -- has=$($g.query_has) composite=$($g.composite) (expected has:false / composite FALSE; the on-person predicate excludes the avatar's own ground tile)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: dropped_at_contact_feather -- has:false -> composite FALSE (Spike 26B's broader crafting_inventory() scope would flip this)." -ForegroundColor Green
}

# --- Hard gate 6: wrong_position_glass_shard -- composite FALSE with PROVEN off-contact move. ---
$g = $gates.wrong_position_glass_shard
$moveProven = $null -ne $g -and $g.moved_off_contact -eq $true -and $g.move_ok -eq $true `
              -and ($g.delta -join ',') -eq '0,1,0'
if( $null -eq $g -or -not $g.pass -or $g.query_has -ne $true -or $g.composite -ne $false -or -not $moveProven ) {
    Write-Host "  FAIL: wrong_position_glass_shard -- has=$($g.query_has) composite=$($g.composite) moved_off_contact=$($g.moved_off_contact) move_ok=$($g.move_ok) delta=[$($g.delta -join ',')] (expected has:true / composite FALSE / proven off-contact move_s delta [0,1,0])." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: wrong_position_glass_shard -- after a PROVEN move_s off contact (delta [0,1,0]), has:true but pos!=contact -> composite FALSE." -ForegroundColor Green
}

# --- Hard gate 7: flat_carried_items_not_authority -- query true, flat export lacks the nested id. ---
$g = $gates.flat_carried_items_not_authority
if( $null -eq $g -or -not $g.pass -or $g.query_has -ne $true -or $g.flat_carried_has -ne $false ) {
    Write-Host "  FAIL: flat_carried_items_not_authority -- query_has=$($g.query_has) flat_carried_has=$($g.flat_carried_has) (expected query has:true while flat carried_items[] lacks the nested glass_shard). A flat export that NOW contains it is a STOP -> re-audit the fixture/export." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: flat_carried_items_not_authority -- query has:true while flat avatar.carried_items[] omits the nested glass_shard (the predicate is the authority, not the flat export)." -ForegroundColor Green
}

# --- Hard gate 8: scope_label_guard -- every successful query carries the labelling guard verbatim. ---
if( $result.scope_label_ok -ne $true ) {
    Write-Host "  FAIL: scope_label_guard -- not every successful query carried scope='on_person_dialogue_predicate' (observed: $($result.successful_query_scopes -join ', '))." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: scope_label_guard -- every successful query response carries scope='on_person_dialogue_predicate' verbatim." -ForegroundColor Green
}

# --- Hard gate 9: absent_hairpin -- has:false / composite FALSE (a valid-but-absent id). ---
$g = $gates.absent_hairpin
if( $null -eq $g -or -not $g.pass -or $g.query_has -ne $false -or $g.composite -ne $false ) {
    Write-Host "  FAIL: absent_hairpin -- has=$($g.query_has) composite=$($g.composite) (expected has:false / composite FALSE)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: absent_hairpin -- a valid-but-absent id is has:false -> composite FALSE." -ForegroundColor Green
}

# --- Hard gate 10: unknown_id_fail_loud -- bad_request, not a silent has:false. ---
$g = $gates.unknown_id_fail_loud
if( $null -eq $g -or -not $g.pass -or $g.query_ok -ne $false -or $g.error_code -ne 'bad_request' ) {
    Write-Host "  FAIL: unknown_id_fail_loud -- ok=$($g.query_ok) code='$($g.error_code)' (expected ok:false / bad_request; NOT a silent has:false). [Health/recovery only -- Spike 26A already proves this, not new Stage A evidence.]" -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: unknown_id_fail_loud -- garbage itype_id -> bad_request (recoverable; health gate, not new Stage A evidence)." -ForegroundColor Green
}

if( $fail -gt 0 ) {
    Write-Host "STAGE A RETURN-CONDITION REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "STAGE A RETURN-CONDITION REGRESSION: ok." -ForegroundColor Green
exit 0
