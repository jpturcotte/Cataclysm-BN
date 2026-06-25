---
name: arcopolis-build-from-approved-plan
description: Implementation skill for Arcopolis (Cataclysm-BN simulation-backend) work, used ONLY after the user approves a plan. Use when the user says "approved, build it", "go ahead with the plan", "implement the approved plan", or "Phase 2 BUILD". Performs the smallest change consistent with the approved equivalence claim and witness, preserves fail-loud behavior and non-goals, updates only the minimum tests/regressions/docs, and runs the narrowest relevant validation. Do not use for planning (use arcopolis-claim-plan) or review (use arcopolis-red-team-review).
---

# Arcopolis Build From Approved Plan

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. Use this only after a
plan is approved. If no approved plan exists, stop and run `arcopolis-claim-plan`.

## Workflow

1. Re-state the approved plan, the equivalence claim, and the witness in one or two
   lines. If the work has drifted from what was approved, stop and re-plan. Do not
   reopen strategy mid-implementation unless source inspection contradicts the approved
   plan or the approved witness becomes impossible — then stop and return to planning.
2. **Reframe drift check.** After restating the plan, ask whether source inspection while
   implementing has revealed a DIFFERENT decision axis than the approved plan assumed — a
   different route, downstream consumer, native-authority class guess, active mechanism,
   witness, stop condition, or scope — or a derived build-time consequence such as a
   different equivalence level or an audit-only result. (An **orthogonal reframe** of this
   kind changes the axis, not the size of the change; the class guess is named explicitly
   because Spike 25 was a class drift — display-D masquerading as predicate-C — and build is
   the last line before code is written.) If YES on any axis, STOP and return to planning
   (`arcopolis-claim-plan`); do not silently rebuild around the new frame, and do not soften
   the drift into an optional note — a graded drift is a STOP, reported as graded. If NO, do
   not reopen strategy — build the smallest approved change.
3. Implement the **smallest** change consistent with the claim. Match surrounding
   code; follow the C++23 conventions in AGENTS.md (trailing returns, `auto`,
   `std::ranges`/`std::views`, options structs, designated initializers).
4. Preserve every non-goal and all fail-loud behavior.
5. Add/update only the minimum tests/regressions/docs the witness needs.
6. Run the narrowest relevant validation (see below) and report it honestly.
7. State whether the witness proves the claim or forces a downgrade. A downgrade is a
   reportable result, not a failure to hide.

## Guardrails

The fidelity rule is that backend _input_ behavior is the spec, so equivalence comes
from driving real registered inputs through the engine's own active loop — never from
reproducing the end state by a shortcut.

- No direct simulation mutation (world, inventory, item stacks, activity, or
  menu-selection structures) except by existing engine code reached through the real
  input path.
- Do not bypass `game::handle_action()` / `game::do_turn()` when the claim needs them.
- Do not force a selector/menu return value or edit prompt state directly.
- No broad prompt/menu support; no generic raw BN action passthrough unless the
  approved plan says so explicitly.
- Each served UI category is gated on its OWN per-transaction predicate (e.g.
  `arcopolis::backend_uilist_transaction_active()` for UILIST,
  `arcopolis::backend_query_popup_transaction_active()` for query_popup). A new
  category needs its own new gate + begin/resolve/end + RAII guard — never reuse a
  sibling family's gate. See the invariant block atop `src/arcopolis_backend_input.h`.
- Headless backend creates no curses window and calls no render primitive in any
  build. Run data-population (`setup()`/`filterlist()`) but skip window creation —
  `catacurses::newwin` is the real `::newwin` in the curses build and is fatal before
  `initscr`.
- No broad refactor or C++23 modernization beyond the touched lines.
- No fixture/baseline changes unless they are explicitly part of the approved plan.
- Don't rewrite historical `NN_SPIKE*.md` docs; update current-truth docs
  (`ARCOPOLIS_STATE.md`) only.
- A counterexample/divergence state named in the plan must be EXERCISED by the
  witness, not just asserted. For a predicate / goal-fit claim, the witness must be
  the engine-real-path behavioral one the equivalence level demands — a Catch2 test
  over a contrived structure proves backend logic, not engine equivalence (cf. the L4
  "Catch2 alone does not prove" rule). If exercising the divergence needs a fixture
  that does not exist (e.g. a nested-container entry), the claim is NOT proven this
  session — downgrade and file the defect; never ship the predicate goal on a
  happy-path witness.

## Validation — use the narrowest proof

- Pure parser/command/helper/guard change → Catch2 `[arcopolis]` or the specific test
  (sufficient on its own).
- Engine behavior → one selected fixture/script PowerShell regression (run with
  `pwsh`, not `powershell` — 5.1 mishandles BOM-less UTF-8 and causes phantom gate
  failures).
- Prompt/menu L4 support → transcript/path witness through the real loop PLUS a
  negative fail-loud adjacent check; Catch2 alone does not prove prompt/menu L4.
- Docs-only audit → no build; state explicitly that there is no behavior change.

Format touched C++ before building:
`& C:\dev\astyle\bin\AStyle.exe --options=.astylerc -n <files>`.
