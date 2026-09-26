import BigInt
import Foundation

// The control operators that compute a value or decode text: `.cat`, `.det`
// and `.plus` (RFC 9165 Section 2), the text conversion operators and
// `.printf`, `.json` and `.join` (RFC 9741). `.abnf` and `.abnfb` (RFC 9165
// Section 3) are not provided.

// MARK: - Operands

/// The text and byte string literals a rule identifier denotes as an operand of
/// `.cat` or `.det`.
private func stringLiteralsFromIdent(_ schema: Schema, _ ident: Identifier) -> Result<[Type2], SchemaFault> {
    controlOperandValues(schema, ident, .stringLiteral)
}

/// The numeric values a rule identifier denotes as an operand of `.plus`.
private func numericValuesFromIdent(_ schema: Schema, _ ident: Identifier) -> Result<[Type2], SchemaFault> {
    controlOperandValues(schema, ident, .numeric)
}

/// The text of a UTF-8 byte string, or why it is not UTF-8.
private func utf8Text(_ bytes: [UInt8]) -> Result<String, SchemaFault> {
    if let text = String(validatingUTF8Bytes: bytes) {
        return .success(text)
    }
    return .failure(SchemaFault(utf8ErrorDescription(bytes)))
}

/// `text` without the single quotes it starts and ends with.
private func trimmingQuotes(_ text: String) -> String {
    var scalars = Substring(text).unicodeScalars[...]
    while scalars.first == "'" {
        scalars = scalars.dropFirst()
    }
    while scalars.last == "'" {
        scalars = scalars.dropLast()
    }
    return String(String.UnicodeScalarView(scalars))
}

// MARK: - .cat and .det

/// The concatenation of target and controller (RFC 9165 Section 2.2); with
/// `isDedent`, of each with the leading whitespace of its lines removed
/// (`.det`). One literal for each choice of the controller.
func catOperation(_ schema: Schema, _ target: Type2, _ controller: Type2, _ isDedent: Bool) -> Result<[Type2], SchemaFault> {
    do {
        return .success(try catValues(schema, target, controller, isDedent))
    } catch let fault as SchemaFault {
        return .failure(fault)
    } catch {
        return .failure(SchemaFault("\(error)"))
    }
}

private func catValues(_ schema: Schema, _ target: Type2, _ controller: Type2, _ isDedent: Bool) throws -> [Type2] {
    var literals: [Type2] = []
    let ctrl: ControlOperator = isDedent ? .det : .cat

    func joined(_ value: String, _ controller: String) -> Type2 {
        if isDedent {
            return Type2(text: dedentText(value) + dedentText(controller))
        }
        return Type2(text: value + controller)
    }

    func controllerLiterals(_ ident: Identifier) throws -> [Type2] {
        switch stringLiteralsFromIdent(schema, ident) {
        case .success(let values): return values
        case .failure(let fault): throw SchemaFault("controller of \(ctrl) operation: \(fault)")
        }
    }

    func eachChoice(_ pt: Type) throws {
        for choice in pt.typeChoices where choice.type1.operator == nil {
            literals.append(contentsOf: try catValues(schema, target, choice.type1.type2, isDedent))
        }
    }

    switch target {
    case .textValue(let value, _):
        switch controller {
        case .textValue(let controller, _):
            literals.append(joined(value, controller))
        case .typename(let ident, _, _):
            for controller in try controllerLiterals(ident) {
                literals.append(contentsOf: try catValues(schema, target, controller, isDedent))
            }
        case .utf8ByteString(let controller, _):
            switch utf8Text(controller) {
            case .success(let text): literals.append(joined(value, trimmingQuotes(text)))
            case .failure(let fault): throw SchemaFault("error parsing byte string: \(fault)")
            }
        case .b16ByteString(let controller, _), .b64ByteString(let controller, _):
            switch utf8Text(controller) {
            case .success(let text): literals.append(joined(value, text))
            case .failure(let fault): throw SchemaFault("error decoding utf-8: \(fault)")
            }
        case .parenthesizedType(let pt, _, _, _):
            try eachChoice(pt)
        default:
            throw SchemaFault("invalid controller used for \(ctrl) operation")
        }
    case .typename(let ident, _, _):
        // Only the first literal of the target is taken.
        let values: [Type2]
        switch stringLiteralsFromIdent(schema, ident) {
        case .success(let found): values = found
        case .failure(let fault): throw SchemaFault("target of \(ctrl) operation: \(fault)")
        }
        guard let value = values.first else {
            throw SchemaFault("target of \(ctrl) operation denotes no value")
        }
        literals.append(contentsOf: try catValues(schema, value, controller, isDedent))
    case .parenthesizedType(let pt, _, _, _):
        guard let tc = pt.typeChoices.first, tc.type1.operator == nil else {
            throw SchemaFault("invalid target type in \(ctrl) control operator")
        }
        literals.append(contentsOf: try catValues(schema, tc.type1.type2, controller, isDedent))
    case .utf8ByteString(let value, _):
        let valueText: String
        switch utf8Text(value) {
        case .success(let text): valueText = text
        case .failure(let fault): throw SchemaFault("error parsing byte string: \(fault)")
        }
        switch controller {
        case .textValue(let controller, _):
            literals.append(joined(trimmingQuotes(valueText), controller))
        case .typename(let ident, _, _):
            for controller in try controllerLiterals(ident) {
                literals.append(contentsOf: try catValues(schema, target, controller, isDedent))
            }
        case .utf8ByteString(let controller, _):
            switch utf8Text(controller) {
            case .success(let text): literals.append(joined(trimmingQuotes(valueText), trimmingQuotes(text)))
            case .failure(let fault): throw SchemaFault("error parsing byte string: \(fault)")
            }
        case .b16ByteString(let controller, _), .b64ByteString(let controller, _):
            switch utf8Text(controller) {
            case .success(let text): literals.append(joined(trimmingQuotes(valueText), text))
            case .failure(let fault): throw SchemaFault("error decoding utf-8: \(fault)")
            }
        case .parenthesizedType(let pt, _, _, _):
            try eachChoice(pt)
        default:
            throw SchemaFault("invalid controller used for \(ctrl) operation")
        }
    case .b16ByteString(let value, _), .b64ByteString(let value, _):
        // A base16 or base64 literal holds the bytes it denotes, so the
        // concatenation is over those bytes, written in the target's notation.
        let targetBytes = isDedent ? try dedentBytes(value, false) : value
        let isB64: Bool
        if case .b64ByteString = target {
            isB64 = true
        } else {
            isB64 = false
        }
        func concatenated(_ controller: [UInt8]) -> Type2 {
            let bytes = targetBytes + controller
            return isB64 ? .b64ByteString(value: bytes) : .b16ByteString(value: bytes)
        }

        switch controller {
        case .textValue(let controller, _):
            literals.append(concatenated(Array((isDedent ? dedentText(controller) : controller).utf8)))
        case .typename(let ident, _, _):
            for controller in try controllerLiterals(ident) {
                literals.append(contentsOf: try catValues(schema, target, controller, isDedent))
            }
        case .utf8ByteString(let controller, _):
            literals.append(concatenated(isDedent ? try dedentBytes(controller, true) : controller))
        case .b16ByteString(let controller, _), .b64ByteString(let controller, _):
            literals.append(concatenated(isDedent ? try dedentBytes(controller, false) : controller))
        case .parenthesizedType(let pt, _, _, _):
            try eachChoice(pt)
        default:
            throw SchemaFault("invalid controller used for \(ctrl) operation")
        }
    default:
        throw SchemaFault("invalid target used for \(ctrl) operation, got \(target)")
    }

    return literals
}

/// Whether a scalar is whitespace by the Unicode White_Space property.
private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace
}

/// `source` with the leading whitespace of every line removed.
func dedentText(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        String(String.UnicodeScalarView(line.unicodeScalars.drop(while: isWhitespace)))
    }.joined(separator: "\n")
}

private func dedentBytes(_ source: [UInt8], _ isUTF8ByteString: Bool) throws -> [UInt8] {
    guard let text = String(validatingUTF8Bytes: source) else {
        throw SchemaFault(utf8ErrorDescription(source))
    }
    if isUTF8ByteString {
        return Array(dedentText(trimmingQuotes(text)).utf8)
    }
    return Array(dedentText(text).utf8)
}

// MARK: - .plus

/// The smallest value a signed 128-bit integer holds; the computed values are
/// held to that range.
private let signedMin = -(BigInt(1) << 127)
/// The largest value a signed 128-bit integer holds.
private let signedMax = (BigInt(1) << 127) - 1

/// The whole number a float contributes to a computed integer: its floor (RFC
/// 9165 Section 2.1).
private func integerSummand(_ value: Double) throws -> BigInt {
    let floor = value.rounded(.down)
    let limit = 0x1p127
    if floor >= -limit && floor < limit {
        return BigInt(floor)
    }
    throw SchemaFault("\(floatDisplay(value)) is outside the range of integers a computed value can be composed of")
}

private func intSum(_ target: BigInt, _ controller: BigInt) throws -> BigInt {
    let sum = target + controller
    if sum < signedMin || sum > signedMax {
        throw SchemaFault("the sum of \(target) and \(controller) is outside the range of a signed integer")
    }
    return sum
}

/// The value an unsigned target computes to when a summand is added to it: a
/// uint literal where it is one, a negative integer literal where the sum is
/// negative.
private func uintSum(_ target: BigInt, _ controller: BigInt) throws -> Type2 {
    let sum = try intSum(target, controller)
    if let value = UInt64(exactly: sum) {
        return .uintValue(value: value)
    }
    if sum.sign == .minus {
        return .intValue(value: sum)
    }
    throw SchemaFault("the sum of \(target) and \(controller) is outside the range of an unsigned integer")
}

/// The numeric sum of target and controller (RFC 9165 Section 2.1), one value
/// for each choice of the controller.
func plusOperation(_ schema: Schema, _ target: Type2, _ controller: Type2) -> Result<[Type2], SchemaFault> {
    do {
        return .success(try plusValues(schema, target, controller))
    } catch let fault as SchemaFault {
        return .failure(fault)
    } catch {
        return .failure(SchemaFault("\(error)"))
    }
}

private func plusValues(_ schema: Schema, _ target: Type2, _ controller: Type2) throws -> [Type2] {
    var values: [Type2] = []

    func controllerChoices(_ pt: Type) throws {
        for choice in pt.typeChoices {
            if let op = choice.type1.operator {
                guard case .ctlOp(.plus, _) = op.operator else {
                    throw SchemaFault("nested operator must be .plus")
                }
                for v in try plusValues(schema, choice.type1.type2, op.type2) {
                    values.append(contentsOf: try plusValues(schema, target, v))
                }
            } else {
                values.append(contentsOf: try plusValues(schema, target, choice.type1.type2))
            }
        }
    }

    func controllerIdent(_ ident: Identifier) throws {
        switch numericValuesFromIdent(schema, ident) {
        case .success(let found):
            for controller in found {
                values.append(contentsOf: try plusValues(schema, target, controller))
            }
        case .failure(let fault):
            throw SchemaFault("controller of .plus operation: \(fault)")
        }
    }

    switch target {
    case .uintValue(let value, _):
        switch controller {
        case .uintValue(let c, _): values.append(try uintSum(BigInt(value), BigInt(c)))
        case .intValue(let c, _): values.append(try uintSum(BigInt(value), c))
        case .floatValue(let c, _, _): values.append(try uintSum(BigInt(value), try integerSummand(c)))
        case .typename(let ident, _, _): try controllerIdent(ident)
        case .parenthesizedType(let pt, _, _, _): try controllerChoices(pt)
        default: throw SchemaFault("invalid controller used for .plus operation")
        }
    case .intValue(let value, _):
        switch controller {
        case .intValue(let c, _): values.append(.intValue(value: try intSum(value, c)))
        case .uintValue(let c, _): values.append(.intValue(value: try intSum(value, BigInt(c))))
        case .floatValue(let c, _, _): values.append(.intValue(value: try intSum(value, try integerSummand(c))))
        case .typename(let ident, _, _): try controllerIdent(ident)
        case .parenthesizedType(let pt, _, _, _): try controllerChoices(pt)
        default: throw SchemaFault("invalid controller used for .plus operation")
        }
    case .floatValue(let value, _, _):
        switch controller {
        case .intValue(let c, _): values.append(Type2(value + Double(c)))
        case .uintValue(let c, _): values.append(Type2(value + Double(c)))
        case .floatValue(let c, _, _): values.append(Type2(value + c))
        case .typename(let ident, _, _): try controllerIdent(ident)
        case .parenthesizedType(let pt, _, _, _): try controllerChoices(pt)
        default: throw SchemaFault("invalid controller used for .plus operation")
        }
    case .typename(let ident, _, _):
        // Only the first value of the target is taken.
        let found: [Type2]
        switch numericValuesFromIdent(schema, ident) {
        case .success(let values): found = values
        case .failure(let fault): throw SchemaFault("target of .plus operation: \(fault)")
        }
        guard let value = found.first else {
            throw SchemaFault("target of .plus operation denotes no value")
        }
        values.append(contentsOf: try plusValues(schema, value, controller))
    case .parenthesizedType(let pt, _, _, _):
        guard let tc = pt.typeChoices.first else {
            throw SchemaFault("invalid target type in .plus control operator")
        }
        if let op = tc.type1.operator {
            guard case .ctlOp(.plus, _) = op.operator else {
                throw SchemaFault("nested operator must be .plus")
            }
            for v in try plusValues(schema, tc.type1.type2, op.type2) {
                values.append(contentsOf: try plusValues(schema, v, controller))
            }
        } else {
            values.append(contentsOf: try plusValues(schema, tc.type1.type2, controller))
        }
    default:
        throw SchemaFault("invalid target type in .plus control operator, got \(target)")
    }

    return values
}

// MARK: - .abnf and .abnfb

/// The literals an `.abnf` or `.abnfb` controller written as a `.cat` or
/// `.det` computation stands for.
func abnfFromComplexController(_ schema: Schema, _ controller: Type) -> Result<[Type2], SchemaFault> {
    if let tc = controller.typeChoices.first, let op = tc.type1.operator, case .ctlOp(let ctrl, _) = op.operator {
        switch ctrl {
        case .cat: return catOperation(schema, tc.type1.type2, op.type2, false)
        case .det: return catOperation(schema, tc.type1.type2, op.type2, true)
        default: return .failure(SchemaFault("invalid_controller"))
        }
    }
    return .failure(SchemaFault("invalid controller"))
}

/// Matching a target against an ABNF grammar (RFC 9165 Section 3), which this
/// implementation does not provide.
func abnfUnsupported(_ ctrl: ControlOperator) -> CBORValidationError {
    .unsupported("the \(ctrl) control operator (RFC 9165 Section 3) is not supported")
}

// MARK: - Text conversion (RFC 9741 Section 2.1)

private let base64ClassicAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
private let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
private let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
private let base32HexAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUV".utf8)

private func decodingTable(_ alphabet: [UInt8]) -> [Int8] {
    var table = [Int8](repeating: -1, count: 256)
    for (value, symbol) in alphabet.enumerated() {
        table[Int(symbol)] = Int8(value)
    }
    return table
}

private let base64ClassicTable = decodingTable(base64ClassicAlphabet)
private let base64URLTable = decodingTable(base64URLAlphabet)
private let base32Table = decodingTable(base32Alphabet)
private let base32HexTable = decodingTable(base32HexAlphabet)

/// Why text is not an encoding.
struct EncodingError: Error, Equatable {}

/// Decodes the symbols of an unpadded base-2^`bits` encoding (6 for base64, 5
/// for base32), requiring the bits the final symbol carries beyond the
/// encoded data to be zero.
private func decodeSymbols(_ symbols: ArraySlice<UInt8>, _ table: [Int8], bits: Int) throws(EncodingError) -> [UInt8] {
    let groupSymbols = bits == 6 ? 4 : 8
    let validRemainders: Set<Int> = bits == 6 ? [0, 2, 3] : [0, 2, 4, 5, 7]
    guard validRemainders.contains(symbols.count % groupSymbols) else {
        throw EncodingError()
    }
    var out: [UInt8] = []
    var accumulator: UInt64 = 0
    var held = 0
    for symbol in symbols {
        let value = table[Int(symbol)]
        guard value >= 0 else { throw EncodingError() }
        accumulator = (accumulator << UInt64(bits)) | UInt64(value)
        held += bits
        if held >= 8 {
            held -= 8
            out.append(UInt8((accumulator >> UInt64(held)) & 0xff))
        }
    }
    // The bits left over carry no data and must be zero.
    if held > 0 && accumulator & ((1 << UInt64(held)) - 1) != 0 {
        throw EncodingError()
    }
    return out
}

/// Rewrites the last base64 symbol of `text` so that the bits it carries
/// beyond the encoded data are zero, leaving the alphabet, the length and any
/// padding as they are; `nil` when `text` is not a well formed encoding.
private func zeroBase64TrailingBits(_ text: [UInt8], _ isClassic: Bool) -> [UInt8]? {
    let alphabet = isClassic ? base64ClassicAlphabet : base64URLAlphabet
    var bodyEnd = text.count
    while bodyEnd > 0 && text[bodyEnd - 1] == UInt8(ascii: "=") {
        bodyEnd -= 1
    }
    let trailingBits: UInt8
    switch bodyEnd % 4 {
    case 0: return text
    case 2: trailingBits = 0b0000_1111
    case 3: trailingBits = 0b0000_0011
    default: return nil
    }
    let last = text[bodyEnd - 1]
    guard let value = alphabet.firstIndex(of: last) else { return nil }
    var canonical = text
    canonical[bodyEnd - 1] = alphabet[Int(UInt8(value) & ~trailingBits)]
    return canonical
}

/// Decodes base64 text in the classic (padded) or URL (unpadded) alphabet;
/// the sloppy variants accept nonzero trailing bits (RFC 9741 Section 2.1).
func base64Decode(_ text: String, _ isClassic: Bool, _ isSloppy: Bool) throws(EncodingError) -> [UInt8] {
    var input = Array(text.utf8)
    if isSloppy, let canonical = zeroBase64TrailingBits(input, isClassic) {
        input = canonical
    }

    if !isClassic {
        return try decodeSymbols(input[...], base64URLTable, bits: 6)
    }

    // Padded: blocks of four symbols, each of which may end in padding.
    guard input.count % 4 == 0 else { throw EncodingError() }
    var out: [UInt8] = []
    var start = 0
    while start < input.count {
        let block = input[start..<(start + 4)]
        if let pad = block.firstIndex(of: UInt8(ascii: "=")) {
            let symbols = pad - start
            guard symbols == 2 || symbols == 3,
                block[pad...].allSatisfy({ $0 == UInt8(ascii: "=") })
            else {
                throw EncodingError()
            }
            out.append(contentsOf: try decodeSymbols(block[start..<pad], base64ClassicTable, bits: 6))
        } else {
            out.append(contentsOf: try decodeSymbols(block, base64ClassicTable, bits: 6))
        }
        start += 4
    }
    return out
}

/// Decodes hex text of either case.
private func hexDecodeText(_ text: String) -> [UInt8]? {
    let bytes = Array(text.utf8)
    guard bytes.count % 2 == 0 else { return nil }
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
    var out: [UInt8] = []
    var index = 0
    while index < bytes.count {
        guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
        out.append(high << 4 | low)
        index += 2
    }
    return out
}

private let base45Alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)
private let base45Table = decodingTable(base45Alphabet)

/// Decodes base45 text (RFC 9285).
private func base45Decode(_ text: String) -> [UInt8]? {
    let bytes = Array(text.utf8)
    var out: [UInt8] = []
    var index = 0
    func value(_ c: UInt8) -> UInt32? {
        let v = base45Table[Int(c)]
        return v >= 0 ? UInt32(v) : nil
    }
    while index + 3 <= bytes.count {
        guard let a = value(bytes[index]), let b = value(bytes[index + 1]), let c = value(bytes[index + 2]) else {
            return nil
        }
        let v = a + b * 45 + c * 45 * 45
        guard v <= 0xffff else { return nil }
        out.append(UInt8(v >> 8))
        out.append(UInt8(v & 0xff))
        index += 3
    }
    switch bytes.count - index {
    case 0:
        break
    case 2:
        guard let a = value(bytes[index]), let b = value(bytes[index + 1]) else { return nil }
        out.append(UInt8(truncatingIfNeeded: a + b * 45))
    default:
        return nil
    }
    return out
}

/// The byte string `text` is the encoded form of under a text conversion
/// control operator, or `nil` when it is not a well formed encoding for that
/// operator. The case `.hexlc` and `.hexuc` state is part of the encoding.
func decodeTextConversion(_ ctrl: ControlOperator, _ text: String) -> [UInt8]? {
    switch ctrl {
    case .b64u: return try? base64Decode(text, false, false)
    case .b64uSloppy: return try? base64Decode(text, false, true)
    case .b64c: return try? base64Decode(text, true, false)
    case .b64cSloppy: return try? base64Decode(text, true, true)
    case .hex, .hexlc, .hexuc:
        switch ctrl {
        case .hexlc:
            guard text.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
                return nil
            }
        case .hexuc:
            guard text.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else {
                return nil
            }
        default:
            break
        }
        return hexDecodeText(text)
    case .b32: return try? decodeSymbols(Array(text.utf8)[...], base32Table, bits: 5)
    case .h32: return try? decodeSymbols(Array(text.utf8)[...], base32HexTable, bits: 5)
    case .b45: return base45Decode(text)
    default: return nil
    }
}

// MARK: - .base10 (RFC 9741 Section 2.2)

/// Whether `text` is the decimal representation, without leading zeros, of the
/// integer the controller denotes.
func validateBase10Text(_ target: Type2, _ controller: Type2, _ text: String) -> Result<Bool, SchemaFault> {
    let scalars = Array(text.unicodeScalars)
    if !scalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "-" }) {
        return .success(false)
    }

    if text == "0" {
        // Zero is valid.
    } else if text.hasPrefix("-") {
        if scalars.count < 2 || !("0"..."9").contains(scalars[1]) || scalars[1] == "0" {
            return .success(false)
        }
    } else {
        if text.hasPrefix("0") && scalars.count > 1 {
            return .success(false)
        }
        if scalars.first.map({ !("0"..."9").contains($0) }) ?? true || text.hasPrefix("0") {
            return .success(false)
        }
    }

    switch controller {
    case .intValue(let value, _):
        guard let parsed = parseDecimalInteger(text), parsed >= signedMin, parsed <= signedMax else {
            return .success(false)
        }
        return .success(parsed == value)
    case .uintValue(let value, _):
        guard let parsed = parseDecimalInteger(text), let parsedValue = UInt64(exactly: parsed) else {
            return .success(false)
        }
        return .success(parsedValue == value)
    default:
        return .failure(SchemaFault("invalid controller type for .base10 operation: \(controller)"))
    }
}

/// The integer a decimal string with an optional sign spells.
private func parseDecimalInteger(_ text: String) -> BigInt? {
    var body = Substring(text)
    var negative = false
    if body.hasPrefix("-") {
        negative = true
        body = body.dropFirst()
    } else if body.hasPrefix("+") {
        body = body.dropFirst()
    }
    guard !body.isEmpty, body.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    guard let magnitude = BigInt(String(body), radix: 10) else { return nil }
    return negative ? -magnitude : magnitude
}

// MARK: - .printf (RFC 9741 Section 2.3)

/// Whether `text` is what the controller, an array of a format string and its
/// arguments, formats to.
func validatePrintfText(_ target: Type2, _ controller: Type2, _ text: String) -> Result<Bool, SchemaFault> {
    guard case .array(let group, _, _, _) = controller else {
        return .failure(SchemaFault("invalid controller type for .printf operation: \(controller)"))
    }
    guard let groupChoice = group.groupChoices.first, !groupChoice.groupEntries.isEmpty else {
        return .failure(SchemaFault("printf controller array cannot be empty"))
    }

    var values: [Type2] = []
    for entry in groupChoice.groupEntries {
        if case .valueMemberKey(let ge, _, _, _) = entry.0 {
            if case .type1(let t1, _, _, _, _, _)? = ge.memberKey {
                values.append(t1.type2)
            } else {
                values.append(ge.entryType.typeChoices[0].type1.type2)
            }
        }
    }

    guard !values.isEmpty else {
        return .failure(SchemaFault("printf controller array cannot be empty"))
    }
    guard case .textValue(let format, _) = values[0] else {
        return .failure(SchemaFault("first element of printf controller array must be a format string"))
    }

    do {
        let expected = try formatPrintf(format, Array(values.dropFirst()))
        return .success(text.utf8.elementsEqual(expected.utf8))
    } catch let fault as SchemaFault {
        return .failure(fault)
    } catch {
        return .failure(SchemaFault("\(error)"))
    }
}

private func formatPrintf(_ format: String, _ args: [Type2]) throws -> String {
    var result = ""
    let chars = Array(format.unicodeScalars)
    var index = 0
    var argIndex = 0

    func peek() -> Unicode.Scalar? {
        index < chars.count ? chars[index] : nil
    }

    while index < chars.count {
        let ch = chars[index]
        index += 1
        if ch != "%" {
            result.unicodeScalars.append(ch)
            continue
        }
        if peek() == "%" {
            index += 1
            result += "%"
            continue
        }

        var flags = ""
        while let fc = peek(), fc == "-" || fc == "+" || fc == " " || fc == "0" || fc == "#" {
            flags.unicodeScalars.append(fc)
            index += 1
        }

        var width = ""
        while let wc = peek(), ("0"..."9").contains(wc) {
            width.unicodeScalars.append(wc)
            index += 1
        }

        var precision = ""
        if peek() == "." {
            index += 1
            while let pc = peek(), ("0"..."9").contains(pc) {
                precision.unicodeScalars.append(pc)
                index += 1
            }
        }

        guard let specifier = peek() else {
            throw SchemaFault("incomplete format specifier")
        }
        index += 1

        if argIndex >= args.count {
            throw SchemaFault(
                "not enough arguments for format string (expected at least \(argIndex + 1), got \(args.count))")
        }
        let arg = args[argIndex]
        argIndex += 1

        let widthValue: Int? = width.isEmpty ? nil : (Int(width) ?? 0)
        let precisionValue: Int? = precision.isEmpty ? nil : (Int(precision) ?? 0)

        let formatted = try formatSingleArg(arg, specifier, flags, precisionValue)
        result += applyWidthFlags(formatted, flags, widthValue)
    }

    return result
}

private func formatSingleArg(_ arg: Type2, _ specifier: Unicode.Scalar, _ flags: String, _ precision: Int?) throws -> String {
    switch specifier {
    case "d", "i":
        return try extractInt(arg).description
    case "u":
        return String(try extractUint(arg))
    case "x":
        let value = String(try extractUint(arg), radix: 16)
        return flags.contains("#") ? "0x" + value : value
    case "X":
        let value = String(try extractUint(arg), radix: 16, uppercase: true)
        return flags.contains("#") ? "0X" + value : value
    case "o":
        let value = String(try extractUint(arg), radix: 8)
        return flags.contains("#") ? "0" + value : value
    case "b", "B":
        return String(try extractUint(arg), radix: 2)
    case "f", "F":
        return fixedPrecision(try extractFloat(arg), precision ?? 6)
    case "e", "E":
        let text = exponentPrecision(try extractFloat(arg), precision ?? 6)
        return specifier == "E" ? text.replacingOccurrences(of: "e", with: "E") : text
    case "g", "G":
        let value = try extractFloat(arg)
        if let precision {
            return fixedPrecision(value, precision)
        }
        return floatDisplay(value)
    case "s":
        if case .textValue(let value, _) = arg {
            return value
        }
        throw SchemaFault("expected text string for %s conversion")
    case "c":
        let value = try extractUint(arg)
        if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: value)) {
            return String(scalar)
        }
        throw SchemaFault("invalid Unicode scalar value for %c: \(value)")
    default:
        throw SchemaFault("unsupported printf conversion specifier: %\(specifier)")
    }
}

/// A float with `precision` fraction digits.
private func fixedPrecision(_ value: Double, _ precision: Int) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-inf" : "inf" }
    return String(format: "%.\(precision)f", value)
}

/// A float in exponent notation with `precision` fraction digits, the exponent
/// written without sign padding (`1.50e3`, `1.00e-7`).
private func exponentPrecision(_ value: Double, _ precision: Int) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-inf" : "inf" }
    let text = String(format: "%.\(precision)e", value)
    guard let e = text.firstIndex(of: "e") else { return text }
    let mantissa = text[..<e]
    let exponent = Int(text[text.index(after: e)...]) ?? 0
    return mantissa + "e" + String(exponent)
}

private func extractInt(_ t: Type2) throws -> BigInt {
    switch t {
    case .intValue(let value, _): return value
    case .uintValue(let value, _): return BigInt(value)
    case .floatValue(let value, _, _): return saturatingInteger(value)
    default: throw SchemaFault("expected integer for printf, got \(t)")
    }
}

private func extractUint(_ t: Type2) throws -> UInt64 {
    switch t {
    case .uintValue(let value, _): return value
    case .intValue(let value, _) where value.sign == .plus || value.isZero:
        return UInt64(truncatingIfNeeded: value)
    case .floatValue(let value, _, _):
        if value.isNaN || value <= 0 { return 0 }
        if value >= 18446744073709551615.0 { return UInt64.max }
        return UInt64(value)
    default: throw SchemaFault("expected unsigned integer for printf, got \(t)")
    }
}

private func extractFloat(_ t: Type2) throws -> Double {
    switch t {
    case .floatValue(let value, _, _): return value
    case .intValue(let value, _): return Double(value)
    case .uintValue(let value, _): return Double(value)
    default: throw SchemaFault("expected number for printf, got \(t)")
    }
}

/// The integer a float converts to, saturating at the range of a signed
/// 128-bit integer, and zero for a NaN.
private func saturatingInteger(_ value: Double) -> BigInt {
    if value.isNaN { return 0 }
    if value >= 0x1p127 { return signedMax }
    if value <= -0x1p127 { return signedMin }
    return BigInt(value.rounded(.towardZero))
}

private func applyWidthFlags(_ raw: String, _ flags: String, _ width: Int?) -> String {
    guard let width, width > raw.utf8.count else {
        return raw
    }
    let padZero = flags.contains("0") && !flags.contains("-")
    if flags.contains("-") {
        let count = raw.unicodeScalars.count
        return raw + String(repeating: " ", count: max(0, width - count))
    }
    if padZero && (raw.hasPrefix("-") || raw.hasPrefix("+")) {
        let sign = String(raw.prefix(1))
        let rest = String(raw.dropFirst())
        let count = rest.unicodeScalars.count
        return sign + String(repeating: "0", count: max(0, width - 1 - count)) + rest
    }
    return String(repeating: padZero ? "0" : " ", count: width - raw.utf8.count) + raw
}

// MARK: - .json (RFC 9741 Section 2.4)

/// Whether `text` is JSON whose value the controller admits: a best-effort
/// structural match of the value's kind and of literals.
func validateJSONText(_ target: Type2, _ controller: Type2, _ text: String) -> Result<Bool, SchemaFault> {
    guard let value = parseJSONTopLevel(text) else {
        return .success(false)
    }
    return .success(jsonMatchesType2(value, controller))
}

/// A JSON number as it was written: an integer that fits 64 bits unsigned or
/// signed, or a float.
enum JSONNumberValue: Equatable {
    case unsigned(UInt64)
    case negative(Int64)
    case float(Double)

    var asUInt64: UInt64? {
        if case .unsigned(let v) = self { return v }
        return nil
    }

    var asInt64: Int64? {
        switch self {
        case .unsigned(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .negative(let v): return v
        case .float: return nil
        }
    }

    var asDouble: Double {
        switch self {
        case .unsigned(let v): return Double(v)
        case .negative(let v): return Double(v)
        case .float(let v): return v
        }
    }
}

/// The kind of the top-level value of a JSON document, with its content where
/// it is a scalar.
enum JSONTopLevel: Equatable {
    case null
    case bool(Bool)
    case number(JSONNumberValue)
    case string(String)
    case array
    case object
}

private func jsonMatchesType2(_ json: JSONTopLevel, _ t2: Type2) -> Bool {
    switch t2 {
    case .textValue(let value, _):
        if case .string(let s) = json { return s.utf8.elementsEqual(value.utf8) }
        return false
    case .intValue(let value, _):
        if case .number(let n) = json, let v = n.asInt64 { return BigInt(v) == value }
        return false
    case .uintValue(let value, _):
        if case .number(let n) = json { return n.asUInt64 == value }
        return false
    case .floatValue(let value, _, _):
        if case .number(let n) = json { return n.asDouble == value }
        return false
    case .typename(let ident, _, _):
        switch ident.ident {
        case "text", "tstr":
            if case .string = json { return true }
            return false
        case "uint":
            if case .number(let n) = json { return n.asUInt64 != nil }
            return false
        case "nint":
            if case .number(let n) = json { return n.asInt64.map { $0 < 0 } ?? false }
            return false
        case "int", "integer":
            if case .number(let n) = json {
                let v = n.asDouble
                return v - v.rounded(.towardZero) == 0
            }
            return false
        case "float", "float16", "float32", "float64", "float16-32", "float32-64", "number":
            if case .number = json { return true }
            return false
        case "bool":
            if case .bool = json { return true }
            return false
        case "true":
            return json == .bool(true)
        case "false":
            return json == .bool(false)
        case "null", "nil":
            return json == .null
        default:
            return true
        }
    case .map:
        return json == .object
    case .array:
        return json == .array
    default:
        return true
    }
}

/// Parses a JSON document (RFC 8259) and returns its top-level value, or `nil`
/// when the text is not well-formed JSON. Containers are checked for
/// well-formedness without recursion.
func parseJSONTopLevel(_ text: String) -> JSONTopLevel? {
    var parser = JSONScanner(Array(text.utf8))
    return parser.document()
}

private struct JSONScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func document() -> JSONTopLevel? {
        enum Container {
            case array
            case object
        }
        var stack: [Container] = []
        var top: JSONTopLevel?

        // The state of the innermost container: whether a value is expected
        // next, and whether a key is.
        skipWhitespace()
        var expectValue = true
        var expectKey = false
        var first = true

        while true {
            skipWhitespace()
            if expectKey {
                // In an object: a key or, for an empty object, the close.
                if first, index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    stack.removeLast()
                    expectKey = false
                    expectValue = false
                    first = false
                } else {
                    guard string() != nil else { return nil }
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                    index += 1
                    expectKey = false
                    expectValue = true
                    first = false
                    continue
                }
            } else if expectValue {
                guard index < bytes.count else { return nil }
                let c = bytes[index]
                var scalar: JSONTopLevel?
                switch c {
                case UInt8(ascii: "{"):
                    index += 1
                    if stack.isEmpty && top == nil { top = .object }
                    stack.append(.object)
                    expectKey = true
                    expectValue = false
                    first = true
                    continue
                case UInt8(ascii: "["):
                    index += 1
                    if stack.isEmpty && top == nil { top = .array }
                    stack.append(.array)
                    skipWhitespace()
                    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                        index += 1
                        stack.removeLast()
                        expectValue = false
                    }
                    continue
                case UInt8(ascii: "\""):
                    guard let s = string() else { return nil }
                    scalar = .string(s)
                case UInt8(ascii: "t"):
                    guard literal("true") else { return nil }
                    scalar = .bool(true)
                case UInt8(ascii: "f"):
                    guard literal("false") else { return nil }
                    scalar = .bool(false)
                case UInt8(ascii: "n"):
                    guard literal("null") else { return nil }
                    scalar = .null
                default:
                    guard let n = number() else { return nil }
                    scalar = .number(n)
                }
                if stack.isEmpty && top == nil {
                    top = scalar
                }
                expectValue = false
            }

            // After a value: the end of the document, a separator, or a close.
            skipWhitespace()
            guard let container = stack.last else {
                return index == bytes.count ? top : nil
            }
            guard index < bytes.count else { return nil }
            let c = bytes[index]
            index += 1
            switch (container, c) {
            case (.array, UInt8(ascii: ",")):
                expectValue = true
            case (.object, UInt8(ascii: ",")):
                expectKey = true
                first = false
            case (.array, UInt8(ascii: "]")), (.object, UInt8(ascii: "}")):
                stack.removeLast()
            default:
                return nil
            }
        }
    }

    mutating func literal(_ word: String) -> Bool {
        let w = Array(word.utf8)
        guard index + w.count <= bytes.count, bytes[index..<(index + w.count)].elementsEqual(w) else {
            return false
        }
        index += w.count
        return true
    }

    mutating func string() -> String? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        index += 1
        var out = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() -> Bool {
            if raw.isEmpty { return true }
            guard let text = String(validatingUTF8Bytes: raw) else { return false }
            out.append(contentsOf: text.unicodeScalars)
            raw = []
            return true
        }
        while index < bytes.count {
            let c = bytes[index]
            index += 1
            switch c {
            case UInt8(ascii: "\""):
                guard flush() else { return nil }
                return String(out)
            case UInt8(ascii: "\\"):
                guard flush(), index < bytes.count else { return nil }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "/"): out.append("/")
                case UInt8(ascii: "b"): out.append("\u{8}")
                case UInt8(ascii: "f"): out.append("\u{c}")
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "u"):
                    guard let unit = hex4() else { return nil }
                    if (0xd800...0xdbff).contains(unit) {
                        guard literal("\\u"), let low = hex4(), (0xdc00...0xdfff).contains(low) else { return nil }
                        let value = 0x10000 + ((UInt32(unit) - 0xd800) << 10) + (UInt32(low) - 0xdc00)
                        guard let scalar = Unicode.Scalar(value) else { return nil }
                        out.append(scalar)
                    } else if (0xdc00...0xdfff).contains(unit) {
                        return nil
                    } else {
                        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return nil }
                        out.append(scalar)
                    }
                default:
                    return nil
                }
            default:
                if c < 0x20 { return nil }
                raw.append(c)
            }
        }
        return nil
    }

    mutating func hex4() -> UInt16? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let c = bytes[index]
            index += 1
            let digit: UInt16
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(c - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    mutating func number() -> JSONNumberValue? {
        let start = index
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        func digits() -> Int {
            let from = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
            }
            return index - from
        }
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            return nil
        }
        var isFloat = false
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isFloat = true
            index += 1
            guard digits() > 0 else { return nil }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isFloat = true
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard digits() > 0 else { return nil }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if !isFloat {
            if negative, let v = Int64(text) {
                return .negative(v)
            }
            if !negative, let v = UInt64(text) {
                return .unsigned(v)
            }
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return .float(value)
    }
}

// MARK: - .join (RFC 9741 Section 3.1)

/// Whether `text` is the concatenation of the controller's components, the
/// known literal parts acting as markers between parts that vary.
func validateJoinText(_ target: Type2, _ controller: Type2, _ text: String, _ schema: Schema?) -> Result<Bool, SchemaFault> {
    guard case .array(let group, _, _, _) = controller else {
        return .failure(SchemaFault("invalid controller type for .join operation: \(controller)"))
    }
    guard let groupChoice = group.groupChoices.first else {
        return .success(text.isEmpty)
    }

    var parts: [String?] = []
    for entry in groupChoice.groupEntries {
        switch entry.0 {
        case .valueMemberKey(let ge, _, _, _):
            let t2: Type2
            if case .type1(let t1, _, _, _, _, _)? = ge.memberKey {
                t2 = t1.type2
            } else {
                t2 = ge.entryType.typeChoices[0].type1.type2
            }
            parts.append(extractStringValue(t2, schema))
        case .typeGroupname(let ge, _, _, _):
            parts.append(extractStringValue(.typename(ident: ge.name, genericArgs: ge.genericArgs), schema))
        case .inlineGroup:
            parts.append(nil)
        }
    }

    if parts.allSatisfy({ $0 != nil }) {
        let expected = parts.compactMap { $0 }.joined()
        return .success(text.utf8.elementsEqual(expected.utf8))
    }
    return .success(validateJoinWithMarkers(text, parts))
}

private func extractStringValue(_ t2: Type2, _ schema: Schema?) -> String? {
    switch t2 {
    case .textValue(let value, _):
        return value
    case .utf8ByteString(let value, _):
        return String(validatingUTF8Bytes: value)
    case .typename(let ident, _, _):
        if let schema, case .success(let literals) = stringLiteralsFromIdent(schema, ident), literals.count == 1 {
            return extractStringValue(literals[0], schema)
        }
        return nil
    default:
        return nil
    }
}

private func validateJoinWithMarkers(_ text: String, _ parts: [String?]) -> Bool {
    if parts.isEmpty {
        return text.isEmpty
    }
    if parts.allSatisfy({ $0 != nil }) {
        return text.utf8.elementsEqual(parts.compactMap { $0 }.joined().utf8)
    }

    let bytes = Array(text.utf8)
    var pos = 0
    for (i, part) in parts.enumerated() {
        if let literal = part {
            let marker = Array(literal.utf8)
            guard let found = firstOccurrence(of: marker, in: bytes, from: pos) else {
                return false
            }
            pos = found + marker.count
        } else if i + 1 >= parts.count {
            pos = bytes.count
        }
    }
    return pos == bytes.count
}

private func firstOccurrence(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
    if needle.isEmpty { return from }
    guard haystack.count >= needle.count, from <= haystack.count - needle.count else { return nil }
    for start in from...(haystack.count - needle.count)
    where haystack[start..<(start + needle.count)].elementsEqual(needle) {
        return start
    }
    return nil
}
