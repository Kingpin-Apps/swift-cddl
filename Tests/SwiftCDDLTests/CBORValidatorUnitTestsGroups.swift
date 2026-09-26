import Foundation
import Testing

@testable import SwiftCDDL

// Unit tests of the CBOR validator (RFC 8610 against RFC 8949 data items),
// second part: group choices, array lengths, generics, tagged types and range
// member keys.

/// Whether `node` matches `cddl`. The group choice tests assert the verdict for
/// several inputs against each of several schemas, including the same
/// alternatives written in the opposite order.
private func acceptsNode(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    await nodeResult(cddl, node, sourceLocation: sourceLocation) == nil
}

/// An array of text strings.
private func textArray(_ items: [String]) -> CBORNode {
    .array(items.map { .text($0) })
}

/// An array of unsigned integers.
private func uintArray(_ items: [UInt64]) -> CBORNode {
    .array(items.map { .unsigned($0) })
}

/// A map whose keys are the given integers, each mapped to `value`.
private func intKeyedMap(_ keys: [Int64], _ value: CBORNode) -> CBORNode {
    .map(keys.map { (key: CBORNode.integer($0), value: value) })
}

/// Tests of how the CBOR validator evaluates group choices (RFC 8610 Section
/// 2.2.2), array lengths, generic rules (Section 3.10), tagged types (Section
/// 3.6) and range member keys.
@Suite struct CBORValidatorUnitTestsGroups {
    /// The first alternative fails and contains an entry that resolves to an
    /// array type; the second alternative must still be evaluated against the
    /// array element at its own index.
    @Test func validateGroupChoiceAfterFailedAlternativeWithArrayTypedEntry() async {
        let cddl = """
            outer = [first // second]
            first = (0, inner)
            second = (4, sized, uint)
            inner = [0, bstr]
            sized = bytes .size 28
            """

        let valid = CBORNode.array([.unsigned(4), .bytes([UInt8](repeating: 0, count: 28)), .unsigned(100)])
        #expect(await acceptsNode(cddl, valid))

        let invalid = CBORNode.array([.unsigned(4), .bytes([UInt8](repeating: 0, count: 32)), .unsigned(100)])
        #expect(!(await acceptsNode(cddl, invalid)))
    }

    /// The array length check must remain in force for every alternative, not
    /// just the first one to be tried.
    @Test func validateGroupChoiceArrayLengthCheckedForEveryAlternative() async {
        let cddl = """
            outer = [first // second]
            first = (0, inner)
            second = (4, uint, uint)
            inner = [0, bstr]
            """

        // Four items, while neither alternative admits more than three.
        #expect(!(await acceptsNode(cddl, uintArray([4, 1, 2, 3]))))
        #expect(await acceptsNode(cddl, uintArray([4, 1, 2])))
    }

    /// An occurrence indicator consumed by a failed alternative must not remain
    /// in effect while the next alternative is evaluated.
    @Test func validateGroupChoiceAfterAlternativeWithOptionalEntry() async {
        let cddl = """
            outer = [first // second]
            first = (0, ? uint)
            second = (4, tstr)
            """

        #expect(await acceptsNode(cddl, .array([.unsigned(4), .text("a")])))
        #expect(!(await acceptsNode(cddl, .array([.unsigned(4), .unsigned(9)]))))
    }

    /// An alternative that consumes items homogeneously records its failures
    /// per item rather than as plain errors, and must be judged failed all the
    /// same so that the next alternative is tried. The verdict may not depend
    /// on the order the alternatives are written in.
    @Test func validateGroupChoiceWithHomogeneousAlternativeInEitherOrder() async {
        let uintFirst = """
            x = [g // h]
            g = (* uint)
            h = (tstr, tstr)
            """
        let tstrFirst = """
            x = [h // g]
            g = (* uint)
            h = (tstr, tstr)
            """

        for cddl in [uintFirst, tstrFirst] {
            #expect(await acceptsNode(cddl, textArray(["a", "b"])))
            #expect(await acceptsNode(cddl, uintArray([1, 2])))
            #expect(await acceptsNode(cddl, .array([])))

            // Neither alternative admits a mixture, nor a single text item.
            #expect(!(await acceptsNode(cddl, .array([.unsigned(1), .text("b")]))))
            #expect(!(await acceptsNode(cddl, textArray(["a"]))))
        }
    }

    /// Both alternatives consume items homogeneously, so neither records a
    /// plain error when it fails.
    @Test func validateGroupChoiceBetweenHomogeneousAlternatives() async {
        for cddl in ["x = [ (* uint) // (* tstr) ]", "x = [ (* tstr) // (* uint) ]"] {
            #expect(await acceptsNode(cddl, textArray(["a", "b"])))
            #expect(await acceptsNode(cddl, uintArray([1, 2])))
            #expect(await acceptsNode(cddl, .array([])))

            #expect(!(await acceptsNode(cddl, .array([.unsigned(1), .text("b")]))))
        }
    }

    /// A key matched by an alternative that went on to fail has not been
    /// validated, so the keys the matching alternative does not account for
    /// must still be reported.
    @Test func validateGroupChoiceMapUnexpectedKeyInEitherOrder() async {
        let pairFirst = "x = {a: uint, b: uint // c: uint}"
        let singleFirst = "x = {c: uint // a: uint, b: uint}"

        let aAndB = CBORNode.map([(key: .text("a"), value: .unsigned(1)), (key: .text("b"), value: .unsigned(2))])
        let cOnly = CBORNode.map([(key: .text("c"), value: .unsigned(2))])
        let aAndC = CBORNode.map([(key: .text("a"), value: .unsigned(1)), (key: .text("c"), value: .unsigned(2))])
        let aOnly = CBORNode.map([(key: .text("a"), value: .unsigned(1))])

        for cddl in [pairFirst, singleFirst] {
            #expect(await acceptsNode(cddl, aAndB))
            #expect(await acceptsNode(cddl, cOnly))

            // "a" belongs to the alternative that fails for want of "b", so it
            // is not accounted for by the alternative that matches "c".
            #expect(!(await acceptsNode(cddl, aAndC)))
            #expect(!(await acceptsNode(cddl, aOnly)))
            #expect(!(await acceptsNode(cddl, .map([]))))
        }
    }

    /// The number of items an array may hold is a property of the alternative
    /// being evaluated, not of the widest alternative: an array that matches
    /// one alternative's arity but another's content is not valid under either.
    @Test func validateGroupChoiceArrayLengthPerAlternative() async {
        let shortFirst = """
            x = [first // second]
            first = (0, uint)
            second = (4, uint, uint)
            """
        let longFirst = """
            x = [second // first]
            first = (0, uint)
            second = (4, uint, uint)
            """

        for cddl in [shortFirst, longFirst] {
            #expect(await acceptsNode(cddl, uintArray([0, 8])))
            #expect(await acceptsNode(cddl, uintArray([4, 8, 9])))

            // Three items is the arity of `second`, whose first entry is 4, not 0.
            #expect(!(await acceptsNode(cddl, uintArray([0, 8, 9]))))
            // Two items is the arity of `first`, whose first entry is 0, not 4.
            #expect(!(await acceptsNode(cddl, uintArray([4, 8]))))
            #expect(!(await acceptsNode(cddl, uintArray([4, 1, 2, 3]))))
            #expect(!(await acceptsNode(cddl, .array([]))))
        }
    }

    /// The entries of a group turned into a choice (RFC 8610 Section 3.9) are
    /// alternatives like any others, so each is matched against the same array
    /// item as the first.
    @Test func validateGroupChoiceEnumerationAlternativesInArray() async {
        let leadingEntry = """
            x = [0, sel]
            sel = &g
            g = (a: 1, b: 2)
            """
        let soleEntry = """
            x = [sel]
            sel = &g
            g = (a: 1, b: 2)
            """

        #expect(await acceptsNode(leadingEntry, uintArray([0, 1])))
        #expect(await acceptsNode(leadingEntry, uintArray([0, 2])))
        #expect(!(await acceptsNode(leadingEntry, uintArray([0, 3]))))

        #expect(await acceptsNode(soleEntry, uintArray([1])))
        #expect(await acceptsNode(soleEntry, uintArray([2])))
        #expect(!(await acceptsNode(soleEntry, uintArray([3]))))
    }

    /// With more than two alternatives, the one that matches may be neither the
    /// first nor the last, and the alternatives on both sides of it resolve to
    /// an array type.
    @Test func validateGroupChoiceWithMatchingMiddleAlternative() async {
        let ascending = """
            x = [aa // bb // cc]
            aa = (0, [uint])
            bb = (1, [tstr])
            cc = (2, [bool])
            """
        let descending = """
            x = [cc // bb // aa]
            aa = (0, [uint])
            bb = (1, [tstr])
            cc = (2, [bool])
            """

        let first = CBORNode.array([.unsigned(0), .array([.unsigned(1)])])
        let middle = CBORNode.array([.unsigned(1), .array([.text("s")])])
        let last = CBORNode.array([.unsigned(2), .array([.bool(true)])])
        let mismatched = CBORNode.array([.unsigned(1), .array([.unsigned(1)])])

        for cddl in [ascending, descending] {
            #expect(await acceptsNode(cddl, first))
            #expect(await acceptsNode(cddl, middle))
            #expect(await acceptsNode(cddl, last))

            #expect(!(await acceptsNode(cddl, mismatched)))
        }
    }

    /// A rule's own definition and the alternatives `/=` adds to it are
    /// alternatives of one choice, so whichever matches, what the others
    /// recorded is not the document's error.
    @Test func validateTypeChoiceAlternateBesideTheRuleDefinition() async {
        let cddl = """
            x = [t]
            t = uint
            t /= tstr
            """

        #expect(await acceptsNode(cddl, uintArray([1])))
        #expect(await acceptsNode(cddl, textArray(["a"])))

        #expect(!(await acceptsNode(cddl, .array([.bool(true)]))))
    }

    /// Every `//=` alternate is evaluated from the state the entry was reached
    /// with, so one beyond the first is matched against the same array items.
    @Test func validateGroupChoiceAlternateBeyondTheFirst() async {
        let cddl = """
            tester = [$$val]
            $$val //= (type: 10, data: uint)
            $$val //= (type: 11, data: tstr)
            """

        #expect(await acceptsNode(cddl, uintArray([10, 1])))
        #expect(await acceptsNode(cddl, .array([.unsigned(11), .text("t")])))

        #expect(!(await acceptsNode(cddl, uintArray([12, 1]))))
        #expect(!(await acceptsNode(cddl, .array([.unsigned(10), .text("t")]))))
        #expect(!(await acceptsNode(cddl, uintArray([11, 1]))))
    }

    /// An entry marked `?` may be absent, in which case the entries after it
    /// match the items one position earlier.
    @Test func validateGroupChoiceWithAbsentOptionalEntry() async {
        let cddl = "x = [ (? uint, tstr) // (bool, bool) ]"

        #expect(
            await acceptsNode(cddl, textArray(["z"])),
            "the optional entry is absent and `tstr` matches the sole item"
        )
    }

    /// A group rule assigned with `=` and then extended with `//=` gains an
    /// alternative, which contributes its own arity and has to be evaluated
    /// from the state the choice was entered with, like any other alternative.
    @Test func validateGroupChoiceAlternateExtendingADefinedRule() async {
        let cddl = """
            x = [g]
            g = (0, uint)
            g //= (4, uint, uint)
            """

        #expect(await acceptsNode(cddl, uintArray([0, 1])))
        #expect(await acceptsNode(cddl, uintArray([4, 1, 2])))
        #expect(!(await acceptsNode(cddl, uintArray([4, 1]))))
    }

    /// Wrapping a group choice in parentheses, or behind a group rule, does not
    /// change what it describes: each alternative still accounts for the items
    /// its own entries do, and an array longer than the alternative that
    /// matches has items no entry answers for.
    @Test func validateGroupChoiceArityThroughAWrappingGroup() async {
        let parenthesized = "x = [ ( (0, uint) // (4, uint, uint) ) ]"
        let throughRule = """
            x = [g]
            g = ( (0, uint) // (4, uint, uint) )
            """
        let flat = "x = [ (0, uint) // (4, uint, uint) ]"

        for cddl in [parenthesized, throughRule, flat] {
            #expect(await acceptsNode(cddl, uintArray([0, 8])), "\(cddl)")
            #expect(await acceptsNode(cddl, uintArray([4, 8, 9])), "\(cddl)")

            #expect(
                !(await acceptsNode(cddl, uintArray([0, 8, 9]))),
                "the two-item alternative leaves the third item unaccounted for in \(cddl)"
            )
            #expect(
                !(await acceptsNode(cddl, .array([.unsigned(0), .unsigned(8), .text("junk")]))),
                "\(cddl)"
            )
        }
    }

    /// A group socket (RFC 8610 Section 3.9) is defined by its plugs, each of
    /// which is an alternative accounting for the items its own entries do.
    @Test func validateSocketGroupChoiceAlternateArity() async {
        let cddl = """
            x = [ $$s ]
            $$s //= (0, uint)
            $$s //= (1, tstr, tstr)
            """

        #expect(await acceptsNode(cddl, uintArray([0, 5])))
        #expect(await acceptsNode(cddl, .array([.unsigned(1), .text("a"), .text("b")])))

        #expect(
            !(await acceptsNode(cddl, uintArray([0, 5, 6]))),
            "no plug accounts for three items beginning with 0"
        )
        #expect(!(await acceptsNode(cddl, uintArray([1, 5, 6]))))
    }

    /// An alternative whose entries are a nested group choice followed by
    /// further entries accounts for the items of both, and the nested choice
    /// answers for the items at its own position.
    @Test func validateGroupChoiceNestedAheadOfFurtherEntries() async {
        let inline = "x = [ ( ((0)//(1)), tstr, tstr ) // (uint, uint, uint) ]"
        let throughRule = """
            x = [ (disc, tstr, tstr) // (uint, uint, uint) ]
            disc = ( (0) // (1) )
            """

        let zeroAB = CBORNode.array([.unsigned(0), .text("a"), .text("b")])
        let oneAB = CBORNode.array([.unsigned(1), .text("a"), .text("b")])
        let fiveAB = CBORNode.array([.unsigned(5), .text("a"), .text("b")])
        let zeroANine = CBORNode.array([.unsigned(0), .text("a"), .unsigned(9)])

        for cddl in [inline, throughRule] {
            #expect(await acceptsNode(cddl, zeroAB), "\(cddl)")
            #expect(await acceptsNode(cddl, oneAB), "\(cddl)")
            #expect(await acceptsNode(cddl, uintArray([1, 2, 3])), "\(cddl)")

            #expect(!(await acceptsNode(cddl, fiveAB)), "\(cddl)")
            #expect(!(await acceptsNode(cddl, zeroANine)), "\(cddl)")
            #expect(!(await acceptsNode(cddl, .array([.unsigned(0), .text("a")]))), "\(cddl)")
        }
    }

    /// The entries before a nested group choice account for the items before
    /// it, so the choice answers for the items that follow them rather than for
    /// the items at its own entry indices.
    @Test func validateGroupChoiceFollowingALeadingEntry() async {
        let cddl = "x = [ tstr, ( (0) // (1, uint) ) ]"

        #expect(await acceptsNode(cddl, .array([.text("a"), .unsigned(0)])))
        #expect(await acceptsNode(cddl, .array([.text("a"), .unsigned(1), .unsigned(5)])))

        #expect(
            !(await acceptsNode(cddl, .array([.text("a"), .unsigned(0), .unsigned(5)]))),
            "no alternative accounts for two items after the leading one"
        )
    }

    /// An alternative with no entries accounts for no items, so it matches only
    /// an array the entries around it already account for in full.
    @Test func validateGroupChoiceWithEmptyAlternative() async {
        for cddl in ["x = [ () // (uint) ]", "x = [ (uint) // () ]"] {
            #expect(await acceptsNode(cddl, .array([])), "\(cddl)")
            #expect(await acceptsNode(cddl, uintArray([1])), "\(cddl)")

            #expect(!(await acceptsNode(cddl, textArray(["a"]))), "\(cddl)")
            #expect(!(await acceptsNode(cddl, uintArray([1, 2]))), "\(cddl)")
        }

        // The same holds where a sibling alternative stands for a run of items
        // of a length the group does not state.
        for cddl in ["x = [ (* uint) // () ]", "x = [ () // (* uint) ]"] {
            #expect(await acceptsNode(cddl, .array([])), "\(cddl)")
            #expect(await acceptsNode(cddl, uintArray([1, 2])), "\(cddl)")

            #expect(!(await acceptsNode(cddl, textArray(["a", "b"]))), "\(cddl)")
        }
    }

    /// A choice under an occurrence indicator covering more than one occurrence
    /// matches as many times as its alternatives go, and every map entry has to
    /// be accounted for by one of them.
    @Test func validateRepeatedMapGroupChoice() async {
        let cddl = "x = { * ( a: uint // b: tstr ) }"
        func entry(_ key: String, _ value: CBORNode) -> CBORNode {
            .map([(key: .text(key), value: value)])
        }

        #expect(await acceptsNode(cddl, .map([])))
        #expect(await acceptsNode(cddl, entry("a", .unsigned(1))))
        #expect(await acceptsNode(cddl, entry("b", .text("z"))))
        #expect(
            await acceptsNode(cddl, .map([(key: .text("a"), value: .unsigned(1)), (key: .text("b"), value: .text("z"))]))
        )

        #expect(!(await acceptsNode(cddl, entry("a", .text("z")))), "the value under `a` is not a uint")
        #expect(!(await acceptsNode(cddl, entry("b", .unsigned(5)))), "the value under `b` is not a tstr")
        #expect(!(await acceptsNode(cddl, entry("q", .unsigned(1)))), "no alternative names the key `q`")

        // `+` is the same choice repeated, and requires at least one match.
        let atLeastOnce = "x = { + ( a: uint // b: tstr ) }"
        #expect(!(await acceptsNode(atLeastOnce, .map([]))))
        #expect(await acceptsNode(atLeastOnce, entry("a", .unsigned(1))))
    }

    /// A map admits only the entries its group names, and a group that named
    /// none of them says so as much as one that named some.
    @Test func validateMapRejectsEntriesNoGroupEntryNames() async {
        let cddl = "x = { ? a: uint }"

        #expect(await acceptsNode(cddl, .map([])))
        #expect(await acceptsNode(cddl, .map([(key: .text("a"), value: .unsigned(1))])))

        #expect(!(await acceptsNode(cddl, .map([(key: .text("b"), value: .unsigned(1))]))))
    }

    /// A group entry that names a rule is one entry like any other: the array
    /// has to have a length the group admits, whether the entry names a rule or
    /// spells its type out.
    @Test func validateArrayLengthForEntriesThatNameARule() async {
        let one = "a = [b]\nb = uint\n"
        #expect(await acceptsNode(one, uintArray([1])))
        #expect(!(await acceptsNode(one, uintArray([1, 2]))))
        #expect(!(await acceptsNode(one, uintArray([1, 2, 3]))))

        let three = "a = [b, c, d]\nb = int\nc = tstr\nd = bool\n"
        let matching = CBORNode.array([.unsigned(1), .text("x"), .bool(true)])
        let extra = CBORNode.array([.unsigned(1), .text("x"), .bool(true), .unsigned(9)])
        #expect(await acceptsNode(three, matching))
        #expect(!(await acceptsNode(three, extra)))

        // A document matching neither alternative of a type choice matches the
        // rule no more than it matches either of them.
        let choice = "a = [b] / [c, d]\nb = int\nc = int\nd = tstr\n"
        #expect(await acceptsNode(choice, uintArray([1])))
        #expect(!(await acceptsNode(choice, uintArray([1, 2]))))

        // The rule an entry names may itself be an array, and its own length is
        // checked one nesting level down.
        let nested = "a = [x]\nx = [b]\nb = tstr\n"
        #expect(await acceptsNode(nested, .array([textArray(["a"])])))
        #expect(!(await acceptsNode(nested, .array([textArray(["a", "b"])]))))
    }

    /// `?` widens the lengths a group admits by one entry and no further,
    /// however the optional entry is written.
    @Test func validateArrayLengthUnderAnOptionalEntry() async {
        for cddl in ["a = [int, ? b]\nb = tstr\n", "a = [int, ? tstr]\n"] {
            let one = CBORNode.array([.unsigned(1)])
            let two = CBORNode.array([.unsigned(1), .text("a")])
            let three = CBORNode.array([.unsigned(1), .text("a"), .text("b")])
            let mismatched = CBORNode.array([.unsigned(1), .unsigned(5)])

            #expect(await acceptsNode(cddl, one), "\(cddl)")
            #expect(await acceptsNode(cddl, two), "\(cddl)")
            #expect(!(await acceptsNode(cddl, three)), "\(cddl)")
            #expect(!(await acceptsNode(cddl, mismatched)), "\(cddl)")
        }
    }

    /// An entry under an occurrence indicator covering more than one item
    /// stands for the run of items starting at its own position, and every item
    /// of that run is held to the entry's type.
    @Test func validateEntryCoveringSeveralItems() async {
        for cddl in ["a = [int, 2*3 b]\nb = tstr\n", "a = [int, 2*3 tstr]\n"] {
            let two = CBORNode.array([.unsigned(1), .text("x")])
            let threeText = CBORNode.array([.unsigned(1), .text("x"), .text("y")])
            let threeMixed = CBORNode.array([.unsigned(1), .text("x"), .unsigned(2)])

            // Only one occurrence where the lower bound demands two.
            #expect(!(await acceptsNode(cddl, two)), "\(cddl)")
            #expect(await acceptsNode(cddl, threeText), "\(cddl)")
            // The second occurrence is not a tstr.
            #expect(!(await acceptsNode(cddl, threeMixed)), "\(cddl)")
        }

        // The items before the entry belong to the entries before it and are
        // not held to it.
        let cddl = """
            with-header = [header, * row]
            header = [tstr, tstr]
            row = [tstr, uint]
            """
        let rows = CBORNode.array([
            textArray(["name", "score"]),
            .array([.text("a"), .unsigned(100)]),
            .array([.text("b"), .unsigned(95)]),
        ])
        #expect(await acceptsNode(cddl, rows))

        let badRow = CBORNode.array([textArray(["name", "score"]), textArray(["a", "x"])])
        #expect(!(await acceptsNode(cddl, badRow)))
    }

    /// A generic argument that names a parameter of the rule being evaluated
    /// denotes what that parameter is bound to (RFC 8610 Section 3.10), not the
    /// parameter of the rule it is passed to, which would stand for itself.
    @Test func validateGenericArgumentNamingAnOuterParameter() async {
        let cddl = """
            top = p<int>
            p<T> = [* q<T>]
            q<T> = [T]
            """

        #expect(await acceptsNode(cddl, .array([uintArray([1])])))
        #expect(!(await acceptsNode(cddl, .array([textArray(["x"])]))))
    }

    /// A generic rule defined in terms of itself is a cycle like any other and
    /// is reported rather than resolved without end.
    @Test func validateGenericRuleCycleIsReported() async {
        for cddl in ["x = a<int>\na<T> = a<T>\n", "x = a<int>\na<T> = b<T>\nb<T> = a<T>\n"] {
            #expect(!(await acceptsNode(cddl, .unsigned(1))), "\(cddl)")
        }
    }

    /// A tagged data item is a data item in its own right: a type name matches
    /// it only where the name stands for a tagged type carrying that tag. A
    /// name that describes the enclosed data item does not match the tagged
    /// item, whether it stands alone or as an alternative of a type choice.
    @Test func validateTypeNameDoesNotMatchATaggedDataItem() async {
        for cddl in ["p = #6.121(int) / tstr", "p = tstr / #6.121(int)", "p = uint / #6.121(int)"] {
            #expect(!(await acceptsNode(cddl, .tagged(121, .bool(true)))), "\(cddl)")
            #expect(await acceptsNode(cddl, .tagged(121, .unsigned(5))), "\(cddl)")
        }

        // A lone type name is judged the same way.
        for name in ["tstr", "bstr", "int", "uint", "bool", "nil", "float"] {
            #expect(!(await acceptsNode("p = \(name)", .tagged(121, .bool(true)))), "\(name)")
        }

        // `any` matches every data item, tagged ones included.
        #expect(await acceptsNode("p = any", .tagged(121, .bool(true))))
    }

    /// The alternatives of a type choice are judged the same way wherever the
    /// choice appears, so a tagged alternative whose content fails leaves the
    /// choice to the remaining alternatives.
    @Test func validateTaggedAlternativeOfATypeChoiceNestedInAContainer() async {
        func inMap(_ value: CBORNode) -> CBORNode {
            .map([(key: .unsigned(0), value: value)])
        }

        #expect(!(await acceptsNode("p = [#6.121(int) / tstr]", .array([.tagged(121, .bool(true))]))))
        #expect(await acceptsNode("p = [#6.121(int) / tstr]", .array([.tagged(121, .unsigned(5))])))
        #expect(await acceptsNode("p = [#6.121(int) / tstr]", .array([.text("x")])))

        #expect(!(await acceptsNode("p = {0: #6.121(int) / tstr}", inMap(.tagged(121, .bool(true))))))
        #expect(await acceptsNode("p = {0: #6.121(int) / tstr}", inMap(.tagged(121, .unsigned(5)))))
        #expect(await acceptsNode("p = {0: #6.121(int) / tstr}", inMap(.text("x"))))
    }

    /// The content of a tagged type is a type in its own right, so a later
    /// alternative of a type choice inside a tag settles the match.
    @Test func validateTagContentMatchingALaterAlternative() async {
        let cddl = "p = #6.121(int / tstr)"

        #expect(await acceptsNode(cddl, .tagged(121, .text("s"))))
        #expect(await acceptsNode(cddl, .tagged(121, .unsigned(1))))
        #expect(!(await acceptsNode(cddl, .tagged(121, .bool(true)))))
    }

    /// A tagged type defined in terms of itself is matched at every level of
    /// the data, so a failure at any depth fails the whole.
    @Test func validateRecursiveTaggedTypeAtEveryDepth() async {
        let cddl = "p = #6.121(int) / #6.122([p])"

        func nest(_ depth: Int, _ leaf: CBORNode) -> CBORNode {
            var value = CBORNode.tagged(121, leaf)
            for _ in 1..<depth {
                value = .tagged(122, .array([value]))
            }
            return value
        }

        for depth in [1, 3, 10] {
            #expect(await acceptsNode(cddl, nest(depth, .unsigned(7))), "depth \(depth)")
            #expect(!(await acceptsNode(cddl, nest(depth, .bool(true)))), "depth \(depth)")
        }
    }

    /// A prelude name (RFC 8610 Appendix D) that stands for a tagged type still
    /// matches the data item that type describes, and only that one. The names
    /// that stand for a choice over big numbers match every tagged type the
    /// choice is built from.
    @Test func validatePreludeTaggedTypeNames() async {
        func bignum(_ tag: UInt64) -> CBORNode {
            .tagged(tag, .bytes([1, 2]))
        }

        #expect(await acceptsNode("p = biguint", bignum(2)))
        #expect(!(await acceptsNode("p = biguint", bignum(3))))
        #expect(!(await acceptsNode("p = biguint", .tagged(2, .unsigned(1)))))
        #expect(await acceptsNode("p = bignint", bignum(3)))

        // bigint = biguint / bignint, integer = int / bigint, unsigned = uint / biguint
        #expect(await acceptsNode("p = bigint", bignum(2)))
        #expect(await acceptsNode("p = bigint", bignum(3)))
        #expect(!(await acceptsNode("p = bigint", bignum(4))))
        #expect(await acceptsNode("p = integer", bignum(2)))
        #expect(await acceptsNode("p = integer", .unsigned(3)))
        #expect(await acceptsNode("p = unsigned", bignum(2)))
        #expect(!(await acceptsNode("p = unsigned", bignum(3))))

        #expect(await acceptsNode("p = encoded-cbor", .tagged(24, .bytes([1]))))
        #expect(!(await acceptsNode("p = encoded-cbor", .tagged(24, .unsigned(1)))))
        #expect(await acceptsNode("p = cbor-any", .tagged(55799, .unsigned(1))))
    }

    /// Asking whether a map holds an entry keyed by a type is what a member key
    /// asks. In any other position a type name describes the data item itself,
    /// and a map is not a data item of any of the types a member key can be
    /// keyed by.
    @Test func validateTypeNameDoesNotMatchAMapOutsideMemberKeyPosition() async {
        let map = CBORNode.map([(key: .text("a"), value: .unsigned(1))])

        for name in ["tstr", "bstr", "int", "uint", "bool", "nil", "float"] {
            #expect(!(await acceptsNode("p = \(name)", map)), "\(name)")
        }

        // Nested in a container, where the name describes the item.
        #expect(!(await acceptsNode("p = [tstr]", .array([map]))))
        #expect(!(await acceptsNode("p = {0: tstr}", .map([(key: .unsigned(0), value: map)]))))

        // A member key keyed by a type still matches the keys of the map.
        #expect(await acceptsNode("p = {* tstr => int}", map))
        #expect(!(await acceptsNode("p = {* tstr => tstr}", map)))
        #expect(await acceptsNode("p = {tstr => int}", map))
        #expect(await acceptsNode("p = {a: int}", map))
        #expect(await acceptsNode("p = {k => int}\nk = tstr", map))
        #expect(!(await acceptsNode("p = {k => int}\nk = uint", map)))
    }

    /// A map alternative of a type choice fails on its content like any other,
    /// so data no alternative accepts is rejected and data one alternative
    /// accepts is not.
    @Test func validateMapAlternativeOfATypeChoice() async {
        func entry(_ value: CBORNode) -> CBORNode {
            .map([(key: .text("a"), value: value)])
        }

        for cddl in ["p = {a: int} / tstr", "p = tstr / {a: int}"] {
            #expect(!(await acceptsNode(cddl, entry(.bool(true)))), "\(cddl)")
            #expect(await acceptsNode(cddl, entry(.unsigned(1))), "\(cddl)")
            #expect(await acceptsNode(cddl, .text("z")), "\(cddl)")
        }

        // Nested as the value of a map entry.
        func nested(_ value: CBORNode) -> CBORNode {
            .map([(key: .unsigned(0), value: entry(value))])
        }
        #expect(!(await acceptsNode("p = {0: {a: int} / tstr}", nested(.bool(true)))))
        #expect(await acceptsNode("p = {0: {a: int} / tstr}", nested(.unsigned(2))))
    }

    /// An array alternative records its failures per item rather than as plain
    /// errors, and must be judged failed all the same so that the choice
    /// reports the failure instead of reading it as a match.
    @Test func validateArrayAlternativeOfATypeChoiceFailingOnAnItem() async {
        for cddl in ["p = [int] / tstr", "p = tstr / [int]", "p = [* int] / tstr"] {
            #expect(!(await acceptsNode(cddl, .array([.bool(true)]))), "\(cddl)")
            #expect(await acceptsNode(cddl, .array([.unsigned(1)])), "\(cddl)")
            #expect(await acceptsNode(cddl, .text("q")), "\(cddl)")
        }
    }

    /// A range in member key position denotes the keys the entry answers for,
    /// so each key of the map is held to it in turn. A map is never a member of
    /// a range, so holding the map itself to it would leave the entry
    /// unsatisfiable.
    @Test func validateMapRangeMemberKeyUnderZeroOrMore() async {
        let cddl = "p = {* 3..255 => int}"
        let one = CBORNode.unsigned(1)

        // Zero occurrences, which the empty map has.
        #expect(await acceptsNode(cddl, intKeyedMap([], one)))

        // Keys within the range, both bounds included.
        #expect(await acceptsNode(cddl, intKeyedMap([3], one)))
        #expect(await acceptsNode(cddl, intKeyedMap([255], one)))
        #expect(await acceptsNode(cddl, intKeyedMap([3, 4, 255], one)))

        // Keys outside the range, which no entry of the group accounts for.
        #expect(!(await acceptsNode(cddl, intKeyedMap([2], one))))
        #expect(!(await acceptsNode(cddl, intKeyedMap([256], one))))
        #expect(!(await acceptsNode(cddl, intKeyedMap([3, 2], one))))

        // An exclusive range excludes its upper bound.
        #expect(await acceptsNode("p = {* 3...255 => int}", intKeyedMap([254], one)))
        #expect(!(await acceptsNode("p = {* 3...255 => int}", intKeyedMap([255], one))))
    }

    /// An entry written without an occurrence indicator stands for exactly one
    /// occurrence, so a range there requires one entry with a key in it and
    /// admits no second one.
    @Test func validateMapRangeMemberKeyWithoutAnOccurrenceIndicator() async {
        let cddl = "p = {3..255 => int}"
        let one = CBORNode.unsigned(1)

        #expect(await acceptsNode(cddl, intKeyedMap([3], one)))
        #expect(!(await acceptsNode(cddl, intKeyedMap([], one))))
        #expect(!(await acceptsNode(cddl, intKeyedMap([2], one))))
        #expect(!(await acceptsNode(cddl, intKeyedMap([3, 4], one))))

        // One or more requires at least one entry with a key in the range.
        #expect(!(await acceptsNode("p = {+ 3..255 => int}", intKeyedMap([], one))))
        #expect(await acceptsNode("p = {+ 3..255 => int}", intKeyedMap([3, 4], one)))

        // An optional entry admits absence and one occurrence, and no more.
        #expect(await acceptsNode("p = {? 3..255 => int}", intKeyedMap([], one)))
        #expect(await acceptsNode("p = {? 3..255 => int}", intKeyedMap([3], one)))
        #expect(!(await acceptsNode("p = {? 3..255 => int}", intKeyedMap([3, 4], one))))
    }

    /// A range key accounts for the keys an earlier entry of the group has not,
    /// whichever order the entries are written in.
    @Test func validateMapRangeMemberKeyAlongsideLiteralKeys() async {
        let one = CBORNode.unsigned(1)

        for cddl in ["p = {? 0: int, * 3..255 => int}", "p = {* 3..255 => int, ? 0: int}"] {
            #expect(await acceptsNode(cddl, intKeyedMap([0, 3], one)), "\(cddl)")
            #expect(await acceptsNode(cddl, intKeyedMap([3], one)), "\(cddl)")
            #expect(await acceptsNode(cddl, intKeyedMap([0], one)), "\(cddl)")
            #expect(await acceptsNode(cddl, intKeyedMap([], one)), "\(cddl)")
            #expect(!(await acceptsNode(cddl, intKeyedMap([0, 2], one))), "\(cddl)")
            #expect(!(await acceptsNode(cddl, intKeyedMap([2], one))), "\(cddl)")
        }
    }

    /// A range reaches member key position written out, wrapped in
    /// parentheses, or under a name that stands for one, and each denotes the
    /// same set of keys.
    @Test func validateMapRangeMemberKeyWrittenIndirectly() async {
        let one = CBORNode.unsigned(1)

        for cddl in [
            "p = {* 3..255 => int}",
            "p = {* (3..255) => int}",
            "p = {* r => int}\nr = 3..255",
            "p = {* r => int}\nr = (s)\ns = 3..255",
            "p = {* lo..hi => int}\nlo = 3\nhi = 255",
        ] {
            #expect(await acceptsNode(cddl, intKeyedMap([], one)), "\(cddl)")
            #expect(await acceptsNode(cddl, intKeyedMap([3, 255], one)), "\(cddl)")
            #expect(!(await acceptsNode(cddl, intKeyedMap([2], one))), "\(cddl)")
            #expect(!(await acceptsNode(cddl, intKeyedMap([256], one))), "\(cddl)")
        }

        // A name defined in terms of itself denotes no range, and the entry no
        // set of keys it accounts for.
        #expect(!(await acceptsNode("p = {* r => int}\nr = r", intKeyedMap([3], one))))
    }
}
