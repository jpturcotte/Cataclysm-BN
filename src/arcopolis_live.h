#pragma once

#include <expected>
#include <iosfwd>
#include <optional>
#include <string>

namespace arcopolis
{

/// The only live-protocol version this spike speaks (echoed in the `ready` event). Independent of the
/// snapshot and transcript schema_versions (all three happen to be 1).
constexpr auto live_protocol_version = 1;

/// One decoded live-protocol request: a single JSON object read from one stdin line (Spike 9B).
struct live_request {
    std::optional<int> id;  ///< client correlation id, echoed in the response; nullopt when absent
    std::string op;         ///< "export" | "command" | "quit"
    std::string command;    ///< command verb for op == "command" ("wait" / "move"); empty otherwise
    std::string direction;  ///< direction ident for command "move"; empty otherwise
    std::string
    name;       ///< export label for op == "export"/"command" ("snapshot" when omitted)
};

/// Machine-readable live-protocol error codes (the response's error.code). The first three are
/// RECOVERABLE (the session keeps accepting requests); the last three are fatal and end the session
/// right after the response, mirroring the run_script exit semantics.
enum class live_error_code {
    malformed_json,       ///< the line is not a well-formed JSON object
    bad_request,          ///< structurally invalid: missing/mistyped field, unknown op, invalid name
    unsupported_command,  ///< vocabulary rejection: unknown verb or unsupported direction
    export_failed,        ///< a snapshot could not be written (fatal; process exits 9)
    game_over,            ///< the game ended while a command was in flight (fatal; process exits 11)
    backend_stalled,      ///< the engine stopped consuming input (fatal; process exits 10)
};

/// A protocol-level failure: the code, a human-readable message, and the request id when one could be
/// read before the failure (echoed back; JSON null otherwise).
struct live_error {
    live_error_code code = live_error_code::bad_request;
    std::string message;
    std::optional<int> id;
};

/// The wire name for a live_error_code (the response's error.code string).
auto live_error_code_name( live_error_code code ) -> std::string;

/// Parses + STRUCTURALLY validates one protocol request line. Vocabulary is deliberately NOT checked
/// here ("move" + "move_up" parses fine) -- command_to_action() is the single rejection point for
/// verbs/directions, so the parser and the resolver can never disagree. The export label `name` is
/// whitelisted to [A-Za-z0-9_.-] (max 64 chars; "snapshot" when omitted): ensure_valid_file_name()
/// strips only \/:?"<>|, so an unchecked control character would survive into the snapshot filename,
/// fail the file open, and escalate a recoverable typo into a fatal export_failed. Exposed for unit
/// tests (pure; no engine state).
auto parse_live_request( const std::string &line ) -> std::expected<live_request, live_error>;

// --- Pure protocol-line formatters: each writes exactly one compact JSON object + trailing '\n' to
// `out` (the caller flushes -- std::_Exit skips iostream flushing, so every line is flushed at the
// write site). Exposed so the wire format can be unit-tested without a process or a loaded world. ---

/// `ready`: written once on successful startup (world loaded, transcript open), before any request is
/// read: { "type": "ready", "protocol_version": 1, "ok": true, "world": <world> }.
struct live_ready_event {
    std::string world;
};
auto write_ready_line( std::ostream &out, const live_ready_event &ev ) -> void;

/// A successful export/command response. `snapshot` is the relative NNN_<name>.json filename; `turn`
/// equals the snapshot's backend.turn (read at the same instant).
struct live_success_response {
    std::optional<int> id;  ///< the request's id (JSON null when the request omitted it)
    std::string op;         ///< "export" or "command"
    std::string snapshot;
    int export_index = 0;
    int turn = 0;
};
auto write_success_response_line( std::ostream &out, const live_success_response &ev ) -> void;

/// The quit acknowledgement: { ..., "op": "quit", "status": "session_end" }. The final-on-exit
/// snapshot and the transcript's session_end record are written AFTER this response, before exit.
struct live_quit_response {
    std::optional<int> id;
};
auto write_quit_response_line( std::ostream &out, const live_quit_response &ev ) -> void;

/// An error response (ok = false). `id` is written as JSON null when absent (e.g. malformed JSON);
/// `op` is omitted when unknown for the same reason.
struct live_error_response {
    std::optional<int> id;
    std::string op;  ///< omitted from the wire when empty
    live_error_code code = live_error_code::bad_request;
    std::string message;
};
auto write_error_response_line( std::ostream &out, const live_error_response &ev ) -> void;

/// Inputs for a persistent live session: load `world` EXACTLY ONCE, then serve the stdin/stdout JSON
/// Lines protocol until quit/EOF, writing snapshots + session.jsonl into `export_dir`.
struct live_options {
    std::string world;       ///< prepared world/save to load headlessly (required)
    std::string export_dir;  ///< directory snapshots + session.jsonl are written into (required)
    std::optional<std::string>
    seed;  ///< original --seed CLI string for the transcript's session_start; nullopt if not passed
};

/// Loads `opts.world` once, emits `ready`, then drives the engine's own turn loop with a BLOCKING
/// stdin request pump as the input source at the game::handle_action() seam -- the backend blocks
/// exactly where the GUI blocks on a keypress, so multi-action turns, turn-end and the world tick all
/// stay engine-owned (mechanism M1; see docs/arcopolis/21_SPIKE9B_LIVE_PROTOCOL.md). stdout carries
/// ONLY protocol lines; diagnostics go to stderr. Returns a process exit code (0 = clean quit/EOF).
auto run_live( const live_options &opts ) -> int;

} // namespace arcopolis
