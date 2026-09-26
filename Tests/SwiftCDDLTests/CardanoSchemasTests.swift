import Foundation
import Testing

import SwiftCDDL
import SwiftCDDLCardano

/// The bundled era schemas, and transaction validation that tells the issues
/// the ledger refuses from those it accepts.
@Suite struct CardanoSchemasTests {
    @Test(arguments: CardanoEra.allCases)
    func bundledSchemaIsTheFixture(_ era: CardanoEra) throws {
        #expect(try CardanoSchemas.source(for: era) == Fixtures.read("cardano/\(era.rawValue).cddl"))
        _ = try CardanoSchemas.document(for: era)
    }

    @Test(arguments: CardanoEraCorpusTests.corpus)
    func classifiesTheCorpus(_ entry: CardanoEraCorpusTests.Entry) async throws {
        let era = try #require(CardanoEra(rawValue: entry.era))
        let result = try await CardanoSchemas.validate(transaction: Data(try entry.bytes()), era: era)
        #expect(result.isLedgerValid, "\(entry.hash): \(result.issues.prefix(3))")
        #expect(result.matchesSchema == entry.expectValid)
        if !entry.expectValid {
            #expect(!result.issues.isEmpty)
            #expect(result.issues.allSatisfy { $0.classification == .ledgerChunkedBytes })
        }
        for issue in result.issues {
            #expect(issue.itemPath != nil, "\(issue.issue.path) not found")
        }
    }

    @Test func keepsIssuesTheLedgerRefuses() async throws {
        // A single definite 65-byte string where the schema wants
        // bounded_bytes is refused by the ledger too.
        let entry = try #require(CardanoEraCorpusTests.corpus.first { !$0.expectValid })
        let era = try #require(CardanoEra(rawValue: entry.era))
        let bytes = try entry.bytes()
        let root = try #require(CBORNode.decodeAnnotated(bytes).root)
        var found: CBORAnnotatedItem?
        root.walk { _, item in
            if found == nil, case .byteString(let value, true)? = item.node, value.count > 64 { found = item }
        }
        let item = try #require(found)

        // Rewrite the chunked string as one definite string of the same bytes.
        guard case .byteString(let value, _)? = item.node else {
            Issue.record("not a byte string")
            return
        }
        var definite: [UInt8] = [0x58, UInt8(value.count)]
        #expect(value.count < 256)
        definite += value
        let rewritten = Array(bytes[..<item.span.start]) + definite + Array(bytes[item.span.end...])
        let size = rewritten.count - bytes.count

        let second = try await CardanoSchemas.validate(transaction: Data(rewritten), era: era)
        #expect(!second.isLedgerValid, "size change \(size)")
        #expect(second.issues.contains { $0.classification == .schema })
    }

    @Test func resolvesIssuePathsThroughMapsAndTags() throws {
        // {0: 258([h'aa']), "k": [1, 2]}
        let bytes: [UInt8] = [0xA2, 0x00, 0xD9, 0x01, 0x02, 0x81, 0x41, 0xAA, 0x61, 0x6B, 0x82, 0x01, 0x02]
        let root = try #require(CBORNode.decodeAnnotated(bytes).root)
        #expect(root.path(forIssuePath: "") == [])
        #expect(root.path(forIssuePath: "/0/0") == [1, 0, 0])
        #expect(root.path(forIssuePath: "/\"k\"/1") == [3, 1])
        #expect(root.path(forIssuePath: "/\"k\"/2") == nil)
        #expect(root.path(forIssuePath: "/1") == nil)
    }
}
