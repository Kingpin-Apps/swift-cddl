import BigInt
import Foundation

// The JSON data model a document is validated in (RFC 8259).
//
// An object keeps its members as the document wrote them: in order, a name
// given twice kept twice. RFC 8259 Section 4 leaves what a repeated name means
// to the implementation, and the validator reads an object the way most
// implementations do, as the set of its names each holding the last value
// written for it; it examines the members in the order of the UTF-8 bytes of
// their names, so that what it reports does not depend on how the document
// happened to order them. ``JSONObject/entries`` is that reading.
//
// A number keeps the text it was written as, and is read the way RFC 8259
// Section 6 lets an implementation read it: a number written without a
// fraction or an exponent whose value fits 64 bits is an integer, and every
// other number is an IEEE 754 binary64 value. Section 9 lets a parser bound
// the range of numbers it accepts, and a magnitude too large for binary64 is
// refused rather than read as an infinity.
//
// Nesting in a document is bounded by the input rather than by the stack:
// reading, comparing, rendering and freeing a node all keep the containers
// they have open on the heap.

/// A JSON value (RFC 8259 Section 3).
public enum JSONNode: Sendable {
    /// `null`.
    case null
    /// `false` or `true`.
    case bool(Bool)
    /// A number.
    case number(JSONNumber)
    /// A string.
    case string(String)
    /// An array.
    case array(JSONArray)
    /// An object.
    case object(JSONObject)

    /// An array holding `items`.
    public static func array(_ items: [JSONNode]) -> JSONNode {
        .array(JSONArray(items))
    }

    /// An object holding `members`, in order.
    public static func object(_ members: [(key: String, value: JSONNode)]) -> JSONNode {
        .object(JSONObject(members))
    }

    /// The integer `value`.
    public static func integer(_ value: Int64) -> JSONNode {
        .number(JSONNumber(value))
    }

    /// The integer `value`.
    public static func unsigned(_ value: UInt64) -> JSONNode {
        .number(JSONNumber(value))
    }

    /// The floating point number `value`, which has to be finite.
    public static func float(_ value: Double) -> JSONNode {
        .number(JSONNumber(value))
    }

    /// Reads the JSON document `text` (RFC 8259 Section 2): one value, with
    /// nothing but whitespace around it.
    public static func parse(_ text: String) throws(JSONParsingError) -> JSONNode {
        var reader = JSONReader(Array(text.utf8))
        return try reader.document()
    }

    /// Reads the JSON document `bytes`, which has to be UTF-8 (RFC 8259
    /// Section 8.1).
    public static func parse(bytes: [UInt8]) throws(JSONParsingError) -> JSONNode {
        if String(validatingUTF8Bytes: bytes) == nil {
            var index = 0
            while index < bytes.count, bytes[index] < 0x80 {
                index += 1
            }
            throw JSONParsingError.at("invalid unicode code point", in: bytes, index + 1)
        }
        var reader = JSONReader(bytes)
        return try reader.document()
    }
}

// MARK: - Numbers

/// A JSON number (RFC 8259 Section 6): the text it was written as, and the
/// value it is read as.
public struct JSONNumber: Sendable, Hashable, CustomStringConvertible {
    /// The value a number is read as.
    public enum Value: Sendable, Hashable {
        /// A non-negative integer written without a fraction or an exponent.
        case unsigned(UInt64)
        /// A negative integer written without a fraction or an exponent.
        case negative(Int64)
        /// Any other number: one written with a fraction or an exponent, an
        /// integer beyond the 64-bit range, and negative zero.
        case float(Double)
    }

    /// The text the number was written as.
    public let text: String
    /// The value the number is read as.
    public let value: Value

    /// A number read from `text` as `value`.
    init(text: String, value: Value) {
        self.text = text
        self.value = value
    }

    /// The integer `value`.
    public init(_ value: Int64) {
        self.text = String(value)
        self.value = value < 0 ? .negative(value) : .unsigned(UInt64(value))
    }

    /// The integer `value`.
    public init(_ value: UInt64) {
        self.text = String(value)
        self.value = .unsigned(value)
    }

    /// The floating point number `value`, which has to be finite.
    public init(_ value: Double) {
        precondition(value.isFinite, "a JSON number is finite")
        self.text = jsonNumberText(value)
        self.value = .float(value)
    }

    /// Whether the text is an integer: written without a fraction or an
    /// exponent.
    public var isWrittenAsInteger: Bool {
        !text.utf8.contains { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
    }

    /// The exact integer the text denotes, when it is written as an integer,
    /// whatever its magnitude.
    public var exactInteger: BigInt? {
        isWrittenAsInteger ? BigInt(text) : nil
    }

    /// Whether the number is read as a floating point value.
    public var isFloat: Bool {
        if case .float = value { return true }
        return false
    }

    /// The value as a non-negative 64-bit integer, if it is read as one.
    public var uint64: UInt64? {
        if case .unsigned(let v) = value { return v }
        return nil
    }

    /// The value as a signed 64-bit integer, if it is read as an integer in
    /// that range.
    public var int64: Int64? {
        switch value {
        case .unsigned(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .negative(let v): return v
        case .float: return nil
        }
    }

    /// The value as a floating point number.
    public var double: Double {
        switch value {
        case .unsigned(let v): return Double(v)
        case .negative(let v): return Double(v)
        case .float(let v): return v
        }
    }

    /// The integer the number is read as, if it is read as one.
    var integer: BigInt? {
        switch value {
        case .unsigned(let v): return BigInt(v)
        case .negative(let v): return BigInt(v)
        case .float: return nil
        }
    }

    /// The value written back as a JSON number: an integer in decimal, a float
    /// as its shortest round-trip digits.
    public var description: String {
        switch value {
        case .unsigned(let v): return String(v)
        case .negative(let v): return String(v)
        case .float(let v): return jsonNumberText(v)
        }
    }

    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

// MARK: - Containers

/// The storage shared by the JSON containers. Freeing one frees what it holds
/// one container at a time, so a document nested however deeply is freed on
/// whatever stack drops it.
public class JSONContainer: @unchecked Sendable {
    /// Moves every container this one holds directly into `pending`, leaving it
    /// holding none.
    func takeChildContainers(into pending: inout [JSONContainer]) {}
}

extension JSONNode {
    /// The container this node is, if it is one.
    var container: JSONContainer? {
        switch self {
        case .array(let array): return array
        case .object(let object): return object
        default: return nil
        }
    }
}

private func dismantle(_ pending: inout [JSONContainer]) {
    while !pending.isEmpty {
        var container = pending.removeLast()
        if isKnownUniquelyReferenced(&container) {
            container.takeChildContainers(into: &pending)
        }
    }
}

/// The items of a JSON array.
public final class JSONArray: JSONContainer, @unchecked Sendable {
    /// The items, in order.
    public private(set) var items: [JSONNode]

    /// An array holding `items`.
    public init(_ items: [JSONNode]) {
        self.items = items
    }

    override func takeChildContainers(into pending: inout [JSONContainer]) {
        for item in items {
            if let container = item.container {
                pending.append(container)
            }
        }
        items = []
    }

    deinit {
        if !items.isEmpty {
            var pending: [JSONContainer] = []
            takeChildContainers(into: &pending)
            dismantle(&pending)
        }
    }
}

/// The members of a JSON object.
public final class JSONObject: JSONContainer, @unchecked Sendable {
    /// The members, in the order the document wrote them; a name written twice
    /// is two members.
    public private(set) var members: [(key: String, value: JSONNode)]
    /// The members as the validator reads them: one per distinct name (names
    /// compared by their Unicode scalars), holding the last value written for
    /// it, in the order of the UTF-8 bytes of the names.
    public private(set) var entries: [(key: String, value: JSONNode)]

    /// An object holding `members`, in order.
    public init(_ members: [(key: String, value: JSONNode)]) {
        self.members = members
        let keys = members.map { Array($0.key.utf8) }
        let order = members.indices.sorted { a, b in
            if keys[a] != keys[b] {
                return keys[a].lexicographicallyPrecedes(keys[b])
            }
            return a < b
        }
        var entries: [(key: String, value: JSONNode)] = []
        entries.reserveCapacity(members.count)
        var index = 0
        while index < order.count {
            var last = order[index]
            while index + 1 < order.count, keys[order[index + 1]] == keys[last] {
                index += 1
                last = order[index]
            }
            entries.append(members[last])
            index += 1
        }
        self.entries = entries
    }

    /// The value held under `key`, the name compared by its UTF-8 bytes.
    func entry(_ key: String) -> (key: String, value: JSONNode)? {
        var low = 0
        var high = entries.count
        let target = Array(key.utf8)
        while low < high {
            let mid = (low + high) / 2
            let probe = Array(entries[mid].key.utf8)
            if probe == target {
                return entries[mid]
            }
            if probe.lexicographicallyPrecedes(target) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return nil
    }

    override func takeChildContainers(into pending: inout [JSONContainer]) {
        for (_, value) in members {
            if let container = value.container {
                pending.append(container)
            }
        }
        for (_, value) in entries {
            if let container = value.container {
                pending.append(container)
            }
        }
        members = []
        entries = []
    }

    deinit {
        if !members.isEmpty {
            var pending: [JSONContainer] = []
            takeChildContainers(into: &pending)
            dismantle(&pending)
        }
    }
}

// MARK: - Kinds

extension JSONNode {
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Whether the value nests no further values.
    var isScalar: Bool {
        !isArray && !isObject
    }
}

// MARK: - Equality

extension JSONNode: Equatable {
    /// Whether two values are the same JSON value: numbers compared by the
    /// value they are read as, strings by their Unicode scalars, and objects by
    /// their members in document order.
    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        var pending: [(JSONNode, JSONNode)] = [(lhs, rhs)]
        while let (a, b) = pending.popLast() {
            switch (a, b) {
            case (.null, .null):
                continue
            case (.bool(let x), .bool(let y)):
                if x != y { return false }
            case (.number(let x), .number(let y)):
                if x != y { return false }
            case (.string(let x), .string(let y)):
                if !x.unicodeScalars.elementsEqual(y.unicodeScalars) { return false }
            case (.array(let x), .array(let y)):
                if x === y { continue }
                if x.items.count != y.items.count { return false }
                for (p, q) in zip(x.items, y.items) {
                    pending.append((p, q))
                }
            case (.object(let x), .object(let y)):
                if x === y { continue }
                if x.members.count != y.members.count { return false }
                for (p, q) in zip(x.members, y.members) {
                    if !p.key.unicodeScalars.elementsEqual(q.key.unicodeScalars) { return false }
                    pending.append((p.value, q.value))
                }
            default:
                return false
            }
        }
        return true
    }
}

// MARK: - Rendering

extension JSONNode: CustomStringConvertible {
    /// The value written as compact JSON, its object members in document
    /// order.
    public var description: String {
        var out = ""
        writeJSON(self, into: &out, entries: false, limit: nil)
        return out
    }

    /// The value written as compact JSON the way the validator reads it --
    /// every object as its ``JSONObject/entries`` -- cut short at
    /// ``maxRenderedDataLength`` bytes and marked where the rest was elided.
    var elidedRendering: String {
        var out = ""
        writeJSON(self, into: &out, entries: true, limit: maxRenderedDataLength)
        return elided(out)
    }

    /// The value written as compact JSON the way the validator reads it,
    /// without a bound on its length.
    var fullRendering: String {
        var out = ""
        writeJSON(self, into: &out, entries: true, limit: nil)
        return out
    }
}

/// Writes `node` as compact JSON into `out`: strings escaped as RFC 8259
/// Section 7 requires and with lowercase hexadecimal, numbers as
/// ``JSONNumber/description`` writes them. With a `limit`, writing stops soon
/// after `out` holds more than that many bytes.
private func writeJSON(_ node: JSONNode, into out: inout String, entries: Bool, limit: Int?) {
    enum Step {
        case value(JSONNode)
        case text(String)
        case key(String)
    }
    var pending: [Step] = [.value(node)]
    while let step = pending.popLast() {
        if let limit, out.utf8.count > limit {
            return
        }
        switch step {
        case .text(let text):
            out += text
        case .key(let key):
            writeJSONString(key, into: &out)
            out += ":"
        case .value(let value):
            switch value {
            case .null: out += "null"
            case .bool(let b): out += b ? "true" : "false"
            case .number(let n): out += n.description
            case .string(let s): writeJSONString(s, into: &out)
            case .array(let array):
                out += "["
                pending.append(.text("]"))
                for (idx, item) in array.items.enumerated().reversed() {
                    pending.append(.value(item))
                    if idx > 0 {
                        pending.append(.text(","))
                    }
                }
            case .object(let object):
                out += "{"
                pending.append(.text("}"))
                let members = entries ? object.entries : object.members
                for (idx, member) in members.enumerated().reversed() {
                    pending.append(.value(member.value))
                    pending.append(.key(member.key))
                    if idx > 0 {
                        pending.append(.text(","))
                    }
                }
            }
        }
    }
}

private let lowercaseHexDigits = Array("0123456789abcdef".unicodeScalars)

/// Writes `text` as a JSON string: `"` and `\` escaped, the control characters
/// written as their short escapes where JSON has one and as `\u00xx` otherwise,
/// and every other scalar as itself.
private func writeJSONString(_ text: String, into out: inout String) {
    out += "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{8}": out += "\\b"
        case "\u{c}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += "\\u00"
                out.unicodeScalars.append(lowercaseHexDigits[Int(scalar.value >> 4)])
                out.unicodeScalars.append(lowercaseHexDigits[Int(scalar.value & 0xf)])
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

// MARK: - Reading

/// Why a JSON document did not read as one well-formed value.
public struct JSONParsingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// What is wrong.
    public var message: String
    /// The line the reader had reached, from 1.
    public var line: Int
    /// The column the reader had reached on that line, in bytes.
    public var column: Int

    /// An error.
    public init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// The error `message` at byte offset `index` of `bytes`, counted as the
    /// bytes read up to and including the one at fault.
    static func at(_ message: String, in bytes: [UInt8], _ index: Int) -> JSONParsingError {
        let end = min(index, bytes.count)
        var startOfLine = 0
        var line = 1
        for i in 0..<end where bytes[i] == UInt8(ascii: "\n") {
            line += 1
            startOfLine = i + 1
        }
        return JSONParsingError(message: message, line: line, column: end - startOfLine)
    }

    public var description: String {
        "\(message) at line \(line) column \(column)"
    }
}

/// The powers of ten a decimal number is scaled by.
private let powersOfTen: [Double] = (0...308).map { Double("1e\($0)")! }

/// An iterative reader over the bytes of one JSON document.
private struct JSONReader {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// A container whose members are still being read.
    private enum Open {
        case array([JSONNode])
        case object([(key: String, value: JSONNode)], key: String)
    }

    // MARK: Positions

    /// An error at the byte most recently read.
    func error(_ message: String) -> JSONParsingError {
        JSONParsingError.at(message, in: bytes, index)
    }

    /// An error at the byte about to be read.
    func peekError(_ message: String) -> JSONParsingError {
        JSONParsingError.at(message, in: bytes, index + 1)
    }

    func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    /// The byte about to be read, or zero at the end of the document.
    func peekOrNull() -> UInt8 {
        index < bytes.count ? bytes[index] : 0
    }

    mutating func next() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    /// Skips whitespace (RFC 8259 Section 2) and returns the byte after it.
    mutating func skipWhitespace() -> UInt8? {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d: index += 1
            default: return bytes[index]
            }
        }
        return nil
    }

    // MARK: Structure

    /// Reads the whole document: one value, and nothing but whitespace after
    /// it.
    mutating func document() throws(JSONParsingError) -> JSONNode {
        var open: [Open] = []

        while true {
            // A value is expected here.
            guard let first = skipWhitespace() else {
                throw peekError("EOF while parsing a value")
            }
            var value: JSONNode
            switch first {
            case UInt8(ascii: "["):
                index += 1
                // An empty array closes at once.
                guard let c = skipWhitespace() else {
                    throw peekError("EOF while parsing a list")
                }
                if c == UInt8(ascii: "]") {
                    index += 1
                    value = .array([])
                } else {
                    open.append(.array([]))
                    continue
                }
            case UInt8(ascii: "{"):
                index += 1
                guard let c = skipWhitespace() else {
                    throw peekError("EOF while parsing an object")
                }
                if c == UInt8(ascii: "}") {
                    index += 1
                    value = .object([])
                } else {
                    guard c == UInt8(ascii: "\"") else {
                        throw peekError("key must be a string")
                    }
                    let key = try memberKey()
                    open.append(.object([], key: key))
                    continue
                }
            default:
                value = try scalar()
            }

            // Hands the value to the innermost open container, closing every
            // container it completes.
            while true {
                guard let container = open.popLast() else {
                    if skipWhitespace() != nil {
                        throw peekError("trailing characters")
                    }
                    return value
                }
                switch container {
                case .array(var items):
                    items.append(value)
                    guard let c = skipWhitespace() else {
                        throw peekError("EOF while parsing a list")
                    }
                    if c == UInt8(ascii: ",") {
                        index += 1
                        switch skipWhitespace() {
                        case UInt8(ascii: "]")?: throw peekError("trailing comma")
                        case nil: throw peekError("EOF while parsing a value")
                        default: break
                        }
                        open.append(.array(items))
                    } else if c == UInt8(ascii: "]") {
                        index += 1
                        value = .array(items)
                        continue
                    } else {
                        throw peekError("expected `,` or `]`")
                    }
                case .object(var members, let key):
                    members.append((key: key, value: value))
                    guard let c = skipWhitespace() else {
                        throw peekError("EOF while parsing an object")
                    }
                    if c == UInt8(ascii: ",") {
                        index += 1
                        switch skipWhitespace() {
                        case UInt8(ascii: "\"")?: break
                        case UInt8(ascii: "}")?: throw peekError("trailing comma")
                        case nil: throw peekError("EOF while parsing a value")
                        default: throw peekError("key must be a string")
                        }
                        let next = try memberKey()
                        open.append(.object(members, key: next))
                    } else if c == UInt8(ascii: "}") {
                        index += 1
                        value = .object(members)
                        continue
                    } else {
                        throw peekError("expected `,` or `}`")
                    }
                }
                break
            }
        }
    }

    /// Reads a member name, at its opening quote, and the `:` after it,
    /// leaving the reader at the value.
    mutating func memberKey() throws(JSONParsingError) -> String {
        index += 1
        let key = try string()
        switch skipWhitespace() {
        case UInt8(ascii: ":")?: index += 1
        case nil: throw peekError("EOF while parsing an object")
        default: throw peekError("expected `:`")
        }
        return key
    }

    /// Reads a scalar value: a literal name, a number or a string.
    mutating func scalar() throws(JSONParsingError) -> JSONNode {
        let first = bytes[index]
        switch first {
        case UInt8(ascii: "n"):
            index += 1
            try literal("ull")
            return .null
        case UInt8(ascii: "t"):
            index += 1
            try literal("rue")
            return .bool(true)
        case UInt8(ascii: "f"):
            index += 1
            try literal("alse")
            return .bool(false)
        case UInt8(ascii: "\""):
            index += 1
            return .string(try string())
        case UInt8(ascii: "-"):
            let start = index
            index += 1
            let value = try integer(positive: false)
            return .number(JSONNumber(text: text(from: start), value: value))
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let start = index
            let value = try integer(positive: true)
            return .number(JSONNumber(text: text(from: start), value: value))
        default:
            throw peekError("expected value")
        }
    }

    func text(from start: Int) -> String {
        String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Reads the rest of a literal name.
    mutating func literal(_ rest: String) throws(JSONParsingError) {
        for expected in rest.utf8 {
            guard let c = next() else {
                throw error("EOF while parsing a value")
            }
            if c != expected {
                throw error("expected ident")
            }
        }
    }

    // MARK: Numbers

    /// Reads a number after its sign (RFC 8259 Section 6).
    ///
    /// The digits are accumulated in 64 bits while they fit; a number written
    /// with a fraction or an exponent, or with more digits than fit, is scaled
    /// by powers of ten in binary64 arithmetic.
    mutating func integer(positive: Bool) throws(JSONParsingError) -> JSONNumber.Value {
        guard let c = next() else {
            throw error("EOF while parsing a value")
        }
        switch c {
        case UInt8(ascii: "0"):
            // There can be only one leading zero.
            if case UInt8(ascii: "0")...UInt8(ascii: "9") = peekOrNull() {
                throw peekError("invalid number")
            }
            return try number(positive: positive, significand: 0)
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            var significand = UInt64(c - UInt8(ascii: "0"))
            while true {
                let d = peekOrNull()
                guard d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") else {
                    return try number(positive: positive, significand: significand)
                }
                let digit = UInt64(d - UInt8(ascii: "0"))
                if overflows(significand, digit) {
                    return .float(try longInteger(positive: positive, significand: significand))
                }
                index += 1
                significand = significand * 10 + digit
            }
        default:
            throw error("invalid number")
        }
    }

    /// Whether `significand * 10 + digit` would exceed 64 bits.
    func overflows(_ significand: UInt64, _ digit: UInt64) -> Bool {
        significand >= UInt64.max / 10 && (significand > UInt64.max / 10 || digit > UInt64.max % 10)
    }

    mutating func number(positive: Bool, significand: UInt64) throws(JSONParsingError) -> JSONNumber.Value {
        switch peekOrNull() {
        case UInt8(ascii: "."):
            return .float(try decimal(positive: positive, significand: significand, exponent: 0))
        case UInt8(ascii: "e"), UInt8(ascii: "E"):
            return .float(try exponent(positive: positive, significand: significand, startingExponent: 0))
        default:
            if positive {
                return .unsigned(significand)
            }
            // Negative zero, and a magnitude past the signed range, are read as
            // floats.
            let negated = Int64(bitPattern: significand) &* -1
            if negated >= 0 {
                return .float(-Double(significand))
            }
            return .negative(negated)
        }
    }

    mutating func decimal(positive: Bool, significand start: UInt64, exponent before: Int32) throws(JSONParsingError) -> Double {
        index += 1
        var significand = start
        var after: Int32 = 0
        while case let d = peekOrNull(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
            let digit = UInt64(d - UInt8(ascii: "0"))
            if overflows(significand, digit) {
                // Every further digit is past what the significand holds.
                while case let d = peekOrNull(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
                    index += 1
                }
                let exponent = before + after
                switch peekOrNull() {
                case UInt8(ascii: "e"), UInt8(ascii: "E"):
                    return try self.exponent(positive: positive, significand: significand, startingExponent: exponent)
                default:
                    return try fromParts(positive: positive, significand: significand, exponent: exponent)
                }
            }
            index += 1
            significand = significand * 10 + digit
            after -= 1
        }

        // At least one digit follows the decimal point.
        if after == 0 {
            if peek() != nil {
                throw peekError("invalid number")
            }
            throw peekError("EOF while parsing a value")
        }

        let exponent = before + after
        switch peekOrNull() {
        case UInt8(ascii: "e"), UInt8(ascii: "E"):
            return try self.exponent(positive: positive, significand: significand, startingExponent: exponent)
        default:
            return try fromParts(positive: positive, significand: significand, exponent: exponent)
        }
    }

    mutating func exponent(positive: Bool, significand: UInt64, startingExponent: Int32) throws(JSONParsingError) -> Double {
        index += 1
        var positiveExponent = true
        switch peekOrNull() {
        case UInt8(ascii: "+"):
            index += 1
        case UInt8(ascii: "-"):
            index += 1
            positiveExponent = false
        default:
            break
        }

        guard let first = next() else {
            throw error("EOF while parsing a value")
        }
        guard first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9") else {
            throw error("invalid number")
        }
        var exp = Int32(first - UInt8(ascii: "0"))
        while case let d = peekOrNull(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
            index += 1
            let digit = Int32(d - UInt8(ascii: "0"))
            if exp >= Int32.max / 10 && (exp > Int32.max / 10 || digit > Int32.max % 10) {
                // An exponent past 32 bits: zero, or out of range.
                if significand != 0 && positiveExponent {
                    throw error("number out of range")
                }
                while case let d = peekOrNull(), d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
                    index += 1
                }
                return positive ? 0.0 : -0.0
            }
            exp = exp * 10 + digit
        }

        let finalExponent: Int32
        if positiveExponent {
            let (sum, overflow) = startingExponent.addingReportingOverflow(exp)
            finalExponent = overflow ? Int32.max : sum
        } else {
            let (difference, overflow) = startingExponent.subtractingReportingOverflow(exp)
            finalExponent = overflow ? Int32.min : difference
        }
        return try fromParts(positive: positive, significand: significand, exponent: finalExponent)
    }

    /// Reads the digits of an integer past what 64 bits hold: they scale the
    /// significand read so far by a power of ten each.
    mutating func longInteger(positive: Bool, significand: UInt64) throws(JSONParsingError) -> Double {
        var exponent: Int32 = 0
        while true {
            switch peekOrNull() {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                index += 1
                exponent += 1
            case UInt8(ascii: "."):
                return try decimal(positive: positive, significand: significand, exponent: exponent)
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                return try self.exponent(positive: positive, significand: significand, startingExponent: exponent)
            default:
                return try fromParts(positive: positive, significand: significand, exponent: exponent)
            }
        }
    }

    /// `significand × 10^exponent` in binary64 arithmetic; a magnitude past
    /// what binary64 holds is out of range.
    func fromParts(positive: Bool, significand: UInt64, exponent start: Int32) throws(JSONParsingError) -> Double {
        var f = Double(significand)
        var exponent = start
        while true {
            let magnitude = exponent == Int32.min ? Int(Int32.max) + 1 : Int(abs(exponent))
            if magnitude < powersOfTen.count {
                let power = powersOfTen[magnitude]
                if exponent >= 0 {
                    f *= power
                    if f.isInfinite {
                        throw error("number out of range")
                    }
                } else {
                    f /= power
                }
                break
            }
            if f == 0 {
                break
            }
            if exponent >= 0 {
                throw error("number out of range")
            }
            f /= 1e308
            exponent += 308
        }
        return positive ? f : -f
    }

    // MARK: Strings

    /// Reads a string after its opening quote (RFC 8259 Section 7).
    mutating func string() throws(JSONParsingError) -> String {
        var scalars = String.UnicodeScalarView()
        var runStart = index
        func flush(_ reader: JSONReader, _ end: Int, _ scalars: inout String.UnicodeScalarView) {
            if end > runStart {
                scalars.append(contentsOf: String(decoding: reader.bytes[runStart..<end], as: UTF8.self).unicodeScalars)
            }
        }
        while true {
            guard index < bytes.count else {
                throw error("EOF while parsing a string")
            }
            let c = bytes[index]
            switch c {
            case UInt8(ascii: "\""):
                flush(self, index, &scalars)
                index += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush(self, index, &scalars)
                index += 1
                try escape(into: &scalars)
                runStart = index
            case 0..<0x20:
                index += 1
                throw error("control character (\\u0000-\\u001F) found while parsing a string")
            default:
                index += 1
            }
        }
    }

    /// Reads an escape sequence after its backslash.
    mutating func escape(into scalars: inout String.UnicodeScalarView) throws(JSONParsingError) {
        guard let c = next() else {
            throw error("EOF while parsing a string")
        }
        switch c {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{8}")
        case UInt8(ascii: "f"): scalars.append("\u{c}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"): try unicodeEscape(into: &scalars)
        default: throw error("invalid escape")
        }
    }

    /// Reads a `\u` escape: a scalar of the Basic Multilingual Plane, or a
    /// UTF-16 surrogate pair written as two escapes.
    mutating func unicodeEscape(into scalars: inout String.UnicodeScalarView) throws(JSONParsingError) {
        let unit = try hexEscape()
        if (0xdc00...0xdfff).contains(unit) {
            throw error("lone leading surrogate in hex escape")
        }
        guard (0xd800...0xdbff).contains(unit) else {
            scalars.append(Unicode.Scalar(unit)!)
            return
        }
        guard peek() != nil else {
            throw error("EOF while parsing a string")
        }
        guard peekOrNull() == UInt8(ascii: "\\") else {
            index += 1
            throw error("unexpected end of hex escape")
        }
        index += 1
        guard peek() != nil else {
            throw error("EOF while parsing a string")
        }
        guard peekOrNull() == UInt8(ascii: "u") else {
            index += 1
            throw error("unexpected end of hex escape")
        }
        index += 1
        let low = try hexEscape()
        guard (0xdc00...0xdfff).contains(low) else {
            throw error("lone leading surrogate in hex escape")
        }
        let value = 0x10000 + ((UInt32(unit) - 0xd800) << 10) + (UInt32(low) - 0xdc00)
        scalars.append(Unicode.Scalar(value)!)
    }

    /// Reads the four hexadecimal digits of a `\u` escape.
    mutating func hexEscape() throws(JSONParsingError) -> UInt16 {
        guard index + 4 <= bytes.count else {
            index = bytes.count
            throw error("EOF while parsing a string")
        }
        var value: UInt16 = 0
        var valid = true
        for offset in 0..<4 {
            let c = bytes[index + offset]
            let digit: UInt16
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(c - UInt8(ascii: "A") + 10)
            default:
                digit = 0
                valid = false
            }
            value = value << 4 | digit
        }
        index += 4
        guard valid else {
            throw error("invalid escape")
        }
        return value
    }
}
