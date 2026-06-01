# Spike 3 Movement Exploration

> **Update (post-implementation):** the implementation that followed this exploration
> ([08_SPIKE3_MOVE_COMMAND.md](08_SPIKE3_MOVE_COMMAND.md)) is marked **FAILED**. This doc's
> "Recommendation A" (`command → do_turn`, guarded by `moves<=0`) was built and works mechanically, but it
> leaves the **action/top-half ordering inversion** in place — the action runs _before_ `do_turn` instead
> of at the engine's `handle_action()` slot _inside_ it, so it is not faithful past the bootstrap turn.
> The "Verified byte-identical for `wait`" claim below was **not** independently re-verified and is
> overstated; treat it as "seeded-reproducible, equivalence unproven". The fix (inject the command at the
> engine input point and run the engine's own `do_turn` loop) is proposed in doc 08.

> Scope: **exploration / design only** — the fourth step in the Arcopolis investigation, building on
> [03_SPIKE0_CURRENT_VIEW_EXPORT.md](03_SPIKE0_CURRENT_VIEW_EXPORT.md),
> [05_SPIKE1_WAIT_COMMAND.md](05_SPIKE1_WAIT_COMMAND.md), and
> [06_SPIKE2_STATEFUL_SCRIPT.md](06_SPIKE2_STATEFUL_SCRIPT.md). It investigates how a single **cardinal
> movement** backend command (`move east`, etc.) could be added to the existing stateful step-script
> runner, the engine path it must reuse, and the smallest faithful first scope.
>
> **No source files were changed by this spike.** This document is the entire deliverable. Line numbers
> were read from the source during exploration; they drift as the code evolves — re-run the PowerShell
> checks in the last section against a newer commit.

## Fidelity principle (read this first)

**The GUI behavior is the engine behavior is the behavior, period.** A headless movement command must
reproduce **exactly** what the engine does when the player presses a direction key — no more, no less —
and must **never override engine state/flags** to make the output look nicer or force the avatar to move
when the engine wouldn't let it. The answer to "do headless and GUI movement differ?" is taken **from the
code**, not from experiments (AGENTS.md → "Arcopolis backend fidelity (NON-NEGOTIABLE)").

## Summary

**Feasible**, at a tightly-scoped first slice, with one important guard. A faithful headless cardinal move
is reachable by reusing the _exact_ function the GUI's movement keys call — `avatar_action::move(avatar&,
map&, point_rel_ms)` ([src/avatar_action.cpp:99](../../src/avatar_action.cpp),
[src/avatar_action.h:27–31](../../src/avatar_action.h)) — and then completing the turn the same way the
Spike 1 `wait` does (a single `game::do_turn()`), **guarded** so the engine's player-input loop is never
entered headless.

The feasibility rests on three code facts:

1. The GUI dispatches a movement key to `avatar_action::move(...)` and **nothing else** for a normal
   step ([src/handle_action.cpp:1917–1962](../../src/handle_action.cpp)); that function is the faithful
   entry point.
2. For a cardinal step into **empty, safe, passable terrain on the same z-level**, that path is
   **UI-free** — it never reaches a `query_yn`/`popup`/menu (those fire only for monsters, NPCs, water,
   moving vehicles, or dangerous tiles; traced below).
3. The turn-advance semantics are **identical to `wait`**: movement consumes `u.moves` but does _not_
   itself process the world; `game::do_turn()` does. The Spike 1/2 `do_pause + do_turn` pattern maps
   directly onto `avatar_action::move + do_turn`.

The single **risk that must be guarded** is that `avatar_action::move` _decrements_ moves rather than
zeroing them (unlike `do_pause`). If a move leaves `u.moves > 0`, an unguarded `do_turn()` would enter
the blocking keyboard-input loop ([src/game.cpp:1979–2004](../../src/game.cpp)) and hang headless. The
fix is faithful and trivial: only call `do_turn()` when `u.moves <= 0`, which is **exactly** the GUI's
own input-loop exit condition. This is **uncertain-but-bounded**, not risky.

## Why this matters for Arcopolis

Movement is the first **spatial player-intent** command. `wait` (Spike 1/2) proved the backend can drive
the engine's clock; movement proves the backend can control **position** and that the exported view
**re-centers and changes** as the avatar acts. It is the first command whose effect is visible as a
map/coordinate delta, and the prerequisite for any later traversal, exploration, or mission work. A tiny
external viewer only becomes worthwhile once movement is proven (06_SPIKE2 "Next step").

## Prior backend state

- **Spike 0** — headless load (`g->load(world)`) + read-only current-view JSON export; `std::_Exit` to
  skip fragile teardown. ([03_SPIKE0_CURRENT_VIEW_EXPORT.md](03_SPIKE0_CURRENT_VIEW_EXPORT.md))
- **Spike 1** — first backend command, `wait`, applied via the engine's real `ACTION_PAUSE` mechanism
  (`character_funcs::do_pause` + one `game::do_turn()`), with the GUI safe-mode gate
  (`g->check_safe_mode_allowed()`). Exposed the one-shot lifecycle limit: every command re-pays the
  bootstrap turn, so the clock never advances. **No `new_game` override.**
  ([05_SPIKE1_WAIT_COMMAND.md](05_SPIKE1_WAIT_COMMAND.md))
- **Spike 2** — fixed the _lifecycle_: a persistent step-script runner loads once and runs an ordered
  JSON script (`op: export` / `op: command`) against the live game, exporting between steps. Proved
  `T → T → T+1` (bootstrap turn first, normal turns after) with zero faking.
  ([06_SPIKE2_STATEFUL_SCRIPT.md](06_SPIKE2_STATEFUL_SCRIPT.md))

The backend command set today is **only `wait`**, dispatched by `arcopolis::apply_command`
([src/arcopolis_command.cpp:71–116](../../src/arcopolis_command.cpp)). The step script carries `op`,
`name`, `command` per step ([src/arcopolis_script.h:16–20](../../src/arcopolis_script.h)).

## Files inspected

| File                               | One-line note                                                                                                                             |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `AGENTS.md`                        | Fidelity rule; documentation-only preference; PowerShell for local checks.                                                                |
| `docs/arcopolis/03,05,06_*.md`     | Prior spikes; the `do_pause + do_turn` pattern and bootstrap-turn semantics.                                                              |
| `src/arcopolis_command.h` / `.cpp` | `backend_command{schema_version,command}`; `apply_command` dispatcher (only `wait`); `command_error_kind` + `exit_code_for` (2–9).        |
| `src/arcopolis_script.h` / `.cpp`  | `script_step{op,name,command}`; `parse_script` (validates `op`/`command`); `run_script` load-once loop reusing `apply_command`.           |
| `src/arcopolis_export.h` / `.cpp`  | `write_current_view`; snapshot fields (`avatar.pos_local/pos_abs`, `backend.turn`, tile window re-centred on `u.bub_pos()`).              |
| `src/main.cpp`                     | `--arcopolis-*` flag wiring + mode-exclusive `std::_Exit` dispatch (run_script vs one-shot).                                              |
| `src/handle_action.cpp`            | `ACTION_MOVE_*` cases → `avatar_action::move`; `ACTION_PAUSE`; `ACTION_MOVE_UP/DOWN` (vertical).                                          |
| `src/avatar_action.cpp` / `.h`     | `avatar_action::move(...)` — the faithful movement entry; its UI prompts and special cases.                                               |
| `src/action.cpp`                   | `look_up_action` (`move_e`→`ACTION_MOVE_RIGHT`, …); `get_delta_from_movement_action` — action_id → `point_rel_ms` delta (+ iso rotation). |
| `src/game.cpp`                     | `do_turn()` (input loop + bootstrap branch + bottom-half world processing); `walk_move`; `place_player`.                                  |
| `src/creature.cpp`                 | `Creature::process_turn()` — `moves += get_speed()` (move replenishment).                                                                 |
| `src/output.cpp`                   | `query_yn` — explicit "opened in test_mode" hazard comment.                                                                               |
| `src/popup.cpp`                    | `query_popup::query_once()` returns `{false,"ERROR"}` under `test_mode` (silent "No").                                                    |
| `src/ui.cpp`                       | `uilist::query` under `test_mode` → `debugmsg("Tried to open UI in test mode")` + `UILIST_ERROR`.                                         |
| `src/coordinates.h`, `src/point.h` | Direction helpers; `point_east{1,0}` / `point_north{0,-1}` / `point_south{0,1}` / `point_west{-1,0}`.                                     |

## Normal movement call path

The interactive path for a single cardinal step, traced from input to repositioning (**high
confidence** — every hop read directly):

```
game::do_turn()                                   [src/game.cpp:1846]
  └─ player-input loop  while( u.moves > 0 ... )   [src/game.cpp:1979–2004]   // movement happens HERE
       └─ handle_action()                          [src/game.cpp:2004 -> src/handle_action.cpp]
            └─ case ACTION_MOVE_RIGHT (etc.)        [src/handle_action.cpp:1917–1962]
                 ├─ dest_delta = get_delta_from_movement_action( act, iso_rotate::yes )
                 │                                  [src/action.cpp:549–572]   // action_id -> point_rel_ms
                 └─ avatar_action::move( u, m, dest_delta )
                                                    [src/handle_action.cpp:1957 -> src/avatar_action.cpp:99]
                      ├─ g->check_safe_mode_allowed()      [src/avatar_action.cpp:101]   // same gate as wait
                      ├─ (special cases: attack / NPC / vehicle / water / doors — see below)
                      └─ g->walk_move( dest_loc, via_ramp ) [src/avatar_action.cpp:462 -> src/game.cpp:11481]
                           ├─ mcost = m.combined_movecost(...) ; u.moves -= u.run_cost(mcost,diag)
                           │                                  [src/game.cpp:11688, 11726]   // CONSUMES moves
                           ├─ u.burn_move_stamina( previous_moves - u.moves )  [src/game.cpp:11746]
                           └─ place_player( dest_loc, keep_grab )              [src/game.cpp:11865, 11888]
                                                              // actually repositions the avatar + shifts the bubble
  └─ (after input loop) monmove() / npcmove() / u.process_turn() / world_tick()
                                                    [src/game.cpp:2087, 2090, 2102, 2192]   // turn processed HERE
```

The two halves of `do_turn()` straddle the input loop. The **top half** (calendar/bootstrap, weather,
hordes, autosave) runs at [src/game.cpp:1878–1974](../../src/game.cpp); the **bottom half**
(monster/NPC AI, `u.process_turn()`, `world_tick`) runs at
[src/game.cpp:2025–2218](../../src/game.cpp). **The player's move is consumed in the middle**, inside the
input loop, before the world is processed for that turn.

## Direction and action representation

- **Action IDs** are an `enum action_id` (`ACTION_MOVE_FORTH`, `ACTION_MOVE_FORTH_RIGHT`,
  `ACTION_MOVE_RIGHT`, …, `ACTION_MOVE_FORTH_LEFT`, plus `ACTION_MOVE_UP` / `ACTION_MOVE_DOWN`), grouped
  as the movement cases at [src/handle_action.cpp:1917–1924](../../src/handle_action.cpp) (8 horizontal)
  and 1963 / 2018 (vertical). Keys (arrows / numpad / hjkl-yubn) are mapped to these action IDs by the
  `input_context` / keybindings layer — that mapping is **screen-relative** ("forth/back/left/right"),
  not world-absolute.
- **Action → delta** is `get_delta_from_movement_action( action_id, iso_rotate )`
  ([src/action.cpp:549–572](../../src/action.cpp)), returning a `point_rel_ms`. It applies **isometric
  rotation** only when `use_tiles && tile_iso` (line 551); otherwise `ACTION_MOVE_RIGHT → east()`,
  `ACTION_MOVE_FORTH → north()`, etc.
- **World-relative idents → action** is the engine's _own_ string vocabulary. `look_up_action(ident)`
  ([src/action.cpp:460–491](../../src/action.cpp)) maps `"move_n" → ACTION_MOVE_FORTH`, `"move_s" →
  ACTION_MOVE_BACK`, `"move_e" → ACTION_MOVE_RIGHT`, `"move_w" → ACTION_MOVE_LEFT` (and the four diagonals
  `move_ne/nw/se/sw`, plus `move_up/down`), returning `ACTION_NULL` for an unknown ident (line 490) — a
  free validation hook. These idents are **world-absolute** (north/east/…), unlike the screen-relative
  action names.
- **Direction constants** the deltas resolve to: `point_east{ 1, 0 }`, `point_west{ -1, 0 }`,
  `point_north{ 0, -1 }`, `point_south{ 0, 1 }` ([src/point.h:270–276](../../src/point.h)), with
  `tripoint_*` variants at z=0 ([src/point.h:279–285](../../src/point.h)); the coord helpers
  `point_rel_ms::east()/north()/…` wrap them ([src/coordinates.h:140–180](../../src/coordinates.h)).

**Implication for the backend — reuse the engine's own conversion, don't invent one.** The faithful path
is the GUI's: take a world-relative ident, resolve it with `look_up_action`, then compute the delta with
`get_delta_from_movement_action( act, iso_rotate::no )` — the _exact_ helper `handle_action` calls
([src/handle_action.cpp:1934](../../src/handle_action.cpp), there with `iso_rotate::yes`). Pass
**`iso_rotate::no`** headless: iso rotation only applies when `use_tiles && tile_iso`
([src/action.cpp:551](../../src/action.cpp)), and `test_mode` loads no tileset, so `::yes` and `::no` are
identical here — `::no` is the unambiguous choice that doesn't depend on `tile_iso` state. This routes
through the engine's vocabulary end-to-end (no hand-rolled direction math):

| `direction` ident | `look_up_action` →  | `get_delta_from_movement_action(…, ::no)` → | x, y    |
| ----------------- | ------------------- | ------------------------------------------- | ------- |
| `"move_e"`        | `ACTION_MOVE_RIGHT` | `point_rel_ms::east()`                      | `+1, 0` |
| `"move_w"`        | `ACTION_MOVE_LEFT`  | `point_rel_ms::west()`                      | `-1, 0` |
| `"move_n"`        | `ACTION_MOVE_FORTH` | `point_rel_ms::north()`                     | `0, -1` |
| `"move_s"`        | `ACTION_MOVE_BACK`  | `point_rel_ms::south()`                     | `0, +1` |

`+x = east`, `+y = south`, `-z = down` is the BN world convention. The resulting `point_rel_ms` feeds the
`avatar_action::move` overload ([src/avatar_action.h:28–31](../../src/avatar_action.h)) that auto-wraps to
`tripoint_rel_ms(d, 0)`, so the backend never touches z for cardinals. (Mapping a direction string to
`point_rel_ms::east()` directly would yield the _same_ delta — `get_delta_from_movement_action` literally
returns those constants — but routing through `look_up_action`/`get_delta_from_movement_action` reuses the
engine's table verbatim and stays correct if that table ever changes.)

## Candidate non-UI movement entry points

| Candidate                               | File / function                                                                                 | What it does                                                                                                                                                                                          | UI-free?                                                                                                                                                    | Consumes moves?                                                                          | Needs later `do_turn()`?                                                                  | Risks                                                                                                                                                                                                                                      |
| --------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`avatar_action::move`** (recommended) | [src/avatar_action.cpp:99](../../src/avatar_action.cpp) / [.h:27–31](../../src/avatar_action.h) | The **exact** function the GUI movement keys call ([handle_action.cpp:1957](../../src/handle_action.cpp)). Runs the safe-mode gate, facing, attack/NPC/vehicle/water/door handling, then `walk_move`. | **Conditionally** — UI-free for a cardinal step into empty, safe, passable, same-z terrain; otherwise can `query_yn`/`npc_menu`/`popup` (see next section). | Yes (via `walk_move`: `u.moves -= run_cost(...)`, [game.cpp:11726](../../src/game.cpp)). | Yes — it repositions + spends moves but does **not** run monmove/process_turn/world_tick. | Prompts on special cases; bool return is "auto-move cancel", not "did I move" (compare position instead).                                                                                                                                  |
| `game::walk_move`                       | [src/game.cpp:11481](../../src/game.cpp)                                                        | Lower-level: grabs, vehicle/passage checks, move cost, stamina, `place_player`.                                                                                                                       | More UI-free (still `prompt_dangerous_tile` at 11660–11667), but…                                                                                           | Yes.                                                                                     | Yes.                                                                                      | **Unfaithful to call directly** — it **skips** the safe-mode gate, the stunned/shell checks, and the attack/swim branching that the GUI's `avatar_action::move` performs _before_ it. Using it directly would be inventing a non-GUI path. |
| `game::place_player`                    | [src/game.cpp:11888](../../src/game.cpp)                                                        | Pure reposition + terrain side-effects (signage, ROUGH/SHARP, effects, bubble shift).                                                                                                                 | Mostly.                                                                                                                                                     | **No** (no move-cost accounting).                                                        | Yes.                                                                                      | Even further from the GUI path; bypasses all movement legality and cost. Not faithful.                                                                                                                                                     |
| `Character::set_pos`/teleport-style     | (various)                                                                                       | Direct coordinate set.                                                                                                                                                                                | Yes.                                                                                                                                                        | No.                                                                                      | n/a                                                                                       | **Forbidden** — pure state override; violates the fidelity principle and the task's hard constraints.                                                                                                                                      |

**Conclusion:** `avatar_action::move` is the only faithful entry — it is _literally_ the GUI's call site.
The lower-level functions bypass the gates the GUI runs, so calling them directly would be the very
"invent a headless mode" the fidelity rule forbids.

## Turn-advance semantics

**Decided from the code, not by experiment** (per AGENTS.md):

- Movement does **not** advance the turn by itself. `avatar_action::move` / `walk_move` only **decrement
  `u.moves`** and reposition the avatar; the world (monsters, NPCs, fields, items, the calendar) is
  processed in `do_turn()`'s **bottom half** — `monmove()`/`npcmove()`/`u.process_turn()`/`world_tick()`
  at [src/game.cpp:2087–2192](../../src/game.cpp) — which runs only **after** the input loop exits.
- The input loop exits when `u.moves <= 0` ([src/game.cpp:1979–1980](../../src/game.cpp)). So in the GUI,
  a single move only ends the turn **if it exhausts the avatar's moves**; otherwise the player gets
  another action in the _same_ turn.
- Moves are **replenished** in the bottom half, by `Creature::process_turn()` → `moves += get_speed()`
  ([src/creature.cpp:233–248](../../src/creature.cpp)), invoked as `u.process_turn()` at
  [src/game.cpp:2102](../../src/game.cpp).
- The **bootstrap turn** is unchanged from Spike 1/2: `game::setup()` (run by `g->load`) leaves
  `new_game == true`, and the first `do_turn()` clears it **without** advancing `calendar::turn`
  ([src/game.cpp:1878–1885](../../src/game.cpp)). The player's first post-load action is processed in
  that bootstrap turn (this is the documented "pressing `.` once after loading" behavior).

**Therefore the faithful backend move = `avatar_action::move(...)` then a _guarded_ `g->do_turn()`** —
the exact analogue of Spike 1/2's `do_pause(...) + do_turn()`, with one difference that _must_ be
handled: `do_pause` sets `who.moves = 0` ([src/character_turn.cpp:1084](../../src/character_turn.cpp)) so
the input loop is always skipped, whereas `avatar_action::move` only _decrements_ moves (via `walk_move`,
[src/game.cpp:11726](../../src/game.cpp)). The guard mirrors the engine's own loop condition:

```text
if u.moves > 0 at command start:           # GUI only delivers a movement key when moves > 0
    apply avatar_action::move( u, m, dir )  # the exact GUI call; consumes moves or no-ops if blocked
    if u.moves <= 0:                        # GUI input loop would now EXIT -> process the turn
        g->do_turn()                        # bottom half runs; bootstrap turn first, normal turns after
    else:                                   # GUI would await another key -> turn not over yet
        (do nothing; leftover moves carry to the next command — a faithful mid-turn state)
```

For the sample script (`export → move east → export → wait → export`) against the fixture avatar (100
speed, flat `t_floor`, where one cardinal step costs ~100 moves → exhausts a fresh turn's allotment):

| step                 | engine action                                                   | `do_turn` #     | `new_game` before | `backend.turn` after            | avatar      |
| -------------------- | --------------------------------------------------------------- | --------------- | ----------------- | ------------------------------- | ----------- |
| export `before_move` | —                                                               | —               | true              | **T**                           | start       |
| **move east**        | `avatar_action::move(east)` → moves 100→0 → `do_turn` (moves≤0) | 1st = bootstrap | true→false        | **T** (clock not advanced)      | **+1 east** |
| export `after_move`  | —                                                               | —               | false             | **T**                           | moved       |
| wait                 | `do_pause` → moves 0 → `do_turn` (moves≤0)                      | 2nd = normal    | false             | **T+1** (`calendar::turn += 1`) | —           |
| export `after_wait`  | —                                                               | —               | false             | **T+1**                         | —           |

This is the **same `T → T → T+1` shape Spike 2 proved**, with the first action being a _move_ instead of
a _wait_. The clock advance still emerges purely from the load-once lifecycle; nothing is faked.

> **Known inversion (inherited from Spike 1/2) — this is what failed the spike, see doc 08.** The backend
> calls the player action _before_ `do_turn`'s top half, whereas the GUI runs the top half (calendar
> advance) _before_ the action inside one `do_turn`. This exploration called it "A/B-tested byte-identical
> for `wait`" and "accepted / low risk" — **both characterizations were wrong**: the byte-identical claim
> was never independently re-verified, and the inversion is a fidelity defect, not an accepted pattern.
> Movement makes it observable (the action is evaluated one top-half behind the engine from the second turn
> on). The correct resolution is structural — inject the command at the engine's `handle_action()` input
> point (`src/game.cpp:2004`) and let the engine's own `do_turn` loop run — documented in doc 08.

## Safety, blocking, and prompts

Everything that could prompt, block, or special-case a move, with where it lives and how the first scope
avoids it:

- **Safe-mode gate.** `avatar_action::move` returns `false` immediately if `!g->check_safe_mode_allowed()`
  ([src/avatar_action.cpp:101](../../src/avatar_action.cpp)) — the same gate `wait` already honors. The
  backend should pre-check it for a clean `safe_mode_blocked` (exit 8) result, exactly like
  `apply_command`'s `wait` ([src/arcopolis_command.cpp:101–105](../../src/arcopolis_command.cpp)). The
  check is headless-safe (only `add_msg`/`press_x`).
- **UI prompts (must be avoided by scope — they don't hang, they answer _wrongly_).** In `test_mode` a
  `query_yn`/`query_popup` does **not** block: `query_popup::query_once()` short-circuits to
  `{ false, "ERROR" }` ([src/popup.cpp:269–270](../../src/popup.cpp)), so `query_yn` silently returns
  **`false` ("No")** ([src/output.cpp:707–725](../../src/output.cpp), whose own comment flags "opened in
  test_mode"). A `uilist`-based prompt (e.g. `npc_menu`) instead emits
  `debugmsg( "Tried to open UI in test mode" )` and returns `UILIST_ERROR`
  ([src/ui.cpp:918–921](../../src/ui.cpp)) — a logged error the test harness/stderr treats as a failure.
  Either way the **frontend never gets to decide**, and the silent auto-"No" can leave a subtly wrong
  state — so these paths must be **refused by scope**, never relied on. They fire **only** for
  non-empty/hazardous destinations:
  - attack a neutral creature — `query_yn` ([src/avatar_action.cpp:300](../../src/avatar_action.cpp));
  - interact with a non-enemy NPC — `g->npc_menu(np)` ([src/avatar_action.cpp:328](../../src/avatar_action.cpp));
  - dive from a moving vehicle — `query_yn` ([src/avatar_action.cpp:353](../../src/avatar_action.cpp));
  - dive into deep water — `query_yn` ([src/avatar_action.cpp:390](../../src/avatar_action.cpp));
  - swim with low oxygen — `popup` ([src/avatar_action.cpp:595–597](../../src/avatar_action.cpp));
  - step onto a dangerous tile — `prompt_dangerous_tile`, called from `walk_move`
    ([src/game.cpp:11660–11667](../../src/game.cpp), gated by `is_dangerous_tile`,
    [11648](../../src/game.cpp)); its body is a `query_yn( "Really step into %s?" )`
    ([src/game.cpp:11406](../../src/game.cpp)) — so in `test_mode` it returns `false`, and `walk_move`
    then `return`s without moving the avatar.
    A cardinal step into an empty, non-dangerous, passable, same-z tile reaches **none** of these — it goes
    straight to `walk_move` → `place_player`.
- **Blocked moves are _not_ errors and are headless-safe.** Bumping a wall: `walk_move` returns `false`
  ([src/game.cpp:11600/11692](../../src/game.cpp)), `avatar_action::move` falls through to the
  invalid-move branch and only emits `add_msg("You bump into the %s!")` / "That door is locked!"
  ([src/avatar_action.cpp:466–497](../../src/avatar_action.cpp)); **no moves are spent** unless the avatar
  is blind/stunned. So a blocked move leaves `u.moves` unchanged (still `> 0`) → the `moves <= 0` guard
  correctly **skips** `do_turn` (the GUI would keep the player in control and not advance the turn).
- **Doors.** Walkable doors / fence gates / openable furniture are opened _in-line_ by `m.open_door` and
  cost 100 moves, **without a prompt** ([src/avatar_action.cpp:404–448](../../src/avatar_action.cpp)). Low
  risk, but excluded from the first scope to keep "one step = one tile of translation" clean.
- **Vertical movement is a different code path** — `ACTION_MOVE_UP`/`DOWN` →
  `vertical_move(...)`/`pldrive(...)` ([src/handle_action.cpp:1963–2016+](../../src/handle_action.cpp)),
  not `avatar_action::move`. Out of scope.
- **Ramps / ladders / auto-mine / stunned-stumble** inside `avatar_action::move`
  ([src/avatar_action.cpp:122–166, 230–251, 450–464](../../src/avatar_action.cpp)) only trigger on
  specific terrain/effects — absent on a sheltered flat floor.
- **Terrain cost / stamina / messages.** Cost via `combined_movecost`→`run_cost`
  ([src/game.cpp:11688, 11726](../../src/game.cpp)); stamina via `burn_move_stamina`
  ([src/game.cpp:11746](../../src/game.cpp)); "Moving onto this … is slow!" via `add_msg`
  ([src/game.cpp:11765–11786](../../src/game.cpp)). All headless-safe (`add_msg` only). **Pain** is not
  touched by a plain step.

## Recommended first movement scope

Smallest faithful slice, justified by the trace above:

- **Four cardinal directions** — idents `move_n` / `move_s` / `move_e` / `move_w`. (Diagonals resolve
  through the same `look_up_action`/`get_delta_from_movement_action` path, but four cardinals keep the
  proof axis-clean; pick `move_e` first if even narrower is wanted.)
- **No diagonals** in the first cut (add later by allowing `move_ne`/`move_nw`/`move_se`/`move_sw`).
- **No vertical movement** — `up`/`down` use a different path (`vertical_move`); defer.
- **Same z-level only** — `tripoint_rel_ms(dir, 0)`; reject any z delta.
- **No door auto-open, no displacing/attacking, no water, no vehicles** — i.e. target empty, passable,
  non-dangerous terrain. If the destination is anything else, the move is either a harmless blocked-bump
  (report no-op) or would require a prompt (reject — see failure table).
- **No confirmation prompts** — the scope is defined precisely so that `query_yn`/`popup`/`npc_menu` are
  never reached. Treat reaching one as a bug to document, never to suppress.
- **Guard `do_turn()` with `u.moves <= 0`** — mandatory, to mirror the engine input loop and never block
  headless.
- **Reuse the safe-mode gate** exactly as `wait` does.

This keeps Spike 3 a single, observable proof: _the avatar's absolute position changes by one tile in the
commanded direction, the view re-centers, and the clock behaves exactly as the bootstrap/normal-turn rules
dictate._

## Proposed command schema

A `move` command inside the existing step script (the candidate shape from the task, now grounded in the
code):

```json
{
  "schema_version": 1,
  "steps": [
    { "op": "export", "name": "before_move" },
    { "op": "command", "command": "move", "direction": "move_e" },
    { "op": "export", "name": "after_move" },
    { "op": "command", "command": "wait" },
    { "op": "export", "name": "after_wait" }
  ]
}
```

| field       | rule                                                                                                                                                                                                                                                                                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `op`        | `"command"` (unchanged; `parse_script` already accepts `export`/`command`).                                                                                                                                                                                                                                                                                 |
| `command`   | `"move"` (new) or `"wait"` (existing).                                                                                                                                                                                                                                                                                                                      |
| `direction` | **required when `command == "move"`**; a **cardinal engine ident** — `move_n` / `move_s` / `move_e` / `move_w`. Validated by `look_up_action != ACTION_NULL` **and** membership in that four-ident cardinal set (diagonals `move_ne/…` and vertical `move_up/down` are out of scope → reject). Missing/invalid → `bad_schema` (exit 5). Ignored for `wait`. |

> **Why engine idents, not `"east"`.** The task's candidate used `"direction": "east"`, but the fidelity
> principle favors the engine's own vocabulary (`look_up_action` already understands `move_e`) over a new
> invented one. If a friendlier external surface is wanted, add a trivial 4-entry alias
> (`east→move_e`, …) at the parser edge — purely cosmetic; the canonical/internal value stays the engine
> ident. Either way the _internal_ path is unchanged.

**Code touch-points (for the eventual implementation, not done here):**

- `script_step` ([src/arcopolis_script.h:16–20](../../src/arcopolis_script.h)) gains a `std::string
  direction;` field; `parse_script`'s `command` branch
  ([src/arcopolis_script.cpp:68–73](../../src/arcopolis_script.cpp)) reads `direction` when
  `command == "move"` and validates it against the four cardinal idents (else `bad_schema`).
- `backend_command` ([src/arcopolis_command.h:11–14](../../src/arcopolis_command.h)) gains the same
  `direction` field; `run_script` passes it through
  ([src/arcopolis_script.cpp:170–172](../../src/arcopolis_script.cpp)).
- `apply_command` ([src/arcopolis_command.cpp:71](../../src/arcopolis_command.cpp)) gains a `"move"`
  branch: pre-check `g->check_safe_mode_allowed()` (→ `safe_mode_blocked`); resolve the delta the engine's
  way — `act = look_up_action(direction)` ([src/action.cpp:460](../../src/action.cpp)) →
  `dir = get_delta_from_movement_action(act, iso_rotate::no)` ([src/action.cpp:549](../../src/action.cpp));
  call `avatar_action::move(get_avatar(), get_map(), dir)`; then
  `if( get_avatar().moves <= 0 ) g->do_turn();`. A new `command_error_kind::invalid_direction` (→ a fresh
  exit code, next after `export_failed = 9`) covers a bad/missing direction that slips past the parser.
- No new dependency, no new flag, no UI: the `move` command rides the existing `--arcopolis-run-script` /
  `--arcopolis-export-dir` machinery and the existing `src/*.cpp` glob. (Validation belongs in the
  existing `tests/arcopolis_script_test.cpp` parser tests; the _apply_ path needs a loaded world and is
  proven by the binary run, same as Spikes 1/2.)

### Failure handling (exploration Q11)

What each failure case should do, and where the behavior is decided in the engine. The guiding rule:
**match the GUI** — a GUI bump-into-a-wall is not an error dialog, so the backend shouldn't error either;
a GUI safe-mode decline doesn't advance the turn, so the backend mustn't.

| Failure case                                                                            | Faithful backend behavior                                                                                                                                                                                               | Why / engine site                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Invalid / missing `direction`**                                                       | Reject at parse with `bad_schema` (exit 5); a value slipping past → `invalid_direction` (new code).                                                                                                                     | Parser-level; not the apply path. Validated via `look_up_action(ident) != ACTION_NULL` restricted to the four cardinal `move_*` idents ([src/action.cpp:460–490](../../src/action.cpp)).                                                           |
| **Unsafe movement (safe mode)**                                                         | Decline with `safe_mode_blocked` (exit 8); **do not move, do not advance the turn**.                                                                                                                                    | Mirrors `avatar_action::move`'s own gate ([src/avatar_action.cpp:101](../../src/avatar_action.cpp)) and the GUI `ACTION_PAUSE`/move behavior; identical to `wait` ([src/arcopolis_command.cpp:101–105](../../src/arcopolis_command.cpp)).          |
| **Blocked terrain (wall / locked door)**                                                | **Not an error** — report success with _unchanged_ `pos_abs` and the engine's `add_msg` ("You bump into the %s!" / "That door is locked!") in `messages[]`. No moves spent ⇒ `do_turn` guard skips ⇒ turn not advanced. | `walk_move` returns false → invalid-move branch ([src/avatar_action.cpp:466–497](../../src/avatar_action.cpp)); the GUI keeps the player in control.                                                                                               |
| **Movement not possible (same tile / no-op)**                                           | Success, position unchanged; guard skips `do_turn` (no moves spent).                                                                                                                                                    | `avatar_action::move` early-returns true for `dest_loc == bub_pos()` ([src/avatar_action.cpp:117–120](../../src/avatar_action.cpp)).                                                                                                               |
| **UI confirmation required** (creature/NPC/water/moving-vehicle/dangerous tile at dest) | **Out of scope ⇒ reject** rather than risk a `test_mode` query. The first scope targets terrain where these never fire; a future wider scope must handle each deliberately.                                             | `query_yn`/`npc_menu`/`popup`/`prompt_dangerous_tile` ([src/avatar_action.cpp:300,328,353,390,595](../../src/avatar_action.cpp), [src/game.cpp:11660–11667](../../src/game.cpp)); hazardous headless ([src/output.cpp:709](../../src/output.cpp)). |
| **Avatar dead / terminal state**                                                        | Check `is_game_over()` / `u.is_dead_state()` before and after; if terminal, stop the script with a typed error.                                                                                                         | `do_turn` returns true via `cleanup_at_end` ([src/game.cpp:1851–1852, 2008–2010](../../src/game.cpp)); unhandled in Spike 2 but cheap to add here.                                                                                                 |

Distinguish "did the avatar move" by **comparing `bub_pos()` before/after** (the `avatar_action::move`
bool means "auto-move not cancelled", not "moved").

## Proposed validation script

The script above, run through the persistent runner. **Do not assume it passes until implemented** — this
is the intended proof, not a result:

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before_move" },
  { "op": "command", "command": "move", "direction": "move_e" },
  { "op": "export",  "name": "after_move" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\script_move.json

$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--seed','arco-move',
    '--arcopolis-run-script','.\out\script_move.json',
    '--arcopolis-export-dir','.\out\arcopolis_move',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt
"exit=$($p.ExitCode)"   # expect 0

$b = Get-Content .\out\arcopolis_move\000_before_move.json -Raw | ConvertFrom-Json
$m = Get-Content .\out\arcopolis_move\001_after_move.json  -Raw | ConvertFrom-Json
$w = Get-Content .\out\arcopolis_move\002_after_wait.json  -Raw | ConvertFrom-Json
"pos_abs : $($b.avatar.pos_abs -join ',')  ->  $($m.avatar.pos_abs -join ',')  (expect x+1, same y,z = one tile EAST)"
"turn    : $($b.backend.turn) -> $($m.backend.turn) -> $($w.backend.turn)  (expect T, T, T+1)"
"stamina : $($b.avatar.stamina) -> $($m.avatar.stamina)  (expect a small drop from the step)"
```

**Pass criteria (faithful):** `after_move.avatar.pos_abs` is the `before_move` position with `x+1` (east),
same `y`/`z`; `backend.turn` is `T, T, T+1`; stamina drops slightly on the step; exit `0`, empty stderr.

## Risks and unknowns

- **Leftover-moves block (guarded).** If `u.moves > 0` after the step (high-speed avatar, cheap terrain
  like a road, haste), an unguarded `do_turn()` enters the blocking input loop and hangs headless. The
  `if( u.moves <= 0 )` guard removes this; the only consequence is a faithful _partial turn_ (the world
  isn't processed until moves are exhausted by later commands), which the GUI also exhibits mid-input-loop.
- **`u.moves` value right after load is empirically unknown.** It governs whether one cardinal step
  exhausts moves (clean bootstrap-on-move) or leaves leftovers (bootstrap consumed by a later command).
  It is **> 0** after load (the documented "first action is the bootstrap turn" behavior requires it), but
  the exact magnitude isn't read from the code. Mitigation: the guard makes behavior correct either way,
  and **adding `avatar.moves` to the snapshot** (below) makes it observable. This is a runtime
  observation, **not** a reason to override state.
- **Top-half/action ordering inversion** — same as Spike 1/2 (`action` then `do_turn` vs the GUI's
  `do_turn`-with-action-inside). **⚠️ This is the defect that failed the spike** (see doc 08): it is not
  low-risk and it is not avoided by loading once. The "verified byte-identical for `wait`" wording here was
  never independently confirmed — it should read "seeded-reproducible; GUI-vs-backend equivalence
  unproven". The faithful fix is to run the engine's `while(!do_turn())` loop and inject the command at the
  `handle_action()` call site (`src/game.cpp:2004`), which **does** require a one-site gameplay-source seam;
  that touch is now justified rather than deferred.
- **`avatar_action::move`'s bool is not "did I move."** It returns `false` for auto-move-cancel,
  safe-mode, blocked, attack, etc., and `true` for same-tile no-ops and door opens
  ([src/avatar_action.cpp:99–498](../../src/avatar_action.cpp)). The backend must judge success by
  **comparing `bub_pos()` before/after**, not by the return value.
- **`test_mode` prompts answer silently/wrongly (not a hang).** `query_yn` returns `false` ("No") via
  `query_popup`'s `{false,"ERROR"}` short-circuit ([src/popup.cpp:269–270](../../src/popup.cpp)); a
  `uilist` prompt `debugmsg`s "Tried to open UI in test mode" + `UILIST_ERROR`
  ([src/ui.cpp:918–921](../../src/ui.cpp)). The first scope avoids every path that reaches one; a future,
  wider scope (water, NPCs, dangerous terrain) must handle each deliberately (reject with a typed error),
  never let the silent auto-"No" stand in for the frontend.
- **Game-over during the move** (step into a hazard that kills the avatar → `do_turn` returns `true` via
  `is_game_over`/`cleanup_at_end`, [src/game.cpp:1851–1852, 2008–2010](../../src/game.cpp)) is unhandled,
  as in Spike 2; the sheltered fixture won't trigger it, but a terminal-state check belongs in the move
  branch before/after.
- **Nondeterminism** — like all prior spikes, RNG seeds from `time()` unless `--seed` is passed.

## Implementation recommendation

**A) Implement movement now, via the identified safe path** — but only at the tightly-scoped first slice
above:

> Add a `move` command to the existing step-script runner that resolves a cardinal ident the engine's way
> (`look_up_action` → `get_delta_from_movement_action(act, iso_rotate::no)`), calls the **engine's own**
> `avatar_action::move(get_avatar(), get_map(), dir)` behind the same `check_safe_mode_allowed()` gate
> `wait` uses, and then calls `g->do_turn()` **only when `u.moves <= 0`** (mirroring the engine's
> input-loop exit). Prove it with `export → move_e → export → wait → export` showing a one-tile eastward
> `pos_abs` delta and a faithful `T → T → T+1` clock.

The path is faithful (it is the exact GUI call site), UI-free at this scope (every prompt branch is
provably out of reach), and reuses the proven Spike 1/2 `+ do_turn` pattern. The one real hazard
(leftover moves) is closed by a guard that is itself a copy of the engine's own loop condition — no state
is overridden, nothing is faked. The single empirical unknown (`u.moves` after load) is made safe by that
guard and observable by one additive snapshot field. No smaller code spike (option B) is needed: the
exploration already identified the safe path end-to-end. No blocking subsystem (option C) stands in the
way — the safe-mode and turn-advance subsystems are already understood from Spikes 1/2 and confirmed here.

## Snapshot fields: enough today, and one worth adding

**Enough already** to prove a cardinal move (no exporter expansion required):

- `avatar.pos_abs` / `avatar.pos_local` ([src/arcopolis_export.cpp:66–88](../../src/arcopolis_export.cpp))
  — the primary proof. `pos_abs` changes unambiguously by one tile; `pos_local` shifts too (the tile
  window re-centers on `u.bub_pos()`, [src/arcopolis_export.cpp:121](../../src/arcopolis_export.cpp)).
- `backend.turn` ([src/arcopolis_export.cpp:62](../../src/arcopolis_export.cpp)) — proves the
  bootstrap/normal-turn clock behavior.
- `avatar.stamina` ([src/arcopolis_export.cpp:92](../../src/arcopolis_export.cpp)) — confirms the step's
  `burn_move_stamina`.
- `tiles[]` ([src/arcopolis_export.cpp:120–143](../../src/arcopolis_export.cpp)) — re-centred window shows
  the changed surroundings.

**One small, justified addition** (optional but recommended for this spike): `avatar.moves`
(`Character::moves`) in `write_avatar`. It is the single number that explains turn-completion behavior
(did the step exhaust moves? did `do_turn` fire?) and makes the leftover-moves risk directly observable —
turning the one empirical unknown into a measured value. It is a one-line read-only addition, consistent
with the existing avatar getters, and does **not** over-expand the exporter (no new subsystem, no list).
Avoid adding more than this for Spike 3.

## PowerShell local checks

Run from the repo root (paths shown as repo-relative; do not paste machine-specific absolute paths):

```powershell
# 1. The faithful movement entry point and its prompts/special cases
Select-String -Path .\src\avatar_action.cpp -Pattern 'avatar_action::move|check_safe_mode_allowed|query_yn|npc_menu|walk_move|open_door'
Select-String -Path .\src\avatar_action.h   -Pattern 'bool move\('

# 2. The GUI dispatch (movement keys -> avatar_action::move) and the engine's ident->action->delta path
Select-String -Path .\src\handle_action.cpp -Pattern 'ACTION_MOVE_|avatar_action::move|get_delta_from_movement_action'
Select-String -Path .\src\action.cpp        -Pattern 'look_up_action|"move_n"|"move_e"|get_delta_from_movement_action'

# 3. Turn semantics: input loop guard, bootstrap branch, move replenishment, walk_move move-cost
Select-String -Path .\src\game.cpp     -Pattern 'while\( u.moves > 0|if\( u.moves > 0|if\( new_game|calendar::turn \+=|u.moves -= u.run_cost|place_player'
Select-String -Path .\src\creature.cpp -Pattern 'moves \+= get_speed'

# 4. Direction constants the backend should map to
Select-String -Path .\src\point.h -Pattern 'point_(north|south|east|west)\{'

# 5. test_mode prompt behavior (why prompts must be scoped out: silent "No" / logged error, not a hang)
Select-String -Path .\src\output.cpp -Pattern 'query_yn'
Select-String -Path .\src\popup.cpp  -Pattern 'test_mode|"ERROR"'
Select-String -Path .\src\ui.cpp     -Pattern 'Tried to open UI in test mode'

# 6. Where a 'move' command would slot in (no change yet — just the seams)
Select-String -Path .\src\arcopolis_command.cpp -Pattern 'cmd.command == |do_turn|check_safe_mode_allowed'
Select-String -Path .\src\arcopolis_script.cpp  -Pattern 'op == "command"|apply_command|direction'

# 7. (after implementation) build + run the movement proof script — see "Proposed validation script"
#    cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
```

## Citation audit

Every load-bearing **behavioral** claim (X happens/returns/advances) must cite the line that _implements_
it — not a comment, declaration, wrapper, or caller — and every **absence** claim ("there's no X / must
bypass") must be backed by a search that would have surfaced X. This table is the audit; re-checking it
means opening each cited line and confirming it does what the claim says (regenerate with PowerShell check
#1–#5 above).

| Claim                                                                       | Type       | Citation (implementing line)                                         | Verdict                                                               |
| --------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `avatar_action::move` is the GUI's movement call                            | behavioral | [handle_action.cpp:1957](../../src/handle_action.cpp)                | ✅ leaf-verified                                                      |
| `move` runs the safe-mode gate first                                        | behavioral | [avatar_action.cpp:101](../../src/avatar_action.cpp)                 | ✅                                                                    |
| `walk_move` _decrements_ moves (`-= run_cost`)                              | behavioral | [game.cpp:11726](../../src/game.cpp)                                 | ✅                                                                    |
| `place_player` repositions the avatar                                       | behavioral | [game.cpp:11865 / 11888](../../src/game.cpp)                         | ✅                                                                    |
| Bottom half (monmove/process_turn/world_tick) runs after the input loop     | behavioral | [game.cpp:2087 / 2102 / 2192](../../src/game.cpp)                    | ✅                                                                    |
| Bootstrap turn clears `new_game`, no calendar advance                       | behavioral | [game.cpp:1879–1884](../../src/game.cpp)                             | ✅                                                                    |
| Input loop skipped when `moves <= 0`                                        | behavioral | [game.cpp:1979–1980](../../src/game.cpp)                             | ✅                                                                    |
| `process_turn` replenishes moves (`+= get_speed`)                           | behavioral | [creature.cpp:247](../../src/creature.cpp)                           | ✅                                                                    |
| **`do_pause` zeroes `moves`**                                               | behavioral | [character_turn.cpp:1084](../../src/character_turn.cpp)              | ⚠️→✅ _was cited to the file with no line; opened the leaf this pass_ |
| `look_up_action` maps `move_e`→`ACTION_MOVE_RIGHT`, `ACTION_NULL` on miss   | behavioral | [action.cpp:460–490](../../src/action.cpp)                           | ✅                                                                    |
| `get_delta_from_movement_action` delta; iso only if `use_tiles && tile_iso` | behavioral | [action.cpp:549–572, 551](../../src/action.cpp)                      | ✅                                                                    |
| `query_yn` → `{false,"ERROR"}` under `test_mode`                            | behavioral | [popup.cpp:269–270](../../src/popup.cpp)                             | ✅                                                                    |
| `uilist::query` → `debugmsg` + `UILIST_ERROR` under `test_mode`             | behavioral | [ui.cpp:918–921](../../src/ui.cpp)                                   | ✅                                                                    |
| **`prompt_dangerous_tile` is a `query_yn`**                                 | behavioral | [game.cpp:11406](../../src/game.cpp)                                 | ⚠️→✅ _was cited to the call site only; opened the leaf this pass_    |
| Blocked move spends no moves unless blind/stunned                           | behavioral | [avatar_action.cpp:466–497](../../src/avatar_action.cpp)             | ✅                                                                    |
| "Must bypass the action layer — no string→action path"                      | absence    | refuted by `look_up_action` ([action.cpp:460](../../src/action.cpp)) | ✅ revised: the path exists; the doc now reuses it                    |

**Not leaf-verified (flagged as estimates, not asserted as fact):** the ~~100-move cost of a flat-floor
step (`combined_movecost`/`run_cost` internals not opened — hedged with "~~" and made observable via the
proposed `avatar.moves` field), and `u.moves > 0` immediately after load (reasoned from the documented
"first post-load action is the bootstrap turn", flagged empirical, and made safe by the `moves <= 0`
guard regardless of its exact value).
