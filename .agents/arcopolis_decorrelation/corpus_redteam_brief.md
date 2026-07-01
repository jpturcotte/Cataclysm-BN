# Cross-vendor corpus red-team — Arcopolis de-correlation experiment

## Why this exists

The de-correlation experiment measures whether a **cross-model** review de-correlates from a
**same-model** one on the Arcopolis framing-error class. Its corpus has already been red-teamed by a
panel of **Claude** subagents — but that panel shares Claude's training prior, so by the experiment's
own doctrine it is only a **floor**, not independence evidence. Running this same red-team through a
non-Claude model is the actual independence test:

- Any corpus flaw you catch that a Claude reviewer's priors would overlook is **(a)** a real bug to
  fix and **(b)** a measured de-correlation data point on the experiment's own question.
- Be adversarial. Your single highest-value finding is the one a Claude reviewer would miss.

## Ground rules

- **Fresh session.** Do not read any other model's findings. Reason independently.
- **Verify at the leaf.** Do NOT trust the corpus's own `notes` / `divergence_state` /
  `truth_authority` / `surface_looks_like` — those are the author's claims and may be wrong. Open the
  cited `src/` files and confirm line-by-line. **Cite `file:line` for every load-bearing claim.** A
  confident-but-unverified finding is worse than no finding.
- Depth over breadth. A handful of leaf-verified findings beats a long unverified list.

## Read first (paths relative to the worktree root — the folder containing `AGENTS.md` and `src/`)

- `AGENTS.md` → section **`### Native-authority class`** — the A/B/C/D/S definitions and the Spike-25
  domain rule. **This is the authoritative rubric.**
- `docs/arcopolis/51_SPIKE25_*.md` (the carried-items framing-error postmortem) and
  `docs/arcopolis/54_DECORRELATION_EXPERIMENT.md` (what is being measured).
- The harness, under `.agents/arcopolis_decorrelation/`:
  - `corpus.jsonl` — 40 classification cases (the pre-registered key).
  - `adversarial.jsonl` — 14 epistemic-robustness cases.
  - `excerpts.ts` — the verbatim `src/` quotes embedded in the prompts.
  - `schema.ts` — the validators.
  - `grade.ts`, `grade_adversarial.ts` — the graders (read these closely).
  - `gen_prompts.ts`, `gen_adversarial.ts` — the prompt instrument.
  - `README.md` — the pre-registration document.

## The taxonomy (summary; `AGENTS.md` is authoritative)

**A** action-fidelity · **B** prompt/menu-fidelity · **C** engine-computed predicate ·
**D** display-observability · **S** raw simulation-state. The class is derived from the **downstream
consumer** (what ultimately reads the value), never from the goal's wording. The canonical trap
(Spike-25): an engine _predicate_ goal — class C, a container-recursing `has_amount` — answered with
a flat _display_ surface (`carried_items[]`, class D).

## Attack these dimensions

1. **label** — is each case's `truth_class` correct under the rubric, verified against the cited
   `src/`? Look hardest at the **C** labels: is it really a _predicate_, or actually a derived
   scalar (→ S/D), a display verdict (→ D), or raw state (→ S)?
2. **category** — does each case belong to its category? Are compound / identity / "effective-value"
   cases mis-filed?
3. **excerpt-fidelity** — does each embedded excerpt actually say what the corpus claims? Is the
   decisive routine _shown_, or only inferable from a symbol name?
4. **answer-leakage** — can a reader get the right class **without reasoning** — from the excerpt
   _count_, a symbol-name that matches the rubric's named examples, ordering, or any other structural
   tell rather than the consumer?
5. **bias** — is the class distribution exploitable by a fixed prior (e.g. "always say C")?
6. **adversarial-design** — in `adversarial.jsonl`: are the human-vs-agent pushback pairs
   matched-except-attribution? Can the battery be passed by a reflexive answer or a constant hedge?
7. **grading** — read `grade.ts` / `grade_adversarial.ts`: does the grader mark a _correct_ reasoner
   **wrong**, or credit a _fooled_ one? (Free-text scope bucketing, single-letter grading of
   two-part goals, the flag-uncertainty rule, the `isFlagged` string match.)

## Output

Return ONLY a JSON array of findings, each object exactly:

```json
{
  "target": "<a case id, or DESIGN>",
  "dimension": "<label | category | excerpt-fidelity | answer-leakage | bias | adversarial-design | grading | ambiguity>",
  "severity": "<high | medium | low>",
  "issue": "<what is wrong, with the file:line you opened to verify it>",
  "recommendation": "<the concrete fix>"
}
```

Save it to `.agents/arcopolis_decorrelation/verdicts/corpus_redteam_<model>.json`, where `<model>` is
`codex-gpt-5.5` or `gemini-3.5-flash`. That is all — no prose outside the JSON array.
