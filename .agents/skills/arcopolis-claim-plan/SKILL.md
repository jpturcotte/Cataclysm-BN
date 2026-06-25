---
name: arcopolis-claim-plan
description: Plan-only skill for non-trivial Arcopolis (Cataclysm-BN simulation-backend) coding tasks. Use BEFORE editing whenever the user asks for a spike plan, implementation plan, public-API-shape decision, source-backed feasibility audit, or "run this as plan/build" for an already-narrowed candidate impulse or Task Statement Card. Broad roadmap/options/"what should we do next?"/"what would the design look like if X?" prompts route to arcopolis-design-explore first. Inspect the repo, classify the equivalence claim, name the active engine mechanism, choose the smallest witness, map impact, and STOP before editing. Do not use to implement an already-approved plan (use arcopolis-build-from-approved-plan) or to review existing work (use arcopolis-red-team-review).
---

# Arcopolis Claim Plan

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first — they hold the
non-negotiable fidelity/equivalence rules and the live capability state. This is
inspection and planning only.

Do not edit files. Do not implement. Stop at the plan and wait for approval.

## Incoming Task Statement Card

If the incoming task statement is a Task Statement Card from `arcopolis-design-interrogate`:

- a `CLASS UNVERIFIED` flag in Open unknowns is a mandatory resolution point at the
  "Consumer + native mechanism" step (item 4) — not a passable warning. Do not advance
  past that step until the consumer is anchored to a named engine caller or observing
  surface. If it cannot be resolved, stop and output `AUDIT ONLY` with the same
  inspection-guidance format `arcopolis-design-interrogate` uses.
- a `FALSIFICATION UNKNOWN` flag must be resolved before any witness is chosen (item 5) —
  name the observable behavioral divergence first; an unfalsifiable claim does not get a
  witness.
- an `External-seal required: YES` card (any possession / mission / objective / state-check
  / Stage-blocking goal) is a HARD BLOCK on a Stage-blocking witness until an INDEPENDENT
  check clears it — a human "equivalent to WHAT?" GUI-equivalence confirmation or a
  cross-model adversarial review (`arcopolis-red-team-review` / `/code-review ultra` run by
  a different reasoner). A same-model in-loop re-read does NOT clear it: the canonical
  Spike-25 failure was caught only from outside the loop, and the in-loop gates scored 0%.

A card carrying no blocking flag still has its consumer re-derived at item 4 — the
native-consumer classification, the predicate body-read at `file:line`, AND a three-way
scope comparison (the card's `Goal-required scope` vs the cited `Authority scope` vs the
exported/surface reach): a real predicate of the WRONG scope (e.g. on-person `set_has_items`
for a goal needing `MGOAL_FIND_ITEM`'s `crafting_inventory()` reach) is rejected, not only a
flat surface against a recursing body. If item 4 re-derives the incoming card as possession
/ mission / objective / state-check / Stage-blocking, SET `External-seal required: YES`
immediately — even if the card omitted the flag or marked it `NO`; the external-seal block is
DERIVED from claim-plan's own re-read, never trusted from the card. But this item-4
re-derivation is itself an in-loop SAME-MODEL floor: a re-derived `External-seal required:
NO` is a floor pass, not proof that no abstraction-routed possession/predicate domain
exists. So when the goal is possession / mission / objective / state-check ADJACENT but item
4 re-derived `NO`, do NOT trust that `NO` — set `External-seal required: YES` and route the
blind external (human / cross-model) check anyway; downgrade to `NO` only after that
independent reader confirms no predicate consumer exists. The card's class,
mechanism, and scope are the interrogator's CLAIMED values, not findings, so item 4 runs for
every observation/predicate card regardless of which flags are present; the card only lets
the plan OPEN faster, it does not discharge item 4. Absent a card, plan as normal.

## Plan-frame sanity check

Run this once after opening the card (or, absent a card, after fixing the impulse's frame)
and BEFORE witness planning (item 5). It is a frame-consistency check, NOT a reopening of
options: with a Task Statement Card present, do not reopen broad directions — that belongs
to `arcopolis-design-explore`.

An **orthogonal reframe** changes the decision _axis_, not the size of the task, and must
state what it changes (route, downstream consumer, native-authority class guess, active
mechanism, witness, stop condition, or scope). Here you are not generating one — you are
checking that the card's frame still matches the downstream consumer and the planned witness
on each axis:

- display (D) vs predicate (C) vs raw simulation state (S);
- action (A) vs prompt/menu (B);
- implementation vs audit-only;
- same final state vs same active engine mechanism (L2/L3 vs L4).

If the check CONTRADICTS the card — the consumer the source names sits on a different axis
than the card claims (e.g. a card framed display-D for a goal an engine predicate-C
consumes, the Spike-25 shape; or a card claiming L4 for an action injected at the
`handle_action` seam, never consumed by `input_context::handle_input`) — STOP; do not paper
over it in the plan. For a wrong class/consumer, tell the user to run
`arcopolis-design-interrogate` (it is user-invoked) to re-derive it; for a suspected wrong
frame to adjudicate, route to `arcopolis-red-team-review`. If the frame SURVIVES, continue
directly to the Required output below; this check produces no options brief.

## Why plan-first

Arcopolis fidelity is defined by _backend input behavior_, not by final state, so the
expensive mistakes are locked in before any code is written: claiming the wrong
equivalence level, witnessing against the wrong mechanism, or generalizing one path
into prompt-class support. Surfacing the impact map and false-green risks up front is
what keeps the change small and the review cheap.

## Triage mode (already narrowed only)

Broad roadmap/options prompts belong to `arcopolis-design-explore`, not this skill. If the
user asks "what should we do next?", "what are the possible next steps?", "what would the
roadmap look like?", "what would the design look like if I wanted X?", "push back and give
me alternatives", or any equivalent broad strategy question with no single actionable
impulse, stop and route to `arcopolis-design-explore` first. Do not produce a claim-plan
or Task Statement Card directly from those prompts.

Keep this skill's options/triage behavior only when the input is an already-narrowed
candidate impulse for which the downstream consumer/class is not yet derived AND no Task
Statement Card exists. A Task Statement Card from `arcopolis-design-interrogate`, or an
explicit implementation-plan request after exploration has already narrowed the direction,
MUST bypass Triage and open the plan directly: via the "Incoming Task Statement Card"
preamble when a card exists, otherwise via the preamble's own "Absent a card, plan as
normal" path (item 4 + Required output run either way). A narrowed possession / mission /
objective / inventory impulse whose engine consumer is not yet named is NOT a keep case —
tell the user to run `arcopolis-design-interrogate` first to derive the consumer (it is
user-invoked).

For already-narrowed triage, produce a sourced OPTIONS BRIEF before any plan — 3-5
candidates, each one line:

- native-authority class — A action-fidelity · B prompt/menu-fidelity ·
  C predicate-fidelity · D display-observability · S simulation-state (raw
  authoritative world state — neither a computed predicate nor a display proxy).
  Derive the class from the DOWNSTREAM consumer (what ultimately reads the surface /
  what the goal needs), not the author's framing. Item 4's three observation
  categories map straight across: engine-computed-predicate → C, display-state → D,
  simulation-state → S.
- evidence label — PROVEN / NATIVE-BN / LIKELY / UNKNOWN / NOT FOUND / NEEDS NEW SEAM /
  STAGE B (cite the source).
- unblocks / appetite — what it proves, and a rough size.

Forcing rule: a Class-C option MUST name the candidate engine call (predicate) at
selection time; a Class-D or Class-S option MUST NOT cite a predicate/possession/mission
goal (labeling a possession surface S or D to skip the predicate body-read is the
Spike-25 dodge — item 4's domain trigger still owes the read whatever the letter). The
picked option's class is binding — a later plan that answers a Class-C goal with a
display or raw-state proxy contradicts its own brief (the Spike-25 trap). The human
picks by appetite/tradeoff, not by re-deriving context.

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
   - Seam identity, not just naming: cite the LINE where that loop consumes the input
     and show your call site IS that point — not a leaf it calls before/after. Driving
     `avatar_action::move` before `do_turn` instead of inside `handle_action` names the
     loop honestly yet inverts the seam (the Spike-3 defect).

4. **Consumer + native mechanism (observation claims)** — for any OBSERVATION
   claim, classify the real consumer — display-state vs simulation-state vs
   engine-computed-predicate — and expose the NATIVE mechanism for that category,
   never a convenient JSON proxy. For the engine-computed-predicate case, NAME
   the consuming engine call and its scope, and expose THAT predicate (or its
   result) — never a consumer-side reconstruction from a partial view.
   - Domain trigger (unconditional): if the goal is possession / mission / objective /
     state-check adjacent, NAME the engine predicate that goal calls and run the
     body-read below — whatever class you assigned. The goal domain, not your label,
     decides whether the predicate-read is owed (classifying a possession surface as
     display was the Spike-25 escape).
   - Falsify from the source, don't confirm: read the predicate's engine call BODY
     (cite file:line) and state its traversal SHAPE — flat, or recursing /
     aggregating / scoped. A surface whose REACH is narrower than the body's is
     AUTOMATICALLY INSUFFICIENT — a flat surface against a recursing or child-walking
     body, OR an on-person/top-level surface against a body that aggregates or scopes
     wider (off-person, crafting reach, map tiles) — expose the predicate result.
     Treat the surface as sufficient ONLY after reading the body and confirming the
     surface's reach MATCHES it at the leaf; "I could not think of a divergence" is
     not proof there is none.
   - If sufficiency cannot be shown from the body, the claim is
     display/observation-only — downgrade it, drop the predicate goal, and SAY you
     tripped this (a Class-C goal must not be silently abandoned).

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
prompt-class support · Native-authority class (A action / B prompt-menu /
C predicate / D display / S simulation-state) · Goal-fit (sufficient-for vs
consistent-with) · Counterexample / divergence witness.

Avoid vague terms unless immediately defined: "works", "equivalent enough", "same
result", "GUI equivalent", "supports prompt class".
