---
name: arcopolis-prompt-ui-boundary
description: Specialized skill for the highest-risk Arcopolis surface — prompt/menu/input-loop work in the Cataclysm-BN simulation backend. Use when touching input_context::handle_input(), uilist::query(), query_popup/query_yn, the old PICKUP path, NEW_PICKUP_MENU/inventory_selector, prompt answers, unexpected-prompt handling, or fail-loud behavior. A supported prompt path needs L4 evidence; an unsupported prompt must fail loud, because a silent default is false success. Pair with arcopolis-claim-plan (planning) and arcopolis-red-team-review (review).
---

# Arcopolis Prompt / UI Boundary

Read `AGENTS.md`, `docs/arcopolis/ARCOPOLIS_STATE.md`, and
`docs/arcopolis/40_SPIKE19_BACKEND_UI_BOUNDARY.md` first.

This is where equivalence is most fragile (Spikes 18, 20, 21). A served prompt must
answer through the engine's real active loop; an unserved prompt must abort loudly so
a silent NO/CANCEL/QUIT can never read as engine auto-resolution.

## Answer before writing code

1. Is this a witnessed **supported** transaction, or an **unexpected unarmed** prompt?
2. If supported:
   - which per-transaction gate is armed? (e.g.
     `backend_uilist_transaction_active()`, `backend_query_popup_transaction_active()`)
   - which active engine loop consumes the registered actions?
   - which real engine caller consumes the result?
   - what transcript proves it end to end?
3. If unsupported:
   - how does it fail loud at the abort site?
   - how is a silent NO / CANCEL / QUIT prevented from looking like success?
4. Which adjacent prompt classes stay unsupported? (name them)
5. What wording must docs avoid? (no "supports prompt class" / "supports inventory
   selector" beyond the one proven witness)

## Invariants

- Each served category gets its OWN per-transaction gate + begin/resolve/end + RAII
  guard. Never widen a gate to session scope; never reuse a sibling family's gate.
  See the served-category + invariant block atop `src/arcopolis_backend_input.h`.
- Headless: run data-population but create NO window and call NO render primitive in
  any build. `catacurses::newwin` is the real `::newwin` in the curses build and is
  fatal before `initscr` — the tiles-only regression can never witness that, so uphold
  it by construction, not by test.
- An armed transaction may pierce a `test_mode` abort only when explicitly armed and
  consumed by the real loop; an unarmed prompt FAILS LOUD at the abort site and must
  not be treated as engine auto-resolution.
- The one documented silent prompt-default debt (an unguarded `query_yn` via `examine`,
  noted in `ARCOPOLIS_STATE.md`) is NOT a success witness: do not add new silent
  defaults, do not treat the known one as supported behavior, and do not broaden claims
  around it.

## Negative witnesses (include where feasible)

- existing witnessed paths still pass;
- an unarmed prompt/menu fails loud;
- ordinary non-Arcopolis `test_mode` behavior is unchanged;
- unsupported `INVENTORY` / `inventory_selector` stays fail-loud unless the approved
  plan is exactly one narrow witness;
- no generic prompt-class support is claimed.
