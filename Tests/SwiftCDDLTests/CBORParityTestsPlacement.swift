import Foundation
import Testing

@testable import SwiftCDDL

private typealias P = CBORParityFixture

/// Type expressions held to the documents they admit and refuse at the root,
/// in a map value and in an array item (RFC 8610 Sections 2, 3.8 and 3.9).
extension CBORParityTests {
    /// A literal denotes one data item, and a map is not that data item: only
    /// in member key position does a literal name an entry of the map.
    @Test func aLiteralOutsideMemberKeyPositionIsNotAMapLookupInEitherValidator() async {
        await P.assertSettledInEveryPlacement(
            "", "\"x\"",
            admitted: [P.text("x")],
            refused: [P.map([("x", P.int(9))]), P.map([]), P.text("y")])

        await P.assertSettledInEveryPlacement(
            "", "5",
            admitted: [P.int(5)],
            refused: [P.map([("k", P.int(1))]), P.map([]), P.int(1)])

        // A rule name resolving to a literal states the same type as the
        // literal written in place of it.
        await P.assertSettledInEveryPlacement(
            "\nname = \"x\"", "name",
            admitted: [P.text("x")],
            refused: [P.map([("x", P.int(9))]), P.map([])])
    }

    /// `.default` names the value an absent optional entry stands for and
    /// narrows nothing, so the data item is held to the target whatever the
    /// controller is.
    @Test func defaultOnALiteralTargetStillHoldsTheDataItemToTheTarget() async {
        for typeExpr in ["5 .default \"x\"", "5 .default 5", "5 .default uint", "5 .default (0..10)"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr,
                admitted: [P.int(5)],
                refused: [P.map([("k", P.int(1))]), P.map([]), P.int(1), P.text("x")])
        }

        await P.assertSettledInEveryPlacement(
            "", "\"x\" .default \"y\"",
            admitted: [P.text("x")],
            refused: [P.map([("x", P.int(9))]), P.map([]), P.text("y")])

        // A target naming a data type is held to the same way.
        await P.assertSettledInEveryPlacement(
            "", "tstr .default \"x\"",
            admitted: [P.text("x"), P.text("s")],
            refused: [P.map([("x", P.int(9))]), P.int(5)])
    }

    /// A target written as a map states the entries the data item has to hold;
    /// `.ne` admits exactly the data items of that map type `.eq` refuses.
    @Test func equalityOperatorsOnAMapTargetHoldTheDataItemToThatMap() async {
        let outside: [CBORNode] = [
            P.map([("z", P.int(1))]),
            P.map([("j", P.text("s"))]),
            P.map([]),
            P.int(5),
            P.array([P.int(1)]),
        ]

        await P.assertSettledInEveryPlacement(
            "", "{k: int} .eq {k: 1}",
            admitted: [P.map([("k", P.int(1))])],
            refused: [P.map([("k", P.int(2))])] + outside)

        let refusedByNe = [P.map([("k", P.int(1))])] + outside

        await P.assertSettledInEveryPlacement(
            "", "{k: int} .ne {k: 1}",
            admitted: [P.map([("k", P.int(2))])],
            refused: refusedByNe)

        // A rule name resolving to the map states the same target.
        await P.assertSettledInEveryPlacement(
            "\nm = {k: int}", "m .ne {k: 1}",
            admitted: [P.map([("k", P.int(2))])],
            refused: refusedByNe)
    }

    /// The same statement for a target written as an array.
    @Test func equalityOperatorsOnAnArrayTargetHoldTheDataItemToThatArray() async {
        let outside: [CBORNode] = [
            P.array([P.text("s")]),
            P.array([]),
            P.array([P.int(1), P.int(2)]),
            P.int(5),
            P.map([("k", P.int(1))]),
        ]

        await P.assertSettledInEveryPlacement(
            "", "[int] .eq [1]",
            admitted: [P.array([P.int(1)])],
            refused: [P.array([P.int(2)])] + outside)

        let refusedByNe = [P.array([P.int(1)])] + outside

        await P.assertSettledInEveryPlacement(
            "", "[int] .ne [1]",
            admitted: [P.array([P.int(2)])],
            refused: refusedByNe)

        await P.assertSettledInEveryPlacement(
            "\na = [int]", "a .ne [1]",
            admitted: [P.array([P.int(2)])],
            refused: refusedByNe)
    }

    /// A controller denoting values the target does not admit leaves `.eq` with
    /// no value to be equal to, so no document is admitted.
    @Test func equalityWithAControllerOutsideTheTargetAdmitsNoDocument() async {
        await P.assertSettledInEveryPlacement(
            "", "{k: int} .eq {z: 1}",
            admitted: [],
            refused: [P.map([("z", P.int(1))]), P.map([("k", P.int(1))])])

        await P.assertSettledInEveryPlacement(
            "", "[int] .eq [\"s\"]",
            admitted: [],
            refused: [P.array([P.text("s")]), P.array([P.int(1)])])
    }

    /// A literal is a type that denotes one value, so it stands as the target
    /// of an equality operator.
    @Test func aLiteralTargetOfAnEqualityOperatorIsReadAsTheTypeItNames() async {
        let admitted = [P.int(5)]
        let refused = [P.int(1), P.text("x"), P.map([])]

        for typeExpr in ["5 .ne 1", "5 .eq 5"] {
            await P.assertSettledInEveryPlacement("", typeExpr, admitted: admitted, refused: refused)
        }

        await P.assertSettledInEveryPlacement("\nfive = 5", "five .ne 1", admitted: admitted, refused: refused)

        await P.assertSettledInEveryPlacement(
            "", "\"x\" .ne \"y\"",
            admitted: [P.text("x")],
            refused: [P.text("y"), P.int(5), P.map([])])

        // A literal equal to nothing the controller denotes admits nothing.
        await P.assertSettledInEveryPlacement("", "5 .eq 6", admitted: [], refused: [P.int(5)])
        await P.assertSettledInEveryPlacement("", "5 .ne 5", admitted: [], refused: [P.int(5)])
    }

    /// A comparison relates the data item to the bound, so an integer stands
    /// in a comparison with a float bound.
    @Test func anIntegerComparedAgainstAFloatBoundIsSettledAlikeByBothValidators() async {
        await P.assertSettledInEveryPlacement(
            "", "uint .gt 1.5", admitted: [P.int(5), P.int(2)], refused: [P.int(1), P.int(0)])

        await P.assertSettledInEveryPlacement(
            "", "int .lt 1.5", admitted: [P.int(-2), P.int(1)], refused: [P.int(5), P.int(2)])

        await P.assertSettledInEveryPlacement(
            "", "int .ge 1.5", admitted: [P.int(2)], refused: [P.int(1), P.int(-2)])

        await P.assertSettledInEveryPlacement(
            "", "int .le 1.5", admitted: [P.int(1)], refused: [P.int(2)])
    }

    /// The target a data item failed to be of is named as the schema writes
    /// it, led by the noun the CBOR data model has for its shape.
    @Test func theTargetAnEqualityOperatorRejectsAgainstIsNamedAlikeByBothValidators() async {
        let cases: [(String, String)] = [
            ("root = {k: int} .ne {k: 1}", "expected map { k: int }, got "),
            ("root = {k: int} .eq {k: 1}", "expected map { k: int }, got "),
            ("root = [int] .ne [1]", "expected array [ int ], got "),
            ("root = [int] .eq [1]", "expected array [ int ], got "),
        ]
        for (schema, prefix) in cases {
            let reasons = await P.reasons(schema, P.int(5))

            #expect(reasons.count == 1, "\(schema)")
            #expect(reasons.first?.hasPrefix(prefix) == true, "\(reasons)")
        }
    }

    /// A literal stands as the target of a comparison operator: the data item
    /// is held to that value, and the bound then constrains it (RFC 8610
    /// Section 3.8.6).
    @Test func aLiteralTargetOfAComparisonOperatorIsReadAsTheTypeItNames() async {
        let admitted = [P.int(5)]
        let refused = [P.int(1), P.int(10), P.text("x"), P.map([])]

        // A bound the value satisfies leaves the type admitting just that value.
        for typeExpr in ["5 .lt 10", "5 .le 5", "5 .gt 1", "5 .ge 5"] {
            await P.assertSettledInEveryPlacement("", typeExpr, admitted: admitted, refused: refused)
        }

        // The same type reached through a name states the same thing.
        for typeExpr in ["five .lt 10", "five .le 5", "five .gt 1", "five .ge 5"] {
            await P.assertSettledInEveryPlacement("\nfive = 5", typeExpr, admitted: admitted, refused: refused)
        }

        // A bound the value does not satisfy leaves the type admitting nothing.
        for typeExpr in ["5 .lt 5", "5 .le 1", "5 .gt 10", "5 .ge 10"] {
            await P.assertSettledInEveryPlacement("", typeExpr, admitted: [], refused: admitted)
            let named = "five" + typeExpr.dropFirst()
            await P.assertSettledInEveryPlacement("\nfive = 5", named, admitted: [], refused: admitted)
        }

        // The operators are defined only for numeric types.
        for typeExpr in ["\"x\" .lt 10", "h'78' .gt 1"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr, admitted: [], refused: [P.text("x"), P.int(5)])
        }
    }

    /// A float stands in a comparison with an integer bound just as an integer
    /// stands in one with a float bound.
    @Test func aFloatComparedAgainstAnIntegerBoundIsSettledAlikeByBothValidators() async {
        await P.assertSettledInEveryPlacement(
            "", "float .lt 10",
            admitted: [P.float(1.5), P.float(-2.5)],
            refused: [P.float(12.5), P.float(10.0)])

        await P.assertSettledInEveryPlacement(
            "", "float .le 10",
            admitted: [P.float(10.0), P.float(1.5)],
            refused: [P.float(12.5)])

        await P.assertSettledInEveryPlacement(
            "", "float .gt 1",
            admitted: [P.float(1.5)],
            refused: [P.float(1.0), P.float(0.5)])

        await P.assertSettledInEveryPlacement(
            "", "float .ge 1",
            admitted: [P.float(1.0), P.float(1.5)],
            refused: [P.float(0.5)])

        // A float literal target is held to the same way, and its bound may
        // be an integer.
        await P.assertSettledInEveryPlacement(
            "", "1.5 .lt 10",
            admitted: [P.float(1.5)],
            refused: [P.float(2.5), P.int(1)])

        await P.assertSettledInEveryPlacement("", "1.5 .gt 10", admitted: [], refused: [P.float(1.5)])
    }

    /// RFC 8610 Appendix D defines `number = int / float`, and `number .ge 0`
    /// admits a number of either kind that stands above the bound.
    @Test func aNumberTargetAdmitsANumberWrittenEitherWayInBothValidators() async {
        let numbers = [P.int(0), P.int(5), P.float(1.5), P.float(0.0)]
        let others = [P.text("x"), CBORNode.null, P.map([])]

        await P.assertSettledInEveryPlacement("", "number", admitted: numbers, refused: others)

        let refusedByGe = [P.int(-1), P.float(-1.5)] + others

        await P.assertSettledInEveryPlacement("", "number .ge 0", admitted: numbers, refused: refusedByGe)

        await P.assertSettledInEveryPlacement(
            "", "number .gt 0",
            admitted: [P.int(5), P.float(1.5)],
            refused: [P.int(0), P.float(0.0), P.float(-1.5)])

        // A name standing for the same type states the same thing.
        await P.assertSettledInEveryPlacement("\nn = number", "n .ge 0", admitted: numbers, refused: refusedByGe)
    }

    /// Only an occurrence indicator says that a map entry may be absent; a
    /// control operator on the map type does not excuse an entry.
    @Test func aControlOperatorOnAMapTypeDoesNotExcuseAnEntryTheGroupNames() async {
        await P.assertSettledInEveryPlacement(
            "", "{a: any} .default {}",
            admitted: [P.map([("a", P.int(1))])],
            refused: [P.map([]), P.map([("b", P.int(1))])])

        // The entry the group names is not answered by an entry of another
        // name that happens to be of the value's type.
        await P.assertSettledInEveryPlacement(
            "", "{a: {b: int}} .default {}",
            admitted: [P.map([("a", P.map([("b", P.int(1))]))])],
            refused: [P.map([("b", P.int(1))]), P.map([])])

        // A name standing for the same map type is read the same way.
        await P.assertSettledInEveryPlacement(
            "\nm = {a: any}", "m .default {}",
            admitted: [P.map([("a", P.int(1))])],
            refused: [P.map([])])
    }

    /// A group with no entries admits only the empty map or the empty array,
    /// under a control operator as much as away from one, and the rejection
    /// names the shape.
    @Test func aControlOperatorOnAnEmptyMapOrArrayTypeAdmitsNoOther() async {
        await P.assertSettledInEveryPlacement(
            "", "{} .default {a: int}",
            admitted: [P.map([])],
            refused: [P.map([("k", P.int(1))])])

        await P.assertSettledInEveryPlacement(
            "", "[] .default [1]",
            admitted: [P.array([])],
            refused: [P.array([P.int(1)])])

        let cases: [(String, CBORNode, String)] = [
            ("root = {} .default {a: int}", P.map([("k", P.int(1))]), "expected empty map, got "),
            ("root = [] .default [1]", P.array([P.int(1)]), "expected empty array, got "),
        ]
        for (schema, document, prefix) in cases {
            let reasons = await P.reasons(schema, document)

            #expect(reasons.count == 1, "\(schema): \(reasons)")
            #expect(reasons.first?.hasPrefix(prefix) == true, "\(reasons)")
        }
    }

    /// A name among the integer types constrains the sign as well as the kind
    /// (RFC 8610 Appendix D), and a control operator narrows it rather than
    /// replacing it.
    @Test func anIntegerTargetKeepsItsSignUnderAControlOperator() async {
        for typeExpr in ["nint .le 10", "nint .ne \"x\"", "nint .eq -2", "nint .lt 0"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr, admitted: [P.int(-2)], refused: [P.int(5), P.int(0)])
        }

        for typeExpr in ["uint .ge 0", "uint .ne \"x\""] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr, admitted: [P.int(5), P.int(0)], refused: [P.int(-2)])
        }

        // A name standing for the same type states the same thing.
        await P.assertSettledInEveryPlacement(
            "\nn = nint", "n .le 10", admitted: [P.int(-2)], refused: [P.int(5), P.int(0)])
    }

    /// RFC 8610 Section 2.2.1 makes parenthesization syntactic, so a target
    /// keeps the type it denotes when it is written inside parentheses.
    @Test func anEqualityControlReadsAParenthesizedTargetAsTheTypeItEncloses() async {
        let cases: [(String, [CBORNode], [CBORNode])] = [
            ("\nt = (int) .eq 5", [P.int(5)], [P.int(6), P.text("x")]),
            ("\nt = ((int)) .eq 5", [P.int(5)], [P.int(6), P.text("x")]),
            ("\nt = (tstr) .eq \"x\"", [P.text("x")], [P.text("y"), P.int(5)]),
            ("\nt = (0..10) .eq 5", [P.int(5)], [P.int(6), P.int(20)]),
            ("\nt = (int) .ne 5", [P.int(6)], [P.int(5), P.text("x")]),
            ("\nt = (tstr) .ne \"x\"", [P.text("y")], [P.text("x"), P.int(5)]),
            // What an ordering operator makes of the same target.
            ("\nt = (int) .lt 10", [P.int(5)], [P.int(20), P.text("x")]),
        ]
        for (prelude, admitted, refused) in cases {
            await P.assertSettledInEveryPlacement(prelude, "t", admitted: admitted, refused: refused)
        }
    }

    /// RFC 8610 Section 3.8.6 defines `.eq` and `.ne` for values of every type,
    /// so a target that is not a type name is held to the way any other type
    /// expression is.
    @Test func anEqualityControlHoldsADataItemToATargetThatIsNotATypeName() async {
        // A group choice enumeration denotes the values its alternatives hold.
        await P.assertSettledInEveryPlacement(
            "", "&(a: 1, b: 2) .eq 1",
            admitted: [P.int(1)],
            refused: [P.int(2), P.int(3), P.text("x")])

        await P.assertSettledInEveryPlacement(
            "", "&(a: 1, b: 2) .ne 1",
            admitted: [P.int(2)],
            refused: [P.int(1), P.int(3)])

        // `any` admits every data item, so the controller alone settles it.
        await P.assertSettledInEveryPlacement(
            "", "any .eq 5", admitted: [P.int(5)], refused: [P.int(6), P.text("x")])

        await P.assertSettledInEveryPlacement(
            "", "any .ne 5", admitted: [P.int(6), P.text("x")], refused: [P.int(5)])
    }

    /// A member key states the type of the keys the entry answers for, however
    /// the type is written.
    @Test func aMemberKeyNamingATypeAnswersForTheKeysOfThatType() async {
        let one = P.map([("a", P.int(1))])
        let two = P.map([("a", P.int(1)), ("b", P.int(2))])

        for typeExpr in ["{* any => any}", "{+ any => any}"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr,
                admitted: [one, two, P.map([("a", P.text("x"))])],
                refused: [P.int(1)])
        }

        await P.assertSettledInEveryPlacement(
            "", "{* any => any}", admitted: [P.map([])], refused: [P.int(1)])

        // An entry standing for one occurrence answers for one key.
        await P.assertSettledInEveryPlacement(
            "", "{any => any}", admitted: [one], refused: [two, P.map([])])

        // A member key written as a choice answers for the keys of either
        // alternative, in whichever order the alternatives are written.
        for typeExpr in [
            "{* (int / tstr) => int}",
            "{* (tstr / int) => int}",
            "{* tstr => int}",
            "{* (tstr) => int}",
        ] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr,
                admitted: [one, two, P.map([])],
                refused: [P.map([("a", P.text("x"))])])
        }

        for typeExpr in ["{(int / tstr) => int}", "{(tstr / int) => int}"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr,
                admitted: [one],
                refused: [P.map([]), P.map([("a", P.text("x"))])])
        }

        // A member key choice no alternative of which admits a text string
        // answers for no text-keyed entry.
        for typeExpr in ["{* (uint / nil) => int}", "{* (int / nil) => int}", "{* (bool / nil) => int}"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr, admitted: [P.map([])], refused: [one, two])
        }

        // The same choice under `+` requires an entry it answers for.
        await P.assertSettledInEveryPlacement(
            "", "{+ (uint / nil) => int}", admitted: [], refused: [P.map([]), one])
    }

    /// A text string that is not a URI (RFC 3986) is a document the schema
    /// refuses, rather than a reason to end the whole validation.
    @Test func aTextStringThatIsNotAUriIsRefusedRatherThanAborting() async {
        await P.assertSettledInEveryPlacement(
            "", "uri",
            admitted: [P.text("http://x/"), P.text("a:b")],
            refused: [P.text("::"), P.text("2020-01-01T00:00:00Z"), P.text("a"), P.text("")])

        // A member key naming the type holds each key of the map to it.
        await P.assertSettledInEveryPlacement(
            "", "{* uri => any}",
            admitted: [P.map([("http://x/", P.int(0))]), P.map([])],
            refused: [
                P.map([("::", P.int(0))]),
                P.map([("2020-01-01T00:00:00Z", P.int(0))]),
                P.map([("a", P.int(0))]),
            ])
    }

    /// A float literal's notation is how it was spelled rather than what it
    /// denotes, so every spelling of one value admits and refuses the same
    /// data items.
    @Test func floatLiteralNotationDoesNotChangeWhatTheLiteralAdmits() async {
        let admitted = [P.float(100.0)]
        let refused = [P.float(100.5), P.float(1e2 + 1.0), P.text("100.0")]

        for typeExpr in ["100.0", "1e2", "1.0e2", "1E2", "1e+2", "0x1.9p6"] {
            await P.assertSettledInEveryPlacement("", typeExpr, admitted: admitted, refused: refused)
        }

        // A controller is read as the value it denotes whichever notation
        // wrote it.
        for typeExpr in [
            "float .lt 1e2",
            "float .lt 100.0",
            "float .lt 0x1.9p6",
            "float .ne 1e2",
            "float .ne 100.0",
        ] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr, admitted: [P.float(99.0)], refused: [P.float(100.0)])
        }
    }

    /// `~name` denotes the group the type `name` holds (RFC 8610 Section 3.7),
    /// so inside an array it stands for the run of items that group describes;
    /// the same group written inline says the same thing.
    @Test func anUnwrappedArrayTypeDenotesTheGroupTheArrayHolds() async {
        let cases: [(String, String, String, [CBORNode], [CBORNode])] = [
            (
                "\ninner = [1]", "[~inner]", "[(1)]",
                [P.array([P.int(1)])],
                [
                    P.array([P.int(2)]),
                    P.array([P.array([P.int(1)])]),
                    P.array([]),
                    P.array([P.int(1), P.int(1)]),
                ]
            ),
            (
                "\ninner = [int, tstr]", "[~inner]", "[(int, tstr)]",
                [P.array([P.int(1), P.text("x")])],
                [
                    P.array([P.array([P.int(1), P.text("x")])]),
                    P.array([P.int(1)]),
                    P.array([P.text("x"), P.int(1)]),
                ]
            ),
            (
                "\ninner = [int, tstr]", "[0, ~inner, 9]", "[0, (int, tstr), 9]",
                [P.array([P.int(0), P.int(1), P.text("x"), P.int(9)])],
                [
                    P.array([P.int(0), P.int(9)]),
                    P.array([P.int(0), P.array([P.int(1), P.text("x")]), P.int(9)]),
                ]
            ),
            (
                "\ninner = [* int]", "[~inner]", "[(* int)]",
                [P.array([]), P.array([P.int(1)]), P.array([P.int(1), P.int(2)])],
                [P.array([P.text("x")])]
            ),
        ]

        for (prelude, unwrapped, inline, admitted, refused) in cases {
            await P.assertSettledInEveryPlacement(prelude, unwrapped, admitted: admitted, refused: refused)
            await P.assertSettledInEveryPlacement(prelude, inline, admitted: admitted, refused: refused)
        }

        // A control operator makes the entry a type of its own rather than a
        // group, so the array item stands against the unwrapped type itself.
        await P.assertSettledInEveryPlacement(
            "\ninner = [1]", "[~inner .eq [1]]",
            admitted: [P.array([P.array([P.int(1)])])],
            refused: [P.array([P.int(1)]), P.array([P.array([P.int(2)])])])

        // Where a type is called for rather than a group, an unwrapped name
        // denotes the type the wrapper holds, which is the array itself.
        let typePositions: [(String, CBORNode, [CBORNode])] = [
            (
                "root = ~inner\ninner = [1]",
                P.array([P.int(1)]),
                [P.array([P.int(2)]), P.int(1), P.array([P.array([P.int(1)])])]
            ),
            (
                "root = {k: ~inner}\ninner = [1]",
                P.map([("k", P.array([P.int(1)]))]),
                [
                    P.map([("k", P.array([P.int(2)]))]),
                    P.map([("k", P.int(1))]),
                    P.map([("k", P.array([P.array([P.int(1)])]))]),
                ]
            ),
        ]
        for (schema, admitted, refused) in typePositions {
            #expect(await P.reasons(schema, admitted) == [], "refused \(admitted) against \(schema)")
            for value in refused {
                #expect(!(await P.reasons(schema, value)).isEmpty, "admitted \(value) against \(schema)")
            }
        }
    }

    /// Under weights that count one kind of descent step alone, the smallest
    /// budget that admits a document is that count, and under mixed weights
    /// the weighted sum -- at the root, as a map value and as an array item.
    @Test func descentWeightsAreChargedAlikeByBothValidators() async {
        // Every level steps into one item and resolves four rule references:
        // the three aliases and the rule they resolve to.
        let prelude = P.chainedAliases(3)
        let levels = 5
        let document = P.nestedEmptyArrays(levels)

        // What each placement adds: at the root, the root rule's own reference
        // to `x` is resolved against the root item. A map value is one more
        // item to step into. An array item is one more item as well, and a
        // rule named as an array entry costs no reference.
        let placements: [(String, Int, Int, CBORNode)] = [
            ("root = x", levels, 1 + 4 * levels, document),
            ("root = { k: x }", levels + 1, 1 + 4 * levels, P.map([("k", document)])),
            ("root = [x]", levels + 1, 4 * levels, P.array([document])),
        ]

        for (root, placedLevels, hops, value) in placements {
            let schema = "\(root)\(prelude)"
            let bytes = value.encoded()
            let weightings: [((Int, Int), Int)] = [
                ((1, 0), placedLevels),
                ((0, 1), hops),
                ((7, 3), 7 * placedLevels + 3 * hops),
            ]
            for ((dataLevelCost, ruleHopCost), expected) in weightings {
                // The smallest budget up to 4096 that admits the document;
                // every refusal below it has to be the budget's own.
                var smallest: Int?
                for budget in 0...4096 {
                    let limits = ValidationLimits(
                        maxDescentCost: budget, dataLevelCost: dataLevelCost, ruleHopCost: ruleHopCost)
                    let verdict = await P.limited(schema, bytes, limits)
                    guard let verdict else {
                        smallest = budget
                        break
                    }
                    guard let issues = verdict.issues else {
                        Issue.record("expected validation errors, got \(verdict)")
                        break
                    }
                    let reasons = issues.map(\.reason)
                    guard reasons.allSatisfy({ $0.contains("maximum supported descent budget") }) else {
                        Issue.record("refused the document on other grounds at budget \(budget): \(reasons)")
                        break
                    }
                }
                #expect(smallest == expected, "weights \((dataLevelCost, ruleHopCost)) against \(root)")
            }
        }
    }

    /// A control or range operator on a parenthesized type states the same
    /// thing wherever the type stands.
    @Test func anOperatorOnAParenthesizedTypeIsSettledAlikeInEveryPlacement() async {
        let refused = [P.int(15), P.text("x")]

        await P.assertSettledInEveryPlacement("", "(int) .lt 10", admitted: [P.int(5)], refused: refused)
        await P.assertSettledInEveryPlacement("", "(int) .lt (10)", admitted: [P.int(5)], refused: refused)
        await P.assertSettledInEveryPlacement("", "(int) .eq 5", admitted: [P.int(5)], refused: refused)
        await P.assertSettledInEveryPlacement(
            "", "(1)..(20)", admitted: [P.int(5)], refused: [P.int(25), P.text("x")])
        await P.assertSettledInEveryPlacement(
            "\nbound = 10", "(int) .lt bound", admitted: [P.int(5)], refused: refused)
    }

    /// A map held to a map type by an equality operator is refused for its
    /// number of entries.
    @Test func mapEntryCountUnderEqualityIsWordedAlikeByBothValidators() async {
        let cases: [(String, CBORNode, String)] = [
            (
                "root = { a: int } .eq { a: int, b: int }",
                P.map([("a", P.int(1))]),
                "expected map with 2 entries, got 1"
            ),
            (
                "root = { a: int, b: int } .eq { a: int }",
                P.map([("a", P.int(1)), ("b", P.int(2))]),
                "expected map with 1 entry, got 2"
            ),
        ]
        for (schema, document, expected) in cases {
            let reasons = await P.reasons(schema, document)
            #expect(reasons.first == expected, "\(reasons)")
        }
    }

    /// `x = A` extended by `x /= B` denotes `x = A / B` (RFC 8610 Section 3.9),
    /// wherever `x` is used from and however deeply the data nests.
    @Test func aTypeExtendedByAlternativesDenotesTheChoiceInBothValidators() async {
        let admittedLeaf = P.int(5)
        // No alternative admits a negative integer.
        let refusedLeaf = P.int(-1)

        let pairs: [(String, String)] = [
            ("x = uint\nx /= [* x]\n", "x = uint / [* x]\n"),
            ("x = [* x]\nx /= uint\n", "x = [* x] / uint\n"),
            ("x = uint\nx /= [* r0]\nr0 = x\n", "x = uint / [* r0]\nr0 = x\n"),
            ("x = uint\nx /= {* tstr => x}\n", "x = uint / {* tstr => x}\n"),
            ("x = tstr\nx /= bool\nx /= [* x]\nx /= uint\n", "x = tstr / bool / [* x] / uint\n"),
            // A name that alternatives alone define is the choice of them.
            ("x /= [* x]\nx /= uint\n", "x = [* x] / uint\n"),
        ]
        for (extended, choice) in pairs {
            for levels in [0, 1, 2, 8, cborParityNestedChoiceDepth] {
                let documents = [
                    P.nestedArrays(levels, admittedLeaf),
                    P.nestedArrays(levels, refusedLeaf),
                    P.nestedMaps(levels, admittedLeaf),
                    P.nestedMaps(levels, refusedLeaf),
                ]
                for document in documents {
                    let extendedPlacements = P.placementsOfX(extended, document)
                    let choicePlacements = P.placementsOfX(choice, document)
                    for (lhs, rhs) in zip(extendedPlacements, choicePlacements) {
                        #expect(
                            await P.settled(lhs.schema, lhs.node) == (await P.settled(rhs.schema, rhs.node)),
                            "\(lhs.schema) and \(rhs.schema) were settled differently at \(levels) levels")
                    }
                }
            }
        }
    }

    /// A name that `/=` alternatives alone define -- a type socket that plugs
    /// have filled -- is the choice of those alternatives.
    @Test func aPluggedTypeSocketIsTheChoiceOfItsPlugsInBothValidators() async {
        let schema = "$v /= 12\n$v /= 13\nx = $v\n"

        let cases: [(CBORNode, Bool)] = [
            (P.int(12), true),
            (P.int(13), true),
            (P.int(14), false),
            (P.text("12"), false),
        ]
        for (document, admitted) in cases {
            for (placed, node) in P.placementsOfX(schema, document) {
                #expect(await P.settled(placed, node) == admitted, "\(placed) against \(document)")
            }
        }
    }

    /// `[~x]` splices the entries of the array `x` describes into the array,
    /// and those entries are `[~x]` again: a cycle no finite array satisfies.
    @Test func anUnwrappedArrayGroupReEnteringItsRuleIsRejectedByBothValidators() async {
        let schema = "x = [~x] / uint\n"
        let cycle = "rule x is defined in terms of itself without consuming any data"

        for levels in [1, 2, 8] {
            for (placed, node) in P.placementsOfX(schema, P.nestedArrays(levels, P.int(5))) {
                let reasons = await P.reasons(placed, node)
                #expect(reasons.contains(cycle), "\(placed) at \(levels) levels: \(reasons)")
            }
        }

        // The alternative that consumes the item still admits it.
        for (placed, node) in P.placementsOfX(schema, P.int(5)) {
            #expect(await P.settled(placed, node))
        }
    }

    /// A name unwrapped through a cycle of bare type names resolves to no rule.
    @Test func anUnwrapThroughACycleOfNamesIsRejectedAlikeByBothValidators() async {
        let schema = "x = [* ~y] / uint\ny = z\nz = y\n"
        let expected = "cannot unwrap identifier y, rule not found"

        for (placed, node) in P.placementsOfX(schema, P.nestedArrays(1, P.int(5))) {
            let reasons = await P.reasons(placed, node)
            #expect(reasons.contains(expected), "\(placed): \(reasons)")
        }

        for (placed, node) in P.placementsOfX(schema, P.int(5)) {
            #expect(await P.settled(placed, node))
        }
    }

    /// A group turned into a choice with `&` contributes the values its
    /// entries hold, and a group named from within itself contributes nothing
    /// further.
    @Test func aGroupTurnedIntoAChoiceThatNamesItselfIsSettledAlikeByBothValidators() async {
        let schema = "x = &g\ng = (a: 1, b: 2, g)\n"

        for (document, admitted) in [(P.int(1), true), (P.int(2), true), (P.int(3), false)] {
            for (placed, node) in P.placementsOfX(schema, document) {
                #expect(await P.settled(placed, node) == admitted, "\(placed) against \(document)")
            }
        }
    }

    /// Unwrapping resolves a rule against the item already held, so a chain of
    /// unwraps answers to the bound on rule nesting.
    @Test func aChainOfUnwrapsAgainstOneItemIsBoundedAlikeByBothValidators() async throws {
        // Each array rule splices the next into the same array; each map rule
        // resolves the next against the same map.
        let arrays = "x = [~y] / uint\ny = [~z]\nz = [~w]\nw = [uint]\n"
        let maps = "x = {~y}\ny = {~z}\nz = {~w}\nw = {a: uint}\n"
        let bound = "maximum supported rule nesting"

        for (schema, document) in [(arrays, P.nestedArrays(1, P.int(5))), (maps, P.map([("a", P.int(5))]))] {
            for (placed, node) in P.placementsOfX(schema, document) {
                #expect(await P.settled(placed, node), "\(placed)")

                // Three references resolved against the item: refused as a
                // limit under a bound of two, admitted under a bound of four.
                let cddl = try cddlFromStr(placed)
                let value = try decodeCBOR(node.encoded())

                for (maxRuleNesting, admitted) in [(2, false), (4, true)] {
                    let validator = CBORValidator(cddl: cddl, cbor: value)
                    validator.setMaxRuleNesting(maxRuleNesting)
                    var failure: CBORValidationError?
                    do {
                        try await validator.validate()
                    } catch {
                        failure = error
                    }

                    if admitted {
                        #expect(failure == nil, "\(placed): \(failure.map { "\($0)" } ?? "")")
                    } else {
                        let message = failure.map { "\($0)" } ?? ""
                        #expect(message.contains(bound), "\(placed): \(message)")
                    }
                }
            }
        }
    }

    /// A type choice admits a data item any of its alternatives admits (RFC
    /// 8610 Section 2.2.2), and an array-typed alternative is one alternative
    /// like any other.
    @Test func anArrayTypedAlternativeIsOneAlternativeAmongTheOthersInBothValidators() async {
        let five = P.array([P.int(5)])
        let bare = P.int(5)
        let empty = P.array([])
        let textItem = P.array([P.text("a")])
        let two = P.array([P.int(5), P.int(6)])
        let flag = CBORNode.bool(true)

        // Alternatives naming an array of one item.
        for b in ["[uint]", "[? uint]", "[x: uint]", "[1*1 uint]"] {
            let prelude = "\nb = \(b)"

            for typeExpr in ["b / uint", "b / uint / tstr", "uint / b / tstr", "uint / tstr / b", "(b / uint)"] {
                await P.assertSettledInEveryPlacement(
                    prelude, typeExpr, admitted: [five, bare], refused: [textItem, two, flag])
            }
        }

        // Alternatives naming an array of any number of items.
        for b in ["[* uint]", "[+ uint]"] {
            let prelude = "\nb = \(b)"

            for typeExpr in ["b / tstr", "b / tstr / uint"] {
                await P.assertSettledInEveryPlacement(
                    prelude, typeExpr, admitted: [five, two], refused: [textItem, flag])
            }
        }

        // An alternative written inline, and one naming the empty array.
        await P.assertSettledInEveryPlacement(
            "", "[uint] / uint", admitted: [five, bare], refused: [textItem, empty])
        await P.assertSettledInEveryPlacement(
            "\nb = []", "b / uint", admitted: [empty, bare], refused: [five, textItem])

        // A rule reaching itself through such a choice at every level.
        await P.assertSettledInEveryPlacement(
            "\nx = [x / uint]", "x",
            admitted: [five, P.array([P.array([P.int(5)])]), P.array([P.array([P.array([P.int(5)])])])],
            refused: [P.array([P.array([P.text("a")])]), bare])
    }

    /// An array type written where a group entry stands for items describes
    /// each of those items, not the array holding them.
    @Test func anInlineArrayTypeAsAnArrayEntryDescribesEachItemItStandsFor() async {
        let cases: [(String, [CBORNode], [CBORNode])] = [
            (
                "root = [* [uint]]",
                [P.array([]), P.array([P.array([P.int(5)]), P.array([P.int(6)])])],
                [
                    P.array([P.int(5)]),
                    P.array([P.array([P.int(5)]), P.array([P.text("j")])]),
                    P.array([P.array([P.int(5)]), P.int(6)]),
                ]
            ),
            (
                "root = [+ [uint]]",
                [P.array([P.array([P.int(5)])])],
                [P.array([]), P.array([P.int(5)])]
            ),
            (
                "root = [* ([uint] / uint)]",
                [
                    P.array([]),
                    P.array([P.array([P.int(5)]), P.int(5)]),
                    P.array([P.int(5), P.array([P.int(5)])]),
                ],
                [
                    P.array([P.array([P.int(5)]), P.text("x")]),
                    P.array([P.int(5), P.array([P.text("x")])]),
                ]
            ),
            (
                "root = [* (uint / [uint])]",
                [P.array([P.array([P.int(5)]), P.int(5)]), P.array([P.int(5), P.array([P.int(5)])])],
                [P.array([P.array([P.int(5)]), P.text("x")])]
            ),
            (
                "root = [uint, [uint]]",
                [P.array([P.int(5), P.array([P.int(5)])])],
                [P.array([P.int(5), P.int(5)]), P.array([P.array([P.int(5)]), P.int(5)])]
            ),
        ]
        for (schema, admitted, refused) in cases {
            for value in admitted {
                #expect(await P.reasons(schema, value) == [], "refused \(value) against \(schema)")
            }
            for value in refused {
                #expect(!(await P.reasons(schema, value)).isEmpty, "admitted \(value) against \(schema)")
            }
        }
    }

    /// A type defined in terms of itself through a choice made from a group is
    /// a chain of references resolved against one item, bounded like any
    /// other, and refused as a cycle rather than followed without end.
    @Test func aTypeReEnteringItselfThroughAChoiceFromAGroupIsSettledAlikeByBothValidators() async {
        let cases: [(String, CBORNode, Bool)] = [
            ("x = &(1, x)\n", P.int(1), true),
            ("x = &(1, x)\n", P.int(3), false),
            ("x = &(* x)\n", P.int(5), false),
            ("x = uint / &(int => &(x))\n", P.int(1), true),
            ("x = tstr / &(int => &(x))\n", P.int(1), false),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", P.int(1), true),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", P.int(3), true),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", P.int(4), false),
            ("x = &(a: 1, tstr)\n", P.text("a"), true),
            ("x = &(a: 1, tstr)\n", P.int(2), false),
            ("x = &g\ng = (a: 1, h)\nh = (b: 2, g)\n", P.int(2), true),
            ("x = &g\ng = (a: 1, h)\nh = (b: 2, g)\n", P.int(3), false),
        ]
        for (schema, document, admitted) in cases {
            for (placed, node) in P.placementsOfX(schema, document) {
                #expect(await P.settled(placed, node) == admitted, "\(placed) against \(document)")
            }
        }

        // A self-reference through the choice is named as the cycle it is.
        let expected = "rule x is defined in terms of itself without consuming any data"
        #expect(await P.reasons("x = &(1, x)\n", P.int(3)).contains(expected))
    }

    /// A container type a data item is not of is named as the schema writes
    /// it: on one line, braces or brackets around its group, entries separated
    /// by `, ` and none trailing, led by the CBOR noun for the shape.
    @Test func aContainerTypeADataItemIsNotOfIsNamedAsTheSchemaWritesIt() async {
        let person = "x = {\n  name: tstr,\n  age: uint,\n  ? nickname: tstr,\n}\n"
        let pair = "x = [name: tstr, age: uint]\n"
        let one = P.map([("name", P.text("Alice")), ("age", P.int(30))])
        let two = P.array([one, one])

        let cases: [(String, CBORNode, String)] = [
            (person, two, "expected map { name: tstr, age: uint, ? nickname: tstr }, got "),
            (person, P.int(5), "expected map { name: tstr, age: uint, ? nickname: tstr }, got "),
            (pair, one, "expected array [ name: tstr, age: uint ], got "),
            (pair, P.int(5), "expected array [ name: tstr, age: uint ], got "),
        ]
        for (schema, document, prefix) in cases {
            for (placed, reason) in await P.reasonsInEveryPlacement(schema, document) {
                #expect(reason.hasPrefix(prefix), "against \(placed): \(reason)")
            }
        }
    }

    /// A group longer than the rendering bound is cut to its head and the rest
    /// is counted; a group within the bound is rendered whole.
    @Test func aGroupLongerThanTheRenderingBoundIsCutToItsHead() async {
        let one = P.map([("name", P.text("Alice")), ("age", P.int(30))])
        let two = P.array([one, one])

        // Twenty entries: the four that name the type and a count of the
        // sixteen that do not.
        for (placed, reason) in await P.reasonsInEveryPlacement(P.wideMapSchema(20), two) {
            #expect(
                reason.hasPrefix("expected map { f0: uint, f1: uint, f2: uint, f3: uint, \u{2026} 16 more }, got "),
                "against \(placed): \(reason)")
        }

        for entries in [maxRenderedGroupEntries, maxRenderedGroupEntries + 1, maxRenderedGroupEntries + 16] {
            let prefix = "expected map \(P.wideMapHead(entries)), got "

            for document in [two, P.int(5)] {
                for (placed, reason) in await P.reasonsInEveryPlacement(P.wideMapSchema(entries), document) {
                    #expect(reason.hasPrefix(prefix), "against \(placed): \(reason)")
                }
            }
        }
    }

    /// A rendered type carries none of the schema's comments and stands on one
    /// line, however its group is laid out in the schema.
    @Test func aRenderedTypeCarriesNoCommentAndNoLineBreak() async {
        let body = "\n  a: int, ; the first\n  b: int, ; the second\n  c: int, ; more\n  d: int,\n  e: int, ; nearly\n  f: int, ; the last\n"
        let commentedMap = "x = {\(body)}\n"
        let commentedArray = "x = [\(body)]\n"
        let commentedTag = "x = #6.1({\(body)})\n"

        let cases: [(String, CBORNode, String)] = [
            (commentedMap, P.int(5), "expected map { a: int, b: int, c: int, d: int, \u{2026} 2 more }, got "),
            (
                commentedMap, P.array([P.int(1)]),
                "expected map { a: int, b: int, c: int, d: int, \u{2026} 2 more }, got "
            ),
            (commentedArray, P.int(5), "expected array [ a: int, b: int, c: int, d: int, \u{2026} 2 more ], got "),
            (
                commentedTag, P.int(5),
                "expected tagged data #6.1({ a: int, b: int, c: int, d: int, \u{2026} 2 more }), got "
            ),
        ]
        for (schema, document, prefix) in cases {
            for (placed, reason) in await P.reasonsInEveryPlacement(schema, document) {
                #expect(reason.hasPrefix(prefix), "against \(placed): \(reason)")
                #expect(
                    !reason.contains("\n") && !reason.contains("\t") && !reason.contains(";"),
                    "against \(placed): \(reason)")
            }
        }
    }

    /// A tagged type names the type it wraps through the same rendering, and
    /// each alternative of a choice of container types is named through it in
    /// a rejection of its own.
    @Test func aTaggedTypeAndEachAlternativeOfAChoiceAreRenderedThroughTheSameHead() async {
        let tagged = "x = #6.121([a: int, b: int, c: int, d: int, e: int, f: int])\n"
        let prefix = "expected tagged data #6.121([ a: int, b: int, c: int, d: int, \u{2026} 2 more ]), got "

        for (placed, node) in P.placementsOfX(tagged, P.int(5)) {
            let reasons = await P.reasons(placed, node)
            #expect(reasons.count == 1, "against \(placed): \(reasons)")
            #expect(reasons.first?.hasPrefix(prefix) == true, "against \(placed): \(reasons)")
        }

        // A tag of the wrong number is refused for the tagged type as a whole.
        let wrongTag = CBORNode.tagged(122, P.array((1...6).map { P.int(Int64($0)) }))
        let wrong = await P.reasons(tagged, wrongTag)
        #expect(wrong.count == 1, "\(wrong)")
        #expect(wrong.first?.hasPrefix(prefix) == true, "\(wrong)")

        let choice = "x = {a: int} / {b: int}\n"
        for (placed, node) in P.placementsOfX(choice, P.array([P.int(1)])) {
            let reasons = await P.reasons(placed, node)

            #expect(reasons.count == 2, "against \(placed): \(reasons)")
            guard reasons.count == 2 else { continue }
            #expect(reasons[0].hasPrefix("expected map { a: int }, got "), "\(reasons[0])")
            #expect(reasons[1].hasPrefix("expected map { b: int }, got "), "\(reasons[1])")
        }
    }

    /// The naming of a type moves no verdict: a map type admits the maps its
    /// group describes, and an array of them is what the array type admits.
    @Test func aNamedContainerTypeSettlesTheSameDocumentsInBothValidators() async {
        let prelude = "\nPerson = {\n  name: tstr,\n  age: uint,\n  ? nickname: tstr,\n}\nPersons = [+Person]\n"
        let alice = P.map([("name", P.text("Alice")), ("age", P.int(30))])
        let aliceNicknamed = P.map([("name", P.text("Alice")), ("age", P.int(30)), ("nickname", P.text("Ali"))])
        let two = P.array([alice, aliceNicknamed])

        await P.assertSettledInEveryPlacement(
            prelude, "Person",
            admitted: [alice, aliceNicknamed],
            refused: [two, P.int(5), P.map([]), P.map([("name", P.text("Alice"))])])

        await P.assertSettledInEveryPlacement(
            prelude, "Persons",
            admitted: [two, P.array([alice])],
            refused: [alice, P.int(5), P.array([]), P.array([alice, P.int(5)])])
    }

    /// An inline map type under an occurrence indicator holds each item of the
    /// run it stands for to the map type as a whole.
    @Test func anInlineMapTypeUnderAnOccurrenceIndicatorHoldsEachItemToTheMap() async {
        let a1 = P.map([("a", P.int(1))])

        for typeExpr in ["[* {a: int}]", "[+ {a: int}]", "[* ({a: int})]"] {
            await P.assertSettledInEveryPlacement(
                "", typeExpr,
                admitted: [P.array([a1]), P.array([a1, P.map([("a", P.int(2))])])],
                refused: [
                    P.array([P.array([P.int(1)])]),
                    P.array([P.array([])]),
                    P.array([P.int(5)]),
                    P.array([.null]),
                    P.array([P.map([("a", P.int(1)), ("b", P.int(2))])]),
                    P.array([P.map([])]),
                    P.array([a1, P.array([P.int(1)])]),
                ])
        }

        await P.assertSettledInEveryPlacement(
            "", "[* {a: int, b: tstr}]",
            admitted: [P.array([P.map([("a", P.int(1)), ("b", P.text("x"))])])],
            refused: [P.array([P.array([P.int(1), P.text("x")])]), P.array([a1])])

        await P.assertSettledInEveryPlacement(
            "", "[* {? a: int}]",
            admitted: [P.array([]), P.array([P.map([])]), P.array([a1])],
            refused: [P.array([P.array([])]), P.array([P.array([P.int(1)])]), P.array([P.map([("b", P.int(1))])])])

        await P.assertSettledInEveryPlacement(
            "", "[* {* tstr => int}]",
            admitted: [P.array([P.map([])]), P.array([P.map([("a", P.int(1)), ("b", P.int(2))])])],
            refused: [P.array([P.array([P.int(1)])]), P.array([P.map([("a", P.text("x"))])])])

        await P.assertSettledInEveryPlacement(
            "", "[uint, * {a: int}]",
            admitted: [P.array([P.int(1)]), P.array([P.int(1), a1])],
            refused: [P.array([P.int(1), P.array([P.int(1)])]), P.array([a1])])

        // The item is refused as not being the map type, named as the schema
        // writes it, whichever way the occurrence is written.
        let nested = P.array([P.array([P.int(1)])])
        for schema in ["x = [* {a: int}]\n", "x = [+ {a: int}]\n", "x = [{a: int}]\n", "x = [* m]\nm = {a: int}\n"] {
            for (placed, reason) in await P.reasonsInEveryPlacement(schema, nested) {
                #expect(reason.hasPrefix("expected map { a: int }, got "), "against \(placed): \(reason)")
            }
        }

        let extra = P.array([P.map([("a", P.int(1)), ("b", P.int(2))])])
        for schema in ["x = [* {a: int}]\n", "x = [+ {a: int}]\n", "x = [{a: int}]\n"] {
            for (placed, reason) in await P.reasonsInEveryPlacement(schema, extra) {
                #expect(reason == "unexpected key \"b\"", "against \(placed)")
            }
        }
    }
}
