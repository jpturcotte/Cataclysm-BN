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
constexpr auto max_export_name_length = std::size_t { 64 };

/// The protocol's export-label whitelist. Deliberately STRICTER than ensure_valid_file_name() (which
/// only strips \/:?"<>|): a control character or other exotic byte in a label would survive into the
/// snapshot filename, fail the file open, and escalate a recoverable client typo into the session's
/// fatal export_failed path.
auto is_valid_export_name( std::string_view name ) -> bool
{
    namespace ranges = std::ranges;
    if( name.empty() || name.size() > max_export_name_length ) {
        return false;
    }
    return ranges::all_of( name, []( const auto c ) {
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
    int prompt_seq = 0;  ///< Spike 12A: increments per emitted `prompt`, correlates the answer
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
        // Spike 12A follow-up: a pickup command may have met an UNSUPPORTED in-action prompt the
        // transaction cannot drive (the guard recorded which, surviving the seam's stale-clear).
        const auto outcome = arcopolis::backend_take_pickup_outcome();
        if( outcome == arcopolis::pickup_command_outcome::unsupported_submenu ) {
            // The pre-menu vehicle "Get items from where?" submenu: FAIL LOUD instead of a success
            // snapshot. The guard already force-cancelled it (pick_up returned early, no pickup), so no
            // state changed; answer unsupported_command and keep serving (recoverable). Writing no
            // snapshot is correct -- nothing happened. The avatar parked with its moves (a cancelled
            // pickup does not spend the turn), so the session simply reads the next request below.
            send_error( { .id = pending.id, .op = "command",
                          .code = arcopolis::live_error_code::unsupported_command,
                          .message = "pickup encountered an unsupported 'Get items from where?' "
                                     "vehicle-cargo submenu; the prompt transaction drives only the "
                                     "ground-item PICKUP menu (no items were taken)" } );
        } else {
            const auto written = arcopolis::backend_write_step_snapshot( pending.name, pending.step_index );
            if( !written ) {
                send_error( { .id = pending.id, .op = "command",
                              .code = arcopolis::live_error_code::export_failed,
                              .message = "failed to write the post-command snapshot" } );
                return ACTION_NULL;
            }
            // A secondary capacity/wield/spill prompt force-cancelled mid-activity => a TRUTHFUL PARTIAL
            // pickup: ok stays true (what fit was carried), but the explicit marker set makes the
            // partiality unmistakable so the result is never read as full success.
            const auto partial = outcome == arcopolis::pickup_command_outcome::secondary_forced_cancel;
            arcopolis::write_success_response_line( std::cout, { .id = pending.id, .op = "command",
                                                    .snapshot = written->filename,
                                                    .export_index = written->export_index,
                                                    .turn = written->turn,
                                                    .forced_cancel = partial,
                                                    .partial = partial,
                                                    .unsupported_prompt = partial
                                                            ? std::string( "secondary_capacity" )
                                                            : std::string()
                                                               } );
            std::cout.flush();
        }
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
            // Spike 12A: the pickup prompt transaction drives only the OLD "PICKUP" menu. Under
            // NEW_PICKUP_MENU=true, game::pickup routes to the inventory_selector (a different, unsupported
            // menu mechanism), so FAIL LOUD before dispatching rather than silently auto-cancelling there --
            // recording the loaded value is not enough (docs/arcopolis/30).
            if( req->command == "pickup" && get_option<bool>( "NEW_PICKUP_MENU" ) ) {
                send_error( { .id = req->id, .op = "command",
                              .code = arcopolis::live_error_code::unsupported_command,
                              .message = "pickup prompt transaction requires NEW_PICKUP_MENU=false "
                                         "(the new inventory_selector menu is not supported)" } );
                continue;
            }
            const auto step_index = pump.accepted_requests++;
            // Record what was queued (status "queued"), exactly like the script provider: the
            // observable RESULT is the FOLLOWING export -- the pending snapshot taken at (a).
            arcopolis::session_log_command( { .step_index = step_index,
                                              .command = req->command,
                                              .direction = req->direction,
                                              .action_id = std::optional<std::string>( action_ident( *resolved ) ) } );
            // Spike 11A/12A: arm the one-shot direction answer for the "Examine where?" / "Pickup where?"
            // chooser AFTER the command event (arming emits nothing, so this dispatch's nested_input_* /
            // prompt_* events all order after its command event).
            if( req->command == "examine" || req->command == "pickup" ) {
                if( const auto answer = arcopolis::target_direction_nested_answer( req->direction ) ) {
                    arcopolis::backend_arm_nested_input( { .action = *answer,
                                                           .direction = req->direction,
                                                           .step_index = step_index } );
                }
            }
            // Spike 12A: arm the pickup MENU transaction (the gate src/pickup.cpp's pre-loop block checks).
            // ONLY `pickup` arms it, so examine's auto-pickup tail finds it false and keeps auto-cancelling.
            if( req->command == "pickup" ) {
                arcopolis::backend_arm_pickup_transaction( step_index );
            }
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

/// The live pickup menu-answer channel (registered as the backend session's prompt_source, Spike 12A).
/// Called from INSIDE pick_up_from_items (mid-do_turn) when the old "PICKUP" menu opens during an armed
/// transaction: emits the `prompt` event with the engine's REAL choices, then blocks reading prompt
/// answers. A valid choice is acked and returned (the backend then translates it into the registered
/// PICKUP actions the engine's own menu loop consumes); an explicit cancel returns nullopt; an invalid
/// answer is rejected with ok:false and the prompt stays OPEN (mirrors the GUI menu ignoring an unbound
/// key); EOF returns nullopt (cancel). live_next_action has already RETURNED the action, so this is the
/// sole std::cin reader -- no re-entrancy -- and the stall backstop cannot fire mid-do_turn.
auto live_pickup_prompt( const std::vector<arcopolis::pickup_prompt_choice> &choices ) ->
std::optional<std::vector<int>>
{
    const auto command_id = pump.pending ? pump.pending->id : std::optional<int> {};
    const auto step_index = pump.pending ? std::optional<int>( pump.pending->step_index )
                            : std::optional<int> {};
    const auto prompt_id = ++pump.prompt_seq;
    arcopolis::write_prompt_line( std::cout, { .id = command_id,
                                  .prompt_id = prompt_id,
                                  .kind = "menu",
                                  .title = "Pick up which items?",
                                  .choices = choices,
                                  .cancelable = true
                                             } );
    std::cout.flush();
    for( ;; ) {
        std::string line;
        if( !std::getline( std::cin, line ) ) {
            return std::nullopt;  // EOF mid-prompt: cancel; the outer loop then ends the session cleanly.
        }
        if( !line.empty() && line.back() == '\r' ) {
            line.pop_back();
        }
        if( line.empty() ) {
            continue;
        }
        const auto answer = arcopolis::parse_prompt_answer( line, static_cast<int>( choices.size() ) );
        if( !answer ) {
            // Recoverable: the prompt stays OPEN. Record the rejected attempt; no engine state was touched.
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "invalid_answer",
                                                    .detail = answer.error().message } );
            send_error( { .id = answer.error().id, .op = "prompt_answer",
                          .code = answer.error().code, .message = answer.error().message } );
            continue;
        }
        if( answer->prompt_id != prompt_id ) {
            // Correlate the answer to THIS prompt: a stale/wrong prompt_id is a recoverable bad_request, the
            // prompt stays OPEN, and no engine state is touched. (Parse already rejected a missing one.)
            const auto detail = "prompt_id " + std::to_string( answer->prompt_id ) +
                                " does not match the active prompt " + std::to_string( prompt_id );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "prompt_id_mismatch",
                                                    .detail = detail } );
            send_error( { .id = answer->id, .op = "prompt_answer",
                          .code = arcopolis::live_error_code::bad_request, .message = detail } );
            continue;
        }
        if( answer->act == arcopolis::live_prompt_answer::action::cancel ) {
            arcopolis::write_prompt_ack_line( std::cout, { .id = answer->id, .prompt_id = prompt_id,
                                              .choices = std::nullopt
                                                         } );
            std::cout.flush();
            return std::nullopt;
        }
        arcopolis::write_prompt_ack_line( std::cout, { .id = answer->id, .prompt_id = prompt_id,
                                          .choices = answer->choices
                                                     } );
        std::cout.flush();
        return answer->choices;
    }
}

/// The live backend-driven uilist answer channel (Spike 13B; registered as the session's
/// uilist_prompt_source). Called from INSIDE pick_up (mid-do_turn) when the "Get items from where?"
/// vehicle-source uilist is armed: emits a `prompt` event with kind="uilist" carrying the engine's REAL
/// uilist entries, then blocks reading a SINGLE-select answer. A valid in-range choice is acked and
/// returned (the backend then translates it into the registered UILIST actions [DOWN x choice, CONFIRM] the
/// real uilist loop consumes); an explicit cancel / EOF returns nullopt (the loop's UILIST_CANCEL); an
/// invalid / multi / out-of-range / wrong-prompt_id answer is rejected ok:false and the prompt stays OPEN.
/// Same single-std::cin-reader discipline as live_pickup_prompt (live_next_action already returned the
/// action), so there is no re-entrancy and the stall backstop cannot fire mid-do_turn.
auto live_vehicle_source_prompt( const arcopolis::backend_uilist_prompt_request &request ) ->
std::optional<int>
{
    const auto command_id = pump.pending ? pump.pending->id : std::optional<int> {};
    const auto step_index = pump.pending ? std::optional<int>( pump.pending->step_index )
                            : std::optional<int> {};
    const auto prompt_id = ++pump.prompt_seq;
    arcopolis::write_prompt_line( std::cout, { .id = command_id,
                                  .prompt_id = prompt_id,
                                  .kind = request.kind,
                                  .title = request.title,
                                  .choices = request.choices,
                                  .cancelable = request.cancelable
                                             } );
    std::cout.flush();
    for( ;; ) {
        std::string line;
        if( !std::getline( std::cin, line ) ) {
            return std::nullopt;  // EOF mid-prompt: cancel; the outer loop then ends the session cleanly.
        }
        if( !line.empty() && line.back() == '\r' ) {
            line.pop_back();
        }
        if( line.empty() ) {
            continue;
        }
        const auto answer = arcopolis::parse_prompt_answer( line,
                            static_cast<int>( request.choices.size() ) );
        if( !answer ) {
            // Recoverable (incl. out-of-range): the prompt stays OPEN; no engine state was touched.
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "invalid_answer",
                                                    .detail = answer.error().message } );
            send_error( { .id = answer.error().id, .op = "prompt_answer",
                          .code = answer.error().code, .message = answer.error().message } );
            continue;
        }
        if( answer->prompt_id != prompt_id ) {
            const auto detail = "prompt_id " + std::to_string( answer->prompt_id ) +
                                " does not match the active prompt " + std::to_string( prompt_id );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "prompt_id_mismatch",
                                                    .detail = detail } );
            send_error( { .id = answer->id, .op = "prompt_answer",
                          .code = arcopolis::live_error_code::bad_request, .message = detail } );
            continue;
        }
        if( answer->act == arcopolis::live_prompt_answer::action::cancel ) {
            arcopolis::write_prompt_ack_line( std::cout, { .id = answer->id, .prompt_id = prompt_id,
                                              .choices = std::nullopt
                                                         } );
            std::cout.flush();
            return std::nullopt;
        }
        // The vehicle-source uilist is SINGLE-select. A multi-choice answer is a recoverable bad_request
        // (the prompt stays OPEN), distinct from the multi-select PICKUP item menu above.
        if( answer->choices.size() != 1 ) {
            const auto detail = std::string( "the 'Get items from where?' prompt is single-select; "
                                             "answer with exactly one choice" );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "invalid_answer",
                                                    .detail = detail } );
            send_error( { .id = answer->id, .op = "prompt_answer",
                          .code = arcopolis::live_error_code::bad_request, .message = detail } );
            continue;
        }
        arcopolis::write_prompt_ack_line( std::cout, { .id = answer->id, .prompt_id = prompt_id,
                                          .choices = answer->choices
                                                     } );
        std::cout.flush();
        return answer->choices.front();
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

auto arcopolis::parse_prompt_answer( const std::string &line, int num_choices ) ->
std::expected<live_prompt_answer, live_error>
{
    std::optional<int> id;
    try {
        std::istringstream stream( line );
        JsonIn json( stream );
        auto obj = json.get_object();
        obj.allow_omitted_members();
        if( obj.has_int( "id" ) ) {
            id = obj.get_int( "id" );
        }
        if( !obj.has_string( "op" ) ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "missing or non-string 'op'", .id = id } );
        }
        const auto op = obj.get_string( "op" );
        // Both ops reference the active prompt, so require an integer `prompt_id`: a missing one is rejected
        // here, and the caller (live_pickup_prompt) rejects one that does not match the active prompt. This
        // makes a stale or wrong answer a clean bad_request instead of being silently accepted.
        if( !obj.has_int( "prompt_id" ) ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "prompt answer requires an integer 'prompt_id'", .id = id } );
        }
        const int prompt_id = obj.get_int( "prompt_id" );
        if( op == "prompt_cancel" ) {
            return live_prompt_answer{ .act = live_prompt_answer::action::cancel, .id = id, .prompt_id = prompt_id };
        }
        if( op != "prompt_answer" ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "expected op 'prompt_answer' or 'prompt_cancel', got '" + op + "'",
                                                .id = id } );
        }
        // Accept a single `choice` int or a non-empty `choices` int array (multi-select).
        std::vector<int> picks;
        if( obj.has_array( "choices" ) ) {
            picks = obj.get_int_array( "choices" );
        } else if( obj.has_int( "choice" ) ) {
            picks.push_back( obj.get_int( "choice" ) );
        } else {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "prompt_answer requires an integer 'choice' or a 'choices' int array",
                                                .id = id } );
        }
        if( picks.empty() ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "prompt_answer 'choices' must be non-empty", .id = id } );
        }
        for( const int c : picks ) {
            if( c < 0 || c >= num_choices ) {
                return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                    .message = "choice " + std::to_string( c ) + " out of range [0, " +
                                                            std::to_string( num_choices ) + ")", .id = id } );
            }
        }
        // Canonicalize: sort, then reject duplicates. A repeated index would ack as N picks but drive only
        // one RIGHT mark, and sorting keeps the ack, the prompt_answered transcript, and the served-action
        // order in agreement (the backend's arm also walks the indices ascending).
        std::ranges::sort( picks );
        if( std::ranges::adjacent_find( picks ) != picks.end() ) {
            return std::unexpected( live_error{ .code = live_error_code::bad_request,
                                                .message = "prompt_answer 'choices' must not contain duplicates", .id = id } );
        }
        return live_prompt_answer{ .act = live_prompt_answer::action::choose, .id = id,
                                   .prompt_id = prompt_id, .choices = picks };
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
    // Spike 12A follow-up: a partial pickup with an unsupported secondary prompt force-cancelled is marked
    // explicitly so the response cannot be read as full success (ok stays true -- the partial pickup is
    // real). Emitted only when set, so non-pickup / clean-pickup responses are byte-identical to before.
    if( ev.forced_cancel ) {
        json.member( "forced_cancel", true );
        json.member( "partial", ev.partial );
        json.member( "unsupported_prompt", ev.unsupported_prompt );
    }
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

auto arcopolis::write_prompt_line( std::ostream &out, const live_prompt_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "prompt" ) );
    write_id_member( json, ev.id );
    json.member( "prompt_id", ev.prompt_id );
    json.member( "kind", ev.kind );
    json.member( "title", ev.title );
    json.member( "cancelable", ev.cancelable );
    json.member( "choices" );
    json.start_array();
    for( const pickup_prompt_choice &c : ev.choices ) {
        json.start_object();
        json.member( "index", c.index );
        json.member( "text", c.text );
        json.member( "enabled", c.enabled );
        json.end_object();
    }
    json.end_array();
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_ack_line( std::ostream &out, const live_prompt_ack &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    json.start_object();
    json.member( "type", std::string( "response" ) );
    write_id_member( json, ev.id );
    json.member( "ok", true );
    json.member( "op", std::string( "prompt_answer" ) );
    json.member( "prompt_id", ev.prompt_id );
    if( ev.choices ) {
        json.member( "choices" );
        json.start_array();
        for( const int c : *ev.choices ) {
            json.write( c );
        }
        json.end_array();
    } else {
        json.member( "cancelled", true );
    }
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

    // The pump replaces the steps walk entirely: it is consulted at the same handle_action() seam. The
    // prompt_source serves the Spike 12A pickup item menu; uilist_prompt_source serves the Spike 13B
    // backend-driven "Get items from where?" vehicle-source uilist (both live mode only).
    begin_backend_session( { .steps = {}, .export_dir = opts.export_dir,
                             .live_source = live_next_action, .prompt_source = live_pickup_prompt,
                             .uilist_prompt_source = live_vehicle_source_prompt } );

    // The transcript is a default deliverable; failure to OPEN it is surfaced before driving the
    // engine, exactly like run_script (no backend result exists yet to be masked).
    if( !begin_session_log( { .world = opts.world,
                              .seed = opts.seed,
                              .export_dir = opts.export_dir,
                              .game_version = std::string( getVersionString() ),
                              // Spike 11A: record (never override) the loaded chooser-autoselect option, so
                              // examine witnesses are config-explicit (docs/arcopolis/25, gate (h)).
                              .autoselect_single_valid_target = get_option<bool>( "AUTOSELECT_SINGLE_VALID_TARGET" ) } ) ) {
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
    constexpr auto max_idle_turns = 1000;
    auto last_progress = pump.accepted_requests;
    auto idle_turns = 0;
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
