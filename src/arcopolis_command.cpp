#include "arcopolis_command.h"

#include <algorithm>
#include <array>
#include <string>
#include <string_view>
#include <utility>

#include "action.h"          // look_up_action(), get_delta_from_movement_action(), iso_rotate
#include "avatar.h"          // get_avatar()
#include "avatar_action.h"   // avatar_action::move()
#include "character.h"       // Character (do_pause parameter type)
#include "character_turn.h"  // character_funcs::do_pause()
#include "filesystem.h"      // file_exist()
#include "fstream_utils.h"   // cata_ifstream, cata_ios_mode
#include "game.h"            // g, game::do_turn(), check_safe_mode_allowed()
#include "json.h"            // JsonIn, JsonObject, JsonError
#include "map.h"             // get_map()

namespace
{

/// The only command schema this spike understands.
constexpr int arcopolis_command_schema_version = 1;

} // namespace

auto arcopolis::is_supported_move_direction( std::string_view ident ) -> bool
{
    using namespace std::string_view_literals;
    // The four cardinals this spike supports. look_up_action() also resolves diagonals and vertical
    // moves, so this cardinal-set membership check is what actually rejects move_ne.../move_up/move_down.
    static constexpr std::array cardinals = { "move_n"sv, "move_s"sv, "move_e"sv, "move_w"sv };
    return std::ranges::contains( cardinals, ident );
}

auto arcopolis::parse_command( std::istream &stream ) ->
std::expected<backend_command, command_error>
{
    try {
        JsonIn json( stream );
        auto obj = json.get_object();
        // We read only the fields we care about and may return early on a bad schema; tell the strict
        // JSON reader not to flag other/unread members as unvisited (it logs an error otherwise, which
        // BN's test harness treats as a failure, and which would also appear in the binary's stderr).
        obj.allow_omitted_members();

        if( !obj.has_int( "schema_version" ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "missing or non-integer 'schema_version'" } );
        }
        const auto version = obj.get_int( "schema_version" );
        if( version != arcopolis_command_schema_version ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported schema_version " + std::to_string( version ) +
                                                           " (expected " + std::to_string( arcopolis_command_schema_version ) + ")" } );
        }
        if( !obj.has_string( "command" ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "missing or non-string 'command'" } );
        }
        const auto command = obj.get_string( "command" );
        std::string direction;
        if( command == "move" ) {
            if( !obj.has_string( "direction" ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "command 'move' requires a string 'direction'" } );
            }
            direction = obj.get_string( "direction" );
            if( !is_supported_move_direction( direction ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "unsupported move direction '" + direction +
                                                               "' (expected move_n/move_s/move_e/move_w)" } );
            }
        }
        return backend_command{ .schema_version = version, .command = command, .direction = direction };
    } catch( const JsonError &err ) {
        return std::unexpected( command_error{ .kind = command_error_kind::invalid_json,
                                               .detail = std::string( "invalid JSON: " ) + err.what() } );
    }
}

auto arcopolis::read_command_file( const std::string &path ) ->
std::expected<backend_command, command_error>
{
    if( !file_exist( path ) ) {
        return std::unexpected( command_error{ .kind = command_error_kind::missing_file,
                                               .detail = "command file does not exist: " + path } );
    }

    auto stream = std::move( cata_ifstream().mode( cata_ios_mode::binary ).open( path ) );
    if( !stream.is_open() ) {
        return std::unexpected( command_error{ .kind = command_error_kind::unreadable_file,
                                               .detail = "could not open command file: " + path } );
    }

    return parse_command( *stream );
}

auto arcopolis::apply_command( const backend_command &cmd ) -> std::expected<void, command_error>
{
    if( cmd.command == "wait" ) {
        // FIDELITY PRINCIPLE: the GUI behavior is the engine behavior is the behavior, period. There is
        // no separate "headless mode" to invent — we reproduce exactly what BN does for this action, and
        // we never override engine state to make the output look nicer.
        //
        // What BN does for a wait right after a load: game::setup() (run by g->load) leaves
        // game::new_game == true, so the FIRST do_turn() takes the `if( new_game )` branch and
        // deliberately SKIPS `calendar::turn += 1_turns` (game.cpp:1879). That bootstrap turn processes
        // the world AT the loaded turn T and does NOT advance the clock; pressing '.' once in the GUI
        // right after loading does exactly this. So we honor it: we do NOT clear new_game. (An earlier
        // version cleared it to force a tick, which processed the turn at T+1 — one tick ahead of the
        // engine. That was wrong. See AGENTS.md "Arcopolis backend fidelity" and
        // docs/arcopolis/05_SPIKE1_WAIT_COMMAND.md.)
        //
        // Consequence: on the one-shot (load-per-command) lifecycle the calendar stays at T after a
        // single wait, exactly as the engine's first post-load turn. Per-command clock advance is a
        // property of a PERSISTENT backend (load once -> bootstrap turn happens once -> every later
        // command is a normal, clock-advancing turn). It must come from the right lifecycle, never from
        // faking engine flags here.

        // Mirror the GUI's ACTION_PAUSE safe-mode gate (src/handle_action.cpp:1892): pressing '.' only
        // pauses when check_safe_mode_allowed() is true. Under a laser lock or a new visible threat
        // (SAFE_MODE_STOP) it returns false and the GUI neither pauses nor advances the turn — it warns
        // and leaves the avatar in control. We honor that: decline the wait without advancing the world.
        // check_safe_mode_allowed() is headless-safe (only add_msg / press_x; no popups or queries).
        // (Limitation: the per-turn threat scan mon_info_update runs *inside* do_turn and is private, so a
        // threat first becoming visible this turn isn't pre-assessed here — the gate uses the loaded
        // safe-mode / laser-lock state. Persistent-backend integration would close that gap.)
        if( !g->check_safe_mode_allowed() ) {
            return std::unexpected( command_error{ .kind = command_error_kind::safe_mode_blocked,
                                                   .detail = "wait declined by safe mode (a threat is flagged); the GUI would "
                                                           "warn and not advance the turn either" } );
        }
        // The real ACTION_PAUSE mechanism (the '.' key): zero the avatar's moves and run the
        // pause/trap/wait effects (character_funcs::do_pause, src/character_turn.cpp).
        character_funcs::do_pause( get_avatar() );
        // Advance one turn through the engine's own path. moves == 0 means do_turn()'s input loop (and
        // its blocking handle_action()) is skipped; everything else runs exactly as the engine's turn.
        g->do_turn();
        return {};
    }
    if( cmd.command == "move" ) {
        // FIDELITY PRINCIPLE (AGENTS.md): reproduce exactly what BN does when a movement key is pressed.
        // Defense in depth: parse_command / parse_script already reject a non-cardinal direction as
        // bad_schema, but apply_command is also reachable directly (and from tests), so re-validate.
        if( !is_supported_move_direction( cmd.direction ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported move direction '" + cmd.direction +
                                                           "' (expected move_n/move_s/move_e/move_w)" } );
        }
        // Same safe-mode gate the GUI movement keys honor (avatar_action::move re-checks it internally
        // too): under a laser lock / new visible threat the GUI warns and does not move, so we decline
        // without touching the world. check_safe_mode_allowed() is headless-safe (no popups/queries).
        if( !g->check_safe_mode_allowed() ) {
            return std::unexpected( command_error{ .kind = command_error_kind::safe_mode_blocked,
                                                   .detail = "move declined by safe mode (a threat is flagged); the GUI "
                                                           "would warn and not move either" } );
        }
        // Resolve the cardinal the engine's own way: ident -> action_id -> delta. iso_rotate::no because
        // headless test_mode loads no tileset (iso rotation only applies when use_tiles && tile_iso).
        const auto action = look_up_action( cmd.direction );
        const auto delta = get_delta_from_movement_action( action, iso_rotate::no );
        // The faithful GUI movement entry point — exactly what handle_action()'s ACTION_MOVE_* cases
        // call. Its bool means "auto-move not cancelled", NOT "did move" (docs/arcopolis/07), so we do
        // not branch on it; whether the avatar moved is observable via the exported avatar.pos_abs, and
        // avatar.moves shows whether this step consumed the turn.
        avatar_action::move( get_avatar(), get_map(), delta );
        // KNOWN DEFECT (Spike 3 FAILED — see docs/arcopolis/08_SPIKE3_MOVE_COMMAND.md): this is
        // `action -> do_turn`, which INVERTS the engine's order. The GUI runs the action *inside*
        // do_turn at handle_action() (game.cpp:2004), AFTER that turn's top half; here the action runs
        // before do_turn's top half, so from the 2nd turn on the action is evaluated one top-half early.
        // The guard below matches the engine's input-loop exit (`while( u.moves > 0 )`, game.cpp:1980)
        // and avoids the blocking headless handle_action() loop, but it does NOT make the turn structure
        // faithful. The fix (Spike 3.1) is to drive `while(!g->do_turn())` and inject the command at the
        // handle_action() seam instead of calling do_turn after the action.
        if( get_avatar().moves <= 0 ) {
            g->do_turn();
        }
        return {};
    }
    return std::unexpected( command_error{ .kind = command_error_kind::unsupported_command,
                                           .detail = "unsupported command: '" + cmd.command + "'" } );
}

auto arcopolis::exit_code_for( command_error_kind kind ) -> int
{
    switch( kind ) {
        case command_error_kind::missing_file:
            return 2;
        case command_error_kind::unreadable_file:
            return 3;
        case command_error_kind::invalid_json:
            return 4;
        case command_error_kind::bad_schema:
            return 5;
        case command_error_kind::unsupported_command:
            return 6;
        case command_error_kind::apply_failed:
            return 7;
        case command_error_kind::safe_mode_blocked:
            return 8;
        case command_error_kind::export_failed:
            return 9;
    }
    return 1;  // unreachable; defensive default
}
