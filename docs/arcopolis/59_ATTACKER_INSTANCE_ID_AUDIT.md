# 59 — Stable Per-Instance Attacker ID: Audit + Stage-1 Shadow-Test

**Status:** audit + gap demonstration. Equivalence **level 1 (observation only)**. **NO `src/` change** —
one fixture-generator flag, one new fixture, one regression, docs. This records the deferred **"Codex Claim
4"** from [PR #90](https://github.com/jpturcotte/Cataclysm-BN/pull/90) ("Include a per-creature source
identity") as an audited backlog item, and ships a **Stage-1 shadow-test** that makes the gap a witnessed
fact — the evidence-first step before any engine change is authorized (Stage 2/3 below).

## The impulse

Give each `avatar.damage_taken[]` event (Spike 27B, [doc 57](57_SPIKE27B_ATTACKER_DAMAGE.md)) a **stable
identifier for the specific attacking creature instance**, so an Arcopolis frontend can correlate "who hit
the avatar" to a specific entry in `entities.monsters[]` / `entities.npcs[]` — not just the attacker's
**type** (`source_type_id`, e.g. `"mon_zombie"`, which two adjacent zombies share).

## The audit finding — monsters have NO stable per-instance id (BN-native, leaf-verified)

| Handle                              | Monsters                                                                                                                                                    | NPCs                               | Citation                                                                                                                                                                                                                                                                        |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Self-id / `getID()`                 | **none** (`monster`/`Creature` have no `getID`; `monster.cpp` only calls _other_ creatures' `getID`)                                                        | stable serializable `character_id` | monster: [monster.h:105](../../src/monster.h:105), [monster.cpp:1132](../../src/monster.cpp:1132)/[:3814](../../src/monster.cpp:3814); npc: [character.h:296](../../src/character.h:296), [:2441](../../src/character.h:2441), [character.cpp:679](../../src/character.cpp:679) |
| Tracker handle                      | `Creature_tracker::temporary_id` = the **volatile `monsters_list` index** `iter - monsters_list.begin()`, doc'd "valid until monsters are added or removed" | n/a (NPCs use `getID`)             | [creature_tracker.cpp:41-50](../../src/creature_tracker.cpp:41), contract [creature_tracker.h:51-59](../../src/creature_tracker.h:51)                                                                                                                                           |
| Save format                         | serialized **by position** (`monster_at`), with the engine's own TODO "if monsters/Creatures ever get unique ids… `getID()`"                                | `json.member("id", getID())`       | monster: [savegame_json.cpp:139-178](../../src/savegame_json.cpp:139); "// monsters don't have IDs" at [:1004](../../src/savegame_json.cpp:1004); npc id [:988](../../src/savegame_json.cpp:988)/[:1036](../../src/savegame_json.cpp:1036)                                      |
| `safe_reference` / `game_object` id | **no** — that stable-id + arena system is the item/location layer, not monsters                                                                             | —                                  | [game_object.h:19](../../src/game_object.h:19)                                                                                                                                                                                                                                  |

**The engine itself confirms the gap in two places** (the TODO at `savegame_json.cpp:145-147`/`173-177`, and
`// monsters don't have IDs, so get its index in the Creature_tracker instead` at `savegame_json.cpp:1004`).
This audit is **NATIVE-BN**: the absence is the engine's, not Arcopolis's.

## Why the cheap partials are unreliable (both sides must agree, and neither carries a key)

The frontend must join a damage event to an `entities.monsters[]` entry. Today the entities export keys
monsters by a **windowed post-filter `index`** (`monster_index++` over the radius-12 survivors,
[arcopolis_export.cpp:308](../../src/arcopolis_export.cpp:308)) — a _different_ index from `temporary_id`,
and equally volatile — while the damage event carries `{source_kind, source_type_id, amount, bodypart,
hp_part, turn}` and **nothing per-instance**. The candidate partials all fail:

- **`source_type_id`** — shared by same-type attackers (two `mon_zombie` ⇒ ambiguous). This is the exercised
  divergence below.
- **Position** — the attacker moves between the mid-`do_turn` funnel and the snapshot; a captured position is
  a moving target.
- **Windowed index / `temporary_id`** — reindexes on spawn/death. `do_turn` runs `monmove()`
  ([game.cpp:2298](../../src/game.cpp:2298)) — where the funnel tap fires — and _then_ `cleanup_dead()`
  ([:2359](../../src/game.cpp:2359)) → `remove_dead()` ([:5603](../../src/game.cpp:5603)), reindexing
  `monsters_list` **before** the snapshot serializes. Across turns it is worse.
- **`unique_name`** — usually empty (both fixture zombies export `unique_name=""`).

## The Stage-1 shadow-test (this deliverable) — the divergence, EXERCISED

Fixture **`ArcopolisTwoZombieTest`**: a clone of `ArcopolisTest` with **two** hostile `mon_zombie` (offsets
`0,2,0` and `1,2,0` — both `t_floor`, in dark-shelter detection range), built by
[`make_monster_fixture.py`](make_monster_fixture.py)'s new additive `--extra-offset` flag (default omitted ⇒
`ArcopolisNearMonsterTest`/`ArcopolisLivenessTest` regenerate **byte-for-byte**, verified). The stationary
avatar only `wait`s and kills neither zombie, so both persist and the ambiguity is stable.

[`attacker_instance_ambiguity_regression.ps1`](attacker_instance_ambiguity_regression.ps1) runs
`[export, (wait,export)×8]` over **3 seeds** and asserts, per seed:

- `two_zombies_present` — ≥1 snapshot exports ≥2 `mon_zombie` at once (ambiguity **real**, not the
  happy-path one-zombie case);
- `zombies_distinct` — those ≥2 sit on **distinct** `pos_abs` (genuinely two creatures the surface conflates);
- `hit_under_ambiguity` — ≥1 snapshot has a `mon_zombie` damage entry **and** ≥2 `mon_zombie` present in the
  same snapshot (a hit landed while the attacker was genuinely ambiguous);
- `no_instance_join_key` — **STRUCTURAL, RNG-independent**: no `damage_taken[]` entry carries any per-instance
  discriminator (no id / index / pos / instance / unique_name field). _If a stable-id field is ever added
  this gate FLIPS — correctly signalling the gap has closed and this shadow-test is stale._
- `attacker_position_moves` — the multiset of `mon_zombie` `pos_abs` is not constant across the sequence (they
  pathfind), so "stamp the attacker's position" is a moving target;
- `load_export_no_damage` — `t0` carries no damage (the 27B phantom-record guard).

**RNG-dependent (like its 27B sibling), not RNG-invariant:** the funnel fires only on a landed hit, so a
hit-under-ambiguity needs ≥1 hit in N waits; empirically reliable across seeds (validated 11/10/12 hits), a
pathological all-miss fails loud. **Decisive leaf** (seed `ambig-alpha`, one snapshot): two exported
`mon_zombie` at `[6301,6422]` (index 0) and `[6302,6422]` (index 1); **two** `mon_zombie` damage entries the
same turn (`leg_r`/5 and `arm_l`/6), each `{source_kind, source_type_id, amount, bodypart, hp_part, turn}`;
field-name intersection with the entity entry **empty** — the event cannot be pinned to a specific zombie.

## The decision — audit-only now; options for later (both sides, fidelity rules)

A truly **stable** identifier is satisfiable **only** by a new engine id seam. The bounded options, and their
class (derived from the frontend display-correlation consumer — **not** a possession/mission/objective
predicate, so **no external seal is required**; two blind cross-model reads independently classified it
**S** and rejected the volatile-index and synthetic-id shortcuts — independence evidence, not a seal):

| Option                             | What                                                                                                                                                                                                         | Verdict                                                                                                                                                                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **(1) real engine stable id**      | add a serialized per-monster id + `getID()` (the engine's own TODO); stamp it on the event and emit it on `entities.monsters[]`                                                                              | **NEEDS NEW SEAM / STAGE B** — gameplay + save-format change; plausibly **upstream-first** (benefits BN generally: mission targeting, the `last_target` fallback). Only this satisfies the literal "stable"                                                |
| **(2) resolve-at-serialize join**  | hold a `weak_ptr_fast<monster>` at the funnel; at the snapshot capture site resolve it to the attacker's **current raw `pos_abs`** (class **S**, self-sealing by construction), `null` if dead/out-of-window | **LIKELY** — additive, engine-list-derived, **same-snapshot scope only**; the fidelity-clean bounded substitute. **Use `pos_abs` (raw state = S), not the windowed index (a derived view = D)** — the two blind reads flagged the index as the false-green |
| **(3) flat `temporary_id` stamp**  | stamp the volatile index on both sides                                                                                                                                                                       | **REJECTED** — reindex false-green (§ above), unwitnessable-as-correct                                                                                                                                                                                     |
| **(4) synthetic session-local id** | Arcopolis-owned `monster*`→uint64 registry                                                                                                                                                                   | **REJECTED** — fabricated discriminator; violates "expose the engine's OWN id, never a synthetic discriminator"                                                                                                                                            |

**Fidelity rule (binding):** any cross-instance discrimination lives in the **fixture + regression** (this
two-zombie world), never a synthetic engine-side discriminator — consistent with the 27A/27B discipline and
[`arcopolis-expose-existing-discriminate-in-test`].

## Scope — what this does NOT prove (do not let docs widen it)

This proves a **gap**, not a fix. It builds/witnesses **no** correlation key, stable id, or resolve-at-serialize
handle. It does not cover ranged / NPC-attacker attribution, hit/miss, damage type, or the reindex-on-death
hazard (source-cited above, not gated — forcing a death is non-deterministic). Options (1)/(2) are **not
built** and are **not** authorized by this doc; each would need its own plan + witness that **exercises** the
moved/died divergence (a stationary-adjacent two-zombie fixture is insufficient for that).

## Reproduce

```powershell
# Fixture (no build):
python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisTwoZombieTest `
    --monster mon_zombie --offset 0,2,0 --extra-offset 1,2,0 --anger 100 --morale 100 --aggro-character --force
# Witness (pwsh; -Exe = any exe carrying the shipped 27B surface — no rebuild needed):
pwsh docs/arcopolis/attacker_instance_ambiguity_regression.ps1 -Exe .\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe
```

Related: [57_SPIKE27B_ATTACKER_DAMAGE.md](57_SPIKE27B_ATTACKER_DAMAGE.md) (the surface this audits),
[56_SPIKE27A_WORLD_TICK_LIVENESS.md](56_SPIKE27A_WORLD_TICK_LIVENESS.md) (the sibling fixture pattern).
