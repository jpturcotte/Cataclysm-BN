---
name: arcopolis-design-explore
description: First-stage exploration skill for broad Arcopolis strategy, roadmap, "what should we do next?", "what would the design look like if X?", pushback, and alternative-comparison questions. Use before arcopolis-design-interrogate when no single actionable impulse exists yet. Produces a sourced Exploration Brief with candidate directions, one recommendation, one anti-recommendation, intent forks, and a narrowed handoff impulse. Does not produce a Task Statement Card, implementation plan, equivalence claim, or code changes.
---

# Arcopolis Design Explore

Use this skill for broad Arcopolis strategy/design questions before there is one actionable
impulse. The output is an Exploration Brief, not a Task Statement Card and not an
implementation plan.

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. Ground every brief in the
current repo state and recent Arcopolis capability state before proposing directions. Inspect
nearby docs or source only as needed to avoid stale or invented anchors.

This workflow proves no Cataclysm-BN engine behavior. No L1-L4 engine equivalence claim
applies. Stop before Task Statement Cards, claim-plans, build steps, implementation, or code
changes.

## Routing

Run this skill when the user asks broad questions such as:

- "What should we do next?"
- "What are the possible next steps?"
- "What would the roadmap look like?"
- "What would the design look like if I wanted X?"
- "Push back and give me alternatives."
- "Which direction should we take?"

Do not run this skill when the request is already a single actionable impulse, a Task
Statement Card, an approved implementation plan, or an explicit build instruction. Point the
user to `arcopolis-design-interrogate` (user-invoked), or route to `arcopolis-claim-plan` /
`arcopolis-build-from-approved-plan`, as appropriate.

## Procedure

1. Restate the user's broad question in one sentence.
2. List current-state anchors from `AGENTS.md` and `ARCOPOLIS_STATE.md`; include specific
   existing capabilities, deferred backlog items, fail-loud constraints, or known postmortems
   that shape the exploration.
3. Produce 3-5 candidate directions. Treat a user-suggested direction as one candidate, not
   as the plan.
4. Derive native-authority guesses yourself from the downstream consumer; do not ask the
   user to choose A/B/C/D/S. Label each as `Native-authority guess`, not final class.
5. **Orthogonal reframing pass (after candidates, before the recommendation).** An
   **orthogonal reframe** changes the decision _axis_ before accepting the user's framing;
   it is not a larger or smaller version of the same task. A valid reframe must state what
   it changes — route, downstream consumer, native-authority class guess, active mechanism,
   witness, stop condition, or scope. At least one candidate OR one explicitly rejected
   framing must be orthogonal to the user's proposed direction, and must name which of those
   axes it changes. A "reframe" that changes none of
   those is the same task restated, not an orthogonal one — this is the cheap counter to
   anchoring on the prompt's framing, the pattern behind the Spike-25 miss, where "what can a
   frontend SHOW about carried items?" (display, D) was never flipped to "what engine
   PREDICATE answers possession?" (C). Do not proceed to a Task Statement Card or
   implementation from this pass. Flip the decision on one of these product-level axes:
   - product proof vs backend authority proof,
   - display surface (D) vs engine predicate (C),
   - frontend prototype vs backend witness,
   - implementation vs audit-only,
   - Stage A proof vs Stage B ambition.
6. Give exactly one recommendation and exactly one anti-recommendation.
7. Name intent forks only at the product/intent level; do not ask the user to classify engine
   authority, choose equivalence levels, or walk call paths.
8. End with one narrowed handoff impulse the user can paste into a new
   `arcopolis-design-interrogate` session (interrogate is user-invoked and requires
   per-pass user answers).
9. Explicitly state that the workflow should not proceed to implementation from this brief.

## Evidence Labels

Use only these evidence labels:

`PROVEN` | `NATIVE-BN` | `LIKELY` | `UNKNOWN` | `NOT FOUND` | `NEEDS NEW SEAM` | `STAGE B`

Label evidence honestly:

- `PROVEN`: current Arcopolis capability is documented and witnessed in current-state docs.
- `NATIVE-BN`: BN has an engine concept/mechanism, but Arcopolis has not necessarily exposed it.
- `LIKELY`: grounded by current docs/source, but not yet proven at the required surface.
- `UNKNOWN`: plausible, but the decisive source/call path is not yet known.
- `NOT FOUND`: searched or inspected and did not find the needed mechanism.
- `NEEDS NEW SEAM`: likely needs a new Arcopolis boundary/protocol/prompt family.
- `STAGE B`: useful later, but blocked by a more basic Stage A/authority question.

## Candidate Direction Fields

Each candidate direction must include:

```text
Name
Native-authority guess
Evidence label
What it would prove
What it would not prove
Likely witness type
Risk / false-green
Appetite
Next skill
```

Use `Next skill (for the user to invoke): arcopolis-design-interrogate` for the candidate
that could become the narrowed handoff impulse. Use
`Next skill (for the user to invoke): arcopolis-design-interrogate if selected` for
unselected viable candidates. Use `Next skill: defer` for anti-recommended or Stage B
directions.

## Output Shape

Produce this conceptual structure:

```text
Question restated
Current-state anchors
Candidate directions
Orthogonal reframe (what axis it flips; what it changes vs the user's framing)
Recommendation
Anti-recommendation
Intent forks for the user
Handoff impulse for the user to invoke arcopolis-design-interrogate with
Do not proceed to implementation
```

Do not include a Task Statement Card. Do not include an implementation plan. Do not claim
that any candidate is implementation-ready.

## Domain Guardrails

- Possession, mission, objective, package-return, completion, eligibility, and condition
  questions are usually predicate-fidelity candidates. Treat that as a
  `Native-authority guess` until `arcopolis-design-interrogate` derives and cites the final
  class.
- `avatar.carried_items[]` is top-level display/observability only. Do not recommend it as
  sufficient for "does BN consider the avatar to have X?" or mission/NPC validation.
- For NPC validation of possession, include a predicate-validation direction and warn that a
  flat carried-items display surface does not satisfy BN's own possession validation.
- Prompt/menu/UI directions must preserve the current per-family, per-transaction boundary:
  one witnessed prompt path is not generic prompt-class support.
- Unsupported adjacent prompts/menus must remain fail-loud; do not recommend a direction
  that silently auto-cancels unsupported behavior and calls it success.
- Broader frontend/UI/roadmap directions must not drift into bridging existing BN UI screens
  one by one unless the user explicitly directs that strategy.

## Hard Fails

The skill fails if it:

- produces a Task Statement Card;
- produces an implementation plan;
- claims L1-L4 engine equivalence;
- asks the user to classify A/B/C/D/S;
- skips current-state anchors;
- produces fewer than 3 or more than 5 candidate directions;
- does not recommend exactly one direction;
- does not provide exactly one anti-recommendation;
- has no handoff impulse;
- replaces `arcopolis-design-interrogate` instead of feeding it;
- leaves broad "what-next" routing ambiguous with `arcopolis-claim-plan`;
- offers only smaller-or-larger variants of the user's proposed direction, with no
  candidate or rejected framing orthogonal to it (no orthogonal reframing pass);
- states an "orthogonal reframe" that names no change to any of the reframe axes (route,
  downstream consumer, native-authority class guess, active mechanism, witness, stop
  condition, or scope) — a same-task restatement, not a reframe.

## Validation / Self-Check Examples

### V1 - Plain What-Next

Input:

```text
Following the recent Arcopolis spikes, what should we do next?
```

Expected:

- Run `arcopolis-design-explore`.
- Produce 3-5 candidate directions.
- Give one recommendation.
- Give one anti-recommendation.
- End with a handoff impulse for the user to run `arcopolis-design-interrogate` with.
- Do not produce a Task Statement Card.
- Do not produce an implementation plan.
- Do not ask the user to choose A/B/C/D/S.

### V2 - Roadmap/Design If X

Input:

```text
What would the roadmap look like if I wanted Arcopolis to support a package-return mission with an NPC validating that the avatar has the package?
```

Expected:

- Run `arcopolis-design-explore`.
- Split likely directions such as predicate validation, inventory/display observability, and
  NPC/dialogue interaction.
- Recommend treating NPC validation as likely predicate-fidelity for later interrogation.
- Warn that `avatar.carried_items[]` does not satisfy engine possession validation.
- Hand the user a narrowed impulse to run `arcopolis-design-interrogate` with.
- Do not collapse directly into "extend carried_items."

### V3 - Alternatives / Pushback

Input:

```text
I think the next spike should be inventory display. Push back and give me alternatives.
```

Expected:

- Treat inventory display as one candidate, not the plan.
- Provide alternatives and tradeoffs.
- State what inventory display would prove and what it would not prove.
- Include a real orthogonal reframe, not just more options: flip the decision axis from
  "display surface" to "engine predicate" — e.g. "expose BN's own possession predicate
  (`has_amount`/`has_charges`)" instead of a richer carried-items list. Name what the
  reframe changes: downstream consumer (frontend display → engine condition check),
  native-authority class guess (D → C), and witness (a snapshot field → a
  predicate-divergence state, an item nested in a worn container). This is the Spike-25
  lesson made routine.
- Give one recommendation and one anti-recommendation.
- Hand off only the narrowed choice.
- Do not simply validate the user's proposal, and do not offer only larger/smaller
  inventory-display variants.

### V4 - Already Narrow Task

Input:

```text
Expose BN's own possession predicate result for whether the avatar has a given item id.
```

Expected:

- Do not run `arcopolis-design-explore`, or explicitly route past it.
- Tell the user to run `arcopolis-design-interrogate` (it is user-invoked).
- Do not produce a 3-5 option roadmap unless the user asks for alternatives.

### V5 - Approved Plan

Input:

```text
Approved. Build the plan.
```

Expected:

- Do not run `arcopolis-design-explore`.
- Route to `arcopolis-build-from-approved-plan` if an approved plan exists.
- If no approved plan exists, stop and route back to `arcopolis-claim-plan`.
- Do not reopen strategy.
