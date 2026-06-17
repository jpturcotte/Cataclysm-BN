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
    arcopolis::pickup_command_outcome pickup_outcome =
        arcopolis::pickup_command_outcome::ok;       ///< Spike 12A follow-up: unsupported sub-prompt outcome;
    ///< survives clear_stale, consumed by the live response writer
    arcopolis::backend_uilist_prompt_source
    uilist_prompt_source;  ///< Spike 13B: live uilist answer channel
    bool uilist_transaction =
        false;                 ///< Spike 13B: a uilist drive is armed (the un-abort gate)
    bool uilist_opened = false;                      ///< Spike 13B: a real uilist prompt was exposed
    std::optional<int>
    uilist_step_index;            ///< the arming pickup command's step index (correlation)
    std::vector<std::string> uilist_queue;           ///< Spike 13B: registered UILIST actions, in order
    std::size_t uilist_cursor = 0;                   ///< next uilist_queue index to serve
    int uilist_served =
        0;                           ///< uilist actions served (the prompt_completed count)
    arcopolis::backend_query_popup_source
    query_popup_source;  ///< Spike 15: live query_popup (query_yn) answer channel
    bool examine_query_popup_command =
        false;  ///< Spike 15: a live examine command armed the precondition
    bool query_popup_transaction =
        false;  ///< Spike 15: a query_popup drive is armed (the un-abort gate)
    bool query_popup_opened =
        false;                 ///< Spike 15: a real query_popup prompt was exposed
    std::string query_popup_witness;                 ///< Spike 15: which audited call site armed it
    std::optional<int> query_popup_step_index;       ///< the arming examine command's step index
    std::vector<std::string> query_popup_queue;      ///< Spike 15: registered YESNO actions, in order
    std::size_t query_popup_cursor = 0;              ///< next query_popup_queue index to serve
    int query_popup_served =
        0;                       ///< query_popup actions served (the prompt_completed count)
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

/// The category of the engine's `uilist` input context (src/ui.cpp create_main_input_context, member
/// `input_category` defaults to "UILIST") -- the only context the Spike 13B registered-action queue is
/// served to. Distinct from pickup_menu_category: a different loop in a different translation unit.
const std::string uilist_menu_category = "UILIST";
/// Stable storage for a served uilist-queue action (handle_input returns a const reference).
std::string uilist_served_action;

/// The category of the engine's `query_popup` input context (src/popup.cpp query_once `input_context(
/// category )`; query_yn sets it to "YESNO", src/output.cpp:715) -- the only context the Spike 15
/// registered-action queue is served to. Distinct from uilist_menu_category: a horizontal LEFT/RIGHT/CONFIRM
/// button row in a different translation unit.
const std::string query_popup_category = "YESNO";
/// Stable storage for a served query_popup-queue action (handle_input returns a const reference).
std::string query_popup_served_action;

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
    // Spike 13B: defensively close out any uilist transaction at the seam return. The normal path clears it
    // synchronously via backend_end_uilist_transaction() (a scope guard in src/pickup.cpp) the instant the
    // submenu closes, so this almost never fires; it guards a leak (an early return that skipped the guard)
    // by bookending the missing prompt_completed and clearing the state, so nothing leaks into the next
    // command's prompts.
    if( session.uilist_transaction && session.uilist_opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.uilist_step_index,
            .actions_served = session.uilist_served,
            .kind = "uilist",
        } );
    }
    session.uilist_transaction = false;
    session.uilist_opened = false;
    session.uilist_step_index.reset();
    session.uilist_queue.clear();
    session.uilist_cursor = 0;
    session.uilist_served = 0;
    // Spike 15: defensively close any leaked query_popup transaction at the seam return. The normal path
    // clears it synchronously via the witness guard the instant the witnessed query_yn returns (well before
    // here), so this almost never fires; it bookends a missing prompt_completed and clears the state so
    // nothing leaks into the next command's prompts.
    if( session.query_popup_transaction && session.query_popup_opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.query_popup_step_index,
            .actions_served = session.query_popup_served,
            .kind = "query_popup",
        } );
    }
    session.query_popup_transaction = false;
    session.query_popup_opened = false;
    session.query_popup_witness.clear();
    session.query_popup_queue.clear();
    session.query_popup_cursor = 0;
    session.query_popup_served = 0;
    // Spike 15: clear the per-command examine query_popup precondition (the gate the witness guard checks).
    session.examine_query_popup_command = false;
    session.query_popup_step_index.reset();
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
        .uilist_prompt_source = opts.uilist_prompt_source,
        .query_popup_source = opts.query_popup_source,
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
    session.pickup_outcome = pickup_command_outcome::ok;  // fresh per pickup command
}

auto arcopolis::backend_report_pickup_unsupported_submenu() -> void
{
    // Inert unless a pickup transaction is armed (defense in depth: the engine call site already gates on
    // backend_pickup_transaction_active()). The vehicle submenu fires BEFORE the menu opens, so no
    // prompt_completed will bookend this command -- the force-cancel event is the whole record.
    if( !session.active || !session.pickup_transaction ) {
        return;
    }
    session.pickup_outcome = pickup_command_outcome::unsupported_submenu;
    session_log_prompt_force_cancelled( {
        .step_index = session.pickup_step_index,
        .kind = "vehicle_submenu",
        .reason = "the 'Get items from where?' vehicle-cargo submenu is not driven by the pickup "
        "transaction; failed loud (no items taken)",
    } );
}

auto arcopolis::backend_report_pickup_secondary_forced_cancel() -> void
{
    if( !session.active || !session.pickup_transaction ) {
        return;
    }
    session.pickup_outcome = pickup_command_outcome::secondary_forced_cancel;
    session_log_prompt_force_cancelled( {
        .step_index = session.pickup_step_index,
        .kind = "secondary_capacity",
        .reason = "a secondary capacity/wield/spill prompt is not driven by the pickup transaction; "
        "the item that does not fit is left behind (truthful partial pickup)",
    } );
}

auto arcopolis::backend_report_pickup_orphaned_secondary() -> void
{
    // Fires ONLY for the orphaned case: a backend session is active but NO pickup transaction is armed (a
    // multi-tick pickup activity resumed on a later do_turn, after clear_stale_nested_input cleared the
    // transaction at the seam return). Inert during normal play (no session) and inert while a transaction
    // IS armed (the drive / no-channel paths own that case -- this would double-report otherwise). Logs a
    // transcript prompt_force_cancelled so the engine's own test_mode CANCEL is MARKED, never silent. Sets
    // NO pickup_outcome: there is no owed command response for this resumed-activity prompt to mark, and
    // mutating the outcome could leak a partial marker into an unrelated later response.
    if( !session.active || session.pickup_transaction ) {
        return;
    }
    session_log_prompt_force_cancelled( {
        .step_index = std::nullopt,
        .kind = "secondary_capacity_orphaned",
        .reason = "a secondary capacity/wield/spill prompt was reached during a backend session with no "
        "armed pickup transaction (a multi-tick pickup activity resumed after the transaction was cleared); "
        "the prompt is not driven and the item is left behind. Threading the pickup transaction across "
        "resumed activity ticks is deferred (docs/arcopolis/34).",
    } );
}

auto arcopolis::backend_take_pickup_outcome() -> pickup_command_outcome
{
    const auto outcome = session.pickup_outcome;
    session.pickup_outcome = pickup_command_outcome::ok;
    return outcome;
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

auto arcopolis::backend_ui_mode_active() -> bool
{
    return session.active && session.uilist_transaction;
}

auto arcopolis::backend_uilist_prompt_available() -> bool
{
    return session.active && static_cast<bool>( session.uilist_prompt_source );
}

auto arcopolis::backend_begin_uilist_transaction() -> void
{
    // Gated on an armed pickup transaction (the only backend-driven uilist arises inside a live pickup).
    // Inert otherwise. MUST run before the uilist is constructed: the default ctor's init() reads
    // backend_ui_mode_active() to decide the test_mode abort.
    if( !session.active || !session.pickup_transaction ) {
        return;
    }
    session.uilist_transaction = true;
    session.uilist_opened = false;  // set true only once a real uilist prompt is exposed (resolve)
    session.uilist_step_index = session.pickup_step_index;
    session.uilist_queue.clear();
    session.uilist_cursor = 0;
    session.uilist_served = 0;
}

auto arcopolis::backend_resolve_uilist_choice( const backend_uilist_prompt_request &request ) ->
void
{
    // Inert unless a uilist transaction is armed (backend_begin_uilist_transaction set it). Defense in
    // depth: the engine call site already gates on it.
    if( !session.active || !session.uilist_transaction ) {
        return;
    }
    // Record the opened prompt with the engine's REAL uilist choices (read from amenu.entries by the caller).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.uilist_step_index,
            .kind = request.kind };
    for( const pickup_prompt_choice &c : request.choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.uilist_opened = true;
    // PR #42 review (Codex P2) defense-in-depth: the single-select DOWN x choice -> CONFIRM translation
    // assumes EVERY entry is enabled. uilist::filterlist() lands the initial highlight on the first ENABLED
    // entry and uilist::scrollby() skips disabled entries (src/ui.cpp), so a raw position index would
    // mis-navigate to a DIFFERENT enabled action when any entry is disabled. This driver does NOT support
    // disabled-entry shapes (acceptance criterion #1): if any choice is disabled, refuse WITHOUT asking the
    // client -- serve QUIT (the engine's UILIST_CANCEL) and log prompt_cancelled reason
    // "disabled_entry_unsupported" -- rather than risk the wrong selection. (The pickup call site already
    // refuses + marks partial before reaching here; this guards every other caller and is the unit-test hook.)
    const auto any_disabled = std::ranges::any_of( request.choices,
    []( const pickup_prompt_choice & c ) {
        return !c.enabled;
    } );
    if( any_disabled ) {
        session.uilist_cursor = 0;
        session.uilist_served = 0;
        session.uilist_queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.uilist_step_index,
                .reason = "disabled_entry_unsupported",
                .kind = request.kind } );
        return;
    }
    // Ask the live client for a SINGLE choice. The caller only reaches here with a channel present
    // (it checks backend_uilist_prompt_available() first), but a null channel yields cancel for safety.
    const auto answer = session.uilist_prompt_source
                        ? session.uilist_prompt_source( request )
                        : std::optional<int> {};
    session.uilist_cursor = 0;
    session.uilist_served = 0;
    const auto valid = answer && *answer >= 0 && *answer < static_cast<int>( request.choices.size() );
    if( valid ) {
        // Translate the chosen entry index into the registered keystrokes a GUI player would press: from the
        // menu's start at entry 0, DOWN once per step down to the chosen entry, then CONFIRM. The real uilist
        // loop (src/ui.cpp uilist::query) consumes these through input_context::handle_input and sets
        // amenu.ret = entries[selected].retval -- the backend never touches ret/selected.
        session.uilist_queue.clear();
        session.uilist_queue.insert( session.uilist_queue.end(),
                                     static_cast<std::size_t>( *answer ), "DOWN" );
        session.uilist_queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.uilist_step_index,
                                                .choices = std::vector<int> { *answer },
                                                .actions = session.uilist_queue,
                                                .kind = request.kind } );
    } else {
        // Cancel / EOF / out-of-range / absent channel: serve the registered QUIT (the GUI ESC), which the
        // real loop turns into amenu.ret = UILIST_CANCEL (allow_cancel registers QUIT, src/ui.cpp:224).
        session.uilist_queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.uilist_step_index,
                .reason = session.uilist_prompt_source ? "client_cancel" : "no_channel",
                .kind = request.kind } );
    }
}

auto arcopolis::backend_end_uilist_transaction() -> void
{
    // Inert when not armed (safe to call from a scope guard on the GUI path, or twice). Idempotent.
    if( !session.uilist_transaction ) {
        return;
    }
    // Bookend the transaction with how many registered actions the uilist loop consumed -- only if a real
    // prompt opened (resolve sets uilist_opened; a path that armed but never reached the menu opened nothing).
    if( session.uilist_opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.uilist_step_index,
            .actions_served = session.uilist_served,
            .kind = "uilist",
        } );
    }
    session.uilist_transaction = false;
    session.uilist_opened = false;
    session.uilist_step_index.reset();
    session.uilist_queue.clear();
    session.uilist_cursor = 0;
    session.uilist_served = 0;
}

arcopolis::uilist_transaction_guard::~uilist_transaction_guard()
{
    arcopolis::backend_end_uilist_transaction();
}

auto arcopolis::backend_query_popup_mode_active() -> bool
{
    return session.active && session.query_popup_transaction;
}

auto arcopolis::backend_examine_query_popup_command_active() -> bool
{
    return session.active && session.examine_query_popup_command;
}

auto arcopolis::backend_query_popup_prompt_available() -> bool
{
    return session.active && static_cast<bool>( session.query_popup_source );
}

auto arcopolis::backend_arm_examine_query_popup_command( const std::optional<int> &step_index ) ->
void
{
    // Inert outside a session, like every other public mutator.
    if( !session.active ) {
        return;
    }
    session.examine_query_popup_command = true;
    session.query_popup_step_index = step_index;
}

auto arcopolis::backend_begin_query_popup_transaction( const std::string &witness_id ) -> void
{
    // Gated on an armed examine command precondition (the only backend-driven query_popup arises inside a
    // live examine). Inert otherwise -- so the witness guard at iexamine::deployed_furniture is a no-op in
    // normal play, non-live, and any examine that did not arm the precondition. MUST run before query_yn's
    // query_popup reaches query_once (which reads backend_query_popup_mode_active()).
    if( !session.active || !session.examine_query_popup_command ) {
        return;
    }
    session.query_popup_transaction = true;
    session.query_popup_opened = false;  // set true only once a real prompt is exposed (resolve)
    session.query_popup_witness = witness_id;
    session.query_popup_queue.clear();
    session.query_popup_cursor = 0;
    session.query_popup_served = 0;
}

auto arcopolis::backend_resolve_query_popup_choice( const backend_query_popup_request &request ) ->
void
{
    // Inert unless a query_popup transaction is armed (the witness guard set it). Defense in depth: the
    // query_yn drive-block already gates on backend_query_popup_mode_active().
    if( !session.active || !session.query_popup_transaction ) {
        return;
    }
    // Record the opened prompt with the engine's REAL query_popup options (read from the constructed popup).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.query_popup_step_index,
            .kind = request.kind };
    for( const pickup_prompt_choice &c : request.choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.query_popup_opened = true;
    // Ask the live client for a SINGLE choice. A null channel yields the closed-default branch below.
    const auto answer = session.query_popup_source
                        ? session.query_popup_source( request )
                        : std::optional<int> {};
    session.query_popup_cursor = 0;
    session.query_popup_served = 0;
    const auto valid = answer && *answer >= 0 && *answer < static_cast<int>( request.choices.size() );
    if( valid ) {
        // Translate the chosen option index into the registered keystrokes a GUI player would press: from the
        // popup's REAL starting cursor, navigate the horizontal button row LEFT (toward 0) or RIGHT (toward
        // the end) to the chosen option, then CONFIRM. CONFIRM is filter-free: query_once sets res.action =
        // options[cur].action without consulting the per-option key filter (src/popup.cpp:325-329), so this
        // is robust regardless of FORCE_CAPITAL_YN and the synthetic input event. The real query_once loop
        // moves the cursor and sets the result -- the backend never sets it.
        session.query_popup_queue.clear();
        const int start = static_cast<int>( request.cursor_start );
        const int target = *answer;
        if( target < start ) {
            session.query_popup_queue.insert( session.query_popup_queue.end(),
                                              static_cast<std::size_t>( start - target ), "LEFT" );
        } else if( target > start ) {
            session.query_popup_queue.insert( session.query_popup_queue.end(),
                                              static_cast<std::size_t>( target - start ), "RIGHT" );
        }
        session.query_popup_queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.query_popup_step_index,
                                                .choices = std::vector<int> { target },
                                                .actions = session.query_popup_queue,
                                                .kind = request.kind } );
    } else {
        // EOF / closed client / absent channel: query_yn is NOT cancelable -- no QUIT is registered, so there
        // is nothing to serve as a cancel. To avoid a headless hang, CONFIRM the popup's pre-selected visible
        // default (the starting cursor -- NO for query_yn). This is logged as a CLOSED prompt, NOT
        // prompt_answered: the client did not intentionally choose the default; the engine fell to its own
        // visible default because the channel closed.
        session.query_popup_queue = { "CONFIRM" };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.query_popup_step_index,
                .reason = session.query_popup_source ? "noncancelable_closed" : "no_channel",
                .kind = request.kind } );
    }
}

auto arcopolis::backend_end_query_popup_transaction() -> void
{
    // Inert when not armed (safe to call from the witness guard on the GUI path, or twice). Idempotent.
    if( !session.query_popup_transaction ) {
        return;
    }
    // Bookend the transaction with how many registered actions the query_popup loop consumed -- only if a
    // real prompt opened (resolve sets query_popup_opened; a guard that armed but whose query_yn never
    // reached query_once opened nothing).
    if( session.query_popup_opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.query_popup_step_index,
            .actions_served = session.query_popup_served,
            .kind = "query_popup",
        } );
    }
    session.query_popup_transaction = false;
    session.query_popup_opened = false;
    session.query_popup_witness.clear();
    session.query_popup_queue.clear();
    session.query_popup_cursor = 0;
    session.query_popup_served = 0;
}

arcopolis::query_popup_witness_guard::query_popup_witness_guard( const std::string &witness_id )
{
    arcopolis::backend_begin_query_popup_transaction( witness_id );
}

arcopolis::query_popup_witness_guard::~query_popup_witness_guard()
{
    arcopolis::backend_end_query_popup_transaction();
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
    // Spike 13B: serve the next queued registered UILIST action to the engine's backend-driven uilist loop
    // (src/ui.cpp uilist::query's input_context("UILIST") loop). Same shape as the PICKUP queue: only a
    // BLOCKING read (timeout < 0), only while the asking context is "UILIST", only while actions remain. The
    // real uilist loop reacts to DOWN/CONFIRM and sets amenu.ret; a drained queue falls through to the guard
    // below, which (QUIT is registered for a cancelable uilist) cancels -- the loop's UILIST_CANCEL -- so the
    // loop never hangs. Only ever non-empty while a uilist transaction is armed (the secondary capacity
    // uilist, raised after the transaction is cleared, sees an empty queue and its own test_mode abort).
    if( timeout < 0 && category == uilist_menu_category
        && session.uilist_cursor < session.uilist_queue.size() ) {
        const auto &front = session.uilist_queue[session.uilist_cursor];
        if( ranges::contains( registered_actions, front ) ) {
            uilist_served_action = front;
            ++session.uilist_cursor;
            ++session.uilist_served;
            return &uilist_served_action;
        }
    }
    // Spike 15: serve the next queued registered YESNO action to the engine's backend-driven query_popup
    // loop (src/popup.cpp query_once's input_context("YESNO") loop). Same shape as the UILIST/PICKUP queues:
    // only a BLOCKING read (timeout < 0), only while the asking context is "YESNO", only while actions
    // remain. LEFT/RIGHT/CONFIRM are all registered in the "YESNO" context (src/popup.cpp:282-284); the real
    // query_once loop moves the cursor on LEFT/RIGHT and, on CONFIRM, sets res.action = options[cur].action
    // (the backend never sets the result). Only ever non-empty while a query_popup transaction is armed (the
    // witnessed deployed-furniture take-down query_yn); a drained queue falls through to the guard below.
    if( timeout < 0 && category == query_popup_category
        && session.query_popup_cursor < session.query_popup_queue.size() ) {
        const auto &front = session.query_popup_queue[session.query_popup_cursor];
        if( ranges::contains( registered_actions, front ) ) {
            query_popup_served_action = front;
            ++session.query_popup_cursor;
            ++session.query_popup_served;
            return &query_popup_served_action;
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
