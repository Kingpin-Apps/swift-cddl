// The RFC 8610 Appendix D standard prelude: its names, its text, and the
// tagged types it defines.

/// The standard prelude names of RFC 8610 Appendix D. A reference to one of
/// these is never an undefined reference.
let standardPrelude: [String] = [
    "any", "uint", "nint", "int", "bstr", "bytes", "tstr", "text", "tdate", "time", "number",
    "biguint", "bignint", "bigint", "integer", "unsigned", "decfrac", "bigfloat", "eb64url",
    "eb64legacy", "eb16", "encoded-cbor", "uri", "b64url", "b64legacy", "regexp", "mime-message",
    "cbor-any", "float16", "float32", "float64", "float16-32", "float32-64", "float", "false",
    "true", "bool", "nil", "null", "undefined",
]

/// The text of the RFC 8610 Appendix D standard prelude.
let standardPreludeText: String = """
    any = #

    uint = #0
    nint = #1
    int = uint / nint

    bstr = #2
    bytes = bstr
    tstr = #3
    text = tstr

    tdate = #6.0(tstr)
    time = #6.1(number)
    number = int / float
    biguint = #6.2(bstr)
    bignint = #6.3(bstr)
    bigint = biguint / bignint
    integer = int / bigint
    unsigned = uint / biguint
    decfrac = #6.4([e10: int, m: integer])
    bigfloat = #6.5([e2: int, m: integer])
    eb64url = #6.21(any)
    eb64legacy = #6.22(any)
    eb16 = #6.23(any)
    encoded-cbor = #6.24(bstr)
    uri = #6.32(tstr)
    b64url = #6.33(tstr)
    b64legacy = #6.34(tstr)
    regexp = #6.35(tstr)
    mime-message = #6.36(tstr)
    cbor-any = #6.55799(any)

    float16 = #7.25
    float32 = #7.26
    float64 = #7.27
    float16-32 = float16 / float32
    float32-64 = float32 / float64
    float = float16-32 / float64

    false = #7.20
    true = #7.21
    bool = false / true
    nil = #7.22
    null = nil
    undefined = #7.23

    """

// MARK: - Prelude helpers

/// Builds an array type `[token1, token2, ...]` for use in tagged data
/// definitions.
func arrayTypeFromTokens(_ tokens: [Token]) -> Type {
    let groupEntries = tokens.map { token in
        GroupEntry.typeGroupname(
            ge: TypeGroupnameEntry(occur: nil, name: Identifier(token: token), genericArgs: nil),
            span: .zero
        )
    }
    let t2 = Type2.array(
        group: Group(groupChoices: [GroupChoice(entries: groupEntries)], span: .zero),
        span: .zero
    )
    return Type(typeChoices: [TypeChoice(type1: Type1(type2: t2, operator: nil, span: .zero))], span: .zero)
}

/// Returns the `Type2` of `token` if it is a tag type in the standard prelude.
func tagFromToken(_ token: Token) -> Type2? {
    func tagged(_ tag: UInt64, _ t: Type) -> Type2 {
        .taggedData(tag: .literal(tag), t: t, span: .zero)
    }
    switch token {
    case .tdate: return tagged(0, typeFromToken(.tstr))
    case .time: return tagged(1, typeFromToken(.number))
    case .biguint: return tagged(2, typeFromToken(.bstr))
    case .bignint: return tagged(3, typeFromToken(.bstr))
    case .decfrac: return tagged(4, arrayTypeFromTokens([.int, .integer]))
    case .bigfloat: return tagged(5, arrayTypeFromTokens([.int, .integer]))
    case .eb64url: return tagged(21, typeFromToken(.any))
    case .eb64legacy: return tagged(22, typeFromToken(.any))
    case .eb16: return tagged(23, typeFromToken(.any))
    case .encodedCBOR: return tagged(24, typeFromToken(.bstr))
    case .uri: return tagged(32, typeFromToken(.tstr))
    case .b64url: return tagged(33, typeFromToken(.tstr))
    case .b64legacy: return tagged(34, typeFromToken(.tstr))
    case .regexp: return tagged(35, typeFromToken(.tstr))
    case .mimeMessage: return tagged(36, typeFromToken(.tstr))
    case .cborAny: return tagged(55799, typeFromToken(.any))
    default: return nil
    }
}

/// A new `Type` naming the prelude type of `token`.
func typeFromToken(_ token: Token) -> Type {
    Type(
        typeChoices: [
            TypeChoice(
                type1: Type1(
                    type2: .typename(ident: Identifier(token: token), genericArgs: nil, span: .zero),
                    operator: nil,
                    span: .zero
                )
            )
        ],
        span: .zero
    )
}
