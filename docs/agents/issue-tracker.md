# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues on the fork **`jpturcotte/Cataclysm-BN`**. Use the `gh` CLI for all operations.

> **Always pass `--repo jpturcotte/Cataclysm-BN`.** This clone has an `upstream` remote pointing at `cataclysmbn/Cataclysm-BN`, so a bare `gh` command resolves to upstream and fails (or acts on the wrong repo). Every `gh issue` / `gh pr` command below must carry `--repo jpturcotte/Cataclysm-BN`.
>
> Forks have GitHub Issues disabled by default. If `gh issue list` reports that issues are disabled, enable them under the fork's repo **Settings → General → Features → Issues**.

## Conventions

- **Create an issue**: `gh issue create --repo jpturcotte/Cataclysm-BN --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --repo jpturcotte/Cataclysm-BN --comments`, fetching labels as well.
- **List issues**: `gh issue list --repo jpturcotte/Cataclysm-BN --state open --json number,title,body,labels --jq '[.[] | {number, title, body, labels: [.labels[].name]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --repo jpturcotte/Cataclysm-BN --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --repo jpturcotte/Cataclysm-BN --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --repo jpturcotte/Cataclysm-BN --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.** `/triage` looks only at GitHub issues, not PRs.

_(This is a personal research fork — you author your own PRs to the `arcopolis` branch; see AGENTS.md "Repository layout". Set this flag to `yes` only if you start treating external contributors' PRs as feature requests, at which point `/triage` would pull external PRs into the same labels/states using the `gh pr` equivalents — `gh pr view`, `gh pr diff`, `gh pr list ... --json author,authorAssociation`, keeping only `CONTRIBUTOR` / `FIRST_TIME_CONTRIBUTOR` / `NONE` and dropping your own `OWNER` PRs. GitHub shares one number space across issues and PRs, so a bare `#42` may be either — resolve with `gh pr view 42 --repo jpturcotte/Cataclysm-BN` and fall back to `gh issue view 42 --repo jpturcotte/Cataclysm-BN`.)_

## When a skill says "publish to the issue tracker"

Create a GitHub issue with `gh issue create --repo jpturcotte/Cataclysm-BN ...`.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --repo jpturcotte/Cataclysm-BN --comments`.
