import Foundation
import Testing

@testable import SwiftCDDL

/// Verdicts compared with a reference oracle over the Cardano transactions and
/// over mutations of them.
///
/// Opt-in: the suite runs only when `CDDL_ORACLE_BIN` names the reference
/// oracle executable. Every other CBOR test compares its own documents with
/// the oracle through the shared helpers whenever the variable is set, so
/// `CDDL_ORACLE_BIN=<oracle> swift test` is the differential run over every
/// ported vector; this suite adds the transaction corpus and a few hundred
/// single-byte mutations of it.
@Suite(.enabled(if: OracleCheck.executable != nil))
struct ReferenceVerdictTests {
    static let conway: String = (try? Fixtures.read("cardano/conway.cddl")) ?? ""

    static let corpus: [String] = {
        let directory = Fixtures.url("cardano/tx").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".hex") }.sorted().map { String($0.dropLast(4)) }
    }()

    @Test(arguments: corpus)
    func transactionVerdictsMatchTheOracle(_ name: String) async throws {
        let bytes = hexBytes(try Fixtures.read("cardano/tx/\(name).hex"))
        await cborResult(Self.conway, bytes, rule: "transaction", comparePaths: true)
    }

    /// Single-byte mutations of every transaction that still decode: each is
    /// validated by both implementations, and the verdicts and error
    /// locations compared.
    @Test(arguments: corpus)
    func mutatedTransactionVerdictsMatchTheOracle(_ name: String) async throws {
        let bytes = hexBytes(try Fixtures.read("cardano/tx/\(name).hex"))
        var generator = SeededGenerator(seed: UInt64(bytes.count) &* 8610)
        var compared = 0
        var attempts = 0
        while compared < 60 && attempts < 2000 {
            attempts += 1
            var mutated = bytes
            let index = Int.random(in: 0..<mutated.count, using: &generator)
            mutated[index] = UInt8.random(in: 0...255, using: &generator)
            guard (try? decodeCBOR(mutated)) != nil else { continue }
            compared += 1
            await cborResult(Self.conway, mutated, rule: "transaction", comparePaths: true)
        }
        #expect(compared > 0)
    }
}
