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

TEST_CASE( "arcopolis parse_script rejects op:\"query\" as bad_schema (Spike 26A: query is a live-only op)",
           "[arcopolis]" )
{
    // Spike 26A added op:"query" to the LIVE protocol parser (arcopolis_live.cpp parse_live_request)
    // but NOT to the script step parser (arcopolis_script.cpp ~:178-182, which accepts op == "export"
    // and op == "command" only). A scripted "query" step must therefore be rejected at parse time as
    // bad_schema -- there is no scalar-response channel in script mode, so silently accepting it would
    // be a hidden no-op. This case pins the symmetric rejection that the doc 52 spike doc calls out.
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "query", "kind": "has_item", "item": "glass_shard" } ] })" );
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

TEST_CASE( "arcopolis parse_script accepts move steps with cardinal and diagonal directions",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "move", "direction": "move_e" },
        { "op": "command", "command": "move", "direction": "move_ne" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 2 );
    CHECK( ( *result )[0].command == "move" );
    CHECK( ( *result )[0].direction == "move_e" );
    CHECK( ( *result )[1].command == "move" );
    CHECK( ( *result )[1].direction == "move_ne" );  // a diagonal -- a real GUI step
}

TEST_CASE( "arcopolis parse_script rejects a move step without a direction", "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "move" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a move step with a vertical direction", "[arcopolis]" )
{
    // Vertical (move_up/move_down) is the separate game::vertical_move primitive, not a planar step.
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "move", "direction": "move_up" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script accepts vertical_move steps (down and up)", "[arcopolis]" )
{
    // Spike 24: the separate vertical verb is a normal command step (distinct down/up vocabulary), so it
    // parses in --arcopolis-run-script -- the matched-stair round-trip witness drives exactly this.
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "vertical_move", "direction": "down" },
        { "op": "command", "command": "vertical_move", "direction": "up" }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 2 );
    CHECK( ( *result )[0].command == "vertical_move" );
    CHECK( ( *result )[0].direction == "down" );
    CHECK( ( *result )[1].command == "vertical_move" );
    CHECK( ( *result )[1].direction == "up" );
}

TEST_CASE( "arcopolis parse_script rejects a vertical_move step without a direction",
           "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "vertical_move" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a vertical_move step with a non-vertical direction",
           "[arcopolis]" )
{
    // The vertical vocabulary is exactly down/up; planar-style tokens, the examine self-tile token, and ""
    // all reject at the script layer (its own coverage, though is_supported_vertical_direction is shared).
    for( const std::string &dir : { "move_down", "move_up", "move_n", "here", "" } ) {
        const auto json = R"({ "schema_version": 1, "steps": [
            { "op": "command", "command": "vertical_move", "direction": ")" + dir + R"(" }
        ] })";
        std::istringstream is( json );
        const auto result = arcopolis::parse_script( is );
        REQUIRE_FALSE( result.has_value() );
        CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
    }
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

TEST_CASE( "arcopolis exit_code_for maps script_prompt_failed to 13", "[arcopolis]" )
{
    CHECK( arcopolis::exit_code_for( arcopolis::command_error_kind::script_prompt_failed ) == 13 );
}

// --- Spike 16: prompt_answers parsing (the smallest additive script format -- Option A). Structural
// validation only; semantic matching against the real opened prompt happens at runtime. ---

TEST_CASE( "arcopolis parse_script accepts pickup with a direction and a menu answer",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "choice": 6 } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 1 );
    CHECK( ( *result )[0].command == "pickup" );
    CHECK( ( *result )[0].direction == "move_s" );
    REQUIRE( ( *result )[0].prompt_answers.size() == 1 );
    CHECK( ( *result )[0].prompt_answers[0].kind == "menu" );
    CHECK_FALSE( ( *result )[0].prompt_answers[0].cancel );
    CHECK( ( *result )[0].prompt_answers[0].choices == std::vector<int> { 6 } );  // `choice` canonicalized
}

TEST_CASE( "arcopolis parse_script rejects a pickup step without a direction", "[arcopolis]" )
{
    std::istringstream is(
        R"({ "schema_version": 1, "steps": [ { "op": "command", "command": "pickup" } ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script canonicalizes a menu choices array and a multi-prompt sequence",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [
            { "kind": "uilist", "choice": 1, "title_contains": "Get items from where" },
            { "kind": "menu", "choices": [5, 6] }
          ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    const auto &pa = ( *result )[0].prompt_answers;
    REQUIRE( pa.size() == 2 );
    CHECK( pa[0].kind == "uilist" );
    CHECK( pa[0].choices == std::vector<int> { 1 } );
    REQUIRE( pa[0].title_contains.has_value() );
    CHECK( *pa[0].title_contains == "Get items from where" );
    CHECK( pa[1].kind == "menu" );
    CHECK( pa[1].choices == std::vector<int> { 5, 6 } );  // multi-select preserved for a menu
}

TEST_CASE( "arcopolis parse_script accepts a query_popup answer and a cancel answer",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "examine", "direction": "move_e",
          "prompt_answers": [ { "kind": "query_popup", "choice": 0, "title_exact": "Take down the mattress?" } ] },
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "cancel": true } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE( result.has_value() );
    REQUIRE( result->size() == 2 );
    CHECK( ( *result )[0].prompt_answers[0].kind == "query_popup" );
    REQUIRE( ( *result )[0].prompt_answers[0].title_exact.has_value() );
    CHECK( *( *result )[0].prompt_answers[0].title_exact == "Take down the mattress?" );
    CHECK( ( *result )[1].prompt_answers[0].cancel );
    CHECK( ( *result )[1].prompt_answers[0].choices.empty() );  // cancel carries no choice
}

TEST_CASE( "arcopolis parse_script rejects a prompt answer with an unknown kind", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "popup", "choice": 0 } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a prompt answer with both choice and cancel",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "choice": 0, "cancel": true } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a prompt answer with neither choice nor cancel",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu" } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a multi-choice uilist answer", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "uilist", "choices": [0, 1] } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a menu answer with duplicate choices", "[arcopolis]" )
{
    // codex PR#44 review: a duplicate index would ack as N picks but the resolver silently sorts+uniques it
    // (driving one selection), normalizing a malformed answer into a success. Live mode rejects duplicates
    // (src/arcopolis_live.cpp); the script parser must too, before the resolver ever sees it.
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "choices": [0, 0] } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects a title assertion on a menu answer", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "pickup", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "choice": 0, "title_contains": "x" } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects both title_contains and title_exact", "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "examine", "direction": "move_e",
          "prompt_answers": [ { "kind": "query_popup", "choice": 0, "title_contains": "a", "title_exact": "b" } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}

TEST_CASE( "arcopolis parse_script rejects prompt_answers on a non-prompted command",
           "[arcopolis]" )
{
    std::istringstream is( R"({ "schema_version": 1, "steps": [
        { "op": "command", "command": "move", "direction": "move_s",
          "prompt_answers": [ { "kind": "menu", "choice": 0 } ] }
    ] })" );
    const auto result = arcopolis::parse_script( is );
    REQUIRE_FALSE( result.has_value() );
    CHECK( result.error().kind == arcopolis::command_error_kind::bad_schema );
}
