# Spike 5 — Export cheap wins / contract hygiene

> **Status: ✅ implemented (2026-06-03).** Two **lowest-risk, additive** items from Spike 4's doc 12
> §"Future export work": an explicit per-tile **avatar marker** in the snapshot, and the original
> **`--seed`** string in the transcript's `session_start`. **No shared gameplay/system files are
> touched beyond `main.cpp` argument plumbing** — no turn-loop, command dispatch, messages, map,
> monster, NPC, or gameplay-behavior change. Builds on
> [12_SPIKE4_OFFLINE_SESSION_VIEWER.md](12_SPIKE4_OFFLINE_SESSION_VIEWER.md).

## Why this is "Spike 5"

Spikes 3.1A/B/C were point releases on the movement spike (each only adjusted the backend boundary);
Spike 4 was a consumer-only viewer. This is the **first change to the export contract itself since
3.1C**, so it earns a new number — but it is deliberately the _smallest_ such change: the "cheap
wins" slice of doc 12's future-export backlog. The heavier items (dynamic entities, per-tile
symbol/colour, message type/severity, multi-z) are **explicitly deferred** (see below).

## Scope

- **#3 — explicit avatar marker.** `tiles[]` carries a per-tile `"is_avatar": true` on the one tile
  the avatar occupies, so a reader need not re-derive it by matching `avatar.pos_local`.
- **#6 — seed in `session_start`.** The stateful script runner records the original `--seed` CLI
  string in the transcript's `session_start` record (omitted when no `--seed` was passed).

Both are read-only and additive (the proven Spike 0/2 export pattern). Snapshot and transcript
`schema_version` stay **1** (BN readers skip unknown members).

## Change 1 — avatar marker (`is_avatar`)

`write_tiles` ([src/arcopolis_export.cpp](../../src/arcopolis_export.cpp)) already centres its
single-z square window on `center = ctx.u.bub_pos()` — the same coordinate `write_avatar` serializes
as `avatar.pos_local`. Exactly one tile in that window equals `center`, so the marker is emitted
there and **nowhere else** (absent ⇒ not the avatar; lean and additive):

```cpp
json.member( "seen", ctx.m.pl_sees( p, ctx.radius ) );
if( p == center ) {
    json.member( "is_avatar" );
    json.write( true );
}
```

The offline viewer ([tools/arcopolis_viewer/make_report.py](../../tools/arcopolis_viewer/make_report.py),
`render_map_html`) now **prefers** the flag, falling back to the coordinate match for pre-Spike-5
snapshots:

```python
is_avatar = bool(tile.get("is_avatar")) or (avatar_in_window and x == ax and y == ay)
```

Because the marker is written at `p == center` and `avatar.pos_local == center`, the flag and the
fallback resolve to the **same** cell — the viewer's behaviour is unchanged on existing data and
unambiguous on new data.

## Change 2 — seed in `session_start`

The transcript side already supported `seed` end-to-end: `session_start_event.seed` is
`std::optional<std::string>` ([src/arcopolis_session_log.h](../../src/arcopolis_session_log.h)) and
`write_session_start_line` emits it only when present
([src/arcopolis_session_log.cpp](../../src/arcopolis_session_log.cpp)); both the present and absent
cases are already unit-tested
([tests/arcopolis_session_log_test.cpp](../../tests/arcopolis_session_log_test.cpp)). The only gap
was CLI plumbing — `--seed` is hashed to an `int` and the original string discarded. Three additive
hops close it:

1. **[src/main.cpp](../../src/main.cpp)** — a new `std::optional<std::string> seed_arg` is set to the
   original argument inside the `--seed` handler (alongside the existing `djb2_hash`), and passed as
   `.seed = seed_arg` to `run_script(...)`.
2. **[src/arcopolis_script.h](../../src/arcopolis_script.h)** — `run_script_options` gains
   `std::optional<std::string> seed`.
3. **[src/arcopolis_script.cpp](../../src/arcopolis_script.cpp)** — `run_script` passes
   `.seed = opts.seed` to `begin_session_log(...)` (was hard-coded `std::nullopt`).

### Seed semantics (important)

The recorded value is the original `--seed` **CLI string** — the **reproducibility input**, not the
internal RNG integer (`djb2_hash(string)`) that is actually fed to the engine. It is **omitted** when
no `--seed` was passed (the run used a time-based RNG seed and is not reproducible).

This is provenance/repro **metadata, not a complete repro key**: re-running with the same `--seed`
reproduces the RNG draws, but a run also depends on the loaded world/save fixture state, so the seed
alone does not guarantee a byte-identical run. The one-shot path (`export_current_view`) is
unaffected — it writes no transcript and therefore no `session_start`.

## What this spike does NOT do (deferred)

These remain on doc 12's future-export backlog and are **not** in this spike:

- **#4 message type/severity** — `game_message.type` is private and `Messages::` exposes no typed
  accessor, so this needs a new public read-only accessor in the shared engine `src/messages.{h,cpp}`
  — out of the "cheap wins / no shared-system-file" scope. Deferred to the richer-export spike.
- **#1 per-tile symbol/colour**, **#2 dynamic entities** (monsters/NPCs/items/fields/vehicles),
  **#5 tile elevation / multi-z** — the larger read-only export work.
- No new command/gameplay, no protocol/socket, no snapshot- or transcript-`schema_version` change.

## Files changed

| File                                          | Change                                                                     |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| `src/arcopolis_export.cpp`                    | `write_tiles`: emit `"is_avatar": true` on the avatar's tile.              |
| `src/arcopolis_script.h`                      | `run_script_options`: add `std::optional<std::string> seed`.               |
| `src/arcopolis_script.cpp`                    | `run_script`: pass `.seed = opts.seed` to `begin_session_log`.             |
| `src/main.cpp`                                | capture the original `--seed` string and forward it to `run_script`.       |
| `tools/arcopolis_viewer/make_report.py`       | `render_map_html`: prefer `is_avatar`, fall back to the `pos_local` match. |
| `docs/arcopolis/13_…md`, `ARCOPOLIS_STATE.md` | this doc + the current-truth checkpoint page.                              |

No engine system files (`messages`, `map`, `game`, turn loop) are touched. CMake needs no edit
(`src/`/`tests/` are globbed).

## Validation

Build the game **and** tests in the single `win-rel-deb` dir (shared `cataclysm-bn-tiles-common`
OBJECT library — see [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)). Copy the
external `ArcopolisTest` fixture first.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force
New-Item -ItemType Directory -Force .\out | Out-Null

@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "start" },
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export",  "name": "after_move" }
] }
'@ | Set-Content -Encoding ascii .\out\arco_s5.json

# With --seed: session_start.seed == the CLI string; exactly one tile is_avatar at pos_local.
& $exe --world ArcopolisTest --seed arco-s5 --arcopolis-run-script .\out\arco_s5.json --arcopolis-export-dir .\out\arco_s5 --userdir .\arcopolis_user
$start = Get-Content .\out\arco_s5\session.jsonl | Select-Object -First 1 | ConvertFrom-Json
"seed = $($start.seed)"                                   # expect arco-s5
$snap = Get-Content .\out\arco_s5\000_start.json -Raw | ConvertFrom-Json
$av = @($snap.tiles | Where-Object { $_.is_avatar })
"is_avatar count = $($av.Count)"                          # expect 1
"flag tile = [$($av[0].x),$($av[0].y)]  pos_local = [$($snap.avatar.pos_local[0]),$($snap.avatar.pos_local[1])]"  # expect equal

# Without --seed: session_start has no seed member.
& $exe --world ArcopolisTest --arcopolis-run-script .\out\arco_s5.json --arcopolis-export-dir .\out\arco_s5_noseed --userdir .\arcopolis_user
$start2 = Get-Content .\out\arco_s5_noseed\session.jsonl | Select-Object -First 1 | ConvertFrom-Json
"has seed (expect False) = " + ($null -ne $start2.PSObject.Properties['seed'])
```

Unit run: `& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"`. Viewer:
`python tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_s5 --output .\out\arco_s5_report.html` (exit 0).

### Results (this run, 2026-06-03, MSVC/Ninja/ccache `win-rel-deb`)

Built `cataclysm-bn-tiles` + `cata_test-tiles` in the single `win-rel-deb` dir — both exit 0, no
errors on the changed files.

- **Unit:** `cata_test-tiles "[arcopolis]"` → **All tests passed (204 assertions in 41 test cases)** —
  unchanged from 3.1C (the seed formatter cases already existed; `is_avatar` / seed plumbing are
  e2e-proven).
- **E2e, with `--seed arco-s5`** (`export → move_s → export`) → exit `0`:
  - `session.jsonl` `session_start.seed == "arco-s5"`.
  - `000_start.json`: exactly **one** `is_avatar` tile at `(85,85)`, equal to `avatar.pos_local`.
  - `001_after_move.json`: exactly **one** `is_avatar` tile at `(85,86)`, equal to `avatar.pos_local`
    — the marker tracks the `move_s`.
- **E2e, no `--seed`** → exit `0`; `session_start` has **no** `seed` member.
- **Viewer:** `make_report.py --session-dir .\out\arco_s5` → exit `0`, `exports=3 pass=3 fail=0`; the
  report shows seed `arco-s5` and renders the avatar `@` cell (now driven by `is_avatar`).

## Citation audit

| Claim                                                     | Implementing line(s)                                                                | Verdict                          |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------- |
| `is_avatar` emitted only on the avatar's tile             | `write_tiles` `if( p == center ) { member("is_avatar"); write(true); }`             | ✅ e2e (count==1)                |
| Avatar tile == `avatar.pos_local`                         | `center = ctx.u.bub_pos()`, the same accessor `write_avatar` writes as `pos_local`  | ✅ e2e (flag==pos_local)         |
| Viewer prefers the flag, falls back to coordinates        | `render_map_html` `bool(tile.get("is_avatar")) or (… x==ax and y==ay)`              | ✅ (viewer exit 0, `@` rendered) |
| Seed recorded is the `--seed` string, omitted when absent | `main.cpp` `seed_arg = params[0]` → `run_script_options.seed` → `begin_session_log` | ✅ e2e (present/absent)          |
| Transcript writer already emits seed conditionally        | `write_session_start_line` `if( ev.seed ) member("seed", *ev.seed)`                 | ✅ (unit + e2e)                  |
| No snapshot/transcript `schema_version` change            | snapshot/transcript writers' `schema_version` unchanged (additive members only)     | ✅                               |
