#include "arcopolis_command.h"

#include <string>
#include <utility>

#include "avatar.h"          // get_avatar()
#include "character.h"       // Character (do_pause parameter type)
#include "character_turn.h"  // character_funcs::do_pause()
#include "filesystem.h"      // file_exist()
#include "fstream_utils.h"   // cata_ifstream, cata_ios_mode
#include "game.h"            // g, game::do_turn()
#include "json.h"            // JsonIn, JsonObject, JsonError

namespace
{

/// The only command schema this spike understands.
constexpr int arcopolis_command_schema_version = 1;

} // namespace

auto arcopolis::parse_command( std::istream &stream )
-> std::expected<backend_command, command_error>
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
        return backend_command{ .schema_version = version, .command = obj.get_string( "command" ) };
    } catch( const JsonError &err ) {
        return std::unexpected( command_error{ .kind = command_error_kind::invalid_json,
                                .detail = std::string( "invalid JSON: " ) + err.what() } );
    }
}

auto arcopolis::read_command_file( const std::string &path )
-> std::expected<backend_command, command_error>
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
    }
    return 1;  // unreachable; defensive default
}
