// Byte-offset bookkeeping over a CDDL source, shared by the parser, the
// comment attachment pass and error reporting.

/// A CDDL source held as UTF-8 bytes, with a line index so that the line of
/// any byte offset is found in logarithmic time.
struct SourceText: Sendable {
    let bytes: [UInt8]
    /// Byte offsets of the start of every line after the first, that is one
    /// past every `\n`.
    private let lineBreaks: [Int]

    init(_ string: String) {
        self.init(bytes: Array(string.utf8))
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var breaks: [Int] = []
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            breaks.append(index + 1)
        }
        self.lineBreaks = breaks
    }

    var count: Int { bytes.count }

    /// The text of `start..<end`.
    func text(_ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The number of `\n` bytes before `offset`.
    func newlinesBefore(_ offset: Int) -> Int {
        // Count of line breaks `b` with `b <= offset` (a break at `b` means a
        // `\n` at `b - 1 < offset`).
        var low = 0
        var high = lineBreaks.count
        while low < high {
            let mid = (low + high) / 2
            if lineBreaks[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 1-based line of `offset`.
    func line(of offset: Int) -> Int {
        newlinesBefore(offset) + 1
    }

    /// Byte offset of the start of the line holding `offset`.
    func lineStart(of offset: Int) -> Int {
        let n = newlinesBefore(offset)
        return n == 0 ? 0 : lineBreaks[n - 1]
    }

    /// The number of characters in `start..<end`.
    func characterCount(_ start: Int, _ end: Int) -> Int {
        var count = 0
        for byte in bytes[start..<end] where byte & 0xC0 != 0x80 {
            count += 1
        }
        return count
    }

    /// The AST span of `start..<end`: `(start, end, line)`.
    func span(_ start: Int, _ end: Int) -> Span {
        Span(start, end, line(of: start))
    }

    /// Line and column (counted in characters) of `start`, with the range.
    func position(_ start: Int, _ end: Int) -> Position {
        let column = characterCount(lineStart(of: start), start) + 1
        return Position(line: line(of: start), column: column, range: (start, end), index: start)
    }

    /// Line and column of `offset`, reading `\r\n` as one line break.
    func lineColumnCountingCRLF(_ offset: Int) -> (Int, Int) {
        var line = 1
        var column = 1
        var index = 0
        while index < offset {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\r") {
                if index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\n") && index + 1 < offset {
                    index += 2
                    line += 1
                    column = 1
                } else if index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\n") {
                    // A `\r\n` straddling the offset still counts as a break.
                    index += 1
                    line += 1
                    column = 1
                } else {
                    index += 1
                    column += 1
                }
            } else if byte == UInt8(ascii: "\n") {
                index += 1
                line += 1
                column = 1
            } else {
                var width = 1
                if byte >= 0xF0 {
                    width = 4
                } else if byte >= 0xE0 {
                    width = 3
                } else if byte >= 0xC0 {
                    width = 2
                }
                index += width
                column += 1
            }
        }
        return (line, column)
    }
}
