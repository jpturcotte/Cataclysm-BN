# Spike 6B — deterministic monster witness fixture

> **Status: ✅ validated (docs/script, no engine change).** Spike 6A shipped the `entities.monsters[]`
> exporter but the only fixture we had (`ArcopolisTest`) has no monster inside the radius-12 window, so the
> shipped contract was **present-but-empty** there and could only be proven with a throwaway radius-60 probe.
> This spike adds a **second fixture** — `ArcopolisNearMonsterTest`, one witness monster inside the window —
> built by a **scripted save-injector** (`make_monster_fixture.py`, no GUI, no build) and gated by
> `monster_export_regression.ps1`. Both were run end-to-end against the Spike 6A engine build: the gate
> passes **exit 0** (`exports=3 pass=3 monsters_off_window=0`). No backend, schema, command, or viewer code
> changes. Builds on [14_SPIKE6_MONSTER_EXPORT.md](14_SPIKE6_MONSTER_EXPORT.md).

## Why this is the right next move

After Spike 6A the backend was **slightly ahead of the fixtures.** We had a real movement seam, a transcript,
snapshots, an offline viewer, the monster exporter, and a movement-regression script — but no small,
deterministic world-state **witness for dynamic entities**. Without one, every dynamic-export test is
half-manual or leans on ad-hoc fixture facts.

The gap was concrete. In `ArcopolisTest` the avatar is boxed in an evac shelter at local `(85,85)`
(`abs_pos [6301,6421,0]`) and the nearest of the world's 14 monsters is **Chebyshev 31 tiles away**, so at
the shipped radius 12 its `entities.monsters[]` is correctly **present-but-empty** — that fixture can never
satisfy a `count > 0` gate. Spike 6A only proved emission by **temporarily** raising the view radius to 60 (a
probe that was reverted — see [14_SPIKE6_MONSTER_EXPORT.md](14_SPIKE6_MONSTER_EXPORT.md), "Fixture finding").

Spike 6B makes the contract witnessable: a second fixture with one monster **inside** the radius-12 window,
plus a script that gates `entities.monsters` present / `count > 0` / `off-window == 0` / viewer exit 0. The
goal is **not** more export fields — it is to turn a present-but-empty contract into a tested one.

## The two-fixture split

| Fixture                    | Role                       | Monster situation at r12                     | Gated by                        |
| -------------------------- | -------------------------- | -------------------------------------------- | ------------------------------- |
| `ArcopolisTest`            | movement / NPC (unchanged) | present-but-**empty** (14 monsters ≥31 away) | `movement_regression.ps1`       |
| `ArcopolisNearMonsterTest` | **monster-export witness** | `count > 0` (one witness monster in-window)  | `monster_export_regression.ps1` |

`ArcopolisTest` keeps doing exactly what it did: the avatar in the shelter, NPC Edwardo Stovall one tile north
(the documented `move_n` no-op, see [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)),
14 monsters out of window. It is **not** modified. `ArcopolisNearMonsterTest` is a **clone** of it with one
extra monster, in the **same** external fixture userdir (a second world), so one
`Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force` brings both.

## The witness monster, and what "deterministic" means here

The witness is a **`mon_fungal_wall`** (HP 20), an `IMMOBILE`-flagged type
([`data/json/monsters/fungus.json`](../../data/json/monsters/fungus.json) — `"flags": ["NOHEAD", "POISON",
"NO_BREATHE", "IMMOBILE"]`; `MF_IMMOBILE` = "Doesn't move & doesn't use non-special attacks",
[`src/mtype.h:123`](../../src/mtype.h)). It is chosen because, unlike the stock wildlife, it does **not**
wander turn-to-turn — so the in-window set is stable.

**Behaviour (validated):** placed on **passable terrain** (the default offset `0,8,0` = grass south of the
shelter, `[6301,6429,0]`), the witness is **exactly stationary** — `pos_abs`/`pos_local` are identical on
every exported frame, every run, with **no `--seed`**. So "deterministic" here is literal: a fixed tile, plus
in-window `count > 0` / `off-window == 0`.

> **Terrain matters — the one rule.** An early version used offset `0,6,0`, which lands on the shelter's
> **south wall** (`t_wall_w`, impassable). At load the monster is placed at its exact `pos_abs` with no
> terrain check, but on the first turn `game::monmove`'s lifecycle guard teleports any critter off an
> impassable tile (radius-3 search) — or **kills it** if no passable tile is within 3. That produced a
> one-time deterministic `(-3,-3)` "drift toward the avatar" that looked like it broke immobility. It did
> not: on passable terrain the guard never fires and the `IMMOBILE` type never wanders. Full line-by-line
> trace + experiments: [17_MONSTER_LOAD_AND_WALL_EJECT.md](17_MONSTER_LOAD_AND_WALL_EJECT.md).

(Spawned/edited monsters live in the save's `active_monsters` list —
[`src/savegame.cpp:143`](../../src/savegame.cpp) on save, `:337` on load — so the witness reloads from its
stored `pos_abs`; the engine resolves `type_id` and rebuilds the type's body, so the exported
`hp_max`/`symbol` come from the engine, not from the edited blob.)

## Creating / updating the fixture — `make_monster_fixture.py` (scripted, no GUI, no build)

The headless modes can load a world but cannot yet create one (the `--arcopolis-new-world` generator is
deferred — [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) backlog). Rather than author the fixture by hand in the
graphical client, [`make_monster_fixture.py`](make_monster_fixture.py) (stdlib-only, read-only on
`ArcopolisTest`) does it reproducibly:

```powershell
python docs/arcopolis/make_monster_fixture.py            # clones ArcopolisTest -> ArcopolisNearMonsterTest
python docs/arcopolis/make_monster_fixture.py --force    # overwrite an existing witness world
# options: --monster mon_fungal_wall  --offset 0,8,0  --fixture-root <userdir>  --dest-world <name>
```

It clones the world folder, then **deep-copies a real, engine-written monster** already in the save (a stock
groundhog — so every required field is present and well-formed) and overlays only what defines a fresh
witness: `typeid → mon_fungal_wall`, `pos_abs → avatar + offset` (default `0,8,0` = grass, passable),
`hp/speed` reset, `body` dropped (so the engine rebuilds the `NOHEAD` fungal-wall body), and `last_updated →
turn`. It does **not** hand-author a monster from scratch, which is what keeps the object engine-loadable. It
also reads `map.sqlite3` and **warns if the target tile looks impassable** — because a monster on impassable
terrain is teleported or killed on the first turn (see
[17_MONSTER_LOAD_AND_WALL_EJECT.md](17_MONSTER_LOAD_AND_WALL_EJECT.md)).

> **Why save-injection is legitimate, not "faking state":** it only authors an **initial world condition** —
> exactly what the graphical debug "Spawn monster" does — and the engine then simulates faithfully. The
> exported values are the engine's, not the editor's. (See the fidelity rule in
> [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md): never fake _runtime_ engine state; this authors a save, then lets
> the engine run.)

**Alternative (graphical):** clone the world folder, set `RENDERER=opengl` in `config/options.json`, launch
`cataclysm-bn-tiles.exe --world ArcopolisNearMonsterTest --userdir .\arcopolis_user`, debug-menu **Spawn
monster** (`debug_menu::wishmonster`, [`src/wish.cpp:578`](../../src/wish.cpp)) a `mon_fungal_wall` a few
tiles from the avatar, then **Save & Quit**. After either method, copy the new world back into the external
fixture root and add a line to `C:\dev\arcopolis-fixtures\README.md` (that README is outside the repo).

**Authoring mistakes the builder guards against:** an offset with Chebyshev > 12 puts the witness **outside**
the window ⇒ the gate fails with `count 0` ("present but empty"); an offset onto **impassable terrain** (a
wall/tree) makes the engine teleport the witness (radius-3) or, if walled in, **kill it** ⇒ it drifts or
vanishes ([doc 17](17_MONSTER_LOAD_AND_WALL_EJECT.md)). The builder warns on both (over-large offset; a tile
that looks impassable in `map.sqlite3`).

## The regression — `monster_export_regression.ps1`

A sibling of [`movement_regression.ps1`](movement_regression.ps1) with the same shape (param block,
`$ErrorActionPreference = "Stop"`, gitignored-sandbox refresh, the `Start-Process -Wait -PassThru` pattern a
GUI-subsystem exe needs, `ConvertFrom-Json` reads, a single `$fail` accumulator, `exit 1`/`exit 0`). It runs
a fixed `export(witness_load) → wait → export(witness_after_tick)` script over `ArcopolisNearMonsterTest` (the
`wait` ticks the world one turn — in the validated run `turn 1324801 → 1324802`), then asserts:

| Gate | Assertion                                                 | How                                                                                |
| ---- | --------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 1    | `entities.monsters` is **present** on each snapshot       | property-bag test (`$snap.PSObject.Properties['entities']` …), not truthiness      |
| 2    | `entities.monsters` **count > 0**                         | `@($snap.entities.monsters).Count` — `@()`-wrap first (a single monster is scalar) |
| 3    | **off-window == 0** on each snapshot                      | build the `"x,y,z"` set from `tiles[]`, assert each monster's `pos_local` is in it |
| 4    | viewer **exits 0** AND prints **`monsters_off_window=0`** | `make_report.py` via `Start-Process`, parse stdout with `[regex]::Match`           |

It also **reports** (soft, non-fatal) whether each monster carries the 10-field contract; flip the marked
`$fail++` to make that a hard gate. Gate 4 is partly redundant with gate 3 by design — the viewer already ANDs
`monsters_off_window==0` into pass/fail, so its exit 0 is itself end-to-end — but it does **not** require
`count > 0` (a present-but-empty array passes the viewer), which is why gate 2 is a separate local check.

### Exit codes

| code | meaning                                                                   |
| ---- | ------------------------------------------------------------------------- |
| 0    | all hard gates passed                                                     |
| 1    | a hard assertion failed (aggregated across frames + the viewer)           |
| 3    | exe missing                                                               |
| 4    | fixture userdir missing                                                   |
| 5    | `save\ArcopolisNearMonsterTest` missing — **run make_monster_fixture.py** |
| 6    | `python` not on PATH (the viewer needs it)                                |
| 7    | viewer `make_report.py` missing                                           |

(The guards use a `Stop-WithCode` helper: under `$ErrorActionPreference = "Stop"` a bare `Write-Error; exit N`
throws before `exit` runs and would collapse every guard to exit 1, so `-ErrorAction Continue` is used to
return the real code. `movement_regression.ps1` still has the bare form — low impact there.)

## Validation (run, not just described)

Validated **without a fresh build**: a 6A-capable `cataclysm-bn-tiles.exe` was already on disk in a sibling
worktree (the `feat/arcopolis-spike6a-monster-export` branch build); a fresh build was skipped because free
disk was tight (~7.6 GB) and the existing build already contains the `entities.monsters[]` exporter. Run from
the repo root with `-Exe` pointed at that build:

```powershell
python docs/arcopolis/make_monster_fixture.py --force
.\docs\arcopolis\monster_export_regression.ps1 -Exe <path-to-6A-build>\cataclysm-bn-tiles.exe
```

Observed (engine exit 0 throughout), default offset `0,8,0` (grass):

```
terrain at witness tile: t_grass  (passable)
created world : …\save\ArcopolisNearMonsterTest   witness mon_fungal_wall @ pos_abs [6301,6429,0] (cheb 8)
[000_witness_load.json]       PASS: 1 monster(s), all in-window (off=0).  mon_fungal_wall @ 85,93,0
[001_witness_after_tick.json] PASS: 1 monster(s), all in-window (off=0).  mon_fungal_wall @ 85,93,0
[002_final.json]              PASS: 1 monster(s), all in-window (off=0).  mon_fungal_wall @ 85,93,0
[viewer] exit=0  …  exports=3 pass=3 fail=0 … monsters_off_window=0
MONSTER EXPORT REGRESSION: ok.            # exit 0
```

The witness's `pos_abs` is **identical on every frame** (`[6301,6429,0]`) — exactly stationary, reproducible
across rebuilds. (The earlier in-wall offset `0,6,0` drifted `[6301,6427] → [6298,6424]` once; that is the
`game::monmove` impassable-eject, root-caused in
[17_MONSTER_LOAD_AND_WALL_EJECT.md](17_MONSTER_LOAD_AND_WALL_EJECT.md).) Negative checks confirm the gate has
teeth: `-World ArcopolisTest` ⇒ **exit 1** (`count 0`, present-but-empty); a missing witness world ⇒
**exit 5**. The `[arcopolis]` unit suite is unchanged by this PR (it is pure formatters/parsers).

## Files

| File                                             | Change                                                               |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| `docs/arcopolis/make_monster_fixture.py`         | **new** — scripted fixture builder (clone + save-inject the witness) |
| `docs/arcopolis/monster_export_regression.ps1`   | **new** — the witness gate                                           |
| `docs/arcopolis/16_…md`                          | this doc                                                             |
| `docs/arcopolis/17_…md`                          | **new** — line-by-line monster load / wall-eject root-cause analysis |
| `docs/arcopolis/ARCOPOLIS_STATE.md`, `AGENTS.md` | two-fixture split + Spike 6B capability row + fixture pointer        |

## Citation audit

| Claim                                                            | Evidence                                                                                                                                         | Verdict |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| Gate passes against the real 6A engine (count>0, off-window 0)   | end-to-end run, `exports=3 pass=3 monsters_off_window=0`, exit 0 (Validation)                                                                    | ✅      |
| Witness loads as a real `mon_fungal_wall` (engine-resolved type) | export shows `type_id=mon_fungal_wall`, `hp_max=20` (from the type, not the edited blob)                                                         | ✅      |
| On passable terrain the witness is exactly stationary            | `pos_abs [6301,6429,0]` identical on frames 000/001/002 (Validation, default offset)                                                             | ✅      |
| The in-wall drift is the monmove impassable-eject, not AI        | `game::monmove` lifecycle teleports critters off impassable tiles ([`src/game.cpp:5994`](../../src/game.cpp)); see doc 17                        | ✅      |
| `MF_IMMOBILE` is read from the type via `has_flag` (so it idles) | `monster::has_flag` returns `type->has_flag(f)` OR `monster_flags` ([`src/monster.cpp:1149`](../../src/monster.cpp)); idle at `monmove.cpp:1029` | ✅      |
| `batch_turns` (load catch-up) never changes position             | early `return` for `n<=0`, ends `moves=0`, no `setpos` ([`src/monster.cpp:2971`](../../src/monster.cpp)); builder sets `last_updated=turn`       | ✅      |
| Injected monster persists at its tile on reload                  | `active_monsters` serialize/deserialize [`src/savegame.cpp:143`](../../src/savegame.cpp) / `:337`                                                | ✅      |
| Viewer exit 0 requires `monsters_off_window == 0` (gate 4)       | `build_model` ANDs it into `overall_pass` ([`tools/arcopolis_viewer/make_report.py`](../../tools/arcopolis_viewer/make_report.py))               | ✅      |
| Single-monster JSON is a scalar in PowerShell (needs `@()`)      | doc-14 validation snippet uses `@($snap.entities.monsters)`                                                                                      | ✅      |
