# Arcopolis canonical regression fixtures

This directory holds the **committed, canonical save worlds** the Arcopolis regression scripts load. They
are **regression inputs, not gameplay examples** — do not treat them as demo saves or edit them casually.

Previously these worlds lived only outside the repo at `C:\dev\arcopolis-fixtures\arcopolis_user` (saves are
gitignored), which made the suite impossible to reproduce without recreating that directory by hand.
Committing a minimal, curated pack here makes the regressions runnable from a clean checkout by future
agents, CI, and contributors.

## Layout

```
docs/arcopolis/fixtures/arcopolis_user/
  config/options.json          # the one config file the scripts read/patch (see "Why config/options.json")
  save/<World>/                # the thirteen canonical worlds
```

## Fixture root resolution (default + override)

Every `docs/arcopolis/*_regression.ps1` script and every `make_*_fixture.py` generator resolves the fixture
root with this precedence:

1. **Explicit** — the script's `-FixtureSrc <path>` parameter, or a generator's `--fixture-root <path>`.
2. **`ARCO_FIXTURE_ROOT`** environment variable (an empty value is ignored, so it never shadows the default).
3. **Repo-local default** — `docs/arcopolis/fixtures/arcopolis_user` (this directory). **No external setup
   required.**
4. **Optional external dev fallback** — `C:\dev\arcopolis-fixtures\arcopolis_user`, used only if it exists.

The shared resolver is [`docs/arcopolis/arco_fixture_root.ps1`](../arco_fixture_root.ps1) (dot-sourced by
every regression script) and `_default_fixture_root()` in each generator. To point the suite at an external
root for a one-off:

```powershell
$env:ARCO_FIXTURE_ROOT = "C:\dev\arcopolis-fixtures\arcopolis_user"
pwsh -File .\docs\arcopolis\movement_regression.ps1
Remove-Item Env:\ARCO_FIXTURE_ROOT
```

**Run the regressions with `pwsh` (PowerShell 7), not `powershell` (5.1)** — 5.1 misreads BOM-less UTF-8
snapshots and writes an options.json BOM, causing spurious gate failures on unchanged code.

## Included worlds and what each witnesses

`ArcopolisTest` is the base world; the rest are clones of it — or of `ArcopolisBackpackTest`, itself a
GUI-built base variant — each adding deterministic witness elements. The full witness-role write-up
lives in [`docs/arcopolis/TEST_FIXTURES.md`](../TEST_FIXTURES.md); summary:

| World                            | Witnesses                                                                                               | Refresh                                      |
| -------------------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `ArcopolisTest`                  | base: movement / NPC-export / item-export / live-protocol; driven WIELD capacity (Spike 14)             | base world (GUI-created); not regenerated    |
| `ArcopolisNearMonsterTest`       | monster-export (`mon_fungal_wall` in the r12 window)                                                    | `make_monster_fixture.py`                    |
| `ArcopolisBackpackTest`          | multi-item carry-both (Spike 12A); avatar wears a `backpack`                                            | base + worn backpack (GUI); not regenerated  |
| `ArcopolisCarriedNestedTest`     | on-person dialogue-predicate `has_item` query + Stage A carried-at-contact (Spikes 26A / doc 53)        | `make_carried_nested_fixture.py`             |
| `ArcopolisVehicleCargoTest`      | driven vehicle-source `uilist` (Spike 13B) + vehicle-`examine` fail-loud (Spike 21)                     | `make_vehicle_fixture.py`                    |
| `ArcopolisCapacityTest`          | driven secondary-capacity/wield `uilist` (Spike 14)                                                     | `make_capacity_fixture.py`                   |
| `ArcopolisDeployedFurnitureTest` | driven `query_popup` / `query_yn` (Spike 15)                                                            | `make_furniture_fixture.py`                  |
| `ArcopolisWallTest`              | genuine terrain `blocked_no_op` (Spike 21)                                                              | `make_wall_fixture.py`                       |
| `ArcopolisStairsTest`            | aligned two-floor stair fixture (Spike 23); matched-stair `vertical_move` down→up round trip (Spike 24) | `make_stairs_fixture.py`                     |
| `ArcopolisLivenessTest`          | world-tick liveness: a hostile mobile `mon_zombie` acts on its own engine turn (Spikes 27A/27B)         | `make_monster_fixture.py` (hostility flags)  |
| `ArcopolisTwoZombieTest`         | attacker per-instance ambiguity shadow-test — two same-type attackers, no join key (doc 59)             | `make_monster_fixture.py` (`--extra-offset`) |
| `ArcopolisSliceTest`             | 2-floor vertical-slice composite with a `box_small` package at z=−1 (folded Spike 28, gate G3)          | `make_stairs_fixture.py` (slice flags)       |
| `ArcopolisTowerTest`             | 6-floor traversal + deepest-floor composite; floors z=−2..−5 synthesized (folded Spike 28, G2/G4)       | `make_stairs_fixture.py` (tower flags)       |

## Refreshing / regenerating a generated world

The `make_*_fixture.py` generators each clone a source world and apply deterministic save-edits
(no GUI, no build). With the repo-local default they refresh the committed world **in place**:

```powershell
python .\docs\arcopolis\make_monster_fixture.py     # rewrites save/ArcopolisNearMonsterTest
python .\docs\arcopolis\make_vehicle_fixture.py     # rewrites save/ArcopolisVehicleCargoTest
python .\docs\arcopolis\make_capacity_fixture.py    # rewrites save/ArcopolisCapacityTest
python .\docs\arcopolis\make_furniture_fixture.py   # rewrites save/ArcopolisDeployedFurnitureTest
python .\docs\arcopolis\make_wall_fixture.py        # rewrites save/ArcopolisWallTest
python .\docs\arcopolis\make_stairs_fixture.py      # rewrites save/ArcopolisStairsTest
python .\docs\arcopolis\make_carried_nested_fixture.py  # rewrites save/ArcopolisCarriedNestedTest
# ArcopolisLivenessTest / ArcopolisTwoZombieTest: make_monster_fixture.py with the opt-in hostility /
# --extra-offset flags — the exact invocations live in the generator docstring and TEST_FIXTURES.md.
# the folded-Spike-28 slice worlds (clone ArcopolisBackpackTest, not ArcopolisTest — doc 61):
python .\docs\arcopolis\make_stairs_fixture.py --source-world ArcopolisBackpackTest `
    --dest-world ArcopolisSliceTest --package-typeid box_small --package-offset 0,2,-1 --force
python .\docs\arcopolis\make_stairs_fixture.py --source-world ArcopolisBackpackTest `
    --dest-world ArcopolisTowerTest --floors 6 --package-typeid box_small --package-offset 0,6,-5 --force
```

Pass `--fixture-root <path>` (or set `ARCO_FIXTURE_ROOT`) to read/write a different root. `ArcopolisTest`
and `ArcopolisBackpackTest` are not script-generated — recreate them via the graphical client (New Game →
one step → Save & Quit; backpack added to `player.worn`), as documented in the spike history.

## Why `config/options.json` is committed (and nothing else from `config/`)

The engine loads a world from `save/<World>/` alone — `config/` is **not** required to load and export
(verified). But four scripts (`prompt_menu`, `examine`, `query_popup`, `script_prompt`) pin deterministic
options by patching `config/options.json` in the sandbox copy, and that patch reads the file (it throws if
absent). So this one file is committed; it is BOM-less and contains no personal data.

## What must NOT be committed here

Keep this pack minimal and clean. **Do not commit:**

- generated regression outputs, session transcripts, or snapshot JSON;
- screenshots or any images;
- crash dumps (`*.dmp`), crash logs, or diagnostic logs (`config/debug.log`, `config/crash.log`);
- temp/cache/editor/OS files;
- experimental or unrelated save worlds (only the thirteen worlds above belong here);
- user/profile config not needed to load the worlds (`fonts.json`, `base_colors.json`, `lastworld.json`,
  `templates/`);
- anything containing local absolute paths, usernames, or other personal data.

**Allowed** save-required binaries: `map.sqlite3` and the per-character `*.sqlite3`. Tiny save-internal
`*.log` files (the per-character memorial line) are allowed **only** because they are part of the world save
structure and carry no personal/local-path data.

## Size

~17 MB across the thirteen worlds (each ~1.3 MB, dominated by a 1.2 MB `map.sqlite3`;
`ArcopolisTowerTest`'s 196 synthesized quad rows compress to ~60 KB extra) plus a 63 KB `options.json`.
Normal Git — **no Git LFS**.

## When to change fixture data

Treat the bytes here as a frozen contract. **Change a world only when a regression contract changes** (a new
witness element, a deliberate re-baseline). Regenerate generated worlds with the `make_*_fixture.py` script
that owns them so the change is reproducible and reviewable, and update `TEST_FIXTURES.md` to match.
