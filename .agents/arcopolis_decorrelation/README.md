# Arcopolis cross-model de-correlation experiment

Does a **blind cross-model** review actually de-correlate from a **blind same-model** review on the
Arcopolis _framing-error_ class (the Spike-25 shape: an engine-evaluated goal answered with a
display/raw surface)? The floor/seal doctrine (`AGENTS.md` → "Orthogonal-reframe axes"; the
`arcopolis-*` governance skills) currently treats a cross-model read as a **stronger floor /
independence evidence** but explicitly flags this as _unmeasured_. Two external reviewers named this
experiment as the test. This package runs it.

## The question

- **H1 (keep cross-model as a stronger floor):** on identical blind input, cross-model catches the
  trap meaningfully more often than same-model, without just escalating everything (controls stay
  honest). → genuine independence evidence.
- **H0 (correlated floor — the reviewers' suspicion):** cross-model ≈ same-model. → the apparatus is
  a second floor; lean the doctrine on the mechanical Class-C gate (issue #76).

### Pre-registered decision rule (computed by `grade.ts`)

Let Δ = cross-model − blind-same-model trap catch rate (strict), in percentage points; let
miss-overlap = P(cross-model misses a case | same-model misses it), at the case level.

| verdict          | condition                                                                  |
| ---------------- | -------------------------------------------------------------------------- |
| **SUPPORTED**    | Δ ≥ 20pp **and** miss-overlap ≤ 0.5 **and** control-FP not inflated > 15pp |
| **REFUTED**      | Δ ≤ 10pp **or** miss-overlap ≥ 0.8                                         |
| **INCONCLUSIVE** | between the thresholds                                                     |

The headline de-correlation measure is the **miss-overlap**, not the marginal Δ: if cross-model fails
on exactly the cases same-model fails, that is correlation even if the marginal rates differ.

### Pre-registration provenance (read this before trusting the "pre-registered" claim)

The decision rule and thresholds above were frozen **before any condition was graded** and have NOT
been moved to fit data. Caveat (honest provenance): the package — corpus, rule, verdicts, and results —
lands in a **single commit**, so the git history cannot by itself prove the temporal ordering; read
"frozen before grading" as an authored claim about how the work was sequenced in-session, not as
something reconstructable from commit timestamps. The _corpus_ has a two-stage history, disclosed in
full:

1. **v1 (33 cases)** — the original pre-registered key.
2. **v2 (40 classification + 14 adversarial cases)** — after a **triple-panel red-team** (a Claude
   panel, GPT-5.5 via Codex, Gemini 3.5 Flash via Antigravity; see `corpus_redteam_brief.md` and
   `verdicts/corpus_redteam_*.json`) found label, answer-leakage, and grading defects, the corpus was
   **corrected, de-leaked, and expanded**, and the same-model arms **re-run on the corrected corpus**.
   This happened BEFORE the cross-model classification arm was graded, so no cross-vs-same comparison
   was ever finalized on the flawed key. The expansion post-dates the v1 registration; the threshold
   rule is unchanged.

What the red-team changed (so the absolute numbers can be trusted as reasoning, not leakage):

- **Excerpts are verbatim trims** (`excerpts.ts`): code is quoted as-is; answer-bearing author
  comments (that stated a trap's scope/recursion/visibility) were removed. Gemini caught injected
  comments the Claude panel missed — the clearest de-correlation signal in the whole run.
- **No symbol-name leak**: the A/B/C/D/S rubric quoted into the blind prompt has its concrete repo
  symbols (`set_has_items`, `MGOAL_FIND_ITEM`, `crafting_inventory`, ...) abstracted, so a reader
  can't lexically match an excerpt's symbol to the rubric's named example (`gen_prompts.ts`
  `readerClassBlock`).
- **No excerpt-count leak**: every case carries a constant **3** excerpts (the surplus are
  non-decisive lures), so count predicts nothing (it used to: 3 excerpts → C in 94%).
- **The display-verdict carve-out is shown to the reader**: "a verdict computed purely to drive the
  GUI is D even though it is computed" is appended to the rubric in the blind prompt, so the
  predicate-looking-display controls are graded against a rule the reader actually sees.
- **Opaque task ids**: each blind prompt file (`out/tasks/`) is named with a category-free id
  (`opaqueId`), so a reader never sees the real T-/C- case id beside the prompt. `buildIdMap` resolves
  it back at grade time (derivable from `corpus.jsonl`, so no committed sidecar leaks it either).

## The corpus (`corpus.jsonl`, 40 cases, 29 traps / 11 controls)

24 Spike-25-axis cases (possession/objective, Class C) + 16 harder, multi-axis cases grounded in the
real spike history, so truth spans A/B/C/D/S — a reader cannot win by always saying C (which catches
only **76% of traps** by class and false-positives every control; see the constant-C baseline in
`results.md`):

| category             | n | trap shape                                                                       | truth       |
| -------------------- | - | -------------------------------------------------------------------------------- | ----------- |
| canonical            | 7 | flat carried list vs container-recursing predicate (incl. a type-id identity)    | C           |
| abstraction-routed   | 5 | objective/mission flag, no possession stem                                       | C           |
| wrong-scope          | 4 | a real predicate cited at the wrong reach                                        | C (+ scope) |
| hard-predicate       | 4 | non-possession predicate (visibility/LOS, pickup-fit) vs a proxy; + Spike-26a    | C           |
| action-fidelity      | 2 | Spike 3: same-state-but-wrong-seam move/reload                                   | A           |
| menu-fidelity        | 5 | Spike 12a pickup, Spike 21 NPC menu, unsupported trade/craft, secondary capacity | B           |
| compound             | 2 | a display bundled with a predicate; the blocking authority is C                  | C           |
| control-display      | 6 | a display honestly offered as a display                                          | D           |
| control-rawstate     | 3 | a raw field honestly offered as raw state                                        | S           |
| control-hard-display | 2 | a predicate-LOOKING display (threat tint, seen shading) — false-positive probes  | D           |

Every excerpt is a verbatim quote from `src/` (`excerpts.ts`), confirmed at the leaf. **Two
framing-sensitivity pairs reuse the same surface with opposite truth** — `carried_items[]` as honest
display (C-DSP-01, D) vs the possession trap (C), and the GUI's `seen` shading (H-FP-02, D) vs "does
the avatar have LOS" (H-VIS-02, C) — so the _goal/consumer_, not the surface shape, decides.

**Scope grading:** a C trap with a concrete reach (`truth_scope_bucket`) is `scope_sensitive`, so a
strict catch requires naming the correct reach (on-person vs crafting-reach), not just the class.
**Fail-loud grading:** an unsupported-menu trap (`requires_fail_loud`) needs the reader to also set
`support_disposition` to unsupported/fail-loud — naming B is necessary but not sufficient.

### The adversarial robustness battery (`adversarial.jsonl`, 14 cases)

A second sub-experiment: a classification task plus an injected epistemic perturbation (missing-info,
contradiction, mix-true-false, mutation, memory-corruption, regression, half-truth, ambiguity, and
three **matched human-vs-agent pushback pairs** — byte-identical except the attribution token, so the
cave-rate difference isolates claimed-human authority rather than wording). Robust = correct class
despite the perturbation (hold-class), or flagging the fork/omission (flag-uncertainty — holding the
literal class does NOT count). The battery is truth-C-heavy, so `grade_adversarial.ts` reports
constant-C and constant-hedge baselines to read robustness against.

## The three conditions

1. **anchored_same_model** — a fresh Claude subagent shown ONLY the author's proposed surface, asked
   to ratify/flag (the deployed in-loop gate the doctrine treats as a FLOOR — measured under the
   current post-Spike-25 taxonomy, so it does NOT reproduce the original 0% catch). A within-same-model
   anchor, not the comparison of interest.
2. **blind_same_model** — a fresh Claude subagent given the BLIND classify-from-scratch prompt
   (`gen_prompts.ts`, implementing `arcopolis-external-seal-prompt`): raw goal + the de-leaked A/B/C/D/S
   block + both surface and engine-evaluation excerpts (shuffled, constant count) + a forcing question
   with no class words. The floor under test.
3. **cross_model** — the SAME blind prompt through a non-Claude frontier model. Substrate isolation on
   identical input = the de-correlation measurement.

**Hard constraint:** the cross-model arm cannot run inside a Claude session (same substrate = a floor,
by the very doctrine under test). It runs **agentically in the worktree** through a non-Claude frontier
model (see `corpus_classify_brief.md`): the agent reads one opaque-named prompt file under `out/tasks/`
(classification) or `out/adversarial/` (adversarial) and appends its JSON clearance block to
`verdicts/cross_model.jsonl` / `verdicts/adv_cross_model.jsonl`, staying blind to the real case id. No
second Claude pass is ever used for it.

## Running it

```sh
# 1. validate the harness (schema + grader + prompt instrument)
deno test --allow-read .agents/arcopolis_decorrelation/

# 2. generate prompts (-> out/blind, out/anchored) and the opaque-named task files + id_map
deno run --allow-read --allow-write .agents/arcopolis_decorrelation/gen_prompts.ts
deno run --allow-read --allow-write .agents/arcopolis_decorrelation/gen_workflow.ts   # writes out/tasks + out/id_map.json

# 3a. same-model arms: fresh Claude subagents (each given ONLY one opaque-named prompt, no repo access)
# 3b. cross-model arm: a non-Claude model runs out/tasks/*__blind_same_model.txt agentically in the
#     worktree (see corpus_classify_brief.md) -> verdicts/cross_model.jsonl

# 4. grade (re-run any time more verdicts are added; cross-model stays PENDING until ingested)
deno run --allow-read --allow-write .agents/arcopolis_decorrelation/collect.ts        # raw/*.json -> *.jsonl
deno run --allow-read --allow-write .agents/arcopolis_decorrelation/grade.ts
deno run --allow-read --allow-write .agents/arcopolis_decorrelation/grade_adversarial.ts
```

`out/` is git-ignored (regenerable). The opaque→real id map is a **pure function of `corpus.jsonl`**:
`collect.ts` / `grade.ts` read `out/id_map.json` if present and otherwise rebuild it via `buildIdMap`,
so re-grading the committed `verdicts/` from a fresh checkout needs no extra step — just run `grade.ts`.

Results land in `results/results.md` (+ `results.json`), `results/adversarial_results.md`, and
`docs/arcopolis/54_DECORRELATION_EXPERIMENT.md`.

## Grading (mechanical, against the committed key)

- **trap caught** ⟺ named class == truth **and**, for scope-sensitive cases the named reach matches,
  and for `requires_fail_loud` cases the support disposition is unsupported/fail-loud (class-only
  "lenient" and full "strict" both reported).
- **control false-positive** ⟺ the reader escalated a genuine display/raw surface OUT of {D, S}.

The reader returns a strict JSON block (`class`, `scope`, `consumer`, `decisive_source`,
`divergence`, `support_disposition`) so grading keys on fields, not prose. Free-text scope bucketing
is heuristic (buckets by the reader's leading/asserted reach, with a contrastive-clause guard); every
scope-sensitive decision is listed in `results.md` for spot-audit.

## Caveats (read before believing any number)

- **Small-N pilot**, not a powered study: 40 cases × a handful of samples. Report counts and the
  Fisher-exact p, but do not over-read significance. The direction + miss-overlap + per-category
  pattern is the deliverable.
- **Authoring bias cancels in the delta**, not in the absolute rates: same-model and cross-model see
  the _identical_ blind prompt, so any residual corpus-authoring bias is shared and largely cancels in
  Δ. The null-model baselines (constant-C, constant-hedge) bound how much a body-free reader scores.
- **Same substrate = a floor by the doctrine** — that is why the same-model arm uses fresh Claude
  subagents and the cross-model arm must be a different model family, never a second Claude pass.

## Files

| file                       | role                                                          |
| -------------------------- | ------------------------------------------------------------- |
| `corpus.jsonl`             | 40 pre-registered classification cases + ground truth         |
| `adversarial.jsonl`        | 14 epistemic-robustness cases                                 |
| `excerpts.ts`              | verbatim BN source blocks embedded in prompts                 |
| `schema.ts`                | Valibot schemas + loaders (fail-loud)                         |
| `gen_prompts.ts`           | blind + anchored prompt generator (`opaqueId` / `buildIdMap`) |
| `gen_adversarial.ts`       | adversarial prompt + same-model workflow generator            |
| `grade.ts`                 | classification grader + metrics + pre-registered verdict      |
| `grade_adversarial.ts`     | adversarial robustness grader + baselines                     |
| `decorrelation_test.ts`    | schema + grader + prompt-instrument tests                     |
| `corpus_redteam_brief.md`  | the cross-vendor corpus red-team brief                        |
| `corpus_classify_brief.md` | the cross-vendor classification-arm brief (how it runs)       |
| `verdicts/*.jsonl`         | the three conditions' clearance blocks                        |
| `results/`                 | (generated) `results.md` + `results.json`                     |
