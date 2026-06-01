#include "catch/catch.hpp"

#include <sstream>

#include "arcopolis_command.h"

// Unit tests for the Arcopolis backend-command PARSER and validation (Spike 1). These are pure and
// world-independent. The "wait" APPLY path (character pause + game::do_turn) needs a fully loaded
// world and is verified by the headless binary run against ArcopolisTest, not here.

TEST_CASE( "arcopolis parse_command accepts a valid wait command", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "wait" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE( result.has_value() );
    CHECK( result->schema_version == 1 );
    CHECK( result->command == "wait" );
}

TEST_CASE( "arcopolis parse_command rejects an unsupported schema_version", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 2, "command": "wait" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects a missing command field", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1 })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects malformed JSON", "[arcopolis]" )
{
    std::istringstream is( "{ not valid json" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::invalid_json );
}

TEST_CASE( "arcopolis read_command_file reports a missing file", "[arcopolis]" )
{
    const auto result = arcopolis::read_command_file( "arcopolis_nonexistent_command_file_xyz.json" );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::missing_file );
}

TEST_CASE( "arcopolis apply_command rejects an unsupported command", "[arcopolis]" )
{
    // A non-"wait" verb is rejected before any simulation state is touched, so this is safe to call
    // without a loaded world.
    const auto result = arcopolis::apply_command( { .schema_version = 1, .command = "teleport" } );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::unsupported_command );
}

TEST_CASE( "arcopolis parse_command accepts a valid move command", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "move", "direction": "move_e" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE( result.has_value() );
    CHECK( result->command == "move" );
    CHECK( result->direction == "move_e" );
}

TEST_CASE( "arcopolis parse_command rejects a move without a direction", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "move" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects non-cardinal move directions", "[arcopolis]" )
{
    // "east" is not an engine ident; move_ne is a diagonal; move_up/move_down are vertical; "" is empty.
    // All four resolve to a valid action_id via look_up_action (except "east"/""), so the cardinal-set
    // check is what rejects them.
    for( const std::string dir : { "east", "move_ne", "move_up", "move_down", "" } ) {
        const auto json = R"({ "schema_version": 1, "command": "move", "direction": ")" + dir + R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE_FALSE( result.has_value() );
        CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis is_supported_move_direction accepts only the four cardinals", "[arcopolis]" )
{
    CHECK( arcopolis::is_supported_move_direction( "move_n" ) );
    CHECK( arcopolis::is_supported_move_direction( "move_s" ) );
    CHECK( arcopolis::is_supported_move_direction( "move_e" ) );
    CHECK( arcopolis::is_supported_move_direction( "move_w" ) );
    CHECK_FALSE( arcopolis::is_supported_move_direction( "move_ne" ) );
    CHECK_FALSE( arcopolis::is_supported_move_direction( "move_up" ) );
    CHECK_FALSE( arcopolis::is_supported_move_direction( "east" ) );
    CHECK_FALSE( arcopolis::is_supported_move_direction( "" ) );
}

TEST_CASE( "arcopolis exit_code_for maps error kinds to distinct nonzero codes", "[arcopolis]" )
{
    using kind = arcopolis::command_error_kind;
    CHECK( arcopolis::exit_code_for( kind::missing_file ) == 2 );
    CHECK( arcopolis::exit_code_for( kind::unreadable_file ) == 3 );
    CHECK( arcopolis::exit_code_for( kind::invalid_json ) == 4 );
    CHECK( arcopolis::exit_code_for( kind::bad_schema ) == 5 );
    CHECK( arcopolis::exit_code_for( kind::unsupported_command ) == 6 );
    CHECK( arcopolis::exit_code_for( kind::apply_failed ) == 7 );
    CHECK( arcopolis::exit_code_for( kind::safe_mode_blocked ) == 8 );
}
