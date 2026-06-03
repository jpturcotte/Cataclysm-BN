#include "arcopolis_backend_input.h"

#include <cstddef>
#include <filesystem>
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
};

backend_session session;

/// Writes one session snapshot (an `export` step or the final-on-exit terminal snapshot) using the live
/// session's export dir + running index. On failure records session.failure, sets done, returns false; on
/// success advances export_index and returns true. Shared by next_backend_action() and
/// backend_write_final_snapshot() so both emit identically-formatted NNN_<label>.json files.
auto write_session_snapshot( const std::string &label, const std::optional<int> &step_index,
                             bool is_final ) -> bool
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
        return false;
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
    return true;
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
        return resolved.value_or( ACTION_NULL );
    }
    // Cursor exhausted: signal "done" so do_turn's clean-stop parks the turn before the bottom half.
    session.done = true;
    return ACTION_NULL;
}

auto arcopolis::backend_write_final_snapshot() -> bool
{
    // Inert unless a session with an export dir is active: without it write_session_snapshot would build a
    // cwd-relative path (e.g. "000_final.json") and write there. run_script (the only caller) is always
    // active with a dir, so this is defense-in-depth that keeps the public writer inert outside a session.
    if( !session.active || session.export_dir.empty() ) {
        return false;
    }
    // Terminal snapshot: no steps[] entry (step_index = nullopt) and final = true. Reuses the running
    // export index, so it follows the last export step's file as NNN_final.json.
    return write_session_snapshot( "final", std::nullopt, /*is_final=*/true );
}
