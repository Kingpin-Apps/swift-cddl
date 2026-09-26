# Getting Started

Parse a schema, format it, and validate CBOR and JSON documents against it.

## Parse a schema

Create a ``CDDLDocument`` from CDDL text. Parsing checks the syntax and that
every name the schema uses is defined.

```swift
import SwiftCDDL

let source = """
    ; A reading from a sensor.
    reading = {
        sensor: tstr,
        value: float / int,
        ? unit: "C" / "F",
    }
    readings = [* reading]
    """

let schema = try CDDLDocument(source)
print(schema.rules.count)                          // 2
print(schema.rule(named: "readings") != nil)       // true
```

`CDDLDocument(data:)` reads UTF-8 encoded text, such as a file's contents.

A schema that does not parse throws ``CDDLParseError``. It carries the line,
the column and a message, and ``CDDLParseError/rendered(source:)`` turns it
into a diagnostic that quotes the offending line:

```swift
do {
    _ = try CDDLDocument("reading = { sensor: tstr\n")
} catch {
    print(error.line, error.column, error.message)
    print(error.rendered(source: "reading = { sensor: tstr\n"))
}
```

## Format a schema

``CDDLDocument/formatted()`` writes the schema back as CDDL text in a
consistent layout. Every comment is kept, and formatting the output again
changes nothing.

```swift
print(schema.formatted())
```

## Validate CBOR

Pass the encoded bytes. By default a document is matched against the first
type rule of the schema (RFC 8610 Section 3.1); name another with `rule:`.

```swift
let bytes: Data = ...  // [{"sensor": "t1", "value": 21.5}]
let result = await schema.validate(cbor: bytes, rule: "readings")
if result.isValid {
    print("valid")
} else {
    for issue in result.issues {
        print("\(issue.path): \(issue.reason)")
    }
}
```

Each ``ValidationIssue`` has a ``ValidationIssue/path`` to the data item it
is about, one `/`-prefixed segment per step from the root (an array index, or
a map key written as a CDDL literal, such as `/0/"value"`), and a
``ValidationIssue/reason``. Its ``ValidationIssue/kind`` tells a mismatch
apart from a document that does not decode, a fault in the schema, and a
feature this package does not support.

Already decoded data can be validated as a ``CBORNode``:

```swift
let node = try CBORNode(decoding: bytes)
let result = await schema.validate(cbor: node, rule: "readings")
```

## Validate JSON

JSON is validated the same way, from a `String`, UTF-8 `Data` or a parsed
``JSONNode``:

```swift
let result = await schema.validate(
    json: #"[{"sensor": "t1", "value": 21.5, "unit": "K"}]"#,
    rule: "readings"
)
print(result.issues.map(\.path))  // ["/0/unit", "/0/unit"]
```

A value that matches none of the alternatives of a choice is reported once
for each alternative it was tried against: here `"K"` is neither `"C"` nor
`"F"`.

## Validate without `await`

Every `validate` method has a `validateSynchronously` counterpart that blocks
the calling thread until the verdict is in. It is safe to call from any
context; see <doc:LimitsAndConcurrency>.

```swift
let result = schema.validateSynchronously(json: text)
```

## Choose options

``ValidationOptions`` names the features the `.feature` control operator
treats as enabled (RFC 9165 Section 4) and the ``ValidationLimits`` a run is
held to:

```swift
var options = ValidationOptions(enabledFeatures: ["v2"])
options.limits.maxNestingDepth = 256
let result = await schema.validate(json: text, options: options)
```
