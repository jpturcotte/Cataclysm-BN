---
name: arcopolis-upstream-sync-seam-audit
description: Specialized audit skill for Arcopolis after an upstream Cataclysm-BN sync/rebase, or when reviewing a sync PR. Use when upstream was merged/rebased onto the arcopolis branch, or when recurring collision files changed upstream — main.cpp, handle_action.cpp, input.cpp, game.cpp, pickup.cpp, ui.cpp, popup.cpp. Verifies the Arcopolis seams survived the merge (CLI flags, arg_handler count, input-branch placement, do_turn clean-park gating, per-transaction gates) and lists the smallest regressions to run as proof.
---

# Arcopolis Upstream-Sync Seam Audit

Read `AGENTS.md` (Repository layout) and `docs/arcopolis/ARCOPOLIS_STATE.md` first;
see `docs/arcopolis/41_UPSTREAM_SYNC_MAP_AUDIT.md` for the recurring collision map.

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

## Output

- Per point: intact / drifted / broken, with the `file:line` evidence.
- The smallest set of local fixture regressions / Catch2 tests to run as proof (run
  PowerShell regressions with `pwsh`, not `powershell`).
- For syncs touching engine APIs or Arcopolis-touched translation units, distrust stale
  incremental/ccache greens — do the smallest CLEAN compile needed to prove the touched
  seam still builds (doc 41 records a real stale-ccache false green after the map
  migration).
- Any seam that needs manual re-resolution before the sync is trusted.
