import Testing

@testable import SwiftCDDL

/// Tokens, literal values, float notation and AST rendering.
@Suite struct TokenTests {
    /// A literal is written back in the notation it was read in.
    @Test func aNotationThatDenotesItsValueIsWhatIsWritten() {
        for (text, value) in [
            ("1e300", 1e300),
            ("1e20", 1e20),
            ("1E5", 1e5),
            ("1e+5", 1e5),
            ("123.456e3", 123.456e3),
            ("-0.0", -0.0),
            ("0x1.9p6", 100.0),
            ("-0x1.8p3", -12.0),
        ] {
            let notation = FloatNotation(literal: text)
            #expect(notation.literal(for: value) == text)
            #expect(FloatLiteralValue(value, notation: notation).description == text)
        }
    }

    /// A notation left on a node whose value was replaced is dropped.
    @Test func aNotationThatDenotesAnotherValueIsNotWritten() {
        for (text, value, canonical) in [
            ("1e20", 1e21, "1.0e21"),
            ("100.0", 100.5, "100.5"),
            ("0x1p-10", 1.0, "1.0"),
            ("-0.0", 0.0, "0.0"),
            ("1e300", Double.infinity, "Infinity"),
            ("1e300", Double.nan, "NaN"),
            ("", 1.0, "1.0"),
            ("1e", 1.0, "1.0"),
        ] {
            let notation = FloatNotation(literal: text)
            #expect(notation.literal(for: value) == nil)
            #expect(FloatLiteralValue(value, notation: notation).description == canonical)
        }
    }

    /// A value with no notation is written canonically.
    @Test func aValueWithNoNotationIsWrittenCanonically() {
        let notation = FloatNotation()
        #expect(notation.literal(for: 1e20) == nil)
        #expect(FloatLiteralValue(1e20, notation: notation).description == "100000000000000000000.0")
    }

    /// Two spellings of one value are one literal.
    @Test func notationTakesNoPartInEquality() {
        #expect(
            Value.float(FloatLiteralValue(100.0, notation: FloatNotation(literal: "1e2")))
                == Value.float(FloatLiteralValue(100.0, notation: FloatNotation(literal: "100.0")))
        )
        #expect(Value.float(FloatLiteralValue(100.0, notation: FloatNotation(literal: "1e2"))) == .float(FloatLiteralValue(100.0)))
        #expect(Value.float(FloatLiteralValue(100.0)) != .float(FloatLiteralValue(101.0)))
    }

    @Test func lookupControlFromStrFindsEveryOperator() {
        for ctrl in ControlOperator.allCases {
            #expect(lookupControlFromStr(ctrl.description) == ctrl)
        }
        #expect(lookupControlFromStr(".size") == .size)
        #expect(lookupControlFromStr(".nope") == nil)
    }

    @Test func lookupIdentAndPrelude() {
        #expect(lookupIdent("false") == .false)
        #expect(Token.any.inStandardPrelude() == "any")
        #expect(lookupIdent("$$g") == .ident("g", .group))
        #expect(lookupIdent("$t") == .ident("t", .type))
        #expect(lookupIdent("plain") == .ident("plain", nil))
        for name in standardPrelude {
            #expect(lookupIdent(name).inStandardPrelude() == name)
        }
    }

    @Test func tagFromTokenCoversThePrelude() {
        #expect(tagFromToken(.tdate)?.description == "#6.0(tstr)")
        #expect(tagFromToken(.decfrac)?.description == "#6.4([ int integer ])")
        #expect(tagFromToken(.cborAny)?.description == "#6.55799(any)")
        #expect(tagFromToken(.int) == nil)
    }

    @Test func standardPreludeTextParses() throws {
        let cddl = try parseOK(standardPreludeText)
        #expect(cddl.rules.count == standardPrelude.count)
    }

    @Test func verifyGroupentryOutput() {
        let entry = GroupEntry.typeGroupname(
            ge: TypeGroupnameEntry(occur: nil, name: Identifier("entry1"), genericArgs: nil),
            span: Span(0, 0, 0)
        )
        #expect(entry.description == "entry1")
    }

    @Test func verifyGroupOutput() {
        func entry(_ key: String, _ value: String) -> (GroupEntry, OptionalComma) {
            (
                .valueMemberKey(
                    ge: ValueMemberKeyEntry(
                        occur: nil,
                        memberKey: .bareword(ident: Identifier(key), span: .zero),
                        entryType: Type(
                            typeChoices: [TypeChoice(type1: Type1(type2: .textValue(value: value, span: .zero)))],
                            span: .zero
                        )
                    ),
                    span: .zero
                ),
                OptionalComma(optionalComma: true)
            )
        }
        let group = Group(
            groupChoices: [GroupChoice(groupEntries: [entry("key1", "value1"), entry("key2", "value2")], span: .zero)],
            span: .zero
        )
        #expect(group.description == " key1: \"value1\", key2: \"value2\", ")
    }

    @Test func identifierEqualityIgnoresSpanAndComparesNames() {
        #expect(Identifier(ident: "a", socket: nil, span: Span(1, 2, 3)) == Identifier("a"))
        #expect(Identifier(ident: "a", socket: .type, span: .zero) != Identifier("a"))
        // A name written with a socket prefix and one whose `ident` already
        // carries that prefix denote the same rule.
        #expect(Identifier(ident: "x", socket: .type, span: .zero) == Identifier(ident: "$x", socket: nil, span: .zero))
        #expect(Identifier(ident: "x", socket: .type).hashValue == Identifier(ident: "$x").hashValue)
    }

    @Test func byteValuesRender() {
        #expect(ByteValue.b16([0xaa, 0x00, 0xff]).description == "h'aa00ff'")
        #expect(ByteValue.b16(Array("AA".utf8)).description == "h'4141'")
        #expect(ByteValue.b64([0xfb, 0xff]).description == "b64'-_8'")
        #expect(ByteValue.b64(Array("AA".utf8)).description == "b64'QUE'")
        #expect(ByteValue.utf8([0xff]).description == "h'ff'")
        #expect(Type2(ByteValue.utf8([0xff])).description == "h'ff'")
    }
}
