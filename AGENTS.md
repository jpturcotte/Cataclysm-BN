# Cataclysm: Bright Nights - Agent Guidelines

## Arcopolis Project Context

Arcopolis is a separate game/project concept being investigated on top of Cataclysm: Bright Nights.

Arcopolis is not currently an implemented game. It began as repository research and has moved into implementing the Bright Nights simulation backend in small, validated spikes (see `docs/arcopolis/ARCOPOLIS_STATE.md`).

### Game concept

Arcopolis is intended to be a dense, vertical, cyberpunk-style roguelike/survival-sim focused on combat, exploration, looting, equipment management, hazards, NPCs, factions, and mission-like traversal through stacked urban spaces.

The goal is not to make a simple roguelike. The goal is to investigate whether Bright Nights can provide the simulation base.

### Why Bright Nights

Bright Nights already contains many systems Arcopolis may need: world simulation, local map/reality-bubble style gameplay, items, equipment, character state, NPCs, monsters, factions, environmental hazards, pathfinding, save/load, debug tools, JSON data loading, and mod/content infrastructure.

### Problem being investigated

The existing Bright Nights player-facing UI is not the desired final UI for Arcopolis.

A previous attempt at GUI/overlay work suggested that bridging or replacing individual existing UI screens may become awkward and high-maintenance. The current hypothesis is that Bright Nights might be more useful as an authoritative simulation backend than as the final player-facing client.

### Target architecture under investigation

- Bright Nights remains authoritative for simulation, save/load, rules, world state, and content loading.
- A future Arcopolis frontend is separate, graphical, file-based or protocol-based, and mouse-first.
- The frontend sends high-level commands to the backend.
- The backend validates and applies commands.
- The backend returns snapshots, deltas, events, and query responses.
- The frontend never directly mutates simulation state.
- The project must not bridge existing Bright Nights UI screens one by one unless explicitly directed.

### Current phase

Implementing the backend boundary in small, validated spikes — Spikes 0–5 are merged. Changes now routinely include real `src/` / tests / tooling (scoped to the `--arcopolis-*` modes), not just docs. See `docs/arcopolis/ARCOPOLIS_STATE.md` for the current state and the deferred backlog.

### Default Arcopolis rules

- Do not modify gameplay source code unless explicitly asked.
- Do not modernize or replace the Bright Nights UI during exploration.
- Do not port old GUI/overlay work during exploration.
- Do not bridge existing UI screens one by one.
- Do not add third-party dependencies.
- Default to small, additive, well-tested changes scoped to `src/arcopolis_*` and `docs/arcopolis/`; modify shared engine files (the turn loop, `messages`, `map`, …) only when a spike justifies it and the change is gated behind the `--arcopolis-*` modes.
- When exploring code, record exact file paths, functions, classes, and call paths.
- If uncertain, state uncertainty and list what to inspect next.
- Use PowerShell commands for Windows-local instructions.

### Arcopolis backend fidelity (NON-NEGOTIABLE)

**The GUI behavior is the engine behavior is the behavior, period.** There is no separate "headless mode" to
invent — BN's code IS the spec. When driving BN headlessly (the `--arcopolis-*` export/command modes),
reproduce EXACTLY what the engine does for the same action.

- **Never override engine state/flags to make output look nicer or to make a counter move.** Worked example:
  a `wait` issued right after a load is the engine's _bootstrap turn_ — `game::setup()` leaves
  `game::new_game == true`, so the first `do_turn()` deliberately skips `calendar::turn += 1_turns`
  (src/game.cpp:1879) and processes the world at the loaded turn `T` without advancing the clock, exactly as
  pressing `'.'` once in the GUI. Do **NOT** clear `new_game` to force a tick (an earlier Spike-1 build did;
  it ran the turn at `T+1`, one tick ahead of the GUI — wrong, reverted).
- **If the lifecycle makes faithful behavior inconvenient, fix the lifecycle, not the behavior.** A one-shot
  (load-per-command) wait re-pays the bootstrap turn every time, so the clock never advances. That is a signal
  to build a _persistent_ backend (load once → bootstrap turn happens once → every later command is a normal,
  clock-advancing turn), NOT to fake an advance.
- **Answer "do headless and GUI differ?" from the code, decisively.** Read `do_turn` / the action path and
  state the answer; do not spin up little experiments to defer the question. (Litigating this the slow way
  cost a full session once — don't repeat it.)

### Backend documentation

**Read first (current truth):** `docs/arcopolis/ARCOPOLIS_STATE.md` — a single-page checkpoint of the backend's current architecture (the input-seam design), the snapshot/transcript contract, capabilities by spike, and the deferred backlog. The numbered `NN_SPIKE*.md` files are the chronological record (including the failed Spike 3); list the live set with `Get-ChildItem docs/arcopolis`.

### Arcopolis local setup checks

Use PowerShell for Windows-local checks:

```powershell
Get-Location
git status
git branch --show-current
git remote -v
Get-Content .\AGENTS.md -TotalCount 160
New-Item -ItemType Directory -Force .\docs\arcopolis
```

### Arcopolis Windows build route

For this Windows/Codex worktree, the known-good build-backed exploration route is Visual Studio 2022 DevShell + MSVC + Ninja + vcpkg, with ccache from `C:\dev\ccache`.

- Activate the Visual Studio 2022 x64 DevShell before configure/build commands.
- Append `C:\dev\ccache` to `PATH` after DevShell activation; do not prepend it, because the real MSVC `cl.exe` should stay first.
- Use short vcpkg temporary roots under `C:\tmp` to avoid Windows `MAX_PATH` failures in dependency builds.
- Prefer the repo-supported Ninja shape from `CMakeSettings.json` for ccache-backed command-line builds; this route has built `cataclysm-bn-tiles` and `cata_test-tiles`. The Visual Studio solution preset can configure with short vcpkg roots, but it is not the proven ccache route.
- Build the game and tests in **one** build dir. `cataclysm-bn-tiles-common` is a CMake OBJECT library shared by `cataclysm-bn-tiles` and `cata_test-tiles`, so build `cata_test-tiles` in the SAME `out/build/win-rel-deb` dir (re-configure with `-DTESTS=True`, then `--target cata_test-tiles`) to reuse the game's compiled objects — only the test sources recompile. A SEPARATE `out/build/win-tests` dir duplicates the entire ~10 GB object tree and has exhausted the disk here (`fatal error C1085: ... No space left on device`).
- See `docs/arcopolis/00_WINDOWS_LOCAL_ENVIRONMENT.md` for the exact current PowerShell commands and the historical failure analysis.

### Arcopolis test world fixture

The headless `--arcopolis-*` modes load a prepared world, and this repo ships none (saves are gitignored).
The canonical `ArcopolisTest` world (avatar in an evac shelter, ~14 nearby monsters, calendar turn
~1,324,801) lives **outside the repo** at `C:\dev\arcopolis-fixtures\` so it survives worktree pruning and
`git clean -fdx`. Copy it into the working tree (the `/arcopolis_user/` sandbox is gitignored) before
running validation:

```powershell
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force
```

`C:\dev\arcopolis-fixtures\README.md` documents the world, how to refresh it, and how to recreate it from
scratch (graphical New Game → one step → Save & Quit). It is a point-in-time snapshot, not auto-synced.

## HARD CONSTRAINTS (NEVER VIOLATE)

Before writing **ANY** code, verify:

| ❌ VIOLATION                           | ✅ REQUIRED                                                                      |
| -------------------------------------- | -------------------------------------------------------------------------------- |
| manual iterator loops (`it++`, `++it`) | `std::ranges::*`, `collection \| std::views::*`, or range-based `for` if clearer |
| `int foo()`                            | `auto foo() -> int`                                                              |
| `Type x = value`                       | `auto x = value`                                                                 |
| `void fn(a, b, c, d, e)`               | `void fn(options_struct)`                                                        |
| `[](){\n return 1; \n }`               | `[](){ return 1; }`                                                              |

**Prefer `std::ranges`/`std::views`/`std::ranges::to`/cata_algo.h for collection work. Avoid manual iterator increment loops unless required by mutation semantics.**

- prefer function-local `using namespace std::views;` and use `transform`/`filter` unqualified.
- prefer function-local `namespace ranges = std::ranges;` and use `ranges::*` without `std::`
- prefer method/function references over lambdas whenever possible, e.g. `transform( &vpart_position::part_index )` instead of `transform( []( const auto &vp ) { return vp.part_index(); } )`.

## Coding Convention

```c++
const auto foo = 3; //< **MUST** use `auto` for type. `const` **MUST** come before `auto`.

auto bar() -> int; //< **MUST** use trailing return types.
using my_callback_t = std::function<auto( int ) -> bool>; //< **MUST** use trailing return types in type aliases.
auto baz() -> int&; // *NOPAD*  //< **MUST** append `// *NOPAD*` for references/pointer returns to prevent astyle bugs.
auto qux() -> int { return 42; } //< **MUST** use single-line functions whenever possible.

auto qux = my_struct{ .a = 1, .b = 2 }; //< **MUST** use designated initializers.
auto two_value() -> my_data; //< **MUST NOT** use `std::pair`/`std::tuple` for multiple return values. Create a struct instead.
auto may_have_value() -> std::optional<int>; //< **MUST** use `std::optional` for functions that may not return a value.
auto may_fail() -> std::expected<int, std::string>; //< **MUST** use `std::expected` for functions that may fail.

/// **MUST** use triple slash for doc comments like rust's.
/// **MUST** use snake_case for functions and variables.
struct comparable {
  int x;
  int y;
  auto operator<=>( const comparable & ) const = default; // *NOPAD* //< **MUST** use `<=>` for comparisons and append `// *NOPAD*` at the end to prevent astyle bugs.
}

auto values = xs
  | std::views::filter( []( const auto & v ) { return v.is_valid(); } ) //< **MUST** use single line expression if it's single line expression
  | std::views::transform( []( const auto & v ) { return v.get_value(); } ) //< **SHOULD** use `auto` for lambda params
  | std::ranges::to<std::vector>(); //< **MUST** use `std::ranges` over for loops for collections.

namespace { // **MUST** use anonymous namespace for internal linkage over `static`.

// **MUST** use options struct for functions with >3 parameters
struct button_options {
  point pos;
  std::string text;
  nc_color fg = c_white;
  nc_color bg = c_black;
  bool enabled = true;
};
auto print_button( const catacurses::window &w, const button_options &opts ) -> void;

} // namespace
```

- **SHOULD NOT** modify existing headers with >10 usages. Create new header with pure functions.
- **MUST** use modern C++23 features.
- **MUST** preserve unused parameter names as comments instead of deleting them, e.g. `bool /*is_avatar*/` not `bool`; applies to functions and lambdas.
- **MUST** keep Lua function parameters typed with EmmyLua/LuaLS annotations, including existing and local helper functions: `---@param` and table `---@class`/`---@field` shapes where parameters are tables. Do not require or add `---@return` solely for annotation enforcement when the return type is inferable. Before touching Lua, inspect the file's annotation style and preserve complete function typing.
- **MUST** fix missing Lua binding type declarations at the binding/doc-generation source; do not hard-code generated binding classes in `data/raw/generate_types.lua` as a shortcut.
- **MUST** test C++ Lua binding behavior with real bound objects when adding or changing bindings; Lua-only mocks may supplement but must not be the sole validation for binding correctness.
- **MUST** use options struct for functions with more than 3 parameters. Use designated initializers at call sites.
- **MUST NOT** manually write an options/struct type at a call site when the function parameter type makes it inferable; use `{ .field = value }` instead of `options_type{ .field = value }`.
- **SHOULD** search for existing solution because it's a large, legacy codebase.
- **MUST** verify helper-specific matching semantics before relying on string prefixes. For overmap terrain `OtMatchType.PREFIX` / `is_ot_match`, pass the base token without a trailing separator, e.g. `"robofachq"`, because the matcher itself requires the following character to be `_`.

## Workflow

## Privacy and Environment Documentation

- **MUST NOT** publish machine-specific absolute paths, local usernames, auth tokens, private environment values, or raw auth/credential command output in docs, PR descriptions, comments, final responses, or committed scripts.
- **MUST** use placeholders for local paths, for example `<repo-root>`, `<user-profile>`, `<vs-install-root>`, and `<path-to-ccache-dir>`.
- **MUST** redact local paths from diagnostic script output by default. If exact paths are useful, require an explicit opt-in flag such as `-RevealPaths`.
- **MUST** summarize credential/auth checks as pass/fail only. Never paste token-like values, full credential helper output, or authenticated account details unless the user explicitly asks.
- When environment discovery needs exact local paths, keep them in transient local notes or command output only, not in committed documentation or PR text.

### WHEN given a link to an issue

- **Context**: Fetch issue details via GitHub MCP.
- **Branch**: Use `coderabbitai/git-worktree-runner` to create branch: `git gtr new <type>/<issue-id>/<issue-slug>`
  - type MUST be one of: `feat`, `fix`, `refactor`, `chore`, `build`, `ci`
- **Code**: Refer to [code changes](#when-working-on-code-changes).
- **PR**: Use [Template](./.github/pull_request_template.md). **DO NOT ADD fluff**. create via `git push && gh pr create --web --fill`.
- After opening or updating a Cataclysm-BN PR, track `gh pr checks` until CI finishes or a concrete blocker is identified; inspect failing job logs, fix branch-owned failures, commit, and push before finalizing. For transient or infrastructure failures, rerun when permitted or report the exact failing job and evidence.
- Before running broad formatter targets, prefer file-scoped formatting for touched files when available; if only a broad target exists, inspect and revert unrelated formatter-only changes before continuing.

### WHEN working on code changes

- **Style**: Follow [Code Style](./docs/en/dev/explanation/code_style.md). Use `_( "text" )` for L10n.
- **Format**: Format code before building/testing.

```sh
# Format C++ code
cmake --build build --target format
# Format JSON files
cmake --build build --target style-json-parallel
# Format scripts
deno fmt
deno task dprint fmt
```

- **Verify**: Build and fix any issues. Do not skip the game binary target when validating code changes; build `cataclysm-bn-tiles` together with tests.

```sh
# Build project and tests
cmake --preset linux-full
cmake --build --preset linux-full --target cataclysm-bn-tiles cata_test-tiles
```

- **Test**: Create/update relevant `tests/` (Catch2).

```sh
# Run Tests
./out/build/linux-full/tests/cata_test-tiles "[optional-filter]"

# Validate JSON
./build-scripts/lint-json.sh

# Check Mods (validates mod JSON files)
./out/build/linux-full/cataclysm-bn-tiles --check-mods

# Generate Lua Documentation (if conflicts with lua_annotations.lua or docs/en/mod/lua/reference/lua.md)
deno task docs:gen
```

- **Commit**: Commit **ATOMICALLY**. **MUST** Follow [Conventional Commits](./docs/en/contribute/changelog_guidelines.md). **MUST NOT** add body/footer unless critical.

## WHEN working on i18n / PO context

- **MUST NOT** reduce requested string/context coverage for review risk or churn. If the user names a word and its meanings, handle every named meaning.
- If adding JSON context requires loader support, add loader support instead of leaving a source uncontexted.
- **MUST** run `msgfmt -f -c -o /tmp/ko.mo lang/po/ko.po` after touching Korean PO files and fix reported errors before PR.
- **MUST** run `./tools/check_po_printf_format.py` after touching PO files and fix reported errors before PR.
- Do not call PO/printf errors pre-existing to skip them when the task touches that locale or validation path.
- If a mistake is found during the task, update AGENTS/skill immediately and fix the current branch before summarizing.

## WHEN translating docs

When translating, MUST search for correct glossary, e.g

```sh
rg -C2 -i '<<TARGET>>' lang/po/<<LANG>>.po | rg -v '^(#:|--)' | head -n 20
rg -C2 -i 'speedway' lang/po/ko.po | rg -v '^(#:|--)' | head -n 20
```

## References

- **Docs**: [Building](./docs/en/dev/guides/building/cmake.md), [Formatting](./docs/en/dev/guides/formatting.md), [Dev Index](./docs/en/dev/).
- **Review**: [LLM Guide](./.github/llm_review_guide.md).

- When fixing a bug, preserve requested behavior and visible content unless the user explicitly asks to remove it; fix the underlying issue instead of suppressing the affected feature.
- When reviewing PRs that stop tracking generated or externally pulled files, verify ignore rules by running the generator/pull command or checking `git status --ignored`; do not assume removed tracked files are ignored.
- When generated or externally pulled files are removed from tracking, verify all CI and release consumers still receive required files or directories.
