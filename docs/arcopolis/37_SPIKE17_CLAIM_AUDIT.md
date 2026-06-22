# Arcopolis Spike 17 — claim audit (backend-input vs engine vs frontend equivalence)

**Status: standing reference (audit of the tree as of Spike 16, performed 2026-06-18).** A
correctness/honesty pass over every load-bearing equivalence claim across `src/`, `tests/`, the
regression scripts, the PR history (#37/#38/#40–#44), and `docs/arcopolis/`. **No behavior changed.**
The authoritative current-state page remains [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md); this doc records
what the audit found and the minimal doc/comment corrections it triggered.

> **Companion (added 2026-06-18):** [38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md) sharpens this
> audit's level-4 claims at the leaf — where we are _truly_ with backend-input (sense-1) equivalence, per
> path — and triggered the three corrections folded in below: the `move` sense-2/3 caveat, the fail-loud
> "no silent _fake success_" vs. silent prompt-default distinction, and the vehicle-ground / WIELD
> witness-scope notes.

> **On line-number citations in this doc:** they were re-read at the leaf in the current tree at audit
> time and are tagged "(current tree)". They drift as gated call sites move (this audit exists partly
> because several did) — treat them as approximate-and-dated, confirm by symbol name, and prefer the
> function names over the numbers when they disagree.

## Scope and why this spike exists

Spikes 13B–16 widened the backend from "drive the old `"PICKUP"` menu" to "drive **four** witnessed prompt
paths at level 4, live and (Spike 16) non-live, with fail-loud fallbacks." That widening is real and witnessed
— but generic-sounding labels ("GUI-equivalent", "backend-driven uilist", "query_popup", "level 4")
accumulate ambiguity, and line-number citations drift as the gated call sites move. Before **any** further prompt-class
exploration, this audit pins exactly what is supported, exactly what is witness-scoped, and exactly what
fails loud — so a future reader neither over-credits the backend nor chases a phantom regression.

This audit is meant to make the project **more honest, not more impressive.** Every claim below is
witness-scoped and cited at the implementing line.

**Headline finding:** the recent docs are already unusually disciplined — docs 30/31/32/34/35/36 carry
their own dated supersession banners and several carry their own cite-the-line audits. The audit found
**no** doc or comment that claims a path it cannot drive, and **no** implication of a general arbitrary-
menu abstraction. The corrections are a small set of (a) one banner-less standing-reference doc that now
silently conflicts with the tree, (b) line-number drift on two current-truth surfaces, and (c) one stale
fixture parenthetical in AGENTS.md. Everything else is accurate or accurate-but-broad (flagged, not
wrong).

## Terminology this audit enforces

Three distinct senses, anchored by `AGENTS.md:83-120` (the numbered **equivalence levels 1–4** are defined
at `AGENTS.md:111-120`, restated at [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) §Terminology →
"Equivalence levels (1–4)"):

1. **Backend-input-equivalent** — the backend serves registered actions that BN's real
   `input_context`/menu/UI loop consumes (e.g. `input_context("UILIST")::handle_input`,
   `input_context("YESNO")` via `query_popup::query_once`).
2. **Engine-equivalent** — the real engine caller receives the UI result and mutates
   world/inventory/activity state (e.g. `pickup_activity_actor` performs the transfer; the engine sets
   `amenu.ret` / `result.action`). The backend NEVER mutates menu/selection state directly.
3. **Frontend-equivalent (the project goal)** — an external, mouse-first frontend exposes the same
   meaningful choices/consequences **while BN stays authoritative**, possibly with different visuals.
   Backend-input level 4 (sense 1) is the **proof mechanism** for this goal — it shows the player's choices
   flow through BN's own real loop and mutate real state — **not** a replacement for it.

**Spikes 13B–16 prove backend-input + engine equivalence for SPECIFIC WITNESSED paths. They do NOT prove
frontend/visual equivalence.** By design the backend creates **no curses window and calls no render
primitive in any build**: `ui_adaptor::redraw_invalidated()` returns early under `test_mode`
(`src/ui_manager.cpp:328`), both gates leave `test_mode` true (they only bypass the early abort), so the
`on_redraw`/`on_screen_resize` callbacks never fire; the `uilist` path additionally skips
`catacurses::newwin` (`src/ui.cpp:638-643`). Pinned by `tests/arcopolis_backend_input_test.cpp` no-window
assertions. "GUI-equivalent" / "level 4" in these docs means the **backend-input** sense, per
`AGENTS.md:83-93` ("'GUI behavior' means backend INPUT behavior"; "A different external frontend/client
UX is fine").

## Claim audit table

Verdict vocabulary: **Accurate · Accurate but too broad · Superseded · Misleading wording · Unsupported
by current tests · Incorrect · Needs follow-up spike.** Verdicts honor the adversarial verifications;
each load-bearing line was re-read at the leaf in the current tree.

| Area                                                                                             | Claim found                                                                                                                                                                                                                                                                                                     | Evidence in current code/tests/docs                                                                                                                                                                                                                                                                                                                                | Verdict                                                | Required fix                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| doc 28 — secondary capacity uilist (Q1/Q3/Q5/Q11/Q15)                                            | `28_GUI_EQUIVALENCE_AUDIT.md:33` "After CONFIRM the activity's secondary capacity/wield/spill `uilist` is **not driven** … the guard force-cancels it"; `:51` lists "driving the in-activity capacity/wield/spill prompts" as deferred. Doc `:3` "standing reference (2026-06-13)", **no supersession banner**. | Spike 14 DRIVES that uilist at level 4 when all-enabled: drive gate `src/pickup.cpp:193-194`, resolve `:289`, `amenu.query()` `:292`; `ARCOPOLIS_STATE.md:236-242`. Grep for any supersession/13B/14 marker over doc 28 → 0 hits.                                                                                                                                  | **Superseded**                                         | One dated, **scoped** banner under doc 28:3 — the all-enabled/single-tick/channel-present uilist is now driven; force-cancel/fail-loud is **retained** for disabled-entry (`src/pickup.cpp:285-288`), no-channel (`:195-198`), and multi-tick orphaned (`:208-211`). Do NOT flatly call "force-cancels" superseded; leave the `NEW_PICKUP_MENU`/inventory_selector rows. |
| doc 28 — examine menu-targets row (Q1/Q13/Q15)                                                   | `:29` examine menu targets "reaches the target, then the menu auto-cancels … never claimed drivable".                                                                                                                                                                                                           | Vehicle-source uilist driven via pickup; deployed-furniture `query_yn` driven via examine (`src/iexamine.cpp:1427` → `src/popup.cpp:277-279`). Blanket "never drivable" now false for those two.                                                                                                                                                                   | **Superseded**                                         | Same doc-28 banner carves out the vehicle-source uilist + deployed-furniture query_yn; the still-undriven list is NPC talk/attack, monster menus, computer use, and the examine auto-pickup tail (still ESC-cancels, `ARCOPOLIS_STATE.md:561`).                                                                                                                          |
| AGENTS.md — `ArcopolisTest` fixture parenthetical (Q3/Q5/Q11/Q15)                                | `AGENTS.md:191` `ArcopolisTest` "witnesses **rejected-items** pickup (an over-capacity selected item is left on the ground … driving the in-activity capacity prompt is a tracked defect, so the guard force-cancels it)".                                                                                      | Regression **Scenario E** drives that exact `[0,6]` over-capacity blanket case on the **default no-backpack `ArcopolisTest` avatar**: Spike 14 wields the blanket (7→5), "NO forced_cancel/partial/unsupported_prompt markers" (`prompt_menu_regression.ps1:447-456`; doc 34 Gate E). The force-cancel survives only as the no-channel/disabled/orphaned fallback. | **Superseded**                                         | Update the parenthetical: `ArcopolisTest` is the Spike-14 **driven single-entry WIELD** secondary-capacity witness; force-cancel retained only as the no-channel/disabled-entry/orphaned fallback. (`ArcopolisBackpackTest`'s carry-both description — Scenario F, `[5,6]` — stays accurate.)                                                                            |
| doc 33 — "current tree" source-audit block, `src/ui.cpp` lines (Q14/Q16)                         | `33_SPIKE13B…:21` header "Source audit (read at the implementing line, current tree)" then `:28` abort `:918-922`, `:30` redraw `:934`, `:31` do-loop `:944-1001`, `:33` CONFIRM `:974-980`, `:34` QUIT→CANCEL `:981-982`, `:39` seam `:944`.                                                                   | Current tree (verified): abort `:933-937`; redraw `:961`; do-loop `:971-1028`; CONFIRM `:1001-1007`; QUIT→`UILIST_CANCEL` `:1008-1009`; seam `:971`. PR #40's own newwin-skip insertion (`:638-643`) shifted them down. doc 34:66 already cites `:933-937`.                                                                                                        | **Superseded (line drift, not behavioral)**            | **Safest:** append a header caveat to the block ("line numbers pre-date PR #40's newwin-skip insertion; current gate is `src/ui.cpp:933-937` — see doc 34"). Behavior described is correct.                                                                                                                                                                              |
| STATE.md — stale `src/ui.cpp:918` / `src/popup.cpp:269` (Q4/Q14/Q16)                             | `ARCOPOLIS_STATE.md:573` "(`src/ui.cpp:918`)"; `:574` "(`src/popup.cpp:269`)".                                                                                                                                                                                                                                  | `src/ui.cpp:918` is `reposition( ui );`; gated abort `:933-937`. `src/popup.cpp:269` is blank; gated abort `:277-279`. Same page `:590` already cites the correct `src/popup.cpp:277`.                                                                                                                                                                             | **Superseded (line drift)**                            | Bump numbers only: `:573` `918`→`933-937`; `:574` `269`→`277-279`. Behavior (short-circuit before the `input_context` is built) is correct.                                                                                                                                                                                                                              |
| `prompt_menu_regression.ps1` header (Q1/Q2/Q17)                                                  | `:1` "Arcopolis Spike 12A regression: **GUI-equivalent** pickup prompt/menu transaction."                                                                                                                                                                                                                       | Body `:5-6` precise ("drives the engine's OWN menu loop with the SAME registered actions"); no rendering compared anywhere. In-bounds via `AGENTS.md:83-93` but reads visually broader standalone.                                                                                                                                                                 | **Misleading wording (header only)**                   | Optional one-line header tighten "GUI-equivalent" → "level-4 (backend-input)".                                                                                                                                                                                                                                                                                           |
| Generic-sounding uilist test titles (Q2/Q3/Q18)                                                  | `arcopolis_backend_input_test.cpp` "backend-driven uilist serves DOWN+CONFIRM…", "builds the right action queue per answer", "refuses a disabled-entry shape".                                                                                                                                                  | Each drives a 2-entry all-enabled single-select shape; the disabled case serves QUIT before asking the client. All-enabled bound enforced `src/pickup.cpp:285-288`. No larger / non-pickup uilist exercised.                                                                                                                                                       | **Accurate but too broad (flag only)**                 | None required. Bodies + `ARCOPOLIS_STATE.md:248-250` scope them.                                                                                                                                                                                                                                                                                                         |
| Generic-sounding query_popup test titles (Q4/Q18)                                                | `arcopolis_backend_input_test.cpp` "backend-driven query_popup …".                                                                                                                                                                                                                                              | Every query_popup test is the one deployed-furniture take-down `query_yn` (witness `examine_deployed_furniture_take_down`), 2 entries YES/NO, cursor NO, cancelable=false; no second query_yn constructed.                                                                                                                                                         | **Accurate but too broad (flag only)**                 | None required. Witness scope asserted structurally + documented (`ARCOPOLIS_STATE.md:260-277`).                                                                                                                                                                                                                                                                          |
| Orphaned-secondary / multi-tick test (Q1/Q12/Q18)                                                | `arcopolis_backend_input_test.cpp` "orphaned secondary report marks but sets no outcome"; a comment frames a "multi-tick … resumed after the transaction was cleared" scenario.                                                                                                                                 | Test calls the reporter in three session states and CHECKs outcome; it never drives a resumed prompt or a second tick. The coverage gap is self-disclosed; multi-tick is backlog (`ARCOPOLIS_STATE.md:599`).                                                                                                                                                       | **Unsupported by current tests — but title is honest** | None. Title = exactly what the test checks; comment self-discloses the proxy. Do NOT add a fixture (out of scope).                                                                                                                                                                                                                                                       |
| STATE.md banner + level-4 framing (Q1/Q16)                                                       | `ARCOPOLIS_STATE.md:1-6` "this page is the current truth. When they disagree, this page wins".                                                                                                                                                                                                                  | Body accurately describes post-Spike-16 state (pickup `:177-186`, vehicle uilist `:204-213`, secondary capacity uilist `:236-242`, query_yn `:260-277`, non-live script `:215-234`). No drift into frontend-equivalence.                                                                                                                                           | **Accurate**                                           | None (ADD a current-truth banner, a Terminology section, and a centralized fail-loud table — additions, not corrections).                                                                                                                                                                                                                                                |
| STATE.md — bare "GUI-equivalent" wording (Q13/Q20)                                               | `:178`, `:320`, `:584` use "GUI-equivalent" / "generalizes the mode … at a second site".                                                                                                                                                                                                                        | `:584` qualified to "a second site"; surrounded by explicit backlog; per-transaction gate aborts every other uilist (`src/ui.cpp:933`). Bound inline to the level-4 backend-input sense (`:184-186`). No arbitrary-menu abstraction implied.                                                                                                                       | **Accurate**                                           | None. The new Terminology section mitigates standalone misreads.                                                                                                                                                                                                                                                                                                         |
| Generic `popup()`/`popup_getkey`/`PF_GET_KEY`/`ANY_INPUT` remain aborted (Q2/Q4) — absence claim | `ARCOPOLIS_STATE.md:595-600` "Still backlog … none are implemented yet".                                                                                                                                                                                                                                        | `src/output.cpp` `popup()`/`popup_getkey()` build a `query_popup` but never arm a `query_popup_transaction`, so `query_once` still test_mode-aborts (`src/popup.cpp:277-279`). Grep `query_popup_witness_guard` over `src/*.cpp` → exactly one engine site (`src/iexamine.cpp:1427`).                                                                              | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Renderer-neutral / no-window comments (Q19)                                                      | `src/ui.cpp` + `src/popup.cpp` "creates NO curses window and calls NO render primitive in any build".                                                                                                                                                                                                           | `src/ui_manager.cpp:328` `test_mode` early-return; newwin skipped under the gate `src/ui.cpp:638-643`; pinned by unit tests.                                                                                                                                                                                                                                       | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Script vs one-shot scope (Q5/Q6/Q7)                                                              | run-script rejects `NEW_PICKUP_MENU=true` (exit 6) and a `pickup` with no `prompt_answers`; one-shot `--arcopolis-command pickup` rejected (exit 6); `is_live_only_command("pickup")`.                                                                                                                          | All cited and symmetric with live mode; `unsupported_command`→exit 6 (`src/arcopolis_command.cpp:255-256`); `ARCOPOLIS_STATE.md:229-231`, doc 36:129.                                                                                                                                                                                                              | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Non-live "no answer channel" supersession (Q8)                                                   | docs 30/31/35 banners; doc 36:129 / `ARCOPOLIS_STATE.md:230` scope "no answer channel" to one-shot.                                                                                                                                                                                                             | Every surviving "no answer channel" statement is Spike-16-bannered or correctly one-shot-scoped (one-shot genuinely has none). No unqualified "non-live has no channel" survives.                                                                                                                                                                                  | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Script fail-loud answers (Q9)                                                                    | `record_script_prompt_failure` → `script_prompt_failed` (exit 13); per-reason logging; first-failure-wins.                                                                                                                                                                                                      | Missing/wrong-kind/title-mismatch/out-of-range/cancel-of-noncancelable/unused all fail loud (`script_prompt_failed`→13, `src/arcopolis_command.cpp:269-270`); none returns a silent default.                                                                                                                                                                       | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Legitimate cancel vs fatal loop-exit (Q10)                                                       | comment "// legitimate cancel -> resolve serves the loop-exit QUIT"; "Amendment 1: prompt_failed precedes any engine loop-exit action".                                                                                                                                                                         | Cancelable cancel returns `nullopt` with no failure; fatal paths set session failure+done; first-failure-wins prevents a second prompt being misread as a user cancel.                                                                                                                                                                                             | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Disabled-entry consistently fail-loud (Q11)                                                      | call-site refuse `src/pickup.cpp:285-288`; resolver backstop reason `disabled_entry_unsupported` `src/arcopolis_backend_input.cpp:817`; unit test.                                                                                                                                                              | Defense-in-depth; unit refuses without asking the client and serves QUIT. **REFUSE-ONLY: no fixture/regression drives a disabled entry**; the level-4 claim is self-bounded to all-enabled.                                                                                                                                                                        | **Accurate (coverage gap disclosed)**                  | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Multi-tick resumed pickup consistently backlog (Q12)                                             | `src/pickup.cpp:208-211` orphaned-secondary report + CANCEL; reporter sets NO outcome; `ARCOPOLIS_STATE.md:228-229,:599`.                                                                                                                                                                                       | Consistent in code/docs; coverage by proxy only (in-memory reporter call), honestly disclosed.                                                                                                                                                                                                                                                                     | **Accurate (coverage gap disclosed)**                  | None.                                                                                                                                                                                                                                                                                                                                                                    |
| docs 30/31/32/34/35 supersession banners & corrected citations (Q14/Q15) — control               | docs 30/31/32 carry dated banners; doc 32 flags the popup.cpp 269→277 move; doc 34:66 cites `:933-937`; doc 35:49,301 cite `:277-279`.                                                                                                                                                                          | Match the current tree. Model of correct supersession discipline; confirm the legacy `:918`/`:269` citations elsewhere are the drifted ones.                                                                                                                                                                                                                       | **Accurate**                                           | None.                                                                                                                                                                                                                                                                                                                                                                    |
| Older chronological-record docs with bare drifted citations (Q14)                                | docs 07/15/25/26/30/31/32 cite `:269`/`:918` etc.                                                                                                                                                                                                                                                               | All are historical chronological-record docs (not current-truth pages). Drift, not behavioral error; corrected ranges live in the tree and docs 33–35.                                                                                                                                                                                                             | **Superseded (historical record — leave as-is)**       | None. Per supersession discipline these keep their as-written numbers; only current-truth surfaces (STATE.md, doc 33's "current tree" block) need bumping.                                                                                                                                                                                                               |
| Centralized fail-loud table absent (Q16) — structural gap                                        | `ARCOPOLIS_STATE.md` scatters triggers/exit codes across `:201`,`:229-233`,`:595-600`, table `:318-326`; no single Known-unsupported/fail-loud table.                                                                                                                                                           | Not a false claim; a structural gap the task asked to flag.                                                                                                                                                                                                                                                                                                        | **Needs follow-up (editorial)**                        | ADD a consolidated table to STATE.md (done below).                                                                                                                                                                                                                                                                                                                       |

## What Arcopolis supports today (witness-scoped, level 4 = backend-input + engine)

"Supported" = driven at `AGENTS.md` **level 4** (registered backend inputs consumed by the engine's own
active input loop; the engine mutates state) **for a specific witnessed shape**. None is visual/frontend
equivalence — every path creates no curses window and calls no render primitive.

- **Old `"PICKUP"` multi-select item menu** — `NEW_PICKUP_MENU=false`, every exposed entry
  `enabled:true`, single- or multi-select. The gated pre-loop block exposes the real `stacked_here`
  entries; the UNMODIFIED engine loop consumes the served `[DOWN×K, RIGHT, …, CONFIRM]`; the engine's
  `pickup_activity_actor` performs every transfer. Gate `backend_pickup_transaction_active()`
  (`src/pickup.cpp` ~`:761`); `ARCOPOLIS_STATE.md:177-186`. Live **and** (Spike 16) non-live
  `--arcopolis-run-script`.
- **Vehicle-source `"Get items from where?"` uilist** — exactly two always-enabled entries
  (cargo/ground). Driven only when `backend_pickup_transaction_active() &&
  backend_uilist_prompt_available()`; arms a uilist transaction, serves registered `UILIST` actions
  through `input_context("UILIST")::handle_input`; the engine sets `amenu.ret`. `src/pickup.cpp`
  (~`:1370-1409`); `ARCOPOLIS_STATE.md:204-213`. No channel → fail-loud. **Witness scope (doc 38):** only
  the **ground** branch (choice 1) is driven to a consequence — every Scenario-H sub-gate answers ground
  (served `[DOWN, CONFIRM]`) and asserts the ground count drops (`prompt_menu_regression.ps1:713-716`);
  the **cargo** branch (choice 0) is exposed as a real entry but is never selected or mutation-witnessed.
- **Secondary capacity/wield/spill uilist (`handle_problematic_pickup`)** — **bounded to all-enabled
  entries** (witnessed: single WIELD on the blanket — `ArcopolisTest` Scenario E; WEAR+WIELD = 2 on
  `jacket_leather` — `ArcopolisCapacityTest` Scenario J). Reuses the 13B machinery unchanged. Drive gate
  `src/pickup.cpp:193-194`, resolve `:289`, query `:292`; `ARCOPOLIS_STATE.md:236-242,:248-250`.
  Disabled-entry shape is REFUSED/force-cancelled (`:285-288`), not driven. **Witness scope (doc 38):** the
  WIELD consequence is witnessed by the engine's own `"Wielding <item>"` message (emitted inside `u.wield`)
  plus the item leaving the ground (`prompt_menu_regression.ps1:509,525`); no snapshot field asserts the
  resulting weapon slot directly (the export carries no wielded-weapon field). EMPTY/SPILL branches are
  unwitnessed.
- **Deployed-furniture take-down `query_yn`** — exactly **one** call site (witness
  `examine_deployed_furniture_take_down`), 2 entries YES/NO, cursor on NO, cancelable=false. Un-abort
  armed by the single guard `src/iexamine.cpp:1427`; resolved under `backend_query_popup_mode_active()`;
  served `LEFT`/`CONFIRM` through `input_context("YESNO")`. `ARCOPOLIS_STATE.md:260-277`. **Every other
  query_yn still aborts.**
- **Non-live `--arcopolis-run-script` replay of all four classes** — a command step's declared
  `prompt_answers` feed the **same** `backend_resolve_*` machinery + input loops as live; only the
  transport differs (`src/arcopolis_script.cpp` installs `script_pickup_prompt`/`script_uilist_prompt`/
  `script_query_popup_prompt`). `ARCOPOLIS_STATE.md:215-234`.
- **Planar move + examine-targeting (the ONE genuine frontend-surface claim, Spike 11B)** — a 3×3 d-pad
  - click-to-move reaching all eight neighbors; examine in 8 planar directions + `here`. Explicitly NOT
    a claim about reproducing every GUI mouse/key affordance, vertical move, or prompt/menu protocols
    (doc 29; `ARCOPOLIS_STATE.md:410`). **Equivalence-sense caveat (doc 38):** unlike the four prompt
    classes above, `move` itself is NOT backend-input (sense-1) level 4 — its `action_id` is injected as a
    bare top-level action at `src/handle_action.cpp:1778-1779` and never enters
    `input_context::handle_input`; it is engine/frontend-equivalent (sense 2/3) and raises no prompt. Only
    the examine **direction-chooser** sub-prompt is sense-1 level 4 (served through `handle_input` via
    `src/input.cpp:941-947`); acting on examine's downstream target menus is not driven (they auto-cancel).

## What fails loud / is unsupported (centralized, leaf-cited)

Every unsupported path is **fail-loud** (typed error + nonzero exit) or an **honest marked partial** —
never a silent _fake success_. **One caveat (doc 38):** this guarantee covers fabricated success, NOT every
prompt. An unguarded `query_yn` reachable through the **supported** `examine` verb (only the
deployed-furniture take-down is guarded) silently defaults to NO — unmarked, exit 0 — at
`src/popup.cpp:277-279` → `src/output.cpp:748`. Nothing mutates (so it is not a fake success), but it is a
silent prompt-default; no current fixture witnesses it.

| Trigger                                                                                       | Behavior                                                                                      | Exit                          | Where (current tree)                                                                  |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------- |
| `pickup` under `NEW_PICKUP_MENU=true` — live                                                  | reject pre-flight, `unsupported_command`                                                      | 6                             | `src/arcopolis_live.cpp`                                                              |
| `pickup` under `NEW_PICKUP_MENU=true` — run-script                                            | post-load reject                                                                              | 6                             | `src/arcopolis_script.cpp`                                                            |
| one-shot `--arcopolis-command pickup` (no answer channel)                                     | reject pre-flight                                                                             | 6                             | `src/arcopolis_export.cpp`; `is_live_only_command` `src/arcopolis_command.cpp:95-101` |
| `--arcopolis-run-script pickup` with NO `prompt_answers`                                      | reject                                                                                        | 6                             | `src/arcopolis_script.cpp`                                                            |
| vehicle/secondary uilist with a transaction but NO uilist channel                             | marked partial, CANCEL                                                                        | 13 (run-script)               | `src/pickup.cpp:195-198`                                                              |
| secondary capacity uilist with ANY disabled entry                                             | refuse (`scrollby` would mis-navigate); marked partial; backstop `disabled_entry_unsupported` | 13 (run-script)               | `src/pickup.cpp:285-288`; `src/arcopolis_backend_input.cpp:817`                       |
| multi-tick resumed orphaned secondary                                                         | report marks, sets NO outcome, CANCEL                                                         | — (marked)                    | `src/pickup.cpp:208-211`                                                              |
| scripted answer missing/wrong-kind/title-mismatch/out-of-range/cancel-of-noncancelable/unused | `script_prompt_failed` (first-failure-wins)                                                   | 13                            | `src/arcopolis_backend_input.cpp`; `src/arcopolis_command.cpp:269-270`                |
| generic `popup()`/`popup_getkey()`/`PF_GET_KEY`→`ANY_INPUT` (never arms a transaction)        | `query_once` test_mode abort `{false,"ERROR",{}}`                                             | — (aborted)                   | `src/output.cpp`; `src/popup.cpp:277-279`                                             |
| any `query_yn` ≠ the deployed-furniture witness (incl. via the supported `examine` verb)      | test_mode abort → **silent NO, unmarked**                                                     | 0 (silent — see caveat above) | `src/popup.cpp:277-279` → `src/output.cpp:748`                                        |
| any other `uilist` (cata_test, `inventory_selector`, computer, NPC dialogue)                  | test_mode abort → `UILIST_ERROR`                                                              | —                             | `src/ui.cpp:933-937` (gated on per-transaction `backend_ui_mode_active()`)            |

**Still backlog (no driving claim):** vertical `move` (`<`/`>`); explicit `open`/`close`/`smash`;
per-unit pickup quantity (whole-stack only); nested-container parent/child mark propagation (exposed but
**unexercised**, `src/pickup.cpp:1107-1123`); NPC talk/attack/swap; monster menus; computer use; the
examine auto-pickup tail (still ESC-cancels, `ARCOPOLIS_STATE.md:561`); the `inventory_selector`
(`NEW_PICKUP_MENU=true`); multi-tick resumed-activity secondary prompts; generic `popup()`/`query_popup`
families. (`ARCOPOLIS_STATE.md:595-600`; doc 36:129-136.)

## Why the old pickup menu is a legacy witness

The `"PICKUP"` menu is an `input_context`-based loop in the OLD pickup path. BN routes pickup to it only
when `NEW_PICKUP_MENU=false`. It was the first prompt class proven (Spike 12A) precisely because it is a
simple, stable `input_context` loop the engine still consumes unchanged — an ideal first witness. It is a
**legacy** witness: BN's default and forward direction is the `inventory_selector`
(`NEW_PICKUP_MENU=true`), which the backend deliberately fails loud on today. The PICKUP menu proves the
mechanism; it is not where real play is heading.

## On NEW_PICKUP_MENU / inventory_selector — a backlog candidate, NOT a committed next step

`inventory_selector` is the modern menu BN uses for pickup when `NEW_PICKUP_MENU=true`. It is a
**different** UI mechanism (not the old `input_context("PICKUP")` loop), so driving it would need its
**own** gated un-abort at its call site plus a witnessed registered-input path, upholding the
renderer-neutral invariant (`AGENTS.md:56`). It is one notable item on the backlog — the old `"PICKUP"`
menu is a legacy witness, and `inventory_selector` is the menu real play uses — and today it is
centralized **fail-loud** (exit 6) in both live and script paths, symmetric, with no silent _fake-success_
path to regress (the one silent prompt-default — an unguarded `query_yn` via `examine` — is documented in
doc 38). **Whether it is the next spike — versus open/close/smash, NPC interaction, computer UI, richer
export, or something else — is an open product/architecture decision this audit does NOT settle.** What
the audit establishes is only that the baseline is honest enough that _any_ of these can be stated at the
correct equivalence level from the start.

## Why frontend visual equivalence ≠ backend-input equivalence

A future Arcopolis frontend is separate, graphical, and mouse-first (`AGENTS.md:25-33`). The backend
proves the player's **choices and consequences** flow through the engine's own input loop — not that any
pixels match. The backend renders nothing. So "the backend drives the secondary capacity uilist at level
4" means the engine consumed served `DOWN×K, CONFIRM` and mutated activity state; it does **not** mean a
frontend showing WEAR/WIELD as buttons has been validated. Frontend equivalence is a separate, later
claim — scoped today only to the planar move/examine surface (Spike 11B, doc 29).

## Corrections made by this audit (doc/comment only; no behavior change)

1. **`docs/arcopolis/28_GUI_EQUIVALENCE_AUDIT.md`** — added a dated, scoped supersession banner: the
   all-enabled secondary capacity uilist, the vehicle-source uilist, and the deployed-furniture query_yn
   are now driven at level 4 (13B/14/15); force-cancel/fail-loud retained for disabled-entry/no-channel/
   multi-tick; the audit standard and the `NEW_PICKUP_MENU` rows are untouched.
2. **`docs/arcopolis/ARCOPOLIS_STATE.md`** — bumped the two drifted citations `src/ui.cpp:918`→`:933-937`
   and `src/popup.cpp:269`→`:277-279` (numbers only); added a current-truth banner, a Terminology
   section, and a centralized Known-unsupported/fail-loud table.
3. **`docs/arcopolis/33_SPIKE13B_BACKEND_DRIVEN_UILIST.md`** — caveated its "current tree" source-audit
   block (its `src/ui.cpp` numbers pre-date PR #40's newwin-skip insertion; current gate is `:933-937`).
4. **`AGENTS.md`** — corrected the stale `ArcopolisTest` fixture parenthetical at `:191`: that fixture is
   now the Spike-14 **driven single-entry WIELD** secondary-capacity witness (Scenario E), not a
   force-cancelled "rejected-items" witness. (The workflow's automated first-pass synthesis had marked
   this "no edit"; a leaf re-read of `prompt_menu_regression.ps1:447-456` showed it stale — recorded here
   so the override is visible.)
5. **`docs/arcopolis/prompt_menu_regression.ps1`** — tightened the one-line header "GUI-equivalent" →
   "level-4 (backend-input)" (body was already precise).

**No code comment or test name was found to OVERCLAIM scope.** The generic-sounding test titles are
accurate for what they assert structurally; their bodies and STATE.md scope them. The seam-code
reviewer's flag on `arcopolis_backend_input.h` ("`enabled` reserved") is a low-severity comment-precision
note, not an overclaim of support, and is left as-is.

## Follow-up recommendations

- **Multi-tick resumed-activity secondary-prompt fixture** — currently proxy-only (in-memory reporter
  calls), honestly disclosed. A real resumed-tick fixture would move it from "marked, not silent" to
  "witnessed." Out of this audit's scope.
- **Disabled-entry / SPILL / EMPTY secondary-capacity fixture** — the disabled path is unit-refused but
  no fixture drives it; a witness would let the all-enabled bound be relaxed deliberately rather than by
  necessity. Out of scope.
- **Nested-container parent/child pickup witness** — `src/pickup.cpp:1107-1123` is exposed but
  unexercised; a container-with-child-entries fixture would close it.

## Ready baseline for the next prompt-class exploration (whatever it turns out to be)

The prerequisites for the _next_ prompt-class exploration — **target undecided** — are in place and
honest:

- The four driven classes are witness-scoped, **per-transaction gated**, and **renderer-neutral** — the
  mechanism generalizes by reuse, not by a general UI abstraction (`ARCOPOLIS_STATE.md:583-591`).
- Every unsupported class is centralized **fail-loud**, so there is no silent _fake-success_ path to
  regress (one silent prompt-default — an unguarded `query_yn` via the supported `examine` verb — does
  exist; doc 38).
- Terminology is pinned (backend-input vs engine vs frontend), so any new claim is stated at the correct
  level from the start.
- No current doc implies a general arbitrary-menu abstraction, so the next spike begins from an honest
  baseline.

`inventory_selector` (`NEW_PICKUP_MENU=true`) is **a** candidate — it is the menu real play uses and it
already fails loud cleanly — but it is **not** designated the canonical next step; the next direction is
an open decision (it might well be something else). Whatever is chosen, the proven shape is the same: a
new gated un-abort at that call site, a witnessed registered-input path, upholding `AGENTS.md:56`'s
no-window invariant, with the existing fail-loud retained until the path is proven.
