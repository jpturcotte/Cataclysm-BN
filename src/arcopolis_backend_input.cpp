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
#include "creature.h"           // Creature::is_monster/as_monster/is_npc (Spike 27B source classify)
#include "filesystem.h"         // ensure_valid_file_name
#include "monster.h"            // monster::type (Spike 27B attacker type id)
#include "mtype.h"              // mtype::id (Spike 27B attacker type id)
#include "string_formatter.h"   // string_format
#include "type_id.h"            // mtype_id::str (Spike 27B attacker type id)

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

/// Per-class STATE for ONE backend-driven prompt transaction (the PICKUP / UILIST / QUERY_POPUP families).
/// Grouping the previously-scattered `<class>_transaction` / `<class>_opened` / `<class>_queue` /
/// `<class>_cursor` / `<class>_served` booleans here makes each family visible in ONE place. This is STATE
/// ONLY -- it has no methods and does NOT genericize behavior: every family keeps its OWN DISTINCT serve
/// branch (backend_nested_input_action), resolve function, gate predicate, and RAII guard. The class-specific
/// extras (answer source, outcome, witness id, examine precondition) stay as named fields on the owning
/// family below. See the backend UI / prompt boundary block at the top of arcopolis_backend_input.h.
struct prompt_transaction {
    bool armed = false;             ///< the per-transaction un-abort gate is on (a drive is in flight)
    bool opened = false;            ///< a real prompt was exposed (set by the family's resolve step)
    std::optional<int> step_index;  ///< the arming command's step index (transcript correlation)
    std::vector<std::string> queue; ///< registered actions to serve to the engine's own loop, in order
    std::size_t cursor = 0;         ///< next queue index to serve
    int served = 0;                 ///< actions served so far (the prompt_completed count)
};

/// Translation-unit-local backend session. A single instance; begin/end toggle `active`. While `active`,
/// game::handle_action() pulls its per-iteration action from next_backend_action() (the seam in
/// handle_action.cpp), so the engine's do_turn runs verbatim with the backend as its input source. The
/// served prompt families are grouped below, one prompt_transaction each (+ their class-specific extras),
/// so the transaction state is no longer a flat scattering of booleans.
struct backend_session {
    bool active = false;
    std::vector<arcopolis::script_step> steps;
    std::size_t cursor = 0;
    std::string export_dir;
    int export_index = 0;
    bool done = false;
    std::optional<arcopolis::command_error> failure;
    arcopolis::backend_action_source live_source;  ///< Spike 9B: replaces the steps walk when set

    // --- One-shot nested direction answer (Spike 11A). NOT a queue: a single armed answer to the
    //     examine/pickup "where?" chooser, kept (consumed) until the seam return. Its own slot type. ---
    std::optional<nested_input_slot> nested;       ///< the one-shot nested-input answer
    int nested_guard_fires = 0;                    ///< guard fires for the current command

    // --- PICKUP family (Spike 12A): the OLD "PICKUP" item menu. The WITNESSED old-pickup path, NOT generic
    //     pickup UI. `pickup.armed` is set ONLY by a top-level pickup command (backend_arm_pickup_transaction). ---
    prompt_transaction pickup;
    arcopolis::backend_prompt_source
    prompt_source;  ///< live pickup menu-answer channel (null in script/one-shot)
    arcopolis::pickup_command_outcome pickup_outcome =
        arcopolis::pickup_command_outcome::ok;       ///< Spike 12A follow-up: unsupported sub-prompt outcome;
    ///< survives clear_stale (it is the command's result, consumed + reset by the response writer / script
    ///< seam-return check), so it is deliberately NOT part of the cleared prompt_transaction above

    // --- UILIST family (Spike 13B vehicle-source; Spike 14 secondary capacity): two WITNESSED uilists, NOT
    //     generic uilist. backend_uilist_transaction_active() == active && uilist.armed. ---
    prompt_transaction uilist;
    arcopolis::backend_uilist_prompt_source
    uilist_prompt_source;                            ///< live uilist answer channel (null elsewhere)

    // --- QUERY_POPUP family (Spike 15): ONE witnessed deployed-furniture take-down query_yn, NOT generic
    //     query_popup. backend_query_popup_transaction_active() == active && query_popup.armed. ---
    prompt_transaction query_popup;
    arcopolis::backend_query_popup_source
    query_popup_source;                              ///< live query_yn answer channel (null elsewhere)
    std::string
    query_popup_witness;                 ///< which call site armed it (emitted in prompt_opened)
    bool examine_query_popup_command =
        false;                                       ///< a live examine armed the precondition the guard checks

    // --- Spike 16 non-live SCRIPT prompt answers: the active command's declared answers + consume cursor.
    //     Loaded at each command dispatch (next_backend_action); consumed in order by the script prompt
    //     sources; leftover entries at the seam return FAIL LOUD (clear_stale_scripted_prompt_answers).
    //     Empty in live mode. ---
    std::vector<arcopolis::script_prompt_answer> script_prompt_answers;
    std::size_t script_prompt_cursor = 0;            ///< next script_prompt_answers index to consume
    std::optional<int>
    script_prompt_step_index;     ///< the arming command's step index (transcript correlation)

    // --- Spike 20: an UNARMED player-visible prompt/query was reached during this session (a test_mode
    //     abort that would otherwise silently default/cancel). Recorded by backend_report_unexpected_prompt
    //     at the abort site. In NON-LIVE mode that sets `failure`+`done` (surfaced post-do_turn/post-loop as
    //     exit 14); in LIVE mode it sets THIS recoverable pending error instead (no done/failure), which the
    //     per-request runner consumes -> a visibly-failed ok=false response, session stays open. ---
    std::optional<arcopolis::command_error> unexpected_prompt_pending;

    // --- Spike 27B: attacker-attributed avatar-damage events recorded at the Character::apply_damage
    //     funnel (gated tap, src/character.cpp). DRAINED per snapshot by backend_take_avatar_damage_taken(),
    //     so a snapshot's avatar.damage_taken[] is the event window since the prior snapshot. Avatar-only by
    //     construction (the tap gates on is_avatar()); cleared with the session by end_backend_session(). ---
    std::vector<arcopolis::avatar_damage_record> avatar_damage;
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
}

/// Spike 12A: close out a pickup transaction at the seam return -- the "PICKUP" menu loop has run to
/// completion (or cancel), so record the bookend (how many registered actions the loop consumed) and
/// clear the queue so nothing leaks into a later command. Only emit prompt_completed if a prompt was
/// actually OPENED: a pickup that armed the transaction but never reached the menu (empty target / no
/// items / cancelled "Pickup where?") opened nothing, and a phantom prompt_completed (actions_served:0)
/// with no matching prompt_opened would be a transcript lie.
auto clear_stale_pickup_transaction() -> void
{
    if( session.pickup.armed && session.pickup.opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.pickup.step_index,
            .actions_served = session.pickup.served,
        } );
    }
    session.pickup.armed = false;
    session.pickup.opened = false;
    session.pickup.step_index.reset();
    session.pickup.queue.clear();
    session.pickup.cursor = 0;
    session.pickup.served = 0;
}

/// Spike 13B: defensively close out any uilist transaction at the seam return. The normal path clears it
/// synchronously via backend_end_uilist_transaction() (a scope guard in src/pickup.cpp) the instant the
/// submenu closes, so this almost never fires; it guards a leak (an early return that skipped the guard)
/// by bookending the missing prompt_completed and clearing the state, so nothing leaks into the next
/// command's prompts.
auto clear_stale_uilist_transaction() -> void
{
    if( session.uilist.armed && session.uilist.opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.uilist.step_index,
            .actions_served = session.uilist.served,
            .kind = "uilist",
        } );
    }
    session.uilist.armed = false;
    session.uilist.opened = false;
    session.uilist.step_index.reset();
    session.uilist.queue.clear();
    session.uilist.cursor = 0;
    session.uilist.served = 0;
}

/// Spike 15: defensively close any leaked query_popup transaction at the seam return. The normal path
/// clears it synchronously via the witness guard the instant the witnessed query_yn returns (well before
/// here), so this almost never fires; it bookends a missing prompt_completed and clears the state so
/// nothing leaks into the next command's prompts. Also clears the per-command examine query_popup
/// precondition (the gate the witness guard checks).
auto clear_stale_query_popup_transaction() -> void
{
    if( session.query_popup.armed && session.query_popup.opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.query_popup.step_index,
            .actions_served = session.query_popup.served,
            .kind = "query_popup",
        } );
    }
    session.query_popup.armed = false;
    session.query_popup.opened = false;
    session.query_popup_witness.clear();
    session.query_popup.queue.clear();
    session.query_popup.cursor = 0;
    session.query_popup.served = 0;
    // Spike 15: clear the per-command examine query_popup precondition (the gate the witness guard checks).
    session.examine_query_popup_command = false;
    session.query_popup.step_index.reset();
}

/// Force-clears ALL stale backend prompt state at a return to the top-level seam, by delegating to the
/// per-concern helpers above IN TRANSCRIPT ORDER: the nested one-shot direction slot (Spike 11A), then the
/// pickup (12A), uilist (13B/14), and query_popup (15) transactions. The nested helper runs FIRST so its
/// nested_input_unconsumed event precedes any prompt bookends -- exactly as before this was split out of one
/// monolithic clear_stale_nested_input(). The pickup_command_outcome is deliberately NOT cleared here: it is
/// the command's result, consumed by the live response writer and reset by backend_arm_pickup_transaction().
auto clear_stale_backend_prompt_state() -> void
{
    clear_stale_nested_input();
    clear_stale_pickup_transaction();
    clear_stale_uilist_transaction();
    clear_stale_query_popup_transaction();
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

/// Records a fatal non-live script-prompt failure (Spike 16): sets session.failure (mapped to exit 13) and
/// `done` so the steps walk stops and run_script aborts honestly with session_end status "error". Logs a
/// typed `error` transcript record at the point of detection; when a prompt was open the calling source logs
/// the per-prompt `prompt_failed` detail FIRST (Amendment 1: prompt_failed precedes any engine loop-exit
/// action, so an escape QUIT/CONFIRM is never misread as a user cancel). First failure wins. Inert outside a
/// session.
auto record_script_prompt_failure( const std::string &detail,
                                   const std::optional<int> &step_index ) -> void
{
    if( !session.active || session.failure ) {
        return;
    }
    session.failure = arcopolis::command_error{
        .kind = arcopolis::command_error_kind::script_prompt_failed,
        .detail = detail,
    };
    session.done = true;
    arcopolis::session_log_error( {
        .step_index = step_index,
        .kind = arcopolis::command_error_kind::script_prompt_failed,
        .detail = detail,
    } );
}

/// Peeks the next declared script prompt answer and checks it matches the open prompt's class (and title,
/// when one is supplied -- the "menu" hook has none). On a match returns the answer (the caller validates
/// choice/cancel); on a missing answer / kind mismatch / title mismatch it logs `prompt_failed` (the
/// per-prompt reason + detail) then records the fatal failure and returns nullptr. Does NOT advance the
/// cursor (the caller advances only on a fully-accepted answer). Spike 16.
auto match_scripted_answer( const std::string &expected_kind, const std::string *title,
                            const std::optional<int> &step_index )
-> const arcopolis::script_prompt_answer * // *NOPAD*
{
    // First-failure-wins, extended to the transcript (gemini PR#44 review): once a fatal script-prompt
    // failure is recorded, a LATER prompt opened during the same engine unwind (e.g. a second secondary-
    // capacity uilist while picking up multiple over-capacity items) must not be answered or log a second
    // prompt_failed. record_script_prompt_failure is already first-failure-wins, but session_log_prompt_failed
    // is not -- so guard here, the single point every script source funnels through. All callers treat a
    // nullptr return as "serve the loop-exit", so the in-flight prompt closes cleanly without being driven.
    if( session.failure ) {
        return nullptr;
    }
    if( session.script_prompt_cursor >= session.script_prompt_answers.size() ) {
        const auto detail = string_format(
                                "a '%s' prompt opened but the script declares no answer for it", expected_kind.c_str() );
        arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                .reason = "no_scripted_answer", .detail = detail } );
        record_script_prompt_failure( detail, step_index );
        return nullptr;
    }
    const arcopolis::script_prompt_answer &ans =
        session.script_prompt_answers[session.script_prompt_cursor];
    if( ans.kind != expected_kind ) {
        const auto detail = string_format(
                                "scripted answer kind '%s' does not match the open '%s' prompt",
                                ans.kind.c_str(), expected_kind.c_str() );
        arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                .reason = "kind_mismatch", .detail = detail } );
        record_script_prompt_failure( detail, step_index );
        return nullptr;
    }
    if( title ) {
        if( ans.title_exact && *ans.title_exact != *title ) {
            const auto detail = string_format(
                                    "scripted title_exact '%s' does not equal the prompt title '%s'",
                                    ans.title_exact->c_str(), title->c_str() );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "title_mismatch", .detail = detail } );
            record_script_prompt_failure( detail, step_index );
            return nullptr;
        }
        if( ans.title_contains && title->find( *ans.title_contains ) == std::string::npos ) {
            const auto detail = string_format(
                                    "scripted title_contains '%s' is not a substring of the prompt title '%s'",
                                    ans.title_contains->c_str(), title->c_str() );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "title_mismatch", .detail = detail } );
            record_script_prompt_failure( detail, step_index );
            return nullptr;
        }
    }
    return &ans;
}

/// Shared single-select script matcher for the uilist / query_popup sources: matches the next answer (kind +
/// optional title), then accepts exactly one in-range choice, or a cancel ONLY if the prompt is cancelable.
/// Returns the chosen index, or nullopt on a legitimate cancel / a recorded fatal failure. Spike 16.
auto match_single_select_scripted( const std::string &expected_kind, const std::string &title,
                                   std::size_t choices_size, bool cancelable,
                                   const std::optional<int> &step_index ) -> std::optional<int>
{
    const arcopolis::script_prompt_answer *ans = match_scripted_answer( expected_kind, &title,
            step_index );
    if( !ans ) {
        return std::nullopt;
    }
    if( ans->cancel ) {
        if( !cancelable ) {
            const auto detail = string_format(
                                    "scripted cancel on a non-cancelable '%s' prompt", expected_kind.c_str() );
            arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                    .reason = "noncancelable", .detail = detail } );
            record_script_prompt_failure( detail, step_index );
            return std::nullopt;
        }
        ++session.script_prompt_cursor;  // legitimate cancel -> resolve serves the loop-exit QUIT
        return std::nullopt;
    }
    if( ans->choices.size() != 1 ) {
        const auto detail = string_format(
                                "the '%s' prompt is single-select; declare exactly one choice", expected_kind.c_str() );
        arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                .reason = "invalid_answer", .detail = detail } );
        record_script_prompt_failure( detail, step_index );
        return std::nullopt;
    }
    const int idx = ans->choices.front();
    if( idx < 0 || idx >= static_cast<int>( choices_size ) ) {
        const auto detail = string_format( "'%s' choice %d out of range [0, %d)",
                                           expected_kind.c_str(), idx, static_cast<int>( choices_size ) );
        arcopolis::session_log_prompt_failed( { .step_index = step_index,
                                                .reason = "choice_out_of_range", .detail = detail } );
        record_script_prompt_failure( detail, step_index );
        return std::nullopt;
    }
    ++session.script_prompt_cursor;
    return idx;
}

/// Force-clears the script prompt-answer queue at a return to the top-level seam (Spike 16), and surfaces a
/// pickup's UNSUPPORTED-sub-prompt outcome as a fail-loud script failure in script mode. Cases:
///  - **unused answers:** any answer the just-completed command did not consume is an authoring error (a
///    declared answer with no matching prompt) -- FAIL LOUD.
///  - **forced-cancel outcome (the doc-31/Spike-14 honesty gap fixed here):** a pickup can end with an
///    unsupported in-activity sub-prompt force-cancelled -- the disabled-entry secondary capacity/wield/spill
///    uilist (Spike 14's all-enabled bound, src/pickup.cpp:279-282) or a no-channel submenu. LIVE mode marks
///    that partial via backend_take_pickup_outcome() in its response writer (src/arcopolis_live.cpp); SCRIPT
///    mode has no writer, so without this the run would end status="ok"/exit 0 with the item silently left
///    behind -- the silent auto-cancel-as-success AGENTS.md forbids. In script mode (no live_source) we read
///    the outcome here and FAIL LOUD on a non-ok value. Live mode is gated out (live_source set) -- its
///    writer owns + resets the outcome before the next seam return, so this never double-consumes there.
/// Both are skipped once a fatal failure is already recorded (don't double-mark). Then the queue is cleared
/// so nothing leaks into the next command. Inert in live mode (the queue is never loaded there).
auto clear_stale_scripted_prompt_answers() -> void
{
    if( !session.live_source && !session.failure
        && arcopolis::backend_take_pickup_outcome() != arcopolis::pickup_command_outcome::ok ) {
        record_script_prompt_failure(
            "a pickup reached an in-activity sub-prompt that script mode does not drive (e.g. a "
            "disabled-entry secondary capacity/wield/spill uilist -- Spike 14's all-enabled bound); the "
            "over-capacity item was left behind. Failing loud rather than reporting a silent partial as full "
            "success.",
            session.script_prompt_step_index );
    }
    if( !session.failure
        && session.script_prompt_cursor < session.script_prompt_answers.size() ) {
        const auto unused =
            static_cast<int>( session.script_prompt_answers.size() - session.script_prompt_cursor );
        record_script_prompt_failure(
            string_format( "%d scripted prompt answer(s) were not consumed by the command "
                           "(a declared answer had no matching prompt)", unused ),
            session.script_prompt_step_index );
    }
    session.script_prompt_answers.clear();
    session.script_prompt_cursor = 0;
    session.script_prompt_step_index.reset();
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

auto arcopolis::backend_record_avatar_damage( const Creature &source,
        arcopolis::avatar_damage_record event ) -> void
{
    if( !session.active ) {
        return;  // inert outside a session (the apply_damage call site also gates -- defence in depth)
    }
    // Classify the engine's in-scope attacker INTO the caller's event. The category discrimination the
    // witness relies on (mon_zombie vs the stationary ally NPC vs terrain) is done in the FIXTURE +
    // regression, never here: this only reads the raw kind + type id off `source`, the engine's ground truth.
    if( source.is_monster() ) {
        event.source_kind = "monster";
        event.source_type_id = source.as_monster()->type->id.str();
    } else if( source.is_npc() ) {
        event.source_kind = "npc";  // stable NPC type identity stays deferred (Spike 7A npc export v0)
    } else {
        event.source_kind =
            "creature";  // unreached for the witnessed melee; never the avatar (source != this)
    }
    session.avatar_damage.push_back( std::move( event ) );
}

auto arcopolis::backend_take_avatar_damage_taken() -> std::vector<arcopolis::avatar_damage_record>
{
    auto out = std::move( session.avatar_damage );
    session.avatar_damage.clear();  // a moved-from vector is valid-but-unspecified; force a known-empty buffer
    return out;
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

auto arcopolis::backend_report_unexpected_prompt( const std::string &family,
        const std::string &site ) -> void
{
    // Spike 20. Called from the engine's test_mode prompt-abort sites (e.g. query_popup::query_once) when an
    // UNARMED player-visible prompt is reached during an active session -- the abort would otherwise silently
    // default/cancel and report a hidden lost interaction as success. Inert outside a session, so cata_test /
    // normal play are unchanged (the abort site still takes its normal default). This is a SEPARATE,
    // generically-named channel from record_script_prompt_failure (it is reached from live and one-shot too,
    // not just scripts) but reuses the SAME session.failure storage + session_log_error plumbing. The
    // signature takes NO step_index on purpose: generic UI code must not know Arcopolis script internals -- the
    // current command's step index is inferred here for transcript correlation only.
    if( !session.active ) {
        return;
    }
    const auto detail = string_format(
                            "an unsupported player-visible prompt (%s, at %s) was reached during an active Arcopolis "
                            "session but no matching backend transaction was armed; failing loud rather than silently "
                            "defaulting/cancelling it (a hidden lost interaction)",
                            family.c_str(), site.c_str() );
    // Best-effort transcript correlation: the examine precondition / armed query_popup step, else the script
    // command step, else absent (one-shot has neither).
    const auto step_index = session.query_popup.step_index
                            ? session.query_popup.step_index
                            : session.script_prompt_step_index;
    if( session.live_source ) {
        // LIVE: recoverable. The per-request runner consumes this -> a visibly-failed ok=false response; the
        // session stays open (the engine already handled query_once's fallback as a safe cancel/default).
        // First report wins; do NOT set failure/done (that would end the live session). Mark the command
        // failed in the transcript with the RECOVERABLE `prompt_failed` marker, NOT an `error` event -- in
        // the live transcript an `error` means the session FAILED (src/arcopolis_live.cpp), which this does
        // not. This still satisfies "the transcript must mark the command failed" without faking a fatal end.
        if( !session.unexpected_prompt_pending ) {
            session.unexpected_prompt_pending = arcopolis::command_error{
                .kind = arcopolis::command_error_kind::unexpected_prompt,
                .detail = detail,
            };
            arcopolis::session_log_prompt_failed( {
                .step_index = step_index,
                .reason = "unexpected_prompt",
                .detail = detail,
            } );
        }
        return;
    }
    // NON-LIVE (script / one-shot): fatal. Set failure + done so the post-do_turn (one-shot) / post-loop
    // (run_script) backend_session_failure() check surfaces exit 14 and the steps walk stops. First failure
    // wins (shared with record_script_prompt_failure).
    if( session.failure ) {
        return;
    }
    session.failure = arcopolis::command_error{
        .kind = arcopolis::command_error_kind::unexpected_prompt,
        .detail = detail,
    };
    session.done = true;
    arcopolis::session_log_error( {
        .step_index = step_index,
        .kind = arcopolis::command_error_kind::unexpected_prompt,
        .detail = detail,
    } );
}

auto arcopolis::backend_take_unexpected_prompt_error() -> std::optional<command_error>
{
    // Spike 20 (live): return and clear the recoverable pending unexpected-prompt error. The live runner calls
    // this after each request's do_turn; a non-null result means the command reached an unarmed prompt and must
    // be reported as a visibly-failed ok=false response (never success), with the session left open.
    const auto pending = session.unexpected_prompt_pending;
    session.unexpected_prompt_pending.reset();
    return pending;
}

auto arcopolis::next_backend_action() -> action_id
{
    // Spike 11A: control is back at the top-level seam, so the previous command's dispatch is complete
    // and any armed-but-unconsumed nested answer / prompt transaction is stale -- force-clear ALL of it
    // (with its transcript events) BEFORE the live pull below, so the events precede the pending live
    // response written inside the pull and can never leak into the next command's prompts.
    clear_stale_backend_prompt_state();
    // Spike 16: also force-clear the previous command's scripted prompt-answer queue before the next command
    // loads its own. Any answer the just-completed command did not consume is an authoring error and FAILS
    // LOUD here (a declared answer with no matching prompt).
    clear_stale_scripted_prompt_answers();
    // Spike 9B live mode: the session's pull source replaces the steps walk entirely. It runs at this
    // same faithful input-loop instant and owns its exports/termination (backend_mark_input_done()).
    if( session.live_source ) {
        return session.live_source();
    }
    // Spike 16: a mid-command fatal script-prompt failure set `done` (and session.failure); stop the steps
    // walk so no further steps run -- the cursor has already advanced past the failed command. run_script's
    // post-loop check surfaces session.failure as the exit code (13) with session_end status "error".
    if( session.done ) {
        return ACTION_NULL;
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
        // Spike 11A/16: arm the one-shot direction answer for examine AND pickup -- both use the
        // allow_vertical=false "Examine/Pickup where?" chooser. AFTER the command event (arming emits
        // nothing, so every nested_input_* event of this dispatch orders after its command event).
        if( ( step.command == "examine" || step.command == "pickup" ) && resolved ) {
            if( const auto answer = target_direction_nested_answer( step.direction ) ) {
                backend_arm_nested_input( { .action = *answer,
                                            .direction = step.direction,
                                            .step_index = step_index } );
            }
        }
        // Spike 16: arm the prompt transactions a scripted prompted command needs (mirroring
        // live_next_action) and load this command's declared answers for the script prompt sources to
        // consume in order. A `pickup` reaches the old "PICKUP" menu (and possibly a vehicle-source /
        // secondary-capacity uilist); an `examine` of a deployed furniture reaches the take-down query_yn.
        // run_script installs the script_*_prompt sources, so these feed the SAME backend_resolve_* path as
        // live mode. Non-prompt commands (move/wait) carry no declared answers (parser-enforced), so the
        // load is a no-op for them.
        if( resolved ) {
            if( step.command == "pickup" ) {
                backend_arm_pickup_transaction( step_index );
            } else if( step.command == "examine" ) {
                backend_arm_examine_query_popup_command( step_index );
            }
            backend_load_scripted_prompt_answers( step.prompt_answers, step_index );
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
    return session.active && session.pickup.armed;
}

auto arcopolis::backend_arm_pickup_transaction( const std::optional<int> &step_index ) -> void
{
    // Inert outside a session, like every other public mutator.
    if( !session.active ) {
        return;
    }
    session.pickup.armed = true;
    session.pickup.opened =
        false;  // set true only once a real menu is exposed (backend_resolve_pickup_choice)
    session.pickup.step_index = step_index;
    session.pickup.queue.clear();
    session.pickup.cursor = 0;
    session.pickup.served = 0;
    session.pickup_outcome = pickup_command_outcome::ok;  // fresh per pickup command
}

auto arcopolis::backend_report_pickup_unsupported_submenu() -> void
{
    // Inert unless a pickup transaction is armed (defense in depth: the engine call site already gates on
    // backend_pickup_transaction_active()). The vehicle submenu fires BEFORE the menu opens, so no
    // prompt_completed will bookend this command -- the force-cancel event is the whole record.
    if( !session.active || !session.pickup.armed ) {
        return;
    }
    session.pickup_outcome = pickup_command_outcome::unsupported_submenu;
    session_log_prompt_force_cancelled( {
        .step_index = session.pickup.step_index,
        .kind = "vehicle_submenu",
        .reason = "the 'Get items from where?' vehicle-cargo submenu is not driven by the pickup "
        "transaction; failed loud (no items taken)",
    } );
}

auto arcopolis::backend_report_pickup_secondary_forced_cancel() -> void
{
    if( !session.active || !session.pickup.armed ) {
        return;
    }
    session.pickup_outcome = pickup_command_outcome::secondary_forced_cancel;
    session_log_prompt_force_cancelled( {
        .step_index = session.pickup.step_index,
        .kind = "secondary_capacity",
        .reason = "a secondary capacity/wield/spill prompt is not driven by the pickup transaction; "
        "the item that does not fit is left behind (truthful partial pickup)",
    } );
}

auto arcopolis::backend_report_pickup_orphaned_secondary() -> void
{
    // Fires ONLY for the orphaned case: a backend session is active but NO pickup transaction is armed (a
    // multi-tick pickup activity resumed on a later do_turn, after clear_stale_backend_prompt_state cleared
    // the transaction at the seam return). Inert during normal play (no session) and inert while a transaction
    // IS armed (the drive / no-channel paths own that case -- this would double-report otherwise). Logs a
    // transcript prompt_force_cancelled so the engine's own test_mode CANCEL is MARKED, never silent. Sets
    // NO pickup_outcome: there is no owed command response for this resumed-activity prompt to mark, and
    // mutating the outcome could leak a partial marker into an unrelated later response.
    if( !session.active || session.pickup.armed ) {
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
    if( !session.active || !session.pickup.armed ) {
        return;
    }
    namespace ranges = std::ranges;
    // Record the opened prompt with the engine's REAL choices (the transcript's survey data).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.pickup.step_index, .kind = "menu" };
    for( const pickup_prompt_choice &c : choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.pickup.opened =
        true;  // a real menu was exposed; clear_stale may now bookend it with prompt_completed
    // Ask the live client. A null channel (script/one-shot) yields cancel, so the menu auto-cancels there.
    const auto answer = session.prompt_source
                        ? session.prompt_source( choices )
                        : std::optional<std::vector<int>> {};
    session.pickup.cursor = 0;
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
        session.pickup.queue.clear();
        int cursor = 0;
        for( const int idx : picks ) {
            session.pickup.queue.insert( session.pickup.queue.end(),
                                         static_cast<std::size_t>( idx - cursor ), "DOWN" );
            session.pickup.queue.emplace_back( "RIGHT" );
            cursor = idx;
        }
        session.pickup.queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.pickup.step_index,
                                                .choices = picks,
                                                .actions = session.pickup.queue } );
    } else {
        // Cancel / EOF / absent channel: ESC-equivalent. QUIT is the loop-exit action.
        session.pickup.queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.pickup.step_index,
                .reason = session.prompt_source ? "client_cancel" : "no_channel" } );
    }
}

auto arcopolis::backend_uilist_transaction_active() -> bool
{
    return session.active && session.uilist.armed;
}

auto arcopolis::backend_uilist_prompt_available() -> bool
{
    return session.active && static_cast<bool>( session.uilist_prompt_source );
}

auto arcopolis::backend_begin_uilist_transaction() -> void
{
    // Gated on an armed pickup transaction (the only backend-driven uilist arises inside a live pickup).
    // Inert otherwise. MUST run before the uilist is constructed: the default ctor's init() reads
    // backend_uilist_transaction_active() to decide the test_mode abort.
    if( !session.active || !session.pickup.armed ) {
        return;
    }
    session.uilist.armed = true;
    session.uilist.opened = false;  // set true only once a real uilist prompt is exposed (resolve)
    session.uilist.step_index = session.pickup.step_index;
    session.uilist.queue.clear();
    session.uilist.cursor = 0;
    session.uilist.served = 0;
}

auto arcopolis::backend_resolve_uilist_choice( const backend_uilist_prompt_request &request ) ->
void
{
    // Inert unless a uilist transaction is armed (backend_begin_uilist_transaction set it). Defense in
    // depth: the engine call site already gates on it.
    if( !session.active || !session.uilist.armed ) {
        return;
    }
    // Record the opened prompt with the engine's REAL uilist choices (read from amenu.entries by the caller).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.uilist.step_index,
            .kind = request.kind };
    for( const pickup_prompt_choice &c : request.choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.uilist.opened = true;
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
        session.uilist.cursor = 0;
        session.uilist.served = 0;
        session.uilist.queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.uilist.step_index,
                .reason = "disabled_entry_unsupported",
                .kind = request.kind } );
        return;
    }
    // Ask the live client for a SINGLE choice. The caller only reaches here with a channel present
    // (it checks backend_uilist_prompt_available() first), but a null channel yields cancel for safety.
    const auto answer = session.uilist_prompt_source
                        ? session.uilist_prompt_source( request )
                        : std::optional<int> {};
    session.uilist.cursor = 0;
    session.uilist.served = 0;
    const auto valid = answer && *answer >= 0 && *answer < static_cast<int>( request.choices.size() );
    if( valid ) {
        // Translate the chosen entry index into the registered keystrokes a GUI player would press: from the
        // menu's start at entry 0, DOWN once per step down to the chosen entry, then CONFIRM. The real uilist
        // loop (src/ui.cpp uilist::query) consumes these through input_context::handle_input and sets
        // amenu.ret = entries[selected].retval -- the backend never touches ret/selected.
        session.uilist.queue.clear();
        session.uilist.queue.insert( session.uilist.queue.end(),
                                     static_cast<std::size_t>( *answer ), "DOWN" );
        session.uilist.queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.uilist.step_index,
                                                .choices = std::vector<int> { *answer },
                                                .actions = session.uilist.queue,
                                                .kind = request.kind } );
    } else {
        // Cancel / EOF / out-of-range / absent channel: serve the registered QUIT (the GUI ESC), which the
        // real loop turns into amenu.ret = UILIST_CANCEL (allow_cancel registers QUIT, src/ui.cpp:224).
        session.uilist.queue = { nested_cancel_quit };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.uilist.step_index,
                .reason = session.uilist_prompt_source ? "client_cancel" : "no_channel",
                .kind = request.kind } );
    }
}

auto arcopolis::backend_end_uilist_transaction() -> void
{
    // Inert when not armed (safe to call from a scope guard on the GUI path, or twice). Idempotent.
    if( !session.uilist.armed ) {
        return;
    }
    // Bookend the transaction with how many registered actions the uilist loop consumed -- only if a real
    // prompt opened (resolve sets uilist.opened; a path that armed but never reached the menu opened nothing).
    if( session.uilist.opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.uilist.step_index,
            .actions_served = session.uilist.served,
            .kind = "uilist",
        } );
    }
    session.uilist.armed = false;
    session.uilist.opened = false;
    session.uilist.step_index.reset();
    session.uilist.queue.clear();
    session.uilist.cursor = 0;
    session.uilist.served = 0;
}

arcopolis::uilist_transaction_guard::~uilist_transaction_guard()
{
    arcopolis::backend_end_uilist_transaction();
}

auto arcopolis::backend_query_popup_transaction_active() -> bool
{
    return session.active && session.query_popup.armed;
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
    session.query_popup.step_index = step_index;
}

auto arcopolis::backend_begin_query_popup_transaction( const std::string &witness_id ) -> void
{
    // Gated on an armed examine command precondition AND an available prompt channel (the only
    // backend-driven query_popup arises inside a live examine, which always has a channel). The channel
    // gate matters for a misconfigured session: without a `query_popup_source` there is nothing to ask, so
    // we must NOT arm -- query_yn then takes its normal test_mode abort (returns NO) instead of driving a
    // loop with no answer channel (the AGENTS.md "don't drive a prompt you can't answer" rule; mirrors the
    // Spike 13B/14 uilist call site, which checks backend_uilist_prompt_available() before driving). Inert
    // otherwise -- so the witness guard at iexamine::deployed_furniture is a no-op in normal play, non-live,
    // and any examine that did not arm the precondition. MUST run before query_yn's query_popup reaches
    // query_once (which reads backend_query_popup_transaction_active()).
    if( !backend_examine_query_popup_command_active() || !backend_query_popup_prompt_available() ) {
        return;
    }
    session.query_popup.armed = true;
    session.query_popup.opened = false;  // set true only once a real prompt is exposed (resolve)
    session.query_popup_witness = witness_id;
    session.query_popup.queue.clear();
    session.query_popup.cursor = 0;
    session.query_popup.served = 0;
}

auto arcopolis::backend_resolve_query_popup_choice( const backend_query_popup_request &request ) ->
void
{
    // Inert unless a query_popup transaction is armed (the witness guard set it). Defense in depth: the
    // query_yn drive-block already gates on backend_query_popup_transaction_active().
    if( !session.active || !session.query_popup.armed ) {
        return;
    }
    // Record the opened prompt with the engine's REAL query_popup options (read from the constructed popup).
    auto opened = arcopolis::prompt_opened_event{ .step_index = session.query_popup.step_index,
            .kind = request.kind, .witness = session.query_popup_witness };
    for( const pickup_prompt_choice &c : request.choices ) {
        opened.choices.push_back( { .index = c.index, .text = c.text, .enabled = c.enabled } );
    }
    arcopolis::session_log_prompt_opened( opened );
    session.query_popup.opened = true;
    // Ask the live client for a SINGLE choice. The answer channel is an invariant here:
    // backend_begin_query_popup_transaction refuses to arm the transaction without a registered
    // query_popup_source (its backend_query_popup_prompt_available() gate), and the source is never cleared
    // mid-session, so it is non-null whenever this gated resolve runs. A null RETURN (EOF / closed client)
    // takes the closed-default branch below.
    const auto answer = session.query_popup_source( request );
    session.query_popup.cursor = 0;
    session.query_popup.served = 0;
    const auto valid = answer && *answer >= 0 && *answer < static_cast<int>( request.choices.size() );
    if( valid ) {
        // Translate the chosen option index into the registered keystrokes a GUI player would press: from the
        // popup's REAL starting cursor, navigate the horizontal button row LEFT (toward 0) or RIGHT (toward
        // the end) to the chosen option, then CONFIRM. CONFIRM is filter-free: query_once sets res.action =
        // options[cur].action without consulting the per-option key filter (src/popup.cpp:325-329), so this
        // is robust regardless of FORCE_CAPITAL_YN and the synthetic input event. The real query_once loop
        // moves the cursor and sets the result -- the backend never sets it.
        session.query_popup.queue.clear();
        const int start = static_cast<int>( request.cursor_start );
        const int target = *answer;
        if( target < start ) {
            session.query_popup.queue.insert( session.query_popup.queue.end(),
                                              static_cast<std::size_t>( start - target ), "LEFT" );
        } else if( target > start ) {
            session.query_popup.queue.insert( session.query_popup.queue.end(),
                                              static_cast<std::size_t>( target - start ), "RIGHT" );
        }
        session.query_popup.queue.emplace_back( "CONFIRM" );
        arcopolis::session_log_prompt_answered( { .step_index = session.query_popup.step_index,
                                                .choices = std::vector<int> { target },
                                                .actions = session.query_popup.queue,
                                                .kind = request.kind } );
    } else {
        // EOF / closed client: the source returned no choice. query_yn is NOT cancelable -- no QUIT is
        // registered, so there is nothing to serve as a cancel. To avoid a headless hang, CONFIRM the popup's
        // pre-selected visible default (the starting cursor -- NO for query_yn). This is logged as a CLOSED
        // prompt, NOT prompt_answered: the client did not intentionally choose the default; the engine fell to
        // its own visible default because the channel closed. (An out-of-range answer lands here too -- same
        // safe default, same closed record.)
        session.query_popup.queue = { "CONFIRM" };
        arcopolis::session_log_prompt_cancelled( { .step_index = session.query_popup.step_index,
                .reason = "noncancelable_closed",
                .kind = request.kind } );
    }
}

auto arcopolis::backend_end_query_popup_transaction() -> void
{
    // Inert when not armed (safe to call from the witness guard on the GUI path, or twice). Idempotent.
    if( !session.query_popup.armed ) {
        return;
    }
    // Bookend the transaction with how many registered actions the query_popup loop consumed -- only if a
    // real prompt opened (resolve sets query_popup.opened; a guard that armed but whose query_yn never
    // reached query_once opened nothing).
    if( session.query_popup.opened ) {
        arcopolis::session_log_prompt_completed( {
            .step_index = session.query_popup.step_index,
            .actions_served = session.query_popup.served,
            .kind = "query_popup",
        } );
    }
    session.query_popup.armed = false;
    session.query_popup.opened = false;
    session.query_popup_witness.clear();
    session.query_popup.queue.clear();
    session.query_popup.cursor = 0;
    session.query_popup.served = 0;
}

arcopolis::query_popup_witness_guard::query_popup_witness_guard( const std::string &witness_id )
{
    arcopolis::backend_begin_query_popup_transaction( witness_id );
}

arcopolis::query_popup_witness_guard::~query_popup_witness_guard()
{
    arcopolis::backend_end_query_popup_transaction();
}

auto arcopolis::backend_load_scripted_prompt_answers(
    const std::vector<script_prompt_answer> &answers, const std::optional<int> &step_index ) -> void
{
    // Inert outside a session, like every other public mutator. Loaded fresh at each command dispatch so the
    // consume cursor and the (Amendment-2) single-turn scope reset per command.
    if( !session.active ) {
        return;
    }
    session.script_prompt_answers = answers;
    session.script_prompt_cursor = 0;
    session.script_prompt_step_index = step_index;
}

auto arcopolis::script_pickup_prompt( const std::vector<pickup_prompt_choice> &choices ) ->
std::optional<std::vector<int>>
{
    // The script-mode counterpart of arcopolis_live's live_pickup_prompt: instead of blocking on stdin it
    // consumes the next declared answer. Returns the same internal result type (chosen indices, or nullopt
    // for cancel) so backend_resolve_pickup_choice converts it into registered actions identically.
    if( !session.active ) {
        return std::nullopt;
    }
    const auto step_index = session.pickup.step_index;
    const script_prompt_answer *ans = match_scripted_answer( "menu", nullptr, step_index );
    if( !ans ) {
        return std::nullopt;  // mismatch/missing recorded a fatal failure
    }
    if( ans->cancel ) {
        ++session.script_prompt_cursor;  // legitimate cancel (the old "PICKUP" menu is cancelable)
        return std::nullopt;
    }
    const int n = static_cast<int>( choices.size() );
    const bool any_bad = ans->choices.empty()
    || std::ranges::any_of( ans->choices, [n]( const int c ) {
        return c < 0 || c >= n;
    } );
    if( any_bad ) {
        const auto detail = string_format( "menu choice out of range [0, %d)", n );
        session_log_prompt_failed( { .step_index = step_index,
                                     .reason = "choice_out_of_range", .detail = detail } );
        record_script_prompt_failure( detail, step_index );
        return std::nullopt;
    }
    ++session.script_prompt_cursor;
    return ans->choices;
}

auto arcopolis::script_uilist_prompt( const backend_uilist_prompt_request &request ) ->
std::optional<int>
{
    if( !session.active ) {
        return std::nullopt;
    }
    return match_single_select_scripted( "uilist", request.title, request.choices.size(),
                                         request.cancelable, session.uilist.step_index );
}

auto arcopolis::script_query_popup_prompt( const backend_query_popup_request &request ) ->
std::optional<int>
{
    if( !session.active ) {
        return std::nullopt;
    }
    return match_single_select_scripted( "query_popup", request.title, request.choices.size(),
                                         request.cancelable, session.query_popup.step_index );
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
    // The three serve branches below are the WITNESSED served prompt categories documented at the top of
    // arcopolis_backend_input.h (the backend UI / prompt boundary): the "PICKUP" / "UILIST" / "YESNO"
    // queues, each gated on its OWN per-transaction flag. There is deliberately NO generic / "INVENTORY"
    // serve branch -- read that boundary block (and docs/arcopolis/40) before adding a category.
    // Spike 12A: serve the next queued registered PICKUP action to the engine's pickup menu loop. This is a
    // DISTINCT mechanism from the one-shot slot below (whose serve gate is hard-coded to DEFAULTMODE): the
    // queue feeds the SAME unmodified input_context("PICKUP") loop the keystrokes a player would press, in
    // order. Like the one-shot path, only a BLOCKING read (timeout < 0) is served; a timeout >= 0 poll
    // passes through. DOWN/RIGHT/CONFIRM/QUIT are all registered in "PICKUP" (src/pickup.cpp:722-735); if a
    // queued action somehow is not, fall through to the guard (defensive).
    if( timeout < 0 && category == pickup_menu_category
        && session.pickup.cursor < session.pickup.queue.size() ) {
        const auto &front = session.pickup.queue[session.pickup.cursor];
        if( ranges::contains( registered_actions, front ) ) {
            pickup_served_action = front;
            ++session.pickup.cursor;
            ++session.pickup.served;
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
        && session.uilist.cursor < session.uilist.queue.size() ) {
        const auto &front = session.uilist.queue[session.uilist.cursor];
        if( ranges::contains( registered_actions, front ) ) {
            uilist_served_action = front;
            ++session.uilist.cursor;
            ++session.uilist.served;
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
        && session.query_popup.cursor < session.query_popup.queue.size() ) {
        const auto &front = session.query_popup.queue[session.query_popup.cursor];
        if( ranges::contains( registered_actions, front ) ) {
            query_popup_served_action = front;
            ++session.query_popup.cursor;
            ++session.query_popup.served;
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
