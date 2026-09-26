import Testing

@testable import SwiftCDDL

/// Byte string literals in base16 and base64 notation (RFC 8610 Section 3.1)
/// match the bytes they decode to, and a mismatch names the literal in its
/// canonical notation. How the literals parse and render is covered by the
/// literal and token tests.
@Suite struct ByteStringLiteralValidationTests {
    @Test func nonUtf8ByteLiteralMismatchesReturnDiagnostics() async {
        for (literal, rendered) in [("h'AA'", "h'aa'"), ("b64'qg=='", "b64'qg'")] {
            let verdict = await expectInvalid("m = \(literal)", [0x01])
            let error = verdict?.description ?? ""

            #expect(
                error.contains("expected \(rendered)") && error.contains("got"),
                "unexpected diagnostic for \(literal): \(error)"
            )
        }
    }

    @Test func decodedByteLiteralAcceptingAndRejectingControls() async {
        for (literal, matching) in [
            ("h'AA'", [UInt8]([0x41, 0xaa])),
            ("b64'qg=='", [0x41, 0xaa]),
            ("b64'qg'", [0x41, 0xaa]),
        ] {
            let schema = "m = \(literal)"
            await expectValid(schema, matching)
            // A distinct byte string must not match the literal.
            await expectInvalid(schema, [0x41, 0xab])
        }
    }

    @Test func base64AlphabetAndPaddingVariantsDecodeIdentically() async {
        for literal in ["b64'-_8='", "b64'-_8'", "b64'+/8='", "b64'+/8'"] {
            let schema = "m = \(literal)"
            await expectValid(schema, [0x42, 0xfb, 0xff])
            // A distinct byte string must not match the literal.
            await expectInvalid(schema, [0x42, 0xfb, 0xfe])
        }
    }
}
