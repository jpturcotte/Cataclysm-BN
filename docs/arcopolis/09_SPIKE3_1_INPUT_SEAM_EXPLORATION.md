# Spike 3.1 Input-Seam Exploration

> **Scope update — Spike 3.1A is now IMPLEMENTED & VALIDATED (2026-06-02).** This document began as
> exploration/design; the **M1** mechanism it recommended has since been implemented and validated — see
> [§ Spike 3.1A — implementation result](#spike-31a--implementation-result) immediately below. The
> original exploration text (from "Fidelity principle" onward) is retained **unchanged** as the design
> record. It superseded the *execution* approach of Spike 3
> ([08_SPIKE3_MOVE_COMMAND.md](08_SPIKE3_MOVE_COMMAND.md), FAILED) while keeping its reusable parts. Line
> numbers drift — trust the symbol names and re-run the PowerShell checks in the last section.

## Spike 3.1A — implementation result

**Status: ✅ implemented and validated.** The action/top-half **inversion that failed Spike 3 is gone**:
the backend is now a pure input source, the engine's `game::do_turn` runs verbatim, and each command's
`action_id` is consumed at the real `handle_action()` input seam — after the turn's top half — exactly
where a keypress is. There is no `command → do_turn` caller anywhere.

### What shipped (5 commits)

| Commit | Change |
| --- | --- |
| `feat(arcopolis): backend input source` | New `src/arcopolis_backend_input.{h,cpp}`: a TU-local session + the `next_backend_action()` provider (inline exports, returns the next `action_id`); plus `command_to_action()` (pure `wait → ACTION_PAUSE`, `move → look_up_action`) in `arcopolis_command.cpp`. Unit-tested. |
| `feat(arcopolis): consume backend action at the seam` | **Seam 1** — gated branch in `game::handle_action` (`src/handle_action.cpp`) sets `act` from the provider, mirroring the auto-move precedent. **Seam 2** — gated clean-park `return false` in `game::do_turn` (`src/game.cpp`), placed **after** the existing `is_game_over()` check, leaving `do_turn` before the bottom half (world not ticked). Both gated on `arcopolis::backend_session_active()`. |
| `refactor(arcopolis): drive the script runner through the seam` | `run_script` (`src/arcopolis_script.cpp`) pre-flights `command_to_action`, asserts `TURN_DURATION <= 0.005`, then drives `while( !backend_input_done() ) g->do_turn();` with a stall backstop + game-over handling. Old per-step `apply_command` loop removed. |
| `feat(arcopolis): drive the one-shot through the seam` | `export_current_view` (`src/arcopolis_export.cpp`) routes `--arcopolis-command` through one bootstrap `do_turn` at the seam; **`apply_command` (the inverted body) deleted**. |
| `docs(arcopolis): record Spike 3.1A result` | This section. |

> **One refinement vs the design plan, mandated by the fidelity bar:** Seam 2 is placed **after**
> `is_game_over()` (not before, as the line-level plan first said). Placing it before would let a fatal
> *final* action skip game-over processing and report success with a dead avatar. After `is_game_over()`,
> a fatal step ends the game correctly and a normal exhaustion parks — both faithful.

### Validation (game build `cataclysm-bn-tiles`, `--seed`, world `ArcopolisTest`)

| Check | Result |
| --- | --- |
| `cata_test-tiles "[arcopolis]"` | ✅ **28 cases / 113 assertions pass** (incl. the new provider/cursor + `command_to_action` unit tests). |
| **Two `move_s` + `wait`** (clean N-S corridor) | ✅ exit 0, empty stderr. `pos_abs.y`: 6421 → **6422 (+1)** → **6423 (+1)** → 6423; x,z fixed. Calendar **T, T+1, T+2, T+3** (1324801→1324804) — bootstrap then one tick per action. **Each move advances exactly 1, evaluated after each turn's top half.** |
| **Two `move_e` + `wait`** (the Spike-3 bug case) | ✅ exit 0, empty stderr. 1st `move_e`: 6301 → **6302 (+1)**; 2nd `move_e`: **blocked** by `t_wall_w` one tile east (doc 08's documented wall) — a faithful no-op, and the script **continued to the wait** (never failed). Calendar **T, T+1, T+1, T+2**: the blocked move spent no moves, so the wait shared its turn — a **multi-action turn** (two actions, world ticked once). |
| **One-shot `--arcopolis-command move_e`** | ✅ exit 0, empty stderr. `pos_abs.x` 6301 → **6302 (+1)**, calendar **T** (single bootstrap `do_turn`) — the one-shot's result is unchanged, but now executed at the seam (no inversion). |
| **One-shot `--arcopolis-command fly`** | ✅ exit **6** (`unsupported_command`) — the pre-flight resolver rejects it before driving a turn, preserving the typed exit model. |

The decisive signal that the inversion is gone: `after_move1` is observed at **T+1**, not T. The inverted
Spike 3 took that snapshot between turns at T (bootstrap); M1 takes it at the next turn's input-loop rest
**after** the top half advanced the calendar — exactly the frame a GUI player sees after one keypress.

### Citation audit of the implemented behavior (trust symbols; line numbers drift)

| Claim | Implementing symbol | Verdict |
| --- | --- | --- |
| Backend action consumed at the `handle_action` input seam, gated | `game::handle_action` first branch → `arcopolis::next_backend_action()` (`handle_action.cpp`) | ✅ |
| Clean park leaves `do_turn` before the bottom half, after game-over check | `game::do_turn` input loop → `backend_input_done()` `return false` (`game.cpp`, after `is_game_over()`) | ✅ |
| Command → `action_id`, pure (no engine mutation) | `arcopolis::command_to_action` (`arcopolis_command.cpp`) | ✅ |
| Provider performs `export` inline + returns the next `action_id`; `done` at end | `arcopolis::next_backend_action` (`arcopolis_backend_input.cpp`) | ✅ |
| Runner drives the engine's own loop; **no `command → do_turn`** | `arcopolis::run_script` (`arcopolis_script.cpp`); grep `do_turn` in `src/arcopolis_*` → none | ✅ |
| One-shot routes through one bootstrap `do_turn` at the seam | `arcopolis::export_current_view` (`arcopolis_export.cpp`) | ✅ |
| Inverted `apply_command` removed | absence (grep `apply_command` in `src/`,`tests/` → none) | ✅ |
| `TURN_DURATION <= 0.005` asserted on both driven paths | `run_script` / `export_current_view` (`get_option<float>`) | ✅ |
| Each `move` advances `pos_abs` by 1, after the top half | two-`move_s` run: y 6421→6422→6423; calendar T,T+1,T+2,T+3 | ✅ |
| Blocked move = no-op; script feeds the next command | two-`move_e` run: 2nd move bumps `t_wall_w`, wait still runs (multi-action turn) | ✅ |
| Seams inert in normal play (gated on `backend_session_active()`) | both seams behind the gate; session begun only in `run_script`/`export_current_view` | ✅ |

### Known limitations (carried forward)

- **Sleep boundary**: the input loop is skipped while the avatar sleeps (`effect_sleep`,
  `game.cpp`), so the cursor cannot advance; a script crossing a sleep span errors with
  `backend_stalled` (exit 10) rather than sleeping through. Acceptable for the move/wait spike (the
  `ArcopolisTest` avatar is awake). It is a hang backstop, not a feature.
- **Observation-point shift (intended)**: exports are now taken at the input-loop rest (post-top-half),
  the GUI's only observable resting state. So a *wait-only* script now reads `T, T+1, T+2` (each snapshot
  one tick later, at the next turn's rest) rather than Spike 2's `T, T, T+1` (which sampled
  non-GUI-observable between-turn instants). This is the faithful correction this doc predicted
  (§ "faithful observation point").
- **`game_over` (exit 11)**: avatar death while driving a script reports a distinct terminal code, not a
  malformed-input error (2–6).

## Fidelity principle (read this first — it is the whole point)

**The GUI behavior is the engine behavior is the behavior, period.** Every spike, including this one,
must reproduce *exactly* what Bright Nights does for the same action, at the same point in the turn. A
backend behavior the GUI never produces is a **bug**, not a "headless mode." If a design cannot mirror
the engine, the design is wrong and must be reworked until it can — we do **not** ship a divergent path
and call it good enough. (AGENTS.md → "Arcopolis backend fidelity (NON-NEGOTIABLE)".)

This document therefore (a) steps through **every line** of the engine's turn/input machinery, (b)
resolves the faithful observation-point ("`after_load`") timing question from that code, and (c)
documents **all three** mechanisms that can drive the engine faithfully, with their exact seams.

## Summary

The backend must be a **pure input source**: the engine's own `game::do_turn` runs unmodified, and the
*only* thing that changes is where the per-iteration action comes from. The engine — never the backend —
decides when a turn ends (the input loop exits when `u.moves <= 0`) and when the world ticks (the bottom
half, which runs only after that loop exits). A backend that feeds one action and then "ends the turn"
itself (Spike 3's `command → do_turn`) inverts the order; a backend that *fails* or *breaks to the bottom
half* when a turn isn't consumed in one action invents a non-GUI behavior. Both are rejected.

**Three mechanisms can make the engine run faithfully while the backend supplies input.** They are
documented in full below; here is the verdict:

| # | Mechanism | Seam | Faithful? | When to use |
| - | --------- | ---- | --------- | ----------- |
| **M1** | **Synchronous input-seam callback** | `get_player_input` call site (handle_action.cpp:1683) + a clean-stop at the do_turn input-loop (game.cpp:2004) | ✅ Perfectly, for a **script** (all input known up front) | **Recommended now** (Spike 3.1A). Smallest change; `do_turn` runs verbatim. |
| **M2** | **Split `do_turn`** into begin / input-iteration / end | `game::do_turn` itself (game.cpp:1846–2230) | ✅ if the decomposition stays in lockstep with the real `do_turn` | Not recommended — forks the engine's most central function; drift = divergence. |
| **M3** | **Coroutine / stackful fiber** | same as M1 (handle_action.cpp:1683), but the provider can *suspend* | ✅ Perfectly, including a **live async protocol** | The eventual answer for a real-time protocol frontend; overkill for a script. |

**M1 and M3 share the same seam**; they differ only in whether the input provider returns synchronously
(M1, scripts) or can suspend and resume (M3, live protocol). So M1 implemented now **evolves into** M3
later without moving the seam — and M2 is never needed. Backend commands are represented as engine
`action_id`s (`wait → ACTION_PAUSE`, `move_e → ACTION_MOVE_RIGHT`); the engine's own `switch( act )`
dispatches them, so no payload, delta math, or `avatar_action::move` call lives in the backend.

The line-by-line read also resolves the **observation-timing** question: the GUI's only observable
resting state is an input-loop iteration (where it redraws and blocks), so a faithful snapshot — *including
the initial one* — must be taken there. Spike 2's `export after_load` (taken before the first `do_turn`)
is a non-GUI-observable instant; M1 fixes this for free, because the backend's exports run from inside
the input loop.

## Why Spike 3 failed (the inversion, in one paragraph)

The GUI runs `while( !g->do_turn() );` ([main.cpp:930](../../src/main.cpp)). One `do_turn` is **top half →
action (at `handle_action`) → bottom half**. Spike 3's `apply_command` ran the action *first*
(`avatar_action::move`, [arcopolis_command.cpp:168](../../src/arcopolis_command.cpp)) and *then*
`g->do_turn()` ([arcopolis_command.cpp:177–178](../../src/arcopolis_command.cpp)), i.e. **action →
do_turn(top → bottom)** — the action and that turn's top half are transposed, so from the second turn on
the action is evaluated one top-half early. Loading once (Spike 2) fixed the clock, not the action
placement. Full detail in [08_SPIKE3_MOVE_COMMAND.md](08_SPIKE3_MOVE_COMMAND.md).

## Desired faithful shape

```
game::do_turn()                                   game.cpp:1846
  ├─ calendar gate                                game.cpp:1879-1884   (bootstrap / +1 turn)
  ├─ TOP HALF                                     game.cpp:1887-1974   (runs FIRST)
  ├─ INPUT LOOP  while( u.moves > 0 … )            game.cpp:1980
  │     ├─ cleanup_dead(); mon_info_update();      game.cpp:1981-1982  (threat scan, BEFORE action)
  │     └─ handle_action()                         game.cpp:2004   ←── BACKEND ACTION LANDS HERE
  └─ BOTTOM HALF                                  game.cpp:2025-2229   (world ticks, AFTER input loop)
```

The backend supplies the action consumed at `handle_action` (game.cpp:2004), once per input-loop
iteration, exactly where a keypress is consumed — after the top half and after `mon_info_update`. The
world ticks only when an action drives `u.moves <= 0` and the loop exits. Multiple actions can occur in
one turn (the loop iterates); the backend must support that, not fail on it.

---

# Line-by-line walkthrough

Everything the seam touches, read top to bottom. (Blocks irrelevant to control flow — Tracy counters,
sfx, redraw bookkeeping — are noted by range so nothing is skipped.)

## 1. The GUI turn driver — `main.cpp:914–933`

- `914  while( true ) {` — outer session loop.
- `915–919  if( !world.empty() ) { if( !g->load( world ) ) break; world.clear(); }` — headless/`--world`
  load path (what the backend uses); `game::load` runs `game::setup()` which sets `new_game = true`.
- `921–926  else { main_menu … }` — interactive menu (not the backend path).
- `928  shared_ptr_fast<ui_adaptor> ui = g->create_or_get_main_ui_adaptor();` — sets up the draw adaptor;
  **does not render a frame of game state**.
- `929  options_manager::cache_balance_options();`
- `930  while( !g->do_turn() );` — **the entire game is this loop.** `do_turn` returns `false` to keep
  going, `true` when the game ends (`cleanup_at_end`).
- `931  }` / `933  exit_handler( -999 );`

**Consequence for timing:** nothing renders game state between `load` (916) and the first `do_turn`
(930). The first observable frame happens *inside* the first `do_turn`'s input loop (see §4). So the
"state right after load, before any `do_turn`" is **never shown to a GUI player**.

## 2. `game::do_turn` — `game.cpp:1846–2230`

**Pre-turn / game-over (1846–1876):**
- `1846  bool game::do_turn()`.
- `1850  cleanup_arenas();`
- `1851–1853  if( is_game_over() ) return cleanup_at_end();` — the only place `do_turn` returns `true`.
- `1855–1860` sleep-perf flags (`asleep`, `vehperf`, `soundperf`, `monperf`, `npcperf`).
- `1861–1876` Tracy monster/NPC counters (telemetry only).

**Calendar gate (1878–1885) — the bootstrap rule:**
- `1879–1884  if( new_game ) { new_game = false; } else { gamemode->per_turn(); calendar::turn += 1_turns; }`
  First `do_turn` after load is the **bootstrap turn**: clears `new_game`, does **not** advance the clock.

**TOP HALF (1887–1974) — runs before any input:**
- `1887  swapping_dimensions = false;`
- `1892–1893  m.invalidate_lightmap_caches(); m.invalidate_visibility_caches();`
- `1897–1900  weather.clear_temp_cache();`
- `1902–1904  if( npcs_dirty ) load_npcs();`
- `1907  timed_events.process();`
- `1910  mission::process_all();`
- `1913–1918` vehicle-theft check; `1920–1922` mount spook.
- `1923–1925  if( once_every( 1_days ) ) … process_mongroups();`
- `1928–1936  if( once_every( 2.5 min ) ) … move_hordes(); move_nemesis(); m.spawn_monsters(false);`
- `1938` debug hour timer.
- `1941  u.update_body();` — **mutates avatar state** (needs, wetness, etc.).
- `1945–1949  if( AUTOSAVE && once_every(… ) && !dead ) autosave();`
- `1952–1953  weather.update_weather(); reset_light_level();` — **mutates weather + light**.
- `1957–1960` `perhaps_add_random_npc(); process_voluntary_act_interrupt(); process_activity(); update_performance_bubble();`
- `1962–1974` NPC sound pre-processing (skipped if `soundperf`).

**INPUT LOOP (1978–2023) — where actions are consumed:**
- `1978  if( !u.has_effect( effect_sleep ) || uquit == QUIT_WATCH ) {` — **if the avatar is asleep, the
  whole input loop is skipped** (turns auto-process until waking). Relevant edge case for the backend.
- `1979  if( u.moves > 0 || uquit == QUIT_WATCH ) {`
- `1980  while( u.moves > 0 || uquit == QUIT_WATCH ) {` — **the input loop.** Iterates while the avatar
  has moves (multi-action turns are normal). For a live backend avatar `uquit` is not `QUIT_WATCH`, so the
  condition is effectively `u.moves > 0`.
- `1981  cleanup_dead();`
- `1982  mon_info_update();` — **per-iteration threat scan**, runs *before* the action; this is why a
  safe-mode gate inside `handle_action` is faithful (threats already assessed this iteration).
- `1984–1991` per-iteration NPC sound markers (if `!soundperf`).
- `1992–1995  if( !u.activity && !u.has_distant_destination() && uquit != QUIT_WATCH && wait_popup ) { wait_popup.reset(); ui_manager::redraw(); }`
  — gated; inert headless (no `wait_popup`).
- `1997–2002  if( queue_screenshot ) { … }` — gated; inert headless.
- `2004  if( handle_action() ) { ++moves_since_last_save; }` — **THE ACTION SEAM.** `handle_action`
  returns `!u.is_dead_state()` (see §3), so this counts a survived action toward autosave.
- `2008–2010  if( is_game_over() ) return cleanup_at_end();` — death mid-loop ends the turn (and game).
- `2012–2014  if( uquit == QUIT_WATCH ) break;`
- `2015–2017  if( u.activity ) process_activity();`
- `2018  }` end while; `2021  sounds::reset_markers();`

**BOTTOM HALF (2025–2229) — the world ticks here, only after the loop exits:**
- `2025–2032` driving view offset; `2035–2042` scent; `2046` `m.build_floor_caches();`
- `2049–2053  if( !vehperf ) { m.process_falling(); autopilot_vehicles(); m.vehmove(); }`
- `2056  m.process_items();` `2059  m.creature_in_field( u );` `2062–2067` grid trackers.
- `2069–2071` portal links; `2074` `fluid_grid::update();`; `2079  sounds::process_sounds();`
- `2084  m.build_map_cache(…);`
- `2087  if( !monperf ) monmove();` — **monsters act.**
- `2090–2093  if( !npcperf ) npcmove(); else sleep_skip_npc_process();` — **NPCs act.**
- `2094–2096  if( once_every(5 min) ) overmap_npc_move();` `2098  update_stair_monsters();`
- `2099  mon_info_update();`
- `2102  u.process_turn();` — **refills the avatar's moves** (`moves += get_speed()` via
  `Creature::process_turn`); this is why `avatar.moves` exported *after* `do_turn` is the refilled value.
- `2107` Lua `on_every_x` hooks; `2111` explosions; `2114  cleanup_dead();`
- `2117–2120` FORCE_REDRAW (inert headless); `2122–2124` weather effects.
- `2126–2170` sleep / travel / activity wait-redraw (inert headless: `add_msg`/redraw gated).
- `2172–2176` bodytemp/wetness/morale; `2178–2186` sfx (inert headless).
- `2189  u.volume = 0;`
- `2192  world_tick();` — **submap-level world processing (fields, batched items/vehicles).**
- `2199–2214` submap loader + grid-tracker cleanup; `2218  Pathfinding::clear_d_maps();`
- `2225–2227  if( !u.activity && !u.has_destination() ) inp_mngr.pump_events();` — drains OS input
  (no-op headless: `pump_events` early-returns in `test_mode`).
- `2229  return false;`

**Conclusion:** `do_turn` returns `true` **only** via `cleanup_at_end` (1852 or 2009); otherwise `false`
at 2229 after a full top→loop→bottom pass. There is **no** path that returns mid-loop with the world
unticked — so any mechanism that needs to "park mid-turn" must either avoid being inside `do_turn`
(M2), add such a return at 2004 (M1's clean-stop), or suspend the stack (M3).

## 3. `game::handle_action` — `handle_action.cpp:1663–2874`

**Locals (1665–1668):** `std::string action; input_context ctxt; action_id act = ACTION_NULL; user_turn
current_turn;` — `current_turn` starts a wall-clock timer at entry (see §5).

**Input acquisition — the three sources (1669–1684):**
- `1670–1676  if( u.has_destination() ) { act = u.get_next_auto_move_direction(); if( act == ACTION_NULL ) { … clear_destination(); return false; } }`
  — **the auto-move queue: the engine's existing precedent for a non-interactive queued `action_id`
  source.** It sets `act` from a stored route and lets the rest of the function dispatch it.
- `1677–1680  else if( u.has_destination_activity() ) { u.start_destination_activity(); return false; }`
- `1681–1684  else { ctxt = get_player_input( action ); }` — **the blocking interactive path** (§4).

**`act` resolution (1686–1817):**
- `1686–1697` vehicle locals + `mouse_target`.
- `1699–1702  if( uquit == QUIT_WATCH && action == "QUIT" ) { uquit = QUIT_DIED; return false; }`
- `1704–1799  if( act == ACTION_NULL ) { act = look_up_action( action ); … menus (main/action/keybindings) … mouse SELECT/SEC_SELECT … else clear_destination(); }`
  — **skipped entirely when `act` is already non-null** (auto-move and, by extension, the backend seam).
- `1801–1817  if( act == ACTION_NULL ) { … "Unknown command" via raw input; return false; }` — also
  skipped when `act` is set; with a default `ctxt` the raw input is empty, so this would `return false`
  silently (relevant to why an empty backend provider must **not** route through here — see M1).
- `1820  gamemode->pre_action( act );` (DEFAULTMODE: no-op).
- `1822  int soffset = …;` `1824  int before_action_moves = u.moves;`

**Dispatch — two switches (1827–2864):**
- `1827  if( uquit == QUIT_WATCH || !u.is_dead_state() ) { switch( act ) { … } }` — **deathcam-allowed
  actions** (1828–1871): `ACTION_TOGGLE_MAP_MEMORY`, `ACTION_CENTER`, `ACTION_SHIFT_N…NW`, `ACTION_LOOK`,
  `ACTION_KEYBINDINGS`, `default: break`. View/UI only; no turn effect.
- `1875  if( !u.is_dead_state() ) { switch( act ) { … } }` — **alive-only actions** (1876–2863). The ones
  that matter for the backend:
  - `1885–1889  case ACTION_TIMEOUT: if( check_safe_mode_allowed( false ) ) do_pause( u ); break;`
  - `1891–1895  case ACTION_PAUSE: if( check_safe_mode_allowed() ) character_funcs::do_pause( u ); break;`
    — **this is `wait`.** `do_pause` zeroes moves (§ run model). Payload-free; driven only by `act`.
  - `1917–1962  case ACTION_MOVE_FORTH … ACTION_MOVE_FORTH_LEFT:` — the 8 horizontal moves. Normal branch
    (1933–1960): `auto dest_delta = get_delta_from_movement_action( act, iso_rotate::yes ); … if( !avatar_action::move( u, m, dest_delta ) ) u.clear_destination();`
    — **this is `move`.** The delta is computed *from `act`*; payload-free. (`iso_rotate::yes` ≡ `::no`
    headless: iso rotates only under `use_tiles && tile_iso`.)
  - `1963–2016  case ACTION_MOVE_DOWN:` and `2018–2091  case ACTION_MOVE_UP:` — vertical moves
    (`vertical_move`/`pldrive`); **out of scope.**
  - `2093–2862` — ~120 more cases: `OPEN/CLOSE/SMASH/EXAMINE`, inventory/craft/read/wield/fire, info
    screens, toggles, debug. Each is `case ACTION_X: <handler>(); break;`. **Having read all of them:**
    none advance `calendar::turn`, none run the bottom half, none call `do_turn`. A handful set
    terminal/loop state explicitly — `ACTION_SUICIDE` (2539: `u.moves = 0; uquit = QUIT_SUICIDE`),
    `ACTION_SAVE` (2550: `u.moves = 0; uquit = QUIT_SAVED`), `ACTION_QUICKSAVE`/`ACTION_QUICKLOAD`
    (2561/2565: `return false`). The backend never queues any of these, so they're unreachable in backend
    mode — but it confirms the engine's "end the turn" levers are exactly *spend moves* or *set uquit*.

**Move-charge tail + return (2865–2873):**
- `2865–2867  if( act != ACTION_TIMEOUT ) { u.mod_moves( -current_turn.moves_elapsed() ); }` — charges
  **real wall-clock** elapsed against moves (see §5: **0 unless `TURN_DURATION > 0.005`**).
- `2868  gamemode->post_action( act );` (no-op DEFAULTMODE).
- `2870  u.movecounter = !dead ? before_action_moves - u.moves : 0;`
- `2873  return ( !u.is_dead_state() );` — **the return is "avatar is alive," not "an action
  happened."** Early `return false`s above are the cancel/no-op exits.

## 4. `get_player_input` — `handle_action.cpp:258–408` (the blocking, redrawing path)

- `258–286` builds the `input_context` (deathcam-restricted vs `get_default_mode_input_context()`).
- `288` `user_turn current_turn;` (separate from handle_action's).
- `294–315` decides whether to animate.
- `317–405` the wait-for-input body: it **redraws** (`ui_manager::redraw_invalidated()`, lines 389 and
  395) and then **blocks** on input via `handle_mouseview(ctxt, action)` with a 125 ms timeout loop
  (which calls `ctxt.handle_input()` → "internally calls getch()", [input.h:620–631](../../src/input.h)).
- `407  return ctxt;`

**This is the GUI's resting/observable point:** the player sees the rendered frame here and the engine
waits. Headless this must never be reached (no input device; it would block). The backend replaces this
call.

## 5. `user_turn` / `moves_elapsed` — `handle_action.cpp:151–181` (a fidelity guard)

- `157–159` starts a `steady_clock` timer at construction (handle_action entry, 1668).
- `165–179  int moves_elapsed()`: reads option `TURN_DURATION`; **`if( turn_duration <= 0.005 ) return 0;`**
  (line 172) — the default. Otherwise returns wall-clock-ms `/ (10 * TURN_DURATION)`.

**Implication:** with default options, handle_action.cpp:2866 subtracts **0** — the time spent acquiring
the action does not affect `u.moves`. **But if `TURN_DURATION > 0.005`** (the "real-time turns" option),
the wall-clock spent *inside the backend provider — including export file I/O —* would be charged against
`u.moves`, which is non-deterministic and unfaithful. **The backend session must assert/force
`TURN_DURATION <= 0.005`.**

---

# The faithful observation point, and the `after_load` timing question

**Question:** is Spike 2's `export after_load` (taken right after `g->load`, before any `do_turn`) a
faithful snapshot?

**Answer (from the code): no — it is a non-GUI-observable instant.** The GUI never renders between `load`
(main.cpp:916) and the first `do_turn` (main.cpp:930); the first frame a player sees is rendered inside
the bootstrap `do_turn`'s input loop, at `get_player_input` (handle_action.cpp:388/395), which is reached
only **after**:

- the bootstrap calendar gate (game.cpp:1879–1884),
- the **entire top half** (game.cpp:1887–1974) — including `u.update_body()` (1941),
  `weather.update_weather()` + `reset_light_level()` (1952–1953), `timed_events.process()` (1907),
  `mission::process_all()` (1910), and possibly `load_npcs()` (1903), and
- the per-iteration `cleanup_dead()` + `mon_info_update()` (game.cpp:1981–1982).

Those mutate avatar body state, weather, light level, and visible-monster info. So the raw post-load
state differs from the first observable frame by all of that processing. **The faithful "initial"
snapshot is the bootstrap turn's first input-loop iteration (post-top-half), not the pre-`do_turn`
state.**

**M1 fixes this for free:** because the backend's exports are performed by the input provider *from
inside the input loop* (at the `get_player_input` seam), an `export` that appears before the first
`command` in the script is taken at exactly that faithful point. No special "before the first turn"
export path is needed — and Spike 2's subtly-early `after_load` timing is corrected as a side effect.
(General rule the walkthrough establishes: **every faithful snapshot is taken at an input-loop
iteration**, never "between turns," because "between turns" is not a state the GUI ever rests in — it
flows straight from one turn's bottom half into the next turn's top half and stops only at the next input
loop.)

---

# Existing input/action architecture

- **`action_id` is the currency.** `look_up_action(ident)` maps engine idents (`"move_e" →
  ACTION_MOVE_RIGHT`; `ACTION_NULL` on miss) — already used by Spike 3
  ([arcopolis_command.cpp:162](../../src/arcopolis_command.cpp)). Movement and pause are *fully*
  determined by `act` (handle_action.cpp:1891, 1934/1957).
- **The auto-move queue is the precedent** for a non-interactive `action_id` source feeding
  `handle_action` (handle_action.cpp:1670–1671; declared [character.h:2281,2287](../../src/character.h)).
- **No other queue/macro/replay/autoplay exists.** A `src/` search for
  macro/replay/autoplay/action_queue/input_queue/playback returns only Lua-interpreter internals and
  unrelated preprocessor macros; `input_context`'s "next action in the queue"
  ([input.h:620](../../src/input.h)) is the OS key-event buffer, not a command queue.

# Candidate injection seams (where to inject — A–E)

This is the *placement* analysis (the *how-to-drive* analysis is the three mechanisms below).

| Option | What | Verdict |
| --- | --- | --- |
| **A — dispatch at the `handle_action()` call site** (game.cpp:2004) | Re-run `avatar_action::move`/`do_pause` in `do_turn` instead of calling `handle_action`. | ❌ for dispatch (duplicates the switch, drifts). ✅ only as the *location* of M1's clean-stop. |
| **B — extract `consume_player_action()`** wrapping the input acquisition | Refactor `handle_action`'s 1669–1684 into an overridable function. | ❌ churns the hottest input function for no gain over C. |
| **C — backend input source at the acquisition point** (handle_action.cpp:1669/1683) | A gated branch that sets `act` from the backend, mirroring auto-move. | ✅ **the seam M1 and M3 both use.** |
| **D — split `do_turn`** | Carve top/iteration/bottom. | = **M2**; faithful but forks the central function. |
| **E — keep `command → do_turn`** | Spike 3's shape. | ❌ the inversion that failed. |

---

# The three faithful mechanisms (the core deliverable)

All three keep the engine authoritative over turn-end and world-tick. They differ in *how* the runner
regains control between actions so it can export and feed the next command without the world ticking
prematurely.

## Mechanism M1 — synchronous input-seam callback (recommended for the script model)

**Idea.** Replace the blocking `get_player_input` with a backend provider that synchronously returns the
next `action_id`, performing any `export` steps inline at that point. The engine's `do_turn` runs
verbatim.

**Seam (two gated touches, both behind `arcopolis::backend_session_active()`):**

1. **Acquisition — handle_action.cpp:~1683.** Add a branch to the 1669–1684 chain:
   ```cpp
   // PSEUDOCODE — not implemented by this exploration.
   if( arcopolis::backend_session_active() ) {
       act = arcopolis::next_backend_action();   // performs inline `export` steps, returns the next
                                                 // command's action_id, or ACTION_NULL if the script is done
   } else if( u.has_destination() ) { act = u.get_next_auto_move_direction(); … }   // existing
   else if( u.has_destination_activity() ) { … }                                    // existing
   else { ctxt = get_player_input( action ); }                                      // existing (blocking)
   ```
   A non-null `act` skips the 1704 and 1801 `ACTION_NULL` blocks and flows to the switch — exactly as
   auto-move does. The action runs through the engine's real `ACTION_PAUSE`/`ACTION_MOVE_*` leaves,
   including their internal `check_safe_mode_allowed()`, after the top half and after `mon_info_update`.

2. **Clean-stop — game.cpp:2004 (the input-loop body, before `handle_action`).** When the script is
   exhausted while `u.moves > 0`, the turn must end the way a player who *stops giving input* ends it:
   the world is **not** ticked. Since `do_turn` has no mid-loop return that skips the bottom half, add
   one — as a **clean stop, not an error, not a fake `do_pause`:**
   ```cpp
   // PSEUDOCODE — not implemented by this exploration.
   while( u.moves > 0 || uquit == QUIT_WATCH ) {
       ...
       if( arcopolis::backend_session_active() && arcopolis::backend_input_done() ) {
           return false;   // leave do_turn BEFORE the bottom half (2025+). Faithful "player walked away
                           // mid-turn": world not ticked, avatar keeps its moves. NOT `break`, NOT do_pause.
       }
       if( handle_action() ) { ++moves_since_last_save; }
       ...
   }
   ```

**Control-flow trace (fast avatar, 250 moves, script `export, move_e, export, move_e, export, wait,
export`):**
- Runner: `begin_backend_session(script)`, then `while( !g->do_turn() ) { if( backend_input_done() ) break; }`.
- `do_turn` #1 (bootstrap): top half. Input loop iter 1 → `handle_action` → provider: does `export #1`
  inline (faithful post-top-half "after_load"), returns `ACTION_MOVE_RIGHT`; dispatch → moves 250→150.
- iter 2 → provider: `export #2` inline (avatar +1 E, **world not ticked**), returns `ACTION_MOVE_RIGHT`;
  moves 150→50.
- iter 3 → provider: `export #3` inline (avatar +2 E, world not ticked), returns `ACTION_PAUSE`;
  `do_pause` → moves 50→0. Loop condition false → exit → **bottom half runs (world ticks once)** → bootstrap
  turn complete, calendar stays T → `do_turn` returns false.
- Runner: `do_turn` #2: top half (calendar → T+1). iter 1 → provider: `export #4` inline (post-T+1-top-half),
  script now exhausted → returns "done." Wait — `export #4` was the last step, so after it the provider has
  no command and `backend_input_done()` is true; the clean-stop at game.cpp:2004 returns before the bottom
  half. Turn T+1 is left parked (faithful: the snapshot shows the start of T+1's input phase, world not yet
  ticked for T+1). Runner's `while` sees `backend_input_done()` → stops.

This is the GUI's exact behavior: three actions in the bootstrap turn (because the avatar had the moves),
mid-turn exports showing the frozen-world states the GUI would render between keypresses, world ticking
once at turn end. **No fail, no fake, no early world tick, no `do_turn` split.**

- **Fidelity:** ✅ perfect for the script model (`do_turn` runs verbatim; the only change is the input
  source and one clean-stop return).
- **Risk:** low–medium. Touches a hot function (handle_action) and adds one gated return to `do_turn`;
  both inert unless `backend_session_active()`. Must verify a normal `--world` GUI run is byte-identical.
- **Size:** smallest of the three.
- **Normal gameplay:** unchanged (gated off).

## Mechanism M2 — split `do_turn` (option D)

**Idea.** Factor `do_turn` so the runner drives the phases explicitly:
- `do_turn_begin()` ≈ game.cpp:1846–1974 (game-over check, calendar gate, top half),
- `do_turn_input_iteration()` ≈ game.cpp:1981–2017 (cleanup_dead, mon_info_update, sounds, the
  `handle_action` equivalent, mid-loop game-over check, activity),
- `do_turn_end()` ≈ game.cpp:2025–2229 (bottom half),
- `is_turn_input_pending()` ≈ the loop condition game.cpp:1980.

The normal `do_turn` is recomposed as `begin(); while(pending()) iteration(); end();` so the GUI is
unchanged. The runner does:
```
do_turn_begin();
while( is_turn_input_pending() ) {
    // export here (faithful), per script
    if( no more commands ) return;   // park: do NOT call do_turn_end() → world not ticked
    queue_action(next); do_turn_input_iteration();
}
do_turn_end();   // only when the turn actually completed (moves <= 0)
```

- **Fidelity:** ✅ *if* the decomposition mirrors `do_turn` exactly — including the mid-loop early-returns
  (game.cpp:2008 game-over, 2012 QUIT_WATCH) and ordering.
- **Risk:** **high.** Forks the engine's most central function; every future change to `do_turn` must be
  mirrored in the split or the backend silently diverges — which contradicts "perfectly mirror." The
  mid-loop `return cleanup_at_end()` (2009) is awkward to express across the split.
- **Size:** large.
- **Normal gameplay:** must be preserved exactly by the recomposed `do_turn`.
- **Verdict:** not recommended; M1 achieves the same fidelity without forking `do_turn`. (The task's "do
  not split `do_turn` unless no smaller safe seam exists" applies — M1 is the smaller safe seam.)

## Mechanism M3 — coroutine / stackful fiber (the live-protocol answer)

**Idea.** Run `do_turn` on a stackful fiber. The provider at handle_action.cpp:1683, when no command is
available *yet* (a live frontend that sends commands over time), **suspends the fiber** — preserving the
whole `do_turn` stack (top-half-done, mid-loop, world frozen) exactly as the GUI's `getch` block
preserves it. The runner regains control, reads the next protocol message, pushes the command, and
**resumes** the fiber; the provider returns the `action_id` and dispatch continues. When an action
exhausts moves, the loop exits, the bottom half runs on the fiber, `do_turn` returns.

- **Fidelity:** ✅ highest — `do_turn` and its exact interleaving run completely unmodified; suspension is
  semantically identical to the GUI blocking on input.
- **Risk:** **high infrastructure.** C++ stackful suspension across an ordinary deep call stack needs a
  fiber library (boost.context / `ucontext` / Windows Fibers) — a new dependency — plus care with
  RAII/exceptions across yields, on a hot path. (C++20 coroutines don't suspend a normal call stack;
  they'd require rewriting `do_turn` as a coroutine, which is worse than M2.)
- **Size:** small seam, heavy runtime.
- **When:** required only for a **live asynchronous protocol** frontend, where the backend genuinely must
  park mid-turn waiting on the network. The script model never needs it (all input is known, so M1's
  synchronous provider suffices).
- **Continuity:** M3 uses the **same seam as M1** (handle_action.cpp:1683). Implement M1 now; when a live
  protocol arrives, swap the synchronous provider for a suspending one at the same location. **M2 is never
  needed.**

---

# Proposed backend command representation

Queue an engine **`action_id`** (the auto-move precedent's currency; payload-free for the in-scope set):

| backend command | `action_id` | engine leaf |
| --- | --- | --- |
| `wait` | `ACTION_PAUSE` | `check_safe_mode_allowed()` + `do_pause(u)` — handle_action.cpp:1891–1895 |
| `move` + `move_n/s/e/w` | `ACTION_MOVE_FORTH/BACK/RIGHT/LEFT` (via `look_up_action`) | `get_delta_from_movement_action(act,…)` + `avatar_action::move` — handle_action.cpp:1934/1957 |

The backend does **no** delta math and makes **no** `avatar_action::move`/`do_pause` call itself — the
engine's switch does, from `act`. A future payload (e.g. a target tile) promotes the queue element to
`struct { action_id act; /* payload */ }`; out of scope now.

# Proposed script-runner lifecycle (M1)

`run_script` ([arcopolis_script.cpp:118](../../src/arcopolis_script.cpp)) keeps validate → `g->load`
once, and changes to drive the engine's own loop with the backend as input source:

1. After load succeeds: assert `TURN_DURATION <= 0.005` (§5), then `arcopolis::begin_backend_session(steps)`.
2. `while( !g->do_turn() ) { if( arcopolis::backend_input_done() ) break; }` — the engine drives turns;
   the provider (handle_action seam) consumes `command` steps as `action_id`s and performs `export` steps
   inline at the faithful input-loop point; the world ticks only when an action exhausts the turn.
3. `arcopolis::end_backend_session();` and return 0 (or a typed error if `do_turn` returned `true` =
   game over).

- **Multi-action turns are faithful** (the provider feeds successive commands into one turn until moves
  are spent). **Blocked moves stay open** (spend no moves → loop continues → next command). **`wait`
  ends the turn** (`do_pause` zeroes moves). **Script ends mid-turn → clean park** (world not ticked).
- **Exports are taken at input-loop iterations** — the GUI's resting points — including the initial one
  (fixing the Spike 2 `after_load` timing). There is **no** `backend_input_exhausted_mid_turn` failure
  and **no** "must exhaust moves" precondition; those were the rejected compromises.

# Reuse from failed Spike 3

**Reuse:** direction vocabulary + `is_supported_move_direction`
([arcopolis_command.cpp:28](../../src/arcopolis_command.cpp)); `look_up_action` → `action_id`; the
schema/parser (`direction` field, cardinal validation, `bad_schema`/`unsupported_command`) and its Catch2
tests; the additive `avatar.moves` snapshot field; "judge a move by `pos_abs` delta, not the `move()`
bool."

**Supersede / remove:** `apply_command`'s `move` body (the `avatar_action::move` + `if(moves<=0) do_turn`
inversion, [arcopolis_command.cpp:168,177–178](../../src/arcopolis_command.cpp)) and `wait` body's
pre-checked gate + `do_pause` + `do_turn` ([arcopolis_command.cpp:130–140](../../src/arcopolis_command.cpp)).
Both collapse to "resolve command → `action_id`," queued at the seam; the safe-mode gate runs inside the
engine (after `mon_info_update`, closing the Spike-1 timing gap).

# Treating the merged Spike 3 code (revert vs supersede)

**Supersede in place; do NOT `git revert` PR #10.** A revert would also delete the reusable
vocab/parser/`avatar.moves`/error-model and the evidence (docs 07/08). The unfaithful part is only the
`apply_command` execution shape, which Spike 3.1A rewrites in place.

```powershell
# Inspect what PR #10 changed (reference only — this exploration executes no revert):
git log --oneline --grep "Spike 3" --grep "#10" --all-match -i
git show --stat eb4a4e1278
git diff eb4a4e1278~1 eb4a4e1278 -- src/arcopolis_command.cpp src/arcopolis_script.cpp
# A clean revert, if ever wanted, should be a NEW commit that re-restores the reusable parts + docs 07/08.
```

# Risks and unknowns

- **`TURN_DURATION` / real-time moves (verified).** handle_action.cpp:2866 charges
  `current_turn.moves_elapsed()` against `u.moves`; that is 0 only while `TURN_DURATION <= 0.005`
  (handle_action.cpp:172). The backend **must** assert/force the default, or time spent in the provider
  (including export I/O) drains moves non-deterministically.
- **Asleep avatar (verified).** The input loop is skipped entirely if `u.has_effect( effect_sleep )`
  (game.cpp:1978); a queued command would not be consumed while the avatar sleeps (turns auto-process).
  Faithful (you can't act while asleep), but the runner must handle "command not consumed because asleep"
  rather than assume every `do_turn` consumes one.
- **`backend_session_active()` gating is load-bearing.** If ever true in normal play, GUI input breaks.
  Single owner: set after `g->load`, clear before exit.
- **`handle_action` is a hot, central function.** Keep the seam branch first and minimal (structurally
  identical to the adjacent auto-move branch); build the GUI target and confirm no normal-input
  regression.
- **`do_turn` clean-stop return (M1).** Adding a gated `return false` at game.cpp:2004 must be proven to
  leave a valid parked state and to be unreachable in normal play (gated).
- **Game-over.** `do_turn` returns `true` via `cleanup_at_end` (game.cpp:1852/2009); the runner stops on
  it with a typed result.
- **Determinism.** RNG seeds from `time()` unless `--seed` is passed.

# Proposed Spike 3.1A implementation plan (M1; small commits)

> Follow-up task; not done here.

1. `feat(arcopolis): backend input source` — new `src/arcopolis_backend_input.{h,cpp}`: session flag +
   the script/step cursor + `begin/end_backend_session`, `next_backend_action` (does inline exports,
   returns the next `action_id`), `backend_input_done`, `backend_session_active`. Unit-test the cursor.
2. `feat(arcopolis): consume backend action at the handle_action seam` — gated branch at
   handle_action.cpp:~1683 + the gated clean-stop `return` at game.cpp:2004. Assert no GUI change.
3. `refactor(arcopolis): drive wait through the seam` — `wait → ACTION_PAUSE`; remove `apply_command`'s
   `do_pause`+`do_turn`. Re-prove `T → T → T+1`.
4. `feat(arcopolis): drive move_e through the seam (supersede Spike 3)` — `move → ACTION_MOVE_*`; delete
   the inverted `move` body. **Prove the inversion is gone with a *two-move* script** (the case that
   exposed the bug) and a **multi-action-in-one-turn** check on a higher-speed avatar (two moves consumed
   before any bottom half), with mid-turn exports showing the frozen world.
5. `docs(arcopolis): mark Spike 3.1A result` — outcome + citation audit.
6. Assert `TURN_DURATION <= 0.005` at session start (§5).

Out of scope: diagonals, vertical, pathfinding, interaction, multi-tile, live async protocol (→ M3),
any socket surface.

# Validation (for the eventual Spike 3.1A task)

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "move_e" },
  { "op": "export",  "name": "after_move1" },
  { "op": "command", "command": "move", "direction": "move_e" },
  { "op": "export",  "name": "after_move2" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\script_two_move.json
$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--seed','arco-3v1',
    '--arcopolis-run-script','.\out\script_two_move.json',
    '--arcopolis-export-dir','.\out\arcopolis_3v1',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt
"exit=$($p.ExitCode)"; Get-Content C:\tmp\err.txt
```

Expect each `move_e` to advance `pos_abs.x` by 1 with the action evaluated *after* each turn's top half
(no transposition), the calendar to follow bootstrap-then-normal, and — on a higher-speed avatar — both
moves to land in one turn with the world ticking only once.

# PowerShell local checks

```powershell
# The GUI turn driver + every do_turn phase boundary
Select-String -Path .\src\main.cpp -Pattern 'while\( !g->do_turn'
Select-String -Path .\src\game.cpp -Pattern 'bool game::do_turn|if\( new_game|calendar::turn \+=|while\( u\.moves > 0|effect_sleep|mon_info_update\(\)|handle_action\(\)|is_game_over|u\.process_turn|world_tick'

# handle_action: the 3 input sources, the act-driven switch leaves, the move-charge tail + return
Select-String -Path .\src\handle_action.cpp -Pattern 'bool game::handle_action|has_destination\(\)|get_next_auto_move_direction|get_player_input|act == ACTION_NULL|case ACTION_PAUSE|case ACTION_MOVE_RIGHT|avatar_action::move|moves_elapsed|return \( !u.is_dead_state'

# get_player_input: the blocking + redraw path; user_turn::moves_elapsed + TURN_DURATION guard
Select-String -Path .\src\handle_action.cpp -Pattern 'input_context game::get_player_input|redraw_invalidated|handle_mouseview|class user_turn|TURN_DURATION'

# The auto-move precedent (declarations)
Select-String -Path .\src\character.h -Pattern 'has_destination|get_next_auto_move_direction'

# The failed Spike 3 execution path to supersede
Select-String -Path .\src\arcopolis_command.cpp -Pattern 'cmd.command == "move"|avatar_action::move|get_avatar\(\).moves <= 0|g->do_turn'

# Confirm no other queued-action/macro/replay/autoplay (absence)
Select-String -Path .\src -Recurse -Pattern 'action_queue|queued_action|input_queue|autoplay|\breplay\b' |
  Where-Object { $_.Path -notmatch '\\(lua|sol)\\' }
```

# Citation audit (load-bearing claims)

| Claim | Type | Citation | Verdict |
| --- | --- | --- | --- |
| GUI drives the game as `while(!do_turn())` | behavioral | main.cpp:930 | ✅ |
| Nothing renders game state between `load` and the first `do_turn` | behavioral | main.cpp:916–930 (only `create_or_get_main_ui_adaptor`/`cache_balance_options` between) | ✅ |
| Bootstrap gate skips `calendar::turn += 1` | behavioral | game.cpp:1879–1884 | ✅ |
| Top half (update_body/weather/missions/timed_events) runs before the input loop | behavioral | game.cpp:1907,1910,1941,1952 | ✅ |
| Input loop is multi-iteration `while( u.moves > 0 …)` | structural | game.cpp:1980 | ✅ |
| Input loop is **skipped** while asleep | behavioral | game.cpp:1978 | ✅ |
| `mon_info_update()` runs in-loop before the action | behavioral | game.cpp:1982 | ✅ |
| Action consumed at `handle_action()` in-loop, after top half | behavioral | game.cpp:2004 | ✅ |
| Bottom half (monmove/process_turn/world_tick) runs only after the loop | behavioral | game.cpp:2087,2102,2192 | ✅ |
| `do_turn` returns true only via `cleanup_at_end`; else false at end | behavioral | game.cpp:1852,2009,2229 | ✅ |
| `handle_action` acquires `act` from auto-move / dest-activity / `get_player_input` | behavioral | handle_action.cpp:1670–1684 | ✅ |
| A non-null `act` skips the ACTION_NULL/menu/unknown blocks | behavioral | handle_action.cpp:1704,1801 | ✅ |
| `get_player_input` redraws then blocks on input | behavioral | handle_action.cpp:388/395 + input.h:620–631 | ✅ |
| `ACTION_PAUSE` = gate + `do_pause`, payload-free | behavioral | handle_action.cpp:1891–1895 | ✅ |
| `ACTION_MOVE_*` = delta-from-`act` + `avatar_action::move`, payload-free | behavioral | handle_action.cpp:1934/1957 | ✅ |
| No alive-only case advances calendar / ticks world / calls do_turn (read all 1876–2862) | behavioral | handle_action.cpp:1876–2862 (turn-enders only spend moves or set `uquit`: 2543,2553,2561,2565) | ✅ |
| `handle_action` returns `!u.is_dead_state()` (not "did an action") | behavioral | handle_action.cpp:2873 | ✅ |
| `moves_elapsed()` is 0 unless `TURN_DURATION > 0.005`; charged at 2866 | behavioral | handle_action.cpp:165–179 (return-0 at 172) + 2866 | ✅ |
| `do_pause` zeroes moves (wait ends the turn) | behavioral | character_turn.cpp:1084 | ✅ |
| `move` subtracts a variable `run_cost` (may not end the turn) | behavioral | game.cpp:11726 | ✅ |
| auto-move API declared (the queued-action precedent) | structural | character.h:2281,2287 | ✅ |
| Spike 3 inversion: action before `do_turn` | behavioral | arcopolis_command.cpp:168,177–178 | ✅ |
| No other player-action queue/macro/replay/autoplay | absence | `src/` grep → only auto-move + OS key buffer (input.h:620) | ✅ |
