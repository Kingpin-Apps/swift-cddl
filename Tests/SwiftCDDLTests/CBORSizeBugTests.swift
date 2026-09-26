import Testing

@testable import SwiftCDDL

/// A `.size` control on a text string type (RFC 8610 Section 3.8.1) does not
/// widen the type it constrains: a byte string is no text string, with or
/// without a size bound.
@Suite struct CBORSizeBugTests {
    @Test func testTypeCheckWithSizeConstraint() async {
        // A map holding a byte string where a text string is expected.
        let document = CBORNode.map([(key: .text("digitalSourceType"), value: .bytes([1, 2, 3, 4]))])

        // Without a size constraint the byte string is rejected.
        let withoutSize = """
                    root = {
                        "digitalSourceType": tstr
                    }
            """
        let resultWithoutSize = await expectInvalid(withoutSize, document.encoded())
        let messageWithoutSize = resultWithoutSize?.description ?? ""
        #expect(
            messageWithoutSize.contains("expected type tstr, got Bytes"),
            "the error names the type mismatch: \(messageWithoutSize)"
        )

        // With a size constraint the same byte string is still rejected.
        let withSize = """
                    root = {
                        "digitalSourceType": tstr .size (1..500)
                    }
            """
        let resultWithSize = await expectInvalid(withSize, document.encoded())
        let messageWithSize = resultWithSize?.description ?? ""
        #expect(messageWithSize.contains("expected type tstr"), "the error names the type mismatch: \(messageWithSize)")
    }
}
