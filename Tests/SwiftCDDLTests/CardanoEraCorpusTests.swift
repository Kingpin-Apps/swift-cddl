import Foundation
import Testing

@testable import SwiftCDDL

/// Real ledger transactions of every era, each validated against the
/// `transaction` rule of its own era's schema.
///
/// The corpus lives in `Fixtures/cardano/tx/<era>/`: one `<hash>.hex` file per
/// transaction, pulled from Koios (mainnet, and preprod for part of Conway),
/// and a `MANIFEST.tsv` naming each transaction's network, epoch, expected
/// verdict and the features it exercises.
///
/// A few transactions the ledger accepted are refused by the pinned schemas,
/// and are kept as expected-invalid: their Plutus data holds byte strings
/// longer than 64 bytes written as indefinite-length strings of chunks of at
/// most 64 bytes. The ledger decoder checks each chunk, while the schema's
/// `bounded_bytes = bytes .size (0 .. 64)` constrains the value, which is the
/// concatenation of the chunks. The reference oracle reads it the same way.
@Suite struct CardanoEraCorpusTests {
    static let eras = ["shelley", "allegra", "mary", "alonzo", "babbage", "conway"]

    /// One transaction of the corpus, as its manifest lists it.
    struct Entry: Sendable, CustomTestStringConvertible {
        var era: String
        var hash: String
        var network: String
        var epoch: Int
        var expectValid: Bool
        var features: [String]

        var testDescription: String { "\(era)/\(hash.prefix(12)) \(features.joined(separator: ","))" }

        func bytes() throws -> [UInt8] {
            hexBytes(try Fixtures.read("cardano/tx/\(era)/\(hash).hex"))
        }
    }

    static let corpus: [Entry] = eras.flatMap { era -> [Entry] in
        guard let manifest = try? Fixtures.read("cardano/tx/\(era)/MANIFEST.tsv") else { return [] }
        return manifest.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let epoch = Int(fields[2]) else { return nil }
            return Entry(
                era: era,
                hash: fields[0],
                network: fields[1],
                epoch: epoch,
                expectValid: fields[3] == "valid",
                features: fields[4].split(separator: ",").map(String.init)
            )
        }
    }

    static let schemas: [String: String] = Dictionary(
        uniqueKeysWithValues: eras.map { ($0, (try? Fixtures.read("cardano/\($0).cddl")) ?? "") }
    )

    static func verdict(_ entry: Entry) async throws -> CBORValidationError? {
        let bytes = try entry.bytes()
        do {
            try await validateCBOR(cddl: schemas[entry.era] ?? "", cbor: bytes, rule: "transaction")
            return nil
        } catch {
            return error
        }
    }

    @Test func everyEraHasItsCorpus() throws {
        for era in Self.eras {
            let entries = Self.corpus.filter { $0.era == era }
            #expect(entries.filter(\.expectValid).count >= 10, "\(era) has too few valid transactions")
            let directory = Fixtures.url("cardano/tx/\(era)").path
            let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".hex") }
            #expect(Set(files) == Set(entries.map { "\($0.hash).hex" }), "\(era): manifest and files differ")
        }
    }

    @Test(arguments: corpus)
    func transactionVerdictMatchesTheManifest(_ entry: Entry) async throws {
        let verdict = try await Self.verdict(entry)
        if entry.expectValid {
            #expect(verdict == nil, "\(entry.hash): \(verdict.map { "\($0)" } ?? "")")
        } else {
            let reported = issues(verdict)
            #expect(!reported.isEmpty)
            #expect(
                reported.contains { $0.reason.contains("bounded_bytes") },
                "\(entry.hash): refused for another reason: \(reported.prefix(3))"
            )
        }
    }

    /// Opt-in, when `CDDL_ORACLE_BIN` names the reference oracle: the verdict,
    /// and for a refused transaction the location and reason of every error,
    /// equal the oracle's.
    @Test(.enabled(if: OracleCheck.executable != nil), arguments: corpus)
    func verdictAndErrorsMatchTheOracle(_ entry: Entry) async throws {
        let verdict = try await Self.verdict(entry)
        let output = try #require(
            try OracleCheck.run(cddl: Self.schemas[entry.era] ?? "", rule: "transaction", bytes: try entry.bytes()))
        let valid = try #require(output.valid as Bool?, "the reference oracle did not validate: \(output.parseError ?? "")")
        #expect(valid == (verdict == nil))
        #expect(valid == entry.expectValid)
        if !valid, let oracleErrors = output.errors {
            let reported = issues(verdict)
            #expect(oracleErrors.map(\.path) == reported.map(\.cborLocation))
            #expect(oracleErrors.map(\.reason) == reported.map(\.reason))
        }
    }

    /// The mean time one transaction of each era takes to validate once the
    /// schema is parsed, printed per era. A release build holds Conway to
    /// under 50 ms a transaction; a debug build only to a generous bound.
    @Test func validationTimePerEra() async throws {
        let clock = ContinuousClock()
        var report: [String] = []
        for era in Self.eras {
            let schema = try cddlFromStr(Self.schemas[era] ?? "")
            let nodes = try Self.corpus.filter { $0.era == era }.map { try decodeCBOR(try $0.bytes()) }
            guard !nodes.isEmpty else { continue }
            let rounds = 3
            let elapsed = await clock.measure {
                for _ in 0..<rounds {
                    for node in nodes {
                        let validator = CBORValidator(cddl: schema, cbor: node)
                        validator.setRootRule("transaction")
                        _ = try? await validator.validate()
                    }
                }
            }
            let mean = elapsed / (rounds * nodes.count)
            let milliseconds = Double(mean.components.attoseconds) / 1e15 + Double(mean.components.seconds) * 1000
            report.append("\(era) \(String(format: "%.2f", milliseconds)) ms over \(nodes.count)")
            #if DEBUG
                #expect(mean < .seconds(2), "\(era): \(mean) a transaction")
            #else
                if era == "conway" {
                    #expect(mean < .milliseconds(50), "conway: \(mean) a transaction")
                }
            #endif
        }
        print("mean validation time per transaction: " + report.joined(separator: "; "))
    }
}
