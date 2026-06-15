#pragma once

#include <cstddef>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "arcopolis_command.h"  // command_error (failure surfacing)
#include "arcopolis_script.h"   // script_step (the session's step list)

// Forward declaration so next_backend_action() can return an engine action_id without including the
// heavy action.h here -- this keeps the seam translation units (handle_action.cpp, game.cpp) from
// pulling action.h via this header. The .cpp includes action.h. Matches the global enum in action.h.
enum action_id : int;

namespace arcopolis
{

/// A pull-based action source for a LIVE backend session (Spike 9B): called by next_backend_action()
/// each time the engine's input loop asks for input, exactly where the GUI would block on a keypress.
/// The source may block (e.g. reading stdin), perform inline exports at this faithful instant, and
/// signal end-of-session via backend_mark_input_done() before returning ACTION_NULL.
using backend_action_source = std::function < auto() -> action_id >;

/// One pickup-menu choice exposed to the external client, built from the engine's REAL live menu entries
/// (src/pickup.cpp stacked_here) -- never from a snapshot. `index` is the entry's position in the menu's
/// display order, which equals the DOWN-navigation distance from the chooser's start at entry 0 (Spike 12A).
struct pickup_prompt_choice {
    int index = 0;
    std::string text;     ///< the entry's engine display name (e.g. "2 rags")
    bool enabled =
        true;  ///< reserved (all exposed entries are selectable; the engine drives parent/child
    ///< marking faithfully) -- a future prompt class may use it to gray out an entry
};

/// The live pickup menu-answer channel (Spike 12A): given the engine's real choices, returns the chosen
/// menu index/indices (one or several -- multi-select), or nullopt for an explicit client cancel / EOF
/// (== the GUI player pressing ESC). Set only in live mode (arcopolis_live); null in script/one-shot
/// modes, where a pickup menu has no answer channel and auto-cancels via the existing nested-input guard.
using backend_prompt_source =
    std::function < auto( const std::vector<pickup_prompt_choice> & ) -> std::optional<std::vector<int>>
    >;

/// Inputs for an input-seam backend session (mechanism M1): the ordered steps to drive the engine with,
/// and the directory inline `export` steps write their snapshots into.
struct backend_session_options {
    std::vector<script_step> steps;  ///< the script's steps, executed in order by the provider
    std::string export_dir;          ///< directory inline `export` steps write NNN_<name>.json into
    backend_action_source
    live_source;  ///< Spike 9B live mode: when set, replaces the steps walk entirely
    backend_prompt_source
    prompt_source;  ///< Spike 12A live mode: the pickup menu-answer channel (null elsewhere)
};

/// Begins a backend input session: while it is active, game::handle_action() takes its action from
/// next_backend_action() instead of the keyboard (gated by backend_session_active()). Stores the steps +
/// export dir and resets the cursor / done / failure state. Single owner: set after g->load, cleared by
/// end_backend_session() before exit -- it MUST be false during normal play or GUI input breaks.
auto begin_backend_session( const backend_session_options &opts ) -> void;

/// Ends the session and clears all state (backend_session_active() becomes false).
auto end_backend_session() -> void;

/// True while a session is active (the load-bearing gate for both engine seams).
auto backend_session_active() -> bool;

/// True once the provider has walked past the last step (or hit an export failure). The do_turn input
/// loop's clean-stop checks this to park the turn before the bottom half.
auto backend_input_done() -> bool;

/// The input provider: returns the next step's engine action_id, performing any `export` steps inline at
/// this faithful input-loop point first. Returns ACTION_NULL (and sets backend_input_done()) when the
/// script is exhausted or an export write failed. Call site: the game::handle_action() input seam.
/// When the session has a live_source (Spike 9B), it delegates to that source instead.
auto next_backend_action() -> action_id;

/// Marks the session's input as exhausted (backend_input_done() becomes true) so do_turn's clean-stop
/// parks the turn before the bottom half. For a live_source to signal quit/EOF -- the steps walk sets
/// `done` itself. No-op while no session is active (gate inertness).
auto backend_mark_input_done() -> void;

// --- Spike 11A: one-shot nested-input answer + auto-cancel guard. During a backend session every
// input_context::handle_input() call is by definition a NESTED read (the seam intercepts the only
// top-level one), and a blocking nested read would otherwise busy-wait forever headless
// (docs/arcopolis/25). The backend therefore answers every blocking nested read: with the armed
// one-shot direction answer if the engine's direction chooser is asking, else with the context's own
// registered cancel action (== the GUI player pressing ESC), else it hard-fails the process rather
// than hang. Every intervention is a transcript event. ---

/// What an `examine` command arms for the engine's possible direction prompt: the input-context action
/// id to serve IF the chooser asks (the keystroke mirror), plus transcript correlation fields.
struct nested_input_request {
    std::string action;             ///< input-context action id to serve (e.g. "UP", "pause")
    std::string direction;          ///< the command's direction token (e.g. "move_n")
    std::optional<int> step_index;  ///< the arming command's step index
};

/// Arms the one-shot nested-input answer for the command about to be dispatched, and resets the
/// per-command guard-fire counter. Inert while no session is active. The provider force-clears any
/// stale answer at every return to the seam, so arming never stacks.
auto backend_arm_nested_input( const nested_input_request &req ) -> void;

/// True while an armed answer exists and has not been consumed (tests/diagnostics).
auto backend_nested_input_armed() -> bool;

/// Guard fires allowed within one command before the backend assumes a nested loop is ignoring its
/// cancel action and hard-fails instead of spinning (docs/arcopolis/25, "guard fire-limit").
constexpr auto nested_input_guard_fire_limit = 64;

/// What the backend does for one nested input read.
enum class nested_input_outcome {
    pass_through,      ///< timeout >= 0: a poll, not a blocking read -- the engine's own read runs untouched
    serve,             ///< serve the armed answer (one-shot)
    cancel_quit,       ///< return "QUIT", the context's registered cancel
    cancel_text_quit,  ///< return "TEXT.QUIT", the text-input context's registered cancel
    hard_fail,         ///< no servable answer and no registered cancel (or fire limit hit) -- fatal
};

/// Why the guard (rather than the serve path) answered; `none` for pass_through/serve.
enum class nested_input_guard_reason {
    none,
    no_answer,              ///< nothing armed (or already consumed)
    context_mismatch,       ///< an answer is armed but the asking context is not the direction chooser
    answer_not_registered,  ///< the chooser-category context did not register the armed action
};

/// The plain values one nested read is classified from, so the decision is unit-testable without an
/// input_context or an active session.
struct nested_input_observation {
    bool armed = false;              ///< an unconsumed answer is armed
    int timeout = -1;                ///< handle_input's timeout parameter; >= 0 polls, < 0 blocks
    std::string category;            ///< the asking context's category
    bool answer_registered = false;  ///< the asking context registered the armed action
    bool quit_registered = false;    ///< the asking context registered "QUIT"
    bool text_quit_registered = false;  ///< the asking context registered "TEXT.QUIT"
    int fires = 0;                   ///< guard fires already taken for the current command
};

/// One classified decision: the outcome plus the guard reason recorded in its transcript event.
struct nested_input_decision {
    nested_input_outcome outcome = nested_input_outcome::pass_through;
    nested_input_guard_reason reason = nested_input_guard_reason::none;
};

/// Pure classification of one nested input read (no side effects; see nested_input_observation).
auto decide_nested_input( const nested_input_observation &obs ) -> nested_input_decision;

/// The engine-side hook, called at the top of input_context::handle_input( timeout ) while a backend
/// session is active. The call site is a MEMBER of input_context, so it passes the context's private
/// `category` and `registered_actions` directly -- input_context's category/membership accessors are
/// Android-only public API (src/input.h, the `#if defined(__ANDROID__)` block), and this keeps the
/// backend decoupled from input.h entirely. Returns the action string handle_input must return
/// (stable backend-owned storage -- handle_input returns a reference), or nullptr to let the engine's
/// own read run (pass-through; also inert without an active session). Emits the matching transcript
/// event. On a hard_fail decision it writes a transcript `error` (kind nested_input_failed), prints
/// to stderr and hard-exits with exit code 12 INSTEAD of returning -- a deliberate last-resort:
/// better a fatal, observable exit than a silent headless hang (docs/arcopolis/25).
auto backend_nested_input_action( const std::string &category,
                                  const std::vector<std::string> &registered_actions,
                                  int timeout ) -> const std::string *; // *NOPAD*

// --- Spike 12A: pickup prompt/menu transaction (live mode only). The old "PICKUP" item-selection menu
// (src/pickup.cpp pick_up_from_items) is a real input_context loop; the backend drives its selection at
// LEVEL 4 -- the SAME registered actions a player presses (DOWN/RIGHT/CONFIRM), in order, consumed by
// that same UNMODIFIED loop -- never by mutating its getitem state. The external client sees a structured
// prompt and answers with a choice index; the backend translates the index into the registered-action
// queue served below. This is a DISTINCT mechanism from the one-shot nested slot (whose serve gate is
// hard-coded to the "DEFAULTMODE" direction chooser): it serves only while the asking context is the
// engine's "PICKUP" menu. ---

/// True while a TOP-LEVEL pickup command's prompt transaction is armed -- the gate src/pickup.cpp's
/// pre-loop block checks before exposing its menu. Armed ONLY for the live `pickup` command (never merely
/// because pick_up_from_items is running), so examine's auto-pickup tail finds it false and keeps
/// auto-cancelling (preserving examine_regression). Inert (false) outside a session.
auto backend_pickup_transaction_active() -> bool;

/// Arms the pickup transaction for the live command about to be dispatched (sets the flag + records its
/// step index for transcript correlation; clears any prior queue). Inert outside a session. The flag and
/// queue are force-cleared at the next top-level seam return (alongside the one-shot slot).
auto backend_arm_pickup_transaction( const std::optional<int> &step_index ) -> void;

/// Called by src/pickup.cpp's gated pre-loop block when the pickup menu opens during an armed transaction.
/// Logs `prompt_opened` with the real `choices`, asks the live client via the session's prompt_source, and
/// ARMS the registered-action queue the UNMODIFIED "PICKUP" loop then consumes: [DOWN x choice, "RIGHT",
/// "CONFIRM"] for a valid choice (logs `prompt_answered` with the exact sequence), or ["QUIT"] for a
/// cancel / EOF / absent channel (logs `prompt_cancelled`). The queue's terminal element is always the
/// loop-exit action ("CONFIRM"/"QUIT"), so the loop never exits with actions unserved. This NEVER touches
/// the menu's selection state -- the engine loop does, by reacting to the served actions. Inert unless a
/// pickup transaction is active.
auto backend_resolve_pickup_choice( const std::vector<pickup_prompt_choice> &choices ) -> void;

/// The outcome of a pickup command with respect to UNSUPPORTED in-action sub-prompts (Spike 12A follow-up).
/// A live `pickup` may meet a real engine `uilist` the transaction does not drive. In the backend
/// (test_mode=true) a `uilist` NEVER reaches input_context::handle_input -- it short-circuits to
/// UILIST_ERROR at the top of uilist::query (src/ui.cpp:918) -- so the nested-input guard cannot see it.
/// The engine call site therefore reports the outcome directly (gated on backend_pickup_transaction_active),
/// and the live response writer reads it to fail loud / mark partial. The value outlives
/// clear_stale_nested_input() (it is the command's result, consumed by the response writer at the next seam
/// entry), is reset by backend_arm_pickup_transaction(), and is read-and-reset by backend_take_pickup_outcome().
enum class pickup_command_outcome {
    ok,                  ///< no unsupported sub-prompt was encountered (clean pickup / cancel)
    unsupported_submenu, ///< the pre-menu vehicle "Get items from where?" uilist -> FAIL LOUD (no pickup)
    secondary_forced_cancel,  ///< an in-activity capacity/wield/spill uilist -> TRUTHFUL PARTIAL pickup,
    ///< marked not-full-success on the wire (what fit was carried; the rest stays)
};

/// Called by src/pickup.cpp when a live pickup transaction meets the vehicle "Get items from where?"
/// submenu (both vehicle cargo and ground items on the target tile). This is a real GUI prompt the
/// transaction cannot drive, so the command FAILS LOUD: records `unsupported_submenu` (the live writer
/// then answers unsupported_command, no pickup) and logs a `prompt_force_cancelled` event so the decline
/// is never silent. Inert unless a pickup transaction is active.
auto backend_report_pickup_unsupported_submenu() -> void;

/// Called by src/pickup.cpp when a live pickup activity meets a secondary capacity/wield/spill prompt
/// (handle_problematic_pickup) for an item that does not fit. The backend cannot drive it, so the item is
/// left behind (the engine's own behaviour) -- a TRUTHFUL PARTIAL pickup. Records `secondary_forced_cancel`
/// (the live writer marks the response partial, NOT full success) and logs a `prompt_force_cancelled`
/// event. Inert unless a pickup transaction is active.
auto backend_report_pickup_secondary_forced_cancel() -> void;

/// Reads and resets the current pickup command's unsupported-sub-prompt outcome (defaults to `ok`).
/// Called once by the live response writer when the owed pickup response is emitted. Reset to `ok`.
auto backend_take_pickup_outcome() -> pickup_command_outcome;

/// What backend_write_step_snapshot() wrote, for a live-protocol response: the snapshot's relative
/// filename plus the scalars the response echoes (turn read at the same instant as the snapshot).
struct backend_step_snapshot {
    std::string filename;  ///< relative NNN_<label>.json (not a machine-local path)
    int export_index = 0;  ///< the snapshot's 0-based export sequence number
    int turn = 0;          ///< calendar turn at the write instant (equals the snapshot's backend.turn)
};

/// Writes one non-final session snapshot (label sanitized into NNN_<label>.json) using the live
/// session's export dir + running index -- the same writer `export` steps use, so the snapshot's
/// `session` block and the transcript's `export` event stay equal by construction. Returns the written
/// info, or nullopt on failure (the failure is recorded via backend_session_failure(), `done` is set,
/// and an `error` event is logged -- the session must end). Inert (nullopt) without an active session
/// with an export dir, mirroring backend_write_final_snapshot(). (Spike 9B)
auto backend_write_step_snapshot( const std::string &label, const std::optional<int> &step_index )
-> std::optional<backend_step_snapshot>;

/// The provider's step cursor (index of the next step to process). The script runner compares this
/// across do_turn() calls to detect a stall (e.g. the input loop skipped while the avatar sleeps).
auto backend_cursor() -> std::size_t;

/// The session's recorded failure, if an inline `export` step could not be written. The runner surfaces
/// it as the process exit code after the engine loop ends.
auto backend_session_failure() -> std::optional<command_error>;

/// Writes the terminal final-on-exit snapshot (NNN_final.json, with session.final = true and a null
/// step_index) using the live session's export dir + running index. Called by run_script() on clean script
/// completion -- after do_turn returns from the clean-park path and before end_backend_session() clears
/// state. Records a write failure via backend_session_failure(); returns true on success. (Spike 3.1B)
auto backend_write_final_snapshot() -> bool;

} // namespace arcopolis
