import Testing

@testable import SwiftCDDL

/// Map entries claim complete key/value pairs (RFC 8610 Appendix C), not keys
/// in isolation: a table claims a pair only when both its key type and its
/// value type match.
@Suite struct MapTableCompletePairClaimsTests {
    // MARK: - Private helpers

    private func accepts(_ schema: String, _ hex: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await expectValid(schema, hexBytes(hex), sourceLocation: sourceLocation)
    }

    private func rejects(_ schema: String, _ hex: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await expectInvalid(schema, hexBytes(hex), sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    @Test func repeatingTablesClaimOnlyCompleteKeyValueMatches() async {
        // The broad table cannot claim this pair because its value is not a
        // uint, so the later specific member remains able to own it.
        // {"extra":"hi"}
        await accepts("m = { * any => uint, extra: tstr }", "a1656578747261626869")

        // Two tables with the same key domain can partition pairs by value
        // type. {"a":"x","b":1}
        await accepts("m = { * any => uint, * any => tstr }", "a261616178616201")

        // The specific-before-general order remains valid.
        // {"extra":"hi","b":1}
        await accepts("m = { extra: tstr, * any => uint }", "a2656578747261626869616201")
    }

    @Test func occurrenceBoundsCountSuccessfulPairMatches() async {
        // The upper bound applies after complete-pair probing. The first
        // candidate fails the uint value type, but probing continues until one
        // compatible pair has been found; the later table then owns the
        // text-valued pair.
        await accepts("m = { 1*1 any => uint, * any => tstr }", "a261616178616201")

        // A lower bound is likewise based on complete pairs, not key
        // candidates. {"a":"x"}
        await rejects("m = { + any => uint, * any => tstr }", "a161616178")
    }

    @Test func completePairClaimsPreserveGreedyAndCutBehavior() async {
        // A compatible pair is greedily claimed by the first table. A later
        // required member cannot reuse it. {"extra":1}
        await rejects("m = { * any => uint, extra: uint }", "a165657874726101")

        // With no compatible owner, a bad table value remains invalid.
        await rejects("m = { * any => uint }", "a161616178")

        // The colon shortcut carries a cut (RFC 8610 Section 3.5.4). Once its
        // key matches, a later table must not rescue its bad value.
        await rejects("m = { extra: uint, * any => tstr }", "a1656578747261626869")
    }
}
