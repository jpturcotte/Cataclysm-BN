<#
.SYNOPSIS
  Spike 10A regression: the browser-frontend prototype bridge drives one persistent
  --arcopolis-live backend end-to-end through its HTTP API (no browser automation).

.DESCRIPTION
  Starts tools/arcopolis_frontend/prototype_server.py against the canonical ArcopolisTest
  fixture and exercises the whole server/live-backend path over plain HTTP:

    Gate  1: server up; GET / serves the UI; GET /api/state reports phase "idle".
    Gate  2: static whitelist (app.js/style.css 200, unknown 404) + Cache-Control: no-store.
    Gate 2b: Spike 10B snapshot-diff UI hooks are present in the SERVED assets (app.js carries
             computeSnapshotDiff + the changed-tile class, style.css styles .changed-tile and
             .g-door-open, the page carries the diff-summary panel). Static-content asserts only;
             diff BEHAVIOR is browser-side JS and deliberately not automated here.
    Gate 2c: Spike 10C tileset asset serving + UI hooks: /tileset/info reports the enabled
             tileset, /tileset/tile_config.json serves with tile_info + tiles-new, sheet PNGs
             DERIVED FROM THE SERVED CONFIG serve as non-empty image/png, unwhitelisted and
             traversal-shaped names 404, and the served assets carry the tileset hooks
             (loadTileset / setRenderMode / renderSpriteCell / mode-tileset / tileset-status /
             tileset-mode). Server/static/API-level only - sprite RENDERING is browser-side JS
             covered by the manual smoke (doc 24), never asserted here.
    Gate  3: POST /api/start -> phase "ready", session_001, a NNN_start.json snapshot on disk,
             avatar present, 625 tiles (FIXTURE-SPECIFIC: ArcopolisTest's avatar sits
             mid-bubble so its radius-12 window is the full 25x25; the general contract is
             "radius-12, clamped to the loaded bubble", NOT "always 625 tiles").
    Gate  4: GET /api/state is a side-effect-free cache (state_serial/turn stable across reads).
    Gate  5: a second POST /api/start -> 409 session_already_running.
    Gate  6: move_n  -> outcome blocked_no_op, blocked_by npc "Edwardo Stovall",
             turn_delta 0, pos_abs_delta 0,0,0 (the canonical Spike 7A/9A blocker).
    Gate  7: move_s  -> outcome moved, pos_abs_delta 0,1,0, turn_delta >= 1.
    Gate  8: POST /api/wait -> outcome waited, pos_abs_delta 0,0,0, turn_delta >= 1.
    Gate  9: POST /api/export -> outcome no_command, turn_delta 0, snapshot file readable.
    Gate 10: vocabulary is the BACKEND's to judge: move_up passes through and surfaces the
             authoritative unsupported_command as HTTP 200 + outcome "error"; the session
             survives (phase still "ready") and a recovery wait succeeds.
    Gate 11: bridge-side validation tiers: malformed JSON body -> 400 bad_request;
             GET /api/command -> 405.
    Gate 12: POST /api/quit -> phase "ended", backend exit_code 0, a NNN_final.json snapshot
             on disk, session.jsonl present.
    Gate 13: restartability: a second session starts as session_002 and quits cleanly.
    Gate 14: POST /api/shutdown -> HTTP 200, the server process exits, the port is released.
    Gate 15: tileset fail-safe: a SECOND short-lived server started with --disable-tileset still
             serves the UI, /tileset/info answers enabled:false, /tileset/tile_config.json 404s,
             and the server shuts down cleanly (glyph mode never needs the tileset).

  Together gates 3..12 reproduce the fixture-proven live sequence
  (blocked_no_op, moved, waited, no_command) through the HTTP bridge.

  A deliberate omission: there is no "busy 409" race gate. Commands complete in milliseconds
  and the prototype has no test hook to wedge one, so a parallel-request race would be flaky;
  the 409 path is exercised deterministically by the double-start gate instead.

  Like the sibling regressions this needs a prepared local fixture world and a built game
  binary, so it cannot run in CI.

.PARAMETER Exe
  Path to the built cataclysm-bn-tiles executable.
.PARAMETER FixtureSrc
  The external canonical fixture userdir to copy from.
.PARAMETER UserDir
  The gitignored sandbox userdir refreshed from FixtureSrc on every run.
.PARAMETER World
  The fixture world name (ArcopolisTest carries the NPC blocker this script asserts).
.PARAMETER OutRoot
  Output sandbox (server logs + one sessions/ dir); recreated on every run.
.PARAMETER Server
  Path to the prototype bridge script.
.PARAMETER Port
  Loopback HTTP port (deliberately NOT the server's 8765 default, so the regression never
  collides with a manually running prototype).
.PARAMETER TilesetDir
  The in-repo BN tileset dir Gate 2c serves (tile_config.json + referenced spritesheets).
  Tileset failures are fail-safe server-side, so a broken tileset cannot take gates 1..14
  down - only Gate 2c would fail.

.EXAMPLE
  pwsh -File docs/arcopolis/frontend_prototype_regression.ps1

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
    [string]$OutRoot    = ".\out\arco_frontend_regress",
    [string]$Server     = "tools\arcopolis_frontend\prototype_server.py",
    [int]$Port          = 8799,
    [string]$TilesetDir = ".\gfx\UltimateCataclysm"
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

# --- Prereqs (each exits with a distinct code: 3=exe, 4=fixture, 5=world, 6=python,
# --- 7=server script, 8=static files, 9=port already in use, 10=tileset dir). NOTE:
# --- prereq exit 10 here is unrelated to the backend's exit 10 (backend_stalled). ---
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
    Stop-WithCode "python not found on PATH (needed to run the prototype bridge). See 00_WINDOWS_LOCAL_ENVIRONMENT.md." 6
}
if( -not (Test-Path $Server) ) {
    Stop-WithCode "Prototype server not found: $Server" 7
}
$staticDir = Join-Path (Split-Path $Server -Parent) "static"
foreach( $name in @("index.html", "app.js", "style.css") ) {
    if( -not (Test-Path (Join-Path $staticDir $name)) ) {
        Stop-WithCode "Static UI file missing: $(Join-Path $staticDir $name)" 8
    }
}
if( Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue ) {
    Stop-WithCode "Port $Port is already listening -- is a prototype server (or another service) running? Rerun with -Port <free port>." 9
}
if( -not (Test-Path (Join-Path $TilesetDir "tile_config.json")) ) {
    Stop-WithCode "Tileset config not found: $(Join-Path $TilesetDir 'tile_config.json') -- Gate 2c serves the in-repo UltimateCataclysm tileset (or pass -TilesetDir)." 10
}

# Refresh the gitignored sandbox world from the external fixture. `Copy-Item -Recurse` nests the
# source INSIDE the destination when the destination already exists, so delete any existing
# sandbox first (same rationale as the sibling regression scripts).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
# Fresh OutRoot so the bridge's session_NNN numbering starts at 001 (gate 3/13 assert dir names).
if( Test-Path $OutRoot ) { Remove-Item $OutRoot -Recurse -Force }
New-Item -ItemType Directory -Force $OutRoot | Out-Null
$sessionsRoot = Join-Path $OutRoot "sessions"

$baseUrl = "http://127.0.0.1:$Port"

# One HTTP helper for every gate: -SkipHttpErrorCheck so expected 4xx are data, -NoProxy so a
# system proxy can never intercept loopback. Returns status + parsed JSON (or $null).
function Invoke-Api {
    param([string]$Method, [string]$Path, [string]$Body = $null, [int]$TimeoutSec = 120)
    $request = @{
        Uri                = "$baseUrl$Path"
        Method             = $Method
        NoProxy            = $true
        SkipHttpErrorCheck = $true
        TimeoutSec         = $TimeoutSec
    }
    if( $null -ne $Body ) {
        $request.ContentType = "application/json"
        $request.Body = $Body
    }
    $response = Invoke-WebRequest @request
    $json = $null
    try { $json = $response.Content | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; Raw = $response }
}

$script:fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail = "")
    if( $Condition ) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $Label $Detail" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "Starting the prototype server on port $Port ..." -ForegroundColor Cyan
$serverOut = Join-Path $OutRoot "server_stdout.txt"
$serverErr = Join-Path $OutRoot "server_stderr.txt"   # MUST be two distinct redirect files
# --tileset-dir is safe on the one shared server: tileset failures are fail-safe
# server-side (serving disabled, UI glyph-only), so a broken tileset cannot take
# gates 1..14 down - only Gate 2c would fail.
$serverProc = Start-Process python -ArgumentList @(
        $Server, "--exe", $Exe, "--userdir", $UserDir, "--world", $World,
        "--out-root", $sessionsRoot, "--port", $Port,
        "--tileset-dir", $TilesetDir
    ) -NoNewWindow -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
$serverProc2 = $null   # Gate 15's second server; predeclared so `finally` can reap it

try {
    try {
        # --- Readiness: poll /api/state until the listener answers. -------------------------
        $state = $null
        foreach( $i in 1..40 ) {
            if( $serverProc.HasExited ) { break }
            try {
                $state = Invoke-Api GET "/api/state" -TimeoutSec 3
                break
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
        if( $serverProc.HasExited ) {
            Write-Host "  FAIL: server process exited during startup. stderr:" -ForegroundColor Red
            Get-Content $serverErr -Raw -ErrorAction SilentlyContinue | Write-Host
            $script:fail++
            throw "server died during startup"
        }
        if( $null -eq $state ) {
            $script:fail++
            throw "server did not answer /api/state within the readiness window"
        }

        # --- Gate 1: server up + idle state + UI page. ---------------------------------------
        Write-Host "Gate 1: server up, UI served, idle state" -ForegroundColor Cyan
        $page = Invoke-Api GET "/"
        Assert-True ($page.Status -eq 200 -and $page.Raw.Content -like "*Arcopolis frontend prototype*") `
            "GET / serves the prototype page" "(status $($page.Status))"
        Assert-True ($state.Status -eq 200 -and $state.Json.ok -eq $true -and $state.Json.phase -eq "idle") `
            "GET /api/state reports ok + phase idle" "(status $($state.Status), phase $($state.Json.phase))"
        Assert-True ($state.Json.state_serial -is [long] -or $state.Json.state_serial -is [int]) `
            "state_serial is an integer"

        # --- Gate 2: static whitelist + no-store. --------------------------------------------
        Write-Host "Gate 2: static whitelist + Cache-Control" -ForegroundColor Cyan
        $js  = Invoke-Api GET "/static/app.js"
        $css = Invoke-Api GET "/static/style.css"
        $bad = Invoke-Api GET "/static/nope.js"
        Assert-True ($js.Status -eq 200 -and "$($js.Raw.Headers['Content-Type'])" -like "text/javascript*") `
            "GET /static/app.js is 200 text/javascript" "(status $($js.Status))"
        Assert-True ($css.Status -eq 200) "GET /static/style.css is 200" "(status $($css.Status))"
        Assert-True ($bad.Status -eq 404) "GET /static/nope.js is 404 (whitelist)" "(status $($bad.Status))"
        Assert-True ("$($state.Raw.Headers['Cache-Control'])" -eq "no-store") `
            "/api/state carries Cache-Control: no-store"

        # --- Gate 2b: Spike 10B diff-UI hooks in the served assets (static asserts only). ----
        Write-Host "Gate 2b: snapshot-diff UI hooks served" -ForegroundColor Cyan
        Assert-True ($js.Raw.Content -like "*computeSnapshotDiff*") `
            "served app.js carries computeSnapshotDiff"
        Assert-True ($js.Raw.Content -like "*changed-tile*") `
            "served app.js applies the changed-tile class"
        Assert-True ($css.Raw.Content -like "*.changed-tile*") `
            "served style.css styles .changed-tile"
        Assert-True ($css.Raw.Content -like "*.g-door-open*") `
            "served style.css styles .g-door-open"
        Assert-True ($page.Raw.Content -like "*diff-summary*") `
            "served page carries the diff-summary panel"

        # --- Gate 2c: Spike 10C tileset asset serving + UI hooks (server/static/API level ----
        # --- only; sprite RENDERING is browser-side JS, covered by the manual smoke). --------
        Write-Host "Gate 2c: tileset asset serving + UI hooks" -ForegroundColor Cyan
        $tinfo = Invoke-Api GET "/tileset/info"
        Assert-True ($tinfo.Status -eq 200 -and $tinfo.Json.enabled -eq $true) `
            "/tileset/info reports an enabled tileset" "(status $($tinfo.Status), enabled $($tinfo.Json.enabled))"
        Assert-True ($tinfo.Json.name -eq "UltimateCataclysm") `
            "tileset name is UltimateCataclysm" "(got $($tinfo.Json.name))"
        $tcfg = Invoke-Api GET "/tileset/tile_config.json"
        Assert-True ($tcfg.Status -eq 200 -and "$($tcfg.Raw.Headers['Content-Type'])" -like "application/json*") `
            "tile_config.json serves as application/json" "(status $($tcfg.Status))"
        Assert-True ("$($tcfg.Raw.Headers['Cache-Control'])" -eq "no-store") `
            "tile_config.json carries Cache-Control: no-store"
        Assert-True ($null -ne $tcfg.Json.tile_info -and $null -ne $tcfg.Json.'tiles-new') `
            "served config carries tile_info and tiles-new"
        # PNG asserts are DERIVED FROM THE SERVED CONFIG (future-proof): probe the known
        # UltimateCataclysm sheets when referenced, else the config's first sheet. Tolerant
        # body check: status + content type + non-empty bytes; Content-Length is deliberately
        # NOT asserted (it may be absent depending on how the server writes files).
        $sheetFiles = @($tcfg.Json.'tiles-new' | ForEach-Object { $_.file })
        Assert-True ($sheetFiles.Count -gt 0) "served config references at least one sheet"
        $probeNames = @("small.png", "normal.png") | Where-Object { $sheetFiles -contains $_ }
        if( @($probeNames).Count -eq 0 -and $sheetFiles.Count -gt 0 ) { $probeNames = @($sheetFiles[0]) }
        foreach( $sheetName in $probeNames ) {
            $img = Invoke-Api GET "/tileset/$sheetName"
            Assert-True ($img.Status -eq 200 -and "$($img.Raw.Headers['Content-Type'])" -like "image/png*") `
                "GET /tileset/$sheetName is 200 image/png" "(status $($img.Status), type $($img.Raw.Headers['Content-Type']))"
            Assert-True ($img.Raw.Content.Length -gt 0) "/tileset/$sheetName body is non-empty"
        }
        $tbad = Invoke-Api GET "/tileset/nope.png"
        Assert-True ($tbad.Status -eq 404) "GET /tileset/nope.png is 404 (whitelist)" "(status $($tbad.Status))"
        # The %2F-encoded probe reaches the server literally (Invoke-WebRequest collapses a
        # literal ../ client-side). The server percent-decodes ONCE, then rejects separators
        # before the exact-name lookup, so either client behavior must end in 404 - the real
        # guarantee is the flat-basename whitelist with no path arithmetic on client input.
        $trav = Invoke-Api GET "/tileset/..%2Ftile_config.json"
        Assert-True ($trav.Status -eq 404) "traversal-shaped name is 404 (containment)" "(status $($trav.Status))"
        Assert-True ($js.Raw.Content -like "*loadTileset*") "served app.js carries loadTileset"
        Assert-True ($js.Raw.Content -like "*setRenderMode*") "served app.js carries setRenderMode"
        Assert-True ($js.Raw.Content -like "*renderSpriteCell*") "served app.js carries renderSpriteCell"
        Assert-True ($page.Raw.Content -like "*mode-tileset*" -and $page.Raw.Content -like "*tileset-status*") `
            "served page carries the render-mode UI"
        Assert-True ($css.Raw.Content -like "*tileset-mode*") "served style.css styles tileset-mode"

        # --- Gate 3: start -> ready + initial snapshot. --------------------------------------
        Write-Host "Gate 3: POST /api/start" -ForegroundColor Cyan
        $start = Invoke-Api POST "/api/start" "{}"
        Assert-True ($start.Status -eq 200 -and $start.Json.phase -eq "ready") `
            "start answers 200 + phase ready" "(status $($start.Status), phase $($start.Json.phase))"
        Assert-True ($start.Json.session.index -eq 1 -and $start.Json.session.dir_name -eq "session_001") `
            "first session is session_001"
        Assert-True ($start.Json.backend.snapshot -match '^\d+_start\.json$') `
            "initial snapshot is NNN_start.json" "(got $($start.Json.backend.snapshot))"
        $startSnapshot = Join-Path (Join-Path $sessionsRoot "session_001") $start.Json.backend.snapshot
        Assert-True (Test-Path $startSnapshot) "initial snapshot file exists on disk"
        Assert-True ($null -ne $start.Json.avatar) "state carries the avatar block"
        # FIXTURE-SPECIFIC: ArcopolisTest's avatar sits mid-bubble, so the radius-12 window is
        # the full 25x25 = 625 tiles. The general contract is "radius-12, clamped to the loaded
        # bubble" -- do not reuse this exact count for other fixtures.
        Assert-True (@($start.Json.map.tiles).Count -eq 625) `
            "snapshot window is 625 tiles (ArcopolisTest-specific)" "(got $(@($start.Json.map.tiles).Count))"

        # --- Gate 4: /api/state is a side-effect-free cache. ---------------------------------
        Write-Host "Gate 4: GET /api/state is side-effect-free" -ForegroundColor Cyan
        $s1 = Invoke-Api GET "/api/state"
        $s2 = Invoke-Api GET "/api/state"
        Assert-True ($s1.Json.state_serial -eq $s2.Json.state_serial) `
            "state_serial unchanged across reads" "($($s1.Json.state_serial) vs $($s2.Json.state_serial))"
        Assert-True ($s1.Json.backend.turn -eq $s2.Json.backend.turn) "turn unchanged across reads"

        # --- Gate 5: double start -> 409. ------------------------------------------------------
        Write-Host "Gate 5: double start is rejected" -ForegroundColor Cyan
        $again = Invoke-Api POST "/api/start" "{}"
        Assert-True ($again.Status -eq 409 -and $again.Json.error.code -eq "session_already_running") `
            "second start answers 409 session_already_running" "(status $($again.Status), code $($again.Json.error.code))"

        # --- Gate 6: move_n -> blocked_no_op (the canonical NPC blocker). --------------------
        Write-Host "Gate 6: move_n -> blocked_no_op (Edwardo)" -ForegroundColor Cyan
        $mn = Invoke-Api POST "/api/command" '{"command":"move","direction":"move_n"}'
        $o = $mn.Json.last_result.outcome
        Assert-True ($mn.Status -eq 200 -and $o.outcome -eq "blocked_no_op") `
            "outcome is blocked_no_op" "(status $($mn.Status), outcome $($o.outcome))"
        Assert-True (@($o.blocked_by) -contains "npc") "blocked_by contains npc" "(got $(@($o.blocked_by) -join ','))"
        Assert-True ($o.blocker_name -eq "Edwardo Stovall") "blocker is Edwardo Stovall" "(got $($o.blocker_name))"
        Assert-True ($o.turn_delta -eq 0) "turn_delta is 0" "(got $($o.turn_delta))"
        Assert-True ((@($o.pos_abs_delta) -join ",") -eq "0,0,0") "pos_abs_delta is 0,0,0" "(got $(@($o.pos_abs_delta) -join ','))"

        # --- Gate 7: move_s -> moved. ----------------------------------------------------------
        Write-Host "Gate 7: move_s -> moved" -ForegroundColor Cyan
        $ms = Invoke-Api POST "/api/command" '{"command":"move","direction":"move_s"}'
        $o = $ms.Json.last_result.outcome
        Assert-True ($ms.Status -eq 200 -and $o.outcome -eq "moved") `
            "outcome is moved" "(status $($ms.Status), outcome $($o.outcome))"
        Assert-True ((@($o.pos_abs_delta) -join ",") -eq "0,1,0") "pos_abs_delta is 0,1,0" "(got $(@($o.pos_abs_delta) -join ','))"
        Assert-True ($o.turn_delta -ge 1) "turn_delta >= 1" "(got $($o.turn_delta))"

        # --- Gate 8: /api/wait alias -> waited. ------------------------------------------------
        Write-Host "Gate 8: wait -> waited" -ForegroundColor Cyan
        $wt = Invoke-Api POST "/api/wait" "{}"
        $o = $wt.Json.last_result.outcome
        Assert-True ($wt.Status -eq 200 -and $o.outcome -eq "waited") `
            "outcome is waited" "(status $($wt.Status), outcome $($o.outcome))"
        Assert-True ((@($o.pos_abs_delta) -join ",") -eq "0,0,0") "pos_abs_delta is 0,0,0" "(got $(@($o.pos_abs_delta) -join ','))"
        Assert-True ($o.turn_delta -ge 1) "turn_delta >= 1" "(got $($o.turn_delta))"

        # --- Gate 9: /api/export -> no_command + readable snapshot. ---------------------------
        Write-Host "Gate 9: export -> no_command" -ForegroundColor Cyan
        $ex = Invoke-Api POST "/api/export" "{}"
        $o = $ex.Json.last_result.outcome
        Assert-True ($ex.Status -eq 200 -and $o.outcome -eq "no_command") `
            "outcome is no_command" "(status $($ex.Status), outcome $($o.outcome))"
        Assert-True ($o.turn_delta -eq 0) "turn_delta is 0" "(got $($o.turn_delta))"
        $exportSnapshot = Join-Path (Join-Path $sessionsRoot "session_001") $ex.Json.backend.snapshot
        Assert-True (Test-Path $exportSnapshot) "export snapshot file exists" "(missing $exportSnapshot)"

        # --- Gate 10: backend vocabulary rejection is survivable data. ------------------------
        Write-Host "Gate 10: move_up -> backend unsupported_command, session survives" -ForegroundColor Cyan
        $mu = Invoke-Api POST "/api/command" '{"command":"move","direction":"move_up"}'
        $o = $mu.Json.last_result.outcome
        Assert-True ($mu.Status -eq 200 -and $o.outcome -eq "error") `
            "rejection is HTTP 200 + outcome error (game data, not transport)" "(status $($mu.Status), outcome $($o.outcome))"
        Assert-True ($mu.Json.last_result.response.ok -eq $false) "backend response is ok:false"
        Assert-True ($o.error.code -eq "unsupported_command") "error code is unsupported_command" "(got $($o.error.code))"
        $alive = Invoke-Api GET "/api/state"
        Assert-True ($alive.Json.phase -eq "ready") "session still ready after the rejection" "(phase $($alive.Json.phase))"
        $rec = Invoke-Api POST "/api/wait" "{}"
        Assert-True ($rec.Status -eq 200 -and $rec.Json.last_result.outcome.outcome -eq "waited") `
            "recovery wait succeeds" "(outcome $($rec.Json.last_result.outcome.outcome))"

        # --- Gate 11: bridge-side validation tiers. -------------------------------------------
        Write-Host "Gate 11: bridge validation (400 / 405)" -ForegroundColor Cyan
        $mal = Invoke-Api POST "/api/command" "{"
        Assert-True ($mal.Status -eq 400 -and $mal.Json.error.code -eq "bad_request") `
            "malformed body answers 400 bad_request" "(status $($mal.Status), code $($mal.Json.error.code))"
        $wrongMethod = Invoke-Api GET "/api/command"
        Assert-True ($wrongMethod.Status -eq 405) "GET /api/command answers 405" "(status $($wrongMethod.Status))"

        # --- Gate 12: quit ladder. --------------------------------------------------------------
        Write-Host "Gate 12: POST /api/quit" -ForegroundColor Cyan
        $quit = Invoke-Api POST "/api/quit" "{}"
        Assert-True ($quit.Status -eq 200 -and $quit.Json.phase -eq "ended") `
            "quit answers 200 + phase ended" "(status $($quit.Status), phase $($quit.Json.phase))"
        Assert-True ($quit.Json.session.exit_code -eq 0) "backend exit code is 0" "(got $($quit.Json.session.exit_code))"
        Assert-True ($quit.Json.session.final_snapshot -match '^\d+_final\.json$') `
            "final snapshot recorded" "(got $($quit.Json.session.final_snapshot))"
        $session1 = Join-Path $sessionsRoot "session_001"
        Assert-True (Test-Path (Join-Path $session1 $quit.Json.session.final_snapshot)) "final snapshot file exists"
        Assert-True (Test-Path (Join-Path $session1 "session.jsonl")) "session.jsonl transcript exists"

        # --- Gate 13: restartability (numbered session dirs). ---------------------------------
        Write-Host "Gate 13: second session" -ForegroundColor Cyan
        $start2 = Invoke-Api POST "/api/start" "{}"
        Assert-True ($start2.Status -eq 200 -and $start2.Json.session.index -eq 2 -and $start2.Json.session.dir_name -eq "session_002") `
            "second start is session_002" "(status $($start2.Status), session $($start2.Json.session.dir_name))"
        Assert-True (Test-Path (Join-Path (Join-Path $sessionsRoot "session_002") $start2.Json.backend.snapshot)) `
            "session_002 has its own start snapshot"
        $quit2 = Invoke-Api POST "/api/quit" "{}"
        Assert-True ($quit2.Status -eq 200 -and $quit2.Json.session.exit_code -eq 0) `
            "second session quits cleanly" "(status $($quit2.Status), exit $($quit2.Json.session.exit_code))"

        # --- Gate 14: clean server shutdown. ----------------------------------------------------
        Write-Host "Gate 14: POST /api/shutdown" -ForegroundColor Cyan
        $down = Invoke-Api POST "/api/shutdown" "{}"
        Assert-True ($down.Status -eq 200 -and $down.Json.shutting_down -eq $true) `
            "shutdown answers 200 shutting_down" "(status $($down.Status))"
        Assert-True ($serverProc.WaitForExit(8000)) "server process exits within 8s"
        $stillListening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        Assert-True (@($stillListening).Count -eq 0) "port $Port is released"

        # --- Gate 15: tileset-disabled fail-safe (a second, short-lived server on the now- ---
        # --- released port; own out-root + redirect files so server 1's diagnostics survive). -
        Write-Host "Gate 15: --disable-tileset fail-safe" -ForegroundColor Cyan
        $server2Out = Join-Path $OutRoot "server2_stdout.txt"
        $server2Err = Join-Path $OutRoot "server2_stderr.txt"
        $serverProc2 = Start-Process python -ArgumentList @(
                $Server, "--exe", $Exe, "--userdir", $UserDir, "--world", $World,
                "--out-root", (Join-Path $OutRoot "sessions_gate15"), "--port", $Port,
                "--disable-tileset"
            ) -NoNewWindow -PassThru -RedirectStandardOutput $server2Out -RedirectStandardError $server2Err
        $state2 = $null
        foreach( $i in 1..40 ) {
            if( $serverProc2.HasExited ) { break }
            try {
                $state2 = Invoke-Api GET "/api/state" -TimeoutSec 3
                break
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
        Assert-True ($null -ne $state2 -and $state2.Status -eq 200) `
            "second server (tileset disabled) answers /api/state"
        $page2 = Invoke-Api GET "/"
        Assert-True ($page2.Status -eq 200) "UI still serves with the tileset disabled" "(status $($page2.Status))"
        $info2 = Invoke-Api GET "/tileset/info"
        Assert-True ($info2.Status -eq 200 -and $info2.Json.enabled -eq $false) `
            "/tileset/info reports enabled:false" "(status $($info2.Status), enabled $($info2.Json.enabled))"
        $cfg2 = Invoke-Api GET "/tileset/tile_config.json"
        Assert-True ($cfg2.Status -eq 404) "/tileset/tile_config.json is 404 when disabled" "(status $($cfg2.Status))"
        $down2 = Invoke-Api POST "/api/shutdown" "{}"
        Assert-True ($down2.Status -eq 200) "second server shuts down" "(status $($down2.Status))"
        Assert-True ($serverProc2.WaitForExit(8000)) "second server process exits within 8s"
    } catch {
        Write-Host "  FATAL: unexpected error: $_" -ForegroundColor Red
        $script:fail++
    }
} finally {
    # Belt and braces: never leave either server (and through their atexit quit ladders,
    # the backend) running past this script.
    if( -not $serverProc.HasExited ) {
        try { Invoke-Api POST "/api/shutdown" "{}" -TimeoutSec 5 | Out-Null } catch {}
        if( -not $serverProc.WaitForExit(5000) ) {
            Write-Host "  WARN: force-stopping the server process (check for an orphan cataclysm-bn-tiles process)" -ForegroundColor Yellow
            Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if( $null -ne $serverProc2 -and -not $serverProc2.HasExited ) {
        try { Invoke-Api POST "/api/shutdown" "{}" -TimeoutSec 5 | Out-Null } catch {}
        if( -not $serverProc2.WaitForExit(5000) ) {
            Write-Host "  WARN: force-stopping the second (Gate 15) server process" -ForegroundColor Yellow
            Stop-Process -Id $serverProc2.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

if( $script:fail -gt 0 ) {
    Write-Host "FRONTEND PROTOTYPE REGRESSION: $script:fail hard assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "FRONTEND PROTOTYPE REGRESSION: all 17 gates passed." -ForegroundColor Green
exit 0
