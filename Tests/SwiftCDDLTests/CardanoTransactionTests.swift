import Foundation
import Testing

@testable import SwiftCDDL

/// Real ledger transactions validated against the Conway era schema, and
/// mutations of them that the schema refuses.
///
/// The transactions are stored as hex under `Fixtures/cardano/tx/`: three
/// mainnet transactions (one of them carrying an indefinite-length tag-258
/// set), a Conway transaction with map-form redeemers, and a hand-built
/// transaction whose collateral inputs and required signers are empty sets,
/// which Conway requires to be non-empty.
@Suite struct CardanoTransactionTests {
    static let conway: String = (try? Fixtures.read("cardano/conway.cddl")) ?? ""

    static let valid = [
        "mainnet-script-data-hash-1",
        "mainnet-script-data-hash-2",
        "mainnet-indefinite-set",
        "conway-map-redeemers",
    ]

    /// Each refused transaction with the errors the refusal reports, as
    /// location and reason.
    static let invalid: [(String, [(String, String)])] = [
        (
            "invalid-empty-collateral-and-signers",
            [
                ("/0/13", "array must have exactly one item"),
                ("/0/13", "array must have at least one item"),
                ("/0/14", "array must have exactly one item"),
                ("/0/14", "array must have at least one item"),
            ]
        ),
        ("invalid-fee-is-text", [("/0/2", "expected type uint, got Text(\"xx\")")]),
        ("invalid-unknown-body-key", [("/0", "unexpected key 99")]),
        (
            "invalid-transaction-arity",
            [
                (
                    "",
                    "array validation failed: item sequence does not match group \n\ttransaction_body,\n\ttransaction_witness_set,\n\tbool,\n\tauxiliary_data / nil\n"
                )
            ]
        ),
    ]

    static func transaction(_ name: String) throws -> [UInt8] {
        hexBytes(try Fixtures.read("cardano/tx/\(name).hex"))
    }

    @Test(arguments: ["shelley", "allegra", "mary", "alonzo", "babbage", "conway"])
    func everyEraSchemaParses(_ era: String) throws {
        let schema = try cddlFromStr(try Fixtures.read("cardano/\(era).cddl"))
        #expect(!schema.rules.isEmpty)
    }

    @Test(arguments: valid)
    func realTransactionValidates(_ name: String) async throws {
        let verdict = await cborResult(Self.conway, try Self.transaction(name), rule: "transaction", comparePaths: true)
        #expect(verdict == nil, "\(name): \(verdict.map { "\($0)" } ?? "")")
    }

    @Test(arguments: invalid.map(\.0))
    func mutatedTransactionIsRefused(_ name: String) async throws {
        let expected = try #require(Self.invalid.first { $0.0 == name }?.1)
        let verdict = await cborResult(Self.conway, try Self.transaction(name), rule: "transaction", comparePaths: true)
        let reported = issues(verdict)
        #expect(reported.map(\.cborLocation) == expected.map(\.0))
        #expect(reported.map(\.reason) == expected.map(\.1))
    }

    /// The time the valid transactions take to validate, once the schema is
    /// parsed: printed, and held to a generous bound so that a regression that
    /// multiplies the work shows up.
    @Test func validationTimeOfTheRealTransactions() async throws {
        let schema = try cddlFromStr(Self.conway)
        var nodes: [CBORNode] = []
        for name in Self.valid {
            nodes.append(try decodeCBOR(try Self.transaction(name)))
        }

        let clock = ContinuousClock()
        let rounds = 5
        let elapsed = try await clock.measure {
            for _ in 0..<rounds {
                for node in nodes {
                    let validator = CBORValidator(cddl: schema, cbor: node)
                    validator.setRootRule("transaction")
                    try await validator.validate()
                }
            }
        }
        let perTransaction = elapsed / (rounds * nodes.count)
        print("validating one Conway transaction takes \(perTransaction)")
        #expect(perTransaction < .seconds(2))
    }
}
