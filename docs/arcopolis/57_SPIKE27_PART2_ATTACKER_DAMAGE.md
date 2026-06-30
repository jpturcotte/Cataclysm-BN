# Spike 27 Part 2 — Attacker-Attributed Damage Fact

**Status:** built, validated. Equivalence **level 1 (observation only)**, native-authority class **S**
(raw simulation state). One gated `src/` funnel tap plus a read-only export field — unlike Part 1 (which
was fixture/docs only), this **is** a `src/` change. Reuses Part 1's `ArcopolisLivenessTest` fixture
**unchanged**.

This is **Part 2** of the Spike 27 frontier. **Part 1**
([56_SPIKE27_WORLD_TICK_LIVENESS.md](56_SPIKE27_WORLD_TICK_LIVENESS.md)) proved BN simulates between
inputs (an autonomous monster moves on its own turn) with a **source-blind** position witness. Part 2
adds the **attacker-attributed damage fact**: the engine's own `source` at the damage funnel, surfaced as
observable state, so a frontend knows **who** attacked the avatar — not just that the world ticked.

## What it proves

Across `[export, (wait, export) × N]` on `ArcopolisLivenessTest`, once the hostile `mon_zombie` reaches
the stationary avatar it melee-attacks; a **landed hit** flows through the engine's own damage funnel
`Creature::deal_damage(source=monster)` ([creature.cpp:1243](../../src/creature.cpp:1243)) →
`Character::apply_damage(source, …)` ([character.cpp:9495](../../src/character.cpp:9495)). A gated,
additive Arcopolis tap immediately after the funnel's event send
([character.cpp:9518](../../src/character.cpp:9518)) records `{source_kind, source_type_id, amount,
bodypart, turn}` into a session buffer, surfaced read-only as **`avatar.damage_taken[]`**. The regression
asserts that some post-load export's `damage_taken[]` carries an entry with `source_kind=="monster" &&
source_type_id=="mon_zombie" && amount>0`.

**The witnessed signal is the engine's OWN attribution**, reproduced as backend state. It is the same
`Creature *source` the GUI's "You were attacked by %s!" message is built from
([on_hurt, character.cpp:9801](../../src/character.cpp:9801)) — surfaced as a value, not scraped from a
string.

## Native-authority class S — self-sealing by construction

The surface exposes the **raw in-scope `source` pointer** at the funnel — authoritative simulation state,
neither a computed predicate (C) nor a display proxy (D). It is the engine's ground truth for "who dealt
this damage," and **it cannot diverge from itself**, so the class-S classification is **mechanically
self-sealing** and needs no counterexample (the External-seal finding). The two independent blind
cross-model reads recorded for Part 1 are corroborating **independence evidence**, not the seal — the
self-seal is the construction itself. The category discrimination the witness depends on (`mon_zombie` vs
the stationary ally NPC vs terrain) is done in the **fixture + regression**, never via a synthetic
engine-side discriminator: the tap reads only the engine's own coarse gate (`source != nullptr`, the
same null/identity check the engine uses at on_hurt and `set_killer`) plus `source != this`.

## The divergence that bounds the claim — perception is a DISPLAY filter, recorded BEFORE it

The funnel value is recorded **before** the GUI's display filters, and is the FUNNEL FACT, **never**
message-equivalence. Two distinct GUI strings, with **two distinct gates** (verified at the leaf — this
corrects an earlier imprecise "perception-gated" label on the on_hurt message):

- **on_hurt distraction message** "You were attacked by %s!"
  ([character.cpp:9801-9804](../../src/character.cpp:9801)) is gated by **painkiller / narcosis /
  `disturb`** ([:9528](../../src/character.cpp:9528), [:9800](../../src/character.cpp:9800)) — **NOT**
  perception. Its `source->disp_name()` for a monster is **unconditional** (`monster::disp_name` has no
  `sees()` mask, [monster.cpp:809](../../src/monster.cpp:809)).
- **per-hit combat message** is the genuinely **perception-gated** one: `monster::melee_attack` computes
  `u_see_me = g->u.sees(*this)` ([monster.cpp:2210](../../src/monster.cpp:2210)) and renders **"The
  zombie hits your leg."** when seen ([:2259](../../src/monster.cpp:2259)) but **"Something hits your
  %s."** — attacker identity **dropped** — when not ([:2284](../../src/monster.cpp:2284)).

So perception masks the **displayed attacker identity** at the display layer. The funnel `source` is the
real attacker **regardless of LOS**; the backend exposes that pre-perception ground truth (class S), and
the **frontend** applies its own (optionally `sees()`-masked) rendering (class D). The perception-masked
_display_ — and whether the avatar would see "the zombie" vs "Something" — is the separate, deferred
frontier (blocked on the `sees()` / `pl_sees` seam). **The backend `source` is never claimed equal to the
GUI's displayed attacker — only to the raw funnel attacker.**

## RNG-DEPENDENT, not RNG-invariant (the key difference from Part 1)

Part 1's position gates are **RNG-invariant** (the zombie always approaches). Part 2's gate is
**RNG-dependent**: the funnel fires **only on a landed hit** (`apply_damage` is hit-only; a miss never
reaches it), so "took damage from the zombie" requires ≥1 hit to land in N waits. With a generous N
(default 8) the zombie gets several melee attempts once adjacent and a hit is **empirically reliable**
every run across seeds — but it is **not** guaranteed by construction. A pathological all-miss run
**fails loud** (empty `damage_taken[]` across every export), never a false green. The regression runs
**3 distinct seeds** and requires each to land ≥1 attributed hit; exact amount/bodypart/turn are
RNG-dependent and **not** gated. This was **validated empirically** across the three seeds (see
"Validation").

## The funnel tap (the gated `src/` change)

`Character::apply_damage` ([character.cpp:9495](../../src/character.cpp:9495)) is the engine's single
"where damage is actually applied" funnel. Immediately after it sends the source-blind
`character_takes_damage` event, the tap records the attacker when **all** hold:

```
arcopolis::backend_session_active() && is_avatar() && source != nullptr && source != this && dam_to_bodypart > 0
```

- `dam_to_bodypart` (HP actually lost, [:9515](../../src/character.cpp:9515)) — **not** the raw incoming
  `dam` — so a record is never logged for a part already at 0 HP (no phantom "damage taken").
- `is_avatar()` — only the avatar's damage is recorded (`avatar.damage_taken[]`).
- `source != nullptr` excludes environmental damage (fields / `suffer` / `hurtall` pass a null source);
  `source != this` excludes self/suicide.
- `backend_session_active()` — **inert in cata_test / normal play** (no behavior change outside a
  session).

Mechanism **(b)** — a direct read at the funnel — was chosen over **(a)** enriching the shared
`character_takes_damage` event (rejected: it changes engine construction repo-wide and is
`ENABLE_EVENTS`-fragile). The event stays source-blind; the tap is purely additive.

**Per-application, not per-turn:** a turn can carry multiple `apply_damage` calls (per bodypart / per
hit); `damage_taken[]` is the **event stream**, drained per snapshot (each snapshot's array is the window
since the prior one), never a lossy per-turn rollup.

## Scope — what this does NOT prove (do not let docs widen it)

- the perception-gated GUI **message** (the masked display is the deferred `sees()` frontier);
- **misses** — only landed hits reach the funnel (`apply_damage` is hit-only);
- **damage type** (`DT_BASH`/`DT_CUT`/…) — collapsed to a scalar before the funnel;
- **ranged-vs-melee** — the surface mechanically captures **any** `apply_damage` source, but only
  **melee `mon_zombie`** is witnessed here;
- **NPC-attacker** attribution — captured as `source_kind=="npc"` (with a deferred type id) but
  **unwitnessed** (the fixture's only hostile is the monster zombie);
- LOS / perception; full combat resolution.

### Damage type vs misses — what the GUI itself surfaces (a fidelity distinction)

Both `amount`/`bodypart`/`source` cross the funnel, but **damage type** and **misses** do not — and they
matter to a frontend's GUI fidelity **very differently**, so do not lump them:

- **Damage type is NOT a GUI-fidelity gap.** The standard player-facing hit message is
  `"%1$s hits your %2$s."` ([monster.cpp:2259](../../src/monster.cpp:2259)) — **type- and
  amount-agnostic** ("The zombie hits your torso."). The `DT_BASH`/`DT_CUT` split is an **internal enum the
  GUI never shows the player** in combat feedback. Mechanically it is unavailable at the funnel anyway:
  `Creature::deal_damage` sums the per-type units into a single scalar
  ([creature.cpp:1262](../../src/creature.cpp:1262)) and passes only that to `apply_damage`
  ([creature.cpp:1268](../../src/creature.cpp:1268)), returning the typed `dealt_damage_instance` to the
  _caller_, not the funnel. So omitting damage type loses **nothing the GUI shows**. It would matter only
  for a frontend that wants to show **more than the GUI** (a typed breakdown), or to reconstruct a
  downstream _consequence_ the GUI does surface — e.g. **bleeding** is the visible effect of cut damage, so
  the player sees the bleed effect, not a "cut" label. (BN's "claws"/"bites" verbs are attack-_definition_
  flavor, NOT the `DT_*` damage type — do not conflate them.)
- **Misses ARE a GUI-fidelity gap.** A miss produces real player-facing messages — "You dodge the
  zombie." / unseen, "You dodge an attack from an unseen source."
  ([monster.cpp:2236-2249](../../src/monster.cpp:2236)) — but in the **attack-resolution** branch
  (`!attack_success`), which never reaches the hit-only `apply_damage`. So a frontend wanting
  GUI-equivalent combat feedback **does** need miss information, and this field structurally cannot carry
  it; closing that gap means tapping the **resolution path**, not the damage funnel — a separate, broader
  surface (which would also be where typed `dealt_damage_instance` / hit-vs-miss live, for a future
  richer-combat spike).

**Net for a frontend:** the binding gaps between `damage_taken[]` and a GUI-faithful combat _display_ are
**misses** and **perception masking** (the `sees()` form), **not** damage type. This surface is the narrow
"applied damage, attributed to a source" fact; flavor and misses live on paths this spike deliberately did
not touch.

## Impact (files)

- **`src/character.cpp`** — the gated funnel tap (additive). **NEW engine touch point** — `character.cpp`
  carried no Arcopolis code before, so it becomes a **new upstream-rebase collision surface** alongside
  `main.cpp` / `handle_action.cpp` / `input.cpp` / `game.cpp` / `pickup.cpp` / `ui.cpp` / `popup.cpp` /
  `output.cpp` / `iexamine.cpp`. The tap sits right after the `character_takes_damage` event send; an
  upstream change to that funnel region collides there.
- **`src/arcopolis_backend_input.{h,cpp}`** — the `avatar_damage_record` struct + the session-gated buffer
  (`backend_record_avatar_damage` / `backend_take_avatar_damage_taken`, drain semantics); cleared with the
  session.
- **`src/arcopolis_export.cpp`** — `write_damage_taken()` writes `avatar.damage_taken[]` inside the avatar
  block (drains the buffer). `schema_version` unchanged (additive field).
- **`tests/arcopolis_backend_input_test.cpp`** — a `[arcopolis]` unit test pins the buffer contract
  (classify a **real** `mon_zombie`, preserve per-application order, drain per take, inert outside a
  session).
- **`docs/arcopolis/attacker_damage_regression.ps1`** — the RNG-dependent fixture regression (sibling to
  `world_tick_liveness_regression.ps1`, kept separate so Part 1's RNG-invariant gates stay pristine).

## Validation (measured 2026-06-29, MSVC RelWithDebInfo)

- **Catch2 `[arcopolis]`** — `arcopolis avatar-damage buffer records attacker identity, preserves order,
  drains per take` **passed** (10 assertions: classifies a real `monster` → `mon_zombie`, per-application
  order, drain, inert outside a session). Full `[arcopolis]` suite: **158 cases / 1040 assertions, all
  passed**.
- **Fixture regression** — `attacker_damage_regression.ps1`, **3 seeds passed** (attributed hits **5 / 3 /
  5**, total amount **24 / 14 / 18**); each landed ≥1 `mon_zombie`-attributed hit and the load (`t0`) export
  carried no damage (no phantom record).
- **Empirical reliability (the RNG-dependence check, the red-team-required validation)** — re-ran with **12
  additional distinct seeds**: all passed, **3–6** attributed hits each. **Across 15 distinct seeds total,
  every one landed ≥3 hits (minimum 3), zero all-miss** — the witness is **empirically reliable, not
  RNG-invariant**; a pathological all-miss run fails loud, never false-greens.
- **No Part 1 regression** — `world_tick_liveness_regression.ps1` still passes (3 seeds, all RNG-invariant
  gates) with the export field + funnel tap added.

## Reproduce

```powershell
# Fixture (reuse Part 1's; no build):
python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisLivenessTest `
    --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force
# Unit test:
.\out\build\win-rel-deb\tests\cata_test-tiles.exe "[arcopolis]"
# Witness (pwsh; -Exe points at a built tiles exe):
pwsh docs/arcopolis/attacker_damage_regression.ps1 -Exe .\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe
```
