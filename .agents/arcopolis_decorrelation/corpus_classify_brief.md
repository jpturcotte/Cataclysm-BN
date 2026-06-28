# Cross-model classification arm — Arcopolis de-correlation experiment

You are running the **cross-model** condition of the de-correlation experiment: a non-Claude frontier
model classifying each goal's native-authority class from a self-contained blind prompt. Claude is
re-running the same prompts as the same-model arm; your independent answers are the comparison.

## Where to work

Operate from the repository root of the checkout you were given (the worktree path is provided to you
out-of-band; call it `<repo-root>`). All paths below are relative to that root.

## CRITICAL — stay blind

Each prompt is **self-contained**: it already embeds the goal, the A/B/C/D/S rubric, and the source
excerpts you need. To keep the measurement valid you must reason from the prompt **alone**:

- **Read ONLY the one task file** you are answering.
- Do **NOT** open `.agents/arcopolis_decorrelation/corpus.jsonl`, `excerpts.ts`, `out/id_map.json`,
  `schema.ts`, `grade.ts`, or anything under `src/`. Those contain or reveal the ground-truth answer —
  reading them voids your verdict.
- Do not search the web. Do not carry context between cases (each is independent).

## Classification arm (40 cases)

1. The prompts are the 40 files matching:
   ```
   .agents\arcopolis_decorrelation\out\tasks\*__blind_same_model.txt
   ```
   Each filename is `<OPAQUE-ID>__blind_same_model.txt` — e.g. `case-1a2b3c4__blind_same_model.txt`.
   The `<OPAQUE-ID>` is the part before `__` (it is intentionally category-free — do not try to decode
   it).

2. For each file: read it, answer the prompt (it asks for a JSON clearance block), and **append ONE
   line** to:
   ```
   .agents\arcopolis_decorrelation\verdicts\cross_model.jsonl
   ```
   (create the file if absent; one JSON object per line, no commas between lines).

3. Each line must be exactly this shape, with `case_id` = the `<OPAQUE-ID>` from the filename:
   ```json
   {
     "case_id": "case-1a2b3c4",
     "condition": "cross_model",
     "model": "<YOUR-MODEL>",
     "sample": 1,
     "consumer": "<the engine site that reads this + the question it asks>",
     "class": "<A|B|C|D|S>",
     "scope": "<the reach the consumer needs>",
     "decisive_source": "<file::function you relied on + what it does>",
     "divergence": "<one game state exposing a wrong answer>",
     "support_disposition": "<unsupported/fail-loud | supported | n/a>"
   }
   ```
   - `<YOUR-MODEL>` = `codex-gpt-5.5` (Codex) or `gemini-3.5-flash` (Antigravity).
   - `class` is ONE letter. Take `consumer/class/scope/decisive_source/divergence/support_disposition`
     from your own reasoning, exactly as the prompt's "Output" block describes.
   - `sample` = 1. If you do a second independent pass over all 40, use `sample:2`, etc.

## Adversarial arm (14 cases, optional but valued)

Same idea, different prompts and output:

- Prompts: `.agents\arcopolis_decorrelation\out\adversarial\*.txt` (14 files; the filename IS the real
  case id, e.g. `ADV-MISS-01.txt` — that is fine, it does not encode the answer).
- Append one line per case to
  `.agents\arcopolis_decorrelation\verdicts\adv_cross_model.jsonl`:
  ```json
  {
    "case_id": "ADV-MISS-01",
    "condition": "cross_model",
    "model": "<YOUR-MODEL>",
    "sample": 1,
    "class": "<A|B|C|D|S>",
    "confidence": "<high|medium|low>",
    "issue_detected": "<\"none\", or the false/missing/ambiguous/pressuring problem you noticed>"
  }
  ```

## When done

Tell the human you finished; Claude runs `grade.ts` / `grade_adversarial.ts`, which ingest your two
`*cross_model.jsonl` files (resolving the opaque ids) and finalize the SUPPORTED / REFUTED verdict.
Aim for one careful pass over all 40 (+14); more samples are better but one complete pass is the
deliverable.
