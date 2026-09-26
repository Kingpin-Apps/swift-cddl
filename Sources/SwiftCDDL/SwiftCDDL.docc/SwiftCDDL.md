# ``SwiftCDDL``

Parse CDDL schemas and validate CBOR and JSON documents against them.

## Overview

The Concise Data Definition Language (CDDL, RFC 8610) describes the shape of
CBOR and JSON data. SwiftCDDL parses a CDDL schema, writes it back out with
its comments kept, and checks whether a document matches it, reporting where
and why it does not.

```swift
import SwiftCDDL

let schema = try CDDLDocument("""
    person = {
        name: tstr,
        ? age: uint,
    }
    """)

let result = await schema.validate(json: #"{"name": "Ada", "age": "old"}"#)
for issue in result.issues {
    print(issue.path, issue.reason)  // /age expected type uint, ...
}
```

The package covers:

- The CDDL grammar of RFC 8610, with the updates of RFC 9682 (empty
  documents, `\u{...}` escapes, and non-literal tag numbers).
- The control operators of RFC 8610, RFC 9165 and RFC 9741, except `.abnf`
  and `.abnfb`; see <doc:ControlOperators>.
- Validation of CBOR (RFC 8949) and CBOR sequences (RFC 8742) inside
  `.cborseq`, and of JSON (RFC 8259).
- The Cardano ledger schemas of every era, from Shelley to Conway; see
  <doc:ValidatingCardanoTransactions>.

## Topics

### Essentials

- <doc:GettingStarted>
- ``CDDLDocument``
- ``ValidationResult``
- ``ValidationIssue``
- ``CDDLParseError``

### Guides

- <doc:ValidatingCardanoTransactions>
- <doc:ControlOperators>
- <doc:LimitsAndConcurrency>

### Options and limits

- ``ValidationOptions``
- ``ValidationLimits``

### Documents

- ``CBORNode``
- ``CBORDecodingError``
- ``JSONNode``
- ``JSONParsingError``

### Lower-level validators

- ``CBORValidator``
- ``CBORValidationError``
- ``CBORValidationIssue``
- ``JSONValidator``
- ``JSONValidationError``
- ``JSONValidationIssue``

### Syntax tree

- ``CDDL``
- ``Rule``
- ``TypeRule``
- ``GroupRule``
- ``Type``
- ``TypeChoice``
- ``Type1``
- ``Type2``
- ``Group``
- ``GroupChoice``
- ``GroupEntry``
- ``MemberKey``
- ``Identifier``
- ``ControlOperator``
- ``Value``
