# Arcopolis Vertical Slice Roadmap — backend and frontend next steps

## Status and scope

- **Roadmap only.** No source, test, script, fixture, build, CI, or runtime behavior changed. Like
  [48_ARCOPOLIS_DESIGN_GRILL_SUMMARY.md](48_ARCOPOLIS_DESIGN_GRILL_SUMMARY.md) §21, this is a strategic
  sequence, **not a coding prompt** — every step below still goes through the normal governance path
  (`arcopolis-design-interrogate` / `arcopolis-claim-plan` / `arcopolis-red-team-review`) before it is
  built, and each plan must state its own equivalence level (`AGENTS.md:111-120`) and native-authority
  class (`AGENTS.md:130-156`).
- **Baseline:** `arcopolis` @ `95556bd` (Spike 27B + one-shot serialization fix + attacker-instance-id
  audit merged; docs through 59).
- **Inputs:** the Stage A engine audit ([47](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md)), the design
  grill ([48](48_ARCOPOLIS_DESIGN_GRILL_SUMMARY.md)), the current-truth page
  ([ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md)), and the Stage A contract-placement decision
  ([55](55_SPIKE26B_26C_NOT_REQUIRED.md)).
- **Honesty stance.** Statuses below use doc 47's labels; "reachable through a witnessed verb" is never
  written as "witnessed". Spike numbers ≥ 28 are **proposed**, not committed.
- **Revision (2026-07-01).** Amended after an adversarial review pass with leaf verification (a 6-lens
  doc red-team, an FE-1/FE-3 scope review, and an attack-surface source sweep): Spike 30/31's turret
  facts corrected (the searchlight cannot attack; armor bounds the bump witness), Spike 32's witness
  gained an engagement-capability requirement, and FE-1/FE-3 carry transport/fixture caveats. All
  findings are folded inline below; the review verdicts live in the session record, the load-bearing
  leaves are cited in place.

## 1. Where the slice stands today

Stage A ([47 §1](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md)): a nobody protagonist enters a 5–6 floor
vertical complex, finds a package, and returns it to the contact area — fight route and sneak route
available, everything observable enough for a frontend to explain.

Against the design-grill proof sequence (48 §21):

| # | Step (48 §21)                        | Status                                                                                                                                                                                                                                                              |
| - | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | Minimal vertical fixture/generator   | **DONE** — Spike 23, `ArcopolisStairsTest` (2 floors, matched stairs)                                                                                                                                                                                               |
| 2 | Vertical movement witness            | **DONE** — Spike 24, `vertical_move` down→up round trip, level 2/3, per-floor snapshot witnessed (doc 49)                                                                                                                                                           |
| 3 | Package placement / pickup / export  | **DONE in pieces** — ground-item export (8A), level-4 `pickup` (12A/16), carried display (25), on-person possession query (26A) — but never on a vertical fixture                                                                                                   |
| 4 | Return/contact-area placeholder      | **DONE** — consumer-side conjunction over position + the 26A query; seal cleared; no backend `return_condition` API (docs 53/55)                                                                                                                                    |
| 5 | Security drone / fight route witness | **OPEN** — 27A/27B witnessed hostile-monster liveness + attacker-attributed damage with `mon_zombie`, so the observation machinery exists; **no drone fixture, no melee witness** (bump-melee is NATIVE-BN, prompt-suppressed in default play, unwitnessed — 47 §6) |
| 6 | Sneak / alternate route witness      | **OPEN** — planar `move` is witnessed; **route composition and door auto-open are not** (47 §7)                                                                                                                                                                     |
| 7 | Stage B audit / first social spike   | **OPEN** — deferred by design (48 §18)                                                                                                                                                                                                                              |

Frontend (the Spike 10A/10B/10C/11B browser prototype + bridge):

- **HAS:** session lifecycle, 8-way move, 8-way-plus-`here` examine, snapshot diff, tileset v0 with glyph
  fallback, monsters/NPCs/items rendered and inspectable, recoverable-error handling.
- **LACKS (all deliberately, all now unblocked by proven backend surfaces):** the `vertical_move` verb
  (the bridge comment explicitly excludes it — `tools/arcopolis_frontend/prototype_server.py`), the
  prompt/`prompt_answer` wire (pickup/uilist/query_popup are driven only by the Python live drivers), and
  display for the newer exports (`avatar.carried_items[]`, `avatar.damage_taken[]`, the `has_item` query).

The headline: **every load-bearing seam the slice needs on the happy path is proven; what remains is
composition, two route witnesses, floor count, and catching the frontend up to the backend.**

## 2. The two tracks, one sentence each

- **Backend:** compose the already-proven verbs into the actual slice loop on a vertical fixture, then
  add the two missing route witnesses (fight, sneak) and the floor count — no new prompt class required
  for any of it.
- **Frontend:** expose what the backend already proves — `vertical_move`, the prompt transaction wire,
  and the new observability surfaces — so the same slice loop runs mouse-first in the browser (the
  project-goal sense of frontend equivalence, ARCOPOLIS_STATE.md §Terminology).

## 3. Backend track — proposed spike ladder

### Spike 28 — Stage A two-floor composite slice witness (the keystone)

**What:** one live session on a new fixture (`ArcopolisStairsTest` clone + one low-volume package item —
`box_small` per 47 §5 — save-edited onto a floor-(−1) tile; contact tile = the start tile) that runs the
whole loop: export → `vertical_move down` → planar `move` to the package → `pickup` (level-4 prompt
transaction) → planar return → `vertical_move up` → `op:"query" has_item` + position, conjunction green.
Plus the false-green guards doc 53 established: possession false before pickup, off-contact false after a
proven displacement — and two composite-specific gates the review added: **floor provenance** (the package
is asserted on the floor-(−1) ground BEFORE the pickup, then ground −1 == carried +1 across it, so the
pickup provably came from the descended floor) and a **z-changed off-contact guard** (the conjunction
reads false while the avatar is on the other floor, not merely one tile off-contact on the same floor).

**Why first:** it is the actual "vertical slice" milestone — 48 §21 steps 1–4 exist only as separate
witnesses on separate fixtures; nothing has ever proven they compose in one session. Composition bugs
(prompt state across a z-change, window rebase across floors, clean-park interaction) are exactly what
separate witnesses cannot catch.

**Shape:** NO new engine touch expected; a fixture generator (crib `make_stairs_fixture.py` +
`make_carried_nested_fixture.py` item injection), a live driver modeled on
`stage_a_return_condition_driver.py` extended with `vertical_move` + the pickup prompt flow, and a
`slice_regression.ps1`. Claims: per-verb levels as already recorded (vertical 2/3, pickup 4, query class
C, position class S); the slice itself is an Arcopolis-layer L1 composite per docs 53/55 — **no new
equivalence claim**.

### Spike 29 — N-floor fixture generator + 5–6 floor traversal

**What:** parameterize the stairs generator (`--floors N`), asserting doc 47 §4's three determinism
conditions **per floor pair** (travel-direction flag on the current tile, aligned counterpart, no
creature on the destination stair); witness a 5–6 floor descent→ascent round trip with a per-floor
snapshot each leg.

**Why:** "5–6 floors work" must not be claimed from the 2-floor witness (47 §11); this is the cheapest
honest closure — pure fixture + regression work, zero `src/`. Keep `hotel_1` as the eventual
product-faithful target, not the witness (47 §4 caveat). Once 28 and 29 both exist, re-run the composite
on the tall fixture (package on the deepest floor) — that IS Stage A's traversal core.

### Spike 30 — hostile security-drone fixture + observation witness

**What:** a hostile-bot fixture via the (already parameterized, 27A) `make_monster_fixture.py` hostility
flags, plus the drone-specific gaps 47 §6 names: `mon_turret_searchlight` for the positional witness —
immobile and, leaf-verified, **unable to attack at all** (no `melee_dice`; its `SEARCHLIGHT` special is
illumination-only — `turrets.json:19/26`) — and optionally `mon_secubot` for a ranged-attack observation
the existing 27B tap **already captures with source** (`ballistics.cpp:622` → `deal_projectile_attack` →
`creature.cpp:1271` `apply_damage`), i.e. an attributed `avatar.damage_taken[]` witness, not merely an
engine-message one. Ammo semantics (leaf-verified): the monster ctor seeds `ammo = type->starting_ammo`
(`monster.cpp:342`) and deserialization reads the `"ammo"` key only when present
(`savegame_json.cpp:2151-2155`), so the fixture blob must **omit** the key rather than write an empty
map; the generator also writes `special_attacks = {}` — verify attack-cooldown reconstruction on load
before relying on the gun attack. L1 observation only, 27A/27B pattern (RNG-invariant gates where
possible, seed-sampled where not).

**Why:** step 5's cheap half. The liveness/damage machinery from 27A/27B transfers; only the fixture and
the drone-specific hazards (ammo, `FOCUSEDBEAM` death) are new.

### Spike 31 — fight-route witness (bump-melee)

**What:** `move` into an adjacent hostile monster; assert a monster `hp` decrement across snapshots
(class S, `entities.monsters[]`), **stop before the kill** (the searchlight's `FOCUSEDBEAM` death
explodes — `mondeath.cpp:646-684`), fixture **saves `manual_combat_mode: false`** (it is save-persisted —
47 §6/Provenance), and any technique/unexpected prompt fails loud. **Target selection is a real
constraint (leaf-verified):** the searchlight carries `armor_bash 14 / armor_cut 16`
(`turrets.json:20-21`), which plausibly zeroes a stock unarmed avatar's hits — the plan must either arm
the avatar past that armor (compute the damage budget) or pick a softer adjacent target (a hostile
`mon_zombie` at offset `0,1,0` is unarmored but mobile; the turret trades damageability for
deterministic adjacency and no counter-attack confound). The searchlight **cannot melee back** (no
`melee_dice`), so no avatar-side `damage_taken[]` counter-fact exists on a turret fixture.

**Why after 30:** the fight route becomes witnessed with **no new engine seam** — the bump path is
NATIVE-BN and prompt-suppressed in default play; the claim stays "reachable via the witnessed `move`,
now witnessed for this fixture", engine-equivalent for the attack, never level 4.

### Spike 32 — sneak/alternate-route witness

**What:** a fixture with a static, **engagement-capable** threat on the direct route (NOT the
searchlight — it cannot attack, which would make the damage-empty gate structurally unable to fail) and
an open alternate route; witness the route composition (planar moves only) arriving with
`damage_taken[]` empty and the threat's position held/never adjacent, **plus a contrast/capability arm**:
a direct-route (or adjacency) leg on the same fixture where the threat DOES land attributed damage — the
27B pattern proves that witnessable — so "empty" discriminates route-avoidance from threat-impotence.
Without the contrast arm, the claim must be downgraded to "a damage-free alternate route exists."
(Once §5's field export lands, a FIRE field is an alternative direct-route hazard — but field damage is
source-less, so `damage_taken[]` stays empty even when burned: a field-hazard variant must contrast on
avatar hp instead, or keep the monster threat.)
Also the near-free door sub-witness: `move` into an unlocked `t_door_c` auto-opens
(`t_door_c → t_door_o`, `moves -= 100` turn-economy assertion — body leaf-verified prompt-free,
`avatar_action.cpp:693-705`), which the backlog already flags as the cheapest interaction follow-up.

**Bound (47 §7):** layout-driven avoidance, **never a stealth claim** — headless `seen=false` hides
player LOS, so "sneaked past undetected" is not snapshot-observable and must not be asserted.

### Stage A exit

After 28–32: a claim-audit pass in the 37/38 style over the slice claims, and an updated
`ARCOPOLIS_STATE.md` §Stage A. The remaining maintainer decisions (§6 below) close Stage A or bounce a
step. Only then open the Stage B design interrogation (48 §21 step 7).

## 4. Frontend track — catching the browser up to the proven backend

Ordered so each step consumes only surfaces the backend has already proven; each extends
`frontend_prototype_regression.ps1` the way 10B/10C/11B did.

### FE-1 — `vertical_move` in bridge + UI

Up/Down controls + a floor (`z`) indicator; the bridge classifies the outcome like planar moves. Scope
caveats from the review (leaf-verified): **(a)** `vertical_move` is witnessed only in run-script — doc 49
§Live mode explicitly added no live probe — and the browser is live-only, so **FE-1's regression gate is
also the first live-transport `vertical_move` witness**; a failure there is a backend finding, not a
frontend bug. **(b)** the FE regression's fixture (`ArcopolisTest`) has no stairs — the two-floor
traversal needs an `ArcopolisStairsTest` scenario, and the no-stairs `vertical_move` outcome contract
must be pinned first (it is unwitnessed; the existing negative probes send planar `move_up`, a different
rejection). **(c)** the diff view already nulls its baseline on a z-change (`app.js:305-310` gates on
`prevState.z === next.z`), so the cross-floor diff work is an annotation nicety, not a correctness fix.
Appetite: 11B-class, not trivial. Unlocks the browser two-floor traversal.

### FE-2 — prompt-transaction UI (the big one)

Surface live `prompt` events (`kind: menu / uilist / query_popup`) as a real modal rendering the
engine's **verbatim** entries, send the user's `prompt_answer`, handle recoverable `prompt_failed`
(prompt stays open) and cancel semantics (including `cancelable:false`). The wire, the transcript events,
and the level-4 backend proof all exist (12A/13B/14/15/16); today only the Python drivers speak it. This
is the step that makes the browser **frontend-equivalent for the pickup surface** — the project-goal
sense — rather than move/examine only.

### FE-3 — slice status surfaces

- `avatar.carried_items[]` panel (label it what it is: top-level display state, **not** the possession
  predicate — the Spike 25 postmortem distinction, doc 51).
- `avatar.damage_taken[]` combat feed (label the honest bound: the raw funnel attacker, **not** the
  perception-masked GUI display — doc 57's deferred `sees()` frontier).
- A `has_item` query control + contact-tile indicator computing the doc 53 conjunction **client-side** —
  the frontend is precisely the consumer the docs 53/55 contract placement intends; no backend change.
  Scope honesty (review): the contact tile is a fixture **convention** (the start tile), so the UI needs
  a declared source for it; and on the standard FE fixture the indicator can only ever read false — gate
  the red path there, take the optional green path on `ArcopolisCarriedNestedTest` (pre-carried item),
  and leave pickup-then-green to FE-4 (it needs FE-2's modal).

### FE-4 — browser slice demo

Run Spike 28's composite through the browser end-to-end (descend → walk → pick up via the modal → return
→ ascend → return-signal green). This is the demonstrable vertical slice — the artifact that shows the
product differentiator (verticality, 48 §15) in the mouse-first frontend. Gate it in the frontend
regression like the existing session_002 scenario.

**Deliberately later:** SSE/push updates, sockets, tileset depth (multitile/rotation/`looks_like`),
multi-z minimap, hazard display (field / known-trap panels — once the §5 exports land) — none block the
slice; the polling bridge and glyph fallback are adequate for it (ARCOPOLIS_STATE.md deferred backlog).

## 5. Parallel / opportunistic backend hardening (not on the critical path)

Small, additive, in rough value order — good fill-in work between ladder spikes:

1. **Attacker per-instance correlation (bounded substitute).** Doc 59 proved the gap and named the
   fidelity-clean option: a same-snapshot `weak_ptr`→raw-`pos_abs` resolve (class S) at the drain site.
   Flips the `no_instance_join_key` shadow-gate by design; enables a frontend "which drone hit me"
   affordance. No stable-id engine seam (that stays an upstream question).
2. **`messages[].type`** — the export field is present but blank (needs a public `Messages::` accessor —
   a small engine touch); makes the frontend's message feed classifiable and strengthens the
   message-stream second witness chain.
3. **Rejected-request transcript event** — the additive `"rejected"` event kind the live-protocol backlog
   already names; makes live sessions fully replayable from the transcript alone.
4. **Per-tile field export (fields v0 — candidate, from the terrain exploration).** The deferred-backlog fields item, now
   source-mapped: field state is raw class-S per-tile data (`field_entry` {type, intensity, age};
   `submap::fld`) whose lifecycle runs in the **turn loop** (`process_fields_in_submap`) — headless-alive,
   no extraction needed. Additive export in the snapshot window (the `entities.items[]` pattern);
   unlocks slice hazard pressure + a frontend hazard display. Field DAMAGE stays unattributed
   (`source == nullptr` — invisible to `damage_taken[]` by design); attribution is a separate, narrow
   decision, not part of this export.
5. **Known-traps export (traps v0 — candidate, from the terrain exploration).** Leaf-verified: "player knows trap" is
   **turn-loop stored state** (`search_surroundings`, `game.cpp:13074` → `known_traps`) —
   headless-faithful, the opposite of the draw-populated fog-of-war. Export the KNOWN set only
   (windowed): raw-all-traps would leak traps the GUI player cannot see — an information-fidelity
   break. Disarm (a `query_yn` B path, `iexamine.cpp:4676-4679`) stays deferred.
6. **Explicit `open`/`close` verbs** — the backlog's "near-free follow-ups" (same chooser shape as
   examine, prompt-free bodies for plain doors — a vehicle door can raise the owner-theft `query_yn`
   (`vehicle.cpp:5444`), which fails loud; turn-economy witness); natural sibling of Spike 32's door
   sub-witness.
7. **Avatar→hostile-NPC bump-melee (recorded fact, blocked witness).** Leaf-verified prompt-free:
   `avatar_action.cpp:592-598` fires `npc_menu` only for `!is_enemy()`; a hostile NPC is bump-attacked
   like a hostile monster — Spike 21's fail-loud is the **non-hostile** case only. A fight-route sibling
   once two blockers land: a hostile-NPC fixture generator (attitude `NPCATT_KILL` is a save-editable
   int, `savegame_json.cpp:1720/1866`; no generator exists today) and an `entities.npcs[].hp` export
   (absent — avatar→NPC damage has no observation surface).
8. **Routine upstream sync** per the STATE workflow — note the collision-surface set grew again
   (`character.cpp` since 27B); keep syncs small and `ccache -C` before the post-sync compile check
   (doc 41 §4).

## 6. Decision points for the maintainer (carried forward, still open)

1. **Vertical at level 2/3** (47 §13 Q1) — Spike 24 shipped and was adversarially audited at 2/3; does
   Stage A accept that permanently, or does the slice exit require a level-4 vertical mechanism?
2. **Multi-z export contract** (48 §25) — how much cross-floor information does the mouse-first frontend
   need (stacked minimap? last-seen-per-floor cache client-side?)? Today's contract is single-z per
   snapshot; FE-1 can ship with a floor indicator only, but the decision shapes FE-beyond.
3. **Stage A completion bar** — is 28 (2-floor composite) + 29 (5–6 floor traversal) + 31 (fight) + 32
   (sneak) the agreed exit, or is a drone on the route of the **composite** run (not a separate fixture)
   required before calling Stage A done?
4. **`hotel_1`** stays the product-faithful eventual target, purpose-built fixtures the witnesses (47
   §4) — reconfirm, since Stage B's "living city" framing will eventually force the procedural question.

## 7. Sequencing rationale

- **Composition before expansion.** 28 before 29: a 2-floor composite failure is a seam bug worth finding
  before floor count multiplies the surface (the doc 48 §20 lesson — isolate the environment variable
  from the capability variable).
- **Observation before interaction** for the fight route (30 before 31), exactly as 27A preceded 27B.
- **Frontend consumes only proven surfaces.** FE-2/FE-3 start any time (their backend halves are done,
  with FE-3's green-path caveat above); FE-1 starts any time too, **with the declared caveat** that its
  gate doubles as the first live-transport `vertical_move` witness (backend-attributed failure
  semantics). FE-4 waits on 28. Backend and frontend tracks are otherwise independent and can interleave.
- **No new prompt class anywhere in Stage A.** Every remaining step reuses witnessed verbs or is
  observation-only — the first genuinely new prompt family (NPC dialogue) is Stage B's opener, using the
  established per-family per-transaction witness pattern (13B/14/15 shape), and should start with a
  design interrogation, not code.

## 8. Beyond Stage A (Stage B frontier, rough order)

Per 48 §18 these stay deferred until Stage A exits; recorded here only so the ladder has a visible next
rung:

1. **Stage B design interrogation** — scope the social slice (guard NPC, bribe/trade/dialogue) against
   the fail-loud rules; the open question "how to witness dialogue without weakening unexpected-prompt
   guarantees" (48 §25) is the crux.
2. **NPC dialogue/menu as a new served category** — its OWN per-transaction gate + serve branch + RAII
   guard per the AGENTS.md invariant; the npc_menu `uilist` that Spike 21 made fail-loud is the natural
   first witness site.
3. **Mission-scope possession query** — the deferred Spike 26B (`crafting_inventory()` scope, class C
   with the broader reach) once the backend is meant to own "package returned" (Stage B per doc 55).
4. **World/avatar state separation audit** — death continuation (48 §12) is an architecture question
   before it is a feature; audit-first like 47.
5. **Player ranged combat** — now source-mapped: fire, reach-attack, and throw all route through the ONE
   bespoke targeting loop (`target_ui::run`, `input_context("TARGET")`, `ranged.cpp:2937-3188`), which is
   NOT test_mode-abortable like `uilist`; driving it means a new served per-transaction family (the
   13B/14/15 pattern) plus a renderer-neutrality audit, and one family would unlock all three verbs —
   **elevator** (`iexamine_elevator` uilist — mechanically the 13B pattern at a new site),
   **lockpick/smash** (smash is NOT prompt-free at entry — a weapon-shatter `query_yn` at
   `handle_action.cpp:821-823` plus an acid-corpse query; the terrain bash itself is prompt-free once
   past them) — each its own witnessed spike when a route needs it.

## 9. Claims this roadmap does not make

- No step above is committed, sized, or approved — proposed sequence only; each goes through claim-plan.
- Nothing here upgrades any existing equivalence claim (vertical stays 2/3; bump-melee, door auto-open,
  and route composition are NATIVE-BN until their witnesses exist).
- No stealth, no perception-display, no mission-completion, no multi-z-snapshot, no "5–6 floors work"
  claim until the named witness ships.
- The frontend steps make the browser consume proven surfaces; they do not by themselves prove new
  backend equivalence (frontend-equivalence claims stay scoped to the surfaces actually driven, as 11B's
  planar claim is today).
