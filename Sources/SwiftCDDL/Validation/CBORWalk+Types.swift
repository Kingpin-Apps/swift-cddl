import BigInt
import Foundation

// Types matched against a CBOR data item: ranges, the forms of `type2`, names
// and literal values (RFC 8610 Sections 2.2 and 3).

extension CBORInteger {
    /// The integer as an arbitrary-precision value.
    var bigInt: BigInt {
        isNegative ? -1 - BigInt(argument) : BigInt(argument)
    }
}

/// The debug rendering of a tag constraint, `Some(Literal(5))` or `None`.
func tagConstraintDebug(_ constraint: TagConstraint?) -> String {
    switch constraint {
    case nil: return "None"
    case .literal(let value)?: return "Some(Literal(\(value)))"
    case .type(let text)?: return "Some(Type(\(debugString(text))))"
    }
}

extension Level {
    /// Resolves a range bound to the value it denotes.
    func resolveBound(_ bound: Type2) -> Result<RangeBound, RangeBoundError> {
        state.resolveRangeBound(bound, limits.maxRuleNesting)
    }

    // MARK: Ranges

    func visitRange(_ lower: Type2, _ upper: Type2, _ isInclusive: Bool) async throws(CBORValidationError) {
        if item.isArray {
            try await validateArrayItems(.range(lower, upper, isInclusive))
            return
        }

        let l: RangeBound
        let u: RangeBound
        switch (resolveBound(lower), resolveBound(upper)) {
        case (.success(let lb), .success(let ub)):
            l = lb
            u = ub
        case (.success, .failure(let uErr)):
            addError("invalid cddl range. upper value must be a numeric type. got \(upper). Error: \(uErr)")
            return
        case (.failure(let lErr), .success):
            addError("invalid cddl range. lower value must be a numeric type. got \(lower). Error: \(lErr)")
            return
        case (.failure(let lErr), .failure(let uErr)):
            addError(
                "invalid cddl range. upper and lower values must be numeric types. got \(lower) and \(upper). Error: \(lErr) and \(uErr)"
            )
            return
        }

        switch (l, u) {
        case (.int(let l), .int(let u)):
            intRange(l, u, isInclusive)
        case (.float(let l), .float(let u)):
            floatRange(l, u, isInclusive)
        default:
            addError(
                "invalid cddl range. upper and lower values must both be integers or both be floats. got \(l) and \(u)")
        }
    }

    private func intRange(_ l: BigInt, _ u: BigInt, _ isInclusive: Bool) {
        switch item {
        case .byteString(let b, _):
            switch state.ctrl {
            case .size?:
                // Under `.size` a range bounds the length of the byte string.
                let len = b.count
                let bLen = BigInt(len)
                if isInclusive {
                    if bLen < l || bLen > u {
                        addError("expected byte string length to be in the range \(l) <= value <= \(u), got \(len)")
                    }
                } else if bLen < l || bLen >= u {
                    addError("expected byte string length to be in the range \(l) <= value < \(u), got \(len)")
                }
            case .ne?:
                // A range denotes a set of numbers, so no byte string is one of
                // them and the exclusion holds.
                break
            default:
                addError("byte string value cannot be validated against a range without the .size control operator")
            }
        case .textString(let s, _):
            switch state.ctrl {
            case .size?:
                let len = s.utf8.count
                let sLen = BigInt(len)
                if isInclusive {
                    if sLen < l || sLen > u {
                        addError("expected \"\(s)\" string length to be in the range \(l) <= value <= \(u), got \(len)")
                    }
                } else if sLen < l || sLen >= u {
                    addError("expected \"\(s)\" string length to be in the range \(l) <= value < \(u), got \(len)")
                }
            case .ne?:
                break
            default:
                addError("string value cannot be validated against a range without the .size control operator")
            }
        case .unsigned, .negative:
            let integer = item.integerValue!
            let i = integer.bigInt
            let rangeText = "\(l)\(isInclusive ? ".." : "...")\(u)"

            // Under `.size` a range bounds the byte width the value is
            // represented in: the control holds when it fits the widest.
            if state.ctrl == .size {
                let widest = isInclusive ? u : u - 1
                if l > widest {
                    addError("invalid cddl range. the .size range (\(rangeText)) admits no byte width")
                } else if !uintFitsInSize(i, widest) {
                    addError("expected value .size (\(rangeText)), got \(integerDebug(integer))")
                }
                return
            }

            // The controller of `.ne` is a type; a range excludes each value it
            // contains.
            if state.ctrl == .ne {
                let isMember = isInclusive ? (i >= l && i <= u) : (i >= l && i < u)
                if isMember {
                    addError("expected value .ne (\(rangeText)), got \(integerDebug(integer))")
                }
                return
            }

            // A comparison resolves a range controller to the member it has to
            // hold against.
            if let ctrl = state.ctrl, let comparison = Comparison(ctrl) {
                switch comparison.holdsAgainstIntRange(i, l, u, isInclusive) {
                case true?:
                    break
                case false?:
                    addError("expected value \(ctrl) (\(rangeText)), got \(integerDebug(integer))")
                case nil:
                    addError("invalid cddl range. the range (\(rangeText)) holds no values to compare against")
                }
                return
            }

            if isInclusive {
                if i < l || i > u {
                    addError("expected integer to be in range \(l) <= value <= \(u), got \(integerDebug(integer))")
                }
            } else if i < l || i >= u {
                addError("expected integer to be in range \(l) <= value < \(u), got \(integerDebug(integer))")
            }
        default:
            // An integer range denotes integers, so the exclusion holds for
            // anything else.
            if state.ctrl == .ne {
                return
            }
            let op = isInclusive ? "<=" : "<"
            addError("expected value to be in range \(l) \(op) value \(op) \(u), got \(item.debugRendering)")
        }
    }

    private func floatRange(_ l: Double, _ u: Double, _ isInclusive: Bool) {
        if case .float(let f, _) = item {
            // Negated so that a NaN, which compares false against every bound,
            // is rejected.
            let inRange = isInclusive ? (f >= l && f <= u) : (f >= l && f < u)

            if state.ctrl == .ne {
                if inRange {
                    addError(
                        "expected value .ne (\(floatDebug(l))\(isInclusive ? ".." : "...")\(floatDebug(u))), got \(floatDebug(f))"
                    )
                }
                return
            }

            if let ctrl = state.ctrl, let comparison = Comparison(ctrl) {
                let rangeText = "\(floatDebug(l))\(isInclusive ? ".." : "...")\(floatDebug(u))"
                switch comparison.holdsAgainstFloatRange(f, l, u, isInclusive) {
                case true?:
                    break
                case false?:
                    addError("expected value \(ctrl) (\(rangeText)), got \(floatDebug(f))")
                case nil:
                    addError("invalid cddl range. the range (\(rangeText)) holds no values to compare against")
                }
                return
            }

            if !inRange {
                addError(
                    "expected float to be in range \(floatDebug(l)) <= value \(isInclusive ? "<=" : "<") \(floatDebug(u)), got \(floatDebug(f))"
                )
            }
            return
        }

        if state.ctrl == .ne {
            return
        }
        addError(
            "expected value to be in range \(floatDebug(l)) <= value \(isInclusive ? "<=" : "<") \(floatDebug(u)), got \(item.debugRendering)"
        )
    }

    // MARK: Type2

    func visitType2(_ t2: Type2) async throws(CBORValidationError) {
        // Matching one type against one data item is a step of the walk.
        try chargeWork()

        if state.ctrl == .cbor || state.ctrl == .cborseq {
            if case .byteString(let b, _) = item {
                let value: CBORNode
                do {
                    value = state.ctrl == .cbor ? try decodeCBOR(b) : try decodeCBORSequence(b)
                } catch {
                    addError("error decoding embedded CBOR, \(error)")
                    return
                }
                try await walkEmbeddedPayload(value, t2)
            }
            return
        }

        switch t2 {
        case .textValue(let value, _):
            try await visitValue(.text(value))
        case .map(let group, _, _, _):
            try await visitMapType(t2, group)
        case .array(let group, _, _, _):
            try await visitArrayType(t2, group)
        case .choiceFromGroup(let ident, let genericArgs, _, _):
            try await visitChoiceFromGroup(ident, genericArgs)
        case .choiceFromInlineGroup(let group, _, _, _, _):
            state.isGroupToChoiceEnum = true
            try await visitGroup(group)
            state.isGroupToChoiceEnum = false
        case .typename(let ident, let genericArgs, _):
            try await visitTypename(ident, genericArgs)
        case .intValue(let value, _):
            try await visitValue(.int(value))
        case .uintValue(let value, _):
            try await visitValue(.uint(value))
        case .floatValue(let value, let notation, _):
            try await visitValue(.float(FloatLiteralValue(value, notation: notation)))
        case .utf8ByteString(let value, _):
            try await visitValue(.byte(.utf8(value)))
        case .b16ByteString(let value, _):
            try await visitValue(.byte(.b16(value)))
        case .b64ByteString(let value, _):
            try await visitValue(.byte(.b64(value)))
        case .parenthesizedType(let pt, _, _, _):
            try await visitType(pt)
        case .unwrap(let ident, let genericArgs, _, _):
            try await visitUnwrap(ident, genericArgs)
        case .taggedData(let tag, let t, _, _, _):
            try await visitTaggedData(t2, tag, t)
        case .dataMajorType(let mt, let constraint, _):
            visitDataMajorType(mt, constraint)
        case .any:
            break
        }
    }

    /// Walks a payload decoded out of the byte string this level holds
    /// against `t2`, under `.cbor` or `.cborseq`.
    private func walkEmbeddedPayload(_ value: CBORNode, _ t2: Type2) async throws(CBORValidationError) {
        let currentLocation = location
        let level = try embedded(value)
        level.state.isMultiTypeChoice = state.isMultiTypeChoice
        level.state.isMultiGroupChoice = state.isMultiGroupChoice
        level.state.typeGroupNameEntry = state.typeGroupNameEntry
        try await level.walk(.type2(t2))

        if level.errors.isEmpty {
            location = currentLocation
            return
        }
        errors.append(contentsOf: level.errors)
    }

    private func visitMapType(_ t2: Type2, _ group: Group) async throws(CBORValidationError) {
        switch item {
        case .map(let map):
            let m = map.entries
            if state.isMemberKey {
                let currentLocation = location
                for (k, v) in m {
                    let level = try child(k)
                    level.state.isMultiTypeChoice = state.isMultiTypeChoice
                    level.state.isMultiGroupChoice = state.isMultiGroupChoice
                    level.state.typeGroupNameEntry = state.typeGroupNameEntry
                    try await level.walk(.type2(t2))
                    if level.errors.isEmpty {
                        objectValue = v
                        noteValidatedKey(k)
                        location = currentLocation
                        return
                    }
                    errors.append(contentsOf: level.errors)
                }
                return
            }

            // A group with no entries admits only the empty map.
            if group.groupChoices.count == 1 && group.groupChoices[0].groupEntries.isEmpty && !m.isEmpty {
                addError("expected empty map, got \(item.debugRendering)")
                return
            }

            // The map matcher decides whether the map matches; each
            // alternative of the map's own group is held to every pair.
            var ctx = MapMatchCtx()
            var failureErrors: [ErrorRecord] = []
            // "unexpected key" reports for pairs whose value no entry was tried
            // against: nothing else explains them.
            var unexplainedKeys: [ErrorRecord] = []
            for gc in group.groupChoices {
                var claims = MapClaims(m.count)
                if try await mapMatchTopGroupChoice(gc, m, &claims, &ctx) {
                    if claims.claimed.allSatisfy({ $0 }) {
                        state.isCutPresent = false
                        cutValue = nil
                        return
                    }

                    let errorCount = errors.count
                    for (pair, entry) in m.enumerated() where !claims.claimed[pair] {
                        var explained = false
                        if let recorded = ctx.pairFailures.removeValue(forKey: pair) {
                            errors.append(contentsOf: recorded)
                            explained = !ctx.declinedPairs.contains(pair)
                        }
                        addError("unexpected key \(formatPathKey(entry.key))")
                        if !explained, let error = errors.last {
                            unexplainedKeys.append(error)
                        }
                    }
                    failureErrors.append(contentsOf: errors[errorCount...])
                    errors.removeLast(errors.count - errorCount)
                } else {
                    failureErrors.append(contentsOf: ctx.errors)
                    ctx.errors = []
                }
            }

            // The map does not match. Where its keys and values are all
            // scalars, the entry walk reports what is wrong in detail; it is not
            // run over pairs that nest further data, which the matcher has
            // already walked. Where it finds nothing to report, or was not run,
            // the matcher's own account is reported.
            let errorCount = errors.count
            if m.allSatisfy({ isScalarItem($0.key) && isScalarItem($0.value) }) {
                try await validateMapGroupDetail(group, m)
            }
            if errors.count == errorCount {
                errors.append(contentsOf: failureErrors)
            } else {
                for error in unexplainedKeys
                where !errors[errorCount...].contains(where: { $0.reason == error.reason && $0.location == error.location }) {
                    errors.append(error)
                }
            }

            state.isCutPresent = false
            cutValue = nil
        case .array:
            try await validateArrayItems(.map(t2))
        default:
            addError(expectedTypeError(.cbor, t2, item.debugRendering))
        }
    }

    private func visitArrayType(_ t2: Type2, _ group: Group) async throws(CBORValidationError) {
        switch item {
        case .array(let array):
            let a = array.items
            let len = a.count

            // A group with no entries admits only the empty array.
            if group.groupChoices.count == 1 && group.groupChoices[0].groupEntries.isEmpty && len != 0 {
                addError("expected empty array, got \(item.debugRendering)")
                return
            }

            // RFC 8610 Appendix A: the array matches when its item sequence
            // matches the group. Each group choice of the array's own group is
            // held to the whole array, reading `[g1 // g2]` as the choice of
            // `[g1]` and `[g2]`.
            var ctx = ArraySeqCtx()
            var matched: Int?
            for gc in group.groupChoices {
                let end = try await seqMatchGroupChoice(gc, a, 0, &ctx)
                if end == len {
                    return
                }
                if let end, end > (matched ?? -1) {
                    matched = end
                }
            }

            // The array does not match. Where its items are all scalars, the
            // arity-plan walk reports what is wrong in detail; otherwise, or
            // where it finds nothing to report, the matcher's account is.
            let errorCount = errors.count
            if a.allSatisfy(isScalarItem) {
                try await validateArrayGroupDetail(group, a)
            }
            if errors.count == errorCount {
                let stoppedAt = matched ?? 0
                if let (idx, recorded) = ctx.bestFailure, idx >= stoppedAt, !recorded.isEmpty {
                    ctx.bestFailure = nil
                    errors.append(contentsOf: recorded)
                } else if let end = matched {
                    addError(
                        "array validation failed: group \(group) matched the first \(end) item(s), but the array has \(len) items"
                    )
                } else {
                    addError("array validation failed: item sequence does not match group \(group)")
                }
            }
        case .map(let map) where state.isMemberKey:
            let currentLocation = location
            let savedEntryCounts = state.entryCounts
            state.entryCounts = entryCountsFromGroup(state.schema, group)

            for (k, v) in map.entries {
                let level = try child(k)
                level.state.entryCounts = state.entryCounts
                level.state.isMultiTypeChoice = state.isMultiTypeChoice
                level.state.isMultiGroupChoice = state.isMultiGroupChoice
                level.state.typeGroupNameEntry = state.typeGroupNameEntry
                try await level.walk(.type2(t2))
                if level.errors.isEmpty {
                    objectValue = v
                    noteValidatedKey(k)
                    location = currentLocation
                    state.entryCounts = savedEntryCounts
                    return
                }
                errors.append(contentsOf: level.errors)
            }
            state.entryCounts = savedEntryCounts
        default:
            addError(expectedTypeError(.cbor, t2, item.debugRendering))
        }
    }

    /// Resolves a generic rule reference (`name<args>`), `&name<args>` or
    /// `~name<args>` against the item already held, on a level of its own.
    private func visitGenericReference(
        _ ident: Identifier,
        _ rule: Rule,
        _ ga: GenericArgs,
        groupToChoice: Bool
    ) async throws(CBORValidationError) {
        let resolvedArgs = state.resolvedGenericArgs(ga)
        let genericRules = state.genericRulesForInstantiation(rule, ident.ident, resolvedArgs)
        let descentCost = try checkRuleNesting(ident)

        let level = sameItem()
        level.ruleNesting = ruleNesting + 1
        level.descentCost = descentCost
        level.state.genericRules = genericRules
        level.state.evalGenericRule = ident.ident
        if groupToChoice {
            level.state.isGroupToChoiceEnum = true
        }
        level.state.isMultiTypeChoice = state.isMultiTypeChoice
        try await level.walk(.rule(rule))

        errors.append(contentsOf: level.errors)
        adoptMatchedMapKeys(level)
    }

    private func visitChoiceFromGroup(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(CBORValidationError) {
        if let ga = genericArgs, let rule = ruleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: true)
            return
        }

        if groupRuleFromIdent(state.schema, ident) == nil {
            addError("rule \(ident) must be a group rule to turn it into a choice")
            return
        }

        state.isGroupToChoiceEnum = true
        try await visitIdentifier(ident)
        state.isGroupToChoiceEnum = false
    }

    private func visitTypename(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(CBORValidationError) {
        if let ga = genericArgs, let rule = ruleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: false)
            return
        }

        // A name extended by `/=` stands for the choice of its definition and
        // the alternatives, evaluated where the name is resolved.
        if !typeChoiceAlternatesFromIdent(state.schema, ident).isEmpty {
            state.isMultiTypeChoice = true
        }

        try await visitIdentifier(ident)
    }

    private func visitUnwrap(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(CBORValidationError) {
        // An unwrapped prelude tag name stands for the type the tag encloses.
        if case .taggedData(_, let t, _, _, _)? = tagFromToken(lookupIdent(ident.ident)) {
            try await visitType(t)
            return
        }

        if let ga = genericArgs, let rule = unwrapRuleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: false)
            return
        }

        // The rule an unwrapped name resolves to is matched against the item
        // already held, so the reference is a hop like a type name's.
        if let rule = unwrapRuleFromIdent(state.schema, ident) {
            try await visitRuleAgainstItem(ident, rule)
            return
        }

        addError("cannot unwrap identifier \(ident), rule not found")
    }

    private func visitTaggedData(_ t2: Type2, _ tag: TagConstraint?, _ t: Type) async throws(CBORValidationError) {
        switch item {
        case .tagged(let tagged):
            // Without a tag constraint the tag number is left unspecified.
            if let tag, let expected = tag.asLiteral(), expected != tagged.tag {
                addError(expectedTypeError(.cbor, t2, item.debugRendering))
                return
            }
            let level = try child(tagged.content)
            level.state.isMultiTypeChoice = state.isMultiTypeChoice
            level.state.isMultiGroupChoice = state.isMultiGroupChoice
            level.state.typeGroupNameEntry = state.typeGroupNameEntry
            try await level.walk(.type(t))
            errors.append(contentsOf: level.errors)
        case .array:
            try await validateArrayItems(.taggedData(t2))
        default:
            addError(expectedTypeError(.cbor, t2, item.debugRendering))
        }
    }

    private func visitDataMajorType(_ mt: UInt8, _ constraint: TagConstraint?) {
        let otherMajor = {
            "expected major type \(mt) with constraint \(tagConstraintDebug(constraint)), got \(self.item.debugRendering)"
        }
        switch item {
        case .unsigned, .negative:
            let i = item.integerValue!.bigInt
            switch mt {
            case 0:
                if let c = constraint {
                    if let literal = c.asLiteral(), i == BigInt(literal) && i >= 0 {
                        return
                    }
                    addError("expected uint data type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                    return
                }
                if i < 0 {
                    addError("expected uint data type (#\(mt)), got \(item.debugRendering)")
                }
            case 1:
                if let c = constraint {
                    if let literal = c.asLiteral(), i == -BigInt(literal) {
                        return
                    }
                    addError("expected nint type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                    return
                }
                if i >= 0 {
                    addError("expected nint data type (#\(mt)), got \(item.debugRendering)")
                }
            default:
                addError(otherMajor())
            }
        case .byteString(let b, _):
            if mt == 2 {
                if let c = constraint, !c.isLiteral(UInt64(b.count)) {
                    addError("expected byte string type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .textString(let t, _):
            if mt == 3 {
                if let c = constraint, !c.isLiteral(UInt64(t.utf8.count)) {
                    addError("expected text string type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .array(let a):
            if mt == 4 {
                if let c = constraint, !c.isLiteral(UInt64(a.items.count)) {
                    addError("expected array type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .map(let m):
            if mt == 5 {
                if let c = constraint, !c.isLiteral(UInt64(m.entries.count)) {
                    addError("expected map type with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .float:
            if mt == 7 {
                // A float matches only the general `#7`.
                if let c = constraint {
                    addError("expected simple value with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .bool(let b):
            if mt == 7 {
                if let c = constraint, !c.isLiteral(b ? 21 : 20) {
                    addError("expected simple value with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .null, .undefined:
            if mt == 7 {
                if let c = constraint, !c.isLiteral(22) {
                    addError("expected simple value with constraint \(c) (#\(mt).\(c)), got \(item.debugRendering)")
                }
            } else {
                addError(otherMajor())
            }
        case .simple(let s):
            if mt == 7 {
                if let c = constraint, !c.isLiteral(UInt64(s)) {
                    addError("expected simple value with constraint \(c) (#\(mt).\(c)), got simple(\(s))")
                }
            } else {
                addError("expected major type \(mt) with constraint \(tagConstraintDebug(constraint)), got simple(\(s))")
            }
        case .tagged:
            if let constraint {
                addError("expected major type #\(mt).\(constraint), got \(item.debugRendering)")
            } else {
                addError("expected major type #\(mt), got \(item.debugRendering)")
            }
        }
    }

    /// Validates the data item against the tagged types a prelude type name
    /// admits, reporting against the name written in the schema.
    func validateTaggedPreludeType(_ ident: Identifier, _ candidates: [Type2]) async throws(CBORValidationError) {
        var actualTag: UInt64?
        if case .tagged(let tagged) = item {
            actualTag = tagged.tag
        }

        let errorCount = errors.count
        var anyApplied = false

        for candidate in candidates {
            if let actual = actualTag, let expected = literalTagOf(candidate), actual != expected {
                continue
            }
            anyApplied = true
            let candidateErrorCount = errors.count
            try await visitType2(candidate)
            if errors.count == candidateErrorCount {
                errors.removeLast(errors.count - errorCount)
                return
            }
        }

        if !anyApplied {
            addError("expected type \(ident), got \(item.debugRendering)")
        }
    }
}

/// The data item a literal type denotes, where the type is a literal.
func literalType2Value(_ t2: Type2) -> Value? {
    switch t2 {
    case .uintValue(let value, _): return .uint(value)
    case .intValue(let value, _): return .int(value)
    case .textValue(let value, _): return .text(value)
    case .utf8ByteString(let value, _), .b16ByteString(let value, _), .b64ByteString(let value, _):
        return .byte(.b16(value))
    default: return nil
    }
}

/// Whether a data item nests no further data items (a tag nests its content).
func isScalarItem(_ node: CBORNode) -> Bool {
    var node = node
    while true {
        switch node {
        case .array, .map: return false
        case .tagged(let tagged): node = tagged.content
        default: return true
        }
    }
}

/// The data item a CDDL literal stands for.
func tokenValueIntoCBORValue(_ value: Value) -> CBORNode {
    switch value {
    case .uint(let v):
        return .unsigned(v)
    case .int(let v):
        if v.sign == .minus && !v.isZero {
            return .negative(UInt64(-1 - v))
        }
        return .unsigned(UInt64(v))
    case .float(let f):
        return .float(f.value)
    case .text(let t):
        return .textString(t)
    case .byte(let b):
        return .byteString(byteStringLiteralContent(b))
    }
}
