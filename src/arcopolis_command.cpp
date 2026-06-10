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

/// The only command schema this spike understands.
constexpr auto arcopolis_command_schema_version = 1;

} // namespace

auto arcopolis::is_supported_move_direction( std::string_view ident ) -> bool
{
    using namespace std::string_view_literals;
    namespace ranges = std::ranges;
    // The four cardinals this spike supports. look_up_action() also resolves diagonals and vertical
    // moves, so this cardinal-set membership check is what actually rejects move_ne.../move_up/move_down.
    static constexpr std::array cardinals = { "move_n"sv, "move_s"sv, "move_e"sv, "move_w"sv };
    return ranges::contains( cardinals, ident );
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
        // Defense in depth: the parsers already reject non-cardinals as bad_schema, but command_to_action
        // is also reachable directly (and from tests), so re-validate before resolving.
        if( !is_supported_move_direction( cmd.direction ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                   .detail = "unsupported move direction '" + cmd.direction +
                                                           "' (expected move_n/move_s/move_e/move_w)" } );
        }
        // ident -> action_id the engine's own way (e.g. "move_e" -> ACTION_MOVE_RIGHT). The switch then
        // computes the delta via get_delta_from_movement_action and calls avatar_action::move.
        return look_up_action( cmd.direction );
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
    }
    return 1;  // unreachable; defensive default
}
