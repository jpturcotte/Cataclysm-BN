#pragma once

#include <expected>
#include <iosfwd>
#include <optional>
#include <string>
#include <vector>

#include "arcopolis_command.h"  // command_error / command_error_kind (shared error model)

namespace arcopolis
{

/// One decoded entry from a Spike 2 step script. A step is either a script-runner directive
/// (`op == "export"`) or a backend command (`op == "command"`); the two are deliberately separate so
/// `export` is never confused with a game command as the backend command set grows.
struct script_step {
    std::string op;         ///< "export" (script directive) or "command" (backend command)
    std::string name;       ///< export label (op == "export"; "" when omitted)
    std::string command;    ///< backend command verb (op == "command", e.g. "wait" / "move")
    std::string
    direction;  ///< cardinal ident for command "move" (move_n/move_s/move_e/move_w); else ""
};

/// Inputs for a stateful headless session: load a world EXACTLY ONCE, then run a step script against
/// the live game, writing a snapshot per `export` step into a directory.
struct run_script_options {
    std::string world;        ///< prepared world/save to load headlessly (required)
    std::string script_path;  ///< JSON step script to execute in order (required)
    std::string export_dir;   ///< directory the snapshots are written into (required)
    std::optional<std::string>
    seed;  ///< original --seed CLI string for the transcript's session_start; nullopt if not passed
};

/// Parses and schema-validates a step script from an open JSON stream (no file I/O). Exposed so the
/// parser can be unit-tested directly; read_script_file() layers file handling on top. Returns the
/// ordered steps, or a typed error for malformed JSON (invalid_json) or a schema problem
/// (bad_schema: bad schema_version, non-array steps, a step missing/with-non-string op, an unknown
/// op, or a "command" op without a string command).
auto parse_script( std::istream &stream ) -> std::expected<std::vector<script_step>, command_error>;

/// Reads and validates a step script from `path`, reusing the in-tree JsonIn. Touches no simulation
/// state. Returns the ordered steps, or a typed error for a missing/unreadable file, malformed JSON,
/// or a schema problem.
auto read_script_file( const std::string &path )
-> std::expected<std::vector<script_step>, command_error>;

/// Loads `opts.world` EXACTLY ONCE, then executes the script's steps in order against the persistent
/// loaded game, writing read-only current-view snapshots into `opts.export_dir`. Returns a process
/// exit code (0 = success; non-zero via exit_code_for(), or 1 for a pre-flight guard / world-load
/// failure). Never initializes the player-facing UI; never overrides engine state — the per-step
/// calendar advance emerges from the load-once lifecycle (the engine clears game::new_game on the
/// first do_turn), not from faking anything. See AGENTS.md "Arcopolis backend fidelity".
auto run_script( const run_script_options &opts ) -> int;

} // namespace arcopolis
