#pragma once

#include <expected>
#include <iosfwd>
#include <optional>
#include <string>
#include <vector>

#include "arcopolis_backend_input.h"  // pickup_prompt_choice (the Spike 12A prompt event's choice list)

namespace arcopolis
{

/// The only live-protocol version this spike speaks (echoed in the `ready` event). Independent of the
/// snapshot and transcript schema_versions (all three happen to be 1).
constexpr auto live_protocol_version = 1;

/// One decoded live-protocol request: a single JSON object read from one stdin line (Spike 9B).
///
/// FUTURE DIRECTION (not load-bearing for Spike 26A): with four ops today the flat struct stays
/// readable, but the per-op field clusters (export's `name`; command's `command`/`direction`; query's
/// `query_kind`/`query_item`/`query_count`) are starting to imply a tagged-union shape. If a fifth or
/// sixth op lands (e.g. Spike 26B's `crafting_has_item` extending query, or a future `subscribe` op),
/// reshape this as a `std::variant<live_export_request, live_command_request, live_query_request,
/// live_quit_request>` -- the parser already structurally validates per-op, so the variant fits the
/// dispatch shape without losing the single-rejection-point design. Deferred deliberately: the
/// refactor would touch the parser, the response formatters, AND every caller of `live_request`
/// field accessors, well beyond Spike 26A's scope.
struct live_request {
    std::optional<int> id;  ///< client correlation id, echoed in the response; nullopt when absent
    std::string op;         ///< "export" | "command" | "quit" | "query"
    std::string command;    ///< command verb for op == "command" ("wait" / "move"); empty otherwise
    std::string direction;  ///< direction ident for command "move"; empty otherwise
    std::string
    name;       ///< export label for op == "export"/"command" ("snapshot" when omitted)
    // --- Spike 26A: op == "query" fields. Empty / default for every other op. The query is a
    // parameterized read-only observation of an engine predicate (no engine action, no per-transaction
    // gate, no transcript engine event). v0 accepts kind == "has_item" only; the kind discriminator
    // exists so Spike 26B can add "crafting_has_item" additively without re-shaping the wire. ---
    std::string
    query_kind; ///< query kind for op == "query" (v0: "has_item"); empty otherwise
    std::string query_item; ///< itype_id string for op == "query"; empty otherwise
    int query_count = 1;    ///< requested quantity (>= 1) for op == "query"; defaults to 1 when omitted
};

/// Machine-readable live-protocol error codes (the response's error.code). The first three are
/// RECOVERABLE (the session keeps accepting requests); the last three are fatal and end the session
/// right after the response, mirroring the run_script exit semantics.
enum class live_error_code {
    malformed_json,       ///< the line is not a well-formed JSON object
    bad_request,          ///< structurally invalid: missing/mistyped field, unknown op, invalid name
    unsupported_command,  ///< vocabulary rejection: unknown verb or unsupported direction
    unexpected_prompt,    ///< RECOVERABLE: the command reached an UNARMED player-visible prompt that would
    ///< have silently test_mode-defaulted; reported ok=false (never success) and the session keeps serving
    ///< (Spike 20). The engine already handled query_once's fallback as a safe cancel/default.
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
/// equals the snapshot's backend.turn (read at the same instant). The Spike 12A-follow-up marker set is
/// emitted ONLY for a pickup whose activity force-cancelled an unsupported SECONDARY prompt (capacity/
/// wield/spill): `ok` stays true because a real PARTIAL pickup happened (what fit was carried), but the
/// three markers make the partiality unmistakable so the result is never read as a full success. They are
/// all absent for every other response (every non-pickup command, and a clean pickup), so existing wire
/// output is byte-unchanged.
struct live_success_response {
    std::optional<int> id;  ///< the request's id (JSON null when the request omitted it)
    std::string op;         ///< "export" or "command"
    std::string snapshot;
    int export_index = 0;
    int turn = 0;
    bool forced_cancel =
        false;          ///< a secondary prompt was force-cancelled (markers emitted iff true)
    bool partial = false;                ///< the pickup carried only part of the selection
    std::string
    unsupported_prompt;      ///< which prompt class was declined (e.g. "secondary_capacity")
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

/// Spike 26A: a successful query response. v0 only accepts kind == "has_item" (the parser rejects any
/// other) and always reports scope == "on_person_dialogue_predicate" — the scope string is a
/// load-bearing labeling guard repeated VERBATIM across the doc 52 spike doc, the ARCOPOLIS_STATE row,
/// and the Catch2 test name, so a future doc-or-code drift cannot silently re-claim mission-completion
/// scope without touching every coordinated site. `kind` is echoed from the request rather than
/// hardcoded so Spike 26B can reuse this formatter for kind "crafting_has_item" (scope
/// "crafting_inventory") without a wire change. See docs/arcopolis/52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md.
struct live_query_response {
    std::optional<int> id;  ///< the request's id (JSON null when the request omitted it)
    std::string
    kind;       ///< query kind echoed back (v0: "has_item"); set from the request's query_kind
    bool has = false;       ///< the engine predicate's verbatim answer
    std::string scope;      ///< "on_person_dialogue_predicate" for v0 has_item kind
};
auto write_query_response_line( std::ostream &out, const live_query_response &ev ) -> void;

// --- Spike 12A pickup prompt/menu transaction wire format. A command that reaches a real in-action menu
// emits a `prompt` event (its terminal response is deferred until the prompt is answered), the client
// replies with a `prompt_answer`/`prompt_cancel`, and only then does the engine resume and the command's
// success response follow at the next input-rest. ---

/// `prompt`: a real in-action engine menu was reached during a command and is exposed to the client. `id`
/// echoes the in-flight command's id; `prompt_id` correlates the answer; `choices` are the engine's REAL
/// live menu entries (not snapshot-derived).
struct live_prompt_event {
    std::optional<int> id;
    int prompt_id = 0;
    std::string kind;   ///< prompt class (v0: "menu")
    std::string title;
    std::vector<pickup_prompt_choice> choices;
    bool cancelable = true;
};
auto write_prompt_line( std::ostream &out, const live_prompt_event &ev ) -> void;

/// Ack for a prompt answer. On a valid selection: ok:true with the accepted `choices`. On an explicit
/// cancel: ok:true with `choices` nullopt (cancelled:true on the wire). Invalid answers instead reuse
/// write_error_response_line and the prompt stays OPEN for a retry.
struct live_prompt_ack {
    std::optional<int> id;
    int prompt_id = 0;
    std::optional<std::vector<int>> choices;  ///< the accepted index/indices; nullopt => cancelled
};
auto write_prompt_ack_line( std::ostream &out, const live_prompt_ack &ev ) -> void;

/// One decoded prompt answer (Spike 12A): the chosen menu index/indices, or an explicit cancel. A single
/// `"choice": K` decodes to `choices == {K}`; a `"choices": [...]` array decodes to the listed indices
/// (multi-select).
struct live_prompt_answer {
    enum class action { choose, cancel };
    action act = action::cancel;
    std::optional<int> id;     ///< the answer request's id (echoed in the ack)
    int prompt_id =
        0;         ///< the prompt this answers; the caller rejects a mismatch with the active id
    std::vector<int>
    choices;  ///< the chosen menu indices, sorted + duplicate-free; valid when act == choose
};

/// Parses + validates one prompt-answer line against the menu size. `op` must be "prompt_answer" (carrying
/// either an int "choice" or a non-empty int-array "choices", each in [0, num_choices), with NO duplicates)
/// or "prompt_cancel"; both ops REQUIRE an integer "prompt_id" (the caller checks it against the active
/// prompt). The accepted `choices` are returned sorted + duplicate-free. A missing prompt_id, a
/// missing/out-of-range/empty/duplicate selection, or any other op is a RECOVERABLE bad_request (the caller
/// rejects it, logs prompt_failed, and keeps the prompt open). Exposed for unit tests (pure; no engine state).
auto parse_prompt_answer( const std::string &line, int num_choices )
-> std::expected<live_prompt_answer, live_error>;

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
