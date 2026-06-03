#include "arcopolis_backend_input.h"

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "action.h"             // action_id, ACTION_NULL
#include "arcopolis_command.h"  // backend_command, command_to_action, command_error, command_error_kind
#include "arcopolis_export.h"   // write_current_view, snapshot_session_info
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
            // Perform the export inline at this faithful input-loop point. Mirrors the old run_script
            // export block, but now taken from INSIDE do_turn's input loop -- the GUI's resting point --
            // which also fixes Spike 2's pre-do_turn `after_load` timing for free.
            const auto label = step.name.empty() ? std::string( "snapshot" ) : step.name;
            const auto info = snapshot_session_info{
                .export_index = session.export_index,
                .step_index = static_cast<int>( session.cursor ),
                .export_name = label,
            };
            const auto filename = string_format( "%03d_%s.json", session.export_index,
                                                 ensure_valid_file_name( label ) );
            const auto path = ( std::filesystem::path( session.export_dir ) / filename ).string();
            if( !write_current_view( path, info ) ) {
                // The provider cannot return an error; record it and stop cleanly. The runner surfaces it
                // as the process exit code once the engine loop ends.
                session.failure = command_error{ .kind = command_error_kind::export_failed,
                                                 .detail = "failed to write snapshot to '" + path + "'" };
                session.done = true;
                return ACTION_NULL;
            }
            ++session.export_index;
            ++session.cursor;
            continue;
        }
        // op == "command": advance past it, then resolve to the engine action_id. The runner's pre-flight
        // already validated every command, so command_to_action always succeeds here; value_or is the
        // total fallback (an unexpected ACTION_NULL is a harmless no-op -- the cursor has already moved).
        ++session.cursor;
        return command_to_action( { .schema_version = 1,
                                    .command = step.command,
                                    .direction = step.direction } )
               .value_or( ACTION_NULL );
    }
    // Cursor exhausted: signal "done" so do_turn's clean-stop parks the turn before the bottom half.
    session.done = true;
    return ACTION_NULL;
}
