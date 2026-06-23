---
name: arcopolis-red-team-review
description: Adversarial review skill for Arcopolis (Cataclysm-BN simulation-backend) prompts, plans, patches, and PRs. Use when the user says "review this PR/plan/prompt", "red team this", "are we sure?", "does this overclaim equivalence?", or "what could go wrong?". Its job is to reject false confidence — false-green equivalence, seam bypass, silent prompt defaults, overbroad claims, unapproved fixture/baseline edits, and prompt-class generalization. Review only — do not implement fixes unless explicitly asked.
---

# Arcopolis Red-Team Review

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. Review only; do not
fix unless asked. Open and read every file/line a claim depends on before agreeing or
flagging — confident-but-wrong `file:line`/existence claims are common, including from
review bots and verify subagents.

## Reject or flag if

- same final state is used as L4 proof;
- a shared `do_turn`/finalization path is used as L4 proof without registered inputs;
- prompt/menu/selector state is directly edited, or a selector return value is forced;
- a per-transaction gate becomes a session-wide gate, or a served category reuses a
  sibling family's gate instead of its own;
- an unsupported prompt silently defaults / cancels / quits and is treated as success;
- one witnessed path is generalized into prompt-class support;
- L4 is claimed without naming the exact active mechanism that consumes the inputs;
- docs/PR text claim support broader than the fixture/protocol witness;
- the capability is only CONSISTENT WITH the cited goal, not SUFFICIENT FOR it (e.g.
  a flat/top-level observation surface offered as proof of a predicate the engine
  evaluates by a deeper, recursing mechanism);
- a surface is offered as proof of an engine-computed predicate with no named state
  where surface and predicate DISAGREE (a counterexample), OR that counterexample is
  asserted but never exercised by the witness — a happy-path-only "divergence" filed
  as a footnote is the Spike-25 failure;
- a surface any cited or foreseeable goal consumes as an engine-computed predicate is
  classified display/observation-only — or its consuming goal is left unnamed — to
  dodge the divergence test; the class follows the downstream consumer's authority,
  not the author's framing;
- backend/headless code depends on curses/window/render behavior in any build;
- baseline/fixture files are changed without explicit approval;
- tests, fixtures, or baselines are weakened, deleted, or rewritten to make a green
  result easier;
- a PR/commit/doc cites local-only or manual evidence (e.g. an uncommitted benchmark)
  as if it were committed, reproducible repo evidence;
- after an upstream sync, `main.cpp`'s `<arg_handler, N>` literal or the array entry
  count is wrong.

## Adversarial pass (any equivalence or goal-fit claim)

A single read is not a review. Run at least THREE INDEPENDENT refute-lenses — this is
what caught the failures a routine pass missed (docs 28/37/38), never one skill read.

- Each lens DEFAULTS to "refuted / insufficient" and tries to CONSTRUCT a divergence
  (a state where the claim's surface/path and the engine's real mechanism disagree).
- Use DISTINCT lenses, not three identical: e.g. goal-fit/sufficiency,
  seam/active-mechanism, fail-loud/silent-default, witness-scope/leaf-citation.
- Verify at the DECISIVE leaf, not a convenient one: the load-bearing line is the
  predicate's traversal body (recursing vs flat) or the action's call-site placement
  (the seam line the loop consumes, vs a leaf called before/after). Verifying a
  faithful-looking sibling leaf while missing the decisive one is how a reviewer who
  shares the author's conflation passes a broken claim. Confident file:line/existence
  claims (incl. review bots and verify subagents) are often false — open it.
- The claim survives only if no lens constructs a divergence the witness does not cover.

## Required output

1. **Verdict** — safe to proceed / needs plan revision / block merge / audit-only.
2. **Equivalence claim status** — proven / downgraded / not proven / overclaimed.
3. **Strongest evidence** — cite `file:line` or the exact witness.
4. **Biggest false-green risk.**
5. **Required next action.**

Keep hedges and witness-scoping intact; do not polish an uncertain claim into
confident prose.

## Shared vocabulary

Claim type · Equivalence level · Active engine mechanism · Registered backend
input/action · Real engine caller · Witness · Witness scope · False-green risk ·
Fail-loud · Unsupported adjacent path · Per-transaction gate · No generic
prompt-class support · Native-authority class (A action / B prompt-menu /
C predicate / D display) · Goal-fit (sufficient-for vs consistent-with) ·
Counterexample / divergence witness.
