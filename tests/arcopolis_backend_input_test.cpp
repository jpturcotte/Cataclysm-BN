#include "catch/catch.hpp"

#include <optional>

#include "action.h"  // ACTION_PAUSE, ACTION_MOVE_*, ACTION_NULL
#include "arcopolis_backend_input.h"
#include "arcopolis_command.h"  // command_error_kind
#include "arcopolis_script.h"   // script_step

// Unit tests for the Arcopolis backend INPUT SOURCE (Spike 3.1A, mechanism M1). These cover the pure,
// world-independent parts: the command->action_id resolver (command_to_action) and the session/cursor
// state machine driven over COMMAND steps. The `export` branch of next_backend_action() writes a
// snapshot of a loaded world and is exercised by the headless binary run against ArcopolisTest, not here.
// Each test that begins a session ends it, so the translation-unit-local session does not leak between
// tests.

TEST_CASE( "arcopolis command_to_action resolves wait and the four cardinals", "[arcopolis]" )
{
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "wait" } ).value_or(
               ACTION_NULL ) == ACTION_PAUSE );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_n" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_FORTH );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_s" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_BACK );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_e" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_RIGHT );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_w" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_LEFT );
}

TEST_CASE( "arcopolis command_to_action rejects unsupported commands and bad directions",
           "[arcopolis]" )
{
    const auto unsupported = arcopolis::command_to_action( { .schema_version = 1, .command = "teleport" } );
    REQUIRE_FALSE( unsupported.has_value() );
    CHECK( unsupported.error().kind == arcopolis::command_error_kind::unsupported_command );

    // Diagonal/vertical/garbage directions resolve to an action_id via look_up_action, so the cardinal
    // gate inside command_to_action is what rejects them as bad_schema.
    for( const std::string &dir : { "move_ne", "move_up", "east", "" } ) {
        const auto bad = arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = dir } );
        REQUIRE_FALSE( bad.has_value() );
        CHECK( bad.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis backend input session drives command steps to done", "[arcopolis]" )
{
    arcopolis::begin_backend_session( {
        .steps = {
            { .op = "command", .command = "wait" },
            { .op = "command", .command = "move", .direction = "move_e" },
        },
    } );

    CHECK( arcopolis::backend_session_active() );
    CHECK( arcopolis::backend_cursor() == 0 );
    CHECK_FALSE( arcopolis::backend_input_done() );

    CHECK( arcopolis::next_backend_action() == ACTION_PAUSE );
    CHECK( arcopolis::backend_cursor() == 1 );
    CHECK_FALSE( arcopolis::backend_input_done() );

    CHECK( arcopolis::next_backend_action() == ACTION_MOVE_RIGHT );
    CHECK( arcopolis::backend_cursor() == 2 );
    CHECK_FALSE( arcopolis::backend_input_done() );

    // Cursor exhausted: the provider signals "done" and returns ACTION_NULL (which the do_turn clean-stop
    // turns into a park). No export step ran, so no failure was recorded.
    CHECK( arcopolis::next_backend_action() == ACTION_NULL );
    CHECK( arcopolis::backend_input_done() );
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_session_active() );
    CHECK_FALSE( arcopolis::backend_input_done() );
}

TEST_CASE( "arcopolis backend input session keeps moves > 0 open across commands", "[arcopolis]" )
{
    // The provider never ends a turn itself -- it just returns successive action_ids. Two move commands
    // resolve independently; whether they share a turn is the engine's call (the input loop), not the
    // provider's. Here we only assert the provider feeds them in order without stalling.
    arcopolis::begin_backend_session( {
        .steps = {
            { .op = "command", .command = "move", .direction = "move_n" },
            { .op = "command", .command = "move", .direction = "move_n" },
        },
    } );

    CHECK( arcopolis::next_backend_action() == ACTION_MOVE_FORTH );
    CHECK( arcopolis::next_backend_action() == ACTION_MOVE_FORTH );
    CHECK( arcopolis::next_backend_action() == ACTION_NULL );
    CHECK( arcopolis::backend_input_done() );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_session_active() );
}
