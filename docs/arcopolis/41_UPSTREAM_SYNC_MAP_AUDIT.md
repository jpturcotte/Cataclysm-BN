# Arcopolis upstream sync + map/reality-bubble/mapbuffer impact audit (2026-06-19)

**Status: upstream sync, NOT a feature spike. NO new Arcopolis behavior.** This records syncing the
`arcopolis` dev branch onto current `upstream/main` and audits whether the upstream map /
reality-bubble / mapbuffer / absolute-coordinate churn broke any Arcopolis assumption. No new
gameplay, no `NEW_PICKUP_MENU=true` / `inventory_selector` support, no protocol/wire/exit-code change,
no `command -> do_turn` revival, no seam bypass, no fail-loud weakening, no new un-abort gate.

> **Equivalence level changed by this sync: NONE.** The four witnessed level-4 prompt paths stay
> level-4; everything else stays fail-loud / honest-backlog exactly as before
> ([ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md), [38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md)).
> The only goal here is to keep those claims TRUE after upstream's engine churn.

> **Citations.** Line numbers drift as the gated call sites move; **confirm by symbol name** and prefer
> the symbol over the number when they disagree.

## 1. Sync refs and model

Per the documented **mirror + rebased dev branch** model (`AGENTS.md` "Repository layout"):

| | ref | date |
| --- | --- | --- |
| previous merge-base | `fe628e7d24` (the 2026-06-10 sync, PR #26) | 2026-06-10 |
| `arcopolis` before sync | `c2bca2d8fe` (53 patches on the old base) | 2026-06-19 |
| `upstream/main` merged (new base) | `20e4cb2d24` "fix: let ear protection block screecher daze (#9577)" | 2026-06-19 |
| result branch | `arcopolis-upstream-sync-map-audit` = the 53 patches rebased onto `20e4cb2d24`, linear | 2026-06-19 |

`main` was fast-forwarded `fe628e7d24 -> 20e4cb2d24` and pushed (pure mirror; never conflicts), then
`arcopolis`'s 53 commits were **rebased** onto it on the dedicated branch. **112 upstream commits**
were absorbed. `git diff main...arcopolis-upstream-sync-map-audit` remains exactly the backend patch
set (linear; the invariant holds).

## 2. Upstream churn that lands in Arcopolis's blast radius

The wave the project flagged in advance — all present and absorbed:

| PR | what | Arcopolis relevance |
| --- | --- | --- |
| #9398 `dda6330da9` | Map function migration API start (mapbuffer +1277, submap_load_manager, overmapbuffer, new `map_functions`) | export reads map state |
| #9506 `cefac1cfc5` | Absolute migration + pathfinding (map.cpp −159, pathfinding +460, monmove/npcmove, **iexamine ±88**, new `map_utils`) | export coords + Spike 15 iexamine witness |
| #9519 `6f5fe49f7a` | Absolute Space Migrations | coords |
| #9543 `5927589293` | **Absolute Mapgen Migration + Z-Level Option Removal** | coords; fixture option staleness (§6) |
| #9559 `b0382913dc` | Absolute Backing API | touches `pickup.cpp` |
| #9479 `d31831136a` / #9447 `865cb1f0e6` | Visibility & Position Fixes / Absolute Peek Anchor | export `seen`/`pl_sees` |
| #9482 `1b79f6bee0` | Fix filter in experimental pickup menu | touches `inventory_ui` only (the NEW menu) — **not** the old `"PICKUP"` menu Arcopolis drives |
| #9518 `968b72fda3` | action-id lookup no longer aborts | seam behavior note (§5) |
| #9535 `22b1c4d4f4` | fix auto-drive | `handle_action` auto-move branch (neighbours the seam hook) |

## 3. Conflicts and how they were resolved

The conflict-risk set = {files Arcopolis modifies} ∩ {files upstream touched} = **7 files**. The rebase
**auto-merged 6 of them cleanly** (Arcopolis hooks and upstream changes lived in different regions);
**only `deno.jsonc` required a hand resolution.** Each auto-merge was then re-verified by reading the
result (a clean rebase is necessary but not sufficient).

| File | conflict | resolution (verified) |
| --- | --- | --- |
| `deno.jsonc` | **manual** | kept BOTH upstream's `build-scripts/problem-matchers` exclude + `build-scripts` include AND Arcopolis's `.claude/worktrees` exclude |
| `src/game.cpp` | auto | clean-park guard `backend_session_active() && backend_input_done() -> return false` intact, after `is_game_over()`, before `QUIT_WATCH`; `do_turn` head byte-identical so the `new_game` bootstrap-turn skip is preserved |
| `src/handle_action.cpp` | auto | backend-input branch (`backend_session_active() -> next_backend_action()`) still LEADS `handle_action_get_action`'s dispatch chain as `if / else if (u.has_destination())`; upstream only touched `pldrive`/`smash`/`sleep` (far away) |
| `src/iexamine.cpp` | auto | Spike 15 `query_popup_witness_guard` intact at the top of `deployed_furniture`; its body is upstream-unchanged and still calls the **2-arg** `take_down_deployed_furniture(pos,pos)` (upstream KEEPS that overload alongside the new 3-arg `mapbuffer&` one) |
| `src/pickup.cpp` | auto | all three gated blocks intact — Spike 12A top-level menu arm, Spike 13B vehicle-source uilist drive, Spike 14 secondary-capacity uilist drive + no-channel/orphaned/disabled-entry fail-loud fallbacks; upstream's `pick_one_up`/`do_pickup` migration is in different functions |
| `AGENTS.md` | auto | 185 insertions / 0 deletions vs the upstream base — Arcopolis sections layered on top, upstream's recent AGENTS.md edits preserved |
| `.github/semantic.yml` | auto | adds only the `arcopolis` scope; upstream's scope additions preserved |

`git diff --check` is clean; no conflict markers remain anywhere in the tree.

## 4. Map / coordinate / API impact — ONE export line adapted; everything else unchanged

The previous sync (commit `89a00c1533`) already moved the export into typed bubble/absolute space, so
most APIs Arcopolis calls are **unchanged on `upstream/main`** — **but one is not**: this wave's
absolute-coordinate / z-level migration turned `map::get_abs_sub()` from `tripoint_abs_sm` into a 2-D
`point_abs_sm` (`abs_sub` is now a `point_abs_sm` member; the bubble always spans every z-level so the
submap origin carries no single z). The export's `write_map_bounds` wrote `origin_abs_sm[z] =
get_abs_sub().z()`, which no longer compiles. **Fix (`src/arcopolis_export.cpp`):** the origin z now
comes from `ctx.levz` (`g->get_levz()`) — the z-level being exported, which already equals
`map_bounds "z"` and every exported tile's z, so the emitted value is unchanged for the single-z
snapshot. This is the **only** `arcopolis_*` source change in the sync.

| API used by `src/arcopolis_export.cpp` | upstream status |
| --- | --- |
| `Creature::bub_pos()` / `abs_pos()` (avatar, monster, npc) | unchanged (tripoint, has `.z()`) |
| `map::get_abs_sub()` | **CHANGED → 2-D `point_abs_sm`** (`map.h:1979`); export adapted to use `ctx.levz` for the origin z |
| `map::ter/furn(tripoint_bub_ms)` | unchanged (`map.h:1236/1261`) |
| `map::i_at(tripoint_bub_ms) -> map_stack` | public signature/behavior unchanged; internal storage moved to abs_ms but encapsulated (`map.h:1712`) |
| `map::inbounds / getmapsize / pl_sees` | unchanged |
| `points_in_radius(tripoint_bub_ms,int)` | unchanged (`map_iterator.h:126`) |
| `bub_to_abs(tripoint_bub_ms) -> tripoint_abs_ms` | unchanged (`map.h:2796`) |
| coordinate types `tripoint_bub_ms / _abs_ms / _abs_sm` | intact |

`src/main.cpp` was **not** touched by upstream this round, so the `std::array<arg_handler, N>`
literal replayed clean and the silent-mis-merge gotcha did not bite: upstream first_pass is still 17,
Arcopolis adds 5, the literal is **22** (hand-verified, all 5 `--arcopolis-*` flags present).

> **ccache-staleness lesson (load-bearing for future syncs).** The `get_abs_sub` break was **masked**
> on the first build: the shared cross-worktree ccache (`CCACHE_BASEDIR` + `CCACHE_NOHASHDIR`) served a
> **stale `arcopolis_export.cpp.obj`** compiled against the pre-migration header, so the export "compiled"
> while other TUs linked against the new signatures → `LNK2001/2019` (e.g. `get_overmapbuffer(std::string)`
> vs the new `get_overmapbuffer(dim_id)`, `fake_item_location::position` after `item_location.cpp` moved to
> `locations.cpp`). The real error only surfaced after `ccache -C` + `ninja clean` forced a fresh compile.
> **A clean compile — not a stale incremental — is the only valid post-sync build check.** All 9
> Arcopolis-touched TUs (`arcopolis_export`, plus the engine hooks `game`/`handle_action`/`iexamine`/
> `pickup`/`input`/`output`/`popup`/`ui`) compile clean after the fix (§7).

## 5. Protected seams re-verified

All preserved, present, and correctly placed (each read in the post-rebase tree):

- **Seam entry** — `arcopolis::next_backend_action()` leads `game::handle_action()`'s dispatch
  (`src/handle_action.cpp`), gated on `backend_session_active()`.
- **`do_turn` ownership + clean-park** — `game::do_turn` runs verbatim; the clean-park early-return is
  intact (`src/game.cpp`). The `new_game` bootstrap-turn skip (do_turn head) is upstream-unchanged.
- **Nested-input hook** — Spike 11A one-shot answer + auto-cancel guard at the top of
  `input_context::handle_input` (`src/input.cpp`); `input.cpp` was untouched upstream this round.
- **Per-transaction un-abort gates** — `backend_uilist_transaction_active()` (`src/ui.cpp`) and
  `backend_query_popup_transaction_active()` (`src/popup.cpp`, `src/output.cpp`) intact and
  witness-scoped; `ui.cpp`/`popup.cpp`/`output.cpp` were untouched upstream this round.
- **Fail-loud** — `NEW_PICKUP_MENU=true` rejects pre-flight (`unsupported_command`, exit 6) in both
  live (`src/arcopolis_live.cpp`) and run-script (`src/arcopolis_script.cpp`); one-shot pickup and
  no-answer run-script pickup still reject. None weakened.

**Behavior note — #9518** (`src/action.cpp`: `abort()` -> `return "null"`): an unknown action id no
longer hard-aborts the process. Arcopolis validates verbs -> action_ids up front
(`arcopolis_command.cpp`), so this never fires on the Arcopolis path; the change is strictly *safer*
for a headless run (a stray unknown action degrades to a no-op instead of killing the process). It
does **not** alter any Arcopolis fail-loud (those are explicit typed errors, not `abort()`).

## 6. Remaining uncertainties

- **Runtime validation** — see §7; until the build + `[arcopolis]` tests + fixture regressions pass,
  the "no behavior change" claim is **static** (textual/semantic merge review + a clean compile),
  not runtime-proven.
- **#9543 Z-Level Option Removal** — if the removed game option was persisted in the fixture worlds'
  `options.json`, loading them may emit a benign "unknown option" warning. Forward-compatible (unknown
  options are ignored), but confirm the fixture regressions still load and gate green; if a fixture
  carries a now-invalid option, note it rather than silently rewriting saved fixtures.
- **`pickup.cpp` interleave** — RESOLVED. The Spike 12A/13B/14 gated blocks auto-merged adjacent to
  upstream's `pick_one_up`/`do_pickup` absolute-coordinate migration; the clean compile confirms no
  migrated type/var leaked into a gated block (§7).
- **`origin_abs_sm[z]` faithfulness** — the `get_abs_sub()` 2-D adaptation uses `ctx.levz`. Argued
  faithful (it equals the value already reported as `map_bounds "z"`), but the snapshot/movement
  fixture regressions are the runtime confirmation that the exported bounds are sane.

## 7. Validation

Run on the post-rebase branch (VS 2022 MSVC + Ninja, `out/build/win-rel-deb`, fixtures from
`C:\dev\arcopolis-fixtures`, regressions driven with `pwsh`). **All green.**

- **Build** — `cataclysm-bn-tiles` + `cata_test-tiles`. The first build **falsely link-failed** on stale
  cross-worktree ccache objects (§4); after `ccache -C` + `ninja clean` a full cold rebuild linked **both
  exes fresh** (the `exit 1` is the cosmetic `deno docs:gen`/`applocal` post-link tail under a background
  DevShell — both `.exe`s have fresh timestamps, the documented benign tail per
  `00_WINDOWS_LOCAL_ENVIRONMENT.md`). A focused recompile of all 9 Arcopolis-touched TUs is clean.
- **Unit tests** — `cata_test-tiles.exe "[arcopolis]"` → **All tests passed (888 assertions, 139 cases)**, exit 0.
- **Fixture regressions (10/10 PASS):**
  - `movement_regression` — `move_s`/`move_se` advance `pos_abs` + tick the world; `move_n` is the
    faithful NPC no-op. (Exercises the snapshot export incl. the adapted `map_bounds`.)
  - `item_export` / `npc_export` / `monster_export` — `exports=3 pass=3`, `*_off_window=0` (every exported
    entity sits on an exported tile; the `origin_abs_sm`/bounds export is sound).
  - `script_prompt` — 4 scripted level-4 witnesses + fail-loud gates: out-of-range → exit 13
    (`prompt_failed choice_out_of_range`), **`NEW_PICKUP_MENU=true` → exit 6**.
  - `prompt_menu` — old `"PICKUP"` menu driven at level 4, secondary-capacity recover, `NEW_PICKUP_MENU` fail-loud.
  - `query_popup` — all gates (Spike 15 `query_yn` driven; non-cancelable + EOF paths).
  - `examine` — Spike 11A nested-input answer + autoselect.
  - `live_protocol` — `move_up` rejected `unsupported_command`, session survives, recovery, clean quit.
  - `client_harness` — end-to-end harness (blocked/moved/waited classification, monster fixture).
  - `frontend_prototype` — all 18 bridge gates.

The "no behavior change" claim is therefore **runtime-confirmed**, not merely static: the witnessed
level-4 prompt paths, the fail-loud guards (`NEW_PICKUP_MENU=true` exit 6), and the snapshot export all
behave as before the sync.

## 8. Behavior statement

This PR **adds no new Arcopolis behavior.** It moves the existing, witnessed backend onto current
upstream and verifies the move preserved: the protected `handle_action`/`do_turn` seam; the read-only
snapshot/transcript contract; the four witnessed level-4 prompt paths; the per-transaction un-abort
gates; and every fail-loud guard (notably `NEW_PICKUP_MENU=true`). No command, prompt class, export
field, protocol message, or exit code was added or changed.
