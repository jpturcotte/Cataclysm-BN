---
name: arcopolis-external-seal-prompt
description: Generates the BLIND, author-frame-removed, classify-from-scratch prompt that an external seal needs for an Arcopolis (Cataclysm-BN simulation-backend) equivalence claim. Use when a Task Statement Card is `External-seal required: YES` (status pending), when arcopolis-claim-plan hits its hard block awaiting the independent check, or whenever a possession/mission/objective/state-check/Stage-blocking claim needs a cross-model or human seal. It PRODUCES THE PROMPT ONLY and does not itself review — a same-model pass is a floor, not a seal. The user carries the prompt to the independent reader and relays the verdict back.
---

# Arcopolis External-Seal Prompt

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. This skill BUILDS the blind
input an external seal needs; it does NOT render the verdict. The verdict comes from a
reasoner that does not share this session's prior — a human "equivalent to WHAT?" read or a
blind cross-model read. A subagent you could spawn here is the SAME substrate (Claude): that
is a FLOOR, not a seal (the floor/seal doctrine is owned by `arcopolis-design-interrogate`,
"Floor, not seal"; the canonical 0%-in-loop-catch basis is Spike-25). So this skill stops at
a portable prompt; the USER pastes it to the independent reader and relays the verdict back.
Naming the user as the dispatch actor is deliberate, not a hand-wave: the cross-substrate
step cannot happen in-session without collapsing back into the floor it exists to exceed.

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
3. **Point neutrally.** Provide repo pointers to BOTH any display / raw surface AND any
   suspected predicate / condition source the impulse could touch — or grant the reader an
   independent grep. NEVER point only at the first agent's preferred surface.
4. **Ask the forcing question without leaking the answer.** "Name the concrete downstream
   engine consumer; is it a predicate/condition, a display, raw state, an action, or a
   menu/input loop?" — without naming the suspected class, the authority target, or the word
   "predicate."

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
- **Requested output** — ask the reader to return: the concrete downstream consumer they
  name; its class (A/B/C/D/S) and why, derived from the consumer NOT from any wording; and one
  concrete state where a display/raw surface and the engine predicate would DISAGREE (or
  UNKNOWN if they cannot construct one). Default skeptical — "looks reasonable" is not an
  answer.

For the canonical-axis-set seal specifically, the ready-made instrument already exists —
`docs/arcopolis/reframe_axis_external_seal_prompt.md`; use it verbatim rather than
regenerating. This skill generalizes that one-off file to any `External-seal required` claim.

## What to paste back (recording the verdict)

The reader's reply fills the seal fields on the `arcopolis-design-interrogate` card:

- agrees, names the same consumer/class, constructs no divergence the witness misses →
  `External-seal status: cleared by blind cross-model read` (or `cleared by human`), with the
  reply summary in `External-seal evidence`.
- disagrees, names a different consumer/scope, or returns UNKNOWN → `AUDIT ONLY`.

A same-model in-loop re-read does NOT fill these — it is the floor the seal exists to exceed.

## Channel note

The sanctioned blind channels are a human "equivalent to WHAT?" read and a blind cross-model
read. The `arcopolis-red-team-review` / `/code-review ultra` TOOLS are NOT a sanctioned
channel: they rate an EXISTING claim rather than classify from scratch (the tool-channel
blind-input shape is deferred to issue #73). This skill produces the classify-from-scratch
input such a channel would need, but it does not by itself sanction the tools — until #73
lands, paste the prompt to a human or a blind cross-model reasoner, not to those tools.

## Self-check (before handing the prompt over)

- Is the prompt BLIND — no card, no proposed class, no authority target, no "predicate" in
  the forcing question?
- Are the pointers NEUTRAL — a display/raw surface AND a suspected predicate source (or an
  independent grep), never only the preferred surface?
- Is the reader asked to CLASSIFY from scratch (name the consumer, derive the class), not to
  RATE the first agent's claim?
- Is the standing A/B/C/D/S block quoted from `AGENTS.md`, not paraphrased into a third copy?
- Did you STOP at the prompt — not spawn a same-model subagent and call its output the seal?

## Shared vocabulary

Blind input · Author-frame removal (the `arcopolis-red-team-review` primitive) · Floor vs
seal (same-substrate = floor; cross-substrate / human = seal; doctrine in
`arcopolis-design-interrogate`) · Native-authority class (A action / B prompt-menu /
C predicate / D display / S simulation-state) · Sanctioned blind channel (human "equivalent
to WHAT?" / blind cross-model — NOT the `arcopolis-red-team-review` / `/code-review ultra`
tools; issue #73) · Classify-from-scratch vs rate-an-existing-claim.
