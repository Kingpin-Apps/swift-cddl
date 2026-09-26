import Foundation

// How data items and numbers are written in validation messages.
//
// A message names the data item that failed to match. Two renderings are
// used: a structured one, which names the kind of each item (`Integer(5)`,
// `Text("a")`, `Array([...])`), and a compact one (`5`, `"a"`, `[...]`). Both
// are bounded in depth and in length, so a message about a deeply nested or a
// very large item stays small.

/// Nesting depth beyond which a data item is rendered as an ellipsis rather
/// than descended into.
let maxRenderedNestingDepth = 8

/// Upper bound on how much of a data item one error message renders, in bytes.
///
/// A message names the data item that failed to match, and a prefix of it
/// names it; rendering all of it would cost the length of the item, once for
/// every way of matching it that failed. The bound is on what the message
/// says, not on what is checked.
let maxRenderedDataLength = 256

/// What stands in a rendering for the part of it that was elided.
let elision = "..."

/// `text` cut short at ``maxRenderedDataLength`` bytes, on a character
/// boundary, and marked where the rest was elided.
func elided(_ text: String) -> String {
    let bytes = Array(text.utf8)
    if bytes.count <= maxRenderedDataLength {
        return text
    }
    var end = maxRenderedDataLength
    while end > 0 && bytes[end] & 0xc0 == 0x80 {
        end -= 1
    }
    return String(decoding: bytes[..<end], as: UTF8.self) + elision
}

// MARK: - Numbers

/// A float written as its shortest round-trip digits in full: `1` for 1.0,
/// `0.1`, `100000000000000000000` for 1e20, `NaN`, `inf`, `-inf`.
func floatDisplay(_ value: Double) -> String {
    plainDecimalDescription(value)
}

/// A float written as its shortest round-trip digits in the structured form:
/// plain decimal with at least one fraction digit between 1e-4 and 1e16
/// (`1.0`, `0.0001`, `100000.0`), exponent notation outside it (`1e300`,
/// `1e-7`), and `NaN`, `inf`, `-inf` for the values no digits denote.
func floatDebug(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value.sign == .minus ? "-inf" : "inf" }
    let magnitude = abs(value)
    if magnitude < 1e16 && (magnitude == 0 || magnitude >= 1e-4) {
        let plain = plainDecimalDescription(value)
        return plain.contains(".") ? plain : plain + ".0"
    }
    return exponentialDescription(value)
}

/// An integer of a data item in the structured form, `Integer(5)`.
func integerDebug(_ value: CBORInteger) -> String {
    "Integer(\(value))"
}

/// A byte string's content in the structured form, `[1, 2, 3]`.
func bytesDebug(_ bytes: [UInt8]) -> String {
    "[" + bytes.map { String($0) }.joined(separator: ", ") + "]"
}

/// Renders a byte string in the base16 literal notation `h'..'`, which can
/// denote content of any shape.
func base16Literal(_ bytes: [UInt8]) -> String {
    var out = "h'"
    out.reserveCapacity(bytes.count * 2 + 3)
    for byte in bytes {
        if byte < 16 { out.append("0") }
        out.append(String(byte, radix: 16))
    }
    out.append("'")
    return out
}

// MARK: - Text

/// Whether a scalar is written as itself in a quoted rendering: everything but
/// the controls, format characters, separators other than the space, private
/// use, unassigned code points and marks that extend a grapheme.
private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    let properties = scalar.properties
    if properties.isGraphemeExtend {
        return false
    }
    switch properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
        return false
    case .spaceSeparator:
        return scalar == " "
    default:
        return true
    }
}

/// `text` quoted for a structured rendering: `"` and `\` escaped, and every
/// scalar that is not printable written as `\u{..}`.
func debugString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\0": out += "\\0"
        default:
            if isPrintable(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            }
        }
    }
    return out + "\""
}

// MARK: - Data items

extension CBORNode {
    /// The node in the structured rendering validation messages name a data
    /// item by, bounded in depth and length.
    var debugRendering: String {
        var out = ""
        writeDebug(self, depth: 0, into: &out)
        return elided(out)
    }

    /// The node in the compact rendering, bounded in depth.
    var displayRendering: String {
        var out = ""
        writeDisplay(self, depth: 0, into: &out)
        return out
    }
}

/// A check that stops a rendering once it has run past the length it will be
/// cut to, so that rendering a large item costs no more than the bound.
private func pastBound(_ out: String) -> Bool {
    out.utf8.count > maxRenderedDataLength + 4
}

private func writeDebug(_ node: CBORNode, depth: Int, into out: inout String) {
    if pastBound(out) { return }
    switch node {
    case .unsigned, .negative:
        out += "Integer(" + integerDebug(node.integerValue!) + ")"
    case .byteString(let bytes, _):
        out += "Bytes(["
        for (idx, byte) in bytes.enumerated() {
            if idx > 0 { out += ", " }
            out += String(byte)
            if pastBound(out) { return }
        }
        out += "])"
    case .float(let value, _):
        out += "Float(" + floatDebug(value) + ")"
    case .textString(let text, _):
        out += "Text(" + debugString(text) + ")"
    case .bool(let value):
        out += "Bool(\(value))"
    case .null, .undefined:
        out += "Null"
    case .simple(let value):
        out += "Simple(\(value))"
    case .tagged(let tagged):
        if depth < maxRenderedNestingDepth {
            out += "Tag(\(tagged.tag), "
            writeDebug(tagged.content, depth: depth + 1, into: &out)
            out += ")"
        } else {
            out += "Tag(\(tagged.tag), ...)"
        }
    case .array(let array):
        if depth < maxRenderedNestingDepth {
            out += "Array(["
            for (idx, item) in array.items.enumerated() {
                if idx > 0 { out += ", " }
                writeDebug(item, depth: depth + 1, into: &out)
                if pastBound(out) { return }
            }
            out += "])"
        } else {
            out += "Array(...)"
        }
    case .map(let map):
        if depth < maxRenderedNestingDepth {
            out += "Map(["
            for (idx, entry) in map.entries.enumerated() {
                if idx > 0 { out += ", " }
                out += "("
                writeDebug(entry.key, depth: depth + 1, into: &out)
                out += ", "
                writeDebug(entry.value, depth: depth + 1, into: &out)
                out += ")"
                if pastBound(out) { return }
            }
            out += "])"
        } else {
            out += "Map(...)"
        }
    }
}

private func writeDisplay(_ node: CBORNode, depth: Int, into out: inout String) {
    switch node {
    case .unsigned, .negative:
        out += integerDebug(node.integerValue!)
    case .byteString(let bytes, _):
        out += base16Literal(bytes)
    case .float(let value, _):
        out += floatDisplay(value)
    case .textString(let text, _):
        out += "\"" + text + "\""
    case .bool(let value):
        out += String(value)
    case .null, .undefined:
        out += "null"
    case .simple(let value):
        out += "simple(\(value))"
    case .tagged(let tagged):
        if depth < maxRenderedNestingDepth {
            out += "\(tagged.tag)("
            writeDisplay(tagged.content, depth: depth + 1, into: &out)
            out += ")"
        } else {
            out += "\(tagged.tag)(...)"
        }
    case .array(let array):
        if depth < maxRenderedNestingDepth {
            out += "["
            for (idx, item) in array.items.enumerated() {
                if idx > 0 { out += ", " }
                writeDisplay(item, depth: depth + 1, into: &out)
            }
            out += "]"
        } else {
            out += "[...]"
        }
    case .map(let map):
        if depth < maxRenderedNestingDepth {
            out += "{"
            for (idx, entry) in map.entries.enumerated() {
                if idx > 0 { out += ", " }
                writeDisplay(entry.key, depth: depth + 1, into: &out)
                out += ": "
                writeDisplay(entry.value, depth: depth + 1, into: &out)
            }
            out += "}"
        } else {
            out += "{...}"
        }
    }
}

/// A CBOR map key rendered as a path component, in the notation a CDDL
/// literal for the same data item is written in, so that the key can be found
/// in the document and matched against the member key that describes it. A
/// composite key has no compact literal notation and is rendered in the
/// structured form.
func formatPathKey(_ key: CBORNode) -> String {
    switch key {
    case .textString(let text, _):
        return "\"" + text + "\""
    case .unsigned, .negative:
        return key.integerValue!.description
    case .float(let value, _):
        return FloatLiteral(value).description
    case .byteString(let bytes, _):
        return base16Literal(bytes)
    case .bool(let value):
        return String(value)
    case .null, .undefined:
        return "null"
    default:
        return key.debugRendering
    }
}
