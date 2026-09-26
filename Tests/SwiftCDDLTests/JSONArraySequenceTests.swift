import Testing

@testable import SwiftCDDL

// The array sequence vectors of CBORArraySequenceTests held against JSON
// documents: the same vector set, minus the shapes JSON has no values of
// (tags, byte strings, `.cbor`). The normative basis -- RFC 8610 Appendix A
// PEG semantics and the Appendix C matching rules, and the tension between
// them -- is set out in the header of CBORArraySequenceTests.
//
// A vector's placement under `Regression` or `PostFix` follows the JSON
// validator's own behaviour before the sequence matcher, which differed from
// the CBOR validator's on a few vectors (`choiceFromGroup`'s `[1, 2, 1]`,
// `nestedArray`'s `[1]`), so the two files place those differently.

/// Array group and occurrence sequence matching (RFC 8610 Section 3.4 and
/// Appendices A and C) against JSON documents.
@Suite struct JSONArraySequenceTests {
    /// Behaviour that was already correct before the sequence matcher and must
    /// not change.
    @Suite struct Regression {
        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4, 3.11.
        @Test func choiceDiffLengths() async {
            await expectJSONValid("a = [(bool // int, tstr)]", #"[true]"#)
            await expectJSONValid("a = [(bool // int, tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [(bool // int, tstr)]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& group choice).
        @Test func choiceFromGroup() async {
            await expectJSONValid("a = [* &(1, 2)]", #"[]"#)
            await expectJSONInvalid("a = [* &(1, 2)]", #"[3]"#)
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& groupname).
        @Test func choiceFromNamedGroup() async {
            await expectJSONInvalid("a = [* e]\ne = &g\ng = (1, 2)", #"[3]"#)
        }

        /// RFC 8610: Sections 2.1, 3.4.
        @Test func emptyArray() async {
            await expectJSONValid("a = []", #"[]"#)
            await expectJSONInvalid("a = []", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence must terminate
        /// on zero-width repetitions); Appendix B (parenthesized group).
        @Test func emptyGroupStar() async {
            // NOTE: a second implementation loops forever on zero-width group repetition; expected per RFC: () matches trivially, then int matches. Matcher must terminate.
            await expectJSONValid("a = [* (), int]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact11() async {
            await expectJSONInvalid("a = [1*1 (int, tstr)]", #"[]"#)
            await expectJSONInvalid("a = [1*1 (int, tstr)]", #"[1]"#)
            await expectJSONInvalid("a = [1*1 (int, tstr)]", #"[1, "x", 2, "y"]"#)
            await expectJSONInvalid("a = [1*1 (int, tstr)]", #"["x", 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact22() async {
            await expectJSONInvalid("a = [2*2 (int, tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [2*2 (int, tstr)]", #"[1, "x", 2, "y", 3, "z"]"#)
            await expectJSONInvalid("a = [2*2 (int, tstr)]", #"[1, "x", 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10.
        @Test func genericElem() async {
            await expectJSONInvalid("a = [* box<int>]\nbox<T> = [T]", #"[["x"]]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10; Appendix B (groupname entry).
        @Test func genericGroupElem() async {
            // REJECT [1] (cross-checked against a second implementation)
            await expectJSONInvalid("a = [* g<int>]\ng<T> = (T, T)", #"[1]"#)
            // REJECT [1, "x"] (cross-checked against a second implementation)
            await expectJSONInvalid("a = [* g<int>]\ng<T> = (T, T)", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func groupBetweenSiblings() async {
            await expectJSONInvalid("a = [bool, * (int, tstr), bool]", #"[true, 1, false]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4.
        @Test func groupChoiceInside() async {
            await expectJSONInvalid("a = [1*1 (int, tstr // tstr, int)]", #"[1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefAfterSibling() async {
            await expectJSONInvalid("a = [tstr, * pair]\npair = (int, tstr)", #"["h", 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefExact() async {
            await expectJSONInvalid("a = [1*1 b]\nb = (int, tstr)", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefStar() async {
            await expectJSONValid("a = [* pair]\npair = (int, tstr)", #"[]"#)
            await expectJSONInvalid("a = [* pair]\npair = (int, tstr)", #"[1, "x", 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousAlias() async {
            await expectJSONValid("a = [* zip]\nzip = int", #"[]"#)
            await expectJSONValid("a = [* zip]\nzip = int", #"[1, 2]"#)
            await expectJSONInvalid("a = [* zip]\nzip = int", #"["x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousExact() async {
            await expectJSONValid("a = [3*3 int]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [3*3 int]", #"[1, 2]"#)
            await expectJSONInvalid("a = [3*3 int]", #"[1, 2, 3, 4]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousLower() async {
            await expectJSONValid("a = [3* int]", #"[1, 2, 3]"#)
            await expectJSONValid("a = [3* int]", #"[1, 2, 3, 4]"#)
            await expectJSONInvalid("a = [3* int]", #"[1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousOpt() async {
            await expectJSONValid("a = [? int]", #"[]"#)
            await expectJSONValid("a = [? int]", #"[1]"#)
            await expectJSONInvalid("a = [? int]", #"[1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousPlus() async {
            await expectJSONValid("a = [+ int]", #"[1]"#)
            await expectJSONValid("a = [+ int]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [+ int]", #"[]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousRange() async {
            await expectJSONValid("a = [1*3 int]", #"[1]"#)
            await expectJSONValid("a = [1*3 int]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [1*3 int]", #"[]"#)
            await expectJSONInvalid("a = [1*3 int]", #"[1, 2, 3, 4]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousStar() async {
            await expectJSONValid("a = [* int]", #"[]"#)
            await expectJSONValid("a = [* int]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [* int]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.4.
        @Test func literalElements() async {
            await expectJSONValid("a = [1, 2, 3]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [1, 2, 3]", #"[1, 2]"#)
            await expectJSONInvalid("a = [1, 2, 3]", #"[1, 2, 4]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func lowerBoundOnly() async {
            await expectJSONInvalid("a = [2* (int, tstr)]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.5, 3.5.1; Appendix B (groupname entry).
        @Test func mapGroupRef() async {
            await expectJSONValid("a = {g}\ng = (x: int, y: tstr)", #"{"x": 1, "y": "h"}"#)
            await expectJSONInvalid("a = {g}\ng = (x: int, y: tstr)", #"{"x": 1}"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.5.1.
        @Test func mapInArray() async {
            await expectJSONValid("a = [* {k: int}]", #"[]"#)
            await expectJSONValid("a = [* {k: int}]", #"[{"k": 1}]"#)
            await expectJSONInvalid("a = [* {k: int}]", #"[{"k": "x"}]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.5.1; Appendix B (groupname entry).
        @Test func mapInArrayWithGroup() async {
            await expectJSONValid("a = [* {g}]\ng = (x: int)", #"[]"#)
            await expectJSONValid("a = [* {g}]\ng = (x: int)", #"[{"x": 1}]"#)
            await expectJSONInvalid("a = [* {g}]\ng = (x: int)", #"[{"x": "h"}]"#)
        }

        /// RFC 8610: Sections 2.1, 3.5.1; Appendix B (parenthesized group).
        @Test func mapInlineGroup() async {
            await expectJSONValid("a = {(x: int, y: tstr)}", #"{"x": 1, "y": "h"}"#)
            await expectJSONInvalid("a = {(x: int, y: tstr)}", #"{"x": 1}"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.5.1.
        @Test func mapOptionalMember() async {
            await expectJSONValid("a = {x: int, ? y: tstr}", #"{"x": 1}"#)
            await expectJSONValid("a = {x: int, ? y: tstr}", #"{"x": 1, "y": "h"}"#)
            await expectJSONInvalid("a = {x: int, ? y: tstr}", #"{}"#)
        }

        /// RFC 8610: Sections 2.1, 3.5.1.
        @Test func mapRecord() async {
            await expectJSONValid("a = {x: int, y: tstr}", #"{"x": 1, "y": "h"}"#)
            await expectJSONInvalid("a = {x: int, y: tstr}", #"{"x": 1}"#)
            await expectJSONInvalid("a = {x: int, y: tstr}", #"{"x": "h", "y": "h"}"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.5.2.
        @Test func mapStarMembers() async {
            await expectJSONValid("a = {* tstr => int}", #"{}"#)
            await expectJSONValid("a = {* tstr => int}", #"{"a": 1, "b": 2}"#)
            await expectJSONInvalid("a = {* tstr => int}", #"{"a": "x"}"#)
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4; Appendix B (choice extension).
        @Test func namedTypeChoiceElem() async {
            await expectJSONInvalid("a = [* elem]\nelem = int\nelem /= tstr", #"[true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedArray() async {
            await expectJSONValid("a = [* [int]]", #"[]"#)
            await expectJSONValid("a = [* [int]]", #"[[1], [2]]"#)
        }

        /// RFC 8610: Sections 2.1, 3.4.
        @Test func nestedArrayLiteral() async {
            await expectJSONValid("a = [int, [int, int], [int, int]]", #"[1, [2, 3], [4, 5]]"#)
            await expectJSONInvalid("a = [int, [int, int], [int, int]]", #"[1, [2, 3]]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func nestedParens() async {
            await expectJSONInvalid("a = [1*1 (int, (tstr))]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedStarOfStar() async {
            await expectJSONValid("a = [* [* (int, tstr)]]", #"[]"#)
            await expectJSONValid("a = [* [* (int, tstr)]]", #"[[]]"#)
            await expectJSONInvalid("a = [* [* (int, tstr)]]", #"[[1]]"#)
            await expectJSONInvalid("a = [* [* (int, tstr)]]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurInsideOccur() async {
            await expectJSONInvalid("a = [* (int, 2*2 tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [* (int, 2*2 tstr)]", #"[1, "x", "y", "z"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurOnSingleEntryGroup() async {
            await expectJSONInvalid("a = [2*2 (int, 1*1 (tstr))]", #"[1, "x", 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func oneOrMore() async {
            await expectJSONInvalid("a = [+ (int, tstr)]", #"[]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optional() async {
            await expectJSONValid("a = [? (int, tstr)]", #"[]"#)
            await expectJSONInvalid("a = [? (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optionalMiddle() async {
            await expectJSONInvalid("a = [int, ? tstr, bool]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [int, ? tstr, bool]", #"[1, "x", true, true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func prefixThenStar() async {
            await expectJSONInvalid("a = [tstr, * int]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4; Appendix A (prioritized choice).
        @Test func prioritizedChoiceLocks() async {
            await expectJSONValid("a = [(int // int, tstr)]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func range12() async {
            await expectJSONInvalid("a = [1*2 (int, tstr)]", #"[]"#)
            await expectJSONInvalid("a = [1*2 (int, tstr)]", #"[1, "x", 2, "y", 3, "z"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.4, 3.5.1.
        @Test func record() async {
            await expectJSONValid("a = [x: int, y: int, z: int]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [x: int, y: int, z: int]", #"[1, 2]"#)
            await expectJSONInvalid("a = [x: int, y: int, z: int]", #"[1, 2, 3, 4]"#)
        }

        /// RFC 8610: Sections 2.1, 3.4, 3.5.1.
        @Test func recordMixed() async {
            await expectJSONValid("a = [x: tstr, y: int]", #"["h", 1]"#)
            await expectJSONInvalid("a = [x: tstr, y: int]", #"[1, "h"]"#)
            await expectJSONInvalid("a = [x: tstr, y: int]", #"["h"]"#)
            await expectJSONInvalid("a = [x: tstr, y: int]", #"["h", 1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingAfter() async {
            await expectJSONInvalid("a = [(int, tstr), bool]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [(int, tstr), bool]", #"[1, true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeNoOccur() async {
            await expectJSONInvalid("a = [bool, (int, tstr)]", #"[true, 1]"#)
            await expectJSONInvalid("a = [bool, (int, tstr)]", #"[true, "x", 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeOccur() async {
            await expectJSONInvalid("a = [bool, 1*1 (int, tstr)]", #"[true]"#)
            await expectJSONInvalid("a = [bool, 1*1 (int, tstr)]", #"[true, 1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.8, 3.8.1.
        @Test func sizeControlElem() async {
            await expectJSONValid("a = [* tstr .size 2]", #"[]"#)
            await expectJSONValid("a = [* tstr .size 2]", #"["ok"]"#)
            await expectJSONInvalid("a = [* tstr .size 2]", #"["x"]"#)
            await expectJSONInvalid("a = [* tstr .size 2]", #"["abc"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func soleGroupNoOccurInline() async {
            await expectJSONValid("a = [(int, tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [(int, tstr)]", #"[1]"#)
            await expectJSONInvalid("a = [(int, tstr)]", #"[1, "x", 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func soleGroupNoOccurRef() async {
            await expectJSONValid("a = [b]\nb = (int, tstr)", #"[1, "x"]"#)
            await expectJSONInvalid("a = [b]\nb = (int, tstr)", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starGroupThenInt() async {
            await expectJSONInvalid("a = [* (int, tstr), int]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starOfVarArity() async {
            await expectJSONValid("a = [* (int, * tstr)]", #"[]"#)
            await expectJSONInvalid("a = [* (int, * tstr)]", #"["x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starThenTstr() async {
            await expectJSONInvalid("a = [* int, tstr]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func threeLevelNesting() async {
            await expectJSONInvalid("a = [1*1 (int, (tstr, (bool)))]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func tupleElements() async {
            await expectJSONValid("a = [* [int, tstr]]", #"[]"#)
            await expectJSONValid("a = [* [int, tstr]]", #"[[1, "x"]]"#)
            await expectJSONValid("a = [* [int, tstr]]", #"[[1, "x"], [2, "y"]]"#)
            await expectJSONInvalid("a = [* [int, tstr]]", #"[[1]]"#)
            await expectJSONInvalid("a = [* [int, tstr]]", #"[[1, "x", 2]]"#)
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4, 3.11.
        @Test func typeChoiceElement() async {
            await expectJSONValid("a = [* (int / tstr)]", #"[]"#)
            await expectJSONValid("a = [* (int / tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [* (int / tstr)]", #"[true]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.2, 3.4.
        @Test func typeChoiceOfArraysElem() async {
            await expectJSONValid("a = [* ([int] / [tstr])]", #"[[1]]"#)
            await expectJSONInvalid("a = [* ([int] / [tstr])]", #"[[true]]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapAfterSibling() async {
            await expectJSONInvalid("a = [bool, ~b]\nb = [int, tstr]", #"[true, 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4 (member keys are annotation-only in an
        /// array context), 3.7.
        @Test func unwrapLabeled() async {
            await expectJSONValid("a = [x: ~b]\nb = [int, tstr]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [x: ~b]\nb = [int, tstr]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapSole() async {
            await expectJSONInvalid("a = [~b]\nb = [int, tstr]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapWithOccur() async {
            await expectJSONValid("a = [* ~b]\nb = [int, tstr]", #"[]"#)
            await expectJSONInvalid("a = [* ~b]\nb = [int, tstr]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyGroup() async {
            await expectJSONValid("a = [*2 (int, tstr)]", #"[]"#)
            await expectJSONInvalid("a = [*2 (int, tstr)]", #"[1, "x", 2, "y", 3, "z"]"#)
            await expectJSONInvalid("a = [*2 (int, tstr)]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyHomogeneous() async {
            await expectJSONValid("a = [*2 int]", #"[]"#)
            await expectJSONValid("a = [*2 int]", #"[1, 2]"#)
            await expectJSONInvalid("a = [*2 int]", #"[1, 2, 3]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func upstreamIgnoredCase() async {
            await expectJSONValid("a = [int, (int, int)]", #"[1, 2, 3]"#)
            await expectJSONInvalid("a = [int, (int, int)]", #"[1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func varArityInside() async {
            await expectJSONInvalid("a = [1*1 (int, * tstr)]", #"[]"#)
            await expectJSONInvalid("a = [1*1 (int, * tstr)]", #"["x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func zeroOrMore() async {
            await expectJSONValid("a = [* (int, tstr)]", #"[]"#)
            await expectJSONInvalid("a = [* (int, tstr)]", #"[1]"#)
            await expectJSONInvalid("a = [* (int, tstr)]", #"[1, "x", 2]"#)
            await expectJSONInvalid("a = [* (int, tstr)]", #"["x", 1]"#)
        }
    }

    /// Behaviour the positional array walk got wrong and the sequence matcher
    /// gets right.
    @Suite struct PostFix {
        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7, 3.10.
        @Test func genericGroupChoiceNoArgLeak() async {
            // Generic args registered while a failing choice alternative was tried
            // speculatively must not leak into the next alternative.
            // ACCEPT ["x", "x"] (cross-checked against a second implementation)
            await expectJSONValid("a = [(g<int> // g<tstr>)]\ng<T> = (T, T)", #"["x", "x"]"#)
            // ACCEPT [1, 1] (cross-checked against a second implementation)
            await expectJSONValid("a = [(g<int> // g<tstr>)]\ng<T> = (T, T)", #"[1, 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7, 3.10.
        @Test func unwrapGenericChoiceNoArgLeak() async {
            // ACCEPT ["x"] (cross-checked against a second implementation)
            await expectJSONValid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", #"["x"]"#)
            // ACCEPT [1] (cross-checked against a second implementation)
            await expectJSONValid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", #"[1]"#)
            // REJECT [true] (cross-checked against a second implementation)
            await expectJSONInvalid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", #"[true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapRecursive() async {
            // Recursive unwrap references must terminate instead of overflowing the
            // stack; the rule is unsatisfiable.
            // REJECT [] (cross-checked against a second implementation)
            await expectJSONInvalid("a = [~b]\nb = [~b]", #"[]"#)
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& group choice).
        @Test func choiceFromGroup() async {
            // ACCEPT [1, 2, 1] (cross-checked against a second implementation)
            await expectJSONValid("a = [* &(1, 2)]", #"[1, 2, 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedArray() async {
            // REJECT [1] (cross-checked against a second implementation)
            await expectJSONInvalid("a = [* [int]]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& groupname).
        @Test func choiceFromNamedGroup() async {
            await expectJSONValid("a = [* e]\ne = &g\ng = (1, 2)", #"[1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence must terminate
        /// on zero-width repetitions); Appendix B (parenthesized group).
        @Test func emptyGroupStar() async {
            // NOTE: a second implementation loops forever on zero-width group repetition; expected per RFC: trailing int unmatched in []. Matcher must terminate.
            await expectJSONInvalid("a = [* (), int]", #"[]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact11() async {
            await expectJSONValid("a = [1*1 (int, tstr)]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact22() async {
            await expectJSONValid("a = [2*2 (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10.
        @Test func genericElem() async {
            await expectJSONValid("a = [* box<int>]\nbox<T> = [T]", #"[]"#)
            await expectJSONValid("a = [* box<int>]\nbox<T> = [T]", #"[[1]]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10; Appendix B (groupname entry).
        @Test func genericGroupElem() async {
            // ACCEPT [] (cross-checked against a second implementation)
            await expectJSONValid("a = [* g<int>]\ng<T> = (T, T)", #"[]"#)
            // ACCEPT [1, 2] (cross-checked against a second implementation)
            await expectJSONValid("a = [* g<int>]\ng<T> = (T, T)", #"[1, 2]"#)
            // ACCEPT [1, 2, 3, 4] (cross-checked against a second implementation)
            await expectJSONValid("a = [* g<int>]\ng<T> = (T, T)", #"[1, 2, 3, 4]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence behavior).
        @Test func greedyStarThenInt() async {
            await expectJSONInvalid("a = [* int, int]", #"[1]"#)
            await expectJSONInvalid("a = [* int, int]", #"[1, 2]"#)
            await expectJSONInvalid("a = [* int, int]", #"[]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func groupBetweenSiblings() async {
            await expectJSONValid("a = [bool, * (int, tstr), bool]", #"[true, false]"#)
            await expectJSONValid("a = [bool, * (int, tstr), bool]", #"[true, 1, "x", false]"#)
            await expectJSONValid("a = [bool, * (int, tstr), bool]", #"[true, 1, "x", 2, "y", false]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4.
        @Test func groupChoiceInside() async {
            await expectJSONValid("a = [1*1 (int, tstr // tstr, int)]", #"[1, "x"]"#)
            await expectJSONValid("a = [1*1 (int, tstr // tstr, int)]", #"["x", 1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefAfterSibling() async {
            await expectJSONValid("a = [tstr, * pair]\npair = (int, tstr)", #"["h"]"#)
            await expectJSONValid("a = [tstr, * pair]\npair = (int, tstr)", #"["h", 1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefExact() async {
            await expectJSONValid("a = [1*1 b]\nb = (int, tstr)", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefStar() async {
            await expectJSONValid("a = [* pair]\npair = (int, tstr)", #"[1, "x"]"#)
            await expectJSONValid("a = [* pair]\npair = (int, tstr)", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func lowerBoundOnly() async {
            await expectJSONValid("a = [2* (int, tstr)]", #"[1, "x", 2, "y"]"#)
            await expectJSONValid("a = [2* (int, tstr)]", #"[1, "x", 2, "y", 3, "z"]"#)
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4; Appendix B (choice extension).
        @Test func namedTypeChoiceElem() async {
            await expectJSONValid("a = [* elem]\nelem = int\nelem /= tstr", #"[]"#)
            await expectJSONValid("a = [* elem]\nelem = int\nelem /= tstr", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func nestedParens() async {
            await expectJSONValid("a = [1*1 (int, (tstr))]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedStarOfStar() async {
            await expectJSONValid("a = [* [* (int, tstr)]]", #"[[1, "x"]]"#)
            await expectJSONValid("a = [* [* (int, tstr)]]", #"[[1, "x", 2, "y"], []]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurInsideOccur() async {
            await expectJSONValid("a = [* (int, 2*2 tstr)]", #"[]"#)
            await expectJSONValid("a = [* (int, 2*2 tstr)]", #"[1, "x", "y"]"#)
            await expectJSONValid("a = [* (int, 2*2 tstr)]", #"[1, "x", "y", 2, "p", "q"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurOnSingleEntryGroup() async {
            await expectJSONValid("a = [2*2 (int, 1*1 (tstr))]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func oneOrMore() async {
            await expectJSONValid("a = [+ (int, tstr)]", #"[1, "x"]"#)
            await expectJSONValid("a = [+ (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optional() async {
            await expectJSONValid("a = [? (int, tstr)]", #"[1, "x"]"#)
            await expectJSONInvalid("a = [? (int, tstr)]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optionalMiddle() async {
            await expectJSONValid("a = [int, ? tstr, bool]", #"[1, true]"#)
            await expectJSONValid("a = [int, ? tstr, bool]", #"[1, "x", true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func prefixThenStar() async {
            await expectJSONValid("a = [tstr, * int]", #"["h"]"#)
            await expectJSONValid("a = [tstr, * int]", #"["h", 1, 2]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4; Appendix A (prioritized choice).
        @Test func prioritizedChoiceLocks() async {
            await expectJSONInvalid("a = [(int // int, tstr)]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.2, 3.4. Errors recorded while trying a
        /// failing type-choice alternative must not poison a successful one,
        /// regardless of the order the alternatives appear in.
        @Test func typeChoiceAlternativeOrder() async {
            await expectJSONValid("a = [* ([int] / [tstr])]", #"[["x"]]"#)
            await expectJSONValid("a = [* ([tstr] / [int])]", #"[[1]]"#)
        }

        /// RFC 8610: Section 2.2.1. A type choice must reject an array when no
        /// alternative matches it, including alternatives that are not array-shaped
        /// (a non-array alternative failing against an array must count as a
        /// failure, not be skipped silently).
        @Test func typeChoiceNonArrayAlternates() async {
            await expectJSONInvalid("a = tstr / bool", #"[1]"#)
            await expectJSONInvalid("a = [int, int] / tstr", #"[1, "x"]"#)
            await expectJSONInvalid("a = [* (tstr / bool)]", #"[[1]]"#)
            await expectJSONValid("a = [int, int] / tstr", #""hi""#)
            await expectJSONValid("a = tstr / [int]", #"[1]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func range12() async {
            await expectJSONValid("a = [1*2 (int, tstr)]", #"[1, "x"]"#)
            await expectJSONValid("a = [1*2 (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingAfter() async {
            await expectJSONValid("a = [(int, tstr), bool]", #"[1, "x", true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeNoOccur() async {
            await expectJSONValid("a = [bool, (int, tstr)]", #"[true, 1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeOccur() async {
            await expectJSONValid("a = [bool, 1*1 (int, tstr)]", #"[true, 1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starGroupThenInt() async {
            await expectJSONValid("a = [* (int, tstr), int]", #"[5]"#)
            await expectJSONValid("a = [* (int, tstr), int]", #"[1, "x", 5]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starOfVarArity() async {
            await expectJSONValid("a = [* (int, * tstr)]", #"[1]"#)
            await expectJSONValid("a = [* (int, * tstr)]", #"[1, "x", 2]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starThenTstr() async {
            await expectJSONValid("a = [* int, tstr]", #"["x"]"#)
            await expectJSONValid("a = [* int, tstr]", #"[1, "x"]"#)
            await expectJSONValid("a = [* int, tstr]", #"[1, 2, "x"]"#)
            await expectJSONInvalid("a = [* int, tstr]", #"[]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func threeLevelNesting() async {
            await expectJSONValid("a = [1*1 (int, (tstr, (bool)))]", #"[1, "x", true]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapAfterSibling() async {
            await expectJSONValid("a = [bool, ~b]\nb = [int, tstr]", #"[true, 1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapSole() async {
            await expectJSONValid("a = [~b]\nb = [int, tstr]", #"[1, "x"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapWithOccur() async {
            await expectJSONValid("a = [* ~b]\nb = [int, tstr]", #"[1, "x"]"#)
            await expectJSONValid("a = [* ~b]\nb = [int, tstr]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyGroup() async {
            await expectJSONValid("a = [*2 (int, tstr)]", #"[1, "x"]"#)
            await expectJSONValid("a = [*2 (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func varArityInside() async {
            await expectJSONValid("a = [1*1 (int, * tstr)]", #"[1]"#)
            await expectJSONValid("a = [1*1 (int, * tstr)]", #"[1, "x"]"#)
            await expectJSONValid("a = [1*1 (int, * tstr)]", #"[1, "x", "y"]"#)
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func zeroOrMore() async {
            await expectJSONValid("a = [* (int, tstr)]", #"[1, "x"]"#)
            await expectJSONValid("a = [* (int, tstr)]", #"[1, "x", 2, "y"]"#)
        }
    }
}
