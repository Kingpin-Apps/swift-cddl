import Foundation
import Testing

import SwiftCDDL
@testable import SwiftCDDLCardano

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

    /// Data nested past the validation bound but within the decoding bound is
    /// refused, then rewritten for the ledger's reading, on a task of Swift
    /// concurrency, whose stack is small.
    @Test func validatesDeeplyNestedDataOnATask() async throws {
        let bytes = Data([UInt8](repeating: 0x81, count: 60_000) + [0x00])
        let result = try await Task.detached {
            try await CardanoSchemas.validate(transaction: bytes, era: .conway)
        }.value
        #expect(result.decoding.error == nil)
        #expect(!result.matchesSchema)
        #expect(!result.isLedgerValid)
    }

    /// A 65-byte string written in chunks of 64 and 1 bytes.
    private static let chunked: [UInt8] = [0x5F, 0x58, 0x40] + [UInt8](repeating: 0xAB, count: 64) + [0x41, 0xCD, 0xFF]

    /// `payload` embedded under tag 24, `levels` times over.
    private static func embedded(_ payload: [UInt8], levels: Int) -> [UInt8] {
        var bytes = payload
        for _ in 0..<levels {
            precondition(bytes.count <= 0xFFFF)
            bytes = [0xD8, 0x18, 0x59, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        }
        return bytes
    }

    /// A chunked string is cut for the ledger's reading inside CBOR embedded
    /// under tag 24, as deep as validation reads embedded CBOR and no deeper.
    @Test func cutsChunkedBytesInsideEmbeddedCBOR() throws {
        let depth = ValidationLimits.defaultMaxEmbeddedDepth
        let within = try #require(CBORNode.decodeAnnotated([0x81] + Self.embedded(Self.chunked, levels: depth)).root)
        let view = CardanoSchemas.ledgerBoundedBytes(within)
        #expect(view.changed)
        var node = try #require(view.item.node)
        node = try #require(node.arrayItems?.first)
        for _ in 0..<depth {
            guard case .tagged(let tagged) = node, tagged.tag == 24, case .byteString(let bytes, _) = tagged.content else {
                Issue.record("not embedded CBOR: \(node)")
                return
            }
            node = try CBORNode(decoding: bytes)
        }
        #expect(node == .byteString([UInt8](repeating: 0xAB, count: 64)))

        let beyond = try #require(CBORNode.decodeAnnotated(Self.embedded(Self.chunked, levels: depth + 1)).root)
        #expect(!CardanoSchemas.ledgerBoundedBytes(beyond).changed)
        #expect(CardanoSchemas.ledgerBoundedBytes(beyond, maxEmbeddedDepth: depth + 1).changed)
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
