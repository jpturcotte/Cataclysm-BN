#include "arcopolis_script.h"

#include <cstddef>
#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "arcopolis_backend_input.h"  // begin/end_backend_session, backend_input_done, backend_cursor
#include "arcopolis_command.h"  // backend_command, command_to_action, command_error, exit_code_for
#include "arcopolis_export.h"  // current_snapshot_summary (final-state fields for the transcript)
#include "arcopolis_session_log.h"  // begin/end_session_log, session_log_error
#include "color.h"  // init_colors()
#include "filesystem.h"  // assure_dir_exist(), file_exist()
#include "fstream_utils.h"  // cata_ifstream, cata_ios_mode
#include "game.h"  // g, game::load(world), game::do_turn()
#include "get_version.h"  // getVersionString()
#include "json.h"  // JsonIn, JsonObject, JsonArray, JsonError
#include "options.h"  // get_option<float>( "TURN_DURATION" )

namespace
{

/// The only step-script schema this spike understands.
constexpr int arcopolis_script_schema_version = 1;

/// Builds a session_end_summary carrying the live final turn/position (read with the snapshot's
/// accessors). Used by the clean-completion tail and the stall path, where the avatar is alive; the
/// game-over path uses a bare status instead, since the avatar may be dead.
auto end_summary_with_state( const std::string &status ) -> arcopolis::session_end_summary
{
    const auto s = arcopolis::current_snapshot_summary();
    return arcopolis::session_end_summary{
        .status = status,
        .final_turn = s.turn,
        .final_pos_abs = arcopolis::session_log_point{ .x = s.pos_abs_x, .y = s.pos_abs_y, .z = s.pos_abs_z },
    };
}

} // namespace

auto arcopolis::parse_script( std::istream &stream ) ->
std::expected<std::vector<script_step>, command_error>
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

auto arcopolis::read_script_file( const std::string &path ) ->
std::expected<std::vector<script_step>, command_error>
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

    // Pre-flight: resolve every command to its engine action_id now, so an unsupported verb or a bad
    // direction fails fast (before the world load) and the input provider stays total -- by the time the
    // engine pulls actions through the seam, every command is already known-good.
    for( const auto &step : *script ) {
        if( step.op != "command" ) {
            continue;
        }
        const auto resolved = command_to_action( { .schema_version = arcopolis_script_schema_version,
                              .command = step.command, .direction = step.direction } );
        if( !resolved ) {
            std::cerr << "arcopolis: " << resolved.error().detail << "\n";
            return exit_code_for( resolved.error().kind );
        }
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

    // FIDELITY GUARD: force real-time moves off. handle_action() charges current_turn.moves_elapsed()
    // against u.moves at its tail (~handle_action.cpp:2866); the backend runs THROUGH handle_action with
    // the provider's inline export I/O inside that timed window, so a nonzero TURN_DURATION would drain
    // the avatar's moves by wall-clock (non-deterministically, including file I/O). moves_elapsed()
    // returns 0 only while TURN_DURATION <= 0.005 (handle_action.cpp:172); the option default is 0.0.
    if( get_option<float>( "TURN_DURATION" ) > 0.005f ) {
        std::cerr << "arcopolis: TURN_DURATION must be <= 0.005 for headless runs (real-time moves would "
                  "drain the avatar by wall-clock); set it to 0 in the world's options\n";
        return exit_code_for( command_error_kind::apply_failed );
    }

    // Drive the engine's OWN turn loop with the backend as the per-iteration input source (mechanism M1).
    // do_turn runs verbatim: the provider feeds each command's action_id at the handle_action() seam
    // (AFTER the turn's top half) and performs `export` steps inline at that faithful point; the world
    // ticks only when an action exhausts the turn. The script-exhausted clean-stop parks the final turn
    // before its bottom half. This replaces the Spike 3 `command -> do_turn` inversion entirely.
    begin_backend_session( { .steps = *script, .export_dir = opts.export_dir } );

    // Spike 3.1C: open the JSON Lines session transcript beside the snapshots and record session_start.
    // The transcript is a default deliverable for a script run, so a failure to OPEN it is surfaced as a
    // typed error BEFORE driving the engine -- at this point no backend result exists to be masked, and a
    // bad export dir is caught here rather than on the first snapshot. Once open, the writer is best-effort
    // and never overrides the real backend exit code (see docs/arcopolis/11).
    if( !begin_session_log( { .world = opts.world,
                              .seed = std::nullopt,
                              .export_dir = opts.export_dir,
                              .game_version = std::string( getVersionString() ) } ) ) {
        std::cerr << "arcopolis: failed to open session transcript in '" << opts.export_dir << "'\n";
        end_backend_session();
        return exit_code_for( command_error_kind::export_failed );
    }

    // The input loop is skipped while the avatar sleeps (game.cpp:1978), so the provider would never be
    // called and the cursor would never advance. Bound the consecutive cursor-stalled turns as a hang
    // backstop (the ArcopolisTest avatar is awake, so the happy path never trips this).
    constexpr int max_idle_turns = 1000;
    auto last_cursor = backend_cursor();
    int idle_turns = 0;
    while( !backend_input_done() ) {
        if( g->do_turn() ) {
            // do_turn returns true only via cleanup_at_end (game over / avatar death mid-script).
            session_log_error( { .step_index = std::nullopt,
                                 .kind = command_error_kind::game_over,
                                 .detail = "the game ended (avatar died?) while running the script" } );
            end_session_log( { .status = "error" } );  // avatar may be dead -> omit final position
            end_backend_session();
            std::cerr << "arcopolis: the game ended (avatar died?) while running the script\n";
            return exit_code_for( command_error_kind::game_over );
        }
        const auto cursor = backend_cursor();
        if( cursor == last_cursor ) {
            if( ++idle_turns >= max_idle_turns ) {
                session_log_error( { .step_index = std::nullopt,
                                     .kind = command_error_kind::backend_stalled,
                                     .detail = "backend stalled (no input consumed; is the avatar asleep?)" } );
                end_session_log( end_summary_with_state( "error" ) );
                end_backend_session();
                std::cerr << "arcopolis: backend stalled (no input consumed for " << max_idle_turns
                          << " turns; is the avatar asleep?)\n";
                return exit_code_for( command_error_kind::backend_stalled );
            }
        } else {
            idle_turns = 0;
            last_cursor = cursor;
        }
    }

    // Final-on-exit snapshot (Spike 3.1B): ALWAYS capture the terminal backend state on clean completion
    // (every non-failing run, regardless of its last step type) -- after do_turn returned from the
    // clean-park path and before the session is cleared. Suppressed ONLY by a recorded failure (the guard
    // below; game-over and stall already returned inside the loop). This is a terminal state capture, NOT a
    // world-tick witness (deferred -- see docs/arcopolis/10_SPIKE3_1B_CLEAN_PARK_HARDENING.md).
    if( !backend_session_failure() ) {
        backend_write_final_snapshot();  // records session.failure if the write fails
    }

    // Surface a deferred inline-export write failure (the provider cannot return one) as the exit code.
    const auto failure = backend_session_failure();
    // session_end is the transcript's last line on every post-open return path. An export-failure `error`
    // line (if any) was already written at the point of detection; here we only close the run out. The
    // avatar is alive on both branches (a clean park or an export-write failure, not death), so the live
    // final turn/position are safe to read.
    end_session_log( end_summary_with_state( failure ? "error" : "ok" ) );
    end_backend_session();
    if( failure ) {
        std::cerr << "arcopolis: " << failure->detail << "\n";
        return exit_code_for( failure->kind );
    }
    return 0;
}
