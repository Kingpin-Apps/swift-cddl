import BigInt
import Testing

@testable import SwiftCDDL

/// The computations behind the control operators: `.cat` and `.det`
/// (RFC 9165 Section 2), the text conversion operators, `.base10`, `.printf`
/// and `.json` (RFC 9741), and the base64 decoding they share.
@Suite struct ControlsTests {
    // MARK: - Private helpers

    /// `type2` as the single choice of a type.
    private func singleType(_ type2: Type2) -> Type {
        Type(typeChoices: [TypeChoice(type1: Type1(type2: type2))])
    }

    /// A `.printf` controller: an array of the format string followed by its
    /// arguments, each an entry without a member key.
    private func printfArray(_ format: String, _ args: [Type2]) -> Type2 {
        var entries: [GroupEntry] = [
            .valueMemberKey(ge: ValueMemberKeyEntry(entryType: singleType(.textValue(value: format))))
        ]
        for arg in args {
            entries.append(.valueMemberKey(ge: ValueMemberKeyEntry(entryType: singleType(arg))))
        }
        return .array(group: Group(groupChoices: [GroupChoice(entries: entries)]))
    }

    /// The bytes base64 text decodes to, or `nil` when it is not an encoding
    /// under the alphabet and padding rule asked for.
    private func base64(_ text: String, _ isClassic: Bool, _ isSloppy: Bool) -> [UInt8]? {
        try? base64Decode(text, isClassic, isSloppy)
    }

    // MARK: - .cat and .det

    @Test func testCat() throws {
        let cddl = try cddlFromStr(
            """
            a = "foo" .cat '
              bar
              baz
            '
            """
        )

        let result = try catOperation(
            Schema(cddl),
            .textValue(value: "foo"),
            .utf8ByteString(value: Array("'\n  bar\n  baz\n'".utf8)),
            false
        ).get()
        #expect(result == [.textValue(value: "foo\n  bar\n  baz\n")])
    }

    @Test func testCatWithDedent() throws {
        let cddl = try cddlFromStr(
            """
            a = "foo" .det b
            b = '
              bar
              baz
            '
            """
        )

        let result = try catOperation(
            Schema(cddl),
            .textValue(value: "foo"),
            .typename(ident: Identifier("b")),
            true
        ).get()
        #expect(result == [.textValue(value: "foo\nbar\nbaz\n")])
    }

    /// Matching text against an ABNF grammar (RFC 9165 Section 3) is not
    /// provided; a schema using `.abnf` reports it as unsupported.
    @Test(.disabled("matching against ABNF grammars (.abnf, RFC 9165 Section 3) is not supported; there is no grammar matcher to call"))
    func testAbnf() async throws {
        let schema = """
            d = tstr .abnf ('date-fullyear' .det rules)
            rules = '
              date-fullyear   = 4DIGIT
              date-month      = 2DIGIT  ; 01-12
              date-mday       = 2DIGIT  ; 01-28, 01-29, 01-30, 01-31 based on
                                        ; month/year
              time-hour       = 2DIGIT  ; 00-23
              time-minute     = 2DIGIT  ; 00-59
              time-second     = 2DIGIT  ; 00-58, 00-59, 00-60 based on leap sec
                                        ; rules
              time-secfrac    = "." 1*DIGIT
              time-numoffset  = ("+" / "-") time-hour ":" time-minute
              time-offset     = "Z" / time-numoffset

              partial-time    = time-hour ":" time-minute ":" time-second
                                [time-secfrac]
              full-date       = date-fullyear "-" date-month "-" date-mday
              full-time       = partial-time time-offset

              date-time       = full-date "T" full-time

              DIGIT          =  %x30-39 ; 0-9
              ; abbreviated here
            '
            """
        let verdict = await cborResult(schema, CBORNode.text("2009").encoded())
        guard case .unsupported? = verdict else {
            Issue.record("expected the .abnf control to be reported as unsupported, got \(String(describing: verdict))")
            return
        }
    }

    // MARK: - Text conversion

    /// RFC 9741 Section 2.1: the text conversion control operators each name
    /// one encoding of byte strings, and text that is no encoding under the
    /// operator carries no byte string for the controller to be matched
    /// against.
    @Test func decodeTextConversionReadsEachEncodingTheOperatorNames() {
        let hello = Array("hello".utf8)

        #expect(decodeTextConversion(.b64u, "aGVsbG8") == hello)
        #expect(decodeTextConversion(.b64c, "aGVsbG8=") == hello)
        #expect(decodeTextConversion(.hex, "68656c6c6f") == hello)
        #expect(decodeTextConversion(.hex, "68656C6C6F") == hello)
        #expect(decodeTextConversion(.b32, "NBSWY3DP") == hello)

        // The padding rule each base64 operator names is part of the encoding.
        #expect(decodeTextConversion(.b64u, "aGVsbG8=") == nil)
        #expect(decodeTextConversion(.b64c, "aGVsbG8") == nil)

        // Text that is no encoding at all decodes to nothing.
        #expect(decodeTextConversion(.b64u, "!!!") == nil)
        #expect(decodeTextConversion(.hex, "invalid") == nil)
    }

    /// `.hexlc` and `.hexuc` differ from `.hex` only in the case they admit,
    /// which decoding does not answer for: hex decoding is case insensitive.
    @Test func decodeTextConversionHoldsHexToTheCaseTheOperatorStates() {
        let hello = Array("hello".utf8)

        #expect(decodeTextConversion(.hexlc, "68656c6c6f") == hello)
        #expect(decodeTextConversion(.hexlc, "68656C6C6F") == nil)

        #expect(decodeTextConversion(.hexuc, "68656C6C6F") == hello)
        #expect(decodeTextConversion(.hexuc, "68656c6c6f") == nil)
    }

    // MARK: - .base10, .printf, .json

    @Test func testBase10Validation() throws {
        let target = Type2.textValue(value: "text")
        let controller = Type2.intValue(value: BigInt(123))

        #expect(try validateBase10Text(target, controller, "123").get())
        #expect(try !validateBase10Text(target, controller, "124").get())
        // Leading zeros are not allowed.
        #expect(try !validateBase10Text(target, controller, "0123").get())
        #expect(try !validateBase10Text(target, controller, "abc").get())
    }

    @Test func testPrintfValidation() throws {
        let target = Type2.textValue(value: "text")

        // "0x%04x" with the value 19 formats to "0x0013".
        let controller = printfArray("0x%04x", [.uintValue(value: 19)])
        #expect(try validatePrintfText(target, controller, "0x0013").get())
        #expect(try !validatePrintfText(target, controller, "0x0014").get())
    }

    @Test func testJsonValidation() throws {
        let target = Type2.textValue(value: "text")

        // A controller of any type: the text only has to be JSON.
        let controller = Type2.typename(ident: Identifier("any"))

        #expect(try validateJSONText(target, controller, #"{"key": "value"}"#).get())
        #expect(try validateJSONText(target, controller, "[1, 2, 3]").get())
        #expect(try validateJSONText(target, controller, #""hello""#).get())
        #expect(try validateJSONText(target, controller, "42").get())
        #expect(try validateJSONText(target, controller, "true").get())

        // Text that is not JSON.
        #expect(try !validateJSONText(target, controller, "not valid json").get())
        #expect(try !validateJSONText(target, controller, "{invalid}").get())

        // A text controller matches only JSON strings.
        let textController = Type2.typename(ident: Identifier("text"))
        #expect(try validateJSONText(target, textController, #""hello""#).get())
        #expect(try !validateJSONText(target, textController, "42").get())
    }

    // MARK: - base64

    /// The sloppy decode differs from the strict one in exactly one respect:
    /// the bits the final symbol carries beyond the encoded data need not be
    /// zero. It yields the same bytes the strict decode would, and it holds to
    /// the alphabet, the length and the padding rule all the same.
    @Test func base64SloppyDecodeRelaxesOnlyTheTrailingBits() {
        // Two symbols carry four bits beyond the one byte they encode.
        #expect(base64("AQ", false, false) == [0x01])
        #expect(base64("AR", false, false) == nil)
        #expect(base64("AQ", false, true) == [0x01])
        #expect(base64("AR", false, true) == [0x01])
        #expect(base64("AV", false, true) == [0x01])
        #expect(base64("Ag", false, true) == [0x02])

        // Three symbols carry two such bits beyond the two bytes they encode.
        #expect(base64("AQI", false, false) == [0x01, 0x02])
        #expect(base64("AQJ", false, false) == nil)
        #expect(base64("AQJ", false, true) == [0x01, 0x02])

        // Four symbols carry none, so sloppy and strict agree.
        #expect(base64("AQID", false, true) == [0x01, 0x02, 0x03])

        // The padding rule of each alphabet holds under sloppy decoding.
        #expect(base64("AQ==", false, true) == nil)
        #expect(base64("AQ", true, true) == nil)
        #expect(base64("AR==", true, true) == [0x01])

        // So does the alphabet itself.
        #expect(base64("aGX/bw", false, true) == nil)
        #expect(base64("aGX_bw==", true, true) == nil)
        #expect(base64("aGX_bw", false, true) == [0x68, 0x65, 0xff, 0x6f])
        #expect(base64("aGX/bw==", true, true) == [0x68, 0x65, 0xff, 0x6f])

        // A length base64 cannot produce is still a length base64 cannot
        // produce.
        #expect(base64("Z", false, true) == nil)
        #expect(base64("aGVsbG8gd", false, true) == nil)
    }
}
