import Testing

@testable import SwiftCDDL

/// Validation against group choices built incrementally with `//=` (RFC 8610
/// Appendix C). The parse-time duplicate-definition checks are covered by
/// ``IncrementalChoicesTests``.
@Suite struct IncrementalGroupChoicesValidationTests {
    @Test func incrementalGroupChainStaysValidAtRootAndThroughAlias() async {
        // A pure `//=` chain is the well-formed way to build a named group
        // choice, whether or not a plain base rule ever existed.
        let alias = "r = {g}\ng //= (k: int)\ng //= (j: int)\n"
        let reordered = "g //= (k: int)\ng //= (j: int)\nr = {g}\n"

        for schema in [alias, reordered] {
            // {"k":1} / {"j":1} / {"x":1}
            await expectValid(schema, [0xa1, 0x61, UInt8(ascii: "k"), 0x01])
            await expectValid(schema, [0xa1, 0x61, UInt8(ascii: "j"), 0x01])
            await expectInvalid(schema, [0xa1, 0x61, UInt8(ascii: "x"), 0x01])
        }
    }
}
