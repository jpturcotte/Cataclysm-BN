#include "catch/catch.hpp"

#include <algorithm>
#include <optional>
#include <sstream>
#include <string>

#include "arcopolis_command.h"      // command_error_kind, exit_code_for
#include "arcopolis_session_log.h"  // the JSON Lines transcript formatters
#include "json.h"                   // JsonIn, JsonObject, JsonArray

// Unit tests for the Arcopolis session transcript (Spike 3.1C). These cover the PURE formatters
// (write_*_line) -- the world-independent core that turns an event into one JSON Lines record. The
// stateful file writer (begin/end_session_log) opens a real file and is exercised by the headless binary
// run against ArcopolisTest, not here, mirroring the backend-input test's split.

namespace
{

/// True iff `s` is exactly one newline-terminated line (a single JSON Lines record): non-empty, ends in
/// '\n', and contains no other newline.
auto is_one_line( const std::string &s ) -> bool
{
    namespace ranges = std::ranges;
    return !s.empty() && s.back() == '\n' && ranges::count( s, '\n' ) == 1;
}

/// Parses one formatted record and runs `check` on the resulting object. JsonObject keeps a raw JsonIn*
/// (and reads members from the stream), so the istringstream + JsonIn must stay alive across the reads --
/// hence the callback rather than returning the object. Folds in the shared "one JSON Lines record with
/// schema_version 1" assertions every event must satisfy.
template<typename Check>
auto with_record( const std::string &line, Check check ) -> void
{
    REQUIRE( is_one_line( line ) );
    std::istringstream is( line );
    JsonIn json( is );
    auto obj = json.get_object();  // throws JsonError (fails the test) on malformed JSON
    obj.allow_omitted_members();
    CHECK( obj.get_int( "schema_version" ) == 1 );
    check( obj );
}

} // namespace

TEST_CASE( "arcopolis session_start record is one valid JSON Lines object", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_session_start_line( out, { .world = "ArcopolisTest",
                                         .seed = std::nullopt,
                                         .export_dir = "out/arco",
                                         .game_version = "test-version"
                                              } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "session_start" );
        CHECK( obj.get_string( "world" ) == "ArcopolisTest" );
        CHECK( obj.get_string( "export_dir" ) == "out/arco" );
        CHECK( obj.get_string( "game_version" ) == "test-version" );
        CHECK_FALSE( obj.has_member( "seed" ) );  // omitted when absent
    } );
}

TEST_CASE( "arcopolis session_start writes seed only when present", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_session_start_line( out, { .world = "W",
                                         .seed = std::optional<std::string>( "abc123" ),
                                         .export_dir = "d",
                                         .game_version = "v"
                                              } );
    with_record( out.str(), []( const auto & obj ) {
        REQUIRE( obj.has_member( "seed" ) );
        CHECK( obj.get_string( "seed" ) == "abc123" );
    } );
}

TEST_CASE( "arcopolis command record carries direction and action_id for a move", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_command_line( out, { .step_index = 1,
                                          .command = "move",
                                          .direction = "move_s",
                                          .action_id = std::optional<std::string>( "move_back" )
                                        } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "command" );
        CHECK( obj.get_int( "step_index" ) == 1 );
        CHECK( obj.get_string( "command" ) == "move" );
        CHECK( obj.get_string( "direction" ) == "move_s" );
        CHECK( obj.get_string( "action_id" ) == "move_back" );
        CHECK( obj.get_string( "status" ) == "queued" );
    } );
}

TEST_CASE( "arcopolis command record omits direction for a directionless command", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_command_line( out, { .step_index = 5,
                                          .command = "wait",
                                          .direction = "",
                                          .action_id = std::optional<std::string>( "pause" )
                                        } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "command" ) == "wait" );
        CHECK_FALSE( obj.has_member( "direction" ) );  // empty -> omitted
        CHECK( obj.get_string( "action_id" ) == "pause" );
        CHECK( obj.get_string( "status" ) == "queued" );
    } );
}

TEST_CASE( "arcopolis command record omits action_id when unresolved", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_command_line( out, { .step_index = 0,
                                          .command = "move",
                                          .direction = "move_e",
                                          .action_id = std::nullopt
                                        } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK_FALSE( obj.has_member( "action_id" ) );
    } );
}

TEST_CASE( "arcopolis export record carries a pos_abs array and an integer step_index",
           "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_export_line( out, { .step_index = std::optional<int>( 2 ),
                                         .export_index = 1,
                                         .name = "after_move1",
                                         .path = "001_after_move1.json",
                                         .final = false,
                                         .turn = 1324801,
                                         .pos_abs = { .x = 12, .y = 69, .z = 0 },
                                         .moves = 0
                                       } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "export" );
        CHECK( obj.get_int( "step_index" ) == 2 );
        CHECK( obj.get_int( "export_index" ) == 1 );
        CHECK( obj.get_string( "name" ) == "after_move1" );
        CHECK( obj.get_string( "path" ) == "001_after_move1.json" );  // relative filename, not absolute
        CHECK_FALSE( obj.get_bool( "final" ) );
        CHECK( obj.get_int( "turn" ) == 1324801 );
        CHECK( obj.get_int( "moves" ) == 0 );

        auto pos = obj.get_array( "pos_abs" );
        REQUIRE( pos.size() == 3 );
        CHECK( pos.get_int( 0 ) == 12 );
        CHECK( pos.get_int( 1 ) == 69 );
        CHECK( pos.get_int( 2 ) == 0 );
    } );
}

TEST_CASE( "arcopolis export record writes a null step_index for the final snapshot",
           "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_export_line( out, { .step_index = std::nullopt,
                                         .export_index = 4,
                                         .name = "final",
                                         .path = "004_final.json",
                                         .final = true,
                                         .turn = 1324803,
                                         .pos_abs = { .x = 12, .y = 70, .z = 0 },
                                         .moves = 100
                                       } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.has_null( "step_index" ) );  // final-on-exit snapshot belongs to no steps[] entry
        CHECK( obj.get_bool( "final" ) );
        CHECK( obj.get_int( "export_index" ) == 4 );
    } );
}

TEST_CASE( "arcopolis error record maps the kind to its name and exit code", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_error_line( out, { .step_index = std::optional<int>( 4 ),
                                        .kind = arcopolis::command_error_kind::export_failed,
                                        .detail = "failed to write snapshot to 'x'"
                                      } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "error" );
        CHECK( obj.get_int( "step_index" ) == 4 );
        CHECK( obj.get_string( "kind" ) == "export_failed" );
        CHECK( obj.get_string( "detail" ) == "failed to write snapshot to 'x'" );
        CHECK( obj.get_int( "exit_code" ) ==
               arcopolis::exit_code_for( arcopolis::command_error_kind::export_failed ) );  // 9
    } );
}

TEST_CASE( "arcopolis error record omits step_index when unknown", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_error_line( out, { .step_index = std::nullopt,
                                        .kind = arcopolis::command_error_kind::game_over,
                                        .detail = "the game ended"
                                      } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK_FALSE( obj.has_member( "step_index" ) );
        CHECK( obj.get_string( "kind" ) == "game_over" );
        CHECK( obj.get_int( "exit_code" ) ==
               arcopolis::exit_code_for( arcopolis::command_error_kind::game_over ) );
    } );
}

TEST_CASE( "arcopolis session_end record carries counts and final state", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_session_end_line( out, { .status = "ok",
                                       .snapshots = 5,
                                       .commands = 3,
                                       .final_turn = std::optional<int>( 1324803 ),
                                       .final_pos_abs = arcopolis::session_log_point{ .x = 12, .y = 70, .z = 0 }
                                            } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "session_end" );
        CHECK( obj.get_string( "status" ) == "ok" );
        CHECK( obj.get_int( "snapshots" ) == 5 );
        CHECK( obj.get_int( "commands" ) == 3 );
        CHECK( obj.get_int( "final_turn" ) == 1324803 );

        auto pos = obj.get_array( "final_pos_abs" );
        REQUIRE( pos.size() == 3 );
        CHECK( pos.get_int( 1 ) == 70 );
    } );
}

TEST_CASE( "arcopolis session_end omits final state when absent", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_session_end_line( out, { .status = "error",
                                       .snapshots = 0,
                                       .commands = 0,
                                       .final_turn = std::nullopt,
                                       .final_pos_abs = std::nullopt
                                            } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "status" ) == "error" );
        CHECK_FALSE( obj.has_member( "final_turn" ) );
        CHECK_FALSE( obj.has_member( "final_pos_abs" ) );
    } );
}

TEST_CASE( "arcopolis transcript is valid JSON Lines: every line parses as a JSON object",
           "[arcopolis]" )
{
    // Concatenate one of each event into a single buffer, exactly as the file accumulates them.
    std::ostringstream out;
    arcopolis::write_session_start_line( out, { .world = "W", .seed = std::nullopt,
                                         .export_dir = "d", .game_version = "v"
                                              } );
    arcopolis::write_export_line( out, { .step_index = std::optional<int>( 0 ), .export_index = 0,
                                         .name = "start", .path = "000_start.json", .final = false,
                                         .turn = 1, .pos_abs = { .x = 0, .y = 0, .z = 0 }, .moves = 100
                                       } );
    arcopolis::write_command_line( out, { .step_index = 1, .command = "move", .direction = "move_s",
                                          .action_id = std::optional<std::string>( "move_back" )
                                        } );
    arcopolis::write_error_line( out, { .step_index = std::nullopt,
                                        .kind = arcopolis::command_error_kind::backend_stalled,
                                        .detail = "stalled"
                                      } );
    arcopolis::write_session_end_line( out, { .status = "error", .snapshots = 1, .commands = 1,
                                       .final_turn = std::nullopt, .final_pos_abs = std::nullopt
                                            } );

    // JSON Lines: one record per '\n'-terminated line. getline strips the '\n'; each non-empty line must
    // parse as a JSON object carrying schema_version + event.
    std::istringstream all( out.str() );
    std::string line;
    auto parsed = 0;
    while( std::getline( all, line ) ) {
        if( line.empty() ) {
            continue;
        }
        std::istringstream is( line );
        JsonIn json( is );
        auto obj = json.get_object();  // throws JsonError (fails the test) on malformed JSON
        obj.allow_omitted_members();
        CHECK( obj.get_int( "schema_version" ) == 1 );
        CHECK( obj.has_member( "event" ) );
        ++parsed;
    }
    CHECK( parsed == 5 );
}

TEST_CASE( "arcopolis session_start records the loaded autoselect option", "[arcopolis]" )
{
    // Spike 11A, doc 25 gate (h): the loaded AUTOSELECT_SINGLE_VALID_TARGET value is RECORDED (never
    // overridden) so examine witnesses are config-explicit.
    std::ostringstream out_true;
    arcopolis::write_session_start_line( out_true, { .world = "W", .export_dir = "d",
                                         .game_version = "v",
                                         .autoselect_single_valid_target = true
                                                   } );
    with_record( out_true.str(), []( const auto & obj ) {
        REQUIRE( obj.has_member( "autoselect_single_valid_target" ) );
        CHECK( obj.get_bool( "autoselect_single_valid_target" ) );
    } );

    std::ostringstream out_false;
    arcopolis::write_session_start_line( out_false, { .world = "W", .export_dir = "d",
                                         .game_version = "v",
                                         .autoselect_single_valid_target = false
                                                    } );
    with_record( out_false.str(), []( const auto & obj ) {
        REQUIRE( obj.has_member( "autoselect_single_valid_target" ) );
        CHECK_FALSE( obj.get_bool( "autoselect_single_valid_target" ) );
    } );
}

TEST_CASE( "arcopolis nested_input_answer record carries context, direction and action",
           "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_nested_input_answer_line( out, { .step_index = std::optional<int>( 3 ),
            .context = "DEFAULTMODE",
            .direction = "move_n",
            .action = "UP"
                                                    } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "nested_input_answer" );
        CHECK( obj.get_int( "step_index" ) == 3 );
        CHECK( obj.get_string( "context" ) == "DEFAULTMODE" );
        CHECK( obj.get_string( "direction" ) == "move_n" );
        CHECK( obj.get_string( "action" ) == "UP" );
    } );
}

TEST_CASE( "arcopolis nested_input_guard record carries the cancel, reason and fire count",
           "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_nested_input_guard_line( out, { .step_index = std::nullopt,
            .context = "PICKUP",
            .action = "QUIT",
            .reason = "no_answer",
            .fires = 1
                                                   } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "nested_input_guard" );
        CHECK_FALSE( obj.has_member( "step_index" ) );  // omitted when unknown
        CHECK( obj.get_string( "context" ) == "PICKUP" );
        CHECK( obj.get_string( "action" ) == "QUIT" );
        CHECK( obj.get_string( "reason" ) == "no_answer" );
        CHECK( obj.get_int( "fires" ) == 1 );
    } );
}

TEST_CASE( "arcopolis nested_input_unconsumed record explains the force-clear", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_nested_input_unconsumed_line( out, { .step_index = std::optional<int>( 4 ),
            .direction = "move_w",
            .action = "LEFT",
            .reason = "command_completed"
                                                        } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "nested_input_unconsumed" );
        CHECK( obj.get_int( "step_index" ) == 4 );
        CHECK( obj.get_string( "direction" ) == "move_w" );
        CHECK( obj.get_string( "action" ) == "LEFT" );
        CHECK( obj.get_string( "reason" ) == "command_completed" );
    } );
}

TEST_CASE( "arcopolis error record names nested_input_failed with exit code 12", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_error_line( out, { .step_index = std::nullopt,
                                        .kind = arcopolis::command_error_kind::nested_input_failed,
                                        .detail = "no cancel action registered"
                                      } );
    with_record( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "event" ) == "error" );
        CHECK( obj.get_string( "kind" ) == "nested_input_failed" );
        CHECK( obj.get_int( "exit_code" ) == 12 );
    } );
}
