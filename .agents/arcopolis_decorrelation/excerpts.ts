/**
 * @module
 *
 * Bright Nights source excerpts embedded into the blind classification prompts for the
 * cross-model de-correlation experiment (see README.md).
 *
 * Each excerpt is a faithful TRIM of real `src/` at the cited line range, confirmed at the leaf.
 * The CODE is quoted verbatim; comments are either the source's own or an honest `// ...` elision.
 * No author-added annotation states the scope, recursion, visibility, or class that a trap is
 * testing — those must be DERIVED from the code, never read off a comment. A blind reader with no
 * repo checkout classifies a goal from these excerpts, so a fabricated or answer-bearing excerpt
 * would invalidate the measurement. Line numbers drift across upstream syncs — trust the symbol
 * names; re-verify the snippet against the symbol if a sync moves it.
 *
 * The A/B/C/D/S class of a surface is never stated here; which excerpt (if any) answers a given
 * goal is exactly what the blind reader must decide.
 */

export interface Excerpt {
  /** stable id referenced from corpus.jsonl */
  id: string
  /** source file (repo-relative) */
  file: string
  /** symbol the excerpt is drawn from */
  symbol: string
  /** approximate line range at time of capture */
  lines: string
  /** fence language for rendering */
  lang: "cpp" | "json"
  /** a NEUTRAL one-line description of what the routine does — never names a class */
  neutral_desc: string
  /** faithful (trimmed) source text — code verbatim, comments from source or elided */
  text: string
}

export const EXCERPTS: Record<string, Excerpt> = {
  carried_items_export: {
    id: "carried_items_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_carried_items",
    lines: "~97-132",
    lang: "cpp",
    neutral_desc:
      "Writes the avatar's wielded/worn/inventory items into the snapshot JSON as avatar.carried_items[].",
    text: `auto write_carried_items( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    json.member( "carried_items" );
    json.start_array();
    auto item_index = 0;
    const auto emit = [&]( const item & it, const std::string & location ) {
        json.start_object();
        json.member( "index", item_index++ );
        json.member( "type_id", it.typeId().str() );
        json.member( "name", it.display_name() );
        json.member( "symbol", it.symbol() );
        json.member( "location", location );  // "wielded" | "worn" | "inventory"
        json.member( "charges", it.charges );
        json.member( "count_by_charges", it.count_by_charges() );
        json.end_object();
    };
    for( const item *it : ctx.u.wielded_items() ) {
        emit( *it, "wielded" );
    }
    for( const item *it : ctx.u.worn ) {
        emit( *it, "worn" );
    }
    for( const auto *stack : ctx.u.inv_const_slice() ) {
        for( const item *it : *stack ) {
            emit( *it, "inventory" );
        }
    }
    json.end_array();
}`,
  },

  entities_items_export: {
    id: "entities_items_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_entities (items)",
    lines: "~350-388",
    lang: "cpp",
    neutral_desc:
      "Writes the ground-item stack (map::i_at) of each nearby tile into the snapshot JSON as entities.items[].",
    text: `json.member( "items" );
json.start_array();
auto item_index = 0;
for( const auto &p : points_in_radius( center, ctx.radius ) ) {
    if( !in_export_window( p, center, ctx ) ) { continue; }
    for( const auto *const it : get_map().i_at( p ) ) {
        json.start_object();
        json.member( "index", item_index++ );
        json.member( "type_id", it->typeId().str() );
        json.member( "name", it->display_name() );
        json.member( "symbol", it->symbol() );
        // ... pos_local / pos_abs ...
        json.member( "charges", it->charges );
        json.member( "count_by_charges", it->count_by_charges() );
        json.end_object();
    }
}
json.end_array();`,
  },

  avatar_scalars_export: {
    id: "avatar_scalars_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_avatar (scalars)",
    lines: "~157-167",
    lang: "cpp",
    neutral_desc:
      "Writes the avatar's scalar status values straight from the engine getters into the snapshot JSON.",
    text: `json.member( "hp", ctx.u.get_hp() );            // sum across body parts
json.member( "hp_max", ctx.u.get_hp_max() );
json.member( "stamina", ctx.u.get_stamina() );
json.member( "moves", ctx.u.get_moves() );
json.member( "pain", ctx.u.get_pain() );
json.member( "thirst", ctx.u.get_thirst() );
json.member( "fatigue", ctx.u.get_fatigue() );
json.member( "stored_kcal", ctx.u.get_stored_kcal() );
json.member( "kcal_percent", ctx.u.get_kcal_percent() );  // float`,
  },

  tiles_export: {
    id: "tiles_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_tiles (per tile)",
    lines: "~213-214",
    lang: "cpp",
    neutral_desc:
      "For each nearby tile, writes the terrain and furniture string ids into the snapshot JSON.",
    text: `// inside write_tiles' per-tile loop (p : tripoint_bub_ms):
json.member( "ter", ctx.m.ter( p ).id().str() );    // e.g. "t_floor"
json.member( "furn", ctx.m.furn( p ).id().str() );  // e.g. "f_null"`,
  },

  monster_hp_export: {
    id: "monster_hp_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_entities (monsters)",
    lines: "~284-287",
    lang: "cpp",
    neutral_desc:
      "For each nearby monster, writes its current and max hp integers straight from the engine getters.",
    text: `json.member( "hp", mon.get_hp() );
json.member( "hp_max", mon.get_hp_max() );
json.member( "moves", mon.get_moves() );
json.member( "hallucination", mon.is_hallucination() );`,
  },

  set_has_items: {
    id: "set_has_items",
    file: "src/condition.cpp",
    symbol: "conditional_t<T>::set_has_items  (u_has_items / npc_has_items)",
    lines: "~279-296",
    lang: "cpp",
    neutral_desc:
      "Builds the dialogue/condition lambda for u_has_items/npc_has_items; evaluates over the character actor.",
    text: `template<class T>
void conditional_t<T>::set_has_items( const JsonObject &jo, const std::string &member, bool is_npc )
{
    JsonObject has_items = jo.get_object( member );
    // ... reads "item" and "count" ...
    condition = [item_id, count, is_npc]( const T & d ) {
        player *actor = d.alpha;
        if( is_npc ) { actor = dynamic_cast<player *>( d.beta ); }
        return actor->has_charges( item_id, count ) || actor->has_amount( item_id, count );
    };
}`,
  },

  set_has_item: {
    id: "set_has_item",
    file: "src/condition.cpp",
    symbol: "conditional_t<T>::set_has_item  (u_has_item / npc_has_item)",
    lines: "~266-276",
    lang: "cpp",
    neutral_desc:
      "Builds the dialogue/condition lambda for the single-item u_has_item/npc_has_item check over the character actor.",
    text: `template<class T>
void conditional_t<T>::set_has_item( const JsonObject &jo, const std::string &member, bool is_npc )
{
    const itype_id item_id( jo.get_string( member ) );
    condition = [item_id, is_npc]( const T & d ) {
        player *actor = d.alpha;
        if( is_npc ) { actor = dynamic_cast<player *>( d.beta ); }
        return actor->charges_of( item_id ) > 0 || actor->has_amount( item_id, 1 );
    };
}`,
  },

  mission_is_complete: {
    id: "mission_is_complete",
    file: "src/mission.cpp",
    symbol: "mission::is_complete  (MGOAL_FIND_ITEM)",
    lines: "~384, 424-432",
    lang: "cpp",
    neutral_desc:
      "Decides whether a find-item mission is complete by checking a quantity against the player's crafting_inventory().",
    text: `bool mission::is_complete( const character_id &_npc_id ) const
{
    // ...
    switch( type->goal ) {
        case MGOAL_FIND_ITEM: {
            if( npc_id.is_valid() && npc_id != _npc_id ) { return false; }
            const inventory &tmp_inv = u.crafting_inventory();
            if( !tmp_inv.has_amount( type->item_id, item_count ) ) {
                return tmp_inv.has_amount( type->item_id, 1 )
                       && tmp_inv.has_charges( type->item_id, item_count );
            }
        }
        // ...
    }
}`,
  },

  visit_internal_recursion: {
    id: "visit_internal_recursion",
    file: "src/visitable.cpp",
    symbol: "visit_internal",
    lines: "~442-466",
    lang: "cpp",
    neutral_desc:
      "The item-traversal step used by visit_items: handles a node, then its contained items unless it is a gun/magazine.",
    text:
      `static VisitResponse visit_internal( const std::function<VisitResponse( item *, item * )> &func,
                                     item *node, item *parent = nullptr )
{
    switch( func( node, parent ) ) {
        case VisitResponse::ABORT:
            return VisitResponse::ABORT;
        case VisitResponse::NEXT:
            if( node->is_gun() || node->is_magazine() ) {
                // Content of guns and magazines are accessible only via their specific accessors
                return VisitResponse::NEXT;
            }
            if( node->contents.visit_contents( func, node ) == VisitResponse::ABORT ) {
                return VisitResponse::ABORT;
            }
        /* intentional fallthrough */
        case VisitResponse::SKIP:
            return VisitResponse::NEXT;
    }
    return VisitResponse::ABORT;
}`,
  },

  has_amount_def: {
    id: "has_amount_def",
    file: "src/visitable.cpp",
    symbol: "visitable<T>::has_amount / amount_of_internal",
    lines: "~1148-1160, 1244-1248",
    lang: "cpp",
    neutral_desc:
      "has_amount(id, qty) tallies matching items through visit_items (capped at qty) and returns whether the tally reached qty.",
    text: `template <typename T>
static int amount_of_internal( const T &self, const itype_id &id, bool pseudo, int limit, ... )
{
    int qty = 0;
    self.visit_items( [&]( const item * e ) {
        if( ( id.str() == "any" || e->typeId() == id ) && filter( *e )
              && ( pseudo || !e->has_flag( PSEUDO ) ) ) {
            qty = sum_no_wrap( qty, 1 );
        }
        return qty != limit ? VisitResponse::NEXT : VisitResponse::ABORT;
    } );
    return qty;
}

template <typename T>
bool visitable<T>::has_amount( const itype_id &what, int qty, bool pseudo, ... ) const
{
    return amount_of( what, pseudo, qty, filter ) == qty;
}`,
  },

  char_amount_of_onperson: {
    id: "char_amount_of_onperson",
    file: "src/visitable.cpp",
    symbol: "visitable<Character>::amount_of",
    lines: "~1213-1240",
    lang: "cpp",
    neutral_desc:
      "The Character specialization of amount_of: special-cases bionic pseudo-tools, otherwise tallies via amount_of_internal.",
    text: `template <>
int visitable<Character>::amount_of( const itype_id &what, bool pseudo, int limit, ... ) const
{
    auto self = static_cast<const Character *>( this );
    if( what->has_flag( flag_BIONIC_TOOLS ) && pseudo && self->has_active_bionic_with_fake( what ) ) {
        return 1;
    }
    if( what == itype_voltmeter_bionic && pseudo && self->has_bionic( bio_electrosense_voltmeter ) ) {
        return 1;
    }
    if( what == itype_apparatus && pseudo ) { /* SMOKE_PIPE quality tools */ }
    return amount_of_internal( *this, what, pseudo, limit, filter );
}`,
  },

  char_visit_items_roots: {
    id: "char_visit_items_roots",
    file: "src/visitable.cpp",
    symbol: "visitable<Character>::visit_items",
    lines: "~515-534",
    lang: "cpp",
    neutral_desc:
      "Defines which items belong to a Character for traversal: the wielded weapon, each worn item, and the inventory.",
    text: `template <>
VisitResponse visitable<Character>::visit_items(
    const std::function<VisitResponse( item *, item * )> &func )
{
    auto ch = static_cast<Character *>( this );
    if( !ch->primary_weapon().is_null() &&
        visit_internal( func, &ch->primary_weapon() ) == VisitResponse::ABORT ) {
        return VisitResponse::ABORT;
    }
    for( auto &e : ch->worn ) {
        if( visit_internal( func, e ) == VisitResponse::ABORT ) { return VisitResponse::ABORT; }
    }
    return ch->inv.visit_items( func );
}`,
  },

  i_add_to_container_ammo_only: {
    id: "i_add_to_container_ammo_only",
    file: "src/character.cpp",
    symbol: "Character::i_add_to_container",
    lines: "~2675-2707",
    lang: "cpp",
    neutral_desc:
      "On pickup, merges an item into an already-worn matching container only when the item is ammo; otherwise returns it unchanged.",
    text:
      `detached_ptr<item> Character::i_add_to_container( detached_ptr<item> &&it, const bool unloading )
{
    if( !it->is_ammo() || unloading ) {
        return std::move( it );
    }
    const itype_id item_type = it->typeId();
    // ...
    visit_items( [ & ]( item * item ) {
        if( it && item->is_ammo_container() && item_type == item->contents.front().typeId() ) {
            add_to_container( *item );
            item->handle_pickup_ownership( *this );
        }
        return VisitResponse::NEXT;
    } );
    return std::move( it );
}`,
  },

  creature_sees: {
    id: "creature_sees",
    file: "src/creature.cpp",
    symbol: "Creature::sees",
    lines: "~369-448",
    lang: "cpp",
    neutral_desc:
      "Computes whether one creature can see another right now, from range, light, line of sight, and concealment.",
    text: `bool Creature::sees( const Creature &critter ) const
{
    if( &critter == this ) { return true; }
    if( critter.is_hallucination() ) { return is_player(); }
    if( get_dimension() != critter.get_dimension() ) { return false; }
    map &here = get_map();
    const Character *ch = critter.as_character();
    const int wanted_range = rl_dist( bub_pos(), critter.bub_pos() );
    if( wanted_range <= 1 && ( bub_pos().z() == critter.bub_pos().z() ||
                               here.sees( bub_pos(), critter.bub_pos(), 1 ) ) ) {
        if( here.obscured_by_vehicle_rotation( bub_pos(), critter.bub_pos() ) ) { return false; }
        return visible( ch );
    }
    // ... else range/light/night-invisibility/hide-place/crouch-coverage checks, then a final
    //     here.sees( bub_pos(), critter.bub_pos(), ... ) ...
}`,
  },

  map_sees: {
    id: "map_sees",
    file: "src/map.cpp",
    symbol: "map::sees",
    lines: "~7724-7735",
    lang: "cpp",
    neutral_desc:
      "Tests reachability from one tile to another within range via the four-argument overload.",
    text:
      `bool map::sees( const tripoint_bub_ms &F, const tripoint_bub_ms &T, const int range ) const
{
    int dummy = 0;
    return sees( F, T, range, dummy );
}`,
  },

  tiles_seen_export: {
    id: "tiles_seen_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_tiles (seen)",
    lines: "~213-217",
    lang: "cpp",
    neutral_desc:
      "For each nearby tile, writes terrain/furniture ids and a 'seen' value taken from map::pl_sees.",
    text: `// inside write_tiles' per-tile loop (p : tripoint_bub_ms):
json.member( "ter", ctx.m.ter( p ).id().str() );
json.member( "furn", ctx.m.furn( p ).id().str() );
json.member( "seen", ctx.m.pl_sees( p, ctx.radius ) );`,
  },

  monster_window_export: {
    id: "monster_window_export",
    file: "src/arcopolis_export.cpp",
    symbol: "write_entities (monsters window)",
    lines: "~250-290",
    lang: "cpp",
    neutral_desc:
      "Builds entities.monsters[] from g->all_monsters(), filtered by in_export_window around the avatar.",
    text: `// entities.monsters[] from g->all_monsters(), filtered by in_export_window:
for( const monster &mon : g->all_monsters() ) {
    if( !in_export_window( mon.bub_pos(), center, ctx ) ) { continue; }
    // ... writes index, type_id, pos_local/pos_abs, hp, hp_max, hallucination ...
}`,
  },

  handle_action_move: {
    id: "handle_action_move",
    file: "src/handle_action.cpp",
    symbol: "game::handle_action (ACTION_MOVE_*)",
    lines: "~2122-2182",
    lang: "cpp",
    neutral_desc:
      "The engine's input-dispatch site for the registered planar movement actions; calls the avatar move, then the turn loop owns the tick.",
    text: `case ACTION_MOVE_FORTH:
case ACTION_MOVE_RIGHT:
// ... the eight registered planar movement actions ...
case ACTION_MOVE_FORTH_LEFT: {
    auto moved = false;
    moved = avatar_action::move( u, m, dest_delta );
    if( !moved ) { u.clear_destination(); }
}
break;`,
  },

  handle_action_reload: {
    id: "handle_action_reload",
    file: "src/handle_action.cpp",
    symbol: "game::handle_action (ACTION_RELOAD_WIELDED)",
    lines: "~2536-2538",
    lang: "cpp",
    neutral_desc:
      "The engine's input-dispatch site for the registered reload action; runs the avatar's reload.",
    text: `case ACTION_RELOAD_WIELDED:
    avatar_action::reload_wielded();
    break;`,
  },

  npc_menu_uilist: {
    id: "npc_menu_uilist",
    file: "src/game.cpp",
    symbol: "game::npc_menu",
    lines: "~7927-7973",
    lang: "cpp",
    neutral_desc:
      "Reached when the avatar bumps or examines a tile occupied by an NPC; builds a uilist and queries it.",
    text: `bool game::npc_menu( npc &who, const bool &force )
{
    // ...
    uilist amenu;
    amenu.text = string_format( _( "What to do with %s?" ), who.disp_name() );
    amenu.addentry( talk, true, 't', _( "Talk" ) );
    amenu.addentry( swap_pos, ..., 's', _( "Swap positions" ) );
    amenu.addentry( push, ..., 'p', _( "Push away" ) );
    // ... examine wounds / use item / attack / disarm / steal / ...
    amenu.query();
    const int choice = amenu.ret;
    // ...
}`,
  },

  pickup_menu_inputcontext: {
    id: "pickup_menu_inputcontext",
    file: "src/pickup.cpp",
    symbol: "pick_up_from_items (PICKUP menu)",
    lines: "~291, 832-849",
    lang: "cpp",
    neutral_desc:
      "The old item-pickup selector: registers navigation/select actions and runs an input loop over them.",
    text: `input_context ctxt( "PICKUP" );
ctxt.register_action( "UP" );
ctxt.register_action( "DOWN" );
ctxt.register_action( "RIGHT" );
ctxt.register_action( "CONFIRM" );
ctxt.register_action( "QUIT", to_translation( "Cancel" ) );
// ... then a redraw/input loop: const std::string action = ctxt.handle_input();
//     marking the selection on UP/DOWN/RIGHT and finalizing on CONFIRM ...`,
  },

  weight_capacity_computed: {
    id: "weight_capacity_computed",
    file: "src/character.cpp",
    symbol: "Character::weight_capacity",
    lines: "~3167-3195",
    lang: "cpp",
    neutral_desc:
      "Computes how much weight a character can carry from base capacity, strength, mutations, enchantments, worn items, and bionics.",
    text: `units::mass Character::weight_capacity() const
{
    if( has_trait( trait_DEBUG_STORAGE ) ) { return units::mass_max; }
    units::mass ret = Creature::weight_capacity();
    ret += get_str() * 4_kilogram;
    ret *= mutation_value( "weight_capacity_modifier" );
    ret += bonus_from_enchantments( ret / 1_gram, enchantment_value_id( "CARRY_WEIGHT" ) ) * 1_gram;
    for( const item * const &it : worn ) { ret *= it->get_weight_capacity_modifier(); /* + bonus */ }
    for( const bionic &i : get_bionic_collection() ) { ret *= i.id->weight_capacity_modifier; /* +bonus */ }
    return ret;
}`,
  },

  can_pick_weight: {
    id: "can_pick_weight",
    file: "src/character.cpp",
    symbol: "Character::can_pick_weight",
    lines: "~3250-3264",
    lang: "cpp",
    neutral_desc:
      "Decides whether the character can take on a given weight: compares current carried weight plus the weight against the carry capacity.",
    text: `bool Character::can_pick_weight( const item &it, bool safe ) const
{
    return can_pick_weight( it.weight(), safe );
}

bool Character::can_pick_weight( units::mass weight, bool safe ) const
{
    if( !safe ) {
        return ( weight_carried() + weight <= ( has_trait( trait_DEBUG_STORAGE ) ?
                                                units::mass_max : weight_capacity() * 4 ) );
    } else {
        return ( weight_carried() + weight <= weight_capacity() );
    }
}`,
  },

  secondary_capacity_uilist: {
    id: "secondary_capacity_uilist",
    file: "src/pickup.cpp",
    symbol: "handle_problematic_pickup",
    lines: "~164-245",
    lang: "cpp",
    neutral_desc:
      "Builds a Wear/Wield/Empty/Spill uilist and queries it; reached from the pickup path when an item does not fit.",
    text: `static pickup_answer handle_problematic_pickup( const item &it, bool &offered_swap,
        bool has_children, const std::string &explain )
{
    uilist amenu;
    amenu.text = explain;                                  // e.g. "The %s is too heavy!"
    if( it.is_armor() ) { amenu.addentry( WEAR, u.can_wear( it ).success(), 'W', _( "Wear %s" ), ... ); }
    if( u.is_armed() ) { amenu.addentry( WIELD, ..., 'w', _( "Dispose of %s and wield %s" ), ... ); }
    else { amenu.addentry( WIELD, true, 'w', _( "Wield %s" ), ... ); }
    if( has_children ) { amenu.addentry( EMPTY, ..., 'e', _( "Pick up just %s, without contents" ), ... ); }
    // ... amenu.query();
}`,
  },

  crafting_recipe_select: {
    id: "crafting_recipe_select",
    file: "src/crafting.cpp, src/crafting_gui.cpp",
    symbol: "Character::craft -> select_crafting_recipe",
    lines: "crafting.cpp:387, crafting_gui.cpp:664",
    lang: "cpp",
    neutral_desc:
      "Crafting: Character::craft calls select_crafting_recipe(), which sets up an input_context over the recipe list and returns the selected recipe.",
    text: `// Character::craft (src/crafting.cpp):
int batch_size = 0;
const recipe *rec = select_crafting_recipe( batch_size, *this );
if( rec ) {
    if( crafting_allowed( *this, *rec ) ) {
        make_craft( rec->ident(), batch_size, loc );
// src/crafting_gui.cpp:
const recipe *select_crafting_recipe( int &batch_size_out, Character &crafter )
{
    struct {
        const recipe *recp = nullptr;
        // ...
    } recipe_info_cache;
    int recipe_info_scroll = 0;
    // ...
    input_context ctxt = make_crafting_context( highlight_unread_recipes );
    // ...
}`,
  },
}
