# Arcopolis Spike 21 — fail-loud for unarmed UILIST prompts; reclassify move-into-NPC honestly

**Status: narrow fail-loud implementation (2026-06-20).** The deliberate follow-up named in Spike 20
([42_SPIKE20_UNEXPECTED_PROMPT_FAIL_LOUD.md](42_SPIKE20_UNEXPECTED_PROMPT_FAIL_LOUD.md) §6): during an
active Arcopolis session, an UNARMED player-visible `uilist` reached under `test_mode` no longer silently
returns `UILIST_ERROR` — it **fails loud** (`unexpected_prompt`), reusing the Spike 20 channel. This
deliberately changes a previously tolerated baseline: `move_n` into the shelter NPC Edwardo was witnessed
as `blocked_no_op`; it is now `unexpected_prompt`. NO new prompt support, NO NPC menu, NO generic uilist,
NO new error kind, NO curses window or render primitive.

> **Equivalence level proved: NONE changed.** This is an architecture/honesty spike, not a capability
> spike. The witnessed level-4 paths (PICKUP / UILIST 13B/14 / query_popup 15) stay exactly level 4; this
> spike only converts a SILENT uilist auto-cancel into a LOUD failure for the unarmed case. Terminology
> (backend-input vs engine vs frontend equivalence) is the three senses in
> [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md) §Terminology and `AGENTS.md:83-120`.

> **Citations** are current-tree at write time and drift; **confirm by symbol name.**

## 1. Problem statement

Spike 20 closed the silent-`query_popup` hole but **deliberately left the `uilist` family alone**, because
guarding it flips the witnessed move-into-NPC `blocked_no_op` baseline (Spike 20 §6). That baseline was the
hole: under Arcopolis, `move_n` into Edwardo runs `avatar_action::move` → bump → `game::npc_menu` →
`uilist::query` → the `test_mode` abort → `UILIST_ERROR` (silent) → no move, 0 AP, clean-park. The client
harness/docs called this `blocked_no_op` — but it is **not** a faithful blocked movement, it is a **hidden
player-visible menu cancellation** (the NPC interaction menu a GUI player would see, silently ESC'd). A
real external GUI would expose an NPC menu or report the interaction unsupported. Treating it as
`blocked_no_op` overclaims equivalence — exactly the `AGENTS.md:122-128` failure mode ("silently
auto-cancel unsupported prompts while claiming success").

## 2. The specific collision (move AND examine into Edwardo)

Both supported commands that can target a creature tile route to the SAME unarmed `npc_menu` uilist:

- **move:** `avatar_action::move` (`src/avatar_action.cpp`) detects an NPC at the destination and calls
  `game::npc_menu( np )` → `uilist amenu; … amenu.query();` (`src/game.cpp` `game::npc_menu`).
- **examine:** `game::examine( const tripoint_bub_ms & )` (`src/game.cpp`) finds the creature at the
  examined tile and calls `npc_menu( *np )` — the SAME unarmed uilist.

So guarding `uilist::query` makes **both** `move_n` and `examine move_n` into Edwardo fail loud. This is
the task's mandate ("if BN reaches an unarmed uilist prompt/menu, Arcopolis must report
unexpected_prompt") applied uniformly; the examine case is the same honesty fix (examine-into-NPC also
silently cancelled the npc menu before).

**Blast radius (verified by code trace) — `npc_menu` plus the vehicle "Select an action" menu are
collateral:** `examine` onto the south item pile reaches `input_context("PICKUP")` (not a uilist) and stays
an accepted guard-cancel; `wait` reaches no uilist; the `pickup` vehicle-source and secondary-capacity
uilists are ARMED (`uilist_transaction_guard`, `src/pickup.cpp`) and keep driving at level 4; cata_test /
normal play are inert (`!session.active`). **One more collateral, also correct:** `examine` of a _vehicle_
tile routes to `vehicle::interact_with` (`src/game.cpp` `game::examine` → `vp->vehicle().interact_with`,
which `return`s before the pickup tail), and that opens its OWN unarmed `uilist selectmenu` ("Select an
action", `src/vehicle_use.cpp` — EXAMINE + TRACK are unconditional so it is always ≥2 entries and calls
`query()`). `examine` arms only the query_popup transaction, so this uilist is unarmed and now **also fails
loud** — the intended honesty behavior (it was a silent auto-cancel before). This is now **witnessed** by
scenario C of [`examine_regression.ps1`](examine_regression.ps1): an `examine move_s` of the
`ArcopolisVehicleCargoTest` cart asserts the fail-loud in BOTH modes (non-live run-script exit 14; live
recoverable `ok=false`). The `pickup`-path vehicle gates (`prompt_menu_regression.ps1`) still use the ARMED
uilist; scenario C is the distinct, unarmed `examine` path. See §10.

## 3. What changed (one site, reusing Spike 20)

`uilist::query()` (`src/ui.cpp`), at its existing `test_mode` abort
(`if( test_mode && !arcopolis::backend_uilist_transaction_active() )`), now calls — **before** the safe
`ret = UILIST_ERROR; return;` fallback:

```cpp
arcopolis::backend_report_unexpected_prompt( "uilist", "uilist::query" );
```

`backend_report_unexpected_prompt` (`src/arcopolis_backend_input.cpp`, the **Spike 20** helper — no new
error kind, no new helper) is **inert outside a session**, so cata_test / normal play keep the plain
abort. Inside a session with no uilist transaction armed it records a fail-loud `unexpected_prompt`. The
safe default (`UILIST_ERROR` → npc_menu cancels) is still returned as a **transport fallback** so nothing
hangs; the command runner turns the recorded state into the failure.

- **Reported at `query()` ONLY** — `uilist::init()`'s pre-existing `test_mode` debugmsg is untouched, so
  exactly ONE report fires per uilist (no `init()`+`query()` double entry). `backend_report_unexpected_prompt`
  is also first-report-wins, a second safety net. One `npc_menu` opens one uilist → one `query()` → one
  report.
- **No render/window/curses call** is added; the safe fallback is unchanged.

Surfacing is **entirely reused** from Spike 20 (no new code):

- one-shot/export: `src/arcopolis_export.cpp` checks `backend_session_failure()` after `do_turn` and
  before the snapshot → exit 14, no success snapshot.
- run-script: `src/arcopolis_script.cpp` post-loop `backend_session_failure()` check → exit 14; `done`
  stops the steps walk (so a move_n-first script aborts at move_n).
- live: `src/arcopolis_live.cpp` block (a) takes `backend_take_unexpected_prompt_error()` → a
  visibly-failed `ok=false` / `unexpected_prompt` response; the session stays open (recoverable).

## 4. Why this adds no prompt support

Nothing new is driven, exposed, or answered. No served category is added (`backend_nested_input_action`
still serves only `PICKUP`/`UILIST`/`YESNO`); no uilist transaction is armed by this spike. The change is
purely **detection**: an unarmed uilist that previously cancelled silently now records a typed failure.
The engine still proceeds down its own cancel branch (no state faked, nothing mutated) — the spike just
makes that silent cancel **observable and fatal/visible** instead of hidden. NPC dialogue/menu interaction
is **not** implemented; generic uilist support is **not** implemented.

## 5. How it preserves witnessed transactions and non-Arcopolis behavior

- **Witnessed UILIST (Spike 13B/14):** the vehicle-source and secondary-capacity uilists arm
  `backend_uilist_transaction_active()`, so `query()` does NOT take the abort —
  `backend_report_unexpected_prompt` is never called. Unit-pinned: the armed-uilist witness asserts
  `backend_session_failure()` stays empty (`tests/arcopolis_backend_input_test.cpp`).
- **Witnessed query_popup (15) / PICKUP (12A):** untouched — different chokepoints
  (`query_once` / `input_context("PICKUP")`), unchanged gates and serve branches.
- **Non-Arcopolis test_mode (cata_test / normal play):** `backend_report_unexpected_prompt` is inert when
  `!session.active`, so `query()` returns its usual `UILIST_ERROR` exactly as before. Pinned by the
  existing "cata_test uilist still aborts" test (extended to assert no failure recorded).

## 6. The reclassified baseline + the replacement `blocked_no_op` witness

move-into-NPC was the ONLY `blocked_no_op` witness; it now fails loud. To keep the harness's
`blocked_no_op` classification covered by a REAL runtime witness, a new fixture provides a **genuine
terrain block**:

- **`ArcopolisWallTest`** ([`make_wall_fixture.py`](make_wall_fixture.py)): a clone of `ArcopolisTest`
  with a `t_wall` (`move_cost 0`) on the clean floor tile one tile EAST of the avatar. A `move_e` into it
  runs the real `avatar_action::move` → `g->walk_move` leaf, which rejects the impassable destination with
  no move, no tick, and NO prompt (the "Invalid move" tail at `src/avatar_action.cpp` spends no moves for a
  sighted, same-z move; auto-bash needs the smash command; auto-mine needs a dig tool the avatar lacks) —
  a genuine `blocked_no_op`. Gated by the terrain `blocked_no_op` gate in
  [`client_harness_regression.ps1`](client_harness_regression.ps1).

The client harness now classifies the move-into-NPC outcome **distinctly** as `unexpected_prompt` (a new
outcome in `tools/arcopolis_client/harness.py`'s `OUTCOMES`) — never from the deltas alone, since a
fail-loud no-op and a genuine block have identical snapshots. The two surfacings differ by mode:
**non-live** aborts the run (no after-snapshot, so no export pair forms) and `cmd_run` reports it via the
backend exit code alone — it emits only the `run` block (`run.exit_meaning=unexpected_prompt`) and exits 1
_before_ `build_explain_model`, so neither `classify_pair` nor the top-level `model["errors"]` is produced
in the aborting path (`model["errors"]` is built by `build_explain_model`, reached only by a separate
`explain` of the saved session dir, or by a run that exited 0); **live** is recoverable, so `cmd_live`
anchors the failed command into its own
export pair carrying the `prompt_failed` marker, and `classify_pair` keys on that marker to label the pair
`unexpected_prompt` (the per-pair `errors` disjunct in `classify_pair` is defensive only). Either way it
still shows the NPC destination in the explanation when inferable from the before snapshot.

**`blocked_by=terrain` is NOT asserted for the wall witness (honest scope).** The harness's terrain-blocker
attribution requires `dest.seen=true`, but a HEADLESS run never populates the player's LOS / map-memory, so
**every** tile exports `seen=false` at the export instant (this is why the _old_ NPC witness used
`blocked_by=npc`, which is seen-agnostic). The harness `seen` guard mirrors real player knowledge, so it was
deliberately **left unchanged** (dropping it would make the external consumer ignore its own contract field
— an Arcopolis-side divergence). The wall gate therefore asserts the essential `blocked_no_op` outcome plus
that the harness's destination analysis reads the real `t_wall` terrain; `blocked_by` is honestly reported
empty ("no obvious blocker") for the unseen tile. The witness proves the `blocked_no_op` _classification_
(distinct from the move-into-NPC `unexpected_prompt`) on a genuine no-prompt terrain block — not the
seen-gated attribution.

## 7. What remains unsupported / fail-loud

- **NPC menu / dialogue (talk/attack/swap/push/steal/…)** — NOT implemented. Acting on a creature-occupied
  destination still needs its own command + (eventually) its own armed uilist transaction.
- **Generic `uilist`** — still none; exactly two witnessed sites arm a transaction (vehicle-source,
  secondary-capacity). Every OTHER uilist (computer menus, monster pet/bot/friend menus, the NPC menu,
  cata_test) now fails loud during a session instead of silently cancelling; none are DRIVEN.
- **`NEW_PICKUP_MENU=true` / `inventory_selector`** — still rejected at pre-flight (`unsupported_command`,
  exit 6), unweakened (docs 39/40). `INVENTORY` is NOT served.
- **`query_popup` / `query_yn`** — Spike 20 behavior unchanged (exactly one armed witness; every other
  fails loud during a session).

## 8. Validation (RECORDED 2026-06-20, PowerShell only)

All recorded against a fresh incremental build of `cataclysm-bn-tiles` + `cata_test-tiles` in
`out\build\win-rel-deb`. (Build host caveat: the worktree has no `out/` dir, so the two touched C++ files
were copied into the main repo, incremental-built, then the main sources were `git checkout`-restored — the
linked exes retain the change as a build artifact; the main repo tree is clean.)

- **AStyle** (`C:\dev\astyle\bin\AStyle.exe --options=.astylerc -n src\ui.cpp tests\arcopolis_backend_input_test.cpp`):
  both files **Unchanged** (already CI-formatted).
- **Build**: every touched TU compiled with zero errors (`ui.cpp`, the test TU); both exes freshly linked.
  `cmake --build` exit was nonzero ONLY from the known cosmetic post-link packaging tail
  (`applocal.ps1` / `deno docs:gen` → "The system cannot find the path specified") — `link.exe` produced
  both exes first (verified by fresh timestamps), so the tests ran from the freshly-linked binary.
- **Unit tests** `cata_test-tiles.exe "[arcopolis]"`: **All tests passed — 920 assertions in 143 test
  cases, exit 0** (the Spike-20 baseline was 903/141; +2 cases = the new "unarmed uilist fails loud
  (non-live)" and "unarmed uilist LIVE recoverable"; plus the extended cata_test-uilist-aborts and armed
  uilist setup "no failure" assertions).
- **Fixture** `python docs\arcopolis\make_wall_fixture.py`: created `ArcopolisWallTest` with `t_wall` one
  tile EAST of the avatar; read-back verified. (First attempt placed the wall one tile SOUTH — the flat
  terrain index is row-major `y*SEEX+x`, not `x*SEEY+y`; fixed in the generator, re-verified by the gate.)

### 8a. Recorded results — all green

- **`npc_export_regression.ps1`** — exit 0. Headline: `move_n` fail-loud `exit=14`, `before` written,
  **no** `after_move_n` snapshot, **exactly one** `error kind=unexpected_prompt` (no init()+query() double).
- **`client_harness_regression.ps1`** — exit 0 (all 7 gates): run-mode `move_n` →
  `run.exit_meaning=unexpected_prompt` (exit 14, not blocked_no_op); `move_s,wait` → `moved,waited,no_command`;
  **terrain** `move_e` on `ArcopolisWallTest` → `blocked_no_op,no_command` on a real `t_wall`
  (`blocked_by` withheld — `seen=false` headlessly, heuristic not bent); view carries Edwardo; diagonal
  `move_se`; viewer; monster fixture.
- **`live_protocol_regression.ps1`** — exit 0: 6 responses, `move_n` recoverable `ok=false/unexpected_prompt`,
  4-pair sequence `unexpected_prompt,moved,waited,no_command`, NPC-aware explanation, negative probe.
- **`examine_regression.ps1`** — exit 0 (13 gates as recorded; the §10-item-3 follow-up later added
  **scenario C** for the vehicle "Select an action" uilist, +2 gates → 15, also exit 0): `examine move_n`
  (A: served chooser then fail-loud; B: auto-select force-clear then fail-loud), both recoverable;
  item-examine / diagonal / message-stream / recoverability all green.
- **`prompt_menu_regression.ps1`** — exit 0: the **armed** uilist witnesses (vehicle-source 13B,
  secondary-capacity 14 WIELD/WEAR) still DRIVEN at level 4, **no spurious `unexpected_prompt`**.
- **`script_prompt_regression.ps1`** — exit 0: W1–W5 + fail-loud gates; armed uilist via script unbroken.
- **`query_popup_regression.ps1`** — exit 0 (6 gates): Spike 20 armed query_popup unbroken.
- **`frontend_prototype_regression.ps1`** — exit 0 (18 gates): bridge `move_n` and `examine move_n` →
  recoverable `unexpected_prompt` (HTTP 200, session survives); no bridge code change needed.

## 9. Claim → cite → verdict

Per [[cite-the-implementing-line]].

| Claim                                                                                                              | Cite                                                                                     | Type       | Verdict                                                  |
| ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------- |
| query() reports unexpected_prompt before its UILIST_ERROR fallback, gated on session                               | `src/ui.cpp` `uilist::query`                                                             | behavioral | ✅ unit + npc_export/examine/live regressions            |
| Reported at query() only; exactly one report per uilist (no init() double)                                         | `src/ui.cpp` (init() unchanged)                                                          | absence    | ✅ static; npc_export gate asserts exactly 1 error event |
| Inert outside a session (cata_test unchanged)                                                                      | `src/arcopolis_backend_input.cpp` `backend_report_unexpected_prompt` (`!session.active`) | behavioral | ✅ unit (cata_test uilist still aborts, no failure)      |
| Reuses Spike 20 channel (no new error kind / exit 14)                                                              | `src/arcopolis_command.cpp` `exit_code_for`                                              | structural | ✅ static                                                |
| Both move AND examine into the NPC reach the same unarmed npc_menu uilist                                          | `src/avatar_action.cpp` move; `src/game.cpp` `game::examine` → `npc_menu`                | behavioral | ✅ regression (npc_export / examine / live)              |
| Armed uilist (13B/14) records no failure / still driven L4                                                         | `tests/arcopolis_backend_input_test.cpp` + prompt_menu/script_prompt                     | behavioral | ✅ unit + prompt_menu/script_prompt regressions          |
| harness classifies move-into-NPC as unexpected_prompt, not blocked_no_op                                           | `tools/arcopolis_client/harness.py` `classify_pair` / `BACKEND_EXIT_MEANINGS`            | behavioral | ✅ client_harness / live regressions                     |
| terrain `blocked_no_op` retains a live witness (classification only; `blocked_by` withheld, `seen=false` headless) | `docs/arcopolis/make_wall_fixture.py` + client_harness terrain gate                      | behavioral | ✅ regression (blocked_no_op + t_wall dest)              |
| No new curses window / render primitive                                                                            | no new `newwin`/draw call added                                                          | absence    | ✅ static                                                |

## 10. Residual uncertainties (kept)

1. Runtime greens (the new unit tests + the reworked regressions) rest on the build/run recorded in §8a;
   if the build was blocked, only what compiled/ran is claimed.
2. The wall `blocked_no_op` witness assumes a plain `move_e` into `t_wall` is a clean no-op (no prompt, no
   tick). This is argued from `avatar_action::move` and confirmed by the self-checking terrain gate; if a
   future BN sync makes a wall bump prompt or bash, swap `WALL_TER` in `make_wall_fixture.py` for an inert
   impassable id (the gate catches it).
3. Two reachable unarmed-uilist sites are now WITNESSED by gates: `npc_menu` (move/examine into the NPC) and
   the vehicle `interact_with` "Select an action" `uilist` (§2). The vehicle case is exercised by **scenario
   C** of [`examine_regression.ps1`](examine_regression.ps1): an `examine move_s` of the
   `ArcopolisVehicleCargoTest` cart (the `folding_wagon` one tile south of the post-`move_s` avatar) asserts
   the fail-loud in BOTH surfacings — non-live run-script (exit 14, `before` written, NO `after_examine`
   snapshot, exactly one `unexpected_prompt` error event) and live (recoverable `ok=false` / `unexpected_prompt`
   with a `prompt_failed` marker, the DEFAULTMODE chooser answer still served, and NO pickup guard — proving
   the vehicle branch returns before the pickup tail). Recorded green 2026-06-20 (the full
   `examine_regression.ps1` passes 15 gates, exit 0, against the same exe as §8a). The OTHER unarmed uilist
   families remain fail-loud-by-guard but **unwitnessed** in the current fixtures — computer menus and monster
   pet/bot/friend menus are not reachable by the supported command surface here.
4. The harness's `blocked_by=terrain` attribution is **not** witnessed end-to-end: it needs `dest.seen=true`,
   but a headless run never populates LOS/map-memory so every exported tile is `seen=false`. The terrain
   witness therefore proves the `blocked_no_op` classification + the `t_wall` destination read, not the
   seen-gated attribution. (Fixing this would need an export-`seen` change — out of scope — or bending the
   consumer heuristic, deliberately rejected.) The GUI itself does see the adjacent wall; this is an export
   limitation, not an engine difference.
5. Line numbers drift; confirm by symbol.
