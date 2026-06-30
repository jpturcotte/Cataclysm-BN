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

// Forward declaration so backend_record_avatar_damage() can take the engine's in-scope attacker by
// reference without this header pulling creature.h. The .cpp includes creature.h/monster.h to classify it.
class Creature;

namespace arcopolis
{

// ===========================================================================================
// THE ARCOPOLIS BACKEND UI / PROMPT BOUNDARY  (read before adding any prompt category)
//
// The backend drives a SMALL, FIXED set of WITNESSED prompt paths headlessly at "level 4": the real
// BN input_context/menu/query loop consumes backend-served REGISTERED ACTIONS and the real engine
// caller consumes the result. This is NOT a generic renderer-neutral backend UI mode -- it is a
// handful of per-transaction un-abort WITNESSES. The gate names below are deliberately CLASS-specific
// (no "ui_mode" umbrella) so a narrow witness is never mistaken for generic UI support
// (docs/arcopolis/39 §5.1; docs/arcopolis/40).
//
// Served prompt categories today -- each behind its OWN per-transaction gate, never a session flag:
//   * "DEFAULTMODE" -- one-shot direction answer to the examine/pickup "where?" chooser (Spike 11A).
//   * "PICKUP"      -- registered-action queue for the OLD pickup item menu (Spike 12A): the WITNESSED
//                      old-pickup path, NOT generic pickup UI.
//   * "UILIST"      -- backend_uilist_transaction_active() gate; two WITNESSED sites (Spike 13B/14:
//                      vehicle-source submenu; secondary capacity/wield/spill), NOT generic uilist.
//   * "YESNO"       -- backend_query_popup_transaction_active() gate; ONE WITNESSED query_yn (Spike 15:
//                      deployed-furniture take-down), NOT generic query_popup / query_yn.
//   * Spike 16 SCRIPT replay of all of the above feeds the SAME backend_resolve_* machinery; only the
//     answer TRANSPORT differs (a declared field vs a live stdin line).
//
// DELIBERATELY UNSUPPORTED -- stays FAIL-LOUD until a renderer-neutral selector design exists:
//   * INVENTORY / inventory_selector (NEW_PICKUP_MENU=true) is rejected at Arcopolis PRE-FLIGHT
//     (src/arcopolis_live.cpp / src/arcopolis_script.cpp -> unsupported_command, exit 6), NOT here.
//     Unlike uilist/query_popup it has NO single narrow test_mode abort to pierce: its real
//     input_context("INVENTORY") loop exists, but its layout/window setup is NOT renderer-neutral, so a
//     faithful witness is the START of a renderer-neutral selector architecture, not a one-line un-abort
//     (docs/arcopolis/39 §4/§5.1/§8). Do NOT add an "INVENTORY" serve branch or gate in this design.
//
// INVARIANT for adding a NEW served category (ALL must hold, else keep it fail-loud):
//   1. a REAL BN input_context/menu/query loop (no parallel or mock loop);
//   2. REAL registered actions served through it (never a forced retval / direct result injection);
//   3. the REAL engine caller consumes the result and mutates real state;
//   4. NO curses window and NO render primitive, in ANY build (AGENTS.md no-window invariant);
//   5. its OWN per-transaction begin/resolve/end (+ RAII guard) and gate predicate -- NEVER a widened
//      session-wide flag;
//   6. no equivalence claim from final state alone -- the witness is scoped to its proven shape.
// ===========================================================================================

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

/// A backend-driven `uilist` prompt request (Spike 13B): the engine's REAL `uilist` entries (read from
/// `amenu.entries` -- txt/enabled + position index), plus the menu's `kind`/`title`, exposed to the live
/// client. `kind` ("uilist") distinguishes this prompt from the old "PICKUP" item menu ("menu") in the
/// protocol and the transcript. The `index` of each choice equals its DOWN-navigation distance from the
/// menu's start at entry 0.
struct backend_uilist_prompt_request {
    std::string kind = "uilist";                ///< protocol/transcript prompt class
    std::string
    title;                          ///< the menu's header text (e.g. "Get items from where?")
    std::vector<pickup_prompt_choice>
    choices;  ///< the REAL amenu.entries (txt/enabled + position index)
    bool cancelable = true;
};

/// The live single-select `uilist` answer channel (Spike 13B): given the engine's real `uilist` choices,
/// returns the chosen entry index (0-based position), or nullopt for an explicit client cancel / EOF (==
/// the GUI player pressing ESC). Set only in live mode; null elsewhere (a `uilist` then has no answer
/// channel, so the engine call site fails loud rather than driving it).
using backend_uilist_prompt_source =
    std::function < auto( const backend_uilist_prompt_request & ) -> std::optional<int> >;

/// A backend-driven `query_popup` prompt request (Spike 15): the engine's REAL query_popup options (read
/// from the constructed query_popup -- for `query_yn` these are the two YES/NO option actions, each
/// enabled, at positions 0/1), the popup's `cursor_start` (so the backend can compute the LEFT/RIGHT
/// navigation to a chosen option from the popup's real starting cursor -- query_yn starts on NO=1), plus
/// the menu's `kind`/`title`. `cancelable` is false for a `query_yn` (no QUIT is registered). DISTINCT
/// from the uilist request: query_popup navigates a horizontal button row (LEFT/RIGHT) rather than a
/// vertical list (DOWN), and query_yn cannot be cancelled.
struct backend_query_popup_request {
    std::string kind = "query_popup";           ///< protocol/transcript prompt class
    std::string
    title;                          ///< the popup's message text (e.g. "Take down the mattress?")
    std::vector<pickup_prompt_choice>
    choices;  ///< the REAL query_popup options (txt = option action, position index, all enabled)
    std::size_t cursor_start = 0;               ///< the popup's starting cursor (query_yn: 1 = NO)
    bool cancelable = false;                     ///< query_yn registers no QUIT -- not cancelable
};

/// The live single-select `query_popup` answer channel (Spike 15): given the engine's real query_popup
/// options, returns the chosen option index (0-based position), or nullopt on EOF / closed client (the
/// resolve then serves the popup's visible default -- CONFIRM on the starting cursor -- to avoid a hang,
/// marked as a closed prompt, NOT an intentional answer). Set only in live mode; null elsewhere (the
/// witness guard then never arms, so the query_yn aborts as in normal test_mode).
using backend_query_popup_source =
    std::function < auto( const backend_query_popup_request & ) -> std::optional<int> >;

/// Inputs for an input-seam backend session (mechanism M1): the ordered steps to drive the engine with,
/// and the directory inline `export` steps write their snapshots into.
struct backend_session_options {
    std::vector<script_step> steps;  ///< the script's steps, executed in order by the provider
    std::string export_dir;          ///< directory inline `export` steps write NNN_<name>.json into
    backend_action_source
    live_source;  ///< Spike 9B live mode: when set, replaces the steps walk entirely
    backend_prompt_source
    prompt_source;  ///< Spike 12A live mode: the pickup menu-answer channel (null elsewhere)
    backend_uilist_prompt_source
    uilist_prompt_source;  ///< Spike 13B live mode: the backend-driven uilist answer channel (null elsewhere)
    backend_query_popup_source
    query_popup_source;  ///< Spike 15 live mode: the backend-driven query_popup (query_yn) answer channel (null elsewhere)
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
/// clear_stale_backend_prompt_state() (it is the command's result, consumed by the response writer at the next seam
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

/// Called by src/pickup.cpp when handle_problematic_pickup is reached during an active backend session but
/// with NO armed pickup transaction (Spike 14 / PR #42 review). The only path is a MULTI-TICK pickup
/// activity that resumed on a later do_turn after the transaction was cleared at the seam return, so there
/// is no armed transaction/channel to drive the uilist and no owed command response to mark. Without this,
/// the uilist would test_mode-abort to a SILENT cancel mid-session. Logs a `prompt_force_cancelled` event
/// (kind="secondary_capacity_orphaned") so the engine's own CANCEL is MARKED in the transcript, never
/// silent. Sets NO pickup_outcome (no owed response exists to mark, and it must not leak a partial marker
/// into a later command). Gated to the orphaned case: inert with no session AND inert while a pickup
/// transaction IS armed (the drive / no-channel paths own that case). Threading the transaction across
/// resumed activity ticks remains deferred (docs/arcopolis/34).
auto backend_report_pickup_orphaned_secondary() -> void;

/// Reads and resets the current pickup command's unsupported-sub-prompt outcome (defaults to `ok`).
/// Called once by the live response writer when the owed pickup response is emitted. Reset to `ok`.
auto backend_take_pickup_outcome() -> pickup_command_outcome;

// --- Spike 13B: ONE backend-driven uilist transaction (live mode only). The "Get items from where?"
// vehicle-source submenu (src/pickup.cpp) is a real `uilist`. Under a backend session that opts in
// (backend_uilist_transaction_active), the uilist's test_mode abort in init()/query() is bypassed so its real
// input_context("UILIST") loop runs, and the backend drives its selection at LEVEL 4 -- the SAME
// registered actions a player presses (DOWN/CONFIRM/QUIT), consumed by that loop, which sets amenu.ret.
// The backend NEVER mutates amenu.ret/selected/fentries as a substitute for input; it only runs the
// uilist's own setup() on a non-render path (so fentries/retvals exist for the loop to act on) and feeds
// the queued actions through the seam. DISTINCT from the "PICKUP" queue above (different category, a
// single-select navigate-then-CONFIRM queue). ---

/// True ONLY while a uilist transaction is armed (between backend_begin_uilist_transaction and
/// backend_end_uilist_transaction). This -- and nothing weaker -- is the gate src/ui.cpp's
/// uilist::init/query/setup test_mode-abort bypass keys off, so the un-abort fires for EXACTLY the
/// witnessed menu and no other uilist. It MUST NOT be replaced by backend_pickup_transaction_active() or
/// backend_session_active() at any un-abort site. Inert (false) outside a session.
auto backend_uilist_transaction_active() -> bool;

/// True when the session has a live uilist answer channel (set only in live mode). The engine call site
/// checks this and FAILS LOUD (unsupported_submenu) when false, rather than driving a uilist with no
/// channel -- preserving the doc-31 fail-loud for non-live / misconfigured sessions.
auto backend_uilist_prompt_available() -> bool;

/// Arms a uilist transaction (makes backend_uilist_transaction_active() true) so the `uilist` about to be CONSTRUCTED
/// does not take the test_mode abort in init()/query(). MUST be called BEFORE the uilist object is
/// constructed (the default ctor's init() reads the gate). Records the arming pickup command's step index
/// for transcript correlation and clears any prior queue. Gated on an armed pickup transaction (the only
/// backend-driven uilist arises inside a live pickup). Inert otherwise.
auto backend_begin_uilist_transaction() -> void;

/// Called by src/pickup.cpp AFTER the uilist's entries are populated (so `request.choices` are the REAL
/// amenu.entries) and BEFORE amenu.query(). Logs `prompt_opened` (kind), asks the live client via the
/// session's uilist_prompt_source, and ARMS the registered-action queue the real uilist loop consumes:
/// [DOWN x choice, "CONFIRM"] for a valid single choice (logs `prompt_answered`), or ["QUIT"] for a
/// cancel / EOF / out-of-range / absent channel (logs `prompt_cancelled`). The terminal element is always
/// the loop-exit action, so the loop never exits with actions unserved. NEVER touches amenu.ret/selected
/// -- the engine loop does, by reacting to the served actions. Inert unless a uilist transaction is armed.
auto backend_resolve_uilist_choice( const backend_uilist_prompt_request &request ) -> void;

/// Closes the uilist transaction: logs `prompt_completed` (kind="uilist", actions_served) if a prompt was
/// opened, then clears all uilist transaction state -- so backend_uilist_transaction_active() becomes false again
/// BEFORE pick_up continues into the ground item menu / activity (whose own uilists must stay aborted /
/// fail-loud). Inert (no-op) when not armed, so it is safe to call unconditionally / from a scope guard on
/// the GUI path. Idempotent.
auto backend_end_uilist_transaction() -> void;

/// RAII guard: calls backend_end_uilist_transaction() on scope exit -- on cancel return, normal
/// fall-through, or an exception -- so a partially-driven uilist can never leak the armed flag into the
/// next command. backend_end is inert when not armed, so constructing this on the GUI path is harmless.
struct uilist_transaction_guard {
    uilist_transaction_guard() = default;
    ~uilist_transaction_guard();
    uilist_transaction_guard( const uilist_transaction_guard & ) = delete;
    auto operator=( const uilist_transaction_guard & ) -> uilist_transaction_guard & = delete;
    uilist_transaction_guard( uilist_transaction_guard && ) = delete;
    auto operator=( uilist_transaction_guard && ) -> uilist_transaction_guard & = delete;
};

// --- Spike 15: ONE backend-driven query_popup transaction (live mode only). The witnessed call site is
// iexamine::deployed_furniture's query_yn("Take down the %s?") (reached by `examine`). The un-abort is
// WITNESS-SCOPED, never command/session-wide: a tiny RAII query_popup_witness_guard at THAT one call site
// arms the per-prompt transaction, so query_popup::query_once()'s test_mode abort is bypassed for exactly
// that one query_yn and no other. Every other query_yn an examine can reach (e.g. "Slip through the %s?")
// has no guard, so it aborts as in normal test_mode -- this spike claims ONE query_popup witness, not
// generic query_yn support. Past the un-abort, the real input_context("YESNO") loop runs and the backend
// drives its selection at LEVEL 4 -- registered LEFT/RIGHT/CONFIRM a player would press, consumed by that
// loop, which sets result.action; the backend never sets the result. DISTINCT from the "UILIST" queue: a
// horizontal-button-row navigate-then-CONFIRM queue served to the "YESNO" category. ---

/// True ONLY while a query_popup transaction is armed (between the witness guard's construction and
/// destruction). This -- and nothing weaker (never backend_examine_query_popup_command_active() or
/// backend_session_active()) -- is the gate src/popup.cpp's query_once test_mode-abort bypass and
/// src/output.cpp's query_yn drive-block key off, so the un-abort fires for EXACTLY the witnessed
/// query_yn and no other query_popup. Inert (false) outside a session.
auto backend_query_popup_transaction_active() -> bool;

/// True while an `examine` command's query_popup precondition is armed -- the gate the witness guard
/// checks before arming the per-prompt transaction. Armed ONLY for the live `examine` command (never
/// merely because a session is active), and cleared at the next top-level seam return. Without it the
/// witness guard never arms, so query_yn aborts as in normal test_mode (the non-live / non-examine path).
/// Inert (false) outside a session.
auto backend_examine_query_popup_command_active() -> bool;

/// True when the session has a live query_popup answer channel (set only in live mode). The witness guard
/// arms only when both this and the examine command precondition hold, so a misconfigured session (no
/// channel) leaves query_yn aborting rather than driving with nothing to ask.
auto backend_query_popup_prompt_available() -> bool;

/// Arms the `examine` command's query_popup precondition (sets the flag + records the command's step index
/// for transcript correlation). Called at live `examine` dispatch. Inert outside a session. Cleared at the
/// next top-level seam return (alongside the one-shot slot / pickup transaction).
auto backend_arm_examine_query_popup_command( const std::optional<int> &step_index ) -> void;

/// Arms a query_popup transaction (makes backend_query_popup_transaction_active() true) so the query_yn about to
/// run does not take its test_mode abort. MUST run BEFORE query_yn's query_popup reaches query_once (the
/// witness guard's constructor calls this, immediately before the query_yn). `witness_id` names WHICH
/// audited call site armed it (e.g. "examine_deployed_furniture_take_down") and is emitted in the
/// `prompt_opened` transcript record, so a reader can confirm the driven prompt was the witnessed one. Gated
/// on BOTH an armed examine command precondition AND a registered answer channel
/// (backend_query_popup_prompt_available()): the only backend-driven query_popup arises inside a live
/// examine, which always has a channel; without one there is nothing to ask, so it refuses to arm and the
/// query_yn aborts as in normal test_mode. Inert otherwise -- so the guard at iexamine::deployed_furniture is
/// a no-op in normal play / non-live / non-examine.
auto backend_begin_query_popup_transaction( const std::string &witness_id ) -> void;

/// Called by src/output.cpp's query_yn drive-block (only while a transaction is armed) AFTER the
/// query_popup's options are built, with `request.choices` the REAL options and `request.cursor_start` the
/// real starting cursor. Logs `prompt_opened` (kind="query_popup"), asks the live client via the session's
/// query_popup_source, and ARMS the registered-action queue the real query_once loop consumes:
/// [LEFT|RIGHT x |cursor_start - choice|, "CONFIRM"] for a valid choice (logs `prompt_answered`), or
/// ["CONFIRM"] on EOF / closed client (CONFIRM the popup's pre-selected visible default -- query_yn's NO --
/// to avoid a headless hang, logged as a CLOSED prompt via `prompt_cancelled` reason "noncancelable_closed",
/// NOT prompt_answered: the client did not intentionally choose the default). NEVER touches the popup's
/// result/cursor -- the engine loop does, by reacting to the served actions. Inert unless a transaction is armed.
auto backend_resolve_query_popup_choice( const backend_query_popup_request &request ) -> void;

/// Closes the query_popup transaction: logs `prompt_completed` (kind="query_popup", actions_served) if a
/// prompt was opened, then clears all query_popup transaction state -- so backend_query_popup_transaction_active()
/// becomes false again BEFORE control returns past the witnessed query_yn (the examine pickup tail's own
/// prompts must stay aborted / guard-handled). Inert (no-op) when not armed, so a scope guard on the GUI
/// path is harmless. Idempotent.
auto backend_end_query_popup_transaction() -> void;

/// RAII guard placed at the ONE witnessed query_yn call site (iexamine::deployed_furniture): its
/// constructor arms the query_popup transaction (gated -- inert unless a live examine command is active),
/// its destructor ends it. Because it exists at exactly one call site, no other query_yn is ever
/// un-aborted. Constructing it elsewhere or on the GUI path is harmless (begin/end are both gated/inert).
struct query_popup_witness_guard {
    explicit query_popup_witness_guard( const std::string &witness_id );
    ~query_popup_witness_guard();
    query_popup_witness_guard( const query_popup_witness_guard & ) = delete;
    auto operator=( const query_popup_witness_guard & ) -> query_popup_witness_guard & = delete;
    query_popup_witness_guard( query_popup_witness_guard && ) = delete;
    auto operator=( query_popup_witness_guard && ) -> query_popup_witness_guard & = delete;
};

// --- Spike 16: non-live SCRIPT prompt-answer support. A `--arcopolis-run-script` command step may declare
// ordered `prompt_answers` (arcopolis_script.h). run_script installs the three script sources below as the
// session's prompt_source / uilist_prompt_source / query_popup_source, so a scripted prompted command feeds
// the SAME backend_resolve_* machinery + registered-action queues + input_context loops + prompt_* transcript
// events as live mode (only the answer's TRANSPORT differs: a declared field, not a stdin line). The sources
// consume the per-command answer queue (loaded at dispatch by next_backend_action) in order. A missing /
// wrong-kind / title-mismatch / out-of-range / cancel-on-noncancelable / unused answer FAILS LOUD
// (command_error_kind::script_prompt_failed -> exit 13) via session.failure, never a silent auto-cancel. On a
// fatal failure the source logs `prompt_failed` BEFORE returning nullopt (so the resolve's loop-exit QUIT /
// default-CONFIRM is an engine escape hatch, never read as a user cancel). Scope is the single command turn
// being driven; a multi-tick resumed pickup secondary prompt remains orphaned-marked / unsupported (doc 34).
// The sources write NO stdout (transcript events only). ---

/// Loads the active command's declared prompt answers for the script sources to consume, resetting the
/// consume cursor and the per-command step index. Called by next_backend_action() at each command dispatch;
/// also exposed so unit tests can seed the queue without the steps walk. Inert outside a session.
auto backend_load_scripted_prompt_answers( const std::vector<script_prompt_answer> &answers,
        const std::optional<int> &step_index ) -> void;

/// The script-mode pickup menu answer source (signature backend_prompt_source). Matches the next declared
/// answer (kind must be "menu") against the open menu and returns its chosen index/indices, or nullopt for a
/// legitimate cancel; a missing / wrong-kind / out-of-range answer logs prompt_failed, records a fatal
/// script_prompt_failed, and returns nullopt. Installed only in --arcopolis-run-script.
auto script_pickup_prompt( const std::vector<pickup_prompt_choice> &choices )
-> std::optional<std::vector<int>>;

/// The script-mode uilist answer source (signature backend_uilist_prompt_source). As script_pickup_prompt
/// but for kind "uilist": single-select, optional title assertion, cancel accepted only when the prompt is
/// cancelable (else fail loud).
auto script_uilist_prompt( const backend_uilist_prompt_request &request ) -> std::optional<int>;

/// The script-mode query_popup answer source (signature backend_query_popup_source). As script_uilist_prompt
/// but for kind "query_popup": single-select, optional title assertion; query_yn is not cancelable, so a
/// scripted cancel fails loud.
auto script_query_popup_prompt( const backend_query_popup_request &request ) -> std::optional<int>;

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

// --- Spike 20: fail-loud for an UNARMED player-visible prompt reached during an active session. The
// engine's test_mode prompt-abort sites (today: query_popup::query_once) would otherwise silently
// default/cancel an unsupported prompt and report a hidden lost interaction as success. These two
// functions are the generic runtime channel for that -- a SEPARATE channel from the script-named
// record_script_prompt_failure (it is reached from live and one-shot too), sharing the same
// session.failure storage + transcript plumbing. See docs/arcopolis/42. ---

/// Records that an UNARMED player-visible prompt/query (`family`, e.g. "query_popup", at `site`, e.g.
/// "query_once") was reached during an active session. The signature deliberately takes NO step_index:
/// generic UI code must not know Arcopolis script internals -- the current command's step index is inferred
/// internally for transcript correlation. Inert outside a session (cata_test / normal play unchanged, so the
/// abort site keeps its normal default). NON-LIVE (script/one-shot): records a fatal session failure (kind
/// unexpected_prompt -> exit 14) + sets `done` + logs an `error` event, first-failure-wins. LIVE: records a
/// RECOVERABLE pending error (no done/failure) the per-request runner surfaces as a visibly-failed ok=false
/// response, leaving the session open. The abort site still returns its safe default as a transport fallback.
auto backend_report_unexpected_prompt( const std::string &family, const std::string &site ) -> void;

/// (Live) Returns and clears the recoverable pending unexpected-prompt error set by
/// backend_report_unexpected_prompt during the just-completed request's do_turn. The live runner calls this
/// after each request; a non-null result means the command reached an unarmed prompt and MUST be reported as
/// a visibly-failed ok=false response (never success), with the session left open. nullopt otherwise.
auto backend_take_unexpected_prompt_error() -> std::optional<command_error>;

/// Writes the terminal final-on-exit snapshot (NNN_final.json, with session.final = true and a null
/// step_index) using the live session's export dir + running index. Called by run_script() on clean script
/// completion -- after do_turn returns from the clean-park path and before end_backend_session() clears
/// state. Records a write failure via backend_session_failure(); returns true on success. (Spike 3.1B)
auto backend_write_final_snapshot() -> bool;

// --- Spike 27B: attacker-attributed avatar-damage observation (read-only, native-authority class S).
// A gated, ADDITIVE tap at the engine's own Character::apply_damage funnel (src/character.cpp) records who
// dealt damage to the AVATAR, surfaced read-only as avatar.damage_taken[] (arcopolis_export). This is L1
// observation -- it drives NO registered input and makes NO level-4 claim. It exposes the raw in-scope
// `source` the funnel already carries -- the SAME pointer the GUI "You were attacked by %s!" message is
// built from (Character::on_hurt) -- which is RAW SIMULATION STATE: it cannot diverge from itself, so the
// class-S surface is self-sealing and needs no counterexample. The funnel value is recorded BEFORE the
// GUI's display filters and is independent of both:
//   * PERCEPTION -- the per-hit combat message masks the attacker name to "Something hits your %s." when
//     !g->u.sees(attacker) (src/monster.cpp melee_attack); the funnel `source` is the real attacker
//     regardless of LOS. A frontend renders its own (optionally perception-masked) message from this.
//   * the on_hurt distraction message is gated by painkiller / narcosis / disturb (NOT perception); the
//     funnel value is present even when that message is suppressed.
// So this asserts the FUNNEL FACT, never message-equivalence (the perception-masked display is a separate,
// deferred frontier). Per-APPLICATION (per bodypart / per hit) -- an event stream, NOT a per-turn rollup.
// The funnel fires only on a landed HIT, so a witness of "took damage from X" is RNG-DEPENDENT (empirically
// reliable across seeds, NOT RNG-invariant like the Spike 27A position witness). ---

/// One attacker-attributed avatar-damage event, captured at the apply_damage funnel.
struct avatar_damage_record {
    std::string source_kind;     ///< "monster" / "npc" (the attacker's Creature kind)
    std::string source_type_id;  ///< monster type id (e.g. "mon_zombie"); empty for an npc source
    ///< (stable NPC identity is deferred, as in the Spike 7A npc export v0)
    int amount = 0;              ///< dam_to_bodypart actually applied (HP lost on the part), always > 0
    std::string
    bodypart;        ///< the STRUCK part the GUI message names (apply_damage `hurt`, e.g. "eyes")
    std::string hp_part;         ///< the HP-pool part `amount` was deducted from (hurt->main_part, e.g.
    ///< "head"); == bodypart for a torso/head/limb hit, differs only on a sub-part hit (eyes/mouth/hand/foot)
    int turn = 0;                ///< calendar turn at the funnel (matches the snapshot's backend.turn)
};

/// Records one avatar-damage event from the apply_damage funnel: classifies `source` (monster/npc + type
/// id) INTO `event` and appends it. `event` carries the OBSERVABLE fields the caller knows (amount,
/// bodypart, hp_part, turn); this fills source_kind/source_type_id. Called ONLY from the gated tap in
/// Character::apply_damage, which has already checked is_avatar() / source != nullptr / source != this /
/// dam_to_bodypart > 0. Inert (no-op) outside an active session, so cata_test / normal play never accumulate.
auto backend_record_avatar_damage( const Creature &source, avatar_damage_record event ) -> void;

/// Returns the avatar-damage events recorded since the previous call and CLEARS the buffer (drain): each
/// snapshot's avatar.damage_taken[] is therefore the event window since the prior snapshot, not a
/// cumulative rollup. Empty outside a session. Read by arcopolis_export's write_damage_taken().
auto backend_take_avatar_damage_taken() -> std::vector<avatar_damage_record>;

} // namespace arcopolis
