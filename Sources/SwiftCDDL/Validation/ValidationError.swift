// The errors CBOR validation reports.

/// One way a CBOR document fails to match a CDDL schema.
///
/// An error carries the location of the data item it is about, not of the
/// schema construct the item was tried against: the walk resolves rule
/// references, generic arguments and choice alternatives on the way to an item,
/// so the construct is a path through the schema rather than one span of its
/// text.
public struct CBORValidationIssue: Sendable, Hashable, CustomStringConvertible {
    /// Why the data item does not match.
    public var reason: String
    /// Where the data item is in the document: one `/`-prefixed segment per
    /// step from the root (an array index, or a map key written as a CDDL
    /// literal), and the empty string for the root itself.
    public var cborLocation: String
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
        cborLocation: String,
        isMultiTypeChoice: Bool = false,
        isMultiGroupChoice: Bool = false,
        isGroupToChoiceEnum: Bool = false,
        typeGroupNameEntry: String? = nil
    ) {
        self.reason = reason
        self.cborLocation = cborLocation
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
        return "\(prefix) at cbor location \(cborLocation): \(reason)"
    }
}

/// Why a CBOR document was not validated as matching a CDDL schema.
public enum CBORValidationError: Error, Sendable, CustomStringConvertible {
    /// The document does not match the schema, for these reasons.
    case validation([CBORValidationIssue])
    /// The document is not one well-formed CBOR data item.
    ///
    /// The fault is in the document alone: nothing follows from it about the
    /// schema.
    case cborDecoding(CBORDecodingError)
    /// The schema did not parse.
    case cddlParsing(String)
    /// A text value that has to be UTF-8 is not.
    case utf8Parsing(String)
    /// A fault in the schema found while validating, rather than a mismatch
    /// between the document and the schema: a control operator whose operand
    /// denotes no value, for example. Validation stops where the fault was
    /// found, since reporting a mismatch instead would let the first
    /// alternative of a choice that matches discard it.
    case invalidSchema(CBORValidationIssue)
    /// The schema uses a feature this implementation does not provide: the
    /// `.abnf` and `.abnfb` control operators (RFC 9165 Section 3).
    case unsupported(String)

    /// The errors of a document that does not match, or `nil` for any other
    /// failure.
    public var issues: [CBORValidationIssue]? {
        if case .validation(let issues) = self {
            return issues
        }
        return nil
    }

    public var description: String {
        switch self {
        case .validation(let issues):
            return issues.map { "\($0)\n" }.joined()
        case .cborDecoding(let error):
            return "error decoding CBOR document: \(error)"
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
