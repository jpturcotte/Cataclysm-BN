#include "arcopolis_session_log.h"

#include <filesystem>
#include <optional>
#include <ostream>
#include <string>

#include "arcopolis_command.h"  // exit_code_for
#include "fstream_utils.h"      // cata_ofstream, cata_ios_mode
#include "json.h"               // JsonOut

namespace
{

/// Opens a record: `{ "schema_version": 1, "event": "<event>"`. The compact JsonOut (pretty_print=false)
/// keeps the whole object on one line, as JSON Lines requires.
auto begin_record( JsonOut &json, const char *event ) -> void
{
    json.start_object();
    json.member( "schema_version", arcopolis::session_log_schema_version );
    json.member( "event", std::string( event ) );
}

/// Writes `"<name>": [x, y, z]`, matching the snapshot's pos_abs array shape.
auto write_point( JsonOut &json, const char *name, const arcopolis::session_log_point &p ) -> void
{
    json.member( std::string( name ) );
    json.start_array();
    json.write( p.x );
    json.write( p.y );
    json.write( p.z );
    json.end_array();
}

/// The machine-readable name written for an `error` record's kind. Kept beside the writer (not widened
/// into arcopolis_command's public API) since it is transcript-formatting only.
auto error_kind_name( arcopolis::command_error_kind kind ) -> std::string
{
    using kind_t = arcopolis::command_error_kind;
    switch( kind ) {
        case kind_t::missing_file:
            return "missing_file";
        case kind_t::unreadable_file:
            return "unreadable_file";
        case kind_t::invalid_json:
            return "invalid_json";
        case kind_t::bad_schema:
            return "bad_schema";
        case kind_t::unsupported_command:
            return "unsupported_command";
        case kind_t::safe_mode_blocked:
            return "safe_mode_blocked";
        case kind_t::apply_failed:
            return "apply_failed";
        case kind_t::export_failed:
            return "export_failed";
        case kind_t::backend_stalled:
            return "backend_stalled";
        case kind_t::game_over:
            return "game_over";
        case kind_t::nested_input_failed:
            return "nested_input_failed";
    }
    return "unknown";
}

/// Translation-unit-local transcript. A single open session at a time; begin/end toggle `active`. Holds
/// the UTF-8 file stream plus running counts surfaced in the session_end record.
struct session_log_state {
    bool active = false;
    cata_ofstream stream;
    int command_count = 0;
    int export_count = 0;
};

session_log_state s_log;

} // namespace

auto arcopolis::write_session_start_line( std::ostream &out, const session_start_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "session_start" );
    json.member( "world", ev.world );
    if( ev.seed ) {
        json.member( "seed", *ev.seed );
    }
    json.member( "export_dir", ev.export_dir );
    json.member( "game_version", ev.game_version );
    json.member( "autoselect_single_valid_target", ev.autoselect_single_valid_target );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_command_line( std::ostream &out, const command_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "command" );
    json.member( "step_index", ev.step_index );
    json.member( "command", ev.command );
    if( !ev.direction.empty() ) {
        json.member( "direction", ev.direction );
    }
    if( ev.action_id ) {
        json.member( "action_id", *ev.action_id );
    }
    json.member( "status", std::string( "queued" ) );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_export_line( std::ostream &out, const export_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "export" );
    // step_index is null for the final-on-exit snapshot (it belongs to no steps[] entry); the int form is
    // used for every export step, mirroring the snapshot's session.step_index.
    json.member( "step_index" );
    if( ev.step_index ) {
        json.write( *ev.step_index );
    } else {
        json.write_null();
    }
    json.member( "export_index", ev.export_index );
    json.member( "name", ev.name );
    json.member( "path", ev.path );
    json.member( "final", ev.final );
    json.member( "turn", ev.turn );
    write_point( json, "pos_abs", ev.pos_abs );
    json.member( "moves", ev.moves );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_error_line( std::ostream &out, const error_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "error" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "kind", error_kind_name( ev.kind ) );
    json.member( "detail", ev.detail );
    json.member( "exit_code", exit_code_for( ev.kind ) );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_nested_input_answer_line( std::ostream &out,
        const nested_input_answer_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "nested_input_answer" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "context", ev.context );
    json.member( "direction", ev.direction );
    json.member( "action", ev.action );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_nested_input_guard_line( std::ostream &out,
        const nested_input_guard_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "nested_input_guard" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "context", ev.context );
    json.member( "action", ev.action );
    json.member( "reason", ev.reason );
    json.member( "fires", ev.fires );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_nested_input_unconsumed_line( std::ostream &out,
        const nested_input_unconsumed_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "nested_input_unconsumed" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "direction", ev.direction );
    json.member( "action", ev.action );
    json.member( "reason", ev.reason );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_opened_line( std::ostream &out, const prompt_opened_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_opened" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "kind", ev.kind );
    json.member( "choices" );
    json.start_array();
    for( const prompt_choice_log &c : ev.choices ) {
        json.start_object();
        json.member( "index", c.index );
        json.member( "text", c.text );
        json.member( "enabled", c.enabled );
        json.end_object();
    }
    json.end_array();
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_answered_line( std::ostream &out,
        const prompt_answered_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_answered" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "choices" );
    json.start_array();
    for( const int c : ev.choices ) {
        json.write( c );
    }
    json.end_array();
    json.member( "actions" );
    json.start_array();
    for( const std::string &a : ev.actions ) {
        json.write( a );
    }
    json.end_array();
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_cancelled_line( std::ostream &out,
        const prompt_cancelled_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_cancelled" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "reason", ev.reason );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_failed_line( std::ostream &out, const prompt_failed_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_failed" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "reason", ev.reason );
    json.member( "detail", ev.detail );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_completed_line( std::ostream &out,
        const prompt_completed_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_completed" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "actions_served", ev.actions_served );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_prompt_force_cancelled_line( std::ostream &out,
        const prompt_force_cancelled_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "prompt_force_cancelled" );
    if( ev.step_index ) {
        json.member( "step_index", *ev.step_index );
    }
    json.member( "kind", ev.kind );
    json.member( "reason", ev.reason );
    json.end_object();
    out << '\n';
}

auto arcopolis::write_session_end_line( std::ostream &out, const session_end_event &ev ) -> void
{
    JsonOut json( out, /*pretty_print=*/false );
    begin_record( json, "session_end" );
    json.member( "status", ev.status );
    json.member( "snapshots", ev.snapshots );
    json.member( "commands", ev.commands );
    if( ev.final_turn ) {
        json.member( "final_turn", *ev.final_turn );
    }
    if( ev.final_pos_abs ) {
        write_point( json, "final_pos_abs", *ev.final_pos_abs );
    }
    json.end_object();
    out << '\n';
}

auto arcopolis::begin_session_log( const session_start_event &ev ) -> bool
{
    if( s_log.active || ev.export_dir.empty() ) {
        return false;
    }
    const auto path = ( std::filesystem::path( ev.export_dir ) / "session.jsonl" ).string();
    // Binary mode keeps line endings LF-only (JSON Lines wants '\n'); cata_ofstream handles UTF-8 paths.
    // mode()/open() return the stream itself, so this opens the member in place (no move needed).
    s_log.stream.mode( cata_ios_mode::binary ).open( path );
    if( !s_log.stream.is_open() ) {
        return false;
    }
    s_log.active = true;
    s_log.command_count = 0;
    s_log.export_count = 0;
    write_session_start_line( *s_log.stream, ev );
    s_log.stream.flush();
    return true;
}

auto arcopolis::session_log_command( const command_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_command_line( *s_log.stream, ev );
    s_log.stream.flush();
    ++s_log.command_count;
}

auto arcopolis::session_log_export( const export_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_export_line( *s_log.stream, ev );
    s_log.stream.flush();
    ++s_log.export_count;
}

auto arcopolis::session_log_error( const error_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_error_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_nested_input_answer( const nested_input_answer_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_nested_input_answer_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_nested_input_guard( const nested_input_guard_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_nested_input_guard_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_nested_input_unconsumed( const nested_input_unconsumed_event &ev ) ->
void
{
    if( !s_log.active ) {
        return;
    }
    write_nested_input_unconsumed_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_opened( const prompt_opened_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_opened_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_answered( const prompt_answered_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_answered_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_cancelled( const prompt_cancelled_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_cancelled_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_failed( const prompt_failed_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_failed_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_completed( const prompt_completed_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_completed_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::session_log_prompt_force_cancelled( const prompt_force_cancelled_event &ev ) -> void
{
    if( !s_log.active ) {
        return;
    }
    write_prompt_force_cancelled_line( *s_log.stream, ev );
    s_log.stream.flush();
}

auto arcopolis::end_session_log( const session_end_summary &summary ) -> void
{
    if( !s_log.active ) {
        return;
    }
    const auto ev = session_end_event{
        .status = summary.status,
        .snapshots = s_log.export_count,
        .commands = s_log.command_count,
        .final_turn = summary.final_turn,
        .final_pos_abs = summary.final_pos_abs,
    };
    write_session_end_line( *s_log.stream, ev );
    s_log.stream.flush();
    s_log.stream.close();
    s_log.active = false;
    s_log.command_count = 0;
    s_log.export_count = 0;
}
