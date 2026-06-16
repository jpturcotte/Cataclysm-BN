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

// --- Spike 13B: backend-driven uilist transaction (the "Get items from where?" vehicle-source submenu). ---

TEST_CASE( "arcopolis backend_ui_mode_active gates on an armed uilist transaction only",
           "[arcopolis]" )
{
    // The uilist test_mode-abort bypass (src/ui.cpp) keys on this gate and NOTHING weaker. It must be false
    // outside a session, false inside a session with no uilist transaction (even with a pickup transaction
    // armed), true only between begin/end of a uilist transaction.
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );           // no session
    arcopolis::begin_backend_session( { .steps = {} } );
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );           // session, nothing armed
    arcopolis::backend_begin_uilist_transaction();                // inert without a pickup transaction
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );
    arcopolis::backend_arm_pickup_transaction( 1 );
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );           // pickup transaction is not enough
    arcopolis::backend_begin_uilist_transaction();
    CHECK( arcopolis::backend_ui_mode_active() );                 // armed
    arcopolis::backend_end_uilist_transaction();
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );           // cleared
    arcopolis::backend_end_uilist_transaction();                  // idempotent
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );
    arcopolis::end_backend_session();
    CHECK_FALSE( arcopolis::backend_ui_mode_active() );
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
    // session) still short-circuits every uilist to UILIST_ERROR. backend_ui_mode_active() is false here, so
    // both init() and query() take the abort (each emits its debugmsg, captured so the test does not abort).
    REQUIRE_FALSE( arcopolis::backend_ui_mode_active() );
    const std::string msgs = capture_debugmsg_during( []() {
        uilist menu( "Get items from where?", { "Get items from vehicle cargo", "Get items on the ground" } );
        CHECK( menu.ret == UILIST_ERROR );
    } );
    CHECK_FALSE( msgs.empty() );
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
