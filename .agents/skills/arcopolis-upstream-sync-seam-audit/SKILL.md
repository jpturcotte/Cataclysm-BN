---
name: arcopolis-upstream-sync-seam-audit
description: Specialized audit skill for Arcopolis after an upstream Cataclysm-BN sync/rebase, or when reviewing a sync PR. Use when upstream was merged/rebased onto the arcopolis branch, or when recurring collision files changed upstream — main.cpp, handle_action.cpp, input.cpp, game.cpp, pickup.cpp, ui.cpp, popup.cpp, output.cpp, iexamine.cpp, character.cpp — or when upstream moved headers into subdirectories. Verifies the Arcopolis seams survived the merge (CLI flags, arg_handler count, input-branch placement, do_turn clean-park gating, per-transaction gates, the damage tap, include paths) and that clean-merging upstream behavior changes inside relied-on engine functions are classified, then lists the smallest regressions to run as proof.
---

# Arcopolis Upstream-Sync Seam Audit

Read `AGENTS.md` (Repository layout) and `docs/arcopolis/ARCOPOLIS_STATE.md` first;
see `docs/arcopolis/41_UPSTREAM_SYNC_MAP_AUDIT.md` for the recurring collision map and
`docs/arcopolis/63_UPSTREAM_SYNC_2026_10_21.md` for the behavior-change audit pattern.

`git rerere` replays the recurring _textual_ conflicts once trained, but it does not
catch semantically-wrong silent auto-merges — especially `main.cpp`'s arg count, which
git merges silently and incorrectly even in commits that replay with no conflict
markers. Audit the seams by hand.

## Audit points

1. **`src/main.cpp`** — the Arcopolis `--arcopolis-*` CLI flags are present; the
   `<arg_handler, N>` literal equals upstream's arg count plus the Arcopolis flags AND
   the array entry count matches. Recount both after any sync that added a CLI arg.
2. **`src/handle_action.cpp`** — the backend input branch still leads
   `handle_action()`'s input-dispatch chain; no `command->do_turn` revival.
3. **`src/input.cpp`** — the nested-input hook still leads
   `input_context::handle_input( const int timeout )`; unsupported prompts still fail
   loud.
4. **`src/game.cpp`** — `do_turn` clean-park remains gated; world-tick ownership is
   unchanged; the `new_game` bootstrap-turn branch is intact (no forced extra tick).
5. **Prompt/menu surfaces (`src/ui.cpp`, `src/popup.cpp`, `src/output.cpp`,
   `src/iexamine.cpp`, `src/pickup.cpp`, and the served-category invariant in
   `src/arcopolis_backend_input.h`/`.cpp`)** — per-transaction gates are not widened;
   no new upstream UI path silently invalidates a witnessed assumption.
6. **`src/character.cpp` `Character::apply_damage`** — the Spike 27B damage tap is still
   inside the engine's own funnel (after `mod_part_hp_cur` / `character_takes_damage`),
   still gated on `backend_session_active() && is_avatar() && source != nullptr && source
   != this && dam_to_bodypart > 0`; diff the whole function body old-tip vs new-tip, not
   just the hook lines. Proof: `attacker_damage_regression`, `oneshot_damage_regression`,
   `attacker_instance_ambiguity_regression`.
7. **Moved headers / include-path drift** — upstream file moves (e.g. `map.h` →
   `map/map.h`) break Arcopolis-owned TUs silently: the rebase replays clean and only the
   compile fails. For every `#include "…"` in the Arcopolis diff (`git diff --name-only
   upstream/main HEAD -- src tests`), check the header still exists at that path; list
   renames with `git diff -M --name-status <old-base> upstream/main`. A clean compile is
   the proof.
8. **Behavior changes INSIDE relied-on engine functions that merge clean** — the
   most dangerous drift: no conflict, no compile error, different behavior. Diff the full
   bodies (old Arcopolis tip vs synced tip) of at least `game::do_turn`,
   `game::mon_info_update`, `game::check_safe_mode_allowed`, `map::pl_sees`,
   `game::vertical_move` + `suggest_auto_walk_to_stairs`, the `handle_action` movement
   case, `avatar_action::move`, `Character::apply_damage`, `query_yn`, and the options /
   submap loaders the fixtures depend on. Search the upstream log for visibility,
   safe-mode, stairs, option and save-format PRs. Classify each change per AGENTS.md
   fidelity rules:
   - **faithful new engine behavior** — the GUI now does the same thing; adapt the
     WITNESS (deployment config in the sandbox such as the `SAFEMODE=false` pin, a new
     assertion, a refreshed doc claim), never override an engine flag or state;
   - **regression** — the backend path now differs from the GUI path; fix the
     lifecycle/seam, not the behavior.
     Worked examples (2026-10-21, doc 63): the per-turn tiles visibility refresh made safe
     mode live headless at turn start (waits/moves refused, turn frozen — reads like an
     RNG all-miss) and exported `seen` true, with within-turn parity still unproven; a
     fixture NPC started fighting the witness monster (leading candidate: the per-turn
     lightmap build; cause not isolated); `suggest_auto_walk_to_stairs` dropped its
     `sees()` guard, so failed vertical moves reach an unarmed `query_yn` that must fail
     loud; fixtures without `turn_last_actualized` replay a full catch-up on load. State
     the evidence level of each classification; do not round "likely" up to "faithful".
     Run the full fixture suite to surface these, and separate causes with a scratch-pack
     probe that flips one option.

## Output

- Per point: intact / drifted / broken, with the `file:line` evidence.
- Per behavior change (point 8): PR, `file:line`, faithful vs regression, and the
  witness adaptation or fix.
- The smallest set of local fixture regressions / Catch2 tests to run as proof (run
  PowerShell regressions with `pwsh`, not `powershell`).
- For syncs touching engine APIs or Arcopolis-touched translation units, distrust stale
  incremental/ccache greens — do the smallest CLEAN compile needed to prove the touched
  seam still builds (doc 41 records a real stale-ccache false green after the map
  migration).
- Any seam that needs manual re-resolution before the sync is trusted.
