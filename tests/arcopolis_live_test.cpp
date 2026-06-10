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

TEST_CASE( "arcopolis live request parser accepts the three ops", "[arcopolis]" )
{
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
