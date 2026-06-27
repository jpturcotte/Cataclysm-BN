---
name: arcopolis-external-seal-prompt
description: Generates the BLIND, author-frame-removed, classify-from-scratch prompt that an external seal needs for an Arcopolis (Cataclysm-BN simulation-backend) equivalence claim. Use when a Task Statement Card is `External-seal required: YES` (status pending), when arcopolis-claim-plan hits its hard block awaiting the independent check, or whenever a possession/mission/objective/state-check/Stage-blocking claim needs a cross-model or human independent read. It PRODUCES THE PROMPT ONLY and does not itself review — a same-model pass is a floor, not a seal. The user carries the prompt to the independent reader and relays the verdict back.
---

# Arcopolis External-Seal Prompt

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. This skill BUILDS the blind
input an independent reader needs; it does NOT render the verdict. The verdict comes from a
reasoner that does not share this session's prior — a human "equivalent to WHAT?" read or a
blind cross-model read. A subagent you could spawn here is the SAME substrate (Claude): that
is a FLOOR, not a seal (the floor/seal doctrine is owned by `arcopolis-design-interrogate`,
"Floor, not seal"; the canonical 0%-in-loop-catch basis is Spike-25). So this skill stops at
a portable prompt; the USER pastes it to the independent reader and relays the verdict back.
Naming the user as the dispatch actor is deliberate, not a hand-wave: the cross-substrate
step cannot happen in-session without collapsing back into the floor it exists to exceed.

**Independence evidence, not a proven seal.** A blind cross-model read is an INDEPENDENT read
— a stronger floor — not a guaranteed seal: a different model may share the same plausibility
prior and miss the framing error for the same reason an in-loop pass would. (An external
blind review of this design raised exactly that; whether frontier models are de-correlated on
this error class is unmeasured.) The only structural seal is MECHANICAL — e.g. a Class-C
witness that exercises the engine predicate's own returned result. Treat this skill's output
as preparing independence evidence; aligning the rest of the doctrine's "seal" language to
match is a tracked follow-up.

## When to invoke

- A Task Statement Card carries `External-seal required: YES` with status `required
  (pending)`.
- `arcopolis-claim-plan` reaches its hard block (item-4 re-derivation set `External-seal
  required: YES`) and needs the independent check.
- Any possession / mission / objective / state-check / Stage-blocking claim needs a seal and
  no blind prompt exists yet.

This skill does NOT decide whether a seal is required — `arcopolis-design-interrogate` raises
it and `arcopolis-claim-plan` re-derives it; they own that judgment. It is invoked once the
requirement already exists, to remove the manual step of hand-authoring the prompt each time.

## Build the blind input (a shared frame-removal primitive)

The frame-removal step is NOT redefined here — it is `arcopolis-red-team-review`'s
"Author-frame removal" procedure (restate the claim from the DIFF / plan text, the WITNESS,
the named downstream consumer, and `AGENTS.md` / `ARCOPOLIS_STATE.md` — never the author's
framing). That skill removes the frame to REVIEW; this skill removes the same frame to HAND
OFF a blind input. One procedure, two consumers — do not fork a second copy.

The blind-input REQUIREMENTS are likewise owned elsewhere: `arcopolis-design-interrogate`'s
"External seal" section is the authoritative spec ("the external-seal input must be BLIND").
This skill OPERATIONALIZES that spec; if the two ever disagree, the spec wins. Apply it to
assemble the prompt:

1. **Strip the author frame.** Do NOT include the Task Statement Card, the proposed
   native-authority class, the authority target, the scope, or the rationale. Those are the
   first agent's ANSWER; revealing them anchors the reader and recreates the circularity the
   seal exists to break.
2. **Give only the raw impulse.** The goal in the user's plain words ("does the avatar HAVE
   the package?"), not the classified restatement.
3. **Give the reader independent verification material.** Pointers alone are not enough — a
   reader with no checkout cannot follow them. Either EMBED the decisive source excerpts (both
   any display / raw surface AND any source where the engine evaluates a value into a result)
   OR state explicitly that the reader needs independent repo / grep access. NEVER hand only
   the first agent's preferred surface.
4. **Ask the forcing question functionally — never with the loaded class words.** "Name the
   concrete downstream engine consumer, and say what the engine DOES with the value: does it
   SHOW it, EVALUATE a yes/no it computes from it, hold it as raw state, perform it as an
   action, or present it as a menu?" Do NOT use the word "predicate," name the suspected
   class, or name the authority target.

## Output: the portable seal prompt

Emit ONE self-contained block the user can paste verbatim to an independent reader (it must
stand alone — the reader may have no repo access). Assemble it from:

- **Standing context** — one line: Arcopolis runs Cataclysm-BN headless as a simulation
  backend organized around equivalence (drive the engine's own paths; never reproduce an end
  state by shortcut). Then quote the **native-authority class (A/B/C/D/S)** list VERBATIM from
  `AGENTS.md`'s canonical class block — it is the single source; do not paraphrase it into a
  third copy.
- **The blind claim-specific input** — the raw impulse, the neutral repo pointers, and the
  forcing question from the section above.
- **Requested output — a structured clearance block** (so a "looks reasonable" rubber-stamp
  is structurally insufficient). Ask the reader to return EVERY field:
  - **Downstream consumer** — the concrete engine caller / site.
  - **Class** — A/B/C/D/S and why, derived from the consumer NOT from any wording.
  - **Decisive source** — the `file:function` (and what its body does) they relied on.
  - **Scope** — the reach the consumer needs (e.g. on-person vs container-deep vs map).
  - **One CLASS-APPROPRIATE divergence** — a concrete state that would falsify a wrong answer
    FOR THE CLASS THEY NAMED: for an engine-computed check, where a flat/surface view and the
    engine's own result disagree; for a display, where it diverges from the GUI; for raw
    state, from the authoritative value; for an action, an engine-state / seam divergence.
  - Default skeptical — "looks reasonable" is not an answer.

  Do NOT ask for a witness or test — none exists yet at seal time (the plan picks the witness
  later). The clearance is the independent consumer / class / scope read, nothing more.

For the canonical-axis-set seal specifically, the ready-made instrument already exists —
`docs/arcopolis/reframe_axis_external_seal_prompt.md`; use it verbatim rather than
regenerating. This skill generalizes that one-off file to any `External-seal required` claim.

## What to paste back (recording the verdict)

The reader's reply fills the External-seal fields on the `arcopolis-design-interrogate` card.
Judge it on the consumer / class / scope read — NOT on a witness (none exists yet):

- Every clearance-block field present, and the reader names the same consumer / class / scope
  as the first agent → record the independent read (`External-seal status: cleared by blind
  cross-model read`, or `cleared by human`), summary in `External-seal evidence`. This is
  independence evidence, not proof — a structural (mechanical) check is the only true seal.
- Any field missing or `UNKNOWN`, or a different consumer / class / scope named → `AUDIT ONLY`.

A same-model in-loop re-read does NOT fill these — it is the floor the independent read exceeds.

## Channel note

The sanctioned blind channels are a human "equivalent to WHAT?" read and a blind cross-model
read. The `arcopolis-red-team-review` / `/code-review ultra` TOOLS are NOT a sanctioned
channel: they rate an EXISTING claim rather than classify from scratch. This skill produces
the classify-from-scratch input a blind reader needs, but feeding it to those tools still
would not seal anything — the limitation is the tools' rate-not-classify behavior, not the
input shape. Paste the prompt to a human or a blind cross-model reasoner, not to those tools.

## Self-check (before handing the prompt over)

- Is the prompt BLIND — no card, no proposed class, no authority target, and no "predicate" /
  class-word in the forcing question?
- Does the reader have independent verification material — embedded decisive source excerpts
  OR explicit repo / grep access — covering BOTH a surface AND the engine's own result, not
  just pointers to the preferred surface?
- Is the requested output a structured clearance block (consumer / class / source / scope /
  class-appropriate divergence), with any missing field → `AUDIT ONLY`, and NO witness asked?
- Is the reader asked to CLASSIFY from scratch (name the consumer, derive the class), not to
  RATE the first agent's claim?
- Is the standing A/B/C/D/S block quoted from `AGENTS.md`, not paraphrased into a third copy?
- Did you STOP at the prompt — not spawn a same-model subagent and call its output a seal?

## Shared vocabulary

Blind input · Author-frame removal (the `arcopolis-red-team-review` primitive) · Floor vs
independence evidence vs seal (same-substrate = floor; cross-substrate / human = INDEPENDENCE
EVIDENCE, a stronger floor, NOT a proven seal; a structural / mechanical check is the true
seal; doctrine in `arcopolis-design-interrogate`) · Native-authority class (A action / B prompt-menu /
C predicate / D display / S simulation-state) · Sanctioned blind channel (human "equivalent
to WHAT?" / blind cross-model — NOT the `arcopolis-red-team-review` / `/code-review ultra`
tools, which rate rather than classify) · Classify-from-scratch vs rate-an-existing-claim.
