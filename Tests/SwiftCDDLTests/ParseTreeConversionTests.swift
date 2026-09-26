import Testing

@testable import SwiftCDDL

/// Conversion of the parse tree into the AST: spans, comment attachment,
/// duplicate rules, undefined references, error reporting and escapes.
@Suite struct ParseTreeConversionTests {
    private func firstEntry(_ ty: Type?) -> GroupEntry? {
        guard let group = arrayOrMapGroup(ty) else {
            Issue.record("first type choice is not an array or map")
            return nil
        }
        return group.groupChoices[0].groupEntries[0].0
    }

    private func prefix(_ input: String, _ end: Int) -> String {
        String(decoding: Array(input.utf8)[..<end], as: UTF8.self)
    }

    private func suffix(_ input: String, _ start: Int) -> String {
        String(decoding: Array(input.utf8)[start...], as: UTF8.self)
    }

    /// Leaf and container spans are tight, while the enclosing Type1 and
    /// GroupEntry spans are greedy.
    @Test func tightExtentHelpers() throws {
        var input = "a = 0\n"
        var cddl = try parseCDDL(input)
        var end = type2TightSpan(try #require(findType(cddl, "a")).typeChoices[0].type1.type2).end
        #expect(prefix(input, end).hasSuffix("0"), "leaf end \(prefix(input, end))")

        input = "a = [0, bytes]\n"
        cddl = try parseCDDL(input)
        end = type2TightSpan(try #require(findType(cddl, "a")).typeChoices[0].type1.type2).end
        #expect(prefix(input, end).hasSuffix("]"), "array end \(prefix(input, end))")

        input = "a = uint .size 4\n"
        cddl = try parseCDDL(input)
        end = type1TightEnd(try #require(findType(cddl, "a")).typeChoices[0].type1)
        #expect(prefix(input, end).hasSuffix("4"), "ctlop end \(prefix(input, end))")

        // Tight at `bytes`, stopping before the trailing space.
        input = "a = [bytes , int]\n"
        cddl = try parseCDDL(input)
        var tight = entryTightEnd(try #require(firstEntry(findType(cddl, "a"))))
        #expect(prefix(input, tight).hasSuffix("bytes"), "tgn end \(prefix(input, tight))")
        #expect(suffix(input, tight).hasPrefix(" "), "tight end should stop before trailing trivia")

        input = "a = {x: int, y: int}\n"
        cddl = try parseCDDL(input)
        tight = entryTightEnd(try #require(firstEntry(findType(cddl, "a"))))
        #expect(prefix(input, tight).hasSuffix("int"), "vmk end \(prefix(input, tight))")
    }

    /// Stand-alone comments are `pure`, trailing ones are not; group-choice
    /// leading anchors exist only for genuine multi-`//` groups.
    @Test func collectCommentToksAndAnchors() throws {
        let input = """
            multi = [
              ; @name A
              x: int //
              ; @name B
              y: int
            ]
            single = {
              z: int ; @name C
            }

            """
        let source = SourceText(input)
        let pair = try parseDocument(source)
        let toks = collectCommentToks(pair, source)
        #expect(toks.count == 3, "texts: \(toks.map(\.text))")
        #expect(toks.filter(\.pure).map(\.text) == [" @name A", " @name B"])
        #expect(zip(toks, toks.dropFirst()).allSatisfy { $0.lo < $1.lo }, "comment tokens must be source-ordered")

        var cddl = try parseCDDL(input)
        var grpCount = 0
        visitAnchorSlots(&cddl.rules, source) { _, kind, _ in
            if kind == .grpChoiceLeading {
                grpCount += 1
            }
        }
        #expect(grpCount == 2, "GrpChoiceLeading only for multi-`//` groups")
    }

    /// Drives the merge directly (the public API discards orphans).
    private func runMerge(_ input: String) throws -> ([[String]], [CommentTok]) {
        let source = SourceText(input)
        let pair = try parseDocument(source)
        let toks = collectCommentToks(pair, source)
        var cddl = try parseCDDL(input)
        var anchors: [Anchor] = []
        visitAnchorSlots(&cddl.rules, source) { pos, kind, _ in
            anchors.append(Anchor(pos: pos, kind: kind))
        }
        let containers = collectContainerExtents(cddl.rules)
        return mergeComments(toks, anchors, containers)
    }

    /// Only `TypeChoice.commentsAfterType` is written, never `Type1`'s, so
    /// each hint is emitted once.
    @Test func noDoubleEmitOnTypeChoiceTrailing() throws {
        let input = """

            my_enum = 0 ; @name ValA
                    / 1 ; @name ValB
                    / 2 ; @name ValC

            """
        let cddl = try parseCDDL(input)
        let myEnum = try #require(findType(cddl, "my_enum"))
        for (i, want) in [" @name ValA", " @name ValB", " @name ValC"].enumerated() {
            let tc = myEnum.typeChoices[i]
            #expect(commentFirst(tc.commentsAfterType) == want)
            #expect(tc.type1.commentsAfterType == nil, "Type1.comments_after_type must stay None")
        }
        let s = cddl.description
        for hint in ["@name ValA", "@name ValB", "@name ValC"] {
            #expect(s.occurrences(of: hint) == 1, "\(hint) count in \(s)")
        }
    }

    /// A trailing comment after an operator-bearing type1.
    @Test func operatorBearingTrailing() throws {
        let cddl = try parseCDDL("m = uint .size 4 ; @name n\n")
        #expect(commentFirst(findType(cddl, "m")?.typeChoices[0].commentsAfterType) == " @name n")
    }

    /// A comment before the first alternative is rule-level.
    @Test func firstChoiceLeadingIsRuleLevel() throws {
        let cddl = try parseCDDL("\n; doc\nfoo = 0 / 1\n")
        #expect(ruleLeading(cddl, "foo") == " doc")
        #expect(findType(cddl, "foo")?.typeChoices[0].commentsBeforeType == nil)
    }

    /// A leading comment before a non-first alternative populates that
    /// choice's `commentsBeforeType`.
    @Test func leadingCommentOnNonfirstTypeChoice() throws {
        let cddl = try parseCDDL("\nt = int\n  ; doc\n  / text\n")
        let t = try #require(findType(cddl, "t"))
        #expect(commentFirst(t.typeChoices[1].commentsBeforeType) == " doc")
        #expect(t.typeChoices[0].commentsBeforeType == nil)
    }

    /// Stacked leading comments accumulate; a blank line breaks the run.
    @Test func leadingAccumulationAndBlankLineBreak() throws {
        let cddl = try parseCDDL("\n; first\n; second\nfoo = 0\n")
        let lead = cddl.rules.first { $0.name() == "foo" }?.commentsBeforeRule()
        #expect(lead?.comments == [" first", " second"])

        let cddl2 = try parseCDDL("\n; orphan\n\nbar = 0\n")
        #expect(ruleLeading(cddl2, "bar") == nil)
    }

    /// A hint after `]` binds the array choice, not the inner entries.
    @Test func noDuplicationArrayChoiceTrailing() throws {
        let cddl = try parseCDDL("block = [0, bytes] ; @name w\n")
        let block = try #require(findType(cddl, "block"))
        #expect(commentFirst(block.typeChoices[0].commentsAfterType) == " @name w")
        let g = arrayOrMapGroup(block)
        #expect(entryTrailing(g, 0, 0) == nil)
        #expect(entryTrailing(g, 0, 1) == nil)
    }

    /// Round-trip preserves trailing hints.
    @Test func roundTripTrailingHints() throws {
        let input = """

            my_enum = 0 ; @name ValA
                    / 1 ; @name ValB
                    / 2 ; @name ValC

            """
        let emitted = try parseCDDL(input).description
        let reparsed = try parseCDDL(emitted)
        let myEnum = try #require(findType(reparsed, "my_enum"))
        for (i, want) in [" @name ValA", " @name ValB", " @name ValC"].enumerated() {
            #expect(commentFirst(myEnum.typeChoices[i].commentsAfterType) == want, "lost choice \(i) in \(emitted)")
        }
    }

    /// A control-op entry binds the entry trailing slot, not the inner type
    /// choice.
    @Test func entryTrailingTiebreak() throws {
        let cddl = try parseCDDL("\nm = {\n  x: uint .size 4 ; @name n\n}\n")
        let g = arrayOrMapGroup(findType(cddl, "m"))
        #expect(entryTrailing(g, 0, 0) == " @name n")
        guard case .valueMemberKey(let ge, _, _, _)? = g?.groupChoices[0].groupEntries[0].0 else {
            Issue.record("expected ValueMemberKey")
            return
        }
        #expect(ge.entryType.typeChoices[0].commentsAfterType == nil)
    }

    /// A pure comment after the last entry before `]` does not leak onto the
    /// next rule's leading slot.
    @Test func enclosingGuardNoForwardLeak() throws {
        let input = "\na = [ int\n  ; dangling\n]\nb = 0\n"
        let cddl = try parseCDDL(input)
        #expect(ruleLeading(cddl, "b") == nil)
        let (_, orphans) = try runMerge(input)
        #expect(orphans.contains { $0.text == " dangling" })
    }

    /// `entryTightEnd` on an inline `( ... )` group is tight at `)`.
    @Test func inlineGroupTightEnd() throws {
        let input = "a = [ (int, text), bytes ]\n"
        let cddl = try parseCDDL(input)
        let entry = try #require(firstEntry(findType(cddl, "a")))
        guard case .inlineGroup = entry else {
            Issue.record("expected inline group entry")
            return
        }
        let end = entryTightEnd(entry)
        #expect(prefix(input, end).hasSuffix(")"), "inline group end \(prefix(input, end))")
    }

    /// Single-choice groups put a leading comment on the entry; multi-choice
    /// groups on the group choice.
    @Test func singleVsMultiGroupChoiceLeading() throws {
        let single = try parseCDDL("\ng = {\n  ; @name First\n  a: int, b: int\n}\n")
        let g = try #require(arrayOrMapGroup(findType(single, "g")))
        #expect(g.groupChoices[0].commentsBeforeGrpchoice == nil)
        guard case .valueMemberKey(_, _, let leading, _) = g.groupChoices[0].groupEntries[0].0 else {
            Issue.record("expected ValueMemberKey")
            return
        }
        #expect(commentFirst(leading) == " @name First")

        let multi = try parseCDDL("\nh = [\n  ; @name X\n  tag: int //\n  b: int\n]\n")
        let hg = try #require(arrayOrMapGroup(findType(multi, "h")))
        #expect(commentFirst(hg.groupChoices[0].commentsBeforeGrpchoice) == " @name X")
        guard case .valueMemberKey(_, _, let multiLeading, _) = hg.groupChoices[0].groupEntries[0].0 else {
            Issue.record("expected ValueMemberKey")
            return
        }
        #expect(multiLeading == nil)
    }

    /// Orphans never fail the public entry point; a normal parse has none.
    @Test func orphanNonPanic() throws {
        let weird = "\nx = {\n  foo ; c\n  : int\n}\n"
        #expect(throws: Never.self) { try parseCDDL(weird) }
        let (_, orphans) = try runMerge(weird)
        #expect(!orphans.isEmpty, "the stray comment should orphan")
        let (_, orphans2) = try runMerge("y = 0 ; @name k\n")
        #expect(orphans2.isEmpty, "unexpected orphans: \(orphans2.map(\.text))")
    }

    /// A trailing hint on a bare value member binds to the entry's trailing
    /// comments.
    @Test func bareValueMemberTrailing() throws {
        let cddl = try parseCDDL("\nsuits = [\n  0, ; @name hearts\n  1 ; @name spades\n]\n")
        let g = arrayOrMapGroup(findType(cddl, "suits"))
        #expect(entryTrailing(g, 0, 0) == " @name hearts")
        #expect(entryTrailing(g, 0, 1) == " @name spades")
        for ei in 0..<2 {
            if case .valueMemberKey(let ge, _, _, _)? = g?.groupChoices[0].groupEntries[ei].0 {
                #expect(ge.entryType.typeChoices[0].commentsAfterType == nil, "inner choice must not claim the hint")
            }
        }
    }

    /// The enclosing guard uses the innermost container.
    @Test func enclosingGuardInnermostContainer() throws {
        let input = "\nx = [\n  a: [ int\n  ; @name X\n  ], b: int\n]\ny = 0\n"
        let cddl = try parseCDDL(input)
        let g = try #require(arrayOrMapGroup(findType(cddl, "x")))
        for (ge, _) in g.groupChoices[0].groupEntries {
            if case .valueMemberKey(_, _, let leading, _) = ge {
                #expect(leading == nil, "comment leaked onto an outer-array entry")
            }
        }
        let (_, orphans) = try runMerge(input)
        #expect(orphans.contains { $0.text == " @name X" }, "escaping comment should orphan")
    }

    /// Trailing hints on bare-typename type-choice alternatives.
    @Test func trailingCommentOnTypenameTypeChoice() throws {
        let cddl = try parseCDDL("\nt = foo ; @name a\n  / bar ; @name b\nfoo = int\nbar = int\n")
        let t = findType(cddl, "t")
        #expect(choiceTrailing(t, 0) == " @name a")
        #expect(choiceTrailing(t, 1) == " @name b")
        #expect(ruleLeading(cddl, "foo") == nil)
        #expect(ruleLeading(cddl, "bar") == nil)
    }

    /// A trailing hint on a type alias does not leak onto the next rule.
    @Test func trailingCommentOnTypenameNoForwardLeak() throws {
        let cddl = try parseCDDL("\ndevice = phone ; @name Phone\nphone = 0\n")
        #expect(choiceTrailing(findType(cddl, "device"), 0) == " @name Phone")
        #expect(ruleLeading(cddl, "phone") == nil)
    }

    @Test func basicTypeRule() throws {
        let cddl = try parseCDDL("myrule = int\n")
        #expect(cddl.rules.count == 1)
    }

    @Test func astCommentsPopulatedForRuleAndNestedEntries() throws {
        let input =
            "; A person.\n; identity info.\nperson = {\n  ; full name\n  name: tstr, ; trailing name\n  address: {\n    ; street line\n    street: tstr,\n  },\n}\n"
        let cddl = try parseCDDL(input)

        let before = try #require(cddl.rules[0].commentsBeforeRule(), "rule should have leading comments")
        #expect(before.comments == [" A person.", " identity info."])

        guard case .map(let group, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("expected map")
            return
        }
        let entries = group.groupChoices[0].groupEntries

        guard case .valueMemberKey(_, _, let leading, let trailing) = entries[0].0 else {
            Issue.record("expected value member key")
            return
        }
        #expect(leading?.comments == [" full name"])
        #expect(trailing?.comments == [" trailing name"])

        guard case .valueMemberKey(let ge, _, _, _) = entries[1].0,
            case .map(let inner, _, _, _) = ge.entryType.typeChoices[0].type1.type2,
            case .valueMemberKey(_, _, let innerLeading, _) = inner.groupChoices[0].groupEntries[0].0
        else {
            Issue.record("expected nested value member key")
            return
        }
        #expect(innerLeading?.comments == [" street line"])
    }

    /// A commented map formats back into valid, re-parseable CDDL.
    @Test func astCommentsRoundtripReparses() throws {
        let input = "person = {\n  ; full name\n  name: tstr, ; trailing\n  age: uint,\n}\n"
        let formatted = try parseCDDL(input).description
        #expect(throws: Never.self) { try parseCDDL(formatted) }
        #expect(formatted.contains("; full name"))
        #expect(formatted.contains("; trailing"))
    }

    @Test func simpleStruct() {
        #expect(throws: Never.self) { try parseCDDL("person = { name: tstr, age: uint }\n") }
    }

    @Test func typeChoice() {
        #expect(throws: Never.self) { try parseCDDL("value = int / text / bool\n") }
    }

    /// A redefinition is reported at the declaration that redefines the
    /// name, covering exactly that declaration.
    @Test func duplicateRuleIsReportedAtTheRedefinition() {
        for (input, expected) in [
            ("Person = { name: tstr }\nPerson = { age: uint }\n", "Person = { age: uint }"),
            ("a = uint\nb = tstr\na = bstr\n", "a = bstr"),
            ("a = uint ; a comment\na = bstr", "a = bstr"),
            ("grp = (a: uint)\ngrp = (b: uint)\n", "grp = (b: uint)"),
        ] {
            do {
                _ = try parseCDDL(input)
                Issue.record("expected a duplicate-rule rejection for \(input.debugDescription)")
            } catch {
                guard case .parser(let position, let msg) = error else {
                    Issue.record("unexpected error \(error)")
                    continue
                }
                #expect(msg.short.contains("is already defined"), "\(msg.short)")
                let bytes = Array(input.utf8)
                #expect(String(decoding: bytes[position.range.0..<position.range.1], as: UTF8.self) == expected)
                #expect(position.line == bytes[..<position.range.0].filter { $0 == UInt8(ascii: "\n") }.count + 1)
            }
        }
    }

    /// A rule that extends an earlier one is not a redefinition.
    @Test(arguments: ["a = uint\na /= tstr\n", "g = (a: uint)\ng //= (b: uint)\n"])
    func choiceAlternatesAreNotDuplicateRules(_ input: String) {
        #expect(throws: Never.self, "rejected a choice alternate: \(input.debugDescription)") {
            try parseCDDL(input)
        }
    }

    @Test func trailingCommentOnScalarTypeChoice() throws {
        let cddl = try parseCDDL(
            "my_enum = 0 ; @name first\n        / 1 ; @name second\n        / 2 ; @name third\n"
        )
        let myEnum = findType(cddl, "my_enum")
        #expect(choiceTrailing(myEnum, 0) == " @name first")
        #expect(choiceTrailing(myEnum, 1) == " @name second")
        #expect(choiceTrailing(myEnum, 2) == " @name third")
    }

    @Test func trailingCommentOnArrayTypeChoice() throws {
        let cddl = try parseCDDL("my_choice = [0, bytes] ; @name first\n            / [1, bytes] ; @name second\n")
        let myChoice = findType(cddl, "my_choice")
        #expect(choiceTrailing(myChoice, 0) == " @name first")
        #expect(choiceTrailing(myChoice, 1) == " @name second")
    }

    @Test func trailingCommentOnMapEntry() throws {
        let cddl = try parseCDDL(
            "my_map = {\n  ? 0 : int, ; @name first\n  ? 2 : tstr, ; @name second\n}\n"
        )
        let myMap = arrayOrMapGroup(findType(cddl, "my_map"))
        #expect(entryTrailing(myMap, 0, 0) == " @name first")
        #expect(entryTrailing(myMap, 0, 1) == " @name second")
    }

    @Test func trailingCommentOnArrayEntry() throws {
        let cddl = try parseCDDL(
            "my_array = [ bytes ; @name first\n             , bytes ; @name second\n             ]\n"
        )
        let myArray = arrayOrMapGroup(findType(cddl, "my_array"))
        #expect(entryTrailing(myArray, 0, 0) == " @name first")
        #expect(entryTrailing(myArray, 0, 1) == " @name second")
    }

    @Test func leadingCommentOnGroupChoice() throws {
        let cddl = try parseCDDL(
            "my_group = [\n  ; @name first\n  x: 0, int //\n  ; @name second\n  y: 1\n]\n"
        )
        let myGroup = try #require(arrayOrMapGroup(findType(cddl, "my_group")))
        #expect(commentFirst(myGroup.groupChoices[0].commentsBeforeGrpchoice) == " @name first")
        #expect(commentFirst(myGroup.groupChoices[1].commentsBeforeGrpchoice) == " @name second")
    }

    @Test func generic() {
        #expect(throws: Never.self) { try parseCDDL("map<K, V> = { * K => V }\nmy-map = map<text, int>\n") }
    }

    @Test func checkedAndUncheckedEntryPointsAgree() throws {
        let input = "\nperson = {\n  name: tstr,\n  age: uint\n}\n"
        let existing = try cddlFromStr(input, printStderr: true)
        let direct = try parseCDDL(input)
        #expect(existing.rules.count == direct.rules.count)
    }

    @Test func rangeOperator() {
        #expect(throws: Never.self) { try parseCDDL("port = 0..65535\n") }
    }

    @Test func array() {
        #expect(throws: Never.self) { try parseCDDL("my-array = [* int]\n") }
    }

    @Test func occurrenceIndicators() {
        let input = "\noptional-field = { ? name: tstr }\nzero-or-more = { * items: int }\none-or-more = { + values: text }\n"
        #expect(throws: Never.self) { try parseCDDL(input) }
    }

    @Test func comments() {
        let input = "\n; This is a comment\nperson = {\n  name: tstr,  ; person's name\n  age: uint    ; person's age\n}\n"
        #expect(throws: Never.self) { try parseCDDL(input) }
    }

    @Test func errorReporting() {
        do {
            _ = try parseCDDL("invalid syntax @#$")
            Issue.record("Should fail on invalid syntax")
        } catch {
            let errorStr = error.debugDescription
            #expect(errorStr.contains("expected") || errorStr.contains("assignment"), "got: \(errorStr)")
        }
    }

    @Test func enhancedErrorMessages() {
        do {
            _ = try parseCDDL("myrule")
        } catch {
            let errorStr = error.debugDescription
            #expect(errorStr.contains("assignment"), "Error should mention assignment, got: \(errorStr)")
            #expect(errorStr.contains("Hint"), "Error should include a hint, got: \(errorStr)")
        }

        do {
            _ = try parseCDDL("myrule = ")
        } catch {
            let errorStr = error.debugDescription
            #expect(errorStr.contains("type value") || errorStr.contains("group entry"), "got: \(errorStr)")
        }

        do {
            _ = try parseCDDL("x = !!invalid!!")
        } catch {
            #expect(error.debugDescription.contains("expected"), "got: \(error.debugDescription)")
        }
    }

    @Test func errorPositionTracking() {
        do {
            _ = try parseCDDL("myrule = \n  invalid @#$")
        } catch {
            #expect(error.debugDescription.contains("line: 2"), "got: \(error.debugDescription)")
        }
    }

    @Test func undefinedReferenceError() {
        do {
            _ = try parseCDDLChecked("X = {\n  a: UnknownType,\n}\n")
            Issue.record("Expected error for undefined reference")
        } catch {
            #expect(error.description.contains("missing definition for rule UnknownType"), "got: \(error)")
        }
    }

    @Test(arguments: [
        "X = { a: int, b: tstr, c: bool }\n",
        "MyType = int\nX = { a: MyType }\n",
        "container<T> = { value: T }\n",
        "X = { a: $my-socket }\n",
    ])
    func referencesThatAreNotFlagged(_ input: String) {
        #expect(throws: Never.self) { try parseCDDLChecked(input) }
    }

    @Test func fromSliceUndefinedReference() {
        do {
            _ = try CDDL.fromSlice(Array("X = {\n  a: UnknownType,\n}\n".utf8))
            Issue.record("CDDL.fromSlice should return error for undefined reference")
        } catch {
            #expect(error.description.contains("missing definition for rule UnknownType"), "got: \(error)")
        }
    }

    // MARK: Error messages and RFC 9682

    @Test func errorMsgSerializationCompat() {
        do {
            _ = try parseCDDL("invalid syntax @#$")
            Issue.record("Should fail on invalid syntax")
        } catch {
            guard case .parser(_, let msg) = error else {
                Issue.record("expected a parser error")
                return
            }
            #expect(!msg.short.isEmpty)
            #expect(msg.extended != nil, "Extended message should be present for enhanced errors")
            #expect(!msg.description.isEmpty)
        }
    }

    @Test func rfc9682EmptyCDDL() throws {
        let cddl = try parseCDDL("")
        #expect(cddl.rules.isEmpty)
    }

    @Test func rfc9682CommentOnlyCDDL() {
        #expect(throws: Never.self) { try parseCDDL("; just a comment\n") }
    }

    @Test func rfc9682UnicodeBraceEscapeParsing() {
        #expect(throws: Never.self) { try parseCDDL("a = \"D\\u{6f}mino\"") }
    }

    @Test func rfc9682SurrogatePairParsing() {
        #expect(throws: Never.self) { try parseCDDL("b = \"test \\uD83C\\uDC73\"") }
    }

    @Test func unescapeRFC9682BraceForm() {
        #expect(unescapeText("D\\u{6f}mino") == "Domino")
    }

    @Test func unescapeRFC9682BraceFormLargeCodepoint() {
        #expect(unescapeText("\\u{1F073}") == "\u{1F073}")
    }

    @Test func unescapeRFC9682BraceFormWithLeadingZeros() {
        #expect(unescapeText("\\u{006f}") == "o")
    }

    @Test func unescapeSurrogatePair() {
        #expect(unescapeText("\\uD83C\\uDC73") == "\u{1F073}")
    }

    @Test func unescapeFourDigitForm() {
        #expect(unescapeText("\\u2318") == "⌘")
    }

    @Test func rfc9682TagTypeExpression() {
        let input = "ct-tag<content> = #6.<ct-tag-number>(content)\nct-tag-number = 1668546817..1668612095"
        #expect(throws: Never.self) { try parseCDDL(input) }
    }

    @Test func rfc9682SimpleValueTypeExpression() {
        #expect(throws: Never.self) { try parseCDDL("my-simple = #7.<0..23>") }
    }

    /// The error points at the invalid token, not at the first rule.
    @Test func errorPositionForInvalidSecondRule() {
        do {
            _ = try parseCDDL("value = 0x1\n\nbreak")
            Issue.record("Should fail to parse")
        } catch {
            guard case .parser(let position, let msg) = error else {
                Issue.record("expected a parser error")
                return
            }
            #expect(position.line == 3, "Error should be on line 3, not line \(position.line). Message: \(msg.short)")
            #expect(position.column == 1)
            #expect(position.range == (13, 18))
        }
    }
}
