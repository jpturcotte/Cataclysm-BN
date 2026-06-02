#pragma once

#include <expected>
#include <iosfwd>
#include <string>
#include <string_view>

// Forward declaration so command_to_action() can return an engine action_id without pulling the heavy
// action.h into this parser header (the .cpp includes action.h). Matches the global enum in action.h.
enum action_id : int;

namespace arcopolis
{

/// One decoded backend command. Supports "wait" (Spike 1) and "move" + a cardinal direction (Spike 3).
struct backend_command {
    int schema_version = 0;  ///< must equal the supported schema version (1)
    std::string command;     ///< command verb, e.g. "wait" or "move"
    std::string
    direction;   ///< cardinal ident for "move" (move_n/move_s/move_e/move_w); empty otherwise
};

/// Why a command file could not be read, validated, or applied. Mapped to a distinct
/// process exit code by exit_code_for() so an external frontend can tell failures apart.
enum class command_error_kind {
    missing_file,         ///< the command file does not exist
    unreadable_file,      ///< the file exists but could not be opened
    invalid_json,         ///< the file is not well-formed JSON
    bad_schema,           ///< missing/wrong schema_version, or missing/non-string command
    unsupported_command,  ///< a well-formed command this spike does not implement
    safe_mode_blocked,    ///< recognised, but safe mode declined it (mirrors the GUI pause gate)
    apply_failed,         ///< the command was recognised but could not be applied
    export_failed,        ///< a current-view snapshot could not be written (Spike 2 script runner)
    backend_stalled,      ///< the input-seam session made no progress (e.g. avatar asleep); hang backstop
    game_over,            ///< the avatar died / the game ended while driving the engine's turn loop
};

/// A command failure: a machine-readable kind plus a human-readable detail for stderr.
struct command_error {
    command_error_kind kind;
    std::string detail;
};

/// Parses and schema-validates a command from an open JSON stream (no file I/O). Exposed so the
/// parser can be unit-tested directly; read_command_file() layers file handling on top. Returns
/// the decoded command, or a typed error for malformed JSON (invalid_json) or a schema problem
/// (bad_schema).
auto parse_command( std::istream &stream ) -> std::expected<backend_command, command_error>;

/// Reads and validates a single backend command from `path`, reusing the in-tree JsonIn.
/// Touches no simulation state. Returns the decoded command, or a typed error for a
/// missing/unreadable file, malformed JSON, or a schema problem.
auto read_command_file( const std::string &path ) -> std::expected<backend_command, command_error>;

/// Applies a validated command to the already-loaded game through existing non-UI action mechanisms.
/// Supports "wait" (character pause + a one-turn world advance; Spike 1) and "move" + a cardinal
/// direction (the GUI avatar_action::move path, advancing the turn only when the avatar's moves are
/// spent; Spike 3). Both require a loaded world (the global game `g`, avatar, and map). Returns nothing
/// on success, or a typed error for an unsupported command, a bad move direction (bad_schema), a
/// safe-mode decline (safe_mode_blocked), or a failed application.
auto apply_command( const backend_command &cmd ) -> std::expected<void, command_error>;

/// Resolves a validated command to the engine action_id the GUI's input switch dispatches for it
/// (`wait` -> ACTION_PAUSE, `move` + cardinal -> ACTION_MOVE_* via look_up_action), WITHOUT touching
/// simulation state. This is the faithful Spike 3.1 path: the engine's own switch( act ) in
/// handle_action() computes the delta and calls avatar_action::move / do_pause at the input seam, so the
/// backend never runs the action itself. Returns the action_id, or a typed error for an unsupported
/// command (unsupported_command) or a bad move direction (bad_schema). Pure: safe without a loaded world.
auto command_to_action( const backend_command &cmd ) -> std::expected<action_id, command_error>;

/// Maps a command_error_kind to a distinct nonzero process exit code (success stays 0).
auto exit_code_for( command_error_kind kind ) -> int;

/// True iff `ident` is one of the four cardinal movement idents this spike supports
/// (move_n / move_s / move_e / move_w). Diagonals (move_ne/...) and vertical (move_up/move_down) are
/// intentionally rejected. Shared by the command/script parsers and apply_command to gate "move".
auto is_supported_move_direction( std::string_view ident ) -> bool;

} // namespace arcopolis
