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

TEST_CASE( "arcopolis parse_command accepts all eight planar move directions", "[arcopolis]" )
{
    // The four cardinals plus the four diagonals -- the full planar set a GUI player can step (the
    // diagonals dispatch through the same avatar_action::move body as cardinals).
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw"
         } ) {
        const auto json = R"({ "schema_version": 1, "command": "move", "direction": ")" + dir + R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE( result.has_value() );
        CHECK( result->command == "move" );
        CHECK( result->direction == dir );
    }
}

TEST_CASE( "arcopolis parse_command rejects vertical and garbage move directions", "[arcopolis]" )
{
    // Vertical (move_up/move_down) is the separate game::vertical_move primitive driven by the
    // `vertical_move` verb (Spike 24), NOT a planar `move` step; "east" is not an engine ident; "" is
    // empty. (Diagonals are now ACCEPTED -- see above.) This is the executable guard that the
    // planar/vertical split holds: `move` stays strictly planar, so the old planar-direction negative
    // probes (live/frontend recoverability) keep rejecting move_up/move_down.
    for( const std::string &dir : { "move_up", "move_down", "east", "move_nene", "" } ) {
        const auto json = R"({ "schema_version": 1, "command": "move", "direction": ")" + dir + R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE_FALSE( result.has_value() );
        CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis is_supported_move_direction accepts the eight planar directions",
           "[arcopolis]" )
{
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw"
         } ) {
        CHECK( arcopolis::is_supported_move_direction( dir ) );
    }
    // Vertical is a separate primitive; garbage/empty rejected.
    CHECK_FALSE( arcopolis::is_supported_move_direction( "move_up" ) );
    CHECK_FALSE( arcopolis::is_supported_move_direction( "move_down" ) );
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
    CHECK( arcopolis::exit_code_for( kind::nested_input_failed ) == 12 );
}

TEST_CASE( "arcopolis parse_command accepts examine with every supported direction", "[arcopolis]" )
{
    // All EIGHT planar directions the GUI examine chooser offers, plus "here" (self tile) -- the backend
    // must mirror the full chooser, not a cardinal-only subset.
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw", "here"
         } ) {
        const auto json = R"({ "schema_version": 1, "command": "examine", "direction": ")" + dir +
                          R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE( result.has_value() );
        CHECK( result->command == "examine" );
        CHECK( result->direction == dir );
    }
}

TEST_CASE( "arcopolis parse_command rejects an examine without a direction", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "examine" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects unsupported examine directions", "[arcopolis]" )
{
    // Vertical stays rejected (game::examine passes allow_vertical=false). "pause" is the CHOOSER's
    // action id, not a protocol token: the protocol spells the self-tile "here". "move_n_e"/garbage and
    // empty are rejected. (Diagonals move_ne... are now ACCEPTED -- see the acceptance test above.)
    for( const std::string &dir : { "move_up", "move_down", "east", "pause", "move_nene", "" } ) {
        const auto json = R"({ "schema_version": 1, "command": "examine", "direction": ")" + dir +
                          R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE_FALSE( result.has_value() );
        CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis is_supported_target_direction accepts all 8 planar dirs plus here",
           "[arcopolis]" )
{
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw", "here"
         } ) {
        CHECK( arcopolis::is_supported_target_direction( dir ) );
    }
    // Vertical and garbage rejected; "pause" is the action id, not the protocol token.
    CHECK_FALSE( arcopolis::is_supported_target_direction( "move_up" ) );
    CHECK_FALSE( arcopolis::is_supported_target_direction( "move_down" ) );
    CHECK_FALSE( arcopolis::is_supported_target_direction( "pause" ) );
    CHECK_FALSE( arcopolis::is_supported_target_direction( "east" ) );
    CHECK_FALSE( arcopolis::is_supported_target_direction( "" ) );
}

TEST_CASE( "arcopolis target_direction_nested_answer maps every direction to its chooser action id",
           "[arcopolis]" )
{
    // The chooser consumes input-context action ids (register_directions plus its own "pause"
    // self-tile branch), not engine action_ids; the plain mapping holds headless because no iso
    // rotation can apply (tile_iso is set only at tileset load -- docs/arcopolis/25, point 4). The
    // diagonal pairings are verified against get_direction (src/input.cpp): screen north=-y, east=+x,
    // so move_ne (north_east, +x,-y) -> "RIGHTUP", move_sw (south_west, -x,+y) -> "LEFTDOWN", etc.
    CHECK( arcopolis::target_direction_nested_answer( "move_n" ).value_or( "" ) == "UP" );
    CHECK( arcopolis::target_direction_nested_answer( "move_s" ).value_or( "" ) == "DOWN" );
    CHECK( arcopolis::target_direction_nested_answer( "move_e" ).value_or( "" ) == "RIGHT" );
    CHECK( arcopolis::target_direction_nested_answer( "move_w" ).value_or( "" ) == "LEFT" );
    CHECK( arcopolis::target_direction_nested_answer( "move_ne" ).value_or( "" ) == "RIGHTUP" );
    CHECK( arcopolis::target_direction_nested_answer( "move_nw" ).value_or( "" ) == "LEFTUP" );
    CHECK( arcopolis::target_direction_nested_answer( "move_se" ).value_or( "" ) == "RIGHTDOWN" );
    CHECK( arcopolis::target_direction_nested_answer( "move_sw" ).value_or( "" ) == "LEFTDOWN" );
    CHECK( arcopolis::target_direction_nested_answer( "here" ).value_or( "" ) == "pause" );
    CHECK_FALSE( arcopolis::target_direction_nested_answer( "move_up" ).has_value() );
    CHECK_FALSE( arcopolis::target_direction_nested_answer( "" ).has_value() );
}

TEST_CASE( "arcopolis parse_command accepts a valid pickup command", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "pickup", "direction": "move_s" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE( result.has_value() );
    CHECK( result->command == "pickup" );
    CHECK( result->direction == "move_s" );
}

TEST_CASE( "arcopolis parse_command rejects pickup without a direction", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "pickup" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects an unsupported pickup direction", "[arcopolis]" )
{
    // pickup shares the examine target chooser (allow_vertical=false), so vertical is rejected.
    std::istringstream is( R"({ "schema_version": 1, "command": "pickup", "direction": "move_up" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis is_live_only_command flags only pickup", "[arcopolis]" )
{
    // pickup's core action needs the live prompt answer channel, so non-live modes FAIL LOUD for it; every
    // other verb completes in non-live mode and must NOT be rejected (examine still examines; its tail
    // auto-cancel is the engine's own "Never mind.").
    CHECK( arcopolis::is_live_only_command( "pickup" ) );
    CHECK_FALSE( arcopolis::is_live_only_command( "wait" ) );
    CHECK_FALSE( arcopolis::is_live_only_command( "move" ) );
    CHECK_FALSE( arcopolis::is_live_only_command( "examine" ) );
    // vertical_move's matched-stair fast path is prompt-free, so it needs no answer channel: it runs in
    // --arcopolis-run-script (and one-shot) without prompt_answers, NOT live-only (Spike 24).
    CHECK_FALSE( arcopolis::is_live_only_command( "vertical_move" ) );
    CHECK_FALSE( arcopolis::is_live_only_command( "" ) );
}

TEST_CASE( "arcopolis parse_command accepts vertical_move down and up", "[arcopolis]" )
{
    // The SEPARATE vertical verb (Spike 24): a distinct "down"/"up" vocabulary, kept apart from the
    // planar move_* tokens so a frontend never confuses planar and vertical movement.
    for( const std::string &dir : { "down", "up" } ) {
        const auto json = R"({ "schema_version": 1, "command": "vertical_move", "direction": ")" + dir +
                          R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE( result.has_value() );
        CHECK( result->command == "vertical_move" );
        CHECK( result->direction == dir );
    }
}

TEST_CASE( "arcopolis parse_command rejects a vertical_move without a direction", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "command": "vertical_move" })" );
    const auto result = arcopolis::parse_command( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_command rejects non-vertical vertical_move directions", "[arcopolis]" )
{
    // The vertical vocabulary is exactly "down"/"up". The planar-style "move_down"/"move_up" tokens, a
    // planar cardinal, the examine self-tile token "here", a bare compass word, and "" are all rejected --
    // the parser half of the planar/vertical split.
    for( const std::string &dir : { "move_down", "move_up", "move_n", "here", "north", "" } ) {
        const auto json = R"({ "schema_version": 1, "command": "vertical_move", "direction": ")" + dir +
                          R"(" })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_command( is );
        REQUIRE_FALSE( result.has_value() );
        CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis is_supported_vertical_direction accepts only down and up", "[arcopolis]" )
{
    CHECK( arcopolis::is_supported_vertical_direction( "down" ) );
    CHECK( arcopolis::is_supported_vertical_direction( "up" ) );
    // The planar-style move_* tokens, a planar cardinal, and "" are NOT vertical directions.
    CHECK_FALSE( arcopolis::is_supported_vertical_direction( "move_down" ) );
    CHECK_FALSE( arcopolis::is_supported_vertical_direction( "move_up" ) );
    CHECK_FALSE( arcopolis::is_supported_vertical_direction( "move_n" ) );
    CHECK_FALSE( arcopolis::is_supported_vertical_direction( "" ) );
}
