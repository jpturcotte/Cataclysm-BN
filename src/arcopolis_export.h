#pragma once

#include <optional>
#include <string>

namespace arcopolis
{

/// Inputs for a one-shot headless run: load a world, optionally apply one backend command,
/// then write a read-only "current view" snapshot.
struct export_current_view_options {
    std::string world;         ///< prepared world/save to load headlessly (required)
    std::string output_path;   ///< filesystem path the JSON snapshot is written to
    std::string command_path;  ///< optional backend command file to apply before export ("" = none)
};

/// Headlessly loads `opts.world` via the existing game::load(world) path, optionally applies one
/// backend command from `opts.command_path` (Spike 1), then writes a small read-only current-view
/// JSON snapshot to `opts.output_path` and returns a process exit code (0 = success; non-zero =
/// missing world, load failure, command error, or write failure). The only simulation mutation is
/// through the applied command's existing in-engine action path; never touches the player-facing UI.
auto export_current_view( const export_current_view_options &opts ) -> int;

/// Optional per-snapshot session metadata. When supplied to write_current_view(), a "session"
/// object is written into the snapshot so a stateful run (Spike 2) records where each snapshot came
/// from. Absent for the one-shot Spike 0/1 export, whose output is therefore unchanged.
struct snapshot_session_info {
    int export_index = 0;     ///< 0-based sequence among export steps in this session
    int step_index = 0;       ///< 0-based index of this export within the script's steps[]
    std::string export_name;  ///< the export step's "name" label
};

/// Writes a read-only current-view JSON snapshot of the ALREADY-LOADED game to `output_path`,
/// reusing the single snapshot format. When `session` is set, a "session" object is included.
/// Requires a loaded world (the global game `g`, avatar, and map); performs no simulation mutation.
/// Returns true on success, false if the file could not be written.
auto write_current_view( const std::string &output_path,
                         const std::optional<snapshot_session_info> &session ) -> bool;

} // namespace arcopolis
