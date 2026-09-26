import Foundation
import Testing

@testable import SwiftCDDL

/// Decoding that keeps where each item was written: spans, the flags for
/// encodings that depart from the preferred serialization, and partial trees
/// for input that breaks off.
@Suite struct CBORAnnotatedTests {
    /// Every CBOR input the fixtures hold: the era corpus and the `.cbor` files.
    static let inputs: [String: [UInt8]] = {
        var inputs: [String: [UInt8]] = [:]
        let root = Fixtures.url("")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            let name = url.path.replacingOccurrences(of: root.path, with: "")
            if url.pathExtension == "cbor", let data = try? Data(contentsOf: url) {
                inputs[name] = [UInt8](data)
            } else if url.pathExtension == "hex", name.contains("cardano/tx/"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            {
                inputs[name] = hexBytes(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return inputs
    }()

    @Test func fixturesArePresent() {
        #expect(Self.inputs.keys.filter { $0.contains("cardano/tx/") }.count >= 74)
        #expect(Self.inputs.count > 74)
    }

    @Test func agreesWithDecodingOnEveryFixture() {
        for (name, bytes) in Self.inputs {
            let annotated = CBORNode.decodeAnnotated(bytes)
            let plain = try? CBORNode(decoding: bytes)
            #expect(annotated.node == plain, "\(name)")
            if let plain {
                #expect(annotated.root?.node == plain, "\(name)")
                #expect(annotated.error == nil, "\(name)")
            }
        }
    }

    @Test func spansTileTheirParent() {
        for (name, bytes) in Self.inputs {
            guard let root = CBORNode.decodeAnnotated(bytes).root, root.isComplete else { continue }
            #expect(root.span.range == 0..<bytes.count, "\(name)")
            var ok = true
            root.walk { _, item in
                var position = item.span.headerEnd
                for child in item.children {
                    if child.span.start != position { ok = false }
                    position = child.span.end
                }
                let breakByte = item.flags.contains(.indefiniteLength) ? 1 : 0
                if !item.children.isEmpty && position + breakByte != item.span.end { ok = false }
                if item.children.isEmpty && !item.flags.contains(.indefiniteLength),
                    let node = item.node, node.encoded() != Array(bytes[item.span.range]),
                    item.flags.isEmpty
                {
                    ok = false
                }
            }
            #expect(ok, "\(name)")
        }
    }

    @Test func spansOfAMap() throws {
        // {1: h'aabb', "k": [2, 3]}
        let bytes: [UInt8] = [0xA2, 0x01, 0x42, 0xAA, 0xBB, 0x61, 0x6B, 0x82, 0x02, 0x03]
        let root = try #require(CBORNode.decodeAnnotated(bytes).root)
        #expect(root.span == CBORByteSpan(start: 0, headerEnd: 1, end: 10))
        #expect(root.children.map(\.span.range) == [1..<2, 2..<5, 5..<7, 7..<10])
        #expect(root.children[1].span.payload == 3..<5)
        #expect(root.flags.isEmpty)
        #expect(root.path(toByte: 4) == [1])
        #expect(root.path(toByte: 9) == [3, 1])
        #expect(root.path(toByte: 0) == [])
        #expect(root.path(toByte: 10) == nil)
        #expect(root.item(at: [3, 1])?.node == .unsigned(3))
    }

    @Test func flagsOverlongHeads() throws {
        // 1 written in two bytes, and a one-item array whose count takes two.
        let one = try #require(CBORNode.decodeAnnotated([0x18, 0x01]).root)
        #expect(one.flags == .overlongHead)
        #expect(one.node == .unsigned(1))
        let array = try #require(CBORNode.decodeAnnotated([0x98, 0x01, 0x00]).root)
        #expect(array.flags == .overlongHead)
        #expect(array.span.header == 0..<2)
        #expect(try #require(CBORNode.decodeAnnotated([0x18, 0x18]).root).flags.isEmpty)
    }

    @Test func flagsIndefiniteLengths() throws {
        // [_ 1], and (_ h'01', h'0203')
        let array = try #require(CBORNode.decodeAnnotated([0x9F, 0x01, 0xFF]).root)
        #expect(array.flags == .indefiniteLength)
        #expect(array.span.end == 3)
        let bytes = try #require(CBORNode.decodeAnnotated([0x5F, 0x41, 0x01, 0x42, 0x02, 0x03, 0xFF]).root)
        #expect(bytes.flags == .indefiniteLength)
        #expect(bytes.node == .byteString([1, 2, 3], indefinite: true))
        #expect(bytes.children.map(\.span.range) == [1..<3, 3..<6])
    }

    @Test func refusesAChunkOfTheWrongType() {
        // (_ h'01', "a")
        let result = CBORNode.decodeAnnotated([0x5F, 0x41, 0x01, 0x61, 0x61, 0xFF])
        #expect(result.error == .syntax(offset: 3))
        #expect(result.errorOffset == 3)
        #expect(result.root?.isComplete == false)
    }

    @Test func flagsWideFloats() throws {
        // 1.5 as a single and as a double; 0.1 needs a double.
        let single = try #require(CBORNode.decodeAnnotated([0xFA, 0x3F, 0xC0, 0x00, 0x00]).root)
        #expect(single.flags == .nonPreferredFloat)
        let double = try #require(
            CBORNode.decodeAnnotated([0xFB, 0x3F, 0xF8, 0, 0, 0, 0, 0, 0]).root
        )
        #expect(double.flags == .nonPreferredFloat)
        let tenth = try #require(
            CBORNode.decodeAnnotated([0xFB, 0x3F, 0xB9, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A]).root
        )
        #expect(tenth.flags.isEmpty)
    }

    @Test func flagsMapKeyOrder() throws {
        // {2: 0, 1: 0} is out of order; {1: 0, 1: 0} repeats a key.
        let unsorted = try #require(CBORNode.decodeAnnotated([0xA2, 0x02, 0x00, 0x01, 0x00]).root)
        #expect(unsorted.flags == .unsortedMapKeys)
        let repeated = try #require(CBORNode.decodeAnnotated([0xA2, 0x01, 0x00, 0x01, 0x00]).root)
        #expect(repeated.flags == .duplicateMapKeys)
        #expect(repeated.children[0].flags.isEmpty)
        #expect(repeated.children[2].flags == .duplicateKey)
        #expect(repeated.node?.mapEntries?.count == 2)
    }

    @Test func keepsWhatDecodedBeforeTheInputEnds() throws {
        // [1, [2, h'03 (truncated)
        let result = CBORNode.decodeAnnotated([0x83, 0x01, 0x82, 0x02, 0x42, 0x03])
        #expect(result.error == .unexpectedEndOfInput)
        #expect(result.errorOffset == 4)
        #expect(result.node == nil)
        let root = try #require(result.root)
        #expect(!root.isComplete)
        #expect(root.span.range == 0..<4)
        #expect(root.children.count == 2)
        #expect(root.children[0].node == .unsigned(1))
        #expect(root.children[1].isComplete == false)
        #expect(root.children[1].children.map(\.node) == [.unsigned(2)])
    }

    @Test func reportsTrailingBytesWithTheItemWhole() throws {
        let result = CBORNode.decodeAnnotated([0x01, 0x02])
        #expect(result.error == .trailingBytes(1))
        #expect(result.errorOffset == 1)
        #expect(result.root?.node == .unsigned(1))
        #expect(result.node == nil)
    }

    @Test func refusesAStrayBreak() {
        let result = CBORNode.decodeAnnotated([0x81, 0xFF])
        #expect(result.error == .unexpectedBreak)
        #expect(result.errorOffset == 1)
    }

    @Test func keepsNonCanonicalCardanoEncodings() throws {
        // Ledger transactions are rarely in canonical form; the corpus must
        // show at least one of each departure a viewer would flag.
        var seen: CBORNonCanonicalFlags = []
        for (name, bytes) in Self.inputs where name.contains("cardano/tx/") {
            CBORNode.decodeAnnotated(bytes).root?.walk { _, item in seen.formUnion(item.flags) }
        }
        #expect(seen.contains(.indefiniteLength))
        #expect(seen.contains(.overlongHead) || seen.contains(.unsortedMapKeys))
    }

    // MARK: - Nesting

    /// How many levels `item` nests through first children, walked without
    /// recursing.
    private static func depth(of item: CBORAnnotatedItem) -> Int {
        var depth = 1
        var item = item
        while let child = item.children.first {
            depth += 1
            item = child
        }
        return depth
    }

    /// Decoding, copying and freeing an annotated tree keep their pending work
    /// on the heap, so a tree nested far past what a small stack holds is
    /// handled on a task of Swift concurrency.
    @Test func aDeeplyNestedTreeIsDecodedCopiedAndFreedOnATask() async {
        let levels = 100_000
        await Task.detached {
            // Past the decoding bound: the levels read are kept, incomplete.
            var decoding: CBORAnnotatedDecoding? = CBORNode.decodeAnnotated(
                [UInt8](repeating: 0x81, count: levels) + [0x00]
            )
            #expect(decoding?.error == .nestedTooDeeply)
            #expect(decoding?.root.map(Self.depth) == maxDecodeNestingDepth + 1)

            // At the bound: the whole tree decodes.
            var complete: CBORAnnotatedItem? = CBORNode.decodeAnnotated(
                [UInt8](repeating: 0x81, count: maxDecodeNestingDepth) + [0x00]
            ).root
            #expect(complete?.isComplete == true)
            #expect(complete.map(Self.depth) == maxDecodeNestingDepth + 1)

            // Built by hand, past the bound.
            var built = CBORAnnotatedItem(node: .unsigned(0), span: CBORByteSpan(start: 0, headerEnd: 1, end: 1), flags: [], children: [])
            for _ in 0..<levels {
                built = CBORAnnotatedItem(node: nil, span: built.span, flags: [], children: [built])
            }
            var copy: CBORAnnotatedItem? = built
            #expect(copy.map(Self.depth) == levels + 1)

            built = CBORAnnotatedItem(node: nil, span: built.span, flags: [], children: [])
            decoding = nil
            complete = nil
            copy = nil
            #expect(decoding == nil && complete == nil && copy == nil)
        }.value
    }
}
