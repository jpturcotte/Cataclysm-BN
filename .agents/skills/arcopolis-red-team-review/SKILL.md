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
  evaluates by a deeper/recursing mechanism);
- backend/headless code depends on curses/window/render behavior in any build;
- baseline/fixture files are changed without explicit approval;
- tests, fixtures, or baselines are weakened, deleted, or rewritten to make a green
  result easier;
- a PR/commit/doc cites local-only or manual evidence (e.g. an uncommitted benchmark)
  as if it were committed, reproducible repo evidence;
- after an upstream sync, `main.cpp`'s `<arg_handler, N>` literal or the array entry
  count is wrong.

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
prompt-class support.
