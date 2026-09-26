import Foundation

// Validation of a JSON document (RFC 8259) against a CDDL schema (RFC 8610,
// Section 3 and Appendix E).

// MARK: - Errors

/// One way a JSON document fails to match a CDDL schema.
///
/// An error carries the location of the value it is about, not of the schema
/// construct the value was tried against: the walk resolves rule references,
/// generic arguments and choice alternatives on the way to a value, so the
/// construct is a path through the schema rather than one span of its text.
public struct JSONValidationIssue: Sendable, Hashable, CustomStringConvertible {
    /// Why the value does not match.
    public var reason: String
    /// Where the value is in the document, as a JSON Pointer (RFC 6901) of
    /// array indices and member names; the empty string for the root.
    public var jsonLocation: String
    /// Whether the error is associated with a choice between types.
    public var isMultiTypeChoice: Bool
    /// Whether the error is associated with a choice between groups.
    public var isMultiGroupChoice: Bool
    /// Whether the error is associated with a group turned into a choice
    /// (RFC 8610 Section 3.6).
    public var isGroupToChoiceEnum: Bool
    /// The rule a type or group name entry names, where the error is
    /// associated with one.
    public var typeGroupNameEntry: String?

    /// An error.
    public init(
        reason: String,
        jsonLocation: String,
        isMultiTypeChoice: Bool = false,
        isMultiGroupChoice: Bool = false,
        isGroupToChoiceEnum: Bool = false,
        typeGroupNameEntry: String? = nil
    ) {
        self.reason = reason
        self.jsonLocation = jsonLocation
        self.isMultiTypeChoice = isMultiTypeChoice
        self.isMultiGroupChoice = isMultiGroupChoice
        self.isGroupToChoiceEnum = isGroupToChoiceEnum
        self.typeGroupNameEntry = typeGroupNameEntry
    }

    public var description: String {
        var prefix = "error validating"
        if isMultiGroupChoice {
            prefix += " group choice"
        }
        if isMultiTypeChoice {
            prefix += " type choice"
        }
        if isGroupToChoiceEnum {
            prefix += " type choice in group to choice enumeration"
        }
        if let entry = typeGroupNameEntry {
            prefix += " group entry associated with rule \"\(entry)\""
        }
        if jsonLocation.isEmpty {
            return "\(prefix) at the root of the JSON document: \(reason)"
        }
        return "\(prefix) at JSON location \(jsonLocation): \(reason)"
    }
}

/// Why a JSON document was not validated as matching a CDDL schema.
public enum JSONValidationError: Error, Sendable, CustomStringConvertible {
    /// The document does not match the schema, for these reasons.
    case validation([JSONValidationIssue])
    /// The document is not one well-formed JSON value.
    ///
    /// The fault is in the document alone: nothing follows from it about the
    /// schema.
    case jsonParsing(JSONParsingError)
    /// The schema did not parse.
    case cddlParsing(String)
    /// A text value that has to be UTF-8 is not.
    case utf8Parsing(String)
    /// A fault in the schema found while validating, rather than a mismatch
    /// between the document and the schema: a control operator whose operand
    /// denotes no value, for example. Validation stops where the fault was
    /// found, since reporting a mismatch instead would let the first
    /// alternative of a choice that matches discard it.
    case invalidSchema(JSONValidationIssue)
    /// The schema uses a feature this implementation does not provide: the
    /// `.abnf` and `.abnfb` control operators (RFC 9165 Section 3).
    case unsupported(String)

    /// The errors of a document that does not match, or `nil` for any other
    /// failure.
    public var issues: [JSONValidationIssue]? {
        if case .validation(let issues) = self {
            return issues
        }
        return nil
    }

    public var description: String {
        switch self {
        case .validation(let issues):
            return issues.map { "\($0)\n" }.joined()
        case .jsonParsing(let error):
            return "error parsing JSON: \(error)"
        case .cddlParsing(let error):
            return "error parsing CDDL: \(error)"
        case .utf8Parsing(let error):
            return "error parsing utf8: \(error)"
        case .invalidSchema(let issue):
            return issue.description
        case .unsupported(let feature):
            return "unsupported: \(feature)"
        }
    }
}

// MARK: - Validator

/// Validates one JSON document against a CDDL schema.
///
/// The document is matched against the root rule: the first type rule of the
/// schema that takes no generic parameters (RFC 8610 Section 3.1), or the rule
/// named by ``rootRule``.
///
/// The walk keeps its state in the frames of asynchronous calls, which live on
/// the heap, so a document nested as deeply as ``ValidationLimits`` admits is
/// validated on any thread, a Swift concurrency task's included.
public final class JSONValidator {
    var state: ValidationState
    /// The document being validated.
    public let json: JSONNode
    var errors: [JSONValidationIssue] = []
    var storedLimits: ValidationLimits
    var work: WorkBudget

    /// A validator of `json` against `cddl`, with the given features enabled
    /// for the `.feature` control operator (RFC 9165 Section 4).
    public convenience init(cddl: CDDL, json: JSONNode, enabledFeatures: [String]? = nil) {
        self.init(schema: Schema(cddl), json: json, enabledFeatures: enabledFeatures)
    }

    /// A validator of `json` against `document`, with the given features enabled
    /// for the `.feature` control operator (RFC 9165 Section 4).
    public convenience init(document: CDDLDocument, json: JSONNode, enabledFeatures: [String]? = nil) {
        self.init(schema: document.schema, json: json, enabledFeatures: enabledFeatures)
    }

    init(schema: Schema, json: JSONNode, enabledFeatures: [String]?) {
        self.state = ValidationState(schema: schema, enabledFeatures: enabledFeatures)
        self.json = json
        self.storedLimits = ValidationLimits()
        self.work = WorkBudget(limit: ValidationLimits.defaultMaxValidationWork)
    }

    /// Validates the document against the type rule named `name` rather than
    /// against the first type rule of the schema. A name the schema does not
    /// define as a non-generic type rule is reported as a validation error.
    func setRootRule(_ name: String) {
        state.rootRule = name
    }

    /// The type rule the document is validated against, by name; `nil`
    /// means the first type rule of the schema that takes no generic
    /// parameters. A name the schema does not define as such a rule is
    /// reported as a validation error.
    public var rootRule: String? {
        get { state.rootRule }
        set { state.rootRule = newValue }
    }

    /// The implementation limits this validator runs under. Setting them
    /// starts a fresh work budget.
    public var limits: ValidationLimits {
        get {
            var limits = storedLimits
            limits.maxValidationWork = work.limit
            return limits
        }
        set {
            setLimits(newValue)
        }
    }

    /// Sets every implementation limit this validator runs under, starting a
    /// fresh work budget.
    func setLimits(_ limits: ValidationLimits) {
        storedLimits = limits
        work = WorkBudget(limit: limits.maxValidationWork)
    }

    /// Sets the upper bound on the nesting depth of the data.
    func setMaxNestingDepth(_ maxNestingDepth: Int) {
        storedLimits.maxNestingDepth = maxNestingDepth
    }

    /// Sets the upper bound on how many rule references are resolved against
    /// one value.
    func setMaxRuleNesting(_ maxRuleNesting: Int) {
        storedLimits.maxRuleNesting = maxRuleNesting
    }

    /// Sets the upper bound on what the descent to one value may cost.
    func setMaxDescentCost(_ maxDescentCost: Int) {
        storedLimits.maxDescentCost = maxDescentCost
    }

    /// Sets what a step into a nested value and a rule reference resolved
    /// against the value already held charge the descent budget.
    func setDescentWeights(dataLevelCost: Int, ruleHopCost: Int) {
        storedLimits.dataLevelCost = dataLevelCost
        storedLimits.ruleHopCost = ruleHopCost
    }

    /// Sets the upper bound on how many values synthesised from the document
    /// -- a member name held as a string of its own, a bit number `.bits`
    /// enumerates, a byte string a text conversion control decodes -- may be
    /// open at once.
    func setMaxEmbeddedDepth(_ maxEmbeddedDepth: Int) {
        storedLimits.maxEmbeddedDepth = maxEmbeddedDepth
    }

    /// Sets the upper bound on the size of the report, in bytes of its rendered
    /// errors.
    func setMaxReportBytes(_ maxReportBytes: Int) {
        storedLimits.maxReportBytes = maxReportBytes
    }

    /// Sets the upper bound on the work one run may do, starting a fresh work
    /// budget.
    func setMaxValidationWork(_ maxValidationWork: Int) {
        storedLimits.maxValidationWork = maxValidationWork
        work = WorkBudget(limit: maxValidationWork)
    }

    /// Records a validation error at the root of the document, reported with
    /// the errors the walk finds.
    func addError(_ reason: String) {
        errors.append(
            JSONValidationIssue(
                reason: reason,
                jsonLocation: "",
                isMultiTypeChoice: state.isMultiTypeChoice,
                isMultiGroupChoice: state.isMultiGroupChoice,
                isGroupToChoiceEnum: state.isGroupToChoiceEnum,
                typeGroupNameEntry: state.typeGroupNameEntry
            ))
    }

    /// The error a spent work budget reports.
    func workLimitError() -> JSONValidationError {
        .validation([
            JSONValidationIssue(
                reason:
                    "validating this data against this schema takes more than the maximum supported \(work.limit) steps of validation work",
                jsonLocation: "",
                isMultiTypeChoice: state.isMultiTypeChoice,
                isMultiGroupChoice: state.isMultiGroupChoice,
                isGroupToChoiceEnum: state.isGroupToChoiceEnum,
                typeGroupNameEntry: state.typeGroupNameEntry
            )
        ])
    }

    /// Validates the document, throwing what does not match.
    public func validate() async throws(JSONValidationError) {
        let paths = PathArena()
        let root = JSONLevel(root: self, paths: paths)

        try await root.walk(.root)

        // A run that asked for a step it did not have cannot be reported as a
        // verdict: what the budget did not reach went unexamined.
        if work.overspent {
            throw workLimitError()
        }

        let recorded = retainedErrors(root.errors, paths, storedLimits.maxReportBytes)
        if !recorded.isEmpty || !errors.isEmpty {
            var issues = recorded.map { renderJSONError($0, paths) }
            issues.append(contentsOf: errors)
            throw .validation(issues)
        }
    }

    /// Validates the document, blocking the calling thread until the walk is
    /// done; see ``validate()``.
    ///
    /// Safe to call from any context, a task of the shared concurrency pool
    /// included: the calling thread runs the walk itself.
    public func validateSynchronously() throws(JSONValidationError) {
        try validate()
    }

    func validate() throws(JSONValidationError) {
        let validator = UncheckedBox(self)
        let result = runBlocking { () async -> Result<Void, JSONValidationError> in
            do throws(JSONValidationError) {
                try await validator.value.validate()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }
}

/// The report of one recorded error, at its rendered location.
func renderJSONError(_ record: ErrorRecord, _ paths: PathArena) -> JSONValidationIssue {
    JSONValidationIssue(
        reason: record.reason,
        jsonLocation: paths.render(record.location),
        isMultiTypeChoice: record.isMultiTypeChoice,
        isMultiGroupChoice: record.isMultiGroupChoice,
        isGroupToChoiceEnum: record.isGroupToChoiceEnum,
        typeGroupNameEntry: record.typeGroupNameEntry
    )
}

// MARK: - One-call entry points

/// Validates the JSON document `json` against the CDDL schema text `cddl`.
///
/// A schema that does not parse and a document that does not read as one
/// JSON value are reported apart, as ``JSONValidationError/cddlParsing(_:)``
/// and ``JSONValidationError/jsonParsing(_:)``.
///
/// - Parameters:
///   - cddl: The schema.
///   - json: The document.
///   - rule: The type rule to validate against; the first type rule of the
///     schema when `nil`.
///   - enabledFeatures: The features the `.feature` control operator treats as
///     enabled.
///   - limits: The implementation limits the walk runs under.
func validateJSON(
    cddl: String,
    json: String,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) async throws(JSONValidationError) {
    let validator = try makeJSONValidator(cddl: cddl, json: json, rule: rule, enabledFeatures: enabledFeatures)
    validator.setLimits(limits)
    try await validator.validate()
}

/// Validates the JSON document `json` against the CDDL schema text `cddl`,
/// blocking the calling thread until the walk is done.
func validateJSON(
    cddl: String,
    json: String,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) throws(JSONValidationError) {
    let validator = try makeJSONValidator(cddl: cddl, json: json, rule: rule, enabledFeatures: enabledFeatures)
    validator.setLimits(limits)
    try validator.validate()
}

private func makeJSONValidator(
    cddl: String,
    json: String,
    rule: String?,
    enabledFeatures: [String]?
) throws(JSONValidationError) -> JSONValidator {
    let schema: CDDL
    do {
        schema = try cddlFromStr(cddl)
    } catch {
        throw .cddlParsing(error.description)
    }
    let node: JSONNode
    do {
        node = try JSONNode.parse(json)
    } catch {
        throw .jsonParsing(error)
    }
    let validator = JSONValidator(cddl: schema, json: node, enabledFeatures: enabledFeatures)
    if let rule {
        validator.setRootRule(rule)
    }
    return validator
}
