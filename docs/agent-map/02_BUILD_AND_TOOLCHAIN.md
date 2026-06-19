# Build & toolchain — navigation

> Practical starting points, not a full build manual. The authoritative guide is
> `docs/en/dev/guides/building/cmake.md`; Windows/Arcopolis specifics live in `AGENTS.md` and
> `docs/arcopolis/00_WINDOWS_LOCAL_ENVIRONMENT.md`.

## Language & CMake

- **CMake ≥ 3.24** (`CMakeLists.txt:1`).
- **C++23**, required, no GNU extensions (`CMakeLists.txt:318-320`:
  `set(CMAKE_CXX_STANDARD 23)` / `CMAKE_CXX_STANDARD_REQUIRED ON` / `CMAKE_CXX_EXTENSIONS OFF`).

## Presets & build directories

- Cross-platform presets are in `CMakePresets.json` (configure + build). Examples: `linux-full`
  (the devteam canonical Linux build, `CMakePresets.json:101-134`), `linux-slim`, `ci-tiles`,
  `ci-curses`, `windows-tiles-sounds-x64-msvc`.
- Windows Visual Studio / Ninja shapes are in `CMakeSettings.json` — e.g. the `RelWithDebInfo`
  config builds into `out/build/win-rel-deb` (`CMakeSettings.json:26-46`). This is the build dir
  AGENTS.md uses for local Windows work.

## Main targets

| Target               | What                   | Where                                  |
| -------------------- | ---------------------- | -------------------------------------- |
| `cataclysm-bn-tiles` | Game, SDL3 tiles build | `src/CMakeLists.txt:134-210`           |
| `cataclysm-bn`       | Game, curses build     | `src/CMakeLists.txt:213-253`           |
| `cata_test-tiles`    | Catch2 tests (tiles)   | `tests/CMakeLists.txt:16-35`           |
| `cata_test`          | Catch2 tests (curses)  | `tests/CMakeLists.txt:37-54`           |
| `json_formatter`     | JSON formatter tool    | `tools/format/` (option `JSON_FORMAT`) |
| `translations`       | compiled `.mo` files   | `lang/`                                |

The game and tests **share one object library** `cataclysm-bn-tiles-common` (a CMake `OBJECT`
library, `src/CMakeLists.txt:135-138`), which `cata_test-tiles` links against
(`tests/CMakeLists.txt:18`). Building the game and tests in the **same** build dir reuses those
objects — see `AGENTS.md:156` (do not create a second test-only build dir).

## Canonical commands

Linux (from `AGENTS.md:371-375` / `docs/en/dev/guides/building/cmake.md`):

```sh
cmake --preset linux-full
cmake --build --preset linux-full --target cataclysm-bn-tiles cata_test-tiles
```

Windows: this workflow uses **PowerShell** (`AGENTS.md:59`) with the VS 2022 DevShell, MSVC, Ninja,
and vcpkg, building into `out/build/win-rel-deb`. See `AGENTS.md:147-167` for the exact local setup
(including the `ccache` and `astyle` `PATH` additions).

## Dependencies & package manager

- Windows uses a **vcpkg manifest**: `msvc-full-features/vcpkg.json` — `sdl3` (vulkan),
  `sdl3-image`, `sdl3-mixer`, `sdl3-shadercross`, `sdl3-ttf`, `sqlite3`, `zlib`.
- Linux/macOS discover SDL3 etc. via system packages or a CMake FetchContent fallback
  (`CMakeLists.txt:399-415`).
- Tiles builds need compiled shaders: `SDL_shadercross` compiles `src/shaders/*.hlsl` into
  `data/shaders/*` at configure/build time (`CMakeLists.txt:516-622`). Those outputs are generated —
  see [`04_RISK_ZONES.md`](04_RISK_ZONES.md).
- Linux canonical toolchain: `clang`/`clang++` + `mold` linker + `ccache`
  (`CMakePresets.json:38-53`); the docs require clang ≥ 22 (`docs/en/dev/guides/building/cmake.md`).

> Note (uncertain / doc drift): `docs/en/dev/guides/building/cmake.md` still lists **SDL2** in its
> prerequisites, but the actual build (vcpkg manifest, CMake FetchContent) uses **SDL3**
> (`msvc-full-features/vcpkg.json`, `CMakeLists.txt:404`). Trust the build files.

## `compile_commands.json` (symbol navigation)

- Every preset sets `CMAKE_EXPORT_COMPILE_COMMANDS=ON` (e.g. `CMakePresets.json:50`), so configuring
  any preset emits `compile_commands.json` into that build dir. `.clangd` is present, so clangd is
  the intended LSP consumer.
- **Local convenience / caveat (not repo truth):** on this workstation a database already exists at
  `out/build/win-rel-deb/compile_commands.json` (an MSVC `cl.exe`, `-std:c++latest` tiles DB). It
  reflects whatever the local build tree was configured from — useful for navigation, but it is a
  build artifact, not a checked-in source of truth, and may lag the current branch.

## Running tests

- The Catch2 binaries are run **from the repo root** (working dir must contain `data/`), with
  `--rng-seed time` (`tests/CMakeLists.txt:21-24`). The test exe locates `data/shaders/...` and the
  Lavapipe ICD relative to its CWD — see `AGENTS.md:159-165` for the Windows `Start-Process` pattern.
- Filter example (Arcopolis tag): `cata_test-tiles "[arcopolis]"`.

## Formatting & linting (pointers)

- **C++ format:** AStyle via the CMake `format` target, or directly
  `AStyle.exe --options=.astylerc -n <files>` (`AGENTS.md:153`); config `.astylerc`.
  `.clang-format` is also present.
- **JSON:** the `json_formatter` target / `style-json*` CMake targets (`AGENTS.md:362-367`); validate
  mods with `--check-mods` and `build-scripts/lint-json.sh` (`AGENTS.md:384-387`).
- **Scripts/docs:** `deno fmt` / `dprint` (`deno.jsonc`); note `.claude/worktrees` is excluded from
  `deno fmt` (`deno.jsonc:33`).
- **Static analysis:** clang-tidy with a custom `cata-*` plugin (`.clang-tidy`,
  `tools/clang-tidy-plugin/`, `.github/workflows/clang-tidy.yml`).

CI wiring (kept minimal here): `.github/workflows/build.yml` and `.github/workflows/matrix.yml`
drive the multi-platform build/test matrix; read those for exact CI invocations.

> Deferred: a standalone testing/quality doc (`03`) is out of scope for this v0 — the pointers above
> are enough to navigate.
