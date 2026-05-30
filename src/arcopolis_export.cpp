#include "arcopolis_export.h"

#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include "avatar.h"          // avatar, get_avatar()
#include "character.h"       // get_name/thirst/fatigue/stamina/kcal getters
#include "color.h"           // init_colors()
#include "coordinates.h"     // tripoint_bub_ms / _abs_ms / _abs_sm, .x()/.y()/.z()
#include "creature.h"        // get_hp/get_hp_max/get_pain
#include "fstream_utils.h"   // write_to_file()
#include "game.h"            // g, game::load(world), get_levz(), savegame_version
#include "game_constants.h"  // SEEX
#include "get_version.h"     // getVersionString()
#include "json.h"            // JsonOut
#include "map.h"             // get_map(), ter/furn/pl_sees/inbounds/getmapsize/get_abs_sub
#include "map_iterator.h"    // points_in_radius()
#include "messages.h"        // Messages::recent_messages()
#include "type_id.h"         // ter_id/furn_id -> .id().str()

namespace
{

/// Conservative half-width (tiles) of the square window exported around the avatar. The full loaded
/// reality bubble is ~132x132 (getmapsize()*SEEX); 12 keeps Spike 0 snapshots small but real.
constexpr int arcopolis_view_radius = 12;

/// Read-only bundle passed to each writer (keeps every writer at <=3 params per AGENTS).
struct snapshot_ctx {
    const avatar &u;                     //< read-only avatar state
    const map &m;                        //< read-only loaded reality bubble
    int levz;                            //< current z-level (game::get_levz())
    int radius;                          //< half-width of the exported square tile window
    std::vector<std::string> &warnings;  //< diagnostics accumulator (referent is mutable)
};

auto write_backend( JsonOut &json ) -> void
{
    json.member( "backend" );
    json.start_object();
    json.member( "game_version", std::string( getVersionString() ) );
    json.member( "save_version", savegame_version );
    json.end_object();
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
    json.member( "pain", ctx.u.get_pain() );
    json.member( "thirst", ctx.u.get_thirst() );
    json.member( "fatigue", ctx.u.get_fatigue() );
    json.member( "stored_kcal", ctx.u.get_stored_kcal() );
    json.member( "kcal_percent", ctx.u.get_kcal_percent() );  // float
    json.end_object();
}

auto write_map_bounds( JsonOut &json, const snapshot_ctx &ctx ) -> void
{
    const auto origin = ctx.m.get_abs_sub();        // tripoint_abs_sm - absolute submap coords
    const auto size = ctx.m.getmapsize() * SEEX;    // loaded bubble width in ms tiles (square)

    json.member( "map_bounds" );
    json.start_object();
    json.member( "origin_abs_sm" );
    json.start_array();
    json.write( origin.x() );
    json.write( origin.y() );
    json.write( origin.z() );
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
        json.end_object();
    }
    json.end_array();
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
    write_backend( json );
    write_avatar( json, ctx );
    write_map_bounds( json, ctx );
    write_tiles( json, ctx );
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

    init_colors();  // mirror the other headless flows; the world-load path may colorize output

    if( !g->load( opts.world ) ) {
        std::cerr << "arcopolis: failed to load world '" << opts.world << "'\n";
        return 1;
    }

    std::vector<std::string> warnings;
    const auto ctx = snapshot_ctx{
        .u = get_avatar(),
        .m = get_map(),
        .levz = g->get_levz(),
        .radius = arcopolis_view_radius,
        .warnings = warnings,
    };

    const auto ok = write_to_file( opts.output_path, [&]( std::ostream & stream ) {
        JsonOut json( stream, /*pretty_print=*/true );
        write_snapshot( json, ctx );
    }, "arcopolis snapshot" );

    if( !ok ) {
        std::cerr << "arcopolis: failed to write snapshot to '" << opts.output_path << "'\n";
        return 1;
    }

    return 0;
}
