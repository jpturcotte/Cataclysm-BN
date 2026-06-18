# Arcopolis level-4 truth audit — where we actually are with backend-input equivalence

**Status: standing reference (level-4 honesty companion to [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md);
audit performed 2026-06-18, no behavior changed).** Doc 37 audited every equivalence *claim* across the
tree. This doc answers one narrower question at the leaf: **where are we *truly* with backend-input
(sense-1) level-4 equivalence for the prompt paths Spikes 11B–16 (PRs #31/#34/#37/#38/#40–#44) touched or
added?** It downgrades any claim the audit's adversarial pass refuted, and records two places where a leaf
re-read corrected the audit itself. The authoritative current-state page remains
[ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md).

> **Method + honesty caveats.** A multi-agent audit (per path: ground-truth read → classify → three
> adversarial refute-lenses) followed by a hand leaf-verification of every load-bearing downgrade. **No
> build was run** — the runtime greens (regression gates, exit codes, the `[arcopolis]` unit pass) rest on
> the docs' run-logs, not re-execution this session; the *source seams* were verified, the *live passes*
> were not re-run. Line numbers are current-tree at audit time; confirm by symbol name (they drift — that
> is partly why this audit exists). Terminology (backend-input vs engine vs frontend equivalence) is the
> three senses pinned in [doc 37](37_SPIKE17_CLAIM_AUDIT.md) §"Terminology" and `AGENTS.md:83-120`.

## The question, and the one-paragraph honest answer

We have **genuine backend-input (sense-1) level-4 drive for a small set of single hardcoded prompt
*instances* — not for any prompt *class*.** The shared seam is real and verified at the leaf: at the top of
`input_context::handle_input(timeout)` the backend is consulted and, in a session, its served action is
returned straight into the engine's own loop (`src/input.cpp:941-947`); the real loops then compute their
*own* result — the uilist do-loop sets `ret` only at `src/ui.cpp:994/1003/1009`, the `query_popup`
`query_once` loop sets `res.action` only at `src/popup.cpp:333-337`. The backend never writes the return
value; its resolve functions only translate a chosen index into a queue of registered actions
(`[DOWN×K, CONFIRM]` / `LEFT/RIGHT/CONFIRM`). That is the line between level 4 and a fake (a resolve-choice
shortcut, a forced retval, or a preloaded answer that bypassed the loop would **not** be level 4). Where
that machinery fires it is true level 4 and the engine mutates real world/inventory/activity state
(sense-2). But every level-4 cell is **one fixture, one call site**: one examine direction-chooser, the old
`"PICKUP"` menu, exactly two pickup `uilist` sites (`src/pickup.cpp:292`, `:1405`), and exactly one
`query_yn` (`src/iexamine.cpp:1427`). **`move` is *not* level 4** (its action_id never enters
`handle_input`); generic `uilist`/`query_yn`, `inventory_selector`, and `NEW_PICKUP_MENU` still
test_mode-abort. The fail-loud boundary is leaf-comprehensive against silent *fake success*, but it is
**not** "no silent prompt at all": an unguarded `query_yn` reached through the supported `examine` verb
silently defaults to NO, unmarked, exit 0.

## Leaf re-verifications (the load-bearing downgrades, checked by hand)

These five were re-read at the implementing line this session — the three the adversarial pass used to
downgrade, plus two where the leaf read *corrected the audit's own draft*:

| Claim | Leaf check (current tree) | Result |
| ----- | ------------------------- | ------ |
| The level-4 seam is real — the loop consumes a served action and computes its **own** result; the backend never sets the retval | `src/input.cpp:941-947` returns `backend_nested_input_action(...)` at the *top* of `handle_input`; the normal keyboard read is below at `:949-`. uilist sets `ret` only at `src/ui.cpp:994/1003/1009`; `query_once` sets `res.action` only at `src/popup.cpp:333-337` | **Confirmed** — genuine level 4 |
| **`move` is NOT level 4** | `src/handle_action.cpp:1778-1779` injects `act = arcopolis::next_backend_action()` as a bare top-level `action_id` into the `switch` (mirrors the auto-move branch); it never reaches `input_context::handle_input` | **Confirmed** — `move` is sense 2/3 only |
| **"No silent path" is too strong** — an unguarded `query_yn` via `examine` → silent NO, exit 0 | `src/output.cpp:735-746` arms the drive-block ONLY under `backend_query_popup_mode_active()`; otherwise `src/output.cpp:748` runs `return popup.query().action == "YES"`, and under test_mode `query_once` returns `{false,"ERROR",{}}` (`src/popup.cpp:277-279`) → NO, with **no** transcript mark (the mark is inside the un-run armed block) and **no** nonzero exit | **Confirmed** — real silent prompt-default |
| Audit draft said the WIELD consequence was "inferred from a message string" | The regression asserts the engine's own **`"Wielding <item>"` message** (emitted *inside* `u.wield`) **plus the item leaving the ground** (`prompt_menu_regression.ps1:509,525`; capacity gate `:903,912`). That is a real engine consequence, not a guess | **Corrected** — witnessed via real engine output + item-gone; gap is narrower (see below) |
| Audit draft said the vehicle drive is witnessed for the submenu generally | Every Scenario-H sub-gate answers **ground** (choice:1, served `[DOWN, CONFIRM]`) and asserts the ground count drops (`prompt_menu_regression.ps1:713-716`); the **cargo** branch (choice:0) is exposed as a real entry but never selected | **Corrected** — witnessed for the **ground** branch only |

## Scorecard

Cells reflect the adversarial verdicts and the leaf re-verifications above. "L4" = backend-input / sense-1.

| Path | Backend-input L4 | Engine-equiv | Frontend-equiv | Witness scope | True level |
| ---- | ---------------- | ------------ | -------------- | ------------- | ---------- |
| `move` / directed-examine (baseline) | **examine chooser: yes · `move`: no** | yes | yes (read/unit only) | one-witness-per-shape | examine chooser **4**; `move` **2/3** |
| Legacy `"PICKUP"` menu (12A) | yes | yes | yes | single hardcoded witness | **4** (this path) |
| Vehicle-source `uilist` (13B) | yes | yes — **ground branch only**; cargo branch exposed but undriven | partial | single hardcoded witness | **4** (from-ground submenu only) |
| Secondary capacity `uilist` (14) | yes (all-enabled only) | yes — WIELD via `"Wielding"` msg + item-gone (**no snapshot weapon-slot field**) | no | single hardcoded witness | **4** (all-enabled WEAR/WIELD only) |
| `query_popup` `query_yn` (15) | yes | yes | partial | single hardcoded witness | **4** (deployed-furniture take-down only) |
| Non-live script-replay (16/44) | yes — **"level-4-replayed"** | yes | yes (choices exposed; no live frontend) | single witness ×4 sites | **4-replayed** |
| Renderer-neutral invariant | n/a | n/a | partial (**tiles-only**) | cross-cutting | sense-3 only |
| Fail-loud boundary | n/a | partial | partial | cross-cutting | **"no silent path" refuted** (see §below) |

## What level 4 truly means here

Level 4 (sense-1) means a backend-served action is **consumed by the engine's real, unmodified active
input loop** — the same `do/while` on `input_context::handle_input` a human keypress would drive — and the
**loop itself** computes the result. The served string enters at `src/input.cpp:944-946` exactly as a
decoded keypress would; the uilist loop sets `ret` (`src/ui.cpp:994/1003/1009`), the `query_popup` loop sets
`res.action` (`src/popup.cpp:333-337`). The backend's `backend_resolve_*` functions only translate a choice
into a queue of registered actions; they never set the return value.

The honest distinction: **"this one witnessed path is level 4" ≠ "this prompt class is supported."** Every
level-4 claim here is a single hardcoded call site reached by a specific fixture. The un-abort gates are
armed *per-transaction* at exactly the audited sites (`backend_ui_mode_active = session.active &&
session.uilist_transaction`, `src/arcopolis_backend_input.cpp:758-761`; `backend_query_popup_mode_active`
`:880-883`). A *second, different* instance of the same class that does not arm a transaction hits the
ordinary test_mode abort (`src/ui.cpp:933`, `src/popup.cpp:277`) and is undriven. Generalization is by
**reuse of the seam at new hardcoded sites**, not by a general UI abstraction.

## Per-path honest notes

- **`move` / directed-examine.** SPLIT. The examine direction-chooser genuinely reaches the real loop
  (`choose_direction` do/while on `input_context("DEFAULTMODE")`, served via `src/input.cpp:941-947`) — level
  4 for the **sub-prompt only**. `move` is **not** level 4: the action_id is injected as a bare top-level
  action at `src/handle_action.cpp:1778-1779` and never enters `handle_input` — it is engine/frontend-
  equivalent (sense 2/3) but raises no prompt. Witnessed for three shapes (one cardinal, one diagonal, one
  served-then-cancel); the other directions + `here`→pause are unit-tested vocabulary only, not each
  fixture-witnessed (doc 26 "known limitations").

- **Legacy `"PICKUP"` menu (12A).** True level 4 for the main item menu: the unmodified `do`-loop's
  `action = ctxt.handle_input()` exits only on QUIT/CONFIRM; `backend_resolve_pickup_choice` only translates
  indices to keystrokes. Real consequence: `assign_activity(pickup_activity_actor)` → real `i_add`/detach on
  drain. **Scope boundary:** no in-process C++ test composes the real `query()` loop end-to-end (only the
  seam is unit-tested); end-to-end is proven only by the (unexecuted-this-session) PS regression.

- **Vehicle-source `uilist` (13B).** Level 4 for the "Get items from where?" submenu (`src/pickup.cpp:1405`
  region); the served action drives the real loop and the engine sets `get_items_from` from `amenu.ret`.
  **Scope boundary (leaf-confirmed):** the **ground** branch is the only one driven to a consequence — every
  Scenario-H sub-gate answers choice:1 and asserts the ground tile count drops
  (`prompt_menu_regression.ps1:713-716`). The **cargo** branch (choice:0) is exposed as a real entry by the
  engine's own `setup()` but is **never selected, driven, or mutation-witnessed**.

- **Secondary capacity `uilist` (14).** Level 4 for `handle_problematic_pickup`'s all-enabled WEAR/WIELD
  prompt (`amenu.query()` `src/pickup.cpp:292`); real mutation `u.wield` / `u.wear_item`. The WIELD is
  witnessed by the engine's own **`"Wielding <item>"` message (emitted inside `u.wield`) plus the item
  leaving the ground** — a real consequence — but **no snapshot field asserts the resulting weapon slot
  directly** (the export carries no wielded-weapon field). **Scope boundary:** level 4 **only when every
  entry is enabled** (`src/pickup.cpp:285-288` gate); a disabled-entry shape is refused/fail-loud, not
  driven. EMPTY/SPILL branches unwitnessed. Frontend = no (no prototype drives it).

- **`query_popup` `query_yn` (15).** Level 4 for the deployed-furniture take-down: guard at
  `src/iexamine.cpp:1427`, real `query_once("YESNO")` loop, YES → `take_down_deployed_furniture`. **Scope
  boundary (grep-confirmed):** exactly ONE engine site arms a `query_popup` transaction; the same-file
  slip-through and the portable-structure take-down carry NO guard and abort to NO. No unit covers the full
  `query_yn`→drive-block; only the live regression does.

- **Non-live script-replay (16/44).** See the subtle case below.

- **Renderer-neutral invariant.** Proves only sense-3 (no curses window, no render primitive) and, as
  *witnessed*, only in the **tiles** build (the no-window unit assertions). The curses `::newwin`-before-
  `initscr` crash it guards is reasoned from code, never run in a curses build. The mechanism is
  **asymmetric**: `uilist` needs the explicit `src/ui.cpp:638` skip; `query_popup` is window-free only via
  the `src/ui_manager.cpp:328` redraw no-op. A new `setup()`/`init()`-calling site must re-uphold the
  invariant explicitly. Says nothing about senses 1/2.

- **Fail-loud boundary.** Leaf-verified exit codes: unsupported → 6 (`src/arcopolis_command.cpp:255-256`),
  nested_input_failed → 12, script_prompt_failed → 13 (`:269-270`). Genuinely prevents silent *fake
  success*. But the broad "no silent path" framing is refuted — see below.

## The subtle case — is non-live script-replay still level 4?

**Verdict: yes — but precisely "level-4-replayed," not live level 4.** The skeptic tried to show it bypasses
the loop and could not. Non-live changes **only the answer transport** (a preloaded per-command queue
instead of live stdin), not the loop. The queued answer enters the real loop at the **same seam** as a live
answer (`src/input.cpp:941-947`): at the top of the real `input_context::handle_input`,
`backend_nested_input_action` is consulted and, if non-null, returned as the loop's action. The script
source returns the **same internal type** as the live source and is installed in the **same session slots**;
the unchanged `backend_resolve_*` builds the identical keystroke queue, and the real loops still set their
own `ret`/`res.action`. So the loop genuinely runs and consumes registered actions — **the answer is
pre-recorded, the consumption is real.** A preloaded answer that *bypassed* the loop would not be level 4;
this one does not bypass it. Scope: four hardcoded sites only.

## "No silent path" is refuted for one in-scope verb

The supported `examine` verb dispatches to the engine's real `examine()`, which can reach any `iexamine`
`query_yn`. Only the deployed-furniture take-down is guarded (`src/iexamine.cpp:1427`); an unguarded
`query_yn` (e.g. a gas pump, recharge station — `iexamine.cpp` has many `query_yn` sites, one guarded)
aborts at `src/popup.cpp:277-279`, and `src/output.cpp:748` maps `{false,"ERROR",{}}` to a **silent NO,
unmarked, exit 0**. It is **not** a fabricated success (nothing mutates — the engine simply proceeds down
the NO branch), so the genuine guarantee — *no silent fake-success* — still holds. But it **is** a silent
prompt: a decision the player would be asked is silently answered NO with no transcript mark and no nonzero
exit. **No current fixture examines such a tile,** so this is a latent gap, not a witnessed live regression
— but the "comprehensive / no silent path" framing in doc 37 and STATE.md papered over it, and is corrected
there.

## Open defects / residual uncertainties (kept verbatim in spirit)

- **No session was rebuilt or re-run.** Every runtime claim rests on doc run-logs (doc 33 2026-06-15; docs
  34/35 2026-06-16; doc 36), not re-execution. Source seams verified; live passes not re-run.
- **No in-process C++ test composes the real `uilist` `query()` loop end-to-end** — uilist end-to-end is
  proven only by the external PS regression.
- **Vehicle CARGO branch (choice:0) has no drive or world-mutation witness** — exposed in the prompt, but
  every sub-gate answers ground.
- **WIELD weapon-slot is witnessed indirectly** — the `"Wielding"` message (real engine output) + item-gone,
  not a snapshot field reading the weapon slot (none is exported).
- **Multi-tick resumed orphaned secondary pickup** is transcript-marked but sets **no `pickup_outcome` and
  exits 0** — coverage-by-proxy (in-memory reporter call; no fixture drives a real second activity tick).
  Honest-in-transcript, but exit-0.
- **`query_popup` EOF/closed path exits 0** — confirms the engine's own visible NO-default, logged
  `noncancelable_closed`; transcript-marked, not a fabricated success, but a reader skimming "exit 0" could
  misread it.
- **The silent-NO `query_yn` gap above** — reachable in principle through the supported `examine` verb; not
  witnessed by any current fixture.
- **Renderer-neutrality is tiles-only and mechanism-asymmetric**; the curses crash it guards is reasoned,
  never run.
- **Several docs carry stale line numbers** (doc 33's `ui.cpp` block; some doc 34/35 backend_input cites).
  Current-tree leaves were used throughout; doc line numbers are not authoritative.

## Honest "not yet" — NOT proven

- **Generic `uilist` support** — only two hardcoded pickup `uilist` sites are driven; every other `uilist`
  (`inventory_selector`, cata_test, NPC dialogue, computer, monster menus) still test_mode-aborts at
  `src/ui.cpp:933`.
- **Generic `query_yn`/`query_popup` support** — exactly one site arms a transaction
  (`src/iexamine.cpp:1427`); cancelable `query_popup`s, `popup()`, `popup_getkey`, `ANY_INPUT`,
  `string_input` are all undriven.
- **`NEW_PICKUP_MENU=true` / `inventory_selector`** — explicitly rejected (exit 6) in both live and
  run-script. Only the OLD `input_context("PICKUP")` menu is driven.
- **Second instances of every witnessed path** — a different examine direction/target, a vehicle
  **cargo-pull**, a disabled-entry capacity prompt, a non-deployed-furniture `query_yn`, a multi-tick
  resumed secondary — none are witnessed; most hit a refusal, an abort, or a mark.
- **`move` as level 4** — it never enters `handle_input`; it is sense 2/3 only. Do not round it up.
- **Frontend equivalence as a witnessed fact** — no external mouse-first frontend was driven against any
  `uilist`/`query_popup` path; choices are *exposed*, parity is argued, not observed (the prototype covers
  only planar move/examine, doc 29).
- **Disabled-entry navigation** — refused (served QUIT), never driven, for every `uilist` path.

## Corrections this audit triggered (doc-only; no behavior change)

1. **`37_SPIKE17_CLAIM_AUDIT.md`** — three targeted corrections:
   (a) the "supported today" list now marks `move` as engine/frontend-equivalent (sense 2/3, no
   `handle_input`), distinct from the examine direction sub-prompt (sense-1 level 4);
   (b) the fail-loud framing now distinguishes "no silent *fake success*" (holds) from the silent-NO
   `query_yn`-via-`examine` prompt-default (a real gap), and softens "no silent path to regress";
   (c) the vehicle bullet notes the **ground-branch-only** witness, and the secondary-capacity bullet
   states the WIELD is witnessed via the `"Wielding"` message + item-gone (no snapshot weapon-slot field).
2. **`ARCOPOLIS_STATE.md`** — the Known-unsupported/fail-loud table's intro and the `query_yn` row carry the
   same "no silent *fake success*, but one silent prompt-default exists" nuance; a pointer to this doc is
   added to the current-truth banner.

*All file:line references verified against the current worktree this session; runtime results were read from
regression scripts and doc logs, not re-executed (read-only audit).*
