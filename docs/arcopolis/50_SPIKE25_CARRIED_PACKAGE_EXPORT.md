# Spike 25 — carried-package observability v0 (`avatar.carried_items[]`)

> **Correction (post-implementation): this export is display/observability ONLY.** Spike 25 is logged as a
> **process-failed spike** — the code is correct and merged, but it was framed as resolving the Stage A
> carried-package blocker, which is a **possession-validation** question BN answers with a container-recursing
> predicate (`has_amount`) that this **top-level** export cannot mirror. Stage A possession must come from
> BN's own possession predicate, not this export; `carried_items[]` is for frontend display. Full analysis:
> [`51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md`](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md).

## Status and claim

- **Built.** Adds a conservative, **read-only** top-level carried-item export to the snapshot so a consumer
  can see what the avatar is carrying after a `pickup`. It provides **display visibility** of top-level
  carried items; it does **not** resolve the carried-package blocker named in
  [47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md) §5/§9 (Stage A
  Step 2) — that is a **possession-validation** question answered by BN's container-recursing `has_amount`
  predicate, which this top-level export cannot mirror. The corrected primitive is BN's own possession
  predicate, exposed via a dedicated read-only query (a follow-up, not this spike).
  See [51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md).
- **Equivalence level 1 — observation only.** This adds snapshot visibility of engine-owned carried state;
  it adds **no** input behavior and makes **no new level-4 claim**. The witness reuses the **already-proven**
  Spike 12A/16 level-4 `pickup` machinery to _create_ a carried item, then observes it — observation, not a
  new driven path. There is no registered-input/active-loop mechanism to name because nothing new is driven.
- **No objective/mission state.** "Returned with package" is **BN's verdict**, not a consumer composition
  from this export: possession is BN's verdict via its own predicate (`has_amount`/`has_charges`). This spike
  exports neither possession nor a "returned" flag — only top-level display state.
- Citations are current-tree; confirm by symbol (line numbers drift).

## What changed (one source file)

`src/arcopolis_export.cpp` only. A new anonymous-namespace helper `write_carried_items( JsonOut &, const
snapshot_ctx & )` is called as the **last member of the existing `avatar` object** in `write_avatar` (so the
array lands at `avatar.carried_items[]`). `schema_version` stays **1** — the field is purely additive and
existing consumers ignore it (verified: the share-nothing Python consumers `make_report.py` and `harness.py`
re-derive the contract unchanged; see Validation). No header, no fixture, no engine/seam change.

### Export shape (`avatar.carried_items[]`)

Per entry: `index` (export-local, 0-based across all sources), `type_id`, `name` (`item::display_name()`),
`symbol`, `location` (`"wielded"` | `"worn"` | `"inventory"`), `charges`, `count_by_charges`. Fields match
`entities.items[]` (ground) **minus** `pos_local`/`pos_abs` (a carried item has no tile) **plus** the
`location` tag.

### Enumeration — three explicit top-level sources

The three carried sources are enumerated directly, in the **same order** BN's own
`visitable<Character>::visit_items` roots them (`src/visitable.cpp` `visitable<Character>::visit_items`:
primary weapon → worn → inv), which (a) gives the `location` tag for free and (b) is **top-level by
construction** — no descent into container contents:

- **wielded** → `Character::wielded_items()` (`src/character.h`, `src/melee.cpp`): the documented-preferred
  accessor; returns only limb-held items and is **empty when unarmed**, so no null/"fists" entry is emitted
  (avoids `primary_weapon()`'s legacy null-item hack).
- **worn** → the public `Character::worn` (`src/character.h`) `location_vector<item>`; its `const_iterator`
  yields `item* const` (`src/location_vector.h`), so a `const avatar&` reads it without mutation.
- **inventory** → `Character::inv_const_slice()` (`src/character.h`, `src/character.cpp`) →
  `const_invslice` (`std::vector<const std::vector<item *> *>`, `src/inventory.h`); one entry is emitted per
  physical top-level item, matching `entities.items[]` granularity, never descending into contents.

Every accessor is `const`; nothing is moved, equipped, unequipped, or otherwise mutated.

### What the top-level export shows (and what it does NOT prove)

A picked-up **loose** item lands in the **flat top-level `Character::inv`** — `pickup`'s `pick_one_up` calls
`u.i_add(...)` (`src/pickup.cpp`), and `Character::i_add` stores via `inv.add_item(...)`
(`src/character.cpp`). So a top-level-only export **displays** that picked item as a `location:"inventory"`
entry without descending into any container. That is the export's real value: **display visibility** of what
was just picked up.

What it does **NOT** do is **answer possession** — and the original "the v0 contract is sufficient to prove
the carried package" framing was the wrong-primitive error logged in
[`51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md`](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md). "Does the character
have the package" is BN's own verdict via its container-recursing `has_amount` / `has_charges` predicates
(`visitable<Character>`; real callers `condition.cpp`, `mission.cpp`), which recurse into container contents.
A flat top-level export cannot mirror that recursion, so it is **not** a possession check and does **not**
resolve the audit's Stage A Step 2 blocker.

## Witness

Extends the existing `pickup` witness W1 in
[script_prompt_regression.ps1](script_prompt_regression.ps1) (real engine, non-live
`--arcopolis-run-script`, `ArcopolisTest`): `move_s → export(before) → pickup(move_s, menu choice 6) →
export(after)`. The pickup + both exports already existed; this spike adds gates on the snapshots:

- `avatar.carried_items[]` is **present** in the after snapshot (additive field round-trips).
- **count-delta proof** (not mere presence): the type_id whose **ground** quantity at the south tile dropped
  by `N` is shown to have its `location="inventory"` quantity in `avatar.carried_items[]` rise by **exactly
  `N`** (`before → after`). Witnessed value: `glass_shard` ground `−1`, carried(inventory) `0 → 1`. A
  presence/absence check would false-green (type already carried) or false-fail; the count-delta proves
  _this_ pickup became carried.
- **worn source enumerated**: the clothed avatar shows ≥1 `location="worn"` entry before any pickup
  (witnessed: 6 worn items).
- **clean transcript (honesty)**: zero `unexpected_prompt`, zero `prompt_force_cancelled` (which carries the
  partial/forced-cancel marker), zero `prompt_cancelled` — beyond W1's existing exit-0 / no-`prompt_failed`
  gates, which alone do not exclude a silent cancel or marked-partial.

### Witness scope (honest limits)

- **Witnessed:** the `worn` source (clothing) and the `inventory` source (the picked package). The unarmed
  `ArcopolisTest` avatar produces no wielded entries, so the **`wielded`** branch is **code-present but
  unwitnessed** — stated, not claimed.
- **Count-delta scope = loose non-ammo pickup only.** The proof holds because the witnessed pickup routes the
  loose `glass_shard` (a non-ammo item) through `i_add` → flat `inv` (`src/pickup.cpp` `i_add` at the
  loose-pickup calls, e.g. `pickup.cpp:489,521`), so it shows as a `location:"inventory"` entry. The one
  pickup-time route that nests-and-hides is **narrow and ammo-only**: `Character::i_add_to_container`
  (`src/pickup.cpp:399`) **early-returns unless `is_ammo()`** (`src/character.cpp`) and merges only into a
  pre-existing worn `is_ammo_container`, so picked-up **ammo** can vanish into that container's pocket —
  nested, and so enumerated by neither a flat `inv` entry nor this top-level export. A **non-ammo** package
  does **not** take this path; "picked up into a backpack pocket" is _not_ a real pickup route for it (see
  [`51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md`](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md)). More fundamentally,
  possession is BN's container-recursing `has_amount`/`has_charges` verdict while `carried_items[]` is flat,
  so this export must not be read as a possession check.
- **Not exported (deferred):** nested-container contents, vehicle cargo (`vehicle::get_items`), NPC
  inventory, and weight/volume/damage/rot/per-item state. Carried items are top-level only.
- **Not added:** any objective/"returned" completion state; any new prompt/menu support; per-unit
  quantities; `NEW_PICKUP_MENU=true` / `inventory_selector` / generic inventory UI.

## Validation

- `cata_test-tiles "[arcopolis]"` — All tests passed (981 assertions in 152 test cases). No new unit test:
  carried-item serialization is world-dependent (the `[arcopolis]` Catch2 set is pure/world-independent), so
  the witness is the fixture-backed regression, matching the Spike 8A ground-item precedent.
- `pwsh script_prompt_regression.ps1` — all gates green, including the four new W1 carried gates; W2–W5 and
  every fail-loud gate unchanged.
- Nearby pickup/export regressions confirm the additive field breaks nothing: `item_export_regression.ps1`,
  `prompt_menu_regression.ps1`, `movement_regression.ps1`, and `client_harness_regression.ps1` all exit 0 —
  the last two prove the live driver and the independent Python consumers (`harness.py`, `make_report.py`)
  tolerate the new `avatar.carried_items` field.
- Run with **`pwsh`** (PS7), never Windows PowerShell 5.1.

## Claims not to make

- **No nested-container / vehicle-cargo / NPC-inventory export** — top-level carried only.
- **No `wielded`-location claim** — code-present but unwitnessed (the witness avatar is unarmed).
- **No "package returned" / possession** from the export alone — possession is **BN's verdict** via its
  container-recursing `has_amount`/`has_charges` predicates, **not** a consumer composition from this
  display-only field (see [`51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md`](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md)).
- **No new level-4 / prompt-class support** — observation only; the level-4 pickup it rides is the existing
  Spike 12A/16 witness, not new.
