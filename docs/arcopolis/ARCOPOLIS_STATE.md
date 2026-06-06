# Arcopolis backend — current state (truth as of Spike 6B, 2026-06-05)

A single-page checkpoint of what the Arcopolis backend **is today**, so you don't have to
reconstruct it from the per-spike history. The numbered `NN_SPIKE*.md` docs are the chronological
record (including a **failed** Spike 3); **this page is the current truth.** When they disagree, this
page wins — or fix it.

## Purpose

Run Cataclysm-BN **headless as a simulation backend** for a separate "Arcopolis" frontend: load a
world, drive faithful engine turns from a script, and export read-only JSON the frontend (or an
offline viewer) consumes. No new gameplay; the engine remains the single source of truth.

## Repository layout (branch model)

The fork follows a fast-moving upstream while carrying this backend work, using a **mirror + rebased
dev branch** layout (set up 2026-06-04):

- **`main` mirrors `upstream/main`** (`cataclysmbn/Cataclysm-BN`) exactly — **no Arcopolis work lives
  on it.** Don't commit here; it only fast-forwards to upstream.
- **`arcopolis` is the development branch** — the Spike 0–5 commits plus all new work, kept linear on
  top of `main`, and the GitHub **default branch**. **Branch and PR off `arcopolis`.**
- `git diff main...arcopolis` is always exactly the backend patch set.

Sync with upstream:

```sh
git fetch upstream
git switch main && git merge --ff-only upstream/main && git push origin main   # mirror; never conflicts
git switch arcopolis && git rebase main                                        # replay patches onto upstream
git push --force-with-lease origin arcopolis
```

`git rerere` replays the two recurring rebase conflicts automatically **once trained**: the `do_turn`
clean-park vs. upstream's sound block (`src/game.cpp`), and the `first_pass_arguments` array-size
literal (`src/main.cpp`). Its resolution cache (`.git/rr-cache`) is **local to each clone** and is not
shared by git, so a fresh checkout hits both conflicts and must resolve them by hand the first time
(which trains that clone's cache); they auto-replay only afterward. Enable it per clone with
`git config rerere.enabled true`. Either way, if upstream adds a **new** CLI argument the
`<arg_handler, N>` count still needs a manual bump (N = base + your flags + upstream's new ones) — git
merges the literal silently and wrong.

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
**`entities.monsters[]`** (index, type_id, name, symbol, pos_local[xyz], pos_abs[xyz], hp, hp_max,
moves, hallucination — Spike 6A) · `messages[]` (text, type — **type currently blank**, deferred) ·
`diagnostics.warnings[]`. Tiles **and the monster window** are a radius-12 single-z square around the
avatar, clamped to the loaded bubble; `entities.monsters[]` uses the **identical** window predicate, so
every exported monster sits on an exported tile. It is the **authoritative** monster list
(`game::all_monsters()`) — it includes hallucinations and out-of-LOS monsters (flagged via
`hallucination`), not a "what the player sees" list.

### Transcript `session.jsonl` (`schema_version` 1, one JSON object per line, flushed per event)

`session_start` (world, **seed** opt — Spike 5, export_dir, game_version) · `command` (step_index,
command, direction opt, action_id opt, status="queued") · `export` (step_index|null, export_index,
name, path, final, turn, pos_abs, moves — scalars equal the named snapshot) · `error` (step_index
opt, kind, detail, exit_code) · `session_end` (status, snapshots, commands, final_turn opt,
final_pos_abs opt).

### Commands

`wait` → `ACTION_PAUSE` (`do_pause`); `move` + cardinal `direction` (`move_n`/`move_s`/`move_e`/`move_w`)
→ `ACTION_MOVE_*`. Diagonals, vertical, and everything else are rejected with a typed error.

**Movement into an occupied/obstructed tile is a faithful no-op.** A `move` whose destination holds a
creature, or a closed-but-not-bump-openable obstacle, runs the engine's real `avatar_action::move` leaf
and can end the turn with the avatar not having moved — exactly as in the GUI. The studied case
([15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)): in `ArcopolisTest` the stock
evac-shelter NPC **Edwardo Stovall** stands one tile north of the avatar, so `move_n` opens the engine's
NPC interaction menu and returns without spending moves — and since the backend runs in `test_mode`, that
`uilist` **auto-cancels** (≡ a GUI player pressing ESC) rather than blocking. Result: no move, 0 AP,
clean-park (world not ticked). This is GUI-faithful, **not** a seam bug; there is simply no command yet to
_choose_ an NPC interaction. Snapshots don't export NPCs (Spike 6A is monsters-only), so such a blocker is
invisible in the export — check the save / a live `critter_at` when a move "does nothing."

## Capabilities by spike

| Spike | What                                                                      | State                                   |
| ----- | ------------------------------------------------------------------------- | --------------------------------------- |
| 0     | headless load + one-shot snapshot                                         | ✅                                      |
| 1     | `wait` command (bootstrap turn)                                           | ✅                                      |
| 2     | persistent `--arcopolis-run-script` + `--arcopolis-export-dir` (T→T→T+1)  | ✅                                      |
| 3     | movement via `command → do_turn`                                          | ❌ failed (turn inversion) — superseded |
| 3.1A  | input-seam architecture (the fix)                                         | ✅                                      |
| 3.1B  | clean-park hardening + final-on-exit snapshot                             | ✅                                      |
| 3.1C  | `session.jsonl` transcript                                                | ✅                                      |
| 4     | offline viewer / contract consumer (Python → HTML)                        | ✅                                      |
| 5     | `is_avatar` marker + `seed` in `session_start`                            | ✅                                      |
| 6A    | nearby monster export (`entities.monsters[]`)                             | ✅                                      |
| 6B    | monster witness fixture (`ArcopolisNearMonsterTest`) + monster regression | ✅ validated (vs 6A build)              |

## Source & tests

`src/arcopolis_export.{h,cpp}` (snapshot; `write_entities` → `entities.monsters[]`, Spike 6A) ·
`arcopolis_command.{h,cpp}` (verb→action_id, errors) ·
`arcopolis_script.{h,cpp}` (script runner) · `arcopolis_backend_input.{h,cpp}` (input-seam provider,
clean-park, final snapshot) · `arcopolis_session_log.{h,cpp}` (transcript). Flags wired in
`src/main.cpp`; the seam branch lives at `src/handle_action.cpp`, the clean-park at `src/game.cpp`.
Unit tests: `tests/arcopolis_*_test.cpp` (`[arcopolis]` tag). Consumer:
`tools/arcopolis_viewer/make_report.py` (stdlib-only). Fixture-driven regressions (need a loaded world, so
not in CI):
[`docs/arcopolis/movement_regression.ps1`](movement_regression.ps1) gates movement/NPC on **`ArcopolisTest`**
(the movement/NPC fixture, unchanged), and
[`docs/arcopolis/monster_export_regression.ps1`](monster_export_regression.ps1) gates the monster export on
**`ArcopolisNearMonsterTest`** — the monster-export witness, a clone of `ArcopolisTest` with one in-window
monster, built reproducibly by [`docs/arcopolis/make_monster_fixture.py`](make_monster_fixture.py) (save-edit,
no GUI/build, witness on **passable** terrain so it stays put); see
[16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md](16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md) and the load/wall-eject
analysis [17_MONSTER_LOAD_AND_WALL_EJECT.md](17_MONSTER_LOAD_AND_WALL_EJECT.md).

## Deferred backlog

- **Richer read-only export:** dynamic entities — **monsters done (Spike 6A, `entities.monsters[]`)**;
  NPCs/items/fields/vehicles still deferred (#2) — plus per-tile symbol/colour (#1), message
  type/severity (#4 — needs a public `Messages::` accessor), multi-z (#5). Dynamic-entity export is the
  linchpin: monsters now exist, bringing the deferred **world-tick regression harness** closer (still
  needs a `--arcopolis-new-world` generator + monster/field state to witness a tick — see
  [10_SPIKE3_1B_CLEAN_PARK_HARDENING.md](10_SPIKE3_1B_CLEAN_PARK_HARDENING.md)).
- **Live protocol:** bidirectional commands over a transport (socket/stdin) with framing/acks (the
  M3 path) — everything today is file-based.
- **Richer commands:** examine/look, interaction (open/close/smash/pickup), **NPC interaction
  (talk/attack/swap/push — needed to act on a creature-occupied destination, the move-into-NPC no-op in
  [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md))**, inventory, targeting,
  diagonals, vertical.

## Build (Windows)

Activate the VS DevShell, append `C:\dev\ccache` to PATH, configure with `-G Ninja
-DCMAKE_BUILD_TYPE=RelWithDebInfo` into **one** `out/build/win-rel-deb` dir (game + tests share the
`cataclysm-bn-tiles-common` OBJECT lib; a second dir exhausts the disk), then `cmake --build
.\out\build\win-rel-deb --target cataclysm-bn-tiles cata_test-tiles`. Exact commands +
disk/ccache notes: [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md).
