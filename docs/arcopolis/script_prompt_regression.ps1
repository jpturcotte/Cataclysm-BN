<#
.SYNOPSIS
  Arcopolis Spike 16 regression: non-live SCRIPT prompt-answer support (--arcopolis-run-script).

.DESCRIPTION
  Proves that a `--arcopolis-run-script` script can declare `prompt_answers` for already-proven prompted
  flows, and that those answers are consumed by the SAME backend prompt machinery as live mode (the same
  backend_resolve_* path, the same registered-action queues, the same prompt_* transcript events) -- only the
  answer's TRANSPORT differs (a declared script field, not a stdin JSONL line). It also proves the spike's
  fail-loud guarantees: a missing / wrong-kind / unused scripted answer aborts the run honestly
  (script_prompt_failed, exit 13), never a silent auto-cancel-as-success.

  This is a pure run-script regression -- it drives the binary directly and parses the snapshots +
  session.jsonl. It needs NO live driver / python (unlike the live prompt regressions): script mode has no
  client, so there is no stdin/stdout exchange, only the transcript and snapshots.

  Witnesses (all four fixtures live under C:\dev\arcopolis-fixtures\arcopolis_user\save):
    1. Pickup item menu        (ArcopolisTest)                -- kind=menu
    2. Vehicle-source uilist   (ArcopolisVehicleCargoTest)    -- kind=uilist then kind=menu
    3. Secondary capacity uilist (ArcopolisCapacityTest)      -- kind=menu then kind=uilist (WIELD)
    4. query_popup YES/NO      (ArcopolisDeployedFurnitureTest) -- kind=query_popup (YES takes down; NO keeps)
  Failure gates: pickup with no prompt_answers -> exit 6; wrong-kind answer -> exit 13; unused answer -> 13;
    NEW_PICKUP_MENU=true -> exit 6 (symmetric with live mode; the new inventory_selector is not driven).

  Equivalence proved: LEVEL 4 (for the supported scripted prompted paths) -- the script answer becomes
  registered actions (DOWN/RIGHT/CONFIRM / DOWN,CONFIRM / LEFT,CONFIRM) consumed by the engine's own
  input_context loop, which sets the result; the engine caller mutates world/inventory/activity state.

.NOTES
  Run with `pwsh` (PowerShell 7), NOT `powershell` (5.1): 5.1 misreads BOM-less UTF-8 snapshots and writes a
  BOM into options.json -> spurious gate failures on unchanged code (AGENTS.md / memory).
  C:\dev\arcopolis-fixtures and C:\dev\ccache are the project's approved local-path exceptions.
#>
[CmdletBinding()]
param(
    [string]$Exe             = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe",
    [string]$FixtureSrc      = "",
    [string]$UserDir         = ".\arcopolis_user",
    [string]$World           = "ArcopolisTest",
    [string]$VehicleWorld    = "ArcopolisVehicleCargoTest",
    [string]$CapacityWorld   = "ArcopolisCapacityTest",
    [string]$FurnitureWorld  = "ArcopolisDeployedFurnitureTest",
    [string]$OutRoot         = ".\out\arco_script_prompt_regress"
)

$ErrorActionPreference = "Stop"
# Resolve the fixture root: explicit -FixtureSrc > $env:ARCO_FIXTURE_ROOT > repo-local committed pack
# (docs/arcopolis/fixtures/arcopolis_user) > optional external dev fallback. See docs/arcopolis/fixtures/README.md.
. "$PSScriptRoot\arco_fixture_root.ps1"
if( $FixtureSrc ) { } else { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }

function Stop-WithCode {
    param([string]$Message, [int]$Code)
    Write-Error $Message -ErrorAction Continue
    exit $Code
}

# --- Prereqs (3=exe, 4=fixture, 5=world). ---
if( -not (Test-Path $Exe) ) {
    Stop-WithCode "Binary not found: $Exe  (build cataclysm-bn-tiles in out/build/win-rel-deb first; see 00_WINDOWS_LOCAL_ENVIRONMENT.md)" 3
}
if( -not (Test-Path $FixtureSrc) ) { Stop-WithCode "Fixture source directory not found: $FixtureSrc  (set ARCO_FIXTURE_ROOT, pass -FixtureSrc, or restore the committed pack at docs\arcopolis\fixtures\arcopolis_user)" 4 }
foreach( $w in @($World, $VehicleWorld, $CapacityWorld, $FurnitureWorld) ) {
    $fw = Join-Path $FixtureSrc (Join-Path "save" $w)
    if( -not (Test-Path $fw) ) {
        Stop-WithCode "Fixture world '$w' not found at $fw -- see AGENTS.md (Arcopolis test world fixture) / the make_*_fixture.py builders." 5
    }
}

# Refresh the gitignored sandbox userdir from the external fixture (a single shared config/options.json
# applies to every world under save/).
if( Test-Path $UserDir ) { Remove-Item $UserDir -Recurse -Force }
Copy-Item $FixtureSrc $UserDir -Recurse -Force
New-Item -ItemType Directory -Force $OutRoot | Out-Null

# Pin one boolean option in the SANDBOX copy's options.json (deployment config, never an in-memory override),
# UTF-8 with NO BOM. Same helper as prompt_menu_regression.ps1.
function Set-SandboxOption {
    param([string]$Name, [bool]$Value)
    $optPath = Join-Path $UserDir "config\options.json"
    $text = Get-Content $optPath -Raw
    $word = if( $Value ) { "true" } else { "false" }
    if( $text -match ('"name": "' + $Name + '", "value": "(true|false)"') ) {
        $patched = $text -replace ('("name": "' + $Name + '", "value": ")(true|false)(")'), "`${1}$word`${3}"
    } else {
        $entry = '{ "name": "' + $Name + '", "value": "' + $word + '" },'
        $patched = ([regex]'\[').Replace($text, ('[' + "`n  " + $entry), 1)
    }
    if( $patched -notmatch ('"name": "' + $Name + '", "value": "' + $word + '"') ) {
        Stop-WithCode "Could not set $Name=$word in the sandbox options.json" 4
    }
    Set-Content -Path $optPath -Value $patched -NoNewline -Encoding utf8
}

# AUTOSELECT=false so "Pickup/Examine where?" always prompts (the direction one-shot is served); AUTO_PICKUP
# =false so the master auto-pickup never silently grabs the witness pile during the move_s approach.
Set-SandboxOption -Name "AUTOSELECT_SINGLE_VALID_TARGET" -Value $false
Set-SandboxOption -Name "AUTO_PICKUP" -Value $false
# NEW_PICKUP_MENU=false so pickup uses the old "PICKUP" menu the script sources drive (the new
# inventory_selector is unsupported; F5 below witnesses that =true fails loud, symmetric with live mode).
Set-SandboxOption -Name "NEW_PICKUP_MENU" -Value $false

# Run one script and return { ExitCode, Transcript[], Stderr, Dir }. The GUI/windows-subsystem exe needs
# Start-Process -Wait -PassThru to capture the real exit code (a bare `& $exe` does not wait).
function Invoke-ScriptScenario {
    param([string]$Name, [string]$ScenarioWorld, [string]$ScriptJson)
    $dir = Join-Path $OutRoot $Name
    if( Test-Path $dir ) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $scriptPath = Join-Path $dir "script.json"
    Set-Content -Path $scriptPath -Value $ScriptJson -Encoding ascii
    $p = Start-Process -FilePath $Exe -ArgumentList @(
            '--world', $ScenarioWorld,
            '--arcopolis-run-script', $scriptPath,
            '--arcopolis-export-dir', $dir,
            '--userdir', $UserDir
        ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $dir "stdout.txt") -RedirectStandardError (Join-Path $dir "stderr.txt")
    $logPath = Join-Path $dir "session.jsonl"
    $transcript = @()
    if( Test-Path $logPath ) {
        $transcript = @(Get-Content $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{
        Name       = $Name
        ExitCode   = $p.ExitCode
        Transcript = $transcript
        Stderr     = (Get-Content (Join-Path $dir "stderr.txt") -Raw -ErrorAction SilentlyContinue)
        Dir        = $dir
    }
}

function Get-Snapshot {
    param([string]$Dir, [string]$Label)
    $f = Get-ChildItem $Dir -Filter "*_$Label.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if( -not $f ) { return $null }
    return (Get-Content $f.FullName -Raw | ConvertFrom-Json)
}

# Count top-level ground items at a LOCAL tile (snapshots use one frame for before/after since neither the
# pickup nor the examine moves the avatar).
function Count-ItemsAt {
    param($Snap, [int]$X, [int]$Y, [int]$Z)
    if( -not $Snap -or -not $Snap.entities -or -not $Snap.entities.items ) { return 0 }
    return @($Snap.entities.items | Where-Object {
        $_.pos_local[0] -eq $X -and $_.pos_local[1] -eq $Y -and $_.pos_local[2] -eq $Z
    }).Count
}

function Get-FurnAt {
    param($Snap, [int]$X, [int]$Y, [int]$Z)
    if( -not $Snap -or -not $Snap.tiles ) { return "" }
    $t = @($Snap.tiles | Where-Object { $_.x -eq $X -and $_.y -eq $Y -and $_.z -eq $Z }) | Select-Object -First 1
    if( -not $t ) { return "" }
    return [string]$t.furn
}

function Avatar-Local { param($Snap) return @([int]$Snap.avatar.pos_local[0], [int]$Snap.avatar.pos_local[1], [int]$Snap.avatar.pos_local[2]) }
function Of-Type { param($Transcript, [string]$Type) return @($Transcript | Where-Object { $_.event -eq $Type }) }

$fail = 0
function Gate { param([bool]$Cond, [string]$Pass, [string]$FailMsg)
    if( $Cond ) { Write-Host "  PASS: $Pass" -ForegroundColor Green }
    else { Write-Host "  FAIL: $FailMsg" -ForegroundColor Red; $script:fail++ }
}

# =============================================================================
# Witness 1 -- scripted PICKUP item-menu answer (ArcopolisTest).
# move_s, then pickup move_s answering the LAST menu entry (choice 6 = glass shard, fits the unarmed avatar).
# =============================================================================
Write-Host "[W1] scripted pickup item-menu answer (ArcopolisTest)"
$w1Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export", "name": "before" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "menu", "choice": 6 } ] },
  { "op": "export", "name": "after" }
] }
'@
$w1 = Invoke-ScriptScenario -Name "w1_menu" -ScenarioWorld $World -ScriptJson $w1Json
$b1 = Get-Snapshot $w1.Dir "before"; $a1 = Get-Snapshot $w1.Dir "after"
Gate ($w1.ExitCode -eq 0) "run exited 0" "run exited $($w1.ExitCode); stderr='$($w1.Stderr)'"
if( $b1 -and $a1 ) {
    $av = Avatar-Local $b1
    $bN = Count-ItemsAt $b1 $av[0] ($av[1]+1) $av[2]
    $aN = Count-ItemsAt $a1 $av[0] ($av[1]+1) $av[2]
    $opened = @(Of-Type $w1.Transcript "prompt_opened")
    $answered = @(Of-Type $w1.Transcript "prompt_answered")
    $completed = @(Of-Type $w1.Transcript "prompt_completed")
    $failed = @(Of-Type $w1.Transcript "prompt_failed")
    Gate ($opened.Count -eq 1 -and $opened[0].kind -eq "menu" -and @($opened[0].choices).Count -eq 7) `
        "prompt_opened kind=menu with the 7 REAL choices" `
        "prompt_opened wrong: $($opened | ConvertTo-Json -Compress -Depth 6)"
    $acts = if( $answered.Count -ge 1 ) { @($answered[0].actions) -join ',' } else { "<none>" }
    Gate ($answered.Count -eq 1 -and (@($answered[0].choices) -join ',') -eq "6" -and $acts -eq "DOWN,DOWN,DOWN,DOWN,DOWN,DOWN,RIGHT,CONFIRM") `
        "prompt_answered choices=[6] served [DOWN x6, RIGHT, CONFIRM] (level-4 registered actions)" `
        "prompt_answered wrong: choices=$(@($answered[0].choices) -join ',') actions=$acts"
    Gate ($completed.Count -eq 1 -and $completed[0].actions_served -eq 8 -and $failed.Count -eq 0) `
        "prompt_completed actions_served=8, no prompt_failed" `
        "prompt_completed/failed wrong: completed=$($completed | ConvertTo-Json -Compress) failed=$($failed.Count)"
    Gate ($bN -eq 7 -and $aN -eq 6) "south pile 7 -> 6 (the chosen item left the ground -- engine state change)" `
        "south pile $bN -> $aN (expected 7 -> 6)"
} else { Gate $false "" "missing before/after snapshot for W1" }

# =============================================================================
# Witness 2 -- scripted vehicle-source uilist answer (ArcopolisVehicleCargoTest).
# pickup move_s opens "Get items from where?" (uilist) -> choose ground (1) -> the old PICKUP menu -> choice 6.
# =============================================================================
Write-Host "[W2] scripted vehicle-source uilist answer (ArcopolisVehicleCargoTest)"
$w2Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export", "name": "before" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [
      { "kind": "uilist", "choice": 1, "title_contains": "Get items from where" },
      { "kind": "menu", "choice": 6 }
  ] },
  { "op": "export", "name": "after" }
] }
'@
$w2 = Invoke-ScriptScenario -Name "w2_vehicle_uilist" -ScenarioWorld $VehicleWorld -ScriptJson $w2Json
$b2 = Get-Snapshot $w2.Dir "before"; $a2 = Get-Snapshot $w2.Dir "after"
Gate ($w2.ExitCode -eq 0) "run exited 0" "run exited $($w2.ExitCode); stderr='$($w2.Stderr)'"
if( $b2 -and $a2 ) {
    $av = Avatar-Local $b2
    $bN = Count-ItemsAt $b2 $av[0] ($av[1]+1) $av[2]
    $aN = Count-ItemsAt $a2 $av[0] ($av[1]+1) $av[2]
    $opened = @(Of-Type $w2.Transcript "prompt_opened")
    Gate ($opened.Count -eq 2 -and $opened[0].kind -eq "uilist" -and $opened[1].kind -eq "menu") `
        "two prompts opened in order: kind=uilist then kind=menu" `
        "prompt_opened sequence wrong: $(@($opened | ForEach-Object { $_.kind }) -join ',')"
    $uAns = @(Of-Type $w2.Transcript "prompt_answered" | Where-Object { $_.kind -eq "uilist" })
    $uActs = if( $uAns.Count -ge 1 ) { @($uAns[0].actions) -join ',' } else { "<none>" }
    Gate ($uAns.Count -eq 1 -and $uActs -eq "DOWN,CONFIRM") `
        "uilist prompt_answered served [DOWN, CONFIRM] (chose ground)" `
        "uilist prompt_answered actions=$uActs"
    Gate ($bN -eq 7 -and $aN -eq 6) "ground pile 7 -> 6 (the chosen ground item left)" "ground pile $bN -> $aN (expected 7 -> 6)"
    Gate (@(Of-Type $w2.Transcript "prompt_failed").Count -eq 0) "no prompt_failed" "unexpected prompt_failed present"
} else { Gate $false "" "missing before/after snapshot for W2" }

# =============================================================================
# Witness 3 -- scripted secondary capacity uilist answer (ArcopolisCapacityTest).
# Two passes: PROBE (cancel the menu) discovers the jacket's menu index from prompt_opened.choices; then the
# real run picks the jacket -> the activity raises the secondary capacity uilist -> answer WIELD (entry 1).
# =============================================================================
Write-Host "[W3] scripted secondary capacity uilist answer (ArcopolisCapacityTest)"
$w3probeJson = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "menu", "cancel": true } ] }
] }
'@
$w3p = Invoke-ScriptScenario -Name "w3_probe" -ScenarioWorld $CapacityWorld -ScriptJson $w3probeJson
$jacketIdx = -1
if( $w3p.ExitCode -eq 0 ) {
    $menuOpened = @(Of-Type $w3p.Transcript "prompt_opened" | Where-Object { $_.kind -eq "menu" }) | Select-Object -First 1
    if( $menuOpened ) {
        # Match the INJECTED jacket_leather ("leather jacket") specifically -- ArcopolisTest's stock pile
        # already contains a different "emergency jacket", so a bare '*jacket*' would mis-match that.
        $j = @($menuOpened.choices | Where-Object { $_.text -like '*leather jacket*' }) | Select-Object -First 1
        if( $j ) { $jacketIdx = [int]$j.index }
    }
}
Gate ($jacketIdx -ge 0) "probe found the leather jacket at PICKUP menu index $jacketIdx" `
    "probe could not find a 'jacket' menu entry (exit=$($w3p.ExitCode)); ArcopolisCapacityTest may need rebuilding (make_capacity_fixture.py)"
if( $jacketIdx -ge 0 ) {
    $w3Json = @"
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export", "name": "before" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [
      { "kind": "menu", "choice": $jacketIdx },
      { "kind": "uilist", "choice": 1 }
  ] },
  { "op": "export", "name": "after" }
] }
"@
    $w3 = Invoke-ScriptScenario -Name "w3_capacity_uilist" -ScenarioWorld $CapacityWorld -ScriptJson $w3Json
    $b3 = Get-Snapshot $w3.Dir "before"; $a3 = Get-Snapshot $w3.Dir "after"
    Gate ($w3.ExitCode -eq 0) "run exited 0" "run exited $($w3.ExitCode); stderr='$($w3.Stderr)'"
    if( $b3 -and $a3 ) {
        $av = Avatar-Local $b3
        $bN = Count-ItemsAt $b3 $av[0] ($av[1]+1) $av[2]
        $aN = Count-ItemsAt $a3 $av[0] ($av[1]+1) $av[2]
        $opened = @(Of-Type $w3.Transcript "prompt_opened")
        Gate ($opened.Count -eq 2 -and $opened[0].kind -eq "menu" -and $opened[1].kind -eq "uilist") `
            "two prompts opened in order: kind=menu then kind=uilist (secondary capacity)" `
            "prompt_opened sequence wrong: $(@($opened | ForEach-Object { $_.kind }) -join ',')"
        $uAns = @(Of-Type $w3.Transcript "prompt_answered" | Where-Object { $_.kind -eq "uilist" })
        $uActs = if( $uAns.Count -ge 1 ) { @($uAns[0].actions) -join ',' } else { "<none>" }
        Gate ($uAns.Count -eq 1 -and $uActs -eq "DOWN,CONFIRM") `
            "secondary uilist prompt_answered served [DOWN, CONFIRM] (chose WIELD, entry 1)" `
            "secondary uilist actions=$uActs"
        Gate (@(Of-Type $w3.Transcript "prompt_force_cancelled").Count -eq 0) `
            "secondary capacity uilist was DRIVEN, not force-cancelled (no prompt_force_cancelled)" `
            "unexpected prompt_force_cancelled -- the secondary uilist was not driven"
        Gate ($bN - $aN -eq 1) "the jacket left the ground (pile $bN -> $aN; engine wielded it)" `
            "ground pile $bN -> $aN (expected -1: the wielded jacket should leave the ground)"
    } else { Gate $false "" "missing before/after snapshot for W3" }
}

# =============================================================================
# Witness 4 -- scripted query_popup YES/NO answer (ArcopolisDeployedFurnitureTest).
# examine move_e opens the deployed-furniture take-down query_yn. YES takes it down (furniture gone +
# mattress dropped); NO keeps it.
# =============================================================================
Write-Host "[W4] scripted query_popup YES/NO answer (ArcopolisDeployedFurnitureTest)"
$w4yesJson = @'
{ "schema_version": 1, "steps": [
  { "op": "export", "name": "before" },
  { "op": "command", "command": "examine", "direction": "move_e", "prompt_answers": [ { "kind": "query_popup", "choice": 0, "title_contains": "Take down" } ] },
  { "op": "export", "name": "after" }
] }
'@
$w4y = Invoke-ScriptScenario -Name "w4_query_popup_yes" -ScenarioWorld $FurnitureWorld -ScriptJson $w4yesJson
$b4 = Get-Snapshot $w4y.Dir "before"; $a4 = Get-Snapshot $w4y.Dir "after"
Gate ($w4y.ExitCode -eq 0) "YES run exited 0" "YES run exited $($w4y.ExitCode); stderr='$($w4y.Stderr)'"
if( $b4 -and $a4 ) {
    $av = Avatar-Local $b4
    $ex = $av[0]+1; $ey = $av[1]; $ez = $av[2]
    $bFurn = Get-FurnAt $b4 $ex $ey $ez
    $aFurn = Get-FurnAt $a4 $ex $ey $ez
    $aMattress = @($a4.entities.items | Where-Object { $_.pos_local[0] -eq $ex -and $_.pos_local[1] -eq $ey -and $_.pos_local[2] -eq $ez -and ($_.type_id -like '*mattress*' -or $_.name -like '*mattress*') }).Count
    $opened = @(Of-Type $w4y.Transcript "prompt_opened")
    $answered = @(Of-Type $w4y.Transcript "prompt_answered")
    $acts = if( $answered.Count -ge 1 ) { @($answered[0].actions) -join ',' } else { "<none>" }
    Gate ($opened.Count -eq 1 -and $opened[0].kind -eq "query_popup" -and $opened[0].witness -eq "examine_deployed_furniture_take_down" -and @($opened[0].choices).Count -eq 2) `
        "prompt_opened kind=query_popup witness=examine_deployed_furniture_take_down with 2 choices" `
        "prompt_opened wrong: $($opened | ConvertTo-Json -Compress -Depth 6)"
    Gate ($answered.Count -eq 1 -and $answered[0].kind -eq "query_popup" -and (@($answered[0].choices) -join ',') -eq "0" -and $acts -eq "LEFT,CONFIRM") `
        "YES prompt_answered choices=[0] served [LEFT, CONFIRM] (level-4)" "YES prompt_answered actions=$acts"
    Gate ($bFurn -like '*mattress*' -and $aFurn -notlike '*mattress*') `
        "furniture taken down: east tile furn '$bFurn' -> '$aFurn'" "furniture not taken down: '$bFurn' -> '$aFurn'"
    Gate ($aMattress -ge 1) "a mattress item was dropped on the east tile" "no mattress item dropped after YES"
} else { Gate $false "" "missing before/after snapshot for W4 (YES)" }

$w4noJson = @'
{ "schema_version": 1, "steps": [
  { "op": "export", "name": "before" },
  { "op": "command", "command": "examine", "direction": "move_e", "prompt_answers": [ { "kind": "query_popup", "choice": 1, "title_contains": "Take down" } ] },
  { "op": "export", "name": "after" }
] }
'@
$w4n = Invoke-ScriptScenario -Name "w4_query_popup_no" -ScenarioWorld $FurnitureWorld -ScriptJson $w4noJson
$b4n = Get-Snapshot $w4n.Dir "before"; $a4n = Get-Snapshot $w4n.Dir "after"
Gate ($w4n.ExitCode -eq 0) "NO run exited 0" "NO run exited $($w4n.ExitCode); stderr='$($w4n.Stderr)'"
if( $b4n -and $a4n ) {
    $av = Avatar-Local $b4n
    $ex = $av[0]+1; $ey = $av[1]; $ez = $av[2]
    $aFurn = Get-FurnAt $a4n $ex $ey $ez
    $answered = @(Of-Type $w4n.Transcript "prompt_answered")
    $acts = if( $answered.Count -ge 1 ) { @($answered[0].actions) -join ',' } else { "<none>" }
    Gate ($answered.Count -eq 1 -and (@($answered[0].choices) -join ',') -eq "1" -and $acts -eq "CONFIRM") `
        "NO prompt_answered choices=[1] served [CONFIRM]" "NO prompt_answered actions=$acts"
    Gate ($aFurn -like '*mattress*') "furniture STAYS after NO (east tile furn '$aFurn')" "furniture unexpectedly changed after NO: '$aFurn'"
} else { Gate $false "" "missing before/after snapshot for W4 (NO)" }

# =============================================================================
# Witness 5 -- a LEGITIMATE scripted cancel (cancel:true on the cancelable PICKUP menu). Distinct from a
# fatal fallback: clean exit 0, prompt_cancelled with NO preceding prompt_failed and NO error, pile unchanged.
# =============================================================================
Write-Host "[W5] legitimate scripted cancel (ArcopolisTest)"
$w5Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export", "name": "before" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "menu", "cancel": true } ] },
  { "op": "export", "name": "after" }
] }
'@
$w5 = Invoke-ScriptScenario -Name "w5_legit_cancel" -ScenarioWorld $World -ScriptJson $w5Json
$b5 = Get-Snapshot $w5.Dir "before"; $a5 = Get-Snapshot $w5.Dir "after"
Gate ($w5.ExitCode -eq 0) "legitimate cancel run exited 0" "legit cancel exit=$($w5.ExitCode); stderr='$($w5.Stderr)'"
if( $b5 -and $a5 ) {
    $av = Avatar-Local $b5
    $bN = Count-ItemsAt $b5 $av[0] ($av[1]+1) $av[2]
    $aN = Count-ItemsAt $a5 $av[0] ($av[1]+1) $av[2]
    Gate (@(Of-Type $w5.Transcript "prompt_cancelled").Count -ge 1 -and @(Of-Type $w5.Transcript "prompt_failed").Count -eq 0 -and @(Of-Type $w5.Transcript "error").Count -eq 0) `
        "legitimate cancel: prompt_cancelled with NO prompt_failed/error (distinct from a fatal fallback)" `
        "legit cancel transcript: cancelled=$(@(Of-Type $w5.Transcript 'prompt_cancelled').Count) failed=$(@(Of-Type $w5.Transcript 'prompt_failed').Count) err=$(@(Of-Type $w5.Transcript 'error').Count)"
    Gate ($bN -eq 7 -and $aN -eq 7) "legitimate cancel took no items (south pile 7 unchanged)" "south pile $bN -> $aN (expected 7 -> 7)"
} else { Gate $false "" "missing before/after snapshot for W5" }

# =============================================================================
# Failure gates -- the run must abort honestly, never a silent success.
# =============================================================================
Write-Host "[F] fail-loud gates"

# F1: pickup with NO prompt_answers -> exit 6 (no channel; rejected at pre-flight before the world load).
$f1Json = '{ "schema_version": 1, "steps": [ { "op": "command", "command": "pickup", "direction": "move_s" } ] }'
$f1 = Invoke-ScriptScenario -Name "f1_no_answers" -ScenarioWorld $World -ScriptJson $f1Json
Gate ($f1.ExitCode -eq 6 -and $f1.Stderr -like '*requires --arcopolis-live*') `
    "pickup with no prompt_answers fails loud at pre-flight (exit 6)" `
    "no-answers exit=$($f1.ExitCode) stderr='$($f1.Stderr)' (expected 6)"

# F2: wrong-kind answer (a uilist answer for the menu prompt that opens) -> exit 13, prompt_failed kind_mismatch.
$f2Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "uilist", "choice": 0 } ] }
] }
'@
$f2 = Invoke-ScriptScenario -Name "f2_wrong_kind" -ScenarioWorld $World -ScriptJson $f2Json
$f2failed = @(Of-Type $f2.Transcript "prompt_failed")
Gate ($f2.ExitCode -eq 13 -and @($f2failed | Where-Object { $_.reason -eq "kind_mismatch" }).Count -ge 1) `
    "wrong-kind answer fails loud (exit 13, prompt_failed reason=kind_mismatch)" `
    "wrong-kind exit=$($f2.ExitCode) failed=$(@($f2failed | ForEach-Object { $_.reason }) -join ',')"
# Amendment 1: prompt_failed must precede the engine loop-exit escape (prompt_cancelled), so the escape is
# never misread as a user cancel. Witness the ordering directly in the transcript.
$f2evts = @($f2.Transcript)
$failedIdx = -1; $cancelIdx = -1
for( $i = 0; $i -lt $f2evts.Count; $i++ ) {
    if( $failedIdx -lt 0 -and $f2evts[$i].event -eq "prompt_failed" ) { $failedIdx = $i }
    if( $cancelIdx -lt 0 -and $f2evts[$i].event -eq "prompt_cancelled" ) { $cancelIdx = $i }
}
Gate ($failedIdx -ge 0 -and $cancelIdx -ge 0 -and $failedIdx -lt $cancelIdx) `
    "Amendment 1: prompt_failed (idx $failedIdx) precedes the escape prompt_cancelled (idx $cancelIdx)" `
    "ordering wrong: prompt_failed idx=$failedIdx, prompt_cancelled idx=$cancelIdx"

# F3: unused answer (a second uilist answer the single-menu pickup never reaches) -> exit 13.
$f3Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [
      { "kind": "menu", "choice": 6 },
      { "kind": "uilist", "choice": 0 }
  ] }
] }
'@
$f3 = Invoke-ScriptScenario -Name "f3_unused" -ScenarioWorld $World -ScriptJson $f3Json
$f3err = @(Of-Type $f3.Transcript "error")
Gate ($f3.ExitCode -eq 13 -and @($f3err | Where-Object { $_.kind -eq "script_prompt_failed" }).Count -ge 1) `
    "unused answer fails loud (exit 13, error kind=script_prompt_failed)" `
    "unused exit=$($f3.ExitCode) errors=$(@($f3err | ForEach-Object { $_.kind }) -join ',')"

# F4: out-of-range menu choice -> exit 13, prompt_failed reason=choice_out_of_range (witnesses that reason e2e).
$f4Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "menu", "choice": 99 } ] }
] }
'@
$f4 = Invoke-ScriptScenario -Name "f4_out_of_range" -ScenarioWorld $World -ScriptJson $f4Json
$f4failed = @(Of-Type $f4.Transcript "prompt_failed")
Gate ($f4.ExitCode -eq 13 -and @($f4failed | Where-Object { $_.reason -eq "choice_out_of_range" }).Count -ge 1) `
    "out-of-range choice fails loud (exit 13, prompt_failed reason=choice_out_of_range)" `
    "out-of-range exit=$($f4.ExitCode) failed=$(@($f4failed | ForEach-Object { $_.reason }) -join ',')"

# F5: NEW_PICKUP_MENU=true -> a scripted pickup is rejected loud and early (exit 6), symmetric with live mode
# (src/arcopolis_live.cpp:213); the new inventory_selector menu is NOT driven by the script prompt sources. The
# reject fires after the world load but before the session log opens, so (like F1) assert on exit + stderr.
Set-SandboxOption -Name "NEW_PICKUP_MENU" -Value $true
$f5Json = @'
{ "schema_version": 1, "steps": [
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "command", "command": "pickup", "direction": "move_s", "prompt_answers": [ { "kind": "menu", "choice": 6 } ] }
] }
'@
$f5 = Invoke-ScriptScenario -Name "f5_new_pickup_menu" -ScenarioWorld $World -ScriptJson $f5Json
Gate ($f5.ExitCode -eq 6 -and $f5.Stderr -like '*NEW_PICKUP_MENU=false*') `
    "NEW_PICKUP_MENU=true fails loud and early (exit 6, clear 'requires NEW_PICKUP_MENU=false' message)" `
    "new-pickup-menu exit=$($f5.ExitCode) stderr='$($f5.Stderr)' (expected 6)"
Set-SandboxOption -Name "NEW_PICKUP_MENU" -Value $false  # reset for hygiene

if( $fail -gt 0 ) { Write-Host "SCRIPT PROMPT REGRESSION: $fail gate(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "SCRIPT PROMPT REGRESSION: ok." -ForegroundColor Green
exit 0
