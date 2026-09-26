import BigInt
import Foundation

// Names, group entries, member keys and literal values matched against a JSON
// value (RFC 8610 Sections 3.1, 3.5 and 3.7).

extension JSONLevel {
    // MARK: Names

    func visitIdentifier(_ ident: Identifier) async throws(JSONValidationError) {
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
            // that entry's position, not the array holding it: step into that
            // item, so the rule is matched against the value it describes.
            if !state.isMemberKey, case .type = r, case .array(let array) = item, let idx = state.groupEntryIdx {
                if idx < array.items.count {
                    let level = try childAt(array.items[idx], .index(idx))
                    level.state.ctrl = state.ctrl
                    level.state.isMultiTypeChoice = state.isMultiTypeChoice
                    try await level.walk(.rule(r))
                    errors.append(contentsOf: level.errors)
                    return
                }
                // An occurrence indicator admitting zero occurrences imposes no
                // requirement once the array has run out of items to match.
                if occurrenceAdmitsAbsence(state.occurrence) {
                    return
                }
                addError(JSONItemToken.identifier(ident).errorMessage(idx))
                return
            }

            try await visitRuleAgainstItem(ident, r)
            return
        }

        if isIdentAnyType(state.schema, ident) {
            return
        }

        // In an array, a name referring to another array type is walked as
        // that type.
        if item.isArray, case .type(let rule, _, _, _)? = ruleFromIdent(state.schema, ident) {
            for tc in rule.value.typeChoices {
                if case .array = tc.type1.type2 {
                    state.visitedRules.insert(ident.ident)
                    defer { state.visitedRules.remove(ident.ident) }
                    try await visitTypeChoice(tc)
                    return
                }
            }
        }

        let schema = state.schema
        switch item {
        case .null where isIdentNullDataType(schema, ident):
            return
        case .bool(let b):
            if isIdentBoolDataType(schema, ident) || identMatchesBoolValue(schema, ident, b) {
                return
            }
            addError("expected type \(ident), got \(item.elidedRendering)")
        case .number(let n):
            if let value = n.integer, let admitted = integerMatchesDataType(schema, ident, value) {
                if !admitted {
                    addError("expected type \(ident), got \(item.elidedRendering)")
                }
                return
            }

            if isIdentTimeDataType(schema, ident) {
                // A number spans a wider range than the instants a date and time
                // can express, so the seconds count is range checked as it
                // stands.
                if let whole = n.integer {
                    if !secondsAreRepresentableTime(whole) {
                        addError(invalidTimestampError(.whole(whole)))
                    }
                } else if !floatSecondsAreRepresentableTime(n.double) {
                    addError(invalidTimestampError(.fractional(n.double)))
                }
                return
            } else if (isIdentFloatDataType(schema, ident) || isIdentNumberDataType(schema, ident)) && n.isFloat {
                // RFC 8610 Appendix D defines `number = int / float`, so a name
                // standing for it admits a number written as a float as well.
                return
            }

            addError("expected type \(ident), got \(item.elidedRendering)")
        case .string(let s):
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
                addError("expected type \(ident), got \(item.elidedRendering)")
            }
        case .array:
            // A name referring to an array type rule is walked as that rule.
            if let r = ruleFromIdent(schema, ident), isArrayTypeRule(schema, ident) {
                state.visitedRules.insert(ident.ident)
                defer { state.visitedRules.remove(ident.ident) }
                try await visitRule(r)
                return
            }
            try await validateArrayItems(.identifier(ident))
        case .object(let object):
            try await visitIdentifierAgainstObject(ident, object.entries)
        default:
            if let cut = cutValue {
                cutValue = nil
                addError("cut present for member key \(cut). expected type \(ident), got \(item.elidedRendering)")
            } else {
                addError("expected type \(ident), got \(item.elidedRendering)")
            }
        }
    }

    /// Matches a name against an object: in member key position, the question
    /// whether the object holds a member whose name the name admits.
    private func visitIdentifierAgainstObject(_ ident: Identifier, _ entries: [(key: String, value: JSONNode)]) async throws(JSONValidationError) {
        let schema = state.schema

        // A bareword member key is shorthand for the text string of that name
        // (RFC 8610 Section 3.5.1).
        if state.isColonShortcutPresent {
            try await visitValue(.text(ident.ident))
            return
        }

        // `true` and `false` each name one value rather than a type, so in
        // member key position they name the member held under that value. A
        // member name is a string, so no object holds one.
        if state.isMemberKey, let b = boolLiteralOfIdent(schema, ident) {
            addError("CDDL member key must be string data type. got \(b)")
            return
        }

        switch state.occurrence {
        case .optional?, nil:
            // A member key states the type of the names the entry answers for,
            // and an entry standing for one occurrence answers for one of them.
            // A member name is a string, so a name answers for a member when it
            // states a text string type and for none when it states any other
            // primitive type.
            if state.isMemberKey && isIdentPrimitiveDataType(schema, ident) {
                let entry = isIdentStringDataType(schema, ident) ? entries.first : nil
                if let (k, v) = entry {
                    noteNamedKey(k)
                    objectValue = v
                    location = paths.child(location, .key(k))
                } else {
                    addError(missingKeyTypeError(.json, ident.description))
                }
                return
            }

            if lookupIdent(ident.ident).inStandardPrelude() != nil {
                addError("expected type \(ident), got \(item.elidedRendering)")
                return
            }

            try await visitValue(.text(ident.ident))
        case let occur?:
            // An indicator covering more than one occurrence lets the member
            // key answer for every name the group has not otherwise accounted
            // for.
            if isIdentPrimitiveDataType(schema, ident) {
                let admitsObjectKeys = isIdentStringDataType(schema, ident)
                var keyErrors: [String] = []
                var values: [JSONNode] = []
                for (k, v) in entries {
                    if let keys = validatedKeys, containsName(keys, k) {
                        continue
                    }
                    if admitsObjectKeys {
                        values.append(v)
                    } else {
                        keyErrors.append("key of type \(ident) required, got \(debugString(k))")
                    }
                }
                valuesToValidate = values

                if !keyErrors.isEmpty {
                    for e in keyErrors {
                        addError(e)
                    }
                    return
                }
            }

            switch occur {
            case .zeroOrMore, .oneOrMore:
                if case .oneOrMore = occur, entries.isEmpty {
                    addError("object cannot be empty, one or more entries with key type \(ident) required")
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

            if lookupIdent(ident.ident).inStandardPrelude() != nil {
                return
            }

            // Any other name is a bareword member key naming one member; the
            // occurrence indicator says how many times the group holding it
            // repeats rather than which member it names.
            try await visitValue(.text(ident.ident))
        }
    }

    // MARK: Group entries

    func visitValueMemberKeyEntry(_ entry: ValueMemberKeyEntry) async throws(JSONValidationError) {
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

        // A type in member key position denotes the names the entry answers
        // for, so the entry is matched against the members one at a time.
        if case .type1(let t1, _, _, _, _, _)? = entry.memberKey,
            let keyType = memberKeyType(state, t1, limits.maxRuleNesting), case .object(let object) = item
        {
            try await validateObjectTypedKeyEntry(object.entries, keyType, entry)
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

        // An entry of an array group describes the item at its own position;
        // an entry standing for a run of items is left to the walk that covers
        // them all.
        if case .array(let array) = item, let idx = state.groupEntryIdx, !occurrenceCoversMany(state.occurrence) {
            let a = array.items
            if idx < a.count {
                let level = try childAt(a[idx], .index(idx))
                level.state.ctrl = state.ctrl
                level.state.isMultiGroupChoice = state.isMultiGroupChoice
                level.state.typeGroupNameEntry = state.typeGroupNameEntry
                try await level.walk(.type(entry.entryType))
                errors.append(contentsOf: level.errors)
                if entry.occur != nil {
                    state.occurrence = nil
                }
                return
            }
            // An occurrence indicator admitting zero occurrences imposes nothing
            // once the array has run out of items to match.
            if occurrenceAdmitsAbsence(state.occurrence) {
                return
            }
            addError("expected array element at index \(idx), but array only has \(a.count) elements")
            return
        }

        try await visitType(entry.entryType)
    }

    func visitTypeGroupnameEntry(_ entry: TypeGroupnameEntry) async throws(JSONValidationError) {
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
                var failure: JSONValidationError?
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

            // Inside an array, the item at the entry's index is walked.
            var element: (Int, JSONNode)?
            if case .array(let array) = item, let idx = state.groupEntryIdx, idx < array.items.count {
                element = (idx, array.items[idx])
            }

            let stepsIntoItem = element != nil
            let level: JSONLevel
            if let (idx, value) = element {
                level = try childAt(value, .index(idx))
                // Reaching the rule's body costs the step into the item and the
                // resolution of the rule's own name.
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

    func visitMemberKey(_ mk: MemberKey) async throws(JSONValidationError) {
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

    // MARK: Object members

    /// Holds the group entry to the object member its member key names. Only
    /// the occurrence indicator says that an entry may be absent.
    private func validateObjectValue(_ value: Value) {
        guard case .object(let object) = item else { return }

        // A bareword member key is converted to a text string value.
        guard case .text(let t) = value else {
            addError("CDDL member key must be string data type. got \(value)")
            return
        }

        if state.isCutPresent {
            cutValue = t
        }
        if sameText(t, "any") {
            return
        }

        if let (k, v) = object.entry(t) {
            noteNamedKey(k)
            objectValue = v
            location = paths.child(location, .key(k))
            return
        }

        // The occurrence is consumed whether or not it admits absence.
        let occurrence = state.occurrence
        state.occurrence = nil
        switch occurrence {
        case .optional?, .zeroOrMore?:
            state.advanceToNextEntry = true
        default:
            // The name is written as the schema writes it.
            addError(missingKeyError(.json, value.description))
        }
    }

    /// Validates the members of an object against a group entry whose member
    /// key denotes a type: each name the group has not already accounted for
    /// is held to that type, and the occurrence indicator bounds how many of
    /// the matching members this one accounts for. A member name is a string
    /// and a range denotes numbers, so no name is a member of a range.
    private func validateObjectTypedKeyEntry(
        _ entries: [(key: String, value: JSONNode)],
        _ keyType: MemberKeyType,
        _ entry: ValueMemberKeyEntry
    ) async throws(JSONValidationError) {
        let keyDesc: String
        switch keyType {
        case .range(let lower, let upper, let isInclusive):
            // Bounds that do not denote a range denote no set of names either,
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

        var matched: [(String, JSONNode)] = []
        for (k, v) in entries {
            if containsName(accountedFor, k) {
                continue
            }
            let walk: Walk
            switch keyType {
            case .range(let lower, let upper, let isInclusive): walk = .range(lower, upper, isInclusive)
            case .rule(let ident): walk = .identifier(ident)
            }
            if try await keyAdmitted(k, walk) {
                matched.append((k, v))
            }
        }

        let accounted = memberKeyAccountedCount(occurrence, matched.count)

        if let e = memberKeyCountError(.json, occurrence, matched.count, keyDesc) {
            // The names are of the type whatever their number.
            for (k, _) in matched {
                noteValidatedKey(k)
            }
            addError(e)
            return
        }

        for (k, v) in matched.prefix(accounted) {
            noteValidatedKey(k)
            let level = try childAt(v, .key(k))
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

    /// Validates the members of an object against a member key applying a
    /// control operator to the type it names: every name the group has not
    /// already accounted for is held to the whole of it.
    func validateObjectKeyControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(JSONValidationError) {
        guard case .object(let object) = item else { return }
        let entries = object.entries

        let keyDesc = memberKeyControlDesc(target, ctrl, controller)
        let occurrence = state.occurrence
        let accountedFor = validatedKeys ?? []

        // An occurrence indicator other than `?` lets the entry stand for a
        // run of members.
        let answersForARun: Bool
        switch occurrence {
        case .optional?, nil: answersForARun = false
        default: answersForARun = true
        }

        var matched: [(String, JSONNode)] = []
        var rejected: [String] = []
        for (k, v) in entries {
            if containsName(accountedFor, k) {
                continue
            }
            if try await keyAdmitted(k, .control(target, ctrl, controller)) {
                matched.append((k, v))
            } else {
                rejected.append(k)
            }
        }

        // A name the entry stands for but the control does not admit is a
        // name the object type does not admit either.
        if answersForARun && !rejected.isEmpty {
            for k in rejected {
                addError("key \(keyDesc) required, got \(debugString(k))")
            }
            return
        }

        if let e = memberKeyCountError(.json, occurrence, matched.count, keyDesc) {
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
                location = paths.child(location, .key(k))
                objectValue = v
            } else {
                // An optional entry the object holds no name for is one the
                // object is not held to.
                state.occurrence = nil
                state.advanceToNextEntry = true
            }
        default:
            valuesToValidate = matched.map(\.1)
        }
    }

    // MARK: Membership

    /// Whether the value is one of the values `t2` admits; the visit is rolled
    /// back, and only the verdict kept.
    func admitsDataItem(_ t2: Type2) async throws(JSONValidationError) -> Bool {
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

    /// Holds the value to the target of an equality control operator, and
    /// reports the target it is not a value of.
    func targetAdmitsDataItem(_ target: Type2, _ isExpectedKind: Bool) async throws(JSONValidationError) -> Bool {
        if isExpectedKind, try await admitsDataItem(target) {
            return true
        }
        addError(targetTypeError(.json, target, item.elidedRendering))
        return false
    }

    /// Validates the value against the exclusion `.ne` states.
    func validateExclusion(_ target: Type2, _ controller: Type2) async throws(JSONValidationError) {
        if try await admitsDataItem(controller) {
            addError(exclusionError(target, controller, item.elidedRendering))
        }
    }

    // MARK: Values

    func visitValue(_ value: Value) async throws(JSONValidationError) {
        if item.isArray {
            try await validateArrayItems(.value(value))
            return
        }

        if item.isObject {
            // A literal in member key position names one member of the object.
            // In any other position it names a value, and an object is not a
            // value of any literal's type.
            if state.isMemberKey || state.isColonShortcutPresent {
                validateObjectValue(value)
                return
            }
            addError("expected value \(value), got \(item.elidedRendering)")
            return
        }

        // A comparison relates the value to the literal rather than asking it to
        // be equal to one, so a number read as a float stands in a comparison
        // with an integer literal, both sides widened to floats.
        if let ctrl = state.ctrl, let comparison = Comparison(ctrl), let bound = integerLiteralAsDouble(value),
            case .number(let n) = item, n.isFloat
        {
            if !comparison.holds(n.double, bound) {
                addError("expected value \(ctrl) \(value), got \(n)")
            }
            return
        }

        let error: String?
        switch value {
        case .int(let v):
            if case .number(let n) = item {
                if let i = n.int64 {
                    error = integerAgainstLiteral(BigInt(i), v, v.description, "\(n)")
                } else {
                    error = "\(n) cannot be represented as an i64"
                }
            } else {
                error = "expected value \(v), got \(item.elidedRendering)"
            }
        case .uint(let v):
            switch item {
            case .number(let n):
                if let i = n.integer {
                    if state.ctrl == .size {
                        error = uintFitsInSize(i, BigInt(v)) ? nil : "expected value .size \(v), got \(n)"
                    } else {
                        error = integerAgainstLiteral(i, BigInt(v), String(v), "\(n)")
                    }
                } else {
                    error = "\(n) cannot be represented as an integer"
                }
            case .string(let s):
                if state.ctrl == .size {
                    error = UInt64(s.utf8.count) == v ? nil : "expected \"\(s)\" .size \(v), got \(s.utf8.count)"
                } else {
                    error = "expected \(v), got \(s)"
                }
            default:
                error = "expected value \(v), got \(item.elidedRendering)"
            }
        case .float(let literal):
            if case .number(let n) = item {
                error = floatAgainstLiteral(n.double, literal.value, "\(n)")
            } else {
                error = "expected value \(FloatLiteral(literal.value)), got \(item.elidedRendering)"
            }
        case .text(let t):
            if case .string(let s) = item {
                error = try textAgainstLiteral(s, t, value)
            } else {
                error = "expected value \(t), got \(item.elidedRendering)"
            }
        case .byte(let bv):
            if state.ctrl == .abnf {
                // RFC 9165 Section 3: the controller of `.abnf` is a grammar.
                guard case .string = item else {
                    error = "expected value .abnf \(bv), got \(item.elidedRendering)"
                    break
                }
                throw jsonAbnfUnsupported(.abnf)
            }
            switch item {
            case .string where state.ctrl == .ne:
                // A byte string literal never matches a string: the two are
                // distinct types whatever their content.
                error = nil
            default:
                if ctrlComputesConcatenation(state.ctrl) {
                    error = "expected value to match concatenated byte string \(bv), got \(item.elidedRendering)"
                } else if let ctrl = state.ctrl {
                    error = "expected value \(ctrl) \(bv), got \(item.elidedRendering)"
                } else {
                    error = "expected value \(bv), got \(item.elidedRendering)"
                }
            }
        }

        if let error {
            addError(error)
        }
    }

    /// The error an integer `i` reports against an integer literal `v`, under
    /// the control operator in effect.
    private func integerAgainstLiteral(_ i: BigInt, _ v: BigInt, _ text: String, _ got: String) -> String? {
        let ctrl = state.ctrl
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

    /// The error a number `f` reports against a float literal `v`, under the
    /// control operator in effect.
    private func floatAgainstLiteral(_ f: Double, _ v: Double, _ got: String) -> String? {
        let ctrl = state.ctrl
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

    /// The error a string `s` reports against a text literal `t`, under the
    /// control operator in effect.
    private func textAgainstLiteral(_ s: String, _ t: String, _ value: Value) throws(JSONValidationError) -> String? {
        let ctrl = state.ctrl
        switch ctrl {
        case .ne?:
            return !sameText(s, t) ? nil : "expected \(value) .ne to \"\(s)\""
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
            throw jsonAbnfUnsupported(.abnf)
        default:
            if ctrlEvaluatesLiteralAsValue(ctrl) {
                if sameText(s, t) {
                    return nil
                }
                if ctrlComputesConcatenation(ctrl) {
                    return "expected value to match concatenated string \(value), got \"\(s)\""
                }
            }
            // Every remaining operator constrains its target by something other
            // than a value, so a text literal can never satisfy it.
            if let ctrl {
                return "expected value \(ctrl) \(value), got \"\(s)\""
            }
            return "expected value \(value) got \"\(s)\""
        }
    }

    /// A regular expression compiled for a control operator; one that does not
    /// compile ends the walk with the reason.
    private func compileRegex(_ pattern: String) throws(JSONValidationError) -> ControlRegex {
        switch ControlRegex.compile(pattern) {
        case .success(let regex): return regex
        case .failure(let reason): throw limitError(reason.message)
        }
    }
}

/// The error the `.abnf` and `.abnfb` control operators report: this
/// implementation provides no ABNF matching (RFC 9165 Section 3).
func jsonAbnfUnsupported(_ ctrl: ControlOperator) -> JSONValidationError {
    .unsupported("the \(ctrl) control operator (RFC 9165 Section 3) is not supported")
}

/// Whether `ident` names a type rule with an array among its alternatives.
func isArrayTypeRule(_ schema: Schema, _ ident: Identifier) -> Bool {
    for rule in schema.cddl.rules {
        if case .type(let typeRule, _, _, _) = rule, typeRule.name.ident == ident.ident {
            for tc in typeRule.value.typeChoices {
                if case .array = tc.type1.type2 {
                    return true
                }
            }
        }
    }
    return false
}
