# Movement `move_n` no-op — root cause (the evac-shelter NPC)

> **Status: ✅ root-caused decisively from the engine code + the authoritative `ArcopolisTest` save, and
> then live-confirmed by a real build (2026-06-05). Verdict: GUI-FAITHFUL behavior, NOT a seam bug.** The
> `move_n` "no-op" seen while validating Spike 6A is the engine correctly declining to walk the avatar
> into a **neutral NPC** standing on the destination tile. No engine/seam change is warranted; the
> deliverable is this write-up and a fixture-driven movement regression scenario. (The cardinal
> command→action mapping it leans on is already test-locked in `tests/arcopolis_backend_input_test.cpp`,
> so no new unit test was needed.) Builds on the input-seam architecture
> ([09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md](09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md)) and the monster export
> that surfaced it ([14_SPIKE6_MONSTER_EXPORT.md](14_SPIKE6_MONSTER_EXPORT.md)).

## The symptom (observed during Spike 6A, `--arcopolis-run-script`, Windows)

In `ArcopolisTest` the avatar (`Nubia 'Single' Rosales`) spawns in an evac shelter at local `(85,85,0)`,
abs `(6301,6421,0)`, calendar turn ~1,324,801. Driving isolated single moves and exporting before/after:

| command  | result                                                                                                                                                                                                      |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `move_s` | **works** — avatar `(85,85)→(85,86)`, `avatar.moves` drops, `backend.turn` advances.                                                                                                                        |
| `move_n` | **complete no-op** — avatar stays `(85,85)`, `avatar.moves` stays `99` (0 AP), `backend.turn` does not advance (the turn never completes → clean-park, world not ticked). Reproduced with `SAFEMODE=false`. |
| `move_e` | advances one tile `(85,85)→(86,85)`, then the next `move_e` bumps the east wall (faithful no-op).                                                                                                           |

Crucially, the run **completes** (the "after" snapshot is written; 5 isolated runs all parked cleanly) —
it does **not** hang.

## Why we answered this from the save, then confirmed with a build

The fidelity rule is "answer GUI-vs-headless **from the code**, decisively; live runs are for
reproduction/instrumentation only" (AGENTS.md). The one missing fact was a **data** question — _what
occupies `(85,84)`?_ — and the snapshot exports neither NPCs nor adjacency. So we read the **authoritative
`ArcopolisTest` save** directly (`map.sqlite3` submaps + the `o.1.1` overmap) — _more_ authoritative than
a printf probe: it is the exact state the engine loads. The engine turn-order then fixes the rest (below),
with no runtime guess. A real `win-rel-deb` build later **live-confirmed** the conclusion (see "Validation
status").

## What is at `(85,84)`: an NPC, invisible to the snapshot

Reading the fixture (`save/ArcopolisTest/`):

- **Destination terrain is open.** Submap `(525,535,0)` (file `maps/8.8.0/262.267.0.map`): the avatar tile
  `(1,1)`, the north dest `(1,0)`, the south `(1,2)` and east `(2,1)` are **all `t_floor`**; the submap has
  **no traps, no fields, no spawns, no vehicles** near the avatar. Terrain/hazard is _not_ the blocker.
- **No monster is adjacent.** The `.sav` `active_monsters` list holds the same 14 monsters Spike 6A found;
  the **nearest is Chebyshev 31 tiles away** (`mon_fish_lbass` at abs `(6332,6397)`). Nothing on or beside
  `(85,84)`.
- **One NPC — on the destination tile.** Overmap `o.1.1` (the avatar's own overmap, `om 1,1`) holds a
  single NPC, **`Edwardo Stovall` (`NC_DOCTOR`, `my_fac = no_faction`, `attitude = 0` = `NPCATT_NULL`),
  with `abs_pos = [6301, 6420, 0]`** — i.e. exactly **one tile north of the avatar**, the `move_n`
  destination `(85,84)`.

`NPCATT_NULL` is the attitude **"assigned on shelter NPC generation"** ([npc.h:80](../../src/npc.h)):
Edwardo is the stock evac-shelter NPC, placed beside the player at spawn. He is absent from the snapshot
because Spike 6A exports **monsters only** — NPC export is the deferred follow-up (6B). That is precisely
why the blocker was invisible.

Local map rendered from the save (`@`=avatar, `E`=Edwardo; `.`floor `#`wall `+`door `%`window
`,`outdoors):

```
     8 9 0 1 2 3 4 5 6 7 8        bub x →
83   . ? ? . . . . . . + ?
84   . ? ? . . . . E . + ?    ← Edwardo at (85,84), on t_floor; (87,84)=t_door_b (boarded)
85   . . . . . . . @ . # ?    ← (87,85)=t_wall_w blocks the 2nd move_e
86   . . . . . . . . . % ?
91   # # # # % # # # # # ?
92   , , , , , , , , , , ,    ← outdoors
```

This reproduces the reported east-wall layout exactly: `(87,83)=t_door_c`, `(87,84)=t_door_b` (boarded),
`(87,85)=t_wall_w`.

## The causal chain (each step cited; line numbers drift — trust the symbols)

1. `move_n` → `arcopolis::command_to_action` → `look_up_action("move_n")` = **`ACTION_MOVE_FORTH`**
   ([action.cpp:475-476](../../src/action.cpp); [arcopolis_command.cpp](../../src/arcopolis_command.cpp)
   `command_to_action`). The mapping is symmetric and correct — _not_ the bug.
2. The action is fed at the real input seam; the alive-only `switch( act )` reaches the `ACTION_MOVE_FORTH`
   case → `dest_delta = get_delta_from_movement_action( ACTION_MOVE_FORTH, … )` =
   **`point_rel_ms::north()` = (0,-1,0)** ([action.cpp:557-558](../../src/action.cpp);
   [handle_action.cpp:1973-1990](../../src/handle_action.cpp)). Headless `iso_mode` is false (`use_tiles`
   is off), so the delta is plain north. → `avatar_action::move( u, m, (0,-1,0) )`.
3. `dest_loc = bub_pos + north =` local `(85,84)` = abs `(6301,6420)`
   ([avatar_action.cpp:114](../../src/avatar_action.cpp)) — **Edwardo's tile**.
4. `avatar_action::move`: `critter_at<monster>(dest_loc)` is null (Edwardo is an NPC) → the monster branch
   is skipped; `critter_at<npc>(dest_loc)` returns **Edwardo**
   ([avatar_action.cpp:318](../../src/avatar_action.cpp)).
5. `you.is_auto_moving()` is false (a single scripted command, no route) → skip. `!np.is_enemy()` is
   **true**: `npc::is_enemy()` is true only for `NPCATT_KILL/FLEE/FLEE_TEMP`
   ([npc.cpp:2246-2249](../../src/npc.cpp)), and Edwardo is `NPCATT_NULL`. → the engine runs
   **`g->npc_menu( np ); return false;`** ([avatar_action.cpp:327-329](../../src/avatar_action.cpp)) —
   `return false` **without spending any moves**.
6. `npc_menu` ends in `amenu.query()` ([game.cpp:7691](../../src/game.cpp)). The backend binary runs in
   **`test_mode`** (`--arcopolis-run-script` sets it, [main.cpp:508](../../src/main.cpp)), and
   `uilist::query()` in test_mode does **not** block — it logs `debugmsg("Tried to open UI in test mode")`
   and sets `ret = UILIST_ERROR`, returning immediately ([ui.cpp:918-922](../../src/ui.cpp)). No menu
   choice is taken → **equivalent to a player opening the menu and pressing ESC** (the caller ignores the
   return value and `return false`s regardless).
7. `move()` returned false with **0 AP spent** → the engine's input loop still sees `u.moves > 0` → it
   iterates again; the provider writes the "after" export (avatar unchanged) and the script is exhausted →
   the gated **clean-park** returns `do_turn` before its bottom half ([game.cpp ~2004](../../src/game.cpp))
   → world **not** ticked, calendar does not advance.

That is exactly the observed triple: no move, 0 AP, no tick — and no hang, because test_mode auto-cancels
the menu instead of waiting on `get_input_event` (which _would_ block forever headless,
[sdltiles.cpp:3963-3970](../../src/sdltiles.cpp)).

`move_s` and `move_e` corroborate: `(85,86)` and `(86,85)` are empty `t_floor`, so `critter_at` is null,
`g->walk_move` succeeds and spends moves; the second `move_e` bumps `t_wall_w` at `(87,85)` and takes the
silent invalid-move return ([avatar_action.cpp:466-497](../../src/avatar_action.cpp)).

## Classification: GUI-FAITHFUL, not a seam bug

The avatar-state outcome headless (no move, 0 AP, world not ticked) is **identical** to a GUI player who
bumps north into Edwardo, sees the "What to do with Edwardo Stovall?" menu, and presses **ESC**. The
backend is _correctly not moving_. This is the engine's spec for "walk into a neutral NPC," reproduced
faithfully — there is no divergence to fix and **no `command → do_turn` regression to revive**.

Two honest nuances, neither a fidelity break:

- **The `debugmsg` artifact.** test_mode's `uilist::query()` emits `"Tried to open UI in test mode"` to
  `debug.log` (it is _captured/logged_, not a popup, and does not abort —
  [debug.cpp:518-519](../../src/debug.cpp)). It never reaches the snapshot/transcript or stderr, so it did
  not appear in the runs; it is a useful tell that the backend steered the engine into an interactive path.
  Suppressing it would mean editing shared engine code for cosmetics — out of scope and against the
  fidelity rule. We **document** it instead.
- **It is a capability gap, not a wrong answer.** "ESC/decline" is the _only_ outcome the current command
  vocabulary can express, because there is no command for an NPC interaction. Even a GUI player **cannot
  simply walk through** a neutral non-ally NPC: for Edwardo (`no_faction`, not an ally) the menu's "Swap
  positions" and "Push away" entries are **disabled** (they require `obeys` = ally,
  [game.cpp:7669-7677](../../src/game.cpp)); the only ways past are Talk (negotiate), Attack (turn him
  hostile), or route around him.

## Scope question surfaced (NOT silently added)

To let the backend _act_ on an NPC-occupied destination, a future spike would add an NPC-interaction
command surface — e.g. one or more of:

- an `interact`/`talk` command (open dialogue → recruit / ask-to-move),
- an `attack` command (deliberate melee; the engine's enemy path already exists),
- a `swap`/`push` command (only meaningful once the NPC is an obeying ally),
- or pathing/`travel_to` that walks **around** blockers.

Each is a real command-vocabulary expansion with its own fidelity surface (the GUI menu, dialogue,
hostility). It belongs in a dedicated "richer commands / NPC interaction" spike (backlog: _Richer
commands_), not bolted onto `move`. **No such command was added here.**

## What changed in this pass (additive, no engine edit)

| File                                          | Change                                                                                                                                                       |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docs/arcopolis/15_…md`, `ARCOPOLIS_STATE.md` | this root-cause write-up + a current-truth note (move-into-creature semantics).                                                                              |
| `docs/arcopolis/movement_regression.ps1`      | fixture-driven movement regression scenario: a known-walkable cardinal must advance `pos_abs` **and** tick `backend.turn`, so a movement no-op fails loudly. |

No `src/` change: the behavior is faithful, so nothing is "fixed" in the engine or the seam. **No new unit
test was added either** — building revealed that `command_to_action`'s cardinal mapping is _already_ fully
covered by `tests/arcopolis_backend_input_test.cpp:17-45` (`wait→ACTION_PAUSE`, the four
cardinals→`ACTION_MOVE_*`, and the unsupported/bad-direction rejections), so there was no pure-logic gap to
fill.

## Citation audit (load-bearing claims)

| Claim                                                                     | Type       | Citation                                                            | Verdict |
| ------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------- | ------- |
| `move_n` resolves to `ACTION_MOVE_FORTH` (mapping is correct)             | behavioral | action.cpp:475-476; tested in arcopolis_backend_input_test.cpp:17   | ✅      |
| `ACTION_MOVE_FORTH` delta is north `(0,-1,0)` headless                    | behavioral | action.cpp:557-558 (`iso_mode` false: use_tiles off)                | ✅      |
| The dest tile `(85,84)`/abs `(6301,6420)` is `t_floor`, no trap/field     | data       | `map.sqlite3` submap `(525,535,0)` (file `maps/8.8.0/262.267.0`)    | ✅      |
| Nearest monster is Chebyshev 31 (none adjacent)                           | data       | `.sav` `active_monsters` `pos_abs` (matches Spike 6A)               | ✅      |
| NPC `Edwardo Stovall` is at abs `(6301,6420)` = the move_n dest           | data       | overmap `o.1.1` npcs[0] `abs_pos = [6301,6420,0]`                   | ✅      |
| `NPCATT_NULL` is the shelter-NPC attitude and is **not** an enemy         | behavioral | npc.h:80; npc.cpp:2246-2249                                         | ✅      |
| Non-enemy NPC at dest → `npc_menu` + `return false`, 0 AP                 | behavioral | avatar_action.cpp:318,327-329                                       | ✅      |
| `--arcopolis-run-script` runs in `test_mode`                              | behavioral | main.cpp:508                                                        | ✅      |
| test_mode `uilist::query()` returns immediately (UILIST_ERROR + debugmsg) | behavioral | ui.cpp:918-922                                                      | ✅      |
| test_mode `debugmsg` is logged, not aborting/popping                      | behavioral | debug.cpp:518-519                                                   | ✅      |
| A reached query would otherwise _block_ headless (so a hit query = hang)  | behavioral | popup.cpp:269 (test_mode short-circuit) + sdltiles.cpp:3963-3970    | ✅      |
| 0-AP no-op + exhausted script → clean-park, world not ticked              | behavioral | game.cpp clean-park (after `is_game_over()`); avatar_action.cpp:497 | ✅      |
| Live: move_s moves+ticks; move_n no-op (pos/turn/moves unchanged)         | empirical  | win-rel-deb run on `ArcopolisTest` (see Validation status)          | ✅      |

## Validation status

A real `win-rel-deb` build was produced to run the tests and live-confirm the conclusion (the stale
main-repo build dir was reclaimed for disk space; worktrees and ccache left intact).

- **`[arcopolis]` unit suite** (`cata_test-tiles "[arcopolis]"`): **All tests passed (204 assertions in 41
  test cases).** This includes the existing `command_to_action` cardinal-mapping coverage
  (`arcopolis_backend_input_test.cpp:17-45`) that locks `move_n→ACTION_MOVE_FORTH`. No new unit test was
  needed; building also caught (and we removed) a redundant duplicate-name test before it could land.
- **Live movement corroboration** (`cataclysm-bn-tiles.exe` on `ArcopolisTest`, export → move → export):
  - `move_s`: `pos_abs (6301,6421)→(6301,6422)` (+1 south), `turn 1324801→1324802` (+1), `moves 99→98`.
  - `move_n`: `pos_abs`, `turn`, and `moves` **all unchanged** (`6301,6421` / `1324801` / `99`), exit 0,
    empty stderr — the exact reported symptom, exactly as the NPC root cause predicts.
- **Movement regression scenario** (`movement_regression.ps1`): runs green — the `move_s` hard gate passes
  (advances `pos_abs` + ticks the turn) and the `move_n` arm reports the faithful NPC no-op. Running it
  surfaced and fixed a real script bug: `cataclysm-bn-tiles` is a GUI/WINDOWS-subsystem exe, so a bare
  `& $exe` does not wait for it (empty `$LASTEXITCODE`); the script now uses `Start-Process -Wait
  -PassThru`, the pattern the spike validations use. A _fully automated_ in-CI world-driven movement
  assertion still depends on the deferred `--arcopolis-new-world` generator (state-doc backlog) — we
  **note that dependency rather than fake world state**, so this scenario remains a fixture-driven check.
- **Root cause needs no build:** it rests on the authoritative save data + cited engine code, and the
  engine turn-order (NPCs act in the bottom half, _after_ the avatar's input loop — so Edwardo is at his
  loaded tile when `move_n` is evaluated). The build only re-confirmed it.
