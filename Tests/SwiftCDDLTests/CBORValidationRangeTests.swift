import Foundation
import Testing

@testable import SwiftCDDL

/// A float in the shortest width that holds it exactly, as preferred
/// serialization encodes it (RFC 8949 Section 4.1).
private func shortestFloat(_ value: Double) -> CBORNode {
    if doubleToHalf(value) != nil {
        return .float(value, width: .half)
    }
    if Double(Float(value)) == value {
        return .float(value, width: .single)
    }
    return .float(value)
}

/// Validates the encoding of `node`, expecting a match.
private func expectValidNode(
    _ cddl: String,
    _ node: CBORNode,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
    #expect(
        verdict == nil, "\(comment.map { "\($0): " } ?? "")expected a match, got \(verdict.map { "\($0)" } ?? "")",
        sourceLocation: sourceLocation)
}

/// Validates the encoding of `node`, expecting a mismatch.
private func expectInvalidNode(
    _ cddl: String,
    _ node: CBORNode,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
    #expect(verdict != nil, comment ?? "expected a mismatch", sourceLocation: sourceLocation)
}

/// The rendered failure of validating the encoding of `node`, expected to be
/// a failure; empty when the document matched.
private func failureText(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> String {
    guard let error = await expectInvalid(cddl, node.encoded(), sourceLocation: sourceLocation) else { return "" }
    return error.description
}

/// The number of lines of `text` that are not blank: one per error of a
/// rendered report.
private func nonBlankLineCount(_ text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .count
}

/// A map with text keys, in order.
private func textMap(_ entries: [(String, CBORNode)]) -> CBORNode {
    .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
}

/// Validation of ranges (RFC 8610 Section 2.2.2.1) and of the `.size`,
/// `.bits` and comparison control operators (RFC 8610 Sections 3.8.1, 3.8.2
/// and 3.8.6).
@Suite
struct CBORValidationRangeTests {
    /// `time` under tag 1 rejects an integer outside the range of seconds a
    /// point in time can be expressed with (RFC 8949 Section 3.4.2).
    @Test func validateTimeTagIntegerRange() async {
        var cddl = "start = time"

        await expectValidNode(cddl, .tagged(1, .integer(1_363_896_240)))

        for outOfRange in [CBORNode.unsigned(UInt64.max), .negative(UInt64.max)] {
            await expectInvalidNode(cddl, .tagged(1, outOfRange))
        }

        // Nested, not only at the root.
        cddl = "start = { t: time }"
        await expectInvalidNode(cddl, textMap([("t", .tagged(1, .unsigned(UInt64.max)))]))
    }

    /// Range bounds may be negative, may be floats, and may be references to
    /// rules resolving to numeric literals.
    @Test func validateRangeWithNegativeBounds() async {
        let cddl = "start = -5..5"

        for value: Int64 in [-5, 0, 5] {
            await expectValidNode(cddl, .integer(value))
        }

        for value: Int64 in [-6, 6] {
            await expectInvalidNode(cddl, .integer(value))
        }

        // Both bounds negative.
        let bothNegative = "start = -10..-5"
        await expectValidNode(bothNegative, .integer(-7))
        await expectInvalidNode(bothNegative, .integer(-3))

        // `...` excludes the upper bound.
        let exclusive = "start = -5...5"
        await expectValidNode(exclusive, .integer(4))
        await expectInvalidNode(exclusive, .integer(5))

        // Bounds spanning the full 64-bit signed range.
        let signed64 = """
            start = min .. max
            min = -9223372036854775808
            max = 9223372036854775807

            """
        await expectValidNode(signed64, .integer(0))
        await expectValidNode(signed64, .integer(Int64.min))
    }

    @Test func validateRangeBoundsThroughRuleReferences() async {
        // A bound may be a rule reference that refers to another rule.
        let cddl = """
            start = 1 .. max
            max = upper_limit
            upper_limit = 100

            """
        await expectValidNode(cddl, .integer(50))
        await expectInvalidNode(cddl, .integer(150))

        // A rule carrying an operator of its own is a range, not a bound, and
        // does not resolve to its first type.
        let withOperator = """
            start = 1 .. max
            max = 1 .. 200

            """
        await expectInvalidNode(withOperator, .integer(50))

        // A circular reference is reported rather than recursed into.
        let circular = """
            start = 1 .. max
            max = max

            """
        await expectInvalidNode(circular, .integer(50))
    }

    @Test func validateFloatRange() async {
        let cddl = "start = 0.0..1.5"

        for value in [0.0, 0.5, 1.5] {
            await expectValidNode(cddl, shortestFloat(value))
        }

        for value in [-0.5, 2.0, Double.nan] {
            await expectInvalidNode(cddl, shortestFloat(value))
        }

        // A float range matches floats, not integers.
        await expectInvalidNode(cddl, .integer(1))

        // `...` excludes the upper bound.
        await expectInvalidNode("start = 0.0...1.5", shortestFloat(1.5))

        // Bounds of different kinds do not denote a range.
        await expectInvalidNode("start = 0 .. 1.5", shortestFloat(0.5))
    }

    @Test func validateSizeRangeWithNegativeLowerBound() async {
        // Lengths are not negative, so a negative lower bound excludes nothing;
        // the upper bound is still enforced.
        let cddl = "start = tstr .size (-1..3)"

        await expectValidNode(cddl, .text("ab"))

        await expectInvalidNode(cddl, .text("abcd"))
    }

    /// RFC 8610 Section 2.2.2.1 allows ranges only between integers or between
    /// floats, and they match values of that kind. A string is neither, so a
    /// range bounds a string only under `.size`, where it bounds the length.
    @Test func validateRangeMatchesAStringOnlyUnderSize() async {
        let bytes = CBORNode.bytes([0x01, 0x02, 0x03])
        let text = CBORNode.text("abc")

        for cddl in ["start = -5..5", "start = 0..10", "start = 0.0..10.0"] {
            await expectInvalidNode(cddl, bytes, "a byte string is not a member of the range in \(cddl)")
            await expectInvalidNode(cddl, text, "a text string is not a member of the range in \(cddl)")
        }

        // The same holds wherever the range occurs.
        await expectInvalidNode("m = { k: -5..5 }", textMap([("k", .bytes([0x01, 0x02, 0x03]))]))

        await expectInvalidNode("a = [* -5..5]", .array([.bytes([0x00, 0x01])]))

        await expectInvalidNode("a = #6.2(-5..5)", .tagged(2, .bytes([0x01, 0x02, 0x03])))

        // Under `.size` the range bounds the length, in both directions and for
        // both string types.
        let sizedBytes = "start = bstr .size (2..4)"
        await expectValidNode(sizedBytes, bytes)
        await expectInvalidNode(sizedBytes, .bytes([UInt8](repeating: 0, count: 5)))
        await expectInvalidNode(sizedBytes, .bytes([0]))

        let sizedText = "start = tstr .size (2..4)"
        await expectValidNode(sizedText, text)
        await expectInvalidNode(sizedText, .text("abcde"))
    }

    /// The controller of `.ne` is a type and every member of it is excluded,
    /// so a data item of a kind the range cannot contain is never excluded.
    @Test func validateNeRangeExcludesOnlyMembersOfTheRange() async {
        await expectValidNode("start = bstr .ne (1..5)", .bytes([0x01, 0x02, 0x03]))

        await expectValidNode("start = tstr .ne (1..5)", .text("abc"))

        // An integer inside the range is a member and is excluded.
        let integers = "start = int .ne (1..5)"
        await expectValidNode(integers, .integer(7))
        await expectInvalidNode(integers, .integer(3))

        // An integer is not a member of a float range, so it is not excluded.
        await expectValidNode("start = number .ne (1.0..5.0)", .integer(3))
    }

    /// An integer range matches integers only.
    @Test func validateIntegerRangeRejectsOtherDataItems() async {
        let cddl = "start = 1..5"

        await expectValidNode(cddl, .integer(3))

        for node in [CBORNode.map([]), .bool(true), .null, shortestFloat(3.0), .tagged(9, .integer(3))] {
            await expectInvalidNode(cddl, node, "\(node) is not an integer and so is not in the range")
        }
    }

    /// A float range matches floats only.
    @Test func validateFloatRangeRejectsOtherDataItems() async {
        let cddl = "start = 0.0..1.5"

        await expectValidNode(cddl, shortestFloat(1.0))

        for node in [CBORNode.bytes([0x01]), .text("ab"), .integer(1), .bool(false), .map([])] {
            await expectInvalidNode(cddl, node, "\(node) is not a float and so is not in the range")
        }
    }

    /// The infinities order normally against finite bounds rather than
    /// comparing false the way a NaN does, so the bounds exclude them.
    @Test func validateFloatRangeRejectsInfinities() async {
        for cddl in ["start = 0.0..1.5", "start = 0.0...1.5"] {
            await expectValidNode(cddl, shortestFloat(1.0))

            for value in [Double.infinity, -Double.infinity, Double.nan] {
                await expectInvalidNode(cddl, shortestFloat(value), "\(value) is outside \(cddl)")
            }
        }
    }

    /// RFC 8610 Section 2.2.2.1: a range whose lower bound exceeds its upper
    /// bound is the empty set, so it matches nothing.
    @Test func validateRangeWithLowerBoundAboveUpperBoundMatchesNothing() async {
        let cddl = "start = 10..0"

        for value: Int64 in [0, 5, 10] {
            await expectInvalidNode(cddl, .integer(value), "\(value) is in the empty set")
        }

        // The same bounds in order do match.
        await expectValidNode("start = 0..10", .integer(5))

        await expectInvalidNode("start = 1.5..0.5", shortestFloat(1.0), "1.0 is in the empty set")
        await expectValidNode("start = 0.5..1.5", shortestFloat(1.0))
    }

    /// A parenthesized bound denotes the value it wraps; parentheses around
    /// something that is not a single value do not denote a bound.
    @Test func validateRangeWithParenthesizedBounds() async {
        let cddl = "start = (1)..(3)"
        await expectValidNode(cddl, .integer(2))
        await expectInvalidNode(cddl, .integer(4))

        await expectValidNode("start = ((0.5))..1.5", shortestFloat(1.0))

        // A type choice and a range are not values.
        for cddl in ["start = (1/2)..3", "start = (1..2)..3"] {
            await expectInvalidNode(cddl, .integer(2), "\(cddl) does not denote a bound")
        }
    }

    /// Only a rule that denotes a single value resolves to a bound.
    @Test func validateRangeBoundRuleMustDenoteAValue() async {
        let value = CBORNode.integer(3)

        await expectValidNode(
            """
            start = 1..max
            max = 5

            """, value)

        for cddl in [
            // A group rule is not a value.
            """
            start = 1..max
            max = (b: 1)

            """,
            // A choice of several types is not a value.
            """
            start = 1..max
            max = 5 / 10

            """,
            // A rule taking generic parameters denotes a value only once
            // instantiated.
            """
            start = 1..max
            max<t> = t

            """,
        ] {
            await expectInvalidNode(cddl, value, "\(cddl) does not denote a bound")
        }
    }

    /// RFC 8610 Section 2.2.2.1 names generics as a motivating case for
    /// ranges, so a generic parameter used as a bound resolves to the argument
    /// the rule was instantiated with.
    @Test func validateRangeBoundFromGenericParameter() async {
        let cddl = """
            start = bounded<255>
            bounded<n> = 0..n

            """
        await expectValidNode(cddl, .integer(255))
        await expectInvalidNode(cddl, .integer(256))

        // The argument may itself be a rule reference.
        let indirect = """
            start = bounded<max-byte>
            max-byte = 255
            bounded<n> = 0..n

            """
        await expectValidNode(indirect, .integer(255))
        await expectInvalidNode(indirect, .integer(256))

        // Float bounds work the same way.
        let floats = """
            start = bounded<2.5>
            bounded<n> = 0.0..n

            """
        await expectValidNode(floats, shortestFloat(1.0))
        await expectInvalidNode(floats, shortestFloat(3.0))
    }

    /// Bounds of different kinds do not denote a range, and the report names
    /// the values, with a float bound keeping its decimal point.
    @Test func validateMixedRangeBoundsAreReportedWithTheirKinds() async {
        var message = await failureText("start = 0.0 .. 1", .integer(0))
        #expect(message.contains("got 0.0 and 1"), "got:\n\(message)")

        // A bound reached through a rule reference is reported by its value.
        message = await failureText(
            """
            start = 1..max
            max = 2.5

            """, .integer(1))
        #expect(message.contains("got 1 and 2.5"), "got:\n\(message)")
    }

    /// Resolving a bound through a chain of rule references counts against
    /// the rule nesting limit rather than running without bound.
    @Test func validateRangeBoundReferenceChainIsBounded() async throws {
        func chain(_ links: Int) -> String {
            var cddl = "start = 1 .. r0\n"
            for index in 0..<links {
                cddl += "r\(index) = r\(index + 1)\n"
            }
            cddl += "r\(links) = 100\n"
            return cddl
        }

        let value = CBORNode.integer(50)

        // A chain inside the limit resolves.
        await expectValidNode(chain(8), value)

        let longChain = chain(200)
        let message = await failureText(longChain, value)
        #expect(message.contains("maximum supported rule nesting"), "got:\n\(message)")

        // The limit is settable, and the same chain resolves once it is raised
        // past the chain's length.
        var validator = CBORValidator(cddl: try cddlFromStr(longChain), cbor: value)
        validator.setMaxRuleNesting(1000)
        try await validator.validate()

        // Nested parentheses count against the same limit.
        let nested = try cddlFromStr("start = 1 .. ((((100))))")
        validator = CBORValidator(cddl: nested, cbor: value)
        validator.setMaxRuleNesting(2)
        do {
            try await validator.validate()
            Issue.record("parentheses nested past the limit are reported rather than recursed into")
        } catch {
            #expect(error.description.contains("maximum supported rule nesting"), "got:\n\(error)")
        }

        validator = CBORValidator(cddl: nested, cbor: value)
        validator.setMaxRuleNesting(8)
        try await validator.validate()
    }

    /// A control operator whose target is `uint` is evaluated: the check that
    /// the data is a uint is a precondition for the control, not a substitute.
    @Test func validateControlOperatorsAgainstUintTarget() async {
        // `.size` on a uint bounds the bytes the value is representable in
        // (RFC 8610 Section 3.8.1), so 2 admits 0 through 65535.
        let size = "start = uint .size 2"
        await expectValidNode(size, .integer(65535))
        var message = await failureText(size, .integer(65536))
        #expect(message.contains(".size 2"), "got:\n\(message)")

        let lessThan = "start = uint .lt 10"
        await expectValidNode(lessThan, .integer(9))
        await expectInvalidNode(lessThan, .integer(10))

        let atLeast = "start = uint .ge 10"
        await expectValidNode(atLeast, .integer(10))
        await expectInvalidNode(atLeast, .integer(9))

        let notEqual = "start = uint .ne 5"
        await expectValidNode(notEqual, .integer(7))
        await expectInvalidNode(notEqual, .integer(5))

        let within = "start = uint .within (0..10)"
        await expectValidNode(within, .integer(10))
        await expectInvalidNode(within, .integer(11))

        // A rule resolving to uint is the same target.
        let alias = """
            start = myuint .lt 10
            myuint = uint

            """
        await expectValidNode(alias, .integer(5))
        await expectInvalidNode(alias, .integer(20))

        // The target type is still enforced ahead of the control.
        message = await failureText(lessThan, .integer(-1))
        #expect(message.contains("expected type uint"), "got:\n\(message)")
    }

    /// A control on a `uint` is evaluated wherever the uint occurs, and a
    /// violation is reported once, where it happened.
    @Test func validateUintControlOperatorNestedInArrayAndMap() async {
        let cddl = """
            start = [idx: uint .size 2, entry]
            entry = { count: uint .lt 10 }

            """

        let countOK = textMap([("count", .integer(9))])

        await expectValidNode(cddl, .array([.integer(1), countOK]))

        var message = await failureText(cddl, .array([.integer(70000), countOK]))
        #expect(message.contains(".size 2"), "got:\n\(message)")
        #expect(nonBlankLineCount(message) == 1, "expected exactly one error, got:\n\(message)")

        message = await failureText(cddl, .array([.integer(1), textMap([("count", .integer(10))])]))
        #expect(message.contains(".lt 10"), "got:\n\(message)")
    }

    /// `.size` on a uint bounds the byte width. A width beyond any value does
    /// not reject every value, and a range controller admits the widest width
    /// in it.
    @Test func validateUintSizeWidthsAndRanges() async {
        var cddl = "start = uint .size 3"
        await expectValidNode(cddl, .integer(16_777_215))
        await expectInvalidNode(cddl, .integer(16_777_216))

        // The widest integer fits in eight bytes, and any wider size admits
        // everything.
        cddl = "start = uint .size 8"
        await expectValidNode(cddl, .unsigned(UInt64.max))

        cddl = "start = uint .size 16"
        await expectValidNode(cddl, .integer(1))

        // A range controller bounds the width, not the value.
        cddl = "start = uint .size (1..2)"
        await expectValidNode(cddl, .integer(65_535))
        await expectInvalidNode(cddl, .integer(65_536))

        // `...` excludes the upper width.
        cddl = "start = uint .size (1...2)"
        await expectValidNode(cddl, .integer(255))
        await expectInvalidNode(cddl, .integer(256))

        // An empty range of widths admits nothing, and the report says so
        // rather than blaming the data.
        cddl = "start = uint .size (2..1)"
        let message = await failureText(cddl, .integer(0))
        #expect(message.contains("admits no byte width"), "got:\n\(message)")
    }

    /// A `.size` controller reached through a rule reference is the same
    /// controller, a width or a range of widths.
    @Test func validateUintSizeControllerFromRuleReference() async {
        var cddl = """
            start = uint .size sz
            sz = 2

            """
        await expectValidNode(cddl, .integer(65_535))
        await expectInvalidNode(cddl, .integer(65_536))

        cddl = """
            start = uint .size sz
            sz = 1..2

            """
        await expectValidNode(cddl, .integer(65_535))
        await expectInvalidNode(cddl, .integer(65_536))
    }

    /// A `.size` range failure is reported at the data item that failed.
    @Test func validateUintSizeRangeFailureLocation() async {
        let cddl = "start = [idx: uint .size (1..2)]"

        await expectValidNode(cddl, .array([.integer(65_535)]))

        let message = await failureText(cddl, .array([.integer(65_536)]))
        #expect(message.contains("cbor location /0"), "got:\n\(message)")
        #expect(nonBlankLineCount(message) == 1, "expected exactly one error, got:\n\(message)")
    }

    /// The target type of a control is a precondition for it, so a data item
    /// that is not a uint is rejected as such whatever the control.
    @Test func validateUintControlTargetRejectsNonUintData() async {
        for cddl in ["start = uint .size 2", "start = uint .lt 10", "start = uint .bits 3"] {
            for node in [
                CBORNode.text("x"), .bytes([0x01]), shortestFloat(1.5), .null, .bool(true), .integer(-1), .array([]),
            ] {
                let message = await failureText(cddl, node)
                #expect(message.contains("expected type uint"), "for \(node) got:\n\(message)")
            }
        }
    }

    /// A control constraining something a uint does not have reports that its
    /// target is wrong rather than holding.
    @Test func validateControlsMeaninglessForUintReportATargetError() async {
        for cddl in [
            #"start = uint .regexp "a""#,
            #"start = uint .pcre "a""#,
            "start = uint .cbor uint",
            "start = uint .cborseq uint",
            #"start = uint .cat "a""#,
            "start = uint .plus 1",
        ] {
            await expectInvalidNode(cddl, .integer(1), "expected \(cddl) to report a target error")
        }
    }

    /// Every comparison control is evaluated against a uint target.
    @Test func validateComparisonControlsAgainstUintTarget() async {
        let cases: [(String, Int64, Int64)] = [
            ("start = uint .gt 5", 6, 5),
            ("start = uint .le 5", 5, 6),
            ("start = uint .eq 5", 5, 6),
            ("start = uint .lt 5", 4, 5),
            ("start = uint .ge 5", 5, 4),
            ("start = uint .ne 5", 4, 5),
        ]
        for (cddl, holds, fails) in cases {
            await expectValidNode(cddl, .integer(holds), "\(cddl) must admit \(holds)")
            await expectInvalidNode(cddl, .integer(fails), "\(cddl) must reject \(fails)")
        }

        // `.and` holds only when both sides do.
        let cddl = "start = (uint .ge 1) .and (uint .le 9)"
        await expectValidNode(cddl, .integer(5))
        for outside: Int64 in [0, 50] {
            await expectInvalidNode(cddl, .integer(outside))
        }
    }

    /// The controller of `.ne` is a type, so a range controller excludes every
    /// value in it and nothing else.
    @Test func validateNeWithARangeController() async {
        var cddl = "start = uint .ne (0..10)"
        for inside: Int64 in [0, 5, 10] {
            await expectInvalidNode(cddl, .integer(inside), "\(inside) is a member of the controller type")
        }
        for outside: Int64 in [11, 50] {
            await expectValidNode(cddl, .integer(outside), "\(outside) is not a member of the controller type")
        }

        // `...` excludes the upper bound from the controller type, so the
        // upper bound is admitted.
        cddl = "start = uint .ne (0...10)"
        await expectValidNode(cddl, .integer(10))
        await expectInvalidNode(cddl, .integer(9))

        // A negative value is outside a non-negative controller range.
        cddl = "start = int .ne (0..10)"
        await expectValidNode(cddl, .integer(-1))
    }

    /// RFC 8610 Section 3.8.2: only the bits numbered by a member of the
    /// control type may be set. No bit has to be set, so a data item with no
    /// bit set holds.
    @Test func validateBitsControlAdmitsOnlyTheNumberedBits() async {
        var cddl = "start = uint .bits 3"
        for admitted: Int64 in [0, 8] {
            await expectValidNode(cddl, .integer(admitted), "\(admitted) sets only bit 3 or no bit at all")
        }
        for rejected: Int64 in [1, 9, 16] {
            await expectInvalidNode(cddl, .integer(rejected), "\(rejected) sets a bit other than 3")
        }

        // A range controller names a set of bit numbers, not of values.
        cddl = "start = uint .bits (0..7)"
        for admitted: Int64 in [0, 8, 255] {
            await expectValidNode(cddl, .integer(admitted), "\(admitted) sets only bits 0 through 7")
        }
        await expectInvalidNode(cddl, .integer(256))

        // `...` excludes the upper bit number.
        cddl = "start = uint .bits (0...7)"
        await expectValidNode(cddl, .integer(127))
        await expectInvalidNode(cddl, .integer(128))

        // The report names the bit that is set and the control type as written.
        cddl = "start = uint .bits 3"
        let message = await failureText(cddl, .integer(9))
        #expect(message.contains(".bits 3"), "got:\n\(message)")
        #expect(message.contains("Bit 0"), "got:\n\(message)")
        #expect(nonBlankLineCount(message) == 1, "expected exactly one error, got:\n\(message)")
    }

    /// A `.bits` control type may be a choice of a group-to-choice
    /// enumeration and a range; a bit holds when any alternative admits it.
    @Test func validateBitsControlWithACompositeControlType() async {
        let cddl = """
            tcpflagbytes = bstr .bits flags
            flags = &(
              fin: 8,
              syn: 9,
              rst: 10,
              psh: 11,
              ack: 12,
              urg: 13,
              ece: 14,
              cwr: 15,
              ns: 0,
            ) / (4..7)

            """

        for admitted: [UInt8] in [[0x00, 0x00], [0x50, 0x02], [0x90, 0x6d]] {
            await expectValidNode(cddl, .bytes(admitted), "\(admitted) sets only admitted bits")
        }
        // Bits 1, 2 and 3 are named by neither alternative.
        for rejected: [UInt8] in [[0x0e, 0x00], [0xff, 0xff]] {
            await expectInvalidNode(cddl, .bytes(rejected), "\(rejected) sets a bit no alternative admits")
        }

        // The same control type applies to a uint target, where bit n is 2^n.
        let uintCDDL = cddl.replacingOccurrences(of: "bstr .bits", with: "uint .bits")
        for admitted: Int64 in [0x0000, 0x0001, 0x0060, 0x00f0] {
            await expectValidNode(uintCDDL, .integer(admitted), "\(admitted) sets only admitted bits")
        }
        for rejected: Int64 in [0x0002, 0xffff] {
            await expectInvalidNode(uintCDDL, .integer(rejected), "\(rejected) sets a bit no alternative admits")
        }
    }

    /// Bit number n of a byte string is bit n & 7 of byte n >> 3, bit 0 of a
    /// byte being its least significant bit (RFC 8610 Section 3.8.2).
    @Test func validateBitsControlBitNumberingInAByteString() async {
        let cddl = "start = bstr .bits 3"

        for admitted: [UInt8] in [[], [0x00], [0x08], [0x08, 0x00]] {
            await expectValidNode(cddl, .bytes(admitted), "\(admitted) sets only bit 3 or no bit at all")
        }

        // h'0008' sets bit 11, not bit 3.
        for rejected: [UInt8] in [[0x09], [0x00, 0x08]] {
            await expectInvalidNode(cddl, .bytes(rejected), "\(rejected) sets a bit other than 3")
        }

        let message = await failureText(cddl, .bytes([0x00, 0x08]))
        #expect(message.contains("Bit 11"), "got:\n\(message)")
    }

    /// A `.bits` control is evaluated wherever its target occurs, and the
    /// failure is reported at the data item that failed.
    @Test func validateBitsControlNestedInArrayAndMap() async {
        let cddl = """
            start = [idx: uint .bits (0..7), entry]
            entry = { flags: bstr .bits (0..7) }

            """

        let entryOK = textMap([("flags", .bytes([0xff]))])

        await expectValidNode(cddl, .array([.integer(255), entryOK]))

        var message = await failureText(cddl, .array([.integer(256), entryOK]))
        #expect(message.contains("cbor location /0"), "got:\n\(message)")
        #expect(message.contains("Bit 8"), "got:\n\(message)")

        message = await failureText(cddl, .array([.integer(255), textMap([("flags", .bytes([0x00, 0x01]))])]))
        #expect(message.contains(#"cbor location /1/"flags""#), "got:\n\(message)")
    }

    /// `.bits` constrains a byte string or a uint; any other target is a
    /// schema error and any other data item a type error.
    @Test func validateBitsControlTarget() async {
        var message = await failureText("start = tstr .bits 3", .text("x"))
        #expect(message.contains(".bits control"), "got:\n\(message)")

        message = await failureText("start = bstr .bits 3", .integer(8))
        #expect(message.contains("expected type bstr"), "got:\n\(message)")
    }
}
