#pragma once

#include <cstddef>
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

/// Inputs for an input-seam backend session (mechanism M1): the ordered steps to drive the engine with,
/// and the directory inline `export` steps write their snapshots into.
struct backend_session_options {
    std::vector<script_step> steps;  ///< the script's steps, executed in order by the provider
    std::string export_dir;          ///< directory inline `export` steps write NNN_<name>.json into
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
auto next_backend_action() -> action_id;

/// The provider's step cursor (index of the next step to process). The script runner compares this
/// across do_turn() calls to detect a stall (e.g. the input loop skipped while the avatar sleeps).
auto backend_cursor() -> std::size_t;

/// The session's recorded failure, if an inline `export` step could not be written. The runner surfaces
/// it as the process exit code after the engine loop ends.
auto backend_session_failure() -> std::optional<command_error>;

} // namespace arcopolis
