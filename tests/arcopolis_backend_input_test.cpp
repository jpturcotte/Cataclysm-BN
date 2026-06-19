#include "catch/catch.hpp"

#include <optional>
#include <string>
#include <vector>

#include "action.h"  // ACTION_PAUSE, ACTION_MOVE_*, ACTION_EXAMINE, ACTION_NULL
#include "arcopolis_backend_input.h"
#include "arcopolis_command.h"  // command_error_kind
#include "arcopolis_script.h"   // script_step
#include "debug.h"              // capture_debugmsg_during (cata_test uilist-abort witness)
#include "input.h"              // inp_mngr, input_manager::wait_for_any_key (raw-read guard)
#include "output.h"             // query_yn (Spike 15 cata_test query_popup-abort witness)
#include "popup.h"              // query_popup (Spike 15 backend-driven query_popup witnesses)
#include "ui.h"                 // uilist, UILIST_ERROR (Spike 13B backend-UI-mode witnesses)

// Unit tests for the Arcopolis backend INPUT SOURCE (Spike 3.1A, mechanism M1). These cover the pure,
// world-independent parts: the command->action_id resolver (command_to_action) and the session/cursor
// state machine driven over COMMAND steps. The `export` branch of next_backend_action() writes a
// snapshot of a loaded world and is exercised by the headless binary run against ArcopolisTest, not here.
// Each test that begins a session ends it, so the translation-unit-local session does not leak between
// tests.

TEST_CASE( "arcopolis command_to_action resolves wait and the eight planar moves", "[arcopolis]" )
{
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "wait" } ).value_or(
               ACTION_NULL ) == ACTION_PAUSE );
    // Cardinals.
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_n" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_FORTH );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_s" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_BACK );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_e" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_RIGHT );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_w" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_LEFT );
    // Diagonals -> the engine's diagonal move actions (look_up_action resolves them; the same
    // avatar_action::move body dispatches them, so they are as faithful as the cardinals).
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_ne" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_FORTH_RIGHT );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_nw" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_FORTH_LEFT );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_se" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_BACK_RIGHT );
    CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = "move_sw" } )
           .value_or( ACTION_NULL ) == ACTION_MOVE_BACK_LEFT );
}

TEST_CASE( "arcopolis command_to_action rejects unsupported commands and bad directions",
           "[arcopolis]" )
{
    const auto unsupported = arcopolis::command_to_action( { .schema_version = 1, .command = "teleport" } );
    REQUIRE_FALSE( unsupported.has_value() );
    CHECK( unsupported.error().kind == arcopolis::command_error_kind::unsupported_command );

    // Vertical (separate vertical_move primitive) and garbage resolve via look_up_action, so the planar
    // gate inside command_to_action is what rejects them as bad_schema. (Diagonals are now accepted.)
    for( const std::string &dir : { "move_up", "move_down", "east", "" } ) {
        const auto bad = arcopolis::command_to_action( { .schema_version = 1, .command = "move", .direction = dir } );
        REQUIRE_FALSE( bad.has_value() );
        CHECK( bad.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis backend gate is inert without an active session", "[arcopolis]" )
{
    // Normal gameplay path: no backend session has begun, so BOTH halves of the do_turn clean-stop guard
    // (backend_session_active() && backend_input_done(), game.cpp:2021) are false -- the clean-park branch
    // is dead code during normal play; only begin_backend_session() can arm it. Relies on the file-wide
    // invariant that every test which begins a session also ends it, so no session leaks in here.
    CHECK_FALSE( arcopolis::backend_session_active() );
    CHECK_FALSE( arcopolis::backend_input_done() );

    // A begin -> end cycle arms then fully disarms the gate, leaving it inert again with no leaked state:
    // the next normal turn cannot see an active session or a queued action.
    arcopolis::begin_backend_session( {
        .steps = { { .op = "command", .command = "wait" } },
    } );
    CHECK( arcopolis::backend_session_active() );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_session_active() );
    CHECK_FALSE( arcopolis::backend_input_done() );
    CHECK( arcopolis::backend_cursor() == 0 );
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
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

TEST_CASE( "arcopolis command_to_action resolves examine for every supported direction",
           "[arcopolis]" )
{
    // All eight planar directions plus "here" resolve to the engine's ACTION_EXAMINE (the direction is
    // carried as the nested-input answer, not encoded in the action_id).
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw", "here"
         } ) {
        CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "examine", .direction = dir } )
               .value_or( ACTION_NULL ) == ACTION_EXAMINE );
    }
    // Same defense-in-depth gate as "move": vertical/garbage directions are bad_schema. ("pause" is the
    // chooser action id, not a protocol token.)
    for( const std::string &dir : { "move_up", "move_down", "pause", "" } ) {
        const auto bad = arcopolis::command_to_action( { .schema_version = 1, .command = "examine", .direction = dir } );
        REQUIRE_FALSE( bad.has_value() );
        CHECK( bad.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis decide_nested_input classifies polls, serves, cancels and hard-fails",
           "[arcopolis]" )
{
    using arcopolis::decide_nested_input;
    using outcome_t = arcopolis::nested_input_outcome;
    using reason_t = arcopolis::nested_input_guard_reason;

    // A timeout-bounded read is a poll (it returns by itself headless): untouched even with a perfect
    // armed answer. The engine's activity-interrupt check polls DEFAULTMODE with timeout 0.
    CHECK( decide_nested_input( { .armed = true, .timeout = 0, .category = "DEFAULTMODE",
                                  .answer_registered = true, .quit_registered = true } ).outcome
           == outcome_t::pass_through );
    CHECK( decide_nested_input( { .armed = true, .timeout = 250, .category = "DEFAULTMODE",
                                  .answer_registered = true } ).outcome == outcome_t::pass_through );

    // The serve gate: armed AND the chooser category AND the action registered there.
    const auto serve = decide_nested_input( { .armed = true, .timeout = -1,
                                            .category = "DEFAULTMODE", .answer_registered = true } );
    CHECK( serve.outcome == outcome_t::serve );
    CHECK( serve.reason == reason_t::none );

    // Armed but a different context is asking (e.g. the pickup menu, which registers UP/DOWN for
    // scrolling): cancel, never serve -- the armed answer must not scroll a menu.
    const auto wrong_ctx = decide_nested_input( { .armed = true, .timeout = -1, .category = "PICKUP",
                           .answer_registered = true, .quit_registered = true } );
    CHECK( wrong_ctx.outcome == outcome_t::cancel_quit );
    CHECK( wrong_ctx.reason == reason_t::context_mismatch );

    // Armed, chooser category, but the action was not registered there.
    const auto unregistered = decide_nested_input( { .armed = true, .timeout = -1,
                              .category = "DEFAULTMODE", .quit_registered = true } );
    CHECK( unregistered.outcome == outcome_t::cancel_quit );
    CHECK( unregistered.reason == reason_t::answer_not_registered );

    // Nothing armed: cancel with QUIT, or TEXT.QUIT where only that exists (the text-input context),
    // and hard-fail when neither is registered.
    const auto esc = decide_nested_input( { .timeout = -1, .category = "PICKUP", .quit_registered = true } );
    CHECK( esc.outcome == outcome_t::cancel_quit );
    CHECK( esc.reason == reason_t::no_answer );
    const auto text_esc = decide_nested_input( { .timeout = -1, .category = "STRING_INPUT",
                          .text_quit_registered = true } );
    CHECK( text_esc.outcome == outcome_t::cancel_text_quit );
    CHECK( text_esc.reason == reason_t::no_answer );
    CHECK( decide_nested_input( { .timeout = -1, .category = "NO_CANCEL" } ).outcome
           == outcome_t::hard_fail );

    // The anti-livelock fire limit converts an ignored cancel into a hard fail.
    CHECK( decide_nested_input( { .timeout = -1, .category = "PICKUP", .quit_registered = true,
                                  .fires = arcopolis::nested_input_guard_fire_limit - 1 } ).outcome
           == outcome_t::cancel_quit );
    CHECK( decide_nested_input( { .timeout = -1, .category = "PICKUP", .quit_registered = true,
                                  .fires = arcopolis::nested_input_guard_fire_limit } ).outcome
           == outcome_t::hard_fail );
}

TEST_CASE( "arcopolis nested-input slot is inert without a session and one-shot within one",
           "[arcopolis]" )
{
    // Action sets mirroring the real contexts (the hook receives category + registered actions from
    // input_context::handle_input -- the accessors are Android-only, so the engine passes them in).
    const std::vector<std::string> chooser_actions = {
        "UP", "DOWN", "LEFT", "RIGHT", "LEFTUP", "LEFTDOWN", "RIGHTUP", "RIGHTDOWN",
        "pause", "QUIT", "HELP_KEYBINDINGS",
    };
    const std::vector<std::string> pickup_actions = { "UP", "DOWN", "QUIT" };
    const std::vector<std::string> no_cancel_actions = {};

    // Without a session: arming is inert and the hook never intervenes, even on a context with no
    // cancel action -- normal play must be untouched (the same inertness bar as the do_turn gate).
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );
    arcopolis::backend_arm_nested_input( { .action = "UP", .direction = "move_n" } );
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );
    CHECK( arcopolis::backend_nested_input_action( "NO_CANCEL", no_cancel_actions, -1 ) == nullptr );

    arcopolis::begin_backend_session( { .steps = {} } );

    arcopolis::backend_arm_nested_input( { .action = "UP", .direction = "move_n", .step_index = 2 } );
    CHECK( arcopolis::backend_nested_input_armed() );

    // Poll reads pass through without consuming the answer.
    CHECK( arcopolis::backend_nested_input_action( "DEFAULTMODE", chooser_actions, 0 ) == nullptr );
    CHECK( arcopolis::backend_nested_input_armed() );

    // The blocking chooser read is served the armed answer -- exactly once.
    const std::string *served =
        arcopolis::backend_nested_input_action( "DEFAULTMODE", chooser_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served == "UP" );
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );

    // The next blocking read gets the guard's cancel, never a stale answer.
    const std::string *cancelled =
        arcopolis::backend_nested_input_action( "DEFAULTMODE", chooser_actions, -1 );
    REQUIRE( cancelled != nullptr );
    CHECK( *cancelled == "QUIT" );

    // A pickup-shaped context (registers the direction actions for scrolling, and QUIT) with an armed
    // answer gets the cancel too: the category gate stops the answer scrolling a menu.
    arcopolis::backend_arm_nested_input( { .action = "UP", .direction = "move_n", .step_index = 3 } );
    const std::string *guarded =
        arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
    REQUIRE( guarded != nullptr );
    CHECK( *guarded == "QUIT" );
    CHECK( arcopolis::backend_nested_input_armed() );  // the slot waits for the chooser or the seam clear

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );
}

TEST_CASE( "arcopolis provider arms examine steps and clears stale answers at the seam",
           "[arcopolis]" )
{
    arcopolis::begin_backend_session( {
        .steps = {
            { .op = "command", .command = "examine", .direction = "move_n" },
            { .op = "command", .command = "wait" },
        },
    } );

    // The examine step resolves to ACTION_EXAMINE and arms the one-shot answer.
    CHECK( arcopolis::next_backend_action() == ACTION_EXAMINE );
    CHECK( arcopolis::backend_nested_input_armed() );

    // Control returning to the seam (the next provider pull) force-clears the unconsumed answer
    // before the next command dispatches: nothing can leak into the wait.
    CHECK( arcopolis::next_backend_action() == ACTION_PAUSE );
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );
}

TEST_CASE( "arcopolis provider arms a DIAGONAL examine and serves its action string",
           "[arcopolis]" )
{
    // End-to-end at the provider level: a diagonal examine step must flow command -> armed slot ->
    // the exact diagonal chooser action string the GUI uses, not just a cardinal subset. move_ne maps
    // to "RIGHTUP" (north_east), verified against src/input.cpp get_direction.
    const std::vector<std::string> chooser_actions = {
        "UP", "DOWN", "LEFT", "RIGHT", "LEFTUP", "LEFTDOWN", "RIGHTUP", "RIGHTDOWN",
        "pause", "QUIT", "HELP_KEYBINDINGS",
    };
    arcopolis::begin_backend_session( {
        .steps = { { .op = "command", .command = "examine", .direction = "move_ne" } },
    } );

    CHECK( arcopolis::next_backend_action() == ACTION_EXAMINE );
    REQUIRE( arcopolis::backend_nested_input_armed() );

    const std::string *served =
        arcopolis::backend_nested_input_action( "DEFAULTMODE", chooser_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served == "RIGHTUP" );
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_nested_input_armed() );
}

TEST_CASE( "arcopolis command_to_action resolves pickup for every supported direction",
           "[arcopolis]" )
{
    // pickup shares examine's planar target chooser (the "Pickup where?" choose_adjacent_highlight, also
    // allow_vertical=false), so the same eight planar directions + "here" resolve to ACTION_PICKUP.
    for( const std::string &dir : {
             "move_n", "move_s", "move_e", "move_w",
             "move_ne", "move_nw", "move_se", "move_sw", "here"
         } ) {
        CHECK( arcopolis::command_to_action( { .schema_version = 1, .command = "pickup", .direction = dir } )
               .value_or( ACTION_NULL ) == ACTION_PICKUP );
    }
    for( const std::string &dir : { "move_up", "move_down", "pause", "" } ) {
        const auto bad = arcopolis::command_to_action( { .schema_version = 1, .command = "pickup", .direction = dir } );
        REQUIRE_FALSE( bad.has_value() );
        CHECK( bad.error().kind == arcopolis::command_error_kind::bad_schema );
    }
}

TEST_CASE( "arcopolis pickup transaction translates a multi-select into registered PICKUP actions",
           "[arcopolis]" )
{
    // The level-4 proof at unit level: a client selection (here TWO entries) becomes the SAME registered
    // keystrokes a GUI player would press -- DOWN to walk to each chosen entry, RIGHT to mark it, CONFIRM to
    // finalize -- served one per blocking handle_input read to the engine's own "PICKUP" loop. The backend
    // never mutates getitem.
    const std::vector<std::string> pickup_actions = {
        "UP", "DOWN", "LEFT", "RIGHT", "CONFIRM", "SELECT_ALL", "QUIT",
    };

    // A stub live client standing in for arcopolis_live's prompt_source: it picks entries 0 and 2.
    arcopolis::begin_backend_session( {
        .steps = {},
        .prompt_source = []( const std::vector<arcopolis::pickup_prompt_choice> & ) -> std::optional<std::vector<int>> {
            return std::vector<int> { 0, 2 };
        },
    } );

    // Isolation: a fresh session has no transaction, and arming the examine one-shot slot does NOT arm the
    // pickup transaction (so examine's auto-pickup tail keeps auto-cancelling).
    CHECK_FALSE( arcopolis::backend_pickup_transaction_active() );
    arcopolis::backend_arm_nested_input( { .action = "UP", .direction = "move_n" } );
    CHECK_FALSE( arcopolis::backend_pickup_transaction_active() );

    arcopolis::backend_arm_pickup_transaction( 7 );
    CHECK( arcopolis::backend_pickup_transaction_active() );

    const std::vector<arcopolis::pickup_prompt_choice> choices = {
        { .index = 0, .text = "a rock", .enabled = true },
        { .index = 1, .text = "a rag", .enabled = true },
        { .index = 2, .text = "a string", .enabled = true },
    };
    arcopolis::backend_resolve_pickup_choice( choices );

    // The unmodified loop consumes the queue one action per blocking read, IN ORDER: RIGHT (mark entry 0),
    // DOWN DOWN (walk to entry 2), RIGHT (mark it), CONFIRM (finalize / loop-exit).
    for( const std::string &expected : { "RIGHT", "DOWN", "DOWN", "RIGHT", "CONFIRM" } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    // A timeout-bounded poll on the menu context always passes through (mirrors the one-shot path).
    CHECK( arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, 0 ) == nullptr );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_pickup_transaction_active() );
}

TEST_CASE( "arcopolis pickup transaction with no answer channel cancels via QUIT", "[arcopolis]" )
{
    // Script/one-shot modes register no prompt_source, so backend_resolve_pickup_choice arms the cancel
    // queue ["QUIT"] -- the engine loop QUIT-exits ("Never mind."), the GUI ESC equivalent.
    const std::vector<std::string> pickup_actions = { "UP", "DOWN", "RIGHT", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {} } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    const std::vector<arcopolis::pickup_prompt_choice> choices = {
        { .index = 0, .text = "a rock", .enabled = true },
    };
    arcopolis::backend_resolve_pickup_choice( choices );

    const std::string *served = arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served == "QUIT" );

    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_pickup_transaction_active() );
}

TEST_CASE( "arcopolis pickup reports the vehicle submenu as a fail-loud outcome", "[arcopolis]" )
{
    // The vehicle "Get items from where?" submenu is a uilist that auto-errors in the backend's test_mode
    // (never reaching the input guard), so src/pickup.cpp reports it directly. The report records
    // unsupported_submenu, which the live writer reads (read-and-reset) to FAIL LOUD with unsupported_command.
    using outcome_t = arcopolis::pickup_command_outcome;
    arcopolis::begin_backend_session( { .steps = {} } );
    arcopolis::backend_arm_pickup_transaction( 3 );
    arcopolis::backend_report_pickup_unsupported_submenu();
    // The outcome survives the seam's stale-clear; the live writer takes it (read-and-reset).
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::unsupported_submenu );
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis pickup reports a secondary prompt as a partial outcome", "[arcopolis]" )
{
    // The in-activity capacity/wield/spill uilist (handle_problematic_pickup) also auto-errors in test_mode;
    // src/pickup.cpp reports it as secondary_forced_cancel so the live response is marked partial, NOT full
    // success (the item that does not fit is left behind -- the engine's own outcome).
    using outcome_t = arcopolis::pickup_command_outcome;
    arcopolis::begin_backend_session( { .steps = {} } );
    arcopolis::backend_arm_pickup_transaction( 5 );
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::secondary_forced_cancel );
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis pickup outcome reports are inert without an armed transaction",
           "[arcopolis]" )
{
    // examine's auto-pickup tail (and any non-pickup command) never arms the transaction, so the engine's
    // own pickup paths that call these reporters leave the outcome `ok` -- the report functions are gated,
    // and the markers never appear for a non-pickup command. Inert outside a session too.
    using outcome_t = arcopolis::pickup_command_outcome;
    arcopolis::backend_report_pickup_unsupported_submenu();  // no session at all
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );

    arcopolis::begin_backend_session( { .steps = {} } );  // session, but no pickup transaction armed
    arcopolis::backend_report_pickup_unsupported_submenu();
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis Spike 14 orphaned secondary report marks but sets no outcome", "[arcopolis]" )
{
    // PR #42 review fix: handle_problematic_pickup reached during a backend session with NO armed pickup
    // transaction (a multi-tick pickup activity resumed after the transaction was cleared) reports an
    // ORPHANED secondary so the engine's test_mode CANCEL is MARKED in the transcript, never silent. The
    // reporter is gated to exactly that case and must NEVER set pickup_outcome (there is no owed response
    // to mark, and a leaked partial marker could mis-mark an unrelated later command).
    using outcome_t = arcopolis::pickup_command_outcome;
    arcopolis::backend_report_pickup_orphaned_secondary();  // no session -> inert (no crash)
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );

    arcopolis::begin_backend_session( { .steps = {} } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    // A transaction IS armed -> NOT the orphaned case -> inert (the drive / no-channel paths own it).
    arcopolis::backend_report_pickup_orphaned_secondary();
    CHECK( arcopolis::backend_take_pickup_outcome() ==
           outcome_t::ok );  // backend_arm reset it; still ok
    arcopolis::end_backend_session();

    // Session active, NO transaction -> the orphaned case. It logs a transcript event (no transcript open
    // here, so nothing to observe) and crucially sets NO outcome -- it must not leak a partial marker.
    arcopolis::begin_backend_session( { .steps = {} } );
    REQUIRE( arcopolis::backend_session_active() );
    REQUIRE_FALSE( arcopolis::backend_pickup_transaction_active() );
    arcopolis::backend_report_pickup_orphaned_secondary();
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::ok );  // no partial marker leaked
    arcopolis::end_backend_session();
}

// --- Spike 13B: backend-driven uilist transaction (the "Get items from where?" vehicle-source submenu). ---

TEST_CASE( "arcopolis backend_uilist_transaction_active gates on an armed uilist transaction only",
           "[arcopolis]" )
{
    // The uilist test_mode-abort bypass (src/ui.cpp) keys on this gate and NOTHING weaker. It must be false
    // outside a session, false inside a session with no uilist transaction (even with a pickup transaction
    // armed), true only between begin/end of a uilist transaction.
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );           // no session
    arcopolis::begin_backend_session( { .steps = {} } );
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );           // session, nothing armed
    arcopolis::backend_begin_uilist_transaction();                // inert without a pickup transaction
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );
    arcopolis::backend_arm_pickup_transaction( 1 );
    CHECK_FALSE(
        arcopolis::backend_uilist_transaction_active() );           // pickup transaction is not enough
    arcopolis::backend_begin_uilist_transaction();
    CHECK( arcopolis::backend_uilist_transaction_active() );                 // armed
    arcopolis::backend_end_uilist_transaction();
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );           // cleared
    arcopolis::backend_end_uilist_transaction();                  // idempotent
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );
    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_uilist_transaction_active() );
}

TEST_CASE( "arcopolis backend-driven uilist serves DOWN+CONFIRM for the ground choice",
           "[arcopolis]" )
{
    // The witnessed level-4 path: the client picks entry 1 (ground), and the backend translates it into the
    // registered UILIST actions [DOWN, CONFIRM] the real uilist loop consumes -- one per blocking read, only
    // for the "UILIST" category.
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "PAGE_UP", "PAGE_DOWN", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = []( const arcopolis::backend_uilist_prompt_request & req )
    -> std::optional<int> {
        CHECK( req.kind == "uilist" );
        CHECK( req.choices.size() == 2 );
        return 1;  // choose "ground" (entry 1)
    } } );
    CHECK( arcopolis::backend_uilist_prompt_available() );
    arcopolis::backend_arm_pickup_transaction( 4 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist", .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    } } );
    for( const std::string &expected : { "DOWN", "CONFIRM" } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    // A timeout-bounded poll passes through (a blocking read only is served), mirroring the PICKUP queue.
    CHECK( arcopolis::backend_nested_input_action( "UILIST", uilist_actions, 0 ) == nullptr );
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis backend-driven uilist builds the right action queue per answer",
           "[arcopolis]" )
{
    // The single-select queue: choose entry K -> DOWN x K then CONFIRM; cancel / EOF / out-of-range -> QUIT.
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    auto served_for = [&]( const std::optional<int> &answer ) -> std::vector<std::string> {
        arcopolis::begin_backend_session( {
            .steps = {},
            .uilist_prompt_source = [answer]( const arcopolis::backend_uilist_prompt_request & )
            -> std::optional<int> { return answer; } } );
        arcopolis::backend_arm_pickup_transaction( 0 );
        arcopolis::backend_begin_uilist_transaction();
        arcopolis::backend_resolve_uilist_choice( {
            .kind = "uilist", .title = "t",
            .choices = { { .index = 0, .text = "cargo", .enabled = true },
                { .index = 1, .text = "ground", .enabled = true }
            } } );
        std::vector<std::string> served;
        for( ;; )
        {
            const std::string *a = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
            REQUIRE( a != nullptr );
            served.push_back( *a );
            if( *a == "CONFIRM" || *a == "QUIT" ) {
                break;  // the queue's terminal element is always the loop-exit action
            }
        }
        arcopolis::backend_end_uilist_transaction();
        arcopolis::end_backend_session();
        return served;
    };
    CHECK( served_for( 0 ) == std::vector<std::string> { "CONFIRM" } );          // cargo (entry 0)
    CHECK( served_for( 1 ) == std::vector<std::string> { "DOWN", "CONFIRM" } );  // ground (entry 1)
    CHECK( served_for( std::nullopt ) == std::vector<std::string> { "QUIT" } );  // cancel / EOF
    CHECK( served_for( 5 ) == std::vector<std::string> { "QUIT" } );             // out of range -> cancel
}

TEST_CASE( "arcopolis backend-driven uilist refuses a disabled-entry shape", "[arcopolis]" )
{
    // PR #42 review (Codex P2): the single-select DOWN x choice -> CONFIRM translation is UNSAFE when any
    // entry is disabled -- uilist::filterlist() lands the initial highlight on the first ENABLED entry and
    // uilist::scrollby() skips disabled entries (src/ui.cpp), so a raw position index mis-navigates to a
    // DIFFERENT enabled action (wield/wear the wrong item). The driver must REFUSE such a request WITHOUT
    // asking the client and serve QUIT (the engine's UILIST_CANCEL), never a navigation queue. (The pickup
    // call site also refuses + marks partial before reaching here; this is the general driver-level guard.)
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    bool client_asked = false;
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = [&client_asked]( const arcopolis::backend_uilist_prompt_request & )
    -> std::optional<int> {
        client_asked = true;
        return 1;
    } } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist",
            .title = "Not enough capacity to stash leather jacket",
    .choices = { { .index = 0, .text = "Wear leather jacket", .enabled = false },  // a DISABLED entry
        { .index = 1, .text = "Wield leather jacket", .enabled = true }
    } } );
    CHECK_FALSE( client_asked );  // refused before ever asking the client
    // The first served action is QUIT -- never a DOWN that could land on the wrong enabled entry. (Once the
    // queue drains, the nested-input guard keeps returning the registered QUIT as a safety net, so the real
    // uilist loop always cancels; we assert only that the queued action is the cancel, not a navigation step.)
    const std::string *first = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
    REQUIRE( first != nullptr );
    CHECK( *first == "QUIT" );
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis vehicle submenu fails loud with no uilist answer channel", "[arcopolis]" )
{
    // No uilist_prompt_source (script/one-shot / misconfigured live): the engine call site (src/pickup.cpp)
    // finds backend_uilist_prompt_available() false and reports unsupported_submenu instead of driving a
    // uilist with no channel -- preserving the doc-31 fail-loud. With a channel set it is available.
    using outcome_t = arcopolis::pickup_command_outcome;
    arcopolis::begin_backend_session( { .steps = {} } );  // no uilist_prompt_source
    arcopolis::backend_arm_pickup_transaction( 0 );
    CHECK_FALSE( arcopolis::backend_uilist_prompt_available() );
    arcopolis::backend_report_pickup_unsupported_submenu();  // exactly what src/pickup.cpp does in that branch
    CHECK( arcopolis::backend_take_pickup_outcome() == outcome_t::unsupported_submenu );
    arcopolis::end_backend_session();

    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = []( const arcopolis::backend_uilist_prompt_request & )
                                                -> std::optional<int> { return 0; } } );
    CHECK( arcopolis::backend_uilist_prompt_available() );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis cata_test uilist still aborts to UILIST_ERROR without a backend session",
           "[arcopolis]" )
{
    // The invariant the Spike 13B un-abort must NOT break: ordinary test_mode (cata_test, no backend
    // session) still short-circuits every uilist to UILIST_ERROR. backend_uilist_transaction_active() is false here, so
    // both init() and query() take the abort (each emits its debugmsg, captured so the test does not abort).
    REQUIRE_FALSE( arcopolis::backend_uilist_transaction_active() );
    const std::string msgs = capture_debugmsg_during( []() {
        uilist menu( "Get items from where?", { "Get items from vehicle cargo", "Get items on the ground" } );
        CHECK( menu.ret == UILIST_ERROR );
    } );
    CHECK_FALSE( msgs.empty() );
}

TEST_CASE( "arcopolis backend uilist setup populates state but creates NO curses window",
           "[arcopolis]" )
{
    // INVARIANT (build-independent): the Arcopolis backend headless path must create no curses window and
    // call no render primitive in ANY build. The driven uilist loop reads only entries/retvals/fentries, so
    // setup() under backend_uilist_transaction_active() runs its data-population pass but SKIPS catacurses::newwin --
    // which in a curses build is the real ncurses ::newwin (src/ncurses_def.cpp), fatal before initscr (which
    // --arcopolis-live skips under test_mode). This pins that here in the tiles cata_test: the tiles
    // pseudo-curses newwin would return a NON-null window, so `!menu.window` FAILS the instant a regression
    // re-adds an unconditional newwin -- catching the curses-build crash in the build we CAN run. (Codex
    // review, PR #40.)
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = []( const arcopolis::backend_uilist_prompt_request & )
                                                -> std::optional<int> { return 1; } } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    REQUIRE( arcopolis::backend_uilist_transaction_active() );

    uilist menu;  // default ctor's init() does NOT abort here (backend_uilist_transaction_active() is true)
    menu.text = "Get items from where?";
    menu.addentry( "Get items from vehicle cargo" );  // entry 0
    menu.addentry( "Get items on the ground" );        // entry 1
    menu.setup();  // the engine's own non-render layout/data pass

    CHECK( !menu.window );                  // the load-bearing invariant: NO window was created
    CHECK( menu.entries[0].retval ==
           0 );   // setup()'s data pass ran: retvals auto-assigned to the index
    CHECK( menu.entries[1].retval ==
           1 );   // (so the real loop's CONFIRM resolves ground -> from_ground=1)

    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

// --- Spike 14: backend-driven uilist transaction at a SECOND site -- the secondary capacity/wield/spill
// uilist (handle_problematic_pickup, src/pickup.cpp), reusing the Spike 13B machinery unchanged. The seam
// (gate / serve branch / channel) is byte-identical to the vehicle-source path; these tests pin that the
// same machinery serves a different uilist shape (WEAR/WIELD choices) without regression.

TEST_CASE( "arcopolis Spike 14 secondary capacity uilist serves WEAR/WIELD via the same UILIST seam",
           "[arcopolis]" )
{
    // The handle_problematic_pickup uilist (Spike 14 witness) has at most 4 entries (WEAR/WIELD/EMPTY/SPILL).
    // The witness scenario has 2: WEAR+WIELD for an over-capacity armor item. Choose entry 1 (WIELD) -> queue
    // [DOWN, CONFIRM] consumed through the real "UILIST" loop, same as the vehicle-source ground choice.
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = []( const arcopolis::backend_uilist_prompt_request & req )
    -> std::optional<int> {
        CHECK( req.kind == "uilist" );
        CHECK( req.title == "Not enough capacity to stash leather jacket" );
        REQUIRE( req.choices.size() == 2 );
        CHECK( req.choices[0].text == "Wear leather jacket" );
        CHECK( req.choices[0].enabled );        // Spike 14 acceptance: all-enabled-entries only
        CHECK( req.choices[1].text == "Wield leather jacket" );
        CHECK( req.choices[1].enabled );
        return 1;  // choose WIELD (entry 1)
    } } );
    CHECK( arcopolis::backend_uilist_prompt_available() );
    arcopolis::backend_arm_pickup_transaction( 7 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist",
            .title = "Not enough capacity to stash leather jacket",
    .choices = { { .index = 0, .text = "Wear leather jacket", .enabled = true },
        { .index = 1, .text = "Wield leather jacket", .enabled = true }
    } } );
    for( const std::string &expected : { "DOWN", "CONFIRM" } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis Spike 14 secondary capacity setup leaves NO curses window", "[arcopolis]" )
{
    // The no-window invariant binds EVERY un-abort site, not just the vehicle submenu. Pin it for the
    // secondary capacity uilist's shape too: setup() under backend_uilist_transaction_active() populates the entry
    // retvals/fentries without ever calling catacurses::newwin -- so the curses build (where ::newwin is
    // the real ncurses one, fatal before initscr) never crashes here. The tiles cata_test we CAN run
    // witnesses this because the tiles pseudo-curses newwin returns a non-null window, so a regression
    // re-adding an unconditional newwin would make !menu.window FAIL.
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = []( const arcopolis::backend_uilist_prompt_request & )
                                                -> std::optional<int> { return 1; } } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    REQUIRE( arcopolis::backend_uilist_transaction_active() );

    uilist menu;
    menu.text = "Not enough capacity to stash leather jacket";
    menu.addentry( "Wear leather jacket" );    // entry 0
    menu.addentry( "Wield leather jacket" );    // entry 1
    menu.setup();

    CHECK( !menu.window );                  // the load-bearing invariant for ANY un-aborted uilist
    CHECK( menu.entries[0].retval == 0 );
    CHECK( menu.entries[1].retval == 1 );

    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis wait_for_any_key does not block during a backend session", "[arcopolis]" )
{
    // The raw "press any key" prompt (input_manager::wait_for_any_key, reached e.g. by examining a
    // CONSOLE tile -> computer_session::query_any) reads inp_mngr.get_input_event() DIRECTLY, bypassing
    // the input_context::handle_input seam where the backend's nested-input guard lives -- so headless
    // it would busy-wait forever. The guard at the top of wait_for_any_key must make it return
    // immediately while a backend session is active. This test would HANG (never reach the assert) if
    // that guard regressed; it must only be called WITH a session active (without one it blocks on real
    // input, so it is never exercised in the no-session case here).
    arcopolis::begin_backend_session( { .steps = {} } );
    CHECK( arcopolis::backend_session_active() );
    inp_mngr.wait_for_any_key();  // returns at the guard; reaching the next line is the proof
    CHECK( arcopolis::backend_session_active() );
    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_session_active() );
}

// --- Spike 15: backend-driven query_popup transaction (the deployed-furniture "Take down the %s?"
// query_yn). The un-abort is WITNESS-SCOPED -- armed only by the guard at that one call site, never by the
// command precondition or the session alone -- so no other query_yn is ever driven. The serve branch
// translates a YES/NO choice into the registered LEFT/RIGHT/CONFIRM a player would press on the horizontal
// button row, consumed by the real input_context("YESNO") loop in query_popup::query_once. ---

TEST_CASE( "arcopolis backend_query_popup_transaction_active gates on an armed witness transaction only",
           "[arcopolis]" )
{
    // The query_popup test_mode-abort bypass (src/popup.cpp) and the query_yn drive-block (src/output.cpp)
    // key on this gate and NOTHING weaker. This case pins the GATE STATE: the per-COMMAND examine precondition
    // alone does NOT flip it -- only the per-PROMPT witness guard (begin/end) does. The downstream consequence
    // -- a non-witnessed query_yn during an examine (e.g. iexamine.cpp's "Slip through the %s?") is never
    // un-aborted -- follows STRUCTURALLY from there being no witness guard at those call sites; this test does
    // not itself construct a second query_yn. (Amendment 1: witness-scoping.) A channel IS present throughout
    // so this isolates the command/transaction dimension; the separate no-channel test below covers that
    // backend_begin refuses to arm without a channel.
    CHECK_FALSE( arcopolis::backend_query_popup_transaction_active() );            // no session
    arcopolis::begin_backend_session( { .steps = {},
                                        .query_popup_source = []( const arcopolis::backend_query_popup_request & )
                                                -> std::optional<int> { return 0; } } );
    CHECK_FALSE(
        arcopolis::backend_query_popup_transaction_active() );            // session + channel, nothing armed
    arcopolis::backend_begin_query_popup_transaction( "w" );               // inert without the examine command
    CHECK_FALSE( arcopolis::backend_query_popup_transaction_active() );
    arcopolis::backend_arm_examine_query_popup_command( 1 );
    CHECK( arcopolis::backend_examine_query_popup_command_active() );
    CHECK_FALSE(
        arcopolis::backend_query_popup_transaction_active() );            // the command precondition is NOT enough
    arcopolis::backend_begin_query_popup_transaction( "w" );
    CHECK( arcopolis::backend_query_popup_transaction_active() );                  // command + channel + begin -> armed
    arcopolis::backend_end_query_popup_transaction();
    CHECK_FALSE( arcopolis::backend_query_popup_transaction_active() );            // cleared
    arcopolis::backend_end_query_popup_transaction();                      // idempotent
    CHECK_FALSE( arcopolis::backend_query_popup_transaction_active() );
    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_query_popup_transaction_active() );
}

TEST_CASE( "arcopolis query_popup answer channel availability GATES arming", "[arcopolis]" )
{
    // backend_begin_query_popup_transaction must refuse to arm without a live answer channel: a
    // misconfigured session (examine command armed, but NO query_popup_source) leaves query_yn taking its
    // normal test_mode abort (returns NO) rather than driving a loop with nothing to ask -- the AGENTS.md
    // "don't drive a prompt you can't answer" rule, mirroring the uilist call site's prompt-available check.
    // This asserts the channel is actually USED to gate arming, not merely that the predicate returns a bool.
    arcopolis::begin_backend_session( { .steps = {} } );  // no query_popup_source
    CHECK_FALSE( arcopolis::backend_query_popup_prompt_available() );
    arcopolis::backend_arm_examine_query_popup_command( 0 );
    arcopolis::backend_begin_query_popup_transaction( "examine_deployed_furniture_take_down" );
    CHECK_FALSE(
        arcopolis::backend_query_popup_transaction_active() );  // NO channel -> NOT armed (the gating itself)
    arcopolis::backend_end_query_popup_transaction();
    arcopolis::end_backend_session();

    // With a channel registered, the same command + begin sequence DOES arm the transaction.
    arcopolis::begin_backend_session( { .steps = {},
                                        .query_popup_source = []( const arcopolis::backend_query_popup_request & )
                                                -> std::optional<int> { return 0; } } );
    CHECK( arcopolis::backend_query_popup_prompt_available() );
    arcopolis::backend_arm_examine_query_popup_command( 0 );
    arcopolis::backend_begin_query_popup_transaction( "examine_deployed_furniture_take_down" );
    CHECK( arcopolis::backend_query_popup_transaction_active() );  // channel present -> armed
    arcopolis::backend_end_query_popup_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis backend-driven query_popup builds the right YESNO action queue per answer",
           "[arcopolis]" )
{
    // The single-select horizontal-button-row queue, from query_yn's starting cursor 1 (NO): choosing entry
    // 0 (YES) -> [LEFT, CONFIRM]; entry 1 (NO) -> [CONFIRM]; EOF / closed client (nullopt) -> [CONFIRM] (the
    // engine's visible default, NO -- same engine action as an intentional NO, but the transcript records it
    // as a CLOSED prompt, not an answer; the regression checks that distinction). Served one per BLOCKING
    // read, only for the "YESNO" category.
    const std::vector<std::string> yesno_actions = { "LEFT", "RIGHT", "CONFIRM", "YES", "NO", "HELP_KEYBINDINGS" };
    auto served_for = [&]( const std::optional<int> &answer ) -> std::vector<std::string> {
        arcopolis::begin_backend_session( {
            .steps = {},
            .query_popup_source = [answer]( const arcopolis::backend_query_popup_request & )
            -> std::optional<int> { return answer; } } );
        arcopolis::backend_arm_examine_query_popup_command( 0 );
        arcopolis::backend_begin_query_popup_transaction( "examine_deployed_furniture_take_down" );
        arcopolis::backend_resolve_query_popup_choice( {
            .title = "Take down the mattress?",
            .choices = { { .index = 0, .text = "YES", .enabled = true },
                { .index = 1, .text = "NO", .enabled = true }
            },
            .cursor_start = 1, .cancelable = false } );
        std::vector<std::string> served;
        for( ;; )
        {
            const std::string *a = arcopolis::backend_nested_input_action( "YESNO", yesno_actions, -1 );
            REQUIRE( a != nullptr );
            served.push_back( *a );
            if( *a == "CONFIRM" ) {
                break;  // CONFIRM is always the queue's terminal element
            }
        }
        // A timeout-bounded poll passes through (only a blocking read is served), like the UILIST/PICKUP queues.
        CHECK( arcopolis::backend_nested_input_action( "YESNO", yesno_actions, 0 ) == nullptr );
        arcopolis::backend_end_query_popup_transaction();
        arcopolis::end_backend_session();
        return served;
    };
    CHECK( served_for( 0 ) == std::vector<std::string> { "LEFT", "CONFIRM" } );    // YES (entry 0)
    CHECK( served_for( 1 ) == std::vector<std::string> { "CONFIRM" } );            // NO (entry 1, already the cursor)
    CHECK( served_for( std::nullopt ) == std::vector<std::string> { "CONFIRM" } ); // closed -> CONFIRM the default
}

TEST_CASE( "arcopolis backend-driven query_popup runs query() headless with NO window",
           "[arcopolis]" )
{
    // The level-4 path in a unit context, end to end: a real query_yn-shaped query_popup runs its UNMODIFIED
    // query()/query_once loop under an armed witness transaction. The served LEFT/CONFIRM (YES) or CONFIRM
    // (NO) reach input_context("YESNO")::handle_input through the seam (the hook short-circuits at the top of
    // handle_input, so no real input source is touched), query_once sets res.action, and NO curses window is
    // created -- the init()->newwin / show() redraw + resize callbacks are test_mode no-ops in
    // ui_manager::redraw_invalidated(), so the un-abort path is renderer-neutral (the Spike 13B invariant,
    // pinned here for query_popup). The backend never sets the result; the engine's own loop does.
    // SCOPE: this case hand-builds the query_popup and calls backend_resolve_query_popup_choice directly (NOT
    // via query_yn), so it asserts the query_yn-SHAPED request -- the popup's REAL cursor_start
    // (current_index()) plus YES/NO literals -- and the renderer-neutral loop. output.cpp's drive-block
    // wiring (the real query_yn building the request from its OWN options) is exercised by the regression's
    // Gate Y2, not by this unit.
    inp_mngr.init();  // make the input system ready (matches tests/input_test.cpp); the hook still short-circuits
    auto drive = [&]( int choice ) -> std::string {
        arcopolis::begin_backend_session( {
            .steps = {},
            .query_popup_source = [choice]( const arcopolis::backend_query_popup_request & req )
            -> std::optional<int> {
                CHECK( req.kind == "query_popup" );
                REQUIRE( req.choices.size() == 2 );
                CHECK( req.choices[0].text == "YES" );
                CHECK( req.choices[1].text == "NO" );
                CHECK( req.cursor_start == 1 );      // query_yn starts the cursor on NO (real popup.current_index())
                CHECK_FALSE( req.cancelable );       // test-supplied shape; query_yn's cancelable=false is set at output.cpp's drive-block (regression-covered)
                return choice;
            } } );
        arcopolis::backend_arm_examine_query_popup_command( 0 );
        query_popup popup;
        popup.context( "YESNO" )
        .message( "%s", std::string( "Take down the mattress?" ) )
        .option( "YES" )
        .option( "NO" )
        .cursor( 1 );
        std::string action;
        {
            arcopolis::query_popup_witness_guard guard( "examine_deployed_furniture_take_down" );
            REQUIRE( arcopolis::backend_query_popup_transaction_active() );
            arcopolis::backend_resolve_query_popup_choice( {
                .title = "Take down the mattress?",
                .choices = { { .index = 0, .text = "YES", .enabled = true },
                    { .index = 1, .text = "NO", .enabled = true }
                },
                .cursor_start = popup.current_index(),
                .cancelable = false } );
            action = popup.query().action;  // drives the real query_once loop through the seam
        }
        CHECK_FALSE( popup.has_window() );  // the load-bearing invariant: NO curses window was created
        arcopolis::end_backend_session();
        return action;
    };
    CHECK( drive( 0 ) == "YES" );  // entry 0: served [LEFT, CONFIRM] -> options[0] == "YES"
    CHECK( drive( 1 ) == "NO" );   // entry 1: served [CONFIRM] on the NO cursor -> options[1] == "NO"
}

TEST_CASE( "arcopolis cata_test query_popup still aborts without a backend session", "[arcopolis]" )
{
    // The invariant the Spike 15 un-abort must NOT break: ordinary test_mode (cata_test, no backend session)
    // still short-circuits query_popup to {false,"ERROR",{}} at the top of query_once -- so query_yn returns
    // false (action "ERROR" != "YES"), exactly as before this spike. backend_query_popup_transaction_active() is
    // false here, so the abort is taken and no input_context loop runs.
    REQUIRE_FALSE( arcopolis::backend_query_popup_transaction_active() );
    CHECK_FALSE( query_yn( "Take down the mattress?" ) );
}

// --- Spike 16: non-live SCRIPT prompt sources. These prove that a scripted answer, consumed by the script
// source installed in --arcopolis-run-script, produces the SAME registered-action queue a live source would
// (feeding the SAME backend_resolve_* machinery), and that a missing / wrong-kind / title-mismatch /
// out-of-range / cancel-on-noncancelable / unused answer FAILS LOUD (command_error_kind::script_prompt_failed)
// rather than silently auto-cancelling. Each case seeds the per-command answer queue via
// backend_load_scripted_prompt_answers() instead of running the steps walk (world-independent). ---

TEST_CASE( "arcopolis script pickup source drives a multi-select like the live source",
           "[arcopolis]" )
{
    const std::vector<std::string> pickup_actions = {
        "UP", "DOWN", "LEFT", "RIGHT", "CONFIRM", "SELECT_ALL", "QUIT",
    };
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 7 );
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "menu", .choices = { 0, 2 } } }, 7 );
    const std::vector<arcopolis::pickup_prompt_choice> choices = {
        { .index = 0, .text = "a rock", .enabled = true },
        { .index = 1, .text = "a rag", .enabled = true },
        { .index = 2, .text = "a string", .enabled = true },
    };
    arcopolis::backend_resolve_pickup_choice( choices );
    // The SAME sequence the live multi-select test asserts: RIGHT (mark 0), DOWN DOWN (to 2), RIGHT, CONFIRM.
    for( const std::string &expected : {
             "RIGHT", "DOWN", "DOWN", "RIGHT", "CONFIRM"
         } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script uilist source drives a single-select like the live source",
           "[arcopolis]" )
{
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = arcopolis::script_uilist_prompt } );
    arcopolis::backend_arm_pickup_transaction(
        0 );   // the uilist transaction is gated on a pickup transaction
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "uilist", .choices = { 1 } } }, 0 );
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist", .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    },
    .cancelable = true } );
    for( const std::string &expected : {
             "DOWN", "CONFIRM"
         } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script query_popup source drives YES/NO like the live source", "[arcopolis]" )
{
    const std::vector<std::string> yesno_actions = { "LEFT", "RIGHT", "CONFIRM" };
    const auto drive = [&]( const int choice, const std::vector<std::string> &expected ) {
        arcopolis::begin_backend_session( { .steps = {},
                                            .query_popup_source = arcopolis::script_query_popup_prompt } );
        arcopolis::backend_arm_examine_query_popup_command( 0 );
        arcopolis::backend_begin_query_popup_transaction( "examine_deployed_furniture_take_down" );
        arcopolis::backend_load_scripted_prompt_answers( { { .kind = "query_popup", .choices = { choice } } },
        0 );
        arcopolis::backend_resolve_query_popup_choice( { .title = "Take down the mattress?",
        .choices = { { .index = 0, .text = "YES", .enabled = true },
            { .index = 1, .text = "NO", .enabled = true }
        },
        .cursor_start = 1, .cancelable = false } );
        for( const std::string &want : expected ) {
            const std::string *served = arcopolis::backend_nested_input_action( "YESNO", yesno_actions, -1 );
            REQUIRE( served != nullptr );
            CHECK( *served == want );
        }
        CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
        arcopolis::backend_end_query_popup_transaction();
        arcopolis::end_backend_session();
    };
    drive( 0, { "LEFT", "CONFIRM" } );  // YES: cursor NO(1) -> YES(0), then confirm
    drive( 1, { "CONFIRM" } );          // NO: cursor already on NO(1), confirm
}

TEST_CASE( "arcopolis script sources consume sequential prompt answers in order", "[arcopolis]" )
{
    // One pickup command opens a vehicle uilist THEN the old PICKUP menu; the two declared answers are
    // consumed in that order from the single per-command queue.
    const std::vector<std::string> pickup_actions = { "UP", "DOWN", "LEFT", "RIGHT", "CONFIRM", "QUIT" };
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {},
                                        .prompt_source = arcopolis::script_pickup_prompt,
                                        .uilist_prompt_source = arcopolis::script_uilist_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_load_scripted_prompt_answers(
    { { .kind = "uilist", .choices = { 1 } }, { .kind = "menu", .choices = { 0 } } }, 0 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist", .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    },
    .cancelable = true } );
    for( const std::string &expected : {
             "DOWN", "CONFIRM"
         } ) {
        const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
        REQUIRE( served != nullptr );
        CHECK( *served == expected );
    }
    arcopolis::backend_end_uilist_transaction();
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );
    const std::string *menu = arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
    REQUIRE( menu != nullptr );
    CHECK( *menu == "RIGHT" );  // choice 0: RIGHT then CONFIRM
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script pickup source fails loud when no answer is declared", "[arcopolis]" )
{
    const std::vector<std::string> pickup_actions = { "DOWN", "RIGHT", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    // No backend_load_scripted_prompt_answers -> the queue is empty when the menu opens.
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );
    const std::string *served = arcopolis::backend_nested_input_action( "PICKUP", pickup_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served == "QUIT" );  // the loop-exit escape hatch, NOT a user cancel
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script pickup source fails loud on a wrong-kind answer", "[arcopolis]" )
{
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "uilist", .choices = { 0 } } }, 0 );
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script pickup source fails loud on an out-of-range choice", "[arcopolis]" )
{
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "menu", .choices = { 5 } } }, 0 );
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );  // 1 entry only
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script uilist source fails loud on a title mismatch", "[arcopolis]" )
{
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = arcopolis::script_uilist_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_load_scripted_prompt_answers(
    { { .kind = "uilist", .choices = { 0 }, .title_contains = "no such title" } }, 0 );
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist", .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    },
    .cancelable = true } );
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script uilist source accepts a legitimate cancel without failing",
           "[arcopolis]" )
{
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = arcopolis::script_uilist_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "uilist", .cancel = true } }, 0 );
    arcopolis::backend_resolve_uilist_choice( { .kind = "uilist", .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    },
    .cancelable = true } );
    const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served == "QUIT" );  // a real cancel, served as the loop-exit QUIT
    CHECK_FALSE(
        arcopolis::backend_session_failure().has_value() );  // a legitimate cancel is NOT a failure
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script query_popup source fails loud on a cancel of a non-cancelable prompt",
           "[arcopolis]" )
{
    arcopolis::begin_backend_session( { .steps = {},
                                        .query_popup_source = arcopolis::script_query_popup_prompt } );
    arcopolis::backend_arm_examine_query_popup_command( 0 );
    arcopolis::backend_begin_query_popup_transaction( "examine_deployed_furniture_take_down" );
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "query_popup", .cancel = true } }, 0 );
    arcopolis::backend_resolve_query_popup_choice( { .title = "Take down the mattress?",
    .choices = { { .index = 0, .text = "YES", .enabled = true },
        { .index = 1, .text = "NO", .enabled = true }
    },
    .cursor_start = 1, .cancelable = false } );
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::backend_end_query_popup_transaction();
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script sources fail loud on an unused prompt answer", "[arcopolis]" )
{
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    // Two answers declared, but only the menu prompt will open -> the second is never consumed.
    arcopolis::backend_load_scripted_prompt_answers(
    { { .kind = "menu", .choices = { 0 } }, { .kind = "uilist", .choices = { 0 } } }, 0 );
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );  // the first answer matched fine
    // Returning to the top-level seam runs the unused-answer check on the leftover uilist answer.
    arcopolis::next_backend_action();
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script pickup fails loud on an unsupported forced-cancel secondary",
           "[arcopolis]" )
{
    // A disabled-entry secondary capacity uilist (or any unsupported in-activity sub-prompt) force-cancels via
    // backend_report_pickup_secondary_forced_cancel, which sets pickup_outcome but NO session.failure. In LIVE
    // mode the response writer consumes that outcome and marks the response partial. In non-live SCRIPT mode
    // there is no such writer, so the seam-return cleanup must surface a non-ok outcome as a fail-loud
    // script_prompt_failed (exit 13) -- never a silent exit-0 "ok" with the item left behind (AGENTS.md).
    arcopolis::begin_backend_session( { .steps = {}, .prompt_source = arcopolis::script_pickup_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "menu", .choices = { 0 } } }, 0 );
    arcopolis::backend_resolve_pickup_choice( { { .index = 0, .text = "x", .enabled = true } } );  // menu answer consumed
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
    // The activity hits a disabled-entry secondary -> the engine call site (src/pickup.cpp) reports it.
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    // Returning to the top-level seam surfaces the unsupported forced-cancel as a fail-loud script failure.
    arcopolis::next_backend_action();
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->kind ==
           arcopolis::command_error_kind::script_prompt_failed );
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script pickup forced-cancel outcome is NOT surfaced in live mode",
           "[arcopolis]" )
{
    // The mirror of the above: with a live_source installed, clear_stale_scripted_prompt_answers must NOT
    // consume/fail on the pickup outcome -- the live response writer owns it. backend_take_pickup_outcome()
    // therefore still returns the live outcome on the live side.
    arcopolis::begin_backend_session( { .steps = {},
                                        .live_source = []() -> action_id { arcopolis::backend_mark_input_done(); return ACTION_NULL; } } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    arcopolis::next_backend_action();  // live_source path: clear_stale_scripted must NOT touch the outcome
    CHECK_FALSE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_take_pickup_outcome() ==
           arcopolis::pickup_command_outcome::secondary_forced_cancel );  // still available to the live writer
    arcopolis::end_backend_session();
}

TEST_CASE( "arcopolis script source drives no prompt once a fatal failure is already recorded",
           "[arcopolis]" )
{
    // gemini PR#44 review: after a fatal script-prompt failure, a LATER prompt opened during the same engine
    // unwind must not be driven or log a second prompt_failed (match_scripted_answer short-circuits on
    // session.failure). The realistic trigger is a multi-secondary unwind, which no fixture provides; this is
    // the minimal in-memory witness. (1) open a uilist with an EMPTY queue -> fatal failure. (2) load a VALID
    // answer and re-open the prompt -> the guard must still serve the loop-exit QUIT (not the answer's DOWN)
    // and keep the FIRST failure detail. Without the guard the reloaded answer would be served here.
    const std::vector<std::string> uilist_actions = { "UP", "DOWN", "CONFIRM", "QUIT" };
    const arcopolis::backend_uilist_prompt_request request = { .kind = "uilist",
                                                               .title = "Get items from where?",
    .choices = { { .index = 0, .text = "vehicle", .enabled = true },
        { .index = 1, .text = "ground", .enabled = true }
    },
    .cancelable = true
                                                             };
    arcopolis::begin_backend_session( { .steps = {},
                                        .uilist_prompt_source = arcopolis::script_uilist_prompt } );
    arcopolis::backend_arm_pickup_transaction( 0 );
    arcopolis::backend_begin_uilist_transaction();
    arcopolis::backend_resolve_uilist_choice( request );  // (1) empty queue -> no_scripted_answer
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    const auto first_detail = arcopolis::backend_session_failure()->detail;
    CHECK( *arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 ) == "QUIT" );
    // (2) a valid answer is now declared, but the run has already failed -> the guard refuses to drive it.
    arcopolis::backend_load_scripted_prompt_answers( { { .kind = "uilist", .choices = { 1 } } }, 0 );
    arcopolis::backend_resolve_uilist_choice( request );
    const std::string *served = arcopolis::backend_nested_input_action( "UILIST", uilist_actions, -1 );
    REQUIRE( served != nullptr );
    CHECK( *served ==
           "QUIT" );  // loop-exit, NOT the answer's "DOWN" -- the prompt was not driven post-failure
    REQUIRE( arcopolis::backend_session_failure().has_value() );
    CHECK( arcopolis::backend_session_failure()->detail ==
           first_detail );  // first-failure-wins preserved
    arcopolis::backend_end_uilist_transaction();
    arcopolis::end_backend_session();
}
