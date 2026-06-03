# Spike 4 — Offline Session Viewer / Contract Consumer

> **Status: ✅ implemented (2026-06-03).** The first **external consumer** of the Arcopolis backend
> contract: a small, offline, dependency-free Python tool
> (`tools/arcopolis_viewer/make_report.py`) that turns a Spike 3.1C export directory
> (`session.jsonl` + `NNN_<name>.json` snapshots) into **one self-contained HTML report**. A
> **viewer / contract-consumer** spike — **not** a backend spike: no C++/gameplay change, no new
> command, no protocol, no socket, no JSONL command input, no snapshot- or transcript-schema change,
> no third-party dependency, no server. Builds on
> [11_SPIKE3_1C_SESSION_TRANSCRIPT.md](11_SPIKE3_1C_SESSION_TRANSCRIPT.md).

## Why this is "Spike 4" (a new number, not a point release)

Spikes 3.1A/3.1B/3.1C were point releases on the movement spike because each only adjusted the
**backend boundary** — the input seam, clean-park, then the transcript. Spike 4 adds **nothing** to
the backend. It is a **new artifact on the far side of the boundary**: the first program that _reads_
the contract the backend emits and reconstructs a run from it. 3.1C closed by asserting that
"transcript + snapshots are sufficient to reconstruct the whole script run" and explicitly deferred
the viewer ("No protocol / sockets / … a future viewer can tail `session.jsonl`"). Spike 4 **is** that
viewer, and demonstrating the sufficiency claim end-to-end — from outside the engine — is what earns a
fresh spike number rather than a `3.1D` suffix.

## Prior backend state

- **Spike 0–2** — headless load + one-shot view; the `wait` command; persistent
  `--arcopolis-run-script` + `--arcopolis-export-dir` (load once, snapshot per `export`).
- **Spike 3** — movement; FAILED (`command → do_turn` inverted the turn structure).
- **Spike 3.1A/B/C** — fixed via the `handle_action` input seam; clean-park + final-on-exit snapshot;
  the `session.jsonl` transcript.
- **Spike 4** — this pass: the first consumer of those artifacts, a read-only offline report. No
  backend code is touched.

## How it consumes Spike 3.1C artifacts

The tool reads exactly one export directory and writes exactly one HTML file. It:

- parses `<session-dir>\session.jsonl` **line by line**, validating that every non-empty line is a
  JSON object; malformed lines are collected with their line number and surfaced in the report rather
  than aborting the run;
- keeps events in **file order**, so each `command` precedes the `export` it produced — no globbing,
  no sorting, no inference (exactly the 3.1C promise);
- for every `export` event, loads the referenced snapshot from the event's relative `path`
  (`NNN_<name>.json`) and renders it as the resulting frame.

For each `export` the report **re-verifies the 3.1C build-invariant from outside the engine**:

| report check                    | transcript field                              | snapshot field                                        |
| ------------------------------- | --------------------------------------------- | ----------------------------------------------------- |
| turn match                      | `export.turn`                                 | `backend.turn`                                        |
| position match                  | `export.pos_abs`                              | `avatar.pos_abs`                                      |
| moves match                     | `export.moves`                                | `avatar.moves`                                        |
| _(bonus)_ step/index/name/final | `export.{step_index,export_index,name,final}` | `session.{step_index,export_index,export_name,final}` |

3.1C states these equalities hold _by construction_ (`current_snapshot_summary()` reads the same
accessors as the snapshot, at the same instant). Spike 4 is an independent reader that **checks them
on the produced files** — a clean run is one where all of them hold for every export.

## Expected input directory shape

Whatever a stateful `--arcopolis-run-script` run wrote (Spike 2/3.1C). For the canonical
`export → move_s → export → move_s → export → wait → export` script:

```text
<session-dir>\
  session.jsonl          # JSON Lines transcript (session_start, command/export/error…, session_end)
  000_start.json         # snapshot referenced by export #0
  001_after_move1.json   # snapshot referenced by export #1
  002_after_move2.json
  003_after_wait.json
  004_final.json         # final-on-exit snapshot (session.final = true)
```

The viewer needs only the transcript plus the snapshots it references; it loads no other file and
requires no images, tilesets, fonts, or network.

## Report features

A single static `.html` (open it directly with `file://`, no server). Sections:

- **Session summary** — `session_start` (`world`, `seed?`, `export_dir`, `game_version`) and
  `session_end` (`status`, `snapshots`, `commands`, `final_turn`, `final_pos_abs`); absent
  start/end is flagged as a truncated run.
- **Validation summary** — a `PASS` / `DISCREPANCIES` badge plus counts (events parsed, malformed
  lines, commands, exports, matched/mismatched, missing snapshots, error events).
- **Issues** (only when something is wrong) — transcript `error` events, malformed JSONL lines (with
  line number + escaped raw text), and snapshot/contract problems (missing snapshot or scalar
  mismatch with expected-vs-actual).
- **Timeline** — every event in file order: `command` rows (command, direction, `action_id`,
  status); `export` detail cards with a transcript-vs-snapshot scalar table, a match badge,
  `turn`/`moves`/`export_index`/`step_index`/`export_name`/`final`, and a collapsible **2D tile
  map**; `error` callouts; `session_start`/`session_end` markers.
- **2D tile map** — the snapshot's `tiles` window drawn as a monospace text grid (CSS-coloured, no
  images). North is at the top; the avatar is marked `@` at the tile whose `(x,y)` equals
  `avatar.pos_local`; unseen (`seen:false`) tiles are dimmed but still drawn; terrain/furniture ids
  map to schematic glyphs via substring heuristics with a documented `?` fallback, and a per-map
  legend lists the categories present. The window is built from the **actual** tiles, so a
  clamped/asymmetric edge window is handled and captioned rather than mis-centred.

### CLI and exit codes

```powershell
python tools\arcopolis_viewer\make_report.py --session-dir <dir> --output <report.html>
```

| exit | meaning                                                                                                                                                                   |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0`  | report written; every line valid JSON and every export matched its snapshot (a clean run).                                                                                |
| `2`  | report **still written**, but ≥1 discrepancy (bad JSONL line, missing/invalid snapshot, scalar mismatch, an `error` event, or a truncated session) — open it and inspect. |
| `1`  | fatal: bad usage, missing/unreadable `session.jsonl`, or the report could not be written. No report produced.                                                             |

(`argparse` also exits `2` on usage error; both `2`s mean "inspect", and a usage error never reaches
the write path, so the report-written-vs-not distinction stays unambiguous.)

## What Spike 4 proves

- The 3.1C contract is **consumable by an external program with zero engine code** — only the two
  file shapes and the Python standard library.
- **Transcript + snapshots are sufficient** to reconstruct and visualize a run as an ordered timeline
  with a per-frame map — no filename inference, no access to the running game.
- The 3.1C build-invariant (`export` scalars equal the named snapshot) **holds for a real run**, now
  re-checked independently on the produced files.

## What it does NOT prove or solve

- **No backend change** — no gameplay, command, direction, protocol, socket, stdin/stdout mode, or
  JSONL command input; the tool only reads files.
- **No schema change** — snapshot and transcript JSON are consumed exactly as 3.1C writes them.
- **Not a faithful tileset render** — the map uses heuristic schematic glyphs from `ter`/`furn` ids,
  not the engine's real symbols/colours (see Future export work).
- **No dynamic entities** — the snapshot carries terrain/furniture only, so monsters, NPCs, vehicles,
  fields, and items do not appear.
- **Not live** — a one-way, after-the-fact read of a finished run; no following a run in progress
  beyond what a re-run of the tool shows.
- **Not a regression/CI harness** — it is a developer/inspection artifact, not an automated test.

## Future export work (documented, not added)

A richer viewer would want data the **current export does not provide**. These are backend export
enhancements for a later spike — Spike 4 invents none of them:

1. **Per-tile engine symbol + colour.** `write_tiles` emits only `ter`/`furn` ids + `seen`; the real
   display glyph/colour is not exported, forcing the viewer's heuristic glyphs. A resolved
   symbol/colour per tile would let the map match the game.
2. **Dynamic entities.** Monsters / NPCs / vehicles / fields / items have **no** positions in the
   snapshot (only terrain/furniture). A read-only nearby-entity export would let the map show what
   moves and what is dangerous — and would also unblock the deferred tick-witness harness from 3.1B.
3. **Explicit avatar marker in `tiles`.** The avatar is located only by matching `avatar.pos_local`
   to a tile `(x,y)`; an absent `pos_local` leaves it unplaceable. A per-tile `is_avatar` flag (or an
   avatar `(x,y)` header) would be unambiguous.
4. **Message severity / type / timestamp.** `write_messages` sets `type` to `""` always and drops the
   time-of-day the API returns; the viewer can show text only, with no severity colour or ordering.
5. **Tile elevation / multi-z.** `tiles` is one z-slice; stairs/ladders show as ids but not their
   destination level.
6. **`seed` in `session_start`.** Currently omitted (the CLI `--seed` is not threaded into the
   backend session), so the report cannot show a reproducibility seed.

## Files changed

| File                                    | Change                                                            |
| --------------------------------------- | ----------------------------------------------------------------- |
| `tools/arcopolis_viewer/make_report.py` | **new** — stdlib-only offline HTML report generator (the viewer). |
| `docs/arcopolis/12_…md`                 | this doc.                                                         |

No `src/` (C++) change. The generated report and any reused export dir live under the gitignored
`out/` directory.

## Validation

The viewer needs only a conforming Spike 3.1C export directory — **no engine build is required** if one
already exists. Produce one with the 3.1C positive run
([11_SPIKE3_1C_SESSION_TRANSCRIPT.md](11_SPIKE3_1C_SESSION_TRANSCRIPT.md) → Validation, which builds
the engine and runs `export → move_s → export → move_s → export → wait → export` into
`.\out\arco_3v1c`), or reuse an existing `.\out\arco_3v1c`. Then, from `<repo-root>`:

```powershell
# Positive: render a real export dir.
python .\tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_3v1c --output .\out\arco_3v1c_report.html
"exit=$LASTEXITCODE"                       # expect 0
Test-Path .\out\arco_3v1c_report.html      # expect True
Invoke-Item .\out\arco_3v1c_report.html    # opens in the default browser, offline
```

**Expected (positive):** exit `0`; the report exists and is non-empty; it shows `session_start` /
`session_end`, five `export` cards all **PASS** (turn/pos_abs/moves match their snapshots), the three
`command` events in order before their resulting exports, the `004_final.json` card flagged **final**,
and a 2D map per snapshot with `@` marking the avatar (centred at local `(85,85)` in `000_start.json`)
and unseen tiles dimmed; no Issues section.

```powershell
# Negative A: a malformed JSONL line + a deleted snapshot -> report still written, flagged.
Copy-Item .\out\arco_3v1c .\out\arco_neg -Recurse -Force
$sl = '.\out\arco_neg\session.jsonl'
$lines = Get-Content $sl ; $lines[2] = '{ this is NOT valid json' ; Set-Content $sl $lines -Encoding utf8
Remove-Item .\out\arco_neg\002_after_move2.json -Force
python .\tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_neg --output .\out\arco_neg_report.html
"exit=$LASTEXITCODE"                       # expect 2

# Negative B: no session.jsonl -> fatal, no report.
New-Item -ItemType Directory -Force .\out\arco_empty | Out-Null
python .\tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_empty --output .\out\arco_empty_report.html
"exit=$LASTEXITCODE"                       # expect 1
Test-Path .\out\arco_empty_report.html     # expect False
```

**Expected (negative):** A → exit `2`, the report is still written, and its **Issues** section lists
the malformed line (with its line number) and the missing snapshot, with a `DISCREPANCIES` badge. B →
exit `1`, stderr `fatal: session.jsonl not found …`, and **no** report file.

### Results (this run, 2026-06-03, Python 3.13)

Ran against the real engine-produced `arco_3v1c` export from the 3.1C validation (stdlib only — no
venv, no pip). `python -m py_compile` clean.

- **Positive** → exit `0`; report written (≈316 KB). stdout:
  `[OK] exports=5 pass=5 fail=0 missing=0 bad_lines=0 errors=0`. All five export cards PASS:

  | export `path`          | `final`  | `turn` == snapshot | `moves` == snapshot | `pos_abs` == snapshot | avatar `@` (local) |
  | ---------------------- | -------- | ------------------ | ------------------- | --------------------- | ------------------ |
  | `000_start.json`       | false    | 1324801 ✅         | 99 ✅               | `[6301,6421,0]` ✅    | `(85,85)` ✅       |
  | `001_after_move1.json` | false    | 1324802 ✅         | 98 ✅               | `[6301,6422,0]` ✅    | `(85,86)` ✅       |
  | `002_after_move2.json` | false    | 1324803 ✅         | 72 ✅               | `[6301,6423,0]` ✅    | `(85,87)` ✅       |
  | `003_after_wait.json`  | false    | 1324804 ✅         | 100 ✅              | `[6301,6423,0]` ✅    | `(85,87)` ✅       |
  | `004_final.json`       | **true** | 1324804 ✅         | 100 ✅              | `[6301,6423,0]` ✅    | `(85,87)` ✅       |

  35/35 scalar checks matched (3 core + 4 bonus per export); the avatar marker tracks the two `move_s`
  steps south (`y` 85 → 86 → 87) and holds through `wait`/`final`, mirroring the transcript exactly.
- **Negative A** (broken line + deleted `002`) → exit `2`, report still written;
  `[DISCREPANCIES] exports=5 pass=4 fail=0 missing=1 bad_lines=1`; Issues section lists the malformed
  line and `snapshot file not found: 002_after_move2.json`.
- **Negative B** (no `session.jsonl`) → exit `1`, `fatal: session.jsonl not found …`, no report.

## Citation / contract audit

Each report behaviour traced to the producer source it consumes (`src/arcopolis_export.cpp` writes the
snapshot; `src/arcopolis_session_log.cpp` writes the transcript):

| Report behaviour                                                | Producing line(s)                                                                                 | Verdict |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------- |
| `export.turn` checked against `backend.turn`                    | `write_backend` `member("turn", to_turn<int>(calendar::turn))`; `current_snapshot_summary().turn` | ✅ e2e  |
| `export.pos_abs` checked against `avatar.pos_abs`               | `write_avatar` `pos_abs = u.abs_pos()`; `current_snapshot_summary().pos_abs_*`                    | ✅ e2e  |
| `export.moves` checked against `avatar.moves`                   | `write_avatar` `member("moves", u.get_moves())`; `current_snapshot_summary().moves`               | ✅ e2e  |
| bonus `session.*` cross-checks                                  | `write_session` (`export_index`, `step_index` opt-null, `export_name`, `final`)                   | ✅ e2e  |
| map tiles are a radius-12 **local** window, clamp-safe          | `write_tiles` `points_in_radius(u.bub_pos(), radius)` + `if(!m.inbounds(p)) continue`             | ✅      |
| avatar cell == `avatar.pos_local`                               | `write_avatar` `pos_local = u.bub_pos()` (same centre `write_tiles` uses)                         | ✅      |
| dimmed tiles are real LOS, not invented                         | `write_tiles` `member("seen", m.pl_sees(p, radius))`                                              | ✅      |
| each glyph from `ter`/`furn` ids only (no engine symbol exists) | `write_tiles` emits `ter`/`furn` id strings + `seen`; no symbol/colour field                      | ✅      |
| message text shown, severity omitted (not in export)            | `write_messages` `member("type", std::string{})` (always blank) + a diagnostic warning            | ✅      |
| `export.path` joined as a relative filename                     | `write_session_snapshot` passes the relative `filename`, never an absolute path                   | ✅      |
| every transcript line parsed as one JSON object                 | `write_*_line` (`JsonOut`, one object, `out << '\n'`)                                             | ✅      |
| no snapshot/transcript schema change                            | no `src/` edit in this spike (tool + doc only)                                                    | ✅      |
