# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**This repo uses a multi-context layout** — a `CONTEXT-MAP.md` at the root is the entry point and points at one `CONTEXT.md` per context. These files are created lazily by `/domain-modeling` as terms and decisions get resolved; none exist yet, which is expected.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it points at one `CONTEXT.md` per context. Read each `CONTEXT.md` relevant to the topic you're about to work on.
- **`docs/adr/`** — system-wide architectural decisions. Read the ADRs that touch the area you're about to work in.
- **`docs/<context>/`** (e.g. `docs/arcopolis/`) — context-scoped decisions, since `src/` is flat in this repo.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. `/domain-modeling` (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure (multi-context)

```
/
├── CONTEXT-MAP.md                  ← entry point: lists the contexts
├── docs/adr/                       ← system-wide decisions
└── ...                             ← per-context CONTEXT.md files, e.g.
    docs/arcopolis/CONTEXT.md       ← Arcopolis backend-boundary context
    <engine>/CONTEXT.md             ← BN simulation-engine context
```

For this codebase the natural split follows AGENTS.md: the **Bright Nights simulation engine** (authoritative world state, save/load, rules, content loading) versus the **Arcopolis backend boundary** (the `--arcopolis-*` modes and the `src/arcopolis_*` seam). `CONTEXT-MAP.md` should name whatever contexts you actually settle on — let `/domain-modeling` grow them rather than scaffolding empty files now. Note that `src/` is flat here, so a context's ADRs may live under `docs/` (e.g. `docs/arcopolis/`) rather than a `src/<context>/docs/adr/` subtree.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in the relevant `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in any glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
