#include "arcopolis_backend_input.h"

#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "action.h"             // action_id, ACTION_NULL
#include "arcopolis_command.h"  // backend_command, command_to_action, command_error, command_error_kind
#include "arcopolis_export.h"   // write_current_view, snapshot_session_info, current_snapshot_summary
#include "arcopolis_session_log.h"  // session_log_command / session_log_export / session_log_error
#include "filesystem.h"         // ensure_valid_file_name
#include "string_formatter.h"   // string_format

namespace
{

/// The Spike 11A one-shot nested-input slot. Kept (with `consumed` set) until control returns to the
/// top-level seam, so guard events fired later in the SAME dispatch (e.g. examine's pickup tail) can
/// still cite the arming command's step_index.
struct nested_input_slot {
    std::string action;             ///< input-context action id to serve (e.g. "UP", "pause")
    std::string direction;          ///< the arming command's direction token (e.g. "move_n")
    std::optional<int> step_index;  ///< the arming command's step index
    bool consumed = false;          ///< the answer was served (one-shot)
};

/// Translation-unit-local backend session. A single instance; begin/end toggle `active`. While `active`,
/// game::handle_action() pulls its per-iteration action from next_backend_action() (the seam in
/// handle_action.cpp), so the engine's do_turn runs verbatim with the backend as its input source.
struct backend_session {
    bool active = false;
    std::vector<arcopolis::script_step> steps;
    std::size_t cursor = 0;
    std::string export_dir;
    int export_index = 0;
    bool done = false;
    std::optional<arcopolis::command_error> failure;
    arcopolis::backend_action_source live_source;  ///< Spike 9B: replaces the steps walk when set
    std::optional<nested_input_slot> nested;       ///< Spike 11A: the one-shot nested-input answer
    int nested_guard_fires = 0;                    ///< Spike 11A: guard fires for the current command
    arcopolis::backend_prompt_source prompt_source;  ///< Spike 12A: live pickup menu-answer channel
    bool pickup_transaction = false;                 ///< Spike 12A: a top-level pickup command armed it
    bool prompt_opened =
        false;                      ///< Spike 12A: a real menu prompt was actually exposed
    std::optional<int> pickup_step_index;            ///< the arming pickup command's step index
    std::vector<std::string> pickup_queue;           ///< Spike 12A: registered PICKUP actions, in order
    std::size_t pickup_cursor = 0;                   ///< next pickup_queue index to serve
    int pickup_served =
        0;                           ///< pickup actions served (the prompt_completed count)
};

backend_session session;

/// The category of the engine's direction chooser (`choose_direction`, src/action.cpp) -- the only
/// context the armed answer may be served to. Anything else asking is not the question the command
/// armed an answer for, so the guard cancels it instead (docs/arcopolis/25, design point 1).
const std::string nested_chooser_category = "DEFAULTMODE";
/// The cancel action ids the guard may return: "QUIT" everywhere it is registered, "TEXT.QUIT" for the
/// engine's text-input context (src/string_input_popup.cpp registers no plain QUIT).
const std::string nested_cancel_quit = "QUIT";
const std::string nested_cancel_text_quit = "TEXT.QUIT";
/// Stable storage for a served answer: input_context::handle_input returns a const reference, so the
/// returned string must outlive the call (same pattern as input.cpp's own CATA_ERROR/TIMEOUT statics).
std::string nested_served_action;

/// The category of the engine's old pickup menu (src/pickup.cpp:721 `input_context( "PICKUP" )`) -- the
/// only context the Spike 12A registered-action queue is served to. Distinct from nested_chooser_category:
/// the queue feeds a different loop than the one-shot direction answer.
const std::string pickup_menu_category = "PICKUP";
/// Stable storage for a served pickup-queue action (handle_input returns a const reference).
std::string pickup_served_action;

/// Force-clears the nested slot at a return to the top-level seam. An armed-but-unconsumed answer is
/// recorded as a `nested_input_unconsumed` transcript event BEFORE any pending live response is written
/// (the caller runs this before the live pull), then dropped so it can never leak into a later
/// command's prompts (docs/arcopolis/25, design point 1). Also resets the per-command fire counter.
auto clear_stale_nested_input() -> void
{
    if( session.nested && !session.nested->consumed ) {
        arcopolis::session_log_nested_input_unconsumed( {
            .step_index = session.nested->step_index,
            .direction = session.nested->direction,
            .action = session.nested->action,
            .reason = "command_completed",
        } );
    }
    session.nested.reset();
    session.nested_guard_fires = 0;
    // Spike 12A: close out a pickup transaction at the seam return -- the "PICKUP" menu loop has run to
    // completion (or cancel), so record the bookend (how many registered actions the loop consumed) and
    // clear the queue so nothing leaks into a later command. Only emit prompt_completed if a prompt was
    // actually OPENED: a pickup that armed the transaction but never reached the menu (empty target / no
    // items / cancelled "Pickup where?") opened nothing, and a phantom prompt_completed (actions_served:0)
    // with no matching prompt_opened would be a transcript lie.
    if( session.pickup_transaction && session.prompt_opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.pickup_step_index,
            .actions_served = session.pickup_served,
        } );
    }
    session.pickup_transaction = false;
    session.prompt_opened = false;
    session.pickup_step_index.reset();
    session.pickup_queue.clear();
    session.pickup_cursor = 0;
    session.pickup_served = 0;
}

/// The machine-readable name a `nested_input_guard` event records for its reason.
auto nested_guard_reason_name( arcopolis::nested_input_guard_reason reason ) -> std::string
{
    switch( reason ) {
        case arcopolis::nested_input_guard_reason::no_answer:
            return "no_answer";
        case arcopolis::nested_input_guard_reason::context_mismatch:
            return "context_mismatch";
        case arcopolis::nested_input_guard_reason::answer_not_registered:
            return "answer_not_registered";
        case arcopolis::nested_input_guard_reason::none:
            break;
    }
    return "none";
}

/// Last-resort hard-fail for a nested read the backend can neither answer nor cancel: a transcript
/// `error`, a stderr line, then an immediate process exit. Deliberately NOT a recoverable path -- the
/// alternative is a silent headless busy-wait no backstop can see (docs/arcopolis/25). Skipping the
/// final snapshot / session_end tail is accepted: the exit code (12) and the flushed error event are
/// the observable contract ("fatal backend contract violation, observed as EOF + exit 12").
[[noreturn]] auto nested_input_hard_fail( const std::string &category,
        const std::optional<int> &step_index, int fires ) -> void
{
    const auto detail = fires >= arcopolis::nested_input_guard_fire_limit
                        ? string_format( "nested input guard fire limit (%d) exceeded in input context '%s' "
                                         "(a nested loop is ignoring its cancel action)",
                                         arcopolis::nested_input_guard_fire_limit, category )
                        : string_format( "nested input read in input context '%s' has no servable answer and no "
                                         "registered cancel action", category );
    arcopolis::session_log_error( {
        .step_index = step_index,
        .kind = arcopolis::command_error_kind::nested_input_failed,
        .detail = detail,
    } );
    std::cerr << "arcopolis: " << detail << "\n";
    std::_Exit( arcopolis::exit_code_for( arcopolis::command_error_kind::nested_input_failed ) );
}

/// Writes one session snapshot (an `export` step, a live-protocol export, or the final-on-exit terminal
/// snapshot) using the live session's export dir + running index. On failure records session.failure,
/// sets done, returns nullopt; on success advances export_index and returns the written filename/scalars
/// (Spike 9B live responses echo them). Shared by next_backend_action(), backend_write_step_snapshot()
/// and backend_write_final_snapshot() so all emit identically-formatted NNN_<label>.json files.
auto write_session_snapshot( const std::string &label, const std::optional<int> &step_index,
                             bool is_final ) -> std::optional<arcopolis::backend_step_snapshot>
{
    const auto info = arcopolis::snapshot_session_info{
        .export_index = session.export_index,
        .step_index = step_index,
        .export_name = label,
        .final = is_final,
    };
    const auto filename = string_format( "%03d_%s.json", session.export_index,
                                         ensure_valid_file_name( label ) );
    const auto path = ( std::filesystem::path( session.export_dir ) / filename ).string();
    if( !arcopolis::write_current_view( path, info ) ) {
        // The provider cannot return an error; record it and stop cleanly. The runner surfaces it as the
        // process exit code once the engine loop ends.
        session.failure = arcopolis::command_error{
            .kind = arcopolis::command_error_kind::export_failed,
            .detail = "failed to write snapshot to '" + path + "'",
        };
        session.done = true;
        // Record the failure in the transcript here (the single point of detection); the runner's tail
        // then writes only session_end. No-op if no transcript is open.
        arcopolis::session_log_error( {
            .step_index = step_index,
            .kind = arcopolis::command_error_kind::export_failed,
            .detail = session.failure->detail,
        } );
        return std::nullopt;
    }
    ++session.export_index;
    // Record the snapshot in the session transcript with the scalars it serialized. current_snapshot_summary
    // reads the SAME accessors as the snapshot at this same instant (no turn runs between), so the values
    // equal the file just written; `filename` is the relative NNN_<name>.json, not an absolute path.
    const auto summary = arcopolis::current_snapshot_summary();
    arcopolis::session_log_export( {
        .step_index = step_index,
        .export_index = info.export_index,
        .name = label,
        .path = filename,
        .final = is_final,
        .turn = summary.turn,
        .pos_abs = { .x = summary.pos_abs_x, .y = summary.pos_abs_y, .z = summary.pos_abs_z },
        .moves = summary.moves,
    } );
    return arcopolis::backend_step_snapshot{
        .filename = filename,
        .export_index = info.export_index,
        .turn = summary.turn,
    };
}

} // namespace

auto arcopolis::begin_backend_session( const backend_session_options &opts ) -> void
{
    session = backend_session{
        .active = true,
        .steps = opts.steps,
        .cursor = 0,
        .export_dir = opts.export_dir,
        .export_index = 0,
        .done = false,
        .failure = std::nullopt,
        .live_source = opts.live_source,
        .prompt_source = opts.prompt_source,
    };
}

auto arcopolis::end_backend_session() -> void
{
    session = backend_session{};  // active = false; everything cleared
}

auto arcopolis::backend_session_active() -> bool
{
    return session.active;
}

auto arcopolis::backend_input_done() -> bool
{
    return session.done;
}

auto arcopolis::backend_cursor() -> std::size_t
{
    return session.cursor;
}

auto arcopolis::backend_session_failure() -> std::optional<command_error>
{
    return session.failure;
}

auto arcopolis::next_backend_action() -> action_id
{
    // Spike 11A: control is back at the top-level seam, so the previous command's dispatch is complete
    // and an armed-but-unconsumed nested answer is stale -- force-clear it (with its transcript event)
    // BEFORE the live pull below, so the event precedes the pending live response written inside the
    // pull and can never leak into the next command's prompts.
    clear_stale_nested_input();
    // Spike 9B live mode: the session's pull source replaces the steps walk entirely. It runs at this
    // same faithful input-loop instant and owns its exports/termination (backend_mark_input_done()).
    if( session.live_source ) {
        return session.live_source();
    }
    while( session.cursor < session.steps.size() ) {
        const auto &step = session.steps[session.cursor];
        if( step.op == "export" ) {
            // Perform the export inline at this faithful input-loop point (INSIDE do_turn's input loop --
            // the GUI's resting point). The shared helper records any write failure and sets done; we stop
            // the script by returning ACTION_NULL so do_turn parks the turn.
            const auto label = step.name.empty() ? std::string( "snapshot" ) : step.name;
            if( !write_session_snapshot( label, static_cast<int>( session.cursor ), /*is_final=*/false ) ) {
                return ACTION_NULL;
            }
            ++session.cursor;
            continue;
        }
        // op == "command": advance past it, then resolve to the engine action_id. The runner's pre-flight
        // already validated every command, so command_to_action always succeeds here; value_or is the
        // total fallback (an unexpected ACTION_NULL is a harmless no-op -- the cursor has already moved).
        const auto step_index = static_cast<int>( session.cursor );
        ++session.cursor;
        const auto resolved = command_to_action( { .schema_version = 1,
                              .command = step.command,
                              .direction = step.direction } );
        // Record what was queued (status "queued"); the observable result is the FOLLOWING export. No-op
        // if no transcript is open (e.g. the provider unit tests, which drive command steps with no log).
        session_log_command( {
            .step_index = step_index,
            .command = step.command,
            .direction = step.direction,
            .action_id = resolved ? std::optional<std::string>( action_ident( *resolved ) ) : std::nullopt,
        } );
        // Spike 11A: arm the one-shot direction answer AFTER the command event (arming emits nothing,
        // so every nested_input_* event of this dispatch orders after its command event).
        if( step.command == "examine" && resolved ) {
            if( const auto answer = target_direction_nested_answer( step.direction ) ) {
                backend_arm_nested_input( { .action = *answer,
                                            .direction = step.direction,
                                            .step_index = step_index } );
            }
        }
        return resolved.value_or( ACTION_NULL );
    }
    // Cursor exhausted: signal "done" so do_turn's clean-stop parks the turn before the bottom half.
    session.done = true;
    return ACTION_NULL;
}

auto arcopolis::backend_mark_input_done() -> void
{
    // Gate on `active` so the public mutator stays inert outside a session (the same defense-in-depth
    // as the snapshot writers): backend_input_done() must read false during normal play.
    if( session.active ) {
        session.done = true;
    }
}

auto arcopolis::backend_arm_nested_input( const nested_input_request &req ) -> void
{
    // Inert outside a session, like every other public mutator: normal play must never see a slot.
    if( !session.active ) {
        return;
    }
    session.nested = nested_input_slot{
        .action = req.action,
        .direction = req.direction,
        .step_index = req.step_index,
        .consumed = false,
    };
    session.nested_guard_fires = 0;
}

auto arcopolis::backend_nested_input_armed() -> bool
{
    return session.nested.has_value() && !session.nested->consumed;
}

auto arcopolis::backend_pickup_transaction_active() -> bool
{
    return session.active && session.pickup_transaction;
}

auto arcopolis::backend_arm_pickup_transaction( const std::optional<int> &step_index ) -> void
{
    // Inert outside a session, like every other public mutator.
    if( !session.active ) {
        return;
    }
    session.pickup_transaction = true;
    session.prompt_opened =
        false;  // set true only once a real menu is exposed (backend_resolve_pickup_choice)
    session.pickup_step_index = step_index;
    session.pickup_queue.clear();
    session.pickup_cursor = 0;
    session.pickup_served = 0;
}

auto arcopolis::backend_resolve_pickup_choice( const std::vector<pickup_prompt_choice> &choices ) ->
void
{
    // Inert unless a pickup transaction is armed (defense in depth: the engine call site already gates on
    // backend_pickup_transaction_active()).
    if( !session.active || !session.pickup_transaction ) {
        return;
    }
    namespace ranges = std::ranges;
    // Record the opened prompt with the engine's REAL choices (the transcript's survey data).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.pickup_step_index, .kind = "menu" };
    for( const pickup_prompt_choice &c : choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.prompt_opened =
        true;  // a real menu was exposed; clear_stale may now bookend it with prompt_completed
    // Ask the live client. A null channel (script/one-shot) yields cancel, so the menu auto-cancels there.
    const auto answer = session.prompt_source
                        ? session.prompt_source( choices )
                        : std::optional<std::vector<int>> {};
    session.pickup_cursor = 0;
    auto picks = answer.value_or( std::vector<int> {} );
    ranges::sort( picks );
    const auto stale = ranges::unique( picks );
    picks.erase( stale.begin(), stale.end() );
    const auto in_range = ranges::all_of( picks, [&]( const int i ) {
        return i >= 0 && i < static_cast<int>( choices.size() );
    } );
    if( answer && !picks.empty() && in_range ) {
        // Translate the chosen index/indices into the registered keystrokes a GUI player would press: walk
        // DOWN (ascending) from the chooser's current entry to each chosen entry and RIGHT to mark it, then
        // CONFIRM to finalize. Forward DOWN only -- UP/PREV_TAB divide by the headless maxitems==0
        // (src/pickup.cpp:972 and :956). The engine's own loop performs every getitem mutation, including a
        // parent entry auto-marking its children (src/pickup.cpp:1107-1123).
        session.pickup_queue.clear();
        int cursor = 0;
        for( const int idx : picks ) {
            session.pickup_queue.insert( session.pickup_queue.end(),
                                         static_cast<std::size_t>( idx - cursor ), "DOWN" );
            session.pickup_queue.emplace_back( "RIGHT" );
            cursor = idx;
        }
        session.pickup_queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.pickup_step_index,
                                                .choices = picks,
                                                .actions = session.pickup_queue } );
    } else {
        // Cancel / EOF / absent channel: ESC-equivalent. QUIT is the loop-exit action.
        session.pickup_queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.pickup_step_index,
                .reason = session.prompt_source ? "client_cancel" : "no_channel" } );
    }
}

auto arcopolis::decide_nested_input( const nested_input_observation &obs ) -> nested_input_decision
{
    // A timeout >= 0 read is a poll (e.g. the activity-interrupt check, game.cpp
    // handle_key_blocking_activity's handle_input( 0 )): it returns by itself headless, so the engine's
    // own read runs untouched. Only a timeout < 0 read blocks forever headless -- that is the moment a
    // keypress (the armed answer) or ESC (the cancel) is THE faithful input.
    if( obs.timeout >= 0 ) {
        return { .outcome = nested_input_outcome::pass_through };
    }
    if( obs.armed && obs.category == nested_chooser_category && obs.answer_registered ) {
        return { .outcome = nested_input_outcome::serve };
    }
    const auto reason = !obs.armed
                        ? nested_input_guard_reason::no_answer
                        : obs.category != nested_chooser_category
                        ? nested_input_guard_reason::context_mismatch
                        : nested_input_guard_reason::answer_not_registered;
    if( obs.fires >= nested_input_guard_fire_limit ) {
        return { .outcome = nested_input_outcome::hard_fail, .reason = reason };
    }
    if( obs.quit_registered ) {
        return { .outcome = nested_input_outcome::cancel_quit, .reason = reason };
    }
    if( obs.text_quit_registered ) {
        return { .outcome = nested_input_outcome::cancel_text_quit, .reason = reason };
    }
    return { .outcome = nested_input_outcome::hard_fail, .reason = reason };
}

auto arcopolis::backend_nested_input_action( const std::string &category,
        const std::vector<std::string> &registered_actions,
        const int timeout ) -> const std::string * // *NOPAD*
{
    namespace ranges = std::ranges;
    // Defense in depth: the engine call site is already gated on backend_session_active().
    if( !session.active ) {
        return nullptr;
    }
    // Spike 12A: serve the next queued registered PICKUP action to the engine's pickup menu loop. This is a
    // DISTINCT mechanism from the one-shot slot below (whose serve gate is hard-coded to DEFAULTMODE): the
    // queue feeds the SAME unmodified input_context("PICKUP") loop the keystrokes a player would press, in
    // order. Like the one-shot path, only a BLOCKING read (timeout < 0) is served; a timeout >= 0 poll
    // passes through. DOWN/RIGHT/CONFIRM/QUIT are all registered in "PICKUP" (src/pickup.cpp:722-735); if a
    // queued action somehow is not, fall through to the guard (defensive).
    if( timeout < 0 && category == pickup_menu_category
        && session.pickup_cursor < session.pickup_queue.size() ) {
        const auto &front = session.pickup_queue[session.pickup_cursor];
        if( ranges::contains( registered_actions, front ) ) {
            pickup_served_action = front;
            ++session.pickup_cursor;
            ++session.pickup_served;
            return &pickup_served_action;
        }
    }
    const auto armed = backend_nested_input_armed();
    const auto decision = decide_nested_input( {
        .armed = armed,
        .timeout = timeout,
        .category = category,
        .answer_registered = armed && ranges::contains( registered_actions, session.nested->action ),
        .quit_registered = ranges::contains( registered_actions, nested_cancel_quit ),
        .text_quit_registered = ranges::contains( registered_actions, nested_cancel_text_quit ),
        .fires = session.nested_guard_fires,
    } );
    // The guard cites the arming command's step_index while the slot survives (it is kept, consumed,
    // until the next seam return); a guard fire with no slot at all has no index to cite.
    const auto step_index = session.nested ? session.nested->step_index : std::nullopt;
    switch( decision.outcome ) {
        case nested_input_outcome::pass_through:
            return nullptr;
        case nested_input_outcome::serve:
            session.nested->consumed = true;
            nested_served_action = session.nested->action;
            session_log_nested_input_answer( {
                .step_index = session.nested->step_index,
                .context = category,
                .direction = session.nested->direction,
                .action = nested_served_action,
            } );
            return &nested_served_action;
        case nested_input_outcome::cancel_quit:
        case nested_input_outcome::cancel_text_quit: {
            ++session.nested_guard_fires;
            const auto &cancel = decision.outcome == nested_input_outcome::cancel_quit
                                 ? nested_cancel_quit
                                 : nested_cancel_text_quit;
            session_log_nested_input_guard( {
                .step_index = step_index,
                .context = category,
                .action = cancel,
                .reason = nested_guard_reason_name( decision.reason ),
                .fires = session.nested_guard_fires,
            } );
            return &cancel;
        }
        case nested_input_outcome::hard_fail:
            nested_input_hard_fail( category, step_index, session.nested_guard_fires );
    }
    return nullptr;  // unreachable; defensive default
}

auto arcopolis::backend_write_step_snapshot( const std::string &label,
        const std::optional<int> &step_index ) -> std::optional<backend_step_snapshot>
{
    // Same inertness guard as backend_write_final_snapshot below: without an active session + export
    // dir the shared writer would build a cwd-relative path and write there.
    if( !session.active || session.export_dir.empty() ) {
        return std::nullopt;
    }
    return write_session_snapshot( label, step_index, /*is_final=*/false );
}

auto arcopolis::backend_write_final_snapshot() -> bool
{
    // Inert unless a session with an export dir is active: without it write_session_snapshot would build a
    // cwd-relative path (e.g. "000_final.json") and write there. The script/live runners (the only
    // callers) are always active with a dir, so this is defense-in-depth that keeps the public writer
    // inert outside a session.
    if( !session.active || session.export_dir.empty() ) {
        return false;
    }
    // Terminal snapshot: no steps[] entry (step_index = nullopt) and final = true. Reuses the running
    // export index, so it follows the last export step's file as NNN_final.json.
    return write_session_snapshot( "final", std::nullopt, /*is_final=*/true ).has_value();
}
