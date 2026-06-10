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

/// Inputs for an input-seam backend session (mechanism M1): the ordered steps to drive the engine with,
/// and the directory inline `export` steps write their snapshots into.
struct backend_session_options {
    std::vector<script_step> steps;  ///< the script's steps, executed in order by the provider
    std::string export_dir;          ///< directory inline `export` steps write NNN_<name>.json into
    backend_action_source
    live_source;  ///< Spike 9B live mode: when set, replaces the steps walk entirely
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
