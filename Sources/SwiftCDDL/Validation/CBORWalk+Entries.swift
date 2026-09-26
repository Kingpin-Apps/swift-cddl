import BigInt
import Foundation

// Names, group entries, member keys and literal values matched against a CBOR
// data item (RFC 8610 Sections 3.1, 3.5 and 3.7).

extension Level {
    // MARK: Names

    func visitIdentifier(_ ident: Identifier) async throws(CBORValidationError) {
        // A generic parameter stands for the argument its rule was
        // instantiated with; substituting it consumes no data, so the chain of
        // substitutions answers to the bound on rule nesting.
        if let name = state.evalGenericRule, let gr = state.genericRules.first(where: { $0.name == name }) {
            for (idx, gp) in gr.params.enumerated() where gp == ident.ident {
                if idx < gr.args.count {
                    let arg = gr.args[idx]
                    let descentCost = try checkRuleNesting(ident)
                    let outerDescentCost = self.descentCost
                    ruleNesting += 1
                    self.descentCost = descentCost
                    defer {
                        self.descentCost = outerDescentCost
                        ruleNesting -= 1
                    }
                    try await walk(.type1(arg))
                    return
                }
            }
        }

        // A colon member key names a text key, not a rule.
        if !state.isColonShortcutPresent, let r = ruleOrSocketFromIdent(state.schema, ident) {
            // An entry covering more than one item holds every item of its run
            // to the rule.
            if occurrenceCoversMany(state.occurrence) && item.isArray {
                try await validateArrayItems(.identifier(ident))
                return
            }

            // A type used as an array group entry describes the single item at
            // that entry's position; step into that item.
            if !state.isMemberKey, case .type = r, case .array(let array) = item, let idx = state.groupEntryIdx {
                if idx < array.items.count {
                    let level = try childAt(array.items[idx], .index(idx))
                    level.state.ctrl = state.ctrl
                    level.state.isMultiTypeChoice = state.isMultiTypeChoice
                    try await level.walk(.rule(r))
                    errors.append(contentsOf: level.errors)
                    return
                }
                if occurrenceAdmitsAbsence(state.occurrence) {
                    return
                }
                addError(ItemToken.identifier(ident).errorMessage(idx))
                return
            }

            try await visitRuleAgainstItem(ident, r)
            return
        }

        if isIdentAnyType(state.schema, ident) {
            return
        }

        // A reference to another array type in an array context, other than a
        // bareword member key (which is documentation only in an array).
        if !state.isMemberKey && !state.isColonShortcutPresent, item.isArray,
            case .type(let rule, _, _, _)? = ruleFromIdent(state.schema, ident)
        {
            for tc in rule.value.typeChoices {
                if case .array = tc.type1.type2 {
                    try await visitTypeChoice(tc)
                    return
                }
            }
        }

        // The prelude tagged types decfrac and bigfloat.
        let token = lookupIdent(ident.ident)
        switch token {
        case .decfrac, .bigfloat:
            if let tagged = tagFromToken(token) {
                try await validateTaggedPreludeType(ident, [tagged])
                return
            }
        default:
            break
        }

        try await visitIdentifierAgainstItem(ident, token)
    }

    /// Matches a name that is no rule of the schema against the data item.
    private func visitIdentifierAgainstItem(_ ident: Identifier, _ token: Token) async throws(CBORValidationError) {
        let schema = state.schema
        switch item {
        case .null, .undefined:
            if isIdentNullDataType(schema, ident) {
                return
            }
            reportIdentifierMismatch(ident)
        case .byteString:
            if isIdentByteStringDataType(schema, ident) {
                return
            }
            reportIdentifierMismatch(ident)
        case .bool(let b):
            if isIdentBoolDataType(schema, ident) || identMatchesBoolValue(schema, ident, b) {
                return
            }
            addError("expected type \(ident), got \(item.debugRendering)")
        case .unsigned, .negative:
            let i = item.integerValue!.bigInt
            if let admitted = integerMatchesDataType(schema, ident, i) {
                if !admitted {
                    addError("expected type \(ident), got \(item.debugRendering)")
                }
            } else if isIdentTimeDataType(schema, ident) {
                if !secondsAreRepresentableTime(i) {
                    addError(invalidTimestampError(.whole(i)))
                }
            } else {
                addError("expected type \(ident), got \(item.debugRendering)")
            }
        case .float(let f, _):
            if isIdentFloatDataType(schema, ident) || isIdentNumberDataType(schema, ident) {
                return
            }
            if isIdentTimeDataType(schema, ident) {
                if !floatSecondsAreRepresentableTime(f) {
                    addError(invalidTimestampError(.fractional(f)))
                }
                return
            }
            addError("expected type \(ident), got \(item.debugRendering)")
        case .textString(let s, _):
            if isIdentURIDataType(schema, ident) {
                if let e = uriMismatch(s) {
                    addError(e)
                }
            } else if isIdentB64URLDataType(schema, ident) {
                if let e = base64URLDecodeError(s) {
                    addError("expected base64 URL data type, decoding error: \(e)")
                }
            } else if isIdentTdateDataType(schema, ident) {
                if let e = rfc3339ParseError(s) {
                    addError("expected tdate data type, decoding error: \(e)")
                }
            } else if isIdentStringDataType(schema, ident) {
                return
            } else {
                addError("expected type \(ident), got \(item.debugRendering)")
            }
        case .tagged(let tagged):
            switch tagged.tag {
            case 0:
                if isIdentTdateDataType(schema, ident) {
                    if case .textString(let value, _) = tagged.content {
                        if let e = rfc3339ParseError(value) {
                            addError("expected tdate data type, decoding error: \(e)")
                        }
                    } else {
                        addError("expected type \(ident), got \(item.debugRendering)")
                    }
                } else {
                    addError("expected type \(ident), got \(item.debugRendering)")
                }
            case 1:
                if isIdentTimeDataType(schema, ident) {
                    switch tagged.content {
                    case .unsigned, .negative:
                        let value = tagged.content.integerValue!.bigInt
                        if !secondsAreRepresentableTime(value) {
                            addError(invalidTimestampError(.whole(value)))
                        }
                    case .float(let value, _):
                        if !floatSecondsAreRepresentableTime(value) {
                            addError(invalidTimestampError(.fractional(value)))
                        }
                    default:
                        addError("expected type \(ident), got \(item.debugRendering)")
                    }
                } else {
                    addError("expected type \(ident), got \(item.debugRendering)")
                }
            default:
                // A type name matches a tagged data item only when it stands for
                // a tagged type carrying that tag.
                try await validateTaggedPreludeType(ident, taggedPreludeTypes(token))
            }
        case .array:
            try await validateArrayItems(.identifier(ident))
        case .map(let map):
            try await visitIdentifierAgainstMap(ident, map.entries)
        case .simple:
            reportIdentifierMismatch(ident)
        }
    }

    /// The mismatch of a name against a data item of no type it admits,
    /// naming the member key a cut was detected on, if any.
    private func reportIdentifierMismatch(_ ident: Identifier) {
        if let cut = cutValue {
            cutValue = nil
            addError("cut present for member key \(cut). expected type \(ident), got \(item.debugRendering)")
        } else {
            addError("expected type \(ident), got \(item.debugRendering)")
        }
    }

    /// Matches a name against a map: in member key position, the question
    /// whether the map holds an entry whose key the name admits.
    private func visitIdentifierAgainstMap(_ ident: Identifier, _ m: [(key: CBORNode, value: CBORNode)]) async throws(CBORValidationError) {
        let schema = state.schema

        // A bareword member key is shorthand for the text string of that name
        // (RFC 8610 Section 3.5.1).
        if state.isColonShortcutPresent {
            try await visitValue(.text(ident.ident))
            return
        }

        // `true` and `false` each name one data item, so in member key position
        // they name the entry the map holds under that key.
        if state.isMemberKey && !validatingValue, let b = boolLiteralOfIdent(schema, ident) {
            let key = CBORNode.bool(b)
            let entry = m.first { referenceEquals($0.key, key) }
            if let e = selectMapEntry(entry, ident.ident) {
                addError(e)
            }
            return
        }

        // Outside member key position the name describes the data item, and a
        // map is not a data item of a primitive type.
        if !state.isMemberKey && isIdentPrimitiveDataType(schema, ident) {
            addError("expected type \(ident), got \(item.debugRendering)")
            return
        }

        switch state.occurrence {
        case .optional?, nil:
            // A member key states the type of the keys the entry answers for,
            // and an entry standing for one occurrence answers for one of them.
            if isIdentPrimitiveDataType(schema, ident) && !validatingValue {
                if let entry = m.first(where: { preludeTypeAdmitsMapKey(schema, ident, $0.key) }) {
                    noteValidatedKey(entry.key)
                    objectValue = entry.value
                    location = paths.child(location, .key(formatPathKey(entry.key)))
                } else {
                    addError(missingKeyTypeError(.cbor, ident.description))
                }
                return
            }

            if lookupIdent(ident.ident).inStandardPrelude() != nil {
                addError("expected type \(ident), got \(item.debugRendering)")
                return
            }

            try await visitValue(.text(ident.ident))
        case let occur?:
            var keyErrors: [String] = []

            // An indicator covering more than one occurrence lets the member key
            // answer for every key the group has not otherwise accounted for.
            if isIdentPrimitiveDataType(schema, ident) {
                var values: [CBORNode] = []
                for (k, v) in m {
                    if let keys = validatedKeys, containsKey(keys, k) {
                        continue
                    }
                    if preludeTypeAdmitsMapKey(schema, ident, k) {
                        values.append(v)
                    } else {
                        keyErrors.append("key of type \(ident) required, got \(k.debugRendering)")
                    }
                }
                valuesToValidate = values
            }

            if !keyErrors.isEmpty {
                for e in keyErrors {
                    addError(e)
                }
                return
            }

            switch occur {
            case .zeroOrMore, .oneOrMore:
                if case .oneOrMore = occur, m.isEmpty {
                    addError("map cannot be empty, one or more entries with key type \(ident) required")
                    return
                }
            case .exact(let lower, let upper, _):
                if let values = valuesToValidate {
                    if let lower {
                        if let upper, values.count < Int(clamping: lower) || values.count > Int(clamping: upper) {
                            if lower == upper {
                                addError("object must contain exactly \(lower) entries of key of type \(ident)")
                            } else {
                                addError(
                                    "object must contain between \(lower) and \(upper) entries of key of type \(ident)")
                            }
                            return
                        }
                        if values.count < Int(clamping: lower) {
                            addError("object must contain at least \(lower) entries of key of type \(ident)")
                            return
                        }
                    }
                    if let upper, values.count > Int(clamping: upper) {
                        addError("object must contain no more than \(upper) entries of key of type \(ident)")
                        return
                    }
                    return
                }
            case .optional:
                break
            }

            if isIdentPrimitiveDataType(schema, ident) && !validatingValue {
                if let entry = m.first(where: { preludeTypeAdmitsMapKey(schema, ident, $0.key) }) {
                    noteValidatedKey(entry.key)
                    objectValue = entry.value
                    location = paths.child(location, .key(formatPathKey(entry.key)))
                } else {
                    let isZeroOrMore: Bool
                    if case .zeroOrMore = occur {
                        isZeroOrMore = true
                    } else {
                        isZeroOrMore = false
                    }
                    if (!isZeroOrMore && m.isEmpty) || (isZeroOrMore && !m.isEmpty) {
                        addError(missingKeyTypeError(.cbor, ident.description))
                    }
                }
                return
            }

            if lookupIdent(ident.ident).inStandardPrelude() != nil {
                // An outer member key pass has already collected the values for
                // this prelude key type, and a child level is walking the
                // entry's value type: the map is not a mismatched value here.
                if !validatingValue {
                    addError("expected type \(ident), got \(item.debugRendering)")
                }
                return
            }

            try await visitValue(.text(ident.ident))
        }
    }

    // MARK: Group entries

    func visitValueMemberKeyEntry(_ entry: ValueMemberKeyEntry) async throws(CBORValidationError) {
        if let occur = entry.occur {
            visitOccurrence(occur)
        }

        // An entry naming an unwrapped array type stands for the group that
        // array holds; within the run of items it answers for it is walked as
        // that group.
        if state.arrayFrame != nil, item.isArray, let (ident, rule, group) = unwrappedArrayRule(state.schema, entry) {
            try await resolveAgainstItem(ident, rule, .group(group))
            return
        }

        let currentLocation = location

        // A type in member key position denotes the keys the entry answers for.
        if case .type1(let t1, _, _, _, _, _)? = entry.memberKey,
            let keyType = memberKeyType(state, t1, limits.maxRuleNesting), case .map(let map) = item
        {
            try await validateMapTypedKeyEntry(map.entries, keyType, entry)
            return
        }

        if let memberKey = entry.memberKey {
            let errorCount = errors.count
            state.isMemberKey = true
            try await visitMemberKey(memberKey)
            state.isMemberKey = false

            // Move to the next entry if member key validation fails.
            if errors.count != errorCount {
                state.advanceToNextEntry = true
                return
            }
        }

        if let values = valuesToValidate {
            for v in values {
                let level = try child(v)
                level.state.isMultiTypeChoice = state.isMultiTypeChoice
                level.state.isMultiGroupChoice = state.isMultiGroupChoice
                level.state.typeGroupNameEntry = state.typeGroupNameEntry
                level.validatingValue = true
                try await level.walk(.type(entry.entryType))

                location = currentLocation
                errors.append(contentsOf: level.errors)
                if entry.occur != nil {
                    state.occurrence = nil
                }
            }
            return
        }

        if let v = objectValue {
            objectValue = nil
            let level = try child(v)
            level.state.isMultiTypeChoice = state.isMultiTypeChoice
            level.state.isMultiGroupChoice = state.isMultiGroupChoice
            level.state.typeGroupNameEntry = state.typeGroupNameEntry
            try await level.walk(.type(entry.entryType))

            location = currentLocation
            errors.append(contentsOf: level.errors)
            if entry.occur != nil {
                state.occurrence = nil
            }
            return
        }

        if state.advanceToNextEntry {
            return
        }

        if case .array(let array) = item {
            let a = array.items
            // The array length against the entry counts, checked on the first
            // entry, unless an occurrence indicator is active.
            if state.groupEntryIdx == 0 && state.occurrence == nil, let entryCounts = state.entryCounts {
                let len = a.count
                if !validateEntryCount(entryCounts, len) {
                    if entryCounts.count > 1 {
                        let counts = entryCounts.map { String($0.count) }.joined(separator: ", ")
                        addError("expected array with length matching one of [\(counts)], got \(len)")
                    } else {
                        for ec in entryCounts {
                            if let occur = ec.entryOccurrence {
                                addError("expected array with length per occurrence \(occur)")
                            } else {
                                addError("expected array with length \(ec.count), got \(len)")
                            }
                        }
                    }
                    return
                }
            }

            // An entry standing for a run of items is left to the walk that
            // covers them all; otherwise the entry describes the single item at
            // its index.
            let elementIdx = occurrenceCoversMany(state.occurrence) ? nil : state.groupEntryIdx
            if let idx = elementIdx {
                if idx < a.count {
                    let level = try childAt(a[idx], .index(idx))
                    level.state.isMultiGroupChoice = state.isMultiGroupChoice
                    level.state.typeGroupNameEntry = state.typeGroupNameEntry
                    try await level.walk(.type(entry.entryType))
                    errors.append(contentsOf: level.errors)
                    if entry.occur != nil {
                        state.occurrence = nil
                    }
                    return
                }
                switch state.occurrence {
                case .optional?, .zeroOrMore?:
                    break
                default:
                    addError("expected array element at index \(idx), but array only has \(a.count) elements")
                }
                return
            }
        }

        try await visitType(entry.entryType)
    }

    func visitTypeGroupnameEntry(_ entry: TypeGroupnameEntry) async throws(CBORValidationError) {
        state.typeGroupNameEntry = entry.name.ident

        if let ga = entry.genericArgs, let rule = ruleFromIdent(state.schema, entry.name) {
            let resolvedArgs = state.resolvedGenericArgs(ga)
            let genericRules = state.genericRulesForInstantiation(rule, entry.name.ident, resolvedArgs)

            if let occur = entry.occur {
                visitOccurrence(occur)
            }

            // An entry covering more than one item holds every item of its run
            // to the rule it instantiates, with the instantiation in scope.
            if occurrenceCoversMany(state.occurrence) && item.isArray {
                let enclosingGenericRules = state.genericRules
                let enclosingGenericRule = state.evalGenericRule
                state.genericRules = genericRules
                state.evalGenericRule = entry.name.ident
                defer {
                    state.genericRules = enclosingGenericRules
                    state.evalGenericRule = enclosingGenericRule
                }
                try await validateArrayItems(.identifier(entry.name))
                return
            }

            // A rule standing for more than one entry is spliced into the group
            // this entry sits in.
            if ruleSpansMultipleEntries(rule) {
                let enclosingGenericRules = state.genericRules
                let enclosingGenericRule = state.evalGenericRule
                state.genericRules = genericRules
                state.evalGenericRule = entry.name.ident
                var failure: CBORValidationError?
                do {
                    try await visitIdentifier(entry.name)
                } catch {
                    failure = error
                }
                state.genericRules = enclosingGenericRules
                state.evalGenericRule = enclosingGenericRule
                state.typeGroupNameEntry = nil
                if let failure {
                    throw failure
                }
                return
            }

            // Inside an array, the element at the entry's index is walked.
            var element: (Int, CBORNode)?
            if case .array(let array) = item, let idx = state.groupEntryIdx, idx < array.items.count {
                element = (idx, array.items[idx])
            }

            let stepsIntoItem = element != nil
            let level: Level
            if let (idx, value) = element {
                level = try childAt(value, .index(idx))
                // Reaching the rule's body costs the step into the element and
                // the resolution of the rule's own name.
                switch chargeDescent(level.descentCost, level.limits.ruleHopCost, level.limits.maxDescentCost) {
                case .success(let cost): level.descentCost = cost
                case .failure(let reason): throw limitError(reason.reason)
                }
            } else {
                let descentCost = try checkRuleNesting(entry.name)
                level = sameItem()
                level.ruleNesting = ruleNesting + 1
                level.descentCost = descentCost
            }

            level.state.genericRules = genericRules
            level.state.evalGenericRule = entry.name.ident
            level.state.occurrence = state.occurrence
            level.state.isMultiTypeChoice = state.isMultiTypeChoice
            try await level.walk(.rule(rule))

            errors.append(contentsOf: level.errors)
            if !stepsIntoItem {
                adoptMatchedMapKeys(level)
            }
            return
        }

        if !typeChoiceAlternatesFromIdent(state.schema, entry.name).isEmpty {
            state.isMultiTypeChoice = true
        }

        let alternates = groupChoiceAlternatesFromIdent(state.schema, entry.name)
        let hasAlternates = !alternates.isEmpty
        let errorCount = errors.count
        let saved = hasAlternates ? alternativeState() : nil
        let baselineItemErrors = unvalidatedItemErrorCount()

        if hasAlternates {
            state.isMultiGroupChoice = true
        }

        for ge in alternates {
            if let saved {
                restoreAlternativeState(saved)
            }
            let curErrors = errors.count
            try await visitGroupEntry(ge)
            if errors.count == curErrors && unvalidatedItemErrorCount() <= baselineItemErrors {
                errors.removeLast(errors.count - errorCount)
                return
            }
        }

        if let saved {
            restoreAlternativeState(saved)
        }

        let curErrors = errors.count
        if let occur = entry.occur {
            visitOccurrence(occur)
        }
        if let ga = entry.genericArgs {
            for arg in ga.args {
                try await visitType1(arg.arg)
            }
        }
        try await visitIdentifier(entry.name)
        if hasAlternates && errors.count == curErrors && unvalidatedItemErrorCount() <= baselineItemErrors {
            errors.removeLast(curErrors - errorCount)
        }
        state.typeGroupNameEntry = nil
    }

    func visitMemberKey(_ mk: MemberKey) async throws(CBORValidationError) {
        switch mk {
        case .type1(let t1, let isCut, _, _, _, _):
            state.isCutPresent = isCut
            try await visitType1(t1)
            state.isCutPresent = false
        case .bareword(let ident, _, _, _):
            state.isColonShortcutPresent = true
            try await visitIdentifier(ident)
            state.isColonShortcutPresent = false
        case .value(let value, _, _, _):
            try await visitValue(value)
        case .nonMemberKey(let nmk, _, _):
            try await visitNonMemberKey(nmk)
        }
    }

    // MARK: Map entries

    /// Holds the group entry to the map entry whose key is `key`, and returns
    /// the error a map holding no such entry answers with. Only the occurrence
    /// indicator says that an entry may be absent.
    func selectMapEntry(_ entry: (key: CBORNode, value: CBORNode)?, _ keySpelling: String) -> String? {
        if let (k, v) = entry {
            // A location component names a key of the data item, rendered as
            // every other component of the path is.
            noteValidatedKey(k)
            objectValue = v
            location = paths.child(location, .key(formatPathKey(k)))
            return nil
        }

        // The occurrence is consumed whether or not it admits absence.
        let occurrence = state.occurrence
        state.occurrence = nil
        switch occurrence {
        case .optional?, .zeroOrMore?:
            state.advanceToNextEntry = true
            return nil
        default:
            return missingKeyError(.cbor, keySpelling)
        }
    }

    /// Validates the entries of a map against a group entry whose member key
    /// denotes a type: each key the group has not already accounted for is
    /// held to that type, and the occurrence indicator bounds how many of the
    /// matching entries this one accounts for.
    private func validateMapTypedKeyEntry(
        _ entries: [(key: CBORNode, value: CBORNode)],
        _ keyType: MemberKeyType,
        _ entry: ValueMemberKeyEntry
    ) async throws(CBORValidationError) {
        let keyDesc: String
        switch keyType {
        case .range(let lower, let upper, let isInclusive):
            // Bounds that do not denote a range denote no set of keys either,
            // so the range is what is reported.
            if case .success(let l) = resolveBound(lower), case .success(let u) = resolveBound(upper),
                RangeBound.denoteARange(l, u)
            {
                keyDesc = "in range \(l)\(isInclusive ? ".." : "...")\(u)"
            } else {
                try await visitRange(lower, upper, isInclusive)
                return
            }
        case .rule(let ident):
            keyDesc = "of type \(ident)"
        }

        let occurrence = state.occurrence
        let currentLocation = location
        let accountedFor = validatedKeys ?? []

        var matched: [(CBORNode, CBORNode)] = []
        for (k, v) in entries {
            if containsKey(accountedFor, k) {
                continue
            }
            // A range denotes numbers, so a composite item is never one.
            if case .range = keyType, k.isArray || k.isMap {
                continue
            }

            let keyLevel = try child(k)
            let walk: Walk
            switch keyType {
            case .range(let lower, let upper, let isInclusive): walk = .range(lower, upper, isInclusive)
            case .rule(let ident): walk = .identifier(ident)
            }
            try await keyLevel.walk(walk)

            if keyLevel.errors.isEmpty && keyLevel.unvalidatedItemErrorCount() == 0 {
                matched.append((k, v))
            }
        }

        let accounted = memberKeyAccountedCount(occurrence, matched.count)

        if let e = memberKeyCountError(.cbor, occurrence, matched.count, keyDesc) {
            // The keys are of the type whatever their number.
            for (k, _) in matched {
                noteValidatedKey(k)
            }
            addError(e)
            return
        }

        for (k, v) in matched.prefix(accounted) {
            noteValidatedKey(k)
            let level = try childAt(v, .key(formatPathKey(k)))
            level.state.isMultiTypeChoice = state.isMultiTypeChoice
            level.state.isMultiGroupChoice = state.isMultiGroupChoice
            level.state.typeGroupNameEntry = state.typeGroupNameEntry
            try await level.walk(.type(entry.entryType))
            errors.append(contentsOf: level.errors)
        }

        location = currentLocation
        if entry.occur != nil {
            state.occurrence = nil
        }
    }

    /// Validates the entries of a map against a member key applying a control
    /// operator to the type it names: every key the group has not already
    /// accounted for is held to the whole of it.
    func validateMapKeyControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        guard case .map(let map) = item else { return }
        let entries = map.entries

        let keyDesc = memberKeyControlDesc(target, ctrl, controller)
        let occurrence = state.occurrence
        let accountedFor = validatedKeys ?? []

        // An occurrence indicator other than `?` lets the entry stand for a
        // run of entries.
        let answersForARun: Bool
        switch occurrence {
        case .optional?, nil: answersForARun = false
        default: answersForARun = true
        }

        var matched: [(CBORNode, CBORNode)] = []
        var rejected: [CBORNode] = []
        for (k, v) in entries {
            if containsKey(accountedFor, k) {
                continue
            }
            let keyLevel = try child(k)
            try await keyLevel.walk(.control(target, ctrl, controller))
            if keyLevel.errors.isEmpty && keyLevel.unvalidatedItemErrorCount() == 0 {
                matched.append((k, v))
            } else {
                rejected.append(k)
            }
        }

        if answersForARun && !rejected.isEmpty {
            for k in rejected {
                addError("key \(keyDesc) required, got \(k.debugRendering)")
            }
            return
        }

        if let e = memberKeyCountError(.cbor, occurrence, matched.count, keyDesc) {
            addError(e)
            return
        }

        let accounted = memberKeyAccountedCount(occurrence, matched.count)
        matched = Array(matched.prefix(accounted))

        for (k, _) in matched {
            noteValidatedKey(k)
        }

        switch occurrence {
        case .optional?, nil:
            if let (k, v) = matched.first {
                location = paths.child(location, .key(formatPathKey(k)))
                objectValue = v
            } else {
                // An optional entry the map holds no key for is one the map is
                // not held to.
                state.occurrence = nil
                state.advanceToNextEntry = true
            }
        default:
            valuesToValidate = matched.map(\.1)
        }
    }

    // MARK: Membership

    /// Whether the data item is one of the values `t2` admits; the visit is
    /// rolled back, and only the verdict kept.
    func admitsDataItem(_ t2: Type2) async throws(CBORValidationError) -> Bool {
        let saved = alternativeState()
        let savedCtrl = state.ctrl
        state.ctrl = nil
        let savedMapEquality = state.isCtrlMapEquality
        state.isCtrlMapEquality = false
        let errorCount = errors.count
        let itemErrorCount = unvalidatedItemErrorCount()

        try await visitType2(t2)

        let admits = errors.count == errorCount && unvalidatedItemErrorCount() <= itemErrorCount

        errors.removeLast(errors.count - errorCount)
        restoreAlternativeState(saved)
        state.isCtrlMapEquality = savedMapEquality
        state.ctrl = savedCtrl

        return admits
    }

    /// Holds the data item to the target of an equality control operator, and
    /// reports the target it is not a value of.
    func targetAdmitsDataItem(_ target: Type2, _ isExpectedKind: Bool) async throws(CBORValidationError) -> Bool {
        if isExpectedKind, try await admitsDataItem(target) {
            return true
        }
        addError(targetTypeError(.cbor, target, item.debugRendering))
        return false
    }

    /// Validates the data item against the exclusion `.ne` states.
    func validateExclusion(_ target: Type2, _ controller: Type2) async throws(CBORValidationError) {
        if try await admitsDataItem(controller) {
            addError(exclusionError(target, controller, item.debugRendering))
        }
    }

    // MARK: Values

    func visitValue(_ value: Value) async throws(CBORValidationError) {
        // A literal outside member key position names a data item, and a map
        // is not a data item of any literal's type.
        if item.isMap && !state.isMemberKey && !state.isColonShortcutPresent {
            addError("expected value \(value), got \(item.debugRendering)")
            return
        }

        let error: String?
        switch item {
        case .unsigned, .negative:
            error = integerAgainstValue(item.integerValue!, value)
        case .float(let f, _):
            error = floatAgainstValue(f, value)
        case .textString(let s, _):
            error = try textAgainstValue(s, value)
        case .byteString(let b, _):
            error = try bytesAgainstValue(b, value)
        case .array:
            try await validateArrayItems(.value(value))
            error = nil
        case .map(let map):
            if state.isCutPresent {
                cutValue = Type1(value: value)
            }
            if case .text(let text) = value, text == "any" {
                return
            }
            let k = tokenValueIntoCBORValue(value)
            let entry = map.entries.first { referenceEquals($0.key, k) }
            error = selectMapEntry(entry, value.description)
        default:
            error = "expected \(value), got \(item.debugRendering)"
        }

        if let error {
            addError(error)
        }
    }

    private func integerAgainstValue(_ integer: CBORInteger, _ value: Value) -> String? {
        let i = integer.bigInt
        let got = integerDebug(integer)
        let ctrl = state.ctrl

        func literal(_ v: BigInt, _ text: String) -> String? {
            switch ctrl {
            case .ne? where i != v: return nil
            case .lt? where i < v: return nil
            case .le? where i <= v: return nil
            case .gt? where i > v: return nil
            case .ge? where i >= v: return nil
            case .plus?:
                return i == v ? nil : "expected computed .plus value \(text), got \(got)"
            default:
                if ctrlEvaluatesLiteralAsValue(ctrl) {
                    return i == v ? nil : "expected value \(text), got \(got)"
                }
                if let ctrl {
                    return "expected value \(ctrl) \(text), got \(got)"
                }
                return "expected value \(text), got \(got)"
            }
        }

        switch value {
        case .int(let v):
            return literal(v, v.description)
        case .uint(let v):
            if ctrl == .size {
                return uintFitsInSize(i, BigInt(v)) ? nil : "expected value .size \(v), got \(got)"
            }
            return literal(BigInt(v), String(v))
        case .float(let f) where ctrl == .lt || ctrl == .le || ctrl == .gt || ctrl == .ge:
            // A comparison relates the data item to the literal by magnitude.
            let widened = Double(i)
            let v = f.value
            switch ctrl {
            case .lt? where widened < v: return nil
            case .le? where widened <= v: return nil
            case .gt? where widened > v: return nil
            case .ge? where widened >= v: return nil
            default:
                if let ctrl {
                    return "expected value \(ctrl) \(FloatLiteral(v)), got \(got)"
                }
                return "expected value \(FloatLiteral(v)), got \(got)"
            }
        default:
            return "expected \(value), got \(got)"
        }
    }

    private func floatAgainstValue(_ f: Double, _ value: Value) -> String? {
        let ctrl = state.ctrl
        let got = floatDebug(f)
        if case .float(let literal) = value {
            let v = literal.value
            switch ctrl {
            case .ne? where abs(f - v) > Double.ulpOfOne: return nil
            case .lt? where f < v: return nil
            case .le? where f <= v: return nil
            case .gt? where f > v: return nil
            case .ge? where f >= v: return nil
            case .plus?:
                return abs(f - v) < Double.ulpOfOne ? nil : "expected computed .plus value \(FloatLiteral(v)), got \(got)"
            default:
                if ctrlEvaluatesLiteralAsValue(ctrl) {
                    return abs(f - v) < Double.ulpOfOne ? nil : "expected value \(FloatLiteral(v)), got \(got)"
                }
                if let ctrl {
                    return "expected value \(ctrl) \(FloatLiteral(v)), got \(got)"
                }
                return "expected value \(FloatLiteral(v)), got \(got)"
            }
        }

        // A comparison relates a float to an integer literal by magnitude.
        if let ctrl, let comparison = Comparison(ctrl), let bound = integerLiteralAsDouble(value) {
            return comparison.holds(f, bound) ? nil : "expected value \(ctrl) \(value), got \(got)"
        }
        return "expected \(value), got \(got)"
    }

    private func textAgainstValue(_ s: String, _ value: Value) throws(CBORValidationError) -> String? {
        let ctrl = state.ctrl
        switch value {
        case .text(let t):
            switch ctrl {
            case .ne?:
                return !s.utf8.elementsEqual(t.utf8) ? nil : "expected \(value) .ne to \"\(s)\""
            case .regexp?:
                guard let pattern = formatRegex(t) else {
                    throw limitError("malformed regex")
                }
                let regex = try compileRegex(pattern)
                return regex.isMatch(s) ? nil : "expected \"\(s)\" to match regex \"\(t)\""
            case .pcre?:
                let regex = try compileRegex("^(?:\(t))$")
                return regex.isMatch(s) ? nil : "expected \"\(s)\" to match pcre \"\(t)\""
            case .iregexp?:
                let regex = try compileRegex("^(?:\(t))$")
                return regex.isMatch(s) ? nil : "expected \"\(s)\" to match iregexp \"\(t)\""
            case .abnf?:
                throw abnfUnsupported(.abnf)
            default:
                if ctrlEvaluatesLiteralAsValue(ctrl) {
                    if s.utf8.elementsEqual(t.utf8) {
                        return nil
                    }
                    if ctrlComputesConcatenation(ctrl) {
                        return "expected value to match concatenated string \(value), got \"\(s)\""
                    }
                }
                if let ctrl {
                    return "expected value \(ctrl) \(value), got \"\(s)\""
                }
                return "expected value \(value) got \"\(s)\""
            }
        case .uint(let u):
            if ctrl == .size {
                return UInt64(s.utf8.count) == u ? nil : "expected \"\(s)\" .size \(u), got \(s.utf8.count)"
            }
            return "expected \(u), got \(s)"
        case .byte(let bv):
            switch ctrl {
            case .abnf?:
                throw abnfUnsupported(.abnf)
            case .ne?:
                // A byte string literal never matches a text string.
                return nil
            default:
                if ctrlComputesConcatenation(ctrl) {
                    return "expected value to match concatenated byte string \(bv), got \"\(s)\""
                }
                if let ctrl {
                    return "expected value \(ctrl) \(bv), got \"\(s)\""
                }
                return "expected value \(bv), got \"\(s)\""
            }
        default:
            return "expected \(value), got \"\(s)\""
        }
    }

    private func bytesAgainstValue(_ b: [UInt8], _ value: Value) throws(CBORValidationError) -> String? {
        let ctrl = state.ctrl
        switch value {
        case .uint(let v):
            if ctrl == .size {
                if let rangeUpper {
                    let len = UInt64(b.count)
                    if len < v || len > rangeUpper {
                        return "expected bytes .size to be in range \(v) <= value <= \(rangeUpper), got \(len)"
                    }
                    return nil
                }
                if UInt64(b.count) == v {
                    return nil
                }
                return "expected \(base16Literal(b)) .size \(v), got \(b.count)"
            }
            if let ctrl {
                return "expected value \(ctrl) \(v), got \(base16Literal(b))"
            }
            return "expected value \(v), got \(base16Literal(b))"
        case .text(let t):
            switch ctrl {
            case .ne?:
                // A text string literal never matches a byte string.
                return nil
            case .abnfb?:
                throw abnfUnsupported(.abnfb)
            default:
                if ctrlComputesConcatenation(ctrl) {
                    return "expected value to match concatenated string \"\(t)\", got \(base16Literal(b))"
                }
                if let ctrl {
                    return "expected value \(ctrl) \"\(t)\", got \(base16Literal(b))"
                }
                return "expected value \"\(t)\", got \(base16Literal(b))"
            }
        case .byte(let bv):
            if ctrl == .abnfb {
                throw abnfUnsupported(.abnfb)
            }
            let isEqual = byteStringLiteralContent(bv) == b
            if ctrl == .ne {
                return isEqual ? "expected value .ne \(bv), got \(base16Literal(b))" : nil
            }
            if !ctrlEvaluatesLiteralAsValue(ctrl) {
                if let ctrl {
                    return "expected value \(ctrl) \(bv), got \(base16Literal(b))"
                }
                return "expected value \(bv), got \(base16Literal(b))"
            }
            if isEqual {
                return nil
            }
            if ctrlComputesConcatenation(ctrl) {
                return "expected value to match concatenated byte string \(bv), got \(base16Literal(b))"
            }
            return "expected value \(bv), got \(base16Literal(b))"
        default:
            return "expected \(value), got \(bytesDebug(b))"
        }
    }

    /// A regular expression compiled for a control operator; one that does not
    /// compile ends the walk with the reason.
    private func compileRegex(_ pattern: String) throws(CBORValidationError) -> ControlRegex {
        switch ControlRegex.compile(pattern) {
        case .success(let regex): return regex
        case .failure(let reason): throw limitError(reason.message)
        }
    }
}

/// Whether the type the primitive data type name `ident` stands for admits
/// `k` as a map key.
func preludeTypeAdmitsMapKey(_ schema: Schema, _ ident: Identifier, _ k: CBORNode) -> Bool {
    switch k {
    case .textString: return isIdentStringDataType(schema, ident)
    case .byteString: return isIdentByteStringDataType(schema, ident)
    case .unsigned, .negative:
        return integerMatchesDataType(schema, ident, k.integerValue!.bigInt) == true
    case .float: return isIdentFloatDataType(schema, ident) || isIdentNumberDataType(schema, ident)
    case .bool: return isIdentBoolDataType(schema, ident)
    case .null, .undefined: return isIdentNullDataType(schema, ident)
    default: return false
    }
}
