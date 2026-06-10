#pragma once

#include <iosfwd>
#include <optional>
#include <string>

#include "arcopolis_command.h"  // command_error_kind (error_event field; mapped to exit_code in the .cpp)

namespace arcopolis
{

/// The only session-transcript schema this spike emits. Independent of the snapshot's own schema_version
/// (which Spike 3.1C does not touch); both happen to be 1.
constexpr auto session_log_schema_version = 1;

/// An absolute map position, serialized as a `[x, y, z]` array -- the same shape as the snapshot's
/// `avatar.pos_abs`, so a reader handles both identically.
struct session_log_point {
    int x = 0;
    int y = 0;
    int z = 0;
};

/// `session_start`: the run is about to begin. `seed` is omitted when absent (the CLI seed is not currently
/// threaded into the backend -- see docs/arcopolis/11). `game_version` is getVersionString().
struct session_start_event {
    std::string world;
    std::optional<std::string> seed;
    std::string export_dir;
    std::string game_version;
};

/// `command`: one backend command was queued into the engine at the input seam. `direction` is omitted
/// when empty (e.g. `wait`); `action_id` is the resolved engine action ident (action_ident()), omitted
/// when the command did not resolve. The status is always "queued": the observable RESULT of a command is
/// the FOLLOWING `export`/snapshot, never this record.
struct command_event {
    int step_index = 0;
    std::string command;
    std::string direction;
    std::optional<std::string> action_id;
};

/// `export`: a snapshot was written. `step_index` is null for the final-on-exit snapshot (it belongs to no
/// steps[] entry). `path` is the snapshot's RELATIVE filename (`NNN_<name>.json`), not a machine-local
/// path. turn/pos_abs/moves mirror the just-written snapshot (read at the same instant -- see
/// arcopolis::current_snapshot_summary()).
struct export_event {
    std::optional<int> step_index;
    int export_index = 0;
    std::string name;
    std::string path;
    bool final = false;
    int turn = 0;
    session_log_point pos_abs;
    int moves = 0;
};

/// `error`: a typed backend failure occurred during the run. `kind` is mapped to its string name and to
/// exit_code_for(kind) when written. `step_index` is omitted when not known.
struct error_event {
    std::optional<int> step_index;
    command_error_kind kind;
    std::string detail;
};

/// `session_end`: the run finished. `status` is "ok" or "error". snapshots/commands are the counts the
/// writer accumulated over the run. final_turn/final_pos_abs are omitted when not available.
struct session_end_event {
    std::string status;
    int snapshots = 0;
    int commands = 0;
    std::optional<int> final_turn;
    std::optional<session_log_point> final_pos_abs;
};

/// Caller-facing input to end_session_log(): the writer fills in snapshots/commands from its own counters.
struct session_end_summary {
    std::string status;
    std::optional<int> final_turn;
    std::optional<session_log_point> final_pos_abs;
};

// --- Pure formatters: each writes exactly one JSON Lines record (a compact object + trailing '\n') to
// `out`. Exposed so the transcript format can be unit-tested without a file or a loaded world. ---

auto write_session_start_line( std::ostream &out, const session_start_event &ev ) -> void;
auto write_command_line( std::ostream &out, const command_event &ev ) -> void;
auto write_export_line( std::ostream &out, const export_event &ev ) -> void;
auto write_error_line( std::ostream &out, const error_event &ev ) -> void;
auto write_session_end_line( std::ostream &out, const session_end_event &ev ) -> void;

// --- Stateful session transcript (one file-scoped session at a time). All of these are no-ops while no
// log is open, so they stay inert during normal play and in unit tests that drive the input provider
// without a transcript. ---

/// Opens `<export_dir>/session.jsonl` (UTF-8, binary so line endings stay LF), truncating any previous
/// file, resets the counters, and writes the session_start record. Returns false if the file could not be
/// opened -- the caller should surface that as a typed error BEFORE driving the script. Also a no-op
/// returning false if a log is already open or the export dir is empty.
auto begin_session_log( const session_start_event &ev ) -> bool;

/// Writes a `command` record and counts it (for session_end.commands). No-op if no log is open.
auto session_log_command( const command_event &ev ) -> void;

/// Writes an `export` record and counts it (for session_end.snapshots). No-op if no log is open.
auto session_log_export( const export_event &ev ) -> void;

/// Writes an `error` record. No-op if no log is open.
auto session_log_error( const error_event &ev ) -> void;

/// Writes the final `session_end` record (filling snapshots/commands from the counters), flushes, closes
/// the file, and clears the session. No-op if no log is open.
auto end_session_log( const session_end_summary &summary ) -> void;

} // namespace arcopolis
