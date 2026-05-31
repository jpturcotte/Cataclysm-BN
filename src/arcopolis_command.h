#pragma once

#include <expected>
#include <iosfwd>
#include <string>

namespace arcopolis
{

/// One decoded backend command. Spike 1 supports only the "wait" command.
struct backend_command {
    int schema_version = 0;  //< must equal the supported schema version (1)
    std::string command;     //< command verb, e.g. "wait"
};

/// Why a command file could not be read, validated, or applied. Mapped to a distinct
/// process exit code by exit_code_for() so an external frontend can tell failures apart.
enum class command_error_kind {
    missing_file,         //< the command file does not exist
    unreadable_file,      //< the file exists but could not be opened
    invalid_json,         //< the file is not well-formed JSON
    bad_schema,           //< missing/wrong schema_version, or missing/non-string command
    unsupported_command,  //< a well-formed command this spike does not implement
    apply_failed,         //< the command was recognised but could not be applied
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

/// Applies a validated command to the already-loaded game through existing non-UI action
/// mechanisms. Spike 1 supports only "wait" (character pause + a one-turn world advance),
/// and requires a loaded world (the global game `g`, avatar, and map). Returns nothing on
/// success, or a typed error for an unsupported command or a failed application.
auto apply_command( const backend_command &cmd ) -> std::expected<void, command_error>;

/// Maps a command_error_kind to a distinct nonzero process exit code (success stays 0).
auto exit_code_for( command_error_kind kind ) -> int;

} // namespace arcopolis
