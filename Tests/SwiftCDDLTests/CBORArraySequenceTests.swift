import Testing

@testable import SwiftCDDL

// RFC 8610 Section 3.3 defines the primitive names used throughout these
// tests (for example, int, tstr, and bool). Per-test comments cite the
// structural rules that motivate each expected match result.
//
// Two normative appendices underpin every verdict in this file:
// - Appendix C (Matching Rules): an array matches when its element sequence
//   matches the group, and "an occurrence indicator modifies the group given
//   to its right by requiring the group to match the sequence ... in
//   sequence", i.e. repetition quantifies the group's whole entry sequence,
//   not the array length.
// - Appendix A (PEGs): matching semantics are PEG: occurrence indicators are
//   greedy with no backtracking out of a repetition ('"*a a" in CDDL syntax
//   never can match anything'), and "/" and "//" are prioritized choice that
//   locks in the first successful alternative.
//
// Known tension between the two: Appendix C's "a (possibly infinite) group
// choice" wording, read alone, could permit shorter-than-greedy matches (e.g.
// [* int, int] matching [1]). Appendix A's explicit '*a a' example resolves it
// as greedy, and a second implementation agrees; the greedyStarThenInt tests
// encode that resolution.

/// Array group and occurrence sequence matching (RFC 8610 Section 3.4 and
/// Appendices A and C), over vectors cross-checked against a second
/// implementation.
@Suite struct CBORArraySequenceTests {
    /// Behaviour that was already correct before the sequence matcher and must
    /// not change.
    @Suite struct Regression {

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.8, 3.8.4.
        @Test func cborControlElem() async {
            // ACCEPT []
            await expectValid("a = [* bytes .cbor b]\nb = [int, tstr]", [0x80])
            // ACCEPT [h'82016178']
            await expectValid("a = [* bytes .cbor b]\nb = [int, tstr]", [0x81, 0x44, 0x82, 0x01, 0x61, 0x78])
            // REJECT [h'8101']
            await expectInvalid("a = [* bytes .cbor b]\nb = [int, tstr]", [0x81, 0x42, 0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.8, 3.8.4.
        @Test func cborControlGroupInside() async {
            // REJECT [h'8101']
            await expectInvalid("a = [bytes .cbor b]\nb = [* (int, tstr)]", [0x81, 0x42, 0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4, 3.11.
        @Test func choiceDiffLengths() async {
            // ACCEPT [true]
            await expectValid("a = [(bool // int, tstr)]", [0x81, 0xf5])
            // ACCEPT [1, "x"]
            await expectValid("a = [(bool // int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1]
            await expectInvalid("a = [(bool // int, tstr)]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& group choice).
        @Test func choiceFromGroup() async {
            // ACCEPT []
            await expectValid("a = [* &(1, 2)]", [0x80])
            // ACCEPT [1, 2, 1]
            await expectValid("a = [* &(1, 2)]", [0x83, 0x01, 0x02, 0x01])
            // REJECT [3]
            await expectInvalid("a = [* &(1, 2)]", [0x81, 0x03])
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& groupname).
        @Test func choiceFromNamedGroup() async {
            // REJECT [3]
            await expectInvalid("a = [* e]\ne = &g\ng = (1, 2)", [0x81, 0x03])
        }

        /// RFC 8610: Sections 2.1, 3.4.
        @Test func emptyArray() async {
            // ACCEPT []
            await expectValid("a = []", [0x80])
            // REJECT [1]
            await expectInvalid("a = []", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence must terminate
        /// on zero-width repetitions); Appendix B (parenthesized group).
        @Test func emptyGroupStar() async {
            // NOTE: a second implementation loops forever on zero-width group repetition; expected per RFC: () matches trivially, then int matches. Matcher must terminate.
            // ACCEPT [1]
            await expectValid("a = [* (), int]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact11() async {
            // REJECT []
            await expectInvalid("a = [1*1 (int, tstr)]", [0x80])
            // REJECT [1]
            await expectInvalid("a = [1*1 (int, tstr)]", [0x81, 0x01])
            // REJECT [1, "x", 2, "y"]
            await expectInvalid("a = [1*1 (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
            // REJECT ["x", 1]
            await expectInvalid("a = [1*1 (int, tstr)]", [0x82, 0x61, 0x78, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact22() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [2*2 (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1, "x", 2, "y", 3, "z"]
            await expectInvalid(
                "a = [2*2 (int, tstr)]",
                [0x86, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0x03, 0x61, 0x7a]
            )
            // REJECT [1, "x", 2]
            await expectInvalid("a = [2*2 (int, tstr)]", [0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10.
        @Test func genericElem() async {
            // REJECT [["x"]]
            await expectInvalid("a = [* box<int>]\nbox<T> = [T]", [0x81, 0x81, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10; Appendix B (groupname entry).
        @Test func genericGroupElem() async {
            // REJECT [1] (cross-checked against a second implementation)
            await expectInvalid("a = [* g<int>]\ng<T> = (T, T)", [0x81, 0x01])
            // REJECT [1, "x"] (cross-checked against a second implementation)
            await expectInvalid("a = [* g<int>]\ng<T> = (T, T)", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func groupBetweenSiblings() async {
            // REJECT [true, 1, false]
            await expectInvalid("a = [bool, * (int, tstr), bool]", [0x83, 0xf5, 0x01, 0xf4])
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4.
        @Test func groupChoiceInside() async {
            // REJECT [1, 2]
            await expectInvalid("a = [1*1 (int, tstr // tstr, int)]", [0x82, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefAfterSibling() async {
            // REJECT ["h", 1]
            await expectInvalid("a = [tstr, * pair]\npair = (int, tstr)", [0x82, 0x61, 0x68, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefExact() async {
            // REJECT [1]
            await expectInvalid("a = [1*1 b]\nb = (int, tstr)", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefStar() async {
            // ACCEPT []
            await expectValid("a = [* pair]\npair = (int, tstr)", [0x80])
            // REJECT [1, "x", 2]
            await expectInvalid("a = [* pair]\npair = (int, tstr)", [0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousAlias() async {
            // ACCEPT []
            await expectValid("a = [* zip]\nzip = int", [0x80])
            // ACCEPT [1, 2]
            await expectValid("a = [* zip]\nzip = int", [0x82, 0x01, 0x02])
            // REJECT ["x"]
            await expectInvalid("a = [* zip]\nzip = int", [0x81, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousExact() async {
            // ACCEPT [1, 2, 3]
            await expectValid("a = [3*3 int]", [0x83, 0x01, 0x02, 0x03])
            // REJECT [1, 2]
            await expectInvalid("a = [3*3 int]", [0x82, 0x01, 0x02])
            // REJECT [1, 2, 3, 4]
            await expectInvalid("a = [3*3 int]", [0x84, 0x01, 0x02, 0x03, 0x04])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousLower() async {
            // ACCEPT [1, 2, 3]
            await expectValid("a = [3* int]", [0x83, 0x01, 0x02, 0x03])
            // ACCEPT [1, 2, 3, 4]
            await expectValid("a = [3* int]", [0x84, 0x01, 0x02, 0x03, 0x04])
            // REJECT [1, 2]
            await expectInvalid("a = [3* int]", [0x82, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousOpt() async {
            // ACCEPT []
            await expectValid("a = [? int]", [0x80])
            // ACCEPT [1]
            await expectValid("a = [? int]", [0x81, 0x01])
            // REJECT [1, 2]
            await expectInvalid("a = [? int]", [0x82, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousPlus() async {
            // ACCEPT [1]
            await expectValid("a = [+ int]", [0x81, 0x01])
            // ACCEPT [1, 2, 3]
            await expectValid("a = [+ int]", [0x83, 0x01, 0x02, 0x03])
            // REJECT []
            await expectInvalid("a = [+ int]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousRange() async {
            // ACCEPT [1]
            await expectValid("a = [1*3 int]", [0x81, 0x01])
            // ACCEPT [1, 2, 3]
            await expectValid("a = [1*3 int]", [0x83, 0x01, 0x02, 0x03])
            // REJECT []
            await expectInvalid("a = [1*3 int]", [0x80])
            // REJECT [1, 2, 3, 4]
            await expectInvalid("a = [1*3 int]", [0x84, 0x01, 0x02, 0x03, 0x04])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func homogeneousStar() async {
            // ACCEPT []
            await expectValid("a = [* int]", [0x80])
            // ACCEPT [1, 2, 3]
            await expectValid("a = [* int]", [0x83, 0x01, 0x02, 0x03])
            // REJECT [1, "x"]
            await expectInvalid("a = [* int]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.4.
        @Test func literalElements() async {
            // ACCEPT [1, 2, 3]
            await expectValid("a = [1, 2, 3]", [0x83, 0x01, 0x02, 0x03])
            // REJECT [1, 2]
            await expectInvalid("a = [1, 2, 3]", [0x82, 0x01, 0x02])
            // REJECT [1, 2, 4]
            await expectInvalid("a = [1, 2, 3]", [0x83, 0x01, 0x02, 0x04])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func lowerBoundOnly() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [2* (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.5, 3.5.1; Appendix B (groupname entry).
        @Test func mapGroupRef() async {
            // ACCEPT {"x": 1, "y": "h"}
            await expectValid(
                "a = {g}\ng = (x: int, y: tstr)",
                [0xa2, 0x61, 0x78, 0x01, 0x61, 0x79, 0x61, 0x68]
            )
            // REJECT {"x": 1}
            await expectInvalid("a = {g}\ng = (x: int, y: tstr)", [0xa1, 0x61, 0x78, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.5.1.
        @Test func mapInArray() async {
            // ACCEPT []
            await expectValid("a = [* {k: int}]", [0x80])
            // ACCEPT [{"k": 1}]
            await expectValid("a = [* {k: int}]", [0x81, 0xa1, 0x61, 0x6b, 0x01])
            // REJECT [{"k": "x"}]
            await expectInvalid("a = [* {k: int}]", [0x81, 0xa1, 0x61, 0x6b, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.5.1; Appendix B (groupname entry).
        @Test func mapInArrayWithGroup() async {
            // ACCEPT []
            await expectValid("a = [* {g}]\ng = (x: int)", [0x80])
            // ACCEPT [{"x": 1}]
            await expectValid("a = [* {g}]\ng = (x: int)", [0x81, 0xa1, 0x61, 0x78, 0x01])
            // REJECT [{"x": "h"}]
            await expectInvalid("a = [* {g}]\ng = (x: int)", [0x81, 0xa1, 0x61, 0x78, 0x61, 0x68])
        }

        /// RFC 8610: Sections 2.1, 3.5.1; Appendix B (parenthesized group).
        @Test func mapInlineGroup() async {
            // ACCEPT {"x": 1, "y": "h"}
            await expectValid("a = {(x: int, y: tstr)}", [0xa2, 0x61, 0x78, 0x01, 0x61, 0x79, 0x61, 0x68])
            // REJECT {"x": 1}
            await expectInvalid("a = {(x: int, y: tstr)}", [0xa1, 0x61, 0x78, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.5.1.
        @Test func mapOptionalMember() async {
            // ACCEPT {"x": 1}
            await expectValid("a = {x: int, ? y: tstr}", [0xa1, 0x61, 0x78, 0x01])
            // ACCEPT {"x": 1, "y": "h"}
            await expectValid("a = {x: int, ? y: tstr}", [0xa2, 0x61, 0x78, 0x01, 0x61, 0x79, 0x61, 0x68])
            // REJECT {}
            await expectInvalid("a = {x: int, ? y: tstr}", [0xa0])
        }

        /// RFC 8610: Sections 2.1, 3.5.1.
        @Test func mapRecord() async {
            // ACCEPT {"x": 1, "y": "h"}
            await expectValid("a = {x: int, y: tstr}", [0xa2, 0x61, 0x78, 0x01, 0x61, 0x79, 0x61, 0x68])
            // REJECT {"x": 1}
            await expectInvalid("a = {x: int, y: tstr}", [0xa1, 0x61, 0x78, 0x01])
            // REJECT {"x": "h", "y": "h"}
            await expectInvalid(
                "a = {x: int, y: tstr}",
                [0xa2, 0x61, 0x78, 0x61, 0x68, 0x61, 0x79, 0x61, 0x68]
            )
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.5.2.
        @Test func mapStarMembers() async {
            // ACCEPT {}
            await expectValid("a = {* tstr => int}", [0xa0])
            // ACCEPT {"a": 1, "b": 2}
            await expectValid("a = {* tstr => int}", [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02])
            // REJECT {"a": "x"}
            await expectInvalid("a = {* tstr => int}", [0xa1, 0x61, 0x61, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4; Appendix B (choice extension).
        @Test func namedTypeChoiceElem() async {
            // REJECT [true]
            await expectInvalid("a = [* elem]\nelem = int\nelem /= tstr", [0x81, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedArray() async {
            // ACCEPT []
            await expectValid("a = [* [int]]", [0x80])
            // ACCEPT [[1], [2]]
            await expectValid("a = [* [int]]", [0x82, 0x81, 0x01, 0x81, 0x02])
            // REJECT [1]
            await expectInvalid("a = [* [int]]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.4.
        @Test func nestedArrayLiteral() async {
            // ACCEPT [1, [2, 3], [4, 5]]
            await expectValid(
                "a = [int, [int, int], [int, int]]",
                [0x83, 0x01, 0x82, 0x02, 0x03, 0x82, 0x04, 0x05]
            )
            // REJECT [1, [2, 3]]
            await expectInvalid("a = [int, [int, int], [int, int]]", [0x82, 0x01, 0x82, 0x02, 0x03])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func nestedParens() async {
            // REJECT [1]
            await expectInvalid("a = [1*1 (int, (tstr))]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedStarOfStar() async {
            // ACCEPT []
            await expectValid("a = [* [* (int, tstr)]]", [0x80])
            // ACCEPT [[]]
            await expectValid("a = [* [* (int, tstr)]]", [0x81, 0x80])
            // REJECT [[1]]
            await expectInvalid("a = [* [* (int, tstr)]]", [0x81, 0x81, 0x01])
            // REJECT [1, "x"]
            await expectInvalid("a = [* [* (int, tstr)]]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurInsideOccur() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [* (int, 2*2 tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1, "x", "y", "z"]
            await expectInvalid("a = [* (int, 2*2 tstr)]", [0x84, 0x01, 0x61, 0x78, 0x61, 0x79, 0x61, 0x7a])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurOnSingleEntryGroup() async {
            // REJECT [1, "x", 2]
            await expectInvalid("a = [2*2 (int, 1*1 (tstr))]", [0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func oneOrMore() async {
            // REJECT []
            await expectInvalid("a = [+ (int, tstr)]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optional() async {
            // ACCEPT []
            await expectValid("a = [? (int, tstr)]", [0x80])
            // REJECT [1, "x", 2, "y"]
            await expectInvalid("a = [? (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optionalMiddle() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [int, ? tstr, bool]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1, "x", true, true]
            await expectInvalid("a = [int, ? tstr, bool]", [0x84, 0x01, 0x61, 0x78, 0xf5, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func prefixThenStar() async {
            // REJECT [1]
            await expectInvalid("a = [tstr, * int]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4; Appendix A (prioritized choice).
        @Test func prioritizedChoiceLocks() async {
            // ACCEPT [1]
            await expectValid("a = [(int // int, tstr)]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func range12() async {
            // REJECT []
            await expectInvalid("a = [1*2 (int, tstr)]", [0x80])
            // REJECT [1, "x", 2, "y", 3, "z"]
            await expectInvalid(
                "a = [1*2 (int, tstr)]",
                [0x86, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0x03, 0x61, 0x7a]
            )
        }

        /// RFC 8610: Sections 2.1, 3.4, 3.5.1.
        @Test func record() async {
            // ACCEPT [1, 2, 3]
            await expectValid("a = [x: int, y: int, z: int]", [0x83, 0x01, 0x02, 0x03])
            // REJECT [1, 2]
            await expectInvalid("a = [x: int, y: int, z: int]", [0x82, 0x01, 0x02])
            // REJECT [1, 2, 3, 4]
            await expectInvalid("a = [x: int, y: int, z: int]", [0x84, 0x01, 0x02, 0x03, 0x04])
        }

        /// RFC 8610: Sections 2.1, 3.4, 3.5.1.
        @Test func recordMixed() async {
            // ACCEPT ["h", 1]
            await expectValid("a = [x: tstr, y: int]", [0x82, 0x61, 0x68, 0x01])
            // REJECT [1, "h"]
            await expectInvalid("a = [x: tstr, y: int]", [0x82, 0x01, 0x61, 0x68])
            // REJECT ["h"]
            await expectInvalid("a = [x: tstr, y: int]", [0x81, 0x61, 0x68])
            // REJECT ["h", 1, 2]
            await expectInvalid("a = [x: tstr, y: int]", [0x83, 0x61, 0x68, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingAfter() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [(int, tstr), bool]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1, true]
            await expectInvalid("a = [(int, tstr), bool]", [0x82, 0x01, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeNoOccur() async {
            // REJECT [true, 1]
            await expectInvalid("a = [bool, (int, tstr)]", [0x82, 0xf5, 0x01])
            // REJECT [true, "x", 1]
            await expectInvalid("a = [bool, (int, tstr)]", [0x83, 0xf5, 0x61, 0x78, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeOccur() async {
            // REJECT [true]
            await expectInvalid("a = [bool, 1*1 (int, tstr)]", [0x81, 0xf5])
            // REJECT [true, 1, "x", 2, "y"]
            await expectInvalid(
                "a = [bool, 1*1 (int, tstr)]",
                [0x85, 0xf5, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79]
            )
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.8, 3.8.1.
        @Test func sizeControlElem() async {
            // ACCEPT []
            await expectValid("a = [* tstr .size 2]", [0x80])
            // ACCEPT ["ok"]
            await expectValid("a = [* tstr .size 2]", [0x81, 0x62, 0x6f, 0x6b])
            // REJECT ["x"]
            await expectInvalid("a = [* tstr .size 2]", [0x81, 0x61, 0x78])
            // REJECT ["abc"]
            await expectInvalid("a = [* tstr .size 2]", [0x81, 0x63, 0x61, 0x62, 0x63])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func soleGroupNoOccurInline() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [(int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1]
            await expectInvalid("a = [(int, tstr)]", [0x81, 0x01])
            // REJECT [1, "x", 2]
            await expectInvalid("a = [(int, tstr)]", [0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func soleGroupNoOccurRef() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [b]\nb = (int, tstr)", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1]
            await expectInvalid("a = [b]\nb = (int, tstr)", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starGroupThenInt() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [* (int, tstr), int]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starOfVarArity() async {
            // ACCEPT []
            await expectValid("a = [* (int, * tstr)]", [0x80])
            // REJECT ["x"]
            await expectInvalid("a = [* (int, * tstr)]", [0x81, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starThenTstr() async {
            // REJECT [1]
            await expectInvalid("a = [* int, tstr]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 2.2.3, 3.2, 3.4, 3.6 (#6.nnn(type) tag notation).
        @Test func taggedElem() async {
            // ACCEPT []
            await expectValid("a = [* #6.42(tstr)]", [0x80])
            // ACCEPT [42("x")]
            await expectValid("a = [* #6.42(tstr)]", [0x81, 0xd8, 0x2a, 0x61, 0x78])
            // REJECT [43("x")]
            await expectInvalid("a = [* #6.42(tstr)]", [0x81, 0xd8, 0x2b, 0x61, 0x78])
            // REJECT ["x"]
            await expectInvalid("a = [* #6.42(tstr)]", [0x81, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 2.2.3, 3.2, 3.4, 3.6 (#6.nnn(type) tag notation).
        @Test func taggedElemInGroup() async {
            // ACCEPT [1, 42("x")]
            await expectValid("a = [* (int, #6.42(tstr))]", [0x82, 0x01, 0xd8, 0x2a, 0x61, 0x78])
            // REJECT [1, "x"]
            await expectInvalid("a = [* (int, #6.42(tstr))]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func threeLevelNesting() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [1*1 (int, (tstr, (bool)))]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func tupleElements() async {
            // ACCEPT []
            await expectValid("a = [* [int, tstr]]", [0x80])
            // ACCEPT [[1, "x"]]
            await expectValid("a = [* [int, tstr]]", [0x81, 0x82, 0x01, 0x61, 0x78])
            // ACCEPT [[1, "x"], [2, "y"]]
            await expectValid("a = [* [int, tstr]]", [0x82, 0x82, 0x01, 0x61, 0x78, 0x82, 0x02, 0x61, 0x79])
            // REJECT [[1]]
            await expectInvalid("a = [* [int, tstr]]", [0x81, 0x81, 0x01])
            // REJECT [[1, "x", 2]]
            await expectInvalid("a = [* [int, tstr]]", [0x81, 0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4, 3.11.
        @Test func typeChoiceElement() async {
            // ACCEPT []
            await expectValid("a = [* (int / tstr)]", [0x80])
            // ACCEPT [1, "x"]
            await expectValid("a = [* (int / tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [true]
            await expectInvalid("a = [* (int / tstr)]", [0x81, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.2, 3.4.
        @Test func typeChoiceOfArraysElem() async {
            // ACCEPT [[1]]
            await expectValid("a = [* ([int] / [tstr])]", [0x81, 0x81, 0x01])
            // REJECT [[true]]
            await expectInvalid("a = [* ([int] / [tstr])]", [0x81, 0x81, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapAfterSibling() async {
            // REJECT [true, 1]
            await expectInvalid("a = [bool, ~b]\nb = [int, tstr]", [0x82, 0xf5, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4 (member keys are annotation-only in an
        /// array context), 3.7.
        @Test func unwrapLabeled() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [x: ~b]\nb = [int, tstr]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1]
            await expectInvalid("a = [x: ~b]\nb = [int, tstr]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapSole() async {
            // REJECT [1]
            await expectInvalid("a = [~b]\nb = [int, tstr]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapWithOccur() async {
            // ACCEPT []
            await expectValid("a = [* ~b]\nb = [int, tstr]", [0x80])
            // REJECT [1]
            await expectInvalid("a = [* ~b]\nb = [int, tstr]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyGroup() async {
            // ACCEPT []
            await expectValid("a = [*2 (int, tstr)]", [0x80])
            // REJECT [1, "x", 2, "y", 3, "z"]
            await expectInvalid(
                "a = [*2 (int, tstr)]",
                [0x86, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0x03, 0x61, 0x7a]
            )
            // REJECT [1]
            await expectInvalid("a = [*2 (int, tstr)]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyHomogeneous() async {
            // ACCEPT []
            await expectValid("a = [*2 int]", [0x80])
            // ACCEPT [1, 2]
            await expectValid("a = [*2 int]", [0x82, 0x01, 0x02])
            // REJECT [1, 2, 3]
            await expectInvalid("a = [*2 int]", [0x83, 0x01, 0x02, 0x03])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func upstreamIgnoredCase() async {
            // ACCEPT [1, 2, 3]
            await expectValid("a = [int, (int, int)]", [0x83, 0x01, 0x02, 0x03])
            // REJECT [1, 2]
            await expectInvalid("a = [int, (int, int)]", [0x82, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func varArityInside() async {
            // REJECT []
            await expectInvalid("a = [1*1 (int, * tstr)]", [0x80])
            // REJECT ["x"]
            await expectInvalid("a = [1*1 (int, * tstr)]", [0x81, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func zeroOrMore() async {
            // ACCEPT []
            await expectValid("a = [* (int, tstr)]", [0x80])
            // REJECT [1]
            await expectInvalid("a = [* (int, tstr)]", [0x81, 0x01])
            // REJECT [1, "x", 2]
            await expectInvalid("a = [* (int, tstr)]", [0x83, 0x01, 0x61, 0x78, 0x02])
            // REJECT ["x", 1]
            await expectInvalid("a = [* (int, tstr)]", [0x82, 0x61, 0x78, 0x01])
        }
    }

    /// Spec-correct behaviour a positional array matcher gets wrong in both
    /// directions: spec-valid instances rejected and spec-invalid instances
    /// accepted.
    @Suite struct PostFix {

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7, 3.10.
        @Test func genericGroupChoiceNoArgLeak() async {
            // Generic args registered while a failing choice alternative was tried
            // speculatively must not leak into the next alternative.
            // ACCEPT ["x", "x"] (cross-checked against a second implementation)
            await expectValid("a = [(g<int> // g<tstr>)]\ng<T> = (T, T)", [0x82, 0x61, 0x78, 0x61, 0x78])
            // ACCEPT [1, 1] (cross-checked against a second implementation)
            await expectValid("a = [(g<int> // g<tstr>)]\ng<T> = (T, T)", [0x82, 0x01, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7, 3.10.
        @Test func unwrapGenericChoiceNoArgLeak() async {
            // ACCEPT ["x"] (cross-checked against a second implementation)
            await expectValid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", [0x81, 0x61, 0x78])
            // ACCEPT [1] (cross-checked against a second implementation)
            await expectValid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", [0x81, 0x01])
            // REJECT [true] (cross-checked against a second implementation)
            await expectInvalid("a = [~box<int> // ~box<tstr>]\nbox<T> = [T]", [0x81, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapRecursive() async {
            // Recursive unwrap references must terminate instead of overflowing the
            // stack; the rule is unsatisfiable.
            // REJECT [] (cross-checked against a second implementation)
            await expectInvalid("a = [~b]\nb = [~b]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.8, 3.8.4.
        @Test func cborControlGroupInside() async {
            // ACCEPT [h'82016178']
            await expectValid(
                "a = [bytes .cbor b]\nb = [* (int, tstr)]",
                [0x81, 0x44, 0x82, 0x01, 0x61, 0x78]
            )
        }

        /// RFC 8610: Sections 2.2.2.2, 3.2, 3.4; Appendix B (& groupname).
        @Test func choiceFromNamedGroup() async {
            // ACCEPT [1, 2]
            await expectValid("a = [* e]\ne = &g\ng = (1, 2)", [0x82, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence must terminate
        /// on zero-width repetitions); Appendix B (parenthesized group).
        @Test func emptyGroupStar() async {
            // NOTE: a second implementation loops forever on zero-width group repetition; expected per RFC: trailing int unmatched in []. Matcher must terminate.
            // REJECT []
            await expectInvalid("a = [* (), int]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact11() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [1*1 (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func exact22() async {
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [2*2 (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10.
        @Test func genericElem() async {
            // ACCEPT []
            await expectValid("a = [* box<int>]\nbox<T> = [T]", [0x80])
            // ACCEPT [[1]]
            await expectValid("a = [* box<int>]\nbox<T> = [T]", [0x81, 0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.10; Appendix B (groupname entry).
        @Test func genericGroupElem() async {
            // ACCEPT [] (cross-checked against a second implementation)
            await expectValid("a = [* g<int>]\ng<T> = (T, T)", [0x80])
            // ACCEPT [1, 2] (cross-checked against a second implementation)
            await expectValid("a = [* g<int>]\ng<T> = (T, T)", [0x82, 0x01, 0x02])
            // ACCEPT [1, 2, 3, 4] (cross-checked against a second implementation)
            await expectValid("a = [* g<int>]\ng<T> = (T, T)", [0x84, 0x01, 0x02, 0x03, 0x04])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix A (greedy PEG occurrence behavior).
        @Test func greedyStarThenInt() async {
            // REJECT [1]
            await expectInvalid("a = [* int, int]", [0x81, 0x01])
            // REJECT [1, 2]
            await expectInvalid("a = [* int, int]", [0x82, 0x01, 0x02])
            // REJECT []
            await expectInvalid("a = [* int, int]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func groupBetweenSiblings() async {
            // ACCEPT [true, false]
            await expectValid("a = [bool, * (int, tstr), bool]", [0x82, 0xf5, 0xf4])
            // ACCEPT [true, 1, "x", false]
            await expectValid("a = [bool, * (int, tstr), bool]", [0x84, 0xf5, 0x01, 0x61, 0x78, 0xf4])
            // ACCEPT [true, 1, "x", 2, "y", false]
            await expectValid(
                "a = [bool, * (int, tstr), bool]",
                [0x86, 0xf5, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0xf4]
            )
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4.
        @Test func groupChoiceInside() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [1*1 (int, tstr // tstr, int)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT ["x", 1]
            await expectValid("a = [1*1 (int, tstr // tstr, int)]", [0x82, 0x61, 0x78, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefAfterSibling() async {
            // ACCEPT ["h"]
            await expectValid("a = [tstr, * pair]\npair = (int, tstr)", [0x81, 0x61, 0x68])
            // ACCEPT ["h", 1, "x"]
            await expectValid("a = [tstr, * pair]\npair = (int, tstr)", [0x83, 0x61, 0x68, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefExact() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [1*1 b]\nb = (int, tstr)", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (groupname entry).
        @Test func grouprefStar() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [* pair]\npair = (int, tstr)", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [* pair]\npair = (int, tstr)", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func lowerBoundOnly() async {
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [2* (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
            // ACCEPT [1, "x", 2, "y", 3, "z"]
            await expectValid(
                "a = [2* (int, tstr)]",
                [0x86, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0x03, 0x61, 0x7a]
            )
        }

        /// RFC 8610: Sections 2.2.2, 3.2, 3.4; Appendix B (choice extension).
        @Test func namedTypeChoiceElem() async {
            // ACCEPT []
            await expectValid("a = [* elem]\nelem = int\nelem /= tstr", [0x80])
            // ACCEPT [1, "x"]
            await expectValid("a = [* elem]\nelem = int\nelem /= tstr", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func nestedParens() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [1*1 (int, (tstr))]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func nestedStarOfStar() async {
            // ACCEPT [[1, "x"]]
            await expectValid("a = [* [* (int, tstr)]]", [0x81, 0x82, 0x01, 0x61, 0x78])
            // ACCEPT [[1, "x", 2, "y"], []]
            await expectValid(
                "a = [* [* (int, tstr)]]",
                [0x82, 0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79, 0x80]
            )
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurInsideOccur() async {
            // ACCEPT []
            await expectValid("a = [* (int, 2*2 tstr)]", [0x80])
            // ACCEPT [1, "x", "y"]
            await expectValid("a = [* (int, 2*2 tstr)]", [0x83, 0x01, 0x61, 0x78, 0x61, 0x79])
            // ACCEPT [1, "x", "y", 2, "p", "q"]
            await expectValid(
                "a = [* (int, 2*2 tstr)]",
                [0x86, 0x01, 0x61, 0x78, 0x61, 0x79, 0x02, 0x61, 0x70, 0x61, 0x71]
            )
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func occurOnSingleEntryGroup() async {
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [2*2 (int, 1*1 (tstr))]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func oneOrMore() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [+ (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [+ (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optional() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [? (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // REJECT [1]
            await expectInvalid("a = [? (int, tstr)]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func optionalMiddle() async {
            // ACCEPT [1, true]
            await expectValid("a = [int, ? tstr, bool]", [0x82, 0x01, 0xf5])
            // ACCEPT [1, "x", true]
            await expectValid("a = [int, ? tstr, bool]", [0x83, 0x01, 0x61, 0x78, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func prefixThenStar() async {
            // ACCEPT ["h"]
            await expectValid("a = [tstr, * int]", [0x81, 0x61, 0x68])
            // ACCEPT ["h", 1, 2]
            await expectValid("a = [tstr, * int]", [0x83, 0x61, 0x68, 0x01, 0x02])
        }

        /// RFC 8610: Sections 2.1, 2.2.2, 3.2, 3.4; Appendix A (prioritized choice).
        @Test func prioritizedChoiceLocks() async {
            // REJECT [1, "x"]
            await expectInvalid("a = [(int // int, tstr)]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 2.2.1, 3.2, 3.4. Errors recorded while trying a
        /// failing type-choice alternative must not poison a successful one,
        /// regardless of the order the alternatives appear in.
        @Test func typeChoiceAlternativeOrder() async {
            // ACCEPT [["x"]]
            await expectValid("a = [* ([int] / [tstr])]", [0x81, 0x81, 0x61, 0x78])
            // ACCEPT [[1]]
            await expectValid("a = [* ([tstr] / [int])]", [0x81, 0x81, 0x01])
        }

        /// RFC 8610: Section 2.2.1. A type choice must reject an array when no
        /// alternative matches it, including alternatives that are not array-shaped
        /// (a non-array alternative failing against an array must count as a
        /// failure, not be skipped silently).
        @Test func typeChoiceNonArrayAlternates() async {
            // REJECT [1]
            await expectInvalid("a = tstr / bool", [0x81, 0x01])
            // REJECT [1, "x"]
            await expectInvalid("a = [int, int] / tstr", [0x82, 0x01, 0x61, 0x78])
            // REJECT [[1]]
            await expectInvalid("a = [* (tstr / bool)]", [0x81, 0x81, 0x01])
            // ACCEPT "hi"
            await expectValid("a = [int, int] / tstr", [0x62, 0x68, 0x69])
            // ACCEPT [1]
            await expectValid("a = tstr / [int]", [0x81, 0x01])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func range12() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [1*2 (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [1*2 (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingAfter() async {
            // ACCEPT [1, "x", true]
            await expectValid("a = [(int, tstr), bool]", [0x83, 0x01, 0x61, 0x78, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeNoOccur() async {
            // ACCEPT [true, 1, "x"]
            await expectValid("a = [bool, (int, tstr)]", [0x83, 0xf5, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func siblingBeforeOccur() async {
            // ACCEPT [true, 1, "x"]
            await expectValid("a = [bool, 1*1 (int, tstr)]", [0x83, 0xf5, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starGroupThenInt() async {
            // ACCEPT [5]
            await expectValid("a = [* (int, tstr), int]", [0x81, 0x05])
            // ACCEPT [1, "x", 5]
            await expectValid("a = [* (int, tstr), int]", [0x83, 0x01, 0x61, 0x78, 0x05])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starOfVarArity() async {
            // ACCEPT [1]
            await expectValid("a = [* (int, * tstr)]", [0x81, 0x01])
            // ACCEPT [1, "x", 2]
            await expectValid("a = [* (int, * tstr)]", [0x83, 0x01, 0x61, 0x78, 0x02])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func starThenTstr() async {
            // ACCEPT ["x"]
            await expectValid("a = [* int, tstr]", [0x81, 0x61, 0x78])
            // ACCEPT [1, "x"]
            await expectValid("a = [* int, tstr]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, 2, "x"]
            await expectValid("a = [* int, tstr]", [0x83, 0x01, 0x02, 0x61, 0x78])
            // REJECT []
            await expectInvalid("a = [* int, tstr]", [0x80])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4; Appendix B (parenthesized group).
        @Test func threeLevelNesting() async {
            // ACCEPT [1, "x", true]
            await expectValid("a = [1*1 (int, (tstr, (bool)))]", [0x83, 0x01, 0x61, 0x78, 0xf5])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapAfterSibling() async {
            // ACCEPT [true, 1, "x"]
            await expectValid("a = [bool, ~b]\nb = [int, tstr]", [0x83, 0xf5, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapSole() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [~b]\nb = [int, tstr]", [0x82, 0x01, 0x61, 0x78])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4, 3.7.
        @Test func unwrapWithOccur() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [* ~b]\nb = [int, tstr]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [* ~b]\nb = [int, tstr]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func upperOnlyGroup() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [*2 (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [*2 (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func varArityInside() async {
            // ACCEPT [1]
            await expectValid("a = [1*1 (int, * tstr)]", [0x81, 0x01])
            // ACCEPT [1, "x"]
            await expectValid("a = [1*1 (int, * tstr)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", "y"]
            await expectValid("a = [1*1 (int, * tstr)]", [0x83, 0x01, 0x61, 0x78, 0x61, 0x79])
        }

        /// RFC 8610: Sections 2.1, 3.2, 3.4.
        @Test func zeroOrMore() async {
            // ACCEPT [1, "x"]
            await expectValid("a = [* (int, tstr)]", [0x82, 0x01, 0x61, 0x78])
            // ACCEPT [1, "x", 2, "y"]
            await expectValid("a = [* (int, tstr)]", [0x84, 0x01, 0x61, 0x78, 0x02, 0x61, 0x79])
        }
    }
}
