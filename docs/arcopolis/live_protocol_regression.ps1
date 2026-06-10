<#
.SYNOPSIS
  Arcopolis live-protocol regression scenario (Spike 9B, the persistent backend proof).

.DESCRIPTION
  Drives ONE persistent --arcopolis-live backend process over the ArcopolisTest fixture through the
  harness's live probe (tools/arcopolis_client/harness.py live): read the ready event, send
  export(start) -> move_n -> move_s -> wait -> quit ONE REQUEST AT A TIME (each next request only
  after the previous response/snapshot), and assert that the SAME explanation sequence Spike 9A got
  from a one-shot script comes out of one still-running process:

    * move_n FIRST, while the stock shelter NPC Edwardo Stovall is still one tile north of the
      avatar -> "blocked_no_op" with blocked_by=npc (after move_s the start tile is empty, so the
      order is load-bearing, exactly as in client_harness_regression.ps1).
    * move_s -> "moved" with pos_abs delta (0,1,0) and the turn advancing.
    * wait -> "waited" with the position unchanged and the turn advancing.
    * the final-on-exit pair -> "no_command" with nothing changed (clean-park after quit).

  The probe also verifies the live mode's stdout-purity guarantee: every backend stdout line must
  parse as a JSON protocol object (the harness hard-fails on the first non-JSON line), and every
  ok response's referenced snapshot must exist on disk before the next request is sent.

  A second scenario exercises RECOVERABILITY: an unsupported direction (move_up) must produce an
  ok=false response with error.code=unsupported_command WITHOUT ending the session, a follow-up
  wait must succeed and produce a snapshot, and the quit must still exit 0 with a contract-clean
  transcript (rejected requests are protocol-level only; they never become transcript error events).

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as the sibling
  scripts): it needs a fully loaded world and a real child process with redirected pipes. The pure
  request parser / response formatters ARE covered by `cata_test-tiles "[arcopolis]"`.

  What it asserts (hard gates):
    1. Happy path: `harness.py live --json` exits 0.
    2. live.ready_seen=true, live.protocol_version=1, live.process_exit_code=0.
    3. Five protocol responses (export + 3 commands + quit), all ok, in order, each export/command
       response naming an existing snapshot.
    4. explain contract_check.ok=true (schema 1).
    5. 4 pairs with outcome_sequence exactly: blocked_no_op,moved,waited,no_command.
    6. NPC-BLOCK PAIR: pair 0 is the single move_n, outcome blocked_no_op, blocked_by contains
       npc, turn_delta 0, pos_abs_delta 0,0,0, destination one tile north carrying NPC
       "Edwardo Stovall" (the canonical fixture blocker; the PASS line prints the harness's own
       explanation).
    7. MOVED PAIR: pair 1 is move_s, outcome moved, pos_abs_delta 0,1,0, turn_delta >= 1.
    8. WAIT PAIR: pair 2 is wait, outcome waited, pos_abs_delta 0,0,0, turn_delta >= 1.
    9. FINAL PAIR: pair 3 has no command, outcome no_command, turn_delta 0.
   10. The session dir holds session.jsonl + exactly 5 NNN_<name>.json snapshots.
   11. The Spike 4 viewer exits 0 on the same live session dir (consumer cross-check).
   12. Standalone `harness.py explain` exits 0 on the same live session dir.
   13. Negative scenario: `live --commands wait --negative-probe --json` exits 0 with
       negative_probe.error_code=unsupported_command, recovered=true, process_exit_code=0,
       contract_check.ok=true, and outcome_sequence waited,waited,no_command.

.NOTES
  C:\dev\arcopolis-fixtures is the project's approved local-path exception (AGENTS.md fixture
  section); kept verbatim so the commands stay copy-pasteable. No usernames/secrets.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_live_regress",
    [string]$Harness    = "tools\arcopolis_client\harness.py",
    [string]$Viewer     = "tools\arcopolis_viewer\make_report.py"
)

$ErrorActionPreference = "Stop"

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
    Stop-WithCode "Fixture source directory not found: $FixtureSrc" 4
}
$fixtureWorld = Join-Path $FixtureSrc (Join-Path "save" $World)
if( -not (Test-Path $fixtureWorld) ) {
    Stop-WithCode "Fixture world '$World' not found at $fixtureWorld -- copy the canonical ArcopolisTest fixture. See AGENTS.md (Arcopolis test world fixture)." 5
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

# Run a python tool via Start-Process (captures the real exit code) and return exit code + stdout
# text -- the sibling scripts' idiom.
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
# Scenario A: the happy-path live session (export -> move_n -> move_s -> wait -> quit).
# =============================================================================
$liveDir = Join-Path $OutRoot "live"
if( Test-Path $liveDir ) { Remove-Item $liveDir -Recurse -Force }
$liveJson = Join-Path $OutRoot "live_result.json"
$liveErr  = Join-Path $OutRoot "live_stderr.txt"
$pl = Invoke-PyTool -ToolArgs @($Harness, 'live', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $liveDir, '--commands', 'move_n,move_s,wait', '--json') `
    -StdoutPath $liveJson -StderrPath $liveErr

# --- Hard gate 1: the live probe exits 0 (0=clean; 2=contract discrepancies; 1=fatal/protocol). ---
if( $pl.ExitCode -ne 0 ) {
    Write-Host "  FAIL: harness live exited $($pl.ExitCode) (expected 0). stderr: $(Get-Content $liveErr -Raw -ErrorAction SilentlyContinue)" -ForegroundColor Red
    Write-Host "LIVE PROTOCOL REGRESSION: 1 hard assertion failed." -ForegroundColor Red
    exit 1
}
$lj = $pl.Stdout | ConvertFrom-Json
Write-Host "  PASS: harness live exit 0 (one persistent backend process, requests serialized)." -ForegroundColor Green

# --- Hard gate 2: the live block (ready seen, protocol v1, backend exit 0). ---
if( -not $lj.live.ready_seen -or $lj.live.protocol_version -ne 1 -or $lj.live.process_exit_code -ne 0 ) {
    Write-Host "  FAIL: live block -- ready_seen=$($lj.live.ready_seen) protocol_version=$($lj.live.protocol_version) process_exit_code=$($lj.live.process_exit_code) (expected true / 1 / 0)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: ready seen, protocol_version 1, backend exited 0 after quit (in $($lj.live.duration_s)s)." -ForegroundColor Green
}

# --- Hard gate 3: five ok responses in order (export + move_n + move_s + wait + quit), snapshots named. ---
# Wrap with @() FIRST -- a single element deserializes as a scalar; also filter $null elements (the
# documented house gotchas).
$resps = @($lj.live.responses | Where-Object { $null -ne $_ })
$ops = (@($resps | ForEach-Object { $_.op }) -join ',')
$allOk = (@($resps | Where-Object { $_.ok -ne $true }).Count -eq 0)
$snapsNamed = (@($resps | Where-Object { $_.op -ne 'quit' -and [string]::IsNullOrEmpty($_.snapshot) }).Count -eq 0)
if( $resps.Count -ne 5 -or $ops -ne 'export,command,command,command,quit' -or -not $allOk -or -not $snapsNamed ) {
    Write-Host "  FAIL: responses -- count=$($resps.Count) ops='$ops' all_ok=$allOk snapshots_named=$snapsNamed (expected 5 / export,command,command,command,quit / true / true)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: 5 ok responses in order; every export/command response names its snapshot ($((@($resps | Where-Object { $_.op -ne 'quit' } | ForEach-Object { $_.snapshot }) -join ', ')))." -ForegroundColor Green
}

# --- Hard gate 4: explain contract holds on the live session (schema 1, contract_check.ok). ---
if( $lj.schema_version -ne 1 -or -not $lj.contract_check.ok ) {
    Write-Host "  FAIL: contract -- schema_version=$($lj.schema_version) contract_check.ok=$($lj.contract_check.ok): $(($lj.contract_check | ConvertTo-Json -Compress))" -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: schema 1, contract_check.ok=true on the live session." -ForegroundColor Green
}

# --- Hard gate 5: 4 pairs, the exact Spike 9A outcome sequence -- from ONE live process. ---
$pairs = @($lj.pairs | Where-Object { $null -ne $_ })
$seq = (@($lj.summary.outcome_sequence) -join ',')
if( $pairs.Count -ne 4 -or $seq -ne 'blocked_no_op,moved,waited,no_command' ) {
    Write-Host "  FAIL: expected 4 pairs with outcomes 'blocked_no_op,moved,waited,no_command'; got $($pairs.Count) pair(s), '$seq'." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: 4 pairs, outcome sequence = $seq (the Spike 9A sequence, live)." -ForegroundColor Green
}

# --- Hard gate 6: the NPC-block pair (the win condition's headline proof). ---
if( $pairs.Count -ge 1 ) {
    $p0 = $pairs[0]
    $cmd0 = @($p0.commands | Where-Object { $null -ne $_ })
    $ok6 = $true
    if( $cmd0.Count -ne 1 -or $cmd0[0].command -ne 'move' -or $cmd0[0].direction -ne 'move_n' ) {
        Write-Host "  FAIL: pair 0 command is not the single move_n (got: $(($cmd0 | ConvertTo-Json -Compress)))." -ForegroundColor Red
        $ok6 = $false
    }
    if( $p0.outcome -ne 'blocked_no_op' -or @($p0.blocked_by) -notcontains 'npc' ) {
        Write-Host "  FAIL: pair 0 outcome=$($p0.outcome) blocked_by=$(@($p0.blocked_by) -join ',') (expected blocked_no_op / npc)." -ForegroundColor Red
        $ok6 = $false
    }
    if( $p0.turn_delta -ne 0 -or (@($p0.pos_abs_delta) -join ',') -ne '0,0,0' ) {
        Write-Host "  FAIL: pair 0 turn_delta=$($p0.turn_delta) pos_abs_delta=$(@($p0.pos_abs_delta) -join ',') (expected 0 / 0,0,0)." -ForegroundColor Red
        $ok6 = $false
    }
    $destNpcs = @($p0.destination.npcs | Where-Object { $null -ne $_ })
    if( $destNpcs.Count -lt 1 -or $destNpcs[0].name -ne 'Edwardo Stovall' ) {
        Write-Host "  FAIL: pair 0 destination NPC is '$(if ($destNpcs.Count -ge 1) { $destNpcs[0].name } else { '<none>' })' (expected the canonical blocker 'Edwardo Stovall')." -ForegroundColor Red
        $ok6 = $false
    }
    if( $ok6 ) {
        Write-Host ("  PASS: npc-block pair -- north blocker = {0}. Harness explains: ""{1}""" -f $destNpcs[0].name, $p0.explanation) -ForegroundColor Green
    } else {
        $fail++
    }
}

# --- Hard gate 7: the moved pair. ---
if( $pairs.Count -ge 2 ) {
    $p1 = $pairs[1]
    if( $p1.outcome -ne 'moved' -or (@($p1.pos_abs_delta) -join ',') -ne '0,1,0' -or $p1.turn_delta -lt 1 ) {
        Write-Host "  FAIL: pair 1 outcome=$($p1.outcome) pos_abs_delta=$(@($p1.pos_abs_delta) -join ',') turn_delta=$($p1.turn_delta) (expected moved / 0,1,0 / >=1)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: moved pair -- $($p1.explanation)" -ForegroundColor Green
    }
}

# --- Hard gate 8: the wait pair. ---
if( $pairs.Count -ge 3 ) {
    $p2 = $pairs[2]
    if( $p2.outcome -ne 'waited' -or (@($p2.pos_abs_delta) -join ',') -ne '0,0,0' -or $p2.turn_delta -lt 1 ) {
        Write-Host "  FAIL: pair 2 outcome=$($p2.outcome) pos_abs_delta=$(@($p2.pos_abs_delta) -join ',') turn_delta=$($p2.turn_delta) (expected waited / 0,0,0 / >=1)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: wait pair -- $($p2.explanation)" -ForegroundColor Green
    }
}

# --- Hard gate 9: the final (no-command) pair. ---
if( $pairs.Count -ge 4 ) {
    $p3 = $pairs[3]
    $cmd3 = @($p3.commands | Where-Object { $null -ne $_ })
    if( $p3.outcome -ne 'no_command' -or $cmd3.Count -ne 0 -or $p3.turn_delta -ne 0 ) {
        Write-Host "  FAIL: pair 3 outcome=$($p3.outcome) commands=$($cmd3.Count) turn_delta=$($p3.turn_delta) (expected no_command / 0 / 0)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: final pair -- $($p3.explanation)" -ForegroundColor Green
    }
}

# --- Hard gate 10: the session directory artifacts (session.jsonl + exactly 5 snapshots). ---
$snapFiles = @(Get-ChildItem $liveDir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | Sort-Object Name)
$hasLog = Test-Path (Join-Path $liveDir "session.jsonl")
if( -not $hasLog -or $snapFiles.Count -ne 5 ) {
    Write-Host "  FAIL: artifacts -- session.jsonl=$hasLog snapshots=$($snapFiles.Count) (expected true / 5)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: session.jsonl + 5 snapshots ($(($snapFiles | ForEach-Object Name) -join ', '))." -ForegroundColor Green
}

# --- Hard gate 11: the Spike 4 viewer agrees (two independent consumers, one live session). ---
$report = Join-Path $liveDir "report.html"
$pview = Invoke-PyTool -ToolArgs @($Viewer, '--session-dir', $liveDir, '--output', $report) `
    -StdoutPath (Join-Path $OutRoot "viewer_stdout.txt") -StderrPath (Join-Path $OutRoot "viewer_stderr.txt")
if( $pview.ExitCode -ne 0 ) {
    Write-Host "  FAIL: viewer exited $($pview.ExitCode) (0=clean; 2=discrepancies; 1=fatal) on the live session." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 on the live session (consumer cross-check)." -ForegroundColor Green
}

# --- Hard gate 12: standalone explain agrees with the in-process explain. ---
$pe = Invoke-PyTool -ToolArgs @($Harness, 'explain', '--session-dir', $liveDir, '--json') `
    -StdoutPath (Join-Path $OutRoot "explain_stdout.json") -StderrPath (Join-Path $OutRoot "explain_stderr.txt")
if( $pe.ExitCode -ne 0 ) {
    Write-Host "  FAIL: standalone explain exited $($pe.ExitCode) (expected 0) on the live session." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: standalone explain exit 0 on the live session." -ForegroundColor Green
}

# =============================================================================
# Scenario B: recoverability -- a rejected request must not end the session.
# =============================================================================
$negDir = Join-Path $OutRoot "negative"
if( Test-Path $negDir ) { Remove-Item $negDir -Recurse -Force }
$negJson = Join-Path $OutRoot "negative_result.json"
$negErr  = Join-Path $OutRoot "negative_stderr.txt"
$pn = Invoke-PyTool -ToolArgs @($Harness, 'live', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $negDir, '--commands', 'wait', '--negative-probe', '--json') `
    -StdoutPath $negJson -StderrPath $negErr

# --- Hard gate 13: the negative scenario end-to-end. ---
$negOk = $false
if( $pn.ExitCode -eq 0 ) {
    $nj = $pn.Stdout | ConvertFrom-Json
    $probe = $nj.live.negative_probe
    $nseq = (@($nj.summary.outcome_sequence) -join ',')
    $negOk = ($null -ne $probe) -and $probe.sent -and ($probe.error_code -eq 'unsupported_command') -and
             $probe.recovered -and ($nj.live.process_exit_code -eq 0) -and $nj.contract_check.ok -and
             ($nseq -eq 'waited,waited,no_command')
    if( -not $negOk ) {
        Write-Host "  FAIL: negative scenario -- probe=$(($probe | ConvertTo-Json -Compress)) process_exit_code=$($nj.live.process_exit_code) contract_ok=$($nj.contract_check.ok) outcomes='$nseq' (expected unsupported_command / recovered / 0 / true / waited,waited,no_command)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness live (negative probe) exited $($pn.ExitCode) (expected 0). stderr: $(Get-Content $negErr -Raw -ErrorAction SilentlyContinue)" -ForegroundColor Red
}
if( $negOk ) {
    Write-Host "  PASS: negative probe -- move_up rejected as unsupported_command, session survived, recovery wait snapshotted, clean quit." -ForegroundColor Green
} else {
    $fail++
}

if( $fail -gt 0 ) { Write-Host "LIVE PROTOCOL REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "LIVE PROTOCOL REGRESSION: ok." -ForegroundColor Green
exit 0
