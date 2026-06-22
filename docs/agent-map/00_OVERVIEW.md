# Overview: repo shape and engine entry points

> Partial, practical orientation map. Not exhaustive. See [`README.md`](README.md).

## What this is

Cataclysm: Bright Nights (CBN) is a roguelike with sci-fi elements set in a post-apocalyptic world
(`README.md:17-28`). It is a fork of Cataclysm: Dark Days Ahead (`README.md:30`). The engine is a
large C++23 codebase with a flat `src/` tree (~890 top-level files).

## This fork's purpose (Arcopolis)

This fork is investigating using BN as a **headless simulation backend** for a separate, future,
mouse-first frontend (`AGENTS.md:3-37`). The current phase implements that backend boundary in small,
validated spikes, gated behind `--arcopolis-*` modes. The single-page current-state checkpoint is
`docs/arcopolis/ARCOPOLIS_STATE.md` (read it first for backend work); the numbered
`docs/arcopolis/NN_SPIKE*.md` files are the chronological record.

## Engine flow (the spine)

- **Entry point:** `main()` in `src/main.cpp`. The game object is constructed at
  `src/main.cpp:918` (`g = std::make_unique<game>()`).
- **Main loop:** an outer menu/world loop `while( true )` at `src/main.cpp:1046` wraps the inner
  turn loop `while( !g->do_turn() )` at `src/main.cpp:1062`.
- **Turn:** `bool game::do_turn()` at `src/game.cpp:1988` is the per-turn pipeline.
- **Input → action:** `bool game::handle_action()` at `src/handle_action.cpp:1842` resolves input to
  an `action_id` and dispatches it.
- **Global singleton:** `game *g` — declared `extern std::unique_ptr<game> g;` at `src/game.h:63`,
  defined at `src/game.cpp:444`. It owns the avatar, the in-play `map`, calendar, weather, and the
  creature trackers. Most subsystems reach shared state through `g` / `get_avatar()` / `get_map()`.

## Top-level directory map

- `src/` — the engine (flat layout; subdirs: `compute/` GPU, `lua/` + `sol/` vendored Lua/sol2,
  `platform/`, `shaders/`, `utils/`, `third-party/`).
- `data/` — game content: JSON (`data/json/`, ~1888 files), `data/lua/`, `raw/`, `names/`, `mods/`.
- `tests/` — Catch2 test suite (~176 `*.cpp` in `tests/`; the vendored framework header is in
  `tests/catch/`).
- `tools/` — `format/` (JSON formatter), `clang-tidy-plugin/` (custom `cata-*` checks),
  `arcopolis_*` clients/viewer, `gfx_tools/`, `iwyu/`, `json_tools/`.
- `docs/` — markdown docs: player/dev guides (`docs/en/`), this map (`docs/agent-map/`), and the
  Arcopolis record (`docs/arcopolis/`).
- Other: `gfx/` (tilesets), `sound/`, `lang/` (translations), `build-scripts/`, `CMakeModules/`,
  `android/`, `pch/`, `doxygen_doc/` (a manual Doxyfile + `pages.h`, not pre-generated).

## Arcopolis orientation (the protected seam)

The backend turns BN into an input source without touching UI/renderer code or mutating state
directly. The data flow is:

```
external command / JSONL protocol
        -> backend input source        (src/arcopolis_command.*, src/arcopolis_live.*, src/arcopolis_script.*)
        -> game::handle_action()        (hook at src/handle_action.cpp:1858: arcopolis::next_backend_action(), guarded by backend_session_active() at :1857)
        -> game::do_turn()              (src/game.cpp:1988)
        -> read-only snapshot + transcript  (src/arcopolis_export.*, src/arcopolis_session_log.*)
```

The seam guard is `arcopolis::backend_session_active()` (`src/arcopolis_backend_input.cpp:535`); the
pull-based action source is `arcopolis::next_backend_action()` (`src/arcopolis_backend_input.cpp:627`).
The backend-UI boundary rules (no curses window / no render primitive in any build) are documented in
`docs/arcopolis/40_SPIKE19_BACKEND_UI_BOUNDARY.md` and summarized in `AGENTS.md:56`. These rules are
load-bearing — see [`04_RISK_ZONES.md`](04_RISK_ZONES.md) before touching any backend seam.
