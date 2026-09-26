import BigInt
import Foundation

// Control operators applied to a JSON value (RFC 8610 Section 3.8, RFC 9165,
// RFC 9741).

extension JSONLevel {
    func visitControlOperator(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(JSONValidationError) {
        // A type in member key position denotes the names the group entry
        // answers for, so a control applied to it constrains each name.
        if state.isMemberKey && item.isObject {
            try await validateObjectKeyControl(target, ctrl, controller)
            return
        }

        // Inside an array group the control applies to the items the entry
        // stands for, not to the array holding them.
        if case .typename = target, item.isArray, state.entryCounts != nil {
            try await validateArrayItems(.control(target, ctrl, controller))
            return
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

            // The value has to be of the target's type before a control on that
            // type says anything about it; an operator computing its value from
            // both operands is the exception.
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
                addError("expected type \(target) .within type \(controller), got \(item.elidedRendering)")
            }
            state.ctrl = nil
        case .default:
            state.ctrl = ctrl
            let errorCount = errors.count
            try await visitType2(target)
            if errors.count != errorCount, case .optional? = state.occurrence {
                addError("expected default value \(controller), got \(item.elidedRendering)")
            }
            state.ctrl = nil
        case .regexp, .pcre, .iregexp:
            state.ctrl = ctrl
            let name = ctrl == .regexp ? ".regexp" : ctrl == .pcre ? ".pcre" : ".iregexp"
            if case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) {
                switch item {
                case .string, .array:
                    try await visitType2(controller)
                default:
                    addError("\(name) control can only be matched against JSON string, got \(item.elidedRendering)")
                }
            } else {
                addError("\(name) control can only be matched against string data type, got \(target)")
            }
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
            // The generic parameters an operand names stand for their
            // arguments before the sum is computed.
            let substitutedTarget = substituteGenericParam(target) ?? target
            let substitutedController = substituteGenericParam(controller) ?? controller
            switch plusOperation(state.schema, substitutedTarget, substitutedController) {
            case .success(let values): try await visitFirstAdmitting(values)
            case .failure(let fault): throw schemaError(fault.message)
            }
            state.ctrl = nil
        case .abnf:
            state.ctrl = ctrl
            try await abnfControl(target, controller)
            state.ctrl = nil
        case .feature:
            state.ctrl = ctrl
            try await featureControl(target, controller)
            state.ctrl = nil
        case .b64u, .b64c, .b64uSloppy, .b64cSloppy, .hex, .hexlc, .hexuc, .b32, .h32, .b45:
            try await textConversionControl(target, ctrl, controller)
        case .base10, .printf, .json, .join:
            textFormatControl(target, ctrl, controller)
        case .bits:
            state.ctrl = ctrl
            try await bitsControl(target, ctrl, controller)
            state.ctrl = nil
        case .abnfb, .bitfield, .cbor, .cborseq:
            // These constrain byte strings, which the JSON data model has none
            // of.
            addError("unsupported control operator \(ctrl)")
        }
    }

    /// Whether the value is of the type the target names, reporting it when it
    /// is not.
    private func holdsToTargetType(_ targetIdent: Identifier) -> Bool {
        let schema = state.schema
        if isIdentStringDataType(schema, targetIdent), !isString {
            addError("expected type tstr, got \(item.elidedRendering)")
            return false
        } else if isIdentByteStringDataType(schema, targetIdent) {
            // No JSON value is a byte string, so a byte string target admits
            // none of them.
            addError("expected type bstr, got \(item.elidedRendering)")
            return false
        } else if isIdentUintDataType(schema, targetIdent) {
            if case .number(let n) = item, n.uint64 != nil {
                return true
            }
            addError("expected type uint, got \(item.elidedRendering)")
            return false
        } else if isIdentNumberDataType(schema, targetIdent) {
            // RFC 8610 Appendix D defines `number = int / float`, so a number is
            // a value of it however it is written.
            if case .number = item {
                return true
            }
            addError("expected type number, got \(item.elidedRendering)")
            return false
        } else if isIdentIntegerDataType(schema, targetIdent) {
            // A name among the integer types constrains the sign as well as the
            // kind.
            var admitted = false
            if case .number(let n) = item, !n.isFloat {
                admitted = n.integer.map { integerMatchesDataType(schema, targetIdent, $0) != false } ?? true
            }
            if !admitted {
                addError("expected type \(targetIdent), got \(item.elidedRendering)")
                return false
            }
            return true
        } else if isIdentFloatDataType(schema, targetIdent), !isFloatNumber {
            addError("expected type float, got \(item.elidedRendering)")
            return false
        } else if isIdentBoolDataType(schema, targetIdent), !isBool {
            addError("expected type bool, got \(item.elidedRendering)")
            return false
        } else if isIdentNullDataType(schema, targetIdent), !item.isNull {
            addError("expected type null, got \(item.elidedRendering)")
            return false
        }
        return true
    }

    private var isString: Bool {
        if case .string = item { return true }
        return false
    }

    private var isBool: Bool {
        if case .bool = item { return true }
        return false
    }

    private var isFloatNumber: Bool {
        if case .number(let n) = item { return n.isFloat }
        return false
    }

    /// `.eq` (RFC 8610 Section 3.8.6): the value is a value of the target and
    /// equal to the controller.
    private func equalityControl(_ target: Type2, _ controller: Type2) async throws(JSONValidationError) {
        switch target {
        case .typename(let ident, _, _):
            // A name that is not a primitive type names a type the value has
            // to validate against in its own right.
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
            if try await targetAdmitsDataItem(target, item.isObject) {
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
    private func exclusionControl(_ target: Type2, _ controller: Type2) async throws(JSONValidationError) {
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
            if try await targetAdmitsDataItem(target, item.isObject) {
                try await validateExclusion(target, controller)
            }
        default:
            try await visitType2(target)
            try await validateExclusion(target, controller)
        }
    }

    /// `.lt`, `.le`, `.gt` and `.ge`, defined on numeric types (RFC 8610
    /// Section 3.8.6).
    private func comparisonControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(JSONValidationError) {
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

    /// `.bits` (RFC 8610 Section 3.8.2): only the bits numbered by a member of
    /// the control type may be set. The JSON data model has no byte strings,
    /// so a uint is the only target a value can be held to.
    private func bitsControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(JSONValidationError) {
        guard case .typename(let ident, _, _) = target, isIdentUintDataType(state.schema, ident) else {
            addError(".bits control can only be matched against a uint data type, got \(target)")
            return
        }

        var unadmitted: (UInt64, String)?
        switch item {
        case .number(let n):
            if let value = n.uint64 {
                for bit in setBitNumbersInUint(BigInt(value)) where !(try await bitIsAdmitted(bit, controller)) {
                    unadmitted = (bit, n.description)
                    break
                }
            } else {
                addError("\(ctrl) control can only be matched against a non-negative integer, got \(n)")
            }
        default:
            addError("\(ctrl) control can only be matched against a JSON number, got \(item.elidedRendering)")
        }

        if let (bit, data) = unadmitted {
            addError(
                "expected \(target) \(ctrl) \(controller), got \(data). Bit \(bit) is set but is not a member of the control type"
            )
        }
    }

    /// Whether bit number `bit` is a member of `controller`, decided by walking
    /// the bit number as a value of its own.
    private func bitIsAdmitted(_ bit: UInt64, _ controller: Type2) async throws(JSONValidationError) -> Bool {
        let level = try embedded(.unsigned(bit))
        try await level.walk(.type2(controller))
        return level.errors.isEmpty
    }

    /// Matches the value against `values` in turn, keeping the errors of none
    /// of them once one admits it.
    private func visitFirstAdmitting(_ values: [Type2]) async throws(JSONValidationError) {
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

    /// The argument a generic parameter named as an operand stands for, if
    /// `t2` names one.
    private func substituteGenericParam(_ t2: Type2) -> Type2? {
        guard case .typename(let ident, _, _) = t2 else { return nil }
        for gr in state.genericRules {
            for (idx, param) in gr.params.enumerated() where ident.ident == param {
                if idx < gr.args.count {
                    return gr.args[idx].type2
                }
            }
        }
        return nil
    }

    private func abnfControl(_ target: Type2, _ controller: Type2) async throws(JSONValidationError) {
        guard case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) else {
            addError(".abnf can only be matched against string data type, got \(target)")
            return
        }

        switch item {
        case .string, .array:
            break
        default:
            addError(".abnf control can only be matched against a JSON string, got \(item.fullRendering)")
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

    private func featureControl(_ target: Type2, _ controller: Type2) async throws(JSONValidationError) {
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

        if enabled.contains(where: { sameText($0, feature) }) {
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
    /// string, and the controller is the type that byte string belongs to. JSON
    /// carries no byte strings, so the byte string the text decodes to is
    /// matched against the controller in the CBOR data model.
    private func textConversionControl(_ target: Type2, _ ctrl: ControlOperator, _ controller: Type2) async throws(JSONValidationError) {
        guard case .typename(let ident, _, _) = target, isIdentStringDataType(state.schema, ident) else {
            addError("\(ctrl) can only be matched against string data type, got \(target)")
            return
        }
        guard case .string(let s) = item else {
            addError("\(ctrl) can only be matched against JSON string, got \(item.elidedRendering)")
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
        guard case .string(let s) = item else {
            addError("\(ctrl) can only be matched against JSON string, got \(item.elidedRendering)")
            return
        }

        let result: Result<Bool, SchemaFault>
        let mismatch: String
        switch ctrl {
        case .base10:
            result = validateBase10Text(target, controller, s)
            mismatch = "string \"\(s)\" does not match .base10 integer format"
        case .printf:
            result = validatePrintfText(target, controller, s)
            mismatch = "string \"\(s)\" does not match .printf format"
        case .json:
            result = validateJSONText(target, controller, s)
            mismatch = "string \"\(s)\" does not contain valid JSON"
        default:
            result = validateJoinText(target, controller, s, state.schema)
            mismatch = "string \"\(s)\" does not match .join result"
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
