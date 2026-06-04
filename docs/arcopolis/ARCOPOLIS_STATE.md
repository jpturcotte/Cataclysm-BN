# Arcopolis backend — current state (truth as of Spike 5, 2026-06-03)

A single-page checkpoint of what the Arcopolis backend **is today**, so you don't have to
reconstruct it from the per-spike history. The numbered `NN_SPIKE*.md` docs are the chronological
record (including a **failed** Spike 3); **this page is the current truth.** When they disagree, this
page wins — or fix it.

## Purpose

Run Cataclysm-BN **headless as a simulation backend** for a separate "Arcopolis" frontend: load a
world, drive faithful engine turns from a script, and export read-only JSON the frontend (or an
offline viewer) consumes. No new gameplay; the engine remains the single source of truth.

## How to run

| Mode              | Flags                                                                                              | Output                                           |
| ----------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| One-shot snapshot | `--arcopolis-export-current-view <path>` `--world <w>` [`--arcopolis-command <file>`]              | one snapshot JSON                                |
| Stateful script   | `--arcopolis-run-script <script.json>` `--arcopolis-export-dir <dir>` `--world <w>` [`--seed <s>`] | `NNN_<name>.json` per `export` + `session.jsonl` |

Common: `--userdir <dir>`. Headless runs end with `std::_Exit(code)` (skips the fragile global
teardown that corrupts the heap on a fully-loaded game). World options must keep
`TURN_DURATION <= 0.005` or `handle_action` drains `moves` by wall-clock.

## Architecture (the load-bearing design)

The backend is a **pure input source**, not a turn driver:

- The engine's `game::do_turn()` runs **verbatim**. Each backend command resolves to an engine
  `action_id` consumed at the real `handle_action()` input seam (the same slot a keypress uses).
- The **engine alone** owns turn-end (`moves<=0`) and the world tick (bottom half of `do_turn`).
- **Clean-park:** when the script is exhausted while `moves > 0`, the provider sets
  `backend_input_done()` and `do_turn` returns **before** its bottom half — "the player walked away"
  (faithful; world not ticked). Gated on `backend_session_active()` so normal play never reaches it.
- Mechanism in use is **M1** (synchronous input-seam callback). M2 (split `do_turn`) and M3
  (coroutine, for a future live protocol) are designed-but-unused.

**Fidelity rules (non-negotiable):** GUI behavior == engine behavior == the behavior. Never fake
engine state. Answer GUI-vs-headless questions **from the code**, never by spinning up experiments.
The Spike 3 failure came from driving `command → do_turn` (which inverts action/top-half ordering);
3.1A replaced it with the input seam. Do not resurrect `apply_command`-style turn driving.

## The export contract

### Snapshot `NNN_<name>.json` (`schema_version` 1)

`session` (export_index, step_index|null, export_name, final) · `backend` (game_version,
save_version, turn) · `avatar` (name, pos_local[xyz], pos_abs[xyz], z, hp, hp_max, stamina, moves,
pain, thirst, fatigue, stored_kcal, kcal_percent) · `map_bounds` (origin_abs_sm[xyz], size_x, size_y,
z) · `tiles[]` (x, y, z, ter, furn, seen, **is_avatar** on the avatar's tile only — Spike 5) ·
`messages[]` (text, type — **type currently blank**, deferred) · `diagnostics.warnings[]`. Tiles are
a radius-12 single-z square window around the avatar, clamped to the loaded bubble.

### Transcript `session.jsonl` (`schema_version` 1, one JSON object per line, flushed per event)

`session_start` (world, **seed** opt — Spike 5, export_dir, game_version) · `command` (step_index,
command, direction opt, action_id opt, status="queued") · `export` (step_index|null, export_index,
name, path, final, turn, pos_abs, moves — scalars equal the named snapshot) · `error` (step_index
opt, kind, detail, exit_code) · `session_end` (status, snapshots, commands, final_turn opt,
final_pos_abs opt).

### Commands

`wait` → `ACTION_PAUSE` (`do_pause`); `move` + cardinal `direction` (`move_n`/`move_s`/`move_e`/`move_w`)
→ `ACTION_MOVE_*`. Diagonals, vertical, and everything else are rejected with a typed error.

## Capabilities by spike

| Spike | What                                                                     | State                                   |
| ----- | ------------------------------------------------------------------------ | --------------------------------------- |
| 0     | headless load + one-shot snapshot                                        | ✅                                      |
| 1     | `wait` command (bootstrap turn)                                          | ✅                                      |
| 2     | persistent `--arcopolis-run-script` + `--arcopolis-export-dir` (T→T→T+1) | ✅                                      |
| 3     | movement via `command → do_turn`                                         | ❌ failed (turn inversion) — superseded |
| 3.1A  | input-seam architecture (the fix)                                        | ✅                                      |
| 3.1B  | clean-park hardening + final-on-exit snapshot                            | ✅                                      |
| 3.1C  | `session.jsonl` transcript                                               | ✅                                      |
| 4     | offline viewer / contract consumer (Python → HTML)                       | ✅                                      |
| 5     | `is_avatar` marker + `seed` in `session_start`                           | ✅ (this pass)                          |

## Source & tests

`src/arcopolis_export.{h,cpp}` (snapshot) · `arcopolis_command.{h,cpp}` (verb→action_id, errors) ·
`arcopolis_script.{h,cpp}` (script runner) · `arcopolis_backend_input.{h,cpp}` (input-seam provider,
clean-park, final snapshot) · `arcopolis_session_log.{h,cpp}` (transcript). Flags wired in
`src/main.cpp`; the seam branch lives at `src/handle_action.cpp`, the clean-park at `src/game.cpp`.
Unit tests: `tests/arcopolis_*_test.cpp` (`[arcopolis]` tag). Consumer:
`tools/arcopolis_viewer/make_report.py` (stdlib-only).

## Deferred backlog

- **Richer read-only export:** dynamic entities (monsters/NPCs/items/fields/vehicles) (#2), per-tile
  symbol/colour (#1), message type/severity (#4 — needs a public `Messages::` accessor), multi-z (#5).
  Dynamic-entity export is the linchpin: it also unblocks the deferred **world-tick regression
  harness** (needs a `--arcopolis-new-world` generator + dynamic state to witness a tick — see
  [10_SPIKE3_1B_CLEAN_PARK_HARDENING.md](10_SPIKE3_1B_CLEAN_PARK_HARDENING.md)).
- **Live protocol:** bidirectional commands over a transport (socket/stdin) with framing/acks (the
  M3 path) — everything today is file-based.
- **Richer commands:** examine/look, interaction (open/close/smash/pickup), inventory, targeting,
  diagonals, vertical.

## Build (Windows)

Activate the VS DevShell, append `C:\dev\ccache` to PATH, configure with `-G Ninja
-DCMAKE_BUILD_TYPE=RelWithDebInfo` into **one** `out/build/win-rel-deb` dir (game + tests share the
`cataclysm-bn-tiles-common` OBJECT lib; a second dir exhausts the disk), then `cmake --build
.\out\build\win-rel-deb --target cataclysm-bn-tiles cata_test-tiles`. Exact commands +
disk/ccache notes: [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md).
