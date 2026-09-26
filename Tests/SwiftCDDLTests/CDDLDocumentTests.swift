import Foundation
import Testing

@testable import SwiftCDDL

/// The package's front door: parsing a schema into a ``CDDLDocument`` and
/// validating documents against it.
@Suite struct CDDLDocumentTests {
    static let person = """
        ; A person.
        person = { name: tstr, ? age: uint }
        pet = [ kind: "cat" / "dog", owner: person ]
        $extension /= int
        """

    @Test func parsesAndExposesItsRules() throws {
        let document = try CDDLDocument(Self.person)
        #expect(document.rules.count == 3)
        #expect(document.rule(named: "pet")?.ruleName.ident == "pet")
        #expect(document.rule(named: "$extension")?.typeRule != nil)
        #expect(document.rule(named: "extension") == nil)
        #expect(document.rule(named: "missing") == nil)
        #expect(document.ast.rules == document.rules)
    }

    @Test func parsesUTF8Data() throws {
        let document = try CDDLDocument(data: Data(Self.person.utf8))
        #expect(document.rules.count == 3)
        #expect(throws: CDDLParseError.self) {
            _ = try CDDLDocument(data: Data([0x61, 0x20, 0x3d, 0x20, 0xff]))
        }
    }

    @Test func formatsStably() throws {
        let formatted = try CDDLDocument(Self.person).formatted()
        #expect(formatted.contains("; A person."))
        #expect(try CDDLDocument(formatted).formatted() == formatted)
    }

    @Test func reportsWhereTheSourceDoesNotParse() {
        let source = "a = int\nb = [ int\n"
        do {
            _ = try CDDLDocument(source)
            Issue.record("an unterminated array parsed")
        } catch {
            #expect(error.line == 2)
            #expect(error.column > 0)
            #expect(!error.message.isEmpty)
            #expect(error.description.hasPrefix("2:"))
            let rendered = error.rendered(source: source)
            #expect(rendered.contains("b = [ int"))
            #expect(rendered.contains("^"))
        }
    }

    @Test func refusesAnUndefinedReference() {
        #expect(throws: CDDLParseError.self) {
            _ = try CDDLDocument("a = [ b ]\n")
        }
    }

    @Test func validatesJSON() async throws {
        let document = try CDDLDocument(Self.person)
        let valid = await document.validate(json: #"{"name": "Ada", "age": 36}"#)
        #expect(valid.isValid)
        #expect(valid.issues.isEmpty)

        let invalid = await document.validate(json: #"{"name": 1}"#)
        #expect(!invalid.isValid)
        #expect(invalid.issues.first?.path == "/name")
        #expect(invalid.issues.allSatisfy { $0.kind == .mismatch })

        let pet = await document.validate(json: Data(#"["cat", {"name": "Ada"}]"#.utf8), rule: "pet")
        #expect(pet.isValid)

        let malformed = await document.validate(json: "{")
        #expect(malformed.issues.map(\.kind) == [.malformedDocument])
    }

    @Test func validatesCBOR() async throws {
        let document = try CDDLDocument(Self.person)
        // {"name": "Ada"}
        let valid = Data([0xa1, 0x64] + Array("name".utf8) + [0x63] + Array("Ada".utf8))
        #expect(await document.validate(cbor: valid).isValid)

        // {"name": 1}
        let invalid = Data([0xa1, 0x64] + Array("name".utf8) + [0x01])
        let result = await document.validate(cbor: invalid)
        #expect(result.issues.first?.path == "/\"name\"")

        let node = try CBORNode(decoding: valid)
        #expect(await document.validate(cbor: node).isValid)

        let truncated = await document.validate(cbor: Data([0xa1, 0x64]))
        #expect(truncated.issues.map(\.kind) == [.malformedDocument])
    }

    @Test func validatesSynchronouslyFromATask() async throws {
        let document = try CDDLDocument(Self.person)
        let verdicts = await Task.detached { () -> [Bool] in
            [
                document.validateSynchronously(json: #"{"name": "Ada"}"#).isValid,
                document.validateSynchronously(json: Data(#"{"name": 2}"#.utf8)).isValid,
                document.validateSynchronously(cbor: Data([0xa0])).isValid,
                document.validateSynchronously(cbor: .text("x"), rule: "person").isValid,
            ]
        }.value
        #expect(verdicts == [true, false, false, false])
    }

    @Test func reportsAnUnknownRootRule() async throws {
        let document = try CDDLDocument(Self.person)
        let result = await document.validate(json: #"{"name": "Ada"}"#, rule: "nobody")
        #expect(!result.isValid)
    }

    @Test func honoursOptions() async throws {
        let document = try CDDLDocument(#"thing = { ? new: tstr .feature "v2", old: int }"#)
        let json = #"{"new": "x", "old": 1}"#
        #expect(await document.validate(json: json, options: ValidationOptions(enabledFeatures: ["v2"])).isValid)

        var limits = ValidationLimits()
        limits.maxValidationWork = 1
        let limited = await document.validate(json: json, options: ValidationOptions(limits: limits))
        #expect(!limited.isValid)
    }

    @Test func reportsAnUnsupportedControl() async throws {
        let document = try CDDLDocument(#"a = tstr .abnf "x""#)
        let result = await document.validate(json: #""y""#)
        #expect(result.issues.map(\.kind) == [.unsupported])
    }

    @Test func validatesAConwayTransaction() async throws {
        let document = try CDDLDocument(try Fixtures.read("cardano/conway.cddl"))
        let transaction = Data(hexBytes(try Fixtures.read("cardano/tx/mainnet-indefinite-set.hex")))
        let result = await document.validate(cbor: transaction, rule: "transaction")
        #expect(result.isValid, "\(result.issues)")
    }

    @Test(arguments: ["shelley", "allegra", "mary", "alonzo", "babbage", "conway"])
    func everyEraSchemaParsesWithReferencesChecked(_ era: String) throws {
        let document = try CDDLDocument(try Fixtures.read("cardano/\(era).cddl"))
        #expect(document.rule(named: "transaction") != nil)
    }

    @Test func lowerLevelValidatorsAcceptADocument() async throws {
        let document = try CDDLDocument(Self.person)
        let validator = JSONValidator(document: document, json: try JSONNode.parse(#"{"name": 1}"#))
        validator.rootRule = "person"
        #expect(validator.rootRule == "person")
        await #expect(throws: JSONValidationError.self) {
            try await validator.validate()
        }

        let cborValidator = CBORValidator(document: document, cbor: .text("x"))
        #expect(throws: CBORValidationError.self) {
            try cborValidator.validateSynchronously()
        }
    }
}
