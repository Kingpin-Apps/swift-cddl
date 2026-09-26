import Testing

@testable import SwiftCDDL

/// Recursive table maps. RFC 8610 Sections 2.1.2 and 3.5.2 require both sides
/// of every table-map pair to match: in `{* x => y}`, each key has type `x`
/// and each value has type `y`. A recursion guard must therefore not waive
/// validation of a nested pair value.
@Suite struct TableMapCandidateLocationTests {
    // MARK: - Private helpers

    private func accepts(_ schema: String, _ hex: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await expectValid(schema, hexBytes(hex), sourceLocation: sourceLocation)
    }

    private func rejects(_ schema: String, _ hex: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await expectInvalid(schema, hexBytes(hex), sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    @Test func recursiveTableValuesAreValidatedAtEveryDepth() async {
        let schema = "t = uint\nt /= {* tstr => t}\n"

        // {"k":0}, {"k":{"k":0}}, {"k":{"k":{"k":0}}}
        await accepts(schema, "a1616b00")
        await accepts(schema, "a1616ba1616b00")
        await accepts(schema, "a1616ba1616ba1616b00")

        // {"k":{"k":true}}, {"k":{"k":{"k":true}}}
        await rejects(schema, "a1616ba1616bf5")
        await rejects(schema, "a1616ba1616ba1616bf5")
    }

    @Test func recursiveTableValuesRemainCheckedBehindAnAlias() async {
        let schema = "root = t\nt = uint\nt /= {* tstr => t}\n"

        await accepts(schema, "a1616b00")
        await accepts(schema, "a1616ba1616b00")

        // Rejected at the first ill-typed value.
        await rejects(schema, "a1616bf5")
        await rejects(schema, "a1616b6178")
        await rejects(schema, "a1616ba1616bf5")
    }

    @Test func inlineRecursiveTableChoiceChecksNestedValues() async {
        let schema = "t = uint / {* tstr => t}\n"

        await accepts(schema, "a1616ba1616b00")
        await rejects(schema, "a1616ba1616bf5")
    }

    @Test func alternateOnlyRecursiveTableChecksNestedValues() async {
        let schema = "t /= uint\nt /= {* tstr => t}\n"

        await accepts(schema, "a1616b00")
        await accepts(schema, "a1616ba1616b00")

        await rejects(schema, "a1616bf5")
        await rejects(schema, "a1616b6178")
        await rejects(schema, "a1616ba1616bf5")
    }

    @Test func multipleTableArmsDoNotHideABadRecursiveValue() async {
        let schema = "t /= {* tstr => t}\nt /= {\"z\" => uint}\n"

        await rejects(schema, "a1616ba1616bf5")
    }

    @Test func nonRecursiveAndSpecificKeyMapControlsKeepTheirVerdicts() async {
        let table = "m = {* tstr => int}\n"
        await accepts(table, "a1616b01")
        await rejects(table, "a1616b6178")

        // Specific-key descent carries the pair key.
        let specific = "t = uint\nt /= {\"k\" => t}\n"
        await accepts(specific, "a1616b00")
        await accepts(specific, "a1616ba1616b00")
        await accepts(specific, "a1616ba1616ba1616b00")
        await rejects(specific, "a1616ba1616bf5")
    }
}
