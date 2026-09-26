import BigInt
import Foundation

// Control operators applied to a CBOR data item (RFC 8610 Section 3.8, RFC
// 9165, RFC 9741).

extension Level {
    func visitControlOperator(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        // A type in member key position denotes the keys the group entry
        // answers for, so a control applied to it constrains each key.
        if state.isMemberKey && item.isMap {
            try await validateMapKeyControl(target, ctrl, controller)
            return
        }

        // Inside an array group the control applies to the items the entry
        // stands for, not to the array holding them.
        if case .typename = target, case .array(let array) = item, state.entryCounts != nil {
            if occurrenceCoversMany(state.occurrence) {
                try await validateArrayItems(.control(target, ctrl, controller))
                return
            }
            if let idx = state.groupEntryIdx, idx < array.items.count {
                let level = try childAt(array.items[idx], .index(idx))
                level.state.isMultiTypeChoice = state.isMultiTypeChoice
                level.state.isMultiGroupChoice = state.isMultiGroupChoice
                level.state.typeGroupNameEntry = state.typeGroupNameEntry
                try await level.walk(.control(target, ctrl, controller))
                errors.append(contentsOf: level.errors)
                return
            }
        }

        // A controller written as a computation stands for the value it
        // computes; the computation is carried out first. A controller
        // standing for several values holds if any of them does.
        if !ctrlComputesValue(ctrl), let computed = computedControllerValues(state, controller) {
            switch computed {
            case .success(let values) where !values.isEmpty:
                let errorCount = errors.count
                for v in values {
                    let curErrors = errors.count
                    try await visitControlOperator(target, ctrl, v)
                    if errors.count == curErrors {
                        errors.removeLast(errors.count - errorCount)
                        break
                    }
                }
            case .success:
                throw schemaError("controller \(controller) of \(ctrl) operation denotes no value")
            case .failure(let fault):
                throw schemaError(fault.message)
            }
            return
        }

        if case .typename(let targetIdent, _, _) = target {
            if case .typename(let controllerIdent, _, _) = controller, let name = state.evalGenericRule,
                let gr = state.genericRules.first(where: { $0.name == name })
            {
                for (idx, gp) in gr.params.enumerated() where idx < gr.args.count && gp == targetIdent.ident {
                    let arg = gr.args[idx]
                    let t2 = Type2(type1: arg)
                    if gp == controllerIdent.ident {
                        try await visitControlOperator(t2, ctrl, t2)
                        return
                    }
                    try await visitControlOperator(arg.type2, ctrl, controller)
                    return
                }
            }

            if let name = state.evalGenericRule, let gr = state.genericRules.first(where: { $0.name == name }) {
                for (idx, gp) in gr.params.enumerated() where idx < gr.args.count && gp == targetIdent.ident {
                    try await visitControlOperator(Type2(type1: gr.args[idx]), ctrl, controller)
                    return
                }
            }

            // The data item has to be of the target's type before a control on
            // that type says anything about it; an operator computing its value
            // from both operands is the exception.
            if ctrlHoldsTargetToItsType(ctrl), !holdsToTargetType(targetIdent) {
                return
            }
        }

        switch ctrl {
        case .eq:
            try await equalityControl(target, controller)
        case .ne:
            try await exclusionControl(target, controller)
        case .lt, .gt, .ge, .le:
            try await comparisonControl(target, ctrl, controller)
        case .size:
            if case .typename(let ident, _, _) = target,
                isIdentStringDataType(state.schema, ident) || isIdentUintDataType(state.schema, ident)
                    || isIdentByteStringDataType(state.schema, ident)
            {
                state.ctrl = ctrl
                try await visitType2(controller)
                state.ctrl = nil
            } else {
                addError("target for .size must a string or uint data type, got \(target)")
            }
        case .and:
            state.ctrl = ctrl
            try await visitType2(target)
            try await visitType2(controller)
            state.ctrl = nil
        case .within:
            state.ctrl = ctrl
            let errorCount = errors.count
            try await visitType2(target)
            let noErrors = errors.count == errorCount
            try await visitType2(controller)
            if noErrors && errors.count > errorCount {
                errors.removeLast(errors.count - errorCount)
                addError("expected type \(target) .within type \(controller), got \(item.debugRendering)")
            }
            state.ctrl = nil
        case .default:
            state.ctrl = ctrl
            let errorCount = errors.count
            try await visitType2(target)
            if errors.count != errorCount {
                let occurrence = state.occurrence
                state.occurrence = nil
                if case .optional? = occurrence {
                    addError("expected default value \(controller), got \(item.debugRendering)")
                }
            }
            state.ctrl = nil
        case .regexp, .pcre, .iregexp:
            state.ctrl = ctrl
            let name = ctrl == .regexp ? ".regexp" : ctrl == .pcre ? ".pcre" : ".iregexp"
            if case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) {
                switch item {
                case .textString, .array:
                    try await visitType2(controller)
                default:
                    addError("\(name) control can only be matched against CBOR string, got \(item.debugRendering)")
                }
            } else {
                addError("\(name) control can only be matched against string data type, got \(target)")
            }
            state.ctrl = nil
        case .bitfield:
            state.ctrl = ctrl
            bitfieldControl(target, controller)
            state.ctrl = nil
        case .cbor, .cborseq:
            state.ctrl = ctrl
            try await embeddedCBORControl(target, ctrl, controller)
            state.ctrl = nil
        case .bits:
            state.ctrl = ctrl
            try await bitsControl(target, ctrl, controller)
            state.ctrl = nil
        case .cat, .det:
            state.ctrl = ctrl
            switch catOperation(state.schema, target, controller, ctrl == .det) {
            case .success(let values): try await visitFirstAdmitting(values)
            case .failure(let fault): throw schemaError(fault.message)
            }
            state.ctrl = nil
        case .plus:
            state.ctrl = ctrl
            switch plusOperation(state.schema, target, controller) {
            case .success(let values): try await visitFirstAdmitting(values)
            case .failure(let fault): throw schemaError(fault.message)
            }
            state.ctrl = nil
        case .abnf, .abnfb:
            state.ctrl = ctrl
            try await abnfControl(target, ctrl, controller)
            state.ctrl = nil
        case .feature:
            state.ctrl = ctrl
            try await featureControl(target, controller)
            state.ctrl = nil
        case .b64u, .b64c, .b64uSloppy, .b64cSloppy, .hex, .hexlc, .hexuc, .b32, .h32, .b45:
            try await textConversionControl(target, ctrl, controller)
        case .base10, .printf, .json, .join:
            textFormatControl(target, ctrl, controller)
        }
    }

    /// Whether the data item is of the type the target names, reporting it
    /// when it is not.
    private func holdsToTargetType(_ targetIdent: Identifier) -> Bool {
        let schema = state.schema
        if isIdentStringDataType(schema, targetIdent) {
            if case .textString = item { return true }
            addError("expected type tstr, got \(item.debugRendering)")
            return false
        }
        if isIdentByteStringDataType(schema, targetIdent) {
            if case .byteString = item { return true }
            addError("expected type bstr, got \(item.debugRendering)")
            return false
        }
        if isIdentUintDataType(schema, targetIdent) {
            // A uint target must be a non-negative integer.
            if case .unsigned = item { return true }
            addError("expected type uint, got \(item.debugRendering)")
            return false
        }
        if isIdentNumberDataType(schema, targetIdent) {
            switch item {
            case .unsigned, .negative, .float: return true
            default:
                addError("expected type number, got \(item.debugRendering)")
                return false
            }
        }
        if isIdentIntegerDataType(schema, targetIdent) {
            if let integer = item.integerValue, integerMatchesDataType(schema, targetIdent, integer.bigInt) != false {
                return true
            }
            addError("expected type \(targetIdent), got \(item.debugRendering)")
            return false
        }
        if isIdentFloatDataType(schema, targetIdent) {
            if case .float = item { return true }
            addError("expected type float, got \(item.debugRendering)")
            return false
        }
        if isIdentBoolDataType(schema, targetIdent) {
            if case .bool = item { return true }
            addError("expected type bool, got \(item.debugRendering)")
            return false
        }
        if isIdentNullDataType(schema, targetIdent) {
            if item.isNullOrUndefined { return true }
            addError("expected type null, got \(item.debugRendering)")
            return false
        }
        return true
    }

    /// `.eq` (RFC 8610 Section 3.8.6): the data item is a value of the target
    /// and equal to the controller.
    private func equalityControl(_ target: Type2, _ controller: Type2) async throws(CBORValidationError) {
        switch target {
        case .typename(let ident, _, _):
            // A name that is not a primitive type names a type the data item
            // has to validate against in its own right.
            if !isIdentPrimitiveDataType(state.schema, ident) {
                try await visitType2(target)
            }
            try await visitType2(controller)
        case .array(let group, _, _, _):
            if try await targetAdmitsDataItem(target, item.isArray) {
                let savedEntryCounts = state.entryCounts
                state.entryCounts = entryCountsFromGroup(state.schema, group)
                try await visitType2(controller)
                state.entryCounts = savedEntryCounts
            }
        case .map:
            if try await targetAdmitsDataItem(target, item.isMap) {
                state.ctrl = .eq
                state.isCtrlMapEquality = true
                try await visitType2(controller)
                state.ctrl = nil
                state.isCtrlMapEquality = false
            }
        default:
            try await visitType2(target)
            try await visitType2(controller)
        }
    }

    /// `.ne`: the negation of what `.eq` states.
    private func exclusionControl(_ target: Type2, _ controller: Type2) async throws(CBORValidationError) {
        switch target {
        case .typename(let ident, _, _):
            if !isIdentPrimitiveDataType(state.schema, ident) {
                try await visitType2(target)
            }
            try await validateExclusion(target, controller)
        case .array:
            if try await targetAdmitsDataItem(target, item.isArray) {
                try await validateExclusion(target, controller)
            }
        case .map:
            if try await targetAdmitsDataItem(target, item.isMap) {
                try await validateExclusion(target, controller)
            }
        default:
            try await visitType2(target)
            try await validateExclusion(target, controller)
        }
    }

    /// `.lt`, `.le`, `.gt` and `.ge`, defined on numeric types (RFC 8610
    /// Section 3.8.6).
    private func comparisonControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        if case .typename(let ident, _, _) = target, isIdentNumericDataType(state.schema, ident) {
            state.ctrl = ctrl
            try await visitType2(controller)
            state.ctrl = nil
            return
        }
        if type2DenotesNumericType(state.schema, target) {
            let errorCount = errors.count
            let itemErrorCount = unvalidatedItemErrorCount()
            try await visitType2(target)
            if errors.count == errorCount && unvalidatedItemErrorCount() <= itemErrorCount {
                state.ctrl = ctrl
                try await visitType2(controller)
                state.ctrl = nil
            }
            return
        }
        addError("target for .lt, .gt, .ge or .le operator must be a numerical data type, got \(target)")
    }

    private func bitfieldControl(_ target: Type2, _ controller: Type2) {
        guard case .typename(let ident, _, _) = target, isIdentUintDataType(state.schema, ident) else {
            addError(".bitfield control can only be matched against uint data type, got \(target)")
            return
        }
        guard case .unsigned(let value) = item else {
            addError(".bitfield control can only be matched against a non-negative integer, got \(item.debugRendering)")
            return
        }
        switch extractBitfieldWidths(controller) {
        case let totalBits? where totalBits > 0 && totalBits <= 128:
            let maxValue: BigUInt = totalBits >= 128 ? (BigUInt(1) << 128) - 1 : (BigUInt(1) << Int(totalBits)) - 1
            if BigUInt(value) > maxValue {
                addError("value \(value) exceeds .bitfield capacity of \(totalBits) bits (max \(maxValue))")
            }
        case .some:
            addError(".bitfield total bit width must be between 1 and 128")
        case nil:
            addError(".bitfield controller must be an array of uint values representing bit widths")
        }
    }

    private func embeddedCBORControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        // `.cborseq` decodes a CBOR sequence (RFC 8742) into an array; `.cbor`
        // decodes a single data item.
        func decodeInner(_ bytes: [UInt8]) throws(CBORDecodingError) -> CBORNode {
            ctrl == .cborseq ? try decodeCBORSequence(bytes) : try decodeCBOR(bytes)
        }

        guard case .typename(let ident, _, _) = target, isIdentByteStringDataType(state.schema, ident) else {
            addError(".cbor control can only be matched against a byte string data type, got \(target)")
            return
        }

        switch item {
        case .byteString(let b, _):
            let value: CBORNode
            do {
                value = try decodeInner(b)
            } catch {
                addError("error decoding embedded CBOR: \(error)")
                return
            }
            let level = try embedded(value)
            try await level.walk(.type2(controller))
            errors.append(contentsOf: level.errors)
        case .array(let array):
            for (idx, element) in array.items.enumerated() {
                guard case .byteString(let b, _) = element else {
                    addError(
                        "array item at index \(idx) must be a byte string for .cbor control, got \(element.debugRendering)"
                    )
                    continue
                }
                let value: CBORNode
                do {
                    value = try decodeInner(b)
                } catch {
                    addError("error decoding embedded CBOR at index \(idx): \(error)")
                    continue
                }
                let currentLocation = location
                let level = try embedded(value)
                level.location = paths.child(location, .index(idx))
                try await level.walk(.type2(controller))
                errors.append(contentsOf: level.errors)
                location = currentLocation
            }
        default:
            addError(
                ".cbor control can only be matched against a CBOR byte string or array of byte strings, got \(item.debugRendering)"
            )
        }
    }

    private func bitsControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        guard case .typename(let ident, _, _) = target,
            isIdentByteStringDataType(state.schema, ident) || isIdentUintDataType(state.schema, ident)
        else {
            addError(".bits control can only be matched against a byte string or uint data type, got \(target)")
            return
        }

        // Only the bits numbered by a member of the control type may be set.
        var unadmitted: (UInt64, String)?
        switch item {
        case .byteString(let b, _):
            for bit in setBitNumbersInBytes(b) where !(try await bitIsAdmitted(bit, controller)) {
                unadmitted = (bit, base16Literal(b))
                break
            }
        case .unsigned(let value):
            for bit in setBitNumbersInUint(BigInt(value)) where !(try await bitIsAdmitted(bit, controller)) {
                unadmitted = (bit, integerDebug(item.integerValue!))
                break
            }
        default:
            addError("\(ctrl) control can only be matched against a CBOR byte string or uint, got \(item.debugRendering)")
        }

        if let (bit, data) = unadmitted {
            addError(
                "expected \(target) \(ctrl) \(controller), got \(data). Bit \(bit) is set but is not a member of the control type"
            )
        }
    }

    /// Whether bit number `bit` is a member of `controller`, decided by walking
    /// the bit number as a data item of its own.
    private func bitIsAdmitted(_ bit: UInt64, _ controller: Type2) async throws(CBORValidationError) -> Bool {
        let level = try embedded(.unsigned(bit))
        try await level.walk(.type2(controller))
        return level.errors.isEmpty
    }

    /// Matches the data item against `values` in turn, keeping the errors of
    /// none of them once one admits it.
    private func visitFirstAdmitting(_ values: [Type2]) async throws(CBORValidationError) {
        let errorCount = errors.count
        for v in values {
            let curErrors = errors.count
            try await visitType2(v)
            if errors.count == curErrors {
                errors.removeLast(errors.count - errorCount)
                break
            }
        }
    }

    private func abnfControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        let isText = ctrl == .abnf
        let targetMatches: Bool
        if case .typename(let ident, _, _) = target {
            targetMatches =
                isText ? isIdentStringDataType(state.schema, ident) : isIdentByteStringDataType(state.schema, ident)
        } else {
            targetMatches = false
        }
        guard targetMatches else {
            addError(
                isText
                    ? ".abnf can only be matched against string data type, got \(target)"
                    : ".abnfb can only be matched against byte string target data type, got \(target)")
            return
        }

        switch item {
        case .textString where isText, .byteString where !isText, .array:
            break
        default:
            addError(
                isText
                    ? ".abnf control can only be matched against a cbor string, got \(item.debugRendering)"
                    : ".abnfb control can only be matched against cbor bytes, got \(item.debugRendering)")
            return
        }

        var complex: Result<[Type2], SchemaFault>?
        if case .parenthesizedType(let pt, _, _, _) = controller {
            complex = abnfFromComplexController(state.schema, pt)
        } else if case .typename(let ident, _, _) = controller,
            case .type(let rule, _, _, _)? = ruleFromIdent(state.schema, ident),
            case .success(let values) = abnfFromComplexController(state.schema, rule.value)
        {
            complex = .success(values)
        }

        switch complex {
        case .success(let values)?:
            try await visitFirstAdmitting(values)
        case .failure(let fault)?:
            throw schemaError(fault.message)
        case nil:
            try await visitType2(controller)
        }
    }

    private func featureControl(_ target: Type2, _ controller: Type2) async throws(CBORValidationError) {
        guard let enabled = state.enabledFeatures else { return }

        let feature: String
        switch textValueFromType2(state.schema, controller) {
        case .textValue(let value, _)?:
            feature = value
        case .utf8ByteString(let value, _)?:
            guard let text = String(validatingUTF8Bytes: value) else {
                throw .utf8Parsing(utf8ErrorDescription(value))
            }
            feature = text
        default:
            return
        }

        if enabled.contains(where: { $0.utf8.elementsEqual(feature.utf8) }) {
            let errorCount = errors.count
            try await visitType2(target)
            if errors.count > errorCount {
                state.hasFeatureErrors = true
            }
            state.ctrl = nil
        } else {
            if state.disabledFeatures == nil {
                state.disabledFeatures = [feature]
            }
            state.disabledFeatures!.append(feature)
        }
    }

    /// RFC 9741 Section 2.1: the target text is the encoded form of a byte
    /// string, and the controller is the type that byte string belongs to.
    private func textConversionControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(CBORValidationError) {
        guard case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) else {
            addError("\(ctrl) can only be matched against string data type, got \(target)")
            return
        }
        guard case .textString(let s, _) = item else {
            addError("\(ctrl) can only be matched against CBOR text, got \(item.debugRendering)")
            return
        }
        guard let decoded = decodeTextConversion(ctrl, s) else {
            addError(textConversionEncodingError(ctrl, s))
            return
        }
        switch await byteStringMismatches(
            state, controller, decoded, limits, work, dataNesting + 1, descentCost, embeddedDepth + 1)
        {
        case .success(let reasons):
            for reason in reasons {
                addError(textConversionControllerError(ctrl, reason))
            }
        case .failure(let reason):
            throw limitError(reason.reason)
        }
    }

    /// `.base10`, `.printf`, `.json` and `.join` (RFC 9741 Sections 2.2 to 3.1).
    private func textFormatControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) {
        guard case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) else {
            addError("\(ctrl) can only be matched against string data type, got \(target)")
            return
        }
        guard case .textString(let s, _) = item else {
            addError("\(ctrl) can only be matched against CBOR text, got \(item.debugRendering)")
            return
        }

        let result: Result<Bool, SchemaFault>
        let mismatch: String
        switch ctrl {
        case .base10:
            result = validateBase10Text(target, controller, s)
            mismatch = "text string \"\(s)\" does not match .base10 integer format"
        case .printf:
            result = validatePrintfText(target, controller, s)
            mismatch = "text string \"\(s)\" does not match .printf format"
        case .json:
            result = validateJSONText(target, controller, s)
            mismatch = "text string \"\(s)\" does not contain valid JSON"
        default:
            result = validateJoinText(target, controller, s, state.schema)
            mismatch = "text string \"\(s)\" does not match .join result"
        }

        switch result {
        case .success(true):
            break
        case .success(false):
            addError(mismatch)
        case .failure(let fault):
            addError(fault.message)
        }
    }
}

/// The reasons a byte string is not a member of the type `controller` (RFC
/// 9741 Section 2.1), or the breached implementation limit.
///
/// The byte string is a payload decoded out of the document, walked against
/// the budget of the run that reached the control, so that a document holding
/// many such controls spends one budget between them.
func byteStringMismatches(
    _ state: ValidationState,
    _ controller: Type2,
    _ bytes: [UInt8],
    _ limits: ValidationLimits,
    _ work: WorkBudget,
    _ dataNesting: Int,
    _ descentCost: Int,
    _ embeddedDepth: Int
) async -> Result<[String], LimitReason> {
    if dataNesting > limits.maxNestingDepth {
        return .failure(
            LimitReason(
                "data is nested more deeply than the maximum supported nesting depth of \(limits.maxNestingDepth)"))
    }
    if embeddedDepth > limits.maxEmbeddedDepth {
        return .failure(
            LimitReason(
                "embedded payloads are nested more deeply than the maximum supported \(limits.maxEmbeddedDepth) open payloads"
            ))
    }

    let charged: Int
    switch chargeDescent(descentCost, limits.dataLevelCost, limits.maxDescentCost) {
    case .success(let cost): charged = cost
    case .failure(let reason): return .failure(reason)
    }

    var levelState = ValidationState(schema: state.schema, enabledFeatures: state.enabledFeatures)
    levelState.genericRules = state.genericRules
    levelState.evalGenericRule = state.evalGenericRule

    let level = Level(
        state: levelState,
        item: .byteString(bytes),
        location: .root,
        limits: limits,
        work: work,
        paths: PathArena()
    )
    level.descentCost = charged
    level.dataNesting = dataNesting
    level.embeddedDepth = embeddedDepth

    let walked: Result<Void, CBORValidationError>
    do throws(CBORValidationError) {
        try await level.walk(.type2(controller))
        walked = .success(())
    } catch {
        walked = .failure(error)
    }

    switch walked {
    case .success:
        return .success(level.errors.map(\.reason))
    case .failure(let error):
        return .failure(LimitReason(error.description))
    }
}

/// Extracts the total bit width from a `.bitfield` controller, an array of
/// uint widths.
func extractBitfieldWidths(_ controller: Type2) -> UInt64? {
    guard case .array(let group, _, _, _) = controller else { return nil }
    var totalBits: UInt64 = 0
    for gc in group.groupChoices {
        for (ge, _) in gc.groupEntries {
            switch ge {
            case .valueMemberKey(let vmke, _, _, _):
                guard let width = extractUintFromType(vmke.entryType) else { return nil }
                let (sum, overflow) = totalBits.addingReportingOverflow(width)
                if overflow { return nil }
                totalBits = sum
            case .typeGroupname(let tge, _, _, _):
                guard let width = UInt64(tge.name.ident) else { return nil }
                let (sum, overflow) = totalBits.addingReportingOverflow(width)
                if overflow { return nil }
                totalBits = sum
            default:
                return nil
            }
        }
    }
    return totalBits
}

private func extractUintFromType(_ t: Type) -> UInt64? {
    guard t.typeChoices.count == 1 else { return nil }
    switch t.typeChoices[0].type1.type2 {
    case .uintValue(let value, _): return value
    case .intValue(let value, _) where value.sign == .plus || value.isZero: return UInt64(exactly: value)
    default: return nil
    }
}
