param(
    [switch]$RevealPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = ( Resolve-Path ( Join-Path $PSScriptRoot "..\.." ) ).Path
$CMakePresetsPath = Join-Path $RepoRoot "CMakePresets.json"

function ConvertTo-DisplayText {
    param( $Value )

    $text = $Value | Out-String -Width 240
    if( -not $RevealPaths ) {
        if( -not [string]::IsNullOrWhiteSpace( $RepoRoot ) ) {
            $text = $text -replace [regex]::Escape( $RepoRoot ), "<repo-root>"
        }
        $userProfilePath = [Environment]::GetFolderPath( "UserProfile" )
        if( -not [string]::IsNullOrWhiteSpace( $userProfilePath ) ) {
            $text = $text -replace [regex]::Escape( $userProfilePath ), "<user-profile>"
        }
        $programFilesX86Path = [Environment]::GetFolderPath( "ProgramFilesX86" )
        if( -not [string]::IsNullOrWhiteSpace( $programFilesX86Path ) ) {
            $text = $text -replace [regex]::Escape( $programFilesX86Path ), "<program-files-x86>"
        }
        $programFilesPath = [Environment]::GetFolderPath( "ProgramFiles" )
        if( -not [string]::IsNullOrWhiteSpace( $programFilesPath ) ) {
            $text = $text -replace [regex]::Escape( $programFilesPath ), "<program-files>"
        }
        $text = $text -replace "https://github\.com/[^/\s]+/Cataclysm-BN\.git", "https://github.com/<owner>/Cataclysm-BN.git"
    }

    return $text.TrimEnd()
}

function Write-Section {
    param( [string]$Title )

    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Invoke-Check {
    param(
        [string]$Label,
        [scriptblock]$Script
    )

    Write-Host ""
    Write-Host "> $Label" -ForegroundColor DarkGray
    try {
        $output = & $Script 2>&1
        if( $null -ne $output ) {
            $text = ConvertTo-DisplayText $output
            if( -not [string]::IsNullOrWhiteSpace( $text ) ) {
                Write-Host $text
            }
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-Command {
    param( [string]$Name )

    Invoke-Check "where.exe $Name" {
        $whereOutput = & where.exe $Name 2>&1
        if( $LASTEXITCODE -ne 0 ) {
            "not found on PATH"
        } else {
            $whereOutput
        }
    }

    Invoke-Check "Get-Command $Name -ErrorAction SilentlyContinue" {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if( $null -eq $cmd ) {
            "not found by Get-Command"
        } else {
            $cmd | Select-Object CommandType, Name, Version, Source
        }
    }
}

Write-Section "Repo context"
Invoke-Check "Get-Location" { Get-Location }
Invoke-Check "git status" { git status }
Invoke-Check "git branch --show-current" { git branch --show-current }
Invoke-Check "git remote -v" { git remote -v }

Write-Section "Tools detected"
$toolNames = @(
    "git",
    "cmake",
    "ninja",
    "clang",
    "clang-cl",
    "cl",
    "ccache",
    "python",
    "node",
    "deno"
)

foreach( $toolName in $toolNames ) {
    Show-Command $toolName
}

Write-Section "ccache note"
Write-Host ""
Write-Host "If ccache is installed outside PATH, append its directory after Visual Studio DevShell activation:"
Write-Host '  $env:PATH = "$env:PATH;<path-to-ccache-dir>"'
Write-Host "Run with -RevealPaths if you need unredacted local paths in the output."

Write-Section "Visual Studio environment variables"
$vsEnvNames = @(
    "VSINSTALLDIR",
    "VCINSTALLDIR",
    "VSCMD_ARG_TGT_ARCH",
    "VSCMD_VER",
    "VisualStudioVersion",
    "DevEnvDir",
    "WindowsSdkDir",
    "VCToolsInstallDir",
    "VCToolsVersion",
    "VCPKG_ROOT",
    "VCPKG_INSTALLATION_ROOT"
)

foreach( $envName in $vsEnvNames ) {
    $envValue = [Environment]::GetEnvironmentVariable( $envName )
    if( [string]::IsNullOrWhiteSpace( $envValue ) ) {
        Write-Host "$envName=<not set>"
    } else {
        Write-Host "$envName=$envValue"
    }
}

Write-Section "Visual Studio detection"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Invoke-Check "Get-ChildItem `"${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe`" -ErrorAction SilentlyContinue" {
    Get-ChildItem $vswhere -ErrorAction SilentlyContinue
}

if( Test-Path $vswhere ) {
    Invoke-Check "vswhere latest Visual Studio with C++ tools" {
        & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }

    Invoke-Check "vswhere find cmake.exe" {
        & $vswhere -latest -products * -find "**\cmake.exe"
    }

    Invoke-Check "vswhere find ninja.exe" {
        & $vswhere -latest -products * -find "**\ninja.exe"
    }

    Invoke-Check "vswhere find cl.exe" {
        & $vswhere -latest -products * -find "**\cl.exe"
    }

    Invoke-Check "vswhere find clang.exe" {
        & $vswhere -latest -products * -find "**\clang.exe"
    }

    Invoke-Check "vswhere find clang-cl.exe" {
        & $vswhere -latest -products * -find "**\clang-cl.exe"
    }

    Invoke-Check "vswhere find vcpkg.exe" {
        & $vswhere -latest -products * -find "**\vcpkg.exe"
    }

    Invoke-Check "vswhere find Microsoft.VisualStudio.DevShell.dll" {
        & $vswhere -latest -products * -find "**\Microsoft.VisualStudio.DevShell.dll"
    }
}

Write-Section "CMake presets"
Invoke-Check "Get-ChildItem CMakePresets.json -ErrorAction SilentlyContinue" {
    Get-ChildItem $CMakePresetsPath -ErrorAction SilentlyContinue
}

Invoke-Check "CMake preset summary" {
    if( -not ( Test-Path $CMakePresetsPath ) ) {
        "CMakePresets.json not found"
        return
    }

    $presets = Get-Content $CMakePresetsPath -Raw | ConvertFrom-Json
    "configurePresets:"
    foreach( $preset in $presets.configurePresets ) {
        $generatorValue = $preset | Select-Object -ExpandProperty generator -ErrorAction SilentlyContinue
        $generator = if( $null -ne $generatorValue -and -not [string]::IsNullOrWhiteSpace( [string]$generatorValue ) ) {
            $generatorValue
        } else {
            "<inherits>"
        }
        "  $($preset.name) [$generator]"
    }

    "buildPresets:"
    foreach( $preset in $presets.buildPresets ) {
        "  $($preset.name) -> $($preset.configurePreset)"
    }
}

Write-Section "Suggested next command"
Write-Host "Activate Visual Studio DevShell, then run:"
Write-Host "  cmake --preset windows-tiles-sounds-x64-msvc"
