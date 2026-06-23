---
name: arcopolis-claim-plan
description: Plan-only skill for non-trivial Arcopolis (Cataclysm-BN simulation-backend) coding tasks. Use BEFORE editing whenever the user asks for a spike plan, implementation plan, public-API-shape decision, source-backed feasibility audit, "what should the agent do next", or "run this as plan/build". Inspect the repo, classify the equivalence claim, name the active engine mechanism, choose the smallest witness, map impact, and STOP before editing. Do not use to implement an already-approved plan (use arcopolis-build-from-approved-plan) or to review existing work (use arcopolis-red-team-review).
---

# Arcopolis Claim Plan

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first — they hold the
non-negotiable fidelity/equivalence rules and the live capability state. This is
inspection and planning only.

Do not edit files. Do not implement. Stop at the plan and wait for approval.

## Why plan-first

Arcopolis fidelity is defined by _backend input behavior_, not by final state, so the
expensive mistakes are locked in before any code is written: claiming the wrong
equivalence level, witnessing against the wrong mechanism, or generalizing one path
into prompt-class support. Surfacing the impact map and false-green risks up front is
what keeps the change small and the review cheap.

## Required output

1. **Task classification** — one of:
   - audit only
   - fixture/setup only
   - command parser / contract
   - native action-seam witness
   - prompt/menu level-4 witness
   - fail-loud unsupported-path correction
   - upstream-sync seam audit

2. **Equivalence claim** — state the level you will prove (definitions in AGENTS.md):
   - L1 observation only
   - L2 same final state
   - L3 same engine action / finalization path
   - L4 same registered backend inputs consumed by the same active engine input
     loop/mechanism a player would use
   - Player-action implementation defaults to **L4**. If you claim below L4, say why.

3. **Registered input + active engine mechanism** — name BOTH, separately:
   - the registered input/action the player issues — e.g. `ACTION_MOVE_UP` /
     `ACTION_MOVE_DOWN`, a `"PICKUP"`/`"YESNO"` button action, a `uilist` entry key;
   - the active engine loop/caller that consumes it — e.g. `game::handle_action()`
     through the backend input branch, `input_context::handle_input()`,
     `uilist::query()`, or `query_popup`/`query_yn`.
     A registered action (`ACTION_*`) is NOT a mechanism, and "`do_turn` finalizes it" is
     NOT a mechanism. L4 = the named registered input consumed by the named active loop a
     player would use.

4. **Consumer + native mechanism (observation claims)** — for any OBSERVATION
   claim, classify the real consumer — display-state vs simulation-state vs
   engine-computed-predicate — and expose the NATIVE mechanism for that category,
   never a convenient JSON proxy. For the engine-computed-predicate case, NAME
   the consuming engine call and its scope, and expose THAT predicate (or its
   result) — never a consumer-side reconstruction from a partial view.
   - Catch question: name the engine predicate the goal will actually call, and
     show this surface feeds it.

5. **Witness plan** — the smallest fixture/script/Catch2/doc witness:
   - what it proves
   - what it does NOT prove (witness scope)
   - false-green risks
   - Catch2 helper/contract tests prove parser, guard, or decision logic; they do NOT
     by themselves prove L4 prompt/menu equivalence — that needs a transcript/path
     witness showing the registered actions consumed by the active loop, plus scope.

6. **Impact map**:
   - exact files/functions likely touched
   - exact tests/regressions/docs likely touched
   - evidence label per item: PROVEN / NATIVE-BN / LIKELY / UNKNOWN / NOT FOUND /
     NEEDS NEW SEAM / STAGE B

7. **Stop conditions** — what discovery aborts implementation, and what must stay
   fail-loud.

## Hard rules

- Do not claim L4 from final state or a shared finalization path alone — name the
  registered inputs and the active loop that consumes them.
- Do not generalize one witnessed path into prompt-class support.
- Audit-only is a valid, successful outcome. Prefer it to a forced, unprovable
  implementation.
- No broad refactor, C++23 modernization, or framework migration (e.g. Catch2 →
  GoogleTest) as part of the plan.
- Do not recommend CI or coverage gates by default.
- Headless backend touches no curses window and no render primitive in any build.
- Do not propose implementation until the user approves the plan.

## Shared vocabulary

Claim type · Equivalence level · Active engine mechanism · Registered backend
input/action · Real engine caller · Witness · Witness scope · False-green risk ·
Fail-loud · Unsupported adjacent path · Per-transaction gate · No generic
prompt-class support.

Avoid vague terms unless immediately defined: "works", "equivalent enough", "same
result", "GUI equivalent", "supports prompt class".
