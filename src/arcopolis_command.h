#pragma once

#include <expected>
#include <iosfwd>
#include <optional>
#include <string>
#include <string_view>

// Forward declaration so command_to_action() can return an engine action_id without pulling the heavy
// action.h into this parser header (the .cpp includes action.h). Matches the global enum in action.h.
enum action_id : int;

namespace arcopolis
{

/// The accepted direction tokens, as a human-readable slash list for parser error details. Shared
/// across the command and script parsers (both translation units) so the list lives in exactly one
/// place. `expected_examine_directions` is the move list plus "here" (the self tile). Keep these in
/// sync with is_supported_move_direction() / is_supported_examine_direction().
inline constexpr char expected_move_directions[] =
    "move_n/move_s/move_e/move_w/move_ne/move_nw/move_se/move_sw";
inline constexpr char expected_examine_directions[] =
    "move_n/move_s/move_e/move_w/move_ne/move_nw/move_se/move_sw/here";

/// One decoded backend command. Supports "wait" (Spike 1), "move" + a planar direction (Spike 3; eight
/// planar directions since the GUI-equivalence fix), and "examine" + a direction (Spike 11A).
struct backend_command {
    int schema_version = 0;  ///< must equal the supported schema version (1)
    std::string command;     ///< command verb, e.g. "wait", "move" or "examine"
    std::string
    direction;   ///< planar ident: the 8 (move_n/s/e/w + move_ne/nw/se/sw) for "move"; those 8 plus
    ///< "here" for "examine"; empty otherwise
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
    nested_input_failed,  ///< a nested input read had no servable answer and no registered cancel action
    ///< (or the auto-cancel guard exceeded its fire limit) -- fatal, the session
    ///< hard-exits rather than hang (Spike 11A)
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

/// Resolves a validated command to the engine action_id the GUI's input switch dispatches for it
/// (`wait` -> ACTION_PAUSE, `move` + a planar direction -> ACTION_MOVE_* via look_up_action, `examine`
/// -> ACTION_EXAMINE), WITHOUT touching simulation state. This is the faithful Spike 3.1 path: the
/// engine's own switch( act ) in handle_action() computes the delta and calls avatar_action::move /
/// do_pause / examine() at the input seam, so the backend never runs the action itself. An examine
/// direction is NOT encoded in the action_id -- it is the one-shot nested-input answer served if the
/// engine's own chooser asks (Spike 11A; see arcopolis_backend_input.h). Returns the action_id, or a
/// typed error for an unsupported command (unsupported_command) or a bad direction (bad_schema). Pure:
/// safe without a loaded world.
auto command_to_action( const backend_command &cmd ) -> std::expected<action_id, command_error>;

/// Maps a command_error_kind to a distinct nonzero process exit code (success stays 0).
auto exit_code_for( command_error_kind kind ) -> int;

/// True iff `ident` is one of the EIGHT planar movement idents this spike supports: the four cardinals
/// (move_n / move_s / move_e / move_w) and the four diagonals (move_ne / move_nw / move_se / move_sw) --
/// exactly the planar set a BN GUI player can step, all dispatched through the engine's shared
/// avatar_action::move body. Vertical (move_up / move_down) is intentionally rejected: it is the
/// separate game::vertical_move primitive (stairs/ropes/climb), not a planar step. Shared by the
/// command/script parsers and command_to_action to gate "move".
auto is_supported_move_direction( std::string_view ident ) -> bool;

/// True iff `ident` is a direction the "examine" verb accepts: the EIGHT planar directions the GUI
/// examine chooser registers (the four cardinals plus the four diagonals move_ne/move_nw/move_se/move_sw)
/// plus "here" (the avatar's own tile -- the engine chooser's "pause" path) -- exactly the planar target
/// set a GUI player can pick at "Examine where?". Vertical (move_up/move_down) is rejected because
/// game::examine passes allow_vertical=false. Shared by the parsers and command_to_action to gate
/// "examine". (Spike 11A; diagonals added so the backend mirrors the full GUI chooser, not a subset.)
auto is_supported_examine_direction( std::string_view ident ) -> bool;

/// Maps a supported examine direction to the input-context ACTION ID the engine's direction chooser
/// (`choose_direction`, src/action.cpp) consumes -- "UP"/"DOWN"/"RIGHT"/"LEFT" + the diagonals
/// "RIGHTUP"/"LEFTUP"/"RIGHTDOWN"/"LEFTDOWN" from register_directions(), or "pause" for the self-tile.
/// This is the keystroke a GUI player would press at the "Examine where?" prompt, NOT an engine
/// action_id and NOT a target tile. Returns nullopt for an unsupported ident. Pure. (Spike 11A)
auto examine_nested_answer( std::string_view direction ) -> std::optional<std::string>;

} // namespace arcopolis
