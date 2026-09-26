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

/// A map with text keys, in order.
private func textMap(_ entries: [(String, CBORNode)]) -> CBORNode {
    .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
}

/// A map from each of `keys` to 1.
private func integerKeyedMap(_ keys: [Int64]) -> CBORNode {
    .map(keys.map { (key: CBORNode.integer($0), value: CBORNode.integer(1)) })
}

/// Validation of recursive rules, member keys, the locations errors carry,
/// runs of array items, generics (RFC 8610 Section 3.10), tagged alternatives
/// and map member keys that are types.
@Suite
struct CBORValidationStructureTests {
    /// A rule reference stands for the rule's definition wherever it occurs
    /// (RFC 8610 Appendix C), so recursion through a homogeneous occurrence is
    /// checked at every nesting level and a failure reported where it happens.
    @Test func recursiveRuleValidatesEveryNestingLevel() async {
        let cddl = "data = int / tstr / [* data]"

        await expectValidNode(cddl, .array([.integer(1), .array([.text("a"), .array([.integer(2)])])]))

        // The float two levels down satisfies none of the type choices.
        let message = await failureText(cddl, .array([.array([shortestFloat(2.5)])]))
        #expect(message.contains("/0/0"), "got:\n\(message)")
    }

    /// A rule referenced from an array entry describes the item at that
    /// entry's position, so recursion through it is checked one item at a
    /// time and the occurrence indicator decides when it ends.
    @Test func recursiveRuleThroughOptionalEntryValidatesEveryNestingLevel() async {
        let cddl = "a = [int, ? a]"

        for node in [
            CBORNode.array([.integer(1)]),
            .array([.integer(1), .array([.integer(2)])]),
            .array([.integer(1), .array([.integer(2), .array([.integer(3)])])]),
        ] {
            await expectValidNode(cddl, node)
        }

        let message = await failureText(cddl, .array([.integer(1), .array([.integer(2), .array([.text("x")])])]))
        #expect(message.contains("/1/1/0"), "got:\n\(message)")
    }

    /// Recursion that steps into nested data is productive, so a failure under
    /// it is reported as the data item that does not match, not as a cycle.
    @Test func productiveRecursionReportsTheItemThatFails() async {
        let cddl = """
            list = [int, next]
            next = list / null

            """

        await expectValidNode(cddl, .array([.integer(1), .array([.integer(2), .null])]))

        let message = await failureText(cddl, .array([.integer(1), .array([.integer(2), shortestFloat(2.5)])]))
        #expect(message.contains("/1/1"), "got:\n\(message)")
        #expect(!message.contains("without consuming any data"), "got:\n\(message)")
    }

    /// A cycle reached from a type choice another choice satisfies leaves the
    /// document valid; a cycle no choice escapes does not.
    @Test func cycleInALosingTypeChoiceDoesNotReject() async {
        for cddl in ["a = int / b\nb = a", "a = b / int\nb = a"] {
            await expectValidNode(cddl, .integer(1))

            await expectInvalidNode(cddl, .text("x"), "no choice matches a text string")
        }
    }

    /// A bareword member key is shorthand for the text string of that name
    /// (RFC 8610 Section 3.5.1), whatever the entry's value type contains.
    @Test func validateBarewordMemberKeyWithArrowInValueType() async {
        let cddl = "tx = { aux : { * uint => uint } }"

        await expectValidNode(cddl, textMap([("aux", .map([(key: .integer(1), value: .integer(2))]))]))

        // The key is the text "aux", not a value of a type named `aux`.
        await expectInvalidNode(
            cddl, .map([(key: .integer(1), value: .map([(key: .integer(1), value: .integer(2))]))]),
            "1 is not the text key \"aux\"")
    }

    /// The arrow member key form means the key has to match the type, not
    /// equal the name of the type.
    @Test func validateType1MemberKeyIsNotATextKey() async {
        let cddl = "tx = { uint => tstr }"

        await expectValidNode(cddl, .map([(key: .integer(1), value: .text("x"))]))

        await expectInvalidNode(cddl, textMap([("uint", .text("x"))]), "\"uint\" is not a value of type uint")
    }

    /// A component of the reported location names a key of the data item, so
    /// every component of a path renders the same way, whatever the CDDL
    /// literal that matched it had to escape.
    @Test func cborLocationNamesTheDataKey() async {
        let cddl = "tx = { tstr => inner }\n" + #"inner = { "a\\b": uint }"#

        let data = textMap([("a\\b", textMap([("a\\b", .text("x"))]))])

        var message = await failureText(cddl, data)
        #expect(message.contains(#"/"a\b"/"a\b""#), "got:\n\(message)")
        #expect(!message.contains(#"/"a\\b""#), "got:\n\(message)")

        // A key that needs no escaping renders the same either way.
        message = await failureText(#"tx = { "ab": uint }"#, textMap([("ab", .text("x"))]))
        #expect(message.contains(#"/"ab""#), "got:\n\(message)")
    }

    /// A key that is neither text nor an integer is named in the notation of
    /// the CDDL literal for the same data item, so the path component can be
    /// matched against the member key describing it.
    @Test func cborLocationNamesANonTextDataKey() async {
        // (member key, the key as a data item, the component naming it)
        let cases: [(String, CBORNode, String)] = [
            ("1.5", shortestFloat(1.5), "/1.5"),
            ("-1.5", shortestFloat(-1.5), "/-1.5"),
            // An integer and a float of equal value are distinct keys, so the
            // component keeps the fraction that tells them apart.
            ("1.0", shortestFloat(1.0), "/1.0"),
            ("h'0102'", .bytes([0x01, 0x02]), "/h'0102'"),
            ("true", .bool(true), "/true"),
        ]

        for (memberKey, key, component) in cases {
            let cddl = "tx = { \(memberKey) => uint }"

            await expectValidNode(cddl, .map([(key: key, value: .integer(1))]), "\(memberKey) holds 1")

            let message = await failureText(cddl, .map([(key: key, value: .text("x"))]))
            #expect(message.contains(component), "\(memberKey) names its entry \(component), got:\n\(message)")
        }
    }

    /// The key of an entry no group entry accounts for is named the way every
    /// other key is.
    @Test func unaccountedEntryNamesItsKey() async {
        // (the key as a data item, how the message names it)
        let cases: [(CBORNode, String)] = [
            (shortestFloat(2.5), "unexpected key 2.5"),
            (.bytes([0x03, 0x04]), "unexpected key h'0304'"),
            (.bool(false), "unexpected key false"),
            (.text("k"), #"unexpected key "k""#),
            // No float literal denotes these, so each is spelled out rather
            // than approximated by one denoting a different data item.
            (shortestFloat(.nan), "unexpected key NaN"),
            (shortestFloat(.infinity), "unexpected key Infinity"),
            (shortestFloat(-.infinity), "unexpected key -Infinity"),
        ]

        for (key, named) in cases {
            let data = CBORNode.map([(key: .integer(1), value: .integer(1)), (key: key, value: .integer(1))])

            let message = await failureText("tx = { 1 => uint }", data)
            #expect(message.contains(named), "expected \(named), got:\n\(message)")
        }
    }

    /// `true` and `false` each name one data item, so in member key position
    /// each names the entry held under that key, and the entry's value is what
    /// the entry's type is held to.
    @Test func boolLiteralMemberKeyNamesTheEntryValue() async {
        var cddl = "tx = { true => uint, false => tstr }"

        await expectValidNode(
            cddl, .map([(key: .bool(true), value: .integer(1)), (key: .bool(false), value: .text("x"))]))

        // Swapping the two values fails both entries.
        var message = await failureText(
            cddl, .map([(key: .bool(true), value: .text("x")), (key: .bool(false), value: .integer(1))]))
        #expect(message.contains("/true"), "got:\n\(message)")
        #expect(message.contains("/false"), "got:\n\(message)")
        #expect(
            !message.contains("got object"),
            "the mismatch is about the entry's value, not the map, got:\n\(message)")

        // A map holding no entry under the key is missing the entry.
        message = await failureText(cddl, .map([(key: .bool(false), value: .text("x"))]))
        #expect(message.contains("map missing key: true"), "got:\n\(message)")

        // An optional entry the map does not hold is absent rather than wrong.
        cddl = "tx = { ? true => uint }"
        await expectValidNode(cddl, .map([]))
    }

    /// An entry under an occurrence indicator covering more than one item
    /// stands for a run of them, and a control operator on it describes every
    /// item of the run.
    @Test func validateControlOperatorAppliesToEveryItemOfARun() async {
        for cddl in [
            "start = [* uint .size 2]",
            "start = [+ uint .size 2]",
            "start = [2*4 uint .size 2]",
            "start = [* (uint .size 2)]",
        ] {
            await expectValidNode(cddl, .array([.integer(1), .integer(2)]), "\(cddl) must admit two narrow items")

            let message = await failureText(cddl, .array([.integer(1), .integer(70_000)]))
            #expect(
                message.contains("cbor location /1") && message.contains(".size 2"), "for \(cddl) got:\n\(message)")
        }

        // Every control reaches every item of the run, not only `.size`.
        var message = await failureText("start = [* uint .lt 10]", .array([.integer(1), .integer(20)]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")

        message = await failureText("start = [* uint .bits 3]", .array([.integer(8), .integer(9)]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")

        // The target type is a precondition for every item of the run.
        message = await failureText("start = [* uint .size 2]", .array([.integer(1), .text("ab")]))
        #expect(
            message.contains("cbor location /1") && message.contains("expected type uint"), "got:\n\(message)")

        // A run is not uint-specific.
        message = await failureText("start = [* tstr .size 2]", .array([.text("ab"), .text("abc")]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")

        // An entry standing for one item describes the item at its own
        // position, and the run covers only the items left to it.
        let cddl = "start = [name: tstr, * uint .size 2]"
        await expectValidNode(cddl, .array([.text("n"), .integer(1), .integer(2)]))

        message = await failureText(cddl, .array([.text("n"), .integer(1), .integer(70_000)]))
        #expect(message.contains("cbor location /2"), "got:\n\(message)")
    }

    /// A range or a literal standing for a run of items describes every item
    /// of the run the way a control operator does.
    @Test func validateRangeAndLiteralApplyToEveryItemOfARun() async {
        var cddl = "start = [* 1..5]"
        await expectValidNode(cddl, .array([.integer(1), .integer(5)]))
        var message = await failureText(cddl, .array([.integer(1), .integer(9)]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")

        cddl = "start = [* 7]"
        await expectValidNode(cddl, .array([.integer(7), .integer(7)]))
        message = await failureText(cddl, .array([.integer(7), .integer(8)]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")
    }

    /// A type naming an array whose items fail is one the data item does not
    /// match, so a type choice holding it is not satisfied by it either.
    @Test func validateFailingRunItemIsNotSwallowedByATypeChoice() async {
        var cddl = "start = [* uint .size 2] / bool"
        await expectValidNode(cddl, .array([.integer(1), .integer(2)]))

        await expectInvalidNode(
            cddl, .array([.integer(1), .integer(70_000)]),
            "the array alternative does not match and bool does not either")

        cddl = "start = [* 1..5] / bool"
        await expectInvalidNode(cddl, .array([.integer(1), .integer(9)]))
    }

    /// A control operator whose target names a rule applies to the type the
    /// rule resolves to, directly or through further rules.
    @Test func validateControlOperatorWithARuleReferenceTarget() async {
        var cddl = """
            start = u .size 2
            u = uint

            """
        await expectValidNode(cddl, .integer(1))
        await expectInvalidNode(cddl, .integer(70_000))

        // The target type is still a precondition for the control.
        var message = await failureText(cddl, .text("x"))
        #expect(message.contains("expected type uint"), "got:\n\(message)")

        // A chain of references resolves to the same type.
        cddl = """
            start = u .bits 3
            u = u2
            u2 = uint

            """
        await expectValidNode(cddl, .integer(8))
        await expectInvalidNode(cddl, .integer(9))

        // Inside a run of array items, and as a rule of its own.
        cddl = """
            start = [* u .size 2]
            u = uint

            """
        message = await failureText(cddl, .array([.integer(1), .integer(70_000)]))
        #expect(message.contains("cbor location /1"), "got:\n\(message)")

        cddl = """
            start = [* narrow]
            narrow = uint .size 2

            """
        await expectValidNode(cddl, .array([.integer(1), .integer(2)]))
        await expectInvalidNode(cddl, .array([.integer(1), .integer(70_000)]))
    }

    /// An entry naming an array type under an occurrence indicator covering
    /// more than one item stands for a run of nested arrays, each held to the
    /// type the entry names.
    @Test func validateNestedArrayTypeAppliesToEveryItemOfARun() async {
        var cddl = "start = [* [* uint .size 2]]"
        await expectValidNode(cddl, .array([.array([.integer(1)]), .array([.integer(2)])]))

        var message = await failureText(cddl, .array([.array([.integer(1)]), .array([.integer(70_000)])]))
        #expect(message.contains("cbor location /1/0"), "got:\n\(message)")

        // The same holds for a nested array type carrying no control operator.
        cddl = "start = [* [int, tstr]]"
        await expectValidNode(cddl, .array([.array([.integer(1), .text("a")]), .array([.integer(2), .text("b")])]))

        message = await failureText(
            cddl, .array([.array([.integer(1), .text("a")]), .array([.text("b"), .integer(2)])]))
        #expect(message.contains("cbor location /1/"), "got:\n\(message)")

        // An item of the run that is not an array does not match the type.
        cddl = "start = [* [* uint]]"
        await expectInvalidNode(cddl, .array([.array([.integer(1)]), .integer(5)]))

        // An entry standing for a single item describes only its own position.
        cddl = "start = [[int], [tstr]]"
        await expectValidNode(cddl, .array([.array([.integer(1)]), .array([.text("a")])]))

        await expectInvalidNode(cddl, .array([.array([.integer(1)]), .array([.integer(2)])]))
    }

    /// A generic parameter is in scope in the rule declaring it and nowhere
    /// else (RFC 8610 Section 3.10). A rule reached from an instantiated rule
    /// reads its own names.
    @Test func validateGenericParameterIsScopedToTheRuleThatDeclaresIt() async {
        let cddl = """
            start = wrapper<5>
            wrapper<n> = inner
            inner = 0..n
            n = 2

            """
        await expectValidNode(cddl, .integer(2))
        await expectInvalidNode(
            cddl, .integer(3),
            "the bound of `inner` is the rule `n`, not the argument `wrapper` was instantiated with")

        // The same holds for a bound reached through an array item.
        let array = """
            start = wrapper<5>
            wrapper<n> = [n, inner]
            inner = 0..n
            n = 2

            """
        await expectValidNode(array, .array([.integer(5), .integer(2)]))
        await expectInvalidNode(array, .array([.integer(5), .integer(3)]))

        // With no rule of that name the bound is an undefined reference,
        // reported rather than resolved to the caller's argument.
        let undefined = """
            start = wrapper<5>
            wrapper<n> = inner
            inner = 0..n

            """
        let message = await failureText(undefined, .integer(3))
        #expect(message.contains("not found in CDDL rules"), "got:\n\(message)")

        // An identifier standing on its own reads the same way.
        let identifier = """
            start = wrapper<5>
            wrapper<n> = inner
            inner = n
            n = 2

            """
        await expectValidNode(identifier, .integer(2))
        await expectInvalidNode(identifier, .integer(5))

        // A parameter resolves throughout the rule declaring it, including
        // inside a nested array or map.
        let nested = """
            start = wrapper<5>
            wrapper<n> = [n, {k: 0..n}]

            """
        await expectValidNode(nested, .array([.integer(5), textMap([("k", .integer(4))])]))
        await expectInvalidNode(nested, .array([.integer(5), textMap([("k", .integer(6))])]))
    }

    /// The arguments of a generic rule reference belong to that one
    /// instantiation.
    @Test func validateGenericArgumentsBelongToOneInstantiation() async {
        let cddl = """
            start = [g<9>, g<2>]
            g<n> = 0..n

            """
        await expectValidNode(cddl, .array([.integer(1), .integer(2)]))
        await expectInvalidNode(cddl, .array([.integer(1), .integer(5)]), "the second item is held to `g<2>`")

        // The other order: the wider instantiation is not narrowed by the one
        // before it.
        let reversed = """
            start = [g<2>, g<9>]
            g<n> = 0..n

            """
        await expectValidNode(reversed, .array([.integer(1), .integer(5)]))
        await expectInvalidNode(reversed, .array([.integer(5), .integer(1)]))

        // The same in a map.
        let mapCDDL = """
            start = {x: g<9>, y: g<2>}
            g<n> = 0..n

            """
        func map(_ x: Int64, _ y: Int64) -> CBORNode {
            textMap([("x", .integer(x)), ("y", .integer(y))])
        }
        await expectValidNode(mapCDDL, map(1, 2))
        await expectInvalidNode(mapCDDL, map(1, 5))

        // An identifier and a control operator read the arguments of their own
        // instantiation too.
        let identifier = """
            start = [g<9>, g<2>]
            g<n> = n

            """
        await expectValidNode(identifier, .array([.integer(9), .integer(2)]))
        await expectInvalidNode(identifier, .array([.integer(9), .integer(9)]))

        let control = """
            start = [g<9>, g<2>]
            g<n> = uint .le n

            """
        await expectValidNode(control, .array([.integer(1), .integer(2)]))
        await expectInvalidNode(control, .array([.integer(1), .integer(5)]))
    }

    /// An entry naming a generic rule under an occurrence indicator covering
    /// more than one item stands for a run, every item held to the rule as the
    /// entry instantiates it.
    @Test func validateGenericEntryAppliesToEveryItemOfARun() async {
        let cddl = """
            start = [* g<3>]
            g<n> = 0..n

            """
        await expectValidNode(cddl, .array([.integer(0), .integer(1), .integer(3)]))

        let message = await failureText(cddl, .array([.integer(0), .integer(1), .integer(4)]))
        #expect(message.contains("cbor location /2"), "got:\n\(message)")

        // `*` admits an empty run.
        await expectValidNode(cddl, .array([]))

        // The run starts at the entry's own position.
        let leading = """
            start = [tstr, * g<3>]
            g<n> = 0..n

            """
        await expectValidNode(leading, .array([.text("x"), .integer(1), .integer(2)]))

        await expectInvalidNode(leading, .array([.text("x"), .integer(1), .integer(9)]))

        // An optional entry imposes nothing when absent, and holds what is
        // present to the rule as instantiated.
        let optional = """
            start = {? g<3>}
            g<n> = (v: 0..n)

            """
        await expectValidNode(optional, .map([]))

        await expectValidNode(optional, textMap([("v", .integer(1))]))
        await expectInvalidNode(optional, textMap([("v", .integer(9))]))
    }

    /// An argument passed through to a further generic rule is resolved where
    /// it is written.
    @Test func validateRangeBoundThroughAChainOfInstantiations() async {
        let cddl = """
            start = outer<5>
            outer<n> = inner<n>
            inner<m> = 0..m

            """
        await expectValidNode(cddl, .integer(3))
        await expectInvalidNode(cddl, .integer(7))

        // The inner rule may be instantiated with a value of its own, which the
        // outer parameter does not displace.
        let direct = """
            start = outer<5>
            outer<n> = inner<2>
            inner<m> = 0..m

            """
        await expectValidNode(direct, .integer(1))
        await expectInvalidNode(direct, .integer(3))
    }

    /// A bound naming a rule that is present but denotes no value is reported
    /// as what that rule is, not as a missing name.
    @Test func validateRangeBoundNamingAGroupRuleIsReported() async {
        let message = await failureText(
            """
            start = 1..m
            m = (b: 1)

            """, .integer(1))
        #expect(message.contains("Group name 'm' does not resolve to a numeric value"), "got:\n\(message)")
        #expect(!message.contains("not found in CDDL rules"), "got:\n\(message)")
    }

    /// A type name matches a tagged data item only where it stands for a
    /// tagged type carrying that tag, so an alternative whose tag content
    /// fails leaves the choice to the others and, once they are exhausted,
    /// the choice fails.
    @Test func validateTaggedAlternativeOfATypeChoiceReportsItsContentFailure() async {
        for cddl in ["p = #6.121(int) / tstr", "p = tstr / #6.121(int)", "p = uint / #6.121(int)"] {
            let message = await failureText(cddl, .tagged(121, .bool(true)))
            #expect(message.contains("expected type int, got Bool(true)"), "\(cddl) :: got:\n\(message)")

            await expectValidNode(cddl, .tagged(121, .integer(5)), "\(cddl) admits valid tag content")
        }
    }

    /// The alternatives of a type choice are judged the same way wherever the
    /// choice appears.
    @Test func validateTaggedAlternativeOfATypeChoiceInsideAContainer() async {
        let inArray: (CBORNode) -> CBORNode = { .array([$0]) }
        let inMap: (CBORNode) -> CBORNode = { .map([(key: .integer(0), value: $0)]) }

        for (cddl, wrap) in [("p = [#6.121(int) / tstr]", inArray), ("p = {0: #6.121(int) / tstr}", inMap)] {
            await expectInvalidNode(cddl, wrap(.tagged(121, .bool(true))), "\(cddl) must reject a tag whose content fails")

            await expectValidNode(cddl, wrap(.tagged(121, .integer(5))), "\(cddl) admits valid tag content")

            await expectValidNode(cddl, wrap(.text("x")), "\(cddl) admits the other alternative")
        }
    }

    /// A tagged type defined in terms of itself is matched at every level of
    /// the data.
    @Test func validateRecursiveTaggedTypeAtEveryDepth() async {
        let cddl = "p = #6.121(int) / #6.122([p])"

        func nest(_ depth: Int, _ leaf: CBORNode) -> CBORNode {
            var node = CBORNode.tagged(121, leaf)
            for _ in 1..<depth {
                node = .tagged(122, .array([node]))
            }
            return node
        }

        for depth in [1, 3, 10] {
            await expectValidNode(cddl, nest(depth, .integer(7)), "depth \(depth) admits an int leaf")

            await expectInvalidNode(cddl, nest(depth, .bool(true)), "depth \(depth) must reject a bool leaf")
        }
    }

    /// A map alternative of a type choice fails on its content like any
    /// other.
    @Test func validateMapAlternativeOfATypeChoice() async {
        for cddl in ["p = {a: int} / tstr", "p = tstr / {a: int}"] {
            await expectInvalidNode(
                cddl, textMap([("a", .bool(true))]), "\(cddl) must reject data no alternative accepts")

            await expectValidNode(cddl, textMap([("a", .integer(1))]), "\(cddl) admits the map alternative")

            await expectValidNode(cddl, .text("z"), "\(cddl) admits the other alternative")
        }
    }

    /// An array alternative whose item fails is judged failed.
    @Test func validateArrayAlternativeOfATypeChoiceFailingOnAnItem() async {
        for cddl in ["p = [int] / tstr", "p = tstr / [int]", "p = [* int] / tstr"] {
            await expectInvalidNode(cddl, .array([.bool(true)]), "\(cddl) must reject an array whose item fails")

            await expectValidNode(cddl, .array([.integer(1)]), "\(cddl) admits the array alternative")

            await expectValidNode(cddl, .text("q"), "\(cddl) admits the other alternative")
        }
    }

    /// A prelude name standing for a tagged type (RFC 8610 Appendix D)
    /// matches the data item that type describes and only that one.
    @Test func validatePreludeTaggedTypeNamesAgainstTaggedData() async {
        func bignum(_ tag: UInt64) -> CBORNode {
            .tagged(tag, .bytes([1, 2]))
        }

        let cases: [(String, CBORNode, CBORNode)] = [
            ("p = biguint", bignum(2), bignum(3)),
            ("p = bignint", bignum(3), bignum(2)),
            ("p = bigint", bignum(3), bignum(4)),
            ("p = unsigned", bignum(2), bignum(3)),
            ("p = encoded-cbor", .tagged(24, .bytes([1])), .tagged(24, .integer(1))),
        ]
        for (cddl, admitted, rejected) in cases {
            await expectValidNode(cddl, admitted, "\(cddl) admits its own tagged type")
            await expectInvalidNode(cddl, rejected, "\(cddl) must reject another tagged data item")
        }

        // A name standing for no tagged type matches no tagged data item.
        for name in ["tstr", "bstr", "int", "uint", "bool", "nil", "float"] {
            await expectInvalidNode("p = \(name)", .tagged(121, .bool(true)), "\(name) must reject a tagged data item")
        }
    }

    /// A range in member key position denotes the keys the entry answers for,
    /// so each entry of the map is held to it in turn.
    @Test func validateMapRangeMemberKey() async {
        let cases: [(String, [[Int64]], [[Int64]])] = [
            // Zero or more: every key has to lie in the range, and the empty
            // map has no key that does not.
            ("m = {* 3..255 => int}", [[], [3], [255], [3, 4]], [[2], [256], [3, 2]]),
            // Exactly one occurrence, which an absent indicator states.
            ("m = {3..255 => int}", [[3]], [[], [2], [3, 4]]),
            // One or more requires at least one entry keyed in the range.
            ("m = {+ 3..255 => int}", [[3], [3, 4]], [[], [2]]),
            // Optional admits absence and one occurrence, and no more.
            ("m = {? 3..255 => int}", [[], [3]], [[2], [3, 4]]),
        ]
        for (cddl, admitted, rejected) in cases {
            for keys in admitted {
                await expectValidNode(cddl, integerKeyedMap(keys), "\(cddl) admits keys \(keys)")
            }

            for keys in rejected {
                await expectInvalidNode(cddl, integerKeyedMap(keys), "\(cddl) must reject keys \(keys)")
            }
        }

        // A range key accounts for the keys the literal key does not, in
        // either order of the two entries.
        for cddl in ["m = {? 0: int, * 3..255 => int}", "m = {* 3..255 => int, ? 0: int}"] {
            for keys: [Int64] in [[], [0], [3], [0, 3]] {
                await expectValidNode(cddl, integerKeyedMap(keys), "\(cddl) admits keys \(keys)")
            }

            for keys: [Int64] in [[2], [0, 2]] {
                await expectInvalidNode(cddl, integerKeyedMap(keys), "\(cddl) must reject keys \(keys)")
            }
        }

        // The type the entry names is the type of the values of the entries
        // its member key accounts for.
        let withTextValue = CBORNode.map([(key: .integer(3), value: .text("x"))])
        await expectInvalidNode("m = {* 3..255 => int}", withTextValue)
        await expectValidNode("m = {* 3..255 => tstr}", withTextValue, "the entry type holds")
    }

    /// A range reaches member key position written out, in parentheses, under
    /// a name, or under a generic parameter, each denoting the same keys.
    @Test func validateMapRangeMemberKeyWrittenIndirectly() async {
        for cddl in [
            "m = {* 3..255 => int}",
            "m = {* (3..255) => int}",
            "m = {* r => int}\nr = 3..255",
            "m = {* lo..hi => int}\nlo = 3\nhi = 255",
            "m = g<3..255>\ng<t> = {* t => int}",
            "m = g<(3..255)>\ng<t> = {* t => int}",
            "m = g<r>\ng<t> = {* t => int}\nr = 3..255",
        ] {
            for keys: [Int64] in [[], [3], [255], [3, 4, 255]] {
                await expectValidNode(cddl, integerKeyedMap(keys), "\(cddl) admits keys \(keys)")
            }

            for keys: [Int64] in [[2], [256], [3, 2]] {
                await expectInvalidNode(cddl, integerKeyedMap(keys), "\(cddl) must reject keys \(keys)")
            }
        }
    }

    /// A name in member key position states the type of the keys the entry
    /// answers for, held to the keys of the map one at a time.
    @Test func validateMapNamedMemberKeyMatchesKeys() async {
        func map(_ entries: [(CBORNode, CBORNode)]) -> CBORNode {
            .map(entries.map { (key: $0.0, value: $0.1) })
        }
        let text = CBORNode.text
        let int = CBORNode.integer

        var cddl = "m = {* k => int}\nk = tstr"
        for entries in [[], [(text("x"), int(1))], [(text("x"), int(1)), (text("y"), int(2))]] {
            await expectValidNode(cddl, map(entries), "\(entries) is admitted")
        }

        // A key not of the type is one no entry accounts for, and the type
        // the entry names still holds the values of the keys it does.
        for entries in [
            [(int(1), int(1))], [(text("x"), text("y"))], [(text("x"), int(1)), (int(2), int(2))],
        ] {
            await expectInvalidNode(cddl, map(entries), "\(entries) must be rejected")
        }

        // The occurrence indicator bounds how many entries the member key
        // accounts for, as it does for a range.
        let one = [(text("x"), int(1))]
        let two = [(text("x"), int(1)), (text("y"), int(2))]

        await expectValidNode("m = {k => int}\nk = tstr", map(one))
        await expectInvalidNode("m = {k => int}\nk = tstr", map([]))
        await expectInvalidNode("m = {k => int}\nk = tstr", map(two))

        await expectValidNode("m = {? k => int}\nk = tstr", map([]))
        await expectValidNode("m = {+ k => int}\nk = tstr", map(one))
        await expectInvalidNode("m = {+ k => int}\nk = tstr", map([]))

        await expectValidNode("m = {2*3 k => int}\nk = tstr", map(two))
        await expectInvalidNode("m = {2*3 k => int}\nk = tstr", map(one))

        // Two entries partition the keys, each accounting for its own type.
        cddl = "m = {* t => int, * n => tstr}\nt = tstr\nn = int"
        await expectValidNode(cddl, map([(text("x"), int(1)), (int(5), text("y"))]))
        await expectInvalidNode(cddl, map([(text("x"), text("z")), (int(5), text("y"))]))

        // A key of a composite type is held to the type like a scalar one.
        cddl = "m = {* k => int}\nk = [int, int]"
        await expectValidNode(cddl, map([(.array([int(1), int(2)]), int(3))]))
        for key in [CBORNode.array([int(1)]), .array([int(1), text("x")])] {
            await expectInvalidNode(cddl, map([(key, int(3))]), "\(key) is not a key of the type")
        }
    }

    /// A map type whose keys and values are the type the map is an
    /// alternative of describes a document that nests; stepping into the keys
    /// lets the recursion terminate.
    @Test func validateSelfReferentialMapType() async {
        let cddl = """
            start = p
            p = {* p => p} / int / tstr

            """

        for node in [
            CBORNode.map([]),
            .integer(1),
            .text("x"),
            textMap([("k", .integer(1))]),
            textMap([("k", .map([(key: .integer(2), value: .text("v"))]))]),
            .map([(key: .map([(key: .integer(1), value: .integer(2))]), value: .text("v"))]),
        ] {
            await expectValidNode(cddl, node, "\(node) is admitted")
        }

        // What the recursion ends in is held to the alternatives the name
        // offers.
        for node in [
            CBORNode.bool(true),
            textMap([("k", .bytes([]))]),
            .map([(key: .bytes([]), value: .integer(1))]),
        ] {
            await expectInvalidNode(cddl, node, "\(node) must be rejected")
        }
    }

    /// A member key name defined in terms of itself denotes no keys, and
    /// resolving it ends on the cycle rather than on the rule nesting bound,
    /// so raising that bound reports the same rejection.
    @Test func validateCyclicMemberKeyNameTerminatesAboveTheRuleNestingBound() async {
        let cddl = """
            m = {* r => int}
            r = r

            """

        let withKey = CBORNode.map([(key: .integer(4), value: .integer(1))]).encoded()

        for limits in [
            ValidationLimits(),
            ValidationLimits(maxRuleNesting: ValidationLimits.defaultMaxRuleNesting * 1024),
        ] {
            var failed = false
            do {
                try await validateCBOR(cddl: cddl, cbor: withKey, limits: limits)
            } catch {
                failed = true
            }
            #expect(failed, "a key of a type nothing satisfies is one no entry accounts for, at \(limits)")

            // The entry accounts for no key whatever the bound, so a map
            // holding none satisfies it.
            do {
                try await validateCBOR(cddl: cddl, cbor: CBORNode.map([]).encoded(), limits: limits)
            } catch {
                Issue.record("an empty map is admitted at \(limits): \(error)")
            }
        }
    }

    /// A bareword member key is shorthand for the text string of that name
    /// (RFC 8610 Section 3.5.1), whether or not a rule or prelude type
    /// carries the same name.
    @Test func validateMapBarewordMemberKeyIsTheNameItself() async {
        func entry(_ key: String) -> CBORNode {
            textMap([(key, .integer(1))])
        }

        for cddl in ["m = {k: int}\nk = tstr", "m = {? k: int}\nk = tstr", "m = {* k: int}\nk = tstr"] {
            await expectValidNode(cddl, entry("k"), "\(cddl) names the key k")

            await expectInvalidNode(cddl, entry("x"), "\(cddl) does not name the key x")
        }

        // A bareword carrying the name of a prelude type is that text string.
        await expectValidNode("m = {tstr: int}", entry("tstr"))
        await expectInvalidNode("m = {tstr: int}", entry("x"))

        // The arrow form of the same name is the type it stands for.
        await expectValidNode("m = {k => int}\nk = tstr", entry("x"))
    }
}
