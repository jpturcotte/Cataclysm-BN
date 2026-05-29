# Windows Local Environment

## Summary

This checkout has a viable Windows build path, but the current plain PowerShell session is not enough by itself for a direct command-line build.

The repository provides a Windows CMake preset named `windows-tiles-sounds-x64-msvc`, backed by Visual Studio 2022, MSVC, vcpkg, tiles, sound, localization, and tests. Visual Studio 2022 Community is installed locally and `vswhere.exe` can find its C++ toolchain, bundled CMake, bundled Ninja, bundled vcpkg, MSVC `cl.exe`, and LLVM `clang`/`clang-cl`. The public Cataclysm: Bright Nights docs page for [Building with Visual Studio 2022 and CMake](https://docs.cataclysmbn.org/dev/guides/building/vs_cmake/) was checked end-to-end on 2026-05-29. The public page says it was last updated on 2026-05-29, and it appears to match the local `docs/en/dev/guides/building/vs_cmake.md` guide.

Exact local filesystem paths are intentionally redacted in this document. Use placeholders such as `<repo-root>`, `<vs-install-root>`, and `<path-to-ccache-dir>` when sharing commands or PR text.

The missing step is shell activation. In the current shell, `cmake`, `ninja`, `clang`, `clang-cl`, `cl`, and `ccache` are not on `PATH`, and Visual Studio developer environment variables are not set. Opening a Visual Studio Developer PowerShell, or running the PowerShell `Enter-VsDevShell` commands below, makes the shell suitable for the recommended configure/build commands.

## Repo context

- Repo root detected with `Get-Location`: `<repo-root>`
- Initial `git status`, before creating this Arcopolis documentation: `Not currently on any branch.` and `nothing to commit, working tree clean`
- `git branch --show-current`: empty output, because this worktree is detached at `HEAD`
- Remotes:
  - `origin`: personal fork remote
  - `upstream`: official Bright Nights remote

Commands used:

```powershell
Get-Location
git status
git branch --show-current
git remote -v
```

## Tools detected

Detected in the current plain PowerShell session:

| Tool | Current PATH result | Version or note |
| --- | --- | --- |
| `git` | `<program-files>\Git\cmd\git.exe` | `git version 2.54.0.windows.1` |
| `cmake` | Not found | VS-bundled CMake exists, but current shell cannot call `cmake` directly |
| `ninja` | Not found | VS-bundled Ninja exists, but current shell cannot call `ninja` directly |
| `clang` | Not found | VS-bundled LLVM `clang.exe` exists |
| `clang-cl` | Not found | VS-bundled LLVM `clang-cl.exe` exists |
| `cl` | Not found | VS-bundled MSVC `cl.exe` exists |
| `ccache` | Not found on PATH | Installed outside PATH at `<path-to-ccache-dir>\ccache.exe`, version `4.13.6` |
| `python` | Found | `Python 3.13.7` |
| `node` | Found | `v22.19.0` |
| `deno` | Found | `deno 2.7.12` |

Important resolved tool paths outside the current PATH:

- CMake: `<vs-install-root>\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`, version `3.31.6-msvc6`
- Ninja: `<vs-install-root>\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe`, version `1.12.1`
- MSVC: `<vs-install-root>\VC\Tools\MSVC\<version>\bin\Hostx64\x64\cl.exe`, compiler banner `19.44.35227 for x64`
- LLVM clang: `<vs-install-root>\VC\Tools\Llvm\x64\bin\clang.exe`, version `19.1.5`
- LLVM clang-cl: `<vs-install-root>\VC\Tools\Llvm\x64\bin\clang-cl.exe`, version `19.1.5`
- vcpkg: `<vs-install-root>\VC\vcpkg\vcpkg.exe`, version `2025-11-19-da1f056dc0775ac651bea7e3fbbf4066146a55f3`
- ccache: `<path-to-ccache-dir>\ccache.exe`, version `4.13.6`

The local ccache directory also contains `cl.exe` and `clang-cl.exe` wrapper names. For this repo's normal MSVC preset, append `<path-to-ccache-dir>` to `PATH` after activating the Visual Studio DevShell instead of prepending it. That lets `find_program(CCACHE_EXE ccache)` discover `ccache.exe` while keeping the real MSVC `cl.exe` first.

Checks used:

```powershell
where.exe git
where.exe cmake
where.exe ninja
where.exe clang
where.exe clang-cl
where.exe cl
where.exe ccache
where.exe python
where.exe node
where.exe deno
Get-Command cmake -ErrorAction SilentlyContinue
Get-Command ninja -ErrorAction SilentlyContinue
Get-Command clang -ErrorAction SilentlyContinue
Get-Command clang-cl -ErrorAction SilentlyContinue
Get-Command cl -ErrorAction SilentlyContinue
Get-Command ccache -ErrorAction SilentlyContinue
```

## Visual Studio detection

`vswhere.exe` is present:

```powershell
Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -ErrorAction SilentlyContinue
```

It detects:

- Visual Studio Community 2022
- Version: `17.14.33 (May 2026)`
- Install path: `<vs-install-root>`
- State: complete, launchable, no reboot required
- C++ tools present: `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`

The current plain PowerShell session does not have Visual Studio developer variables active. These were unset in the current shell:

- `VSINSTALLDIR`
- `VCINSTALLDIR`
- `VSCMD_ARG_TGT_ARCH`
- `VSCMD_VER`
- `VisualStudioVersion`
- `DevEnvDir`
- `WindowsSdkDir`
- `VCToolsInstallDir`
- `VCToolsVersion`

After a temporary `Enter-VsDevShell` probe, those variables were set and the shell could find `cmake`, `ninja`, `cl`, `clang`, `clang-cl`, and `vcpkg`. The target architecture reported by the DevShell was `x64`.

PowerShell-native DevShell activation command:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devShellModule = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"
```

Conclusion: you do not have to open a separate Visual Studio Developer PowerShell window if you run the `Enter-VsDevShell` commands above in the current PowerShell session first. Without that activation, the current shell is not enough for direct `cmake`, `cl`, or `ninja` commands.

## CMake presets found

`CMakePresets.json` exists at the repo root and has CMake preset schema version `2`.

Windows presets are present, not just Linux presets.

Key configure preset:

- `windows-tiles-sounds-x64-msvc`
  - Generator: `Visual Studio 17 2022`
  - Binary dir: `out/build/windows-tiles-sounds-x64-msvc`
  - Toolchain: `build-scripts/MSVC.cmake`
  - Preload: `build-scripts/windows-tiles-sounds-x64-msvc.cmake`
  - vcpkg triplet: `x64-windows-static`
  - Enables: tiles, sound, localization, tests, JSON formatter

Windows build presets:

- `windows-msvc-debug`
- `windows-msvc-release`
- `windows-msvc-relwithdebinfo`

The Windows build presets target `cataclysm-bn-tiles`, `cata_test-tiles`, `json_formatter`, and `translations`.

Other configure presets include Linux, macOS, distribution, lint, and CI presets:

- `linux-curses`
- `linux-slim`
- `linux-full`
- `linux-cross-aarch64`
- `linux-slim-cross-aarch64`
- `linux-full-cross-aarch64`
- `dist-tiles`
- `dist-curses`
- `osx-*`
- `lint`
- `ci-curses`
- `ci-tiles`

Commands used:

```powershell
Get-ChildItem .\CMakePresets.json -ErrorAction SilentlyContinue
Get-Content .\CMakePresets.json -ErrorAction SilentlyContinue
cmake --list-presets
```

## Likely Windows build path

The best local Windows path for this repository is Visual Studio 2022 plus MSVC plus vcpkg via CMake.

Existing build documentation checked:

- Public latest-looking guide: [Building with Visual Studio 2022 and CMake](https://docs.cataclysmbn.org/dev/guides/building/vs_cmake/). It says VS 2022 17.6+, Desktop development with C++, CMake, Ninja, vcpkg, and git are the expected Windows prerequisites. It also says `RelWithDebInfo` is the best normal development configuration and that first builds download and compile vcpkg dependencies.
- Local equivalent: `docs/en/dev/guides/building/vs_cmake.md`. This is the most relevant guide for this machine.
- Useful legacy/background guide: `docs/en/dev/guides/building/vs_vcpkg.md`. It documents the older `msvc-full-features` solution workflow with vcpkg. It is useful context but not the primary path for a fresh terminal CMake build.
- General CMake guide: `docs/en/dev/guides/building/cmake.md`. It covers Linux, WSL, MSYS2, and older Visual Studio/MSBuild guidance. For this Windows machine, the VS 2022 CMake guide is more specific.

There are two supported-looking Windows workflows:

1. Terminal workflow using `CMakePresets.json`
   - Configure preset: `windows-tiles-sounds-x64-msvc`
   - Build preset: `windows-msvc-relwithdebinfo`
   - Generator: `Visual Studio 17 2022`
   - Compiler: MSVC `cl.exe`
   - Dependencies: vcpkg static triplet `x64-windows-static`
   - Public guide flow: run `.\setup.ps1` once from plain PowerShell, then use a VS 2022 Developer Command Prompt or Developer PowerShell for standard `cmake` commands. A later plain-terminal `cmake --build` relies on generated `CMakeUserPresets.json`.

2. Visual Studio IDE workflow using `CMakeSettings.json`
   - Configurations: `Debug`, `RelWithDebInfo`, `Release`, `Tests`, `Tracy`
   - Generator: `Ninja`
   - Environment: `msvc_x64_x64`
   - Also uses `build-scripts/MSVC.cmake` and `build-scripts/windows-tiles-sounds-x64-msvc.cmake`
   - Public guide flow: open the repo root folder in Visual Studio, do not open the legacy `.sln` from `msvc-full-features`, and set Visual Studio's CMake option for `CMakeSettings.json`/`CMakePresets.json` detection to use `CMakeSettings.json (Legacy)` or to never use CMake Presets.
   - Public guide default: use `RelWithDebInfo` for normal development because it is optimized but still debuggable. Use `Tests` for `cata_test-tiles.exe`.

The repo also documents MSYS2 and a legacy Visual Studio/vcpkg solution path, but this checkout's modern Windows files point most strongly to the VS 2022 CMake route above. The Windows preset does not appear to use `clang-cl` or MinGW for the main build; the VS LLVM tools are installed, but the preset's MSVC toolchain file sets `cl.exe`.

The preload file `build-scripts/windows-tiles-sounds-x64-msvc.cmake` may generate `CMakeUserPresets.json` during first configure. It may also download prebuilt gettext binaries into `build-data/gettext` if `msgfmt.exe` is not already present. First configure/build may also download and build vcpkg dependencies.

The public guide's ccache note is directly relevant here: ccache is used automatically only when `ccache` is installed and on `PATH`. On this machine, add `<path-to-ccache-dir>` to `PATH` for the session before the first configure if you want CMake to bake ccache into the generated build files.

## Recommended PowerShell setup commands

Run these from any PowerShell session before configuring:

```powershell
Set-Location "<repo-root>"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devShellModule = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"

$ccacheDir = "<path-to-ccache-dir>"
if (Test-Path (Join-Path $ccacheDir "ccache.exe")) {
    $env:PATH = "$env:PATH;$ccacheDir"
}

where.exe cmake
where.exe cl
where.exe ninja
where.exe vcpkg
where.exe ccache
```

Alternatively, open a Visual Studio 2022 Developer PowerShell for x64 from the Start menu, then run:

```powershell
Set-Location "<repo-root>"
$ccacheDir = "<path-to-ccache-dir>"
if (Test-Path (Join-Path $ccacheDir "ccache.exe")) {
    $env:PATH = "$env:PATH;$ccacheDir"
}
where.exe cmake
where.exe cl
where.exe ninja
where.exe vcpkg
where.exe ccache
```

## Recommended configure command

After the setup commands above:

```powershell
cmake --preset windows-tiles-sounds-x64-msvc
```

Optional repo setup wrapper:

```powershell
.\setup.ps1
```

`.\setup.ps1` validates prerequisites and runs the same default configure preset. It was not run during this discovery task because it writes build output and may download dependencies. The public guide recommends it as the one-time terminal setup command from plain PowerShell; in this current Codex shell, `cmake` is not on PATH, so activating DevShell first is the more predictable route unless PATH is updated separately.

## Recommended build command

For an initial backend-capable local build with game and tests:

```powershell
cmake --build --preset windows-msvc-relwithdebinfo --target cataclysm-bn-tiles cata_test-tiles
```

For the full preset target set, including formatter and translations:

```powershell
cmake --build --preset windows-msvc-relwithdebinfo
```

## Recommended validation command

Run from the repository root after a successful build:

```powershell
& ".\out\build\windows-tiles-sounds-x64-msvc\tests\RelWithDebInfo\cata_test-tiles.exe"
```

Then validate mod loading:

```powershell
& ".\out\build\windows-tiles-sounds-x64-msvc\src\RelWithDebInfo\cataclysm-bn-tiles.exe" --check-mods
```

For a quick executable existence check:

```powershell
Get-ChildItem ".\out\build\windows-tiles-sounds-x64-msvc\src\RelWithDebInfo\cataclysm-bn-tiles.exe"
Get-ChildItem ".\out\build\windows-tiles-sounds-x64-msvc\tests\RelWithDebInfo\cata_test-tiles.exe"
```

## Missing tools or blockers

- Current plain PowerShell is missing direct `cmake`, `ninja`, `cl`, `clang`, and `clang-cl` commands. Activating Visual Studio DevShell fixes this.
- `ccache` is installed outside PATH, but it was not on PATH in the current shell or the temporary DevShell probe. This is optional; the Windows preload script only enables ccache if it finds `ccache`.
- `CMakeUserPresets.json` does not exist yet. That is expected before first configure; the Windows preload script should generate it.
- First configure was not run during this task. Therefore vcpkg dependency resolution, gettext download, and actual compile success remain unverified.
- The docs and `setup.ps1` mention `windows-tiles-sounds-x64-msvc-tracy`, but that configure preset was not present in the current `CMakePresets.json`. The Visual Studio IDE `CMakeSettings.json` does include a `Tracy` configuration.
- The worktree is detached at `HEAD`. Before code work, create or switch to a branch.

## Questions for the user

- Do you want Arcopolis backend experiments to use the terminal CMake preset workflow, the Visual Studio IDE workflow, or both?
- Do you want your ccache directory added permanently to your user PATH, or should we keep adding it session-by-session after DevShell activation?
- Should the first real build use `RelWithDebInfo` as the default, or should Arcopolis backend work start with `Debug`?
- Is it acceptable for first configure/build to download gettext and vcpkg dependencies, or do you want a documented offline/cache strategy first?

## Next Codex task

Concrete next step: activate the Visual Studio DevShell with the PowerShell setup commands above, run `cmake --preset windows-tiles-sounds-x64-msvc`, then run `cmake --build --preset windows-msvc-relwithdebinfo --target cataclysm-bn-tiles cata_test-tiles` and record the actual configure/build result in this document.
