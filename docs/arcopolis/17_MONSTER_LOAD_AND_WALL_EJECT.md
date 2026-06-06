# Monster load behaviour & the "wall eject" — why a save-injected witness drifted

> **Status: ✅ root-caused & fixed (2026-06-05).** While building the Spike 6B witness
> ([16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md](16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md)) the injected
> `mon_fungal_wall` — an `IMMOBILE` type — moved 3 tiles "toward the avatar" on the first turn, which looked
> like it contradicted immobility. This doc traces the monster save→load→first-turn path **line by line** and
> shows the move is a single deterministic **teleport off impassable terrain**, not AI movement or catch-up.
> The witness had been placed **inside the shelter's south wall**. On passable terrain it is exactly
> stationary. Analysis is **from the code** plus a few save-only experiments (no rebuild); citations are to
> this worktree's `src/`.

## Symptom

Witness injected at the avatar's `abs_pos + (0,6,0)` = **`[6301,6427,0]`**. Across the regression's three
frames:

| frame                    | turn    | witness `pos_abs` | witness `pos_local` |
| ------------------------ | ------- | ----------------- | ------------------- |
| `000_witness_load`       | 1324801 | `[6301,6427,0]`   | `(85,91,0)`         |
| `001_witness_after_tick` | 1324802 | `[6298,6424,0]`   | `(82,88,0)`         |
| `002_final`              | 1324802 | `[6298,6424,0]`   | `(82,88,0)`         |

It jumps `(-3,-3)` exactly once (between load and the first ticked frame), then never moves again — and it is
**reproducible** (identical across independent rebuilds), and **independent of `last_updated`** (the same jump
occurs whether `last_updated` is `1324800` or `1324811`, which already rules out load catch-up).

## The terrain — the whole story in one read

Read straight from `map.sqlite3` (no build; method in the `arcopolis-read-fixture-without-build` memory):

```
        x=6298   6299   6300   6301(av col)
y=6426  floor    floor  floor  floor
y=6427  …S…(6298) wall_w wall_w  I  wall_w   <- shelter SOUTH WALL ; I = injected (6301,6427)=t_wall_w
y=6428  grass    grass  grass  grass         <- outside the shelter (passable)
```

- avatar `(6301,6421)` = `t_floor` (inside the shelter)
- **injected `(6301,6427)` = `t_wall_w`** — `avatar+6 south` is exactly the shelter's south wall (impassable)
- settled `(6298,6424)` = `t_floor` (back inside the shelter)

The witness was injected **inside a wall**. Everything below is the engine correcting that.

## The save → load → first-turn path, line by line

### 1. Save — `active_monsters` is a flat list (`src/savegame.cpp:143`)

```cpp
json.member( "active_monsters", *critter_tracker );   // Creature_tracker::serialize -> array of monsters
```

Each monster serializes its absolute position as `pos_abs` (`src/savegame_json.cpp`, the `monster::store`
path). The witness is just another element appended to this array by `make_monster_fixture.py`.

### 2. Load — placed at the exact tile, no terrain check (`src/creature_tracker.cpp:56`)

`game::unserialize` reads `active_monsters` (`src/savegame.cpp:337`) → `Creature_tracker::deserialize` →
`add()` for each monster:

```cpp
bool Creature_tracker::add( const shared_ptr_fast<monster> &critter_ptr ) {
    ...
    if( const shared_ptr_fast<monster> existing_mon_ptr = find( critter.bub_pos() ) ) {
        ... // only DUPLICATE-position handling (hallucination / debugmsg+reject)
    }
    ...
    monsters_list.emplace_back( critter_ptr );
    monsters_by_location[critter.bub_pos()] = critter_ptr;   // stored at its EXACT bub_pos
    ...
}
```

`add()` validates type-null/vermin/duplicate/blacklist — **never terrain**, and **never relocates**. So the
witness loads at exactly `[6301,6427]` (the wall). This is why **frame 000 still shows it in the wall**.

### 3. `on_load` / `batch_turns` — catch-up, but never position (`src/monster.cpp:4015`, `:2971`)

```cpp
void monster::on_load() {
    batch_turns( to_turns<int>( calendar::turn - last_updated ) );   // catch-up since last save
    last_updated = calendar::turn;
    ...
}
void monster::batch_turns( int n ) {
    if( n <= 0 || is_dead_state() ) { return; }   // <- no-op for n<=0
    ... // try_upgrade, special-attack cooldowns, anger decay, try_reproduce, regen/heal
    moves = 0;                                     // ends here — NO setpos anywhere
}
```

`batch_turns` advances _timers/state_, never coordinates. And `on_load` is only invoked from the map/overmap
**spawn** paths (`src/map.cpp:9332` / `:9390`, `src/overmapbuffer.cpp:1934`) — for monsters spawned from
submap/overmap groups, not for `active_monsters` tracker entries. Either way: **not the mover**. (Setting
`last_updated = turn` makes it a guaranteed no-op; the experiment above confirms it is irrelevant to the
jump.)

### 4. First turn — the eject (`src/game.cpp:5994`, inside `game::monmove`)

`wait` → `game::do_turn` → `game::monmove()` (`src/game.cpp:5603`). Its **lifecycle** pass runs _before_ any
monster AI:

```cpp
// src/game.cpp:5984  ZoneScopedN( "monmove_lifecycle" )
for( monster *critter_ptr : *mon_snap ) {
    monster &critter = *critter_ptr;
    if( !critter.is_simulated() ) { continue; }
    // Critters in impassable tiles get pushed away, unless it's not impassable for them
    if( !critter.is_dead() && m.impassable( critter.bub_pos() ) &&
        !critter.can_move_to( critter.bub_pos() ) ) {            // 5995 : TRUE — it's in a wall
        ...
        bool okay = false;
        for( const tripoint_bub_ms &dest : m.points_in_radius( critter.bub_pos(), 3 ) ) {  // 6002
            if( critter.can_move_to( dest ) && is_empty( dest ) ) {
                critter.setpos( dest );    // 6004 : single teleport to the first valid tile
                okay = true; break;
            }
        }
        if( !okay ) { critter.die( nullptr ); }   // 6011 : walled-in by >3 tiles solid => DIES
    }
    ... // then process_items / process_turn / fields
}
```

This is the mover. It explains **every** observation:

- **One jump, 3 tiles, in one turn:** it is a single `setpos`, not stepwise movement, so move-cost/speed are
  irrelevant. The `points_in_radius(pos, 3)` window is exactly Chebyshev ≤ 3 — the jump is `(-3,-3)`, the
  corner of that window.
- **Deterministic:** `points_in_radius` iterates a fixed order and there is no RNG; the first
  `can_move_to && is_empty` tile is always the same → always `[6298,6424]`.
- **"Toward the avatar":** the only passable tiles near the south-wall cell are the shelter floor to its
  **north/NW** (south is more wall, then grass), so the first valid tile the scan accepts is inward — a
  geometry coincidence, **not** aggression/pathing.
- **Applies to an `IMMOBILE` monster:** this lifecycle guard runs for every simulated critter, _before_
  `decide_action()`. Immobility only governs the monster's _own_ action (next point), not this correction.

### 5. The monster's own action never moves it (`src/monmove.cpp:1000`, `:1029`)

After the lifecycle guard, `game::monmove` calls each monster's `move()` = `decide_action()` +
`execute_action()` (`src/monmove.cpp:1641`). For an `IMMOBILE` monster `decide_action()` returns at the early
guard:

```cpp
// src/monmove.cpp:1029
if( has_flag( MF_IMMOBILE ) || has_flag( MF_RIDEABLE_MECH ) ) {
    action.kind = monster_action_kind::idle;     // returns BEFORE any stumble/step logic
    action.move_cost = moves;
    return action;
}
```

`has_flag(MF_IMMOBILE)` is true because the **type** carries it
(`monster::has_flag` = `type->has_flag(f) || monster_flags.contains(f)`, `src/monster.cpp:1149`; and
`mon_fungal_wall` has `IMMOBILE` in `data/json/monsters/fungus.json`). So the witness _decides idle and never
moves itself_ — independently confirmed by experiment: on open **grass** it does not wander at all (frames 2
and 3 identical). The drift was solely the §4 eject.

## Can the save be edited so this never happens? — Yes: passable terrain

The §4 guard fires only when `m.impassable(pos) && !can_move_to(pos)`. Place the witness on **passable
terrain** and the condition is false → no teleport. Combined with the `IMMOBILE` type (no wandering), the
witness is then **exactly stationary**. Validated (offset `0,8,0` = grass `[6301,6429]`):

| frame | witness `pos_abs` | witness `pos_local` |
| ----- | ----------------- | ------------------- |
| `000` | `[6301,6429,0]`   | `(85,93,0)`         |
| `001` | `[6301,6429,0]`   | `(85,93,0)`         |
| `002` | `[6301,6429,0]`   | `(85,93,0)`         |

So `make_monster_fixture.py` now **defaults to `--offset 0,8,0`** (grass, Chebyshev 8, in-window) and reads
`map.sqlite3` to **warn if the chosen tile looks impassable**. The shelter floor (e.g. `0,5,0`) is equally
valid. There is no save-only way to keep a monster _on an impassable tile_ — the engine corrects it every
turn — so the fix is to not place it there.

> **Danger — not just cosmetic:** if the witness is walled-in with **no** passable tile within radius 3, the
> guard takes the `else` branch and `die()`s it (`src/game.cpp:6011`). The witness would silently **vanish**
> and the gate would fail with `count 0`. Passable placement is mandatory.

## Experiments run (save-edit only, no rebuild)

| Experiment                                             | Result                                        | Conclusion                          |
| ------------------------------------------------------ | --------------------------------------------- | ----------------------------------- |
| Read terrain at injected/settled tiles (`map.sqlite3`) | injected `t_wall_w`, settled/avatar `t_floor` | witness was inside a wall           |
| `last_updated` = `1324800` vs `1324811`                | identical `(-3,-3)` jump                      | not load catch-up (`batch_turns`)   |
| Offset `0,8,0` (grass) vs `0,5,0` (floor)              | stationary on all frames                      | passable terrain → no eject         |
| Offset `0,6,0` (wall) re-run                           | same deterministic jump to `[6298,6424]`      | reproducible, RNG-free              |
| On grass: does the `IMMOBILE` monster wander?          | no (frames 2,3 identical)                     | it really is immobile; drift was §4 |

## Citation audit

| Claim                                                       | Evidence                                                                                                    |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Load places the monster at its exact tile, no terrain check | `Creature_tracker::add` (`src/creature_tracker.cpp:56-92`)                                                  |
| `batch_turns` never changes position; no-op for `n<=0`      | `src/monster.cpp:2971-3057` (early `return`; ends `moves = 0`)                                              |
| The mover is the impassable-eject in the monmove lifecycle  | `src/game.cpp:5994-6013` (`impassable && !can_move_to` → radius-3 setpos)                                   |
| No valid tile in radius 3 ⇒ the monster dies                | `src/game.cpp:6009-6012` (`die( nullptr )`)                                                                 |
| Eject runs before, and independent of, the monster's action | lifecycle loop precedes `move()`; `decide_action` IMMOBILE→idle (`src/monmove.cpp:1029`)                    |
| The witness type really is immobile                         | `monster::has_flag` (`src/monster.cpp:1149`) + `IMMOBILE` in `fungus.json`; no wander on grass (experiment) |
| Injected tile was the shelter's south wall                  | `map.sqlite3` terrain read: `(6301,6427)=t_wall_w`                                                          |
| Passable placement ⇒ exactly stationary                     | offset `0,8,0` run: `pos_abs` identical on frames 000/001/002                                               |
