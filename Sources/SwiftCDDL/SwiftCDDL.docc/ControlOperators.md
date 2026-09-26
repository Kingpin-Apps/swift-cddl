# Control Operators

The control operators a schema can use, and the two it cannot.

## Overview

A control operator constrains a type with a second one, as in
`tstr .size 3` or `bytes .cbor header`. SwiftCDDL implements the operators
of RFC 8610, RFC 9165 and RFC 9741, and `.pcre`, `.iregexp` and `.bitfield`.

## RFC 8610

| Operator | Meaning |
| --- | --- |
| `.size` | The byte length of a string, or the byte width of an unsigned integer. A range bounds it. |
| `.bits` | Only the listed bits may be set in a byte string or unsigned integer. |
| `.regexp` | A text string matches an XSD regular expression, anchored to the whole string. |
| `.cbor` | A byte string holds one CBOR data item matching the controller. |
| `.cborseq` | A byte string holds a CBOR sequence (RFC 8742) matching the controller, an array. |
| `.within`, `.and` | The value matches both types. |
| `.lt`, `.le`, `.gt`, `.ge`, `.eq`, `.ne` | Numeric comparisons, and `.eq` and `.ne` for any value. |
| `.default` | Documents a default value; the value matches the target. |

## RFC 9165

| Operator | Meaning |
| --- | --- |
| `.plus` | Numeric addition of two literals. |
| `.cat` | Concatenation of two strings. |
| `.det` | Concatenation after removing common leading whitespace from each line. |
| `.feature` | Marks a type as belonging to a feature. With ``ValidationOptions/enabledFeatures`` set, a type of a feature that is not enabled is reported. |

`.abnf` and `.abnfb`, which hold a string to an ABNF grammar, are **not
supported**. A schema can use them, but validating a value against one reports
a ``ValidationIssue/Kind/unsupported`` issue rather than a verdict.

## RFC 9741

The text conversion operators check that a text string encodes a byte string
matching the controller: `.b64u`, `.b64c`, `.b64u-sloppy`, `.b64c-sloppy`,
`.hex`, `.hexlc`, `.hexuc`, `.b32`, `.h32`, `.b45` and `.base10`. `.printf`
and `.join` build a text string from values, and `.json` checks that a text
string is JSON matching the controller.

## Regular expressions

`.regexp` patterns use XSD syntax (RFC 8610 Section 3.8.3), `.pcre` patterns
Perl-compatible syntax, and `.iregexp` patterns I-Regexp (RFC 9485).

`.pcre` and `.iregexp` hold the whole string to the pattern. A `.regexp`
pattern matches if it matches anywhere in the string, so anchor it with `^`
and `$` to hold the whole string to it, as XSD patterns are meant to be. In
every case:

- `$` outside multi-line mode matches at the very end of the text only, never
  before a newline that ends it, so `^[a-z]+$` refuses `"abc\n"`.
- `\n` is the only line terminator: `.` matches `\r`.

Lookaround is not part of XSD, so a `.regexp` pattern using it is refused as
malformed.
