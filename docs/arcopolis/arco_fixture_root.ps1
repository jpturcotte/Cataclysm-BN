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

function Format-ArcoPath {
    <#
    .SYNOPSIS
      Redact the user-profile / home portion of a path for diagnostic output (AGENTS.md privacy rule).

    .DESCRIPTION
      A committed regression script MUST NOT echo identifying local paths (e.g. C:\Users\<name>\...) by
      default — see AGENTS.md "Privacy and Environment Documentation" ("MUST redact local paths from
      diagnostic script output by default. If exact paths are useful, require an explicit opt-in flag such
      as -RevealPaths"). This collapses the $USERPROFILE / $HOME prefix to "<user-profile>" and any other
      \Users\<name> segment to \Users\<user>, so a copied failure log carries no username. Relative paths
      and the AGENTS.md-approved non-sensitive roots (C:\dev\*, C:\tmp\*) contain no username and pass
      through UNCHANGED, so default-path diagnostics are unaffected. Set $env:ARCO_REVEAL_PATHS to a
      non-empty value (the explicit opt-in) to print full paths.

      Wrap path interpolations in diagnostic messages, e.g.:
          Stop-WithCode "Binary not found: $(Format-ArcoPath $Exe)" 3
    #>
    param([string]$Path)
    if( -not $Path ) { return $Path }
    if( $env:ARCO_REVEAL_PATHS ) { return $Path }   # opt-in: print full paths (empty = unset)
    $redacted = $Path
    # Collapse a leading $USERPROFILE / $HOME prefix (handles a redirected profile not literally C:\Users\<name>).
    foreach( $root in @($env:USERPROFILE, $HOME) ) {
        if( $root -and $redacted.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) ) {
            $redacted = '<user-profile>' + $redacted.Substring($root.Length)
            break
        }
    }
    # Redact any remaining \Users\<name> segment (e.g. an override path under a different profile).
    return [regex]::Replace($redacted, '(?i)\\Users\\[^\\]+', '\Users\<user>')
}
