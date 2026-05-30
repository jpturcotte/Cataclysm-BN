#pragma once

#include <string>

namespace arcopolis
{

/// Inputs for a one-shot, read-only "current view" export.
struct export_current_view_options {
    std::string world;        //< prepared world/save to load headlessly (required for Spike 0)
    std::string output_path;  //< filesystem path the JSON snapshot is written to
};

/// Headlessly loads `opts.world` via the existing game::load(world) path and writes a small
/// read-only current-view JSON snapshot to `opts.output_path`, then returns a process exit code
/// (0 = success; non-zero = missing world, load failure, or write failure). Mutates no simulation
/// state and never touches the player-facing UI.
auto export_current_view( const export_current_view_options &opts ) -> int;

} // namespace arcopolis
