import XCTest
import AROParser
@testable import ARORuntime

/// Pins the wire-format used by AROCompiler's `LLVMTypeMapper` when it
/// encodes a Preposition as an Int32 and the runtime's `intToPreposition`
/// when it decodes the same value. The two must stay in lockstep or
/// compiled binaries silently misinterpret the preposition of every
/// action call.
///
/// Regression for the bug where `Make the <X> at the <path: Y>.` in an
/// `aro build` binary blew up with
/// "Invalid preposition 'from' for action 'MakeAction'", because
/// `LLVMTypeMapper.prepositionValue(.at)` was 10 but `intToPreposition`
/// only handled 1…8 and fell through to nil → `.from`.
final class ActionBridgePrepositionTests: XCTestCase {

    func testAllPrepositionsRoundTrip() {
        let cases: [(Preposition, Int)] = [
            (.from,     1),
            (.for,      2),
            (.with,     3),
            (.to,       4),
            (.into,     5),
            (.via,      6),
            (.against,  7),
            (.on,       8),
            (.by,       9),
            (.at,      10),
        ]
        for (prep, expected) in cases {
            XCTAssertEqual(
                intToPreposition(expected), prep,
                "Wire code \(expected) must decode back to .\(prep) — keep this table in sync with LLVMTypeMapper.prepositionValue."
            )
        }
    }

    func testUnknownWireCodeReturnsNil() {
        XCTAssertNil(intToPreposition(0))
        XCTAssertNil(intToPreposition(11))
        XCTAssertNil(intToPreposition(-1))
    }
}
