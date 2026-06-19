#include "arcopolis_command.h"

#include <algorithm>
#include <array>
#include <string>
#include <string_view>
#include <utility>

#include "action.h"          // look_up_action(), action_id, ACTION_PAUSE
#include "filesystem.h"      // file_exist()
#include "fstream_utils.h"   // cata_ifstream, cata_ios_mode
#include "json.h"            // JsonIn, JsonObject, JsonError

namespace
{

using namespace std::string_view_literals;

/// The only command schema this spike understands.
constexpr auto arcopolis_command_schema_version = 1;

/// The `examine`/`pickup` verbs' planar direction vocabulary: each protocol token -> the input-context
/// ACTION ID the engine's direction chooser (`choose_direction`, src/action.cpp) consumes. These are
/// exactly the EIGHT planar directions `register_directions()` registers (src/input.cpp:1010-1017:
/// UP/DOWN/LEFT/RIGHT + LEFTUP/LEFTDOWN/RIGHTUP/RIGHTDOWN) plus "pause" for the self/current tile --
/// the complete set of TARGETS a GUI player can pick at "Examine where?" / "Pickup where?" with
/// `allow_vertical=false` (game::examine and game::pickup both pass false, src/game.cpp:8532-8534,
/// :8763-8765, so vertical LEVEL_UP/LEVEL_DOWN are excluded). The diagonal compass->action pairings are
/// verified against `get_direction` (src/input.cpp:1077-1084, screen convention north=-y/east=+x):
/// move_ne->"RIGHTUP" (north_east), move_nw->"LEFTUP" (north_west), move_se->"RIGHTDOWN" (south_east),
/// move_sw->"LEFTDOWN" (south_west). No iso rotation applies headless (get_direction rotates only under
/// iso_mode && tile_iso && use_tiles, and tile_iso is set exclusively at tileset load, which never runs
/// in the --arcopolis-* modes; docs/arcopolis/25 design point 4), so the mapping is plain. Single source
/// of truth: is_supported_target_direction() and target_direction_nested_answer() both derive from this
/// table, so they can never disagree. Shared by `examine` (Spike 11A) and `pickup` (Spike 12A).
constexpr std::array<std::pair<std::string_view, std::string_view>, 9> target_direction_answers
= { {
        { "move_n"sv, "UP"sv },
        { "move_s"sv, "DOWN"sv },
        { "move_e"sv, "RIGHT"sv },
        { "move_w"sv, "LEFT"sv },
        { "move_ne"sv, "RIGHTUP"sv },
        { "move_nw"sv, "LEFTUP"sv },
        { "move_se"sv, "RIGHTDOWN"sv },
        { "move_sw"sv, "LEFTDOWN"sv },
        { "here"sv, "pause"sv },
    }
};

} // namespace

auto arcopolis::is_supported_move_direction( std::string_view ident ) -> bool
{
    using namespace std::string_view_literals;
    namespace ranges = std::ranges;
    // The EIGHT planar move directions a BN GUI player can step -- the four cardinals plus the four
    // diagonals -- exactly the set the engine's shared planar-move case dispatches. look_up_action()
    // resolves all eight to the matching ACTION_MOVE_* (cardinals -> FORTH/BACK/LEFT/RIGHT, diagonals
    // -> FORTH_RIGHT/FORTH_LEFT/BACK_RIGHT/BACK_LEFT), and handle_action()'s switch routes every one
    // through the SAME avatar_action::move body (src/handle_action.cpp), so the diagonals are as
    // faithful as the cardinals -- this membership check is purely the vocabulary gate. VERTICAL
    // (move_up/move_down) is intentionally excluded: it dispatches the separate ACTION_MOVE_UP/DOWN ->
    // game::vertical_move primitive (stairs/ropes/climb), a different command, not a planar step.
    static constexpr std::array planar = {
        "move_n"sv, "move_s"sv, "move_e"sv, "move_w"sv,
        "move_ne"sv, "move_nw"sv, "move_se"sv, "move_sw"sv
    };
    return ranges::contains( planar, ident );
}

auto arcopolis::is_supported_target_direction( std::string_view ident ) -> bool
{
    namespace ranges = std::ranges;
    // The eight planar directions the GUI adjacent chooser registers, plus "here" (the self tile). A
    // direction is supported iff it maps to a chooser action -- so this and target_direction_nested_answer()
    // share the one table and cannot drift apart. Vertical (move_up/move_down) is excluded because
    // game::examine / game::pickup pass allow_vertical=false; movement diagonals being rejected by `move`
    // is a SEPARATE verb's limitation (is_supported_move_direction), not the target chooser's.
    return ranges::contains( target_direction_answers, ident,
                             &std::pair<std::string_view, std::string_view>::first );
}

auto arcopolis::target_direction_nested_answer( std::string_view direction ) ->
std::optional<std::string>
{
    namespace ranges = std::ranges;
    const auto it = ranges::find( target_direction_answers, direction,
                                  &std::pair<std::string_view, std::string_view>::first );
    if( it == target_direction_answers.end() ) {
        return std::nullopt;
    }
    return std::string( it->second );
}

auto arcopolis::is_live_only_command( std::string_view command ) -> bool
{
    // Only `pickup` needs the live prompt_source to complete its core action (the item-selection menu).
    // Keep this an explicit list, not a default-true, so a new verb is non-live by default and is added
    // here deliberately when (and only when) it requires a live answer channel.
    return command == "pickup";
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
                                                               "' (expected " + expected_move_directions + ")" } );
            }
        } else if( command == "examine" ) {
            if( !obj.has_string( "direction" ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "command 'examine' requires a string 'direction'" } );
            }
            direction = obj.get_string( "direction" );
            if( !is_supported_target_direction( direction ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "unsupported examine direction '" + direction +
                                                               "' (expected " + expected_target_directions + ")" } );
            }
        } else if( command == "pickup" ) {
            if( !obj.has_string( "direction" ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "command 'pickup' requires a string 'direction'" } );
            }
            direction = obj.get_string( "direction" );
            if( !is_supported_target_direction( direction ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                       .detail = "unsupported pickup direction '" + direction +
                                                               "' (expected " + expected_target_directions + ")" } );
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

auto arcopolis::command_to_action( const backend_command &cmd ) ->
std::expected<action_id, command_error>
{
    // FIDELITY (Spike 3.1): resolve the command to the engine action_id the GUI's input switch would
    // dispatch, and stop there. The engine's switch( act ) in handle_action() runs the action at the
    // faithful input-loop slot (after the turn's top half) -- the backend never calls avatar_action::move
    // / do_pause / do_turn itself. See docs/arcopolis/09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md.
    if( cmd.command == "wait" ) {
        // The '.' key: handle_action()'s ACTION_PAUSE case gates safe mode then calls do_pause.
        return ACTION_PAUSE;
    }
    if( cmd.command == "move" ) {
        // Defense in depth: the parsers already reject non-planar directions as bad_schema, but
        // command_to_action is also reachable directly (and from tests), so re-validate before resolving.
        if( !is_supported_move_direction( cmd.direction ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported move direction '" + cmd.direction +
                                                           "' (expected " + expected_move_directions + ")" } );
        }
        // ident -> action_id the engine's own way (e.g. "move_e" -> ACTION_MOVE_RIGHT, "move_ne" ->
        // ACTION_MOVE_FORTH_RIGHT). The switch then computes the delta via get_delta_from_movement_action
        // and calls avatar_action::move -- the same shared body for cardinals and diagonals alike.
        return look_up_action( cmd.direction );
    }
    if( cmd.command == "examine" ) {
        // Same defense in depth as "move": parsers already reject bad directions, but command_to_action
        // is also reachable directly (and from tests).
        if( !is_supported_target_direction( cmd.direction ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported examine direction '" + cmd.direction +
                                                           "' (expected " + expected_target_directions + ")" } );
        }
        // The 'e' key: handle_action()'s ACTION_EXAMINE case calls the engine's own prompting examine()
        // overload. The direction is NOT part of the action_id -- it is armed as the one-shot
        // nested-input answer, served only if the engine's chooser actually asks (Spike 11A).
        return ACTION_EXAMINE;
    }
    if( cmd.command == "pickup" ) {
        // Same defense in depth: validate the "Pickup where?" direction (the same allow_vertical=false
        // choose_adjacent_highlight chooser examine uses, src/game.cpp:8761-8765). The direction is the
        // one-shot nested-input answer for THAT chooser; the item-selection MENU that follows is driven by
        // the Spike 12A pickup-prompt transaction (registered PICKUP actions fed through the real
        // input_context("PICKUP") loop) wherever an answer channel exists: LIVE mode (the stdin client) and,
        // since Spike 16, --arcopolis-run-script when the step DECLARES prompt_answers (next_backend_action
        // arms the transaction + installs the script prompt sources). A one-shot --arcopolis-command pickup
        // has no answer channel and is rejected pre-flight (is_live_only_command -> unsupported_command).
        // NEW_PICKUP_MENU=true routes to the inventory_selector instead and is rejected too; see the
        // inventory_selector audit, docs/arcopolis/39_SPIKE18_NEW_PICKUP_MENU_AUDIT.md.
        if( !is_supported_target_direction( cmd.direction ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported pickup direction '" + cmd.direction +
                                                           "' (expected " + expected_target_directions + ")" } );
        }
        // The 'g' key: handle_action()'s ACTION_PICKUP case calls game::pickup() (the chooser overload).
        return ACTION_PICKUP;
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
        case command_error_kind::backend_stalled:
            return 10;
        case command_error_kind::game_over:
            return 11;
        case command_error_kind::nested_input_failed:
            return 12;
        case command_error_kind::script_prompt_failed:
            return 13;
    }
    return 1;  // unreachable; defensive default
}
