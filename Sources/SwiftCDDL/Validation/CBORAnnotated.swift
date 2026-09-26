import CBORCodable
import Foundation

// Decoding that keeps where each data item sits in the bytes.
//
// ``CBORNode`` holds what the bytes mean; this holds, alongside it, where each
// item's head and payload were written and how the writing departs from the
// preferred serialization of RFC 8949 Section 4. A viewer uses it to link a
// byte to the item it belongs to and back, and to show what a canonical
// encoder would have written differently. Input that stops being well-formed
// part way through still yields the items read up to that point.

/// Where a data item was written: its head, then its payload.
///
/// For a container or a tag the payload is its content, and for an item of
/// indefinite length it runs up to and including the break stop code.
public struct CBORByteSpan: Sendable, Hashable, CustomStringConvertible {
    /// The offset of the item's first byte, which starts its head.
    public let start: Int
    /// The offset just past the head, where the payload starts.
    public let headerEnd: Int
    /// The offset just past the item.
    public let end: Int

    public init(start: Int, headerEnd: Int, end: Int) {
        self.start = start
        self.headerEnd = headerEnd
        self.end = end
    }

    /// The bytes of the head: the initial byte and any argument bytes.
    public var header: Range<Int> { start..<headerEnd }
    /// The bytes after the head.
    public var payload: Range<Int> { headerEnd..<end }
    /// Every byte of the item.
    public var range: Range<Int> { start..<end }

    public var description: String { "\(start)..<\(end) (head \(start)..<\(headerEnd))" }
}

/// Ways an item's encoding departs from the preferred serialization of RFC
/// 8949 Section 4.
///
/// None of these makes the bytes malformed. They matter where bytes are hashed
/// or signed, since re-encoding the same value canonically changes them.
public struct CBORNonCanonicalFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The head's argument was written in more bytes than it needs.
    public static let overlongHead = CBORNonCanonicalFlags(rawValue: 1 << 0)
    /// A string, array or map was written with indefinite length.
    public static let indefiniteLength = CBORNonCanonicalFlags(rawValue: 1 << 1)
    /// A float was written wider than needed to hold its value exactly.
    public static let nonPreferredFloat = CBORNonCanonicalFlags(rawValue: 1 << 2)
    /// A map's keys are not in bytewise order of their encodings
    /// (RFC 8949 Section 4.2.1).
    public static let unsortedMapKeys = CBORNonCanonicalFlags(rawValue: 1 << 3)
    /// A map holds a key more than once.
    public static let duplicateMapKeys = CBORNonCanonicalFlags(rawValue: 1 << 4)
    /// This item is a map key written the same as an earlier key of its map.
    public static let duplicateKey = CBORNonCanonicalFlags(rawValue: 1 << 5)
}

/// A decoded data item with where it was written, and the same for its
/// children.
///
/// The children follow the encoding: an array's items; a map's keys and values
/// alternating, key first; a tag's content; and the chunks of a string of
/// indefinite length.
public struct CBORAnnotatedItem: Sendable {
    /// The item, or `nil` when the input ended or broke off before it was
    /// complete.
    public let node: CBORNode?
    /// Where the item was written. An incomplete item ends where decoding
    /// stopped.
    public let span: CBORByteSpan
    /// How the item's own encoding departs from the preferred serialization.
    public let flags: CBORNonCanonicalFlags
    public let children: [CBORAnnotatedItem]

    public init(node: CBORNode?, span: CBORByteSpan, flags: CBORNonCanonicalFlags, children: [CBORAnnotatedItem]) {
        self.node = node
        self.span = span
        self.flags = flags
        self.children = children
    }

    /// Whether the item and everything in it decoded.
    public var isComplete: Bool { node != nil }

    /// The child indexes leading from this item to the innermost item whose
    /// bytes include `offset`, or `nil` when this item's bytes do not.
    public func path(toByte offset: Int) -> [Int]? {
        guard span.range.contains(offset) else { return nil }
        var path: [Int] = []
        var item = self
        while let index = item.children.firstIndex(where: { $0.span.range.contains(offset) }) {
            path.append(index)
            item = item.children[index]
        }
        return path
    }

    /// The item reached by following `path` down from this one.
    public func item(at path: [Int]) -> CBORAnnotatedItem? {
        var item = self
        for index in path {
            guard item.children.indices.contains(index) else { return nil }
            item = item.children[index]
        }
        return item
    }

    /// The child indexes leading to the item a validation issue is about,
    /// given the issue's ``ValidationIssue/path``, or `nil` when no item of
    /// this tree has that location.
    ///
    /// A path names array items by index and map entries by key, and passes
    /// through tags without a segment. A map entry's segment leads to its
    /// value. A path that goes on into CBOR embedded in a byte string (the
    /// `.cbor` control) leads to that byte string.
    public func path(forIssuePath issuePath: String) -> [Int]? {
        var path: [Int] = []
        var item = self
        var rest = Substring(issuePath)
        while true {
            while case .tagged? = item.node, item.children.count == 1 {
                path.append(0)
                item = item.children[0]
            }
            if rest.isEmpty { return path }
            guard rest.first == "/" else { return nil }
            rest = rest.dropFirst()
            switch item.node {
            case .byteString?:
                return path
            case .array?:
                let segment = rest.prefix { $0 != "/" }
                guard let index = Int(segment), item.children.indices.contains(index) else { return nil }
                rest = rest.dropFirst(segment.count)
                path.append(index)
                item = item.children[index]
            case .map?:
                let match = stride(from: 0, to: item.children.count - 1, by: 2).lazy.compactMap { index -> (Int, Int)? in
                    guard let key = item.children[index].node else { return nil }
                    let segment = formatPathKey(key)
                    guard rest.hasPrefix(segment) else { return nil }
                    let after = rest.dropFirst(segment.count)
                    return after.isEmpty || after.first == "/" ? (index + 1, segment.count) : nil
                }.first
                guard let (index, length) = match else { return nil }
                rest = rest.dropFirst(length)
                path.append(index)
                item = item.children[index]
            default:
                return nil
            }
        }
    }

    /// Every item from this one down, in the order they were written, with
    /// the path to each.
    public func walk(_ visit: (_ path: [Int], _ item: CBORAnnotatedItem) -> Void) {
        var pending: [([Int], CBORAnnotatedItem)] = [([], self)]
        while let (path, item) = pending.popLast() {
            visit(path, item)
            for index in item.children.indices.reversed() {
                pending.append((path + [index], item.children[index]))
            }
        }
    }
}

/// The result of decoding with ``CBORNode/decodeAnnotated(_:)``: the items
/// read, and why decoding stopped early if it did.
public struct CBORAnnotatedDecoding: Sendable {
    /// The top-level item, complete or as far as it decoded, or `nil` when
    /// not even its head could be read.
    public let root: CBORAnnotatedItem?
    /// Why the bytes are not a single well-formed data item, if they are not.
    public let error: CBORDecodingError?
    /// The byte offset decoding stopped at, when it stopped with an error.
    public let errorOffset: Int?

    /// The decoded item, when the bytes are exactly one well-formed item.
    public var node: CBORNode? { error == nil ? root?.node : nil }
}

extension CBORNode {
    /// Decodes bytes holding one CBOR data item, keeping where each item was
    /// written and how its encoding departs from the preferred serialization.
    ///
    /// Unlike ``init(decoding:)-([UInt8])`` this does not throw: malformed or
    /// truncated input yields the items read up to where decoding stopped,
    /// with the error and its offset. Bytes after the item are reported as
    /// ``CBORDecodingError/trailingBytes(_:)`` with the item kept whole.
    public static func decodeAnnotated(_ bytes: [UInt8]) -> CBORAnnotatedDecoding {
        var decoder = AnnotatingDecoder(bytes)
        do {
            let root = try decoder.decodeItem()
            let trailing = bytes.count - decoder.offset
            if trailing != 0 {
                return CBORAnnotatedDecoding(root: root, error: .trailingBytes(trailing), errorOffset: decoder.offset)
            }
            return CBORAnnotatedDecoding(root: root, error: nil, errorOffset: nil)
        } catch {
            let stop = decoder.itemStart
            return CBORAnnotatedDecoding(root: decoder.closeIncomplete(at: stop), error: error, errorOffset: stop)
        }
    }

    /// Decodes `data`; see ``decodeAnnotated(_:)-([UInt8])``.
    public static func decodeAnnotated(_ data: Data) -> CBORAnnotatedDecoding {
        decodeAnnotated([UInt8](data))
    }
}

private struct AnnotatingDecoder {
    enum Kind: Equatable {
        case tag(UInt64)
        case array
        case map
        case bytes
        case text
    }

    /// A container, tag or chunked string whose content is still being read.
    struct Frame {
        var kind: Kind
        var start: Int
        var headerEnd: Int
        /// Children still to come, or `nil` for indefinite length.
        var remaining: UInt64?
        var flags: CBORNonCanonicalFlags
        var children: [CBORAnnotatedItem] = []
    }

    let input: [UInt8]
    var reader: CBORReader
    var frames: [Frame] = []
    /// Where the item being read began, which is where an error is reported.
    var itemStart = 0

    init(_ input: [UInt8]) {
        self.input = input
        self.reader = CBORReader(Data(input), maxDepth: Int.max)
    }

    var offset: Int { input.count - reader.remaining }

    mutating func decodeItem() throws(CBORDecodingError) -> CBORAnnotatedItem {
        while true {
            if frames.count > maxDecodeNestingDepth {
                throw .nestedTooDeeply
            }
            itemStart = offset
            let head = try readHead()
            let headerEnd = offset
            var flags = Self.headFlags(head)

            if head.majorType == .simpleOrFloat && head.isIndefinite {
                // A break closes the innermost item of indefinite length.
                guard var frame = frames.popLast(), frame.remaining == nil else {
                    throw .unexpectedBreak
                }
                if case .map = frame.kind, frame.children.count % 2 != 0 {
                    throw .unexpectedBreak
                }
                if let item = try close(&frame, end: offset), let finished = try attach(item) {
                    return finished
                }
                continue
            }

            if head.isIndefinite {
                flags.insert(.indefiniteLength)
            }

            // Chunks of a string of indefinite length are definite strings of
            // the same major type (RFC 8949 Section 3.2.3).
            if let frame = frames.last, frame.remaining == nil {
                switch frame.kind {
                case .bytes where head.majorType != .byteString || head.isIndefinite,
                    .text where head.majorType != .textString || head.isIndefinite:
                    throw .syntax(offset: itemStart)
                default:
                    break
                }
            }

            let length: UInt64? = head.isIndefinite ? nil : head.argument
            let node: CBORNode
            switch head.majorType {
            case .unsignedInt:
                guard !head.isIndefinite else { throw .syntax(offset: itemStart) }
                node = .unsigned(head.argument)
            case .negativeInt:
                guard !head.isIndefinite else { throw .syntax(offset: itemStart) }
                node = .negative(head.argument)
            case .byteString, .textString:
                guard let length else {
                    let kind: Kind = head.majorType == .byteString ? .bytes : .text
                    frames.append(Frame(kind: kind, start: itemStart, headerEnd: headerEnd, remaining: nil, flags: flags))
                    continue
                }
                let bytes = try payload(length)
                if head.majorType == .byteString {
                    node = .byteString(bytes)
                } else {
                    guard let text = String(validatingUTF8Bytes: bytes) else { throw .syntax(offset: itemStart) }
                    node = .textString(text)
                }
            case .array, .map:
                let kind: Kind = head.majorType == .array ? .array : .map
                if length == 0 {
                    node = kind == .array ? .array(CBORArray([])) : .map(CBORMap([]))
                } else {
                    let count = length.map { kind == .map ? $0.multipliedReportingOverflow(by: 2).partialValue : $0 }
                    frames.append(Frame(kind: kind, start: itemStart, headerEnd: headerEnd, remaining: count, flags: flags))
                    continue
                }
            case .tagged:
                guard !head.isIndefinite else { throw .syntax(offset: itemStart) }
                frames.append(Frame(kind: .tag(head.argument), start: itemStart, headerEnd: headerEnd, remaining: 1, flags: flags))
                continue
            case .simpleOrFloat:
                switch head.info {
                case 25:
                    node = .float(halfToDouble(UInt16(truncatingIfNeeded: head.argument)), width: .half)
                case 26:
                    let value = Double(Float(bitPattern: UInt32(truncatingIfNeeded: head.argument)))
                    node = .float(value, width: .single)
                    if doubleToHalf(value) != nil { flags.insert(.nonPreferredFloat) }
                case 27:
                    let value = Double(bitPattern: head.argument)
                    node = .float(value, width: .double)
                    if doubleToHalf(value) != nil || Double(Float(value)).bitPattern == value.bitPattern {
                        flags.insert(.nonPreferredFloat)
                    }
                default:
                    switch head.argument {
                    case 20: node = .bool(false)
                    case 21: node = .bool(true)
                    case 22: node = .null
                    case 23: node = .undefined
                    default: node = .simple(UInt8(truncatingIfNeeded: head.argument))
                    }
                }
            }

            let item = CBORAnnotatedItem(
                node: node,
                span: CBORByteSpan(start: itemStart, headerEnd: headerEnd, end: offset),
                flags: flags,
                children: []
            )
            if let finished = try attach(item) {
                return finished
            }
        }
    }

    /// Hands a finished item to the innermost open frame, closing each frame
    /// it completes, and returns it when no frame is open to take it.
    mutating func attach(_ item: CBORAnnotatedItem) throws(CBORDecodingError) -> CBORAnnotatedItem? {
        var item = item
        while var frame = frames.popLast() {
            frame.children.append(item)
            if let remaining = frame.remaining {
                frame.remaining = remaining - 1
                if remaining - 1 == 0, let closed = try close(&frame, end: offset) {
                    item = closed
                    continue
                }
            }
            frames.append(frame)
            return nil
        }
        return item
    }

    /// Builds the item a frame holds, now that all of it has been read.
    func close(_ frame: inout Frame, end: Int) throws(CBORDecodingError) -> CBORAnnotatedItem? {
        let nodes = frame.children.compactMap(\.node)
        let indefinite = frame.remaining == nil
        let node: CBORNode
        switch frame.kind {
        case .tag(let tag):
            node = .tagged(CBORTaggedItem(tag: tag, content: nodes[0]))
        case .array:
            node = .array(CBORArray(nodes, indefinite: indefinite))
        case .map:
            var entries: [(key: CBORNode, value: CBORNode)] = []
            entries.reserveCapacity(nodes.count / 2)
            for index in stride(from: 0, to: nodes.count, by: 2) {
                entries.append((key: nodes[index], value: nodes[index + 1]))
            }
            node = .map(CBORMap(entries, indefinite: indefinite))
            markKeyOrder(&frame)
        case .bytes:
            var bytes: [UInt8] = []
            for case .byteString(let chunk, _) in nodes { bytes += chunk }
            node = .byteString(bytes, indefinite: true)
        case .text:
            var text = ""
            for case .textString(let chunk, _) in nodes { text += chunk }
            node = .textString(text, indefinite: true)
        }
        return CBORAnnotatedItem(
            node: node,
            span: CBORByteSpan(start: frame.start, headerEnd: frame.headerEnd, end: end),
            flags: frame.flags,
            children: frame.children
        )
    }

    /// Flags a map whose keys, as written, are out of bytewise order or
    /// repeated, and each repeated key.
    func markKeyOrder(_ frame: inout Frame) {
        var seen = Set<ArraySlice<UInt8>>()
        var previous: ArraySlice<UInt8>?
        for index in stride(from: 0, to: frame.children.count, by: 2) {
            let key = input[frame.children[index].span.range]
            if let previous, !previous.lexicographicallyPrecedes(key) {
                frame.flags.insert(previous == key ? .duplicateMapKeys : .unsortedMapKeys)
            }
            if !seen.insert(key).inserted {
                frame.flags.insert(.duplicateMapKeys)
                let child = frame.children[index]
                frame.children[index] = CBORAnnotatedItem(
                    node: child.node,
                    span: child.span,
                    flags: child.flags.union(.duplicateKey),
                    children: child.children
                )
            }
            previous = key
        }
    }

    /// After an error, closes every open frame as an incomplete item ending
    /// at `stop`, and returns the outermost.
    mutating func closeIncomplete(at stop: Int) -> CBORAnnotatedItem? {
        var item: CBORAnnotatedItem?
        while let frame = frames.popLast() {
            item = CBORAnnotatedItem(
                node: nil,
                span: CBORByteSpan(start: frame.start, headerEnd: frame.headerEnd, end: stop),
                flags: frame.flags,
                children: frame.children + (item.map { [$0] } ?? [])
            )
        }
        return item
    }

    mutating func readHead() throws(CBORDecodingError) -> CBORReader.Head {
        do {
            return try reader.readHead()
        } catch CBORError.prematureEnd {
            throw .unexpectedEndOfInput
        } catch {
            throw .syntax(offset: itemStart)
        }
    }

    mutating func payload(_ length: UInt64) throws(CBORDecodingError) -> [UInt8] {
        guard length <= UInt64(reader.remaining) else { throw .unexpectedEndOfInput }
        do {
            return [UInt8](try reader.readBytes(Int(length)))
        } catch {
            throw .unexpectedEndOfInput
        }
    }

    /// Whether a head's argument took more bytes than it needed. Float heads
    /// carry the value's bits, not an argument, and are judged separately.
    static func headFlags(_ head: CBORReader.Head) -> CBORNonCanonicalFlags {
        if head.majorType == .simpleOrFloat && head.info >= 25 { return [] }
        let overlong: Bool
        switch head.info {
        case 24: overlong = head.argument < 24
        case 25: overlong = head.argument <= 0xFF
        case 26: overlong = head.argument <= 0xFFFF
        case 27: overlong = head.argument <= 0xFFFF_FFFF
        default: overlong = false
        }
        return overlong ? .overlongHead : []
    }
}
