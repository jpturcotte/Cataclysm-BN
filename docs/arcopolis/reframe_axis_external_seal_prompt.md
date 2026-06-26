# External seal — canonical orthogonal-reframe axis set

This is the cross-author / cross-model seal for the canonical orthogonal-reframe axis set defined in
`AGENTS.md` ("Orthogonal-reframe axes"). An in-loop same-model review of that set is only a FLOOR: it
keys on the same framing judgment the set encodes, so it cannot certify that the set is _complete_ or
_correctly named_. The block below is the seal instrument — paste it to a reviewer who did NOT author
the axis set (a different model, or a human reviewer), and record their verdict before any change to
the set is merged.

Re-run this whenever an axis is added, removed, or renamed.

---

## Prompt (paste verbatim to an independent reviewer)

You are reviewing a small but load-bearing design artifact from the **Arcopolis** project. Default
skeptical: your job is to try to find what is MISSING or WRONG, not to bless it. "It looks reasonable"
is not a useful answer.

### Context you need

**Arcopolis** runs Cataclysm-BN (a roguelike survival game engine) as a _headless simulation
backend_ for a separate mouse-first frontend. The whole project is organized around **equivalence**:
a backend capability must behave like the real game would, proven by driving the engine's own code
paths — never by reproducing an end state through a shortcut. Work proceeds as small "spikes," each
making one equivalence claim backed by a witness (a test or a recorded transcript).

Two taxonomies govern the work:

1. **Equivalence level (L1–L4)** — how strongly a path is proven. L4 = a registered input consumed by
   the engine's own active input loop; L1 = raw observation only.
2. **Native-authority class (A/B/C/D/S)** — what KIND of authority a surface answers to, derived from
   the _downstream consumer_, never the author's wording:
   - **A** action-fidelity (a registered player action through the engine's input loop)
   - **B** prompt/menu-fidelity (an interactive prompt answered through the real loop)
   - **C** predicate-fidelity (an engine-COMPUTED predicate's own returned result, e.g. a
     possession/mission check — and its SCOPE is part of its identity)
   - **D** display-observability (what the GUI would show — a filtered/derived view)
   - **S** simulation-state (raw authoritative world state)

**Why an "orthogonal reframe" exists.** The project's three most expensive failures were all the same
mistake — accepting the framing of the request/author instead of changing the decision _axis_:

- **Spike 3** (turn-structure inversion): drove the move action BEFORE the engine's turn top-half
  instead of letting the engine's input seam consume it — right end state, wrong active mechanism.
- **Spike 25** (wrong primitive): a possession goal (does the avatar HAVE the package?) was answered
  with a FLAT top-level item list (class D, display). The real engine predicate RECURSES into worn
  containers (class C). The two disagree the moment the item is nested. This had a _documented 0%
  in-loop catch rate_ — it was only ever caught from outside the loop ("equivalent to WHAT?").
- **PR #79** (axis drop): one governance skill's copy of the reframe-axis list silently dropped
  the "native-authority class guess" axis. Every same-model in-loop gate graded it a non-blocking
  NOTE; only a different model (and the spec's author) escalated it to a real mistake.

To make reframing routine, the five `arcopolis-*` governance skills (design-explore,
design-interrogate, claim-plan, build-from-approved-plan, red-team-review) each require any reframe to
**name which decision axis it changes**. A "reframe" that changes none of these axes is just the same
task restated. The canonical axis set — the artifact under review — is:

> **route, downstream consumer, native-authority class guess, active mechanism, witness, stop
> condition, scope**

Intended meanings:

- **route** — which code path / seam carries the input or data.
- **downstream consumer** — who/what ultimately reads the surface and what question they are asking.
- **native-authority class guess** — the A/B/C/D/S class, derived from the consumer (the Spike-25
  axis).
- **active mechanism** — which engine loop/mechanism actually consumes the input, at which line (the
  Spike-3 axis).
- **witness** — what observation would prove or falsify the claim, and whether it exercises the
  divergence.
- **stop condition** — where the work stops / what it deliberately does NOT cover.
- **scope** — the breadth claimed vs. the breadth actually witnessed (e.g. one path vs. a whole class).

### The doctrine that makes YOU necessary

A same-model in-loop review of this set is a **floor, not a seal**: it shares whatever blind spot
produced the set, so it can verify the copies agree (a mechanical check does that) but cannot certify
the set is the _right_ set. That judgment is exactly what we are asking you — an independent author —
to provide.

### Your task

Judge whether this 7-axis set is the correct set for forcing a genuine change of decision axis during
the design and review of Arcopolis equivalence work. Specifically:

1. **Completeness.** Is there a decision axis along which a real framing failure could occur that NONE
   of these 7 would force a reframe on? Construct a concrete example if you can — a plausible Arcopolis
   spike whose mistake rides an axis not in the list. (This is the highest-value thing you can find.)
2. **Redundancy.** Are any two axes the same axis under different names, or so overlapping that one
   could be dropped without losing coverage?
3. **Naming.** Is any axis named in a way a reader would systematically misread or conflate with
   another (e.g. "route" vs "active mechanism")?
4. **Granularity.** Is any single entry actually two distinct axes that should be split (or vice
   versa)?

### Output

Give a structured verdict:

- **Set verdict:** correct as-is / add axis / remove axis / rename axis / split-or-merge — pick the
  strongest single recommendation.
- **Missing axis (if any):** name it, define it, and give the concrete Arcopolis example whose failure
  it would catch.
- **Redundant / mis-named / mis-granular (if any):** which entries, and the fix.
- **Confidence** and the single assumption most likely to make your verdict wrong.

Do not pad. If the set is correct, say so and name the strongest candidate addition you considered and
rejected, so the rejection is on record.

---

## Recording the result

File the reviewer's verdict (and the resulting change, if any) alongside the change to the AGENTS.md
anchor. If the reviewer recommends an axis change, that change is itself a new framing edit and must
clear this seal again on its final wording. The mechanical floor
(`deno test --allow-read .agents/arcopolis_reframe_axes_test.ts`) only proves the skill copies match
the anchor — it never replaces this seal.
