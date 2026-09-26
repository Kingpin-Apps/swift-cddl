import BigInt
import Foundation

// Tokens and literal values of CDDL.

/// Tag constraint for CBOR tags (RFC 9682 Section 3.2).
public enum TagConstraint: Hashable, Sendable {
    /// Literal tag number.
    case literal(UInt64)
    /// Type expression for non-literal tag numbers, held as the source text
    /// between the angle brackets.
    case type(String)

    /// Extracts the literal value if this is a literal constraint.
    func asLiteral() -> UInt64? {
        switch self {
        case .literal(let value): return value
        case .type: return nil
        }
    }

    /// Checks if this is a literal constraint with the given value.
    func isLiteral(_ value: UInt64) -> Bool {
        if case .literal(let v) = self { return v == value }
        return false
    }
}

extension TagConstraint: CustomStringConvertible {
    public var description: String {
        switch self {
        case .literal(let n): return String(n)
        case .type(let t): return "<\(t)>"
        }
    }
}

/// Token which represents a valid CDDL character or sequence.
///
/// The parser is a PEG, so tokens are no longer produced by a lexer; the type
/// is kept because validators use its standard-prelude cases to classify
/// identifiers (see ``lookupIdent(_:)``).
enum Token: Hashable, Sendable {
    /// Illegal sequence of characters.
    case illegal(String)
    /// End of file.
    case eof

    /// Identifier with an optional socket/plug prefix.
    case ident(String, SocketPlug?)
    /// Value.
    case value(Value)
    /// CBOR tag `#` with optional major type and constraint.
    case tag(UInt8?, TagConstraint?)

    /// Assignment operator `=`.
    case assign
    /// Optional occurrence indicator `?`.
    case optional
    /// Zero or more occurrence indicator `*`.
    case asterisk
    /// One or more occurrence indicator `+`.
    case oneOrMore
    /// Unwrap operator `~`.
    case unwrap

    /// Comma `,`.
    case comma
    /// Colon `:`.
    case colon

    /// Comment text.
    case comment(String)

    /// Type choice indicator `/`.
    case tchoice
    /// Group choice indicator `//`.
    case gchoice
    /// Type choice alternative `/=`.
    case tchoiceAlt
    /// Group choice alternative `//=`.
    case gchoiceAlt
    /// Arrow map `=>`.
    case arrowMap
    /// Cut `^`.
    case cut

    /// Range operator. Inclusive `..` if true, otherwise exclusive `...`.
    case rangeOp(Bool)

    /// Range: lower bound, upper bound, inclusive.
    case range(RangeValue, RangeValue, Bool)

    /// Left opening parend.
    case lparen
    /// Right closing parend.
    case rparen
    /// Left opening brace.
    case lbrace
    /// Right closing brace.
    case rbrace
    /// Left opening bracket.
    case lbracket
    /// Right closing bracket.
    case rbracket
    /// Left opening angle bracket.
    case langleBracket
    /// Right closing angle bracket.
    case rangleBracket

    /// Control operator token.
    case controlOperator(ControlOperator)

    /// Group to choice enumeration `&`.
    case gtoChoice

    // Standard prelude
    /// false
    case `false`
    /// true
    case `true`
    /// bool
    case bool
    /// nil
    case `nil`
    /// null
    case null
    /// uint
    case uint
    /// nint
    case nint
    /// int
    case int
    /// float16
    case float16
    /// float32
    case float32
    /// float64
    case float64
    /// float16-32
    case float1632
    /// float32-64
    case float3264
    /// float
    case float
    /// bstr
    case bstr
    /// tstr
    case tstr
    /// any
    case any
    /// bytes
    case bytes
    /// text
    case text
    /// tdate
    case tdate
    /// time
    case time
    /// number
    case number
    /// biguint
    case biguint
    /// bignint
    case bignint
    /// bigint
    case bigint
    /// integer
    case integer
    /// unsigned
    case unsigned
    /// decfrac
    case decfrac
    /// bigfloat
    case bigfloat
    /// eb64url
    case eb64url
    /// eb64legacy
    case eb64legacy
    /// eb16
    case eb16
    /// encoded-cbor
    case encodedCBOR
    /// uri
    case uri
    /// b64url
    case b64url
    /// b64legacy
    case b64legacy
    /// regexp
    case regexp
    /// mime-message
    case mimeMessage
    /// cbor-any
    case cborAny
    /// undefined
    case undefined
    /// Newline (used only for comment formatting).
    case newline

    /// Returns the string literal of the token if it is in the standard
    /// prelude.
    func inStandardPrelude() -> String? {
        switch self {
        case .any: return "any"
        case .uint: return "uint"
        case .nint: return "nint"
        case .int: return "int"
        case .bstr: return "bstr"
        case .bytes: return "bytes"
        case .tstr: return "tstr"
        case .text: return "text"
        case .tdate: return "tdate"
        case .time: return "time"
        case .number: return "number"
        case .biguint: return "biguint"
        case .bignint: return "bignint"
        case .bigint: return "bigint"
        case .integer: return "integer"
        case .unsigned: return "unsigned"
        case .decfrac: return "decfrac"
        case .bigfloat: return "bigfloat"
        case .eb64url: return "eb64url"
        case .eb64legacy: return "eb64legacy"
        case .eb16: return "eb16"
        case .encodedCBOR: return "encoded-cbor"
        case .uri: return "uri"
        case .b64url: return "b64url"
        case .b64legacy: return "b64legacy"
        case .regexp: return "regexp"
        case .mimeMessage: return "mime-message"
        case .cborAny: return "cbor-any"
        case .float16: return "float16"
        case .float32: return "float32"
        case .float64: return "float64"
        case .float1632: return "float16-32"
        case .float3264: return "float32-64"
        case .float: return "float"
        case .false: return "false"
        case .true: return "true"
        case .bool: return "bool"
        case .nil: return "nil"
        case .null: return "null"
        case .undefined: return "undefined"
        default: return nil
        }
    }
}

/// Control operator tokens.
public enum ControlOperator: Hashable, Sendable, CaseIterable {
    /// `.size`
    case size
    /// `.bits`
    case bits
    /// `.regexp`
    case regexp
    /// `.cbor`
    case cbor
    /// `.cborseq`
    case cborseq
    /// `.within`
    case within
    /// `.and`
    case and
    /// `.lt`
    case lt
    /// `.le`
    case le
    /// `.gt`
    case gt
    /// `.ge`
    case ge
    /// `.eq`
    case eq
    /// `.ne`
    case ne
    /// `.default`
    case `default`
    /// `.pcre` (Perl-Compatible Regular Expressions).
    case pcre
    /// `.iregexp` (RFC 9485 I-Regexp).
    case iregexp
    /// `.bitfield` (draft-bormann-cbor-cddl-freezer).
    case bitfield
    /// `.cat` (RFC 9165).
    case cat
    /// `.det` (RFC 9165).
    case det
    /// `.plus` (RFC 9165).
    case plus
    /// `.abnf` (RFC 9165).
    case abnf
    /// `.abnfb` (RFC 9165).
    case abnfb
    /// `.feature` (RFC 9165).
    case feature
    /// `.b64u` (RFC 9741).
    case b64u
    /// `.b64c` (RFC 9741).
    case b64c
    /// `.b64u-sloppy` (RFC 9741).
    case b64uSloppy
    /// `.b64c-sloppy` (RFC 9741).
    case b64cSloppy
    /// `.hex` (RFC 9741).
    case hex
    /// `.hexlc` (RFC 9741).
    case hexlc
    /// `.hexuc` (RFC 9741).
    case hexuc
    /// `.b32` (RFC 9741).
    case b32
    /// `.h32` (RFC 9741).
    case h32
    /// `.b45` (RFC 9741).
    case b45
    /// `.base10` (RFC 9741).
    case base10
    /// `.printf` (RFC 9741).
    case printf
    /// `.json` (RFC 9741).
    case json
    /// `.join` (RFC 9741).
    case join
}

extension ControlOperator: CustomStringConvertible {
    public var description: String {
        switch self {
        case .size: return ".size"
        case .bits: return ".bits"
        case .regexp: return ".regexp"
        case .pcre: return ".pcre"
        case .iregexp: return ".iregexp"
        case .bitfield: return ".bitfield"
        case .cbor: return ".cbor"
        case .cborseq: return ".cborseq"
        case .within: return ".within"
        case .cat: return ".cat"
        case .det: return ".det"
        case .plus: return ".plus"
        case .abnf: return ".abnf"
        case .abnfb: return ".abnfb"
        case .feature: return ".feature"
        case .b64u: return ".b64u"
        case .b64c: return ".b64c"
        case .b64uSloppy: return ".b64u-sloppy"
        case .b64cSloppy: return ".b64c-sloppy"
        case .hex: return ".hex"
        case .hexlc: return ".hexlc"
        case .hexuc: return ".hexuc"
        case .b32: return ".b32"
        case .h32: return ".h32"
        case .b45: return ".b45"
        case .base10: return ".base10"
        case .printf: return ".printf"
        case .json: return ".json"
        case .join: return ".join"
        case .and: return ".and"
        case .lt: return ".lt"
        case .le: return ".le"
        case .gt: return ".gt"
        case .ge: return ".ge"
        case .eq: return ".eq"
        case .ne: return ".ne"
        case .default: return ".default"
        }
    }
}

/// Range value.
enum RangeValue: Hashable, Sendable {
    /// Identifier with optional socket/plug.
    case ident(String, SocketPlug?)
    /// Integer.
    case int(BigInt)
    /// Unsigned integer.
    case uint(UInt64)
    /// Float.
    case float(Double)

    /// Converts a token to a range value.
    init(token: Token) throws(RangeValueError) {
        switch token {
        case .ident(let ident, let socket):
            self = .ident(ident, socket)
        case .value(let value):
            switch value {
            case .int(let i): self = .int(i)
            case .uint(let ui): self = .uint(ui)
            case .float(let f): self = .float(f.value)
            default: throw RangeValueError()
            }
        default:
            throw RangeValueError()
        }
    }

    /// Returns `Value` from the given `RangeValue`.
    func asValue() -> Value? {
        switch self {
        case .uint(let ui): return .uint(ui)
        case .float(let f): return .float(FloatLiteralValue(f))
        default: return nil
        }
    }
}

/// The error of converting a ``Token`` that is no range bound into a
/// ``RangeValue``.
struct RangeValueError: Error, Sendable, CustomStringConvertible {
    var description: String { "Invalid range token" }
}

extension RangeValue: CustomStringConvertible {
    var description: String {
        switch self {
        case .ident(let ident, _): return ident
        case .int(let i): return i.description
        case .uint(let i): return String(i)
        case .float(let fl): return FloatLiteral(fl).description
        }
    }
}

/// The text a float literal was written as.
///
/// A literal read from a document keeps its own text so that writing the
/// document back out spells the literal the way it was written. The text
/// takes no part in equality or hashing.
public struct FloatNotation: Sendable, Hashable {
    /// The literal's source text, if the value was read from a document.
    public let text: String?

    /// A value no document spelled.
    public init() {
        self.text = nil
    }

    /// The notation of a float literal read from a document.
    public init(literal text: String) {
        self.text = text
    }

    public static func == (lhs: FloatNotation, rhs: FloatNotation) -> Bool {
        true
    }

    public func hash(into hasher: inout Hasher) {}

    /// The text to write `value` as, when a notation is known for it and that
    /// notation denotes exactly the value being written.
    func literal(for value: Double) -> String? {
        if !value.isFinite {
            return nil
        }
        guard let text else { return nil }
        guard let read = readFloatLiteral(text) else { return nil }
        return read.bitPattern == value.bitPattern ? text : nil
    }
}

/// Reads a float literal's text back to the value it denotes, in either of
/// the notations RFC 8610 Appendix B writes a float literal in.
func readFloatLiteral(_ text: String) -> Double? {
    if text.contains("x") || text.contains("X") {
        return parseHexf64(text)
    }
    return parseDecimalFloat(text)
}

/// A float literal: the value its digits denote, and the notation they were
/// written in. Equality and hashing consider the value only.
public struct FloatLiteralValue: Sendable, Hashable {
    /// Value the literal's digits denote.
    public var value: Double
    /// Notation the digits were written in.
    public var notation: FloatNotation

    /// A literal denoting `value`, written in `notation`.
    public init(_ value: Double, notation: FloatNotation = FloatNotation()) {
        self.value = value
        self.notation = notation
    }
}

extension FloatLiteralValue: CustomStringConvertible {
    /// Writes the literal in the notation it was written in, where that
    /// notation is known and still denotes the value; in the canonical
    /// spelling of the value otherwise.
    public var description: String {
        if let text = notation.literal(for: value) {
            return text
        }
        return FloatLiteral(value).description
    }
}

/// Literal value.
public enum Value: Hashable, Sendable {
    /// Integer value.
    case int(BigInt)
    /// Unsigned integer value.
    case uint(UInt64)
    /// Float value.
    case float(FloatLiteralValue)
    /// Text value.
    case text(String)
    /// Byte value.
    case byte(ByteValue)
}

/// Numeric value.
enum Numeric: Hashable, Sendable {
    /// Integer.
    case int(BigInt)
    /// Unsigned integer.
    case uint(UInt64)
    /// Float.
    case float(Double)
}

/// The magnitudes a float literal is written in exponent notation at
/// (the ones ECMA-262 switches at in `Number::prototype::toString`).
private let exponentNotationAtOrAbove: Double = 1e21
private let exponentNotationBelow: Double = 1e-6

/// A float value written the way a CDDL float literal writes it: always with
/// a fraction (or an exponent), so the digits keep denoting a float.
struct FloatLiteral: Sendable, Hashable, CustomStringConvertible {
    /// The value to write.
    var value: Double

    /// A float literal for `value`.
    init(_ value: Double) {
        self.value = value
    }

    var description: String {
        if value.isNaN {
            return "NaN"
        }
        if value.isInfinite {
            return value.sign == .minus ? "-Infinity" : "Infinity"
        }

        let magnitude = abs(value)
        if magnitude >= exponentNotationAtOrAbove || (magnitude != 0 && magnitude < exponentNotationBelow) {
            let written = exponentialDescription(value)
            // Supply the fraction a single-digit mantissa is without.
            guard let at = written.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
                return written
            }
            let mantissa = written[written.startIndex..<at]
            let exponent = written[at...]
            if mantissa.contains(".") {
                return written
            }
            return mantissa + ".0" + exponent
        }

        let digits = plainDecimalDescription(value)
        if digits.contains(".") || digits.contains("e") || digits.contains("E") {
            return digits
        }
        return digits + ".0"
    }
}

/// Writes `text` with the escape sequences of RFC 8610 Appendix B applied, so
/// that the result is a valid body for a literal delimited by `quote`.
func writeEscapedText(_ text: String, quote: Unicode.Scalar) -> String {
    var out = ""
    for c in text.unicodeScalars {
        switch c {
        case quote:
            out.append("\\")
            out.unicodeScalars.append(quote)
        case "\\":
            out.append("\\\\")
        case "\u{8}":
            out.append("\\b")
        case "\u{c}":
            out.append("\\f")
        case "\n":
            out.append("\\n")
        case "\r":
            out.append("\\r")
        case "\t":
            out.append("\\t")
        default:
            // An unescaped character of a text literal is drawn from
            // %x20-21 / %x23-5B / %x5D-7E / NONASCII, and NONASCII starts at
            // U+00A0, so DEL and the C1 controls have to be written as escapes
            // too.
            if c.value < 0x20 || (0x7f...0x9f).contains(c.value) {
                out.append("\\u")
                let hex = String(c.value, radix: 16, uppercase: true)
                out.append(String(repeating: "0", count: max(0, 4 - hex.count)) + hex)
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    return out
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .text(let text):
            return "\"" + writeEscapedText(text, quote: "\"") + "\""
        case .int(let i):
            return i.description
        case .uint(let ui):
            return String(ui)
        case .float(let float):
            return float.description
        case .byte(let bv):
            return bv.description
        }
    }
}

extension Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

/// Byte string values.
public enum ByteValue: Hashable, Sendable {
    /// Unprefixed byte string value.
    case utf8([UInt8])
    /// Byte string value written in base16 notation.
    case b16([UInt8])
    /// Byte string value written in base64 notation.
    case b64([UInt8])
}

/// Renders a byte string in the base16 literal notation `h'..'`.
func writeBase16Literal(_ bytes: [UInt8]) -> String {
    var out = "h'"
    for byte in bytes {
        let hex = String(byte, radix: 16)
        if hex.count == 1 { out.append("0") }
        out.append(hex)
    }
    out.append("'")
    return out
}

/// The URL-safe base64 alphabet, indexed by the six-bit group it encodes.
private let base64URLAlphabet: [UInt8] = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
)

/// Renders a byte string in the base64 literal notation `b64'..'`, in the
/// URL-safe alphabet and without padding.
func writeBase64Literal(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = Array("b64'".utf8)
    var index = 0
    while index < bytes.count {
        let chunk = bytes[index..<min(index + 3, bytes.count)]
        var group: UInt32 = 0
        for (idx, byte) in chunk.enumerated() {
            group |= UInt32(byte) << (16 - 8 * idx)
        }
        for idx in 0..<(chunk.count + 1) {
            out.append(base64URLAlphabet[Int((group >> (18 - 6 * UInt32(idx))) & 0x3f)])
        }
        index += 3
    }
    out.append(UInt8(ascii: "'"))
    return String(decoding: out, as: UTF8.self)
}

extension ByteValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .b16(let b):
            return writeBase16Literal(b)
        case .b64(let b):
            return writeBase64Literal(b)
        case .utf8(let b):
            // The unprefixed notation falls back to base16 for content that is
            // not UTF-8.
            if let s = String(validatingUTF8Bytes: b) {
                return "'" + writeEscapedText(s, quote: "'") + "'"
            }
            return writeBase16Literal(b)
        }
    }
}

extension String {
    /// Decodes `bytes` as UTF-8, returning `nil` when they are not valid UTF-8.
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                break loop
            case .error:
                return nil
            }
        }
        self = String(scalars)
    }
}

/// Socket/plug prefix.
public enum SocketPlug: Hashable, Sendable {
    /// Type socket `$`.
    case type
    /// Group socket `$$`.
    case group

    /// Parses a socket/plug prefix from the start of `s`.
    init(prefixOf s: String) throws(SocketPlugError) {
        let bytes = Array(s.utf8.prefix(2))
        guard bytes.first == UInt8(ascii: "$") else {
            throw SocketPlugError()
        }
        self = bytes.count > 1 && bytes[1] == UInt8(ascii: "$") ? .group : .type
    }
}

/// The error of parsing a string that does not begin with a socket prefix.
struct SocketPlugError: Error, Sendable, CustomStringConvertible {
    var description: String { "Malformed socket plug string" }
}

extension SocketPlug: CustomStringConvertible {
    public var description: String {
        switch self {
        case .type: return "$"
        case .group: return "$$"
        }
    }
}

extension Token: CustomStringConvertible {
    var description: String {
        switch self {
        case .ident(let ident, let socketPlug):
            if let sp = socketPlug {
                return "\(sp)\(ident)"
            }
            return ident
        case .illegal(let s): return "ILLEGAL(\(s))"
        case .assign: return "="
        case .oneOrMore: return "+"
        case .optional: return "?"
        case .asterisk: return "*"
        case .lparen: return "("
        case .rparen: return ")"
        case .lbrace: return "{"
        case .rbrace: return "}"
        case .lbracket: return "["
        case .rbracket: return "]"
        case .tchoice: return "/"
        case .tchoiceAlt: return "/="
        case .gchoiceAlt: return "//="
        case .comma: return ","
        case .comment(let c): return ";\(c)"
        case .colon: return ":"
        case .cut: return "^"
        case .eof: return ""
        case .tstr: return "tstr"
        case .langleBracket: return "<"
        case .rangleBracket: return ">"
        case .int: return "int"
        case .uint: return "uint"
        case .arrowMap: return "=>"
        case .controlOperator(let co): return co.description
        case .number: return "number"
        case .bstr: return "bstr"
        case .bytes: return "bytes"
        case .gchoice: return "//"
        case .true: return "true"
        case .gtoChoice: return "&"
        case .value(let value): return value.description
        case .regexp: return "regexp"
        case .rangeOp(let i): return i ? ".." : "..."
        case .range(let l, let u, let i):
            if case .ident = l {
                return i ? "\(l) .. \(u)" : "\(l) ... \(u)"
            }
            return i ? "\(l)..\(u)" : "\(l)...\(u)"
        case .tag(let mt, let tag):
            if let m = mt {
                if let t = tag {
                    return "#\(m).\(t)"
                }
                return "#\(m)"
            }
            return "#"
        default:
            return ""
        }
    }
}

/// Returns an optional control operator from a given string, such as
/// `".size"`.
func lookupControlFromStr(_ ident: String) -> ControlOperator? {
    switch ident {
    case ".size": return .size
    case ".bits": return .bits
    case ".regexp": return .regexp
    case ".cbor": return .cbor
    case ".cborseq": return .cborseq
    case ".within": return .within
    case ".and": return .and
    case ".lt": return .lt
    case ".le": return .le
    case ".gt": return .gt
    case ".ge": return .ge
    case ".eq": return .eq
    case ".ne": return .ne
    case ".default": return .default
    case ".pcre": return .pcre
    case ".iregexp": return .iregexp
    case ".bitfield": return .bitfield
    case ".cat": return .cat
    case ".det": return .det
    case ".plus": return .plus
    case ".abnf": return .abnf
    case ".abnfb": return .abnfb
    case ".feature": return .feature
    case ".b64u": return .b64u
    case ".b64c": return .b64c
    case ".b64u-sloppy": return .b64uSloppy
    case ".b64c-sloppy": return .b64cSloppy
    case ".hex": return .hex
    case ".hexlc": return .hexlc
    case ".hexuc": return .hexuc
    case ".b32": return .b32
    case ".h32": return .h32
    case ".b45": return .b45
    case ".base10": return .base10
    case ".printf": return .printf
    case ".json": return .json
    case ".join": return .join
    default: return nil
    }
}

/// Returns the token in the standard prelude from the given string, or an
/// identifier token (with its socket prefix split off) otherwise.
func lookupIdent(_ ident: String) -> Token {
    switch ident {
    case "false": return .false
    case "true": return .true
    case "bool": return .bool
    case "nil": return .nil
    case "null": return .null
    case "uint": return .uint
    case "nint": return .nint
    case "int": return .int
    case "float16": return .float16
    case "float32": return .float32
    case "float64": return .float64
    case "float16-32": return .float1632
    case "float32-64": return .float3264
    case "float": return .float
    case "bstr": return .bstr
    case "tstr": return .tstr
    case "any": return .any
    case "bytes": return .bytes
    case "text": return .text
    case "tdate": return .tdate
    case "time": return .time
    case "number": return .number
    case "biguint": return .biguint
    case "bignint": return .bignint
    case "bigint": return .bigint
    case "integer": return .integer
    case "unsigned": return .unsigned
    case "decfrac": return .decfrac
    case "bigfloat": return .bigfloat
    case "eb64url": return .eb64url
    case "eb64legacy": return .eb64legacy
    case "eb16": return .eb16
    case "encoded-cbor": return .encodedCBOR
    case "uri": return .uri
    case "b64url": return .b64url
    case "b64legacy": return .b64legacy
    case "regexp": return .regexp
    case "mime-message": return .mimeMessage
    case "cbor-any": return .cborAny
    case "undefined": return .undefined
    default:
        if ident.hasPrefix("$$") {
            return .ident(String(ident.dropFirst(2)), .group)
        }
        if ident.hasPrefix("$") {
            return .ident(String(ident.dropFirst(1)), .type)
        }
        return .ident(ident, nil)
    }
}

/// If `token` is an opening delimiter, returns its matching closing delimiter.
func closingDelimiter(_ token: Token) -> Token? {
    switch token {
    case .lbrace: return .rbrace
    case .lbracket: return .rbracket
    case .lparen: return .rparen
    case .langleBracket: return .rangleBracket
    default: return nil
    }
}
