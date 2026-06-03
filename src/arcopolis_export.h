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
    int export_index = 0;     ///< 0-based sequence among export snapshots in this session
    std::optional<int>
    step_index;               ///< 0-based index within steps[]; nullopt for the final-on-exit snapshot
    std::string export_name;  ///< the export step's "name" label ("final" for the terminal snapshot)
    bool final = false;       ///< true only for the terminal final-on-exit snapshot (Spike 3.1B)
};

/// Writes a read-only current-view JSON snapshot of the ALREADY-LOADED game to `output_path`,
/// reusing the single snapshot format. When `session` is set, a "session" object is included.
/// Requires a loaded world (the global game `g`, avatar, and map); performs no simulation mutation.
/// Returns true on success, false if the file could not be written.
auto write_current_view( const std::string &output_path,
                         const std::optional<snapshot_session_info> &session ) -> bool;

/// A few scalar avatar/clock values read from the live loaded game with the SAME accessors the snapshot
/// uses (calendar::turn, avatar::abs_pos, avatar::get_moves). The Spike 3.1C session transcript records
/// these in its `export` record so a reader sees a snapshot's turn/pos/moves without opening the snapshot
/// file. Read immediately after writing a snapshot (no turn runs in between), the values equal that
/// snapshot's. Requires a loaded game (the global `g` and avatar).
struct snapshot_summary {
    int turn = 0;
    int pos_abs_x = 0;
    int pos_abs_y = 0;
    int pos_abs_z = 0;
    int moves = 0;
};

auto current_snapshot_summary() -> snapshot_summary;

} // namespace arcopolis
