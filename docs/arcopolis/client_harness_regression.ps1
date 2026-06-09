<#
.SYNOPSIS
  Arcopolis client-harness regression scenario (Spike 9A, the external player-loop proof).

.DESCRIPTION
  Drives the headless backend over the ArcopolisTest fixture through ONE script session
  (export start -> move_n -> export -> move_s -> export -> wait -> export, plus the engine's
  final-on-exit snapshot) and asserts that the EXTERNAL consumer harness
  (tools/arcopolis_client/harness.py) can build a local view, run commands through the backend,
  and explain every outcome from the Spikes 0-8A contract alone:

    * move_n FIRST, while the stock shelter NPC Edwardo Stovall is still one tile north of the
      avatar (local [85,84,0]) -> the harness must classify "blocked_no_op" with blocked_by=npc
      and name the NPC from the BEFORE snapshot (after move_s the start tile is empty, so a
      later move_n would SUCCEED - the order is load-bearing).
    * move_s -> "moved" with pos_abs delta (0,1,0) and the turn advancing.
    * wait -> "waited" with the position unchanged and the turn advancing.
    * the final-on-exit pair -> "no_command" with nothing changed (clean-park).

  Why this is a fixture-driven script and not a CI catch2 test (same reasoning as the sibling
  scripts): it needs a fully loaded world; the harness's own load/classify logic is exercised
  offline against recorded sessions during development, and this script is the live end-to-end
  gate. Outcome labels (blocked_no_op etc.) are DATA the harness reports - the gates assert the
  harness derives the RIGHT labels, while the backend behavior itself stays gated by
  movement_regression.ps1 / npc_export_regression.ps1.

  What it asserts (hard gates):
    1. The backend run exits 0 and produces exactly 5 NNN_<name>.json snapshots.
    2. `harness.py explain --json` exits 0, parses, schema_version=1, contract_check.ok=true.
    3. 4 pairs with outcome_sequence exactly: blocked_no_op,moved,waited,no_command.
    4. NPC-BLOCK PAIR: pair 0 is the move_n command, outcome blocked_no_op, blocked_by contains
       "npc", turn_delta 0, pos_abs_delta 0,0,0, and the destination (one tile north of the
       avatar's before-pos_local) carries an NPC - Edwardo Stovall in the canonical fixture.
       The PASS line prints the harness's own explanation string (the spike's headline proof).
    5. MOVED PAIR: pair 1 is move_s, outcome moved, pos_abs_delta 0,1,0, turn_delta >= 1.
    6. WAIT PAIR: pair 2 is wait, outcome waited, pos_abs_delta 0,0,0, turn_delta >= 1.
    7. FINAL PAIR: pair 3 has no command, outcome no_command, turn_delta 0.
    8. `harness.py view --at <north tile>` exits 0 and the HTML carries the inspector markers
       (the NPC's name, t_floor, and the move_n "one command away" hint). Presence-only checks -
       cosmetic layout changes must not break the regression.
    9. RUN MODE: `harness.py run` (the harness launches the backend itself) exits 0 with the
       same outcome_sequence and run.exit_code=0 - the full choose -> run -> explain loop.
   10. The Spike 4 viewer agrees: make_report.py exits 0 on the same session dir (two
       independent consumers accept the same contract artifacts).

.NOTES
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions
  (AGENTS.md fixture section); kept verbatim so the commands stay copy-pasteable. No
  usernames/secrets.
#>
[CmdletBinding()]
param(
    [string]$Exe        = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc = "C:\dev\arcopolis-fixtures\arcopolis_user",
    [string]$UserDir    = ".\arcopolis_user",
    [string]$World      = "ArcopolisTest",
    [string]$OutRoot    = ".\out\arco_client_regress",
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
$dir = Join-Path $OutRoot "loop"
if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null

# move_n FIRST (Edwardo still adjacent-north), then move_s (walkable), then wait (tick). Exports
# between every step; the engine appends NNN_final.json on clean exit.
$scriptPath = Join-Path $dir "script.json"
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "start" },
  { "op": "command", "command": "move", "direction": "move_n" },
  { "op": "export",  "name": "after_move_n" },
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export",  "name": "after_move_s" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii $scriptPath

# cataclysm-bn-tiles is a GUI / WINDOWS-subsystem exe, so a bare `& $exe` does NOT wait for it and
# leaves $LASTEXITCODE empty. Start-Process -Wait -PassThru waits and captures the real exit code.
$p = Start-Process -FilePath $Exe -ArgumentList @(
    '--world', $World,
    '--arcopolis-run-script', $scriptPath,
    '--arcopolis-export-dir', $dir,
    '--userdir', $UserDir
) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")

# --- Hard gate 1: backend exit 0 and exactly 5 snapshots (start, 3 afters, final). ---
if( $p.ExitCode -ne 0 ) {
    Write-Host "  FAIL: backend run exited $($p.ExitCode) (expected 0): $(Get-Content (Join-Path $dir 'stderr.txt') -Raw)" -ForegroundColor Red
    Write-Host "CLIENT HARNESS REGRESSION: 1 hard assertion failed." -ForegroundColor Red
    exit 1
}
$snapFiles = @(Get-ChildItem $dir -Filter "*.json" | Where-Object { $_.Name -match '^\d+_' } | Sort-Object Name)
if( $snapFiles.Count -ne 5 ) {
    Write-Host "  FAIL: expected 5 NNN_<name>.json snapshots, found $($snapFiles.Count)." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: backend exit 0, 5 snapshots produced ($(($snapFiles | ForEach-Object Name) -join ', '))." -ForegroundColor Green
}

# --- Hard gate 2: explain --json exits 0, parses, schema 1, contract_check.ok. ---
$explainJson = Join-Path $dir "explain.json"
$explainErr  = Join-Path $dir "explain_stderr.txt"
$pe = Invoke-PyTool -ToolArgs @($Harness, 'explain', '--session-dir', $dir, '--json') `
    -StdoutPath $explainJson -StderrPath $explainErr
if( $pe.ExitCode -ne 0 ) {
    Write-Host "  FAIL: harness explain exited $($pe.ExitCode) (0=clean; 2=contract discrepancies; 1=fatal). See $explainErr." -ForegroundColor Red
    Write-Host "CLIENT HARNESS REGRESSION: $($fail + 1) hard assertion(s) failed." -ForegroundColor Red
    exit 1
}
$ex = $pe.Stdout | ConvertFrom-Json
if( $ex.schema_version -ne 1 ) {
    Write-Host "  FAIL: explain JSON schema_version=$($ex.schema_version) (expected 1)." -ForegroundColor Red
    $fail++
}
if( -not $ex.contract_check.ok ) {
    Write-Host "  FAIL: contract_check.ok=false: $(($ex.contract_check | ConvertTo-Json -Compress))" -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: explain --json exit 0, schema 1, contract_check.ok=true." -ForegroundColor Green
}

# --- Hard gate 3: 4 pairs, exact outcome sequence. ---
# Wrap with @() FIRST -- a single element deserializes as a scalar; also filter $null elements (a
# missing/null property coerces to @($null), .Count 1), the documented house gotcha.
$pairs = @($ex.pairs | Where-Object { $null -ne $_ })
$seq = (@($ex.summary.outcome_sequence) -join ',')
if( $pairs.Count -ne 4 -or $seq -ne 'blocked_no_op,moved,waited,no_command' ) {
    Write-Host "  FAIL: expected 4 pairs with outcomes 'blocked_no_op,moved,waited,no_command'; got $($pairs.Count) pair(s), '$seq'." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: 4 pairs, outcome sequence = $seq." -ForegroundColor Green
}

# --- Hard gate 4: the NPC-block pair (the spike's headline proof). ---
if( $pairs.Count -ge 1 ) {
    $p0 = $pairs[0]
    $cmd0 = @($p0.commands | Where-Object { $null -ne $_ })
    $ok4 = $true
    if( $cmd0.Count -ne 1 -or $cmd0[0].command -ne 'move' -or $cmd0[0].direction -ne 'move_n' ) {
        Write-Host "  FAIL: pair 0 command is not the single move_n (got: $(($cmd0 | ConvertTo-Json -Compress)))." -ForegroundColor Red
        $ok4 = $false
    }
    if( $p0.outcome -ne 'blocked_no_op' -or @($p0.blocked_by) -notcontains 'npc' ) {
        Write-Host "  FAIL: pair 0 outcome=$($p0.outcome) blocked_by=$(@($p0.blocked_by) -join ',') (expected blocked_no_op / npc)." -ForegroundColor Red
        $ok4 = $false
    }
    if( $p0.turn_delta -ne 0 -or (@($p0.pos_abs_delta) -join ',') -ne '0,0,0' ) {
        Write-Host "  FAIL: pair 0 turn_delta=$($p0.turn_delta) pos_abs_delta=$(@($p0.pos_abs_delta) -join ',') (expected 0 / 0,0,0)." -ForegroundColor Red
        $ok4 = $false
    }
    # The destination must be one tile north of the avatar's before-pos_local and carry an NPC
    # (Edwardo Stovall in the canonical fixture). Computed, not hardcoded, like npc gate 4.
    $apl = @($p0.before.pos_local)
    $destNpcs = @($p0.destination.npcs | Where-Object { $null -ne $_ })
    if( $apl.Count -lt 3 -or $null -eq $p0.destination ) {
        Write-Host "  FAIL: pair 0 lacks before.pos_local or a destination analysis." -ForegroundColor Red
        $ok4 = $false
    } else {
        $expectedDest = "$($apl[0]),$($apl[1] - 1),$($apl[2])"
        if( (@($p0.destination.pos_local) -join ',') -ne $expectedDest ) {
            Write-Host "  FAIL: pair 0 destination $(@($p0.destination.pos_local) -join ',') is not one tile north ($expectedDest)." -ForegroundColor Red
            $ok4 = $false
        }
        if( $destNpcs.Count -lt 1 ) {
            Write-Host "  FAIL: pair 0 destination has no NPC (the move_n blocker is not in the bundle)." -ForegroundColor Red
            $ok4 = $false
        }
    }
    if( $ok4 ) {
        Write-Host ("  PASS: npc-block pair -- north blocker = {0}. Harness explains: ""{1}""" -f $destNpcs[0].name, $p0.explanation) -ForegroundColor Green
    } else {
        $fail++
    }
}

# --- Hard gate 5: the moved pair. ---
if( $pairs.Count -ge 2 ) {
    $p1 = $pairs[1]
    if( $p1.outcome -ne 'moved' -or (@($p1.pos_abs_delta) -join ',') -ne '0,1,0' -or $p1.turn_delta -lt 1 ) {
        Write-Host "  FAIL: pair 1 outcome=$($p1.outcome) pos_abs_delta=$(@($p1.pos_abs_delta) -join ',') turn_delta=$($p1.turn_delta) (expected moved / 0,1,0 / >=1)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: moved pair -- $($p1.explanation)" -ForegroundColor Green
    }
}

# --- Hard gate 6: the wait pair. ---
if( $pairs.Count -ge 3 ) {
    $p2 = $pairs[2]
    if( $p2.outcome -ne 'waited' -or (@($p2.pos_abs_delta) -join ',') -ne '0,0,0' -or $p2.turn_delta -lt 1 ) {
        Write-Host "  FAIL: pair 2 outcome=$($p2.outcome) pos_abs_delta=$(@($p2.pos_abs_delta) -join ',') turn_delta=$($p2.turn_delta) (expected waited / 0,0,0 / >=1)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: wait pair -- $($p2.explanation)" -ForegroundColor Green
    }
}

# --- Hard gate 7: the final (no-command) pair. ---
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

# --- Hard gate 8: the HTML view + tile inspector (presence-only markers, not layout). ---
# Inspect the tile one north of the avatar (the NPC blocker) -- computed from the explain JSON.
$viewHtml = Join-Path $dir "view.html"
$northAt = ""
if( $pairs.Count -ge 1 -and @($pairs[0].before.pos_local).Count -ge 2 ) {
    $apl = @($pairs[0].before.pos_local)
    $northAt = "$($apl[0]),$($apl[1] - 1)"
}
if( $northAt -eq "" ) {
    Write-Host "  FAIL: cannot compute the north tile for the view gate (no pair 0 pos_local)." -ForegroundColor Red
    $fail++
} else {
    $pv = Invoke-PyTool -ToolArgs @($Harness, 'view', '--session-dir', $dir, '--output', $viewHtml, '--snapshot', 'start', '--at', $northAt) `
        -StdoutPath (Join-Path $dir "view_stdout.txt") -StderrPath (Join-Path $dir "view_stderr.txt")
    $htmlOk = $false
    if( ($pv.ExitCode -eq 0) -and (Test-Path $viewHtml) ) {
        $htmlRaw = Get-Content $viewHtml -Raw
        $blockerName = if( $pairs.Count -ge 1 -and @($pairs[0].destination.npcs).Count -ge 1 ) { @($pairs[0].destination.npcs)[0].name } else { "Edwardo Stovall" }
        $htmlOk = $htmlRaw.Contains($blockerName) -and $htmlRaw.Contains('t_floor') -and $htmlRaw.Contains('move_n') -and $htmlRaw.Contains('Tile inspector')
    }
    if( -not $htmlOk ) {
        Write-Host "  FAIL: view gate -- exit=$($pv.ExitCode), or view.html lacks the inspector markers (NPC name / t_floor / move_n)." -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  PASS: view --at $northAt exit 0; HTML carries the map + inspector markers. ($($pv.Stdout.Trim()))" -ForegroundColor Green
    }
}

# --- Hard gate 9: run mode (the harness drives the backend itself: choose -> run -> explain). ---
$runDir = Join-Path $OutRoot "run_mode"
if( Test-Path $runDir ) { Remove-Item $runDir -Recurse -Force }
$runJson = Join-Path $OutRoot "run_mode_result.json"
$pr = Invoke-PyTool -ToolArgs @($Harness, 'run', '--exe', $Exe, '--world', $World, '--userdir', $UserDir,
    '--out', $runDir, '--commands', 'move_n,move_s,wait', '--json') `
    -StdoutPath $runJson -StderrPath (Join-Path $OutRoot "run_mode_stderr.txt")
$runOk = $false
if( $pr.ExitCode -eq 0 ) {
    $rj = $pr.Stdout | ConvertFrom-Json
    $rseq = (@($rj.summary.outcome_sequence) -join ',')
    $runOk = ($rj.run.exit_code -eq 0) -and ($rseq -eq 'blocked_no_op,moved,waited,no_command') -and $rj.contract_check.ok
    if( -not $runOk ) {
        Write-Host "  FAIL: run-mode JSON -- run.exit_code=$($rj.run.exit_code) outcomes='$rseq' contract_ok=$($rj.contract_check.ok)." -ForegroundColor Red
    }
} else {
    Write-Host "  FAIL: harness run exited $($pr.ExitCode) (expected 0). See $(Join-Path $OutRoot 'run_mode_stderr.txt')." -ForegroundColor Red
}
if( $runOk ) {
    Write-Host "  PASS: run mode -- harness launched the backend, re-derived the same outcome sequence (run.exit_code=0)." -ForegroundColor Green
} else {
    $fail++
}

# --- Hard gate 10: the Spike 4 viewer agrees (two independent consumers, one contract). ---
$report = Join-Path $dir "report.html"
$pview = Invoke-PyTool -ToolArgs @($Viewer, '--session-dir', $dir, '--output', $report) `
    -StdoutPath (Join-Path $dir "viewer_stdout.txt") -StderrPath (Join-Path $dir "viewer_stderr.txt")
Write-Host ("[viewer] exit=$($pview.ExitCode)  " + $pview.Stdout.Trim())
if( $pview.ExitCode -ne 0 ) {
    Write-Host "  FAIL: viewer exited $($pview.ExitCode) (0=clean; 2=discrepancies; 1=fatal) on the harness's session." -ForegroundColor Red
    $fail++
} else {
    Write-Host "  PASS: viewer exit 0 on the same session (consumer cross-check)." -ForegroundColor Green
}

if( $fail -gt 0 ) { Write-Host "CLIENT HARNESS REGRESSION: $fail hard assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "CLIENT HARNESS REGRESSION: ok." -ForegroundColor Green
exit 0
