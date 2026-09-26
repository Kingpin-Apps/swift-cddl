import BigInt
import Foundation

// Rule lookups, classification of what names stand for, arity arithmetic and
// error wording shared by the validators (RFC 8610).

// MARK: - Range bounds

/// A range bound resolved to the value it denotes.
///
/// RFC 8610 Section 2.2.2.1 admits a range between two integers, matching
/// integer values, or between two floating point values, matching floating
/// point values.
enum RangeBound: Sendable, CustomStringConvertible {
    /// An integer bound.
    case int(BigInt)
    /// A floating point bound.
    case float(Double)

    var description: String {
        switch self {
        // A bound is echoed as the CDDL writes it, so a float keeps the
        // fraction that tells the two kinds of bound apart.
        case .float(let value): return FloatLiteral(value).description
        case .int(let value): return value.description
        }
    }

    /// Whether a pair of bounds denotes a range: bounds of different kinds
    /// denote none, which is a fault in the schema rather than an answer about
    /// the data.
    static func denoteARange(_ lower: RangeBound, _ upper: RangeBound) -> Bool {
        switch (lower, upper) {
        case (.int, .int), (.float, .float): return true
        default: return false
        }
    }
}

extension ValidationState {
    /// The type a generic parameter is instantiated with in the rule being
    /// evaluated, if `ident` names one of its parameters. A generic parameter
    /// is in scope only in the rule that declares it (RFC 8610 Section 3.10).
    func genericArgument(for ident: Identifier) -> Type1? {
        guard let name = evalGenericRule,
            let gr = genericRules.first(where: { $0.name == name }),
            let idx = gr.params.firstIndex(of: ident.ident),
            idx < gr.args.count
        else {
            return nil
        }
        return gr.args[idx]
    }

    /// The arguments a generic rule reference is instantiated with, with any
    /// argument naming a generic parameter of the rule being evaluated
    /// replaced by what that parameter is bound to.
    func resolvedGenericArgs(_ ga: GenericArgs) -> [Type1] {
        ga.args.map { arg in
            if arg.arg.operator == nil, case .typename(let ident, nil, _) = arg.arg.type2,
                let bound = genericArgument(for: ident)
            {
                return bound
            }
            return arg.arg
        }
    }

    /// The generic rules the body of `rule`, reached as `name` instantiated
    /// with `args`, is evaluated against. The arguments replace whatever the
    /// rule was last instantiated with.
    func genericRulesForInstantiation(_ rule: Rule, _ name: String, _ args: [Type1]) -> [GenericRule] {
        var genericRules = self.genericRules
        guard let params = genericParamsFromRule(rule) else {
            return genericRules
        }
        if let idx = genericRules.firstIndex(where: { $0.name == name }) {
            genericRules[idx].params = params
            genericRules[idx].args = args
        } else {
            genericRules.append(GenericRule(name: name, params: params, args: args))
        }
        return genericRules
    }

    /// Resolves a range bound to the value it denotes: an integer or float
    /// literal, possibly parenthesized, or a name of a rule or of a generic
    /// parameter that resolves to one. `maxDepth` bounds how many references
    /// are followed.
    func resolveRangeBound(_ bound: Type2, _ maxDepth: Int) -> Result<RangeBound, RangeBoundError> {
        var seen: [String] = []
        return resolveRangeBound(bound, &seen, 0, maxDepth)
    }

    private func resolveRangeBound(
        _ bound: Type2,
        _ seen: inout [String],
        _ depth: Int,
        _ maxDepth: Int
    ) -> Result<RangeBound, RangeBoundError> {
        // Every reference followed and every level of parentheses unwrapped
        // is a step of a chain the schema alone decides the length of, so the
        // chain is followed in a loop and carries the rule nesting bound.
        var bound = bound
        var depth = depth
        while true {
            if depth > maxDepth {
                return .failure(
                    RangeBoundError(
                        "resolving the bound nests references more than \(maxDepth) deep, exceeding the maximum supported rule nesting"
                    ))
            }

            switch bound {
            case .uintValue(let value, _):
                return .success(.int(BigInt(value)))
            case .intValue(let value, _):
                return .success(.int(value))
            case .floatValue(let value, _, _):
                return .success(.float(value))
            case .parenthesizedType(let pt, _, _, _) where pt.typeChoices.count == 1 && pt.typeChoices[0].type1.operator == nil:
                bound = pt.typeChoices[0].type1.type2
                depth += 1
            case .typename(let ident, _, _):
                if let arg = genericArgument(for: ident) {
                    if arg.operator == nil {
                        bound = arg.type2
                        depth += 1
                        continue
                    }
                    return .failure(
                        RangeBoundError("Generic argument for '\(ident.ident)' does not resolve to a numeric value"))
                }

                if seen.contains(ident.ident) {
                    return .failure(
                        RangeBoundError(
                            "Type name '\(ident.ident)' is circularly defined and does not resolve to a numeric value"))
                }
                seen.append(ident.ident)

                guard let rule = schema.rules(bareName: ident.ident).first else {
                    return .failure(RangeBoundError("Type name '\(ident.ident)' not found in CDDL rules"))
                }
                switch rule {
                case .type(let rule, _, _, _):
                    if rule.genericParams != nil {
                        return .failure(
                            RangeBoundError(
                                "Type name '\(ident.ident)' is a generic rule and does not resolve to a numeric value"))
                    }
                    if rule.value.typeChoices.count == 1, rule.value.typeChoices[0].type1.operator == nil {
                        bound = rule.value.typeChoices[0].type1.type2
                        depth += 1
                        continue
                    }
                    return .failure(
                        RangeBoundError("Type name '\(ident.ident)' does not resolve to a numeric value"))
                case .group:
                    return .failure(
                        RangeBoundError("Group name '\(ident.ident)' does not resolve to a numeric value"))
                }
            default:
                return .failure(RangeBoundError("Expected a numeric value or type name, got \(bound)"))
            }
        }
    }
}

/// Why a range bound resolves to no value.
struct RangeBoundError: Error, Sendable, CustomStringConvertible {
    var message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { message }
}

// MARK: - Rule lookups

/// The rule defining `ident`, other than a `/=` or `//=` alternative.
func ruleFromIdent(_ schema: Schema, _ ident: Identifier) -> Rule? {
    schema.rules(named: ident).first { rule in
        switch rule {
        case .type(let rule, _, _, _): return !rule.isTypeChoiceAlternate
        case .group(let rule, _, _, _): return !rule.isGroupChoiceAlternate
        }
    }
}

/// The rule a type name resolves to: the rule defining it, or, for a name that
/// `/=` alternatives alone define (a type socket plugs have filled, RFC 8610
/// Section 3.9), the first of those rules, standing for the whole choice.
func ruleOrSocketFromIdent(_ schema: Schema, _ ident: Identifier) -> Rule? {
    ruleFromIdent(schema, ident)
        ?? schema.rules(named: ident).first { rule in
            if case .type = rule { return true }
            return false
        }
}

/// The type a name stands for once every alternative `/=` adds to it is taken
/// into account: the rule's own definition, where there is one, followed by
/// the alternatives, as the choices of one type (RFC 8610 Section 3.9).
func extendedType(_ own: Type?, _ alternates: [Type]) -> Type {
    var types: [Type] = []
    if let own {
        types.append(own)
    }
    types.append(contentsOf: alternates)
    return Type(typeChoices: types.flatMap(\.typeChoices), span: types.first?.span ?? .zero)
}

/// The types still to be examined at one step of the text value walk, and the
/// name whose rule they came from.
private struct TextValueFrame {
    var choices: [TypeChoice]
    var next = 0
    /// The name the choices define, and so a name being followed while the
    /// frame is open.
    var name: Identifier?
    /// Whether the choices were reached through a name: a rule's own choices
    /// admit fewer forms than a type examined directly does.
    var throughName: Bool
}

/// The first text value a name stands for.
func textValueFromIdent(_ schema: Schema, _ ident: Identifier) -> Type2? {
    var frames: [TextValueFrame] = []
    textValueOpenIdent(schema, ident, &frames)
    return textValueFromFrames(schema, &frames)
}

/// The first text value a type stands for.
func textValueFromType2(_ schema: Schema, _ t2: Type2) -> Type2? {
    var frames: [TextValueFrame] = []
    if let value = textValueExamine(schema, t2, &frames) {
        return value
    }
    return textValueFromFrames(schema, &frames)
}

/// Opens a frame for every type rule named `ident`, with the first of them on
/// top.
private func textValueOpenIdent(_ schema: Schema, _ ident: Identifier, _ frames: inout [TextValueFrame]) {
    for rule in schema.rules(named: ident).reversed() {
        if case .type(let rule, _, _, _) = rule {
            frames.append(TextValueFrame(choices: rule.value.typeChoices, name: rule.name, throughName: true))
        }
    }
}

/// The text value one type is, or else opens the frames for the types it may
/// stand for, so that the first of them is examined first.
private func textValueExamine(_ schema: Schema, _ t2: Type2, _ frames: inout [TextValueFrame]) -> Type2? {
    switch t2 {
    case .textValue, .utf8ByteString:
        return t2
    case .typename(let ident, _, _):
        if frames.allSatisfy({ $0.name != ident }) {
            textValueOpenIdent(schema, ident, &frames)
        }
    case .array(let group, _, _, _):
        for gc in group.groupChoices.reversed() {
            if gc.groupEntries.count != 2 {
                continue
            }
            if case .valueMemberKey(let ge, _, _, _) = gc.groupEntries[0].0, ge.memberKey == nil {
                frames.append(TextValueFrame(choices: ge.entryType.typeChoices, name: nil, throughName: false))
            }
        }
    case .parenthesizedType(let pt, _, _, _):
        frames.append(TextValueFrame(choices: pt.typeChoices, name: nil, throughName: false))
    default:
        break
    }
    return nil
}

private func textValueFromFrames(_ schema: Schema, _ frames: inout [TextValueFrame]) -> Type2? {
    while !frames.isEmpty {
        let top = frames.count - 1
        guard frames[top].next < frames[top].choices.count else {
            frames.removeLast()
            continue
        }
        let tc = frames[top].choices[frames[top].next]
        frames[top].next += 1

        if tc.type1.operator != nil {
            continue
        }
        if frames[top].throughName, case .array = tc.type1.type2 {
            continue
        }
        if let value = textValueExamine(schema, tc.type1.type2, &frames) {
            return value
        }
    }
    return nil
}

/// The array, map or tagged type rule an unwrapped name stands for, following
/// a chain of bare type names to it. A chain leading back to a name already on
/// it stands for nothing.
func unwrapRuleFromIdent(_ schema: Schema, _ ident: Identifier) -> Rule? {
    var followed: [Identifier] = []
    var ident = ident

    while true {
        if followed.contains(ident) {
            return nil
        }
        followed.append(ident)

        guard
            let rule = schema.rules(named: ident).first(where: { rule in
                if case .type(let rule, _, _, _) = rule { return !rule.isTypeChoiceAlternate }
                return false
            }), case .type(let typeRule, _, _, _) = rule
        else {
            return nil
        }
        let typeChoices = typeRule.value.typeChoices

        if typeChoices.contains(where: { tc in
            switch tc.type1.type2 {
            case .map, .array, .taggedData: return true
            default: return false
            }
        }) {
            return rule
        }

        guard
            let next = typeChoices.lazy.compactMap({ tc -> Identifier? in
                if case .typename(let ident, nil, _) = tc.type1.type2 { return ident }
                return nil
            }).first
        else {
            return nil
        }
        ident = next
    }
}

/// The group rule defining `ident`, other than a `//=` alternative.
func groupRuleFromIdent(_ schema: Schema, _ ident: Identifier) -> GroupRule? {
    for rule in schema.rules(named: ident) {
        if case .group(let rule, _, _, _) = rule, !rule.isGroupChoiceAlternate {
            return rule
        }
    }
    return nil
}

/// The type rule defining `ident`, other than a `/=` alternative.
func typeRuleFromIdent(_ schema: Schema, _ ident: Identifier) -> TypeRule? {
    for rule in schema.rules(named: ident) {
        if case .type(let rule, _, _, _) = rule, !rule.isTypeChoiceAlternate {
            return rule
        }
    }
    return nil
}

/// The names of a rule's generic parameters, or `nil` for a rule declaring
/// none.
func genericParamsFromRule(_ rule: Rule) -> [String]? {
    switch rule {
    case .type(let rule, _, _, _): return rule.genericParams.map { $0.params.map(\.param.ident) }
    case .group(let rule, _, _, _): return rule.genericParams.map { $0.params.map(\.param.ident) }
    }
}

/// The types every `/=` alternative for `ident` adds.
func typeChoiceAlternatesFromIdent(_ schema: Schema, _ ident: Identifier) -> [Type] {
    schema.rules(named: ident).compactMap { rule in
        if case .type(let rule, _, _, _) = rule, rule.isTypeChoiceAlternate {
            return rule.value
        }
        return nil
    }
}

/// The entries every `//=` alternative for `ident` adds.
func groupChoiceAlternatesFromIdent(_ schema: Schema, _ ident: Identifier) -> [GroupEntry] {
    schema.rules(named: ident).compactMap { rule in
        if case .group(let rule, _, _, _) = rule, rule.isGroupChoiceAlternate {
            return rule.entry
        }
        return nil
    }
}

/// The type choices a group choice turns into (RFC 8610 Section 3.6): an entry
/// naming a type stands for that type, and one naming a group for the choice
/// that group turns into, held as the name it is written as.
func typeChoicesFromGroupChoice(_ schema: Schema, _ grpchoice: GroupChoice) -> [TypeChoice] {
    var typeChoices: [TypeChoice] = []
    var steps: [([(GroupEntry, OptionalComma)], Int)] = [(grpchoice.groupEntries, 0)]

    while let (entries, idx) = steps.popLast() {
        guard idx < entries.count else { continue }
        steps.append((entries, idx + 1))
        let entry = entries[idx].0

        switch entry {
        case .valueMemberKey(let ge, _, _, _):
            typeChoices.append(contentsOf: ge.entryType.typeChoices)
        case .typeGroupname(let ge, _, _, _):
            let type2: Type2
            if case .group = ruleFromIdent(schema, ge.name) {
                type2 = .choiceFromGroup(ident: ge.name, genericArgs: ge.genericArgs, span: ge.name.span)
            } else {
                type2 = .typename(ident: ge.name, genericArgs: ge.genericArgs, span: ge.name.span)
            }
            typeChoices.append(TypeChoice(type1: Type1(type2: type2, operator: nil, span: ge.name.span)))
        case .inlineGroup(_, let group, _, _, _):
            for gc in group.groupChoices.reversed() {
                steps.append((gc.groupEntries, 0))
            }
        }
    }

    return typeChoices
}

// MARK: - What names stand for

/// Whether the type name `ident`, or any name reached by following the names
/// its rule is defined as, stands for a prelude type `matches` accepts. A chain
/// that leads back to a name already on it stands for nothing.
func identDenotesPreludeType(_ schema: Schema, _ ident: Identifier, _ matches: (Token) -> Bool) -> Bool {
    identChainAny(schema, ident, cycleCheck: true) { ident in
        matches(lookupIdent(ident.ident)) ? .accept : .follow
    }
}

/// What a name on a chain of names settles.
enum ChainStep {
    /// The name answers the question.
    case accept
    /// The name answers no on its own path.
    case reject
    /// The question passes to the names its type rules are defined as.
    case follow
}

/// Whether any path of names from `ident` -- a name, then the bare names each
/// type rule defining it has as a choice, and so on -- reaches a name `step`
/// accepts. With `cycleCheck`, a name already on the path is not followed
/// again; without it, a name is followed at most once overall, which only
/// makes a cyclic schema terminate. The paths are walked with a stack of their
/// own, so a chain as long as the schema cares to write costs no stack.
func identChainAny(
    _ schema: Schema,
    _ ident: Identifier,
    cycleCheck: Bool,
    _ step: (Identifier) -> ChainStep
) -> Bool {
    struct Frame {
        var name: String
        var next: [Identifier]
        var index = 0
    }

    func successors(_ ident: Identifier) -> [Identifier] {
        var next: [Identifier] = []
        for rule in schema.rules(named: ident) {
            guard case .type(let rule, _, _, _) = rule else { continue }
            for tc in rule.value.typeChoices {
                if case .typename(let name, _, _) = tc.type1.type2 {
                    next.append(name)
                }
            }
        }
        return next
    }

    var visited: Set<String> = []
    var stack: [Frame] = []

    // Enters a name: whether it settles the question, or else opens its
    // frame when it is to be followed.
    func enter(_ ident: Identifier) -> Bool {
        switch step(ident) {
        case .accept:
            return true
        case .reject:
            return false
        case .follow:
            if cycleCheck {
                if stack.contains(where: { $0.name == ident.ident }) {
                    return false
                }
            } else {
                if visited.contains(identifierKey(ident)) {
                    return false
                }
                visited.insert(identifierKey(ident))
            }
            stack.append(Frame(name: ident.ident, next: successors(ident)))
            return false
        }
    }

    if enter(ident) {
        return true
    }
    while !stack.isEmpty {
        let top = stack.count - 1
        guard stack[top].index < stack[top].next.count else {
            stack.removeLast()
            continue
        }
        let next = stack[top].next[stack[top].index]
        stack[top].index += 1
        if enter(next) {
            return true
        }
    }
    return false
}

/// Whether `ident` stands for `null`.
func isIdentNullDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    identDenotesPreludeType(schema, ident) {
        if case .null = $0 { return true }
        if case .nil = $0 { return true }
        return false
    }
}

/// Whether `ident` stands for `bool`.
func isIdentBoolDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    identDenotesPreludeType(schema, ident) {
        if case .bool = $0 { return true }
        return false
    }
}

/// Whether `ident` admits the boolean `value`.
func identMatchesBoolValue(_ schema: Schema, _ ident: Identifier, _ value: Bool) -> Bool {
    identChainAny(schema, ident, cycleCheck: false) { ident in
        let token = lookupIdent(ident.ident)
        if case .true = token, value {
            return .accept
        }
        if case .false = token, !value {
            return .accept
        }
        return .follow
    }
}

/// The boolean an identifier stands for, and `nil` where it stands for no
/// single one.
func boolLiteralOfIdent(_ schema: Schema, _ ident: Identifier) -> Bool? {
    switch (identMatchesBoolValue(schema, ident, true), identMatchesBoolValue(schema, ident, false)) {
    case (true, false): return true
    case (false, true): return false
    default: return nil
    }
}

private func denotes(_ schema: Schema, _ ident: Identifier, _ tokens: Token...) -> Bool {
    identDenotesPreludeType(schema, ident) { token in tokens.contains(token) }
}

/// Whether `ident` stands for `uri`.
func isIdentURIDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .uri) }
/// Whether `ident` stands for `b64url`.
func isIdentB64URLDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .b64url) }
/// Whether `ident` stands for `tdate`.
func isIdentTdateDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .tdate) }
/// Whether `ident` stands for `time`.
func isIdentTimeDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .time) }
/// Whether `ident` stands for `decfrac`.
func isIdentDecfracDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .decfrac) }
/// Whether `ident` stands for `bigfloat`.
func isIdentBigfloatDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .bigfloat) }
/// Whether `ident` stands for `unsigned` (`uint / biguint`).
func isIdentUnsignedDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .unsigned) }
/// Whether `ident` stands for `uint`.
func isIdentUintDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .uint) }
/// Whether `ident` stands for `nint`.
func isIdentNintDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .nint) }
/// Whether `ident` stands for `number` (`int / float`).
func isIdentNumberDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .number) }
/// Whether `ident` stands for a text string type.
func isIdentStringDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .text, .tstr) }
/// Whether `ident` stands for `any`.
func isIdentAnyType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .any) }
/// Whether `ident` stands for a byte string type.
func isIdentByteStringDataType(_ schema: Schema, _ ident: Identifier) -> Bool { denotes(schema, ident, .bstr, .bytes) }

/// Whether `ident` stands for an integer type.
func isIdentIntegerDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    denotes(schema, ident, .int, .integer, .nint, .uint, .number, .unsigned)
}

/// Whether `ident` stands for a floating point type.
func isIdentFloatDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    denotes(schema, ident, .float, .float16, .float1632, .float32, .float3264, .float64)
}

/// Whether `ident` stands for a numeric type.
func isIdentNumericDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    denotes(
        schema, ident, .uint, .nint, .integer, .int, .number, .float, .float16, .float32, .float64, .float1632,
        .float3264, .unsigned)
}

/// Whether an integer is admitted by the integer type `ident` names: `nil` when
/// the name is no integer type at all. `uint` and `unsigned` admit no negative
/// value, `nint` only negative ones, and `int`, `integer` and `number` either
/// (RFC 8610 Appendix D).
func integerMatchesDataType(_ schema: Schema, _ ident: Identifier, _ value: BigInt) -> Bool? {
    let admitsNonNegative = isIdentUintDataType(schema, ident) || isIdentUnsignedDataType(schema, ident)
    let admitsNegative = isIdentNintDataType(schema, ident)

    switch (admitsNonNegative, admitsNegative) {
    case (true, true): return true
    case (true, false): return value.sign == .plus || value.isZero
    case (false, true): return value.sign == .minus && !value.isZero
    case (false, false):
        return isIdentIntegerDataType(schema, ident) ? true : nil
    }
}

/// Whether a non-negative integer is representable in `bytes` bytes, which is
/// what `.size` constrains for a uint target.
func uintFitsInSize(_ value: BigInt, _ bytes: BigInt) -> Bool {
    if value.sign == .minus && !value.isZero || bytes.sign == .minus && !bytes.isZero {
        return false
    }
    if bytes >= 16 {
        return true
    }
    return value < BigInt(1) << (8 * Int(bytes))
}

/// Whether a whole number of seconds since the UNIX epoch denotes a point in
/// time that can be represented: one between the years -262143 and 262142.
func secondsAreRepresentableTime(_ seconds: BigInt) -> Bool {
    seconds >= BigInt(minRepresentableSeconds) && seconds <= BigInt(maxRepresentableSeconds)
}

/// Whether a fractional number of seconds since the UNIX epoch denotes a point
/// in time that can be represented.
func floatSecondsAreRepresentableTime(_ seconds: Double) -> Bool {
    guard seconds.isFinite else { return false }
    let whole = seconds.rounded(.down)
    guard whole >= -9.223372036854776e18, whole < 9.223372036854776e18 else { return false }
    return secondsAreRepresentableTime(BigInt(Int64(whole)))
}

/// The seconds since the UNIX epoch of the first instant of -262143-01-02.
private let minRepresentableSeconds: Int64 = -8_334_601_228_800
/// The seconds since the UNIX epoch of the last whole second of 262142-12-31.
private let maxRepresentableSeconds: Int64 = 8_210_266_876_799

/// A count of seconds since the UNIX epoch, named for an error message.
enum UnixSeconds: CustomStringConvertible {
    case whole(BigInt)
    case fractional(Double)

    var description: String {
        switch self {
        case .fractional(let seconds): return FloatLiteral(seconds).description
        case .whole(let seconds): return seconds.description
        }
    }
}

/// The rejection of a data item standing for a point in time that cannot be
/// represented.
func invalidTimestampError(_ seconds: UnixSeconds) -> String {
    "expected time data type, invalid UNIX timestamp \(seconds)"
}

/// A control operator that relates its target to its controller by comparing
/// the two as numbers.
enum Comparison {
    case lt, le, gt, ge

    init?(_ ctrl: ControlOperator) {
        switch ctrl {
        case .lt: self = .lt
        case .le: self = .le
        case .gt: self = .gt
        case .ge: self = .ge
        default: return nil
        }
    }

    /// Whether the comparison holds between a value and a controller denoting
    /// a single value, both taken as floating point numbers.
    func holds(_ value: Double, _ bound: Double) -> Bool {
        switch self {
        case .lt: return value < bound
        case .le: return value <= bound
        case .gt: return value > bound
        case .ge: return value >= bound
        }
    }

    /// Whether the comparison holds against every member of an integer range:
    /// against its least member for `.lt` and `.le`, its greatest for `.gt`
    /// and `.ge`. `nil` for a range that holds no members.
    func holdsAgainstIntRange(_ value: BigInt, _ lower: BigInt, _ upper: BigInt, _ isInclusive: Bool) -> Bool? {
        let greatest = isInclusive ? upper : upper - 1
        if lower > greatest {
            return nil
        }
        switch self {
        case .lt: return value < lower
        case .le: return value <= lower
        case .gt: return value > greatest
        case .ge: return value >= greatest
        }
    }

    /// Whether the comparison holds against every member of a float range.
    /// `nil` for a range that holds no members, which includes one bounded by
    /// a NaN.
    func holdsAgainstFloatRange(_ value: Double, _ lower: Double, _ upper: Double, _ isInclusive: Bool) -> Bool? {
        let hasMembers = isInclusive ? lower <= upper : lower < upper
        if !hasMembers {
            return nil
        }
        switch self {
        case .lt: return value < lower
        case .le: return value <= lower
        case .gt where isInclusive: return value > upper
        case .gt, .ge: return value >= upper
        }
    }
}

/// The value an integer literal has as a floating point number, or `nil` for a
/// literal that is not an integer.
func integerLiteralAsDouble(_ value: Value) -> Double? {
    switch value {
    case .int(let v): return Double(v)
    case .uint(let v): return Double(v)
    default: return nil
    }
}

/// The numbers of the bits set in a non-negative integer, in ascending order.
func setBitNumbersInUint(_ value: BigInt) -> [UInt64] {
    var bits: [UInt64] = []
    let magnitude = value.magnitude
    for n in 0..<128 where magnitude.bitWidth > n && (magnitude >> n) & 1 == 1 {
        bits.append(UInt64(n))
    }
    return bits
}

/// The numbers of the bits set in a byte string, in ascending order: bit `n` is
/// bit `n & 7` of byte `n >> 3`, bit 0 being the least significant.
func setBitNumbersInBytes(_ bytes: [UInt8]) -> [UInt64] {
    var bits: [UInt64] = []
    for (idx, byte) in bytes.enumerated() {
        for bit in 0..<8 where byte & (1 << bit) != 0 {
            bits.append(UInt64(idx) * 8 + UInt64(bit))
        }
    }
    return bits
}

/// Which kinds of number a name admits (`number = int / float`, RFC 8610
/// Appendix D).
enum NumericKind: Equatable {
    /// Only integers.
    case int
    /// Only floats.
    case float
    /// Integers and floats.
    case both

    var admitsInt: Bool { self == .int || self == .both }
    var admitsFloat: Bool { self == .float || self == .both }
}

/// The numeric kind of a name, or `nil` if it is not a numeric type.
func identNumericKind(_ schema: Schema, _ ident: Identifier) -> NumericKind? {
    let number = isIdentNumberDataType(schema, ident)
    switch (number || isIdentIntegerDataType(schema, ident), number || isIdentFloatDataType(schema, ident)) {
    case (true, true): return .both
    case (true, false): return .int
    case (false, true): return .float
    case (false, false): return nil
    }
}

/// Whether a name denotes a bignum type accepting CBOR tag `tag`
/// (`biguint = #6.2(bstr)`, `bignint = #6.3(bstr)`).
func identAcceptsBignumTag(_ schema: Schema, _ ident: Identifier, _ tag: UInt64) -> Bool {
    identChainAny(schema, ident, cycleCheck: false) { ident in
        switch lookupIdent(ident.ident) {
        case .biguint: return tag == 2 ? .accept : .reject
        case .bignint: return tag == 3 ? .accept : .reject
        case .bigint: return tag == 2 || tag == 3 ? .accept : .reject
        default: return .follow
        }
    }
}

/// Whether a name denotes a bignum type.
func isIdentBignumDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    identAcceptsBignumTag(schema, ident, 2) || identAcceptsBignumTag(schema, ident, 3)
}

/// Every type assigned to an identifier, in document order (RFC 8610 Section
/// 2.2.2).
func typeChoiceTypesFromIdent(_ schema: Schema, _ ident: Identifier) -> [Type] {
    schema.rules(named: ident).compactMap { rule in
        if case .type(let rule, _, _, _) = rule { return rule.value }
        return nil
    }
}

/// Whether the name is one of the primitive data types a control operator's
/// dispatch can tell apart on its own.
func isIdentPrimitiveDataType(_ schema: Schema, _ ident: Identifier) -> Bool {
    isIdentStringDataType(schema, ident) || isIdentByteStringDataType(schema, ident)
        || isIdentUintDataType(schema, ident) || isIdentIntegerDataType(schema, ident)
        || isIdentFloatDataType(schema, ident) || isIdentBoolDataType(schema, ident)
        || isIdentNullDataType(schema, ident)
}

/// The tagged types a prelude type name admits, in the order they are tried.
func taggedPreludeTypes(_ token: Token) -> [Type2] {
    switch token {
    case .bigint, .integer:
        return [Token.biguint, .bignint].compactMap(tagFromToken)
    case .unsigned:
        return [Token.biguint].compactMap(tagFromToken)
    default:
        return tagFromToken(token).map { [$0] } ?? []
    }
}

/// The tag a tagged type carries, where it is stated as a literal.
func literalTagOf(_ t2: Type2) -> UInt64? {
    if case .taggedData(let tag?, _, _, _, _) = t2 {
        return tag.asLiteral()
    }
    return nil
}

// MARK: - Operands of the computing control operators

/// The kind of value an operand of an RFC 9165 control operator has to denote.
enum ControlOperandKind {
    /// A numeric value, what `.plus` takes.
    case numeric
    /// A text or byte string literal, what `.cat` and `.det` take.
    case stringLiteral

    var descriptionText: String {
        switch self {
        case .numeric: return "a numeric value"
        case .stringLiteral: return "a string literal"
        }
    }

    func matches(_ t2: Type2) -> Bool {
        switch (self, t2) {
        case (.numeric, .intValue), (.numeric, .uintValue), (.numeric, .floatValue):
            return true
        case (.stringLiteral, .textValue), (.stringLiteral, .utf8ByteString), (.stringLiteral, .b16ByteString),
            (.stringLiteral, .b64ByteString):
            return true
        default:
            return false
        }
    }
}

/// The value literals a type name denotes as an operand of an RFC 9165 control
/// operator, followed through further names; a name standing for no value is
/// reported as a fault in the schema.
func controlOperandValues(_ schema: Schema, _ ident: Identifier, _ kind: ControlOperandKind) -> Result<[Type2], SchemaFault> {
    var followed: [String] = []
    let resolution = collectControlOperandValues(schema, ident, kind, &followed)

    if resolution.values.isEmpty {
        if resolution.cycled && !resolution.resolvesOtherwise {
            return .failure(SchemaFault("type rule \(ident) is defined in terms of itself, so it denotes no value"))
        }
        if ruleFromIdent(schema, ident) != nil {
            return .failure(SchemaFault("type rule \(ident) is not \(kind.descriptionText)"))
        }
        return .failure(SchemaFault("no type rule named \(ident) is defined"))
    }
    return .success(resolution.values)
}

private struct ControlOperandResolution {
    var values: [Type2] = []
    var cycled = false
    var resolvesOtherwise = false
}

private func collectControlOperandValues(
    _ schema: Schema,
    _ ident: Identifier,
    _ kind: ControlOperandKind,
    _ followed: inout [String]
) -> ControlOperandResolution {
    // The names are followed depth first, in the order the schema writes
    // them, with a stack of their own; a name leading back to one on the
    // current path contributes nothing but the note that it cycled.
    struct Frame {
        var name: String
        var choices: [Type2]
        var index = 0
    }

    func choices(_ ident: Identifier) -> [Type2] {
        var found: [Type2] = []
        for rule in schema.rules(named: ident) {
            guard case .type(let rule, _, _, _) = rule else { continue }
            found.append(contentsOf: rule.value.typeChoices.map(\.type1.type2))
        }
        return found
    }

    var resolution = ControlOperandResolution()
    if followed.contains(ident.ident) {
        resolution.cycled = true
        return resolution
    }
    var stack = [Frame(name: ident.ident, choices: choices(ident))]

    while !stack.isEmpty {
        let top = stack.count - 1
        guard stack[top].index < stack[top].choices.count else {
            stack.removeLast()
            continue
        }
        let t = stack[top].choices[stack[top].index]
        stack[top].index += 1

        if kind.matches(t) {
            resolution.values.append(t)
            resolution.resolvesOtherwise = true
        } else if case .typename(let next, _, _) = t {
            if followed.contains(next.ident) || stack.contains(where: { $0.name == next.ident }) {
                resolution.cycled = true
            } else {
                stack.append(Frame(name: next.ident, choices: choices(next)))
            }
        } else {
            resolution.resolvesOtherwise = true
        }
    }
    return resolution
}

/// A fault in the schema, carried as the reason it is reported with.
struct SchemaFault: Error, Sendable, CustomStringConvertible {
    var message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { message }
}

/// Whether `ctrl` computes the literal it matches from its two operands
/// (`.plus`, `.cat` and `.det`, RFC 9165), rather than constraining its target
/// by the controller.
func ctrlComputesValue(_ ctrl: ControlOperator) -> Bool {
    ctrl == .plus || ctrl == .cat || ctrl == .det
}

/// Whether the data item has to be of the target's type before `ctrl` is
/// evaluated against it.
func ctrlHoldsTargetToItsType(_ ctrl: ControlOperator) -> Bool {
    !ctrlComputesValue(ctrl)
}

/// Whether `t2` denotes a numeric type, that is, whether every data item it
/// admits is a number (RFC 8610 Section 3.8.6).
func type2DenotesNumericType(_ schema: Schema, _ t2: Type2) -> Bool {
    // Every choice reached has to be numeric, so the answer is the
    // conjunction of every leaf the walk reaches; the walk keeps its own
    // stack, with the names on the current path.
    struct Frame {
        var name: String?
        var choices: [Type2]
        var index = 0
    }

    var stack: [Frame] = []

    // Whether `t2` is numeric on its own, `false` when it is not, or `nil`
    // when a frame was opened for what it stands for.
    func enter(_ t2: Type2) -> Bool? {
        switch t2 {
        case .intValue, .uintValue, .floatValue:
            return true
        case .typename(let ident, _, _):
            if isIdentNumericDataType(schema, ident) {
                return true
            }
            if stack.contains(where: { $0.name == ident.ident }) {
                return false
            }
            if case .type(let rule, _, _, _) = ruleFromIdent(schema, ident) {
                stack.append(Frame(name: ident.ident, choices: rule.value.typeChoices.map(\.type1.type2)))
                return nil
            }
            return false
        case .parenthesizedType(let pt, _, _, _):
            stack.append(Frame(name: nil, choices: pt.typeChoices.map(\.type1.type2)))
            return nil
        default:
            return false
        }
    }

    if let answer = enter(t2) {
        return answer
    }
    while !stack.isEmpty {
        let top = stack.count - 1
        guard stack[top].index < stack[top].choices.count else {
            stack.removeLast()
            continue
        }
        let next = stack[top].choices[stack[top].index]
        stack[top].index += 1
        if enter(next) == false {
            return false
        }
    }
    return true
}

/// The rejection an equality control operator reports when the data item is
/// not one of the values its target admits.
func targetTypeError(_ model: DataModel, _ target: Type2, _ document: String) -> String {
    expectedTypeError(model, target, document)
}

/// The rejection `.ne` reports when the data item is one of the values its
/// controller denotes.
func exclusionError(_ target: Type2, _ controller: Type2, _ document: String) -> String {
    "expected \(typeHead(target)) .ne \(typeHead(controller)), got \(document)"
}

/// The rejection a text string that is no encoding at all under a text
/// conversion control operator reports.
func textConversionEncodingError(_ ctrl: ControlOperator, _ text: String) -> String {
    "text string \"\(text)\" is not \(ctrl) encoded"
}

/// The rejection a decoded byte string that is not a member of the controller
/// type reports.
func textConversionControllerError(_ ctrl: ControlOperator, _ reason: String) -> String {
    "\(ctrl) decoded byte string: \(reason)"
}

/// The value literals a controller written as a computation stands for (RFC
/// 9165: `int .lt (BASE .plus 100)`), and `nil` where the controller is not
/// written as one.
func computedControllerValues(_ state: ValidationState, _ controller: Type2) -> Result<[Type2], SchemaFault>? {
    guard case .parenthesizedType(let pt, _, _, _) = controller else {
        return nil
    }

    var values: [Type2] = []
    for tc in pt.typeChoices {
        guard let op = tc.type1.operator, case .ctlOp(let ctrl, _) = op.operator, ctrlComputesValue(ctrl) else {
            return nil
        }
        let target = controlOperandInScope(state, tc.type1.type2)
        let operand = controlOperandInScope(state, op.type2)

        let computed: Result<[Type2], SchemaFault>
        if ctrl == .plus {
            computed = plusOperation(state.schema, target, operand)
        } else {
            computed = catOperation(state.schema, target, operand, ctrl == .det)
        }
        switch computed {
        case .success(let computed): values.append(contentsOf: computed)
        case .failure(let fault): return .failure(fault)
        }
    }
    return .success(values)
}

/// An operand of a computed controller, with a name bound as a generic
/// parameter replaced by the type it was instantiated with.
private func controlOperandInScope(_ state: ValidationState, _ operand: Type2) -> Type2 {
    if case .typename(let ident, nil, _) = operand, let arg = state.genericArgument(for: ident), arg.operator == nil {
        return arg.type2
    }
    return operand
}

/// Whether `ctrl` computed the literal being matched by concatenating two
/// operands.
func ctrlComputesConcatenation(_ ctrl: ControlOperator?) -> Bool {
    ctrl == .cat || ctrl == .det
}

/// Whether a value literal reached under `ctrl` is validated as a value in its
/// own right, by equality with the data item.
func ctrlEvaluatesLiteralAsValue(_ ctrl: ControlOperator?) -> Bool {
    switch ctrl {
    case nil, .eq?, .default?, .and?, .within?, .cbor?, .cborseq?, .cat?, .det?, .feature?:
        return true
    default:
        return false
    }
}

// MARK: - Occurrences

/// Whether an occurrence indicator admits zero occurrences.
func occurrenceAdmitsAbsence(_ occurrence: Occur?) -> Bool {
    switch occurrence {
    case .optional?, .zeroOrMore?: return true
    case .exact(let lower, _, _)?: return lower == nil || lower == 0
    case .oneOrMore?, nil: return false
    }
}

/// Whether an occurrence indicator lets one group entry cover more than one
/// data item.
func occurrenceCoversMany(_ occurrence: Occur?) -> Bool {
    switch occurrence {
    case .zeroOrMore?, .oneOrMore?: return true
    case .exact(_, let upper, _)?: return !(upper == 0 || upper == 1)
    case .optional?, nil: return false
    }
}

/// The (min, max) number of times an occurrence indicator lets its entry
/// repeat; an entry without one stands for exactly one occurrence.
func occurrenceBounds(_ occur: Occur?) -> (Int, Int?) {
    switch occur {
    case nil: return (1, 1)
    case .optional?: return (0, 1)
    case .zeroOrMore?: return (0, nil)
    case .oneOrMore?: return (1, nil)
    case .exact(let lower, let upper, _)?: return (Int(clamping: lower ?? 0), upper.map { Int(clamping: $0) })
    }
}

/// The occurrence indicator written on a group entry, if any.
func groupEntryOccur(_ entry: GroupEntry) -> Occur? {
    switch entry {
    case .valueMemberKey(let ge, _, _, _): return ge.occur?.occur
    case .typeGroupname(let ge, _, _, _): return ge.occur?.occur
    case .inlineGroup(let occur, _, _, _, _): return occur?.occur
    }
}

// MARK: - Member keys

/// The set of keys a member key that denotes a type stands for.
enum MemberKeyType {
    /// A range: its lower bound, its upper bound and whether the upper bound is
    /// included.
    case range(Type2, Type2, Bool)
    /// A name standing for the type a rule, or the prelude, defines.
    case rule(Identifier)
}

/// The set of keys a member key denotes, and `nil` where it is not one of the
/// forms this describes. A range is looked for first.
func memberKeyType(_ state: ValidationState, _ t1: Type1, _ depth: Int) -> MemberKeyType? {
    if let (lower, upper, isInclusive) = memberKeyRange(state, t1, depth) {
        return .range(lower, upper, isInclusive)
    }
    return memberKeyTypename(state, t1, depth).map { .rule($0) }
}

/// The range a member key denotes, written out, parenthesized, under a name
/// standing for one, or under a generic parameter instantiated with one.
func memberKeyRange(_ state: ValidationState, _ t1: Type1, _ depth: Int) -> (Type2, Type2, Bool)? {
    var paramsSeen: [String] = []
    var rulesSeen: [String] = []
    return memberKeyRange(state, t1, &paramsSeen, &rulesSeen, 0, depth)
}

private func memberKeyRange(
    _ state: ValidationState,
    _ t1: Type1,
    _ paramsSeen: inout [String],
    _ rulesSeen: inout [String],
    _ depth: Int,
    _ maxDepth: Int
) -> (Type2, Type2, Bool)? {
    // A chain of names, parameters and parentheses, followed in a loop.
    var t1 = t1
    var depth = depth
    while true {
        if let op = t1.operator {
            if case .rangeOp(let isInclusive, _) = op.operator {
                return (t1.type2, op.type2, isInclusive)
            }
            // A control operator applies to what the type it targets denotes.
            return nil
        }
        if depth >= maxDepth {
            return nil
        }

        // A choice between types denotes their union, not a single range.
        func soleChoice(_ t: Type) -> Type1? {
            t.typeChoices.count == 1 ? t.typeChoices[0].type1 : nil
        }

        switch t1.type2 {
        case .parenthesizedType(let pt, _, _, _):
            guard let sole = soleChoice(pt) else { return nil }
            t1 = sole
            depth += 1
        case .typename(let ident, nil, _):
            // A generic parameter stands for its argument, substituted once.
            if !paramsSeen.contains(ident.ident), let arg = state.genericArgument(for: ident) {
                paramsSeen.append(ident.ident)
                t1 = arg
                depth += 1
                continue
            }
            // A name reached again is defined in terms of itself.
            if rulesSeen.contains(ident.ident) {
                return nil
            }
            rulesSeen.append(ident.ident)

            var value: Type?
            for rule in state.schema.rules(named: ident) {
                guard case .type(let rule, _, _, _) = rule else { continue }
                // A name extended by `/=` stands for a choice, and a generic
                // rule for what one instantiation of it does.
                if rule.isTypeChoiceAlternate || rule.genericParams != nil {
                    return nil
                }
                value = rule.value
            }
            guard let value, let sole = soleChoice(value) else { return nil }
            t1 = sole
            depth += 1
        default:
            return nil
        }
    }
}

/// The name of the rule a member key stands for, written out, parenthesized,
/// or under a generic parameter instantiated with one.
func memberKeyTypename(_ state: ValidationState, _ t1: Type1, _ depth: Int) -> Identifier? {
    var paramsSeen: [String] = []
    return memberKeyTypename(state, t1, &paramsSeen, 0, depth)
}

private func memberKeyTypename(
    _ state: ValidationState,
    _ t1: Type1,
    _ paramsSeen: inout [String],
    _ depth: Int,
    _ maxDepth: Int
) -> Identifier? {
    var t1 = t1
    var depth = depth
    while true {
        // A control operator applies to what the type it targets denotes.
        if t1.operator != nil {
            return nil
        }
        // Unwrapping parentheses and substituting a generic argument each go
        // a step deeper; naming the rule does not.
        let atTheBound = depth >= maxDepth

        switch t1.type2 {
        case .parenthesizedType(let pt, _, _, _) where !atTheBound:
            // A choice between types is not a single name.
            guard pt.typeChoices.count == 1 else { return nil }
            t1 = pt.typeChoices[0].type1
            depth += 1
        case .typename(let ident, nil, _):
            if !paramsSeen.contains(ident.ident), let arg = state.genericArgument(for: ident) {
                if atTheBound {
                    return nil
                }
                paramsSeen.append(ident.ident)
                t1 = arg
                depth += 1
                continue
            }
            switch ruleFromIdent(state.schema, ident) {
            case .type(let rule, _, _, _)? where rule.genericParams == nil:
                return ident
            case nil where namesAPreludeType(ident):
                return ident
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

/// Whether `ident` is a standard prelude name that states a type: every one
/// but `true` and `false`, which each stand for a single data item.
private func namesAPreludeType(_ ident: Identifier) -> Bool {
    let token = lookupIdent(ident.ident)
    if case .true = token { return false }
    if case .false = token { return false }
    return token.inStandardPrelude() != nil
}

/// The error a group entry whose member key denotes a type reports when the
/// number of map entries whose key is of that type is not one its occurrence
/// indicator admits, and `nil` when it is.
func memberKeyCountError(_ model: DataModel, _ occurrence: Occur?, _ matched: Int, _ keyDesc: String) -> String? {
    let noun = model.mapNoun

    switch occurrence {
    case nil where matched == 0:
        return "\(noun) requires entry with key \(keyDesc)"
    case .oneOrMore? where matched == 0:
        return "\(noun) requires at least one entry with key \(keyDesc)"
    case .exact(let lower, let upper, _)?:
        let isExact = lower != nil && upper != nil && lower == upper
        if let lower, matched < Int(clamping: lower) {
            return isExact
                ? "\(noun) must contain exactly \(lower) entries with key \(keyDesc)"
                : "\(noun) must contain at least \(lower) entries with key \(keyDesc)"
        }
        if let upper, matched > Int(clamping: upper) {
            return isExact
                ? "\(noun) must contain exactly \(upper) entries with key \(keyDesc)"
                : "\(noun) must contain no more than \(upper) entries with key \(keyDesc)"
        }
        return nil
    default:
        return nil
    }
}

/// How many of the map entries whose key a group entry answers for the entry
/// accounts for.
func memberKeyAccountedCount(_ occurrence: Occur?, _ matched: Int) -> Int {
    switch occurrence {
    case .optional?, nil: return min(matched, 1)
    case .exact(_, let upper?, _)?: return min(matched, Int(clamping: upper))
    default: return matched
    }
}

/// How the errors of a group entry whose member key applies a control operator
/// name the set of keys it answers for.
func memberKeyControlDesc(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) -> String {
    "of type \(target) \(ctrl) \(controller)"
}

/// Whether a member key carries a cut: the colon forms always do, and the
/// arrow form does when written with `^` (RFC 8610 Section 3.5.4).
func memberKeyHasCut(_ entry: ValueMemberKeyEntry) -> Bool {
    switch entry.memberKey {
    case .bareword?, .value?: return true
    case .type1(_, let isCut, _, _, _, _)?: return isCut
    default: return false
    }
}

// MARK: - Arity

/// Whether the rule a group entry names stands for more than one entry.
func ruleSpansMultipleEntries(_ rule: Rule) -> Bool {
    if case .group(let rule, _, _, _) = rule, case .inlineGroup(_, let group, _, _, _) = rule.entry {
        return group.groupChoices.contains { $0.groupEntries.count > 1 }
    }
    return false
}

/// Whether the entry counts ``entryCountsFromGroup(_:_:)`` derives from a group
/// are the complete set of array lengths it admits.
func groupArityIsExact(_ schema: Schema, _ group: Group) -> Bool {
    groupArityIsExact(schema, group, 0)
}

/// Whether the counts one alternative of a group contributes are the complete
/// set of item counts it accounts for.
func groupChoiceArityIsExact(_ schema: Schema, _ gc: GroupChoice) -> Bool {
    gc.groupEntries.allSatisfy { groupEntryArityIsExact(schema, $0.0, 0) }
}

private func groupArityIsExact(_ schema: Schema, _ group: Group, _ depth: Int) -> Bool {
    if depth > ValidationLimits.defaultMaxRuleNesting {
        return false
    }
    return group.groupChoices.allSatisfy { gc in
        gc.groupEntries.allSatisfy { groupEntryArityIsExact(schema, $0.0, depth) }
    }
}

private func groupEntryArityIsExact(_ schema: Schema, _ entry: GroupEntry, _ depth: Int) -> Bool {
    switch entry {
    case .valueMemberKey(let ge, _, _, _):
        if occurrenceCoversMany(ge.occur?.occur) {
            return false
        }
        if let group = unwrappedArrayGroup(schema, ge) {
            return groupArityIsExact(schema, group, depth + 1)
        }
        return true
    case .inlineGroup(let occur, let group, _, _, _):
        return !occurrenceCoversMany(occur?.occur) && groupArityIsExact(schema, group, depth + 1)
    case .typeGroupname(let ge, _, _, _):
        if occurrenceCoversMany(ge.occur?.occur) {
            return false
        }
        if let gr = groupRuleFromIdent(schema, ge.name) {
            return groupEntryArityIsExact(schema, gr.entry, depth + 1)
        }
        return groupChoiceAlternatesFromIdent(schema, ge.name).allSatisfy {
            groupEntryArityIsExact(schema, $0, depth + 1)
        }
    }
}

/// Validates array length and homogeneity against an occurrence indicator.
/// Returns whether the items are then validated one by one, and whether an
/// empty array is allowed; or the errors.
func validateArrayOccurrence(_ occurrence: Occur?, _ entryCounts: [EntryCount]?, _ count: Int) -> Result<(Bool, Bool), ArrayOccurrenceErrors> {
    var iterItems = false
    let allowEmptyArray: Bool
    if case .optional? = occurrence {
        allowEmptyArray = true
    } else {
        allowEmptyArray = false
    }

    var errors: [String] = []

    switch occurrence {
    case .zeroOrMore?:
        iterItems = true
    case .oneOrMore?:
        if count == 0 {
            errors.append("array must have at least one item")
        } else {
            iterItems = true
        }
    case .exact(let lower, let upper, _)?:
        if let lower {
            if let upper {
                if lower == upper && count != Int(clamping: lower) {
                    errors.append("array must have exactly \(lower) items")
                }
                if count < Int(clamping: lower) || count > Int(clamping: upper) {
                    errors.append("array must have between \(lower) and \(upper) items")
                }
            } else if count < Int(clamping: lower) {
                errors.append("array must have at least \(lower) items")
            }
        } else if let upper, count > Int(clamping: upper) {
            errors.append("array must have not more than \(upper) items")
        }
        iterItems = true
    case .optional?:
        if count > 1 {
            errors.append("array must have 0 or 1 items")
        }
        iterItems = false
    case nil:
        if count == 0 {
            errors.append("array must have exactly one item")
        } else {
            iterItems = false
        }
    }

    if !iterItems && !allowEmptyArray, let entryCounts {
        if !validateEntryCount(entryCounts, count) {
            if entryCounts.count > 1 {
                let counts = entryCounts.map { String($0.count) }.joined(separator: ", ")
                errors.append("expected array with length matching one of [\(counts)], got \(count)")
            } else {
                for ec in entryCounts {
                    if let occur = ec.entryOccurrence {
                        errors.append("expected array with length per occurrence \(occur)")
                    } else {
                        errors.append("expected array with length \(ec.count), got \(count)")
                    }
                }
            }
        }
    }

    if !errors.isEmpty {
        return .failure(ArrayOccurrenceErrors(messages: errors))
    }
    return .success((iterItems, allowEmptyArray))
}

/// The errors an array's length or homogeneity reports.
struct ArrayOccurrenceErrors: Error {
    var messages: [String]
}

/// The group an unwrapped array type contributes to the group holding it
/// (RFC 8610 Section 3.7).
func unwrappedArrayGroup(_ schema: Schema, _ entry: ValueMemberKeyEntry) -> Group? {
    unwrappedArrayRule(schema, entry)?.2
}

/// The group ``unwrappedArrayGroup(_:_:)`` returns, with the name the entry
/// unwraps and the rule that name resolves to.
func unwrappedArrayRule(_ schema: Schema, _ entry: ValueMemberKeyEntry) -> (Identifier, Rule, Group)? {
    guard entry.memberKey == nil, entry.entryType.typeChoices.count == 1 else { return nil }
    let type1 = entry.entryType.typeChoices[0].type1
    guard type1.operator == nil, case .unwrap(let ident, nil, _, _) = type1.type2 else { return nil }
    guard let rule = unwrapRuleFromIdent(schema, ident), case .type(let typeRule, _, _, _) = rule else { return nil }
    for tc in typeRule.value.typeChoices where tc.type1.operator == nil {
        if case .array(let group, _, _, _) = tc.type1.type2 {
            return (ident, rule, group)
        }
    }
    return nil
}

/// The number of entries a group accounts for, one count for each way its
/// alternatives can match; the occurrence of the second entry is kept alongside.
func entryCountsFromGroup(_ schema: Schema, _ group: Group) -> [EntryCount] {
    group.groupChoices.flatMap { entryCountsFromGroupChoice(schema, $0) }
}

/// The entry counts contributed by one alternative of a group.
func entryCountsFromGroupChoice(_ schema: Schema, _ gc: GroupChoice) -> [EntryCount] {
    var entryOccurrence: Occur?
    for (idx, ge) in gc.groupEntries.enumerated() where idx == 1 {
        entryOccurrence = groupEntryOccur(ge.0)
    }
    return groupChoiceArities(schema, gc).map { EntryCount(count: $0, entryOccurrence: entryOccurrence) }
}

/// The span of the array being validated that one group accounts for.
struct ArrayFrame: Sendable, Equatable {
    /// Index of the first item the group accounts for.
    var cursor: Int
    /// Number of items the group accounts for.
    var budget: Int
    /// Number of items in the array being validated.
    var len: Int
}

/// The error reported when no way of splitting a run of array items between
/// the entries of a group accounts for exactly the items the run holds.
func arrayLengthError(_ arities: [UInt64], _ frame: ArrayFrame) -> String {
    let outside = max(0, frame.len - frame.budget)
    let lengths = arities.map { String(BigUInt($0) + BigUInt(outside)) }
    switch lengths.count {
    case 0: return "expected array with length \(outside), got \(frame.len)"
    case 1: return "expected array with length \(lengths[0]), got \(frame.len)"
    default:
        return "expected array with length matching one of [\(lengths.joined(separator: ", "))], got \(frame.len)"
    }
}

/// The error reported when the number of entries of a map is not one the map
/// type an equality operator holds it to admits.
func mapEntryCountError(_ model: DataModel, _ ctrl: ControlOperator, _ count: EntryCount, _ len: Int) -> String {
    let admitted: String
    if let occur = count.entryOccurrence {
        admitted = "a number of entries the occurrence \(occur) admits"
    } else if count.count == 1 {
        admitted = "1 entry"
    } else {
        admitted = "\(count.count) entries"
    }
    if ctrl == .ne {
        return "expected \(model.mapNoun) with a number of entries other than \(admitted), got \(len)"
    }
    return "expected \(model.mapNoun) with \(admitted), got \(len)"
}

/// Upper bound on the number of ways one group choice is split across its
/// entries before validation stops enumerating them.
let maxArityPlans = 64

private func groupArities(_ schema: Schema, _ group: Group, _ depth: Int) -> [UInt64] {
    normalizeArities(group.groupChoices.flatMap { groupChoiceArities(schema, $0, depth) })
}

/// The set of item counts one alternative of a group accounts for.
func groupChoiceArities(_ schema: Schema, _ gc: GroupChoice) -> [UInt64] {
    groupChoiceArities(schema, gc, 0)
}

private func groupChoiceArities(_ schema: Schema, _ gc: GroupChoice, _ depth: Int) -> [UInt64] {
    var arities: [UInt64] = [0]
    for ge in gc.groupEntries {
        arities = sumArities(arities, groupEntryArities(schema, ge.0, depth))
    }
    return arities
}

/// The set of item counts one group entry accounts for.
func groupEntryArities(_ schema: Schema, _ entry: GroupEntry) -> [UInt64] {
    groupEntryArities(schema, entry, 0)
}

private func groupEntryArities(_ schema: Schema, _ entry: GroupEntry, _ depth: Int) -> [UInt64] {
    if depth > ValidationLimits.defaultMaxRuleNesting {
        return [1]
    }
    if case .exact(_, 0?, _)? = groupEntryOccur(entry) {
        return [0]
    }

    var arities: [UInt64]
    switch entry {
    case .valueMemberKey(let ge, _, _, _):
        if let group = unwrappedArrayGroup(schema, ge) {
            arities = groupArities(schema, group, depth + 1)
        } else {
            arities = [1]
        }
    case .inlineGroup(_, let group, _, _, _):
        arities = groupArities(schema, group, depth + 1)
    case .typeGroupname(let ge, _, _, _):
        arities = []
        let alternates = groupChoiceAlternatesFromIdent(schema, ge.name)
        if let gr = groupRuleFromIdent(schema, ge.name) {
            arities.append(contentsOf: groupEntryArities(schema, gr.entry, depth + 1))
        } else if alternates.isEmpty {
            arities.append(1)
        }
        for alternate in alternates {
            arities.append(contentsOf: groupEntryArities(schema, alternate, depth + 1))
        }
    }

    if occurrenceAdmitsAbsence(groupEntryOccur(entry)) {
        arities.append(0)
    }
    return normalizeArities(arities)
}

/// Whether a group entry accounts for no items of an array at all.
func entryAccountsForNoItems(_ schema: Schema, _ entry: GroupEntry) -> Bool {
    switch entry {
    case .valueMemberKey:
        if case .exact(_, 0?, _)? = groupEntryOccur(entry) {
            return true
        }
        return false
    default:
        return groupEntryArities(schema, entry) == [0]
    }
}

private func sumArities(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    var sums: [UInt64] = []
    sums.reserveCapacity(a.count * b.count)
    for x in a {
        for y in b {
            sums.append(x + y)
        }
    }
    return normalizeArities(sums)
}

private func normalizeArities(_ arities: [UInt64]) -> [UInt64] {
    var sorted = arities.sorted()
    var index = 1
    while index < sorted.count {
        if sorted[index] == sorted[index - 1] {
            sorted.remove(at: index)
        } else {
            index += 1
        }
    }
    return sorted
}

/// Assignments of one admissible count to each entry of a group choice that
/// together account for exactly `budget` items, in the order the entries are
/// written, at most `limit` of them.
func entryArityPlans(_ entryArities: [[UInt64]], _ budget: UInt64, _ limit: Int) -> [[UInt64]] {
    var suffix = [[UInt64]](repeating: [0], count: entryArities.count + 1)
    for idx in stride(from: entryArities.count - 1, through: 0, by: -1) {
        suffix[idx] = sumArities(entryArities[idx], suffix[idx + 1])
    }

    var plans: [[UInt64]] = []
    var plan: [UInt64] = []
    extendArityPlans(entryArities, suffix, 0, budget, &plan, &plans, limit)
    return plans
}

private func extendArityPlans(
    _ entryArities: [[UInt64]],
    _ suffix: [[UInt64]],
    _ idx: Int,
    _ remaining: UInt64,
    _ plan: inout [UInt64],
    _ plans: inout [[UInt64]],
    _ limit: Int
) {
    if plans.count >= limit {
        return
    }
    if idx == entryArities.count {
        if remaining == 0 {
            plans.append(plan)
        }
        return
    }
    for arity in entryArities[idx] {
        if arity > remaining {
            break
        }
        if !suffix[idx + 1].contains(remaining - arity) {
            continue
        }
        plan.append(arity)
        extendArityPlans(entryArities, suffix, idx + 1, remaining - arity, &plan, &plans, limit)
        plan.removeLast()
        if plans.count >= limit {
            return
        }
    }
}

/// Whether an array of `numEntries` items has one of the lengths a group of
/// exact arity admits.
func validateExactEntryCount(_ validEntryCounts: [EntryCount], _ numEntries: Int) -> Bool {
    validEntryCounts.contains { ec in
        if numEntries == Int(ec.count) {
            return true
        }
        if case .exact(let lower, let upper, _)? = ec.entryOccurrence {
            switch (lower, upper) {
            case (let lower?, let upper?): return numEntries >= Int(clamping: lower) && numEntries <= Int(clamping: upper)
            case (let lower?, nil): return numEntries >= Int(clamping: lower)
            case (nil, let upper?): return numEntries <= Int(clamping: upper)
            case (nil, nil): return false
            }
        }
        return false
    }
}

/// Whether `numEntries` is one of the valid entry counts.
func validateEntryCount(_ validEntryCounts: [EntryCount], _ numEntries: Int) -> Bool {
    validEntryCounts.contains { ec in
        if numEntries == Int(ec.count) {
            return true
        }
        switch ec.entryOccurrence {
        case .zeroOrMore?, .optional?:
            return true
        case .oneOrMore? where numEntries > 0:
            return true
        case .exact(let lower, let upper, _)?:
            if let lower {
                if let upper {
                    return numEntries >= Int(clamping: lower) && numEntries <= Int(clamping: upper)
                }
                return numEntries >= Int(clamping: lower)
            } else if let upper {
                return numEntries <= Int(clamping: upper)
            }
            return false
        default:
            return false
        }
    }
}

/// An entry count.
struct EntryCount: Sendable {
    /// Count.
    var count: UInt64
    /// Optional occurrence.
    var entryOccurrence: Occur?
}

// MARK: - Matcher bookkeeping

/// One map pair the map matcher has given to a group entry standing for a
/// single occurrence, with what is needed to test the entry against another
/// pair when the claims are reassigned.
struct MapSingleClaim {
    var entry: ValueMemberKeyEntry
    var genericRules: [GenericRule]
    var evalGenericRule: String?
    var pair: Int
}

/// The ownership ledger of the map matcher: which physical pairs of the map are
/// claimed (by index, never by key equality, so NaN keys and duplicate keys are
/// each their own pair), and which claims are single-occurrence claims that can
/// still be reassigned.
struct MapClaims {
    var claimed: [Bool]
    var singles: [MapSingleClaim] = []

    init(_ len: Int) {
        claimed = [Bool](repeating: false, count: len)
    }

    var claimedCount: Int {
        claimed.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}

/// Bookkeeping for one run of the map matcher.
struct MapMatchCtx {
    /// What the most recent failing member reported.
    var errors: [ErrorRecord] = []
    /// Group rule names being expanded, each with the claimed pair count at the
    /// time; guards against recursion that claims no pair.
    var activeGroupRefs: [(String, Int)] = []
    /// For a pair whose key an entry admitted but whose value it did not, what
    /// that value reported, keyed by pair.
    var pairFailures: [Int: [ErrorRecord]] = [:]
    /// Pairs an optional single entry declined because their value failed.
    var declinedPairs: Set<Int> = []
}

/// Finds an augmenting path in the member-to-pair compatibility graph (the
/// depth-first form of maximum bipartite matching).
func augmentAssignment(_ claimSlot: Int, _ compatibility: [[Bool]], _ visited: inout [Bool], _ owners: inout [Int?]) -> Bool {
    for pairSlot in 0..<compatibility[claimSlot].count {
        if !compatibility[claimSlot][pairSlot] || visited[pairSlot] {
            continue
        }
        visited[pairSlot] = true
        if owners[pairSlot].map({ augmentAssignment($0, compatibility, &visited, &owners) }) ?? true {
            owners[pairSlot] = claimSlot
            return true
        }
    }
    return false
}

/// Bookkeeping for the array sequence matcher (RFC 8610 Appendix A).
struct ArraySeqCtx {
    /// Farthest item index at which a leaf failed, with what it reported.
    var bestFailure: (Int, [ErrorRecord])?
    /// Group rule names being expanded, each with the cursor at the time;
    /// guards against recursion that consumes no item.
    var activeGroupRefs: [(String, Int)] = []

    /// Records a leaf failure at item `idx`, keeping only the farthest one.
    mutating func noteFailure(_ idx: Int, _ errors: [ErrorRecord]) {
        if bestFailure.map({ idx >= $0.0 }) ?? true {
            bestFailure = (idx, errors)
        }
    }
}

/// The bytes a byte string literal denotes, whichever notation it is written
/// in.
func byteStringLiteralContent(_ bv: ByteValue) -> [UInt8] {
    switch bv {
    case .utf8(let b), .b16(let b), .b64(let b): return b
    }
}

// MARK: - Regular expressions

/// The characters a regular expression gives a meaning of their own.
private let regexMetaCharacters: Set<Character> = [
    "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$", "#", "&", "-", "~",
]

/// A `.regexp` controller rewritten into the dialect it is matched in.
///
/// RFC 8610 Section 3.8.3 writes the controller in XSD regular expression
/// syntax, where an escaped character that is not a metacharacter stands for
/// itself; the escape is removed (`\d` keeps its meaning). Lookaround, which
/// XSD does not have, makes the controller malformed (`nil`).
func formatRegex(_ input: String) -> String? {
    var formatted = input
    var unescape: [String] = []
    let scalars = Array(formatted.unicodeScalars)
    // The position is counted in bytes, and the scalar after it read by
    // scalar count, as the rewrite this follows does.
    var byteIndex = 0
    for scalar in scalars {
        if scalar == "\\" {
            let next = byteIndex + 1
            if next < scalars.count {
                let following = Character(scalars[next])
                if !regexMetaCharacters.contains(following) && following != "d" {
                    unescape.append("\\" + String(following))
                }
            }
        }
        byteIndex += String(scalar).utf8.count
    }

    for replace in unescape {
        formatted = replacingBytes(formatted, replace, String(replace.unicodeScalars.dropFirst()))
    }

    for find in ["?=", "?!", "?<=", "?<!"] where containsBytes(formatted, find) {
        return nil
    }

    return formatted
}

/// Whether `text` holds `needle` as a run of its bytes.
func containsBytes(_ text: String, _ needle: String) -> Bool {
    let haystack = Array(text.utf8)
    let pattern = Array(needle.utf8)
    if pattern.isEmpty { return true }
    if pattern.count > haystack.count { return false }
    for start in 0...(haystack.count - pattern.count) where haystack[start..<(start + pattern.count)].elementsEqual(pattern) {
        return true
    }
    return false
}

/// `text` with every non-overlapping run of the bytes of `needle`, from the
/// left, replaced by the bytes of `replacement`.
func replacingBytes(_ text: String, _ needle: String, _ replacement: String) -> String {
    let haystack = Array(text.utf8)
    let pattern = Array(needle.utf8)
    guard !pattern.isEmpty, pattern.count <= haystack.count else { return text }
    var out: [UInt8] = []
    var index = 0
    while index < haystack.count {
        if index + pattern.count <= haystack.count && haystack[index..<(index + pattern.count)].elementsEqual(pattern) {
            out.append(contentsOf: replacement.utf8)
            index += pattern.count
        } else {
            out.append(haystack[index])
            index += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Rendering types for messages

/// The data model a validator reads documents in; a rejection names the shape
/// of a type by the noun the document's vocabulary uses.
enum DataModel {
    /// CBOR data items.
    case cbor
    /// JSON values.
    case json

    /// The noun the model uses for a data item made of key-value pairs.
    var mapNoun: String {
        switch self {
        case .cbor: return "map"
        case .json: return "object"
        }
    }
}

/// Group entries a rendered type keeps before the rest is counted.
let maxRenderedGroupEntries = 4

/// What stands in a rendered group for the entries past the bound.
private let groupElision = "…"

/// A type rendered on one line for an error message, without comments, with
/// every group cut down to its head, and bounded as a rendered data item is.
func typeHead(_ t2: Type2) -> String {
    var out = ""
    writeType2Head(t2, &out)
    return elided(out)
}

/// A type with all its alternatives, rendered as ``typeHead(_:)`` renders one
/// and joined by ` / `.
func alternativesHead(_ t: Type) -> String {
    var out = ""
    writeTypeAlternativesHead(t, &out)
    return elided(out)
}

/// The type a data item was held to, led by the noun for its shape.
func expectedType(_ model: DataModel, _ t2: Type2) -> String {
    let noun: String
    switch t2 {
    case .map: noun = model.mapNoun
    case .array: noun = "array"
    case .taggedData: noun = "tagged data"
    case .intValue, .uintValue, .floatValue, .textValue, .utf8ByteString, .b16ByteString, .b64ByteString:
        noun = "value"
    default: noun = "type"
    }
    return "\(noun) \(typeHead(t2))"
}

/// The alternatives a data item was held to: a single alternative under no
/// operator as ``expectedType(_:_:)`` names it, a choice as a type.
func expectedAlternatives(_ model: DataModel, _ t: Type) -> String {
    if t.typeChoices.count == 1 && t.typeChoices[0].type1.operator == nil {
        return expectedType(model, t.typeChoices[0].type1.type2)
    }
    return "type \(alternativesHead(t))"
}

/// The rejection reported when a data item is not of the type it was held to.
func expectedTypeError(_ model: DataModel, _ target: Type2, _ got: String) -> String {
    "expected \(expectedType(model, target)), got \(got)"
}

/// The rejection reported when an array has no item at the index a type was to
/// be matched against.
func expectedItemError(_ model: DataModel, _ target: Type2, _ idx: Int) -> String {
    "expected \(expectedType(model, target)) at index \(idx)"
}

/// The rejection reported when a map holds no entry under a key the group
/// names.
func missingKeyError(_ model: DataModel, _ key: String) -> String {
    "\(model.mapNoun) missing key: \(key)"
}

/// The rejection reported when a map holds no entry whose key is of the type a
/// member key states.
func missingKeyTypeError(_ model: DataModel, _ keyType: String) -> String {
    "\(model.mapNoun) requires entry key of type \(keyType)"
}

private func writeType2Head(_ t2: Type2, _ out: inout String) {
    switch t2 {
    case .map(let group, _, _, _):
        out += "{"
        writeGroupHead(group, &out)
        out += "}"
    case .array(let group, _, _, _):
        out += "["
        writeGroupHead(group, &out)
        out += "]"
    case .parenthesizedType(let pt, _, _, _):
        out += "("
        writeTypeAlternativesHead(pt, &out)
        out += ")"
    case .taggedData(let tag, let t, _, _, _):
        out += "#6"
        if let tag {
            out += ".\(tag)"
        }
        out += "("
        writeTypeAlternativesHead(t, &out)
        out += ")"
    case .choiceFromInlineGroup(let group, _, _, _, _):
        out += "&("
        writeGroupHead(group, &out)
        out += ")"
    case .typename(let ident, let genericArgs, _):
        out += ident.description
        writeGenericArgsHead(genericArgs, &out)
    case .unwrap(let ident, let genericArgs, _, _):
        out += "~" + ident.description
        writeGenericArgsHead(genericArgs, &out)
    case .choiceFromGroup(let ident, let genericArgs, _, _):
        out += "&" + ident.description
        writeGenericArgsHead(genericArgs, &out)
    default:
        out += t2.description
    }
}

private func writeTypeAlternativesHead(_ t: Type, _ out: inout String) {
    for (idx, tc) in t.typeChoices.enumerated() {
        if idx > 0 {
            out += " / "
        }
        writeType1Head(tc.type1, &out)
    }
}

private func writeType1Head(_ t1: Type1, _ out: inout String) {
    writeType2Head(t1.type2, &out)
    if let op = t1.operator {
        switch op.operator {
        case .rangeOp: out += op.operator.description
        case .ctlOp: out += " \(op.operator.description) "
        }
        writeType2Head(op.type2, &out)
    }
}

private func writeGroupHead(_ group: Group, _ out: inout String) {
    for (idx, gc) in group.groupChoices.enumerated() {
        if idx > 0 {
            out += "//"
        }
        writeGroupChoiceHead(gc, &out)
    }
}

private func writeGroupChoiceHead(_ gc: GroupChoice, _ out: inout String) {
    let entries = gc.groupEntries
    for (idx, entry) in entries.prefix(maxRenderedGroupEntries).enumerated() {
        out += idx == 0 ? " " : ", "
        writeGroupEntryHead(entry.0, &out)
    }
    if entries.count > maxRenderedGroupEntries {
        out += ", \(groupElision) \(entries.count - maxRenderedGroupEntries) more"
    }
    if !entries.isEmpty {
        out += " "
    }
}

private func writeGroupEntryHead(_ entry: GroupEntry, _ out: inout String) {
    switch entry {
    case .valueMemberKey(let ge, _, _, _):
        if let occur = ge.occur {
            out += "\(occur.occur) "
        }
        if let mk = ge.memberKey {
            writeMemberKeyHead(mk, &out)
            out += " "
        }
        writeTypeAlternativesHead(ge.entryType, &out)
    case .typeGroupname(let ge, _, _, _):
        if let occur = ge.occur {
            out += "\(occur.occur) "
        }
        out += ge.name.description
        writeGenericArgsHead(ge.genericArgs, &out)
    case .inlineGroup(let occur, let group, _, _, _):
        if let occur {
            out += "\(occur.occur) "
        }
        out += "("
        writeGroupHead(group, &out)
        out += ")"
    }
}

private func writeMemberKeyHead(_ mk: MemberKey, _ out: inout String) {
    switch mk {
    case .type1(let t1, let isCut, _, _, _, _):
        writeType1Head(t1, &out)
        out += " "
        if isCut {
            out += "^ "
        }
        out += "=>"
    case .bareword(let ident, _, _, _):
        out += ident.description + ":"
    case .value(let value, _, _, _):
        out += value.description + ":"
    case .nonMemberKey(.group(let group), _, _):
        writeGroupHead(group, &out)
    case .nonMemberKey(.type(let t), _, _):
        writeTypeAlternativesHead(t, &out)
    }
}

private func writeGenericArgsHead(_ genericArgs: GenericArgs?, _ out: inout String) {
    guard let ga = genericArgs else { return }
    out += "<"
    for (idx, arg) in ga.args.enumerated() {
        if idx > 0 {
            out += ", "
        }
        writeType1Head(arg.arg, &out)
    }
    out += ">"
}

/// What the items of an array are each matched against, named for an error
/// message.
enum ArrayItemToken {
    case value(Value)
    case range(Type2, Type2, Bool)
    /// A map type whose group the items are matched against.
    case map(Type2)
    case identifier(Identifier)
    case taggedData(Type2)
    case control(Type2, ControlOperator, Type2)
    /// A type naming an array among its alternatives, matched against each
    /// item as the one type it is.
    case type(Type)

    func errorMessage(_ model: DataModel, _ idx: Int?) -> String {
        let suffix = idx.map { " at index \($0)" } ?? ""
        switch self {
        case .value(let value):
            return "expected value \(value)\(suffix)"
        case .range(let lower, let upper, let isInclusive):
            return "expected range lower \(lower) upper \(upper) inclusive \(isInclusive)\(suffix)"
        case .map(let t2), .taggedData(let t2):
            if let idx {
                return expectedItemError(model, t2, idx)
            }
            return "expected \(expectedType(model, t2))"
        case .identifier(let ident):
            return "expected type \(ident)\(suffix)"
        case .control(let target, let ctrl, let controller):
            return "expected \(typeHead(target)) \(ctrl) \(typeHead(controller))\(suffix)"
        case .type(let t):
            return "expected \(expectedAlternatives(model, t))\(suffix)"
        }
    }
}
