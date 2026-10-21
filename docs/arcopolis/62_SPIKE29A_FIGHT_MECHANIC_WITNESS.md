# Spike 29A — fight-MECHANIC witness (avatar bump-melee vs an adjacent hostile)

## Claim (read this first)

**Equivalence level 1 — observation only; native-authority class A (stimulus) via S (observation).**
Backend-driven `move`s into an ADJACENT hostile `mon_zombie` lower its raw `entities.monsters[].hp`
across snapshots, and a **contrast arm** (§2 G2 — the same fixture with `wait` instead of `move`, hp
held exactly) attributes that drop to the moves by experiment. The engine path the move takes (§1,
the engine's own bump-melee) is **source-read** and leaf-cited, not observed by the witness. This is
the **melee MECHANIC half of doc 60 step 5** (Spike 29A), witnessed on ONE purpose-built adjacency
fixture — a fight **mechanic**, not a fight **route**:

- **narrowed from doc 60's Spike 31**: doc 60 proposed a "fight-route witness" ("the fight route
  becomes witnessed … engine-equivalent for the attack"). Spike 29A delivers only the mechanic, at
  L1. Composing the fight onto the slice route (the fight **route**) is the still-**OPEN**,
  not-yet-carded remainder of step 5 — it is NOT doc 60 step 6, which is the **sneak** route;
- the security-DRONE half of step 5 (doc 60's "Spike 30" label — expected **29B** when carded) remains
  **OPEN**;
- sneak / alternate-route composition (doc 60 step 6) remains **OPEN**;
- maintainer decision Q3 (drone on the composite route?) remains **OPEN** — nothing here answers it;
- **NO level-4 claim for the attack**: the `move` verb stays at its recorded level-2/3 injection
  (the `action_id` enters at the `handle_action` seam and never passes
  `input_context::handle_input`); the witness drives no new input path and exports no new field.
- **Zero `src/`.** The only tooling change is an additive `--hp` flag on `make_monster_fixture.py`
  (defaults byte-identical, mechanically gated — §4).

**Card lineage:** first carded + six-lens red-teamed 2026-07-01 (needs revision) → re-interrogated
2026-07-04 → five-lens red-team of the revised card (witness rewrite, not redesign) →
second-revision card → a voluntary BLIND
independent read (external-seal instrument, though no seal was required) that matched the card's
consumer/class/scope derivation (S for the hp value — "not a GUI display string, predicate verdict,
action, or menu answer"; A for the driven move; one adjacent monster's pool).

## 1. The engine chain (source-read and leaf-cited; the witness observes only its hp result)

| Step                                                                     | Leaf                                                                                                                                            | What it does                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Backend serves `move_s` = `ACTION_MOVE_BACK` (keybinding ident `"DOWN"`) | `arcopolis_command.cpp:39` → `action.cpp:262-263`; `src/handle_action.cpp` (backend branch replaces `get_player_input`; movement dispatch case) | the injected action is consumed at the same `handle_action` dispatch a keypress reaches — level 2/3, inside `do_turn`'s top half (no Spike-3 inversion)                                                                                                                                                                                                                                          |
| Monster branch                                                           | `src/avatar_action.cpp:538-574`                                                                                                                 | dest tile holds a non-friendly monster; the neutral-only `query_yn` (`:561-566`) requires `MATT_IGNORE\|\|MATT_FLEE` — **unreachable** for a hostile                                                                                                                                                                                                                                             |
| Hostility                                                                | `src/monster.cpp:1828-1833`                                                                                                                     | `aggro_character` bypasses the `MATT_IGNORE` return; anger/morale 100 → the `:1833` `MATT_ATTACK` fall-through                                                                                                                                                                                                                                                                                   |
| Attack                                                                   | `avatar_action.cpp:569` → `:181-184` → `:976-986`                                                                                               | `melee_attack_from_movement` → `melee_attack_while_handling_manual_combat_mode`: with `manual_combat_mode==false` the engine ITSELF wraps `Character::melee_attack` (`melee.cpp:1477`) in `melee::technique_prompt_suppression_guard` (`:984`) — the technique menu cannot prompt; the `==true` path skips the guard (prompt risk → Spike-21 fail-loud), which is why the mode matters (§5 pins) |
| Damage                                                                   | `src/monster.cpp:2433-2450`                                                                                                                     | `monster::apply_damage`: `hp -= dam`; death check at `hp < 1`                                                                                                                                                                                                                                                                                                                                    |
| Observation                                                              | `src/arcopolis_export.cpp:327-328` ← `src/monster.cpp:4100-4103`                                                                                | the export writes `mon.get_hp()` — `return hp;` verbatim, the raw authoritative pool (NOT the GUI's display: the GUI shows filtered health BANDS via `hp_description`, `monster.cpp:840-846`, trait-filtered — an export showing a band or stale value is the S-falsifier)                                                                                                                       |

## 2. Witness design (gates)

`fight_mechanic_regression.ps1` (run with `pwsh`; renamed from the plan's `fight_route_…` so the
filename cannot claim the route-ness the docs deny), three seeds, non-live `--arcopolis-run-script`
`[export t0, (move_s, export tN) × 6]` plus, per seed, the contrast run `[export t0, (wait, export
tN) × 6]` (a zero-seed `-Seeds @()` invocation exits 11 instead of reporting a vacuous ok):

- **G-ID** — a default-generation-flags invocation (`--fixture-root`/`--dest-world
  ArcopolisIdentityCheck`/`--force` are harness plumbing; byte-identity across a different dest name
  holds because the `.sav` embeds no world name) regenerates the reference
  `ArcopolisNearMonsterTest` `.sav` **byte-for-byte** (SHA256): the mechanical gate for the ratified
  fixture-isolation bound (no committed regression gated this before — the prior card's citation of
  slice_regression G1 for it was false; G1 gates the stairs generator).
- **G0** — fixture pins: `style_selected=="style_none"` (knockback pin — `style_none` defines no
  techniques, so `pick_technique` under the suppression guard yields `tec_none` and neither side is
  displaced; the avatar KNOWS brawling/kicks, so the pin is the SELECTED style, not style-lessness);
  `auto_travel_mode:false` (a silent move-diverter); `manual_combat_mode` key ABSENT — a
  fixture-PROVENANCE pin, not an engine contract: current saves DO write the key on every save
  (`game::serialize`, `savegame.cpp:99`); the committed fixture predates the field, so absence
  detects a re-saved/regenerated fixture. The loaded value is `false` regardless of the key —
  `game::load` resets it unconditionally after unserialize (`game.cpp:3985`; the `savegame.cpp:367-368`
  loader default is not the operative line on this path); zombie authored `hp:80`; avatar
  `"str_max":10` (a kill-safety premise gate — §3).
- **G1 per seed** — t0: exactly ONE in-window monster, `mon_zombie`, hp 80, adjacent one south. Per
  step: **turn advanced OR moves decreased** (the divert discriminator — a safe-mode/auto-travel
  divert burns NEITHER; a fist attack can cost less than a full turn, so strict turn-increase would
  be wrong); avatar `pos_abs` held; target holds its tile; monster count 1 everywhere
  (join-by-elimination validity — monsters have no stable instance id, doc 59) and `type_id ==
  mon_zombie` in every export (a mid-run `poly()` would rescale hp); hp non-increasing;
  **≥1 hp drop** (the RNG-dependent gate, 27B pattern); **zombie alive at end** (no-kill bound);
  NPC Edwardo PRESENT at t0 with a real `pos_abs` and `is_stationary` (its own gate — an empty or
  position-less `entities.npcs` export cannot pass vacuously), then `is_stationary` + position held
  in every export; transcript PRESENT and carries **zero error events** (keyed on `exit_code`, which
  only error events carry: ANY prompt on this path is an attack-path failure; an avatar-death
  DEATHCAM query would fail red as run-death, not attack-path).
- **G2 contrast arm per seed (attribution)** — the identical fixture and seed with every `move_s`
  replaced by `wait`: t0 identity as in G1; the zombie's hp stays **exactly 80 in every export**
  while it stays adjacent (same exposure as the bump arm) and the clock advances; avatar held;
  transcript present and error-free. With the avatar not attacking, ANY other damage source — the
  NPC, fields, traps, defensive traits/bionics, a type change, known or not — would lower hp here
  too, so G1's drop is attributed by experiment rather than only by the review-time elimination
  below. It is a separate run with its own RNG draw: an intermittent third party is made unlikely
  across three seeds, not impossible.
- **Review-time elimination (2026-10-21, NOT gated — G2 is what checks it every run).** Re-verified
  at the source/fixture: the avatar has `my_bionics: []` and six cosmetic/inert traits (hair_treated,
  GOURMAND, KILLER, eye_blue, hair_platinum_blond, SKIN_LIGHT — none of the on-hit defensive ones
  such as SPINES/QUILLS/THORNS/ACIDBLOOD); Edwardo wields a `throwing_knife` whose only flag is
  `SHEATH_KNIFE`, and an NPC throws only `NPC_ALT_ATTACK`/`NPC_THROW_NOW` items
  (`npcmove.cpp:3938-3951`) — no item in the data carries `NPC_ALT_ATTACK`; the generated clone
  carries `"upgrades":false`. Also re-verified (2026-10-21, decoded `ArcopolisTest/map.sqlite3` —
  the fight fixture rewrites only the `.sav`, so it shares this map): **no fields and no traps** in
  the 3×3 submaps around the avatar (empty `fields`/`traps` arrays; the engine writes one entry per
  occupied tile, `savegame_json.cpp:4468-4489`, so empty means none); Edwardo is the **only NPC
  record** in the world's overmap files, and none of the 21 items in his weapon/worn/inventory tree
  is a `GUN`, carries a reach flag, or is NPC-throwable — so a melee attack would need him to move
  (G1 catches that).
- The zombie's counter-hits populate `avatar.damage_taken[]` (the 27B surface) — **reported, not
  gated**: expected, not a confound.

## 3. Kill-safety arithmetic (why hp 80 and K=6)

`make_monster_fixture.py` historically hardcodes witness `hp = 20` (`:188` pre-change) — right for
the liveness/damage witnesses, but a repeated-bump witness would EXPECT a mid-run kill at 20
(median unarmed kill ≈ 6-7 landed hits), violating the ratified no-kill bound and false-firing the
avatar-held falsifier (a vacated tile turns the next bump into real movement). The additive
`--hp` flag authors the type's natural pool instead: **80 = `mon_zombie`'s `type->hp`**. Only the
**hp** is type-natural — the witness is NOT a freshly-spawned zombie: `build_witness` clones the
world's stock wildlife template and overrides only position/hp/moves/speed/hostility, so the clone
keeps `faction:"small_animal"` (a spawned zombie gets its `default_faction`, `zombie`) and is
authored `speed` 100 (`mon_zombie`'s is 70). Neither affects the avatar's attack or the hp
bookkeeping this witness reads; faction can affect how the NPC assesses the threat, which G2 covers
behaviorally.

Crit-inclusive worst case per hit for the fixture avatar (**str 10**, unarmed/bashing skill 0, bare
fists, `style_none` selected, no damage-relevant mutations — the avatar carries six cosmetic/inert
ones, none with `bash_dmg_bonus`/`rand_bash`), verified at the leaf. Premise gating: `"str_max":10`
is asserted in G0; the bare-fists premise has no `.sav` shape to assert textually (no `weapon` key
serializes in this fixture's save) and is backstopped behaviorally — a wielded weapon cannot
false-green, only kill faster, which `zombie_alive_at_end` reds:

```
stat roll   rng_float(str/2, str)      → max 10.0     melee.cpp:2025 (via bonus_damage)
+ skill     unarmed adds skill = 0                    melee.cpp:2100
low-cap     rng_float(0.5·wd, wd)      → max 10.0     melee.cpp:2126-2128 (low_cap = str/20 = 0.5)
bash_mul    0.8 at skill 0                            melee.cpp:2110
crit        bash_mul ×1.5 → 1.2                       melee.cpp:2139-2140
armor       mon_zombie armor_bash 0
MAX/HIT     10.0 × 1.2 = 12
```

**K = 6 bumps → worst case 6 × 12 = 72 < 80: provably kill-safe** even under six consecutive
max-roll criticals. (K=8 would allow a theoretical 96 > 80 — an exploratory K=8 run passed all
gates, but the shipped default is the provable bound.) The vanished-entry rule stays as the
defined backstop: a missing `entities.monsters[]` entry after a prior hp drop is a
**kill-headroom failure, gate RED** — never read as success or knockback.

## 4. Generator `--hp` flag + the default-identity gate

`build_witness(..., hp=20)` + `--hp` (default 20). The default path assigns the same value to the
same existing key of the deep-copied template, so default output is byte-identical by
construction — and **G-ID enforces it mechanically** every run (regenerate with default generation
flags → SHA256 against the reference `ArcopolisNearMonsterTest` `.sav` from the resolved fixture
root). **Scope: G-ID hashes the `.sav` only** — today the generator's sole content write
(`rmtree` + `copytree` + one `.sav` rewrite; a fresh default regeneration was additionally verified
file-by-file identical across all 13 world files) — a future flag that writes other world files
(as the stairs generator does) needs a wider comparison. The ratified isolation bound also
requires: always `--dest-world ArcopolisFightTest`, never `--force` at the default destination
(the generator's default dest is the committed monster-export witness).

## 5. The safe-mode render-coupling artifact (load-bearing; found by the red-team)

The committed pack ships `SAFEMODE: true` (`config/options.json`); the committed `.sav`s carry
`run_mode:1`/`mostseen:0`, but the loader DISCARDS them — `game::load` overwrites `safe_mode`
purely from the SAFEMODE option and resets `mostseen = 0` (and `manual_combat_mode = false`) AFTER
unserialize (`game.cpp:3984-3986`). That post-load clobber is what makes the sandbox options pin
the live control on every build flavor: the `savegame.cpp:363-366` run_mode restore, read alone,
could only be UPGRADED off→on by the option and would defeat an options-only pin. Safe mode's STOP
is set only in `game::mon_info_update`
(`game.cpp:5566-5567`), called each player-action-loop iteration BEFORE `handle_action`
(`game.cpp:2149-2151`) — but `mon_info_update` **early-returns when
`!player_visibility_cache_current()`** (`game.cpp:5319-5326`), and that gate is
`#if defined(CATA_SDL)` → `variables_set && !visibility_caches_dirty()`, else unconditionally
`true` (`game.cpp:5310-5317`). Consequences:

- **headless TILES (today's build): safe mode never fires** — the caches stay dirty because
  `game::draw` is a test_mode no-op — so a hostile-adjacent witness would run while the GUI, for
  the identical fixture and input, would STOP ("safe mode is on!") and refuse the move;
- **curses build (or after a headless visibility-cache refresh lands — upstream #10104 adds one to
  `do_turn`; re-check at the next sync): PREDICTED to fire** — source-inferred, never run: the
  STOP additionally requires the avatar to see the monster (`!u.sees( critter )` early return,
  `game.cpp:5441`); where it fires, driven moves die at `check_safe_mode_allowed()`
  (`avatar_action.cpp:363`) with ZERO moves consumed, the script drains inside one parked turn, and
  the signature would misread as an RNG all-miss. (`command_error_kind::safe_mode_blocked` is
  declared but emitted nowhere.)

The witness therefore **pins `SAFEMODE=false` in the SANDBOX options.json** — the GUI-equivalent
of the player disabling safe mode, taking the safe-mode branch out of the GUI/headless comparison on
every build flavor (the script's post-check proves the TEXT edit only; on today's tiles build, where
safe mode is inert anyway, the pin's engine effect is unwitnessed) — and gates per-step time advance
so a regressed pin would fail with attribution wherever safe mode is live. Behavior under `SAFEMODE=true` is
deliberately **not witnessed**; the artifact is recorded here, not resolved. Every future
hostile-in-view witness must carry the same pin.

## 6. What this does NOT prove (do not let docs widen it)

Level 4 for the attack · that the move took the §1 path (source-read, not observed) · a fight
ROUTE (doc 60's Spike-31 framing, narrowed here; the fight-route composition is the open, uncarded
remainder of step 5) · any sneak / slice-route composition (step 6, OPEN) · the drone half of step 5
(doc 60's "Spike 30", expected 29B, OPEN) · Q3 (open maintainer decision) · NPC or ranged targets ·
kill/death handling (out of scope by ratified bound) · multi-monster attribution (single-monster
fixture only; no stable instance id) · GUI display equivalence of hp (the GUI shows bands) ·
behavior under `SAFEMODE=true` (pinned away, §5) · any generic claim about other monster types,
armors, or weapons.

## 7. Validation record (2026-07-04, revised 2026-10-21; exe of 2026-06-30)

**Revision 2026-10-21 (merge-review hardening):** contrast arm G2 (six per-seed gates), per-export
`monster_type_held`, `is_stationary` + real-`pos_abs` NPC gates, zero-seed guard (exit 11), and the
doc-scope corrections above (Spike-31 narrowing, safe-mode prediction labelled source-inferred,
"type-natural" limited to hp). `pwsh docs/arcopolis/fight_mechanic_regression.ps1` with the
2026-06-30 exe — **all gates green ×3 seeds**: bump arm zombie hp 80→58 / 80→43 / 80→63 (counter-hits
3/4/2); contrast arm hp held at exactly 80 in every export on all three seeds while the zombie stayed
adjacent and hit the avatar 5/7/5 times across 6 turns (so the control is not trivially quiet).
Before this revision, two reruns of the 2026-07-04 script were green (07-05: 80→64/62/56; 10-21:
80→61/58/67), and in all six of those runs every hp decrement matched the engine's own "You hit /
whack the zombie for N" messages (display text — corroboration, not a gate).

`pwsh docs/arcopolis/fight_mechanic_regression.ps1` (2026-07-04 revision: the fourteen G1 per-seed
gates incl. `npc_present_at_t0` and the transcript-must-exist strictness, plus G0's
`avatar_str_max_10`) — **all gates green**: G-ID byte-identical; G0 pins hold; three seeds (`fight-alpha/bravo/charlie`) at K=6:
zombie hp 80→55 / 80→54 / 80→61, avatar and target held every step, every step advanced, monster
count 1 everywhere, transcripts present and clean, zombie alive at end, counter-hits on the avatar
0/2/2 (reported only). Two earlier same-day runs of the pre-revision script also passed: K=6
(hp 80→60/57/72, counter-hits 3/2/2) and an exploratory K=8 (hp 80→57/65/56) before the provable
K=6 bound was adopted per the plan's kill-safety stop condition.
`pwsh docs/arcopolis/monster_export_regression.ps1` (which gains the same G-ID gate in this change)
— **all gates green**: G-ID byte-identical, the witness in-window on all three snapshots, viewer
exit 0 with `monsters_off_window=0`.
