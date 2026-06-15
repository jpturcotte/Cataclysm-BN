#pragma once

#include <iosfwd>
#include <optional>
#include <string>
#include <vector>

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
/// `autoselect_single_valid_target` records the loaded AUTOSELECT_SINGLE_VALID_TARGET interface option
/// (Spike 11A): it decides whether the engine's direction chooser prompts at 0/1 valid targets, so
/// recording it makes examine witnesses config-explicit -- the option itself is NEVER overridden
/// (docs/arcopolis/25, design point 2).
struct session_start_event {
    std::string world;
    std::optional<std::string> seed;
    std::string export_dir;
    std::string game_version;
    bool autoselect_single_valid_target = false;
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

// --- Spike 11A nested-input observability: every backend intervention at a nested input read is a
// transcript event, so auto-cancels can never silently mask a real interaction. ---

/// `nested_input_answer`: the one-shot armed direction answer was served to a nested input read (the
/// engine's direction chooser). `context` is the asking input_context category; `action` is the served
/// input-context action id -- the keystroke mirror, not an engine action_id.
struct nested_input_answer_event {
    std::optional<int> step_index;  ///< the arming command's step index; omitted when unknown
    std::string context;            ///< asking input_context category (e.g. "DEFAULTMODE")
    std::string direction;          ///< the arming command's direction token (e.g. "move_n")
    std::string action;             ///< the served action id (e.g. "UP", "pause")
};

/// `nested_input_guard`: the auto-cancel guard answered a nested input read with the context's registered
/// cancel action (== the GUI player pressing ESC; the engine runs its own cancel path). `reason` is
/// "no_answer" (nothing armed), "context_mismatch" (an answer is armed but this context is not the
/// direction chooser), or "answer_not_registered" (the chooser-category context did not register the
/// armed action). `fires` is the running guard-fire count for the current command.
struct nested_input_guard_event {
    std::optional<int> step_index;  ///< the current command's step index; omitted when unknown
    std::string context;            ///< asking input_context category (e.g. "PICKUP")
    std::string action;             ///< the cancel action returned ("QUIT" or "TEXT.QUIT")
    std::string reason;
    int fires = 0;
};

/// `nested_input_unconsumed`: an armed answer was never asked for by the time control returned to the
/// top-level input seam (e.g. the engine auto-selected the sole valid target and skipped the chooser);
/// the slot was force-cleared so it cannot leak into a later prompt.
struct nested_input_unconsumed_event {
    std::optional<int> step_index;  ///< the arming command's step index; omitted when unknown
    std::string direction;          ///< the armed direction token
    std::string action;             ///< the armed (never served) action id
    std::string reason;             ///< "command_completed"
};

// --- Spike 12A pickup prompt/menu transaction observability: the in-menu prompt exchange is recorded as a
// sequence of events so a reader can reconstruct which command opened the menu, the REAL choices shown, the
// answer, the registered actions it translated into, whether the engine accepted it, and that the engine's
// own menu loop consumed those actions to completion (the resulting state change is the command's following
// `export` record). ---

/// One menu choice as recorded in a `prompt_opened` event: index/text mirror the engine's live menu entry
/// (e.g. pickup's stacked_here display name), NOT snapshot-derived data.
struct prompt_choice_log {
    int index = 0;
    std::string text;
    bool enabled = true;
};

/// `prompt_opened`: a real engine prompt/menu was reached during a command and exposed to the client.
/// `kind` is the prompt class (v0: "menu"); `choices` are the engine's real entries.
struct prompt_opened_event {
    std::optional<int> step_index;
    std::string kind;
    std::vector<prompt_choice_log> choices;
};

/// `prompt_answered`: the client chose one or more listed options; the backend translated `choices` into
/// the registered input `actions` (e.g. ["RIGHT","DOWN","DOWN","RIGHT","CONFIRM"]) the engine's OWN menu
/// loop then consumes (one `RIGHT` mark per chosen entry, navigated by `DOWN`, finalized by `CONFIRM`).
struct prompt_answered_event {
    std::optional<int> step_index;
    std::vector<int> choices;
    std::vector<std::string> actions;
};

/// `prompt_cancelled`: the client cancelled (or disconnected); the backend armed the menu's cancel action
/// (== the GUI player pressing ESC). `reason` is "client_cancel" (live cancel or EOF mid-prompt) or
/// "no_channel" (script/one-shot mode, where there is no answer channel to ask on).
struct prompt_cancelled_event {
    std::optional<int> step_index;
    std::string reason;
};

/// `prompt_failed`: an invalid/malformed prompt answer was rejected; the prompt stays open for a retry and
/// NO engine state was touched. `detail` is human-readable.
struct prompt_failed_event {
    std::optional<int> step_index;
    std::string reason;
    std::string detail;
};

/// `prompt_completed`: control returned to the top-level seam after the transaction -- the engine's menu
/// loop consumed `actions_served` registered actions to completion (or cancel).
struct prompt_completed_event {
    std::optional<int> step_index;
    int actions_served = 0;
};

// --- Pure formatters: each writes exactly one JSON Lines record (a compact object + trailing '\n') to
// `out`. Exposed so the transcript format can be unit-tested without a file or a loaded world. ---

auto write_session_start_line( std::ostream &out, const session_start_event &ev ) -> void;
auto write_command_line( std::ostream &out, const command_event &ev ) -> void;
auto write_export_line( std::ostream &out, const export_event &ev ) -> void;
auto write_error_line( std::ostream &out, const error_event &ev ) -> void;
auto write_session_end_line( std::ostream &out, const session_end_event &ev ) -> void;
auto write_nested_input_answer_line( std::ostream &out,
                                     const nested_input_answer_event &ev ) -> void;
auto write_nested_input_guard_line( std::ostream &out, const nested_input_guard_event &ev ) -> void;
auto write_nested_input_unconsumed_line( std::ostream &out,
        const nested_input_unconsumed_event &ev ) -> void;
auto write_prompt_opened_line( std::ostream &out, const prompt_opened_event &ev ) -> void;
auto write_prompt_answered_line( std::ostream &out, const prompt_answered_event &ev ) -> void;
auto write_prompt_cancelled_line( std::ostream &out, const prompt_cancelled_event &ev ) -> void;
auto write_prompt_failed_line( std::ostream &out, const prompt_failed_event &ev ) -> void;
auto write_prompt_completed_line( std::ostream &out, const prompt_completed_event &ev ) -> void;

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

/// Writes a `nested_input_answer` record. No-op if no log is open. (Spike 11A)
auto session_log_nested_input_answer( const nested_input_answer_event &ev ) -> void;

/// Writes a `nested_input_guard` record. No-op if no log is open. (Spike 11A)
auto session_log_nested_input_guard( const nested_input_guard_event &ev ) -> void;

/// Writes a `nested_input_unconsumed` record. No-op if no log is open. (Spike 11A)
auto session_log_nested_input_unconsumed( const nested_input_unconsumed_event &ev ) -> void;

/// Writes the Spike 12A pickup prompt/menu transaction records. Each is a no-op if no log is open.
auto session_log_prompt_opened( const prompt_opened_event &ev ) -> void;
auto session_log_prompt_answered( const prompt_answered_event &ev ) -> void;
auto session_log_prompt_cancelled( const prompt_cancelled_event &ev ) -> void;
auto session_log_prompt_failed( const prompt_failed_event &ev ) -> void;
auto session_log_prompt_completed( const prompt_completed_event &ev ) -> void;

/// Writes the final `session_end` record (filling snapshots/commands from the counters), flushes, closes
/// the file, and clears the session. No-op if no log is open.
auto end_session_log( const session_end_summary &summary ) -> void;

} // namespace arcopolis
