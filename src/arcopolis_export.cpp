#include "arcopolis_export.h"

#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "arcopolis_backend_input.h"  // begin/end_backend_session (drive the command through the seam)
#include "arcopolis_command.h"  // read_command_file/command_to_action/exit_code_for
#include "arcopolis_script.h"  // script_step (the single-command session step)
#include "avatar.h"          // avatar, get_avatar()
#include "calendar.h"        // to_turn(), calendar::turn
#include "character.h"       // get_name/thirst/fatigue/stamina/kcal getters
#include "color.h"           // init_colors()
#include "coordinates.h"     // tripoint_bub_ms / _abs_ms / _abs_sm, .x()/.y()/.z()
#include "creature.h"        // get_hp/get_hp_max/get_pain
#include "fstream_utils.h"   // write_to_file()
#include "game.h"            // g, game::load(world), get_levz(), savegame_version
#include "game_constants.h"  // SEEX
#include "get_version.h"     // getVersionString()
#include "item.h"            // item (complete type: typeId/display_name/symbol/charges/count_by_charges + map_stack deref)
#include "json.h"            // JsonOut
#include "map.h"             // get_map(), ter/furn/pl_sees/inbounds/getmapsize/get_abs_sub
#include "map_iterator.h"    // points_in_radius()
#include "messages.h"        // Messages::recent_messages()
#include "monster.h"         // monster (complete type for all_monsters() iteration + accessors)
#include "mtype.h"           // mtype::id (mon.type->id)
#include "npc.h"             // npc (complete type for all_npcs() iteration + relationship predicates)
#include "options.h"         // get_option<float>( "TURN_DURATION" )
#include "type_id.h"         // ter_id/furn_id -> .id().str()

namespace
{

/// Conservative half-width (tiles) of the square window exported around the avatar. The full loaded
/// reality bubble is ~132x132 (getmapsize()*SEEX); 12 keeps Spike 0 snapshots small but real.
constexpr auto arcopolis_view_radius = 12;

/// Read-only bundle passed to each writer (keeps every writer at <=3 params per AGENTS).
struct snapshot_ctx {
    const avatar &u;                     ///< read-only avatar state
    const map &m;                        ///< read-only loaded reality bubble
    int levz;                            ///< current z-level (game::get_levz())
    int radius;                          ///< half-width of the exported square tile window
    std::vector<std::string> &warnings;  ///< diagnostics accumulator (referent is mutable)
    const std::optional<arcopolis::snapshot_session_info>
    &session;  ///< Spike 2 metadata (none = nullopt)
    /// Spike 27B events captured WHILE the session was active (drained at the capture site, never
    /// here); write_damage_taken serializes this copy so the serializer is PURE -- one-shot and
    /// run-script render identically.
    std::vector<arcopolis::avatar_damage_record> damage_taken;
};

auto write_session( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    if( !ctx.session ) {
        return;  // one-shot Spike 0/1 export: no "session" block, output unchanged
    }
    json.member( "session" );
    json.start_object();
    json.member( "export_index", ctx.session->export_index );
    // step_index is null for the final-on-exit snapshot (it belongs to no steps[] entry); the value form
    // is unchanged for every export-step snapshot.
    json.member( "step_index" );
    if( ctx.session->step_index ) {
        json.write( *ctx.session->step_index );
    } else {
        json.write_null();
    }
    json.member( "export_name", ctx.session->export_name );
    json.member( "final", ctx.session->final );  // true only for the terminal snapshot (Spike 3.1B)
    json.end_object();
}

auto write_backend( JsonOut &json ) -> void
{
    json.member( "backend" );
    json.start_object();
    json.member( "game_version", std::string( getVersionString() ) );
    json.member( "save_version", savegame_version );
    json.member( "turn", to_turn<int>
                 ( calendar::turn ) );  // current sim turn; advances when a command does
    json.end_object();
}

/// Spike 25: the avatar's TOP-LEVEL carried items, read-only, written inside the avatar object as
/// avatar.carried_items[]. Three sources are enumerated explicitly in the SAME order BN's own
/// visitable<Character>::visit_items roots them (src/visitable.cpp): the wielded weapon, every worn item,
/// then each top-level inventory stack's items. Enumerating the sources directly (rather than visit_items)
/// gives the "location" tag for free and is top-level BY CONSTRUCTION - nothing nested inside a container is
/// traversed (nested-container contents, vehicle cargo, and NPC inventory all stay deferred). A picked-up
/// loose item lands in the flat Character::inv via i_add (src/character.cpp i_add -> inv.add_item, reached at
/// src/pickup.cpp), so it appears here as an "inventory" entry. This export is DISPLAY-ONLY and does NOT
/// answer possession: "does the character have item X" is BN's own verdict via its container-recursing
/// has_amount / has_charges predicates (visitable<Character>; real callers condition.cpp, mission.cpp). A
/// flat top-level export cannot mirror that recursion - see 51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md. v0
/// fields match entities.items (ground) minus pos_local/pos_abs (a carried
/// item has no tile) plus the "location" tag. This is a read-only authoritative export, NOT a drop/use/wear
/// surface: nothing is moved, equipped, unequipped, or otherwise mutated; every accessor is const.
auto write_carried_items( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    json.member( "carried_items" );
    json.start_array();
    auto item_index = 0;
    const auto emit = [&]( const item & it, const std::string & location ) {
        json.start_object();
        json.member( "index", item_index++ );  // export-local, 0-based across all three sources
        json.member( "type_id", it.typeId().str() );
        json.member( "name", it.display_name() );  // same look/pickup display name as ground items
        json.member( "symbol", it.symbol() );
        json.member( "location", location );  // "wielded" | "worn" | "inventory"
        // charges is only semantically meaningful when count_by_charges() is true (ammo/liquids/stackables);
        // for everything else a consumer should treat the item as a single unit (mirrors entities.items).
        json.member( "charges", it.charges );
        json.member( "count_by_charges", it.count_by_charges() );
        json.end_object();
    };
    // wielded_items() is the documented-preferred accessor (returns only limb-held items, empty when
    // unarmed) - it avoids primary_weapon()'s legacy null-item hack, so no null/"fists" entry is emitted.
    for( const item *it : ctx.u.wielded_items() ) {
        emit( *it, "wielded" );
    }
    for( const item *it :
         ctx.u.worn ) {  // location_vector<item>; const_iterator yields item* const (read-only)
        emit( *it, "worn" );
    }
    // inv_const_slice() groups identical items into stacks; emit one entry per physical top-level item so the
    // granularity matches entities.items (one entry per ground item), never descending into contents.
    for( const auto *stack : ctx.u.inv_const_slice() ) {
        for( const item *it : *stack ) {
            emit( *it, "inventory" );
        }
    }
    json.end_array();
}

/// Spike 27B: the avatar's attacker-attributed damage events since the prior snapshot, written inside
/// the avatar object as avatar.damage_taken[]. Each entry is the engine's OWN in-scope `source` + applied
/// `amount` read at the Character::apply_damage funnel (src/character.cpp) -- read-only observation,
/// native-authority class S (raw funnel state). It is recorded BEFORE the GUI's display filters and is
/// independent of both: the per-hit combat message masks the attacker name to "Something hits your %s." when
/// the avatar cannot see the attacker (src/monster.cpp melee_attack, !g->u.sees), and the on_hurt distraction
/// message is gated by painkiller/narcosis/disturb -- the funnel value is present regardless, so the frontend
/// renders its own (optionally perception-masked) message from this ground truth. This is the FUNNEL FACT,
/// NOT message-equivalence: NOT a hit/miss / damage-type / ranged-vs-melee / LOS-perception surface.
///
/// PURE serializer: it reads the already-captured `ctx.damage_taken` and NEVER drains the live session. The
/// drain happens at the snapshot's capture site WHILE the session is active (write_session_snapshot for
/// run-script/live; export_current_view before teardown for one-shot), and this array is the event window
/// since the previous snapshot, never a cumulative rollup. Purity is what makes one-shot and run-script
/// render the SAME array -- the original one-shot bug was draining HERE, after teardown wiped the buffer (so
/// the array was structurally empty). The lexical purity test (.agents/arcopolis_serializer_purity_test.ts)
/// pins that no write_* serializer drains the session.
auto write_damage_taken( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    json.member( "damage_taken" );
    json.start_array();
    for( const arcopolis::avatar_damage_record &rec : ctx.damage_taken ) {
        json.start_object();
        json.member( "source_kind", rec.source_kind );      // "monster" | "npc"
        json.member( "source_type_id", rec.source_type_id ); // monster type id; empty for an npc source
        json.member( "amount",
                     rec.amount );                // dam_to_bodypart actually applied (HP lost), > 0
        json.member( "bodypart",
                     rec.bodypart );            // the struck part the GUI names (apply_damage `hurt`)
        json.member( "hp_part",
                     rec.hp_part );              // the HP-pool part `amount` hit (hurt->main_part)
        json.member( "turn", rec.turn );                    // calendar turn at the funnel (== backend.turn)
        json.end_object();
    }
    json.end_array();
}

auto write_avatar( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    const auto pos_local = ctx.u.bub_pos();  // tripoint_bub_ms - reality-bubble milestone coords
    const auto pos_abs   = ctx.u.abs_pos();  // tripoint_abs_ms - absolute milestone coords

    json.member( "avatar" );
    json.start_object();
    json.member( "name", ctx.u.get_name() );

    json.member( "pos_local" );
    json.start_array();
    json.write( pos_local.x() );
    json.write( pos_local.y() );
    json.write( pos_local.z() );
    json.end_array();

    json.member( "pos_abs" );
    json.start_array();
    json.write( pos_abs.x() );
    json.write( pos_abs.y() );
    json.write( pos_abs.z() );
    json.end_array();

    json.member( "z", ctx.levz );
    json.member( "hp", ctx.u.get_hp() );            // sum across body parts
    json.member( "hp_max", ctx.u.get_hp_max() );
    json.member( "stamina", ctx.u.get_stamina() );
    json.member( "moves",
                 ctx.u.get_moves() );      // action points left this turn; explains turn advance
    json.member( "pain", ctx.u.get_pain() );
    json.member( "thirst", ctx.u.get_thirst() );
    json.member( "fatigue", ctx.u.get_fatigue() );
    json.member( "stored_kcal", ctx.u.get_stored_kcal() );
    json.member( "kcal_percent", ctx.u.get_kcal_percent() );  // float
    write_carried_items( json,
                         ctx );  // Spike 25: read-only top-level carried items (avatar.carried_items[])
    write_damage_taken( json,
                        ctx );  // Spike 27B: attacker-attributed damage events (captured pre-teardown)
    json.end_object();
}

auto write_map_bounds( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    const auto origin =
        ctx.m.get_abs_sub();        // point_abs_sm - absolute submap origin (2D since the
    // upstream absolute-coordinate / z-level migration; the bubble now always spans every z-level so abs_sub
    // carries no single z).
    const auto size = ctx.m.getmapsize() * SEEX;    // loaded bubble width in ms tiles (square)

    json.member( "map_bounds" );
    json.start_object();
    json.member( "origin_abs_sm" );
    json.start_array();
    json.write( origin.x() );
    json.write( origin.y() );
    // The origin submap's z is the z-level being exported: this snapshot is a single z-slice at the avatar's
    // level, so origin_abs_sm[z] == map_bounds "z" == every exported tile's z (all ctx.levz). Faithful
    // replacement for the now-removed abs_sub.z() (which, for the main map at the avatar, was that same level).
    json.write( ctx.levz );
    json.end_array();
    json.member( "size_x", size );
    json.member( "size_y", size );
    json.member( "z", ctx.levz );
    json.end_object();
}

auto write_tiles( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    const auto center = ctx.u.bub_pos();  // tripoint_bub_ms - window centre (reality-bubble coords)

    json.member( "tiles" );
    json.start_array();
    // points_in_radius yields a square (Chebyshev) window at a single z-level, in tripoint_bub_ms.
    for( const auto &p : points_in_radius( center, ctx.radius ) ) {  // p : tripoint_bub_ms
        if( !ctx.m.inbounds( p ) ) {
            continue;  // clamp the square window to the loaded bubble
        }
        json.start_object();
        json.member( "x", p.x() );
        json.member( "y", p.y() );
        json.member( "z", p.z() );
        json.member( "ter", ctx.m.ter( p ).id().str() );   // e.g. "t_floor"
        json.member( "furn", ctx.m.furn( p ).id().str() );  // e.g. "f_null"
        // pl_sees range-checks via square_dist (Chebyshev); radius == window radius rejects nothing
        // by range, so real light/LOS (from caches game::load built) decides visibility.
        json.member( "seen", ctx.m.pl_sees( p, ctx.radius ) );
        // The window is a single z-slice centred on the avatar, so exactly one tile is the avatar's.
        // Emit the marker only on that tile (additive: absent elsewhere) so a reader need not re-derive
        // it from avatar.pos_local. center == ctx.u.bub_pos(), the same coordinate write_avatar serializes.
        if( p == center ) {
            json.member( "is_avatar", true );
        }
        json.end_object();
    }
    json.end_array();
}

/// True if a reality-bubble point falls inside the exported view window: the SAME predicate
/// write_tiles applies (single z-slice, square center +/- radius mirroring points_in_radius, then
/// clamp to the loaded bubble). Shared by the monster and NPC filters so both windows are identical
/// to tiles[] by construction - every exported entity therefore sits on an exported tile.
auto in_export_window( const tripoint_bub_ms &p, const tripoint_bub_ms &center,
                       const snapshot_ctx &ctx ) -> bool
{
    return p.z() == center.z() &&
           p.x() >= center.x() - ctx.radius && p.x() <= center.x() + ctx.radius &&
           p.y() >= center.y() - ctx.radius && p.y() <= center.y() + ctx.radius &&
           ctx.m.inbounds( p );
}

auto write_entities( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    const auto center = ctx.u.bub_pos();  // tripoint_bub_ms - same window centre write_tiles uses

    json.member( "entities" );
    json.start_object();

    json.member( "monsters" );
    json.start_array();
    // The raw engine monster list: it includes hallucinations and friendly/ridden monsters, and
    // monsters outside the avatar's LOS - the GUI hides those at draw time, but the backend exports
    // authoritative state and flags hallucinations (the frontend owns any visibility policy). The
    // window filter (in_export_window) is identical to write_tiles, so every emitted monster's
    // pos_local equals an exported tile.
    auto monster_index = 0;
    for( const monster &mon : g->all_monsters() ) {
        const auto mp = mon.bub_pos();  // tripoint_bub_ms
        if( !in_export_window( mp, center, ctx ) ) {
            continue;
        }
        const auto ma = mon.abs_pos();  // tripoint_abs_ms

        json.start_object();
        json.member( "index", monster_index++ );  // export-local, 0-based, assigned post-filter
        json.member( "type_id", mon.type->id.str() );
        json.member( "name", mon.get_name() );
        json.member( "symbol", mon.symbol() );  // full display string (may be multi-byte)

        json.member( "pos_local" );
        json.start_array();
        json.write( mp.x() );
        json.write( mp.y() );
        json.write( mp.z() );
        json.end_array();

        json.member( "pos_abs" );
        json.start_array();
        json.write( ma.x() );
        json.write( ma.y() );
        json.write( ma.z() );
        json.end_array();

        json.member( "hp", mon.get_hp() );           // current sum across the monster's hp pool
        json.member( "hp_max", mon.get_hp_max() );
        json.member( "moves", mon.get_moves() );      // action points left this turn (mid-turn snapshot)
        json.member( "hallucination", mon.is_hallucination() );
        json.end_object();
    }
    json.end_array();

    // Spike 7A: nearby NPCs, beside monsters, in the IDENTICAL window (in_export_window) so every
    // exported NPC also sits on an exported tile. Source is g->all_npcs() - the active non-dead NPC
    // range (not pre-filtered to loaded/simulated; out-of-bubble NPCs fail the inbounds window check,
    // exactly as monsters do). The avatar is not in this list. v0 fields are conservative and
    // public-API-backed; deeper faction / dialogue / inventory / mission / opinion data and stable
    // persistent IDs are deferred. This is a read-only authoritative/debug export, NOT an interaction
    // surface - no NPC command (talk/attack/swap/push) is added here.
    json.member( "npcs" );
    json.start_array();
    auto npc_index = 0;
    for( const npc &np : g->all_npcs() ) {
        const auto np_local = np.bub_pos();  // tripoint_bub_ms
        if( !in_export_window( np_local, center, ctx ) ) {
            continue;
        }
        const auto np_abs = np.abs_pos();  // tripoint_abs_ms

        json.start_object();
        json.member( "index", npc_index++ );  // export-local, 0-based, assigned post-filter
        json.member( "name", np.get_name() );

        json.member( "pos_local" );
        json.start_array();
        json.write( np_local.x() );
        json.write( np_local.y() );
        json.write( np_local.z() );
        json.end_array();

        json.member( "pos_abs" );
        json.start_array();
        json.write( np_abs.x() );
        json.write( np_abs.y() );
        json.write( np_abs.z() );
        json.end_array();

        // Relationship flags (public const npc predicates): is_enemy = NPCATT_KILL/FLEE/FLEE_TEMP;
        // is_following = NPCATT_FOLLOW/WAIT; is_player_ally = is_ally(g->u); is_stationary = guarding
        // or a shelter/shopkeep/infected mission. These explain move-into-NPC semantics (see doc 15/18).
        json.member( "is_enemy", np.is_enemy() );
        json.member( "is_following", np.is_following() );
        json.member( "is_player_ally", np.is_player_ally() );
        json.member( "is_stationary", np.is_stationary() );
        json.member( "hallucination", np.is_hallucination() );
        json.end_object();
    }
    json.end_array();

    // Spike 8A: nearby GROUND items, beside monsters/npcs, in the IDENTICAL window (in_export_window) so
    // every exported item also sits on an exported tile. Unlike the entity blocks (which filter a global
    // engine list) this iterates the exported TILE window and reads each tile's ground-item stack via
    // map::i_at - the same public accessor look/pickup/examine use (pickup.cpp:1279, game.cpp:8770). i_at
    // returns ONLY top-level ground items (the submap's itm stack): NOT vehicle cargo (that is
    // vehicle::get_items, pickup.cpp:1293) and NOT items nested inside containers - both are naturally
    // excluded here and remain explicitly deferred. The stack is reached through the non-const get_map()
    // because map::i_at has no const overload (map.h:1692, "for safe modification"); every value is only
    // READ - no item is mutated, moved, or removed. This is a read-only authoritative export, NOT a
    // pickup/drop/use surface; avatar inventory, NPC inventory, vehicle cargo, and nested containers are
    // all deferred. v0 fields are conservative and public-API-backed.
    json.member( "items" );
    json.start_array();
    auto item_index = 0;
    for( const auto &p : points_in_radius( center,
                                           ctx.radius ) ) {  // p : tripoint_bub_ms, as write_tiles
        if( !in_export_window( p, center, ctx ) ) {
            continue;  // identical window to tiles[] - here only the inbounds clamp can reject a tile
        }
        const auto ia = bub_to_abs( p );  // tripoint_abs_ms - SAME conversion Creature::abs_pos uses
        for( const auto *const it : get_map().i_at(
                 p ) ) {  // ground stack; only get_map() for the accessor
            json.start_object();
            json.member( "index", item_index++ );  // export-local, 0-based, assigned post-filter
            json.member( "type_id", it->typeId().str() );
            json.member( "name", it->display_name() );  // look/pickup display name (item.h:495)
            json.member( "symbol", it->symbol() );  // type->sym glyph (item.h:606)

            json.member( "pos_local" );
            json.start_array();
            json.write( p.x() );
            json.write( p.y() );
            json.write( p.z() );
            json.end_array();

            json.member( "pos_abs" );
            json.start_array();
            json.write( ia.x() );
            json.write( ia.y() );
            json.write( ia.z() );
            json.end_array();

            // charges is only semantically meaningful when count_by_charges() is true (ammo/liquids/
            // stackables); for everything else a consumer should treat the item as a single unit.
            json.member( "charges", it->charges );
            json.member( "count_by_charges", it->count_by_charges() );
            json.end_object();
        }
    }
    json.end_array();

    json.end_object();
}

auto write_messages( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    // recent_messages() returns (time_of_day, text) pairs - message severity/type is NOT exposed by
    // this public API (verified in messages.cpp), so "type" is intentionally left blank and a
    // diagnostic is recorded rather than mislabeling the timestamp.
    const auto msgs = Messages::recent_messages( 10 );  // vector<pair<string,string>>

    json.member( "messages" );
    json.start_array();
    for( const auto &msg : msgs ) {
        json.start_object();
        json.member( "text", msg.second );
        json.member( "type", std::string{} );
        json.end_object();
    }
    json.end_array();

    if( !msgs.empty() ) {
        ctx.warnings.emplace_back(
            "message type/severity is not exposed by Messages::recent_messages "
            "(only time-of-day and text); 'type' left blank pending a backend accessor" );
    }
}

auto write_snapshot( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    json.start_object();
    json.member( "schema_version", 1 );
    write_session( json, ctx );  // Spike 2: present only for script-runner exports
    write_backend( json );
    write_avatar( json, ctx );
    write_map_bounds( json, ctx );
    write_tiles( json, ctx );
    write_entities( json,
                    ctx );  // Spike 6A/7A/8A: nearby monsters, NPCs, ground items in the tiles window
    write_messages( json, ctx );  // may push to ctx.warnings - must precede diagnostics

    json.member( "diagnostics" );
    json.start_object();
    json.member( "warnings" );
    json.start_array();
    for( const auto &w : ctx.warnings ) {
        json.write( w );
    }
    json.end_array();
    json.end_object();

    json.end_object();
}

} // namespace

auto arcopolis::export_current_view( const export_current_view_options &opts ) -> int
{
    if( opts.world.empty() ) {
        std::cerr << "arcopolis: --arcopolis-export-current-view requires --world <name>\n";
        return 1;
    }

    // A command run always exports its result, so it needs a snapshot output path.
    if( !opts.command_path.empty() && opts.output_path.empty() ) {
        std::cerr << "arcopolis: --arcopolis-command requires --arcopolis-export-current-view <path>\n";
        return 1;
    }

    init_colors();  // mirror the other headless flows; the world-load path may colorize output

    if( !g->load( opts.world ) ) {
        std::cerr << "arcopolis: failed to load world '" << opts.world << "'\n";
        return 1;
    }

    // Captured BEFORE end_backend_session() wipes the session: the bootstrap turn's attacker-attributed
    // damage events. write_current_view (below) serializes this copy. Without this capture-before-teardown
    // the one-shot snapshot's avatar.damage_taken[] was structurally always-empty (the drain ran after the
    // session was cleared). Stays empty unless a command runs and the avatar takes attributed damage.
    std::vector<arcopolis::avatar_damage_record> damage_taken;

    // Spike 1, now Spike 3.1A: optionally apply exactly one backend command between load and export, but
    // through the SAME input seam the script runner uses -- no `command -> do_turn` inversion. The command
    // executes at handle_action() during one bootstrap do_turn (AFTER that turn's top half); then we
    // export the result. Errors map to distinct nonzero exit codes (see arcopolis::exit_code_for).
    if( !opts.command_path.empty() ) {
        const auto cmd = read_command_file( opts.command_path );
        if( !cmd ) {
            std::cerr << "arcopolis: " << cmd.error().detail << "\n";
            return exit_code_for( cmd.error().kind );
        }
        // Non-live FAIL LOUD for promptful commands: a live-only command (e.g. pickup) needs a prompt
        // answer channel this one-shot mode does not have, so it would only auto-cancel and falsely
        // report success. Reject it before driving a turn rather than silently no-op it (docs/arcopolis/31).
        if( is_live_only_command( cmd->command ) ) {
            std::cerr << "arcopolis: command '" << cmd->command <<
                      "' requires --arcopolis-live (its in-action menu needs a live prompt answer channel; "
                      "it is not supported in script/one-shot mode)\n";
            return exit_code_for( command_error_kind::unsupported_command );
        }
        // Pre-flight: reject an unsupported verb / bad direction before driving a turn.
        const auto resolved = command_to_action( *cmd );
        if( !resolved ) {
            std::cerr << "arcopolis: " << resolved.error().detail << "\n";
            return exit_code_for( resolved.error().kind );
        }
        // Same fidelity guard as the script runner: real-time moves would drain the avatar by wall-clock
        // through handle_action()'s moves_elapsed() charge (~handle_action.cpp:2866). It is 0 only here.
        if( get_option<float>( "TURN_DURATION" ) > 0.005f ) {
            std::cerr << "arcopolis: TURN_DURATION must be <= 0.005 for headless runs (real-time moves "
                      "would drain the avatar by wall-clock); set it to 0 in the world's options\n";
            return exit_code_for( command_error_kind::apply_failed );
        }
        // One bootstrap do_turn with the command as the seam's input: the provider feeds its action_id at
        // handle_action() and the engine's switch dispatches it. A single do_turn leaves the calendar at
        // the loaded bootstrap turn T -- exactly as pressing the key once right after loading would.
        begin_backend_session( {
            .steps = { { .op = "command", .command = cmd->command, .direction = cmd->direction } },
        } );
        g->do_turn();
        // Spike 20 FAIL LOUD: if the command reached an UNARMED player-visible prompt during do_turn (a
        // query_yn etc. that would silently test_mode-default to NO/CANCEL), backend_report_unexpected_prompt
        // recorded a fatal failure. Surface it as the exit code HERE -- BEFORE the success snapshot below --
        // so a hidden lost interaction never produces success-looking output (amendment 3). One-shot arms no
        // prompt transaction, so e.g. an `examine` of deployed furniture (which raises query_yn) fails loud
        // here rather than silently answering NO. Capture before end_backend_session() clears the state.
        damage_taken = backend_take_avatar_damage_taken();  // capture the turn's events BEFORE teardown
        backend_assert_event_buffers_drained();             // G2: every registered event buffer now empty
        const auto prompt_failure = backend_session_failure();
        end_backend_session();
        if( prompt_failure ) {
            std::cerr << "arcopolis: " << prompt_failure->detail << "\n";
            return exit_code_for( prompt_failure->kind );
        }
    }

    if( !write_current_view( opts.output_path, std::nullopt, std::move( damage_taken ) ) ) {
        std::cerr << "arcopolis: failed to write snapshot to '" << opts.output_path << "'\n";
        return 1;
    }

    return 0;
}

auto arcopolis::write_current_view( const std::string &output_path,
                                    const std::optional<snapshot_session_info> &session,
                                    std::vector<avatar_damage_record> damage_taken ) -> bool
{
    std::vector<std::string> warnings;
    const auto ctx = snapshot_ctx{
        .u = get_avatar(),
        .m = get_map(),
        .levz = g->get_levz(),
        .radius = arcopolis_view_radius,
        .warnings = warnings,
        .session = session,
        .damage_taken = std::move( damage_taken ),
    };

    return write_to_file( output_path, [&]( auto & stream ) {
        JsonOut json( stream, /*pretty_print=*/true );
        write_snapshot( json, ctx );
    }, "arcopolis snapshot" );
}

auto arcopolis::current_snapshot_summary() -> snapshot_summary
{
    const auto &u = get_avatar();
    const auto pos_abs = u.abs_pos();  // tripoint_abs_ms - the same accessor write_avatar() serializes
    return snapshot_summary{
        .turn = to_turn<int>( calendar::turn ),  // matches write_backend()'s "turn"
        .pos_abs_x = pos_abs.x(),
        .pos_abs_y = pos_abs.y(),
        .pos_abs_z = pos_abs.z(),
        .moves = u.get_moves(),  // matches write_avatar()'s "moves"
    };
}
