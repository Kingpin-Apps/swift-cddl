import BigInt
import CBORCodable
import Foundation

// The CBOR data model a document is validated in (RFC 8949 Section 2).
//
// A map is held as the ordered list of its key/value pairs, as the bytes
// carried them: two pairs with equal keys, or with NaN keys, stay two pairs,
// and every pair keeps its position. Integers cover the whole range major
// types 0 and 1 encode (-2^64 up to 2^64-1); tags 2 and 3 carry larger
// magnitudes as bignums (RFC 8949 Section 3.4.3). The width a float was
// encoded in, and whether a string or container was of indefinite length, are
// kept alongside the value they encode.
//
// Nesting in a data item is bounded by the input rather than by the stack:
// decoding, copying, comparing, encoding and freeing a node all keep the
// containers they have open on the heap.

/// A CBOR data item (RFC 8949 Section 2).
public enum CBORNode: Sendable {
    /// An unsigned integer (major type 0).
    case unsigned(UInt64)
    /// A negative integer (major type 1), holding the encoded argument `n`
    /// of the value `-1 - n`.
    case negative(UInt64)
    /// A byte string (major type 2), with whether it was encoded in chunks of
    /// indefinite length.
    case byteString([UInt8], indefinite: Bool = false)
    /// A text string (major type 3), with whether it was encoded in chunks of
    /// indefinite length.
    case textString(String, indefinite: Bool = false)
    /// An array (major type 4).
    case array(CBORArray)
    /// A map (major type 5).
    case map(CBORMap)
    /// A tagged data item (major type 6).
    case tagged(CBORTaggedItem)
    /// A floating point number (major type 7), with the width it was encoded
    /// in.
    case float(Double, width: CBORFloatWidth = .double)
    /// A simple value other than `false`, `true`, `null` and `undefined`.
    case simple(UInt8)
    /// `false` or `true` (simple values 20 and 21).
    case bool(Bool)
    /// `null` (simple value 22).
    case null
    /// `undefined` (simple value 23).
    case undefined

    /// An array holding `items`.
    public static func array(_ items: [CBORNode], indefinite: Bool = false) -> CBORNode {
        .array(CBORArray(items, indefinite: indefinite))
    }

    /// A map holding `entries`, in order.
    public static func map(_ entries: [(key: CBORNode, value: CBORNode)], indefinite: Bool = false) -> CBORNode {
        .map(CBORMap(entries, indefinite: indefinite))
    }

    /// `content` under tag number `tag`.
    public static func tagged(_ tag: UInt64, _ content: CBORNode) -> CBORNode {
        .tagged(CBORTaggedItem(tag: tag, content: content))
    }

    /// An integer, in the major type its sign selects.
    public static func integer(_ value: Int64) -> CBORNode {
        value < 0 ? .negative(UInt64(-1 - value)) : .unsigned(UInt64(value))
    }

    /// A text string.
    public static func text(_ value: String) -> CBORNode {
        .textString(value)
    }

    /// A byte string.
    public static func bytes(_ value: [UInt8]) -> CBORNode {
        .byteString(value)
    }
}

/// The width a floating point number was encoded in (RFC 8949 Section 3.3).
public enum CBORFloatWidth: Sendable, Hashable {
    /// IEEE 754 binary16 (additional information 25).
    case half
    /// IEEE 754 binary32 (additional information 26).
    case single
    /// IEEE 754 binary64 (additional information 27).
    case double
}

// MARK: - Containers

/// The storage shared by the CBOR containers: an array, a map and a tagged
/// item. Freeing one frees what it holds one container at a time, so a
/// document nested however deeply is freed on whatever stack drops it.
public class CBORContainer: @unchecked Sendable {
    /// Moves every container this one holds directly into `pending`, leaving
    /// it holding none.
    func takeChildContainers(into pending: inout [CBORContainer]) {}
}

extension CBORNode {
    /// The container this node is, if it is one.
    var container: CBORContainer? {
        switch self {
        case .array(let array): return array
        case .map(let map): return map
        case .tagged(let tagged): return tagged
        default: return nil
        }
    }
}

/// Frees what `nodes` hold one container at a time, so that a document nested
/// however deeply is freed on whatever stack drops it.
///
/// A container still referenced from elsewhere is left to its other holders.
func dismantle(_ nodes: inout [CBORNode]) {
    var pending: [CBORContainer] = []
    for node in nodes {
        if let container = node.container {
            pending.append(container)
        }
    }
    nodes = []
    dismantle(&pending)
}

func dismantle(_ pending: inout [CBORContainer]) {
    while !pending.isEmpty {
        var container = pending.removeLast()
        if isKnownUniquelyReferenced(&container) {
            container.takeChildContainers(into: &pending)
        }
    }
}

/// The items of a CBOR array (major type 4).
public final class CBORArray: CBORContainer, @unchecked Sendable {
    /// The items, in order.
    public private(set) var items: [CBORNode]
    /// Whether the array was encoded with indefinite length.
    public let isIndefinite: Bool

    /// An array holding `items`.
    public init(_ items: [CBORNode], indefinite: Bool = false) {
        self.items = items
        self.isIndefinite = indefinite
    }

    override func takeChildContainers(into pending: inout [CBORContainer]) {
        for item in items {
            if let container = item.container {
                pending.append(container)
            }
        }
        items = []
    }

    deinit {
        if !items.isEmpty {
            dismantle(&items)
        }
    }
}

/// The key/value pairs of a CBOR map (major type 5), in the order they were
/// encoded.
public final class CBORMap: CBORContainer, @unchecked Sendable {
    /// The pairs, in order. Equal keys, and NaN keys, are each their own pair.
    public private(set) var entries: [(key: CBORNode, value: CBORNode)]
    /// Whether the map was encoded with indefinite length.
    public let isIndefinite: Bool

    /// A map holding `entries`.
    public init(_ entries: [(key: CBORNode, value: CBORNode)], indefinite: Bool = false) {
        self.entries = entries
        self.isIndefinite = indefinite
    }

    override func takeChildContainers(into pending: inout [CBORContainer]) {
        for (key, value) in entries {
            if let container = key.container {
                pending.append(container)
            }
            if let container = value.container {
                pending.append(container)
            }
        }
        entries = []
    }

    deinit {
        if !entries.isEmpty {
            var pending: [CBORContainer] = []
            takeChildContainers(into: &pending)
            dismantle(&pending)
        }
    }
}

/// A tag number and the data item it encloses (major type 6).
public final class CBORTaggedItem: CBORContainer, @unchecked Sendable {
    /// The tag number.
    public let tag: UInt64
    /// The enclosed data item.
    public private(set) var content: CBORNode

    /// `content` under tag number `tag`.
    public init(tag: UInt64, content: CBORNode) {
        self.tag = tag
        self.content = content
    }

    override func takeChildContainers(into pending: inout [CBORContainer]) {
        if let container = content.container {
            pending.append(container)
        }
        content = .null
    }

    deinit {
        if content.container != nil {
            var pending: [CBORContainer] = []
            takeChildContainers(into: &pending)
            dismantle(&pending)
        }
    }
}

// MARK: - Accessors

extension CBORNode {
    /// Whether this node is an array.
    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    /// Whether this node is a map.
    public var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    /// The items of an array, or `nil` for any other node.
    public var arrayItems: [CBORNode]? {
        if case .array(let array) = self { return array.items }
        return nil
    }

    /// The pairs of a map, or `nil` for any other node.
    public var mapEntries: [(key: CBORNode, value: CBORNode)]? {
        if case .map(let map) = self { return map.entries }
        return nil
    }

    /// The value of an integer (major type 0 or 1), or `nil` for any other
    /// node.
    public var integerValue: CBORInteger? {
        switch self {
        case .unsigned(let value): return CBORInteger(isNegative: false, argument: value)
        case .negative(let value): return CBORInteger(isNegative: true, argument: value)
        default: return nil
        }
    }

    /// The integer the node holds: an integer of major type 0 or 1, or a
    /// bignum, the byte string content of tag 2 (unsigned) or tag 3 (negative,
    /// `-1 - n`) read as a big-endian magnitude (RFC 8949 Section 3.4.3).
    /// `nil` for any other node.
    public var bigIntegerValue: BigInt? {
        switch self {
        case .unsigned(let value):
            return BigInt(value)
        case .negative(let value):
            return -1 - BigInt(value)
        case .tagged(let tagged):
            guard tagged.tag == 2 || tagged.tag == 3, case .byteString(let bytes, _) = tagged.content else {
                return nil
            }
            let magnitude = BigInt(BigUInt(Data(bytes)))
            return tagged.tag == 2 ? magnitude : -1 - magnitude
        default:
            return nil
        }
    }

    /// Whether the node is `null` or `undefined`, the two simple values that
    /// stand for the absence of a value.
    var isNullOrUndefined: Bool {
        switch self {
        case .null, .undefined: return true
        default: return false
        }
    }
}

/// An integer of major type 0 or 1: a value between -2^64 and 2^64-1.
public struct CBORInteger: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Whether the value is negative (major type 1).
    public let isNegative: Bool
    /// The encoded argument: the value itself for major type 0, and `n` of the
    /// value `-1 - n` for major type 1.
    public let argument: UInt64

    /// The integer encoded by `argument` under the major type `isNegative`
    /// selects.
    public init(isNegative: Bool, argument: UInt64) {
        self.isNegative = isNegative
        self.argument = argument
    }

    public static func < (lhs: CBORInteger, rhs: CBORInteger) -> Bool {
        switch (lhs.isNegative, rhs.isNegative) {
        case (true, false): return true
        case (false, true): return false
        case (false, false): return lhs.argument < rhs.argument
        case (true, true): return lhs.argument > rhs.argument
        }
    }

    public var description: String {
        if !isNegative {
            return String(argument)
        }
        if argument == UInt64.max {
            return "-18446744073709551616"
        }
        return "-" + String(argument + 1)
    }
}

// MARK: - Structural equality

extension CBORNode: Equatable {
    /// Two nodes are equal when they encode the same data item the same way:
    /// the same kind, the same value, the same float width and the same
    /// length encoding. Two NaNs of the same width are equal.
    public static func == (lhs: CBORNode, rhs: CBORNode) -> Bool {
        compareNodes(lhs, rhs, structural: true)
    }
}

/// Whether two nodes stand for the same data item as the validator compares
/// them: floats by value (so a NaN equals nothing, and the width a float was
/// encoded in is not part of it), and without regard to how lengths were
/// encoded. `undefined` compares as `null`, the value it stands for when a
/// member key or a literal is looked up.
func referenceEquals(_ lhs: CBORNode, _ rhs: CBORNode) -> Bool {
    compareNodes(lhs, rhs, structural: false)
}

private func compareNodes(_ lhs: CBORNode, _ rhs: CBORNode, structural: Bool) -> Bool {
    var pending: [(CBORNode, CBORNode)] = [(lhs, rhs)]
    while let (a, b) = pending.popLast() {
        switch (a, b) {
        case (.unsigned(let x), .unsigned(let y)), (.negative(let x), .negative(let y)):
            if x != y { return false }
        case (.byteString(let x, let xi), .byteString(let y, let yi)):
            if x != y || (structural && xi != yi) { return false }
        case (.textString(let x, let xi), .textString(let y, let yi)):
            if !x.utf8.elementsEqual(y.utf8) || (structural && xi != yi) { return false }
        case (.float(let x, let xw), .float(let y, let yw)):
            if structural {
                if xw != yw || !(x == y || (x.isNaN && y.isNaN)) { return false }
            } else if !(x == y) {
                return false
            }
        case (.simple(let x), .simple(let y)):
            if x != y { return false }
        case (.bool(let x), .bool(let y)):
            if x != y { return false }
        case (.null, .null), (.undefined, .undefined):
            break
        case (.null, .undefined), (.undefined, .null):
            if structural { return false }
        case (.tagged(let x), .tagged(let y)):
            if x.tag != y.tag { return false }
            pending.append((x.content, y.content))
        case (.array(let x), .array(let y)):
            if x.items.count != y.items.count || (structural && x.isIndefinite != y.isIndefinite) {
                return false
            }
            pending.append(contentsOf: zip(x.items, y.items))
        case (.map(let x), .map(let y)):
            if x.entries.count != y.entries.count || (structural && x.isIndefinite != y.isIndefinite) {
                return false
            }
            for (ex, ey) in zip(x.entries, y.entries) {
                pending.append((ex.key, ey.key))
                pending.append((ex.value, ey.value))
            }
        default:
            return false
        }
    }
    return true
}

// MARK: - Decoding

/// Upper bound on how deeply the data being decoded may nest.
///
/// Decoding keeps its open containers on the heap, so nesting costs it memory
/// and nothing else. RFC 8949 places no bound on how far nesting goes, and a
/// byte of input opens a level, so without a bound a document would be decoded
/// into as many levels as it has bytes; past the bound it is a decoding error,
/// reported as the implementation limit it is. The bound sits above
/// ``ValidationLimits/defaultMaxNestingDepth``, so it rejects nothing
/// validation would otherwise walk to the bottom of.
let maxDecodeNestingDepth = 65_536

/// Why a byte string did not decode as a CBOR data item.
public enum CBORDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A malformed head or payload at the given byte offset.
    case syntax(offset: Int)
    /// The input ended part way through the data item.
    case unexpectedEndOfInput
    /// A break stop code where no indefinite-length item was open.
    case unexpectedBreak
    /// Data nested more deeply than 65,536 levels.
    case nestedTooDeeply
    /// Bytes remained after the data item, carrying the count of them.
    case trailingBytes(Int)

    public var description: String {
        switch self {
        case .syntax(let offset):
            return "syntax error at offset \(offset)"
        case .unexpectedEndOfInput:
            return "unexpected end of input: the data item is incomplete"
        case .unexpectedBreak:
            return "unexpected break"
        case .nestedTooDeeply:
            return "data is nested more deeply than the maximum supported decoding depth of \(maxDecodeNestingDepth)"
        case .trailingBytes(let count):
            return
                "\(count) trailing byte\(count == 1 ? "" : "s") after the data item: a CBOR document is a single data item"
        }
    }
}

extension CBORNode {
    /// Decodes bytes holding exactly one CBOR data item (RFC 8949).
    ///
    /// Bytes after the item are reported as
    /// ``CBORDecodingError/trailingBytes(_:)`` rather than ignored, and
    /// unassigned simple values decode as ``CBORNode/simple(_:)``. The
    /// decoded item keeps what a validator needs and a generic decoder drops:
    /// duplicate map keys and their order, the width of floats, and whether
    /// arrays, maps and strings were written with indefinite length.
    public init(decoding bytes: [UInt8]) throws(CBORDecodingError) {
        self = try decodeCBOR(bytes)
    }

    /// Decodes `data`, which holds exactly one CBOR data item; see
    /// ``init(decoding:)-([UInt8])``.
    public init(decoding data: Data) throws(CBORDecodingError) {
        self = try decodeCBOR([UInt8](data))
    }
}

/// Decodes a byte string holding exactly one CBOR data item.
///
/// A well-formed data item takes no following extraneous data (RFC 8949
/// Section 1.2), so bytes after the item are reported as
/// ``CBORDecodingError/trailingBytes(_:)`` rather than ignored. Unassigned
/// simple values decode as ``CBORNode/simple(_:)``.
func decodeCBOR(_ input: [UInt8]) throws(CBORDecodingError) -> CBORNode {
    let (node, consumed) = try decodeCBORPrefix(input)
    let trailing = input.count - consumed
    if trailing != 0 {
        throw .trailingBytes(trailing)
    }
    return node
}

/// Decodes a CBOR data item held in `data`.
func decodeCBOR(_ data: Data) throws(CBORDecodingError) -> CBORNode {
    try decodeCBOR([UInt8](data))
}

/// Decodes the CBOR data item `input` begins with, returning it with the count
/// of bytes it took.
func decodeCBORPrefix(_ input: [UInt8]) throws(CBORDecodingError) -> (CBORNode, Int) {
    var decoder = NodeDecoder(input)
    let node = try decoder.decodeItem()
    return (node, decoder.offset)
}

/// Decodes a CBOR sequence (RFC 8742): zero or more concatenated data items,
/// returned as an array of them.
///
/// A sequence ends where the input does, and only at an item boundary: input
/// that stops part way through an item is a truncated item, and is reported as
/// the decoding error it is.
func decodeCBORSequence(_ input: [UInt8]) throws(CBORDecodingError) -> CBORNode {
    var decoder = NodeDecoder(input)
    var items: [CBORNode] = []
    while decoder.offset < input.count {
        items.append(try decoder.decodeItem())
    }
    return .array(items)
}

/// A decoded head: what the CBOR head of the next data item says.
private enum DecodedHead {
    case positive(UInt64)
    case negative(UInt64)
    case bytes(UInt64?)
    case text(UInt64?)
    case array(UInt64?)
    case map(UInt64?)
    case tag(UInt64)
    case simple(UInt8)
    case float(Double, CBORFloatWidth)
    case breakCode
}

/// A container whose items are still being read.
private enum OpenContainer {
    case tag(UInt64)
    case array(items: [CBORNode], remaining: UInt64?)
    case map(entries: [(key: CBORNode, value: CBORNode)], pendingKey: CBORNode?, remaining: UInt64?)

    var endsAtBreak: Bool {
        switch self {
        case .array(_, nil), .map(_, _, nil): return true
        default: return false
        }
    }
}

private struct NodeDecoder {
    var reader: CBORReader
    let count: Int

    init(_ input: [UInt8]) {
        self.reader = CBORReader(Data(input), maxDepth: Int.max)
        self.count = input.count
    }

    var offset: Int { count - reader.remaining }

    mutating func pull() throws(CBORDecodingError) -> DecodedHead {
        let start = offset
        let head: CBORReader.Head
        do {
            head = try reader.readHead()
        } catch CBORError.prematureEnd {
            throw .unexpectedEndOfInput
        } catch {
            throw .syntax(offset: start)
        }

        let length: UInt64? = head.isIndefinite ? nil : head.argument
        switch head.majorType {
        case .unsignedInt:
            guard !head.isIndefinite else { throw .syntax(offset: start) }
            return .positive(head.argument)
        case .negativeInt:
            guard !head.isIndefinite else { throw .syntax(offset: start) }
            return .negative(head.argument)
        case .byteString:
            return .bytes(length)
        case .textString:
            return .text(length)
        case .array:
            return .array(length)
        case .map:
            return .map(length)
        case .tagged:
            guard !head.isIndefinite else { throw .syntax(offset: start) }
            return .tag(head.argument)
        case .simpleOrFloat:
            if head.isIndefinite {
                return .breakCode
            }
            switch head.info {
            case 25:
                return .float(halfToDouble(UInt16(truncatingIfNeeded: head.argument)), .half)
            case 26:
                return .float(Double(Float(bitPattern: UInt32(truncatingIfNeeded: head.argument))), .single)
            case 27:
                return .float(Double(bitPattern: head.argument), .double)
            default:
                return .simple(UInt8(truncatingIfNeeded: head.argument))
            }
        }
    }

    /// Reads `length` payload bytes.
    mutating func payload(_ length: UInt64) throws(CBORDecodingError) -> [UInt8] {
        guard length <= UInt64(reader.remaining) else {
            throw .unexpectedEndOfInput
        }
        do {
            return [UInt8](try reader.readBytes(Int(length)))
        } catch {
            throw .unexpectedEndOfInput
        }
    }

    mutating func byteString(_ length: UInt64?) throws(CBORDecodingError) -> [UInt8] {
        if let length {
            return try payload(length)
        }
        // RFC 8949 Section 3.2.3: the chunks of an indefinite-length byte
        // string are definite-length byte strings.
        var result: [UInt8] = []
        while true {
            switch try pull() {
            case .breakCode:
                return result
            case .bytes(let chunk?):
                result.append(contentsOf: try payload(chunk))
            default:
                throw .syntax(offset: offset)
            }
        }
    }

    mutating func textString(_ length: UInt64?) throws(CBORDecodingError) -> String {
        if let length {
            let bytes = try payload(length)
            guard let text = String(validatingUTF8Bytes: bytes) else {
                throw .syntax(offset: offset)
            }
            return text
        }
        // RFC 8949 Section 3.2.3: each chunk of an indefinite-length text
        // string is a definite-length text string, valid UTF-8 on its own.
        var result = ""
        while true {
            switch try pull() {
            case .breakCode:
                return result
            case .text(let chunk?):
                let bytes = try payload(chunk)
                guard let text = String(validatingUTF8Bytes: bytes) else {
                    throw .syntax(offset: offset)
                }
                result += text
            default:
                throw .syntax(offset: offset)
            }
        }
    }

    /// Decodes one data item, keeping the containers being read on a heap
    /// stack rather than recursing into them.
    mutating func decodeItem() throws(CBORDecodingError) -> CBORNode {
        var open: [OpenContainer] = []

        while true {
            // A container of definite length is waiting for an item, so an item
            // past the bound is refused before anything is read for it; one of
            // indefinite length may be waiting for its break instead, which
            // nests nothing, so the head is read first.
            let innermostEndsAtBreak = open.last?.endsAtBreak ?? false
            if !innermostEndsAtBreak && open.count > maxDecodeNestingDepth {
                throw .nestedTooDeeply
            }

            let head = try pull()

            if case .breakCode = head {
                let closed: CBORNode
                switch open.last {
                case .array(let items, nil):
                    closed = .array(CBORArray(items, indefinite: true))
                case .map(let entries, nil, nil):
                    closed = .map(CBORMap(entries, indefinite: true))
                default:
                    throw .unexpectedBreak
                }
                open.removeLast()
                if let node = attach(&open, closed) {
                    return node
                }
                continue
            }

            if innermostEndsAtBreak && open.count > maxDecodeNestingDepth {
                throw .nestedTooDeeply
            }

            let node: CBORNode
            switch head {
            case .positive(let value):
                node = .unsigned(value)
            case .negative(let value):
                node = .negative(value)
            case .float(let value, let width):
                node = .float(value, width: width)
            case .simple(let value):
                switch value {
                case 20: node = .bool(false)
                case 21: node = .bool(true)
                case 22: node = .null
                case 23: node = .undefined
                default: node = .simple(value)
                }
            case .bytes(let length):
                node = .byteString(try byteString(length), indefinite: length == nil)
            case .text(let length):
                node = .textString(try textString(length), indefinite: length == nil)
            case .tag(let tag):
                open.append(.tag(tag))
                continue
            case .array(let length):
                if length == 0 {
                    node = .array(CBORArray([]))
                } else {
                    open.append(.array(items: [], remaining: length))
                    continue
                }
            case .map(let length):
                if length == 0 {
                    node = .map(CBORMap([]))
                } else {
                    open.append(.map(entries: [], pendingKey: nil, remaining: length))
                    continue
                }
            case .breakCode:
                throw .unexpectedBreak
            }

            if let finished = attach(&open, node) {
                return finished
            }
        }
    }

    /// Hands `node` to the innermost open container, closing every container
    /// it completes, and returns it when no container is open to take it.
    private func attach(_ open: inout [OpenContainer], _ node: CBORNode) -> CBORNode? {
        var node = node
        while true {
            guard let last = open.popLast() else {
                return node
            }
            switch last {
            case .tag(let tag):
                node = .tagged(CBORTaggedItem(tag: tag, content: node))
            case .array(var items, let remaining):
                items.append(node)
                if let remaining {
                    if remaining - 1 == 0 {
                        node = .array(CBORArray(items))
                        continue
                    }
                    open.append(.array(items: items, remaining: remaining - 1))
                } else {
                    open.append(.array(items: items, remaining: nil))
                }
                return nil
            case .map(var entries, let pendingKey, let remaining):
                guard let key = pendingKey else {
                    open.append(.map(entries: entries, pendingKey: node, remaining: remaining))
                    return nil
                }
                entries.append((key: key, value: node))
                if let remaining {
                    if remaining - 1 == 0 {
                        node = .map(CBORMap(entries))
                        continue
                    }
                    open.append(.map(entries: entries, pendingKey: nil, remaining: remaining - 1))
                } else {
                    open.append(.map(entries: entries, pendingKey: nil, remaining: nil))
                }
                return nil
            }
        }
    }
}

/// The value of an IEEE 754 binary16 number.
func halfToDouble(_ bits: UInt16) -> Double {
    let sign: Double = bits & 0x8000 != 0 ? -1 : 1
    let exponent = Int((bits >> 10) & 0x1f)
    let fraction = Double(bits & 0x3ff)
    switch exponent {
    case 0:
        return sign * fraction * 0x1p-24
    case 0x1f:
        if fraction == 0 {
            return sign * .infinity
        }
        // Keep the payload: widen the quiet bit and fraction into a double NaN.
        let payload = UInt64(bits & 0x3ff) << 42
        let signBit: UInt64 = bits & 0x8000 != 0 ? 1 << 63 : 0
        return Double(bitPattern: signBit | 0x7ff0_0000_0000_0000 | payload)
    default:
        return sign * (1 + fraction * 0x1p-10) * pow(2, Double(exponent - 15))
    }
}

/// The binary16 encoding of `value`, where it holds `value` exactly.
func doubleToHalf(_ value: Double) -> UInt16? {
    let sign: UInt16 = value.sign == .minus ? 0x8000 : 0
    if value.isNaN {
        let bits = value.bitPattern
        let payload = UInt16(truncatingIfNeeded: (bits >> 42) & 0x3ff)
        let half = sign | 0x7c00 | (payload == 0 ? 0x200 : payload)
        return halfToDouble(half).bitPattern == bits ? half : nil
    }
    if value.isInfinite {
        return sign | 0x7c00
    }
    let magnitude = abs(value)
    if magnitude == 0 {
        return sign
    }
    let candidate: UInt16
    if magnitude >= 0x1p-14 {
        let exponent = Int(magnitude.exponent)
        guard exponent <= 15 else { return nil }
        let fraction = (magnitude.significand - 1) * 1024
        guard fraction == fraction.rounded(.towardZero) else { return nil }
        candidate = UInt16(exponent + 15) << 10 | UInt16(fraction)
    } else {
        let fraction = magnitude * 0x1p24
        guard fraction == fraction.rounded(.towardZero), fraction < 1024 else { return nil }
        candidate = UInt16(fraction)
    }
    return halfToDouble(candidate) == magnitude ? sign | candidate : nil
}

// MARK: - Encoding

extension CBORNode {
    /// The node encoded as CBOR: integers, lengths and tags in their shortest
    /// form, floats in the width the node holds, and indefinite-length items
    /// as the node says.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        // Work items: a node still to encode, or a break to write once an
        // indefinite-length container's items are written.
        enum Work {
            case node(CBORNode)
            case breakCode
        }
        var pending: [Work] = [.node(self)]

        func head(_ major: UInt8, _ argument: UInt64) {
            let m = major << 5
            switch argument {
            case 0..<24:
                out.append(m | UInt8(argument))
            case 24...0xff:
                out.append(m | 24)
                out.append(UInt8(argument))
            case 0x100...0xffff:
                out.append(m | 25)
                out.append(UInt8(argument >> 8))
                out.append(UInt8(argument & 0xff))
            case 0x1_0000...0xffff_ffff:
                out.append(m | 26)
                for shift in stride(from: 24, through: 0, by: -8) {
                    out.append(UInt8((argument >> UInt64(shift)) & 0xff))
                }
            default:
                out.append(m | 27)
                for shift in stride(from: 56, through: 0, by: -8) {
                    out.append(UInt8((argument >> UInt64(shift)) & 0xff))
                }
            }
        }

        while let work = pending.popLast() {
            guard case .node(let node) = work else {
                out.append(0xff)
                continue
            }
            switch node {
            case .unsigned(let value):
                head(0, value)
            case .negative(let value):
                head(1, value)
            case .byteString(let bytes, let indefinite):
                if indefinite {
                    out.append(0x5f)
                    if !bytes.isEmpty {
                        head(2, UInt64(bytes.count))
                        out.append(contentsOf: bytes)
                    }
                    out.append(0xff)
                } else {
                    head(2, UInt64(bytes.count))
                    out.append(contentsOf: bytes)
                }
            case .textString(let text, let indefinite):
                let bytes = Array(text.utf8)
                if indefinite {
                    out.append(0x7f)
                    if !bytes.isEmpty {
                        head(3, UInt64(bytes.count))
                        out.append(contentsOf: bytes)
                    }
                    out.append(0xff)
                } else {
                    head(3, UInt64(bytes.count))
                    out.append(contentsOf: bytes)
                }
            case .array(let array):
                if array.isIndefinite {
                    out.append(0x9f)
                    pending.append(.breakCode)
                } else {
                    head(4, UInt64(array.items.count))
                }
                for item in array.items.reversed() {
                    pending.append(.node(item))
                }
            case .map(let map):
                if map.isIndefinite {
                    out.append(0xbf)
                    pending.append(.breakCode)
                } else {
                    head(5, UInt64(map.entries.count))
                }
                for entry in map.entries.reversed() {
                    pending.append(.node(entry.value))
                    pending.append(.node(entry.key))
                }
            case .tagged(let tagged):
                head(6, tagged.tag)
                pending.append(.node(tagged.content))
            case .float(let value, let width):
                switch width {
                case .half:
                    let bits = doubleToHalf(value) ?? 0x7e00
                    out.append(0xf9)
                    out.append(UInt8(bits >> 8))
                    out.append(UInt8(bits & 0xff))
                case .single:
                    let bits = Float(value).bitPattern
                    out.append(0xfa)
                    for shift in stride(from: 24, through: 0, by: -8) {
                        out.append(UInt8((bits >> UInt32(shift)) & 0xff))
                    }
                case .double:
                    let bits = value.bitPattern
                    out.append(0xfb)
                    for shift in stride(from: 56, through: 0, by: -8) {
                        out.append(UInt8((bits >> UInt64(shift)) & 0xff))
                    }
                }
            case .simple(let value):
                if value < 24 {
                    out.append(0xe0 | value)
                } else {
                    out.append(0xf8)
                    out.append(value)
                }
            case .bool(let value):
                out.append(value ? 0xf5 : 0xf4)
            case .null:
                out.append(0xf6)
            case .undefined:
                out.append(0xf7)
            }
        }
        return out
    }
}

// MARK: - Conversion from the CBOR value model

extension CBORNode {
    /// The node holding the same data item as `cbor`.
    ///
    /// A map of the value model holds each key once, so the node holds its
    /// pairs in the order the model does.
    public init(_ cbor: CBOR) {
        // A container being built from the values it holds, the ones still to
        // convert kept last-first.
        enum Frame {
            case array(pending: [CBOR], built: [CBORNode], indefinite: Bool)
            case map(pending: [CBOR], built: [CBORNode], indefinite: Bool)
            case tag(UInt64)
        }

        var stack: [Frame] = []
        var result: CBORNode?

        // Hands a converted node to the innermost open frame, closing every tag
        // it completes; the node is the result once no frame is open.
        func deliver(_ node: CBORNode) {
            var node = node
            while true {
                guard let top = stack.popLast() else {
                    result = node
                    return
                }
                switch top {
                case .tag(let tag):
                    node = .tagged(tag, node)
                case .array(let pending, var built, let indefinite):
                    built.append(node)
                    stack.append(.array(pending: pending, built: built, indefinite: indefinite))
                    return
                case .map(let pending, var built, let indefinite):
                    built.append(node)
                    stack.append(.map(pending: pending, built: built, indefinite: indefinite))
                    return
                }
            }
        }

        var next: CBOR? = cbor
        while result == nil {
            if let value = next {
                next = nil
                switch value {
                case .unsignedInt(let v): deliver(.unsigned(v))
                case .negativeInt(let v): deliver(.negative(v))
                case .byteString(let data): deliver(.byteString([UInt8](data)))
                case .textString(let text): deliver(.textString(text))
                case .simple(let v):
                    switch v {
                    case 20: deliver(.bool(false))
                    case 21: deliver(.bool(true))
                    case 22: deliver(.null)
                    case 23: deliver(.undefined)
                    default: deliver(.simple(v))
                    }
                case .boolean(let v): deliver(.bool(v))
                case .null: deliver(.null)
                case .undefined: deliver(.undefined)
                case .half(let bits): deliver(.float(halfToDouble(bits), width: .half))
                case .float(let v): deliver(.float(Double(v), width: .single))
                case .double(let v): deliver(.float(v, width: .double))
                case .indefiniteByteString(let chunks):
                    deliver(.byteString(chunks.flatMap { [UInt8]($0) }, indefinite: true))
                case .indefiniteTextString(let chunks):
                    deliver(.textString(chunks.joined(), indefinite: true))
                case .tagged(let tag, let inner):
                    stack.append(.tag(tag))
                    next = inner
                case .array(let items):
                    stack.append(.array(pending: items.reversed(), built: [], indefinite: false))
                case .indefiniteArray(let items):
                    stack.append(.array(pending: items.reversed(), built: [], indefinite: true))
                case .map(let entries):
                    let flat = entries.flatMap { [$0.key, $0.value] }
                    stack.append(.map(pending: flat.reversed(), built: [], indefinite: false))
                case .indefiniteMap(let entries):
                    let flat = entries.flatMap { [$0.key, $0.value] }
                    stack.append(.map(pending: flat.reversed(), built: [], indefinite: true))
                }
                continue
            }

            // The innermost frame is a container: convert its next value, or
            // close it. (A tag frame always has its content in flight.)
            guard let top = stack.popLast() else { break }
            switch top {
            case .array(var pending, let built, let indefinite):
                if let value = pending.popLast() {
                    stack.append(.array(pending: pending, built: built, indefinite: indefinite))
                    next = value
                } else {
                    deliver(.array(built, indefinite: indefinite))
                }
            case .map(var pending, let built, let indefinite):
                if let value = pending.popLast() {
                    stack.append(.map(pending: pending, built: built, indefinite: indefinite))
                    next = value
                } else {
                    var entries: [(key: CBORNode, value: CBORNode)] = []
                    var index = 0
                    while index + 1 < built.count {
                        entries.append((key: built[index], value: built[index + 1]))
                        index += 2
                    }
                    deliver(.map(entries, indefinite: indefinite))
                }
            case .tag:
                stack.append(top)
                result = .null
            }
        }

        self = result ?? .null
    }
}
