// Parser error types.

/// A parser error message: a short description, and optional extended
/// context.
struct ErrorMsg: Error, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Short message.
    var short: String
    /// Extended message with context and hints.
    var extended: String?

    /// An error message.
    init(short: String, extended: String? = nil) {
        self.short = short
        self.extended = extended
    }

    /// An error message of one of the fixed kinds.
    init(_ type: MsgType) {
        self = type.errorMsg
    }

    var description: String { short }

    /// Structured rendering, as embedded in the error's debug description.
    var debugDescription: String {
        let ext = extended.map { "Some(\(debugQuoted($0)))" } ?? "None"
        return "ErrorMsg { short: \(debugQuoted(short)), extended: \(ext) }"
    }
}

/// The fixed kinds of error message.
enum MsgType: Sendable, Hashable, CaseIterable {
    // Parser
    case duplicateRuleIdentifier
    case invalidRuleIdentifier
    case missingAssignmentToken
    case invalidGenericSyntax
    case missingGenericClosingDelimiter
    case invalidGenericIdentifier
    case invalidUnwrapSyntax
    case invalidGroupToChoiceEnumSyntax
    case invalidTagSyntax
    case missingGroupEntryMemberKey
    case missingGroupEntry
    case invalidGroupEntrySyntax
    case missingClosingDelimiter
    case missingClosingParend
    case invalidMemberKeyArrowMapSyntax
    case invalidMemberKeySyntax
    case invalidOccurrenceSyntax
    case noRulesDefined
    case incompleteRuleEntry
    case typeSocketNamesMustBeTypeAugmentations
    case groupSocketNamesMustBeGroupAugmentations

    // Lexer
    case unableToAdvanceToken
    case invalidControlOperator
    case invalidCharacter
    case invalidEscapeCharacter
    case invalidTextStringLiteralCharacter
    case emptyTextStringLiteral
    case invalidByteStringLiteralCharacter
    case emptyByteStringLiteral
    case unterminatedByteStringLiteral
    case invalidHexFloat
    case invalidExponent

    /// The message of this kind.
    var errorMsg: ErrorMsg {
        switch self {
        case .duplicateRuleIdentifier:
            return ErrorMsg(short: "rule with the same identifier is already defined")
        case .invalidRuleIdentifier:
            return ErrorMsg(short: "expected rule identifier followed by an assignment token '=', '/=' or '//='")
        case .missingAssignmentToken:
            return ErrorMsg(short: "expected assignment token '=', '/=' or '//=' after rule identifier")
        case .invalidGenericSyntax:
            return ErrorMsg(
                short: "generic parameters should be between angle brackets '<' and '>' and separated by a comma ','"
            )
        case .missingGenericClosingDelimiter:
            return ErrorMsg(short: "missing closing '>'")
        case .invalidGenericIdentifier:
            return ErrorMsg(short: "generic parameters must be named identifiers")
        case .invalidUnwrapSyntax:
            return ErrorMsg(short: "invalid unwrap syntax")
        case .invalidGroupToChoiceEnumSyntax:
            return ErrorMsg(short: "invalid group to choice enumeration syntax")
        case .invalidTagSyntax:
            return ErrorMsg(short: "invalid tag syntax")
        case .missingGroupEntryMemberKey:
            return ErrorMsg(short: "missing group entry member key")
        case .missingGroupEntry:
            return ErrorMsg(short: "missing group entry")
        case .invalidGroupEntrySyntax:
            return ErrorMsg(short: "invalid group entry syntax")
        case .missingClosingDelimiter:
            return ErrorMsg(short: "missing closing delimiter")
        case .missingClosingParend:
            return ErrorMsg(short: "missing closing parend ')'")
        case .invalidMemberKeyArrowMapSyntax:
            return ErrorMsg(short: "invalid memberkey. missing '=>'")
        case .invalidMemberKeySyntax:
            return ErrorMsg(short: "invalid memberkey. missing '=>' or ':'")
        case .invalidOccurrenceSyntax:
            return ErrorMsg(short: "invalid occurrence indicator syntax")
        case .unableToAdvanceToken:
            return ErrorMsg(short: "unable to advance to the next token")
        case .invalidControlOperator:
            return ErrorMsg(short: "invalid control operator")
        case .invalidCharacter:
            return ErrorMsg(short: "invalid character")
        case .invalidEscapeCharacter:
            return ErrorMsg(short: "invalid escape character")
        case .invalidTextStringLiteralCharacter:
            return ErrorMsg(short: "invalid character in text string literal. expected closing \"")
        case .emptyTextStringLiteral:
            return ErrorMsg(short: "empty text string literal")
        case .invalidByteStringLiteralCharacter:
            return ErrorMsg(short: "invalid character in byte string literal. expected closing '")
        case .emptyByteStringLiteral:
            return ErrorMsg(short: "empty byte string literal")
        case .unterminatedByteStringLiteral:
            return ErrorMsg(short: "unterminated byte string literal, missing closing '")
        case .noRulesDefined:
            return ErrorMsg(short: "you must have at least one rule defined")
        case .incompleteRuleEntry:
            return ErrorMsg(short: "missing rule entry after assignment")
        case .typeSocketNamesMustBeTypeAugmentations:
            return ErrorMsg(
                short: "all plugs for type socket names must be augmentations using '/=' (alternatively change the definition to be a group socket)"
            )
        case .groupSocketNamesMustBeGroupAugmentations:
            return ErrorMsg(
                short: "all plugs for group socket names must be augmentations using '//=' (alternatively change the definition to be a type socket)"
            )
        case .invalidHexFloat:
            return ErrorMsg(short: "invalid hexfloat")
        case .invalidExponent:
            return ErrorMsg(short: "invalid exponent")
        }
    }
}

/// Parsing error types.
enum ParserError: Error, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Parsing errors carrying only a message.
    case cddl(String)
    /// Parsing error at a position in the input.
    case parser(position: Position, msg: ErrorMsg)
    /// Regex error.
    case regex(String)

    /// `parsing error: position Position { .. }, msg: ..` for a positioned
    /// error.
    var description: String {
        switch self {
        case .cddl(let message):
            return message
        case .parser(let position, let msg):
            return "parsing error: position \(position.debugDescription), msg: \(msg.short)"
        case .regex(let message):
            return "regex parsing error: \(message)"
        }
    }

    /// Structured rendering, with the position and both messages.
    var debugDescription: String {
        switch self {
        case .cddl(let message):
            return "CDDL(\(debugQuoted(message)))"
        case .parser(let position, let msg):
            return "PARSER { position: \(position.debugDescription), msg: \(msg.debugDescription) }"
        case .regex(let message):
            return "REGEX(\(debugQuoted(message)))"
        }
    }
}

/// A string quoted for a structured rendering, with quotes, backslashes and
/// control characters escaped.
func debugQuoted(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\0": out += "\\0"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7f {
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
