# Arcopolis C++23 / Engine Refactor Strategy

## Status and scope

This is a research/audit/roadmap document. It does not change source code, implement modernization, change build settings, change CI, or alter Arcopolis runtime behavior.

It does not endorse a big-bang C++23 rewrite. The repository already configures C++23; the relevant question is whether BN should adopt selected C++23-era practices in small, test-backed areas that make the engine safer as an authoritative Arcopolis backend.

Inspected checkout: `origin/arcopolis` at `614f6939d1` (`build(arcopolis): skip <cxxabi.h> under clang-cl in demangle.cpp (#58)`). This includes the Spike 22 coverage feasibility work from PR #57 and the clang-cl demangle include guard from PR #58.

No source files were edited for this audit.

## 1. Current repo constraints

### Build and toolchain reality

BN is already configured as a C++23 project: `CMakeLists.txt:318-320` sets `CMAKE_CXX_STANDARD 23`, requires it, and disables compiler extensions. The practical modernization issue is therefore not "turn on C++23"; it is "which C++23-compatible idioms can be introduced without breaking old-engine behavior, platform support, save data, or the Arcopolis backend contract."

The repo has multiple important build personalities:

| Area                       | Repo evidence                                                                                                                                                                                                                   | Modernization constraint                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Windows local route        | `CMakePresets.json:10-27` defines a Windows VS 2022 / MSVC preset with tiles, sound, tests, JSON formatting, and vcpkg.                                                                                                         | Any C++23 feature used in shared code must be accepted by MSVC in the local route, not merely by Clang.        |
| Linux full route           | `CMakePresets.json:103-134` defines a Clang/Ninja `linux-full` preset with clang-tidy plugin and Tracy.                                                                                                                         | Static-analysis and profiling toolchains matter; source-level churn can affect both.                           |
| Test targets               | `tests/CMakeLists.txt:1-45` glob-loads `tests/*.cpp`, builds `cata_test-tiles` when `TILES` is on, and registers CTest commands.                                                                                                | Refactors need focused Catch2 coverage plus relevant binary regressions; CTest presence is not coverage proof. |
| Formatting/static analysis | `.clang-tidy:14-22` enables broad diagnostic, misc, modernize, performance, and readability families, but `.clang-tidy:49-62` disables several modernize checks including `modernize-loop-convert` and `modernize-use-nullptr`. | The repo already rejects several broad automatic "modernize everything" transformations.                       |

### Current C++ style reality

The local AGENTS rules demand modern C++ style for new/touched code: trailing return types, `auto` where appropriate, designated initializers, options structs for more than three parameters, `std::ranges`/`std::views` or range-for instead of manual iterator loops, and file-scoped formatting for touched C++.

That is not the same thing as permission to mechanically rewrite legacy code. The codebase contains older idioms, large files, globals, UI/simulation coupling, custom containers, serialization code, and C++ ownership patterns that need local understanding before refactor.

Current source already uses some modern constructs:

- `src/game.cpp:2116-2120` uses `std::ranges::any_of` in the main turn loop.
- `tests/arcopolis_live_test.cpp:24-25` and `tests/arcopolis_session_log_test.cpp:24-25` use `std::ranges::count`.
- `tests/algo_test.cpp` exercises `std::ranges`, `std::views`, and `std::ranges::to`.
- Arcopolis-owned tests and backend code use `std::optional` for typed absence and prompt answers.

But the codebase is still a legacy engine, not a greenfield C++23 sample project. For example:

- `src/game.cpp:1917-1964` owns the main `game::do_turn()` structure and the `new_game` bootstrap branch.
- `src/game.cpp:2096-2135` calls `handle_action()` and contains Arcopolis clean-stop logic.
- `src/handle_action.cpp:1759-1782` is the top-level player-action seam.
- `src/input.cpp:931-948` is the nested `input_context::handle_input()` backend hook.
- `src/ui.cpp:153-162`, `src/popup.cpp:326-339`, `src/output.cpp:729-739`, `src/pickup.cpp:170-214`, and `src/iexamine.cpp:1415-1422` show prompt/UI paths where small changes can alter backend equivalence.

### Arcopolis protected architecture

The current Arcopolis truth is narrow and explicit:

- Four prompt paths are currently witnessed at level 4 backend-input + engine equivalence, each scoped to a specific path/fixture, not a prompt class (`docs/arcopolis/ARCOPOLIS_STATE.md:10-21`).
- Movement itself is not level 4 because its action does not enter `handle_input`; unsupported paths fail loud or remain backlog (`docs/arcopolis/ARCOPOLIS_STATE.md:16-20`).
- Backend mode must create no curses window and call no render primitive (`docs/arcopolis/ARCOPOLIS_STATE.md:19-20`).
- The backend UI boundary doc says the current prompt witnesses are not a renderer-neutral backend UI mode (`docs/arcopolis/40_SPIKE19_BACKEND_UI_BOUNDARY.md:36-53`).
- `src/arcopolis_backend_input.h:26-52` deliberately names per-family gates and forbids treating the current witnesses as generic UI support.

The protected Arcopolis path remains:

```text
external frontend/client
-> Arcopolis command/protocol
-> real BN input seam: game::handle_action()
-> game::do_turn owns turns/world ticking
-> read-only snapshots + session transcript
-> external consumer explains/renders state
```

### Test coverage reality

The older coverage audit (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md`) is explicitly not a coverage measurement: it maps current tests/regressions and recommends measurement steps. That gap is now partially closed by Spike 22, `docs/arcopolis/45_WINDOWS_COVERAGE_FEASIBILITY.md`, which ran a Windows-first measurement. Its conclusion is materially relevant here:

- MSVC / Visual Studio native coverage was not usable on that VS Community machine.
- Windows LLVM 22.1.7 source-based coverage with `clang-cl` worked end-to-end.
- The instrumented Catch2 `[arcopolis]` suite plus all nine fixture regressions produced real source-mapped coverage on Arcopolis-owned files: **89.27% region / 86.75% line / 98.53% function** combined.
- It added no CI coverage gate, no repo-wide percentage target, and no runtime/protocol/regression expectation changes.
- It explicitly says coverage does not prove backend equivalence; level-4 input equivalence remains a separate source-witnessed property.
- PR #58 landed the `src/demangle.cpp` clang-cl include guard, so the coverage path no longer needs the temporary empty-`cxxabi.h` shim used during the spike.

Current test layers are useful but scoped:

- Catch2 seam tests cover parser contracts, backend input state machines, prompt formatting, and transcript JSON-line formatting (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:38`).
- CI/static analysis cannot prove prompt equivalence, save/load compatibility, or snapshot fidelity (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:41`).
- PowerShell regressions witness specific fixture-backed backend behaviors, not exhaustive subsystem behavior (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:42`).
- Fixture worlds are committed and deterministic for witness scenarios, but are not a save migration test suite (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:43`).

### Old-codebase/fork/backport risk

BN is a long-lived game engine with upstream sync pressure. The Arcopolis branch carries backend seams on top of a fast upstream. Broad rewrites increase conflict cost, reduce reviewability, and can corrupt subtle gameplay/UI equivalence.

Large files and hot seams are especially risky:

- `src/game.cpp` owns turn progression and many globals.
- `src/handle_action.cpp` is the player action dispatcher.
- `src/input.cpp`, `src/ui.cpp`, `src/popup.cpp`, `src/output.cpp`, `src/pickup.cpp`, and `src/iexamine.cpp` mix user prompts, rendering, and gameplay outcomes.
- `src/activity_actor.cpp` serializes/deserializes many activity actors.
- Map, NPC, monster, options, JSON loading, and save systems are broad shared subsystems.

### Save compatibility and data-driven systems

The engine's content and save model is JSON-heavy and stateful. Representative evidence:

- `src/activity_actor.cpp` contains repeated `serialize` / `deserialize` pairs for activity actors.
- `src/pickup.cpp:1641-1652` serializes/deserializes pickup/drop selection state.
- Arcopolis fixtures are committed save/config packs under `docs/arcopolis/fixtures/arcopolis_user`, and regressions copy them into a sandbox (`docs/arcopolis/TEST_FIXTURES.md:3-13`).

Serialization, save loading, coordinate systems, and data IDs must be treated as compatibility boundaries. Modernizing types inside those boundaries is not mechanical cleanup.

### UI/rendering entanglement risk

The hardest Arcopolis problem is not syntax; it is separating player-visible UI behavior from authoritative simulation without faking state. Evidence:

- `src/ui.cpp:153-162` normally aborts `uilist` in `test_mode`, with a narrow Arcopolis un-abort only when a uilist transaction is armed.
- `src/pickup.cpp:170-214` explains that the secondary uilist witness exposes real menu entries and serves registered actions; the backend never mutates `amenu.ret`, selection, or filtered entries.
- `src/output.cpp:729-739` exposes real `query_yn` options only while a witness-scoped query popup transaction is armed.
- `tests/arcopolis_backend_input_test.cpp:487-506` verifies the uilist gate is true only for an armed uilist transaction.
- `tests/arcopolis_backend_input_test.cpp:651-660` verifies unarmed `uilist` during a session fails loud.
- `tests/arcopolis_backend_input_test.cpp:1025-1042` verifies unarmed `query_popup` during a session fails loud.

Any modernization that "cleans up" these areas without preserving exact input-loop behavior is a regression.

## 2. External research summary

### C++ Core Guidelines / modern C++ principles

Source: [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines), current page dated 2026-06-14 in the inspected copy.

Relevant lessons:

- The guidelines define modern C++ as effective ISO C++ use, focused on interfaces, resource management, memory management, and concurrency; the stated goals include static type safety, resource safety, simplicity, and tooling support.
- The guidelines explicitly say old-system upgrades are hard, rules should be adopted gradually, and complete conversion of a large codebase all at once is typically infeasible.
- Rule I.30 says unsafe/error-prone techniques should be encapsulated locally rather than leak through interfaces.
- Resource-management guidance emphasizes RAII/resource handles; interface guidance says raw pointers/references should not transfer ownership.

Applies to BN/Arcopolis:

- Strongly applicable as direction: local encapsulation, RAII guards, typed results, and ownership clarity are valuable.
- Not directly applicable as a blanket rulebook: BN has existing style, no-exception conventions in practice, custom types, save formats, and engine-specific performance/compatibility constraints.

### C++20/C++23 library features relevant to large codebases

Sources:

- [cppreference: `std::expected`](https://en.cppreference.com/w/cpp/utility/expected)
- [cppreference: `std::span`](https://en.cppreference.com/w/cpp/container/span)
- [cppreference: `std::ranges::to`](https://en.cppreference.com/w/cpp/ranges/to)
- [Clang C++ status](https://clang.llvm.org/cxx_status.html)
- [MSVC C++ language conformance](https://learn.microsoft.com/en-us/cpp/overview/visual-cpp-language-conformance)

Relevant lessons:

- `std::expected` is C++23 and represents either an expected value or an error value; it is well-suited for local APIs where failure is part of normal control flow.
- `std::span` is a non-owning view over contiguous objects; it can clarify view-vs-owner boundaries, but inherits invalidation/lifetime risks from the underlying storage.
- `std::ranges::to` constructs a non-view object from a source range and can simplify local range pipelines.
- Clang documents C++23 mode as partial support and tracks per-feature availability; MSVC also has a conformance matrix. A repo that supports both should verify specific features, not assume all C++23 library pieces are equally portable.

Applies to BN/Arcopolis:

- `std::optional`, `std::variant`, `std::span`, local `std::expected`-style results, and ranges can improve small APIs.
- Feature adoption must be checked against the actual MSVC/Clang versions used by BN, especially when using newer C++23 library features.
- `std::span` and `std::string_view` must not outlive data they view; they are clarity tools, not ownership tools.

### Game engine / game-adjacent codebases

Sources:

- [Dolphin contributing guide](https://github.com/dolphin-emu/dolphin/blob/master/Contributing.md)
- [OpenRCT2 contributing guide](https://github.com/OpenRCT2/OpenRCT2/blob/develop/CONTRIBUTING.md)
- [Godot engine architecture docs](https://docs.godotengine.org/en/stable/engine_details/architecture/index.html)
- [Godot unit testing docs](https://docs.godotengine.org/en/stable/engine_details/architecture/unit_testing.html)
- [Godot internal rendering architecture docs](https://docs.godotengine.org/en/stable/engine_details/architecture/internal_rendering_architecture.html)

Relevant lessons:

- Dolphin uses project-specific formatting/tooling and says compiler/tool formatting wins over prose style guidance. It also recommends avoiding raw `new`/raw pointers where standard containers or `unique_ptr` solve the problem, while acknowledging unavoidable cases.
- Dolphin's `auto` guidance is deliberately not "use auto everywhere"; it asks whether the type is obvious to a reader.
- OpenRCT2 asks bug reporters to include reproduction steps and saved games, and its contribution guide says C++ remains the majority language for now. That is relevant to BN because saved-game fixtures are the cheapest trustworthy repro artifacts for engine behavior.
- Godot 4 stable documents engine source organization, C++ unit tests built with `tests=yes` and run through `--test`, and a rendering architecture with `RenderingDevice` abstracting modern Vulkan/Direct3D 12/Metal paths while OpenGL remains outside that abstraction. This is relevant architecturally: renderer abstraction is a designed subsystem with documented limits, not a one-line bypass around UI code.

Applies to BN/Arcopolis:

- Large game projects keep local style rules and tool-supported workflows; they do not blindly adopt every modern C++ idiom.
- Saved-state repros and fixture-backed regressions are normal and valuable for games.
- Renderer-neutral architecture is designed explicitly; Arcopolis should not infer general renderer-neutral UI support from a handful of prompt witnesses.

### Large non-game C++ modernization/refactor practices

Sources:

- [LLVM Coding Standards](https://llvm.org/docs/CodingStandards.html)
- [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html)

Relevant lessons:

- LLVM says large-scale codebases need coding standards, but the golden rule for existing code is to follow local style when extending/fixing it. It explicitly does not want large-scale reformatting patches and asks for separate commits for style-only changes.
- LLVM constrains language features to major supported toolchains and notes that very recent standards may not be available across all supported subprojects/toolchains.
- LLVM prefers standard/support libraries over custom data structures where appropriate, but also uses project-specific support types when they are better suited.
- Google frames C++ style as complexity management, optimizes for readers over writers, values consistency, but says consistency should not freeze old style forever. It targets C++20 at the time of the inspected page and forbids C++23 features in that codebase pending policy advancement.

Applies to BN/Arcopolis:

- The best analogy is subsystem-by-subsystem modernization with reviewable diffs, not broad style sweeps.
- Project-local constraints matter more than generic "modern C++" fashion.
- Toolchain policy must be explicit before adopting features that are technically C++23 but weakly supported.

### Testing/coverage implications for refactoring

Sources:

- [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines) on tools/static checking and gradual adoption.
- [Godot unit testing docs](https://docs.godotengine.org/en/stable/engine_details/architecture/unit_testing.html) for embedded C++ engine tests.
- [OpenRCT2 contributing guide](https://github.com/OpenRCT2/OpenRCT2/blob/develop/CONTRIBUTING.md) for saved-game repro value.
- Repo evidence from `docs/arcopolis/44_TEST_COVERAGE_AUDIT.md`.
- Measured repo evidence from `docs/arcopolis/45_WINDOWS_COVERAGE_FEASIBILITY.md`.

Relevant lessons:

- Static analysis helps but does not prove behavioral equivalence.
- Game-engine behavior often needs fixture/save repros, not just unit tests.
- BN already has Catch2 plus fixture-backed PowerShell regressions, and now has a proven local Windows LLVM coverage path for Arcopolis-owned files. The remaining gap is contract matrices and explicit thresholds/evidence before touching brittle shared systems.

Applies to BN/Arcopolis:

- Refactors to input, UI, map, activity, serialization, or snapshot/export should require contract tests and fixture regressions first.
- Modernization should be accepted when it reduces a tested backend risk, not because it produces a prettier diff.

## 3. Modernization candidates

| Candidate                                                        | Example                                                                                                           | Benefit                                                    | Risk                                                                                                                                 | Fit for BN                                                       | Fit for Arcopolis backend                                               | Prerequisites                                                         | Verdict                                                                       |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Stronger type aliases / coordinate types                         | Preserve or extend `tripoint_bub_ms`, `tripoint_abs_ms`, `tripoint_abs_sm` boundaries.                            | Prevents coordinate mixups in map/snapshot code.           | Mechanical changes can break map/reality-bubble semantics.                                                                           | Good where existing coordinate types already express intent.     | High value for snapshots and frontend contract.                         | Coordinate contract tests, fixture worlds, map/reality-bubble audits. | Good fit later; avoid mechanical coordinate rewrites.                         |
| Ownership clarity and smart-pointer boundaries                   | Replace local raw owning `new` with `std::unique_ptr` or existing project pointer type where ownership is proven. | Makes lifetime/ownership visible.                          | Raw pointers may be non-owning, external API, intrusive, cached, or serialization-sensitive.                                         | Good only with ownership audit.                                  | Useful around backend session resources and local helpers.              | Ownership notes, local tests, no mass migration.                      | Maybe, only behind tests.                                                     |
| Replacing sentinel/error strings with typed results              | Local Arcopolis parser/command helpers returning typed error values.                                              | Reduces stringly-typed failure handling.                   | Global replacement would churn APIs and translations.                                                                                | Good in new/local APIs.                                          | High value for live protocol and fail-loud behavior.                    | Stable error enum/contract tests.                                     | Good fit now in Arcopolis-owned code.                                         |
| `std::optional` / `std::variant` / `std::expected`-style results | `std::optional<int>` prompt answer; local `expected<value, command_error>`.                                       | Models absence and expected failure.                       | `std::expected` C++23 library support must be checked on MSVC/Clang; global exception-policy mismatch possible if `.value()` throws. | `optional`/`variant` already fit; `expected` should start local. | High for command/result/error contract.                                 | Toolchain check and no `.value()` in untrusted paths unless guarded.  | Good fit now for optional/variant; expected-style local after compiler check. |
| `std::span` / `std::string_view` for non-owning views            | Passing read-only contiguous choices to helpers.                                                                  | Avoids copies and expresses non-ownership.                 | Lifetime bugs if views escape; invalidation still applies.                                                                           | Good in leaf APIs with clear lifetimes.                          | Useful for snapshot serialization helpers.                              | No storage of views beyond call; tests/ASan where possible.           | Good fit now in local leaf helpers.                                           |
| Ranges/algorithms                                                | `ranges::any_of`, `views::filter`, `ranges::to`.                                                                  | Expresses collection intent; reduces loop mistakes.        | Lazy views can dangle; complex pipelines can hurt readability/perf. `.clang-tidy` disables `modernize-loop-convert`.                 | Good for simple local transformations.                           | Useful for snapshot/export filtering.                                   | Keep pipelines short; benchmark hot loops; no broad loop conversion.  | Good fit now when clearer; no mass migration.                                 |
| `constexpr` / `consteval`                                        | Compile-time constants, local table validation.                                                                   | Moves invariants earlier.                                  | Overuse can inflate compile times or fight dynamic JSON/data loading.                                                                | Good for small fixed constants.                                  | Low/moderate; useful for protocol constants.                            | Toolchain support and compile-time impact awareness.                  | Good fit now when obviously local.                                            |
| `enum class` where safe                                          | New Arcopolis protocol states/errors.                                                                             | Stronger typing, avoids implicit conversions.              | Existing serialized/string IDs and switches may depend on old enum behavior.                                                         | Good for new APIs; risky for existing enums.                     | High for protocol and command errors.                                   | Serialization/wire mapping tests.                                     | Good fit now for new local enums; avoid global conversion.                    |
| RAII transaction guards                                          | Prompt transaction begin/end guards.                                                                              | Prevents leaked armed state and encodes cleanup.           | Guard scope mistakes can change input behavior.                                                                                      | Good where transactions already exist.                           | Very high; directly reduces prompt leakage risk.                        | Existing prompt tests plus failure-path tests.                        | Recommended first spike.                                                      |
| Dependency inversion around UI/input seams                       | Small interfaces for backend prompt capture/answer, not direct state writes.                                      | Clarifies simulation vs UI boundary.                       | Easy to invent fake UI semantics.                                                                                                    | Good only around proven seams.                                   | Very high if it preserves real input loops.                             | Level-4 proof plan and fixture witnesses.                             | Good fit later, test-first.                                                   |
| Serialization boundary cleanup                                   | Typed save/snapshot version wrappers, explicit contract schemas.                                                  | Reduces accidental save/frontend drift.                    | Save format compatibility and migrations are brittle.                                                                                | Good as audit/docs/tests first.                                  | High for snapshots/frontend contract.                                   | Golden snapshots, fixture migration checks.                           | Good fit later.                                                               |
| Reducing global state access                                     | Pass narrow context objects into Arcopolis helpers.                                                               | Improves testability and future long-running backend.      | Global `g`, map, calendar, options are pervasive; lifetime changes are dangerous.                                                    | Good in Arcopolis-owned code; risky in shared engine.            | High long-term.                                                         | Load/teardown tests, no behavior change.                              | Good fit later, subsystem by subsystem.                                       |
| Test fixtures and contract tests before refactors                | Golden transcript/snapshot matrix across fixture worlds.                                                          | Makes refactors measurable.                                | Requires maintenance when intended output changes.                                                                                   | Essential.                                                       | Essential.                                                              | Spike 22 coverage data plus contract matrix.                          | Good fit now.                                                                 |
| clang-tidy modernization checks                                  | File-scoped checks on touched Arcopolis files.                                                                    | Finds issues cheaply.                                      | Broad autofix churn; configured checks are intentionally selective.                                                                  | Good when scoped.                                                | Moderate.                                                               | Per-file review, no broad `-fix` runs.                                | Good fit now with strict scope.                                               |
| Formatting/autofix constraints                                   | Format only touched docs/C++ files.                                                                               | Keeps diffs reviewable.                                    | Broad formatting hides behavior changes.                                                                                             | Essential.                                                       | Essential.                                                              | Git diff review.                                                      | Good fit now; forbid broad sweeps.                                            |
| Modules                                                          | Replace headers/imports with C++20/23 modules.                                                                    | Theoretical compile-time/interface benefits.               | Macro-heavy legacy engine, tooling/build complexity, cross-toolchain risk.                                                           | Poor now.                                                        | Low direct value.                                                       | Dedicated build-system design and upstream alignment.                 | Avoid for now.                                                                |
| Coroutines                                                       | Async backend/live protocol or generator-like flows.                                                              | Could model async streams.                                 | Adds complex control flow and compiler/library risk.                                                                                 | Poor now.                                                        | Maybe very later for external frontend transport, not engine semantics. | Design doc, toolchain proof, tests.                                   | Avoid for now.                                                                |
| Concepts                                                         | Constrain generic helpers.                                                                                        | Better template diagnostics.                               | Template abstraction may be unnecessary; can spread complexity.                                                                      | Good only in small libraries.                                    | Low/moderate.                                                           | Clear generic API need.                                               | Maybe later.                                                                  |
| Exceptions policy                                                | Throwing for recoverable command errors.                                                                          | Standard C++ error handling model.                         | BN likely has no broad exception policy for gameplay paths; exceptions across engine boundaries are risky.                           | Bad global fit.                                                  | Bad for protocol errors; typed results are clearer.                     | Explicit upstream policy if ever considered.                          | Avoid globally.                                                               |
| Parallelism/threading                                            | Parallel map/export work.                                                                                         | Potential performance.                                     | BN globals, deterministic replay, UI/backend state, and save/load make races likely.                                                 | Bad now.                                                         | Bad until long-running backend invariants exist.                        | Thread-safety audit and deterministic tests.                          | Avoid for now.                                                                |
| Deterministic replay hooks                                       | Record commands, seed, prompts, snapshots.                                                                        | Enables backend contract testing and frontend equivalence. | Hooks can perturb simulation if invasive.                                                                                            | Good if observation-only or seam-local.                          | Very high.                                                              | Transcript schema, fixture matrix, and coverage-only hooks if needed. | Good fit after contract prerequisites.                                        |

## 4. Engine-backend architecture refactor themes

| Theme                                            | Classification             | Evidence                                                                                                                                                                                       | Backend implication                                                                                                          |
| ------------------------------------------------ | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Simulation loop ownership                        | Already protected, fragile | `src/game.cpp:1917-1964` owns turn start/bootstrap; `src/game.cpp:2096-2135` owns action handling and clean-stop.                                                                              | Do not bypass `do_turn`; persistent backend lifecycle should fix repeated bootstrap issues instead of faking clock advances. |
| Input/action seam                                | Partially protected        | `src/handle_action.cpp:1759-1782` pulls backend actions only when `backend_session_active()`; `src/input.cpp:931-948` answers nested prompts through registered action contexts.               | Refactors should make the seam clearer but keep the same active engine loop/mechanism.                                       |
| UI/prompt isolation                              | Weak/fragile               | `src/ui.cpp:153-162` and `src/popup.cpp` have `test_mode` abort/un-abort paths; `docs/arcopolis/40_SPIKE19_BACKEND_UI_BOUNDARY.md:36-53` says this is not renderer-neutral UI mode.            | Highest-value architecture work is renderer-neutral prompt/menu infrastructure, not wider un-abort hacks.                    |
| Renderer-neutral prompt/menu infrastructure      | Future work                | Inventory selector is explicitly unsupported in `src/arcopolis_backend_input.h:41-47`.                                                                                                         | Needs a design where data population, layout, input loop, and rendering are separated without direct state mutation.         |
| Snapshot/export boundary                         | Partially protected        | Arcopolis state docs and tests cover current snapshots/transcripts; Spike 22 measured `arcopolis_export.cpp` through fixture regressions, but that is still not a versioned frontend contract. | Add versioned contracts and golden fixtures before refactoring export internals.                                             |
| Command/result/error contract                    | Partially protected        | Arcopolis tests cover error-code mappings and transcript formatting (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:38`).                                                                           | Typed results and explicit error enums are valuable in Arcopolis-owned code.                                                 |
| Deterministic replay and transcript relationship | Partially protected        | Session transcript exists; fixture regressions exist; Spike 22 shows unit tests and fixture regressions cover complementary paths.                                                             | Build a contract matrix: command sequence, prompt events, snapshot deltas, exit code, and transcript lines.                  |
| Fixture-backed regression model                  | Partially protected        | Repo-local fixtures are committed and copied by scripts (`docs/arcopolis/TEST_FIXTURES.md:3-13`).                                                                                              | Treat fixtures as witness artifacts; add migration checks before save/load refactors.                                        |
| Save/load and migration safety                   | Weak/fragile               | Fixture worlds are not a migration suite (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:43`).                                                                                                      | Serialization changes need explicit old-save load tests and golden state comparison.                                         |
| Frontend contract versioning                     | Future work                | Current frontend/prototype harnesses consume snapshots but are not final GUI proof (`docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:44`).                                                            | Add protocol/snapshot versioning before external clients become hard to update.                                              |

### Ambitious source organization direction

The ambitious version is not "move every file into a shiny new tree." The proven pattern for a live legacy C++ engine is a strangler-style reorganization: create small, explicit boundaries around the behavior Arcopolis needs, route new code through those boundaries, then move or split legacy implementation only when tests prove the boundary. This preserves upstream access because most upstream-churn files stay in place until a subsystem has a stable adapter, contract tests, and a low-conflict move plan.

Potential long-term organization:

| Layer                               | Future role                                                                               | First iterative step                                                                                                         | Upstream-access rule                                                                                   |
| ----------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `engine_core`-like simulation layer | Turn loop, action resolution, map/reality bubble, activities, creatures, save/load.       | Do not move it first. Add narrow query/command-facing pure helpers beside existing code where Arcopolis already reads state. | Keep upstream-owned files mostly intact; prefer new helper files over reshaping hot upstream files.    |
| `engine_io` / data layer            | JSON loading, save/load, content IDs, migrations, fixture loading.                        | Add explicit snapshot/save-version contract tests before changing serialization helpers.                                     | Never reorganize serialization paths without old-save and fixture drift checks.                        |
| `engine_input` / prompt boundary    | Registered actions, prompt/menu data, prompt result consumption.                          | Extract prompt description structs and transaction guards in Arcopolis-owned code before touching shared UI.                 | No direct result mutation; no generic prompt claim until real engine loops consume registered actions. |
| `engine_ui` / renderer adapters     | Curses/tiles presentation, window/layout/render primitives.                               | Audit which prompt data-population paths can run before window creation; document blockers.                                  | Keep GUI behavior byte-for-byte unless a specific UI PR owns the change.                               |
| `arcopolis_backend`                 | Protocol, session lifecycle, transcript, snapshot export, fail-loud unsupported behavior. | Keep this as the first clean boundary; add versioned command/result/snapshot schemas.                                        | Prefer fork-owned files for Arcopolis work so upstream sync remains cheap.                             |
| `frontend_contract` docs/tests      | Golden external-client contract independent of BN internal layout.                        | Matrix of command, prompt, transcript, snapshot, exit-code expectations.                                                     | Contract changes must be intentional and versioned.                                                    |

This gives Arcopolis a more modern architecture without pretending BN can be atomically rearranged. The order matters:

1. Name boundaries in docs and tests.
2. Add local adapters/facades in new files.
3. Route new Arcopolis code through those adapters.
4. Backfill contract tests and fixture witnesses.
5. Split functions inside existing files only when the adapter is stable.
6. Move files/directories only when upstream conflict cost is understood and the move is mostly mechanical.

The source tree can become more modular over time, but the first wins should be behavioral boundaries, not directory moves. A directory move without a contract is cosmetic; an adapter plus tests is architecture.

## 5. Anti-patterns to avoid

- No "modernize everything" PR.
- No mechanical raw pointer to smart pointer migration without ownership audit.
- No changing coordinate systems without map/reality-bubble tests.
- No replacing error handling globally.
- No adding exceptions, coroutines, modules, concepts, or parallelism because they are modern.
- No fake backend UI.
- No bypassing `game::do_turn()`.
- No reviving the failed command-to-`do_turn` shortcut.
- No claiming level 4 from same final state, same finalization path, or one witnessed prompt path.
- No direct mutation of menu return values, filtered-entry state, inventory state, world state, or activity state outside existing engine code reached by the real input path.
- No mass clang-tidy autofix.
- No broad formatter run that rewrites unrelated files.
- No save serialization changes without migration/load tests.
- No global state lifetime changes without setup/teardown tests.
- No "silent cancel" unsupported prompts; unsupported player-visible prompts must fail loud or be explicitly observation-only.
- No source-tree reshuffle as a substitute for architecture. New directories/files are useful only when they enforce a tested boundary.
- No large file moves across upstream-hot files until the code has a stable adapter and a merge-conflict plan.

## 6. Phased roadmap

### Phase 0: Prerequisites

Purpose: make refactors measurable before changing engine structure.

Recommended first spike:

- Build an Arcopolis backend contract matrix doc/test plan that lists every current command/prompt witness, fixture, expected exit code, transcript event sequence, and snapshot fields.

Likely touched:

- `docs/arcopolis/`
- Possibly tests only, if turning matrix rows into existing regression checks.

Tests needed:

- No source behavior changes required.
- If executable tests are added, run affected Catch2 tests and corresponding PowerShell fixture regressions.

Failure modes:

- Matrix overclaims generic prompt support.
- Matrix lacks fixture/save version awareness.

Arcopolis value:

- High. It prevents future refactors from laundering weaker equivalence claims.

Other prerequisites:

- Consume the Spike 22 measured coverage results and decide whether to land the optional local coverage recipe and guarded profile-flush hook.
- Stabilize repo-local fixture use across all regression scripts.
- Audit source call paths before touching map/input/UI/activity systems.
- Add an "upstream conflict budget" note to each proposed refactor: which upstream-hot files are touched, whether a new file can absorb the change, and how rebase conflicts will be kept small.

### Phase 1: Low-risk hygiene

Purpose: improve Arcopolis-owned code without changing shared engine semantics.

Recommended first real refactor spike:

- Add/standardize RAII transaction guards in Arcopolis-owned prompt transaction code where begin/end pairs already exist, with tests for normal return, cancel, fail-loud, and early-exit paths.

Likely touched:

- `src/arcopolis_backend_input.cpp`
- `src/arcopolis_backend_input.h`
- `tests/arcopolis_backend_input_test.cpp`
- Documentation in `docs/arcopolis/`

Tests needed:

- Existing `[arcopolis]` backend input tests.
- Prompt regression script(s) for any prompt family touched.

Failure modes:

- Guard lifetime starts too early/late and changes which prompt is armed.
- Guard destructor hides a failure that should remain visible.
- Normal play accidentally sees backend state.

Arcopolis value:

- Very high. It reduces leaked prompt transaction state, one of the main backend risks, while preserving existing proof shape.

Other Phase 1 candidates:

- Local typed result wrappers in Arcopolis command/live/script parsing.
- File-scoped clang-tidy/format checks only on touched files.
- `std::span`/`string_view` in leaf serialization helpers where lifetime is obvious.
- Small ranges improvements in Arcopolis-owned collection code when they reduce mistakes.
- New `arcopolis_*` helper files that expose pure, read-only projection helpers instead of adding more logic directly to `src/game.cpp`, `src/handle_action.cpp`, or UI files.

### Phase 2: Backend seam hardening

Purpose: reduce UI/input boundary fragility without widening unsupported behavior.

Recommended first spike:

- Design a renderer-neutral prompt/menu boundary for one unsupported family as an observation-only audit before implementing support. Inventory selector is the best stress case because `src/arcopolis_backend_input.h:41-47` explains why it is not another uilist un-abort.

Likely touched:

- Design docs first.
- If later implemented: narrow UI/prompt files, Arcopolis backend input code, tests.

Tests needed:

- Existing prompt tests.
- New fail-loud tests for unsupported siblings.
- Fixture regression proving no curses window/render primitive and real registered inputs.

Failure modes:

- Accidentally creates a generic backend UI mode.
- Directly mutates selector/menu state.
- Treats layout/window creation as harmless in headless mode.

Arcopolis value:

- Very high if done honestly; this is the road from witnessed prompt paths toward external GUI equivalence.

Other Phase 2 candidates:

- Binary selection for regression coverage so tests run against the intended tiles/curses build.
- Deterministic replay integration if upstream-compatible hooks exist.
- Explicit prompt family registry documenting served, fail-loud, and observation-only states.
- Adapter-first prompt boundary: describe prompt data and registered actions in small structs, with existing UI loops still owning final result mutation.

### Phase 3: Engine architecture refactors

Purpose: isolate simulation assumptions from rendering/input assumptions in shared BN systems.

Recommended first spike:

- Extract a narrow read-only snapshot contract/versioning layer around Arcopolis export output, with golden fixture snapshots and compatibility notes.

Likely touched:

- `src/arcopolis_export.cpp`
- `src/arcopolis_session_log.cpp`
- `tests/arcopolis_session_log_test.cpp`
- Fixture regression expected outputs.

Tests needed:

- Golden snapshot comparison across existing fixture worlds.
- Transcript compatibility checks.
- Save/load sanity on repo-local fixtures.

Failure modes:

- Freezes unstable internal fields into frontend contract.
- Breaks clients without version bump.
- Converts UI-derived state into fake exported state.

Arcopolis value:

- High. It gives the external frontend a stable contract without altering simulation.

Other Phase 3 candidates:

- Clearer activity/action interfaces around backend-visible commands.
- Save/load drift checks for fixture packs.
- Narrow context objects for Arcopolis helpers to reduce ad hoc global access.
- Split leaf helpers from hot files only after tests exist. For example, extract read-only snapshot projection or prompt-description construction before trying to move action dispatch, map loading, or activity execution.
- Introduce stable internal adapters around selected global reads (`g`, map, avatar, calendar) for Arcopolis-owned code, but do not change shared global lifetimes until teardown/load tests exist.

### Phase 4: Broader modernization

Purpose: only after tests, coverage evidence, and contract expectations exist, modernize subsystem-by-subsystem.

Recommended first spike:

- Choose one low-risk, well-covered subsystem with clear ownership and little save/UI coupling, then apply one modernization theme at a time.
- If a subsystem is ready for source reorganization, start with one of these low-conflict patterns: new leaf helper file, header-only interface facade, internal adapter namespace, or function extraction inside the same file. Defer directory moves and include-path churn until the extracted boundary is stable.

Likely touched:

- Choose from Spike 22's measured Arcopolis-owned files first. Shared seam files still need explicit thresholds because their whole-file percentages are not meaningful for Arcopolis seam readiness.

Tests needed:

- Subsystem tests before/after.
- No unrelated formatter churn.
- CI/static analysis.

Failure modes:

- Upstream rebase cost exceeds benefit.
- A syntax cleanup hides behavior changes.
- Toolchain support differs between MSVC and Clang.
- Directory moves create permanent merge pain while leaving the old dependency shape intact.

Arcopolis value:

- Variable. Broader modernization is worthwhile only when it improves backend safety, testability, or maintainability.

### Phase 5: Source tree reorganization, if earned

Purpose: reorganize source layout only after boundaries are real.

Recommended first spike:

- Pick one Arcopolis-owned or low-upstream-churn boundary and move only that boundary into a clearer location, preserving wrapper includes if needed. Good candidates are protocol/session/snapshot contract helpers, not `game.cpp`, action dispatch, map, activity, UI, or save/load.

Likely touched:

- New or existing `src/arcopolis_*` files.
- CMake source lists if required by the build.
- Tests for moved helpers.

Tests needed:

- Affected Catch2 tests.
- Fixture regression if any runtime path changes.
- `git status`/diff review confirming the move did not drag unrelated formatter or include churn.

Failure modes:

- Move-only PR hides behavior changes.
- Include path churn spills across upstream-hot files.
- New organization forks away from upstream without improving backend contracts.

Arcopolis value:

- Moderate to high only after adapters exist. The value is not the directory name; it is making the backend boundary obvious enough that future work cannot accidentally bypass it.

## 7. Proposed AGENTS.md additions

Do not apply these yet. They are proposed guardrails for review after this strategy is accepted.

```markdown
### Modernization / C++23 refactor discipline

- The repo already builds as C++23; do not propose or perform a "C++23 migration" as a broad rewrite.
- Modernization PRs must name the exact subsystem, behavior boundary, tests, and rollback risk.
- Prefer backend-relevant refactors that improve ownership, typed errors, prompt/input safety, serialization contracts, or testability.
- Do not run broad clang-tidy autofix, broad formatter targets, or mechanical loop/pointer/enum conversions unless explicitly requested and scoped.
- Do not replace raw pointers with smart pointers without proving ownership and lifetime.
- Do not change coordinate types, save serialization, map/reality-bubble logic, activity serialization, or global lifetimes without dedicated tests.
- Do not add exceptions, coroutines, modules, concepts-heavy APIs, or threading/parallelism merely because they are modern C++.
- For any broad modernization proposal, cite current external guidance and repo evidence; distinguish source-backed claims from opinion.

### Arcopolis backend refactor discipline

- Refactors around input, prompts, UI, snapshots, transcripts, save/load, or command handling must state the equivalence level they preserve or prove.
- Same final state is not evidence of backend input equivalence.
- Do not create fake backend UI paths, direct menu/result mutation, or shortcuts around `game::handle_action()` / `game::do_turn()`.
- Unsupported player-visible prompts must fail loud or be explicitly observation-only.
- Renderer-neutral backend UI requires a real design; do not infer it from one witnessed `uilist` or `query_popup` path.
```

## 8. Open questions

- What is upstream BN's current and future C++ standard policy, beyond this fork's current `CMAKE_CXX_STANDARD 23`?
- Which exact MSVC, Clang, libstdc++, and libc++ versions must be supported for all official builds?
- Is `std::expected` available and acceptable on every target toolchain BN cares about today?
- Would upstream accept selected C++23 library features in shared engine code, or should Arcopolis confine them to fork-owned files?
- How much downstream divergence can Arcopolis tolerate before upstream sync cost dominates?
- Which shared subsystems are most brittle by measured failures, not intuition: map, input, UI, activity actors, save/load, JSON, NPC/monster, or options?
- What evidence beyond the current Arcopolis-owned coverage is needed before touching `src/game.cpp`, `src/handle_action.cpp`, `src/ui.cpp`, `src/popup.cpp`, `src/pickup.cpp`, `src/iexamine.cpp`, `src/activity_actor.cpp`, or map/save systems?
- Should the optional Windows LLVM coverage recipe and guarded profile-flush hook from Spike 22 be landed, or remain a local measurement recipe?
- What snapshot/protocol fields are stable frontend contract versus current implementation detail?
- Should fixture save packs get explicit save-version drift checks?
- Can renderer-neutral prompt/menu data population be separated from layout/window creation without changing GUI behavior?

## 9. Recommendation

Do not pursue a wholesale C++23 modernization now. The repo already compiles as C++23, and broad syntax churn would increase upstream rebase cost while doing little for Arcopolis.

Pursue targeted, test-backed, backend-relevant refactors after consuming the Spike 22 coverage results and stabilizing fixture-backed contract tests. The best first real refactor spike is RAII cleanup of existing Arcopolis prompt transaction begin/end pairs, because it reduces a real backend risk, is local to Arcopolis-owned code, and can be validated with existing prompt tests plus narrow additions.

Do first:

- Build the Arcopolis backend contract matrix.
- Use the proven Windows LLVM coverage path or land it as an optional local recipe; keep it Arcopolis-scoped and non-gating unless explicitly decided otherwise.
- Add local typed results and RAII guards in Arcopolis-owned code.
- Harden fail-loud prompt behavior and transcript/snapshot contracts.
- Grow adapter/facade boundaries in new files before moving shared legacy files.
- Treat source reorganization as earned architecture: tests first, adapters second, moves last.

Do not do:

- No big-bang rewrite.
- No broad raw-pointer/smart-pointer migration.
- No global exceptions/coroutines/modules/threading push.
- No UI/simulation "separation" by stubbing, bypassing, or faking state.
- No serialization or coordinate-system refactors without migration and map/reality-bubble tests.

This supports Arcopolis because it focuses modernization on the actual product risk: making BN a faithful authoritative backend for an external GUI without corrupting the engine's input, turn, prompt, save/load, and snapshot semantics.

## 10. Adversarial red-team claim audit

Workflow used for this audit:

- Extract the strategy's actionable claims, not every background sentence.
- Attack each claim as if reviewing a risky modernization PR.
- Require repo evidence for Arcopolis-specific claims.
- Require at least one citable external source where the claim reaches beyond this repo; prefer two or more examples.
- Mark contradictions, analogy-only evidence, and open verification work instead of smoothing them over.

Citation keys:

- [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines)
- [Clang C++ status](https://clang.llvm.org/cxx_status.html)
- [MSVC C++ conformance](https://learn.microsoft.com/en-us/cpp/overview/visual-cpp-language-conformance)
- [cppreference `std::expected`](https://en.cppreference.com/w/cpp/utility/expected)
- [cppreference `std::span`](https://en.cppreference.com/w/cpp/container/span)
- [Microsoft `std::span`](https://learn.microsoft.com/en-us/cpp/standard-library/span-class)
- [cppreference `std::ranges::to`](https://en.cppreference.com/w/cpp/ranges/to)
- [LLVM Coding Standards](https://llvm.org/docs/CodingStandards.html)
- [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html)
- [Chromium C++ Style Guide](https://chromium.googlesource.com/chromium/src/+/main/styleguide/c++/c++.md)
- [Unreal Engine C++ Coding Standard](https://dev.epicgames.com/documentation/en-us/unreal-engine/epic-cplusplus-coding-standard-for-unreal-engine)
- [Dolphin Contributing Guide](https://github.com/dolphin-emu/dolphin/blob/master/Contributing.md)
- [OpenRCT2 Contributing Guide](https://github.com/OpenRCT2/OpenRCT2/blob/develop/CONTRIBUTING.md)
- [OpenMW README](https://gitlab.com/OpenMW/openmw/-/raw/master/README.md)
- [Godot 4 stable engine architecture docs](https://docs.godotengine.org/en/stable/engine_details/architecture/index.html)
- [Godot 4 stable unit testing docs](https://docs.godotengine.org/en/stable/engine_details/architecture/unit_testing.html)
- [Godot 4 stable internal rendering architecture](https://docs.godotengine.org/en/stable/engine_details/architecture/internal_rendering_architecture.html)
- [Ullmann et al., game engine architecture recovery](https://arxiv.org/abs/2303.02429)
- [Politowski et al., Are Game Engines Software Frameworks?](https://arxiv.org/abs/2004.05705)
- [Fowler, Strangler Fig Application](https://martinfowler.com/bliki/StranglerFigApplication.html)

Game-industry evidence matrix:

| Example                                    | Relevant lesson for this strategy                                                                                                                                                                                                                                                       | How far the analogy should go                                                                                                                                                    |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unreal Engine                              | A major commercial game engine treats coding standards as maintenance and cross-compiler compatibility tools; it selectively adopts standard-library facilities while preserving engine idioms and API consistency.                                                                     | Strong support for selective modernization and local-style discipline; Unreal's custom framework does not imply BN should copy Unreal idioms.                                    |
| Godot                                      | Public Godot 4 stable docs split engine architecture into source-organization, rendering, and testing topics; `RenderingDevice` is an explicit abstraction layer for modern rendering methods, with OpenGL called out separately; C++ unit tests are documented as part of engine work. | Strong support for explicit subsystem boundaries and test-backed engine changes; Godot does not prove Arcopolis prompt equivalence.                                              |
| OpenMW                                     | A game-engine recreation treats original-game compatibility, mod behavior, and even quirky/bug-dependent behavior as compatibility questions handled case by case.                                                                                                                      | Strong support for Arcopolis fidelity discipline: the existing engine behavior is the spec. OpenMW is a reimplementation, while Arcopolis is backend-driving an existing engine. |
| Dolphin                                    | A mature emulator/game-adjacent C++ project documents its C++ standard, formatting, and readability limits around modern C++ features.                                                                                                                                                  | Strong support for policy-gated modernization and avoiding mechanical feature use.                                                                                               |
| OpenRCT2                                   | The project asks bug reporters for reproduction steps and saved games when possible.                                                                                                                                                                                                    | Strong support for saved-game fixtures as high-value evidence, but not as sufficient proof for all engine refactors.                                                             |
| Game-engine architecture recovery research | Research on Cocos2d-x, Godot, and Urho3D highlights subsystems such as rendering, input, resource management, editor, and core, and emphasizes understanding subsystem coupling.                                                                                                        | Good support for mapping boundaries before moving files; it is not a prescriptive refactor plan for BN.                                                                          |
| Open-source game-engine framework research | Survey/code research finds game engines differ from ordinary frameworks and are often built for control over source/environment and specific games.                                                                                                                                     | Useful warning against blindly importing enterprise modernization patterns; Arcopolis needs game-engine-specific fidelity and content/save/load thinking.                        |

1. Claim: BN already builds as C++23; modernization is practice selection, not standard selection.
   Red-team attack: A `CMAKE_CXX_STANDARD 23` setting does not prove every compiler, standard library, or upstream target can use every C++23 feature.
   Repo evidence: `CMakeLists.txt:318-320` requires C++23 and disables extensions; `CMakePresets.json:10-27` and `CMakePresets.json:103-134` show distinct MSVC and Clang-oriented build routes.
   External evidence/examples: Clang and MSVC both publish feature-by-feature conformance pages, which supports the concern that "C++23 mode" and "all desired C++23 library features work everywhere" are different claims. Unreal's coding standard also ties coding rules to cross-compiler compatibility, and Dolphin documents its active C++ standard instead of assuming every newer feature is acceptable.
   Contradictions/limits: No contradiction with the repo setting; the limit is toolchain granularity. A target-compiler matrix is still required before using `std::expected`, `std::ranges::to`, modules, or other newer facilities broadly.
   Conclusion: Strong, but only at the language-mode level.

2. Claim: Big-bang modernization is inappropriate.
   Red-team attack: A broad rewrite might reduce long-term complexity faster than cautious incrementalism, especially if the codebase is already diverging for Arcopolis.
   Repo evidence: `.clang-tidy:49-62` disables several broad modernize checks; Arcopolis constraints require small, validated spikes; the agent map names upstream-hot files that already carry recurring conflict risk.
   External evidence/examples: The C++ Core Guidelines explicitly frame large old-system adoption as gradual; LLVM discourages large style-only churn; Fowler's legacy modernization writing argues for gradual replacement through small additions and coexistence. In game-engine terms, Godot documents explicit engine architecture areas rather than treating modernization as a syntax pass, and the game-engine architecture-recovery paper argues for understanding subsystem coupling before changing responsibilities.
   Contradictions/limits: Fowler is about application modernization, not C++ syntax cleanup. The analogy is still relevant because Arcopolis is both a backend boundary effort and a fork-maintenance problem.
   Conclusion: Strong. A big-bang rewrite is the wrong default for this repo.

3. Claim: Existing local style/tooling supports selective modern C++ but not mechanical conversion.
   Red-team attack: The AGENTS rules are stricter than upstream Bright Nights and might overfit one branch's preferences.
   Repo evidence: `.clang-tidy:14-22` enables modernize/performance/readability families, while `.clang-tidy:49-62` disables selected broad checks; AGENTS requires C++23 idioms for new code but warns against modifying broad shared areas casually.
   External evidence/examples: Unreal explicitly frames standards around maintenance, readability, source exposure, and cross-compiler compatibility; Dolphin documents modern C++ use while still warning against readability-hostile overuse such as indiscriminate `auto`; Google and LLVM add non-game support for reader optimization and local consistency.
   Contradictions/limits: Google currently targets C++20 in its public guide, so it is not evidence for using C++23 everywhere. It is evidence for policy-gated feature selection.
   Conclusion: Strong. Selective modernization is consistent with both local tooling and large-codebase practice.

4. Claim: Prompt/UI modernization must preserve real input-loop behavior.
   Red-team attack: If final game state matches, requiring the exact active input loop could slow delivery without user-visible benefit.
   Repo evidence: `src/arcopolis_backend_input.h:49-52` states the served-category invariant; `src/input.cpp:931-948` routes backend nested input through the active input context; `src/ui.cpp:153-162` un-aborts `uilist` only under its transaction; `src/popup.cpp:326-339` shows the query popup loop path.
   External evidence/examples: OpenMW's README explicitly treats compatibility with original Morrowind behavior and bug-dependent mods as a case-by-case engine concern; Godot 4's rendering docs treat renderer abstraction as an explicit architecture layer for modern rendering methods while explicitly excluding OpenGL from `RenderingDevice`; C++ Core Guidelines I.30 supports encapsulating dangerous/ugly details rather than spreading shortcuts.
   Contradictions/limits: The external sources cannot prove Arcopolis level-4 equivalence. They support the game-engine norm that compatibility boundaries must be explicit, including explicit limits such as Godot's OpenGL caveat. The decisive evidence is the repo's own invariant.
   Conclusion: Strong for Arcopolis. Same final state is not enough.

5. Claim: Arcopolis has witnessed level-4 prompt paths, not generic prompt-class support.
   Red-team attack: If several prompt families already work, maybe the architecture generalizes and the doc is being too conservative.
   Repo evidence: `docs/arcopolis/ARCOPOLIS_STATE.md:10-21` lists four witnessed level-4 paths and explicitly says this is not prompt-class support; `docs/arcopolis/40_SPIKE19_BACKEND_UI_BOUNDARY.md:36-53` calls out the inventory selector gap.
   External evidence/examples: OpenMW's compatibility stance supports refusing to generalize beyond witnessed behavior; Godot's architecture docs show subsystem boundaries are documented explicitly; LLVM and Google support local consistency and low-surprise changes in large codebases.
   Contradictions/limits: External support is analogy-only for the exact prompt taxonomy. This claim lives or dies on Arcopolis docs and tests.
   Conclusion: Strong, repo-specific. Do not advertise generic prompt support.

6. Claim: Static analysis is useful but cannot prove backend input equivalence.
   Red-team attack: Static analysis and clang-tidy may catch enough unsafe patterns that extra runtime fixtures become redundant.
   Repo evidence: `docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:38-44` distinguishes test layers and their limits; `docs/arcopolis/45_WINDOWS_COVERAGE_FEASIBILITY.md:508` separately states that coverage is not backend equivalence; prompt behavior depends on runtime transaction state and active input loops.
   External evidence/examples: Godot 4 documents C++ unit tests as normal engine-development practice using doctest, a dedicated `tests/` directory, `tests=yes`, and the `--test` runner; Unreal ties coding conventions to maintainability but not to behavior proof; the C++ Core Guidelines encourage static checking/tools. The combination supports "tools plus tests", not "tools instead of tests".
   Contradictions/limits: Static analysis can prove some local properties, and Spike 22 shows line/region/function coverage can prove execution. Neither proves witnessed GUI-equivalent input flow.
   Conclusion: Strong. Static analysis and coverage belong in the workflow, but neither is equivalence evidence.

7. Claim: Saved fixtures are high-value game-engine refactor evidence.
   Red-team attack: Fixture saves can be stale, narrow, or too implementation-specific; they may create false confidence.
   Repo evidence: `docs/arcopolis/TEST_FIXTURES.md:3-13` documents committed fixture worlds and resolver order; `docs/arcopolis/44_TEST_COVERAGE_AUDIT.md:43` notes fixture worlds are not migration tests; `docs/arcopolis/45_WINDOWS_COVERAGE_FEASIBILITY.md:397` measured all nine fixture regressions under an instrumented game binary and showed they cover paths Catch2 does not.
   External evidence/examples: OpenRCT2 asks for steps to reproduce and saved games when possible; OpenMW exposes `--load-savegame` and centers compatibility on real game content; Godot documents repeatable C++ unit-test infrastructure for engine behavior.
   Contradictions/limits: OpenRCT2's saved-game guidance is bug-report evidence, not a full refactor-safety model. Spike 22 makes the fixture value stronger by measuring complementary coverage, but fixtures still need drift checks and broader contracts before they can guard deep engine changes.
   Conclusion: Strong as evidence, still weak as sole proof.

8. Claim: `std::expected`-style typed errors fit Arcopolis command/protocol code.
   Red-team attack: Adopting `std::expected` could fragment error handling or fail on older standard libraries.
   Repo evidence: Arcopolis tests already assert typed prompt error kinds, including unexpected prompt behavior in `tests/arcopolis_backend_input_test.cpp:1038-1040`; the command/protocol boundary naturally returns success-or-error data.
   External evidence/examples: cppreference documents `std::expected` as a C++23 expected-value-or-error vocabulary type; MSVC and Clang conformance pages show why library availability still must be checked feature by feature. Unreal and Dolphin both provide game/engine-adjacent examples of policy-gating standard-library adoption rather than adopting all available features mechanically.
   Contradictions/limits: The strategy should not claim direct `std::expected` is always available. It should allow a local typed-result shim until the compiler/library matrix is proven.
   Conclusion: Good, scoped. Use typed errors first; choose the concrete type after toolchain validation.

9. Claim: `std::span` and `string_view` can help leaf APIs but are not ownership tools.
   Red-team attack: Views are lifetime hazards and may make bugs subtler than explicit containers or pointers.
   Repo evidence: No broad repo-wide `span` need was proven; this strategy only recommends leaf API use after lifetime review.
   External evidence/examples: cppreference defines `std::span` as a non-owning contiguous view; Microsoft documents it as a lightweight view and says it does not own or free the underlying storage; Unreal warns against mixing engine and standard-library idioms inside the same API, which reinforces using views only where the API boundary is explicit.
   Contradictions/limits: `span` improves bounds/shape expression, not lifetime ownership. Every use still needs local lifetime proof.
   Conclusion: Good, narrow. Use views at explicit boundaries, not as ownership modernization.

10. Claim: Ranges and algorithms are good when clearer but should not be mass-applied.
    Red-team attack: AGENTS says to prefer ranges, so the plan may be too timid about replacing loops.
    Repo evidence: `.clang-tidy:59` disables `modernize-loop-convert`; existing code includes hot imperative paths such as `game::do_turn`; `tests/algo_test.cpp` shows the repo already has algorithm helpers.
    External evidence/examples: cppreference documents `std::ranges::to`; Dolphin cautions against modern syntax when it harms reader clarity; Unreal, Google, and LLVM all prioritize maintainability and local consistency over novelty.
    Contradictions/limits: The AGENTS rules are intentionally modern for new/touched code. That does not imply a repo-wide loop rewrite is safe.
    Conclusion: Strong. Prefer ranges in new scoped code; avoid mechanical mass conversion.

11. Claim: Modules, coroutines, broad threading, and concepts-heavy APIs are poor near-term fits.
    Red-team attack: These features might unlock cleaner architecture faster, especially for protocol and backend separation.
    Repo evidence: The current risks sit in global turn/input/prompt/save behavior and test gaps, not in missing language expressiveness; `CMakePresets.json` shows multiple toolchain routes that would all need support.
    External evidence/examples: Unreal's standard-library section is selective about engine idioms and platform consistency; Dolphin documents the active C++ standard instead of treating newest-language adoption as automatic; LLVM cautions against depending on features not supported across intended toolchains; Clang/MSVC conformance pages show feature support is granular.
    Contradictions/limits: This is not a permanent ban. Coroutines or modules could become appropriate after upstream policy, compiler support, and architecture boundaries mature.
    Conclusion: Strong near-term avoid; revisit later with a concrete subsystem and toolchain matrix.

12. Claim: RAII transaction guards are the best first refactor spike.
    Red-team attack: RAII is a generic best-practice answer and may distract from more valuable protocol work.
    Repo evidence: Arcopolis prompt transactions have begin/resolve/end semantics in `src/arcopolis_backend_input.cpp`; tests verify armed versus unarmed prompt behavior in `tests/arcopolis_backend_input_test.cpp:487-506`, `tests/arcopolis_backend_input_test.cpp:651-660`, and `tests/arcopolis_backend_input_test.cpp:1025-1042`.
    External evidence/examples: C++ Core Guidelines resource-management guidance favors RAII; Unreal's standard emphasizes maintainability and clear ownership/parameter intent; Dolphin discourages raw ownership patterns when standard-library ownership tools solve the problem.
    Contradictions/limits: RAII only helps if the guard's scope exactly matches the active backend transaction. A too-wide guard would make equivalence worse, not better.
    Conclusion: Recommended first because it is local, testable, and risk-reducing.

13. Claim: Source reorganization should be adapter-first and move-last.
    Red-team attack: Moving files/directories earlier may create clarity and force boundaries faster.
    Repo evidence: `docs/agent-map/01_MODULES_THIN_INDEX.md:10-22` identifies hot seams in `src/main.cpp`, `src/game.cpp`, `src/handle_action.cpp`, and `src/arcopolis_*`; `docs/agent-map/04_RISK_ZONES.md:6-21` flags backend/UI and renderer hazards. AGENTS also documents recurring upstream conflicts in shared files.
    External evidence/examples: Godot documents architecture/source organization as explicit engine knowledge; game-engine architecture-recovery research emphasizes subsystem detection and coupling assessment; Fowler's Strangler Fig approach supports gradual modernization through small additions and transitional architecture; LLVM discourages large-scale reformatting churn and says to follow local style in existing code.
    Contradictions/limits: Source movement can be the right end state. The contradiction is timing: moving first increases merge/conflict cost before behavior boundaries are proven.
    Conclusion: Strong. Build adapters and tests first; move files only after the boundary is stable and conflict cost is measured.

14. Claim: The layered future organization should preserve upstream access rather than fork the engine into an Arcopolis-only rewrite.
    Red-team attack: If Arcopolis needs a separate frontend and backend contract, a hard fork may be cheaper than preserving upstream shape.
    Repo evidence: AGENTS says `main` mirrors upstream and `arcopolis` rebases on top; it also names recurring conflict points and requires scoped, validated Arcopolis changes. The current source hotspots still route through BN's real `game::do_turn()`, `game::handle_action()`, and active prompt/input loops.
    External evidence/examples: OpenMW's engine-recreation stance demonstrates the game-industry value of preserving compatibility with original content and quirks; Godot's architecture docs show a large engine can document explicit subsystems without treating all existing code as disposable; game-engine framework research warns that engines differ from ordinary frameworks and are often built for control over a specific game's environment; Fowler adds general support for gradual coexistence.
    Contradictions/limits: This is a strategic maintenance claim, not a benchmarked cost model. It needs measured rebase conflict time over several upstream syncs. The game-industry examples strengthen the direction but do not decide the fork economics alone.
    Conclusion: Plausible and aligned with the branch model. Keep upstream access as a design constraint until measured conflict cost says otherwise.
