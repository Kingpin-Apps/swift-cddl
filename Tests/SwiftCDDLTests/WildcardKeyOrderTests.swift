import Testing

@testable import SwiftCDDL

/// Wildcard map entries (RFC 8610 Section 3.5.2 and Appendix C) do not
/// depend on the order they are written in: a key one entry cannot claim is
/// left for a later entry, and only keys no entry claims are an error.
@Suite struct WildcardKeyOrderTests {
    // MARK: - Private helpers

    /// `{"a": 1, 2: 3}`
    private static let mixedMap = "a26161010203"

    private func validates(_ cddl: String, _ hex: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await cborResult(cddl, hexBytes(hex), sourceLocation: sourceLocation) == nil
    }

    // MARK: - Tests

    @Test func wildcardEntryOrderIsIrrelevant() async {
        #expect(await validates("start = { * tstr => int, * int => int }", Self.mixedMap))
        #expect(await validates("start = { * int => int, * tstr => int }", Self.mixedMap))
    }

    @Test func wildcardEntryOrderIsIrrelevantForThreeKeyTypes() async {
        // {"a": 1, 2: 3, true: 4}
        let m = "a36161010203f504"

        #expect(await validates("start = { * tstr => int, * int => int, * bool => int }", m))
        #expect(await validates("start = { * bool => int, * tstr => int, * int => int }", m))
        #expect(await validates("start = { * int => int, * bool => int, * tstr => int }", m))
    }

    @Test func unclaimedKeysAreStillRejected() async {
        // No entry can claim the integer key 2.
        #expect(await !validates("start = { * tstr => int }", Self.mixedMap))
        // No entry can claim the text key "a".
        #expect(await !validates("start = { * int => int }", Self.mixedMap))
    }

    @Test func wildcardEntriesStillEnforceTheValueType() async {
        // {"a": "a"} against * tstr => int
        #expect(await !validates("start = { * tstr => int }", "a161616161"))
        #expect(await validates("start = { * tstr => int }", "a1616101"))
    }

    @Test func wildcardOccurrenceBoundsArePreserved() async {
        // {} is fine for `*` but not for `+`.
        #expect(await validates("start = { * tstr => int }", "a0"))
        #expect(await !validates("start = { + tstr => int }", "a0"))
    }
}
