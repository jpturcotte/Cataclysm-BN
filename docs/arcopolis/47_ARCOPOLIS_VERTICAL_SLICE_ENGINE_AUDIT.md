# Arcopolis Vertical Slice Engine Audit — Stage A

## Status and scope

- **Research/audit only.** No source, test, script, fixture, build, CI, or runtime behavior changed.
- **Stage A only.** Stage B deferrals named in §10.
- **Baseline:** worktree branch `claude/affectionate-hermann-d67063` @
  `4828d586c69e62fe812cdee8604cd5aea65997a1` (off `arcopolis`); PRs #57/#58/#59 included.
- **Final, consolidated audit.** This is the single deliverable. It supersedes the earlier draft passes; the
  questions that could be settled from the repo without a build have been settled and are recorded under
  _Provenance_ (end). One earlier draft claim — that the bump-melee path does not arm the technique-prompt
  suppression guard — was **wrong** and is corrected here; see §6 and Provenance.
- **Honesty stance.** Where a capability rides an existing witnessed command but has **no Arcopolis fixture
  of its own**, this doc says so in the prose, not only in the label. "Reachable through the existing `move`
  path" is **not** "drivable and witnessed." This is the `38_LEVEL4_TRUTH_AUDIT.md` discipline applied to
  prose, not just labels.
- **Citations** are current-tree; confirm by symbol. Line ranges drift — every load-bearing citation in this
  doc was opened first-party this session. Web sources give context only; **every Stage A capability claim is
  sourced from this repo.**

## 1. Stage A product target

A **nobody** protagonist enters a **5–6 floor vertical complex** in a persistent city, finds a **package**
hand-placed somewhere in the complex, and **returns it to the starting / contact area**. The slice exercises
vertical navigation (≥5 stacked floors); package placement, observation, pickup; a simple fight route using
**native** security drones/robots; a sneak/alternate route using **native** terrain/navigation; and
snapshots/transcript sufficient for the frontend to understand avatar floor/position, package presence (and
ideally that it is carried), enemy presence/health, and each command's typed outcome.

**Return / contact resolution is a placeholder.** Reaching the contact tile carrying the package is the
success signal; the _shape_ of "return success" is formalized as **Spike 2** (§9) — and is **not** a thing
Stage A can observe today (the carried package is invisible; §5).

## 2. Evidence labels

| Label              | Meaning                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| **PROVEN**         | Implemented in BN **and already witnessed** by an Arcopolis test / regression / fixture.         |
| **NATIVE-BN**      | Implemented in BN code/data, but **not yet driven or witnessed through Arcopolis**.              |
| **LIKELY**         | Supported by code shape, needs a fixture/regression to confirm.                                  |
| **UNKNOWN**        | Not enough evidence found.                                                                       |
| **NOT FOUND**      | Searched the named scope and found no repo evidence (queries + scope recorded).                  |
| **NEEDS NEW SEAM** | BN may support it in the GUI, but Arcopolis cannot currently **drive or observe** it faithfully. |
| **STAGE B**        | Real requirement, intentionally deferred from this audit.                                        |

**PROVEN-shape ≠ PROVEN.** A capability that rides an already-witnessed command (`move`/`examine`/`pickup`/
snapshot) but whose specific Stage A scenario has **no fixture** is labeled **NATIVE-BN** and described in
prose as "reachable but unwitnessed" — never "drivable now" without that qualifier.

## 3. Relevant baseline after PR #57–#59

- **Measured coverage feasibility exists** (`45_WINDOWS_COVERAGE_FEASIBILITY.md`, Spike 22, PR #57): the
  Windows LLVM 22.1.7 / clang-cl source-based path works end-to-end (89.27% region / 86.75% line / 98.53%
  function on Arcopolis-owned files).
- **MSVC native coverage was NOT recommended** (collector absent on VS Community).
- **PR #58 fixed the clang-cl `<cxxabi.h>` include** in `src/demangle.cpp`; the empty-`cxxabi.h` shim is no
  longer needed.
- **Doc 46 (PR #59) is the modernization guardrail:** targeted, test-backed, backend-relevant refactors
  only; no big-bang C++23 rewrite; repo already builds as C++23.
- **Coverage is not backend equivalence.** This audit does not treat coverage numbers as proof of
  prompt/input equivalence, and recommends **no CI coverage gate and no repo-wide coverage target.**

## 4. Native verticality feasibility

BN's engine and content support a 5–6 floor complex; Arcopolis cannot yet **drive explicit vertical
movement** or **observe more than one floor at a time**. The `hotel_1` floor count is stated precisely below,
and `office_tower` is excluded (it is only 2 z-levels).

| Mechanism                           | Repo evidence                                                                                                                                                                                         | Label                                                                                 | 5–6 floors?      | Arcopolis status (honest)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Z-level capacity                    | `OVERMAP_DEPTH = 10`, `OVERMAP_HEIGHT = 10`, `OVERMAP_LAYERS = 21` (`src/game_constants.h:64-68`)                                                                                                     | NATIVE-BN                                                                             | Yes              | n/a (capacity).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Z-levels on by default              | `bool zlevels = true` (`src/mapbuffer.h:83`); FoV-3D option group (`src/options.cpp:2493`)                                                                                                            | NATIVE-BN                                                                             | Yes              | Pin in fixture options.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Stairs vertical primitive           | `game::vertical_move` (`src/game.cpp:14076`); `find_stairs:14835`; `find_or_make_stairs:14896`                                                                                                        | NATIVE-BN                                                                             | Yes              | **Not drivable** — vertical excluded from `move` vocabulary; prompt-heavy. **Spike 1** (§9).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Action dispatch + string tokens     | `ACTION_MOVE_UP/DOWN` dispatch `vertical_move` (`src/handle_action.cpp:2184,2212,2239,2307`); `"move_up"/"move_down"` already resolve to actions (`src/action.cpp:657-660`)                           | NATIVE-BN                                                                             | Yes              | Engine half is ready; the Arcopolis verb just needs to map to the existing token.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Ramps (auto-z inside planar `move`) | `TFLAG_RAMP_UP` → `dest_loc.z()+=1; via_ramp=true`; `TFLAG_RAMP_DOWN`/ladder → `dest_loc.z()-=1; via_ramp=true` (`src/avatar_action.cpp:390-397`); ramp ids `terrain-zlevel-transitions.json:246-276` | NATIVE-BN (reachable via `move`; ramp branch prompt-free; **end-to-end unwitnessed**) | Yes (ramp tower) | **Resolved this session:** the ramp branch (`:390-397`) adds **no prompt**, sets the destination to the same x/y at `z±1`, and hands off to `g->walk_move(dest_loc, via_ramp)` (`:682`,`:730`). So ramp traversal reduces to a normal planar `walk_move` carrying a `via_ramp` flag onto a z-changed tile (`RAMP_END` is the landing-side flag, `:216`). The only residual is whether `walk_move` itself prompts on the z-changed dest — the same question as any planar `move`, which Arcopolis already drives. A one-command probe should confirm the remaining `walk_move` end-state; the ramp branch itself is no longer fully unverified. |
| Stairs/ladder/ramp terrain content  | `terrain-zlevel-transitions.json:119-276` (stairs/ladders/ramps, `GOES_UP`/`GOES_DOWN`); `t_elevator` `terrain-floors-indoor.json:475`                                                                | NATIVE-BN                                                                             | Yes              | n/a (data).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Elevator + interactive control      | `TFLAG_ELEVATOR`; `src/iexamine_elevator.cpp:1-47` (uses `"ui.h"`)                                                                                                                                    | NEEDS NEW SEAM                                                                        | Yes              | Elevator menu would fail loud (Spike 21). Not Stage A.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **`hotel_1` — a real city tower**   | `hotel_1` city_building, `hotel_tower_*` overmaps. **Verified tiles-per-z: z=-1→3, z=0→10, z=1→6, z=2→6, z=3→6, z=4→6** (`data/json/overmap/multitile_city_buildings.json:2648-2690`)                 | NATIVE-BN                                                                             | **Yes**          | **6 z-levels = partial basement (z=-1) + full ground lobby (z=0, "floor 1") + 3 upper floors (z=1/2/3, the file's `flr2`/`flr3`/`flr4`) + walkable roof (z=4, atop floor 4).** A genuine 5-floor-plus-roof tower (the roof is the z-level above the top floor, not a 5th floor). But it spawns via **procedural** city generation — see the use-path caveat below.                                                                                                                                                                                                                                                                             |
| Other confirmed multi-z content     | `lab_subway_vent_shaft` z=1..-3 = 5 z (`specials.json:3212-3216`); `lab_stairs` (`specials.json:703`)                                                                                                 | NATIVE-BN                                                                             | Yes              | n/a. (`office_tower` is **excluded:** verified tiles-per-z `{z=-1:4, z=0:4}` — only 2 z-levels, a basement+ground building, **not** a tall tower.)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Arcopolis vertical command          | Vertical excluded from `move` vocabulary (`src/arcopolis_command.cpp:60-77,244`)                                                                                                                      | NEEDS NEW SEAM                                                                        | n/a              | No — by design.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Arcopolis multi-floor observation   | Single-z window: `in_export_window` requires `p.z() == center.z()` (`src/arcopolis_export.cpp:180-185`), radius 12 (`:38`), z = `get_levz()`                                                          | NEEDS NEW SEAM                                                                        | n/a              | Per-floor observation is **LIKELY** (code shape: snapshot rebuilds and reads `get_levz()` each command), **but no fixture has witnessed a snapshot taken after a z-change** — make it a Spike 1 assertion, not a fact. Simultaneous multi-floor: no.                                                                                                                                                                                                                                                                                                                                                                                           |

**`hotel_1` use-path caveat.** `hotel_1` is the thematically ideal Stage A complex, but it is placed by
**procedural city generation** — there is no committed fixture that anchors the avatar inside one. Using it
in a deterministic regression means either (a) finding a seed that lands a `hotel_1` near the `ArcopolisTest`
start (untested, fragile) or (b) save-editing the overmap to inject one (no existing generator does this). A
**purpose-built multi-submap save fixture with aligned stairs** is therefore the more deterministic Stage A
path, with `hotel_1` as the eventual product-faithful target — not the first witness.

**`find_or_make_stairs` is a determinism hazard for misaligned fixtures — and the exact safe condition is now
known.** `game::find_or_make_stairs` (`src/game.cpp:14896`) calls `find_stairs` and **returns immediately if
it finds a stair** (`:14904-14909`); it **only fabricates** one — `// No stairs found! Try to make some` →
`stairs.emplace( bub_pos ); stairs->z() = z_after;` (`:14911-14914`) — and raises its **four** lava/
deep-water/one-way `query_yn` prompts (`:14918,14922,14934,14939`) **when `find_stairs` returns `nullopt`.**
`find_stairs` (`:14835`) returns a tile when either (a) the tile **directly above/below** carries
`TFLAG_GOES_UP`/`GOES_DOWN` — the deterministic fast path (`:14840-14846`) — or (b) a nearest-in-OMT search
finds one (`:14854-14867`). **Plus a second prompt source:** `find_stairs` itself raises a `query_yn`
("Attempt to push past?") if a **creature occupies the chosen stairs tile** (`:14885-14887`). Consequences
for Stage A: **Spike 1's fixture generator must assert a matched stair pair** — (1) the avatar's **current**
tile carries the travel-direction flag (`GOES_UP` to ascend / `GOES_DOWN` to descend), because
`game::vertical_move` otherwise diverts a flagless up-move into the climb branch (`src/game.cpp:14095`) and
never reaches stair traversal; (2) the **counterpart** stair sits **directly above/below** (hits
`find_stairs`'s fast path and pins a deterministic destination tile); **and** (3) **no creature on the
destination stairs tile.** All three ⇒ no climb diversion, no fabrication, no `query_yn`, deterministic.

**What could silently fail / overclaim:** single-z snapshot makes a multi-floor complex _look_ one floor
deep; any `vertical_move` sub-prompt must fail loud (AGENTS.md "Arcopolis backend input equivalence"
section); a ramp success on one tile does not prove "stairs work"; auto-made stairs perturb fixture
determinism.

## 5. Package / objective placement feasibility

- **Item candidate.** `briefcase` (`data/json/items/armor/storage.json:222`, type `ARMOR`, storage `15 L`).
  Alternatives: `box_small` (`containers.json:362`), `case_violin` (`armor/storage.json:245`). NATIVE-BN.
- **Objective tagging.** `MISSION_ITEM` is a real engine flag (`src/flag.cpp:202`; `src/flag.h:203`).
  Stage A needs only a uniquely-identifiable item at a known tile; live mission binding is **STAGE B**.
- **Placement.** Mapgen `place_item`/`place_items`/`place_loot`/`place_nested` (`src/mapgen.cpp:3850-3869`);
  direct `place_items(...)` calls (`:4463+`). NATIVE-BN. Save-edit preferred for determinism.
- **Persistence (be specific about which store).** Submap **terrain** edits go through `map.sqlite3` (the
  `.map` RLE `terrain` field — confirmed in `make_wall_fixture.py`'s own header). Monster and other
  dynamic-entity edits go through the `.sav` JSON (confirmed in `make_monster_fixture.py`). Ground items live
  in the submap and serialize with the save. Every committed fixture under
  `docs/arcopolis/fixtures/arcopolis_user/save/Arcopolis*/` has both a `.sav` JSON and a `map.sqlite3`.
  `ArcopolisTest` already carries 27 deterministic in-window ground items (`19_SPIKE8A_ITEM_EXPORT.md`;
  `TEST_FIXTURES.md:31-33`). **NATIVE-BN / PROVEN** for persistence.
- **Observation.** `entities.items[]` exports each windowed tile's **top-level ground stack** (`map::i_at`)
  (`src/arcopolis_export.cpp`; `ARCOPOLIS_STATE.md:154-166`). **PROVEN** for ground export.
- **Pickup.** `pickup` drives the real old `"PICKUP"` menu at level 4 (`prompt_menu_regression.ps1`;
  `ARCOPOLIS_STATE.md:205-231`). **PROVEN** for `NEW_PICKUP_MENU=false`.
- **Carried-package gap (NEEDS NEW SEAM).** Once picked up, the package is in **avatar inventory**, which
  the snapshot does **not** export (`ARCOPOLIS_STATE.md:654-659`). A carried package is invisible to the
  frontend; "package returned" is unprovable from the snapshot alone. **Subject of Spike 2 (§9).**

**Easiest first proof.** Save-edit a **small** ground item (`box_small`, `containers.json:362`) onto a
windowed tile, assert `entities.items[]` shows it, `pickup` removes it. (Prefer a low-volume item over the
15 L `briefcase`: a bulky item picked up by a low-free-volume avatar can route the old `PICKUP` flow into a
capacity/wear/wield prompt instead of a clean removal — use `box_small`, or assert the fixture's free volume.)
Reuses witnessed item-export + pickup paths with **no new engine code.**

**Stage A constraints.** Top-level ground item only; `NEW_PICKUP_MENU=false`; treat "package retrieved" as a
snapshot fact (item missing from ground + recorded pickup outcome) until Spike 2 chooses a richer signal.

## 6. Fight / security route feasibility

- **Drone/robot candidates (NATIVE-BN).** `mon_eyebot` (`utility_bot.json:3`), `mon_manhack`
  (`drones.json:101`), `mon_copbot`/`mon_riotbot`/`mon_secubot`/`mon_science_bot`
  (`defense_bot.json:3,47,89,242`), turrets (`data/json/monsters/turrets.json`).
- **Ranged attack (NATIVE-BN, citation closed this session).** `mon_secubot` carries a full `gun`
  special-attack block — `"type": "gun"`, `"gun_type": "m16a4"`, `"ammo_type": "556"`,
  `"ranges": [[0,20,"BURST"],[21,30,"DEFAULT"]]`, targeting cost/sound, etc.
  (`data/json/monsters/defense_bot.json:112-135`, read first-party). Engine resolves at turn tick — there is
  no Arcopolis command for the _enemy_.
- **Hostility / faction (NATIVE-BN, citation closed this session).** `mon_secubot`:
  `default_faction: "defense_bot"` (`:93`), `aggression: 100` (`:103`), `morale: 100` (`:104`). The other
  bots were re-read this session: `mon_copbot` `default_faction: "cop_bot"` (`:7`), `aggression:100`/
  `morale:100` (`:17-18`); `mon_riotbot` `default_faction: "cop_bot"` (`:51`), `100`/`100` (`:61-62`).
  **Note:** copbot/riotbot are faction `cop_bot`, not `defense_bot` — they are not the same faction as
  secubot. All three are hostile by default.
- **Placement (NATIVE-BN).** Mapgen `place_monster`/`place_monsters` (`src/mapgen.cpp:3861,3866`); example
  `data/json/mapgen/Bastion_Fort.json:215`. The existing `make_monster_fixture.py` injects one monster
  deterministically (`TEST_FIXTURES.md:46-52`) — **but it authors a _passive_ witness** (`anger=0`,
  `morale=0`, `aggro_character=false`, `special_attacks={}`, default `IMMOBILE` `mon_fungal_wall`, and it
  keeps the _cloned template's_ ammo) (`docs/arcopolis/make_monster_fixture.py:161-167`). A **hostile** fight
  fixture needs its own generator/reset that sets the bot aggressive (so a bump does not hit the
  `QUERY_BEFORE_ATTACKING_NEUTRAL` confirm at `avatar_action.cpp:560`) and gives `mon_secubot` its `556` ammo
  (else it sounds `no_ammo_sound`, not the ranged-witness message).
- **Patrol / building alarm (NOT FOUND — searched this session, scoped negative).** No _scripted_ monster
  patrol in `src/monmove.cpp`, `src/monster.cpp`, or `data/json/monsters` (queries: `patrol`/`guard`/
  `wander`), and a broader `data/json` `patrol` sweep returns only vehicle/loot/mapgen/itemgroup hits — **no
  monster patrol behavior is JSON-defined** (it is autonomous C++ AI, `src/monmove.cpp` — emergent,
  nondeterministic). **This fork has no `effect_on_condition` (EOC) system in its JSON at all** (zero hits for
  the `effect_on_condition` type and the bare `EOC` keyword across `data/json`), so the "EOC alarm" angle is
  moot here. A `data/json`-wide `alarm` search (109 files) surfaces only vehicle **car alarms**, the
  **craftable tripwire trap** (`tr_can_alarm`, `data/json/traps.json:244-257`), trap recipes, and
  mapgen/furniture/flavor text — **no building security-AI alarm subsystem.** Treat patrol/alarm gameplay as
  **UNKNOWN / STAGE B**; a building alarm, if added, would be a placed trap or C++ logic, not a JSON system to
  lean on.
- **Arcopolis observation (PROVEN).** `entities.monsters[]` exports `type_id`/`name`/`symbol`/position/
  `hp`/`hp_max`/`moves`/`hallucination` (`ARCOPOLIS_STATE.md:152-153`; `monster_export_regression.ps1`).
- **Bump-melee on a hostile monster (NATIVE-BN, reachable via `move`, unwitnessed).** A hostile bump
  (`friendly==0 && att != MATT_FRIEND`) goes straight to `melee_attack_from_movement( you, critter )` with
  no prompt at the bump site (`src/avatar_action.cpp:533-569`). Only a **neutral** creature triggers
  `query_yn` (`:560`, gated on `QUERY_BEFORE_ATTACKING_NEUTRAL`). Distinct from move-into-NPC (`:578-588`,
  fails loud, Spike 21). **No Arcopolis fixture witnesses a drone melee yet.**
- **Technique-prompt suppression — corrected this session (an earlier draft had this backwards).** The
  earlier pass claimed the bump path does **not** arm the suppression guard, so a technique prompt would
  likely fire. **That is wrong.** The bump call site does not attack directly — it delegates:
  `melee_attack_from_movement` (`src/avatar_action.cpp:181-184`) calls
  `melee_attack_while_handling_manual_combat_mode` (`:971-981`), which **does** arm
  `melee::technique_prompt_suppression_guard` (`:979`) **except** when `g->manual_combat_mode` is on
  (`:974-976`). And `manual_combat_mode` **defaults to `false`** (`src/game.h:1196`) and is set false on
  construction (`src/game.cpp:940,3984`). **It is serialized in the save** (`src/savegame.cpp:98`); on load it
  is reset to false and then **overwritten by the saved value** (`:366-367`), so a save that recorded
  `manual_combat_mode: true` restores `true` — the fixture must **save the field false**, not rely on load
  forcing it. The guard is queried at exactly one site, `src/melee.cpp:1593`; when armed, `is_technique_prompt_suppressed()`
  is true and the non-interactive `pick_technique(...)` branch runs (`:1606-1607`) — **no prompt.** Net:
  **in default play, bump-melee IS technique-prompt-suppressed.** The interactive `choose_melee_technique`
  prompt (`:1594-1605`) can only fire if `manual_combat_mode` is toggled **on** (`ACTION` at
  `src/handle_action.cpp:3097`), which Arcopolis does not do. **Implication:** the simple bump witness is
  safe; the fight fixture should **pin/assert `manual_combat_mode == false`** and still **fail loud on any
  unexpected prompt** as a guard against regressions. `autoattack` (also guard-armed, `:956`) is a fallback,
  not a requirement.
- **Player ranged combat is STAGE B.** `ACTION_THROW`/`ACTION_FIRE`/`ACTION_FIRE_BURST` dispatch
  (`src/handle_action.cpp:2552-2570`) but the targeting UI is its own prompt path; not in
  `arcopolis_command.cpp:195-245`. Stage A fight is **melee or avoidance**, not player gunplay.

**Simplest native fight-route proof.** Lowest-risk is **observation-only**: save-edit a hostile drone in
the monster window, `wait`, witness presence + (for `mon_secubot`) a ranged-attack engine message — no
equivalence claim. The **melee** witness is a safe follow-on: a raw bump in default play is
technique-prompt-suppressed (above); the fixture pins `manual_combat_mode == false` and asserts no unexpected
prompt fires, failing loud if one does.

**Best first security entity (resolved this session).** **`mon_turret_searchlight`**
(`data/json/monsters/turrets.json:3`) is the best _positional_ witness — `IMMOBILE` (`:29`), `hp 30` (`:12`),
and its only attack is `SEARCHLIGHT` (`:26`), so it never shoots or melees the avatar. **But do not bump it to
death:** its `death_function` is `FOCUSEDBEAM` (`:28`), and `mdeath::focused_beam` detonates an explosion at
the turret's tile (`src/mondeath.cpp:682`, "~20 damage") that catches an adjacent melee attacker. So a
searchlight witness must **assert a non-lethal `hp` decrement and stop before the kill.** If the fixture must
bump _to death_, choose a `BROKEN`-death target (no explosion): `mon_manhack` (`drones.json:101,119`,
melee-only — but `speed 190` + `HIT_AND_RUN` `:120` kites, less deterministic), or `mon_copbot`/`mon_riotbot`
(`BROKEN` death at `defense_bot.json:33,75`, but `hp 80` plus an on-contact special — `COPBOT` handcuff /
`RIOTBOT` gas + `ZAPBACK`). **Avoid for the first witness:** `mon_secubot` (gun, range 30, `speed 40`, lethal)
and `mon_laserturret` (gun + `RETURN_FIRE`, `turrets.json:54-75`).

## 7. Sneak / alternate route feasibility

| Route candidate                          | Repo evidence                                                                                                                                                               | Label                                                             | Stage A or later?              |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------ |
| **Alternate unlocked door**              | `m.open_door(&you, dest_loc, ...)` inside move body → `moves -= 100; return true` (`src/avatar_action.cpp:691-709`); `t_door_c → "t_door_o"` (`terrain-doors.json:196,205`) | NATIVE-BN (reachable via `move`; **unwitnessed**)                 | **Stage A**                    |
| **Unguarded route (avoid the fight)**    | Planar movement witnessed; enemies in `entities.monsters[]`                                                                                                                 | NATIVE-BN (planar move witnessed; the _route composition_ is not) | **Stage A**                    |
| **Locked door (lockpick)**               | `t_door_locked`/`lockpick_result` (`terrain-doors.json:1440-1448`); `iexamine::locked_object`/`pick_lock` (`src/iexamine.cpp:1774-1875,8226-8227`); `ACT_LOCKPICK`          | NEEDS NEW SEAM                                                    | Later                          |
| **Window / breakable terrain**           | `t_window` (`terrain-windows.json:4`); `ACTION_SMASH` (`src/game.cpp`)                                                                                                      | NEEDS NEW SEAM                                                    | Later                          |
| **Darkness / vision / patrol avoidance** | `Creature::sees` (`src/creature.cpp:369,450`); crouch `CMM_CROUCH` (`src/character.cpp:391`); sounds/lighting                                                               | NEEDS NEW SEAM / LIKELY                                           | Later (layout, not stealth AI) |
| **Acquire/craft a traversal item**       | Multi-turn crafting + menus (`docs/agent-map/01_MODULES_THIN_INDEX.md:128-132`)                                                                                             | STAGE B                                                           | Later                          |
| **Alarm avoidance**                      | `tr_can_alarm` (craftable tripwire, `data/json/traps.json:244-257`); no building security-alarm system and no EOC system found (§6 scoped search)                           | UNKNOWN / STAGE B                                                 | Later                          |

**Stage A sneak route should be layout-driven, not a stealth-system claim.** Use **already-open / unlocked**
or **unguarded** paths around a static threat — both _reachable through_ the witnessed `move`, though
neither route composition has its own Arcopolis fixture yet. **Silent-failure caveat:** headless
`seen=false` hides player LOS, so stealth _outcomes_ are engine-computed but not snapshot-observable; Stage
A must not claim "the player sneaked past undetected" from the snapshot alone.

## 8. Arcopolis command / snapshot gap matrix

| Required action                   | Native BN system                                          | Evidence                                                                                                                                                                                                | Label                                                                                                 | Verdict                                                                       |
| --------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Vertical move up/down (stairs)    | `game::vertical_move`; `ACTION_MOVE_UP/DOWN`; token table | `src/game.cpp:14076`; `src/handle_action.cpp:2184-2307`; `src/action.cpp:657-660`                                                                                                                       | NEEDS NEW SEAM                                                                                        | Feasible; **Spike 1** (§9). Mind `find_or_make_stairs` determinism (§4).      |
| Vertical move (ramps)             | `TFLAG_RAMP_UP/DOWN` auto-z inside planar move            | `src/avatar_action.cpp:390-397,682,730`                                                                                                                                                                 | NATIVE-BN (z-bump + prompt-free ramp branch confirmed; `walk_move` end-state needs a 1-command probe) | Reduces to a planar `walk_move` onto a z-changed tile (§4).                   |
| Vertical move (elevator)          | `iexamine_elevator` + `TFLAG_ELEVATOR`                    | `src/iexamine_elevator.cpp:1-47`                                                                                                                                                                        | NEEDS NEW SEAM                                                                                        | Deferred (uilist).                                                            |
| Move within a floor               | Planar `avatar_action::move` (8-way)                      | `ARCOPOLIS_STATE.md:189-204`                                                                                                                                                                            | PROVEN                                                                                                | Works today.                                                                  |
| Examine                           | `game::examine` (directed)                                | `ARCOPOLIS_STATE.md:192-204`; `examine_regression.ps1`                                                                                                                                                  | PROVEN                                                                                                | Works today.                                                                  |
| Open/close door (auto)            | `m.open_door` auto-open on move                           | `src/avatar_action.cpp:691-709`; `terrain-doors.json:196,205`                                                                                                                                           | NATIVE-BN (auto-open reachable, unwitnessed) / NEEDS NEW SEAM (explicit)                              | Unlocked auto-open reachable via `move`; explicit open/close deferred.        |
| Window/break                      | bash terrain; `ACTION_SMASH`                              | `t_window`; smash in `src/game.cpp`                                                                                                                                                                     | NEEDS NEW SEAM                                                                                        | Deferred.                                                                     |
| Locked door (lockpick)            | `iexamine::locked_object`/`pick_lock`; `ACT_LOCKPICK`     | `src/iexamine.cpp:1774-1875,8226-8227`; `terrain-doors.json:1440-1448`                                                                                                                                  | NEEDS NEW SEAM                                                                                        | Deferred.                                                                     |
| Pick up package                   | old `"PICKUP"` menu via `ACTION_PICKUP`                   | `ARCOPOLIS_STATE.md:205-231`; `prompt_menu_regression.ps1`                                                                                                                                              | PROVEN                                                                                                | Works today.                                                                  |
| Carry/return package              | avatar inventory                                          | inventory export deferred (`ARCOPOLIS_STATE.md:654-659`)                                                                                                                                                | NEEDS NEW SEAM                                                                                        | **Spike 2** (§9).                                                             |
| See package in snapshot           | `entities.items[]` (ground stack)                         | `src/arcopolis_export.cpp`; `ARCOPOLIS_STATE.md:154-166`                                                                                                                                                | PROVEN (ground) / NEEDS NEW SEAM (carried)                                                            | Ground yes; carried/other-floor no.                                           |
| See drone/enemy in snapshot       | `entities.monsters[]`                                     | `ARCOPOLIS_STATE.md:152-153`; `monster_export_regression.ps1`                                                                                                                                           | PROVEN                                                                                                | Works today (current floor).                                                  |
| Fight drone (melee)               | melee on hostile bump                                     | `src/avatar_action.cpp:533-569`; delegate arms guard `:971-981`; `manual_combat_mode` default false `src/game.h:1196`, save-persisted `savegame.cpp:98,366-367`; single check site `src/melee.cpp:1593` | NATIVE-BN (reachable via `move`, unwitnessed; **prompt-suppressed in default play**)                  | Feasible; fixture pins `manual_combat_mode=false` + fail-loud-on-prompt (§6). |
| Avoid drone                       | planar move to route around                               | `entities.monsters[]`; witnessed `move`                                                                                                                                                                 | NATIVE-BN (route composition unwitnessed)                                                             | Reachable via `move`.                                                         |
| Player ranged combat              | `ACTION_THROW`/`ACTION_FIRE`/`ACTION_FIRE_BURST`          | `src/handle_action.cpp:2552-2570`; not in `arcopolis_command.cpp:195-245`                                                                                                                               | STAGE B / NEEDS NEW SEAM                                                                              | Deferred.                                                                     |
| Route success/failure placeholder | command outcome + transcript                              | `tools/arcopolis_client/harness.py`; `session.jsonl`                                                                                                                                                    | NEEDS NEW SEAM (no quest-state export)                                                                | Spike 2 (§9).                                                                 |
| Return-to-contact placeholder     | position + (carried) package                              | `mission`/`objective` NOT FOUND in `src/arcopolis_export.cpp`                                                                                                                                           | NEEDS NEW SEAM                                                                                        | Spike 2 (§9).                                                                 |

## 9. Minimal Stage A proof plan

Two narrow spikes. Spike 1 is the load-bearing vertical-movement seam (next coding spike). Spike 2 is the
carried/return signal (a real Stage A gap; a Stage-A→B bridge, not a Spike-1 add-on).

### Spike 1 — vertical movement command + 2-floor stair fixture

**Equivalence level (conservative).** `ACTION_MOVE_UP/DOWN` reach the engine through `handle_action`'s real
dispatch, but `vertical_move` is **not** an `input_context::handle_input` prompt/menu loop. Per `AGENTS.md`
"Arcopolis backend input equivalence," level 4 requires the action to be consumed by the **active engine
input loop/mechanism a player would use** — which `move`/`move_up`/`move_down` do **not** satisfy today (they
are engine-action-reached, i.e. **level 2/3**, exactly as planar `move` is documented to be,
`ARCOPOLIS_STATE.md:12`). **Spike 1 should default to a level-2/3 claim; do NOT claim level 4** unless a
different mechanism that routes through a real registered-input loop is built and proven.

**Scope:**

- Add Arcopolis `move_up`/`move_down` verbs resolving to `ACTION_MOVE_UP/ACTION_MOVE_DOWN` through the same
  M1 dispatch the planar `move` uses (`src/handle_action.cpp:2184-2307`); the engine string tokens already
  exist (`src/action.cpp:657-660`). **Do not** call `game::vertical_move` directly from Arcopolis.
- Fixture: two floors with a **matched stair pair** — the avatar **stands on** the travel-direction stair
  (`t_stairs_down`/`GOES_DOWN` to descend, `t_stairs_up`/`GOES_UP` to ascend) and its **counterpart** sits
  **directly above/below**; no rope, climb prompt, elevator, vehicle, NPC, neutral creature, or monster on
  either stairs tile. **The generator must assert all three conditions from §4 before the run** — a flagless
  current tile diverts `vertical_move` into the climb branch (`src/game.cpp:14095`), while a misaligned or
  creature-occupied destination triggers `find_or_make_stairs` fabrication (`:14911-14914`) or the push-past
  `query_yn` (`:14885-14887`), perturbing determinism and possibly failing loud.
- Assert: command succeeds on aligned stairs; avatar `z` changes; **the post-move snapshot reports the new
  `z` and the new floor's tiles/entities** (this is the thing to _prove_, not assume — §4); a unit-level
  no-window/no-prompt check holds; session recoverable where the mode promises it; no curses window / render
  primitive in any build.

**Non-goals:** 5–6 floor proof; simultaneous multi-z export; elevators/ramps-as-feature/ropes/falls;
combat; doors/windows/smash/lockpick; package return; inventory export; any level-4 claim.

**Acceptance wording (only claim what the witness can hit):**

> Arcopolis can drive ordinary stair up/down movement through BN's `ACTION_MOVE_UP/DOWN` action path (level
> 2/3 — engine action reached, not registered-input level 4) in the witnessed 2-floor aligned-stair fixture,
> and the post-move snapshot coherently reports the new floor. **Any `vertical_move` sub-prompt the witness
> actually reaches fails loud rather than silently default** (the rope/autowalk/lava paths are out of scope
> for this fixture and therefore unwitnessed; a unit test pins the no-prompt expectation for the clean case).

**Files likely touched:** `src/arcopolis_command.{cpp,h}`, `src/arcopolis_backend_input.{cpp,h}`, the
existing `src/handle_action.cpp` dispatch (no change), `src/arcopolis_export.cpp` (no change for per-floor),
a new 2-floor save fixture + generator (a `make_wall_fixture.py`-style terrain generator — stairs are
terrain, so they go in `map.sqlite3`, §5), and a new `vertical_move_regression.ps1`.

**Tests/regressions to run:** `cata_test-tiles "[arcopolis]"`; `movement_regression.ps1`,
`client_harness_regression.ps1`, `examine_regression.ps1`, `prompt_menu_regression.ps1`,
`query_popup_regression.ps1`, `script_prompt_regression.ps1`, `live_protocol_regression.ps1`; plus the new
vertical regression. Run with **`pwsh`** (PS7, not `powershell` 5.1).

**Optional local coverage:** Windows LLVM / clang-cl per doc 45 (separate `out/build/win-llvm-cov`, never
reuse `win-rel-deb`). Not a gate; coverage is not equivalence.

### Spike 2 — package carried / returned signal

Do this **after** Spike 1, only if Stage A needs "retrieved **and returned**." Three honest designs; **the
choice is a product decision for the maintainer, not an audit recommendation** (Q3 §13):

| Design                             | What it proves                                                     | Cost / risk                                                                                            |
| ---------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| **Avatar inventory export**        | Package is actually carried after pickup (engine truth).           | New export surface; must be conservative about nested containers, charges, worn/wielded/storage state. |
| **Minimal objective-state export** | Stage A success flag explicit, without exposing full inventory.    | Most product-specific; must export only what the engine itself derives — no faked state.               |
| **Frontend-side heuristic**        | Package left ground + avatar at contact tile ⇒ _consider_ success. | Fastest, weakest; cannot prove the package is still carried (could be dropped/given away).             |

Each has a different honesty profile; whichever ships must be documented with its limit. The audit does not
pick one.

**Acceptance wording (whichever design ships):**

> **(inventory / objective-state export):** Arcopolis can prove "the package is currently carried by the
> avatar" for the witnessed fixture using <chosen design>; a frontend determines "package returned" from that
>
> - the avatar's exported position.
>
> **(frontend heuristic):** Arcopolis can show only that the package _left the ground_ and the avatar is at
> the contact tile — this **infers** success from weaker evidence and **cannot prove the package is still
> carried** (it may have been dropped or given away). The doc must label it as such.

### Lower-risk warm-up witnesses

- **Package fixture on ground (smallest; do this even before Spike 1).** A **small** item (`box_small`)
  save-edited onto a windowed tile; witness `entities.items[]` + `pickup` removal. (Avoid the 15 L `briefcase`
  for the clean-removal witness — §5.) No new engine code.
- **Hostile-drone observation fixture.** `mon_turret_searchlight` (immobile; non-lethal _attacks_ — but do
  not bump it to death, its `FOCUSEDBEAM` death explodes, §6) or `mon_secubot` (ranged message) save-edited on
  passable terrain; `wait`; witness presence. No equivalence claim.
- **Ramp probe (small, confirmatory).** Confirm what tile the avatar ends on after a `via_ramp` move and that
  `g->walk_move` raises no prompt on the z-changed dest (§4 — the ramp branch is already confirmed
  prompt-free; this probes only the `walk_move` end-state).

## 10. Stage B deferrals

- **Guard bribe/trade/dialogue** — NPC dialogue + trade menus (unsupported prompt class). Stage A uses
  monsters/terrain, not a talkable guard; must not show a working bribe.
- **Witnessed NPC conversation path** — `move`/`examine` into an NPC opens `npc_menu` and fails loud
  (`avatar_action.cpp:578-588`; Spike 21). Must not route the package through NPC interaction.
- **Guard hostile state after dialogue** — depends on dialogue.
- **Route-dependent consequences** — needs persistent quest/world state not exported.
- **Death continuation / new unrelated character** — lifecycle/world-persistence feature beyond the slice.
- **NPC/world memory** — no NPC opinion/memory export (`ARCOPOLIS_STATE.md:658-659`).
- **Corpse / dropped-loot persistence after death** — tied to death continuation.
- **Full procedural job generation** — Stage A uses a hand-placed package and a fixed complex; `MISSION_ITEM`
  binding (§5) is also Stage B.
- **Player ranged combat** — `ACTION_THROW`/`FIRE`/`FIRE_BURST` exist (`handle_action.cpp:2552-2570`) but
  the targeting UI is its own prompt path; not exposed.
- **Patrol / building security alarm** — no JSON patrol behavior and no EOC system exist in this fork (§6);
  any patrol/alarm gameplay would be new C++ AI, out of slice scope.
- **Party mechanics, full faction simulation, broad C++23 modernization** — out of slice scope; doc 46 is
  the guardrail.

## 11. Claims not to make yet

- **No "generic vertical movement"** — Spike 1 proves _aligned-stair_ up/down only.
- **No "ramps are a zero-engine-change verticality option"** until the `walk_move` end-state probe confirms
  the end-tile and prompt-free traversal (§4 — the ramp branch is prompt-free; the `walk_move` handoff is the
  remaining probe).
- **No "carried-package visible"** until Spike 2's chosen design ships.
- **No "package returned"** from snapshot position alone unless explicitly labeled a _frontend heuristic_.
- **No stealth AI claim** — Stage A's sneak route is layout-driven avoidance; `seen=false` hides player LOS.
- **No player ranged combat.**
- **No scripted patrol gameplay** — NOT FOUND in monmove/monster/monsters JSON; no JSON patrol behavior and
  no EOC system in this fork (§6).
- **No level-4 equivalence claim** for vertical move from "engine action reached" alone — it is level 2/3,
  like planar `move`.
- **No multi-z snapshot claim** — per-floor observation is LIKELY (witness it in Spike 1); simultaneous
  multi-floor is not built.
- **No "5–6 floors work" from a 2-floor witness.**
- **No "bump-melee is _unconditionally_ technique-prompt-free."** It is suppressed only while
  `manual_combat_mode` is off — which is the default, but the flag is **persisted in the save** (§6), so the
  fixture must **save it false** (not rely on load forcing it) and still fail loud on any prompt; do not assume
  a player who toggled manual combat mode would see the same behavior.
- **No "drivable now" without "but unwitnessed"** for ramps, door-auto-open, bump-melee, and route
  compositions — all are _reachable through_ the witnessed `move` command but have no fixture of their own.

## 12. Stage A recipe after Spike 1

1. **Two-floor traversal:** `move_down` on aligned stairs → assert new floor → planar-move to a visible
   ground package → `pickup` → planar-move back → `move_up` → assert original floor.
2. **5–6 floor expansion:** repeat aligned stairs across 5–6 floors via a **purpose-built deterministic save
   fixture** (preferred over `hotel_1`, which is procedural — §4). Keep one package on the objective floor.
3. **Security pressure (observation first):** save-edit a hostile drone (via a hostile-bot generator — **not**
   the passive `make_monster_fixture.py`, §6) on the direct route; witness it in `entities.monsters[]`; route
   around it (uses witnessed `move`).
4. **Optional fight witness:** a separate fixture where `move` into the hostile drone resolves as melee;
   pin `manual_combat_mode == false`; assert an `hp` decrement **and no unexpected prompt** (the bump path is
   prompt-suppressed in default play, §6). Use `mon_turret_searchlight` for a non-lethal positional bump and
   **stop before the kill** (its `FOCUSEDBEAM` death explodes), or a `BROKEN`-death target if killing (§6).
5. **Alternate route witness:** already-open / unlocked layout; optionally prove auto-open through an
   unlocked `t_door_c` in a focused fixture (`avatar_action.cpp:691-709`). No lockpick/smash/computer/elevator.
6. **Return condition:** without Spike 2, stop at "package picked up on objective floor" (the engine proof);
   with Spike 2, the chosen carried/return signal makes "package returned" provable.

## 13. Open questions

**Resolved from the repo in this audit (no build needed):**

- **Ramp traversal semantics** — the ramp branch is prompt-free and lands at the same x/y, `z±1`, via
  `walk_move(via_ramp)` (§4, §6 table). Only the `walk_move` end-state remains for a 1-command probe.
- **`find_or_make_stairs` determinism** — exact safe condition known: a `GOES_UP`/`GOES_DOWN` stair directly
  above/below + no creature on it avoids both fabrication and the push-past prompt (§4). Spike 1 generator
  must assert it.
- **Bump-melee technique prompt** — suppressed in default play; the bump path arms the guard via its delegate
  while `manual_combat_mode` is off (default + load value) (§6). Corrects an earlier draft.
- **Best first security entity** — `mon_turret_searchlight` for a positional bump (immobile, non-lethal _attacks_; `FOCUSEDBEAM` death explodes — stop before the kill or use a `BROKEN`-death target, §6); avoid secubot/laserturret/
  riotbot/copbot for the first witness (§6).
- **Patrol / alarm scope** — searched: no JSON monster patrol, no EOC system, no building security-AI alarm in
  this fork (§6). UNKNOWN/STAGE B with a scoped negative.

**Still open — product / scope decisions for the maintainer (not repo facts):**

1. **Spike 1 equivalence level.** Is level 2/3 (engine action reached) acceptable for Stage A vertical move,
   or does the project want a level-4 mechanism that routes through a real registered-input loop?
2. **Stage A success at "picked up"?** May Stage A define success as "package picked up on the objective
   floor" before Spike 2 ships (making Spike 2 a Stage-A→B bridge, not a blocker)?
3. **Spike 2 design choice.** Avatar inventory export | minimal objective-state export | frontend heuristic
   — which ships? (Product decision; document the honest limit of whichever wins.)
4. **`hotel_1` vs purpose-built fixture.** Is anchoring the avatar in a procedurally-placed `hotel_1`
   acceptable, or must Stage A use a deterministic purpose-built save? (§4 leans purpose-built.)

## Claim → citation → verdict table

| Claim                                                                                                                                                                | Repo citation                                                                                                                                                                | Label / verdict                                                          | Uncertainty                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BN supports ±10 z-levels (21 layers)                                                                                                                                 | `src/game_constants.h:64-68`                                                                                                                                                 | NATIVE-BN                                                                | None.                                                                                                                                                      |
| Z-levels run by default                                                                                                                                              | `src/mapbuffer.h:83`; `src/options.cpp:2493`                                                                                                                                 | NATIVE-BN                                                                | An option flip could disable; pin in fixture.                                                                                                              |
| **`hotel_1` is a 6 z-level tower: basement(3 tiles)+lobby(10)+3 upper floors(6 each)+roof(6)**                                                                       | `data/json/overmap/multitile_city_buildings.json:2648-2690` (tiles-per-z verified by parse)                                                                                  | NATIVE-BN                                                                | Procedurally placed — hard to use in a deterministic save fixture (§4).                                                                                    |
| **`office_tower` is NOT a tall tower (only z=-1..0)**                                                                                                                | `data/json/overmap/multitile_city_buildings.json` (tiles-per-z `{-1:4,0:4}` verified by parse)                                                                               | excluded                                                                 | Not multi-z evidence.                                                                                                                                      |
| `lab_subway_vent_shaft` stacks 5 z-levels                                                                                                                            | `specials.json:3212-3216`                                                                                                                                                    | NATIVE-BN                                                                | A vent shaft, not an occupiable building.                                                                                                                  |
| String tokens `move_up`/`move_down` resolve to `ACTION_MOVE_UP/DOWN`                                                                                                 | `src/action.cpp:657-660`                                                                                                                                                     | NATIVE-BN                                                                | None.                                                                                                                                                      |
| `ACTION_MOVE_UP/DOWN` dispatch `vertical_move`                                                                                                                       | `src/handle_action.cpp:2184-2307`                                                                                                                                            | NATIVE-BN                                                                | None.                                                                                                                                                      |
| `game::vertical_move` is prompt-heavy                                                                                                                                | `src/game.cpp:14076,14128`                                                                                                                                                   | NATIVE-BN                                                                | Clean aligned-stair case resolved (§4): fixture asserts a matched stair pair + no creature on the destination; residual prompts witnessed in Spike 1 (§9). |
| **`find_or_make_stairs` fabricates only when `find_stairs` returns `nullopt`; aligned-above/below + no creature on the tile avoids it and the push-past `query_yn`** | `src/game.cpp:14835,14840-14846,14885-14887,14896,14904-14914,14918+`                                                                                                        | NATIVE-BN (safe condition known)                                         | Spike 1 generator must assert it (resolved).                                                                                                               |
| Ramps bump `dest_loc.z()` prompt-free and hand off to `walk_move(via_ramp)`                                                                                          | `src/avatar_action.cpp:390-397,682,730`                                                                                                                                      | NATIVE-BN (ramp branch prompt-free; `walk_move` end-state probe pending) | Reduces to a planar `move` onto a z-changed tile (resolved).                                                                                               |
| Elevators are a uilist-based examine path → fail loud                                                                                                                | `src/iexamine_elevator.cpp:1-47`                                                                                                                                             | NEEDS NEW SEAM                                                           | Not Stage A.                                                                                                                                               |
| Arcopolis cannot drive vertical move; snapshot single-z                                                                                                              | `src/arcopolis_command.cpp:60-77`; `src/arcopolis_export.cpp:180-185`                                                                                                        | NEEDS NEW SEAM                                                           | Per-floor observation LIKELY (witness in Spike 1); multi-z not built.                                                                                      |
| `briefcase`/`box_small` are carriable package items                                                                                                                  | `data/json/items/armor/storage.json:222`; `containers.json:362`                                                                                                              | NATIVE-BN                                                                | None.                                                                                                                                                      |
| `MISSION_ITEM` is a real engine flag                                                                                                                                 | `src/flag.cpp:202`; `src/flag.h:203`                                                                                                                                         | NATIVE-BN                                                                | Full mission binding is Stage B.                                                                                                                           |
| Mapgen places item/item-group/loot/monster/nested                                                                                                                    | `src/mapgen.cpp:3850-3869`; `data/json/mapgen/Bastion_Fort.json:215`                                                                                                         | NATIVE-BN                                                                | RNG; save-edit preferred.                                                                                                                                  |
| Terrain edits → `map.sqlite3`; monster edits → `.sav` JSON                                                                                                           | `make_wall_fixture.py` header; `make_monster_fixture.py`; fixture dirs have both files                                                                                       | (baseline)                                                               | Each generator handles the store its edit needs.                                                                                                           |
| Ground items exported; pickup level-4 witnessed                                                                                                                      | `src/arcopolis_export.cpp` `entities.items[]`; `ARCOPOLIS_STATE.md:205-231`                                                                                                  | PROVEN                                                                   | Container contents not exported; whole-stack pickup only.                                                                                                  |
| Carried (inventory) package is NOT exported                                                                                                                          | `ARCOPOLIS_STATE.md:654-659`                                                                                                                                                 | NEEDS NEW SEAM                                                           | Spike 2.                                                                                                                                                   |
| Security drones exist; `mon_secubot`/`mon_copbot`/`mon_riotbot` hostile (faction/aggression/morale)                                                                  | `defense_bot.json:7,17-18` (copbot, `cop_bot`), `:51,61-62` (riotbot, `cop_bot`), `:93,103-104` (secubot, `defense_bot`) — all read this session                             | NATIVE-BN                                                                | copbot/riotbot are faction `cop_bot`, not `defense_bot`.                                                                                                   |
| `mon_secubot` has a native gun special attack (m16a4, range 0–30)                                                                                                    | `data/json/monsters/defense_bot.json:112-135` (read this session)                                                                                                            | NATIVE-BN                                                                | None — block read in full.                                                                                                                                 |
| Bump into a hostile monster melee-attacks with no prompt at the bump site                                                                                            | `src/avatar_action.cpp:533-569`                                                                                                                                              | NATIVE-BN (reachable via `move`, unwitnessed)                            | Neutral → `query_yn`; technique prompt suppressed in default play (below).                                                                                 |
| **Bump-melee IS technique-prompt-suppressed in default play** (delegate arms the guard while `manual_combat_mode` is off)                                            | guard via delegate `src/avatar_action.cpp:181-184,971-981`; default `src/game.h:1196`; serialized+restored `savegame.cpp:98,366-367`; single check site `src/melee.cpp:1593` | NATIVE-BN (corrects earlier draft)                                       | Fixture pins `manual_combat_mode=false` + fail-loud (resolved).                                                                                            |
| `mon_turret_searchlight` is the cleanest _positional_ witness (immobile, hp 30); non-lethal attacks, `FOCUSEDBEAM` death explodes                                    | `turrets.json:3,12,26,28,29`; `mondeath.cpp:682`                                                                                                                             | NATIVE-BN                                                                | Stop before kill or use a `BROKEN`-death target; avoid ranged/high-hp bots first (resolved).                                                               |
| Monster presence + health exported                                                                                                                                   | `ARCOPOLIS_STATE.md:152-153`; `monster_export_regression.ps1`                                                                                                                | PROVEN                                                                   | Single-z window.                                                                                                                                           |
| No JSON monster patrol; no EOC system; no building security-AI alarm in this fork                                                                                    | NOT FOUND after searches (`monmove`/`monster`/`monsters` JSON; `effect_on_condition`/`EOC` zero hits in `data/json`; `alarm` = car/trap/flavor)                              | NOT FOUND / UNKNOWN / STAGE B                                            | Patrol is C++ AI; any alarm would be new (resolved).                                                                                                       |
| Planar move into a closed **unlocked** door auto-opens (no prompt)                                                                                                   | `src/avatar_action.cpp:691-709`; `terrain-doors.json:196,205`                                                                                                                | NATIVE-BN (reachable via `move`, unwitnessed)                            | No Arcopolis fixture yet.                                                                                                                                  |
| Lockpick is an examine→activity/prompt path                                                                                                                          | `src/iexamine.cpp:1774-1875,8226-8227`                                                                                                                                       | NEEDS NEW SEAM                                                           | None.                                                                                                                                                      |
| Detection seam is `Creature::sees`; headless `seen=false` hides player LOS                                                                                           | `src/creature.cpp:369,450`; `43_...` (Spike 21 §6, cite by section)                                                                                                          | NEEDS NEW SEAM / LIKELY                                                  | Stealth outcomes not snapshot-observable.                                                                                                                  |
| Player ranged combat actions exist; not exposed by Arcopolis                                                                                                         | `src/handle_action.cpp:2552-2570`; `src/arcopolis_command.cpp:195-245`                                                                                                       | STAGE B / NEEDS NEW SEAM                                                 | None.                                                                                                                                                      |
| Coverage (doc 45) measured but not equivalence                                                                                                                       | `45_WINDOWS_COVERAGE_FEASIBILITY.md` §8; AGENTS.md "backend input equivalence" section                                                                                       | (baseline)                                                               | Not used as equivalence proof.                                                                                                                             |
| No big-bang C++23 modernization                                                                                                                                      | `46_CPP23_ENGINE_REFACTOR_STRATEGY.md` §9                                                                                                                                    | (baseline)                                                               | None.                                                                                                                                                      |

> **External citations:** none required to prove a BN capability — every capability claim is sourced from
> this repo.

## Provenance: questions resolved while finalizing this audit

Each row is a question that an earlier draft left open or stated imprecisely, settled this session by reading
the cited source first-party. The first row is a **correction** of an earlier draft claim.

A later automated-review pass (Gemini, Codex) flagged additional issues; the validated ones are folded into
the sections above — most importantly the `manual_combat_mode` mechanism (it is **save-persisted**, not forced
false on load — §6), the matched-stair-pair requirement (`vertical_move` gates on the current tile's flag —
§4/§9), the searchlight's `FOCUSEDBEAM` on-death explosion (§6), the _passive_ nature of
`make_monster_fixture.py` (unsuitable for a hostile-bot fixture — §6), and the `briefcase` pickup-volume
caveat (§5). One claim (a `walk_move` line number) was checked against `src/avatar_action.cpp:730` and
**rejected as incorrect**.

| Question                          | Earlier-draft state                                                                             | Final resolution                                                                                                                                                                                                                                                         | Verified first-party                                                                                                      |
| --------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| Bump-melee technique prompt       | "guard NOT armed on bump path → prompt likely fires; witness may need `autoattack`" — **wrong** | Bump delegates to `melee_attack_while_handling_manual_combat_mode`, which **arms** the guard while `manual_combat_mode` is off (the default). The flag is **save-persisted** (`savegame.cpp:98,366-367`), so the fixture must save it false. Suppressed in default play. | `avatar_action.cpp:181-184,971-981`; `game.h:1196`; `game.cpp:940,3984`; `savegame.cpp:98,366-367`; `melee.cpp:1591-1607` |
| `find_or_make_stairs` determinism | hazard flagged; safe condition not pinned                                                       | Fabricates only when `find_stairs` returns `nullopt`; aligned-above/below stair + no creature on the tile avoids fabrication _and_ the push-past prompt                                                                                                                  | `game.cpp:14835,14840-14846,14885-14887,14896,14904-14914`                                                                |
| Ramp traversal                    | "z-bump only; full traversal UNVERIFIED"                                                        | Ramp branch is prompt-free, lands at same x/y `z±1`, hands off to `walk_move(via_ramp)`; residual is the normal-`move` `walk_move` end-state                                                                                                                             | `avatar_action.cpp:390-397,682,730,216`                                                                                   |
| Best first security entity        | open (manhack vs secubot vs turret)                                                             | `mon_turret_searchlight` for a positional bump (immobile, hp 30, non-lethal _attacks_) — its `FOCUSEDBEAM` death explodes (`mondeath.cpp:682`), so stop before the kill or use a `BROKEN`-death target; avoid ranged/retaliating bots first                              | `turrets.json:3,12,26,28,29,54-75`; `mondeath.cpp:682`; `drones.json:101,119-120`; `defense_bot.json:33,75,89-135`        |
| Patrol / alarm / EOC scope        | "EOC/behavior-tree/factions not searched"                                                       | Searched: no JSON monster patrol; **no EOC system exists in this fork's JSON**; `alarm` = car/trap/flavor only — no building security-AI                                                                                                                                 | `data/json` greps (`patrol`, `effect_on_condition`/`EOC`, `alarm`); `traps.json:244-257`                                  |
| secubot gun block citation        | `:112-120 (unread range)`                                                                       | Read in full: `type:"gun"`, `m16a4`, `556`, ranges `[[0,20,BURST],[21,30,DEFAULT]]`                                                                                                                                                                                      | `defense_bot.json:112-135`                                                                                                |
| Other bots' faction citation      | "same structure, unread range"                                                                  | Read: copbot/riotbot are faction `cop_bot` (not `defense_bot`); all three aggression/morale 100                                                                                                                                                                          | `defense_bot.json:7,17-18,51,61-62,93,103-104`                                                                            |
