# Windows Local Environment

## Summary

This checkout has a viable Windows build path, but the current plain PowerShell session is not enough by itself for a direct command-line build.

The repository provides a Windows CMake preset named `windows-tiles-sounds-x64-msvc`, backed by Visual Studio 2022, MSVC, vcpkg, tiles, sound, localization, and tests. Visual Studio 2022 Community is installed locally and `vswhere.exe` can find its C++ toolchain, bundled CMake, bundled Ninja, bundled vcpkg, MSVC `cl.exe`, and LLVM `clang`/`clang-cl`. The public Cataclysm: Bright Nights docs page for [Building with Visual Studio 2022 and CMake](https://docs.cataclysmbn.org/dev/guides/building/vs_cmake/) was checked end-to-end on 2026-05-29. The public page says it was last updated on 2026-05-29, and it appears to match the local `docs/en/dev/guides/building/vs_cmake.md` guide.

Exact local filesystem paths are intentionally redacted in this document unless explicitly approved. Use placeholders such as `<repo-root>` and `<vs-install-root>` when sharing commands or PR text. The local ccache path is an explicit approved exception for this machine: `C:\dev\ccache`.

The missing step is shell activation. In the current shell, `cmake`, `ninja`, `clang`, `clang-cl`, `cl`, and `ccache` are not on `PATH`, and Visual Studio developer environment variables are not set. Opening a Visual Studio Developer PowerShell, or running the PowerShell `Enter-VsDevShell` commands below, makes the shell suitable for the recommended configure/build commands.

## Current recommendation

For this Windows/Codex worktree, use the repo-supported Ninja shape from `CMakeSettings.json` for build-backed Arcopolis exploration. It is the route that has been proven to configure, build `cataclysm-bn-tiles`, and invoke ccache.

Key points:

- Compiler: MSVC `cl.exe`, not Clang.
- Generator: Ninja.
- ccache: append `C:\dev\ccache` to `PATH` after Visual Studio DevShell activation.
- vcpkg: use short temporary roots under `C:\tmp` to avoid Windows path-length failures.
- Known successful game build dir: `out/build/win-rel-deb`.
- Known successful targets: `cataclysm-bn-tiles` and `cata_test-tiles`.
- **Build game + tests in ONE dir (`out/build/win-rel-deb`).** `cataclysm-bn-tiles-common` is a CMake
  OBJECT library shared by both `cataclysm-bn-tiles` and `cata_test-tiles`, so building the test target in
  the same dir reuses the game's compiled objects — only the ~169 test sources recompile + link. To add
  tests to an existing game build dir, re-configure it with `-DTESTS=True` (and `-DJSON_FORMAT=ON`), then
  `cmake --build .\out\build\win-rel-deb --target cata_test-tiles`. A _separate_ `out/build/win-tests` dir
  (used in the older attempts logged below) duplicates the whole ~10 GB object tree and has exhausted the
  disk in this worktree (`fatal error C1085: Cannot write compiler generated file: ... No space left on
  device`) — prefer the shared dir unless you specifically need an isolated test configuration.

Use this PowerShell sequence from `<repo-root>`:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devShellModule = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"

$ccacheDir = "C:\dev\ccache"
if (-not (Test-Path -LiteralPath (Join-Path $ccacheDir "ccache.exe"))) {
    throw "ccache.exe not found at $ccacheDir"
}
$env:PATH = "$env:PATH;$ccacheDir"

cmake -S . -B .\out\build\win-rel-deb -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DCMAKE_PROJECT_INCLUDE_BEFORE="$PWD\build-scripts\windows-tiles-sounds-x64-msvc.cmake" `
  -DCMAKE_TOOLCHAIN_FILE="$PWD\build-scripts\MSVC.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static `
  -DDYNAMIC_LINKING=False `
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON `
  -DCURSES=False `
  -DLOCALIZE=True `
  -DTILES=True `
  -DSOUND=True `
  -DTESTS=False `
  -DJSON_FORMAT=ON `
  -DCMAKE_INSTALL_MESSAGE=NEVER `
  "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"

cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j2
```

The plain `windows-tiles-sounds-x64-msvc` preset is still repository-supported, but in this deep Codex worktree it failed without short vcpkg roots because `sdl3-mixer` generated a 260-character object path. If using that preset, pass the same `VCPKG_INSTALL_OPTIONS` short-root override. The Visual Studio solution generator configured successfully with the short-root override, but the generated `.vcxproj` files did not prove ccache use; Ninja did.

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

| Tool       | Current PATH result               | Version or note                                                         |
| ---------- | --------------------------------- | ----------------------------------------------------------------------- |
| `git`      | `<program-files>\Git\cmd\git.exe` | `git version 2.54.0.windows.1`                                          |
| `cmake`    | Not found                         | VS-bundled CMake exists, but current shell cannot call `cmake` directly |
| `ninja`    | Not found                         | VS-bundled Ninja exists, but current shell cannot call `ninja` directly |
| `clang`    | Not found                         | VS-bundled LLVM `clang.exe` exists                                      |
| `clang-cl` | Not found                         | VS-bundled LLVM `clang-cl.exe` exists                                   |
| `cl`       | Not found                         | VS-bundled MSVC `cl.exe` exists                                         |
| `ccache`   | Not found on PATH                 | Installed outside PATH at `C:\dev\ccache\ccache.exe`, version `4.13.6`  |
| `python`   | Found                             | `Python 3.13.7`                                                         |
| `node`     | Found                             | `v22.19.0`                                                              |
| `deno`     | Found                             | `deno 2.7.12`                                                           |

Important resolved tool paths outside the current PATH:

- CMake: `<vs-install-root>\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`, version `3.31.6-msvc6`
- Ninja: `<vs-install-root>\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe`, version `1.12.1`
- MSVC: `<vs-install-root>\VC\Tools\MSVC\<version>\bin\Hostx64\x64\cl.exe`, compiler banner `19.44.35227 for x64`
- LLVM clang: `<vs-install-root>\VC\Tools\Llvm\x64\bin\clang.exe`, version `19.1.5`
- LLVM clang-cl: `<vs-install-root>\VC\Tools\Llvm\x64\bin\clang-cl.exe`, version `19.1.5`
- vcpkg: `<vs-install-root>\VC\vcpkg\vcpkg.exe`, version `2025-11-19-da1f056dc0775ac651bea7e3fbbf4066146a55f3`
- ccache: `C:\dev\ccache\ccache.exe`, version `4.13.6`

The local ccache directory also contains `cl.exe` and `clang-cl.exe` wrapper names. For this repo's normal MSVC preset, append `C:\dev\ccache` to `PATH` after activating the Visual Studio DevShell instead of prepending it. That lets `find_program(CCACHE_EXE ccache)` discover `ccache.exe` while keeping the real MSVC `cl.exe` first.

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

The public guide's ccache note is directly relevant here: ccache is used automatically only when `ccache` is installed and on `PATH`. On this machine, add `C:\dev\ccache` to `PATH` for the session before configure if you want CMake to bake ccache into generated Ninja build files. The Visual Studio solution generator finds ccache but does not appear to emit ccache launchers into `.vcxproj` files; the repo's `CMakeSettings.json` Ninja workflow does.

## Recommended PowerShell setup commands

Run these from any PowerShell session before configuring:

```powershell
Set-Location "<repo-root>"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devShellModule = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"

$ccacheDir = "C:\dev\ccache"
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
$ccacheDir = "C:\dev\ccache"
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

In this Codex worktree, the plain preset hit a vcpkg/MSVC path-length failure while building `sdl3-mixer`. Use short vcpkg temporary roots for command-line configure:

```powershell
cmake --preset windows-tiles-sounds-x64-msvc "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"
```

For a ccache-backed Windows build, use the repo-supported Ninja shape from `CMakeSettings.json`:

```powershell
cmake -S . -B .\out\build\win-rel-deb -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DCMAKE_PROJECT_INCLUDE_BEFORE="$PWD\build-scripts\windows-tiles-sounds-x64-msvc.cmake" `
  -DCMAKE_TOOLCHAIN_FILE="$PWD\build-scripts\MSVC.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static `
  -DDYNAMIC_LINKING=False `
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON `
  -DCURSES=False `
  -DLOCALIZE=True `
  -DTILES=True `
  -DSOUND=True `
  -DTESTS=False `
  -DJSON_FORMAT=ON `
  -DCMAKE_INSTALL_MESSAGE=NEVER `
  "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"
```

Optional repo setup wrapper:

```powershell
.\setup.ps1
```

`.\setup.ps1` validates prerequisites and runs the same default configure preset. It was not run during this discovery task because it writes build output and may download dependencies. The public guide recommends it as the one-time terminal setup command from plain PowerShell; in this current Codex shell, `cmake` is not on PATH, so activating DevShell first is the more predictable route unless PATH is updated separately.

## Recommended build command

Do not run the build command until configure succeeds. The next build command after a successful configure is:

For an initial backend-capable local build with game and tests:

```powershell
cmake --build --preset windows-msvc-relwithdebinfo --target cataclysm-bn-tiles cata_test-tiles
```

For the full preset target set, including formatter and translations:

```powershell
cmake --build --preset windows-msvc-relwithdebinfo
```

For the ccache-backed Ninja route verified in this worktree, build the game and the tests in the **same**
`win-rel-deb` dir (they share the `cataclysm-bn-tiles-common` OBJECT library — see "Current
recommendation" above; a separate `win-tests` dir duplicates ~10 GB and has exhausted the disk here).
Re-configure the dir with `-DTESTS=True` before building the test target:

```powershell
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
# add tests to the same dir, then build them:
cmake -S . -B .\out\build\win-rel-deb -G Ninja -DTESTS=True   # …plus the same flags as the configure above
cmake --build .\out\build\win-rel-deb --target cata_test-tiles -- -j4
```

## Recommended validation command

Run from the repository root after a successful build:

```powershell
& ".\out\build\windows-tiles-sounds-x64-msvc\tests\RelWithDebInfo\cata_test-tiles.exe"
```

For the ccache-backed Ninja test build (shared `win-rel-deb` dir):

```powershell
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe"
```

Then validate mod loading:

```powershell
& ".\out\build\windows-tiles-sounds-x64-msvc\src\RelWithDebInfo\cataclysm-bn-tiles.exe" --check-mods
```

For the ccache-backed Ninja game build:

```powershell
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --check-mods
```

For a quick executable existence check:

```powershell
Get-ChildItem ".\out\build\windows-tiles-sounds-x64-msvc\src\RelWithDebInfo\cataclysm-bn-tiles.exe"
Get-ChildItem ".\out\build\windows-tiles-sounds-x64-msvc\tests\RelWithDebInfo\cata_test-tiles.exe"
```

## Configure attempts on 2026-05-29

### Attempt 1: Visual Studio preset without short vcpkg roots

Command attempted from `<repo-root>`:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devShellModule = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"

$ccacheDir = "C:\dev\ccache"
if (-not (Test-Path -LiteralPath (Join-Path $ccacheDir "ccache.exe"))) {
    throw "ccache.exe not found at $ccacheDir"
}
$env:PATH = "$env:PATH;$ccacheDir"

where.exe cmake
where.exe cl
where.exe ccache
ccache --version
cmake --preset windows-tiles-sounds-x64-msvc
```

Result:

- Configure failed.
- Visual Studio DevShell activation succeeded.
- `where.exe cmake` resolved Visual Studio's bundled CMake.
- `where.exe cl` resolved the real MSVC `cl.exe` first, then the ccache wrapper `cl.exe` in `C:\dev\ccache`.
- `where.exe ccache` resolved `C:\dev\ccache\ccache.exe`.
- `ccache --version` reported `4.13.6`.
- The configure generated ignored local build artifacts: `CMakeUserPresets.json`, `build-data/gettext/`, and `out/`.
- The configure downloaded and extracted gettext binaries.
- vcpkg downloaded and built several dependencies, then failed while building `sdl3-mixer:x64-windows-static`.

Error:

```text
error: building sdl3-mixer:x64-windows-static failed with: BUILD_FAILED
fatal error C1083: Cannot open compiler generated file: '': Invalid argument
```

The failing vcpkg log was:

```powershell
Get-Content -LiteralPath ".\out\build\windows-tiles-sounds-x64-msvc\vcpkg_installed\vcpkg\blds\sdl3-mixer\install-x64-windows-static-dbg-out.log" -Tail 200
```

The failure occurred during the debug build of an SDL_mixer example object:

```text
examples/CMakeFiles/basics-play-multiple-sounds.dir/basics/03-play-multiple-sounds/play-multiple-sounds.c.obj
```

The compile line in the log used the real Visual Studio MSVC compiler, not `clang`:

```text
<vs-install-root>\VC\Tools\MSVC\<version>\bin\Hostx64\x64\cl.exe
```

Environment readiness:

- Ready for documentation and source-code exploration tasks that do not require a local build.
- Not ready for build-backed code exploration, local test execution, or `--check-mods` until configure completes.

Root cause found:

- The exact failing object path was 260 characters long.
- Microsoft documents `MAX_PATH` as 260 characters for many Win32 paths, and CMake documents `CMAKE_OBJECT_PATH_MAX` because generated object paths can exceed native tool limits.
- vcpkg documents `VCPKG_INSTALL_OPTIONS`, including `--x-buildtrees-root` and `--x-packages-root`, which can move intermediate build files to shorter paths during automatic manifest installs.

Path-length check used:

```powershell
$wd = (Resolve-Path -LiteralPath ".\out\build\windows-tiles-sounds-x64-msvc\vcpkg_installed\vcpkg\blds\sdl3-mixer\x64-windows-static-dbg").Path
$objRel = "examples\CMakeFiles\basics-play-multiple-sounds.dir\basics\03-play-multiple-sounds\play-multiple-sounds.c.obj"
(Join-Path $wd $objRel).Length
```

Result: `260`

Online references checked:

- Microsoft C1083 documentation: <https://learn.microsoft.com/en-us/cpp/error-messages/compiler-errors-1/fatal-error-c1083>
- Microsoft Windows maximum path length documentation: <https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation>
- CMake `CMAKE_OBJECT_PATH_MAX` documentation: <https://cmake.org/cmake/help/latest/variable/CMAKE_OBJECT_PATH_MAX.html>
- Microsoft vcpkg common command options: <https://learn.microsoft.com/en-us/vcpkg/commands/common-options>
- Microsoft vcpkg CMake integration: <https://learn.microsoft.com/en-us/vcpkg/users/buildsystems/cmake-integration>

### Attempt 2: Visual Studio preset with short vcpkg roots

Command attempted from `<repo-root>` after DevShell activation and appending `C:\dev\ccache`:

```powershell
cmake --preset windows-tiles-sounds-x64-msvc "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"
```

Result:

- Configure succeeded.
- vcpkg restored/built all requested packages successfully.
- `sdl3-mixer:x64-windows-static` succeeded when vcpkg used `C:/tmp/cbn-vcpkg-blds-3ca1` and `C:/tmp/cbn-vcpkg-pkgs-3ca1`.
- Build files were written to `out/build/windows-tiles-sounds-x64-msvc`.
- The project uses MSVC `cl.exe`, not `clang`.
- The generated Visual Studio project files did not show ccache launchers, so this route is configured but not proven ccache-backed.

### Attempt 3: Ninja `RelWithDebInfo` with short vcpkg roots and ccache

Command attempted from `<repo-root>` after DevShell activation and appending `C:\dev\ccache`:

```powershell
cmake -S . -B .\out\build\win-rel-deb -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DCMAKE_PROJECT_INCLUDE_BEFORE="$PWD\build-scripts\windows-tiles-sounds-x64-msvc.cmake" `
  -DCMAKE_TOOLCHAIN_FILE="$PWD\build-scripts\MSVC.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static `
  -DDYNAMIC_LINKING=False `
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON `
  -DCURSES=False `
  -DLOCALIZE=True `
  -DTILES=True `
  -DSOUND=True `
  -DTESTS=False `
  -DJSON_FORMAT=ON `
  -DCMAKE_INSTALL_MESSAGE=NEVER `
  "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"
```

Result:

- Configure succeeded.
- vcpkg restored packages from the local binary cache.
- Build files were written to `out/build/win-rel-deb`.
- Generated `build.ninja` contains ccache launchers using `C:/dev/ccache/ccache.exe`, `CCACHE_BASEDIR=<repo-root>`, and `CCACHE_NOHASHDIR=true`.

ccache proof build:

```powershell
$env:CCACHE_LOGFILE = "C:\tmp\cbn-ccache-json-3ca1.log"
cmake --build .\out\build\win-rel-deb --target json_formatter -- -j2
Get-Content -LiteralPath $env:CCACHE_LOGFILE -TotalCount 80
```

Result:

- `json_formatter` built successfully.
- The ccache log was created.
- The log showed `CCACHE 4.13.6 STARTED`.
- The log command line began with `C:/dev/ccache/ccache.exe` wrapping MSVC `cl.exe`.

### Attempt 4: Ninja `cataclysm-bn-tiles` build with ccache

Command attempted from `<repo-root>` after DevShell activation and appending `C:\dev\ccache`:

```powershell
$env:CCACHE_LOGFILE = "C:\tmp\cbn-ccache-tiles-3ca1.log"
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j2
ccache --show-stats
```

Result:

- Build succeeded.
- Built executable: `out/build/win-rel-deb/src/cataclysm-bn-tiles.exe`.
- The executable size was `66800640` bytes after the build.
- The build compiled `452` Ninja steps.
- ccache was active during the build.
- First cold-build ccache stats: `449 / 451` cacheable calls, `449` misses, `0` hits, and cache size about `0.5 GiB`.
- The build emitted MSVC warnings, but no build-stopping errors.
- The build also ran `deno task docs:gen`, which downloaded Deno/npm/jsr packages into local caches and touched generated CLI documentation. The generated tracked CLI doc change was restored after the build, leaving only this Arcopolis environment document as a tracked change.

Environment readiness:

- Ready for documentation and source-code exploration tasks.
- Ready for build-backed exploration using the Ninja `out/build/win-rel-deb` configuration.
- The `cataclysm-bn-tiles` executable builds successfully with MSVC and ccache.
- Test build, test execution, and `--check-mods` remain unverified.

### Attempt 5: Ninja `cata_test-tiles` configure and build with ccache

Configure command attempted from `<repo-root>` after DevShell activation and appending `C:\dev\ccache`:

```powershell
cmake -S . -B .\out\build\win-tests -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DCMAKE_PROJECT_INCLUDE_BEFORE="$PWD\build-scripts\windows-tiles-sounds-x64-msvc.cmake" `
  -DCMAKE_TOOLCHAIN_FILE="$PWD\build-scripts\MSVC.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static `
  -DDYNAMIC_LINKING=False `
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON `
  -DCURSES=False `
  -DLOCALIZE=True `
  -DTILES=True `
  -DSOUND=True `
  -DTESTS=True `
  -DJSON_FORMAT=OFF `
  -DCMAKE_INSTALL_MESSAGE=NEVER `
  "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vcpkg-blds-3ca1;--x-packages-root=C:/tmp/cbn-vcpkg-pkgs-3ca1"
```

Configure result:

- Configure succeeded.
- vcpkg restored all required packages from the local binary cache.
- Build files were written to `out/build/win-tests`.
- CMake warned that `LOCALIZE` was manually specified but not used.
- CMake warned that `astyle` was not found.

Build command attempted:

```powershell
$env:CCACHE_LOGFILE = "C:\tmp\cbn-ccache-tests-3ca1.log"
cmake --build .\out\build\win-tests --target cata_test-tiles -- -j4
ccache --show-stats
```

Build result:

- Build succeeded.
- Built executable: `out/build/win-tests/tests/cata_test-tiles.exe`.
- The executable size was `71727616` bytes after the build.
- The build compiled `613` Ninja steps.
- ccache was active during the build.
- ccache stats after the test build: `1058 / 1061` cacheable calls, `445` hits, `613` misses, `3` uncacheable calls, and cache size about `0.7 GiB`.
- The build emitted MSVC warnings, but no build-stopping errors.

Environment readiness:

- Ready for documentation and source-code exploration tasks.
- Ready for build-backed exploration using the Ninja `out/build/win-rel-deb` and `out/build/win-tests` configurations.
- The `cataclysm-bn-tiles` and `cata_test-tiles` executables both build successfully with MSVC and ccache.
- Test execution and `--check-mods` remain unverified.

Next validation commands:

```powershell
& ".\out\build\win-tests\tests\cata_test-tiles.exe"
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --check-mods
```

## Missing tools or blockers

- Current plain PowerShell is missing direct `cmake`, `ninja`, `cl`, `clang`, and `clang-cl` commands. Activating Visual Studio DevShell fixes this.
- `ccache` is installed at `C:\dev\ccache` outside PATH. Append that directory to `PATH` after DevShell activation for configure/build sessions.
- `CMakeUserPresets.json` now exists as an ignored generated local file after the configure attempt.
- The first Visual Studio preset configure failed during vcpkg dependency resolution for `sdl3-mixer:x64-windows-static` because the generated object path reached 260 characters.
- The Visual Studio preset configure succeeds when `VCPKG_INSTALL_OPTIONS` moves vcpkg buildtrees/packages under `C:\tmp`.
- The Ninja `RelWithDebInfo` configure succeeds and proves ccache is wired into project compile rules.
- The Ninja `RelWithDebInfo` `cataclysm-bn-tiles` build succeeds with ccache.
- The Ninja `RelWithDebInfo` `cata_test-tiles` build succeeds with ccache.
- Test execution and mod validation remain unverified.
- The docs and `setup.ps1` mention `windows-tiles-sounds-x64-msvc-tracy`, but that configure preset was not present in the current `CMakePresets.json`. The Visual Studio IDE `CMakeSettings.json` does include a `Tracy` configuration.
- The worktree is detached at `HEAD`. Before code work, create or switch to a branch.

## Questions for the user

- Do you want Arcopolis backend experiments to use the terminal CMake preset workflow, the Visual Studio IDE workflow, or both?
- Should the first real build use `RelWithDebInfo` as the default, or should Arcopolis backend work start with `Debug`?
- Should `C:\dev\ccache` stay session-only, or should it be added permanently to user PATH outside this repository?

## Next Codex task

Concrete next step: run the test executable, or run an Arcopolis-relevant test filter, then validate mod loading.

```powershell
& ".\out\build\win-tests\tests\cata_test-tiles.exe"
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --check-mods
```
