import Foundation
import Testing

@testable import SwiftCDDL

/// The DID document fixtures (W3C DID Core): every JSON and CBOR example in a
/// fixture directory is validated against the directory's schema. A file whose
/// name starts with `bad-` is expected to fail, and every other to pass.
@Suite struct DIDFixtureTests {
    /// The fixture directories under `did`, each holding one schema.
    private static func directories() throws -> [String] {
        let root = Fixtures.url("did")
        return try FileManager.default.contentsOfDirectory(atPath: root.path).filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted()
    }

    /// The files of `directory` with the extension `ext`, sorted by name.
    private static func files(_ directory: String, _ ext: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Fixtures.url("did/\(directory)").path)
            .filter { $0.hasSuffix(".\(ext)") }.sorted()
    }

    /// The one schema of `directory`.
    private static func schema(_ directory: String) throws -> String {
        guard let name = try files(directory, "cddl").first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Fixtures.read("did/\(directory)/\(name)")
    }

    @Test func validateDIDJSONExamples() async throws {
        let directories = try Self.directories()
        #expect(directories.count == 26)
        var examples = 0
        for directory in directories {
            let cddl = try Self.schema(directory)
            for name in try Self.files(directory, "json") {
                examples += 1
                let verdict = await jsonResult(cddl, try Fixtures.read("did/\(directory)/\(name)"))
                if name.hasPrefix("bad-") {
                    #expect(verdict != nil, "expected validation failure for \(directory)/\(name), but it passed")
                } else {
                    #expect(verdict == nil, "expected validation success for \(directory)/\(name): \(jsonRendered(verdict))")
                }
            }
        }
        #expect(examples == 36)
    }

    @Test func validateDIDCBORExamples() async throws {
        var examples = 0
        for directory in try Self.directories() {
            let cddl = try Self.schema(directory)
            for name in try Self.files(directory, "cbor") {
                examples += 1
                let bytes = [UInt8](try Data(contentsOf: Fixtures.url("did/\(directory)/\(name)")))
                let verdict = await cborResult(cddl, bytes)
                if name.hasPrefix("bad-") {
                    #expect(verdict != nil, "expected validation failure for \(directory)/\(name), but it passed")
                } else {
                    #expect(
                        verdict == nil,
                        "expected validation success for \(directory)/\(name): \(verdict.map { "\($0)" } ?? "")")
                }
            }
        }
        #expect(examples == 28)
    }
}

/// Incremental type choices (RFC 8610 Section 2.2.2 and Appendix C) against
/// JSON documents: every `/=` right-hand side is an additional arm of the
/// named choice.
@Suite struct IncrementalTypeChoicesJSONTests {
    private static let baseFirstRoot = "\nextended = bool\nextended /= text\nextended /= uint\n"
    private static let baseFirstAlias = "\nroot = extended\nextended = bool\nextended /= text\nextended /= uint\n"
    private static let alternateOnlyRoot = "\nextended /= text\nextended /= uint\n"
    private static let alternateOnlyAlias = "\nroot = extended\nextended /= text\nextended /= uint\n"

    private func assertThreeArmChoice(_ schema: String) async {
        await expectJSONValid(schema, "true")
        await expectJSONValid(schema, #""x""#)
        await expectJSONValid(schema, "0")
        await expectJSONInvalid(schema, "null")
    }

    @Test func jsonIncrementalChoiceIsRootIndependentAndTransactional() async {
        await assertThreeArmChoice(Self.baseFirstRoot)
        await assertThreeArmChoice(Self.baseFirstAlias)
    }

    @Test func alternateOnlyChoiceRemainsValidAtRootAndThroughAlias() async {
        for schema in [Self.alternateOnlyRoot, Self.alternateOnlyAlias] {
            await expectJSONValid(schema, #""x""#)
            await expectJSONValid(schema, "0")
            await expectJSONInvalid(schema, "true")
        }
    }

    /// Both arms of a generic rule extended by `/=` honour the argument bound
    /// at the reference.
    @Test func genericRuleExtendedByAMatchingArmKeepsValidating() async {
        let schema = "root = a<int>\na<t> = [t]\na<t> /= {k: t}\n"
        await expectJSONValid(schema, "[1]")
        await expectJSONValid(schema, #"{"k":1}"#)
        await expectJSONInvalid(schema, #"["x"]"#)
        await expectJSONInvalid(schema, #"{"k":"x"}"#)
    }

    @Test func recursiveChoiceArmsConsumeNestedData() async {
        let schemas = ["t = uint\nt /= [t]\n", "root = t\nt = uint\nt /= [t]\n", "t /= uint\nt /= [t]\n"]
        for schema in schemas {
            for value in ["0", "[0]", "[[0]]", "[[[0]]]"] {
                await expectJSONValid(schema, value)
            }
            await expectJSONInvalid(schema, #""x""#)
            await expectJSONInvalid(schema, "[[true]]")
        }
    }

    @Test func mutuallyRecursiveIncrementalChoiceConsumesNestedData() async {
        let schema = "list = [* item]\nitem = int\nitem /= list\n"
        await expectJSONValid(schema, "[[1], 2]")
        await expectJSONValid(schema, "[[[3]], 4]")
        await expectJSONInvalid(schema, #"[["x"]]"#)
    }

    @Test func recursiveAlternateOnlyReferenceCompletesInsteadOfCrashing() async {
        for schema in ["a /= a\n", "root = a\na /= a\n"] {
            await expectJSONInvalid(schema, "0")
        }
    }
}

/// Incremental group choices (RFC 8610 Appendix C) against JSON documents.
@Suite struct IncrementalGroupChoicesJSONTests {
    @Test func incrementalGroupChainStaysValidAtRootAndThroughAlias() async {
        for schema in ["r = {g}\ng //= (k: int)\ng //= (j: int)\n", "g //= (k: int)\ng //= (j: int)\nr = {g}\n"] {
            await expectJSONValid(schema, #"{"k":1}"#)
            await expectJSONValid(schema, #"{"j":1}"#)
            await expectJSONInvalid(schema, #"{"x":1}"#)
        }
    }
}

/// A group turned into a choice (RFC 8610 Section 3.6) validates the types its
/// entries hold as types, on both channels alike.
@Suite struct GroupToChoiceScopeJSONTests {
    /// Validates `json` and the CBOR encoding of `node` against `schema`, and
    /// expects both to reach `expected`.
    private func assertValidation(_ schema: String, _ json: String, _ node: CBORNode, _ expected: Bool) async {
        let cbor = await cborResult(schema, node.encoded()) == nil
        let other = await jsonResult(schema, json) == nil
        #expect(cbor == expected && other == expected, "schema: \(schema)\nvalue: \(json)\nexpected valid: \(expected)")
    }

    @Test func groupToChoiceValidatesNestedMapsAsTypes() async {
        let x = { (value: CBORNode) in CBORNode.map([(key: .text("x"), value: value)]) }
        let y = { (value: CBORNode) in CBORNode.map([(key: .text("y"), value: value)]) }
        for schema in [
            "root = &(a: { x: foo })\nfoo = { y: uint }",
            "root = &(a: { x: { y: uint } })",
            "root = &(a: wrapper)\nwrapper = { x: foo }\nfoo = { y: uint }",
            "root = &choices\nchoices = (a: { x: foo })\nfoo = { y: uint }",
            "root = &choices<foo>\nchoices<T> = (a: { x: T })\nfoo = { y: uint }",
        ] {
            await assertValidation(schema, #"{"x":{"y":1}}"#, x(y(.unsigned(1))), true)
            let refused: [(String, CBORNode)] = [
                (#"{"x":{"y":"invalid"}}"#, x(y(.text("invalid")))),
                (#"{"x":{}}"#, x(.map([]))),
                (
                    #"{"x":{"extra":2,"y":1}}"#,
                    x(.map([(key: .text("extra"), value: .unsigned(2)), (key: .text("y"), value: .unsigned(1))]))
                ),
                (#"{"x":1}"#, x(.unsigned(1))),
                (#"{"y":1}"#, y(.unsigned(1))),
                ("1", .unsigned(1)),
            ]
            for (json, node) in refused {
                await assertValidation(schema, json, node, false)
            }
        }
    }

    @Test func nestedEnumerationsPreserveLaterGroupChoices() async {
        let schema = "root = &(a: &(zero: 0) // b: 1, c: { x: foo })\nfoo = { y: uint }"
        let nested = { (value: CBORNode) in
            CBORNode.map([(key: .text("x"), value: .map([(key: .text("y"), value: value)]))])
        }
        await assertValidation(schema, "0", .unsigned(0), true)
        await assertValidation(schema, "1", .unsigned(1), true)
        await assertValidation(schema, #"{"x":{"y":1}}"#, nested(.unsigned(1)), true)
        await assertValidation(schema, "2", .unsigned(2), false)
        await assertValidation(schema, #"{"x":{"y":"invalid"}}"#, nested(.text("invalid")), false)
    }

    @Test func groupToChoicePreservesNestedGroupsAndEnumerations() async {
        let schema = """

                root = &(a: { fields })
                fields = (x: foo, kind: &(first: 0, second: 1))
                foo = { y: uint }

            """
        let foo = CBORNode.map([(key: .text("y"), value: .unsigned(1))])
        for kind: UInt64 in [0, 1] {
            await assertValidation(
                schema, #"{"kind":\#(kind),"x":{"y":1}}"#,
                .map([(key: .text("kind"), value: .unsigned(kind)), (key: .text("x"), value: foo)]), true)
        }
        await assertValidation(
            schema, #"{"kind":2,"x":{"y":1}}"#,
            .map([(key: .text("kind"), value: .unsigned(2)), (key: .text("x"), value: foo)]), false)
        await assertValidation(schema, #"{"x":{"y":1}}"#, .map([(key: .text("x"), value: foo)]), false)
    }

    /// Every error of a failing document carries whether it belongs to a group
    /// turned into a choice, and the rendered error says so.
    ///
    /// A regular expression that does not compile is reported in the words of
    /// the engine that compiles it, so `compareErrors` leaves those out of the
    /// comparison with the reference.
    private func assertEnumerationDiagnostics(
        _ schema: String, _ json: String, _ expected: Bool, compareErrors: Bool = true
    ) async {
        let verdict = await jsonResult(schema, json, compareErrors: compareErrors)
        let errors = jsonIssues(verdict)
        #expect(!errors.isEmpty, "\(schema)")
        #expect(errors.allSatisfy { $0.isGroupToChoiceEnum == expected }, "schema: \(schema)\nJSON: \(errors)")
        for error in errors {
            let display = error.description
            #expect(display.contains("type choice in group to choice enumeration") == expected, "\(display)")
            #expect(!error.reason.isEmpty)
            #expect(display.contains(error.reason))
        }
    }

    @Test func groupToChoiceMarksAccumulatedValidationErrors() async {
        for schema in ["root = &(a: 1)", "root = &choices\nchoices = (a: 1)", "root = &choices<1>\nchoices<T> = (a: T)"] {
            await assertEnumerationDiagnostics(schema, "2", true)
        }
        await assertEnumerationDiagnostics(
            "root = &(a: { x: foo })\nfoo = { y: uint }", #"{"x":{"y":"invalid"}}"#, true)
        await assertEnumerationDiagnostics("root = 1", "2", false)
    }

    @Test func groupToChoiceMarksReturnedValidationErrors() async {
        for schema in [
            #"root = &(a: tstr .regexp "[")"#,
            "root = &choices\nchoices = (a: tstr .regexp \"[\")",
            "root = &choices<tstr>\nchoices<T> = (a: T .regexp \"[\")",
            "root = &(a: &(b: tstr .regexp \"[\"))",
        ] {
            await assertEnumerationDiagnostics(schema, #""value""#, true, compareErrors: false)
        }
        await assertEnumerationDiagnostics(#"root = tstr .regexp "[""#, #""value""#, false, compareErrors: false)
    }
}

/// Map matching claims complete member pairs (RFC 8610 Appendix C), on both
/// channels alike.
@Suite struct MapTableCompletePairClaimsJSONTests {
    private func bothValidate(_ schema: String, _ json: String, _ cborHex: String) async {
        let other = await jsonResult(schema, json) == nil
        let cbor = await cborResult(schema, hexBytes(cborHex)) == nil
        #expect(other && cbor, "expected both formats to match \(schema); JSON \(json): \(other), CBOR \(cborHex): \(cbor)")
    }

    private func bothReject(_ schema: String, _ json: String, _ cborHex: String) async {
        let other = await jsonResult(schema, json) == nil
        let cbor = await cborResult(schema, hexBytes(cborHex)) == nil
        #expect(!other && !cbor, "expected both formats to reject \(schema); JSON \(json): \(other), CBOR \(cborHex): \(cbor)")
    }

    @Test func repeatingTablesClaimOnlyCompleteKeyValueMatches() async {
        await bothValidate("m = { * any => uint, extra: tstr }", #"{"extra":"hi"}"#, "a1656578747261626869")
        await bothValidate("m = { * any => uint, * any => tstr }", #"{"a":"x","b":1}"#, "a261616178616201")
        await bothValidate("m = { extra: tstr, * any => uint }", #"{"extra":"hi","b":1}"#, "a2656578747261626869616201")
    }

    @Test func occurrenceBoundsCountSuccessfulPairMatches() async {
        await bothValidate("m = { 1*1 any => uint, * any => tstr }", #"{"a":"x","b":1}"#, "a261616178616201")
        await bothReject("m = { + any => uint, * any => tstr }", #"{"a":"x"}"#, "a161616178")
    }

    @Test func completePairClaimsPreserveGreedyAndCutBehavior() async {
        await bothReject("m = { * any => uint, extra: uint }", #"{"extra":1}"#, "a165657874726101")
        await bothReject("m = { * any => uint }", #"{"a":"x"}"#, "a161616178")
        await bothReject("m = { extra: uint, * any => tstr }", #"{"extra":"hi"}"#, "a1656578747261626869")
    }
}

/// A recursive map table holds every nested value to its type, on both
/// channels alike.
@Suite struct TableMapCandidateLocationJSONTests {
    private func bothAccept(_ schema: String, _ json: String, _ cborHex: String) async {
        let other = await jsonResult(schema, json) == nil
        let cbor = await cborResult(schema, hexBytes(cborHex)) == nil
        #expect(other && cbor, "expected both formats to accept; JSON \(json): \(other), CBOR \(cborHex): \(cbor)\n\(schema)")
    }

    private func bothReject(_ schema: String, _ json: String, _ cborHex: String) async {
        let other = await jsonResult(schema, json) == nil
        let cbor = await cborResult(schema, hexBytes(cborHex)) == nil
        #expect(!other && !cbor, "expected both formats to reject; JSON \(json): \(other), CBOR \(cborHex): \(cbor)\n\(schema)")
    }

    @Test func recursiveTableValuesAreValidatedAtEveryDepth() async {
        let schema = "t = uint\nt /= {* tstr => t}\n"
        await bothAccept(schema, #"{"k":0}"#, "a1616b00")
        await bothAccept(schema, #"{"k":{"k":0}}"#, "a1616ba1616b00")
        await bothAccept(schema, #"{"k":{"k":{"k":0}}}"#, "a1616ba1616ba1616b00")
        await bothReject(schema, #"{"k":{"k":true}}"#, "a1616ba1616bf5")
        await bothReject(schema, #"{"k":{"k":{"k":true}}}"#, "a1616ba1616ba1616bf5")
    }

    @Test func recursiveTableValuesRemainCheckedBehindAnAlias() async {
        let schema = "root = t\nt = uint\nt /= {* tstr => t}\n"
        await bothAccept(schema, #"{"k":0}"#, "a1616b00")
        await bothAccept(schema, #"{"k":{"k":0}}"#, "a1616ba1616b00")
        await bothReject(schema, #"{"k":true}"#, "a1616bf5")
        await bothReject(schema, #"{"k":"x"}"#, "a1616b6178")
        await bothReject(schema, #"{"k":{"k":true}}"#, "a1616ba1616bf5")
    }

    @Test func inlineRecursiveTableChoiceChecksNestedValues() async {
        let schema = "t = uint / {* tstr => t}\n"
        await bothAccept(schema, #"{"k":{"k":0}}"#, "a1616ba1616b00")
        await bothReject(schema, #"{"k":{"k":true}}"#, "a1616ba1616bf5")
    }

    @Test func alternateOnlyRecursiveTableChecksNestedValues() async {
        let schema = "t /= uint\nt /= {* tstr => t}\n"
        await bothAccept(schema, #"{"k":0}"#, "a1616b00")
        await bothAccept(schema, #"{"k":{"k":0}}"#, "a1616ba1616b00")
        await bothReject(schema, #"{"k":true}"#, "a1616bf5")
        await bothReject(schema, #"{"k":"x"}"#, "a1616b6178")
        await bothReject(schema, #"{"k":{"k":true}}"#, "a1616ba1616bf5")
    }

    @Test func multipleTableArmsDoNotHideABadRecursiveValue() async {
        await bothReject("t /= {* tstr => t}\nt /= {\"z\" => uint}\n", #"{"k":{"k":true}}"#, "a1616ba1616bf5")
    }

    @Test func nonRecursiveAndSpecificKeyMapControlsKeepTheirVerdicts() async {
        let table = "m = {* tstr => int}\n"
        await bothAccept(table, #"{"k":1}"#, "a1616b01")
        await bothReject(table, #"{"k":"x"}"#, "a1616b6178")

        let specific = "t = uint\nt /= {\"k\" => t}\n"
        await bothAccept(specific, #"{"k":0}"#, "a1616b00")
        await bothAccept(specific, #"{"k":{"k":0}}"#, "a1616ba1616b00")
        await bothAccept(specific, #"{"k":{"k":{"k":0}}}"#, "a1616ba1616ba1616b00")
        await bothReject(specific, #"{"k":{"k":true}}"#, "a1616ba1616bf5")
    }
}

/// Byte string literals reach the JSON validator only through the schema.
@Suite struct ByteStringLiteralJSONTests {
    /// The alphabet check lives in the parser, so both validators reject the
    /// same literals for the same reason.
    @Test func mixedAlphabetRejectionIsSharedByTheJSONValidator() async {
        let verdict = await jsonResult("m = tstr .b64u b64'+_8'", #""-_8""#)
        #expect(
            jsonRendered(verdict).contains("mixes the RFC 4648 base64 and base64url alphabets"),
            "unexpected JSON diagnostic: \(jsonRendered(verdict))")
        await expectJSONValid("m = tstr .b64u b64'-_8'", #""-_8""#)
    }
}

/// The document-level entry point.
@Suite struct JSONEntryPointTests {
    @Test func validateJSON() async {
        let cddl = """

              foo = {
                bar: tstr
              }

            """
        for document in [#"{ "bar": "foo" }"#, #"{ "bar": "foo2" }"#] {
            await expectJSONValid(cddl, document)
        }
    }
}
