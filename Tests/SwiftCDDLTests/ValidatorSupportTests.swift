import Testing

@testable import SwiftCDDL

/// The pieces the validator is built from: the arena that records the
/// locations a walk steps along, how a report past its byte budget is cut,
/// how types are named in messages, and how names resolve to the rules,
/// values and choices they stand for (RFC 8610 Sections 2 and 3).
@Suite struct ValidatorSupportTests {
    // MARK: - Private helpers

    private func record(_ reason: String, _ location: PathId) -> ErrorRecord {
        ErrorRecord(
            reason: reason,
            location: location,
            isMultiTypeChoice: false,
            isMultiGroupChoice: false,
            isGroupToChoiceEnum: false,
            typeGroupNameEntry: nil
        )
    }

    /// The type the first rule of `cddl` names.
    private func firstType(_ cddl: CDDL) throws -> Type {
        guard let rule = cddl.rules.first, case .type(let typeRule, _, _, _) = rule else {
            Issue.record("the first rule is a type rule")
            throw FirstRuleIsNotATypeRule()
        }
        return typeRule.value
    }

    private struct FirstRuleIsNotATypeRule: Error {}

    /// The single alternative of the first rule of `cddl`.
    private func firstType2(of cddl: CDDL) throws -> Type2 {
        let t = try firstType(cddl)
        return try #require(t.typeChoices.first).type1.type2
    }

    /// A rule's type rendered as a type head renders it.
    private func headOf(_ schema: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let cddl = try cddlFromStr(schema)
        let t = try firstType(cddl)
        #expect(t.typeChoices.count == 1, "one alternative: \(schema)", sourceLocation: sourceLocation)
        return typeHead(try #require(t.typeChoices.first).type1.type2)
    }

    // MARK: - Paths and reports

    @Test func aPathRendersAsTheValidatorsWriteALocation() {
        let paths = PathArena()
        #expect(paths.render(.root) == "")
        #expect(paths.depth(.root) == 0)

        let first = paths.child(.root, .index(3))
        let second = paths.child(first, .key("\"k\""))
        let third = paths.child(second, .index(0))
        #expect(paths.render(first) == "/3")
        #expect(paths.render(second) == "/3/\"k\"")
        #expect(paths.render(third) == "/3/\"k\"/0")
        #expect(paths.depth(third) == 3)
        #expect(paths.renderedLength(third) == paths.render(third).utf8.count)
        let wide = paths.child(third, .index(1234))
        #expect(paths.renderedLength(wide) == paths.render(wide).utf8.count)

        // Rows are appended, never rewritten: a sibling below the root leaves
        // every earlier location as it was.
        let sibling = paths.child(.root, .index(4))
        #expect(paths.render(sibling) == "/4")
        #expect(paths.render(third) == "/3/\"k\"/0")
    }

    /// A report within the budget is handed out whole and in order; one past
    /// it keeps the innermost errors, in the order they were recorded, up to
    /// what the budget renders, and the innermost of all however much that
    /// renders to.
    @Test func aReportPastTheBudgetKeepsTheInnermostErrorsInRecordedOrder() throws {
        let paths = PathArena()
        var at = PathId.root
        var locations = [at]
        for _ in 0..<40 {
            at = paths.child(at, .index(0))
            locations.append(at)
        }
        // Every error renders to its reason and its location: `at NN` and NN
        // segments of `/0`.
        func rendered(_ errors: ArraySlice<ErrorRecord>) -> Int {
            errors.reduce(0) { $0 + $1.renderedLength(paths) }
        }

        // Recorded shallowest first, with one deep error at the head so that
        // the order kept is the recorded one rather than depth order.
        var errors = [record("innermost", locations[40])]
        errors.append(contentsOf: (10..<40).map { record("at \($0)", locations[$0]) })
        #expect(rendered(errors[..<1]) == "innermost".utf8.count + 80)

        let whole = retainedErrors(errors, paths, rendered(errors[...]))
        #expect(whole.count == errors.count)
        #expect(zip(whole, errors).allSatisfy { $0.reason == $1.reason && $0.location == $1.location })

        // The budget of the innermost eleven, less a byte: ten fit after the
        // innermost.
        let budget = rendered(errors[..<1]) + rendered(errors[21...]) - 1
        let kept = retainedErrors(errors, paths, budget)
        try #require(kept.count == 10)
        #expect(kept[0].reason == "innermost")
        #expect(kept[1].reason == "at 31", "the shallowest are dropped")
        #expect(kept[9].reason == "at 39")
        let depths = kept.map { paths.depth($0.location) }
        #expect(zip(depths.dropFirst(), depths.dropFirst(2)).allSatisfy { $0 <= $1 }, "recorded order kept")

        // Too small for even one: the innermost is handed out all the same.
        let one = retainedErrors(errors, paths, 1)
        #expect(one.count == 1)
        #expect(one.first?.reason == "innermost")

        // Retained as a part and then as the whole, the same errors are kept
        // as retained once from the whole.
        let head = Array(errors[..<16])
        var part = Array(errors[16...])
        retainWithinReport(&part, paths, budget)
        let twice = retainedErrors(head + part, paths, budget)
        #expect(zip(twice, kept).allSatisfy { $0.reason == $1.reason && $0.location == $1.location })
        #expect(twice.count == kept.count)
    }

    // MARK: - Naming types in messages

    /// A type is rendered on one line as the schema writes it, whatever the
    /// layout its own description lays it out in and whatever separator the
    /// schema left after the last entry.
    @Test func aTypeHeadIsOneLineWithBracesAndNoTrailingSeparator() throws {
        #expect(
            try headOf("root = {\n  name: tstr,\n  age: uint,\n  ? nickname: tstr,\n}\n")
                == "{ name: tstr, age: uint, ? nickname: tstr }"
        )
        #expect(try headOf("root = [name: tstr, age: uint]") == "[ name: tstr, age: uint ]")
        #expect(try headOf("root = {}") == "{}")
        #expect(try headOf("root = [* int]") == "[ * int ]")
        #expect(try headOf("root = { a: int // b: int, c: int }") == "{ a: int // b: int, c: int }")
        #expect(
            try headOf("root = { * tstr => int, 1 ^ => int, ? \"k\": bool }")
                == "{ * tstr => int, 1 ^ => int, ? \"k\": bool }"
        )
        #expect(
            try headOf("root = [ a, 2*3 b<int>, (c: int, d: int) ]\na = int\nb<t> = [t]\n")
                == "[ a, 2*3 b<int>, ( c: int, d: int ) ]"
        )
        #expect(try headOf("root = #6.24(bstr .cbor [1..10])") == "#6.24(bstr .cbor [ 1..10 ])")
        #expect(try headOf("root = (uint .size 3)") == "(uint .size 3)")
        #expect(try headOf("root = &(a: 1, b: 2)") == "&( a: 1, b: 2 )")
        // A control operator stands as a word between its operands; a range
        // operator joins its bounds.
        let operators = try cddlFromStr("root = 5 .eq 6 / 1...10 / uint .size (1..3)")
        #expect(alternativesHead(try firstType(operators)) == "5 .eq 6 / 1...10 / uint .size (1..3)")

        // The comments of the schema are not part of the type.
        let commented = "root = {\n  a: int, ; the first\n  b: int ; the last\n}\n"
        #expect(try headOf(commented) == "{ a: int, b: int }")
        // The type's own description renders a large group one entry per
        // line; the head never does.
        var long = "root = {"
        for i in 0..<20 {
            long += "\n  f\(i): uint, ; f\(i)"
        }
        long += "\n}\n"
        let cddl = try cddlFromStr(long)
        let t2 = try firstType2(of: cddl)
        #expect(t2.description.contains("\n"))
        let head = typeHead(t2)
        #expect(head == "{ f0: uint, f1: uint, f2: uint, f3: uint, \u{2026} 16 more }")
        #expect(!head.contains { $0 == "\n" || $0 == "\t" || $0 == ";" })
    }

    /// Every group is cut to its head, at whatever depth it stands: an entry
    /// whose type holds a long group renders that group cut down too.
    @Test func aNestedMapInsideAnEntryIsElidedByTheSameBound() throws {
        var inner = ""
        for i in 0..<(maxRenderedGroupEntries + 3) {
            inner += "g\(i): int, "
        }
        let schema = "root = { a: int, b: { \(inner) }, c: [ \(inner) ] }"
        let kept = (0..<maxRenderedGroupEntries).map { "g\($0): int" }.joined(separator: ", ")

        #expect(try headOf(schema) == "{ a: int, b: { \(kept), \u{2026} 3 more }, c: [ \(kept), \u{2026} 3 more ] }")

        // Exactly the bound prints whole; one past it counts the rest.
        let whole = kept
        #expect(try headOf("root = { \(whole) }") == "{ \(whole) }")
        #expect(
            try headOf("root = { \(whole), g\(maxRenderedGroupEntries): int }")
                == "{ \(whole), \u{2026} 1 more }"
        )
    }

    /// The alternatives of a type are joined by ` / ` on the one line, each
    /// rendered as a type on its own is.
    @Test func aTypeChoiceIsJoinedWithSlashes() throws {
        let cddl = try cddlFromStr("root = {\n  a: int\n} / [\n  b: int\n] / tstr .size (1..3) / #6.1(int)\n")
        let t = try firstType(cddl)

        #expect(t.description.contains("\n"))
        #expect(alternativesHead(t) == "{ a: int } / [ b: int ] / tstr .size (1..3) / #6.1(int)")
        // An entry type with alternatives is rendered the same way in place.
        #expect(try headOf("root = { a: int / tstr / { b: int } }") == "{ a: int / tstr / { b: int } }")
        // Named for a message, one alternative is the type it is; a choice is
        // a type.
        #expect(
            expectedAlternatives(.json, t) == "type { a: int } / [ b: int ] / tstr .size (1..3) / #6.1(int)"
        )
        let one = try cddlFromStr("root = { a: int }")
        #expect(expectedAlternatives(.json, try firstType(one)) == "object { a: int }")
        #expect(expectedAlternatives(.cbor, try firstType(one)) == "map { a: int }")
    }

    /// The rendering as a whole is bounded as a rendered data item is: a type
    /// whose head alone is longer than the bound is cut short and marked.
    @Test func theWholeRenderingStaysUnderMaxRenderedDataLength() throws {
        let wide = String(repeating: "x", count: 1024)
        let schema = "root = { \(wide): int }"
        let head = try headOf(schema)

        #expect(head.hasSuffix("..."), "\(head)")
        #expect(head.utf8.count <= maxRenderedDataLength + "...".utf8.count)
        #expect(head.hasPrefix("{ xxxx"))

        let named = expectedTypeError(.cbor, try firstType2(of: try cddlFromStr(schema)), "5")
        #expect(named.hasPrefix("expected map { xxxx"), "\(named)")
        #expect(named.hasSuffix("..., got 5"), "\(named)")
    }

    /// The noun a type is named by follows its shape and the data model of the
    /// document, and the rest of the message is the same on both.
    @Test func aTypeIsNamedByTheNounOfTheDataModel() throws {
        let cases: [(String, String, String)] = [
            ("root = { a: int }", "map { a: int }", "object { a: int }"),
            ("root = [ a: int ]", "array [ a: int ]", "array [ a: int ]"),
            ("root = #6.1({ a: int })", "tagged data #6.1({ a: int })", "tagged data #6.1({ a: int })"),
            ("root = tstr", "type tstr", "type tstr"),
            ("root = \"hello\"", "value \"hello\"", "value \"hello\""),
            ("root = 5", "value 5", "value 5"),
            ("root = h'01'", "value h'01'", "value h'01'"),
            ("root = ~g\ng = (a: int)", "type ~g", "type ~g"),
            ("root = &(a: 1)", "type &( a: 1 )", "type &( a: 1 )"),
            ("root = (int)", "type (int)", "type (int)"),
            ("root = #", "type #", "type #"),
        ]
        for (schema, cbor, json) in cases {
            let t2 = try firstType2(of: try cddlFromStr(schema))

            #expect(expectedType(.cbor, t2) == cbor, "\(schema)")
            #expect(expectedType(.json, t2) == json, "\(schema)")
            #expect(expectedItemError(.cbor, t2, 3) == "expected \(cbor) at index 3")
        }

        #expect(missingKeyError(.cbor, "\"k\"") == "map missing key: \"k\"")
        #expect(missingKeyError(.json, "\"k\"") == "object missing key: \"k\"")
    }

    // MARK: - Resolving names

    /// The rule an unwrapped name resolves to is reached by following bare
    /// type names, and the chain is followed on the heap, so a chain as long
    /// as a schema cares to write resolves.
    @Test func unwrapRuleFromIdentFollowsAChainOfNamesOnTheHeap() throws {
        let hops = 2000
        var schema = "x = [* ~y0] / uint\n"
        for hop in 0..<hops {
            schema += "y\(hop) = y\(hop + 1)\n"
        }
        schema += "y\(hops) = [x]\n"
        let cddl = try cddlFromStr(schema)

        let rule = try #require(unwrapRuleFromIdent(Schema(cddl), Identifier("y0")), "the chain ends at an array rule")
        guard case .type(let typeRule, _, _, _) = rule else {
            Issue.record("the chain ends at a type rule")
            return
        }
        #expect(typeRule.name.ident == "y\(hops)")
    }

    /// A chain of names that leads back to itself resolves to no rule.
    @Test func unwrapRuleFromIdentResolvesACycleOfNamesToNoRule() throws {
        let schema = Schema(try cddlFromStr("x = [* ~y] / uint\ny = z\nz = y\nw = w\nv = z\n"))

        #expect(unwrapRuleFromIdent(schema, Identifier("y")) == nil)
        #expect(unwrapRuleFromIdent(schema, Identifier("w")) == nil)
        #expect(unwrapRuleFromIdent(schema, Identifier("v")) == nil)
        #expect(unwrapRuleFromIdent(schema, Identifier("x")) != nil)
    }

    /// The text value a name stands for is found through the names its rules
    /// are defined as, in the order they are written, and a name already being
    /// followed is not followed again.
    @Test func textValueLookupsFollowNamesInOrderAndCutCycles() throws {
        let schema = Schema(
            try cddlFromStr(
                "a = b\nb = c / \"t\"\nc = a\nd = d\ne = [\"first\", uint]\nf = (e)\ng = h\ng /= \"plugged\"\nh = uint\n"
            )
        )
        func textValue(_ name: String) -> String? {
            guard let t2 = textValueFromIdent(schema, Identifier(name)) else { return nil }
            guard case .textValue(let value, _) = t2 else {
                Issue.record("not a text value: \(t2)")
                return nil
            }
            return value
        }

        // a -> b -> c -> a is cut, and b's second choice is the value.
        #expect(textValue("a") == "t")
        #expect(textValue("d") == nil)
        // A rule's own array choice does not stand for a text value ...
        #expect(textValue("e") == nil)
        #expect(textValue("f") == nil)
        // ... but an array examined directly does, through its first entry.
        guard case .type(let rule, _, _, _)? = ruleFromIdent(schema, Identifier("e")) else {
            Issue.record("e is a type rule")
            return
        }
        let array = try #require(rule.value.typeChoices.first).type1.type2
        guard case .textValue(let first, _)? = textValueFromType2(schema, array) else {
            Issue.record("the array's first entry is the text value")
            return
        }
        #expect(first == "first")
        // Every rule defining a name is examined, in the order written.
        #expect(textValue("g") == "plugged")
    }

    /// The type choices a group contributes come out in the order its entries
    /// are written, the groups written inside it included; an entry naming a
    /// group stands for the choice that group turns into, and one naming a
    /// type stands for that type, each held as the name it is written as.
    @Test func typeChoicesFromGroupChoiceKeepsTheWrittenOrderAndHoldsNames() throws {
        let schema = Schema(
            try cddlFromStr("g = (a: 1, h, (b: 2, i), c: 3)\nh = (d: 4)\ni = (e: 5)\nk = (j, k, uint)\nj = 6\n")
        )
        func values(_ name: String) -> [String] {
            guard let rule = groupRuleFromIdent(schema, Identifier(name)),
                case .inlineGroup(_, let group, _, _, _) = rule.entry,
                let choice = group.groupChoices.first
            else {
                Issue.record("\(name) is a group rule holding a group")
                return []
            }
            return typeChoicesFromGroupChoice(schema, choice).map { $0.type1.description }
        }

        #expect(values("g") == ["1", "&h", "2", "&i", "3"])
        // A name is held as written, whether it names a type, the group being
        // walked, or a type the schema does not define.
        #expect(values("k") == ["j", "&k", "uint"])
    }

    @Test func numericKindClassification() throws {
        let cddl = try cddlFromStr(
            """
            a = int
            b = float32
            c = number
            d = int / float
            e = a / b
            f = tstr
            """
        )
        let schema = Schema(cddl)
        func kindOf(_ name: String) throws -> NumericKind? {
            let ident = try #require(
                cddl.rules.lazy.compactMap { rule -> Identifier? in
                    if case .type(let typeRule, _, _, _) = rule, typeRule.name.ident == name {
                        return typeRule.name
                    }
                    return nil
                }.first
            )
            return identNumericKind(schema, ident)
        }

        #expect(try kindOf("a") == .int)
        #expect(try kindOf("b") == .float)
        #expect(try kindOf("c") == .both)
        #expect(try kindOf("d") == .both)
        #expect(try kindOf("e") == .both)
        #expect(try kindOf("f") == nil)
    }
}
