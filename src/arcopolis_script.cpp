#include "arcopolis_script.h"

#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "arcopolis_command.h"  // backend_command, apply_command, command_error, exit_code_for
#include "arcopolis_export.h"   // write_current_view, snapshot_session_info
#include "color.h"              // init_colors()
#include "filesystem.h"         // assure_dir_exist(), ensure_valid_file_name(), file_exist()
#include "fstream_utils.h"      // cata_ifstream, cata_ios_mode
#include "game.h"               // g, game::load(world)
#include "json.h"               // JsonIn, JsonObject, JsonArray, JsonError
#include "string_formatter.h"   // string_format()

namespace
{

/// The only step-script schema this spike understands.
constexpr int arcopolis_script_schema_version = 1;

} // namespace

auto arcopolis::parse_script( std::istream &stream )
-> std::expected<std::vector<script_step>, command_error>
{
    try {
        JsonIn json( stream );
        JsonObject obj = json.get_object();
        // We read only the fields we care about and may return early on a bad schema; tell the strict
        // JSON reader not to flag other/unread members as unvisited (it logs an error otherwise, which
        // BN's test harness treats as a failure, and which would also appear on the binary's stderr).
        obj.allow_omitted_members();

        if( !obj.has_int( "schema_version" ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                    .detail = "missing or non-integer 'schema_version'" } );
        }
        const auto version = obj.get_int( "schema_version" );
        if( version != arcopolis_script_schema_version ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                    .detail = "unsupported schema_version " + std::to_string( version ) +
                                            " (expected " + std::to_string( arcopolis_script_schema_version ) + ")" } );
        }
        if( !obj.has_array( "steps" ) ) {
            return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                    .detail = "missing or non-array 'steps'" } );
        }

        std::vector<script_step> steps;
        JsonArray arr = obj.get_array( "steps" );
        int idx = 0;
        while( arr.has_more() ) {
            JsonObject e = arr.next_object();
            e.allow_omitted_members();
            const auto at = "steps[" + std::to_string( idx ) + "]: ";
            if( !e.has_string( "op" ) ) {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                        .detail = at + "missing or non-string 'op'" } );
            }
            const auto op = e.get_string( "op" );
            if( op == "export" ) {
                const auto name = e.has_string( "name" ) ? e.get_string( "name" ) : std::string{};
                steps.push_back( script_step{ .op = op, .name = name } );
            } else if( op == "command" ) {
                if( !e.has_string( "command" ) ) {
                    return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                            .detail = at + "op 'command' requires a string 'command'" } );
                }
                const auto command = e.get_string( "command" );
                std::string direction;
                if( command == "move" ) {
                    if( !e.has_string( "direction" ) ) {
                        return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                .detail = at + "command 'move' requires a string 'direction'" } );
                    }
                    direction = e.get_string( "direction" );
                    if( !is_supported_move_direction( direction ) ) {
                        return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                                .detail = at + "unsupported move direction '" + direction +
                                                        "' (expected move_n/move_s/move_e/move_w)" } );
                    }
                }
                steps.push_back( script_step{ .op = op, .command = command, .direction = direction } );
            } else {
                return std::unexpected( command_error{ .kind = command_error_kind::bad_schema,
                                        .detail = at + "unknown op '" + op + "' (expected 'export' or 'command')" } );
            }
            ++idx;
        }
        return steps;
    } catch( const JsonError &err ) {
        return std::unexpected( command_error{ .kind = command_error_kind::invalid_json,
                                .detail = std::string( "invalid JSON: " ) + err.what() } );
    }
}

auto arcopolis::read_script_file( const std::string &path )
-> std::expected<std::vector<script_step>, command_error>
{
    if( !file_exist( path ) ) {
        return std::unexpected( command_error{ .kind = command_error_kind::missing_file,
                                .detail = "script file does not exist: " + path } );
    }

    auto stream = std::move( cata_ifstream().mode( cata_ios_mode::binary ).open( path ) );
    if( !stream.is_open() ) {
        return std::unexpected( command_error{ .kind = command_error_kind::unreadable_file,
                                .detail = "could not open script file: " + path } );
    }

    return parse_script( *stream );
}

auto arcopolis::run_script( const run_script_options &opts ) -> int
{
    if( opts.world.empty() ) {
        std::cerr << "arcopolis: --arcopolis-run-script requires --world <name>\n";
        return 1;
    }
    if( opts.script_path.empty() ) {
        std::cerr << "arcopolis: --arcopolis-run-script requires a <script_path>\n";
        return 1;
    }
    if( opts.export_dir.empty() ) {
        std::cerr << "arcopolis: --arcopolis-run-script requires --arcopolis-export-dir <output_dir>\n";
        return 1;
    }

    // Validate the whole script up front (no simulation state touched) so a typo fails fast before
    // the expensive world load.
    const auto script = read_script_file( opts.script_path );
    if( !script ) {
        std::cerr << "arcopolis: " << script.error().detail << "\n";
        return exit_code_for( script.error().kind );
    }

    if( !assure_dir_exist( opts.export_dir ) ) {
        std::cerr << "arcopolis: failed to create export directory '" << opts.export_dir << "'\n";
        return exit_code_for( command_error_kind::export_failed );
    }

    init_colors();  // mirror the other headless flows; the world-load path may colorize output

    // PERSISTENT LIFECYCLE: load the world EXACTLY ONCE. game::setup() (run by g->load) leaves
    // game::new_game == true, so the FIRST do_turn (the first "wait" step below) is the engine's
    // bootstrap turn at the loaded turn T — it clears new_game and, by design, does NOT advance the
    // calendar (game.cpp:1879). EVERY later do_turn takes the else branch and advances calendar::turn
    // by one. We never touch new_game and never fake an advance; the per-step clock advance emerges
    // purely from loading once. (See AGENTS.md "Arcopolis backend fidelity" and
    // docs/arcopolis/06_SPIKE2_STATEFUL_SCRIPT.md.)
    if( !g->load( opts.world ) ) {
        std::cerr << "arcopolis: failed to load world '" << opts.world << "'\n";
        return 1;
    }

    const auto &steps = *script;
    int export_index = 0;
    for( int i = 0; i < static_cast<int>( steps.size() ); ++i ) {
        const auto &step = steps[i];
        if( step.op == "export" ) {
            const auto label = step.name.empty() ? std::string( "snapshot" ) : step.name;
            const auto session = snapshot_session_info{
                .export_index = export_index,
                .step_index = i,
                .export_name = label,
            };
            const auto filename = string_format( "%03d_%s.json", export_index,
                                                 ensure_valid_file_name( label ) );
            const auto path = ( std::filesystem::path( opts.export_dir ) / filename ).string();
            if( !write_current_view( path, session ) ) {
                std::cerr << "arcopolis: step " << i << " (export '" << label
                          << "'): failed to write snapshot to '" << path << "'\n";
                return exit_code_for( command_error_kind::export_failed );
            }
            ++export_index;
        } else {
            // op == "command": apply through the existing backend path (handles "wait"; returns
            // unsupported_command for anything else). parse_script has already guaranteed op is one of
            // {export, command}, so this branch is always a backend command.
            const auto applied = apply_command( {
                .schema_version = arcopolis_script_schema_version,
                .command = step.command,
                .direction = step.direction
            } );
            if( !applied ) {
                std::cerr << "arcopolis: step " << i << " (command '" << step.command << "'): "
                          << applied.error().detail << "\n";
                return exit_code_for( applied.error().kind );
            }
        }
    }

    return 0;
}
