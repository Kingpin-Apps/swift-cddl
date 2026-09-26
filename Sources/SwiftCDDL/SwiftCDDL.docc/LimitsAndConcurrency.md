# Limits and Concurrency

How validation bounds its work, and how to call it from any context.

## Implementation limits

A document can nest arbitrarily deeply, and a schema of choices can make the
work of a validation grow quickly with the size of the document. Validation
therefore runs under ``ValidationLimits``, which bound:

- how deeply the data nests (``ValidationLimits/maxNestingDepth``, 16,384 by
  default),
- how many rule references are resolved against one data item
  (``ValidationLimits/maxRuleNesting``),
- the memory the descent to one data item holds
  (``ValidationLimits/maxDescentCost``),
- the elementary steps one run takes
  (``ValidationLimits/maxValidationWork``, 4,000,000 by default),
- how many payloads decoded out of the document, by `.cbor`, `.cborseq` and
  the text conversion controls, are open at once
  (``ValidationLimits/maxEmbeddedDepth``), and
- the size of the report (``ValidationLimits/maxReportBytes``).

None of these comes from RFC 8610. Reaching one is reported as an issue that
names the limit, never as a statement about the document. Pass tighter
limits for untrusted input:

```swift
var options = ValidationOptions()
options.limits.maxNestingDepth = 128
options.limits.maxValidationWork = 100_000
let result = await schema.validate(cbor: untrusted, options: options)
```

## Stack use

Validation keeps its state on the heap, so a document nested as deeply as the
limits admit is validated on any thread, including a task of Swift
concurrency, whose stack is small.

Parsing and formatting recurse, and run on a thread of their own with a large
stack. A deeply nested syntax tree is released on such a thread too, when the
last copy of its ``CDDLDocument`` or ``CDDL`` goes away. A rule or type copied
out of the tree and kept after the document is gone is released where its last
copy goes away; for a deeply nested schema, keep the document instead.

## Concurrency

``CDDLDocument`` is immutable and `Sendable`. Share one document between any
number of tasks and validate concurrently.

The `validate` methods are `async`. The `validateSynchronously` methods block
the calling thread until the verdict is in, and are safe to call from any
context: a plain thread, the main thread, or a task of the shared concurrency
pool, even when every thread of the pool is blocked in one. The calling thread
runs the validation itself, so it never waits for a thread of the pool.

``CBORValidator`` and ``JSONValidator`` hold the state of one run and are not
`Sendable`: create one for each document, in the task that validates it.
