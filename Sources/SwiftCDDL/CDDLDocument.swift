import Foundation

// The front door of the package: a parsed schema, and validation of CBOR and
// JSON documents against it with a plain verdict.

/// A parsed CDDL schema (RFC 8610).
///
/// Parse a schema once and validate any number of documents against it:
///
/// ```swift
/// let schema = try CDDLDocument("""
///     person = { name: tstr, age: uint }
///     """)
/// let result = await schema.validate(json: #"{"name": "Ada", "age": 36}"#)
/// print(result.isValid)  // true
/// ```
///
/// A document is immutable and `Sendable`: share it between tasks freely.
public struct CDDLDocument: Sendable {
    /// The schema with its rules indexed by name, built once and shared by
    /// every validation run.
    let schema: Schema

    /// Parses `source` as a CDDL schema.
    ///
    /// Besides the syntax, the parse checks that every name the schema refers
    /// to is defined: by a rule, by the standard prelude (RFC 8610 Appendix
    /// D), as a generic parameter, or as a socket.
    ///
    /// - Throws: ``CDDLParseError`` saying where and why the schema does not
    ///   parse.
    public init(_ source: String) throws(CDDLParseError) {
        do {
            schema = Schema(try parseCDDLChecked(source))
        } catch {
            throw CDDLParseError(error)
        }
    }

    /// Parses `data`, UTF-8 encoded CDDL text, as a CDDL schema; see
    /// ``init(_:)-(String)``.
    ///
    /// - Throws: ``CDDLParseError`` saying where and why the schema does not
    ///   parse, or that `data` is not UTF-8.
    public init(data: Data) throws(CDDLParseError) {
        do {
            schema = Schema(try CDDL.fromSlice([UInt8](data)))
        } catch {
            throw CDDLParseError(error)
        }
    }

    /// A document for an AST built or edited in code.
    public init(_ ast: CDDL) {
        schema = Schema(ast)
    }

    /// The syntax tree of the schema, comments included.
    public var ast: CDDL {
        schema.cddl
    }

    /// The rules of the schema, in the order the source writes them. A name
    /// extended with `/=` or `//=` has one rule for each extension.
    public var rules: [Rule] {
        schema.cddl.rules
    }

    /// The first rule the schema writes for `name`, which may carry its
    /// socket prefix (`$name` or `$$name`), or `nil` when there is none.
    public func rule(named name: String) -> Rule? {
        schema.rules(key: name).first
    }

    /// The schema written back as CDDL text, with every comment kept.
    /// Formatting the text again changes nothing.
    public func formatted() -> String {
        schema.cddl.description
    }

    // MARK: CBOR

    /// Validates `cbor`, which must hold exactly one CBOR data item (RFC
    /// 8949), against the schema.
    ///
    /// - Parameters:
    ///   - cbor: The encoded document.
    ///   - rule: The type rule to validate against; the first type rule of
    ///     the schema that takes no generic parameters when `nil` (RFC 8610
    ///     Section 3.1).
    ///   - options: Enabled features and implementation limits.
    /// - Returns: The verdict; a document that does not decode is reported as
    ///   a ``ValidationIssue/Kind/malformedDocument`` issue.
    public func validate(
        cbor: Data,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) async -> ValidationResult {
        let node: CBORNode
        do {
            node = try CBORNode(decoding: cbor)
        } catch {
            return ValidationResult(CBORValidationError.cborDecoding(error))
        }
        return await validate(cbor: node, rule: rule, options: options)
    }

    /// Validates a decoded CBOR data item against the schema; see
    /// ``validate(cbor:rule:options:)-(Data,_,_)``.
    public func validate(
        cbor node: CBORNode,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) async -> ValidationResult {
        let validator = CBORValidator(schema: schema, cbor: node, enabledFeatures: options.enabledFeatures)
        validator.limits = options.limits
        validator.rootRule = rule
        do {
            try await validator.validate()
            return ValidationResult(issues: [])
        } catch {
            return ValidationResult(error)
        }
    }

    /// Validates `cbor` against the schema, blocking the calling thread until
    /// the verdict is in; see ``validate(cbor:rule:options:)-(Data,_,_)``.
    ///
    /// Safe to call from any context, a task of the shared concurrency pool
    /// included: the calling thread runs the validation itself.
    public func validateSynchronously(
        cbor: Data,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) -> ValidationResult {
        runBlocking { await self.validate(cbor: cbor, rule: rule, options: options) }
    }

    /// Validates a decoded CBOR data item against the schema, blocking the
    /// calling thread until the verdict is in; see
    /// ``validateSynchronously(cbor:rule:options:)-(Data,_,_)``.
    public func validateSynchronously(
        cbor node: CBORNode,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) -> ValidationResult {
        runBlocking { await self.validate(cbor: node, rule: rule, options: options) }
    }

    // MARK: JSON

    /// Validates the JSON text `json` (RFC 8259) against the schema.
    ///
    /// - Parameters:
    ///   - json: The document.
    ///   - rule: The type rule to validate against; the first type rule of
    ///     the schema that takes no generic parameters when `nil`.
    ///   - options: Enabled features and implementation limits.
    /// - Returns: The verdict; text that is not one JSON value is reported as
    ///   a ``ValidationIssue/Kind/malformedDocument`` issue.
    public func validate(
        json: String,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) async -> ValidationResult {
        let node: JSONNode
        do {
            node = try JSONNode.parse(json)
        } catch {
            return ValidationResult(JSONValidationError.jsonParsing(error))
        }
        return await validate(json: node, rule: rule, options: options)
    }

    /// Validates UTF-8 encoded JSON text against the schema; see
    /// ``validate(json:rule:options:)-(String,_,_)``.
    public func validate(
        json: Data,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) async -> ValidationResult {
        let node: JSONNode
        do {
            node = try JSONNode.parse(bytes: [UInt8](json))
        } catch {
            return ValidationResult(JSONValidationError.jsonParsing(error))
        }
        return await validate(json: node, rule: rule, options: options)
    }

    /// Validates a parsed JSON value against the schema; see
    /// ``validate(json:rule:options:)-(String,_,_)``.
    public func validate(
        json node: JSONNode,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) async -> ValidationResult {
        let validator = JSONValidator(schema: schema, json: node, enabledFeatures: options.enabledFeatures)
        validator.limits = options.limits
        validator.rootRule = rule
        do {
            try await validator.validate()
            return ValidationResult(issues: [])
        } catch {
            return ValidationResult(error)
        }
    }

    /// Validates the JSON text `json` against the schema, blocking the calling
    /// thread until the verdict is in; see
    /// ``validate(json:rule:options:)-(String,_,_)``.
    ///
    /// Safe to call from any context, a task of the shared concurrency pool
    /// included: the calling thread runs the validation itself.
    public func validateSynchronously(
        json: String,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) -> ValidationResult {
        runBlocking { await self.validate(json: json, rule: rule, options: options) }
    }

    /// Validates UTF-8 encoded JSON text against the schema, blocking the
    /// calling thread until the verdict is in.
    public func validateSynchronously(
        json: Data,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) -> ValidationResult {
        runBlocking { await self.validate(json: json, rule: rule, options: options) }
    }

    /// Validates a parsed JSON value against the schema, blocking the calling
    /// thread until the verdict is in.
    public func validateSynchronously(
        json node: JSONNode,
        rule: String? = nil,
        options: ValidationOptions = ValidationOptions()
    ) -> ValidationResult {
        runBlocking { await self.validate(json: node, rule: rule, options: options) }
    }
}

// MARK: - Options

/// How a document is validated.
public struct ValidationOptions: Sendable, Hashable {
    /// The features the `.feature` control operator treats as enabled (RFC
    /// 9165 Section 4). When `nil`, `.feature` controls are not checked.
    public var enabledFeatures: [String]?
    /// The implementation limits the validation runs under.
    public var limits: ValidationLimits

    /// Options with the given features and limits.
    public init(enabledFeatures: [String]? = nil, limits: ValidationLimits = ValidationLimits()) {
        self.enabledFeatures = enabledFeatures
        self.limits = limits
    }
}

// MARK: - Results

/// The verdict of validating one document against a schema.
public struct ValidationResult: Sendable, Hashable {
    /// Why the document was not validated as matching, in the order found;
    /// empty when it matches.
    public var issues: [ValidationIssue]

    /// Whether the document matches the schema.
    public var isValid: Bool {
        issues.isEmpty
    }

    /// A verdict with the given issues.
    public init(issues: [ValidationIssue]) {
        self.issues = issues
    }

    /// The verdict a failed CBOR validation stands for.
    public init(_ error: CBORValidationError) {
        switch error {
        case .validation(let found):
            issues = found.map { ValidationIssue(path: $0.cborLocation, reason: $0.reason, kind: .mismatch) }
        case .invalidSchema(let issue):
            issues = [ValidationIssue(path: issue.cborLocation, reason: issue.reason, kind: .invalidSchema)]
        case .cborDecoding:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .malformedDocument)]
        case .cddlParsing, .utf8Parsing:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .invalidSchema)]
        case .unsupported:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .unsupported)]
        }
    }

    /// The verdict a failed JSON validation stands for.
    public init(_ error: JSONValidationError) {
        switch error {
        case .validation(let found):
            issues = found.map { ValidationIssue(path: $0.jsonLocation, reason: $0.reason, kind: .mismatch) }
        case .invalidSchema(let issue):
            issues = [ValidationIssue(path: issue.jsonLocation, reason: issue.reason, kind: .invalidSchema)]
        case .jsonParsing:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .malformedDocument)]
        case .cddlParsing, .utf8Parsing:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .invalidSchema)]
        case .unsupported:
            issues = [ValidationIssue(path: "", reason: error.description, kind: .unsupported)]
        }
    }
}

/// One reason a document was not validated as matching a schema.
public struct ValidationIssue: Sendable, Hashable, CustomStringConvertible {
    /// What an issue is about.
    public enum Kind: Sendable, Hashable {
        /// The document does not match the schema.
        case mismatch
        /// The document is not one well-formed CBOR data item or JSON value.
        case malformedDocument
        /// The schema is at fault: a control operator whose operand denotes
        /// no value, for example.
        case invalidSchema
        /// The schema uses a feature this implementation does not provide:
        /// the `.abnf` and `.abnfb` control operators.
        case unsupported
    }

    /// Where the data item the issue is about is in the document: one
    /// `/`-prefixed segment per step from the root (an array index, or a map
    /// key written as a CDDL literal), and the empty string for the root.
    public var path: String
    /// Why the data item does not match.
    public var reason: String
    /// What the issue is about.
    public var kind: Kind

    /// An issue.
    public init(path: String, reason: String, kind: Kind = .mismatch) {
        self.path = path
        self.reason = reason
        self.kind = kind
    }

    public var description: String {
        path.isEmpty ? reason : "\(path): \(reason)"
    }
}

// MARK: - Parse errors

/// Why CDDL text does not parse.
public struct CDDLParseError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The 1-based line the error is at, or 0 when it is not tied to a
    /// position in the text.
    public var line: Int
    /// The 1-based column, in characters, the error is at, or 0 when it is
    /// not tied to a position in the text.
    public var column: Int
    /// What is wrong.
    public var message: String

    let underlying: ParserError

    init(_ error: ParserError) {
        underlying = error
        switch error {
        case .parser(let position, let msg):
            line = position.line
            column = position.column
            message = msg.short
        case .cddl(let text):
            line = 0
            column = 0
            message = text
        case .regex(let text):
            line = 0
            column = 0
            message = "regex parsing error: \(text)"
        }
    }

    public var description: String {
        line == 0 ? message : "\(line):\(column): \(message)"
    }

    /// The error as a diagnostic that quotes the line of `source` it is at
    /// and marks the offending text, for example:
    ///
    /// ```text
    /// error: parser errors
    ///   ┌─ input:1:21
    ///   │
    /// 1 │ reading = { sensor: tstr
    ///   │                     ^^^^ expected one of: ...
    /// ```
    ///
    /// - Parameter source: The text that was parsed.
    public func rendered(source: String) -> String {
        renderParserError(underlying, input: source)
    }
}
