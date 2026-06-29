# Spike 27 — World-Tick Liveness Witness (Part 1: autonomous agency)

**Status:** built, validated. Equivalence **level 1 (observation only)**, native-authority class
**S** (raw simulation state). No `src/` change — fixture + regression + docs only. This is **Part 1**
of a two-part frontier; **Part 2** (the GUI-faithful attacker-attributed _damage_ fact) is a separate
follow-up, deliberately not in this PR (see "Part 2" below).

## What it proves

Every Arcopolis witness to date asserts a **static** post-condition (a monster/NPC/item is at a
tile) or a **player-driven** transaction (move/examine/pickup). None put **autonomy** on trial — and
every dynamic fixture (`make_monster_fixture.py`) is deliberately **immobile** (doc 16/17). This spike
witnesses that **BN simulates between inputs**: an autonomous entity acts on its **own engine turn**.

A hostile `mon_zombie` is placed 2 tiles **south** of the stationary avatar. Across
`[export, (wait, export) × N]` the driven `wait` ends the avatar's turn and falls through `do_turn`'s
clean-park seam into the **bottom-half tick** — `game::monmove()` (`src/game.cpp`, the autonomous
monster-move pass) — where the zombie pathfinds toward the avatar **on its own turn**. The witnessed
signal is the monster's exported `pos_abs` (class **S**, from `game::all_monsters()`) moving closer to
the avatar.

**One-directional by construction:** a position delta **proves** an autonomous act (`delta ⇒ act`).
A _zero_ delta would **not** disprove liveness (a real tick can be spent attacking, blocked, or
recovering), so the witness never asserts `no-delta ⇒ no-liveness`. We pick a provoked, avatar-targeting
mover precisely so movement is the expected behaviour.

## The fixture (authored initial condition, not faked state)

`ArcopolisLivenessTest` is a clone of `ArcopolisTest` with one hostile mobile witness injected by the
(now parameterized) generator:

```
python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisLivenessTest \
    --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force
```

The opt-in `--anger`/`--morale`/`--aggro-character` flags author a monster that the engine's own
`monmove` will path toward the avatar; the generator's **defaults reproduce the original immobile
witness byte-for-byte** (so `ArcopolisNearMonsterTest` regenerates unchanged — verified). Authoring an
initial anger/aggro state is exactly what the GUI debug "spawn monster" does; the engine then simulates
faithfully — this is **not** overriding running engine state.

Placement detail (root-caused empirically): the avatar sits in a walled, dimly-lit evac shelter, so a
mover detects it only at close range; 2 tiles south, on the **opposite** side from the NPC, on passable
floor with clear LOS, makes detect-approach-attack reliable.

## RNG discipline — why the gates are RNG-invariant, not seeded

The headless simulation is **not byte-deterministic**, and this was established at the leaf and
empirically, not assumed:

- `--seed` re-seeds **only the main engine** (`src/main.cpp:916` → `rng_set_engine_seed`,
  `src/rng.cpp:159`). Worker threads time-seed their **own** RNG
  (`src/thread_pool.cpp:52-56`, `hash(thread_id) ^ high_resolution_clock::now()`), and **parallel
  monster planning is on by default** (`src/cached_options.cpp:48-49`,
  dispatch `src/game.cpp:6293`). The in-tree comment at `src/monmove.cpp:394-399` already notes worker
  aggro rolls "silently break save-file determinism".
- **Both** multithreading flags were tested in isolation — `PARALLEL_MONSTER_PLANNING=false`,
  `MULTITHREADING_ENABLED=false`, and both — with the pin **verified persisted** in the sandbox
  `options.json` the game reads (`get_options().load()` runs headless, `src/main.cpp:855-856`;
  `MULTITHREADING_ENABLED=false` → 0 pool workers, `src/thread_pool.cpp:93-95`, i.e. genuinely
  serial). **Every combination still diverged run-to-run with a fixed seed.** Byte-determinism is
  therefore **unavailable through any option we control**; the residual entropy lives in the serial
  main-thread path (leading hypothesis: ASLR / address-dependent container iteration order shifting the
  `rng()` consumption sequence — the codebase carries a `cata-determinism` lint for exactly this class).
  The exact line was **not** isolated (would need an instrumented build).

So we do **not** gate exact positions or damage (those are RNG-dependent: the stumble tile and the
hit/miss outcome vary per run, even with a fixed seed). Instead we gate only **RNG-invariant**
quantities and **prove invariance** by running the witness under **three distinct seeds** and requiring
every gate to hold in all three realizations. Validated: the zombie's exact landing tile and the avatar
HP drop both vary by seed and run-to-run; the invariants below never do.

## Hard gates (per seed; all must hold for all 3 seeds)

Gated by [`world_tick_liveness_regression.ps1`](world_tick_liveness_regression.ps1) (run with `pwsh`):

1. **single mover at load** — exactly one non-hallucination `mon_zombie` in the radius-12 window.
2. **autonomous approach** — final `Chebyshev(zombie, avatar)` `<` load Chebyshev (it moved toward the
   avatar on its own turn). _The liveness signal._
3. **reached adjacency** — some post-load export has Chebyshev `== 1` (it closed to the avatar).
4. **clock advanced = N** — `backend.turn` rose by exactly `N` (the world ticked; **not** a clean-park
   early return).
5. **avatar held** — `avatar.pos_abs` identical across every export (the avatar only waits).
6. **NPC non-interference** — see below.
7. **mover survived** — exactly one non-hallucination `mon_zombie` at the final export.
8. **autonomous step (no teleport)** — the mover's Chebyshev displacement is `<= 1` between every
   consecutive export (the zombie is speed 100, so a move is `<= 1` tile/turn; the `monmove`
   impassable-eject does a multi-tile `setpos`). Converts an eject/teleport into a fail-loud and
   proves a step-by-step path, not a jump.
9. **mover on passable terrain** — the mover's load tile `ter` shows no clear impassable signal (an
   impassable family token with **no** passable one). The eject precondition is engine impassability;
   this re-asserts the fixture invariant the generator only _warns_ on. (Gates 8/9 were added in the
   red-team pass to close a regenerated-onto-impassable false-green; the committed fixture is on
   passable `t_floor`, so the eject never fires.)

**Soft report (not gated — RNG-dependent):** the avatar HP delta under attack (the stakes preview).
This is observed and reported, never asserted — and it is **source-blind**, so it is **not** a proof
that the monster attacked (that is Part 2).

## NPC non-interference (proven from the export — no new field)

The stock shelter NPC Edwardo Stovall sits 1 tile **north** of the avatar — the **opposite** side from
the zombie, with the stationary avatar between them. The existing `entities.npcs[]` export reports him
**`is_stationary: true`**. Note `is_stationary` suppresses his **pathing/wandering only** — it does NOT
disable an attack on an _adjacent_ hostile (the NPC attack decision in `npcmove.cpp` fires before the
stationary-park branch). So the closure is carried by **geometry**, not `is_stationary` alone: the zombie
targets the _nearer_ avatar (Chebyshev 2 vs 3 to Edwardo), closes to the avatar's south side, and never
becomes adjacent to Edwardo (he stays 2 tiles away with the avatar between) — so Edwardo never gets to
attack it, and being stationary he cannot path to it either. Gate 6 makes this a checked invariant
(`is_stationary == true` **and** `pos_abs` identical across every export), and gate 7 (the mover survives —
the avatar only waits and the NPC is stationary, so nothing third-party kills it) confirms the witnessed
movement is the zombie's own. Strictly, gates 6/7 **detect** NPC displacement and zombie death rather than
_prove_ no attack occurred — but a far-side NPC attack could only _slow_ the zombie's approach, never
_manufacture_ one, so a spurious approach cannot be NPC-induced; adequate for an L1 observation claim. The export **cannot** attribute a monster's hp loss to a source, so non-interference rests
on geometry + `is_stationary`, **not** on hp accounting — which is also why the avatar HP drop is only a
soft, source-blind note here.

## Scope — what this does NOT prove (do not let docs widen it)

1. **One entity, not the world** — fields/fires/vehicles/weather/spawns/faction-AI are unwitnessed.
2. **One state field, not general simulation** — a position delta, not "simulation advances".
3. **One tick's worth, not sustained liveness** — `wait × N` then before/after; the only multi-tick
   anchor is the Spike-2 `T→T→T+1` clock.
4. **A provoked, avatar-targeting mover, not ambient autonomy** — the fixture _causes_ the motion it
   witnesses; an idle monster need not move.
5. **Single-z** — the monster window is a radius-12 single-z square (multi-z is a recorded non-goal).
6. **A perception-free position fact, not combat** — no attacker-identity, no damage attribution, no
   hit/miss/damage-type, no LOS/perception. **That is Part 2.**

## Part 2 (separate follow-up) — the attacker-attributed damage fact

To prove the monster **attacked** the avatar and the avatar **received damage from that monster** the
way the engine computes/shows it, Part 2 surfaces the engine's **own in-scope `source`** (+ `damage`)
at the `Character::apply_damage` funnel (`src/character.cpp:9495/9518`) — the same value the GUI's
"You were attacked by %s!" message is built from (`Character::on_hurt`, `:9801`). The regression then
asserts, on **this same fixture**, that the avatar took damage **and** `source == mon_zombie` — the
engine's own attribution, reproduced as backend semantics (the frontend renders its own message). It is
a one-`src/`-file gated funnel tap (mechanism (b)); its class-S classification was cleared by two
independent blind cross-model reads. We do **not** scrape the perception-gated GUI string (a separate,
larger frontier blocked on the `sees()` seam). Tracked via `arcopolis-claim-plan`.

## Reproduce

```powershell
# Fixture (no build):
python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisLivenessTest `
    --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force
# Witness (pwsh; -Exe points at a built tiles exe):
pwsh docs/arcopolis/world_tick_liveness_regression.ps1 -Exe .\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe
```
