# Agent skills

Reusable agent skills live in `.agents/skills/<name>/SKILL.md` (the Codex/OpenAI
convention). This directory is the single tracked source of truth; the files ride PRs.

## Discovery differs by tool

- **Codex** reads `.agents/skills/` directly — no extra step; a checkout is enough.
- **Claude Code** loads project skills from `.claude/skills/`, **not** `.agents/skills/`.
  `/.claude/` is gitignored here (kept local, out of branches/PRs) and is **not** seeded
  into fresh git worktrees, so the skills are **not** visible to Claude Code from a
  checkout alone. Codex-readiness is a property of the repo; Claude-readiness is local
  setup.

## Making the skills visible to Claude Code (local, not committed by design)

Pick one — both keep `.agents/skills/` as the source of truth and leave the Claude-Code
copy gitignored:

- **Recommended — a `SessionStart` hook** in your global `~/.claude/settings.json` that,
  in any repo with `.agents/skills/` but no `.claude/skills/`, creates a `.claude/skills`
  -> `.agents/skills` directory junction (Windows) / symlink (POSIX). Idempotent, silent,
  and re-applies in every worktree. Example hook body (PowerShell):

  ```powershell
  $root = (git rev-parse --show-toplevel 2>$null); if (-not $root) { exit 0 }
  $a = Join-Path $root '.agents\skills'; $c = Join-Path $root '.claude\skills'
  if ((Test-Path $a) -and -not (Test-Path $c)) {
      New-Item -ItemType Junction -Path $c -Target (Resolve-Path $a) | Out-Null
  }
  ```

- **One-off** from the repo root (copies, not a link):

  ```sh
  for d in .agents/skills/*; do n=$(basename "$d"); mkdir -p ".claude/skills/$n"; cp "$d/SKILL.md" ".claude/skills/$n/"; done
  ```

Newly added project skills load at Claude Code session start (some clients also rescan
mid-session).

## The Arcopolis skill suite

`arcopolis-claim-plan`, `arcopolis-build-from-approved-plan`, `arcopolis-red-team-review`,
`arcopolis-prompt-ui-boundary`, and `arcopolis-upstream-sync-seam-audit` encode the
equivalence-claim discipline from `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md`
(the L1-L4 equivalence ladder, fail-loud-on-unsupported-prompts, and per-transaction
gating), split by workflow stage and risk surface.

The design-stage skills `arcopolis-design-interrogate` (Task Statement Card production for
a single narrowed impulse) and `arcopolis-design-explore` (Exploration Brief for broad
strategy/roadmap questions before there is a narrowed impulse) precede the
equivalence-claim suite — they shape and classify a vague design impulse into something
the governance suite can act on; `arcopolis-design-interrogate` is user-invoked by design
(the model must not launch the interactive interrogation itself).

`arcopolis-external-seal-prompt` is a support instrument, not a workflow stage: it generates
the BLIND, classify-from-scratch prompt an external seal needs — the cross-model / human read
that `arcopolis-design-interrogate` raises and `arcopolis-claim-plan` blocks on. It produces
the prompt only; the seal itself is rendered outside the session, by a reasoner that does not
share this one's prior. It draws its frame-removal step from `arcopolis-red-team-review` and
defers the blind-input spec to `arcopolis-design-interrogate`, so it adds no new copy of
either. It carries no canonical reframe-axis block (it performs no reframe), so it is
correctly absent from the `arcopolis_reframe_axes_test.ts` skill list.
