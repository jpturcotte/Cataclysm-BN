<#
.SYNOPSIS
  Shared Arcopolis fixture-root resolver, dot-sourced by every *_regression.ps1 script.

.DESCRIPTION
  Resolves the Arcopolis test-world fixture root with this precedence:

    1. An explicit non-empty -FixtureSrc passed to the calling script (handled by the caller, before
       this resolver is consulted).
    2. A non-empty $env:ARCO_FIXTURE_ROOT (developer/CI override).
    3. The repo-local committed fixture pack: docs/arcopolis/fixtures/arcopolis_user (the default).
    4. The legacy external dev scratch root C:\dev\arcopolis-fixtures\arcopolis_user (optional fallback).

  Empty values never shadow the repo-local default: the truthiness checks below treat an empty string as
  "unset" (PowerShell coerces "" to $false), so an exported-but-empty ARCO_FIXTURE_ROOT does NOT override
  the committed fixtures.

  The canonical fixtures are committed in the repo (see docs/arcopolis/fixtures/README.md), so the external
  C:\dev\arcopolis-fixtures root is no longer required — it remains only as an optional developer
  convenience. C:\dev\arcopolis-fixtures is an AGENTS.md-approved non-sensitive local path (no
  username/secret), kept verbatim so the fallback stays copy-pasteable.

.NOTES
  Dot-source from a regression script and call after the param() block, e.g.:

    . "$PSScriptRoot/arco_fixture_root.ps1"
    if( -not $FixtureSrc ) { $FixtureSrc = Resolve-ArcoFixtureRoot -ScriptDir $PSScriptRoot }
#>

function Resolve-ArcoFixtureRoot {
    param([string]$ScriptDir)   # caller's $PSScriptRoot; both it and this helper live in docs/arcopolis

    if( $env:ARCO_FIXTURE_ROOT ) { return $env:ARCO_FIXTURE_ROOT }              # override (empty = unset)

    # Fall back to THIS helper's own dir when no/empty -ScriptDir was passed (e.g. dot-sourced at an
    # interactive prompt where the caller's $PSScriptRoot is empty). Both the regression scripts and this
    # helper live in docs/arcopolis, so the same fixtures/ subtree resolves. This avoids Join-Path's
    # empty-Path throw WITHOUT falling back to the (wrong) current working directory.
    if( -not $ScriptDir ) { $ScriptDir = $PSScriptRoot }

    $repoLocal = Join-Path $ScriptDir "fixtures/arcopolis_user"
    if( Test-Path $repoLocal ) { return $repoLocal }                           # repo-local committed pack

    $external = "C:\dev\arcopolis-fixtures\arcopolis_user"
    if( Test-Path $external ) { return $external }                             # optional dev fallback

    # Nothing found anywhere: return the canonical repo-local path so the caller's existing
    # "fixture not found: <path>" guard names the location a contributor should restore.
    return $repoLocal
}
