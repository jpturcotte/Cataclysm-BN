# Arcopolis Design Grill Summary

## Status and scope

This document summarizes a strategic design-grill conversation about Arcopolis product identity, first-slice scope, and how those decisions should guide future Bright Nights backend work.

It is a design-history and decision-context document. It is not a coding prompt, not an implementation plan, and not a request to modify source code.

No source code, tests, fixtures, build settings, CI, or Arcopolis runtime behavior are changed by this document.

## Related Arcopolis documents

This conversation sits on top of the existing Arcopolis documentation chain. The most relevant documents are:

- [Arcopolis current state](ARCOPOLIS_STATE.md)
- [Spike 17 claim audit](37_SPIKE17_CLAIM_AUDIT.md)
- [Level-4 truth audit](38_LEVEL4_TRUTH_AUDIT.md)
- [Spike 19 backend UI boundary](40_SPIKE19_BACKEND_UI_BOUNDARY.md)
- [Spike 21 uilist unexpected-prompt fail-loud audit](43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md)
- [Test coverage audit](44_TEST_COVERAGE_AUDIT.md)
- [Windows coverage feasibility](45_WINDOWS_COVERAGE_FEASIBILITY.md)
- [C++23 / engine refactor strategy](46_CPP23_ENGINE_REFACTOR_STRATEGY.md)
- [Vertical slice engine audit — Stage A](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md)
- [Arcopolis fixture catalog](TEST_FIXTURES.md)
- [Committed fixture README](fixtures/README.md)
- [Agent map overview](../agent-map/README.md)
- [Agent map module index](../agent-map/01_MODULES_THIN_INDEX.md)
- [Agent map risk zones](../agent-map/04_RISK_ZONES.md)

The key relationship is:

- `45_WINDOWS_COVERAGE_FEASIBILITY.md` explains how to measure what code ran locally.
- `46_CPP23_ENGINE_REFACTOR_STRATEGY.md` explains why broad modernization is not the right first move.
- `47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md` turns the product direction into an engine capability audit.
- This document explains the design conversation that produced that product direction.

## 1. Why the design grill happened

The C++23 / engine refactor strategy was useful, but it mostly answered a conservative engineering question:

> How can Bright Nights be modernized or refactored safely without damaging Arcopolis backend guarantees?

That was necessary, but incomplete.

The follow-up design grill asked a different question:

> What game is Arcopolis actually trying to become, and which engine changes become justified because Arcopolis is not simply Bright Nights with a new UI?

This distinction mattered because Arcopolis is not only an interface project. It is a product-direction and engine-extraction project. A safe backend is necessary, but not sufficient.

## 2. Starting tension

At the start of the grill, there were two competing risks:

1. **Endless infrastructure risk**\
   Arcopolis could keep exporting more JSON, proving more seams, and auditing more prompts without ever defining the actual game slice.

2. **Premature rewrite risk**\
   Arcopolis could justify broad engine refactors because of an ambitious future game vision, without first proving the smallest useful product slice.

The design grill tried to find the middle path:

> Define a concrete first game slice, then let that slice determine which backend proofs and refactors matter next.

## 3. Initial product fork: what Arcopolis is

The first direct question asked whether Arcopolis is mostly:

- a new frontend for Bright Nights;
- a new game powered by Bright Nights;
- an engine extraction/fork that may eventually stop looking like BN;
- or a prototype to test whether BN can be used this way.

The answer was effectively:

- **B: a new game powered by Bright Nights**
- **C: an engine extraction/fork that may eventually stop looking like BN**

That answer shifted the whole conversation.

Arcopolis should not be understood as:

> Bright Nights with a prettier graphical UI.

It should be understood as:

> A different game using Bright Nights as a possible authoritative simulation backend.

## 4. Player fantasy answer

The player fantasy was stated as:

> Run dangerous jobs through a living city.

That became the first strong product sentence.

The important parts are:

- **jobs**: the player has concrete tasks, not only sandbox survival;
- **dangerous**: tactical pressure, loss, and risk matter;
- **living city**: the world should feel persistent, social, and reactive;
- **through**: navigation, routes, and spatial traversal are central.

## 5. First-ten-minutes answer

For the first ten minutes, the desired experience was described as:

- a guided quest;
- introduction to game mechanics;
- interaction with NPCs and factions;
- a simple route, possibly A -> B -> A;
- a starting loadout;
- not too much else.

This established that the first experience should be directed and legible, not a full sandbox dump.

The reflection at this point was that the first proof should not start with every long-term system. It should start with a narrow job that exercises the correct engine seams.

## 6. Ten-hour answer

For the ten-hour experience, the answer was much broader:

- procedurally generated quests;
- open-world roguelike structure;
- NPC interaction routines;
- improving relationships;
- role-playing;
- improving loadout;
- leveling characters;
- maybe party mechanics.

This revealed a long-term ambition closer to an open-world RPG or living-city sim than a pure extraction roguelike.

The reflection was that several games were hiding inside the concept:

1. an extraction-like job game;
2. a living-city sim;
3. an open-world RPG;
4. a possible party tactics game.

The useful synthesis was to treat **jobs through a living city** as the spine, with other systems supporting that spine over time.

## 7. Extraction framing reconsidered

At one point, the design was compared to:

- extraction roguelikes;
- Quasimorph-like mission danger;
- RimWorld-ish social/life simulation;
- older live-sim RPG structures.

The later clarification was important:

> It is not supposed to be a survival sim. I am not sure extraction is the best paradigm. I see it more as a sort of open world.

This changed the framing.

Extraction remained a useful influence:

- dangerous missions;
- loadout risk;
- loss matters;
- returning alive can matter.

But extraction stopped being the main genre label.

The revised framing became:

> An open-world / life-sim roguelike RPG where tactics happen sometimes.

## 8. Core BN systems answer

When asked which Bright Nights systems are part of Arcopolis's soul, the answer selected:

- inventory;
- items / loot;
- map / terrain;
- skills;
- activities;
- procedural mapgen;
- save persistence.

This was one of the most important narrowing moments.

It said Arcopolis is not trying to reuse all of BN equally. It wants a curated set of systems.

## 9. Bright Nights baggage answer

When asked which BN systems are baggage for the MVP, the answer was:

> Too much everything else.

This became a strong design constraint.

For Arcopolis, MVP baggage includes:

- full survival-sim sprawl;
- too much crafting complexity;
- too much inherited UI complexity;
- exposing all BN mechanics just because they exist;
- broad vehicles, monsters, and wilderness-survival assumptions unless they serve the slice.

The reflection was:

> The goal is not total Bright Nights parity. The goal is a curated urban RPG backend slice.

## 10. NPC/faction answer

The NPC direction was deliberately modest.

The answer was to reuse simple BN NPC routines where possible:

- NPCs can engage in combat;
- give quests;
- trade;
- carry labels or relationships.

Factions were described as:

> Dynamic labels attached to NPCs and probably zones of the map.

That avoided jumping immediately to full faction simulation.

The reflection was that early factions should be:

- labels;
- local context;
- job/context/consequence metadata;
- not yet full strategic map agents.

## 11. Mission approach answer

The desired mission style was:

> Missions should be approachable from different angles.

The first macro approaches were identified as:

- fight;
- sneak;
- trade / bribe.

Other options, such as lockpicking, hacking, alternate traversal, breaking terrain, or acquiring an item, were treated as subcategories of those macro approaches rather than separate pillars.

The reflection was that this is useful because it keeps the design flexible without multiplying systems too early.

## 12. Failure and continuity answer

For failure, the answer was:

- permadeath;
- continue with a new character;
- maybe recover some loot;
- maybe salvage some relationships.

Later, this was narrowed for the first slice:

- the new character can be unrelated;
- the new character starts in the same world after the previous character dies;
- the world event and package outcome should be remembered.

This revealed an important long-term architecture question:

> Arcopolis may need to separate world/campaign state from the current avatar state.

That does not need to be solved first, but it affects the roadmap.

## 13. Life-sim RPG answer

When asked whether the game is primarily turn-based tactics or a life-sim RPG where tactics happen sometimes, the answer leaned toward:

> Life-sim RPG where tactics happen sometimes.

The reflection was that this is compelling but risky, because "life sim" can expand without limit.

The proposed constraint was:

> Start with labels, schedules, simple consequences, and persistent state, not full RimWorld-grade simulation.

## 14. First-slice world answer

For the first playable slice, the initial answer was:

- one procedurally generated block;
- retrieval mission;
- fight, sneak, and trade/bribe approaches;
- consequences after a mission;
- NPC remembers you;
- dropped/corpse loot persists;
- protagonist starts as a nobody;
- guns but simple;
- security drones;
- procedural quests are not mandatory for the first slice.

This gave the first concrete slice shape.

The reflection was that procedural quests should be deferred. The better first proof is:

> Procedurally generated or fixture-generated space with a semi-authored retrieval mission.

## 15. Verticality answer

The first-slice space was later refined from a city block to:

> One vertical complex.

The answer also stated:

> The key to verticality is our main differentiator.

This became the strongest product differentiator identified in the conversation.

The reflection was that "vertical complex" should replace "city block" as the first proof space. A city block can come later; verticality should be proven first because it makes Arcopolis feel different.

## 16. First mission details

The mission details were narrowed further:

| Question          | Answer                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Vertical space    | One vertical complex.                                                                                                     |
| Number of floors  | Around five to six floors eventually.                                                                                     |
| Target            | Package.                                                                                                                  |
| Package placement | Could be placed procedurally.                                                                                             |
| Resolution        | Return to the NPC/contact.                                                                                                |
| Social route      | Dialogue choice if natively supported.                                                                                    |
| Sneak route       | Native methods such as alternate door, window, unguarded route, breaking through, or locating/acquiring/crafting an item. |
| Fight route       | Native security drone/robot behavior if possible.                                                                         |
| Guard             | A guard could be one NPC that can turn hostile.                                                                           |
| Consequences      | Simple success/failure first, with later route-dependent state based on guarded actions.                                  |

This gave the future Stage A / Stage B split.

## 17. Native-first principle

A key principle emerged:

> Use native BN methods first.

This applies to:

- z-levels and vertical movement;
- stairs, ramps, elevators, or other vertical terrain;
- mapgen and overmap structures;
- item/package placement;
- pickup and inventory;
- enemies, drones, and robots;
- windows, doors, bash/break interactions;
- activities and skills;
- save persistence.

The reflection was that "native" does not automatically mean "Arcopolis-supported." A feature can work in BN's normal UI but still require a new Arcopolis seam to be driven or observed faithfully.

This led to the evidence labels used in `47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md`.

## 18. Stage A / Stage B split

The design was split to avoid making the first proof depend on the hardest prompt and NPC systems.

### Stage A

Stage A is the non-social vertical-slice feasibility proof:

- vertical complex;
- package placement;
- movement and navigation;
- fight/security route;
- sneak/alternate route;
- return/contact-area placeholder.

### Stage B

Stage B defers social and continuity systems:

- guard bribe/trade/dialogue;
- full NPC conversation support;
- generic NPC menu support;
- guard turns hostile after dialogue;
- route-dependent social consequences;
- death continuation/new unrelated character in the same world;
- NPC/world memory;
- corpse/dropped-loot persistence after death;
- full procedural job generation.

The reflection was that Stage A should not pretend to prove Stage B. That boundary is important for avoiding overclaims.

## 19. Link to the vertical slice audit

The design grill led directly to:

- [Vertical slice engine audit — Stage A](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md)

That document asks whether native BN systems can support:

- a 5–6 floor vertical complex;
- package placement and pickup;
- simple fight route using native security drone/robot/enemy behavior;
- sneak/alternate route using native terrain/navigation/interactions;
- existing Arcopolis commands and snapshots sufficient to drive/explain the slice.

It also codifies the evidence labels:

| Label          | Meaning                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------- |
| PROVEN         | Already witnessed by an Arcopolis test/regression/fixture.                                      |
| NATIVE-BN      | Implemented in BN code/data, but not yet proven through Arcopolis.                              |
| LIKELY         | Supported by code shape, but needs a fixture/regression.                                        |
| UNKNOWN        | Not enough evidence found.                                                                      |
| NOT FOUND      | Searched and did not find repo evidence.                                                        |
| NEEDS NEW SEAM | Native BN may support it in GUI, but Arcopolis cannot currently drive or observe it faithfully. |
| STAGE B        | Real requirement, but intentionally deferred.                                                   |

## 20. Why the first vertical proof was inverted

After `47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md`, the initial next-step sequence was:

1. vertical movement witness;
2. vertical fixture/generator.

That was revised because the current fixtures may not place the avatar near usable z-level transitions.

The corrected order became:

1. minimal vertical fixture/generator;
2. vertical movement witness using that fixture.

The reflection was:

> It is cleaner to isolate the test environment before proving the command seam.

A movement witness that also has to discover or build its own vertical test location would conflate fixture problems with backend command problems.

## 21. Current near-term proof sequence

The design-grill outcome implies this staged proof sequence:

1. Minimal deterministic vertical fixture/generator. — **DONE (Spike 23, `ArcopolisStairsTest`).**
2. Vertical movement witness using that fixture. — **DONE (Spike 24, the `vertical_move` verb, matched-stair down→up round trip, level 2/3; doc 49).**
3. Package placement/pickup/export witness. — **next.**
4. Return/contact-area placeholder witness.
5. Security drone/fight route witness.
6. Sneak/alternate route witness.
7. Stage B NPC/guard/bribe/death-continuation audit or first social-interaction spike.

This is not a coding prompt. It is the current strategic sequence.

## 22. Relationship to backend architecture

The design ambition does not relax the protected Arcopolis backend architecture.

The protected path remains:

```text
external frontend/client
-> Arcopolis command/protocol
-> real BN input seam: game::handle_action()
-> game::do_turn owns turns/world ticking
-> read-only snapshots + session transcript
-> external consumer explains/renders state
```

The product direction does not justify:

- faking state;
- bypassing `game::do_turn()`;
- reviving the failed command -> do_turn path;
- directly mutating menu results or map state from Arcopolis;
- claiming equivalence from final state alone;
- treating one prompt witness as generic prompt support;
- broadening prompt/menu support without a witnessed path.

## 23. Relationship to C++23 / refactor strategy

The design grill also clarified why the C++23 strategy is necessary but not sufficient.

The C++23 strategy says:

- no big-bang modernization;
- no broad mechanical refactors;
- refactors must be test-backed and backend-relevant.

The design grill adds:

> Backend-relevant means relevant to the product slice: vertical persistent urban RPG gameplay, not generic code cleanliness.

That means future refactors should be judged by whether they help:

- vertical navigation;
- native action driving;
- snapshot clarity;
- package/objective handling;
- persistent world state;
- staged mission consequences;
- frontend legibility;
- prompt/UI separation.

## 24. Reflection summary

The conversation moved through several layers:

1. **Architecture discipline**\
   Keep BN authoritative. Do not fake state or bypass the turn loop.

2. **Modernization discipline**\
   Do not rewrite BN just because C++23 exists.

3. **Product identity**\
   Arcopolis is a new vertical urban roguelike RPG, not BN with a new UI.

4. **Loop clarification**\
   The player runs dangerous jobs through a living city.

5. **Genre clarification**\
   Extraction is an influence, not the main paradigm. The game is closer to open-world / life-sim RPG with occasional tactics.

6. **System selection**\
   Reuse inventory, items, map/terrain, skills, activities, procedural mapgen, and save persistence. Treat much of the rest as MVP baggage.

7. **First-slice narrowing**\
   Focus on a package retrieval job in a vertical complex.

8. **Stage split**\
   Stage A proves vertical/package/fight/sneak feasibility. Stage B handles guard/bribe/NPC/death-continuation.

9. **Proof-order correction**\
   Build or validate a vertical fixture before proving vertical movement.

## 25. Open questions left by the grill

The grill did not fully resolve:

- Which native vertical mechanism is best for Arcopolis's first controlled fixture?
- Whether the first vertical space should be a save fixture, a mapgen special, or a generated fixture derived from an existing world.
- How much z-level information the snapshot/export contract must expose for a mouse-first frontend.
- Which native sneak route is easiest to prove first.
- Which native drone/robot/security enemy is best for the fight route.
- Whether package/objective state should be BN-native, Arcopolis-owned, or initially fixture-driven.
- How guard/bribe/dialogue should eventually be witnessed without weakening prompt fail-loud rules.
- How death continuation should separate world state from avatar state.

## 26. Bottom line

The design grill turned a broad moonshot into a staged proof strategy.

The core outcome is:

> Arcopolis should first prove a deterministic vertical mission environment, then prove native vertical movement, then layer package retrieval, fight pressure, and alternate routes, before returning to NPC/bribe/death-continuation systems.

This keeps the project aligned with the product differentiator — a persistent vertical urban RPG — while preserving the backend discipline that makes Arcopolis meaningful.
