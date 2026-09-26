import Testing

@testable import SwiftCDDL

/// Validation against type choices built incrementally. RFC 8610 Section
/// 2.2.2 makes every `/=` right-hand side an additional arm of the named type
/// choice, and Appendix C requires those arms to be populated in source order.
@Suite struct IncrementalTypeChoicesValidationTests {
    // MARK: - Private helpers

    private static let baseFirstRoot = """

        extended = bool
        extended /= text
        extended /= uint

        """

    private static let baseFirstAlias = """

        root = extended
        extended = bool
        extended /= text
        extended /= uint

        """

    private static let alternateOnlyRoot = """

        extended /= text
        extended /= uint

        """

    private static let alternateOnlyAlias = """

        root = extended
        extended /= text
        extended /= uint

        """

    private func assertCborThreeArmChoice(_ schema: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        // Accept the base after two failed additions, and accept either
        // addition.
        await expectValid(schema, [0xf5], sourceLocation: sourceLocation)
        await expectValid(schema, [0x61, UInt8(ascii: "x")], sourceLocation: sourceLocation)
        await expectValid(schema, [0x00], sourceLocation: sourceLocation)

        // Reject a value outside every arm.
        await expectInvalid(schema, [0xf6], sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    @Test func cborIncrementalChoiceIsRootIndependentAndTransactional() async {
        await assertCborThreeArmChoice(Self.baseFirstRoot)
        await assertCborThreeArmChoice(Self.baseFirstAlias)
    }

    @Test func alternateOnlyChoiceRemainsValidAtRootAndThroughAlias() async {
        for schema in [Self.alternateOnlyRoot, Self.alternateOnlyAlias] {
            await expectValid(schema, [0x61, UInt8(ascii: "x")])
            await expectValid(schema, [0x00])
            await expectInvalid(schema, [0xf5])
        }
    }

    @Test func genericRuleExtendedByAMatchingArmKeepsValidating() async throws {
        // A rule that carries generic parameters may be extended with `/=`
        // under the same name. RFC 8610's grammar allows it (`rule = typename
        // [genericparm] S assignt S type` with `assignt = "=" / "/="`), and
        // both arms must honor the argument bound at the citation site.
        let schema = "root = a<int>\na<t> = [t]\na<t> /= {k: t}\n"
        _ = try cddlFromStr(schema)

        // Either arm matches, with `t` bound to `int` in both.
        await expectValid(schema, [0x81, 0x01])
        await expectValid(schema, [0xa1, 0x61, UInt8(ascii: "k"), 0x01])

        // The binding is real, not vacuous: a `tstr` where the argument says
        // `int` fails in both arms.
        await expectInvalid(schema, [0x81, 0x61, UInt8(ascii: "x")])
        await expectInvalid(schema, [0xa1, 0x61, UInt8(ascii: "k"), 0x61, UInt8(ascii: "x")])
    }

    @Test func recursiveChoiceArmsConsumeNestedData() async {
        // RFC 8610 Section 2.2.2 and Appendix C resolve every schema below to
        // the choice (uint / [t]) no matter how `t` is reached, and PEG
        // matching recurses into the array arm one data level at a time.
        let root = "t = uint\nt /= [t]\n"
        let alias = "root = t\nt = uint\nt /= [t]\n"
        let alternateOnly = "t /= uint\nt /= [t]\n"

        for schema in [root, alias, alternateOnly] {
            let values: [[UInt8]] = [
                [0x00],
                [0x81, 0x00],
                [0x81, 0x81, 0x00],
                [0x81, 0x81, 0x81, 0x00],
            ]
            for value in values {
                await expectValid(schema, value)
            }
            await expectInvalid(schema, [0x61, UInt8(ascii: "x")])
        }

        // A value outside both arms must fail at every nesting depth instead
        // of being waved through by a coarse recursion guard once `t` repeats.
        for schema in [root, alias, alternateOnly] {
            await expectInvalid(schema, [0x81, 0x81, 0xf5])
        }
    }

    @Test func mutuallyRecursiveIncrementalChoiceConsumesNestedData() async {
        // A list whose items are scalars or lists.
        let schema = "list = [* item]\nitem = int\nitem /= list\n"

        // [[1], 2] and [[[3]], 4]
        await expectValid(schema, [0x82, 0x81, 0x01, 0x02])
        await expectValid(schema, [0x82, 0x81, 0x81, 0x03, 0x04])
        // [["x"]]
        await expectInvalid(schema, [0x81, 0x81, 0x61, UInt8(ascii: "x")])
    }

    @Test func recursiveAlternateOnlyReferenceCompletesInsteadOfCrashing() async {
        for schema in ["a /= a\n", "root = a\na /= a\n"] {
            // A revisited rule is treated as satisfied, so the verdict for
            // this degenerate schema is a vacuous accept (`a = a` behaves the
            // same way); what is pinned here is only that validation
            // completes.
            _ = await cborResult(schema, [0x00])
        }
    }
}
