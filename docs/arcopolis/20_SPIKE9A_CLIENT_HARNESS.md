# Spike 9A — minimal external player-loop harness

> **Status: ✅ implemented (2026-06-09).** The first **consumer-side** spike: a stdlib-only Python
> harness (`tools/arcopolis_client/harness.py`) proving that the Spikes 0–8A contract — terrain +
> monsters + NPCs + ground items in `NNN_<name>.json` snapshots, plus the `session.jsonl`
> transcript — is already enough for an external frontend loop: **build a usable local game view,
> choose a command, run it through the backend, and explain the result.** Zero C++ changes, zero
> schema changes, no new commands; the snapshot `schema_version` stays **1**. Builds on every prior
> spike and on the Spike 4 viewer ([12_SPIKE4_OFFLINE_SESSION_VIEWER.md](12_SPIKE4_OFFLINE_SESSION_VIEWER.md)).

## Why this is "Spike 9A"

Spikes 0–8A proved backend **observability** (where am I, what terrain/monsters/NPCs/items are
around me). The next risk is different: **can an external frontend actually USE this contract
coherently?** Before widening the export (fields, traps, vehicles, weather), this spike connects
all previous slices into one proof. It deliberately produces no new engine capability — if the
harness had needed one, that gap itself would have been the finding.

The harness is the second independent consumer beside the Spike 4 viewer, and the two stay
**share-nothing** on purpose: each re-derives the contract from the docs/source alone, so "two
independent consumers accept the same artifacts" is a real cross-check (regression gate 10), not a
shared-library tautology.

## Scope

**IN:** load any/latest snapshot · per-tile **cell bundles** keyed by `pos_local` (tile + avatar? +
npcs\[] + monsters\[] + items\[]) · a static self-contained **HTML local map + tile inspector**
(zero JavaScript, hover tooltips only) · before/after snapshot comparison across a command ·
**outcome classification** per export pair (moved / blocked / waited / …) with destination analysis
and message diffing · a one-shot **run mode** (compose script → invoke the backend exe →
auto-explain) · a fixture-driven regression on `ArcopolisTest` · this doc + the state page.

**OUT:** live socket/stdin protocol (9B candidate) · GUI framework or mouse UI · pickup/drop/use ·
NPC interaction · any new engine behavior or export field · field/trap/vehicle export ·
**interactive continuation across runs** — `run_script` never saves the world (no save call in
`src/arcopolis_script.cpp`), so every run starts from the same on-disk save; one scripted run per
session **is** the faithful loop today, and that constraint is a designed-in finding of this spike,
not an oversight.

## The tool — `tools/arcopolis_client/harness.py`

Stdlib-only, single file, three subcommands:

```text
harness.py view    --session-dir DIR --output view.html [--snapshot SEL] [--at X,Y] [--reveal-paths]
harness.py explain --session-dir DIR [--json] [--pair N] [--reveal-paths]
harness.py run     --exe PATH --out DIR --commands move_n,move_s,wait
                   [--world ArcopolisTest] [--userdir .\arcopolis_user] [--seed S]
                   [--timeout 120] [--force] [--json] [--reveal-paths]
```

- **`view`** renders ONE static HTML page from one snapshot: scalar header, the local map built
  from cell bundles (overlay precedence **avatar `@` > npc `N` > monster `M` > item `i` >
  terrain**, fixed ASCII letters because the exported `symbol` fields may be multi-byte), per-row
  `y` labels, hover tooltips with the full bundle, and a **tile inspector** panel for the `--at`
  tile (default: the avatar tile) showing ter/furn/family/seen, every entity's v0 fields, the
  Chebyshev distance from the avatar, and — when the tile is exactly one cardinal step away — the
  `move_*` command that reaches it (the "choose a command" hinge). `--snapshot` accepts `latest`
  (default) | `final` | an export index | an export name | a filename; `session.jsonl` is **not**
  required (a bare snapshot dir is viewable).
- **`explain`** loads the transcript, re-verifies every export event against its snapshot
  (turn/pos_abs/moves + the `session` block — the same discipline the viewer applies), pairs
  consecutive exports with the command/error events between them, and classifies each pair (table
  below). `--json` emits ONLY the machine document on stdout (warnings go to stderr), so redirected
  output always parses.
- **`run`** whitelist-validates the command tokens — **exactly `wait`, `move_n`, `move_s`,
  `move_e`, `move_w`**, the backend's complete vocabulary (`src/arcopolis_command.cpp`,
  `command_to_action`) — and rejects anything else **before any subprocess launch**, so a
  harness-vocabulary mistake can never be confused with a backend command failure (backend
  exit 6). It then writes a script (`export "start"`, then per command a command step plus an
  `export "after_NN_<token>"`), invokes the exe once with
  `--world … --arcopolis-run-script … --arcopolis-export-dir … --userdir …` (the userdir is
  **always** passed so a run can never touch the real user directory), maps the exit code through
  the backend's documented table (0 ok … 11 game_over), and on success delegates to the explain
  pipeline. `--out` refuses a non-empty directory unless `--force` — the harness never silently
  deletes.

Exit codes follow the viewer convention: **0** clean · **2** contract discrepancies (bad JSONL
lines, missing/invalid/incomplete snapshots, scalar mismatches, error events, truncated session,
off-window entities — outcome labels are **data**, never failures; `diagnostics.warnings` does
**not** count, since the message-type note makes it non-empty on every healthy snapshot) ·
**1** fatal (usage, missing `session.jsonl`; for run: bad token, missing exe/world, launch
failure, timeout, nonzero backend exit). Paths in output are redacted to basenames by default with
`--reveal-paths` opt-in (AGENTS.md privacy rule, viewer precedent).

### The cell-bundle model

`build_cells(snapshot)` → `{(x, y, z): {tile, is_avatar, npcs[], monsters[], items[]}}`, keyed by
`pos_local` — the per-tile world model a frontend would consume directly. The avatar is matched by
the explicit Spike 5 `is_avatar` marker with a `pos_local` fallback for pre-Spike-5 snapshots;
absent `entities.*` blocks (pre-6A/7A/8A) degrade to empty lists. An exported entity whose
`pos_local` is **not** an exported tile breaks the window-equivalence invariant and is counted as
`entities_off_window` (a contract discrepancy → exit 2).

## The `explain --json` document

Top level: `schema_version` (1) · `tool` / `tool_version` · `session` {world, seed,
game_version, end_status, snapshots, commands} · `contract_check` {ok, bad_lines,
export_mismatches, missing_snapshots, incomplete_snapshots, error_events, schema_mismatches,
entities_off_window, truncated} · `pairs[]` · `summary` {pairs, outcome_sequence\[]} ·
`warnings[]`. `run --json` adds a top-level `run` block {exit_code, exit_meaning, script_file,
commands, duration_s}.

Per pair:

| field                              | meaning                                                                                                                                                                                              |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pair_index`                       | 0-based position in the session's export sequence                                                                                                                                                    |
| `before` / `after`                 | {name, export_index, file, turn, pos_local, pos_abs, moves} — scalars from the export events (verified equal to the snapshots), `pos_local` from the snapshot                                        |
| `commands[]` / `errors[]`          | the transcript events strictly between the two exports                                                                                                                                               |
| `turn_delta` / `moves_delta`       | after − before; **`moves_delta` is reported, never classified** (the after snapshot sits at the next input rest, where `process_turn` may have refilled moves — the `movement_regression.ps1` idiom) |
| `pos_abs_delta` / `expected_delta` | observed `[dx,dy,dz]` vs the commanded `[dx,dy]`; classification keys on **`pos_abs`**, never `pos_local` (a real move can shift the reality bubble, leaving `pos_local` unchanged)                  |
| `outcome` / `blocked_by[]`         | the decision-table label and (for blocks) the attributed blocker kind(s)                                                                                                                             |
| `destination`                      | the commanded destination tile **in the BEFORE snapshot**: {pos_local, ter, furn, terrain_family, seen, npcs\[], monsters\[], items\[]}; `null` for wait/no-command pairs or outside the window      |
| `new_messages[]`                   | message texts new in the after snapshot (see "messages diff" below)                                                                                                                                  |
| `notes[]` / `explanation`          | caveats + one human sentence summarizing the outcome                                                                                                                                                 |

## The outcome decision table

Inputs: commands `C` between the exports, `pos_abs` delta `P`, expected delta `E` from the
direction (y grows **south**: `move_s` = (0,+1)), turn delta `T`, destination cell `D` from the
BEFORE snapshot. Closed label enum: `moved`, `blocked_no_op`, `acted_in_place`, `waited`,
`no_command`, `multi_command`, `displaced`, `unknown`, `unverifiable`.

| C                   | P vs E      | T      | D                             | outcome                                                                                              |
| ------------------- | ----------- | ------ | ----------------------------- | ---------------------------------------------------------------------------------------------------- |
| none                | 0           | 0      | —                             | `no_command` (the final-on-exit pair; an anomaly note if P≠0 or T≠0 — clean-park guarantees neither) |
| `wait`              | 0           | ≥1     | —                             | `waited`; T==0 → `unknown` + anomaly note (do_pause zeroes moves)                                    |
| `move d`            | **P==E**    | any    | any                           | `moved`; T==0 is **legal** (multi-action turns exist) and noted, not failed                          |
| `move d`            | 0           | 0      | NPC on D                      | `blocked_no_op`, `blocked_by=["npc"]`, NPC named with relationship adjectives + the docs-15/18 note  |
| `move d`            | 0           | 0      | monster on D                  | `blocked_no_op`, `blocked_by=["monster"]` + a "hostile bump normally attacks" caveat                 |
| `move d`            | 0           | 0      | wall/window family, seen      | `blocked_no_op`, `blocked_by=["terrain"]` — **heuristic**, the contract has no passability flag      |
| `move d`            | 0           | 0      | floor-like, no creature       | `blocked_no_op`, `blocked_by=[]` + "no exported blocker (v0 has no vehicles/fields)"                 |
| `move d`            | 0           | **≥1** | any                           | `acted_in_place` (door family → "likely opened it"; creature → "likely a bump-attack")               |
| `move d`            | P≠0 and P≠E | any    | —                             | `displaced` (push/swap/displacement?) — facts only                                                   |
| `move d`            | any         | any    | outside window / `seen=false` | facts absent/flagged; unseen contents still listed ("authoritative export, not player knowledge")    |
| >1 command          | —           | —      | —                             | `multi_command` — net deltas reported; per-command destination analysis needs exactly one command    |
| snapshot unloadable | —           | —      | —                             | `unverifiable` → contract discrepancy → exit 2                                                       |

### Messages diff

Snapshots carry `messages[]` **text** (type is blank pending a `Messages::` accessor — Spike 5
deferral). The window is the most recent ≤10 messages in chronological oldest-first order
(`Messages::recent_messages` takes the deque tail in original order, `src/messages.cpp:250-262`),
so the new suffix is everything after the **largest** k with `before[-k:] == after[:k]`. k==0 with
both windows non-empty means a full rotation (≥10 new) or no overlap — all after-messages are then
listed as _possibly_ new with a note. Duplicate texts make the overlap deliberately
**under-report** (conservative; never fabricates news).

## What it proved on `ArcopolisTest`

One session, script `export start → move_n → export → move_s → export → wait → export` (+ the
engine's `004_final`). **`move_n` must run FIRST**, while the stock shelter NPC Edwardo Stovall is
still one tile north (local `[85,84,0]`) — after `move_s` the start tile is empty and a later
`move_n` would _succeed_. Measured (sibling-validated 8A build, 2026-06-09):

| pair | command | turn              | pos_abs                       | outcome         | harness explanation (verbatim)                                                                                                                    |
| ---- | ------- | ----------------- | ----------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | move_n  | 1324801 → 1324801 | [6301,6421,0] → [6301,6421,0] | `blocked_no_op` | "move_n did not move the avatar and the turn did not advance: NPC Edwardo Stovall (neutral, stationary) occupies the destination tile [85,84,0]." |
| 1    | move_s  | 1324801 → 1324802 | [6301,6421,0] → [6301,6422,0] | `moved`         | "move_s moved the avatar by (0,1) to pos_abs [6301,6422,0]; the turn advanced by 1."                                                              |
| 2    | wait    | 1324802 → 1324803 | unchanged                     | `waited`        | "wait kept the avatar in place while the turn advanced by 1 (the world ticked)."                                                                  |
| 3    | (none)  | 1324803 → 1324803 | unchanged                     | `no_command`    | "No command between these exports; the state is unchanged."                                                                                       |

The same three offline outcomes were first re-derived from the **recorded** sibling sessions
(`npc_blocker` → blocked_no_op/no_command, `move_s_walkable` → moved/no_command, `item_export` →
waited/no_command) before any new backend run — the harness is a pure contract consumer either way.

## Heuristics and honesty

- **Passability is a guess.** The contract exports no passability flag; "blocked by terrain" is a
  substring-family heuristic (`wall`/`window` ids) and is labeled as such in the output. A blocked
  move onto plain floor reports "no exported blocker" rather than inventing one.
- **`moves` is reported, never classified** — the after snapshot sits at the next input rest where
  moves may have been refilled (the `movement_regression.ps1` idiom).
- **Classification keys on `pos_abs`.** `pos_local` is reality-bubble-relative and can stay
  constant across a real move when the bubble shifts; it is used only for same-snapshot lookups
  (cell bundles, map, destination).
- **`moved` does not require T≥1** — a fast avatar can act more than once per turn. The
  fixture-specific `turn_delta ≥ 1` assertions live in the regression, not the classifier.
- **`acted_in_place` and `displaced` are designed but not fixture-witnessed** (no door/bump-attack
  case in `ArcopolisTest`'s deterministic script); they exist so real frontend traffic degrades to
  labeled facts instead of misclassification.
- **`diagnostics.warnings` never counts as a discrepancy** — the message-type note makes it
  non-empty on every healthy snapshot.

## Regression — [`client_harness_regression.ps1`](client_harness_regression.ps1)

Fixture-driven (needs a loaded world, so not in CI), structured like the sibling scripts: prereq
exits 3=exe, 4=fixture, 5=world, 6=python, 7=harness, 8=viewer; sandbox refresh from
`C:\dev\arcopolis-fixtures\arcopolis_user`; `Stop-WithCode` (the `Write-Error; exit N` collapse
gotcha). Ten hard gates: backend exit 0 + 5 snapshots · `explain --json` exit 0 with
`contract_check.ok` · the exact outcome sequence `blocked_no_op,moved,waited,no_command` · the
NPC-block pair (blocked_by npc, destination computed one-north of the before `pos_local`, NPC
present — Edwardo in the canonical fixture; the PASS line prints the harness's own explanation) ·
the moved pair (delta `0,1,0`, T≥1) · the wait pair (T≥1, no movement) · the final pair
(`no_command`, T==0) · the HTML view + inspector markers (presence-only, never layout) · **run
mode** end-to-end (the harness launches the backend itself and re-derives the same sequence) · the
Spike 4 viewer exiting 0 on the same session (consumer cross-check). Validated 2026-06-09: exit 0,
all gates green, against the sibling worktree's Spike-8A build.

## Deferred (what a _real_ loop needs next)

- **NPC interaction command** (talk/attack/swap/push) — the Edwardo tile is _visible_ and
  _explained_ but still not actionable (the move-into-NPC no-op,
  [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)).
- **Examine / pickup / interaction commands** — the inspector shows loot it cannot act on.
- **Live protocol** (M3 coroutine seam) — replaces the one-scripted-run-per-session loop with a
  persistent process; the harness's explain pipeline is the consumer it would plug into.
- **Message type/severity** (needs a public `Messages::` accessor) and **per-tile
  symbol/colour + passability** — would replace this spike's glyph/blocking heuristics with engine
  truth.
- **Fields / traps / vehicles export** — the next observability slices (10A candidate), now with a
  consumer ready to render and classify them.
