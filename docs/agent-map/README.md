# Agent orientation map (`docs/agent-map/`)

This folder is a **practical orientation map for agents working in this fork** of
Cataclysm: Bright Nights. It exists to get you to the right files and seams quickly.

**It is intentionally partial.** It is _not_ official, exhaustive BN architecture documentation.
It favors stable entry points, seams, and risk zones over complete coverage. Before editing any
subsystem, read the current code and its tests — do not treat this map as ground truth.

## Contents

- [`00_OVERVIEW.md`](00_OVERVIEW.md) — repo shape and engine entry points (main loop, `do_turn`,
  action dispatch, the global `game` singleton) plus the Arcopolis backend seam.
- [`01_MODULES_THIN_INDEX.md`](01_MODULES_THIN_INDEX.md) — a thin, per-subsystem "start here" index
  (anchor files + the one seam to read first). Ordered by near-term Arcopolis usefulness.
- [`02_BUILD_AND_TOOLCHAIN.md`](02_BUILD_AND_TOOLCHAIN.md) — build/test navigation: CMake, presets,
  targets, Windows notes, `compile_commands.json`, formatting/linting.
- [`04_RISK_ZONES.md`](04_RISK_ZONES.md) — the danger checklist: backend-UI invariant, `test_mode`,
  save/load compatibility, generated files, the object-ownership memory model, threading, etc.

(There is deliberately no `03` or `05` in this v0 — see "deferred" notes in `01`/`02`.)

## Conventions

- Every load-bearing claim cites a repo-relative `path:line` (e.g. `src/game.cpp:1884`). Line
  numbers drift; if one looks off, re-check with `rg`/your editor.
- Arcopolis-specific rules, build environment, and the backend fidelity/equivalence contract live in
  [`AGENTS.md`](../../AGENTS.md) and [`docs/arcopolis/`](../arcopolis/) (start with
  `docs/arcopolis/ARCOPOLIS_STATE.md`). This map does not duplicate them.
