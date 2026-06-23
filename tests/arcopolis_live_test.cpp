#include "catch/catch.hpp"

#include <algorithm>
#include <array>
#include <optional>
#include <sstream>
#include <string>

#include "arcopolis_live.h"  // parse_live_request, the protocol-line formatters
#include "json.h"            // JsonIn, JsonObject

// Unit tests for the Arcopolis live protocol (Spike 9B). These cover the PURE layer -- the request
// parser and the wire formatters -- the world-independent core. The stateful pump/runner (run_live)
// drives a loaded game and stdin/stdout and is exercised by the headless binary against ArcopolisTest
// (docs/arcopolis/live_protocol_regression.ps1), mirroring the session-log test's split.

namespace
{

/// True iff `s` is exactly one newline-terminated line (a single JSON Lines record): non-empty, ends
/// in '\n', and contains no other newline.
auto is_one_line( const std::string &s ) -> bool
{
    namespace ranges = std::ranges;
    return !s.empty() && s.back() == '\n' && ranges::count( s, '\n' ) == 1;
}

/// Parses one formatted protocol line and runs `check` on the resulting object. JsonObject keeps a raw
/// JsonIn* (and reads members from the stream), so the istringstream + JsonIn must stay alive across
/// the reads -- hence the callback. Protocol lines carry NO schema_version (the `ready` event carries
/// protocol_version instead), unlike the transcript's records.
template<typename Check>
auto with_protocol_line( const std::string &line, Check check ) -> void
{
    REQUIRE( is_one_line( line ) );
    std::istringstream is( line );
    JsonIn json( is );
    auto obj = json.get_object();  // throws JsonError (fails the test) on malformed JSON
    obj.allow_omitted_members();
    check( obj );
}

} // namespace

TEST_CASE( "arcopolis live request parser accepts the four ops", "[arcopolis]" )
{
    // Spike 26A added "query" alongside the original export/command/quit; the structural-coverage cases
    // for the new op live in their own labeled TEST_CASE ("arcopolis op:query observes on-person
    // dialogue predicate; does NOT answer MGOAL_FIND_ITEM mission completion") so this case stays
    // focused on the three original command-shape ops.
    SECTION( "export with id and name" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":1,"op":"export","name":"start"})" );
        REQUIRE( req.has_value() );
        CHECK( req->id == std::optional<int>( 1 ) );
        CHECK( req->op == "export" );
        CHECK( req->name == "start" );
    }
    SECTION( "command move with direction and name" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":2,"op":"command","command":"move","direction":"move_n","name":"after_move_n"})" );
        REQUIRE( req.has_value() );
        CHECK( req->id == std::optional<int>( 2 ) );
        CHECK( req->op == "command" );
        CHECK( req->command == "move" );
        CHECK( req->direction == "move_n" );
        CHECK( req->name == "after_move_n" );
    }
    SECTION( "wait command needs no direction" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":3,"op":"command","command":"wait","name":"after_wait"})" );
        REQUIRE( req.has_value() );
        CHECK( req->command == "wait" );
        CHECK( req->direction.empty() );
    }
    SECTION( "quit" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":4,"op":"quit"})" );
        REQUIRE( req.has_value() );
        CHECK( req->op == "quit" );
        CHECK( req->id == std::optional<int>( 4 ) );
    }
    SECTION( "query (covered in depth by its own TEST_CASE; this case pins the four-op acceptance)" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":5,"op":"query","kind":"has_item","item":"glass_shard"})" );
        REQUIRE( req.has_value() );
        CHECK( req->op == "query" );
        CHECK( req->query_kind == "has_item" );
        CHECK( req->query_item == "glass_shard" );
    }
}

TEST_CASE( "arcopolis live request parser applies the documented defaults", "[arcopolis]" )
{
    SECTION( "name defaults to 'snapshot' when omitted (the script provider's default)" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":1,"op":"export"})" );
        REQUIRE( req.has_value() );
        CHECK( req->name == "snapshot" );
    }
    SECTION( "id is optional" ) {
        const auto req = arcopolis::parse_live_request( R"({"op":"export","name":"x"})" );
        REQUIRE( req.has_value() );
        CHECK_FALSE( req->id.has_value() );
    }
    SECTION( "a non-int id reads as absent (the response will carry JSON null)" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":"seven","op":"export"})" );
        REQUIRE( req.has_value() );
        CHECK_FALSE( req->id.has_value() );
    }
}

TEST_CASE( "arcopolis live request parser does NOT pre-screen command vocabulary", "[arcopolis]" )
{
    // Single-rejection-point design: the structural parser accepts any verb/direction string;
    // command_to_action() (already covered by the arcopolis_command tests) is the one place that
    // rejects move_up / unknown verbs, which the pump maps to the protocol's unsupported_command.
    const auto req = arcopolis::parse_live_request(
                         R"({"id":5,"op":"command","command":"move","direction":"move_up","name":"bad"})" );
    REQUIRE( req.has_value() );
    CHECK( req->direction == "move_up" );
}

TEST_CASE( "arcopolis live request parser rejects malformed JSON with a null id", "[arcopolis]" )
{
    const auto req = arcopolis::parse_live_request( "this is not json" );
    REQUIRE_FALSE( req.has_value() );
    CHECK( req.error().code == arcopolis::live_error_code::malformed_json );
    CHECK_FALSE( req.error().id.has_value() );
    CHECK_FALSE( req.error().message.empty() );
}

TEST_CASE( "arcopolis live request parser rejects structural problems as bad_request",
           "[arcopolis]" )
{
    SECTION( "missing op (the readable id is echoed)" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":9})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
        CHECK( req.error().id == std::optional<int>( 9 ) );
    }
    SECTION( "unknown op" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":9,"op":"dance"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "command op without a command verb" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":9,"op":"command"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "non-string name" ) {
        const auto req = arcopolis::parse_live_request( R"({"id":9,"op":"export","name":7})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
}

TEST_CASE( "arcopolis live request parser whitelists the export name", "[arcopolis]" )
{
    // A name outside [A-Za-z0-9_.-] could survive ensure_valid_file_name() into the snapshot
    // filename, fail the file open, and escalate a recoverable typo into the fatal export_failed
    // path -- so the parser rejects it up front as a RECOVERABLE bad_request.
    const auto cases = std::array{
        std::string( R"({"id":1,"op":"export","name":"a b"})" ),    // space
        std::string( R"({"id":1,"op":"export","name":"a\nb"})" ),   // control character
        std::string( R"({"id":1,"op":"export","name":""})" ),       // empty
        std::string( R"({"id":1,"op":"export","name":")" ) + std::string( 65, 'x' ) + R"("})", // too long
    };
    for( const auto &line : cases ) {
        INFO( line );
        const auto req = arcopolis::parse_live_request( line );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
        CHECK( req.error().id == std::optional<int>( 1 ) );
    }
    // The allowed alphabet passes.
    const auto ok = arcopolis::parse_live_request(
                        R"({"id":1,"op":"export","name":"After_2.move-n"})" );
    REQUIRE( ok.has_value() );
    CHECK( ok->name == "After_2.move-n" );
}

TEST_CASE( "arcopolis live ready line is one valid protocol object", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_ready_line( out, { .world = "ArcopolisTest" } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "type" ) == "ready" );
        CHECK( obj.get_int( "protocol_version" ) == arcopolis::live_protocol_version );
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "world" ) == "ArcopolisTest" );
    } );
}

TEST_CASE( "arcopolis live success response carries the snapshot scalars", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_success_response_line( out, { .id = std::optional<int>( 2 ),
                                            .op = "command",
                                            .snapshot = "001_after_move_n.json",
                                            .export_index = 1,
                                            .turn = 1324801
                                                 } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "type" ) == "response" );
        CHECK( obj.get_int( "id" ) == 2 );
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "command" );
        CHECK( obj.get_string( "snapshot" ) == "001_after_move_n.json" );
        CHECK( obj.get_int( "export_index" ) == 1 );
        CHECK( obj.get_int( "turn" ) == 1324801 );
    } );
}

TEST_CASE( "arcopolis live success response omits the partial markers by default", "[arcopolis]" )
{
    // A clean pickup / any non-pickup command emits no forced_cancel/partial/unsupported_prompt members,
    // so existing wire output is byte-unchanged (the follow-up markers are strictly additive).
    std::ostringstream out;
    arcopolis::write_success_response_line( out, { .id = std::optional<int>( 2 ),
                                            .op = "command",
                                            .snapshot = "001_after_pickup.json",
                                            .export_index = 1,
                                            .turn = 1324802
                                                 } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_bool( "ok" ) );
        CHECK_FALSE( obj.has_member( "forced_cancel" ) );
        CHECK_FALSE( obj.has_member( "partial" ) );
        CHECK_FALSE( obj.has_member( "unsupported_prompt" ) );
    } );
}

TEST_CASE( "arcopolis live success response marks a force-cancelled secondary prompt as partial",
           "[arcopolis]" )
{
    // ok stays true (a real partial pickup happened), but the explicit marker set makes the partiality
    // unmistakable so the result is never read as full success (docs/arcopolis/31).
    std::ostringstream out;
    arcopolis::write_success_response_line( out, { .id = std::optional<int>( 5 ),
                                            .op = "command",
                                            .snapshot = "002_after_pickup.json",
                                            .export_index = 2,
                                            .turn = 1324803,
                                            .forced_cancel = true,
                                            .partial = true,
                                            .unsupported_prompt = "secondary_capacity"
                                                 } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_bool( "forced_cancel" ) );
        CHECK( obj.get_bool( "partial" ) );
        CHECK( obj.get_string( "unsupported_prompt" ) == "secondary_capacity" );
    } );
}

TEST_CASE( "arcopolis live quit response reports session_end", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_quit_response_line( out, { .id = std::optional<int>( 4 ) } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "type" ) == "response" );
        CHECK( obj.get_int( "id" ) == 4 );
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "quit" );
        CHECK( obj.get_string( "status" ) == "session_end" );
    } );
}

TEST_CASE( "arcopolis live error response writes a null id and omits an unknown op", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_error_response_line( out, { .id = std::nullopt,
                                          .op = "",
                                          .code = arcopolis::live_error_code::malformed_json,
                                          .message = "malformed JSON: oops"
                                               } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "type" ) == "response" );
        REQUIRE( obj.has_member( "id" ) );   // present...
        CHECK( obj.has_null( "id" ) );       // ...as an explicit JSON null (protocol v0)
        CHECK_FALSE( obj.get_bool( "ok" ) );
        CHECK_FALSE( obj.has_member( "op" ) );  // op unknowable for malformed JSON
        auto err = obj.get_object( "error" );
        CHECK( err.get_string( "code" ) == "malformed_json" );
        CHECK( err.get_string( "message" ) == "malformed JSON: oops" );
    } );
}

TEST_CASE( "arcopolis live error response echoes the id and op when known", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_error_response_line( out, { .id = std::optional<int>( 5 ),
                                          .op = "command",
                                          .code = arcopolis::live_error_code::unsupported_command,
                                          .message = "unsupported move direction 'move_up'"
                                               } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_int( "id" ) == 5 );
        CHECK_FALSE( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "command" );
        auto err = obj.get_object( "error" );
        // Nested objects need their own opt-out from the strict unvisited-member check, or the
        // unread "message" member fails the test run as a logged error.
        err.allow_omitted_members();
        CHECK( err.get_string( "code" ) == "unsupported_command" );
    } );
}

TEST_CASE( "arcopolis live error codes have stable wire names", "[arcopolis]" )
{
    using code_t = arcopolis::live_error_code;
    CHECK( arcopolis::live_error_code_name( code_t::malformed_json ) == "malformed_json" );
    CHECK( arcopolis::live_error_code_name( code_t::bad_request ) == "bad_request" );
    CHECK( arcopolis::live_error_code_name( code_t::unsupported_command ) == "unsupported_command" );
    CHECK( arcopolis::live_error_code_name( code_t::export_failed ) == "export_failed" );
    CHECK( arcopolis::live_error_code_name( code_t::game_over ) == "game_over" );
    CHECK( arcopolis::live_error_code_name( code_t::backend_stalled ) == "backend_stalled" );
}

TEST_CASE( "arcopolis parse_prompt_answer accepts a valid choice and an explicit cancel",
           "[arcopolis]" )
{
    const auto chosen = arcopolis::parse_prompt_answer(
                            R"({ "op": "prompt_answer", "id": 5, "prompt_id": 1, "choice": 1 })", 3 );
    REQUIRE( chosen.has_value() );
    CHECK( chosen->act == arcopolis::live_prompt_answer::action::choose );
    CHECK( chosen->choices == std::vector<int> { 1 } );
    CHECK( chosen->id.value_or( -1 ) == 5 );
    CHECK( chosen->prompt_id == 1 );

    // A `choices` array is multi-select, returned canonical: sorted + duplicate-free ([2, 0] -> [0, 2]).
    const auto multi = arcopolis::parse_prompt_answer(
                           R"({ "op": "prompt_answer", "id": 7, "prompt_id": 2, "choices": [2, 0] })", 3 );
    REQUIRE( multi.has_value() );
    CHECK( multi->act == arcopolis::live_prompt_answer::action::choose );
    CHECK( multi->choices == std::vector<int> { 0, 2 } );
    CHECK( multi->prompt_id == 2 );

    const auto cancel = arcopolis::parse_prompt_answer(
                            R"({ "op": "prompt_cancel", "id": 6, "prompt_id": 1 })", 3 );
    REQUIRE( cancel.has_value() );
    CHECK( cancel->act == arcopolis::live_prompt_answer::action::cancel );
    CHECK( cancel->id.value_or( -1 ) == 6 );
    CHECK( cancel->prompt_id == 1 );
}

TEST_CASE( "arcopolis parse_prompt_answer rejects bad/missing prompt_id, out-of-range, duplicate, wrong-op and malformed",
           "[arcopolis]" )
{
    // Each is a RECOVERABLE bad_request (the caller rejects it, logs prompt_failed, keeps the prompt OPEN).
    for( const std::string &line : {
             R"({ "op": "prompt_answer", "choice": 0 })",                       // missing prompt_id
             R"({ "op": "prompt_cancel" })",                                    // cancel also requires prompt_id
             R"({ "op": "prompt_answer", "prompt_id": 1, "choice": 3 })",       // out of range (high)
             R"({ "op": "prompt_answer", "prompt_id": 1, "choice": -1 })",      // out of range (low)
             R"({ "op": "prompt_answer", "prompt_id": 1, "choices": [5] })",    // out of range
             R"({ "op": "prompt_answer", "prompt_id": 1, "choices": [] })",     // empty
             R"({ "op": "prompt_answer", "prompt_id": 1, "choices": [0, 0] })", // duplicate
             R"({ "op": "prompt_answer", "prompt_id": 1, "choices": [1, 2, 1] })", // duplicate (non-adjacent in input)
             R"({ "op": "prompt_answer", "prompt_id": 1 })"                     // no choice/choices
         } ) {
        const auto bad = arcopolis::parse_prompt_answer( line, 3 );
        REQUIRE_FALSE( bad.has_value() );
        CHECK( bad.error().code == arcopolis::live_error_code::bad_request );
    }
    const auto wrong_op = arcopolis::parse_prompt_answer( R"({ "op": "wait", "prompt_id": 1 })", 3 );
    REQUIRE_FALSE( wrong_op.has_value() );
    CHECK( wrong_op.error().code == arcopolis::live_error_code::bad_request );

    const auto malformed = arcopolis::parse_prompt_answer( "{ not json", 3 );
    REQUIRE_FALSE( malformed.has_value() );
    CHECK( malformed.error().code == arcopolis::live_error_code::malformed_json );
}

TEST_CASE( "arcopolis parse_prompt_answer rejects mid-prompt op:\"query\" as bad_request (Spike 26A parser-level mid-prompt witness)",
           "[arcopolis]" )
{
    // Spike 26A mid-prompt invariant: while a prompt is open, the prompt-source readers own stdin
    // and forward incoming lines through parse_prompt_answer; an out-of-order `op:"query"` (the new
    // live op) must be REJECTED as bad_request here, with the prompt left OPEN. The structural
    // rejection is the existing "expected op 'prompt_answer' or 'prompt_cancel'" branch
    // (arcopolis_live.cpp ~644-646); this case pins it with the VERBATIM `query` op string. The
    // companion live-transcript witness is Gate 8 in spike26a_dialogue_predicate_regression.ps1
    // (drives a real Spike 12A pickup PICKUP menu and submits the mid-prompt query for real).
    // Promoted to its own TEST_CASE (was a SECTION) so the case name describes what it actually
    // tests -- the SECTION was buried inside a "wrong-op and malformed" cluster, which obscured the
    // role of this specific case in the labeling-guard story.
    const auto query_mid_prompt = arcopolis::parse_prompt_answer(
                                      R"({ "op": "query", "prompt_id": 1, "kind": "has_item", "item": "glass_shard" })", 3 );
    REQUIRE_FALSE( query_mid_prompt.has_value() );
    CHECK( query_mid_prompt.error().code == arcopolis::live_error_code::bad_request );

    // Defense in depth: even without a kind/item payload (a malformed query, missing the body the
    // live parser would require), the op string alone is enough for the rejection.
    const auto query_op_only = arcopolis::parse_prompt_answer(
                                   R"({ "op": "query", "prompt_id": 1 })", 3 );
    REQUIRE_FALSE( query_op_only.has_value() );
    CHECK( query_op_only.error().code == arcopolis::live_error_code::bad_request );
}

TEST_CASE( "arcopolis live prompt event carries the real choices", "[arcopolis]" )
{
    std::ostringstream out;
    arcopolis::write_prompt_line( out, { .id = std::optional<int>( 9 ),
                                         .prompt_id = 1,
                                         .kind = "menu",
                                         .title = "Pick up which items?",
    .choices = { { .index = 0, .text = "a rock", .enabled = true },
        { .index = 1, .text = "a rag", .enabled = false }
    },
    .cancelable = true
                                       } );
    CHECK( is_one_line( out.str() ) );
    with_protocol_line( out.str(), []( const auto & obj ) {
        obj.allow_omitted_members();
        CHECK( obj.get_string( "type" ) == "prompt" );
        CHECK( obj.get_int( "id" ) == 9 );
        CHECK( obj.get_int( "prompt_id" ) == 1 );
        CHECK( obj.get_string( "kind" ) == "menu" );
        CHECK( obj.get_bool( "cancelable" ) );
        CHECK( obj.has_member( "choices" ) );
    } );
}

TEST_CASE( "arcopolis live prompt ack reports the chosen index/indices or a cancel", "[arcopolis]" )
{
    std::ostringstream chose;
    arcopolis::write_prompt_ack_line( chose, { .id = std::optional<int>( 2 ), .prompt_id = 1,
                                      .choices = std::vector<int> { 1 }
                                             } );
    with_protocol_line( chose.str(), []( const auto & obj ) {
        obj.allow_omitted_members();
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "prompt_answer" );
        CHECK( obj.get_int_array( "choices" ) == std::vector<int> { 1 } );
    } );

    std::ostringstream cancelled;
    arcopolis::write_prompt_ack_line( cancelled, { .id = std::optional<int>( 3 ), .prompt_id = 1,
                                      .choices = std::nullopt
                                                 } );
    with_protocol_line( cancelled.str(), []( const auto & obj ) {
        obj.allow_omitted_members();
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_bool( "cancelled" ) );
    } );
}

// --- Spike 26A: live op == "query" with kind == "has_item" ----------------------------------------
//
// The TEST_CASE name carries the load-bearing labeling guard verbatim
// ("on_person_dialogue_predicate; does NOT answer MGOAL_FIND_ITEM mission completion") so the same
// string appears in the spike doc 52, the ARCOPOLIS_STATE row, and the live response payload — a
// future doc/code drift would have to change all four coordinated sites to silently re-claim broader
// scope. The handler itself (run_live in arcopolis_live.cpp) needs a loaded world and is covered by the
// pwsh regression spike26a_dialogue_predicate_regression.ps1; the pure layer (parser + formatter +
// labeling-guard string) is covered here.

TEST_CASE( "arcopolis op:query observes on-person dialogue predicate; does NOT answer MGOAL_FIND_ITEM mission completion",
           "[arcopolis]" )
{
    SECTION( "well-formed has_item with explicit count" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":10,"op":"query","kind":"has_item","item":"glass_shard","count":2})" );
        REQUIRE( req.has_value() );
        CHECK( req->op == "query" );
        CHECK( req->id == std::optional<int>( 10 ) );
        CHECK( req->query_kind == "has_item" );
        CHECK( req->query_item == "glass_shard" );
        CHECK( req->query_count == 2 );
        // The query op carries none of the command/export fields.
        CHECK( req->command.empty() );
        CHECK( req->direction.empty() );
    }
    SECTION( "count defaults to 1 when omitted" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":11,"op":"query","kind":"has_item","item":"glass_shard"})" );
        REQUIRE( req.has_value() );
        CHECK( req->query_count == 1 );
    }
    SECTION( "missing kind is bad_request" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":12,"op":"query","item":"glass_shard"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
        CHECK( req.error().id == std::optional<int>( 12 ) );
    }
    SECTION( "unknown kind is bad_request (no silent fall-through)" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":13,"op":"query","kind":"has_quality","item":"butchering"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "missing item is bad_request" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":14,"op":"query","kind":"has_item"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "empty item is bad_request" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":15,"op":"query","kind":"has_item","item":""})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "non-int count is bad_request" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":16,"op":"query","kind":"has_item","item":"glass_shard","count":"two"})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
    SECTION( "count <= 0 is bad_request" ) {
        const auto req = arcopolis::parse_live_request(
                             R"({"id":17,"op":"query","kind":"has_item","item":"glass_shard","count":0})" );
        REQUIRE_FALSE( req.has_value() );
        CHECK( req.error().code == arcopolis::live_error_code::bad_request );
    }
}

TEST_CASE( "arcopolis live query response carries the verbatim scope labeling guard",
           "[arcopolis]" )
{
    // The literal string "on_person_dialogue_predicate" is the labeling guard — it must appear in the
    // response payload BYTE-FOR-BYTE. Any future change to the scope label is the visible signal of a
    // scope-claim change (which would have to be reflected in the spike doc, the STATE row, AND this
    // assertion).
    std::ostringstream out;
    arcopolis::write_query_response_line( out, { .id = std::optional<int>( 10 ),
                                          .kind = std::string( "has_item" ),
                                          .has = true,
                                          .scope = std::string( "on_person_dialogue_predicate" )
                                               } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        CHECK( obj.get_string( "type" ) == "response" );
        CHECK( obj.get_int( "id" ) == 10 );
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "query" );
        CHECK( obj.get_string( "kind" ) == "has_item" );
        CHECK( obj.get_bool( "has" ) );
        CHECK( obj.get_string( "scope" ) == "on_person_dialogue_predicate" );
    } );
}

TEST_CASE( "arcopolis live query response with has=false carries the same scope label",
           "[arcopolis]" )
{
    // The scope label is independent of the boolean — it is a property of the OP, not of the answer.
    std::ostringstream out;
    arcopolis::write_query_response_line( out, { .id = std::nullopt,
                                          .kind = std::string( "has_item" ),
                                          .has = false,
                                          .scope = std::string( "on_person_dialogue_predicate" )
                                               } );
    with_protocol_line( out.str(), []( const auto & obj ) {
        REQUIRE( obj.has_member( "id" ) );
        CHECK( obj.has_null( "id" ) );
        CHECK( obj.get_bool( "ok" ) );
        CHECK( obj.get_string( "op" ) == "query" );
        CHECK( obj.get_string( "kind" ) == "has_item" );
        CHECK_FALSE( obj.get_bool( "has" ) );
        CHECK( obj.get_string( "scope" ) == "on_person_dialogue_predicate" );
    } );
}
