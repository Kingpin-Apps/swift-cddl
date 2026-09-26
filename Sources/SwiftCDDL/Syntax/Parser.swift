import BigInt
import Foundation

// The public parsing entry points, the conversion of the parse tree into the AST,
// the duplicate-rule check, the undefined-reference check and the rendering
// of parse errors.

// MARK: - Public entry points

/// Parses CDDL text into its AST.
///
/// This is a syntactic parse that also
/// rejects a rule redefined with a plain `=`. References to undefined rules
/// are not checked; see ``CDDL/fromSlice(_:)`` for that.
///
/// - Parameters:
///   - input: The CDDL text.
///   - printStderr: When true, a parse failure is also rendered to standard
///     error as a source-annotated diagnostic.
func cddlFromStr(_ input: String, printStderr: Bool = false) throws(ParserError) -> CDDL {
    do {
        return try parseCDDL(input)
    } catch {
        if printStderr {
            FileHandle.standardError.write(Data(renderParserError(error, input: input).utf8))
        }
        throw error
    }
}

extension CDDL {
    /// Parses CDDL from UTF-8 bytes.
    ///
    /// This performs both syntactic parsing and the check that all referenced
    /// type and group names are defined (by a rule, the standard prelude, a
    /// generic parameter, or as a socket).
    static func fromSlice(_ input: [UInt8]) throws(ParserError) -> CDDL {
        guard let text = String(validatingUTF8Bytes: input) else {
            throw .cddl(utf8ErrorDescription(input))
        }
        return try parseCDDLChecked(text)
    }

    /// Parses CDDL from UTF-8 data; see ``fromSlice(_:)-(Array<UInt8>)``.
    static func fromSlice(_ input: Data) throws(ParserError) -> CDDL {
        try fromSlice([UInt8](input))
    }
}

/// Identifies the root type name of a CDDL document: the first type rule that
/// takes no generic parameters.
func rootTypeNameFromCDDLStr(_ input: String) throws(ParserError) -> String {
    let cddl = try cddlFromStr(input)
    for rule in cddl.rules {
        if case .type(let rule, _, _, _) = rule, rule.genericParams == nil {
            return rule.name.description
        }
    }
    throw .cddl("cddl spec contains no root type")
}

/// Parses CDDL from a string into its AST.
func parseCDDL(_ input: String) throws(ParserError) -> CDDL {
    try withLargeStack { () -> Result<CDDL, ParserError> in
        do throws(ParserError) {
            return .success(try parseCDDLOnCurrentThread(input))
        } catch {
            return .failure(error)
        }
    }.get()
}

private func parseCDDLOnCurrentThread(_ input: String) throws(ParserError) -> CDDL {
    let source = SourceText(input)
    let root = try parseDocument(source)
    var (cddl, orphans) = try convertCDDLWithOrphans(root, source)
    attachComments(&cddl, source, orphans: orphans)
    return cddl
}

/// Parses CDDL and checks for undefined references.
func parseCDDLChecked(_ input: String) throws(ParserError) -> CDDL {
    try withLargeStack { () -> Result<CDDL, ParserError> in
        do throws(ParserError) {
            return .success(try parseCDDLCheckedOnCurrentThread(input))
        } catch {
            return .failure(error)
        }
    }.get()
}

private func parseCDDLCheckedOnCurrentThread(_ input: String) throws(ParserError) -> CDDL {
    let source = SourceText(input)
    let root = try parseDocument(source)
    var (cddl, orphans) = try convertCDDLWithOrphans(root, source)
    attachComments(&cddl, source, orphans: orphans)

    if let (name, position) = findFirstUndefinedReference(root, source) {
        throw .parser(position: position, msg: ErrorMsg(short: "missing definition for rule \(name)"))
    }
    return cddl
}

/// Runs the grammar over the whole document and returns the `cddl` pair.
func parseDocument(_ source: SourceText) throws(ParserError) -> Pair {
    let state = GrammarState(input: source.bytes)
    guard state.cddl(), let root = state.pairs().first else {
        throw convertGrammarFailure(state.failure(), source)
    }
    return root
}

/// Parses `literal` with the `number` production alone, returning the rule
/// the number matched as and the number of bytes matched. For the grammar
/// tests only.
func parseNumberProduction(_ literal: String) -> (GrammarRule, Int)? {
    let state = GrammarState(input: Array(literal.utf8))
    guard state.number(), let number = state.pairs().first, let inner = number.children.first else {
        return nil
    }
    return (inner.rule, number.end - number.start)
}

/// Whether the whole of `input` parses with the grammar, without building the
/// AST. For the grammar tests only.
func grammarAccepts(_ input: String) -> Bool {
    withLargeStack {
        let state = GrammarState(input: Array(input.utf8))
        return state.cddl()
    }
}

func utf8ErrorDescription(_ bytes: [UInt8]) -> String {
    // "invalid utf-8 sequence of N bytes from index I" or
    // "incomplete utf-8 byte sequence from index I".
    var index = 0
    while index < bytes.count {
        let lead = bytes[index]
        let width: Int
        if lead < 0x80 {
            width = 1
        } else if lead >= 0xC2 && lead <= 0xDF {
            width = 2
        } else if lead >= 0xE0 && lead <= 0xEF {
            width = 3
        } else if lead >= 0xF0 && lead <= 0xF4 {
            width = 4
        } else {
            return "invalid utf-8 sequence of 1 bytes from index \(index)"
        }
        if index + width > bytes.count {
            return "incomplete utf-8 byte sequence from index \(index)"
        }
        if String(validatingUTF8Bytes: Array(bytes[index..<(index + width)])) == nil {
            return "invalid utf-8 sequence of 1 bytes from index \(index)"
        }
        index += width
    }
    return "invalid utf-8"
}

// MARK: - Errors

/// Converts a grammar failure into a parser error with a user-friendly
/// message naming the rules expected at the furthest point reached.
func convertGrammarFailure(_ failure: GrammarFailure, _ source: SourceText) -> ParserError {
    let index = failure.position
    let (line, column) = source.lineColumnCountingCRLF(index)

    let range = computeErrorRange(index, source.bytes)

    let adjLine: Int
    let adjColumn: Int
    if range.0 < index {
        let position = source.position(range.0, range.0)
        adjLine = position.line
        adjColumn = position.column
    } else {
        adjLine = line
        adjColumn = column
    }

    let friendlyPositives = failure.positives.compactMap(friendlyRuleName)
    let friendlyNegatives = failure.negatives.compactMap(friendlyRuleName)

    let short: String
    if !friendlyPositives.isEmpty {
        if friendlyPositives.count == 1 {
            short = "expected \(friendlyPositives[0])"
        } else {
            short = "expected one of: \(friendlyPositives.joined(separator: ", "))"
        }
    } else if !friendlyNegatives.isEmpty {
        short = "unexpected \(friendlyNegatives.joined(separator: ", "))"
    } else {
        short = "syntax error"
    }

    var extended: String?
    if !friendlyPositives.isEmpty || !friendlyNegatives.isEmpty {
        var context = "At line \(line), column \(column): "
        if !friendlyPositives.isEmpty {
            context += "Expected " + friendlyPositives.joined(separator: " or ") + "."
            if friendlyPositives.contains(where: { $0.contains("assignment") }) {
                context += "\n\nHint: Every rule needs an assignment operator ('=' for new rules, '/=' for type alternatives, or '//=' for group alternatives)."
            } else if friendlyPositives.contains(where: { $0.contains("type") }) {
                context += "\n\nHint: Make sure your type expression is complete and properly formatted."
            } else if friendlyPositives.contains(where: { $0.contains("group") }) {
                context += "\n\nHint: Group definitions should contain valid group entries."
            }
        }
        if !friendlyNegatives.isEmpty {
            if !context.isEmpty {
                context += " "
            }
            context += "Did not expect " + friendlyNegatives.joined(separator: " or ") + "."
        }
        extended = context
    }

    return .parser(
        position: Position(line: adjLine, column: adjColumn, range: range, index: range.0),
        msg: ErrorMsg(short: short, extended: extended)
    )
}

@inline(__always)
private func isASCIIWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
}

@inline(__always)
private func isTokenByte(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
        || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_")
        || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "$")
        || c == UInt8(ascii: "@")
}

/// A byte range for an error at `index`: the visible token there, or else the
/// token before it.
func computeErrorRange(_ index: Int, _ bytes: [UInt8]) -> (Int, Int) {
    if index < bytes.count {
        let ch = bytes[index]
        if !isASCIIWhitespace(ch) && ch != UInt8(ascii: ";") {
            let end = scanTokenEnd(bytes, index)
            if end > index {
                return (index, end)
            }
        }
    }

    if index > 0 {
        var pos = index
        while pos > 0 {
            pos -= 1
            let ch = bytes[pos]
            if !isASCIIWhitespace(ch) && ch != UInt8(ascii: ";") {
                return (scanTokenStart(bytes, pos), pos + 1)
            }
        }
    }

    return (index, index)
}

private func scanTokenEnd(_ bytes: [UInt8], _ start: Int) -> Int {
    var pos = start
    if pos >= bytes.count {
        return pos
    }
    let first = bytes[pos]
    let isAlnum = (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
        || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z"))
        || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9"))
    if isAlnum || first == UInt8(ascii: "_") || first == UInt8(ascii: "$") || first == UInt8(ascii: "@") {
        while pos < bytes.count && isTokenByte(bytes[pos]) {
            pos += 1
        }
    } else {
        pos += 1
    }
    return pos
}

private func scanTokenStart(_ bytes: [UInt8], _ pos: Int) -> Int {
    guard isTokenByte(bytes[pos]) else { return pos }
    var start = pos
    while start > 0 && isTokenByte(bytes[start - 1]) {
        start -= 1
    }
    return start
}

/// Maps grammar rule names to user-friendly descriptions.
func friendlyRuleName(_ rule: GrammarRule) -> String? {
    switch rule {
    case .cddl: return "CDDL specification"
    case .rule: return "rule definition"
    case .typename: return "type name"
    case .groupname: return "group name"
    case .assign: return "assignment operator '='"
    case .assign_t: return "type assignment ('=' or '/=')"
    case .assign_g: return "group assignment ('=' or '//=')"
    case .assign_t_choice: return "type choice assignment '/='"
    case .assign_g_choice: return "group choice assignment '//='"
    case .generic_params: return "generic parameters '<...>'"
    case .generic_param: return "generic parameter"
    case .generic_args: return "generic arguments '<...>'"
    case .generic_arg: return "generic argument"
    case .type_expr: return "type expression"
    case .type_choice: return "type choice"
    case .type_choice_op: return "type choice operator '/'"
    case .type1: return "type"
    case .type2: return "type value"
    case .range_op: return "range operator ('..' or '...')"
    case .range_op_inclusive: return "inclusive range '..'"
    case .range_op_exclusive: return "exclusive range '...'"
    case .control_op: return "control operator"
    case .control_name: return "control operator name"
    case .controller: return "control argument"
    case .group: return "group definition"
    case .group_choice: return "group choice"
    case .group_entry: return "group entry"
    case .optcom: return "entry separator ','"
    case .arrowmap: return "member key delimiter '=>'"
    case .colon: return "member key delimiter ':'"
    case .occur: return "occurrence indicator"
    case .occur_optional: return "optional '?'"
    case .occur_zero_or_more: return "zero or more '*'"
    case .occur_one_or_more: return "one or more '+'"
    case .occur_exact: return "exact occurrence"
    case .occur_range: return "occurrence range"
    case .member_key: return "member key"
    case .bareword: return "bareword identifier"
    case .value: return "value"
    case .number: return "number"
    case .int_value: return "integer"
    case .uint_value: return "unsigned integer"
    case .float_value: return "floating-point number"
    case .hexfloat: return "hexadecimal float"
    case .text_value: return "text string"
    case .bytes_value: return "byte string"
    case .bytes_b16: return "base16 byte string"
    case .bytes_b64: return "base64 byte string"
    case .bytes_utf8: return "unqualified byte string"
    case .bytes_h_quoted: return "hex-quoted byte string"
    case .tag_expr: return "tag expression"
    case .id: return "identifier"
    case .socket_type: return "type socket '$'"
    case .socket_group: return "group socket '$$'"
    case .COMMENT, .S, .EOI: return nil
    default: return "\(rule)"
    }
}

/// Renders a parser error as a source-annotated diagnostic against the input
/// it was produced from, without colour escapes: a header, the source line
/// with the error position underlined, and the extended message as a note.
///
/// Returns the plain error message for an error that carries no position in
/// the input.
func renderParserError(_ error: ParserError, input: String) -> String {
    guard case .parser(let position, let msg) = error else {
        return error.description
    }

    let source = SourceText(input)
    let start = min(max(position.range.0, 0), source.count)
    let end = min(max(position.range.1, start), source.count)
    let lineNumber = source.line(of: start)
    let lineStart = source.lineStart(of: start)
    var lineEnd = lineStart
    while lineEnd < source.count && source.bytes[lineEnd] != UInt8(ascii: "\n") {
        lineEnd += 1
    }
    let lineText = source.text(lineStart, lineEnd)
    let column = source.characterCount(lineStart, start) + 1
    let caretCount = max(1, source.characterCount(start, min(end, lineEnd)))

    let gutter = String(lineNumber)
    let pad = String(repeating: " ", count: gutter.count)
    var out = "error: parser errors\n"
    out += "\(pad) ┌─ input:\(lineNumber):\(column)\n"
    out += "\(pad) │\n"
    out += "\(gutter) │ \(lineText)\n"
    out += "\(pad) │ \(String(repeating: " ", count: column - 1))\(String(repeating: "^", count: caretCount)) \(msg.short)\n"
    if let extended = msg.extended {
        out += "\(pad) │\n"
        let lines = extended.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            out += index == 0 ? "\(pad) = \(line)\n" : "\(pad)   \(line)\n"
        }
    }
    out += "\n"
    return out
}

// MARK: - Literal parsing

/// Parses a CDDL uint literal as `UInt64`, including the RFC 8610 radix forms.
func parseU64Literal(_ s: String) -> UInt64? {
    let bytes = Array(s.utf8)
    if bytes.count >= 2 && bytes[0] == UInt8(ascii: "0") {
        if bytes[1] == UInt8(ascii: "x") || bytes[1] == UInt8(ascii: "X") {
            return parseUnsignedDigits(bytes[2...], radix: 16).flatMap { UInt64(exactly: $0) }
        }
        if bytes[1] == UInt8(ascii: "b") || bytes[1] == UInt8(ascii: "B") {
            return parseUnsignedDigits(bytes[2...], radix: 2).flatMap { UInt64(exactly: $0) }
        }
    }
    return parseUnsignedDigits(bytes[...], radix: 10).flatMap { UInt64(exactly: $0) }
}

/// Parses a CDDL int literal (`["-"] uint`, radix forms included), accepting
/// only the CBOR integer range `-2^64 ... 2^64-1`.
func parseIntLiteral(_ s: String) -> BigInt? {
    let bytes = Array(s.utf8)
    if bytes.first == UInt8(ascii: "-") {
        let rest = bytes[1...]
        let magnitude: BigUInt?
        if rest.count >= 2 && rest[rest.startIndex] == UInt8(ascii: "0")
            && (rest[rest.startIndex + 1] == UInt8(ascii: "x") || rest[rest.startIndex + 1] == UInt8(ascii: "X"))
        {
            magnitude = parseUnsignedDigits(rest.dropFirst(2), radix: 16)
        } else if rest.count >= 2 && rest[rest.startIndex] == UInt8(ascii: "0")
            && (rest[rest.startIndex + 1] == UInt8(ascii: "b") || rest[rest.startIndex + 1] == UInt8(ascii: "B"))
        {
            magnitude = parseUnsignedDigits(rest.dropFirst(2), radix: 2)
        } else {
            magnitude = parseUnsignedDigits(rest, radix: 10)
        }
        guard let magnitude else { return nil }
        // The magnitude must not exceed 2^64 (RFC 8949 major type 1).
        if magnitude.bitWidth > 128 || magnitude > (BigUInt(1) << 64) {
            return nil
        }
        return -BigInt(magnitude)
    }
    return parseU64Literal(s).map { BigInt($0) }
}

/// Parses an unsigned integer in `radix`: an optional `+`, then at least one
/// digit of the radix.
func parseUnsignedDigits(_ digits: ArraySlice<UInt8>, radix: Int) -> BigUInt? {
    var slice = digits
    if slice.first == UInt8(ascii: "+") {
        slice = slice.dropFirst()
    }
    guard !slice.isEmpty else { return nil }
    var value = BigUInt(0)
    for c in slice {
        let digit: Int
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): digit = Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): digit = Int(c - UInt8(ascii: "A")) + 10
        default: return nil
        }
        guard digit < radix else { return nil }
        value = value * BigUInt(radix) + BigUInt(digit)
        if value.bitWidth > 130 {
            // Far beyond every range the callers accept.
            return value
        }
    }
    return value
}

/// Unescapes a text literal body (supports RFC 9682 `\u{hex}` escapes and
/// surrogate pairs). An unknown escape is kept as written.
func unescapeText(_ text: String) -> String {
    let chars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    var index = 0

    func parseHex(_ scalars: [Unicode.Scalar]) -> UInt32? {
        var bytes: [UInt8] = []
        for s in scalars {
            guard s.isASCII else { return nil }
            bytes.append(UInt8(s.value))
        }
        guard let value = parseUnsignedDigits(bytes[...], radix: 16), value.bitWidth <= 32 else {
            return nil
        }
        return UInt32(value)
    }

    while index < chars.count {
        let ch = chars[index]
        index += 1
        guard ch == "\\" else {
            result.append(ch)
            continue
        }
        guard index < chars.count else { continue }
        let next = chars[index]
        index += 1
        switch next {
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        case "\\": result.append("\\")
        case "\"": result.append("\"")
        case "'": result.append("'")
        case "/": result.append("/")
        case "b": result.append("\u{08}")
        case "f": result.append("\u{0C}")
        case "u":
            if index < chars.count && chars[index] == "{" {
                index += 1
                var hex: [Unicode.Scalar] = []
                while index < chars.count {
                    let c = chars[index]
                    index += 1
                    if c == "}" { break }
                    hex.append(c)
                }
                if let code = parseHex(hex), let scalar = Unicode.Scalar(code) {
                    result.append(scalar)
                }
            } else {
                let hex = Array(chars[index..<min(index + 4, chars.count)])
                index += hex.count
                if let code = parseHex(hex) {
                    if (0xD800...0xDBFF).contains(code) {
                        if index + 1 < chars.count && chars[index] == "\\" && chars[index + 1] == "u" {
                            index += 2
                            let lowHex = Array(chars[index..<min(index + 4, chars.count)])
                            index += lowHex.count
                            if let low = parseHex(lowHex), (0xDC00...0xDFFF).contains(low) {
                                let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                                if let scalar = Unicode.Scalar(combined) {
                                    result.append(scalar)
                                }
                            }
                        }
                    } else if let scalar = Unicode.Scalar(code) {
                        result.append(scalar)
                    }
                }
            }
        default:
            result.append("\\")
            result.append(next)
        }
    }
    return String(result)
}

/// Checks that a float literal's digits denote a value the float type holds.
private func finiteFloatLiteral(_ value: Double) -> Result<Double, ErrorMsg> {
    if value.isFinite {
        return .success(value)
    }
    return .failure(ErrorMsg(short: "Float literal out of range for a 64-bit float"))
}

/// Decodes mixed-case hex (base16) bytes.
func hexDecode(_ input: [UInt8]) -> [UInt8]? {
    guard input.count % 2 == 0 else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(input.count / 2)
    var index = 0
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
    while index < input.count {
        guard let high = nibble(input[index]), let low = nibble(input[index + 1]) else { return nil }
        output.append(high << 4 | low)
        index += 2
    }
    return output
}

/// Decodes base64 bytes in either the base64 or the base64url alphabet
/// (RFC 4648 §4 and §5), rejecting a literal that mixes the two. Padding is
/// optional; when present it must be canonical, and the unused trailing bits
/// must be zero.
func base64Decode(_ input: [UInt8]) -> Result<[UInt8], ErrorMsg> {
    let usesClassic = input.contains(UInt8(ascii: "+")) || input.contains(UInt8(ascii: "/"))
    let usesURL = input.contains(UInt8(ascii: "-")) || input.contains(UInt8(ascii: "_"))
    if usesClassic && usesURL {
        return .failure(ErrorMsg(short: "Base64 literal mixes the RFC 4648 base64 and base64url alphabets"))
    }
    let padded = input.contains(UInt8(ascii: "="))
    let invalid = ErrorMsg(short: "Invalid base64 encoding")

    func sextet(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return c - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return c - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return usesClassic ? 62 : nil
        case UInt8(ascii: "/"): return usesClassic ? 63 : nil
        case UInt8(ascii: "-"): return usesClassic ? nil : 62
        case UInt8(ascii: "_"): return usesClassic ? nil : 63
        default: return nil
        }
    }

    var body = input[...]
    if padded {
        // Padded encodings take whole four-character blocks, the last one
        // holding at most two `=` at its end.
        guard input.count % 4 == 0 else { return .failure(invalid) }
        var padding = 0
        while let last = body.last, last == UInt8(ascii: "=") {
            body = body.dropLast()
            padding += 1
        }
        guard padding <= 2 else { return .failure(invalid) }
        if body.contains(UInt8(ascii: "=")) { return .failure(invalid) }
        // The padding must be exactly what the final block needs.
        let remainder = body.count % 4
        let expectedPadding = remainder == 0 ? 0 : 4 - remainder
        guard padding == expectedPadding else { return .failure(invalid) }
    }
    guard body.count % 4 != 1 else { return .failure(invalid) }

    var output: [UInt8] = []
    var buffer: UInt32 = 0
    var bits = 0
    for c in body {
        guard let value = sextet(c) else { return .failure(invalid) }
        buffer = buffer << 6 | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
        }
    }
    // Trailing bits left over from the final partial block must be zero.
    if bits > 0 && buffer & ((1 << UInt32(bits)) - 1) != 0 {
        return .failure(invalid)
    }
    return .success(output)
}

/// Removes whitespace and comments from the content of a prefixed byte string
/// (RFC 8610 §3.1).
func cleanPrefixedByteString(_ content: String) -> String {
    var cleaned = String.UnicodeScalarView()
    var inComment = false
    for c in content.unicodeScalars {
        if inComment {
            if c == "\n" { inComment = false }
            continue
        }
        if c == ";" {
            inComment = true
        } else if !c.properties.isWhitespace {
            cleaned.append(c)
        }
    }
    return String(cleaned)
}

// MARK: - Parse tree to AST

/// The byte offsets, of the `;`, of comments the anchor merge did not bind.
typealias OrphanOffsets = [Int]

/// Converts the `cddl` pair to the AST, returning also the comments the
/// anchor merge could not bind.
func convertCDDLWithOrphans(_ pair: Pair, _ source: SourceText) throws(ParserError) -> (CDDL, OrphanOffsets) {
    var rules: [Rule] = []
    var ruleSpans: [(Int, Int)] = []

    let commentToks = collectCommentToks(pair, source)

    let converter = PairConverter(source: source)
    for inner in pair.children {
        switch inner.rule {
        case .rule:
            ruleSpans.append((inner.start, inner.end))
            rules.append(try converter.convertRule(inner))
        case .EOI:
            break
        default:
            continue
        }
        if inner.rule == .EOI { break }
    }

    // Bind comments to AST nodes by a source-order merge.
    var anchors: [Anchor] = []
    visitAnchorSlots(&rules, source) { pos, kind, _ in
        anchors.append(Anchor(pos: pos, kind: kind))
    }
    let containers = collectContainerExtents(rules)
    let (assigned, orphans) = mergeComments(commentToks, anchors, containers)
    let orphanStarts = orphans.map(\.lo)
    var anchorIndex = 0
    visitAnchorSlots(&rules, source) { _, _, slot in
        if !assigned[anchorIndex].isEmpty {
            slot = Comments(assigned[anchorIndex])
        }
        anchorIndex += 1
    }

    // Duplicate rule names (non-alternate rules). A late plain `=` after a
    // `/=` or `//=` of the same name is a duplicate too.
    var seenNames: Set<String> = []
    var incrementalNames: Set<String> = []
    for (idx, rule) in rules.enumerated() {
        let name = rule.name()
        if rule.isChoiceAlternate() {
            incrementalNames.insert(name)
        } else {
            if seenNames.contains(name) || incrementalNames.contains(name) {
                throw .parser(
                    position: ruleDeclarationPosition(ruleSpans[idx], source),
                    msg: ErrorMsg(short: "rule \"\(name)\" is already defined")
                )
            }
            seenNames.insert(name)
        }
    }

    return (CDDL(rules: rules, comments: nil, nesting: bracketNesting(source.bytes)), orphanStarts)
}

/// Position of a rule declaration, less the whitespace the parse tree takes in
/// after it.
private func ruleDeclarationPosition(_ span: (Int, Int), _ source: SourceText) -> Position {
    var position = source.position(span.0, span.1)
    var end = span.1
    while end > span.0, let scalarEnd = trailingWhitespaceStart(source.bytes, end), scalarEnd >= span.0 {
        end = scalarEnd
    }
    position.range.1 = max(end, position.range.0)
    return position
}

/// If the bytes before `end` end in a Unicode whitespace scalar, the offset
/// where that scalar starts.
private func trailingWhitespaceStart(_ bytes: [UInt8], _ end: Int) -> Int? {
    guard end > 0 else { return nil }
    var start = end - 1
    while start > 0 && bytes[start] & 0xC0 == 0x80 {
        start -= 1
    }
    guard let text = String(validatingUTF8Bytes: Array(bytes[start..<end])),
        let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1,
        scalar.properties.isWhitespace
    else {
        return nil
    }
    return start
}

/// Converts parse tree pairs to AST nodes.
struct PairConverter {
    let source: SourceText

    private func str(_ pair: Pair) -> String {
        source.text(pair.start, pair.end)
    }

    private func span(_ pair: Pair) -> Span {
        source.span(pair.start, pair.end)
    }

    private func position(_ pair: Pair) -> Position {
        source.position(pair.start, pair.end)
    }

    private func error(_ short: String) -> ParserError {
        .parser(position: Position(), msg: ErrorMsg(short: short))
    }

    func convertRule(_ pair: Pair) throws(ParserError) -> Rule {
        let span = self.span(pair)
        guard let first = pair.children.first else {
            throw error("Empty rule")
        }
        let inner = pair.children.dropFirst()

        switch first.rule {
        case .typename:
            let name = try convertIdentifier(first)
            var genericParams: GenericParams?
            var isTypeChoiceAlternate = false
            var value: Type?
            for p in inner {
                switch p.rule {
                case .generic_params:
                    genericParams = try convertGenericParams(p)
                case .assign_t:
                    if p.children.contains(where: { $0.rule == .assign_t_choice }) {
                        isTypeChoiceAlternate = true
                    }
                case .type_expr:
                    value = try convertTypeExpr(p)
                default:
                    break
                }
            }
            guard let value else {
                throw error("Missing type expression in type rule")
            }
            return .type(
                rule: TypeRule(
                    name: name,
                    genericParams: genericParams,
                    isTypeChoiceAlternate: isTypeChoiceAlternate,
                    value: value
                ),
                span: span
            )
        case .groupname:
            let name = try convertIdentifier(first)
            var genericParams: GenericParams?
            var isGroupChoiceAlternate = false
            var entry: GroupEntry?
            for p in inner {
                switch p.rule {
                case .generic_params:
                    genericParams = try convertGenericParams(p)
                case .assign_g:
                    if p.children.contains(where: { $0.rule == .assign_g_choice }) {
                        isGroupChoiceAlternate = true
                    }
                case .group_entry:
                    entry = try convertGroupEntry(p)
                default:
                    break
                }
            }
            guard let entry else {
                throw error("Missing group entry in group rule")
            }
            return .group(
                rule: GroupRule(
                    name: name,
                    genericParams: genericParams,
                    isGroupChoiceAlternate: isGroupChoiceAlternate,
                    entry: entry
                ),
                span: span
            )
        default:
            throw error("Unexpected rule type: \(first.rule)")
        }
    }

    /// Converts a `typename` or `groupname` pair.
    func convertIdentifier(_ pair: Pair) throws(ParserError) -> Identifier {
        var socket: SocketPlug?
        var ident = str(pair)
        for inner in pair.children {
            switch inner.rule {
            case .socket_type: socket = .type
            case .socket_group: socket = .group
            case .id: ident = str(inner)
            default: break
            }
        }
        return Identifier(ident: ident, socket: socket, span: span(pair))
    }

    func convertGenericParams(_ pair: Pair) throws(ParserError) -> GenericParams {
        var params: [GenericParam] = []
        for inner in pair.children where inner.rule == .generic_param {
            for idPair in inner.children where idPair.rule == .id {
                params.append(GenericParam(param: Identifier(ident: str(idPair), socket: nil, span: span(idPair))))
            }
        }
        return GenericParams(params: params, span: span(pair))
    }

    func convertGenericArgs(_ pair: Pair) throws(ParserError) -> GenericArgs {
        var args: [GenericArg] = []
        for inner in pair.children where inner.rule == .generic_arg {
            for type1Pair in inner.children where type1Pair.rule == .type1 {
                args.append(GenericArg(arg: try convertType1(type1Pair)))
            }
        }
        return GenericArgs(args: args, span: span(pair))
    }

    func convertTypeExpr(_ pair: Pair) throws(ParserError) -> Type {
        var typeChoices: [TypeChoice] = []
        for inner in pair.children where inner.rule == .type_choice {
            for type1Pair in inner.children where type1Pair.rule == .type1 {
                typeChoices.append(TypeChoice(type1: try convertType1(type1Pair)))
            }
        }
        return Type(typeChoices: typeChoices, span: span(pair))
    }

    func convertType1(_ pair: Pair) throws(ParserError) -> Type1 {
        var type2: Type2?
        var op: Operator?

        for inner in pair.children {
            switch inner.rule {
            case .type2:
                if type2 == nil {
                    type2 = try convertType2(inner)
                }
            case .range_op:
                let isInclusive = inner.children.contains { $0.rule == .range_op_inclusive }
                op = Operator(
                    operator: .rangeOp(isInclusive: isInclusive, span: span(inner)),
                    type2: .any(span: .zero)
                )
            case .control_op:
                let ctrl = try convertControlOperator(inner)
                op = Operator(operator: .ctlOp(ctrl: ctrl, span: span(inner)), type2: .any(span: .zero))
            case .controller:
                for controllerInner in inner.children where controllerInner.rule == .type2 {
                    if op != nil {
                        op!.type2 = try convertType2(controllerInner)
                    }
                }
            default:
                break
            }
        }

        // Fill in the second type2 of a range operator.
        if var filled = op, case .any = filled.type2 {
            let type2Pairs = pair.children.filter { $0.rule == .type2 }
            if type2Pairs.count > 1 {
                filled.type2 = try convertType2(type2Pairs[1])
                op = filled
            }
        }

        guard let type2 else {
            throw error("Missing type2 in type1")
        }
        return Type1(type2: type2, operator: op, span: span(pair))
    }

    func convertControlOperator(_ pair: Pair) throws(ParserError) -> ControlOperator {
        for inner in pair.children where inner.rule == .control_name {
            let ctrlStr = str(inner)
            guard let ctrl = lookupControlFromStr(".\(ctrlStr)") else {
                throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid control operator: \(ctrlStr)"))
            }
            return ctrl
        }
        throw error("Missing control operator name")
    }

    func convertType2(_ pair: Pair) throws(ParserError) -> Type2 {
        let span = self.span(pair)
        // Which alternative matched is read from the leading character, since
        // literal tokens leave no pair of their own.
        var first = pair.start
        while first < pair.end && source.bytes[first].isASCIIWhitespaceOrOther {
            first += 1
        }
        let lead: UInt8 = first < pair.end ? source.bytes[first] : 0

        switch lead {
        case UInt8(ascii: "~"):
            var ident: Identifier?
            var genericArgs: GenericArgs?
            for inner in pair.children {
                switch inner.rule {
                case .typename: ident = try convertIdentifier(inner)
                case .generic_args: genericArgs = try convertGenericArgs(inner)
                default: break
                }
            }
            guard let ident else {
                throw error("Missing identifier in unwrap expression")
            }
            return .unwrap(ident: ident, genericArgs: genericArgs, span: span)
        case UInt8(ascii: "&"):
            var groupChild: Group?
            var groupnameIdent: Identifier?
            var genericArgs: GenericArgs?
            for inner in pair.children {
                switch inner.rule {
                case .group: groupChild = try convertGroup(inner)
                case .groupname: groupnameIdent = try convertIdentifier(inner)
                case .generic_args: genericArgs = try convertGenericArgs(inner)
                default: break
                }
            }
            if let group = groupChild {
                return .choiceFromInlineGroup(group: group, span: span)
            } else if let ident = groupnameIdent {
                return .choiceFromGroup(ident: ident, genericArgs: genericArgs, span: span)
            }
            throw error("Invalid choice-from-group expression")
        case UInt8(ascii: "("):
            for inner in pair.children where inner.rule == .type_expr {
                return .parenthesizedType(pt: try convertTypeExpr(inner), span: span)
            }
            return .any(span: span)
        case UInt8(ascii: "{"):
            for inner in pair.children where inner.rule == .group {
                return .map(group: try convertGroup(inner), span: span)
            }
            return .any(span: span)
        case UInt8(ascii: "["):
            for inner in pair.children where inner.rule == .group {
                return .array(group: try convertGroup(inner), span: span)
            }
            return .any(span: span)
        case UInt8(ascii: "#"):
            for inner in pair.children where inner.rule == .tag_expr {
                return try convertTagExpr(inner)
            }
            return .any(span: span)
        default:
            var valuePair: Pair?
            var typenameIdent: Identifier?
            var genericArgs: GenericArgs?
            for inner in pair.children {
                switch inner.rule {
                case .value: valuePair = inner
                case .typename: typenameIdent = try convertIdentifier(inner)
                case .generic_args: genericArgs = try convertGenericArgs(inner)
                default: break
                }
            }
            if let vp = valuePair {
                return try convertValueToType2(vp, span: span)
            } else if let ident = typenameIdent {
                return .typename(ident: ident, genericArgs: genericArgs, span: span)
            }
            return .any(span: span)
        }
    }

    func convertValueToType2(_ pair: Pair, span: Span) throws(ParserError) -> Type2 {
        for inner in pair.children {
            switch inner.rule {
            case .number:
                return try convertNumberToType2(inner, span: span)
            case .text_value:
                let bytes = source.bytes[(inner.start + 1)..<(inner.end - 1)]
                let content = String(decoding: bytes, as: UTF8.self)
                return .textValue(value: unescapeText(content), span: span)
            case .bytes_value:
                return try convertBytesValueToType2(inner, span: span)
            default:
                break
            }
        }
        throw error("Invalid value")
    }

    func convertNumberToType2(_ pair: Pair, span: Span) throws(ParserError) -> Type2 {
        for inner in pair.children {
            let text = str(inner)
            switch inner.rule {
            case .uint_value:
                guard let value = parseU64Literal(text) else {
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid unsigned integer"))
                }
                return .uintValue(value: value, span: span)
            case .int_value:
                guard let value = parseIntLiteral(text) else {
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid integer"))
                }
                return .intValue(value: value, span: span)
            case .float_value:
                guard let parsed = parseDecimalFloat(text) else {
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid float"))
                }
                switch finiteFloatLiteral(parsed) {
                case .success(let value):
                    return .floatValue(value: value, notation: FloatNotation(literal: text), span: span)
                case .failure(let msg):
                    throw .parser(position: position(inner), msg: msg)
                }
            case .hexfloat:
                guard let parsed = parseHexf64(text.lowercased()) else {
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid hexfloat"))
                }
                switch finiteFloatLiteral(parsed) {
                case .success(let value):
                    return .floatValue(value: value, notation: FloatNotation(literal: text), span: span)
                case .failure(let msg):
                    throw .parser(position: position(inner), msg: msg)
                }
            default:
                break
            }
        }
        throw error("Invalid number")
    }

    func convertBytesValueToType2(_ pair: Pair, span: Span) throws(ParserError) -> Type2 {
        for inner in pair.children {
            switch inner.rule {
            case .bytes_utf8:
                let content = source.text(inner.start + 1, inner.end - 1)
                return .utf8ByteString(value: Array(unescapeText(content).utf8), span: span)
            case .bytes_b16:
                let content = source.text(inner.start + 2, inner.end - 1)
                let cleaned = cleanPrefixedByteString(content)
                guard let decoded = hexDecode(Array(cleaned.utf8)) else {
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid base16 encoding"))
                }
                return .b16ByteString(value: decoded, span: span)
            case .bytes_b64:
                let content = source.text(inner.start + 4, inner.end - 1)
                let cleaned = cleanPrefixedByteString(content)
                switch base64Decode(Array(cleaned.utf8)) {
                case .success(let decoded):
                    return .b64ByteString(value: decoded, span: span)
                case .failure(let msg):
                    throw .parser(position: position(inner), msg: msg)
                }
            case .bytes_h_quoted:
                let content = Array(source.bytes[(inner.start + 2)..<(inner.end - 1)])
                return .utf8ByteString(value: content, span: span)
            default:
                break
            }
        }
        throw error("Invalid bytes value")
    }

    func convertTagExpr(_ pair: Pair) throws(ParserError) -> Type2 {
        let span = self.span(pair)
        let fullStr = str(pair).trimmingWhitespace()

        if fullStr == "#" {
            return .any(span: span)
        }

        let afterHash = fullStr.utf8.dropFirst()
        var majorType: UInt8?
        if let c = afterHash.first, c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
            majorType = c - UInt8(ascii: "0")
        }

        var tagConstraint: TagConstraint?
        var typeExpr: Type?

        for inner in pair.children {
            switch inner.rule {
            case .tag_value:
                for tv in inner.children {
                    switch tv.rule {
                    case .uint_value:
                        guard let val = parseU64Literal(str(tv)) else {
                            throw .parser(
                                position: position(tv),
                                msg: ErrorMsg(short: "Tag number out of range: \(str(tv))")
                            )
                        }
                        tagConstraint = .literal(val)
                    case .type_expr:
                        tagConstraint = .type(str(tv))
                    default:
                        break
                    }
                }
            case .type_expr:
                typeExpr = try convertTypeExpr(inner)
            default:
                break
            }
        }

        switch majorType {
        case 6:
            let t = typeExpr ?? Type(typeChoices: [], span: .zero)
            return .taggedData(tag: tagConstraint, t: t, span: span)
        case .some(let mt):
            return .dataMajorType(mt: mt, constraint: tagConstraint, span: span)
        case nil:
            if let t = typeExpr {
                return .taggedData(tag: nil, t: t, span: span)
            }
            return .any(span: span)
        }
    }

    func convertGroup(_ pair: Pair) throws(ParserError) -> Group {
        var groupChoices: [GroupChoice] = []
        for inner in pair.children where inner.rule == .group_choice {
            groupChoices.append(try convertGroupChoice(inner))
        }
        return Group(groupChoices: groupChoices, span: span(pair))
    }

    func convertGroupChoice(_ pair: Pair) throws(ParserError) -> GroupChoice {
        var groupEntries: [(GroupEntry, OptionalComma)] = []
        // An `optcom` separator follows the entry it terminates.
        for inner in pair.children {
            switch inner.rule {
            case .group_entry:
                groupEntries.append((try convertGroupEntry(inner), OptionalComma(optionalComma: false)))
            case .optcom:
                if !groupEntries.isEmpty {
                    groupEntries[groupEntries.count - 1].1.optionalComma = true
                }
            default:
                break
            }
        }
        return GroupChoice(groupEntries: groupEntries, span: span(pair))
    }

    func convertGroupEntry(_ pair: Pair) throws(ParserError) -> GroupEntry {
        let span = self.span(pair)

        var occur: Occurrence?
        var memberKey: MemberKey?
        var entryType: Type?
        var groupnameIdent: Identifier?
        var genericArgs: GenericArgs?
        var inlineGroup: Group?

        // The cut child follows the member key child, so it is read first.
        let isCut = pair.children.contains { $0.rule == .cut }

        for inner in pair.children {
            switch inner.rule {
            case .occur:
                occur = try convertOccurrence(inner)
            case .member_key:
                memberKey = try convertMemberKeySimple(inner, isCut: isCut, span: span)
            case .type_expr:
                entryType = try convertTypeExpr(inner)
            case .groupname:
                groupnameIdent = try convertIdentifier(inner)
            case .generic_args:
                genericArgs = try convertGenericArgs(inner)
            case .group:
                inlineGroup = try convertGroup(inner)
            default:
                break
            }
        }

        if let group = inlineGroup {
            return .inlineGroup(occur: occur, group: group, span: span)
        }

        if let name = groupnameIdent {
            return .typeGroupname(
                ge: TypeGroupnameEntry(occur: occur, name: name, genericArgs: genericArgs),
                span: span
            )
        }

        // A single typename with no type choices and no operator is a
        // reference to a named type or group.
        if memberKey == nil, let et = entryType, et.typeChoices.count == 1 {
            let tc = et.typeChoices[0]
            if tc.type1.operator == nil, case .typename(let ident, let genericArgs, _) = tc.type1.type2 {
                return .typeGroupname(
                    ge: TypeGroupnameEntry(occur: occur, name: ident, genericArgs: genericArgs),
                    span: span
                )
            }
        }

        return .valueMemberKey(
            ge: ValueMemberKeyEntry(
                occur: occur,
                memberKey: memberKey,
                entryType: entryType ?? Type(typeChoices: [], span: .zero)
            ),
            span: span
        )
    }

    func convertOccurrence(_ pair: Pair) throws(ParserError) -> Occurrence {
        for inner in pair.children {
            let occur: Occur
            switch inner.rule {
            case .occur_optional:
                occur = .optional(span: span(inner))
            case .occur_zero_or_more:
                occur = .zeroOrMore(span: span(inner))
            case .occur_one_or_more:
                occur = .oneOrMore(span: span(inner))
            case .occur_exact, .occur_range:
                let occurStr = str(inner)

                func parseBound(_ bound: String) throws(ParserError) -> UInt64 {
                    guard let bound = parseU64Literal(bound) else {
                        throw .parser(
                            position: position(inner),
                            msg: ErrorMsg(short: "Occurrence bound out of range: \(bound)")
                        )
                    }
                    return bound
                }

                // "n*" means "n or more".
                if occurStr.hasSuffix("*") && !occurStr.contains("**") {
                    var trimmed = Substring(occurStr)
                    while trimmed.hasSuffix("*") {
                        trimmed = trimmed.dropLast()
                    }
                    let bound = String(trimmed).trimmingWhitespace()
                    if !bound.isEmpty {
                        return Occurrence(
                            occur: .exact(lower: try parseBound(bound), upper: nil, span: span(inner))
                        )
                    }
                }

                // "n*m", "*m" or "n*".
                let parts = occurStr.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                let lowerText = parts[0].trimmingWhitespace()
                let lower: UInt64? = lowerText.isEmpty ? nil : try parseBound(lowerText)
                var upper: UInt64?
                if parts.count > 1 {
                    let upperText = parts[1].trimmingWhitespace()
                    if !upperText.isEmpty {
                        upper = try parseBound(upperText)
                    }
                }
                occur = .exact(lower: lower, upper: upper, span: span(inner))
            default:
                continue
            }
            return Occurrence(occur: occur)
        }
        throw error("Invalid occurrence indicator")
    }

    func convertMemberKeySimple(_ pair: Pair, isCut: Bool, span: Span) throws(ParserError) -> MemberKey {
        for inner in pair.children {
            switch inner.rule {
            case .type1:
                // The grammar only produces a type1 child behind the "=>"
                // lookahead, so this is always the arrow form.
                return .type1(t1: try convertType1(inner), isCut: isCut, span: span)
            case .bareword:
                return .bareword(
                    ident: Identifier(ident: str(inner), socket: nil, span: self.span(inner)),
                    span: span
                )
            case .typename:
                return .bareword(ident: try convertIdentifier(inner), span: span)
            case .value:
                let valueType2 = try convertValueToType2(inner, span: span)
                let value: Value
                switch valueType2 {
                case .intValue(let v, _): value = .int(v)
                case .uintValue(let v, _): value = .uint(v)
                case .floatValue(let v, let notation, _): value = .float(FloatLiteralValue(v, notation: notation))
                case .textValue(let v, _): value = .text(v)
                default:
                    throw .parser(position: position(inner), msg: ErrorMsg(short: "Invalid member key value"))
                }
                return .value(value: value, span: span)
            default:
                break
            }
        }
        throw error("Invalid member key")
    }
}

extension UInt8 {
    /// Whether `trim_start` would drop this byte at the start of a pair; only
    /// ASCII whitespace can start a pair's text in practice.
    fileprivate var isASCIIWhitespaceOrOther: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D || self == 0x0B || self == 0x0C
    }
}

// MARK: - Undefined references

/// Walks a successful parse tree to find the first reference to a name that
/// no rule defines, that is not in the standard prelude, not a generic
/// parameter and not a socket.
func findFirstUndefinedReference(_ root: Pair, _ source: SourceText) -> (String, Position)? {
    let prelude = Set(standardPrelude)
    var defined: Set<String> = []
    var ruleGenericParams: [Int: Set<String>] = [:]

    func collectDefinitions(_ pair: Pair) {
        if pair.rule == .rule {
            var genericParamsForRule: Set<String> = []
            for inner in pair.children {
                switch inner.rule {
                case .typename, .groupname:
                    for idPair in inner.children where idPair.rule == .id {
                        defined.insert(source.text(idPair.start, idPair.end))
                    }
                case .generic_params:
                    for gp in inner.children where gp.rule == .generic_param {
                        for idPair in gp.children where idPair.rule == .id {
                            genericParamsForRule.insert(source.text(idPair.start, idPair.end))
                        }
                    }
                default:
                    break
                }
            }
            if !genericParamsForRule.isEmpty {
                ruleGenericParams[pair.start] = genericParamsForRule
            }
        }
        for inner in pair.children {
            collectDefinitions(inner)
        }
    }
    collectDefinitions(root)

    var currentRuleGenerics: Set<String>?
    var result: (String, Position)?

    func checkReference(_ pair: Pair) {
        if pair.children.contains(where: { $0.rule == .socket_type || $0.rule == .socket_group }) {
            return
        }
        for idPair in pair.children where idPair.rule == .id {
            let name = source.text(idPair.start, idPair.end)
            if defined.contains(name) || prelude.contains(name) || currentRuleGenerics?.contains(name) == true {
                return
            }
            if name.hasPrefix("$") {
                return
            }
            result = (name, source.position(idPair.start, idPair.end))
        }
    }

    func walk(_ pair: Pair) {
        if result != nil { return }

        if pair.rule == .rule {
            let generics = ruleGenericParams[pair.start]
            let previous = currentRuleGenerics
            currentRuleGenerics = generics
            for inner in pair.children {
                walk(inner)
                if result != nil { return }
            }
            currentRuleGenerics = previous
            return
        }

        switch pair.rule {
        case .type2:
            for inner in pair.children {
                if inner.rule == .typename || inner.rule == .groupname {
                    checkReference(inner)
                    if result != nil { return }
                }
                walk(inner)
                if result != nil { return }
            }
            return
        case .group_entry:
            for inner in pair.children {
                if inner.rule == .groupname {
                    checkReference(inner)
                    if result != nil { return }
                }
                walk(inner)
                if result != nil { return }
            }
            return
        default:
            break
        }

        for inner in pair.children {
            walk(inner)
            if result != nil { return }
        }
    }

    walk(root)
    return result
}
