# Spike 24 — matched-stair vertical movement backend-input witness

## Status and scope

- **Built.** Adds the smallest Arcopolis command support to drive native BN vertical movement, and proves
  a **matched-stair down → up round trip** on `ArcopolisStairsTest` (the Spike 23 fixture).
- **Matched-stair only.** This is Stage-A Step 1's movement half from
  [47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md) §9 (the
  fixture was Spike 23; the proof order — fixture first, movement second — is doc 48 §20).
- **Equivalence level 2/3** (engine action reached, NOT registered-input level 4) — exactly like planar
  `move`. See below.
- **No engine change.** Native BN already dispatches the vertical actions; this spike is command
  plumbing + a regression. No change to `handle_action.cpp`, `game.cpp`, the backend-input seam, the
  live protocol, or the export.

## Public API (the chosen shape)

```json
{ "schema_version": 1, "command": "vertical_move", "direction": "down" }
{ "schema_version": 1, "command": "vertical_move", "direction": "up" }
```

A new verb `vertical_move` with a **distinct** vertical vocabulary `"down"`/`"up"`. `schema_version`
stays **1** (additive). Malformed forms fail loud with `bad_schema`: missing `direction`; a non-vertical
direction (`"move_down"`/`"move_up"`/`"move_n"`/`"here"`/`""`). `move`, `examine`, and `pickup` are
unchanged and still reject vertical directions — the planar/vertical split is preserved.

### Why this shape (both fronts)

This was an explicit API decision. Candidates: **A** separate `move_up`/`move_down` verbs; **B**
`vertical_move` with a `direction` field; **C** extend planar `move` with vertical directions; **D** a raw
`action` passthrough verb.

- **Engine internals.** B maps as cleanly as any candidate: `command_to_action` adds one branch
  (`down` → `ACTION_MOVE_DOWN`, `up` → `ACTION_MOVE_UP`, returned directly as `wait`/`examine`/`pickup`
  do). It rides the existing M1 seam with **no new machinery** (`next_backend_action` returns any
  resolved `action_id` generically), never calls `game::vertical_move` directly, and never mutates the
  avatar position.
- **Public API.** B keeps the **planar vs vertical** distinction at the verb level (`move` stays strictly
  planar; vertical is its own verb), so a future mouse-first frontend never conflates them. The `"down"`/
  `"up"` vocabulary is deliberately **not** the planar `move_*` tokens, so it is not misleading next to
  the eight planar directions; it exposes no raw BN internals (vs D); and the bounded down/up-only
  vocabulary keeps it from implying ramps/elevators/climbing/generic vertical interactions.
- **Why not the others.** A is acceptable but its verb names collide textually with the _rejected_ planar
  direction tokens `move_up`/`move_down` (the "misleading frontend" risk). C is rejected — `move` is
  planar by strong repo convention and vertical is the separate `game::vertical_move` primitive. D is
  rejected — it exposes BN internals and invites generic passthrough. (Doc 47 §9 had _sketched_ `move_up`/
  `move_down` verbs, i.e. option A; this spike chose B as the binding API decision.)

## Engine-internal mapping

`vertical_move` `down` → `ACTION_MOVE_DOWN`; `up` → `ACTION_MOVE_UP`. `handle_action()` dispatches these
to the native `game::vertical_move(-1/+1, false)` for a non-mounted, non-vehicle avatar
(`src/handle_action.cpp:2212,2307`). `vertical_move` consumes the avatar's `moves` and leaves the turn
tick to `game::do_turn()` — the protected path (command → `action_id` → `handle_action()` → `do_turn()` →
read-only snapshot/transcript) is unchanged.

The matched-stair fixture makes the run **prompt-free**: `find_stairs` (`src/game.cpp:14840-14846`)
early-returns the aligned counterpart stair (descend: the `GOES_UP` tile directly below; ascend: the
`GOES_DOWN` tile directly above), so `find_or_make_stairs` never reaches its lava/no-return/push-past
`query_yn` prompts. If the path ever _did_ raise an unarmed prompt, the Spike 20/21 guards report
`unexpected_prompt` (exit 14 non-live) — no silent default is possible.

## Equivalence level — precisely level 3 (engine-action-reached), NOT level 4

The compact "level 2/3" label resolves to **level 3** ("same engine action / finalization path"); level 2
(same final state) also holds, witnessed by the round trip. It is **definitively not level 4**. The numbered
levels are defined in `AGENTS.md:111-120`, restated at [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md)
§Terminology → "Equivalence levels (1–4)".

The decisive fork is in `game::handle_action()` (`src/handle_action.cpp:1842`):

- **A player's `>`/`<` keypress** flows through the engine's active input loop —
  `get_player_input()` → `input_context::handle_input()` → `look_up_action()`
  (`src/handle_action.cpp:1876`, then `:1900`) — so the _registered input is consumed by the input loop_.
  That consumption is what level 4 requires.
- **Arcopolis instead injects** the pre-resolved `action_id` at the dispatch seam:
  `if( backend_session_active() ) act = next_backend_action();` (`src/handle_action.cpp:1857-1858`). Because
  `act` is now non-null, the `if( act == ACTION_NULL )` block at `:1898-1900` is skipped (`look_up_action`
  never runs) and the `get_player_input()` branch at `:1876` is never entered. The injected `act` feeds the
  **same** `switch(act)` → the **same** `ACTION_MOVE_DOWN`/`UP` case (`:2212`/`:2307`) → the **same**
  `game::vertical_move`. This is the identical mechanism BN auto-move and Arcopolis planar `move` use.
  (`command_to_action` returns `ACTION_MOVE_DOWN`/`UP` literally for `vertical_move`, vs
  `look_up_action(direction)` for planar `move` — same outcome: an injected action_id.)

So the registered input is **injected at the dispatch point, not consumed by the active input loop** ⇒
level 3, not level 4. On the matched-stair fast path `vertical_move` raises no prompt, so
`input_context::handle_input()` is never even entered for the command — there is no registered-input
consumption to drive, only one action injected.

**Contrast — what IS level 4 in Arcopolis:** the prompt/menu paths serve _registered actions through a real
`input_context::handle_input()` loop_ — the examine direction-chooser (Spike 11A), the pickup `"PICKUP"`
menu and the vehicle-source / secondary-capacity `uilist` (12A/13B/14), and the deployed-furniture
`query_yn` (15). `vertical_move` arms no such transaction, so action-injection at the seam IS the faithful
reproduction; a level-4 vertical path would need a different mechanism (feeding the `move_down`/`move_up`
input through `handle_input`) that no movement command implements and the slice does not require.

**Integrity (audited):** command → `action_id` → real `game::handle_action()` → `game::do_turn()` (owns the
tick); no `arcopolis_*` code calls `game::vertical_move()` directly, mutates the avatar's position/z, or
revives `command → do_turn`. Calling this "level 4" would be exactly the AGENTS.md "launder a weaker claim
through softer words" violation; calling it merely level 2 would under-claim (the engine action genuinely is
reached through the real dispatch + tick).

## Fixture, command sequence, what was proven

- **Fixture:** `ArcopolisStairsTest` (Spike 23) — avatar on `t_stairs_down` at `[6301,6421,0]`, matched
  `t_stairs_up` directly below at `[6301,6421,-1]`.
- **Command sequence** (`--arcopolis-run-script`): `export before` → `vertical_move down` →
  `export after_down` → `vertical_move up` → `export after_up`.
- **Proven** (gated by [`vertical_movement_regression.ps1`](vertical_movement_regression.ps1)):
  - `before`: `pos_abs [6301,6421,0]`, `z 0`, avatar tile `t_stairs_down`.
  - `after_down`: `pos_abs [6301,6421,-1]`, `z -1`, avatar tile `t_stairs_up`, x/y unchanged,
    `backend.turn` advanced.
  - `after_up`: `pos_abs [6301,6421,0]`, `z 0`, avatar tile `t_stairs_down`, x/y unchanged,
    `backend.turn` advanced again.
  - Process exit 0; `session_end status="ok"` (no `unexpected_prompt`, no success-by-silent-default).
  - The `after_down` snapshot re-windows on the new z-level — the **per-floor-observation** witness doc
    47 §4 flagged as LIKELY-but-unwitnessed.
- **Unit coverage** (`[arcopolis]`): `parse_command`/`parse_script` accept `vertical_move` down/up and
  reject the malformed forms; `command_to_action` resolves down/up → `ACTION_MOVE_DOWN`/`ACTION_MOVE_UP`;
  `is_supported_vertical_direction` accepts only down/up; `is_live_only_command("vertical_move")` is
  false; `move`/`examine`/`pickup` still reject vertical; no raw `action` passthrough verb exists.

## What this does NOT prove

- **Not** generic vertical movement — only the _aligned-stair_ fast path.
- **Not** ramps, elevators, ladders, ropes, climbing, falling, ledges, or rooftops.
- **Not** 5–6 floor traversal; **not** simultaneous multi-z export.
- **Not** level-4 (registered-input) equivalence — `vertical_move`, like planar `move`, is
  engine-action-reached (level 2/3); its `action_id` never enters `input_context::handle_input`.
- Nothing about package placement, drones, enemies, NPC dialogue, bribe, trade, guard interaction, death
  continuation, factions, or procedural quests (Stage B / out of scope).

## Files

- `src/arcopolis_command.{h,cpp}` — `expected_vertical_directions`, `is_supported_vertical_direction`,
  the `vertical_move` branches in `parse_command` and `command_to_action`.
- `src/arcopolis_script.cpp` — the `vertical_move` command-step branch in `parse_script`.
- `tests/arcopolis_command_test.cpp`, `tests/arcopolis_backend_input_test.cpp`,
  `tests/arcopolis_script_test.cpp` — the unit coverage above.
- `docs/arcopolis/vertical_movement_regression.ps1` — the round-trip regression.
- Docs in this PR: this file, `TEST_FIXTURES.md`, `fixtures/README.md`.
- Current-truth / strategy docs such as `ARCOPOLIS_STATE.md` and doc 47 §9 are updated in the companion
  documentation PR (not this one).

## Live mode

Live mode (`--arcopolis-live`) is expected to use the same parser and `command_to_action` plumbing, so no
dedicated live-mode plumbing was added. **This PR's positive witness is the non-live run-script regression**;
no live positive probe was added (no narrow existing pattern for one without broadening the spike). The
existing live/frontend negative probes still send `{"command":"move","direction":"move_up"}`, which stays
rejected because `move` remains planar — and still pass.
