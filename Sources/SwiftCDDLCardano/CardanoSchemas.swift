import Foundation
import SwiftCDDL

/// A Cardano ledger era with a transaction schema.
public enum CardanoEra: String, CaseIterable, Sendable, Hashable {
    case shelley, allegra, mary, alonzo, babbage, conway
}

/// The ledger's CDDL schemas for every era from Shelley to Conway, and
/// transaction validation against them.
///
/// The schemas are the ledger's own, unchanged; see `SOURCE.txt` next to them
/// for where they come from and under which licence.
public enum CardanoSchemas {
    /// The text of `era`'s schema.
    public static func source(for era: CardanoEra) throws -> String {
        guard let url = Bundle.module.url(forResource: era.rawValue, withExtension: "cddl") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `era`'s schema, parsed. Parsing takes a while, so each era is parsed
    /// once and kept.
    public static func document(for era: CardanoEra) throws -> CDDLDocument {
        try cache.document(for: era)
    }

    /// Validates `transaction`, the bytes of a whole transaction, against the
    /// `transaction` rule of `era`'s schema, and says which issues the ledger
    /// accepts anyway.
    public static func validate(
        transaction: Data,
        era: CardanoEra,
        options: ValidationOptions = ValidationOptions()
    ) async throws -> CardanoValidationResult {
        let document = try document(for: era)
        let decoding = CBORNode.decodeAnnotated(transaction)
        let result: ValidationResult
        if let node = decoding.node {
            result = await document.validate(cbor: node, rule: "transaction", options: options)
        } else {
            result = await document.validate(cbor: transaction, rule: "transaction", options: options)
        }
        guard !result.isValid, let root = decoding.root, decoding.error == nil else {
            let issues = result.issues.map {
                CardanoValidationIssue(issue: $0, classification: .schema, itemPath: decoding.root?.path(forIssuePath: $0.path))
            }
            return CardanoValidationResult(result: result, issues: issues, decoding: decoding)
        }

        // Validate again as the ledger reads chunked byte strings: whatever
        // refusal goes away was down to them.
        let ledgerView = ledgerBoundedBytes(root, maxEmbeddedDepth: options.limits.maxEmbeddedDepth)
        var remaining = Set<ValidationIssue>()
        if ledgerView.changed, let node = ledgerView.item.node {
            let second = await document.validate(cbor: node, rule: "transaction", options: options)
            remaining = Set(second.issues)
        } else {
            remaining = Set(result.issues)
        }
        let issues = result.issues.map { issue in
            CardanoValidationIssue(
                issue: issue,
                classification: remaining.contains(issue) ? .schema : .ledgerChunkedBytes,
                itemPath: root.path(forIssuePath: issue.path)
            )
        }
        return CardanoValidationResult(result: result, issues: issues, decoding: decoding)
    }

    /// The most bytes a single chunk of a ledger byte string may hold.
    public static let boundedBytesChunkLimit = 64

    /// `item` with every byte string the ledger accepts as bounded bytes
    /// despite its length — longer than 64 bytes, written in chunks of at
    /// most 64 — cut to its first 64 bytes, so the schema's
    /// `bounded_bytes = bytes .size (0 .. 64)` reads it as the ledger does.
    ///
    /// CBOR embedded under tag 24 is read up to `maxEmbeddedDepth` levels
    /// down, as deep as validation reads it. The tree is walked with its
    /// pending work on the heap, so it may nest as deeply as decoding admits
    /// on any stack.
    static func ledgerBoundedBytes(
        _ item: CBORAnnotatedItem,
        maxEmbeddedDepth: Int = ValidationLimits.defaultMaxEmbeddedDepth
    ) -> (item: CBORAnnotatedItem, changed: Bool) {
        /// An item whose children are being rewritten. For CBOR embedded
        /// under tag 24 the one child is the decoded payload.
        struct Frame {
            let item: CBORAnnotatedItem
            let children: [CBORAnnotatedItem]
            let embedded: Bool
            let embeddedDepth: Int
            var rewritten: [CBORAnnotatedItem] = []
            var changed = false
        }

        let limit = boundedBytesChunkLimit
        var frames: [Frame] = []
        var next = item
        var embeddedDepth = 0

        while true {
            // Rewrite `next` if it is a leaf, or open a frame for its children.
            var done: (item: CBORAnnotatedItem, changed: Bool)
            switch next.node {
            case .byteString(let bytes, indefinite: true)?
            where bytes.count > limit && next.children.allSatisfy({ $0.span.payload.count <= limit }):
                let cut = CBORAnnotatedItem(
                    node: .byteString(Array(bytes.prefix(limit))), span: next.span, flags: next.flags, children: []
                )
                done = (cut, true)
            case .tagged(let tagged)? where tagged.tag == 24:
                // CBOR embedded in a byte string, as inline datums are.
                guard embeddedDepth < maxEmbeddedDepth, case .byteString(let embedded, _) = tagged.content,
                    let inner = CBORNode.decodeAnnotated(embedded).root, inner.isComplete
                else {
                    done = (next, false)
                    break
                }
                frames.append(Frame(item: next, children: [inner], embedded: true, embeddedDepth: embeddedDepth))
                next = inner
                embeddedDepth += 1
                continue
            case .array?, .map?, .tagged?:
                guard let first = next.children.first else {
                    done = (next, false)
                    break
                }
                frames.append(Frame(item: next, children: next.children, embedded: false, embeddedDepth: embeddedDepth))
                next = first
                continue
            default:
                done = (next, false)
            }

            // Hand the rewritten item to its parent, closing every frame it
            // completes, until one has a child left to rewrite.
            while var frame = frames.popLast() {
                frame.rewritten.append(done.item)
                frame.changed = frame.changed || done.changed
                if frame.rewritten.count < frame.children.count {
                    next = frame.children[frame.rewritten.count]
                    embeddedDepth = frame.embeddedDepth
                    frames.append(frame)
                    break
                }
                done = rebuilt(frame.item, children: frame.rewritten, changed: frame.changed, embedded: frame.embedded)
            }
            if frames.isEmpty {
                return done
            }
        }
    }

    /// `item` with its children rewritten, or with its embedded CBOR
    /// rewritten when `embedded` says the one child is that.
    private static func rebuilt(
        _ item: CBORAnnotatedItem,
        children: [CBORAnnotatedItem],
        changed: Bool,
        embedded: Bool
    ) -> (item: CBORAnnotatedItem, changed: Bool) {
        guard changed, let node = item.node else { return (item, false) }
        if embedded {
            guard let inner = children[0].node else { return (item, false) }
            let rewrapped = CBORNode.tagged(CBORTaggedItem(tag: 24, content: .byteString(inner.encoded())))
            return (CBORAnnotatedItem(node: rewrapped, span: item.span, flags: item.flags, children: item.children), true)
        }
        let nodes = children.compactMap(\.node)
        let rebuilt: CBORNode
        switch node {
        case .array(let array):
            rebuilt = .array(CBORArray(nodes, indefinite: array.isIndefinite))
        case .map(let map):
            let entries = stride(from: 0, to: nodes.count - 1, by: 2).map { (key: nodes[$0], value: nodes[$0 + 1]) }
            rebuilt = .map(CBORMap(entries, indefinite: map.isIndefinite))
        case .tagged(let tagged):
            rebuilt = .tagged(CBORTaggedItem(tag: tagged.tag, content: nodes[0]))
        default:
            return (item, false)
        }
        return (CBORAnnotatedItem(node: rebuilt, span: item.span, flags: item.flags, children: children), true)
    }

    private static let cache = DocumentCache()
}

/// What a schema mismatch means for the ledger.
public enum CardanoIssueClassification: Sendable, Hashable {
    /// The ledger refuses what the schema refuses.
    case schema
    /// A byte string longer than 64 bytes, written with indefinite length in
    /// chunks of at most 64 bytes each.
    ///
    /// The schema's `bounded_bytes = bytes .size (0 .. 64)` constrains the
    /// whole value, while the ledger's decoder bounds each chunk, so the
    /// ledger accepts it. Plutus data is written this way on chain.
    case ledgerChunkedBytes
}

/// A validation issue, with what it means for the ledger.
public struct CardanoValidationIssue: Sendable, Hashable, CustomStringConvertible {
    public var issue: ValidationIssue
    public var classification: CardanoIssueClassification
    /// The child indexes in ``CardanoValidationResult/decoding`` leading to
    /// the item the issue is about, when it could be found.
    public var itemPath: [Int]?

    /// Whether the ledger accepts what this issue refuses.
    public var isLedgerAccepted: Bool { classification != .schema }

    public var description: String {
        isLedgerAccepted ? "\(issue) (accepted by the ledger)" : issue.description
    }
}

/// The verdict of validating a transaction against its era's schema.
public struct CardanoValidationResult: Sendable {
    /// The schema's verdict as it stands.
    public var result: ValidationResult
    /// The schema's issues, each with what it means for the ledger.
    public var issues: [CardanoValidationIssue]
    /// The transaction decoded with where each item was written, for linking
    /// issues to bytes.
    public var decoding: CBORAnnotatedDecoding

    /// Whether the schema matches the transaction outright.
    public var matchesSchema: Bool { result.isValid }

    /// Whether every issue is one the ledger accepts anyway.
    public var isLedgerValid: Bool { issues.allSatisfy(\.isLedgerAccepted) }
}

private final class DocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [CardanoEra: CDDLDocument] = [:]

    func document(for era: CardanoEra) throws -> CDDLDocument {
        lock.lock()
        defer { lock.unlock() }
        if let document = documents[era] { return document }
        let document = try CDDLDocument(try CardanoSchemas.source(for: era))
        documents[era] = document
        return document
    }
}
