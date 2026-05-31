#pragma once

#include <string>

namespace arcopolis
{

/// Inputs for a one-shot headless run: load a world, optionally apply one backend command,
/// then write a read-only "current view" snapshot.
struct export_current_view_options {
    std::string world;         //< prepared world/save to load headlessly (required)
    std::string output_path;   //< filesystem path the JSON snapshot is written to
    std::string command_path;  //< optional backend command file to apply before export ("" = none)
};

/// Headlessly loads `opts.world` via the existing game::load(world) path, optionally applies one
/// backend command from `opts.command_path` (Spike 1), then writes a small read-only current-view
/// JSON snapshot to `opts.output_path` and returns a process exit code (0 = success; non-zero =
/// missing world, load failure, command error, or write failure). The only simulation mutation is
/// through the applied command's existing in-engine action path; never touches the player-facing UI.
auto export_current_view( const export_current_view_options &opts ) -> int;

} // namespace arcopolis
