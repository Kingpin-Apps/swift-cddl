import Foundation

// Regular expressions for the `.regexp` (RFC 8610 Section 3.8.3), `.pcre`
// and `.iregexp` (RFC 9485) control operators.

/// A compiled regular expression.
struct ControlRegex: @unchecked Sendable {
    private let expression: NSRegularExpression

    /// Why a pattern does not compile.
    struct CompileError: Error {
        var message: String
    }

    /// Compiles `pattern`, or says why it does not compile.
    ///
    /// Only `\n` ends a line: `.` matches every other character, `\r`
    /// included. Outside multi-line mode `$` matches at the end of the text
    /// only, never before a newline that ends it, so a pattern anchored at
    /// both ends holds the whole of the text to it (RFC 8610 Section 3.8.3,
    /// RFC 9485).
    static func compile(_ pattern: String) -> Result<ControlRegex, CompileError> {
        do {
            let expression = try NSRegularExpression(
                pattern: anchoringDollarAtEndOfText(renamingCaptureGroups(pattern)),
                options: [.useUnixLineSeparators]
            )
            return .success(ControlRegex(expression: expression))
        } catch {
            return .failure(CompileError(message: "regex parse error: \(error.localizedDescription)"))
        }
    }

    /// Whether the expression matches somewhere in `text`.
    func isMatch(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }
}

/// `pattern` with every named capture group given a name the matcher accepts.
///
/// A group name may carry underscores and be written `(?P<name>...)` as well
/// as `(?<name>...)`, and a back reference to it `\k<name>` or `(?P=name)`;
/// the matcher accepts only letters and digits, in the `(?<name>...)` and
/// `\k<name>` forms. The name of a group does not change what the expression
/// matches, so each is replaced by one of its own, consistently, and a pattern
/// naming no group is returned as it is.
func renamingCaptureGroups(_ pattern: String) -> String {
    guard pattern.contains("(?") || pattern.contains("\\k<") else { return pattern }
    let scalars = Array(pattern.unicodeScalars)

    var names: [String: String] = [:]
    func rename(_ name: String) -> String {
        if let renamed = names[name] {
            return renamed
        }
        let renamed = "cddlgroup\(names.count)"
        names[name] = renamed
        return renamed
    }

    /// The name that runs from `start` up to `terminator`, and the index after
    /// the terminator.
    func readName(_ start: Int, _ terminator: Unicode.Scalar) -> (String, Int)? {
        var end = start
        while end < scalars.count && scalars[end] != terminator {
            end += 1
        }
        guard end < scalars.count, end > start else { return nil }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: scalars[start..<end])
        return (String(name), end + 1)
    }

    func matches(_ index: Int, _ text: String) -> Bool {
        let expected = Array(text.unicodeScalars)
        guard index + expected.count <= scalars.count else { return false }
        return scalars[index..<(index + expected.count)].elementsEqual(expected)
    }

    var out = String.UnicodeScalarView()
    var classDepth = 0
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\\" {
            if classDepth == 0, matches(index, "\\k<"), let (name, next) = readName(index + 3, ">") {
                out.append(contentsOf: "\\k<\(rename(name))>".unicodeScalars)
                index = next
                continue
            }
            out.append(scalar)
            if index + 1 < scalars.count {
                out.append(scalars[index + 1])
            }
            index += 2
            continue
        }
        if scalar == "[" {
            classDepth += 1
        } else if scalar == "]" && classDepth > 0 {
            classDepth -= 1
        } else if classDepth == 0 && scalar == "(" {
            if matches(index, "(?P<"), let (name, next) = readName(index + 4, ">") {
                out.append(contentsOf: "(?<\(rename(name))>".unicodeScalars)
                index = next
                continue
            }
            if matches(index, "(?P="), let (name, next) = readName(index + 4, ")") {
                out.append(contentsOf: "(?:\\k<\(rename(name))>)".unicodeScalars)
                index = next
                continue
            }
            if matches(index, "(?<"), !matches(index, "(?<="), !matches(index, "(?<!"),
                let (name, next) = readName(index + 3, ">")
            {
                out.append(contentsOf: "(?<\(rename(name))>".unicodeScalars)
                index = next
                continue
            }
        }
        out.append(scalar)
        index += 1
    }
    return String(out)
}

/// `pattern` with every `$` that anchors outside multi-line mode made to match
/// at the very end of the text only.
///
/// Left to itself the matcher lets such a `$` match before a newline that
/// ends the text too, so `^[a-z]+$` would accept `"abc\n"`. A pattern that
/// turns multi-line mode on anywhere is returned as it is: there `$` matches
/// before every newline, as it should.
func anchoringDollarAtEndOfText(_ pattern: String) -> String {
    guard pattern.contains("$") else { return pattern }
    let scalars = Array(pattern.unicodeScalars)
    if enablesMultiLineMode(scalars) {
        return pattern
    }

    var out = String.UnicodeScalarView()
    var classDepth = 0
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\\" {
            out.append(scalar)
            if index + 1 < scalars.count {
                out.append(scalars[index + 1])
            }
            index += 2
            continue
        }
        if scalar == "[" {
            classDepth += 1
            out.append(scalar)
            index += 1
            // A `]` straight after the opening bracket, or after its `^`,
            // stands for itself.
            if index < scalars.count && scalars[index] == "^" {
                out.append(scalars[index])
                index += 1
            }
            if index < scalars.count && scalars[index] == "]" {
                out.append(scalars[index])
                index += 1
            }
            continue
        }
        if scalar == "]" && classDepth > 0 {
            classDepth -= 1
        } else if scalar == "$" && classDepth == 0 {
            out.append(contentsOf: "\\z".unicodeScalars)
            index += 1
            continue
        }
        out.append(scalar)
        index += 1
    }
    return String(out)
}

/// Whether an inline flag group of `scalars` -- `(?m)`, `(?im:...)` and the
/// like -- turns multi-line mode on.
private func enablesMultiLineMode(_ scalars: [Unicode.Scalar]) -> Bool {
    var index = 0
    while index + 1 < scalars.count {
        if scalars[index] == "\\" {
            index += 2
            continue
        }
        if scalars[index] == "(" && scalars[index + 1] == "?" {
            var flag = index + 2
            while flag < scalars.count, scalars[flag].properties.isAlphabetic {
                if scalars[flag] == "m" {
                    return true
                }
                flag += 1
            }
        }
        index += 1
    }
    return false
}
