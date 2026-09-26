import BigInt

// Type expressions: `Type`, `TypeChoice`, `Type1`, `Operator`, `RangeCtlOp`
// and `Type2`.

/// Type choices.
///
/// ```abnf
/// type = type1 *(S "/" S  type1)
/// ```
public struct Type: Hashable, Sendable {
    /// Type choices.
    public var typeChoices: [TypeChoice]
    /// Span.
    public var span: Span

    /// A type.
    public init(typeChoices: [TypeChoice] = [], span: Span = .zero) {
        self.typeChoices = typeChoices
        self.span = span
    }

    /// Takes all the comments after a type. Useful when the type is consumed
    /// to build another type object.
    mutating func takeCommentsAfterType() -> Comments? {
        guard let last = typeChoices.indices.last,
            let comments = typeChoices[last].type1.commentsAfterType,
            comments.anyNonNewline()
        else {
            return nil
        }
        typeChoices[last].type1.commentsAfterType = nil
        return comments
    }

    /// Leaves the first comment after a type as part of its parent; the
    /// subsequent comments are returned as following the type.
    mutating func splitCommentsAfterType() -> Comments? {
        guard let last = typeChoices.indices.last else { return nil }
        guard var comments = typeChoices[last].type1.commentsAfterType,
            comments.anyNonNewline(), comments.comments.count > 1
        else {
            return nil
        }
        let drained = Array(comments.comments[1...])
        comments.comments.removeSubrange(1...)
        typeChoices[last].type1.commentsAfterType = comments
        return Comments(drained)
    }

    /// Used to delineate between a group entry with `Type` and a group entry
    /// with a group name identifier `id`.
    func groupnameEntry() -> (Identifier, GenericArgs?, Span)? {
        guard typeChoices.count == 1, let tc = typeChoices.first, tc.type1.operator == nil else {
            return nil
        }
        if case .typename(let ident, let genericArgs, let span) = tc.type1.type2 {
            return (ident, genericArgs, span)
        }
        return nil
    }
}

/// Type choice.
public struct TypeChoice: Hashable, Sendable {
    /// Type choice.
    public var type1: Type1
    /// Comments before the choice.
    public var commentsBeforeType: Comments?
    /// Comments after the choice.
    public var commentsAfterType: Comments?

    /// A type choice.
    public init(type1: Type1, commentsBeforeType: Comments? = nil, commentsAfterType: Comments? = nil) {
        self.type1 = type1
        self.commentsBeforeType = commentsBeforeType
        self.commentsAfterType = commentsAfterType
    }
}

/// Type with optional range or control operator.
///
/// ```abnf
/// type1 = type2 [S (rangeop / ctlop) S type2]
/// ```
public struct Type1: Hashable, Sendable {
    /// Type.
    public var type2: Type2
    /// Range or control operator over a second type.
    public var `operator`: Operator?
    /// Span.
    public var span: Span
    /// Comments after the type.
    public var commentsAfterType: Comments?

    /// A type1.
    public init(type2: Type2, operator: Operator? = nil, span: Span = .zero, commentsAfterType: Comments? = nil) {
        self.type2 = type2
        self.operator = `operator`
        self.span = span
        self.commentsAfterType = commentsAfterType
    }

    /// A type1 holding a literal value.
    public init(value: Value) {
        let span = Span.zero
        let type2: Type2
        switch value {
        case .text(let value): type2 = .textValue(value: value, span: span)
        case .int(let value): type2 = .intValue(value: value, span: span)
        case .float(let float): type2 = .floatValue(value: float.value, notation: float.notation, span: span)
        case .uint(let value): type2 = .uintValue(value: value, span: span)
        case .byte(.b16(let value)): type2 = .b16ByteString(value: value, span: span)
        case .byte(.b64(let value)): type2 = .b64ByteString(value: value, span: span)
        case .byte(.utf8(let value)): type2 = .utf8ByteString(value: value, span: span)
        }
        self.init(type2: type2, operator: nil, span: span, commentsAfterType: nil)
    }
}

/// Range or control operator applied to a type.
public struct Operator: Hashable, Sendable {
    /// Operator.
    public var `operator`: RangeCtlOp
    /// Type bound by the range or control operator.
    public var type2: Type2
    /// Comments before the operator.
    public var commentsBeforeOperator: Comments?
    /// Comments after the operator.
    public var commentsAfterOperator: Comments?

    /// An operator.
    public init(
        operator: RangeCtlOp,
        type2: Type2,
        commentsBeforeOperator: Comments? = nil,
        commentsAfterOperator: Comments? = nil
    ) {
        self.operator = `operator`
        self.type2 = type2
        self.commentsBeforeOperator = commentsBeforeOperator
        self.commentsAfterOperator = commentsAfterOperator
    }
}

/// Range or control operator.
///
/// ```abnf
/// rangeop = "..." / ".."
/// ctlop = "." id
/// ```
public enum RangeCtlOp: Hashable, Sendable {
    /// Range operator.
    case rangeOp(isInclusive: Bool, span: Span = .zero)
    /// Control operator.
    case ctlOp(ctrl: ControlOperator, span: Span = .zero)
}

/// Type.
///
/// ```abnf
/// type2 = value
///     / typename [genericarg]
///     / "(" S type S ")"
///     / "{" S group S "}"
///     / "[" S group S "]"
///     / "~" S typename [genericarg]
///     / "&" S "(" S group S ")"
///     / "&" S groupname [genericarg]
///     / "#" "6" ["." uint] "(" S type S ")"
///     / "#" DIGIT ["." uint]                ; major/ai
///     / "#"                                 ; any
/// ```
public indirect enum Type2: Hashable, Sendable {
    /// Integer value (negative literals, and any literal with a sign).
    case intValue(value: BigInt, span: Span = .zero)
    /// Unsigned integer value.
    case uintValue(value: UInt64, span: Span = .zero)
    /// Float value, with the notation the literal was written in.
    case floatValue(value: Double, notation: FloatNotation = FloatNotation(), span: Span = .zero)
    /// Text string value (enclosed by `"`).
    case textValue(value: String, span: Span = .zero)
    /// UTF-8 encoded byte string (enclosed by `'`).
    case utf8ByteString(value: [UInt8], span: Span = .zero)
    /// Base 16 encoded prefixed byte string.
    case b16ByteString(value: [UInt8], span: Span = .zero)
    /// Base 64 encoded (URL safe) prefixed byte string.
    case b64ByteString(value: [UInt8], span: Span = .zero)
    /// Type name identifier with optional generic arguments.
    case typename(ident: Identifier, genericArgs: GenericArgs? = nil, span: Span = .zero)
    /// Parenthesized type expression (for operator precedence).
    case parenthesizedType(
        pt: Type,
        span: Span = .zero,
        commentsBeforeType: Comments? = nil,
        commentsAfterType: Comments? = nil
    )
    /// Map expression.
    case map(
        group: Group,
        span: Span = .zero,
        commentsBeforeGroup: Comments? = nil,
        commentsAfterGroup: Comments? = nil
    )
    /// Array expression.
    case array(
        group: Group,
        span: Span = .zero,
        commentsBeforeGroup: Comments? = nil,
        commentsAfterGroup: Comments? = nil
    )
    /// Unwrapped group.
    case unwrap(
        ident: Identifier,
        genericArgs: GenericArgs? = nil,
        span: Span = .zero,
        comments: Comments? = nil
    )
    /// Enumeration expression over an inline group.
    case choiceFromInlineGroup(
        group: Group,
        span: Span = .zero,
        comments: Comments? = nil,
        commentsBeforeGroup: Comments? = nil,
        commentsAfterGroup: Comments? = nil
    )
    /// Enumeration expression over a previously defined group.
    case choiceFromGroup(
        ident: Identifier,
        genericArgs: GenericArgs? = nil,
        span: Span = .zero,
        comments: Comments? = nil
    )
    /// Tagged data item where the first element is an optional tag and the
    /// second is the type of the tagged value.
    case taggedData(
        tag: TagConstraint?,
        t: Type,
        span: Span = .zero,
        commentsBeforeType: Comments? = nil,
        commentsAfterType: Comments? = nil
    )
    /// Data item of a major type with optional data constraint.
    case dataMajorType(mt: UInt8, constraint: TagConstraint?, span: Span = .zero)
    /// Any data item.
    case any(span: Span = .zero)

    /// The span of the node.
    public var span: Span {
        switch self {
        case .intValue(_, let span), .uintValue(_, let span), .floatValue(_, _, let span),
            .textValue(_, let span), .utf8ByteString(_, let span), .b16ByteString(_, let span),
            .b64ByteString(_, let span), .typename(_, _, let span),
            .parenthesizedType(_, let span, _, _), .map(_, let span, _, _),
            .array(_, let span, _, _), .unwrap(_, _, let span, _),
            .choiceFromInlineGroup(_, let span, _, _, _), .choiceFromGroup(_, _, let span, _),
            .taggedData(_, _, let span, _, _), .dataMajorType(_, _, let span), .any(let span):
            return span
        }
    }

    /// A type2 from a range bound.
    init(rangeValue rv: RangeValue) {
        let span = Span.zero
        switch rv {
        case .ident(let ident, let socket):
            self = .typename(ident: Identifier(ident: ident, socket: socket, span: span), genericArgs: nil, span: span)
        case .int(let value):
            self = .intValue(value: value, span: span)
        case .uint(let value):
            self = .uintValue(value: value, span: span)
        case .float(let value):
            self = .floatValue(value: value, notation: FloatNotation(), span: span)
        }
    }

    /// A parenthesized type holding `type1`.
    public init(type1: Type1) {
        self = .parenthesizedType(
            pt: Type(typeChoices: [TypeChoice(type1: type1)], span: .zero),
            span: .zero
        )
    }

    /// An unsigned integer literal.
    public init(_ value: UInt64) {
        self = .uintValue(value: value, span: .zero)
    }

    /// An integer literal.
    public init(_ value: BigInt) {
        self = .intValue(value: value, span: .zero)
    }

    /// A float literal no document spelled.
    public init(_ value: Double) {
        self = .floatValue(value: value, notation: FloatNotation(), span: .zero)
    }

    /// A text literal.
    public init(text value: String) {
        self = .textValue(value: value, span: .zero)
    }

    /// An unprefixed byte string holding the UTF-8 of `value`.
    public init(utf8 value: String) {
        self = .utf8ByteString(value: Array(value.utf8), span: .zero)
    }

    /// A byte string literal.
    public init(_ value: ByteValue) {
        switch value {
        case .utf8(let value): self = .utf8ByteString(value: value, span: .zero)
        case .b16(let value): self = .b16ByteString(value: value, span: .zero)
        case .b64(let value): self = .b64ByteString(value: value, span: .zero)
        }
    }
}
