# Arcopolis Windows Coverage Feasibility

## Status and scope

This is a **real local feasibility spike** (Spike 22), not a docs-only audit. It ran
local probes on a Windows workstation to decide which Windows-first coverage path
Arcopolis should use next. It compares only two paths:

- **A. MSVC / Visual Studio native code coverage**
- **B. Windows LLVM 22.1.7 source-based coverage**

WSL is explicitly **not** investigated here and is mentioned only as a possible future
fallback.

**Outcome in one line:** Path A is **not usable** on this machine (VS Community lacks the
native C++ coverage collector); Path B **works end-to-end** — a clang-cl instrumented
`cata_test-tiles` ran the `[arcopolis]` suite, the instrumented **game** binary ran all nine
fixture regressions, and together they produced real, source-mapped per-file coverage
(**89.27% region / 86.75% line** on the Arcopolis-owned files, combined — Section 6).
**Path B is recommended.**

Tested checkout:

- Worktree branch `claude/magical-euler-417842` at commit `8f1cc5c4bd` (`docs(arcopolis):
  ... fixture pack (#55)` is HEAD), branched off `arcopolis`.
- Main checkout on branch `arcopolis` (same HEAD lineage); its build tree under
  `out/build/win-rel-deb` was used **read-only** and never reconfigured.

Machine / tool constraints known to this spike:

- Windows-first (PowerShell 7).
- **Disk pressure is a first-class constraint**: ~12–21.3 GB free on `C:` across the spike
  (the ~12 GB floor was during the 47-launch regression batch), against an existing normal
  build of **8.92 GB**. The Path B coverage build was sized to **3.96 GB** (debug info
  disabled; test + game targets) to fit; `win-rel-deb` was preserved.
- LLVM tools are installed at **22.1.7** (`clang`, `clang++`, `clang-cl`, `llvm-profdata`,
  `llvm-cov`) under `C:\Program Files\LLVM\bin`.
- Visual Studio 2022 **Community** edition is installed.
- The known-good normal build dir `out/build/win-rel-deb` was preserved (not converted to
  a coverage build, not reconfigured).

This spike adds **no CI coverage gate** and **no repo-wide coverage percentage target**.
It changes no C++ runtime behavior, no Arcopolis protocol/command semantics, and no
regression expectations.

## 1. Why this spike exists

- PR #54 (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md`) **mapped** the test layers and a
  source-audited coverage matrix, but explicitly did **not** measure line, branch, or
  function coverage, and recommended a local measured-coverage recipe scoped to the
  Arcopolis seam as the next step (`44_TEST_COVERAGE_AUDIT.md` §5–6).
- PR #55 committed the canonical fixture pack under
  `docs/arcopolis/fixtures/arcopolis_user/`, making regression inputs reproducible and
  repo-local.
- This spike answers the **practical** follow-up: which Windows coverage path is actually
  usable here, at what disk cost, and is the source/line data usable for the
  Arcopolis-owned files and nearby seam files?

## 2. Baseline environment

| Item                                 | Observed value                                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Worktree branch / commit             | `claude/magical-euler-417842` @ `8f1cc5c4bd` (off `arcopolis`)                                               |
| Main checkout branch                 | `arcopolis`                                                                                                  |
| Free disk on `C:` (spike window)     | floor ~12 GB (during the 47-launch regression batch), ceiling ~21.3 GB; watchdog floor 2.5 GB never tripped  |
| Normal build size (`win-rel-deb`)    | **8.92 GB** (preserved — never reconfigured or rebuilt)                                                      |
| Coverage build (`win-llvm-cov`)      | **3.96 GB** (clang-cl, debug info disabled; `cata_test-tiles` 3.09 GB + game `cataclysm-bn-tiles` target)    |
| Other `out/` entries                 | `arco_*_regress` regression sandboxes only (small; not build dirs; not reclaimable)                          |
| `clang` / `clang++` / `clang-cl`     | LLVM **22.1.7** — `C:\Program Files\LLVM\bin`                                                                |
| `llvm-profdata` / `llvm-cov`         | LLVM **22.1.7** — `C:\Program Files\LLVM\bin`                                                                |
| Visual Studio                        | 2022 **Community** — `C:\Program Files\Microsoft Visual Studio\2022\Community`                               |
| `Microsoft.CodeCoverage.Console.exe` | **ABSENT** (not on PATH; full recursive search of the VS install found none)                                 |
| Classic `CodeCoverage.exe` collector | **ABSENT**                                                                                                   |
| Native collector engine              | `Microsoft.VisualStudio.TraceDataCollector.dll` / `covrun*` **ABSENT**                                       |
| `VSInstr.exe`                        | present — `...\Team Tools\DiagnosticsHub\Collector\VSInstr.exe` (static-instrument half only)                |
| `vstest.console.exe`                 | present (TestWindow + TestPlatform); `Microsoft.CodeCoverage.IO.dll` present (`.coverage` file I/O lib only) |
| `dotnet-coverage` global tool        | not installed; no `Microsoft.CodeCoverage` NuGet cache                                                       |
| Existing `cata_test-tiles.exe`       | only `out/build/win-rel-deb/tests/cata_test-tiles.exe` (main checkout); worktree has no `out/`               |
| Existing CI coverage gate            | **none** (no `coverage`/`codecov`/`gcov`/`llvm-cov`/`profdata` references in `.github/workflows/*`)          |
| `out/` tracked in git                | no — `.gitignore:91` ignores `out/`                                                                          |

## 3. Checkpoint log

### Checkpoint 1 — after tool/disk discovery

- **Branch/commit**: worktree `claude/magical-euler-417842` @ `8f1cc5c4bd`; main checkout
  on `arcopolis`. Worktree clean.
- **Free disk**: ~19.8–21.3 GB free on `C:` (fluctuating). **Normal build**:
  `out/build/win-rel-deb` = **8.92 GB**.
- **LLVM**: 22.1.7 confirmed for all five tools.
- **`Microsoft.CodeCoverage.Console`**: **absent**; the entire native VS coverage
  _collection_ toolchain is absent on this Community install (only `VSInstr.exe`, the
  static-instrument half, and the `.coverage` I/O lib are present).
- **Test binary**: only the main checkout's `win-rel-deb` exe exists.
- **Decision — MSVC probe safe?** Yes to _probe_ (read-only `--help`/banner and a
  non-destructive `vstest` attempt). But the collector is already known absent, so the
  probe is expected to confirm "not usable", not to produce coverage.
- **Decision — LLVM build safe later?** A **full instrumented engine build is NOT safe**
  to attempt (8.92 GB normal build + a cold, preset-less clang-cl duplicate would crowd
  ~20 GB free, with high failure risk and garbage-on-failure). A **tiny LLVM toolchain
  proof** (single sample file) IS safe and will be used to prove the path end-to-end.
- **Continuing safe?** Yes — next steps (Phase 1 read-only probes, then a tiny Phase 2
  sample) do not touch `win-rel-deb` and cost ~MB.

### Checkpoint 2 — after MSVC probe

- **Commands**: `Microsoft.CodeCoverage.Console --help` (absent); `VSInstr.exe` banner
  (present, instrument-only); `vstest.console cata_test-tiles.exe --collect:"Code Coverage"`
  (collector not found; Catch2 exe not a test container).
- **Result**: collection did **not** run; no `.coverage` produced.
- **Artifacts generated locally**: none (`out/coverage-msvc` empty).
- **Source mapping usable?** N/A — nothing collected.
- **Disk impact**: ~0; `win-rel-deb` untouched.
- **Verdict**: **not usable** on VS Community (missing native collector + wrong harness
  shape). Not "maybe usable with a profile build".
- **Continuing to LLVM safe?** Yes — Path A produced nothing on disk and touched nothing.
  Proceed to the Phase 2 decision (Checkpoint 3).

### Checkpoint 3 — before any LLVM coverage build (decision point)

Explicit decisions required before configuring/building:

- **Enough free disk?** No safe margin. ~21.2 GB free vs an existing 8.92 GB normal build.
  A cold, instrumented (coverage objects run larger) duplicate of the engine object
  library + `cata_test-tiles` plausibly lands at ~9–15 GB, and a fresh build dir may
  re-trigger a vcpkg dependency restore (SDL3/sqlite3/zlib). A failed partial build would
  leave multi-GB garbage on an already-pressured disk.
- **Is a separate full build justified after the MSVC result?** The _goal_ (a real
  `[arcopolis]` line/region report) would justify it. Toolchain-wise it is feasible:
  `clang-cl` is a cl.exe-compatible driver (the §5.1 sample built a Windows binary with
  `clang++`), so a coverage build only needs a compiler override + coverage flags on top of
  the existing MSVC/vcpkg setup — the repo just hardwires `cl.exe` today
  (`build-scripts/MSVC.cmake:56-57`) and has no clang Windows preset/CI job. The decisive
  blocker is **disk**, not the toolchain.
- **Decision: DO NOT run the full instrumented build in this spike.** Instead, prove the
  LLVM coverage _toolchain_ end-to-end with a **tiny sample** (single `.cpp`, ~MB) so the
  path is demonstrated without the disk/toolchain risk. The full-build integration is
  deferred to a dedicated PR with a precise plan (Section 9).
- **Build dir that _would_ be used (not executed here):** `out/build/win-llvm-cov`;
  profiles → `out/coverage-llvm`. Both separate from `win-rel-deb`.
- **Cleanup plan if a full build were attempted and failed:**
  `Remove-Item -Recurse -Force out\build\win-llvm-cov, out\coverage-llvm`; never touch
  `win-rel-deb`.
- **Continuing safe?** Yes — the tiny sample writes only to `out/coverage-llvm` and costs
  ~MB.

### Checkpoint 3b — user directed running the build (decision reversed)

After Checkpoint 3, the user explicitly instructed running the full build and tests,
accepting the disk cost. The build proceeded into `out/build/win-llvm-cov` under a hard
disk watchdog (abort if free `C:` < 3.5 GB) with `win-rel-deb` left untouched. Outcome:
**success** — see Checkpoint 4 and Section 5.

### Checkpoint 4 — after the real `[arcopolis]` coverage run

- **What binary was run**: the **instrumented `cata_test-tiles.exe`** (349 MB) built with
  clang-cl 22.1.7 + `-fprofile-instr-generate -fcoverage-mapping` in `out/build/win-llvm-cov`
  (one `demangle.cpp` / `cxxabi.h` build shim needed — Section 5.2).
- **What tests were run**: `cata_test-tiles "[arcopolis]"` → **143 test cases, 920
  assertions, all passed**, exit 0; SDL_GPU on llvmpipe (software, headless).
- **Profile/report files generated locally**: `arco-<pid>.profraw` (197 MB) →
  `arco.profdata` (21 MB) → filtered `llvm-cov report` + HTML, under `out/coverage-llvm`.
- **Arcopolis coverage** (region/line): command 91.95%/91.93%, backend_input 85.47%/82.37%,
  session_log 71.32%/73.85%, script 63.94%/53.50%, live 38.02%/37.10%, **export 0%/0%**
  (Catch2 never exercises export — that is fixture-regression territory).
- **Source mapping usable?** **Yes** — exact per-file region/line/branch/function on the
  real Windows source paths; HTML line view generated.
- **Disk impact**: build dir `win-llvm-cov` = **3.09 GB** (debug info disabled);
  `out/coverage-llvm` = 229 MB; `win-rel-deb` unchanged (8.92 GB, exe mtime intact); free
  `C:` 21.2 → 18.0 GB (peak draw ~3.3 GB; watchdog never neared 3.5 GB).
- **Cleanup/untracked status**: all artifacts under `out/` (gitignored, `.gitignore:91`) and
  `C:\tmp` scratch; nothing staged.
- **Continuing safe?** Yes. Feasibility is answered with real numbers; remaining work is docs.

### Checkpoint 5 — before final commit

- **Only two files changed** (worktree `git status --short`): `M AGENTS.md`,
  `?? docs/arcopolis/45_WINDOWS_COVERAGE_FEASIBILITY.md`. AGENTS.md diff is solely the new
  "Arcopolis coverage claims" block.
- **No coverage artifacts tracked**: `git ls-files` for `*.profraw`/`*.profdata`/`*.coverage`/
  `out/*` is empty; `out/` is gitignored.
- **No C++ source changed** (in this spike's commit). The `demangle.cpp` portability gap was
  handled with an empty `cxxabi.h` shim on the build `INCLUDE` path (under `C:\tmp`), not a
  source edit. The clean one-line fix was left as a recommended follow-up (Section 9) and
  **has since landed in PR #58**.
- **No regression expectations changed**; no regression script modified.
- **`win-rel-deb` not converted**: the coverage build is a separate `out/build/win-llvm-cov`
  dir; the normal build's exe mtime is unchanged. The main checkout has no tracked-file
  changes from the build.
- **Formatting**: `deno fmt` (lineWidth 100, proseWrap preserve) was applied to both files
  via temp copies, because `.claude/worktrees` is in the deno fmt exclude (deno.jsonc:34).
- **Continuing safe?** Yes — ready to finalize.

### Checkpoint 6 — after the fixture-regression coverage run

- **Game binary instrumented + 9 regressions run** under `$env:LLVM_PROFILE_FILE`; all exit 0
  (47 launches). `regress.profdata` 21.5 MB; combined-with-tests `combined.profdata` 21.9 MB.
  Real coverage produced (Section 6.3/6.4) — e.g. `arcopolis_export.cpp` 0% → 74.70% region.
- **Local source edit reverted.** The `main.cpp` `__llvm_profile_write_file` flush hook (6.2)
  was `git checkout`-reverted; the main checkout is verified clean (`git status --porcelain`
  shows only the untracked `.claude/` worktree dir, no tracked changes). Nothing committed.
- **No regression script or expectation changed.** Coverage came from the existing `-Exe`
  hook plus the env var only.
- **Disk:** coverage build now 3.96 GB; free `C:` floored ~12 GB during the batch (watchdog
  floor 2.5 GB never tripped); per-regression raws were merged-then-deleted.
- **Continuing safe?** Yes — Section 6 carries the measured numbers; only docs to commit.

## 4. MSVC / Visual Studio coverage probe

**Goal:** determine whether the existing (or minimally adjusted) MSVC test binary can
yield useful native coverage via Microsoft's first-party tooling.

**Commands attempted** (all read-only against the existing binary; scratch output dir
`out/coverage-msvc`):

```powershell
# (1) modern standalone collector
& Microsoft.CodeCoverage.Console --help
#   -> 'Microsoft.CodeCoverage.Console' is not recognized ... (ABSENT)

# (2) static post-link instrumenter (banner only, no target)
& "...\Team Tools\DiagnosticsHub\Collector\VSInstr.exe"
#   -> "Microsoft (R) VSInstr Post-Link Instrumentation 17.14.37127.6 x64"
#      Usage: VSInstr filename [options]   (present, but INSTRUMENT half only)

# (3) classic collector path via vstest
& vstest.console.exe cata_test-tiles.exe "--collect:Code Coverage" "--ResultsDirectory:out\coverage-msvc"
#   -> "Unable to find a datacollector with friendly name 'Code Coverage'."
#      "Could not find data collector 'Code Coverage'"
#      "No test is available in ...cata_test-tiles.exe."
#      exit 0, NO .coverage file produced
```

**Results**

- **Did collection run?** No. The native **Code Coverage data collector is absent** on
  this VS 2022 **Community** install. A full recursive search of the VS install found
  **no** `Microsoft.CodeCoverage.Console.exe`, **no** classic `CodeCoverage.exe`, and
  **no** `Microsoft.VisualStudio.TraceDataCollector.dll` / `covrun*` native collection
  engine. Only `VSInstr.exe` (static-instrument half) and `Microsoft.CodeCoverage.IO.dll`
  (the `.coverage` file-format I/O library) are present.
- **Did it see native modules / map to source / include Arcopolis files?** N/A — nothing
  was collected.
- **Is `/PROFILE` / static instrumentation required?** Static instrumentation
  (`VSInstr /COVERAGE`) is the only piece present, but it is useless without the
  collection runtime, and it would require modifying a **copy** of the binary plus
  shipping the coverage monitor DLLs that are absent here. There is no point building a
  separate MSVC `/PROFILE` profile build: even a perfectly instrumented binary has no
  collector to read it on this edition.
- **`vstest` shape problem (independent of edition).** Even with a collector,
  `vstest.console` discovers tests inside _test containers_ via adapters; `cata_test-tiles`
  is a **Catch2 console exe**, which vstest reports as having "no test available". The only
  Microsoft tool that can wrap an arbitrary process for native coverage is
  `Microsoft.CodeCoverage.Console.exe` (`collect -- <exe> <args>`) — and that is the tool
  that is absent.
- **Output files generated locally:** none (`out/coverage-msvc` stayed empty).
- **Disk / time cost:** ~0 (no artifacts); a few seconds.

**Verdict: NOT USABLE on this machine.** Two independent blockers: the native C++
coverage _collector_ is an Enterprise-edition feature missing from Community, and the
only Community-present wrapper (`vstest`) cannot drive a Catch2 console exe. Making
Path A work would require VS **Enterprise** (license cost) or a third-party native
coverage tool (e.g. OpenCppCoverage) — out of scope for this spike (no third-party
dependencies; comparison restricted to A vs B). **Not "maybe usable with a profile
build"** — a profile build does not supply the missing collector.

## 5. Windows LLVM 22.1.7 coverage probe

**Goal:** determine whether a Windows LLVM source-based coverage build can produce usable
source coverage for Arcopolis tests, and whether the toolchain (instrument → run →
`profraw` → `profdata` → `llvm-cov`) works on this machine with usable source mapping.

**Outcome: full success.** A clang-cl instrumented `cata_test-tiles` was built, the
`[arcopolis]` Catch2 suite ran under it, and real per-file region/line/branch/function
coverage was produced for the Arcopolis-owned files and nearby seam files.

### 5.1 Toolchain pre-check (tiny sample)

Before the large build, a single throwaway `.cpp` confirmed the pipeline end-to-end:
`clang++ -fprofile-instr-generate -fcoverage-mapping` → run → `llvm-profdata merge` →
`llvm-cov report`/`show` produced exact per-line counts (Regions 90.91%, with the one
unexercised branch correctly flagged) and resolved the Windows source path. ~10 MB, seconds.

### 5.2 Full instrumented `cata_test-tiles` build (clang-cl 22.1.7)

clang on Windows is viable: `clang-cl` is a cl.exe-compatible driver and is the same
compiler family already used in Linux CI — the clang presets `ci-curses` and `ci-tiles`
(`.github/workflows/matrix.yml:82,91`).
The repo hardwires `cl.exe` for Windows (`build-scripts/MSVC.cmake:56-57`) with no clang
preset, so the build reused the proven MSVC/vcpkg setup and only swapped the compiler:

- A scratch toolchain (a copy of `MSVC.cmake`) set
  `CMAKE_C/CXX_COMPILER = C:/Program Files/LLVM/bin/clang-cl.exe`, added
  `/clang:-fprofile-instr-generate /clang:-fcoverage-mapping`, and **disabled debug info**
  (`CMAKE_MSVC_DEBUG_INFORMATION_FORMAT ""`). Source-based coverage uses the embedded
  `__llvm_covmap`, not PDB, so dropping debug info cut the build to **3.09 GB** (vs
  `win-rel-deb`'s 8.92 GB).
- Configure (Ninja + VS DevShell + `$env:VCPKG_ROOT` = the VS-bundled vcpkg) restored vcpkg
  from the binary cache in < 1 s; `cata_test-tiles` and all six Arcopolis TUs compiled
  cleanly under clang-cl (only benign warnings; `/WX-` keeps them non-fatal).
- **Two fixes were needed, both build-environment only — no tracked source changed:**
  1. **Profile runtime at link.** CMake drives the linker as `lld-link` _directly_ (not via
     the clang-cl driver), so a `/clang:-fprofile-instr-generate` link flag is rejected. Fix:
     link `clang_rt.profile-x86_64.lib` as a plain input lib (8.3 short path
     `C:/PROGRA~1/LLVM/...` to dodge the space in "Program Files").
  2. **`demangle.cpp` + `cxxabi.h`.** `demangle.cpp:3` includes `<cxxabi.h>` under
     `#if defined(__GNUC__) || defined(__clang__)`, but **clang-cl defines `__clang__` while
     using the MSVC STL, which has no `cxxabi.h`**. The actual `abi::__cxa_demangle` calls
     sit behind a `#if defined(_MSC_VER)`-first guard, so under clang-cl they are never
     compiled — the header is unused. Fix used here (at spike time): an **empty `cxxabi.h`
     shim** on the build `INCLUDE` path (no source edit). The clean one-line guard,
     `#if (defined(__GNUC__) || defined(__clang__)) && !defined(_MSC_VER)`, **has since landed
     in `src/demangle.cpp` (PR #58)** — so a clang-cl build now compiles `demangle.cpp`
     directly and the shim is no longer required; it is kept here only as the spike's original
     method.

Build: `cmake --build out/build/win-llvm-cov --target cata_test-tiles -- -j4` → exit 0,
`tests/cata_test-tiles.exe` (349 MB). `win-rel-deb` was untouched throughout (exe mtime
unchanged). The instrumented binary also passes the **full** suite, not just `[arcopolis]`:
`cata_test-tiles` with no filter → **957 test cases, 6,710,889 assertions, all passed**
(exit 0), confirming the clang-cl coverage build is sound engine-wide (whole-suite coverage
not collected — out of scope; the profile was routed to scratch and deleted).

### 5.3 Running `[arcopolis]` and the coverage result

```powershell
$env:LLVM_PROFILE_FILE = "...\out\coverage-llvm\arco-%p.profraw"
# child cwd = repo root so SDL_GPU finds data/shaders + the lavapipe ICD
Start-Process ...\win-llvm-cov\tests\cata_test-tiles.exe -ArgumentList "[arcopolis]" `
  -WorkingDirectory <repo-root> -Wait
llvm-profdata merge -sparse out\coverage-llvm\arco-*.profraw -o out\coverage-llvm\arco.profdata
llvm-cov report ...\win-llvm-cov\tests\cata_test-tiles.exe -instr-profile=...\arco.profdata <files>
```

Run: **143 test cases, 920 assertions, all passed** (exit 0); one 197 MB `.profraw` merged
to a 21 MB `.profdata`.

> **Running the suite headless (llvmpipe vs CPU).** The `[arcopolis]` subset passes on either
> compute backend, but the **full** `cata_test-tiles` suite must run on the llvmpipe software-GPU
> backend — `CATA_TEST_COMPUTE_ACCELERATION=cpu` fails the `[vision]`/`[shadowcasting]` cases (their
> light grids are calibrated for llvmpipe). The canonical run procedure (pin `VK_ICD_FILENAMES`,
> leave `CATA_TEST_COMPUTE_ACCELERATION` unset) lives in
> [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md) → "Running the FULL suite needs
> the llvmpipe software-GPU backend".

**Arcopolis-owned coverage** (`llvm-cov report`, real numbers):

| File                        | Region | Function |   Line | Branch |
| --------------------------- | -----: | -------: | -----: | -----: |
| arcopolis_command.cpp       | 91.95% |  100.00% | 91.93% | 91.67% |
| arcopolis_backend_input.cpp | 85.47% |   91.23% | 82.37% | 73.78% |
| arcopolis_session_log.cpp   | 71.32% |   90.32% | 73.85% | 64.15% |
| arcopolis_script.cpp        | 63.94% |   57.14% | 53.50% | 60.39% |
| arcopolis_live.cpp          | 38.02% |   60.00% | 37.10% | 40.43% |
| arcopolis_export.cpp        |  0.00% |    0.00% |  0.00% |  0.00% |
| **TOTAL**                   | 63.06% |   76.47% | 56.96% | 58.91% |

**Nearby engine seam files** (whole-file %, so seam-only hits read low — do **not** read
whole-file meaning into these):

| File              | Region |   Line | Note                                         |
| ----------------- | -----: | -----: | -------------------------------------------- |
| popup.cpp         | 44.51% | 37.69% | query_popup backend transaction exercised    |
| ui.cpp            | 28.40% | 28.41% | uilist backend transaction exercised         |
| input.cpp         | 16.83% | 14.40% | registered-input path                        |
| output.cpp        |  3.82% |  6.45% |                                              |
| game.cpp          |  0.97% |  1.29% | huge file; only the backend seam is hit      |
| iexamine.cpp      |  0.11% |  1.48% |                                              |
| handle_action.cpp |  0.00% |  0.00% | Catch2 tests bypass full action dispatch     |
| pickup.cpp        |  0.00% |  0.00% | exercised by fixture regressions, not Catch2 |

**What the numbers reveal (the point of measuring):** the Catch2 `[arcopolis]` suite covers
the command parser, backend-input state machine, and session-log formatting well, but
**does not touch `arcopolis_export.cpp` at all (0%)**, nor `handle_action`/`pickup`. Those
are exercised by the PowerShell fixture regressions that drive the _game_ binary — exactly
the split doc 44 described, now measured. The uncovered regions in `arcopolis_live.cpp`
(38%) and `arcopolis_script.cpp` (64%) are concrete next witnesses to add.

- **Source / path mapping usable?** **Yes** — per-file region/line/branch/function on the
  real Windows source paths; a filtered HTML line-view was also generated
  (`out/coverage-llvm/html/index.html`).
- **Disk / time:** build dir 3.09 GB at this point (the game target added in Section 6 brings
  it to 3.96 GB); `out/coverage-llvm` 229 MB; the instrumented suite itself reports 0.023 s
  (the rest of wall-clock is world load). `win-rel-deb` untouched.

**Verdict: the Windows LLVM 22.1.7 source-based path WORKS end-to-end** and yields exactly
the Arcopolis-scoped, source-mapped coverage this spike set out to test. This is the
recommended path (Section 7).

## 6. Fixture regression coverage probe

**Run under coverage in this spike** (a follow-up the user directed after the initial probe).
The original draft left this unrun; it was then carried out. The **game** binary
`cataclysm-bn-tiles` was instrumented the same clang-cl way (Section 5.2), all nine
PowerShell fixture regressions were run under `$env:LLVM_PROFILE_FILE`, and the profiles were
merged. This fills the Catch2 blind spots Section 5.3 predicted — most importantly
`arcopolis_export.cpp`, which is **0% under Catch2 but 74.70% region / 85.71% line** under the
regressions.

### 6.1 What was run

- **Game-binary instrumented build.** `cmake --build out/build/win-llvm-cov --target
  cataclysm-bn-tiles` (same scratch toolchain, debug info off). Adding the game target grew
  the shared build dir from 3.09 GB to **3.96 GB**. `win-rel-deb` was untouched.
- **All nine regressions via the existing `-Exe` hook** — no script edited. Each ran as
  `pwsh -File docs\arcopolis\<name>_regression.ps1 -Exe ...\win-llvm-cov\src\cataclysm-bn-tiles.exe`
  from the repo root, under `$env:LLVM_PROFILE_FILE=...\regress-%p.profraw`. All passed
  (exit 0); **47 game launches** total (movement 3, item_export 1, npc_export 2,
  monster_export 1, examine 4, prompt_menu 18, query_popup 4, script_prompt 12,
  live_protocol 2).
- **Disk discipline.** Each launch writes a full ~206 MB `.profraw`; the batch merged each
  regression's raws into `regress.profdata` immediately and deleted them, so peak extra disk
  stayed ~3.7 GB (during the 18-launch prompt_menu) and free `C:` never dropped below ~12 GB
  (watchdog floor 2.5 GB, never tripped).

### 6.2 One local, reverted source edit was required (and why)

The `--arcopolis-*` modes exit via `std::_Exit` (`src/main.cpp`), which **skips the LLVM
profile writer's `atexit` handler** — so an unmodified instrumented game binary writes a
**0-byte** `.profraw`. (LLVM's `%c` continuous-write marker does **not** fix this on Windows;
that needs the build-time `-fprofile-continuous` flag, confirmed against the LLVM docs.) The
minimal fix used was a **local, never-committed** edit to `src/main.cpp`: an explicit
`__llvm_profile_write_file()` call before each `std::_Exit`, guarded by
`#if defined( ARCO_COV_FLUSH )` and compiled only with `$env:CL="/DARCO_COV_FLUSH"`. It is
behaviour-neutral in any normal build (the block compiles to nothing) and **was reverted
immediately after the run** (`git checkout -- src/main.cpp`; main checkout verified clean).
No runtime behavior was changed in any committed artifact. A committable, guarded flush hook
is listed as a follow-up (Section 9) — a real decision, not taken in this docs PR.

### 6.3 Regression-only coverage (game binary, `regress.profdata`)

| File                        | Region | Function |   Line | Branch |
| --------------------------- | -----: | -------: | -----: | -----: |
| arcopolis_command.cpp       | 60.92% |  100.00% | 53.42% | 55.56% |
| arcopolis_backend_input.cpp | 78.69% |   92.98% | 75.03% | 59.76% |
| arcopolis_session_log.cpp   | 75.00% |   93.55% | 80.86% | 59.43% |
| arcopolis_script.cpp        | 78.85% |   85.71% | 59.24% | 68.18% |
| arcopolis_live.cpp          | 80.51% |   95.00% | 74.63% | 67.39% |
| arcopolis_export.cpp        | 74.70% |  100.00% | 85.71% | 64.06% |
| **TOTAL**                   | 77.26% |   94.12% | 73.91% | 62.89% |

### 6.4 Combined coverage — Catch2 `[arcopolis]` ∪ fixture regressions

`llvm-profdata merge -sparse arco.profdata regress.profdata` then `llvm-cov report` against
the game binary. The cross-binary merge is **clean — no hash mismatch warnings**; the unit-
test records attribute correctly onto the game binary (e.g. `arcopolis_command` rises from
60.92% regress-only to 96.55% combined). Same file order as Section 5.3 for row-by-row
comparison:

| File                        | Region | Function |   Line | Branch |
| --------------------------- | -----: | -------: | -----: | -----: |
| arcopolis_command.cpp       | 96.55% |  100.00% | 95.65% | 95.83% |
| arcopolis_backend_input.cpp | 90.80% |   98.25% | 88.17% | 78.05% |
| arcopolis_session_log.cpp   | 90.44% |  100.00% | 92.99% | 82.08% |
| arcopolis_script.cpp        | 91.35% |  100.00% | 79.62% | 85.71% |
| arcopolis_live.cpp          | 87.22% |   95.00% | 83.28% | 80.43% |
| arcopolis_export.cpp        | 74.70% |  100.00% | 85.71% | 64.06% |
| **TOTAL**                   | 89.27% |   98.53% | 86.75% | 80.71% |

Together the two modalities reach **89.27% region / 86.75% line / 98.53% function** on the
Arcopolis-owned files (only 2 of 136 functions never reached).

### 6.5 What the combination reveals

The two test modalities are **complementary, not redundant** — now measured to be so
(region %, Catch2-only → combined):

- **Export is regression-only.** `arcopolis_export.cpp` 0.00% → 74.70%: export is reached
  only by the game-driven fixture runs, never by the Catch2 suite.
- **Command is mostly unit-test.** `arcopolis_command.cpp` Catch2 91.95% vs regressions
  60.92% (combined 96.55%): the command parser is best exercised by direct unit tests.
- **Live/script need real sessions.** `arcopolis_live.cpp` 38.02% → 87.22% and
  `arcopolis_script.cpp` 63.94% → 91.35%: weak under Catch2, lifted by regressions driving
  real game sessions.

This is the split doc 44 predicted and Section 5.3 measured one half of — now measured on
both halves.

(No regression script was modified and no regression expectation was changed; the only source
edit was the local, reverted `main.cpp` flush hook of 6.2.)

## 7. Comparison and recommendation

| Criterion                   | A. MSVC / VS coverage                            | B. Windows LLVM source-based                                   |
| --------------------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| Available on this machine   | **No** — native collector absent on VS Community | **Yes** — proven end-to-end (clang-cl 22.1.7)                  |
| Source-level usefulness     | none produced                                    | exact region/line/branch/function, per-file, + HTML            |
| Disk cost                   | n/a (couldn't run)                               | one-time **3.96 GB** build (test + game) + ~270 MB artifacts   |
| Setup friction              | needs VS **Enterprise** or a 3rd-party tool      | scratch clang-cl toolchain + 2 build-env fixes (below)         |
| Repeatability               | blocked                                          | deterministic; identical flags to the Linux CI clang build     |
| Compat with Arcopolis tests | vstest can't drive a Catch2 console exe          | both proven: `cata_test-tiles` directly + game exe via `-Exe`  |
| Future CI portability       | Windows-only, Enterprise-gated                   | clang is **already** the CI compiler (`ci-curses`, `ci-tiles`) |

**Recommendation: Path B — Windows LLVM 22.1.7 source-based coverage.** It is the only path
that works on this machine, and it produced real, source-mapped, Arcopolis-scoped coverage
for **both** test modalities — the Catch2 `[arcopolis]` suite (test binary) and all nine
fixture regressions (game binary), merging to **89.27% region** (Section 6).
It also matches the project's existing clang CI toolchain, so the same instrumentation
flags port to Linux CI later with no surprises. Path A would require a VS Enterprise license
or a third-party native tool (e.g. OpenCppCoverage) — both out of scope here.

The only friction for Path B is two small, well-understood items: link the LLVM profile
runtime lib (a build-environment step — CMake invokes `lld-link` directly), and the
`demangle.cpp` `<cxxabi.h>` include under clang-cl — **now fixed in tree by a one-line
include guard (PR #58)**, so it no longer needs the empty-`cxxabi.h` shim used during the
spike.

## 8. What this does not prove

- **Not whole-engine coverage.** The numbers are coverage of the listed Arcopolis files by
  the Catch2 `[arcopolis]` suite and the fixture regressions. No whole-engine percentage was
  computed (it would be meaningless from these Arcopolis-scoped workloads).
- **Seam-file %s are whole-file denominators.** `game.cpp` 0.97%, `handle_action.cpp` 0%,
  etc. measure seam-only hits against the entire file — not a statement about those files'
  overall testedness.
- **Coverage ≠ backend equivalence.** Level-4 input equivalence is a separate,
  source-witnessed property; an executed line is not a proof of a faithful registered-input
  path. A high coverage % does not upgrade an equivalence claim.
- **0% ≠ untested (now measured both ways).** `arcopolis_export.cpp` shows 0% under the
  **Catch2** suite only; the fixture regressions reach it at **74.70% region / 85.71% line**
  (Section 6). The `pickup.cpp` / `handle_action.cpp` seam files are likewise reached by the
  regressions driving the game binary, not by the Catch2 suite.
- **No CI gate, no global target.** Nothing was wired into CI; no repo-wide percentage was
  set or implied.
- **Measurement build, not a shipping build.** The clang-cl build disables debug info and is
  not part of any release/CI flow.
- **MSVC verdict is machine-specific.** It reflects VS 2022 **Community** here; Enterprise or
  third-party tools were not evaluated.

## 9. Next steps

Recommended single next PR: **land the clang-cl coverage path as an optional local recipe.**

1. **One-line source fix — ✅ done (PR #58).** So a clang-cl Windows build needs no shim:
   `demangle.cpp:3` → `#if (defined(__GNUC__) || defined(__clang__)) && !defined(_MSC_VER)`.
   (Tiny, behavior-neutral; the MSVC stub path is already what `cl.exe` uses.)
2. **Optional local coverage recipe**, not a CI gate: document the clang-cl toolchain
   (debug-info off; link `clang_rt.profile-x86_64.lib`; coverage flags) and both flows —
   build → run `[arcopolis]` → `llvm-profdata merge` → `llvm-cov report` for the test binary,
   and the game-binary + fixture-regression flow of Section 6 — scoped to the
   `src/arcopolis_*.cpp` files plus the seam files. Keep artifacts under `out/` (gitignored).
3. **Guarded profile-flush hook (a real decision, deferred).** Capturing game-binary coverage
   needed a local `__llvm_profile_write_file()` before each `std::_Exit` (Section 6.2). A
   committable version would gate it behind a coverage-only build flag so normal builds stay
   byte-identical; whether to carry that in tree is a separate call, not made here.

Constraints to carry forward: no CI coverage gate, no repo-wide percentage target, gate the
~4 GB measurement build on local free disk, and never reuse/mutate `out/build/win-rel-deb`.

## Appendix A — raw commands

```powershell
# --- Path A (MSVC) probes — all read-only, produced nothing ---
& Microsoft.CodeCoverage.Console --help                      # 'not recognized' (ABSENT)
& "...\Team Tools\DiagnosticsHub\Collector\VSInstr.exe"      # present, instrument-half only
& vstest.console.exe cata_test-tiles.exe "--collect:Code Coverage" "--ResultsDirectory:out\coverage-msvc"
#   -> "Could not find data collector 'Code Coverage'" ; "No test is available ..." ; no .coverage

# --- Path B (LLVM) — VS DevShell activation ---
$vsPath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module (Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"
$env:VCPKG_ROOT = Join-Path $vsPath "VC\vcpkg"

$RepoRoot = "<repo-root>"    # <-- set to your checkout; every relative path below assumes this is the cwd
Set-Location $RepoRoot

# scratch toolchain = copy of build-scripts/MSVC.cmake with:
#   CMAKE_C/CXX_COMPILER = C:/Program Files/LLVM/bin/clang-cl.exe
#   CMAKE_MSVC_DEBUG_INFORMATION_FORMAT ""                       # no debug info -> small build
#   + /clang:-fprofile-instr-generate /clang:-fcoverage-mapping  # compile
#   + C:/PROGRA~1/LLVM/lib/clang/22/lib/windows/clang_rt.profile-x86_64.lib   # link (plain lib!)
#   (PROGRA~1 assumes 8.3 short names are enabled; `22` = your installed LLVM major version)

cmake -S $RepoRoot -B $RepoRoot\out\build\win-llvm-cov -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo `
  -DCMAKE_PROJECT_INCLUDE_BEFORE="...\build-scripts\windows-tiles-sounds-x64-msvc.cmake" `
  -DCMAKE_TOOLCHAIN_FILE="C:\tmp\arco-llvm-cov-toolchain.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static -DTILES=True -DSOUND=True -DTESTS=True `
  -DCURSES=False -DLOCALIZE=True -DJSON_FORMAT=OFF -DDYNAMIC_LINKING=False `
  "-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root=C:/tmp/cbn-vb-cov;--x-packages-root=C:/tmp/cbn-vp-cov"

# demangle.cpp shim — NO LONGER NEEDED after the PR #58 include-guard fix; kept for the spike's record.
# (Pre-#58 workaround: empty cxxabi.h on INCLUDE so clang-cl's unused <cxxabi.h> include resolves.)
New-Item -ItemType Directory -Force C:\tmp\arco-cov-shim | Out-Null
$null | Set-Content C:\tmp\arco-cov-shim\cxxabi.h
$env:INCLUDE = "C:\tmp\arco-cov-shim;$env:INCLUDE"
cmake --build $RepoRoot\out\build\win-llvm-cov --target cata_test-tiles -- -j4   # exit 0

# --- run the suite under coverage (child cwd = repo root) ---
$env:LLVM_PROFILE_FILE = "$RepoRoot\out\coverage-llvm\arco-%p.profraw"
Start-Process ...\win-llvm-cov\tests\cata_test-tiles.exe -ArgumentList "[arcopolis]" `
  -WorkingDirectory $RepoRoot -NoNewWindow -Wait                          # 920 assertions pass

# --- merge + report ---
& "C:\Program Files\LLVM\bin\llvm-profdata.exe" merge -sparse out\coverage-llvm\arco-*.profraw `
  -o out\coverage-llvm\arco.profdata
$arco = (Get-ChildItem src\arcopolis_*.cpp).FullName   # PS does NOT glob native-exe args — expand first
& "C:\Program Files\LLVM\bin\llvm-cov.exe" report ...\win-llvm-cov\tests\cata_test-tiles.exe `
  -instr-profile=out\coverage-llvm\arco.profdata @arco        # per-file table
& "C:\Program Files\LLVM\bin\llvm-cov.exe" show   ... -format=html -output-dir=out\coverage-llvm\html ...

# --- Section 6: game-binary regression coverage (local, reverted main.cpp flush hook) ---
# LOCAL main.cpp edit (reverted after the run): in the --arcopolis-* modes,
#   extern "C" int __llvm_profile_write_file( void );        // declared at file scope
#   #if defined( ARCO_COV_FLUSH )
#     __llvm_profile_write_file();                            // flush before each std::_Exit
#   #endif
$env:CL = "/DARCO_COV_FLUSH"                                  # compile the guarded flush in
cmake --build out\build\win-llvm-cov --target cataclysm-bn-tiles -- -j4    # game exe, exit 0

# (assumes cwd = $RepoRoot, set above; for a standalone run first: $RepoRoot = "<repo-root>"; Set-Location $RepoRoot)
$nine_regressions = @(                                        # the nine fixture regressions run under coverage
  'movement_regression.ps1', 'item_export_regression.ps1', 'npc_export_regression.ps1',
  'monster_export_regression.ps1', 'examine_regression.ps1', 'prompt_menu_regression.ps1',
  'query_popup_regression.ps1', 'script_prompt_regression.ps1', 'live_protocol_regression.ps1'
)
foreach ($s in $nine_regressions) {                          # -Exe = cov exe
  $env:LLVM_PROFILE_FILE = "out\coverage-llvm\regress-%p.profraw"
  pwsh -File docs\arcopolis\$s -Exe out\build\win-llvm-cov\src\cataclysm-bn-tiles.exe
  $prior = if (Test-Path out\coverage-llvm\regress.profdata) { 'out\coverage-llvm\regress.profdata' } else { @() }
  llvm-profdata merge -sparse out\coverage-llvm\regress-*.profraw $prior `
    -o out\coverage-llvm\regress.profdata                     # incremental merge (accumulate in place)
  Remove-Item out\coverage-llvm\regress-*.profraw            # then delete raws (bound disk)
}
git checkout -- src\main.cpp                                  # REVERT the local flush hook

# combined (Catch2 tests UNION regressions), reported vs the game binary:
llvm-profdata merge -sparse out\coverage-llvm\arco.profdata out\coverage-llvm\regress.profdata `
  -o out\coverage-llvm\combined.profdata
$arco = (Get-ChildItem src\arcopolis_*.cpp).FullName   # re-derive: §5.3 $arco may be out of scope here
llvm-cov report out\build\win-llvm-cov\src\cataclysm-bn-tiles.exe `
  -instr-profile=out\coverage-llvm\combined.profdata @arco
```

## Appendix B — local artifacts not committed

All gitignored (`out/` via `.gitignore:91`) or outside the repo (`C:\tmp`). None are
tracked; all are safe to delete to reclaim disk. The `arco-cov-shim\cxxabi.h` row is now
obsolete — after the PR #58 include-guard fix a clang-cl build no longer needs the shim.

| Path                                      |    Size | Note                                        |
| ----------------------------------------- | ------: | ------------------------------------------- |
| `out/build/win-llvm-cov/`                 | 3.96 GB | instrumented clang-cl build (test + game)   |
| `out/coverage-llvm/arco-<pid>.profraw`    |  197 MB | raw profile from the `[arcopolis]` run      |
| `out/coverage-llvm/arco.profdata`         |   21 MB | merged Catch2 `[arcopolis]` profile         |
| `out/coverage-llvm/regress.profdata`      |   22 MB | merged 9-regression profile (Section 6)     |
| `out/coverage-llvm/combined.profdata`     |   22 MB | tests ∪ regressions (Section 6.4)           |
| `out/coverage-llvm/regress-<pid>.profraw` |    none | transient ~206 MB each; merged-then-deleted |
| `out/coverage-llvm/html/`                 |   small | filtered HTML line-view                     |
| `out/coverage-llvm/sample_coverage.*`     |  ~10 MB | the 5.1 toolchain pre-check sample          |
| `out/coverage-msvc/`                      |   empty | created by the Path A probe (no output)     |
| `C:\tmp\arco-llvm-cov-toolchain.cmake`    |    tiny | scratch clang-cl toolchain                  |
| `C:\tmp\arco-cov-shim\cxxabi.h`           |    tiny | empty `demangle.cpp` build shim             |
| `C:\tmp\arco-regress-coverage.ps1`        |    tiny | scratch 9-regression coverage batch         |
| `C:\tmp\cbn-vb-cov`, `C:\tmp\cbn-vp-cov`  |    var. | vcpkg buildtrees/packages scratch           |
| `C:\tmp\arco-cov-*.log`, `regr-*.log`     |   small | configure / build / regression logs         |
