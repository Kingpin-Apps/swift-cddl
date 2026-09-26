# Validating Cardano Transactions

Check ledger transactions against the CDDL schema of their era.

## Overview

The Cardano ledger publishes a CDDL schema for each era: Shelley, Allegra,
Mary, Alonzo, Babbage and Conway. Each one parses as a ``CDDLDocument``, and
real ledger transactions validate against the schema of their era.

## Pick the schema and the root rule

Use the schema of the era the transaction belongs to. The first rule of the
ledger schemas is `block`, so name the `transaction` rule explicitly:

```swift
let conway = try CDDLDocument(data: Data(contentsOf: conwaySchemaURL))

let transaction: Data = ...  // the CBOR of a signed transaction
let result = await conway.validate(cbor: transaction, rule: "transaction")
for issue in result.issues {
    print(issue.path, issue.reason)
}
```

Parse the schema once and keep the document: it is `Sendable`, and every
validation reuses its index of the rules.

Paths follow the structure of the transaction. A transaction is an array of
its body, its witness set, a validity flag and its auxiliary data, and the
body is a map keyed by integers, so `/0/2` is the fee and `/0/13` the
collateral inputs.

A typical Conway transaction validates in well under 50 milliseconds in a
release build.

## Byte strings longer than 64 bytes

The ledger schemas define

```cddl
bounded_bytes = bytes .size (0..64)
```

and say in a comment that the ledger's real rule is looser: a byte string
with a definite length is limited to 64 bytes, but one with an indefinite
length may be of any length as long as each of its chunks is at most 64
bytes. CDDL has no way to say that, and `.size` measures the whole string.

So a transaction whose Plutus data carries a byte string longer than 64
bytes, encoded in chunks of up to 64 bytes as the ledger allows, is reported
with an issue such as

```text
expected byte string length to be in the range 0 <= value <= 64, got 128
```

even though the ledger accepts it. Where such data is expected, validate
against a copy of the schema that defines `bounded_bytes = bytes`, and check
the chunk sizes separately if that matters.

## Sets

The Conway schema writes sets as `#6.258([* a])` alongside the plain array
form, and ledger transactions use both, with definite and indefinite
lengths. They validate as written; the schema, not this package, decides
which forms are accepted.
