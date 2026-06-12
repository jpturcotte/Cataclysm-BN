# Arcopolis Spike 11A-prep — Examine / targeted-interaction feasibility

**Status: documentation-only investigation (2026-06-12).** No command/protocol/snapshot/frontend
changes; no C++ touched. This is the decision record for the next implementation spike: it answers,
from the Bright Nights source, whether an external client can drive a real BN examine-style
interaction through the accepted backend input seam — supplying any required target direction,
avoiding prompt/menu deadlocks, and observing the real engine outcome through snapshots and the
transcript. The next implementation PR should be based on the decision documented here.

## Why this exists

Every command proven so far (`wait`, `move`) is **one** engine `action_id` consumed at the
`game::handle_action()` seam; the engine never asks a follow-up question. Examine is a different
interaction shape: the action's own handler asks the player **"Examine where?"** through a
**nested** input read, and several target categories then fan out into menus, prompts, or whole
nested UI sessions. None of those nested reads pass through the backend seam. The architectural
risk is therefore not a wrong result but a **deadlock**: a headless process blocking forever inside
a prompt no client can answer. That risk class covers every targeted/prompted interaction (open,
close, smash, pickup, NPC interaction…), so it must be understood before any of them is exposed.

## Current proven baseline

- Persistent live protocol over stdin/stdout JSONL, one request at a time, served by a blocking
  pull source at the `handle_action` seam (Spike 9B,
  [21_SPIKE9B_LIVE_PROTOCOL.md](21_SPIKE9B_LIVE_PROTOCOL.md)).
- `move`/`wait` through the real seam, engine-owned turns and world tick, multi-action turns, and
  the faithful move-into-NPC no-op — the engine's `uilist` auto-cancels under `test_mode`
  ([15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)).
- Terrain change through movement is proven end-to-end: a real `t_door_c` bump-open observed live,
  with the snapshot diff catching exactly the changed tile
  ([23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md](23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md)).
- A browser frontend exists (map, inspector, diff, optional tileset — Spikes 10A–10C).
- Examine is a **new class of risk**: nested input, not rendering or single-action dispatch.

## Source map

Engine files and functions inspected (all paths relative to the repo root):

| Area                   | File                                                                                                                                                                                                     | Functions / symbols read                                                                                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Action ids & choosers  | `src/action.h`, `src/action.cpp`                                                                                                                                                                         | `ACTION_EXAMINE`, `action_ident`, `can_interact_at`, `can_examine_at`, `choose_direction`, `choose_adjacent`, `choose_adjacent_highlight`, `choose_adjacent_uilist` |
| Dispatch               | `src/handle_action.cpp`                                                                                                                                                                                  | the backend seam branch, `case ACTION_EXAMINE/OPEN/CLOSE/PICKUP`, `open()`, `close()`, `smash()`, `grab()`                                                          |
| Examine execution      | `src/game.cpp`                                                                                                                                                                                           | `game::examine()` (both overloads), `game::npc_menu`, `game::use_computer`, `game::pickup`, `game::look_around`                                                     |
| Examine actors         | `src/iexamine.cpp`, `src/mapdata.h`                                                                                                                                                                      | `iexamine::none`, `iexamine::locked_object`, `iexamine_function`                                                                                                    |
| Pickup                 | `src/pickup.cpp`                                                                                                                                                                                         | `pickup::pick_up`, `pick_up_from_items`, the `"PICKUP"` input context                                                                                               |
| Doors                  | `src/gates.cpp`, `data/json/furniture_and_terrain/terrain-doors.json`                                                                                                                                    | `doors::close_door`; `t_door_c`, `t_door_locked` definitions                                                                                                        |
| Computers              | `src/computer_session.cpp`                                                                                                                                                                               | `computer_session::use`                                                                                                                                             |
| Input plumbing         | `src/input.cpp`, `src/sdltiles.cpp`                                                                                                                                                                      | `input_context::handle_input`, `register_directions`, `input_manager::get_input_event`                                                                              |
| Prompt primitives      | `src/ui.cpp`, `src/popup.cpp`, `src/output.cpp`, `src/ui_manager.cpp`                                                                                                                                    | `uilist::query`, `query_popup::query_once`, `query_yn`, `ui_adaptor::redraw_invalidated`                                                                            |
| Headless wiring        | `src/main.cpp`, `src/options.cpp`                                                                                                                                                                        | `test_mode` assignments, curses-init gating, `AUTOSELECT_SINGLE_VALID_TARGET`                                                                                       |
| Backend                | `src/arcopolis_command.cpp`, `src/arcopolis_backend_input.{h,cpp}`, `src/arcopolis_live.cpp`, `src/arcopolis_script.cpp`                                                                                 | vocabulary, provider, both runner loops and stall backstops                                                                                                         |
| Keybinding             | `data/raw/keybindings/keybindings.json`                                                                                                                                                                  | the `examine` entry                                                                                                                                                 |
| Headless display layer | `src/cursesport.cpp`, `src/cursesdef.h`, `src/sdltiles.cpp`, `src/cached_options.cpp`, `src/cata_tiles.cpp`                                                                                              | `stdscr`/`wnoutrefresh`/`doupdate`, `refresh_display`, `try_sdl_update`, `CheckMessages`, `HandleDPad`, `pump_events`, `tile_iso`/`use_tiles`                       |
| Actor audit            | `src/iexamine.cpp` (whole-file primitive sweep), `src/iexamine_elevator.cpp`, `src/monexamine.cpp`, `src/vehicle_use.cpp`, `src/inventory_ui.cpp`, `src/string_input_popup.cpp`, `src/handle_liquid.cpp` | `iexamine_function_from_string`, per-actor raw primitives, `vehicle::interact_with`, `inventory_selector`, `string_input_popup::create_context`                     |

## BN action dispatch path

- `ACTION_EXAMINE` is declared in the `action_id` enum (`src/action.h:102`); `action_ident` maps it
  to `"examine"` (`src/action.cpp:138-139`); the user-visible binding is `e` — "Examine Nearby
  Terrain", category `DEFAULTMODE` (`data/raw/keybindings/keybindings.json:1795-1801`).
- `game::handle_action()` consumes the backend-provided `action_id` at the seam — the **first**
  branch of the input-acquisition chain (`src/handle_action.cpp:1778-1779`), mirroring auto-move.
  The seam intercepts **only this top-level "next action" read**; in a backend session
  `get_player_input` is never reached, so **every `input_context::handle_input` call during a
  backend session is by definition a nested read**. This fact carries the whole compatibility
  analysis below.
- The dispatch case (`src/handle_action.cpp:2279-2287`): a `trait_SHELL2` message guard, a mouse
  branch, else `examine()` — the engine's own prompting overload.

## Examine call graph

Only branches verified by source reading are shown.

```
game::handle_action()                       [seam: src/handle_action.cpp:1778 — top-level action only]
  case ACTION_EXAMINE                       (src/handle_action.cpp:2279)
  -> game::examine()                        (src/game.cpp:8522)
     -> choose_adjacent_highlight(ACTION_EXAMINE)        (src/game.cpp:8532 -> src/action.cpp:1138)
        -> valid-target set: can_interact_at -> can_examine_at   (src/action.cpp:673, :631)
        -> [AUTOSELECT_SINGLE_VALID_TARGET on: 0 valid -> failure msg, return;
            exactly 1 valid -> returned with NO prompt          (src/action.cpp:1163-1169)]
        -> choose_adjacent -> choose_direction                  (src/action.cpp:1121, :1078)
           -> input_context("DEFAULTMODE"), register_directions + "pause" + "QUIT"
           -> loop { ui_manager::redraw(); ctxt.handle_input(); }   [NO test_mode gate]
              -> inp_mngr.get_input_event()                     (src/input.cpp:942 -> src/sdltiles.cpp:3951)
                 -> blocking CheckMessages()/SDL_Delay(1) loop  [headless: blocks forever]
        -> selection validated against the valid set; outside it -> nullopt, message-free
                                                                (src/action.cpp:1182)
  -> game::examine(tripoint)                (src/game.cpp:8610)
     -> creature at target?  monster: message (+ conditional pet/mech/paybot/friendly uilist menus)
                             npc: game::npc_menu -> uilist      (src/game.cpp:8101, :8121)
     -> vehicle part?        vehicle::interact_with (menu)      (src/game.cpp:8676)
     -> CONSOLE flag?        use_computer -> computer_session::use   (src/game.cpp:8680-8681,
                                                                 :7172 -> src/computer_session.cpp:92)
     -> furniture examine actor / terrain examine actor         (src/game.cpp:8692, :8697)
     -> trap? iexamine::trap                                    (src/game.cpp:8716-8717)
     -> auto-pickup tail: pickup::pick_up(examp, 0)             (src/game.cpp:8755)
        -> pick_up_from_items -> input_context("PICKUP") UI     (src/pickup.cpp:627, :721, :1164)
```

## Input requirements

Examine needs, in the general case, **direction input** through a nested raw `input_context` read
— and, depending on the target, may then open a menu, a y/n prompt, or a whole nested UI session.
The decisive split is between **two prompt classes** with opposite headless behavior (all
`--arcopolis-*` modes run `test_mode = true`, `src/main.cpp:528,542,556,570,580`, and never
initialize curses, `src/main.cpp:881-887`):

| Primitive                                                                | Headless (`test_mode`) behavior                                                         | Implementing line(s)                              |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `uilist::query`                                                          | auto-cancel: `debugmsg` + `ret = UILIST_ERROR`, returns **before** any input read       | `src/ui.cpp:916-922`                              |
| `query_popup::query_once` (→ `query_yn`)                                 | auto-cancel: returns `"ERROR"` result; `query_yn` yields `false`                        | `src/popup.cpp:269-271`, `src/output.cpp:707-725` |
| `ui_manager::redraw`                                                     | safe no-op (`redraw_invalidated` early-returns)                                         | `src/ui_manager.cpp:325-330`                      |
| `input_context::handle_input`                                            | **no gate** — loops on `get_input_event`                                                | `src/input.cpp:925-992`                           |
| `input_manager::get_input_event`                                         | **no gate** — infinite `CheckMessages()/SDL_Delay(1)` wait for input that cannot arrive | `src/sdltiles.cpp:3951-3996`                      |
| `choose_direction` / `choose_adjacent*`                                  | **no gate** — raw `handle_input` loop ⇒ blocks forever                                  | `src/action.cpp:1078-1119`                        |
| pickup selection UI                                                      | **no gate** — raw `"PICKUP"` `handle_input` loop ⇒ blocks forever                       | `src/pickup.cpp:721, :1164`                       |
| `computer_session::use`                                                  | full nested UI session mixing gated `query_any`/`query_ynq` with its own loop           | `src/computer_session.cpp:92`                     |
| `string_input_popup`                                                     | **no gate** — raw `"STRING_INPUT"` loop; its cancel action is `TEXT.QUIT`, not `QUIT`   | `src/string_input_popup.cpp:105-133`              |
| `inventory_selector` (all `game_menus::inv::*` / `inv_map_splice` menus) | **no gate** — raw `"INVENTORY"` loop (does register `QUIT`)                             | `src/inventory_ui.cpp:1837, :1851, :1887`         |

**The blocked read is a pure busy-wait hang, not a crash — resolved from source.** The only
pre-block draw, `wrefresh( catacurses::stdscr )` (`src/sdltiles.cpp:3962-3965`), is doubly safe:
it is gated on the `needupdate` flag (static, initially `false`, `:109`), and even when taken,
`wnoutrefresh` null-guards the never-initialized `stdscr` (`src/cursesport.cpp:186-190`; `stdscr`
is a default-constructed null window, `src/cursesport.cpp:36`, `src/cursesdef.h:52-74`) while
`doupdate` → `refresh_display` returns immediately under `test_mode` (`src/cursesport.cpp:206-209`,
`src/sdltiles.cpp:502-509`). Inside the wait loop, `CheckMessages()` (`:2903`) reduces on Windows
to a null-joystick hat probe (`joystick` is only ever assigned inside `WinCreate`,
`src/sdltiles.cpp:151, :374-386`, unreachable in `test_mode`; SDL parameter-validates the null and
returns "centered" — the one non-repo assumption, SDL's documented API contract), an empty poll
loop (the offscreen driver delivers no events), and a tail whose only live branch is the
`test_mode`-gated refresh (`:3614-3615` → `:532-540` → `:507-509`). The engine even acknowledges
the hazard itself: `input_manager::pump_events()` already guards `if( test_mode ) return;` before
calling `CheckMessages` (`src/sdltiles.cpp:3936-3940`) — `get_input_event` simply lacks the same
guard. Verdict: an undetectable ~1 ms-cadence busy-wait, fatal and silent; it must stay
unreachable by design.

Two findings sharpen this:

- **`AUTOSELECT_SINGLE_VALID_TARGET` (an interface option, default `true`,
  `src/options.cpp:1709-1714`)** changes whether the direction prompt happens at all: 0 valid
  targets → failure message and return (no prompt); exactly 1 → that tile is returned **without
  any prompt**; 2+ (or option off) → the blocking `choose_direction`. Backend correctness must
  **never** depend on this option: it is world-config state, and it silently changes _which tile
  gets examined_.
- **No existing backstop can catch a nested block.** Both runner loops check progress **between**
  `g->do_turn()` returns — the script runner's cursor backstop (`src/arcopolis_script.cpp:226-256`)
  and the live runner's request-counter backstop (`src/arcopolis_live.cpp:445-478`). A nested read
  blocks **inside** `do_turn`, so the loop never iterates and the backstop never fires: a silent
  hang in script mode, and a forever-pending request in live mode (the command response is written
  at the _next_ provider call, `src/arcopolis_live.cpp:108-124`, which never comes).

`choose_direction` itself maps `"pause"` to the self-tile (`src/action.cpp:1108-1109`), so a
future direction vocabulary needs a `here`-style token; examine of one's own tile is a real GUI
behavior.

## Target-case behavior

Behavior of `game::examine(tripoint)` per target category, assuming the direction prompt has been
answered (its check order: creature → vehicle → console → furniture actor → terrain actor → trap →
sealed → auto-pickup tail, `src/game.cpp:8610-8759`). "Headless today" = what would happen in the
current backend **if** the verb were naively wired to `ACTION_EXAMINE` with no other change.

| Target                 | Expected source path                                                                                                                                                                                    | Needs extra input?                 | Mutates state?          | Consumes turn/moves?                   | Risk (headless today)                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ----------------------- | -------------------------------------- | ------------------------------------------------------------------------------- |
| empty floor            | not in `can_examine_at`'s valid set (`src/action.cpp:631-659`); selection filtered, message-free nullopt (`:1182`)                                                                                      | —                                  | no                      | no                                     | not selectable; silent engine no-op                                             |
| item pile              | valid via `has_items` (`:641`) → `iexamine::none` + auto-pickup tail → `"PICKUP"` UI (`src/pickup.cpp:721`)                                                                                             | yes — pickup menu (raw loop)       | only if items taken     | via pickup activity                    | **deadlock** (ungated raw loop)                                                 |
| furniture, no actor    | `iexamine::none` — "That is a %s." (`src/iexamine.cpp:253-256`); pickup tail if items on tile                                                                                                           | none                               | no                      | no                                     | message-only (pickup deadlock if items present)                                 |
| furniture with actor   | `xfurn_t.examine` (`src/game.cpp:8692`), e.g. `iexamine::transform`/`workbench` — typically `uilist`-driven                                                                                             | menu (uilist)                      | possible                | possible                               | mostly auto-cancel (gated) — raw exceptions enumerated in the actor audit below |
| closed unlocked door   | `t_door_c` has **no** `examine_action` (`terrain-doors.json:194-231`) → `iexamine::none`; opening is `ACTION_OPEN`/bump                                                                                 | none                               | no                      | no                                     | message-only; door does **not** open via examine                                |
| open door              | same — no `examine_action` → `iexamine::none`                                                                                                                                                           | none                               | no                      | no                                     | message-only                                                                    |
| locked door            | `t_door_locked` → `examine_action: "locked_object"` (`terrain-doors.json:1461`) → `iexamine::locked_object` (`src/iexamine.cpp:1802-1855`): crouch+pickable → lockpick, prying tool → pry, else message | none directly (tool-dependent)     | possible (pry/lockpick) | via lockpick activity (`ACT_LOCKPICK`) | message or activity; no raw prompt in this actor                                |
| NPC                    | `game::npc_menu` `uilist` (`src/game.cpp:8101`, `amenu.query()` `:8121`); on auto-cancel no branch matches and it falls to `return true` (`:8519`) → examine returns                                    | menu (uilist)                      | no (menu choices would) | no                                     | clean no-op **today** — the proven Spike-7A/doc-15 class                        |
| monster (hostile/wild) | "There is a %s." (`src/game.cpp:8626-8629`); pet/mech/pay-bot/friendly menus are conditional (`:8635-8652`)                                                                                             | none (message) / conditional menus | no                      | no                                     | message-only / auto-cancel                                                      |
| computer console       | `CONSOLE` flag (`src/game.cpp:8680`) → `use_computer` (`:7172`) → `computer_session::use` (`src/computer_session.cpp:92`) — a full nested UI session                                                    | yes — a whole session              | yes (computer actions)  | varies                                 | **unsafe — do not expose**; mixed gated/ungated reads                           |
| stairs / z-terrain     | no examine actor → `iexamine::none`; vertical traversal is `ACTION_MOVE_UP/DOWN`, not examine                                                                                                           | none                               | no                      | no                                     | message-only                                                                    |

Moves/turn semantics: examine itself never deducts moves — a completed examine returns to the
input loop with `moves` unchanged (a multi-action-turn iteration, exactly like the NPC no-op).
Contrast the sibling verbs: `open()` deducts `u.moves -= 100` on success
(`src/handle_action.cpp:617, :628`); `close()` → `doors::close_door` deducts 90 (+ up to 100 for
nudging items) (`src/gates.cpp:361, :378-381`). Open/close/pickup share examine's exact
`choose_adjacent_highlight` shape (`src/handle_action.cpp:600, :646`; `src/game.cpp:8763`);
smash and grab use plain `choose_adjacent` — **no autoselect short-circuit, they always prompt**
(`src/handle_action.cpp:761, :670`).

## Examine-actor surface audit (first-order)

The full actor surface is the JSON-name → function map in `iexamine_function_from_string`
(`src/iexamine.cpp:8143-8253`): ~95 named actors, a `lua:` prefix routing to
`iexamine::lua_examine` (`:8145-8147`), unknown names falling back to `iexamine::none` with a
`debugmsg` (`:8250-8252`), and terrain/furniture JSON without an `examine_action` defaulting to
`"none"` (`src/mapdata.cpp:1366-1373`).

A whole-file sweep of `src/iexamine.cpp` for the raw (ungated) primitives is **exhaustive at first
order** — every direct hit, attributed to its enclosing function:

| Raw primitive                 | Actor (enclosing function)                          | Implementing line(s)              |
| ----------------------------- | --------------------------------------------------- | --------------------------------- |
| `string_input_popup`          | `nanofab`                                           | `src/iexamine.cpp:372`            |
| `string_input_popup`          | `atm` (its menu's `prompt_for_amount`)              | `src/iexamine.cpp:687-697`        |
| `string_input_popup`          | `reload_furniture`                                  | `src/iexamine.cpp:4938`           |
| `string_input_popup`          | `sign` (the write branch; reading is display-only)  | `src/iexamine.cpp:5195`           |
| `string_input_popup`          | `pay_gas`                                           | `src/iexamine.cpp:5525`           |
| `string_input_popup`          | smoking-rack loader (serves `smoker_options`)       | `src/iexamine.cpp:6902`           |
| `string_input_popup`          | mill loader (serves `quern_examine`)                | `src/iexamine.cpp:7011`           |
| raw `input_context` loop      | `vending` (`"VENDING_MACHINE"`; registers `QUIT`)   | `src/iexamine.cpp:933-937, :1039` |
| inventory menu (raw selector) | `cvdmachine`, `nanofab`                             | `src/iexamine.cpp:264, :317`      |
| inventory menu (raw selector) | `autoclave_empty` (`sterilize_cbm`)                 | `src/iexamine.cpp:3203`           |
| inventory menu (raw selector) | maple-sap container helper (`tree_maple`/`_tapped`) | `src/iexamine.cpp:4309-4315`      |
| inventory menu (raw selector) | `autodoc` (install/uninstall bionic menus)          | `src/iexamine.cpp:6079, :6152`    |
| inventory menu (raw selector) | `dimensional_portal` (`titled_filter_menu`)         | `src/iexamine.cpp:7602`           |

Inventory menus count as raw because every `game_menus::inv::*` / `inv_map_splice` surface runs
`inventory_selector`'s own ungated `"INVENTORY"` loop (`src/inventory_ui.cpp:1837, :1887`; it does
register `QUIT`, `:1851`). Every other actor in the file is message-only, `uilist`/`query_yn`
gated, or activity-assigning at first order — e.g. `translocator` is a `uilist` + `query_yn`
(`src/iexamine.cpp:522, :530`), not raw. `vehicle::interact_with` (an examined vehicle tile) is a
gated `uilist` (`src/vehicle_use.cpp:2001, :2047, :2127`), so it auto-cancels today; several of its
_choices_ delegate to raw subsystems (autodoc, pickup), unreachable through a cancelled menu. The
`monexamine` pet/friendly menus are gated `uilist`s (`src/monexamine.cpp:298`) whose rename branch
contains a `string_input_popup` (`rename_pet`, `src/monexamine.cpp:692-697`) — likewise
unreachable today.

**Caveat (second order):** this sweep catches direct calls only. Helpers shared with other systems
can introduce raw reads transitively — e.g. the water/liquid-source actors route through liquid
handling, which has a `choose_adjacent` of its own (`src/handle_liquid.cpp:226`), and
`use_furn_fake_item`/`invoke_item` paths run item-use code. The standing rule for the
implementation spikes: **audit each actor's full call chain before exposing its target class**;
until then the guard converts any missed raw read into a logged auto-cancel instead of a hang.

## Arcopolis compatibility analysis

- **Vocabulary today:** `command_to_action` supports `wait` → `ACTION_PAUSE` and `move` + four
  cardinals; everything else is `unsupported_command` (`src/arcopolis_command.cpp:102-119`). An
  `examine` request today is a clean, recoverable reject (exit 6 / live `ok:false`) — nothing can
  deadlock **today** because the verb cannot reach the engine.
- **The protocol already carries a `direction` string field**, but the parser requires/validates
  it **only for `move`** (`src/arcopolis_command.cpp:59-70`). Examine should reuse the direction
  _concept and field_, not the current parser behavior — the validation must be extended to the
  examine verb explicitly.
- **One-request-at-a-time and "response at the next input-rest instant" survive unchanged** for a
  directed examine: the action completes (or faithfully cancels) within one `handle_action`
  dispatch, control returns to the provider, and the next provider call answers with the
  post-command snapshot — the same model `move` uses today.
- **Nested prompt input cannot be supplied through the current seam.** The seam feeds the
  top-level `action_id` only; nested reads call `input_context::handle_input` →
  `get_input_event`, which never consults the backend. In a backend session every `handle_input`
  call is provably nested (see "BN action dispatch path"), which makes that exact function the
  natural choke point for a future answer/guard mechanism.
- **A `needs_input` protocol state is NOT required for direction-shaped prompts.** A queued-answer
  approach suffices because the question ("which direction?") is known _before_ dispatch. A
  prompt-aware protocol would also be architecturally premature: Spike 9B's blocking pull is
  faithful because it blocks at the **between-actions rest point**; a nested read blocks
  mid-`do_turn`, where "response at next input-rest" and snapshots-at-rest have no defined meaning
  yet.

## Candidate implementation options

**Option A — direct one-shot directed examine**
(`{"op":"command","command":"examine","direction":"move_n"}`).

- Proves: a targeted interaction end-to-end through the seam; the response/snapshot model holds for
  prompting actions.
- Touches: `arcopolis_command.{h,cpp}` (verb + direction validation), the provider, and — because
  the direction must reach `choose_direction` — some nested-input delivery mechanism (see B).
- Could go wrong: alone it is **insufficient**. Even with the direction supplied, examine of an
  item tile reaches the ungated `"PICKUP"` loop (`src/game.cpp:8755` → `src/pickup.cpp:1164`) — a
  deadlock reachable by one frontend click. And with autoselect on, the prompt is sometimes
  skipped, so a naively pre-armed answer can leak (see the recommendation).
- Architecture: protects it _if_ the direction is delivered as input at a real engine seam; calling
  `g->examine(tripoint)` directly instead would be a second command path that bypasses
  `handle_action` — rejected outright.

**Option B — queued-input extension** (enqueue `ACTION_EXAMINE`, then the direction answer,
consumed when the engine asks).

- Proves: the general mechanism every future targeted verb needs (open/close/smash share the same
  chooser).
- Touches: a small gated branch at the `input_context::handle_input` choke point plus provider
  state; no protocol change beyond Option A's verb.
- Could go wrong: an unconsumed queued answer leaking into a _later_ prompt; an injected action
  string the asking context did not register; silent auto-cancels masking real bugs.
- Architecture: strongest fit — it is the M1 input-seam philosophy applied one level down (a
  synthetic keypress at the exact point a real keypress becomes an action string), and the engine
  still runs every line of its own prompting/cancel code.

**Option C — prompt-aware protocol** (backend answers "needs_input", frontend sends the choice).

- Proves: general interactive UI (menus with content, string input) — eventually needed for
  computers/dialogue.
- Touches: the protocol contract itself (a request no longer yields exactly one terminal
  response), both runners, the harness, the frontend.
- Could go wrong: blocking mid-`do_turn` has no defined rest-point semantics today (snapshots,
  transcript, stall backstops all assume between-actions rest); large blast radius.
- Architecture: not wrong, but premature — defer until a menu-shaped interaction with _unknown
  content_ is genuinely needed; the guard's transcript events (below) are the survey data for
  designing it.

**Option D — implement a different interaction first** (e.g. open/close).

- Proves: less. Open/close use the **same** `choose_adjacent_highlight` chooser, so the nested
  direction problem is identical — but their post-selection bodies are prompt-free, so they would
  let the deadlock class (pickup tail, etc.) ship latent and unwitnessed.
- Architecture: fine but low-information; open becomes the near-free **follow-up** once the
  mechanism exists (it adds the clean `moves -= 100` turn-economy witness examine cannot provide).

## Recommended next implementation spike

> **Spike 11A — directed examine through a backend nested-input seam.** Option A's protocol
> surface (new verb `examine`, reusing the existing `direction` field — zero new protocol fields)
> implemented via a minimal Option-B mechanism: a **one-slot queued direction answer** plus an
> **auto-cancel guard**, both gated on `backend_session_active()`, at the
> `input_context::handle_input` choke point. Serve the queued answer if one is armed and the
> requested action is registered in the asking context; otherwise return the context's registered
> cancel action — `"QUIT"`, or `"TEXT.QUIT"` for the text-input context
> (`src/string_input_popup.cpp:109`) — and if neither is registered, **hard-fail the session**
> rather than guess (fail-fast beats a silent hang). The hard-fail rule is a **future
> implementation policy proposal** for Spike 11A, not something this documentation PR implements.

This recommendation stands unless implementation-time re-verification contradicts the source
findings above. Framing that matters: **the guard is the spike's primary architectural artifact** —
it converts the entire raw-loop deadlock class (`choose_direction`, the pickup UI, computers,
`look_around`) into the already-accepted ESC class. Examine is the right first witness _because_
its fan-out exercises all three prompt classes in one verb: a served direction
(`choose_direction`), the engine's own `test_mode` uilist auto-cancel (NPC tile), and the new
backend guard (the pickup tail). Those last two are **distinct mechanisms** and must not be
conflated: the uilist gate is upstream engine behavior; the guard is backend behavior. Both are
faithful — an auto-cancel is exactly a GUI player pressing ESC, the engine runs its own cancel
path, and no state is faked.

Design points the implementation must carry (all source-grounded):

1. **Stale-slot leak.** With autoselect on, the 0-valid and 1-valid branches return **without ever
   calling `handle_input`** (`src/action.cpp:1163-1169`) — a pre-armed answer would survive and be
   consumed by a _later_ prompt as a real action (the `"PICKUP"` context registers
   `UP/DOWN/LEFT/RIGHT`, `src/pickup.cpp:722-725` — it would scroll the menu). Therefore:
   force-clear the slot whenever control returns to the top-level seam, emit a transcript event if
   an answer went unconsumed, and **pin `AUTOSELECT_SINGLE_VALID_TARGET = false` for backend
   sessions** (proposed as session configuration, the same class as Spike 9B's in-memory
   `AUTOSAVE` pin and the `TURN_DURATION` guard) so the commanded direction is _always_ consulted
   and protocol semantics are deterministic. Pre-validating the target tile backend-side is
   rejected — it would re-implement `can_examine_at` outside the engine.
2. **Guard observability.** Every guard fire emits a transcript event (asking input-context
   category, action returned, running count). Deny-by-default **and observable**; a silent
   auto-cancel would mask real bugs.
3. **Direction vocabulary mapping — pinned.** The chooser consumes registered **input-context
   action ids** (`UP/DOWN/LEFT/RIGHT` + diagonals from `register_directions`,
   `src/input.cpp:994-1001`), not engine `action_id`s, resolved by `ctxt.get_direction()`:
   `"UP"` → north, `"DOWN"` → south, `"LEFT"` → west, `"RIGHT"` → east
   (`src/input.cpp:1040-1072`). `choose_direction` sets `set_iso(true)`
   (`src/action.cpp:1082`), but rotation applies only when `iso_mode && tile_iso && use_tiles`
   (`src/input.cpp:1051`), and `tile_iso` is a zero-initialized global set exclusively at tileset
   load (`src/cached_options.cpp:26`, `src/cata_tiles.cpp:2220`) — which never happens headless
   (`src/main.cpp:881-887`). So the mapping is the plain one: `move_n`→`"UP"`, `move_s`→`"DOWN"`,
   `move_e`→`"RIGHT"`, `move_w`→`"LEFT"`. Reserve a `here` token for the engine's `"pause"`
   self-tile path.
4. **Parser extension.** Extend `parse_command`/`command_to_action` so `examine` requires and
   validates `direction` the way `move` does today (currently move-only,
   `src/arcopolis_command.cpp:59-70`).
5. **Hook point — concrete candidate, zero new engine accessors.** `input_context` already
   publicly exposes `is_action_registered()` (`src/input.h:475-478`) and `get_category()`
   (`:469-471`), so the guard can validate a served answer against the asking context and name the
   context in transcript events without touching the engine's API. The candidate site is the top
   of `input_context::handle_input( const int timeout )` (`src/input.cpp:930`), before the
   `while( true )` loop (`:939`) reaches the blocking `inp_mngr.get_input_event()` (`:942`) —
   injecting at the action-string level, the same value a resolved keypress yields (`:975-977`).
   One mechanical note for the implementation: the function returns `const std::string &`, so a
   served answer needs stable storage (the same pattern as the function's own
   `CATA_ERROR`/`TIMEOUT` statics).

## Fixture plan

No new fixture worlds are needed for the recommended spike; existing witnesses (under the external
fixture root convention the regressions already use via their `-FixtureSrc` default) cover it:

- **Adjacent NPC** — `ArcopolisTest`: Edwardo Stovall one tile north of the avatar
  ([15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)). `examine` + `move_n` =
  the uilist auto-cancel witness.
- **Adjacent item pile** — `ArcopolisTest`: the `evac_pamphlet` ground item sits two tiles south
  ([19_SPIKE8A_ITEM_EXPORT.md](19_SPIKE8A_ITEM_EXPORT.md)); one proven `move_s` makes it adjacent.
  `examine` + `move_s` = the pickup-tail **guard** witness.
- **Closed door** — `ArcopolisTest`: the known `t_door_c` two tiles east/north-east of spawn,
  reachable by the walk Spike 10B already performed live
  ([23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md](23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md)). Examine = the
  `iexamine::none` message witness (and the explicit "examine does NOT open doors" proof).
- **Adjacent monster** — `ArcopolisNearMonsterTest`: the stationary `mon_fungal_wall` eight tiles
  south ([16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md](16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md)); a short
  proven walk makes it adjacent for the "There is a %s." message witness.
- **Furniture-with-actor and computer-console witnesses — deferred.** Enumerate candidates from a
  snapshot export at implementation time rather than over-claiming shelter contents here; if none
  is reachable, a save-edit fixture (the `make_monster_fixture.py` precedent) is the fallback.

## Future regression plan

Designed now, implemented with the spike (extending the `live_protocol_regression.ps1` pattern —
one persistent backend, request/response pairs asserted, explicit timeout so a hang is a FAIL, not
a stuck script):

- **(a) No-deadlock gate:** every `examine` request must produce its `ok:true` response + named
  post-command snapshot within a bounded read window; on expiry the harness kills the backend and
  the gate fails.
- **(b) Transcript gate:** the `command` event carries `command:"examine"`, the `direction`, and
  the resolved `action_id` — the existing transcript schema already has all three fields (no
  schema change).
- **(c) Per-target witnesses** (fixture plan above): NPC → clean no-op, world unchanged; item pile
  → examine completes with **no items taken** (pickup menu auto-cancelled by the guard); door →
  message-only, terrain unchanged.
- **(d) Recoverability, two distinct cases:** a malformed direction token → `ok:false`, session
  continues, next request succeeds; a **valid** direction at a non-interactable tile → `ok:true`
  with a faithful silent engine no-op (the valid-set filter is message-free,
  `src/action.cpp:1182`, once autoselect is pinned off).
- **(e) No-regression gate:** the existing live-protocol gates (`move`/`wait` sequence,
  `blocked_no_op,moved,waited,no_command`) re-run unchanged.
- **(f) Guard-observability gate:** the item-pile witness also asserts a guard transcript event
  naming the `"PICKUP"` context.
- **(g) Stale-slot gate:** `examine` followed by `wait` — assert no guard-serve event fires during
  the `wait` and its outcome equals the plain-wait baseline.
- **(h) Session-invariant gate:** the pinned autoselect value is recorded (session_start or
  diagnostics) so per-target witnesses are world-config-independent.
- **Frontend:** no frontend work until all backend gates pass; the frontend then only adds a
  consumer surface over the same protocol.

## Risks and open questions

Real uncertainties that remain after source reading (carried into the implementation spike).
Resolved since the first draft of this record, by further source reading: the blocked-read failure
mode (pure busy-wait hang, not a crash — see "Input requirements"), the iso direction mapping
(plain, no rotation headless — design point 3), the `handle_input` hook mechanics (public API
suffices — design point 5), the first-order actor audit, and the QUIT registration inventory
(`"DEFAULTMODE"` chooser `src/action.cpp:1085`, `"PICKUP"` `src/pickup.cpp:732`, `"LOOK"`
`src/game.cpp:9957`, `"INVENTORY"` `src/inventory_ui.cpp:1851`, `"VENDING_MACHINE"`
`src/iexamine.cpp:936` all register `QUIT`; `"STRING_INPUT"` registers `TEXT.QUIT` instead,
`src/string_input_popup.cpp:109`). What remains:

- **SDL parameter-validation assumption:** the no-crash verdict for the blocked read leans on one
  non-repo contract — SDL returning "centered" from `SDL_GetJoystickHat( nullptr, … )` rather than
  crashing (`src/sdltiles.cpp:1810-1813` probes the never-initialized `joystick` global). Repo
  code cannot decide SDL internals; documented SDL behavior says parameter-validated.
- **Second-order actor audit:** the first-order sweep is exhaustive for direct calls, but shared
  helpers can hide raw reads transitively (the liquid-handling `choose_adjacent`,
  `src/handle_liquid.cpp:226`, is a witnessed example; item-use chains are another). Each target
  class needs its full call chain audited before exposure; the guard bounds the damage of a miss
  to a logged auto-cancel.
- **`lua_examine`:** behavior depends on mod script content (`src/iexamine.cpp:8145-8147`) — not
  statically auditable from C++; treat as unaudited-by-definition.
- **Final hook placement:** design point 5 names a concrete candidate site and the API it needs,
  but the exact placement (and the stable-storage detail for the returned reference) is the
  implementation spike's to validate.
- **Guard fire-limit:** a loop that ignores the returned cancel action would spin; the proposed
  failsafe (bounded fires → hard-fail) is likely untestable deterministically in-spike — expose
  the counter in diagnostics and accept as reviewed residual risk.

## Anti-goals

Intentionally **not** done now:

- No frontend-only "inspect" substitute pretending to be examine.
- No fake examine results synthesized from snapshot data.
- No direct state mutation from the backend, bridge, or frontend.
- No `command → do_turn` shortcut (the failed Spike 3 path stays dead).
- No generic UI/menu abstraction yet (Option C deferred with reasons above).
- No broad pickup/talk/menu/computer implementation until the input model is proven.
- No reliance on `AUTOSELECT_SINGLE_VALID_TARGET` (or any interface option) for correctness.

## Citation audit

| Claim                                                                                        | Implementing line(s)                                                                                                                                    |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Seam feeds only the top-level action; first branch of the input chain                        | `src/handle_action.cpp:1778-1779`                                                                                                                       |
| `ACTION_EXAMINE` case dispatches `examine()`                                                 | `src/handle_action.cpp:2279-2287`                                                                                                                       |
| Examine prompts via `choose_adjacent_highlight`                                              | `src/game.cpp:8522-8541`                                                                                                                                |
| Valid-target predicate composition (vehicle/console/items/actor/creature/trap)               | `src/action.cpp:631-659`, `:673-701`                                                                                                                    |
| Autoselect skips the prompt at 0/1 valid targets; default `true`                             | `src/action.cpp:1163-1169`, `src/options.cpp:1709-1714`                                                                                                 |
| Filtered selection returns message-free nullopt                                              | `src/action.cpp:1181-1186`                                                                                                                              |
| `choose_direction` is an ungated raw `handle_input` loop; `pause` = self-tile                | `src/action.cpp:1078-1119`                                                                                                                              |
| `handle_input` → `get_input_event` has no `test_mode` branch; blocking SDL wait              | `src/input.cpp:925-992`, `src/sdltiles.cpp:3951-3996`                                                                                                   |
| All arcopolis modes set `test_mode`; curses never initialized headless                       | `src/main.cpp:528-580`, `:881-887`                                                                                                                      |
| `uilist`/`query_popup` auto-cancel under `test_mode`; redraw is a no-op                      | `src/ui.cpp:916-922`, `src/popup.cpp:269-271`, `src/ui_manager.cpp:325-330`                                                                             |
| NPC examine auto-cancels and returns cleanly                                                 | `src/game.cpp:8101, :8121, :8519`                                                                                                                       |
| Examine's auto-pickup tail reaches the ungated `"PICKUP"` loop                               | `src/game.cpp:8755`, `src/pickup.cpp:627, :721, :1164`                                                                                                  |
| Script & live stall backstops run **between** `do_turn` returns (can't catch a nested block) | `src/arcopolis_script.cpp:226-256`, `src/arcopolis_live.cpp:445-478`                                                                                    |
| Live command response is written at the **next** provider call                               | `src/arcopolis_live.cpp:108-124`                                                                                                                        |
| Vocabulary is `wait`/`move`-only; `direction` validated for `move` only                      | `src/arcopolis_command.cpp:102-119`, `:59-70`                                                                                                           |
| `t_door_c` has no `examine_action`; `t_door_locked` → `locked_object`                        | `data/json/furniture_and_terrain/terrain-doors.json:194-231`, `:1440-1462`                                                                              |
| `open()`/`close()` move costs; smash/grab always prompt                                      | `src/handle_action.cpp:617, :628, :761, :670`, `src/gates.cpp:361, :378-381`                                                                            |
| Chooser action ids come from `register_directions`                                           | `src/input.cpp:994-1001`                                                                                                                                |
| Blocked read cannot crash: null `stdscr` guarded; `refresh_display` test_mode-gated          | `src/cursesport.cpp:36, :186-190, :206-209`, `src/sdltiles.cpp:109, :502-509`                                                                           |
| `CheckMessages` headless: null-joystick probe + empty poll + gated refresh tail              | `src/sdltiles.cpp:1810-1813, :151, :374-386, :2903, :3218, :3614-3615`                                                                                  |
| Engine precedent: `pump_events` already test_mode-guards `CheckMessages`                     | `src/sdltiles.cpp:3936-3940`                                                                                                                            |
| `get_direction` rotates only under `iso_mode && tile_iso && use_tiles`; plain map otherwise  | `src/input.cpp:1040-1072` (`:1051`), `src/cached_options.cpp:26`, `src/cata_tiles.cpp:2220`                                                             |
| `is_action_registered`/`get_category` are existing public API                                | `src/input.h:469-478`                                                                                                                                   |
| Actor map: ~95 names, `lua:` routing, `none` fallback, JSON default                          | `src/iexamine.cpp:8143-8253`, `src/mapdata.cpp:1366-1373`                                                                                               |
| Raw-actor inventory (string-input ×7, vending loop, inventory menus ×6)                      | see "Examine-actor surface audit" table                                                                                                                 |
| QUIT registration: chooser/PICKUP/LOOK/INVENTORY/VENDING yes; STRING_INPUT → `TEXT.QUIT`     | `src/action.cpp:1085`, `src/pickup.cpp:732`, `src/game.cpp:9957`, `src/inventory_ui.cpp:1851`, `src/iexamine.cpp:936`, `src/string_input_popup.cpp:109` |
| `vehicle::interact_with` is a gated `uilist`; monexamine menus gated, rename branch raw      | `src/vehicle_use.cpp:2001, :2047, :2127`, `src/monexamine.cpp:298, :692-697`                                                                            |

## Conclusion

**Examine is feasible — but not yet.** Wiring the verb to `ACTION_EXAMINE` today would introduce
the backend's first reachable deadlock (an ungated nested direction prompt, plus a second one in
the pickup tail), invisible to every existing backstop — and proven from source to be a silent
busy-wait hang, not a crash. What must be built first is small and generic: a one-slot queued
direction answer plus an auto-cancel guard at the `input_context::handle_input` choke point, gated
on the backend session — the engine already exposes the membership/category API the guard needs,
the direction mapping is pinned (no iso rotation headless), and the first-order actor audit bounds
the raw-read surface to a known list. After that, a one-shot
`{"op":"command","command":"examine","direction":"…"}` completes faithfully against every audited
target class. The next PR is **Spike 11A — directed examine through a backend nested-input seam**,
implementing exactly that mechanism with the fixtures and regression gates designed above.
