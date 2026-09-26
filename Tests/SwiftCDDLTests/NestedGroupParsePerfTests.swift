import Foundation
import Testing

@testable import SwiftCDDL

/// Regression tests for exponential parse time on deeply nested arrays, and
/// for the AST shapes the linear `group_entry` ordering must not disturb.
///
/// The time bounds are loose enough for a debug build: a grammar that parses
/// a nested entry more than once per level needs seconds to minutes at these
/// depths.
@Suite struct NestedGroupParsePerfTests {
    private func nestedArray(_ depth: Int) -> String {
        "a = " + String(repeating: "[", count: depth) + "int" + String(repeating: "]", count: depth)
    }

    private func elapsed(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Best of several runs, in nanoseconds.
    private func bestParseTime(_ src: String, runs: Int) throws -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let seconds = try elapsed { _ = try cddlFromStr(src, printStderr: true) }
            best = min(best, seconds)
        }
        return max(best * 1e9, 1)
    }

    @Test func deeplyNestedArraysParseInReasonableTime() throws {
        let src = nestedArray(14)
        let seconds = try elapsed { _ = try cddlFromStr(src, printStderr: true) }
        #expect(seconds < 5, "depth-14 nested array took \(seconds)s")
    }

    /// The cost curve must stay sub-exponential.
    @Test func nestedArrayParseCostIsNotExponential() throws {
        let shallow = nestedArray(7)
        let deep = nestedArray(14)
        _ = try cddlFromStr(shallow)
        let shallowNs = try bestParseTime(shallow, runs: 5)
        let deepNs = try bestParseTime(deep, runs: 3)
        let ratio = deepNs / shallowNs
        #expect(ratio < 600, "depth 14 was \(ratio)x the cost of depth 7")
    }

    /// Nesting through the other bracketing forms stays fast too.
    @Test func deeplyNestedGroupsAndMapsParseQuickly() throws {
        let parens = "a = " + String(repeating: "(", count: 16) + "int" + String(repeating: ")", count: 16)
        var inner = "int"
        for _ in 0..<16 {
            inner = "{ k: \(inner) }"
        }
        let maps = "a = \(inner)"
        for src in [parens, maps] {
            let seconds = try elapsed { _ = try cddlFromStr(src, printStderr: true) }
            #expect(seconds < 5, "depth-16 nesting took \(seconds)s for \(src)")
        }
    }

    private func firstMemberKey(_ src: String) throws -> MemberKey? {
        let cddl = try cddlFromStr(src, printStderr: true)
        guard let t2 = firstType2(typeRule(cddl, 0)), let group = containerGroup(t2) else {
            Issue.record("expected a map or array")
            return nil
        }
        guard case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 else {
            Issue.record("expected a value member key entry")
            return nil
        }
        return ge.memberKey
    }

    @Test func colonFormsProduceBarewordOrValueKeys() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { key: int }")) == "Bareword")
        #expect(memberKeyVariant(try firstMemberKey("a = { 1: tstr }")) == "Value")
        #expect(memberKeyVariant(try firstMemberKey("a = { \"key\": int }")) == "Value")
    }

    @Test func arrowFormsProduceType1KeysAndPreserveCut() throws {
        guard case .type1(_, let isCut, _, _, _, _)? = try firstMemberKey("a = { key => int }") else {
            Issue.record("arrow key should be a Type1 key")
            return
        }
        #expect(!isCut, "plain arrow key should not be cut")

        guard case .type1(_, let cut, _, _, _, _)? = try firstMemberKey("a = { key ^ => int }") else {
            Issue.record("cut arrow key should be a Type1 key")
            return
        }
        #expect(cut, "`^ =>` must still be recorded as a cut")

        #expect(memberKeyVariant(try firstMemberKey("a = { (int / tstr) => bool }")) == "Type1")
    }

    @Test func genericArgsPickTheSameBranchForBothDelimiters() {
        #expect(throws: Never.self) { try cddlFromStr("foo<a> = [a]\nb = { foo<int> => tstr }", printStderr: true) }
        #expect(throws: Never.self) { try cddlFromStr("foo<a> = [a]\nb = [ foo<int> ]", printStderr: true) }
        #expect(throws: ParserError.self) { try cddlFromStr("foo<a> = [a]\nb = { foo<int>: tstr }") }
    }

    @Test func cutBeforeAColonIsStillRejected() {
        #expect(throws: ParserError.self) { try cddlFromStr("a = { key ^ : int }") }
    }

    @Test(arguments: [
        "a = [ int ]",
        "a = [ ? int ]",
        "a = [ * int ]",
        "a = [ 1*3 int ]",
        "g = ( x: int )\na = { g }",
        "a = [ (int, tstr) ]",
    ])
    func nonMemberEntriesStillParse(_ src: String) {
        #expect(throws: Never.self) { try cddlFromStr(src, printStderr: true) }
    }

    @Test func nestedArrayParseTimeIsLinearInDepth() throws {
        for depth in [20, 24] {
            let src = nestedArray(depth)
            let seconds = try elapsed { _ = try cddlFromStr(src, printStderr: true) }
            #expect(seconds < 1, "depth-\(depth) nested array took \(seconds)s")
        }
    }

    @Test func nestedArraysOfParenthesisedGroupsStayFast() throws {
        for depth in [12, 14] {
            var inner = "int"
            for _ in 0..<depth {
                inner = "[(\(inner))]"
            }
            let src = "a = \(inner)"
            let seconds = try elapsed { _ = try cddlFromStr(src, printStderr: true) }
            #expect(seconds < 1, "depth-\(depth) [( )] nesting took \(seconds)s")
        }
    }

    /// Doubling the depth should roughly double the cost.
    @Test func doublingNestedDepthRoughlyDoublesParseCost() throws {
        let shallow = nestedArray(8)
        let deep = nestedArray(16)
        _ = try cddlFromStr(shallow)
        let shallowNs = try bestParseTime(shallow, runs: 5)
        let deepNs = try bestParseTime(deep, runs: 5)
        let ratio = deepNs / shallowNs
        #expect(ratio < 10, "depth 16 was \(ratio)x the cost of depth 8")
    }

    @Test(arguments: [
        "g = ( x: int )\na = { g }",
        "a = { x: int }",
        "a = { x: int, y: tstr }",
        "a = [ ( x: int, y: tstr ) ]",
        "a = { x => int }",
        "a = { x ^ => int }",
        "a = ( x: int )",
        "a = ( x => int )",
        "a = { * tstr => any }",
        "a = [ * ( x: int ) ]",
    ])
    func theDelimiterGuardDoesNotStealMemberKeys(_ src: String) {
        #expect(throws: Never.self) { try cddlFromStr(src, printStderr: true) }
    }

    /// A parenthesised group entry stays a group entry.
    @Test func parenthesisedGroupEntriesAreStillGroups() throws {
        let cddl = try cddlFromStr("a = [ (int) ]", printStderr: true)
        guard case .array(let group, _, _, _)? = firstType2(typeRule(cddl, 0)),
            case .inlineGroup = group.groupChoices[0].groupEntries[0].0
        else {
            Issue.record("`(int)` inside an array must stay an inline group entry")
            return
        }
    }

    /// The guard must not consume the whitespace it looks past.
    @Test func guardLookaheadDoesNotExtendRuleSpans() throws {
        let src = "b = ( x: int ) \n a = { b }"
        let cddl = try cddlFromStr(src, printStderr: true)
        guard case .group(_, let span, _, _) = cddl.rules[0] else {
            Issue.record("expected a group rule")
            return
        }
        #expect(span.end == 14, "rule span must end at the closing paren, got \(span)")
    }

    /// Parsing and formatting run on a thread of their own with a
    /// large stack, so a schema nested far deeper than any real one is
    /// handled whatever thread the caller is on. The AST itself is released
    /// recursively on the thread that drops it, so a caller on a small stack
    /// (Swift Testing's 512 KiB cooperative threads) holds a few hundred
    /// levels.
    @Test func deeplyNestedSchemasDoNotExhaustTheStack() throws {
        let depth = 250
        let cddl = try cddlFromStr(nestedArray(depth))
        let formatted = cddl.description
        #expect(formatted.occurrences(of: "[") == depth)
        #expect(try cddlFromStr(formatted).description == formatted)

        // A thousand levels, held on a thread whose stack can release them.
        let deep = nestedArray(1000)
        let roundTrips = withLargeStack { () -> Bool in
            guard let cddl = try? cddlFromStr(deep) else { return false }
            let formatted = cddl.description
            return (try? cddlFromStr(formatted).description) == formatted
        }
        #expect(roundTrips)
    }

    /// Formatting renders each group choice once, so its cost is polynomial
    /// in the nesting depth (rendering the first choice of every group twice
    /// would double the cost per level).
    @Test func formattingNestedArraysIsNotExponential() throws {
        let cddl = try cddlFromStr(nestedArray(60))
        let seconds = elapsed { _ = cddl.description }
        #expect(seconds < 5, "formatting depth 60 took \(seconds)s")
    }
}
