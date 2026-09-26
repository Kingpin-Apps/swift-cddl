# SwiftCDDL

A pure-Swift [CDDL](https://www.rfc-editor.org/rfc/rfc8610) (Concise Data
Definition Language) parser, formatter and validator. Describe the shape of
CBOR or JSON data in CDDL, then check whether a document matches it and see
where and why it does not.

- Full RFC 8610 grammar, with the RFC 9682 updates: empty documents,
  `\u{...}` escapes and non-literal tag numbers.
- Comment-preserving formatter: every comment is written back, and
  formatting the output again changes nothing.
- CBOR validation (RFC 8949) that keeps what a generic decoder drops:
  duplicate map keys, float widths, indefinite-length items and bignums.
- JSON validation (RFC 8259) that keeps key order, integer-versus-float
  spelling and big integers.
- Control operators of RFC 8610, RFC 9165 and RFC 9741: `.size`, `.bits`,
  `.regexp`, `.pcre`, `.iregexp`, `.cbor`, `.cborseq`, the comparisons,
  `.cat`, `.det`, `.plus`, `.feature`, the text conversions and more. `.abnf`
  and `.abnfb` are not supported.
- Every Cardano ledger era schema, Shelley to Conway, parses, and real
  ledger transactions validate against the schema of their era.
- Issues report a path into the document (`/0/"fee"`) and a reason.
- Bounded by default: nesting, work and report-size limits protect against
  hostile input, and validation keeps its state on the heap, so deep
  documents never overflow a task's stack.
- `Sendable` schemas, `async` validation, and blocking variants that are safe
  to call from any context.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Kingpin-Apps/swift-cddl.git",
             .upToNextMinor(from: "0.1.0")),
]
```

then list `SwiftCDDL` as a target dependency:

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "SwiftCDDL", package: "swift-cddl"),
]),
```

## Quick start

```swift
import SwiftCDDL

let schema = try CDDLDocument("""
    ; A reading from a sensor.
    reading = {
        sensor: tstr,
        value: float / int,
        ? unit: "C" / "F",
    }
    readings = [* reading]
    """)

// JSON
let result = await schema.validate(
    json: #"[{"sensor": "t1", "value": 21.5, "unit": "K"}]"#,
    rule: "readings"
)
if !result.isValid {
    for issue in result.issues {
        print("\(issue.path): \(issue.reason)")
        // /0/unit: expected value "C" got "K"
        // /0/unit: expected value "F" got "K"
    }
}

// CBOR
let bytes: Data = ...
let verdict = await schema.validate(cbor: bytes, rule: "readings")

// Without await, from any context
let same = schema.validateSynchronously(cbor: bytes, rule: "readings")
```

With no `rule:`, a document is matched against the first type rule of the
schema, as RFC 8610 Section 3.1 says.

## Parse errors

A schema that does not parse throws `CDDLParseError`, with the line, the
column and a message, and a rendered diagnostic that quotes the line:

```swift
let source = "reading = { sensor: tstr\n"
do {
    _ = try CDDLDocument(source)
} catch {
    print(error.line, error.column)   // 1 21
    print(error.rendered(source: source))
}
```

```text
error: parser errors
  ┌─ input:1:21
  │
1 │ reading = { sensor: tstr
  │                     ^^^^ expected one of: ...
```

## Formatting

```swift
print(schema.formatted())
```

```cddl
; A reading from a sensor.
reading = { sensor: tstr, value: float / int, ? unit: "C" / "F", }

readings = [ * reading ]
```

## Cardano transactions

Use the ledger schema of the transaction's era and name the `transaction`
rule, since the first rule of the ledger schemas is `block`:

```swift
let conway = try CDDLDocument(data: Data(contentsOf: conwaySchemaURL))
let result = await conway.validate(cbor: transactionBytes, rule: "transaction")
```

The ledger schemas limit `bounded_bytes` to 64 bytes with `.size (0..64)`,
while the ledger itself also accepts longer byte strings encoded in chunks of
at most 64 bytes. CDDL cannot say that, so such byte strings are reported.
The documentation covers this and other details.

## Options and limits

```swift
var options = ValidationOptions(enabledFeatures: ["v2"])
options.limits.maxNestingDepth = 128
options.limits.maxValidationWork = 100_000
let result = await schema.validate(cbor: untrusted, options: options)
```

## Lower-level API

`CBORValidator` and `JSONValidator` validate one document and throw the full
error, with the flags that say which choice an issue arose in. The parsed
syntax tree is available as `CDDLDocument.ast`, and CBOR data as `CBORNode`,
which decodes with `CBORNode(decoding:)`.

## Supported specifications

| RFC | Title |
| --- | --- |
| [RFC 8610](https://www.rfc-editor.org/rfc/rfc8610) | Concise Data Definition Language (CDDL) |
| [RFC 9165](https://www.rfc-editor.org/rfc/rfc9165) | Additional Control Operators for CDDL |
| [RFC 8742](https://www.rfc-editor.org/rfc/rfc8742) | Concise Binary Object Representation (CBOR) Sequences |
| [RFC 9682](https://www.rfc-editor.org/rfc/rfc9682) | Updates to the CDDL Grammar of RFC 8610 |

The text conversion control operators follow
[RFC 9741](https://www.rfc-editor.org/rfc/rfc9741), and `.iregexp` follows
[RFC 9485](https://www.rfc-editor.org/rfc/rfc9485).

## Documentation

The DocC catalog covers getting started, validating Cardano transactions,
the control operators, and limits and concurrency.

## Requirements

- Swift 6.0+
- iOS 18+, macOS 15+, watchOS 11+, tvOS 18+, visionOS 2+, macCatalyst 18+
- Linux (any Swift 6.0+ toolchain)

## License

MIT. See [LICENSE](LICENSE).
