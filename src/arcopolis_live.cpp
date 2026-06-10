#include "arcopolis_live.h"

#include <algorithm>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>

#include "action.h"             // action_id, ACTION_NULL, action_ident
#include "arcopolis_backend_input.h"  // begin/end_backend_session, backend_write_step_snapshot, ...
#include "arcopolis_command.h"  // command_to_action, command_error_kind, exit_code_for
#include "arcopolis_export.h"   // current_snapshot_summary (final-state fields for the transcript)
#include "arcopolis_session_log.h"  // begin/end_session_log, session_log_command, session_log_error
#include "color.h"              // init_colors()
#include "filesystem.h"         // assure_dir_exist()
#include "game.h"               // g, game::load(world), game::do_turn()
#include "get_version.h"        // getVersionString()
#include "json.h"               // JsonIn, JsonOut, JsonObject, JsonError
#include "options.h"            // get_option<float>, get_options() (the in-memory AUTOSAVE override)

namespace
{

/// Longest export label the protocol accepts (the NNN_ prefix and .json suffix come on top).
constexpr std::size_t max_export_name_length = 64;

/// The protocol's export-label whitelist. Deliberately STRICTER than ensure_valid_file_name() (which
/// only strips \/:?"<>|): a control character or other exotic byte in a label would survive into the
/// snapshot filename, fail the file open, and escalate a recoverable client typo into the session's
/// fatal export_failed path.
auto is_valid_export_name( std::string_view name ) -> bool
{
    if( name.empty() || name.size() > max_export_name_length ) {
        return false;
    }
    return std::ranges::all_of( name, []( const char c ) {
        return ( c >= 'a' && c <= 'z' ) || ( c >= 'A' && c <= 'Z' ) || ( c >= '0' && c <= '9' ) ||
               c == '_' || c == '.' || c == '-';
    } );
}

/// A command request whose action was handed to the engine but whose response is still owed: the
/// observable result is the NEXT input-rest instant, where the pump writes the post-command snapshot
/// and answers with it (the same "result = the FOLLOWING export" rule the script transcript uses).
struct live_pending {
    std::optional<int> id;
    std::string name;
    int step_index = 0;
};

/// Translation-unit-local pump state (one live session at a time, like the backend-input session).
/// `accepted_requests` numbers the engine-relevant requests (exports + commands) -- it is the
/// transcript step_index source AND the runner's progress counter for the stall backstop.
struct live_pump {
    std::optional<live_pending> pending;
    int accepted_requests = 0;
    bool eof = false;
    bool quit = false;
};

live_pump pump;

/// Writes one protocol error response + flush (stdout is the protocol stream; std::_Exit does not
/// flush iostreams, so every line is flushed at the write site).
auto send_error( const arcopolis::live_error_response &ev ) -> void
{
    arcopolis::write_error_response_line( std::cout, ev );
    std::cout.flush();
}

/// Answers an in-flight command request with a fatal error so the client is never left waiting on a
/// response that cannot come (game over / stall / export failure). No-op when nothing is pending.
auto fail_live_pending( arcopolis::live_error_code code, const std::string &message ) -> void
{
    if( !pump.pending ) {
        return;
    }
    send_error( { .id = pump.pending->id, .op = "command", .code = code, .message = message } );
    pump.pending.reset();
}

/// Builds a session_end_summary carrying the live final turn/position (read with the snapshot's
/// accessors) -- the avatar is alive on every path that uses this (mirrors run_script's helper).
auto end_summary_with_state( const std::string &status ) -> arcopolis::session_end_summary
{
    const auto s = arcopolis::current_snapshot_summary();
    return arcopolis::session_end_summary{
        .status = status,
        .final_turn = s.turn,
        .final_pos_abs = arcopolis::session_log_point{ .x = s.pos_abs_x, .y = s.pos_abs_y, .z = s.pos_abs_z },
    };
}

/// The live input provider (registered as the backend session's live_source): called by
/// next_backend_action() at the game::handle_action() seam -- the exact instant the GUI would block on
/// a keypress -- so BLOCKING here on stdin is the faithful "player is thinking" state. Multi-action
/// turns, turn-end (moves <= 0) and the world tick stay entirely engine-owned; the pump never drives
/// do_turn. Returns the next engine action_id, or ACTION_NULL with backend input marked done
/// (quit / EOF / fatal export failure) so do_turn clean-parks.
auto live_next_action() -> action_id
{
    // (a) An owed command response: THIS is the post-action faithful instant, so capture the
    // post-command snapshot now and answer with it. On a write failure, mirror run_script's fatal
    // export_failed semantics (the shared writer recorded the failure and set `done`): answer the
    // in-flight request, then park WITHOUT reading further input.
    if( pump.pending ) {
        const auto pending = *pump.pending;
        pump.pending.reset();
        const auto written = arcopolis::backend_write_step_snapshot( pending.name, pending.step_index );
        if( !written ) {
            send_error( { .id = pending.id, .op = "command",
                          .code = arcopolis::live_error_code::export_failed,
                          .message = "failed to write the post-command snapshot" } );
            return ACTION_NULL;
        }
        arcopolis::write_success_response_line( std::cout, { .id = pending.id, .op = "command",
                                                .snapshot = written->filename,
                                                .export_index = written->export_index,
                                                .turn = written->turn
                                                           } );
        std::cout.flush();
    }

    // (b) Read requests until one consumes engine input (a command), or the session ends. `export`
    // requests are served inline and consume no engine input -- exactly like script `export` steps.
    for( ;; ) {
        std::string line;
        if( !std::getline( std::cin, line ) ) {
            // EOF / broken pipe: the client went away. End cleanly, like quit but with no response.
            pump.eof = true;
            arcopolis::backend_mark_input_done();
            return ACTION_NULL;
        }
        if( !line.empty() && line.back() == '\r' ) {
            line.pop_back();  // tolerate CRLF writers; '\r' is the only CRLF dependency left
        }
        if( line.empty() ) {
            continue;  // blank lines are not requests
        }

        const auto req = arcopolis::parse_live_request( line );
        if( !req ) {
            // Recoverable by design: respond and keep serving. Deliberately NOT a transcript `error`
            // event -- those stay fatal-only (an error event means the session failed), and a rejected
            // request never touched the engine.
            send_error( { .id = req.error().id, .code = req.error().code, .message = req.error().message } );
            continue;
        }

        if( req->op == "export" ) {
            const auto step_index = pump.accepted_requests++;
            const auto written = arcopolis::backend_write_step_snapshot( req->name, step_index );
            if( !written ) {
                send_error( { .id = req->id, .op = "export",
                              .code = arcopolis::live_error_code::export_failed,
                              .message = "failed to write the snapshot" } );
                return ACTION_NULL;  // fatal: `done` is already set by the shared writer
            }
            arcopolis::write_success_response_line( std::cout, { .id = req->id, .op = "export",
                                                    .snapshot = written->filename,
                                                    .export_index = written->export_index,
                                                    .turn = written->turn
                                                               } );
            std::cout.flush();
            continue;
        }

        if( req->op == "command" ) {
            const auto resolved = arcopolis::command_to_action( { .schema_version = 1,
                                  .command = req->command, .direction = req->direction } );
            if( !resolved ) {
                // The request was structurally validated, so ANY resolution failure here is a
                // vocabulary rejection by construction -- both kinds (bad_schema for a direction like
                // move_up, unsupported_command for an unknown verb) map to the protocol's
                // unsupported_command, with the resolver's detail passed through.
                send_error( { .id = req->id, .op = "command",
                              .code = arcopolis::live_error_code::unsupported_command,
                              .message = resolved.error().detail } );
                continue;
            }
            const auto step_index = pump.accepted_requests++;
            // Record what was queued (status "queued"), exactly like the script provider: the
            // observable RESULT is the FOLLOWING export -- the pending snapshot taken at (a).
            arcopolis::session_log_command( { .step_index = step_index,
                                              .command = req->command,
                                              .direction = req->direction,
                                              .action_id = std::optional<std::string>( action_ident( *resolved ) ) } );
            pump.pending = live_pending{ .id = req->id, .name = req->name, .step_index = step_index };
            return *resolved;
        }

        // op == "quit" (the parser guarantees one of the three ops).
        arcopolis::write_quit_response_line( std::cout, { .id = req->id } );
        std::cout.flush();
        pump.quit = true;
        arcopolis::backend_mark_input_done();
        return ACTION_NULL;
    }
}

} // namespace

auto arcopolis::live_error_code_name( live_error_code code ) -> std::string
{
    switch( code ) {
        case live_error_code::malformed_json:
            return "malformed_json";
        case live_error_code::bad_request:
            return "bad_request";
        case live_error_code::unsupported_command:
            return "unsupported_command";
        case live_error_code::export_failed:
            return "export_failed";
        case live_error_code::game_over:
            return "game_over";
        case live_error_code::backend_stalled:
            return "backend_stalled";
    }
    return "unknown";
}

auto arcopolis::parse_live_request( const std::string &line ) ->
std::expected<live_request, live_error>
{
    std::optional<int> id;
    try {
        std::istringstream stream( line );
        JsonIn json( stream );
        auto obj = json.get_object();
        // We read only the fields we care about and may return early; tell the strict JSON reader not
        // to flag other/unread members as unvisited (same rationale as the command/script parsers).
        obj.allow_omitted_members();

        // The id is read FIRST so every later structural error can echo it (a non-int id reads as
        // absent -> the response carries JSON null, per protocol v0).
        if( obj.has_int( "id" ) ) {
            id = obj.get_int( "id" );
        }
        if( !obj.has_string( "op" ) ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "missing or non-string 'op'", .id = id } );
        }
        const auto op = obj.get_string( "op" );
        if( op == "quit" ) {
            return live_request{ .id = id, .op = op };
        }
        if( op != "export" && op != "command" ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "unknown op '" + op + "' (expected 'export', 'command' or 'quit')",
                                                .id = id } );
        }

        auto name = std::string( "snapshot" );  // the script provider's empty-label default
        if( obj.has_member( "name" ) ) {
            if( !obj.has_string( "name" ) ) {
                return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                    .message = "non-string 'name'", .id = id } );
            }
            name = obj.get_string( "name" );
            if( !is_valid_export_name( name ) ) {
                return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                    .message = "invalid 'name' (allowed: A-Z a-z 0-9 _ . -, at most "
                                                            + std::to_string( max_export_name_length ) + " chars)",
                                                    .id = id } );
            }
        }
        if( op == "export" ) {
            return live_request{ .id = id, .op = op, .name = name };
        }

        // op == "command". Vocabulary (verbs/directions) is deliberately NOT checked here --
        // command_to_action() is the single rejection point, mapped to unsupported_command.
        if( !obj.has_string( "command" ) ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "op 'command' requires a string 'command'", .id = id } );
        }
        const auto command = obj.get_string( "command" );
        std::string direction;
        if( obj.has_member( "direction" ) ) {
            if( !obj.has_string( "direction" ) ) {
                return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                    .message = "non-string 'direction'", .id = id } );
            }
            direction = obj.get_string( "direction" );
        }
        return live_request{ .id = id, .op = op, .command = command, .direction = direction, .name = name };
    } catch( const JsonError &err ) {
        return std::unexpected( live_error{ .code = live_error_code::malformed_json,
                                            .message = std::string( "malformed JSON: " ) + err.what(),
                                            .id = id } );
    }
}

namespace
{

/// Writes `"id": <value-or-null>`: a response always carries the id member so a client can correlate
/// strictly, with JSON null when the request's id could not be read (protocol v0).
auto write_id_member( JsonOut &json, const std::optional<int> &id ) -> void
{
    json.member( "id" );
    if( id ) {
        json.write( *id );
    } else {
        json.write_null();
    }
}

} // namespace

auto arcopolis::write_ready_line( std::ostream &out, const live_ready_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "ready" ) );
    json.member( "protocol_version", live_protocol_version );
    json.member( "ok", true );
    json.member( "world", ev.world );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_success_response_line( std::ostream &out,
        const live_success_response &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "response" ) );
    write_id_member( json, ev.id );
    json.member( "ok", true );
    json.member( "op", ev.op );
    json.member( "snapshot", ev.snapshot );
    json.member( "export_index", ev.export_index );
    json.member( "turn", ev.turn );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_quit_response_line( std::ostream &out, const live_quit_response &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "response" ) );
    write_id_member( json, ev.id );
    json.member( "ok", true );
    json.member( "op", std::string( "quit" ) );
    json.member( "status", std::string( "session_end" ) );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_error_response_line( std::ostream &out,
        const live_error_response &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "response" ) );
    write_id_member( json, ev.id );
    json.member( "ok", false );
    if( !ev.op.empty() ) {
        json.member( "op", ev.op );
    }
    json.member( "error" );
    json.start_object();
    json.member( "code", live_error_code_name( ev.code ) );
    json.member( "message", ev.message );
    json.end_object();
    json.end_object();
    out << '\n';
}

auto arcopolis::run_live( const live_options &opts ) -> int
{
    if( opts.world.empty() ) {
        std::cerr << "arcopolis: --arcopolis-live requires --world <name>\n";
        return 1;
    }
    if( opts.export_dir.empty() ) {
        std::cerr << "arcopolis: --arcopolis-live requires --arcopolis-export-dir <output_dir>\n";
        return 1;
    }
    if( !assure_dir_exist( opts.export_dir ) ) {
        std::cerr << "arcopolis: failed to create export directory '" << opts.export_dir << "'\n";
        return exit_code_for( command_error_kind::export_failed );
    }

    init_colors();  // mirror the other headless flows; the world-load path may colorize output

    // PERSISTENT LIFECYCLE: load the world EXACTLY ONCE -- identical to run_script. The FIRST do_turn
    // is the engine's bootstrap turn at the loaded turn T (game::new_game stays untouched); every
    // later turn advances the calendar. See arcopolis_script.cpp and AGENTS.md "backend fidelity".
    if( !g->load( opts.world ) ) {
        std::cerr << "arcopolis: failed to load world '" << opts.world << "'\n";
        return 1;
    }

    // FIDELITY GUARD (same as run_script): with a nonzero TURN_DURATION, handle_action() drains the
    // avatar's moves by WALL-CLOCK -- fatal for a live session that blocks on stdin for minutes while
    // the client thinks. moves_elapsed() returns 0 only while TURN_DURATION <= 0.005.
    if( get_option<float>( "TURN_DURATION" ) > 0.005f ) {
        std::cerr << "arcopolis: TURN_DURATION must be <= 0.005 for headless runs (real-time moves would "
                  "drain the avatar by wall-clock); set it to 0 in the world's options\n";
        return exit_code_for( command_error_kind::apply_failed );
    }

    // LIVE-MODE DIVERGENCE from run_script (user-approved, Spike 9B): force the AUTOSAVE option off
    // IN MEMORY for this session. do_turn autosaves once AUTOSAVE_TURNS calendar turns AND
    // AUTOSAVE_MINUTES wall-minutes have passed (game.cpp ~1958, ~15731) -- a live session is designed
    // to sit open, so it WOULD eventually save the world mid-session, breaking the "in-memory backend
    // session" contract and the fixture's determinism. This touches a user OPTION for the lifetime of
    // the process only: options.json is written solely by get_options().save(), which is never called
    // here, so nothing persists and no user config is mutated. NOT simulation state -- the calendar,
    // moves and new_game stay engine-owned (the fidelity bar).
    get_options().get_option( "AUTOSAVE" ).setValue( "false" );

    pump = live_pump{};  // reset the TU-local pump (one live session per process)

    // The pump replaces the steps walk entirely: it is consulted at the same handle_action() seam.
    begin_backend_session( { .steps = {}, .export_dir = opts.export_dir, .live_source = live_next_action } );

    // The transcript is a default deliverable; failure to OPEN it is surfaced before driving the
    // engine, exactly like run_script (no backend result exists yet to be masked).
    if( !begin_session_log( { .world = opts.world,
                              .seed = opts.seed,
                              .export_dir = opts.export_dir,
                              .game_version = std::string( getVersionString() ) } ) ) {
        std::cerr << "arcopolis: failed to open session transcript in '" << opts.export_dir << "'\n";
        end_backend_session();
        return exit_code_for( command_error_kind::export_failed );
    }

    // Startup is complete: the protocol stream begins. From here stdout carries ONLY protocol lines.
    write_ready_line( std::cout, { .world = opts.world } );
    std::cout.flush();

    // Drive the engine's OWN turn loop with the pump as the per-iteration input source. The loop only
    // regains control when do_turn returns (a turn ended, or the input loop was skipped); while the
    // client is merely thinking, the process blocks INSIDE the seam and no turns pass.
    // LIVE-MODE DIVERGENCE from run_script: progress is the pump's accepted-request counter, not
    // backend_cursor() (live never advances the script cursor -- the verbatim copy would false-trip
    // backend_stalled after 1000 healthy turn-ending commands). The backstop therefore fires only for
    // the input-loop-skipped case (e.g. the avatar fell asleep), where requests pile up unread.
    constexpr int max_idle_turns = 1000;
    auto last_progress = pump.accepted_requests;
    int idle_turns = 0;
    while( !backend_input_done() ) {
        if( g->do_turn() ) {
            // do_turn returns true only via cleanup_at_end (game over / avatar death mid-session).
            fail_live_pending( live_error_code::game_over,
                               "the game ended (avatar died?) during the live session" );
            session_log_error( { .step_index = std::nullopt,
                                 .kind = command_error_kind::game_over,
                                 .detail = "the game ended (avatar died?) during the live session" } );
            end_session_log( { .status = "error" } );  // avatar may be dead -> omit final position
            end_backend_session();
            std::cerr << "arcopolis: the game ended (avatar died?) during the live session\n";
            return exit_code_for( command_error_kind::game_over );
        }
        if( pump.accepted_requests == last_progress ) {
            if( ++idle_turns >= max_idle_turns ) {
                fail_live_pending( live_error_code::backend_stalled,
                                   "backend stalled (no input consumed; is the avatar asleep?)" );
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
            last_progress = pump.accepted_requests;
        }
    }

    // Clean completion (quit or EOF) or a recorded export-write failure -- the same tail as
    // run_script: final-on-exit snapshot (suppressed only by a recorded failure), session_end, exit.
    // No pending response can survive to here on the clean path: `done` is only set by quit/EOF/
    // export-failure, all of which run AFTER the pump flushed any pending response.
    if( !backend_session_failure() ) {
        backend_write_final_snapshot();  // records session.failure if the write fails
    }
    const auto failure = backend_session_failure();
    // Both quit and EOF are CLEAN ends -> status "ok" (the transcript convention is "ok"/"error", and
    // the harness's contract check requires "ok"; EOF-vs-quit is visible in stderr diagnostics only).
    end_session_log( end_summary_with_state( failure ? "error" : "ok" ) );
    end_backend_session();
    if( failure ) {
        std::cerr << "arcopolis: " << failure->detail << "\n";
        return exit_code_for( failure->kind );
    }
    if( pump.eof ) {
        std::cerr << "arcopolis: stdin EOF; live session ended\n";  // diagnostic only, never stdout
    }
    return 0;
}
