import Foundation
import Testing

@testable import SwiftCDDL

// Unit tests of the CBOR validator (RFC 8610 against RFC 8949 data items),
// third part: the work budget, reported limits, error reports, prelude names,
// controls and member keys.

/// Whether `node` matches `cddl`.
private func acceptsNode(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    await nodeResult(cddl, node, sourceLocation: sourceLocation) == nil
}

/// A validator of `node` against the schema `cddl`.
private func reportingValidator(_ cddl: String, _ node: CBORNode) throws -> CBORValidator {
    CBORValidator(cddl: try cddlFromStr(cddl), cbor: node)
}

/// Runs `validator`, returning the failure or `nil` when the document matched.
private func reportingVerdict(_ validator: CBORValidator) async -> CBORVerdict {
    do {
        try await validator.validate()
        return nil
    } catch {
        return error
    }
}

/// The rendered text of a failure, or the empty string for a match.
private func renderedVerdict(_ verdict: CBORVerdict) -> String {
    verdict.map { "\($0)" } ?? ""
}

/// An array of the unsigned integers `0..<count`.
private func countingArray(_ count: UInt64) -> CBORNode {
    .array((0..<count).map { .unsigned($0) })
}

/// Whether a run completed within `budget`, told apart from a run that
/// completed and found a mismatch: only the budget is under test here.
private func validatesWithin(
    _ cddl: String,
    _ node: CBORNode,
    _ budget: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    let validator: CBORValidator
    do {
        validator = try reportingValidator(cddl, node)
    } catch {
        Issue.record("schema does not parse: \(error)", sourceLocation: sourceLocation)
        return false
    }
    validator.setMaxValidationWork(budget)

    switch await reportingVerdict(validator) {
    case nil:
        return true
    case .validation(let errors):
        return !errors.contains { $0.reason.contains("steps of validation work") }
    case let other?:
        Issue.record("unexpected failure: \(other)", sourceLocation: sourceLocation)
        return false
    }
}

/// The steps one run spends: the smallest budget it completes on.
private func smallestBudgetThatReturns(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Int {
    var low = 0
    var high = 1_000_000
    #expect(
        await validatesWithin(cddl, node, high, sourceLocation: sourceLocation),
        "the run does not complete within the search ceiling",
        sourceLocation: sourceLocation
    )
    while low < high {
        let middle = low + (high - low) / 2
        if await validatesWithin(cddl, node, middle, sourceLocation: sourceLocation) {
            high = middle
        } else {
            low = middle + 1
        }
    }
    return low
}

/// The distinct locations of the errors `node` is reported with against
/// `cddl`, sorted.
private func errorLocations(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> [String] {
    let verdict = await nodeResult(cddl, node, comparePaths: true, sourceLocation: sourceLocation)
    let locations = issues(verdict, sourceLocation: sourceLocation).map(\.cborLocation)
    return Array(Set(locations)).sorted()
}

/// Schemas whose only failure sits two levels into the data, reached through a
/// rule that describes the item already held. Each is completed by a size.
private let nestedFailureSchemas: [(String, String)] = [
    // A generic rule whose body is a type choice, reached from an array entry.
    ("t = [a, uint]\na = set<i>\nset<a0> = #6.258([* a0]) / [* a0]\ni = bytes .size ", "\n"),
    // The same rule reached from a map value.
    ("t = { k: a }\na = set<i>\nset<a0> = #6.258([* a0]) / [* a0]\ni = bytes .size ", "\n"),
    // The same rule one array level further in.
    ("t = [[a], uint]\na = set<i>\nset<a0> = #6.258([* a0]) / [* a0]\ni = bytes .size ", "\n"),
    // A generic rule with no choice at all: the level is lost by resolving the
    // rule, not by crossing the choice.
    ("t = [a, uint]\na = wrap<i>\nwrap<a0> = [* a0]\ni = bytes .size ", "\n"),
    // A type choice one of whose alternatives is itself a type choice.
    ("t = [outer]\nouter = inner / uint\ninner = [* i] / tstr\ni = bytes .size ", "\n"),
]

private func nestedFailureSchema(_ index: Int, _ size: Int) -> String {
    let (head, tail) = nestedFailureSchemas[index]
    return "\(head)\(size)\(tail)"
}

/// A map holding one entry, and the same map placed as the value of a map
/// entry and as the item of an array, so that a member key can be held to the
/// keys it answers for at every depth. Each schema shape has `{}` where the
/// map type under test goes.
private func mapPlacements(_ key: CBORNode, _ value: CBORNode) -> [(String, CBORNode)] {
    let entry = CBORNode.map([(key: key, value: value)])
    return [
        ("a = {}", entry),
        ("a = { k: {} }", .map([(key: .text("k"), value: entry)])),
        ("a = [{}]", .array([entry])),
    ]
}

/// Tests of the CBOR validator's work budget, limits, error reports, prelude
/// names, controls and member keys.
@Suite struct CBORValidatorUnitTestsReporting {
    /// A type choice whose alternatives cannot be told apart at the head of the
    /// data item evaluates each of them in turn, and each one that descends
    /// walks everything below it again, so the alternatives multiply level by
    /// level. Neither bound on nesting reaches that product: the document here
    /// nests well inside both, and the walk it asks for is two to the power of
    /// its depth.
    ///
    /// The run stops at the work bound and says so, rather than running to a
    /// verdict no caller is still waiting for.
    @Test func validateChoiceAlternativesThatAllDescendStopAtTheWorkBound() async throws {
        // Every level offers two alternatives that both descend, and the leaf
        // matches none of the three, so every level above it is walked twice
        // over.
        var node = CBORNode.text("no alternative admits this")
        // Two to the fortieth steps is beyond any wall clock; the budget is
        // what has to stop it, and the depth is inside both nesting bounds.
        for _ in 0..<40 {
            node = .array([node])
        }

        let validator = try reportingValidator("x = a / b / uint\na = [x]\nb = [x]\n", node)
        validator.setMaxValidationWork(50_000)
        let verdict = await reportingVerdict(validator)
        #expect(verdict != nil, "the walk is exponential in the depth")
        #expect(renderedVerdict(verdict).contains("steps of validation work"), "got:\n\(renderedVerdict(verdict))")
    }

    /// The budget belongs to the run, not to the level of the walk holding it:
    /// a step into nested data walks a level of its own and every alternative
    /// of a choice is evaluated on a copy, so a budget carried per level would
    /// be a budget per alternative and would bound nothing a choice multiplies.
    ///
    /// Two documents of the same shape, one twice the other, are put to the
    /// same schema under a budget that fits the smaller: the larger has to
    /// exhaust it.
    @Test func theWorkBudgetIsSpentOverTheWholeRun() async {
        let cddl = "x = [* uint]"

        let cost = await smallestBudgetThatReturns(cddl, countingArray(16))
        // Twice the items, so about twice the steps: what the first half spent
        // is not there for the second half to spend again.
        #expect(
            await smallestBudgetThatReturns(cddl, countingArray(32)) > cost,
            "a document twice the size cost no more than the budget the half of it did"
        )
    }

    /// The boundary: a run that costs exactly the budget it is given completes,
    /// and the same run one step short of it does not.
    @Test func aRunCostingExactlyTheBudgetCompletes() async {
        let cddl = "x = [* uint]"
        let document = countingArray(8)

        let cost = await smallestBudgetThatReturns(cddl, document)
        #expect(cost > 1, "the run has to cost something to have a boundary")

        #expect(await validatesWithin(cddl, document, cost))
        #expect(!(await validatesWithin(cddl, document, cost - 1)))
    }

    /// A validator reports the limits it runs under, so a caller that raised
    /// them can tell what it is holding the data to.
    @Test func validatorReportsTheLimitsItRunsUnder() throws {
        let validator = try reportingValidator("p = int", .unsigned(1))

        #expect(validator.limits == ValidationLimits())

        var limits = ValidationLimits()
        limits.maxNestingDepth = 7
        validator.setLimits(limits)
        #expect(validator.limits.maxNestingDepth == 7)
        #expect(validator.limits.maxRuleNesting == ValidationLimits.defaultMaxRuleNesting)
        #expect(validator.limits.maxDescentCost == ValidationLimits.defaultMaxDescentCost)
        #expect(validator.limits.dataLevelCost == ValidationLimits.defaultDataLevelCost)
        #expect(validator.limits.ruleHopCost == ValidationLimits.defaultRuleHopCost)
        #expect(validator.limits.maxValidationWork == ValidationLimits.defaultMaxValidationWork)

        // The individual setters and the limits struct name the same bounds.
        validator.setMaxRuleNesting(9)
        validator.setMaxDescentCost(10)
        validator.setDescentWeights(dataLevelCost: 12, ruleHopCost: 13)
        validator.setMaxValidationWork(11)
        validator.setMaxEmbeddedDepth(14)
        validator.setMaxReportBytes(15)
        #expect(
            validator.limits
                == ValidationLimits(
                    maxNestingDepth: 7,
                    maxRuleNesting: 9,
                    maxDescentCost: 10,
                    dataLevelCost: 12,
                    ruleHopCost: 13,
                    maxValidationWork: 11,
                    maxEmbeddedDepth: 14,
                    maxReportBytes: 15
                )
        )
    }

    /// The type an entry names is the type of the values of the entries its
    /// member key accounts for, and a value failing it is reported against the
    /// key it is held under.
    @Test func validateMapRangeMemberKeyEntryValue() async {
        let cddl = "p = {* 3..255 => int}"

        #expect(
            await acceptsNode(cddl, .map([(key: .unsigned(3), value: .unsigned(1)), (key: .unsigned(4), value: .unsigned(1))]))
        )
        #expect(
            !(await acceptsNode(cddl, .map([(key: .unsigned(3), value: .text("x")), (key: .unsigned(4), value: .text("x"))])))
        )

        let node = CBORNode.map([
            (key: .unsigned(3), value: .unsigned(1)),
            (key: .unsigned(4), value: .text("x")),
            (key: .unsigned(5), value: .unsigned(2)),
        ])
        let errors = issues(await nodeResult(cddl, node, comparePaths: true))
        #expect(errors.count == 1)
        #expect(errors.first?.cborLocation == "/4")
    }

    /// A group choice whose alternatives each descend into the same nested
    /// data must not re-examine that data once per alternative: the work an
    /// alternative that has already failed would go on to do is discarded
    /// whole, and repeating it at every level is exponential in the nesting
    /// depth.
    ///
    /// Error count stands in for the work done. It grows with the depth of the
    /// document, so the walk is held to a bound linear in that depth rather
    /// than to a constant.
    @Test func validateFailingGroupChoiceDoesNotReExamineNestedDataPerAlternative() async {
        let cddl = """
            nested = [leaf // all // any]
            leaf = (0, bstr)
            all = (1, [* nested])
            any = (2, [* nested])
            """

        // [1, [1, [ ... [1, [[0, 0]]] ... ]]]: every level matches `all` and
        // only the leaf fails, so every level of every alternative is reached.
        var node = CBORNode.array([.unsigned(0), .unsigned(0)])
        let depth = 12
        for _ in 0..<depth {
            node = .array([.unsigned(1), .array([node])])
        }

        let errors = issues(await nodeResult(cddl, node))
        #expect(!errors.isEmpty, "expected the nested leaf to be rejected")
        #expect(
            errors.count < 16 * depth,
            "walked the document \(errors.count) times over, which is more than the nesting admits"
        )
    }

    /// Stopping a failed alternative early must not stop the choice from
    /// reaching the alternative that matches, wherever it stands among them.
    @Test func validateGroupChoiceStillReachesALaterMatchingAlternative() async {
        let cddl = """
            nested = [leaf // all // any]
            leaf = (0, bstr)
            all = (1, [* nested])
            any = (2, [* nested])
            """

        // The leaf matches the first alternative, the levels above it the
        // second and third in turn.
        let leaf = CBORNode.array([.unsigned(0), .bytes([1])])
        let any = CBORNode.array([.unsigned(2), .array([leaf])])
        let all = CBORNode.array([.unsigned(1), .array([any])])

        #expect(await acceptsNode(cddl, leaf))
        #expect(await acceptsNode(cddl, all))

        // The same document with the leaf made invalid is still rejected.
        let badLeaf = CBORNode.array([.unsigned(0), .unsigned(0)])
        let bad = CBORNode.array([.unsigned(1), .array([.array([.unsigned(2), .array([badLeaf])])])])
        #expect(!(await acceptsNode(cddl, bad)))
    }

    /// A group with one alternative is not one way of matching among several,
    /// so every entry of it still answers for its own position and every
    /// failure is reported.
    @Test func validateSingleAlternativeGroupReportsEveryFailingEntry() async {
        let node = CBORNode.array([.text("x"), .unsigned(1), .text("y")])
        let errors = issues(await nodeResult("a = [uint, tstr, bool]", node, comparePaths: true))
        #expect(errors.count == 3)
    }

    /// An error message names the data item that failed to match. Naming it
    /// must cost a bounded amount whatever the document holds, and must still
    /// name a small item in full.
    @Test func validateErrorMessageRendersALargeDataItemWithinTheBound() async {
        func reason(for node: CBORNode) async -> String {
            issues(await nodeResult("a = tstr", node)).first?.reason ?? ""
        }

        // The small item is named in full, ellipsis and all absent.
        let small = await reason(for: .array([.unsigned(1)]))
        #expect(small.contains("Array([Integer(Integer(1))])"), "got:\n\(small)")
        #expect(!small.hasSuffix("..."), "got:\n\(small)")

        // The large one is named up to the bound and no further.
        let large = await reason(for: countingArray(4096))
        #expect(large.hasSuffix("..."), "got:\n\(large)")
        #expect(
            large.utf8.count < maxRenderedDataLength * 2,
            "the message grew with the document: \(large.utf8.count) bytes"
        )
    }

    /// Bounds of different kinds do not denote a range (RFC 8610 Section 3.8.4
    /// for ranges), so a member key written as one names no set of keys. The
    /// fault is in the schema and has to be reported as one, including when
    /// the map holds no key to ask about, which would otherwise look like a
    /// match.
    @Test func validateMemberKeyRangeWithBoundsOfDifferentKindsIsASchemaError() async throws {
        func reason(_ cddl: String, _ node: CBORNode) async throws -> String {
            let validator = try reportingValidator(cddl, node)
            switch await reportingVerdict(validator) {
            case nil:
                return ""
            case .validation(let errors):
                return errors.first?.reason ?? ""
            case let other?:
                Issue.record("expected a report, got \(other)")
                return ""
            }
        }

        for node: CBORNode in [.map([]), .map([(key: .unsigned(2), value: .unsigned(1))])] {
            let memberKeyReason = try await reason("a = {* 1.5..3 => int}", node)
            #expect(
                memberKeyReason.contains("must both be integers or both be floats"),
                "got:\n\(memberKeyReason)"
            )

            // The same fault the non-member-key path reports.
            let typeReason = try await reason("a = 1.5..3", .unsigned(2))
            #expect(typeReason.contains("must both be integers or both be floats"), "got:\n\(typeReason)")
        }

        // Bounds of one kind denote a range, whether or not any key falls in it.
        #expect(await acceptsNode("a = {* 1..3 => int}", .map([])))
        #expect(await acceptsNode("a = {* 1.5..3.5 => int}", .map([])))
        #expect(await acceptsNode("a = {* 1..3 => int}", .map([(key: .unsigned(2), value: .unsigned(1))])))
    }

    /// A prelude name standing for tagged types (RFC 8610 Appendix D) is a
    /// choice over them. What the data item is held to is the name, so a
    /// mismatch names the name written in the schema and not one of the types
    /// it is a choice over.
    @Test func validatePreludeTagNameMismatchNamesTheNameInTheSchema() async throws {
        func reason(_ cddl: String, _ node: CBORNode) async throws -> String {
            let validator = try reportingValidator(cddl, node)
            switch await reportingVerdict(validator) {
            case nil:
                return ""
            case .validation(let errors):
                return errors.map(\.reason).joined(separator: " | ")
            case let other?:
                Issue.record("expected a report, got \(other)")
                return ""
            }
        }

        let unknownTag = CBORNode.tagged(99, .bytes([1]))

        for name in ["bigint", "biguint", "bignint", "integer", "unsigned", "decfrac", "bigfloat"] {
            let reported = try await reason("a = \(name)", unknownTag)
            #expect(reported.contains("expected type \(name)"), "\(name) reported:\n\(reported)")
            #expect(
                !reported.contains("expected tagged data"),
                "\(name) named a type the schema does not mention:\n\(reported)"
            )
        }

        // A candidate carrying the tag the item does carry still answers for
        // what it encloses, which is the more precise thing to report.
        let reported = try await reason("a = bigint", .tagged(2, .unsigned(5)))
        #expect(reported.contains("expected type bstr"), "got:\n\(reported)")

        // What the name admits is still admitted.
        #expect(await acceptsNode("a = bigint", .tagged(2, .bytes([1]))))
        #expect(await acceptsNode("a = bigint", .tagged(3, .bytes([1]))))
        #expect(await acceptsNode("a = decfrac", .tagged(4, .array([.unsigned(1), .unsigned(2)]))))
    }

    /// The integer prelude names differ in the sign they admit. A name that
    /// constrains the sign settles the question on its own: a value it
    /// excludes must not be admitted by the broader name it is defined in terms
    /// of.
    @Test func validateIntegerPreludeNamesHoldToTheSignTheyAdmit() async {
        let negative = CBORNode.integer(-1)
        let zero = CBORNode.unsigned(0)
        let positive = CBORNode.unsigned(1)

        for name in ["uint", "unsigned"] {
            let cddl = "a = \(name)"
            #expect(!(await acceptsNode(cddl, negative)), "\(name) admits -1")
            #expect(await acceptsNode(cddl, zero), "\(name) rejects 0")
            #expect(await acceptsNode(cddl, positive), "\(name) rejects 1")
        }

        #expect(await acceptsNode("a = nint", negative))
        #expect(!(await acceptsNode("a = nint", zero)), "nint admits 0")
        #expect(!(await acceptsNode("a = nint", positive)), "nint admits 1")

        for name in ["int", "integer", "number"] {
            let cddl = "a = \(name)"
            #expect(await acceptsNode(cddl, negative), "\(name) rejects -1")
            #expect(await acceptsNode(cddl, positive), "\(name) rejects 1")
        }

        // A name reached through another name is held to the same constraint.
        #expect(!(await acceptsNode("b = uint\na = b", negative)))
        #expect(!(await acceptsNode("b = nint\na = b", positive)))

        // A name standing for a choice between them admits either.
        #expect(await acceptsNode("a = uint / nint", negative))
        #expect(await acceptsNode("a = uint / nint", positive))
    }

    /// RFC 9741 Section 2.1: the text is the encoding of the byte string given
    /// as the controller, so a match asks that the decoded bytes are that byte
    /// string entire and not merely a prefix of it. The sloppy variants relax
    /// one requirement only, that the bits the final symbol carries beyond the
    /// encoded data are zero; the alphabet, the length and the padding rule of
    /// the strict variant continue to hold.
    @Test func validateB64SloppyRelaxesOnlyTheTrailingBits() async {
        let sloppyU = "a = tstr .b64u-sloppy h'68656c6c6f20776f726c64'"
        let sloppyC = "a = tstr .b64c-sloppy h'68656c6c6f20776f726c64'"
        let strictU = "a = tstr .b64u h'68656c6c6f20776f726c64'"
        let strictC = "a = tstr .b64c h'68656c6c6f20776f726c64'"

        // The canonical encoding holds, as it does under the strict variants.
        #expect(await acceptsNode(sloppyU, .text("aGVsbG8gd29ybGQ")))
        #expect(await acceptsNode(sloppyC, .text("aGVsbG8gd29ybGQ=")))

        // Eleven bytes end in a group of three symbols, which carries two bits
        // beyond the encoded data. "aGVsbG8gd29ybGR" sets them and encodes the
        // same eleven bytes: the strict variants reject it, the sloppy ones do
        // not.
        #expect(!(await acceptsNode(strictU, .text("aGVsbG8gd29ybGR"))))
        #expect(!(await acceptsNode(strictC, .text("aGVsbG8gd29ybGR="))))
        #expect(await acceptsNode(sloppyU, .text("aGVsbG8gd29ybGR")))
        #expect(await acceptsNode(sloppyC, .text("aGVsbG8gd29ybGR=")))

        // One byte ends in a group of two symbols, which carries four such bits.
        #expect(!(await acceptsNode("a = tstr .b64u h'01'", .text("AR"))))
        #expect(await acceptsNode("a = tstr .b64u-sloppy h'01'", .text("AQ")))
        #expect(await acceptsNode("a = tstr .b64u-sloppy h'01'", .text("AR")))
        #expect(await acceptsNode("a = tstr .b64c-sloppy h'01'", .text("AQ==")))
        #expect(await acceptsNode("a = tstr .b64c-sloppy h'01'", .text("AR==")))
        // Those four bits are all that is relaxed: the encoded byte still counts.
        #expect(!(await acceptsNode("a = tstr .b64u-sloppy h'01'", .text("Ag"))))

        // Text that decodes to a proper prefix of the byte string is not the
        // encoding of that byte string, whatever its length.
        for truncation in ["", "Z", "aGVsbG8g", "aGVsbG8gd", "aGVsbG8gd29yb"] {
            #expect(!(await acceptsNode(sloppyU, .text(truncation))), ".b64u-sloppy admits \"\(truncation)\"")
            #expect(!(await acceptsNode(sloppyC, .text(truncation))), ".b64c-sloppy admits \"\(truncation)\"")
        }

        // The padding rule each operator names still holds: base64url carries
        // no padding, base64 classic carries it.
        #expect(!(await acceptsNode(sloppyU, .text("aGVsbG8gd29ybGQ="))))
        #expect(!(await acceptsNode(sloppyC, .text("aGVsbG8gd29ybGQ"))))

        // So does the alphabet each operator names.
        #expect(!(await acceptsNode("a = tstr .b64u-sloppy h'6865ff6f'", .text("aGX/bw"))))
        #expect(!(await acceptsNode("a = tstr .b64c-sloppy h'6865ff6f'", .text("aGX_bw=="))))
    }

    /// RFC 8610 Section 2.2.3: `#6(t)` leaves the tag number unspecified, so a
    /// tagged data item of any tag number holds and only the item the tag
    /// encloses is in question. `#6.n(t)` states the number and holds the item
    /// to it.
    @Test func validateTaggedDataWithoutATagNumberAdmitsAnyTagNumber() async {
        func tagged(_ number: UInt64) -> CBORNode {
            .tagged(number, .text("x"))
        }

        for number: UInt64 in [0, 1, 24, 1004, UInt64.max] {
            #expect(await acceptsNode("a = #6(tstr)", tagged(number)), "#6(tstr) rejects tag \(number)")
        }

        // The enclosed data item is still held to the type it is given.
        #expect(!(await acceptsNode("a = #6(tstr)", .tagged(24, .unsigned(1)))))

        // A data item carrying no tag at all is not a tagged data item.
        #expect(!(await acceptsNode("a = #6(tstr)", .text("x"))))

        // A stated tag number is still held to.
        #expect(await acceptsNode("a = #6.24(tstr)", tagged(24)))
        #expect(!(await acceptsNode("a = #6.24(tstr)", tagged(25))))
    }

    /// A member key written as a type name asks that the keys it is matched
    /// against be of that type. Under a repeating occurrence it is matched
    /// against every key of the map, so a key of another type is a failure of
    /// the map however many keys of the right type stand beside it.
    @Test func validateMapKeyTypeUnderAnOccurrenceHoldsEveryKey() async {
        let value = CBORNode.text("v")

        // (member key type, a key of that type, a key that is not)
        let cases: [(String, CBORNode, CBORNode)] = [
            ("tstr", .text("k"), .unsigned(1)),
            ("uint", .unsigned(1), .text("x")),
            ("bool", .bool(true), .text("x")),
            ("bstr", .bytes([1, 2]), .text("x")),
            ("nil", .null, .text("x")),
            ("float", .float(1.5), .text("x")),
            ("int", .integer(-1), .text("x")),
        ]

        for (keyType, conforming, other) in cases {
            for occurrence in ["*", "+"] {
                let cddl = "a = { \(occurrence) \(keyType) => tstr }"

                #expect(
                    await acceptsNode(cddl, .map([(key: conforming, value: value)])),
                    "\(cddl) rejects a map whose only key is of that type"
                )

                let mixed = CBORNode.map([(key: conforming, value: value), (key: other, value: value)])
                #expect(
                    !(await acceptsNode(cddl, mixed)),
                    "\(cddl) admits a map holding a key of another type"
                )

                #expect(
                    !(await acceptsNode(cddl, .map([(key: other, value: value)]))),
                    "\(cddl) admits a map whose only key is of another type"
                )
            }
        }
    }

    /// Every mismatch names the data item it was found in.
    ///
    /// A rule resolved against the item already held (the instantiation of a
    /// generic rule among them) describes that same item, so it reports from
    /// the same location; a rule resolved against an item nested inside it
    /// reports from that item's own location. Naming the item one level out,
    /// or the root of the document, points at data that did not fail, and each
    /// alternative of a choice reports from where that alternative got to
    /// rather than from where the choice was entered.
    @Test func validateReportsEachErrorAtTheItemItWasFoundIn() async {
        let oneByteArray = CBORNode.array([.bytes([0])])

        let cases: [(Int, CBORNode, [String])] = [
            (0, .array([oneByteArray, .unsigned(1)]), ["/0", "/0/0"]),
            (1, .map([(key: .text("k"), value: oneByteArray)]), ["/\"k\"", "/\"k\"/0"]),
            (2, .array([.array([oneByteArray]), .unsigned(1)]), ["/0/0", "/0/0/0"]),
            (3, .array([oneByteArray, .unsigned(1)]), ["/0/0"]),
            (4, .array([oneByteArray]), ["/0", "/0/0"]),
        ]

        for (index, node, expected) in cases {
            let cddl = nestedFailureSchema(index, 32)
            #expect(await errorLocations(cddl, node) == expected, "wrong locations for:\n\(cddl)")
        }
    }

    /// The data those schemas do admit is still admitted, tagged or not.
    @Test func validateAdmitsTheDataTheNestedRulesDescribe() async {
        let oneByteArray = CBORNode.array([.bytes([0])])
        let tagged = CBORNode.tagged(258, oneByteArray)

        let cases: [(Int, CBORNode)] = [
            (0, .array([oneByteArray, .unsigned(1)])),
            (0, .array([tagged, .unsigned(1)])),
            (1, .map([(key: .text("k"), value: oneByteArray)])),
            (2, .array([.array([oneByteArray]), .unsigned(1)])),
            (3, .array([oneByteArray, .unsigned(1)])),
            (4, .array([oneByteArray])),
            (4, .array([.unsigned(1)])),
        ]

        for (index, node) in cases {
            let cddl = nestedFailureSchema(index, 1)
            #expect(await acceptsNode(cddl, node), "\(cddl) rejects data it describes")
        }
    }

    /// RFC 8610 Appendix C: a name standing alone as a group entry is resolved
    /// by looking it up. A name that denotes a group is inlined, so each of
    /// that group's entries takes an item of the enclosing array; a name that
    /// denotes a type stands for a single item.
    @Test func arrayEntryNameIsInlinedOnlyWhenItDenotesAGroup() async {
        let group = "arr = [pair, pair]\npair = (int, text)"
        #expect(await acceptsNode(group, .array([.unsigned(1), .text("a"), .unsigned(2), .text("b")])))
        #expect(!(await acceptsNode(group, .array([.unsigned(1), .text("a")]))))

        let type = "arr = [*cap]\ncap = {}"
        #expect(await acceptsNode(type, .array([.map([]), .map([])])))
        #expect(!(await acceptsNode(type, .array([.unsigned(1)]))))
    }

    /// RFC 8610 Section 3.8.6: `.ne` states that the data item is not the value
    /// its controller denotes. A controller that denotes a type denotes every
    /// value of that type, so the exclusion holds exactly when the data item is
    /// none of them, which is the negation of what `.eq` states over the same
    /// controller.
    @Test func exclusionNegatesMembershipOfTheController() async {
        // A controller denoting a single value.
        #expect(await acceptsNode("root = tstr .ne \"y\"", .text("x")))
        #expect(!(await acceptsNode("root = tstr .ne \"x\"", .text("x"))))
        #expect(await acceptsNode("root = tstr .eq \"x\"", .text("x")))
        #expect(!(await acceptsNode("root = tstr .eq \"y\"", .text("x"))))

        // A controller denoting a type.
        #expect(await acceptsNode("root = tstr .ne uint", .text("x")))
        #expect(!(await acceptsNode("root = tstr .ne tstr", .text("x"))))
        #expect(await acceptsNode("root = tstr .eq tstr", .text("x")))
        #expect(!(await acceptsNode("root = any .eq tstr", .unsigned(3))))

        // A controller reached through a rule name denotes what the rule
        // denotes.
        #expect(await acceptsNode("root = tstr .ne c\nc = uint", .text("x")))
        #expect(!(await acceptsNode("root = tstr .ne c\nc = tstr", .text("x"))))

        // A target that is not a numeric or string type is one `.ne` is defined
        // for all the same.
        #expect(await acceptsNode("root = bool .ne true", .bool(false)))
        #expect(!(await acceptsNode("root = bool .ne true", .bool(true))))
    }

    /// RFC 9165 Section 2.2: `.cat` stands for the value it computes from its
    /// two operands, so a target that denotes no value leaves it nothing to
    /// compute. The schema is then unusable whatever the document holds,
    /// including a document the target's own name would have turned away.
    @Test func computingOperatorReportsAnUnusableTargetAsASchemaFault() async throws {
        for document: CBORNode in [.text("x"), .unsigned(3)] {
            let validator = try reportingValidator("root = bstr .cat \"x\"", document)
            let verdict = await reportingVerdict(validator)
            if case .invalidSchema(let issue) = verdict {
                #expect(issue.reason.contains("target of"), "\(issue.reason)")
            } else {
                Issue.record("expected a schema fault, got \(renderedVerdict(verdict))")
            }
        }

        // Operands that do denote values keep the operator on the data channel.
        #expect(await acceptsNode("root = \"a\" .cat \"b\"", .text("ab")))
        #expect(!(await acceptsNode("root = \"a\" .cat \"b\"", .text("ac"))))
    }

    /// RFC 8610 Appendix D defines `number = int / float`, so a member key
    /// naming it answers for a key written either way. The major type the name
    /// is filed under does not settle which keys it answers for, and a name
    /// standing for the same type states the same thing.
    @Test func validateNumberMemberKeyAdmitsAKeyOfEitherNumericKind() async {
        for memberKey in ["number", "n"] {
            let prelude = memberKey == "n" ? "\nn = number" : ""

            for occurrence in ["*", "+", "1*", ""] {
                let entry = "{ \(occurrence) \(memberKey) => uint }"

                for key: CBORNode in [.unsigned(5), .integer(-2), .float(1.5), .float(-1.5)] {
                    for (shape, node) in mapPlacements(key, .unsigned(0)) {
                        let cddl = shape.replacingOccurrences(of: "{}", with: entry) + prelude
                        #expect(await acceptsNode(cddl, node), "\(cddl) rejects a map keyed by \(key)")
                    }
                }

                // A key that is not a number is one the entry does not answer for.
                for key: CBORNode in [.text("x"), .bool(true)] {
                    for (shape, node) in mapPlacements(key, .unsigned(0)) {
                        let cddl = shape.replacingOccurrences(of: "{}", with: entry) + prelude
                        #expect(!(await acceptsNode(cddl, node)), "\(cddl) admits a map keyed by \(key)")
                    }
                }
            }
        }
    }

    /// `uint` and `unsigned` admit no negative integer and `nint` admits only
    /// negative ones (RFC 8610 Appendix D), and a member key naming one of them
    /// answers for exactly the keys the name admits.
    @Test func validateIntegerMemberKeyKeepsTheSignTheNameStates() async {
        // (member key type, a key of that type, a key that is not)
        let cases: [(String, CBORNode, CBORNode)] = [
            ("uint", .unsigned(5), .integer(-2)),
            ("unsigned", .unsigned(5), .integer(-2)),
            ("nint", .integer(-2), .unsigned(5)),
            ("float", .float(1.5), .unsigned(5)),
            ("int", .integer(-2), .float(1.5)),
        ]

        for (memberKey, admitted, refused) in cases {
            for occurrence in ["*", "+", "1*", ""] {
                let entry = "{ \(occurrence) \(memberKey) => uint }"

                for (shape, node) in mapPlacements(admitted, .unsigned(0)) {
                    let cddl = shape.replacingOccurrences(of: "{}", with: entry)
                    #expect(await acceptsNode(cddl, node), "\(cddl) rejects a map keyed by \(admitted)")
                }

                for (shape, node) in mapPlacements(refused, .unsigned(0)) {
                    let cddl = shape.replacingOccurrences(of: "{}", with: entry)
                    #expect(!(await acceptsNode(cddl, node)), "\(cddl) admits a map keyed by \(refused)")
                }
            }
        }
    }

    /// RFC 8610 Section 3.8.6 states equality for tagged values and for the
    /// values of every other type the generic data model holds, so a target of
    /// any kind is held to and the controller then decides equality against
    /// the value the data item turned out to be.
    @Test func validateEqualityControlAgainstATaggedOrUnwrappedTarget() async {
        func tagged(_ number: UInt64) -> CBORNode {
            .tagged(24, .unsigned(number))
        }

        #expect(await acceptsNode("a = #6.24(int) .eq #6.24(5)", tagged(5)))
        #expect(!(await acceptsNode("a = #6.24(int) .eq #6.24(5)", tagged(6))))
        #expect(!(await acceptsNode("a = #6.24(int) .eq #6.24(5)", .unsigned(5))))

        #expect(await acceptsNode("a = #6.24(int) .ne #6.24(5)", tagged(6)))
        #expect(!(await acceptsNode("a = #6.24(int) .ne #6.24(5)", tagged(5))))

        // A tagged target inside a map value is read the same way.
        #expect(await acceptsNode("a = { k: #6.24(int) .eq #6.24(5) }", .map([(key: .text("k"), value: tagged(5))])))
        #expect(
            !(await acceptsNode("a = { k: #6.24(int) .eq #6.24(5) }", .map([(key: .text("k"), value: tagged(6))])))
        )

        // Unwrapping names the type the wrapper holds, which is a type in its
        // own right and is held to as one.
        let one = CBORNode.array([.unsigned(1)])
        let two = CBORNode.array([.unsigned(2)])

        #expect(await acceptsNode("a = ~inner .eq [1]\ninner = [1]", one))
        #expect(!(await acceptsNode("a = ~inner .eq [1]\ninner = [1]", two)))
        #expect(!(await acceptsNode("a = ~inner .eq [1]\ninner = [1]", .unsigned(1))))
        #expect(await acceptsNode("a = { k: ~inner .eq [1] }\ninner = [1]", .map([(key: .text("k"), value: one)])))
        #expect(
            !(await acceptsNode("a = { k: ~inner .eq [1] }\ninner = [1]", .map([(key: .text("k"), value: two)])))
        )
    }

    /// A member key written as a choice between types answers for the keys of
    /// each alternative, and each alternative is read the way it is read
    /// written alone: which major type a name is filed under does not settle
    /// which keys it answers for.
    @Test func validateMemberKeyChoiceAnswersForTheKeysOfEveryAlternative() async {
        // (member key, keys the entry answers for, keys it does not)
        let cases: [(String, [CBORNode], [CBORNode])] = [
            ("(number / nil)", [.unsigned(5), .integer(-2), .float(1.5), .null], [.text("x"), .bool(true)]),
            ("(uint / nil)", [.unsigned(5), .null], [.integer(-2), .float(1.5), .text("x")]),
            ("(nint / nil)", [.integer(-2), .null], [.unsigned(5), .float(1.5)]),
            ("(int / nil)", [.unsigned(5), .integer(-2), .null], [.float(1.5), .text("x")]),
        ]

        for (memberKey, admitted, refused) in cases {
            for occurrence in ["*", "+", "1*", ""] {
                let entry = "{ \(occurrence) \(memberKey) => uint }"

                for key in admitted {
                    for (shape, node) in mapPlacements(key, .unsigned(0)) {
                        let cddl = shape.replacingOccurrences(of: "{}", with: entry)
                        #expect(await acceptsNode(cddl, node), "\(cddl) rejects a map keyed by \(key)")
                    }
                }

                for key in refused {
                    for (shape, node) in mapPlacements(key, .unsigned(0)) {
                        let cddl = shape.replacingOccurrences(of: "{}", with: entry)
                        #expect(!(await acceptsNode(cddl, node)), "\(cddl) admits a map keyed by \(key)")
                    }
                }
            }
        }
    }
}
