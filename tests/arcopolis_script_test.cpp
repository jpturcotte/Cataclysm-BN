#include "catch/catch.hpp"

#include <sstream>

#include "arcopolis_command.h"
#include "arcopolis_script.h"

// Unit tests for the Arcopolis Spike 2 step-SCRIPT parser and validation. These are pure and
// world-independent. The STATEFUL apply path (load once + export/command loop, and the load-once
// clock advance) needs a fully loaded world and is verified by the headless binary run against
// ArcopolisTest, not here.

TEST_CASE( "arcopolis parse_script accepts a valid export/command script", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "export",  "name": "after_load" },
        { "op": "command", "command": "wait" },
        { "op": "export",  "name": "after_wait_1" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 3 );
    CHECK( ( *result )[0].op == "export" );
    CHECK( ( *result )[0].name == "after_load" );
    CHECK( ( *result )[1].op == "command" );
    CHECK( ( *result )[1].command == "wait" );
    CHECK( ( *result )[2].op == "export" );
    CHECK( ( *result )[2].name == "after_wait_1" );
}

TEST_CASE( "arcopolis parse_script accepts an empty step list", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    CHECK( result->empty() );
}

TEST_CASE( "arcopolis parse_script leaves an omitted export name empty", "[arcopolis]" )
{
    // The "snapshot" default is applied at the use site (run_script), not in the parser.
    std::istringstream is( R"({ "schema_version": 1, "steps": [ { "op": "export" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 1 );
    CHECK( ( *result )[0].op == "export" );
    CHECK( ( *result )[0].name.empty() );
}

TEST_CASE( "arcopolis parse_script accepts examine command steps", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "examine", "direction": "move_n" },
        { "op": "command", "command": "examine", "direction": "move_sw" },
        { "op": "command", "command": "examine", "direction": "here" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 3 );
    CHECK( ( *result )[0].command == "examine" );
    CHECK( ( *result )[0].direction == "move_n" );
    CHECK( ( *result )[1].command == "examine" );
    CHECK( ( *result )[1].direction == "move_sw" );  // a diagonal -- the GUI chooser offers all 8
    CHECK( ( *result )[2].command == "examine" );
    CHECK( ( *result )[2].direction == "here" );
}

TEST_CASE( "arcopolis parse_script rejects an examine step without a direction", "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "examine" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects unsupported examine directions", "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "examine", "direction": "move_up" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects an unsupported schema_version", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 2, "steps": [] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects missing/non-array steps", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1 })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a step without an op", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [ { "name": "x" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects an unknown op", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [ { "op": "teleport" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a command op without a command", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [ { "op": "command" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script accepts a move step with a cardinal direction", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "move", "direction": "move_e" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 1 );
    CHECK( ( *result )[0].op == "command" );
    CHECK( ( *result )[0].command == "move" );
    CHECK( ( *result )[0].direction == "move_e" );
}

TEST_CASE( "arcopolis parse_script rejects a move step without a direction", "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "move" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a move step with a non-cardinal direction",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "move", "direction": "move_ne" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects malformed JSON", "[arcopolis]" )
{
    std::istringstream is( "{ not valid json" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::invalid_json );
}

TEST_CASE( "arcopolis read_script_file reports a missing file", "[arcopolis]" )
{
    const auto result = arcopolis::read_script_file( "arcopolis_nonexistent_script_file_xyz.json" );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::missing_file );
}

TEST_CASE( "arcopolis exit_code_for maps export_failed to 9", "[arcopolis]" )
{
    CHECK( arcopolis::exit_code_for( arcopolis::command_error_kind::export_failed ) == 9 );
}
