// A CDDL AST visitor.
//
// Every `visit…` requirement has a default implementation that calls the
// matching `walk…` function, which visits the node's children. A conforming
// type overrides the visits it cares about and calls the `walk…` function
// itself to keep descending. Throwing from a visit stops the walk.

/// CDDL AST visitor.
protocol Visitor {
    /// Visit CDDL.
    mutating func visitCDDL(_ cddl: CDDL) throws
    /// Visit rule.
    mutating func visitRule(_ rule: Rule) throws
    /// Visit identifier.
    mutating func visitIdentifier(_ ident: Identifier) throws
    /// Visit value.
    mutating func visitValue(_ value: Value) throws
    /// Visit type rule.
    mutating func visitTypeRule(_ tr: TypeRule) throws
    /// Visit group rule.
    mutating func visitGroupRule(_ gr: GroupRule) throws
    /// Visit type.
    mutating func visitType(_ t: Type) throws
    /// Visit type choice.
    mutating func visitTypeChoice(_ tc: TypeChoice) throws
    /// Visit type1.
    mutating func visitType1(_ t1: Type1) throws
    /// Visit operator.
    mutating func visitOperator(_ target: Type1, _ o: Operator) throws
    /// Visit range or control operator.
    mutating func visitRangeCtlOp(_ op: RangeCtlOp, _ target: Type1, _ controller: Type2) throws
    /// Visit range.
    mutating func visitRange(_ lower: Type2, _ upper: Type2, _ isInclusive: Bool) throws
    /// Visit control operator.
    mutating func visitControlOperator(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) throws
    /// Visit type2.
    mutating func visitType2(_ t2: Type2) throws
    /// Visit group.
    mutating func visitGroup(_ g: Group) throws
    /// Visit group choice.
    mutating func visitGroupChoice(_ gc: GroupChoice) throws
    /// Visit group entry.
    mutating func visitGroupEntry(_ entry: GroupEntry) throws
    /// Visit value member key entry.
    mutating func visitValueMemberKeyEntry(_ entry: ValueMemberKeyEntry) throws
    /// Visit type/group name entry.
    mutating func visitTypeGroupnameEntry(_ entry: TypeGroupnameEntry) throws
    /// Visit inline group entry.
    mutating func visitInlineGroupEntry(_ occur: Occurrence?, _ g: Group) throws
    /// Visit occurrence.
    mutating func visitOccurrence(_ o: Occurrence) throws
    /// Visit member key.
    mutating func visitMemberKey(_ mk: MemberKey) throws
    /// Visit generic arguments.
    mutating func visitGenericArgs(_ args: GenericArgs) throws
    /// Visit generic argument.
    mutating func visitGenericArg(_ arg: GenericArg) throws
    /// Visit generic parameters.
    mutating func visitGenericParams(_ params: GenericParams) throws
    /// Visit generic parameter.
    mutating func visitGenericParam(_ param: GenericParam) throws
    /// Visit non-member key.
    mutating func visitNonMemberKey(_ nmk: NonMemberKey) throws
}

extension Visitor {
    mutating func visitCDDL(_ cddl: CDDL) throws { try walkCDDL(&self, cddl) }
    mutating func visitRule(_ rule: Rule) throws { try walkRule(&self, rule) }
    mutating func visitIdentifier(_ ident: Identifier) throws {}
    mutating func visitValue(_ value: Value) throws {}
    mutating func visitTypeRule(_ tr: TypeRule) throws { try walkTypeRule(&self, tr) }
    mutating func visitGroupRule(_ gr: GroupRule) throws { try walkGroupRule(&self, gr) }
    mutating func visitType(_ t: Type) throws { try walkType(&self, t) }
    mutating func visitTypeChoice(_ tc: TypeChoice) throws { try walkTypeChoice(&self, tc) }
    mutating func visitType1(_ t1: Type1) throws { try walkType1(&self, t1) }
    mutating func visitOperator(_ target: Type1, _ o: Operator) throws {
        try walkOperator(&self, target, o)
    }
    mutating func visitRangeCtlOp(_ op: RangeCtlOp, _ target: Type1, _ controller: Type2) throws {
        try walkRangeCtlOp(&self, op, target, controller)
    }
    mutating func visitRange(_ lower: Type2, _ upper: Type2, _ isInclusive: Bool) throws {
        try walkRange(&self, lower, upper)
    }
    mutating func visitControlOperator(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) throws {
        try walkControlOperator(&self, target, controller)
    }
    mutating func visitType2(_ t2: Type2) throws { try walkType2(&self, t2) }
    mutating func visitGroup(_ g: Group) throws { try walkGroup(&self, g) }
    mutating func visitGroupChoice(_ gc: GroupChoice) throws { try walkGroupChoice(&self, gc) }
    mutating func visitGroupEntry(_ entry: GroupEntry) throws { try walkGroupEntry(&self, entry) }
    mutating func visitValueMemberKeyEntry(_ entry: ValueMemberKeyEntry) throws {
        try walkValueMemberKeyEntry(&self, entry)
    }
    mutating func visitTypeGroupnameEntry(_ entry: TypeGroupnameEntry) throws {
        try walkTypeGroupnameEntry(&self, entry)
    }
    mutating func visitInlineGroupEntry(_ occur: Occurrence?, _ g: Group) throws {
        try walkInlineGroupEntry(&self, occur, g)
    }
    mutating func visitOccurrence(_ o: Occurrence) throws {}
    mutating func visitMemberKey(_ mk: MemberKey) throws { try walkMemberKey(&self, mk) }
    mutating func visitGenericArgs(_ args: GenericArgs) throws { try walkGenericArgs(&self, args) }
    mutating func visitGenericArg(_ arg: GenericArg) throws { try walkGenericArg(&self, arg) }
    mutating func visitGenericParams(_ params: GenericParams) throws {
        try walkGenericParams(&self, params)
    }
    mutating func visitGenericParam(_ param: GenericParam) throws { try walkGenericParam(&self, param) }
    mutating func visitNonMemberKey(_ nmk: NonMemberKey) throws { try walkNonMemberKey(&self, nmk) }
}

/// Walk CDDL.
func walkCDDL<V: Visitor>(_ visitor: inout V, _ cddl: CDDL) throws {
    for rule in cddl.rules {
        try visitor.visitRule(rule)
    }
}

/// Walk rule.
func walkRule<V: Visitor>(_ visitor: inout V, _ rule: Rule) throws {
    switch rule {
    case .type(let rule, _, _, _): try visitor.visitTypeRule(rule)
    case .group(let rule, _, _, _): try visitor.visitGroupRule(rule)
    }
}

/// Walk type rule.
func walkTypeRule<V: Visitor>(_ visitor: inout V, _ tr: TypeRule) throws {
    try visitor.visitType(tr.value)
}

/// Walk group rule.
func walkGroupRule<V: Visitor>(_ visitor: inout V, _ gr: GroupRule) throws {
    try visitor.visitGroupEntry(gr.entry)
}

/// Walk type.
func walkType<V: Visitor>(_ visitor: inout V, _ t: Type) throws {
    for tc in t.typeChoices {
        try visitor.visitTypeChoice(tc)
    }
}

/// Walk type choice.
func walkTypeChoice<V: Visitor>(_ visitor: inout V, _ tc: TypeChoice) throws {
    try visitor.visitType1(tc.type1)
}

/// Walk type1.
func walkType1<V: Visitor>(_ visitor: inout V, _ t1: Type1) throws {
    if let o = t1.operator {
        try visitor.visitOperator(t1, o)
        return
    }
    try visitor.visitType2(t1.type2)
}

/// Walk operator.
func walkOperator<V: Visitor>(_ visitor: inout V, _ target: Type1, _ o: Operator) throws {
    try visitor.visitRangeCtlOp(o.operator, target, o.type2)
}

/// Walk range or control operator.
func walkRangeCtlOp<V: Visitor>(
    _ visitor: inout V,
    _ op: RangeCtlOp,
    _ target: Type1,
    _ controller: Type2
) throws {
    switch op {
    case .rangeOp(let isInclusive, _):
        try visitor.visitRange(target.type2, controller, isInclusive)
    case .ctlOp(let ctrl, _):
        try visitor.visitControlOperator(target.type2, ctrl, controller)
    }
}

/// Walk range.
func walkRange<V: Visitor>(_ visitor: inout V, _ lower: Type2, _ upper: Type2) throws {
    try visitor.visitType2(lower)
    try visitor.visitType2(upper)
}

/// Walk control operator.
func walkControlOperator<V: Visitor>(_ visitor: inout V, _ target: Type2, _ controller: Type2) throws {
    try visitor.visitType2(target)
    try visitor.visitType2(controller)
}

/// Walk type2.
func walkType2<V: Visitor>(_ visitor: inout V, _ t2: Type2) throws {
    switch t2 {
    case .array(let group, _, _, _):
        try visitor.visitGroup(group)
    case .map(let group, _, _, _):
        try visitor.visitGroup(group)
    case .choiceFromGroup(let ident, let genericArgs, _, _):
        if let genericArgs {
            try visitor.visitGenericArgs(genericArgs)
        }
        try visitor.visitIdentifier(ident)
    case .choiceFromInlineGroup(let group, _, _, _, _):
        try visitor.visitGroup(group)
    case .taggedData(_, let t, _, _, _):
        try visitor.visitType(t)
    case .typename(let ident, _, _):
        try visitor.visitIdentifier(ident)
    case .unwrap(let ident, let genericArgs, _, _):
        if let genericArgs {
            try visitor.visitGenericArgs(genericArgs)
        }
        try visitor.visitIdentifier(ident)
    case .parenthesizedType(let pt, _, _, _):
        try visitor.visitType(pt)
    case .b16ByteString(let value, _):
        try visitor.visitValue(.byte(.b16(value)))
    case .b64ByteString(let value, _):
        try visitor.visitValue(.byte(.b64(value)))
    case .utf8ByteString(let value, _):
        try visitor.visitValue(.byte(.utf8(value)))
    case .floatValue(let value, let notation, _):
        try visitor.visitValue(.float(FloatLiteralValue(value, notation: notation)))
    case .intValue(let value, _):
        try visitor.visitValue(.int(value))
    case .uintValue(let value, _):
        try visitor.visitValue(.uint(value))
    case .textValue(let value, _):
        try visitor.visitValue(.text(value))
    default:
        break
    }
}

/// Walk group.
func walkGroup<V: Visitor>(_ visitor: inout V, _ g: Group) throws {
    for gc in g.groupChoices {
        try visitor.visitGroupChoice(gc)
    }
}

/// Walk group choice.
func walkGroupChoice<V: Visitor>(_ visitor: inout V, _ gc: GroupChoice) throws {
    for (entry, _) in gc.groupEntries {
        try visitor.visitGroupEntry(entry)
    }
}

/// Walk group entry.
func walkGroupEntry<V: Visitor>(_ visitor: inout V, _ entry: GroupEntry) throws {
    switch entry {
    case .valueMemberKey(let ge, _, _, _):
        try visitor.visitValueMemberKeyEntry(ge)
    case .typeGroupname(let ge, _, _, _):
        try visitor.visitTypeGroupnameEntry(ge)
    case .inlineGroup(let occur, let group, _, _, _):
        try visitor.visitInlineGroupEntry(occur, group)
    }
}

/// Walk value member key entry.
func walkValueMemberKeyEntry<V: Visitor>(_ visitor: inout V, _ entry: ValueMemberKeyEntry) throws {
    if let occur = entry.occur {
        try visitor.visitOccurrence(occur)
    }
    if let mk = entry.memberKey {
        try visitor.visitMemberKey(mk)
    }
    try visitor.visitType(entry.entryType)
}

/// Walk type/group name entry.
func walkTypeGroupnameEntry<V: Visitor>(_ visitor: inout V, _ entry: TypeGroupnameEntry) throws {
    if let occur = entry.occur {
        try visitor.visitOccurrence(occur)
    }
    if let genericArgs = entry.genericArgs {
        try visitor.visitGenericArgs(genericArgs)
    }
    try visitor.visitIdentifier(entry.name)
}

/// Walk inline group entry.
func walkInlineGroupEntry<V: Visitor>(_ visitor: inout V, _ occur: Occurrence?, _ g: Group) throws {
    if let occur {
        try visitor.visitOccurrence(occur)
    }
    try visitor.visitGroup(g)
}

/// Walk member key.
func walkMemberKey<V: Visitor>(_ visitor: inout V, _ mk: MemberKey) throws {
    switch mk {
    case .type1(let t1, _, _, _, _, _):
        try visitor.visitType1(t1)
    case .bareword(let ident, _, _, _):
        try visitor.visitIdentifier(ident)
    case .value(let value, _, _, _):
        try visitor.visitValue(value)
    case .nonMemberKey(let nonMemberKey, _, _):
        try visitor.visitNonMemberKey(nonMemberKey)
    }
}

/// Walk generic arguments.
func walkGenericArgs<V: Visitor>(_ visitor: inout V, _ args: GenericArgs) throws {
    for arg in args.args {
        try visitor.visitGenericArg(arg)
    }
}

/// Walk generic argument.
func walkGenericArg<V: Visitor>(_ visitor: inout V, _ arg: GenericArg) throws {
    try visitor.visitType1(arg.arg)
}

/// Walk generic parameters.
func walkGenericParams<V: Visitor>(_ visitor: inout V, _ params: GenericParams) throws {
    for param in params.params {
        try visitor.visitGenericParam(param)
    }
}

/// Walk generic parameter.
func walkGenericParam<V: Visitor>(_ visitor: inout V, _ param: GenericParam) throws {
    try visitor.visitIdentifier(param.param)
}

/// Walk non-member key.
func walkNonMemberKey<V: Visitor>(_ visitor: inout V, _ nmk: NonMemberKey) throws {
    switch nmk {
    case .group(let group): try visitor.visitGroup(group)
    case .type(let t): try visitor.visitType(t)
    }
}
