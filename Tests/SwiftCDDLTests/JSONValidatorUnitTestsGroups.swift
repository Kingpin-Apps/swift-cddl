import Foundation
import Testing

@testable import SwiftCDDL

// Unit tests of the JSON validator, second part: group choices, arrays,
// objects, member keys and recursion.

/// Tests of the JSON validator's group choices, arrays, objects, member keys
/// and recursion.
@Suite struct JSONValidatorUnitTestsGroups {
    /// The first alternative fails and contains an entry that resolves to an
    /// array type; the second alternative must still be evaluated against the
    /// array item at its own index.
    @Test func validateGroupChoiceAfterFailedAlternativeWithArrayTypedEntry() async {
        let cddl = """
            outer = [first // second]
            first = (0, inner)
            second = (4, sized, uint)
            inner = [0, tstr]
            sized = tstr .size 5
            """
        await expectJSONValid(cddl, #"[4, "abcde", 100]"#)
        await expectJSONInvalid(cddl, #"[4, "abcdef", 100]"#)
    }

    /// The array length check remains in force for every alternative, not just
    /// the first one to be tried.
    @Test func validateGroupChoiceArrayLengthCheckedForEveryAlternative() async {
        let cddl = """
            outer = [first // second]
            first = (0, inner)
            second = (4, uint, uint)
            inner = [0, tstr]
            """
        // Four items, while neither alternative admits more than three.
        await expectJSONInvalid(cddl, "[4, 1, 2, 3]")
        await expectJSONValid(cddl, "[4, 1, 2]")
    }

    /// An occurrence indicator consumed by a failed alternative must not remain
    /// in effect while the next alternative is evaluated.
    @Test func validateGroupChoiceAfterAlternativeWithOptionalEntry() async {
        let cddl = """
            outer = [first // second]
            first = (0, ? uint)
            second = (4, tstr)
            """
        await expectJSONValid(cddl, #"[4, "a"]"#)
        await expectJSONInvalid(cddl, "[4, 9]")
    }

    /// An alternative that consumes items homogeneously records its failures
    /// per item rather than as plain errors, and must be judged failed all the
    /// same so that the next alternative is tried, whatever order the
    /// alternatives are written in.
    @Test func validateGroupChoiceWithHomogeneousAlternativeInEitherOrder() async {
        let uintFirst = """
            x = [g // h]
            g = (* uint)
            h = (tstr, tstr)
            """
        let tstrFirst = """
            x = [h // g]
            g = (* uint)
            h = (tstr, tstr)
            """
        for cddl in [uintFirst, tstrFirst] {
            #expect(await jsonAccepts(cddl, #"["a", "b"]"#))
            #expect(await jsonAccepts(cddl, "[1, 2]"))
            #expect(await jsonAccepts(cddl, "[]"))

            // Neither alternative admits a mixture, nor a single text item.
            #expect(!(await jsonAccepts(cddl, #"[1, "b"]"#)))
            #expect(!(await jsonAccepts(cddl, #"["a"]"#)))
        }
    }

    /// A JSON member name is a string, so a member key that names a value of
    /// any other kind names no member of any object. `true` and `false` each
    /// name one boolean, and are reported the way every other member key that
    /// is not a string is.
    @Test func validateBoolLiteralMemberKeyNamesNoJSONMember() async {
        for (cddl, spelling) in [("tx = { true => uint }", "true"), ("tx = { false => uint }", "false")] {
            // The string of the same spelling is a different member name.
            for json in [#"{"true": 1}"#, #"{"false": 1}"#, "{}"] {
                #expect(!(await jsonAccepts(cddl, json)), "\(cddl) admits no JSON object, got \(json) accepted")
            }

            let rendered = jsonRendered(await jsonResult(cddl, #"{"true": 1}"#))
            #expect(rendered.contains("CDDL member key must be string data type. got \(spelling)"), "\(rendered)")
            #expect(!rendered.contains("got object"), "\(rendered)")
        }

        // A bareword of the same spelling is shorthand for the text string of
        // that name, and still names the member it always did.
        #expect(await jsonAccepts("tx = { true: uint }", #"{"true": 1}"#))
        #expect(!(await jsonAccepts("tx = { true: uint }", #"{"true": "x"}"#)))
    }

    /// Both alternatives consume items homogeneously, so neither records a
    /// plain error when it fails.
    @Test func validateGroupChoiceBetweenHomogeneousAlternatives() async {
        for cddl in ["x = [ (* uint) // (* tstr) ]", "x = [ (* tstr) // (* uint) ]"] {
            #expect(await jsonAccepts(cddl, #"["a", "b"]"#))
            #expect(await jsonAccepts(cddl, "[1, 2]"))
            #expect(await jsonAccepts(cddl, "[]"))
            #expect(!(await jsonAccepts(cddl, #"[1, "b"]"#)))
        }
    }

    /// A member matched by an alternative that went on to fail has not been
    /// validated, so the members the matching alternative does not account for
    /// must still be reported.
    @Test func validateGroupChoiceMapUnexpectedKeyInEitherOrder() async {
        for cddl in ["x = {a: uint, b: uint // c: uint}", "x = {c: uint // a: uint, b: uint}"] {
            #expect(await jsonAccepts(cddl, #"{"a": 1, "b": 2}"#))
            #expect(await jsonAccepts(cddl, #"{"c": 2}"#))

            // "a" belongs to the alternative that fails for want of "b".
            #expect(!(await jsonAccepts(cddl, #"{"a": 1, "c": 2}"#)))
            #expect(!(await jsonAccepts(cddl, #"{"a": 1}"#)))
            #expect(!(await jsonAccepts(cddl, "{}")))
        }
    }

    /// The number of items an array may hold is a property of the alternative
    /// being evaluated, not of the widest alternative.
    @Test func validateGroupChoiceArrayLengthPerAlternative() async {
        let shortFirst = """
            x = [first // second]
            first = (0, uint)
            second = (4, uint, uint)
            """
        let longFirst = """
            x = [second // first]
            first = (0, uint)
            second = (4, uint, uint)
            """
        for cddl in [shortFirst, longFirst] {
            #expect(await jsonAccepts(cddl, "[0, 8]"))
            #expect(await jsonAccepts(cddl, "[4, 8, 9]"))

            // Three items is the arity of `second`, whose first entry is 4.
            #expect(!(await jsonAccepts(cddl, "[0, 8, 9]")))
            // Two items is the arity of `first`, whose first entry is 0.
            #expect(!(await jsonAccepts(cddl, "[4, 8]")))
            #expect(!(await jsonAccepts(cddl, "[4, 1, 2, 3]")))
            #expect(!(await jsonAccepts(cddl, "[]")))
        }
    }

    /// The entries of a group turned into a choice are alternatives like any
    /// others, so each is matched against the same array item as the first.
    @Test func validateGroupChoiceEnumerationAlternativesInArray() async {
        let leadingEntry = """
            x = [0, sel]
            sel = &g
            g = (a: 1, b: 2)
            """
        let soleEntry = """
            x = [sel]
            sel = &g
            g = (a: 1, b: 2)
            """
        #expect(await jsonAccepts(leadingEntry, "[0, 1]"))
        #expect(await jsonAccepts(leadingEntry, "[0, 2]"))
        #expect(!(await jsonAccepts(leadingEntry, "[0, 3]")))

        #expect(await jsonAccepts(soleEntry, "[1]"))
        #expect(await jsonAccepts(soleEntry, "[2]"))
        #expect(!(await jsonAccepts(soleEntry, "[3]")))
    }

    /// With more than two alternatives, the one that matches may be neither the
    /// first nor the last.
    @Test func validateGroupChoiceWithMatchingMiddleAlternative() async {
        let ascending = """
            x = [aa // bb // cc]
            aa = (0, [uint])
            bb = (1, [tstr])
            cc = (2, [bool])
            """
        let descending = """
            x = [cc // bb // aa]
            aa = (0, [uint])
            bb = (1, [tstr])
            cc = (2, [bool])
            """
        for cddl in [ascending, descending] {
            #expect(await jsonAccepts(cddl, "[0, [1]]"))
            #expect(await jsonAccepts(cddl, #"[1, ["s"]]"#))
            #expect(await jsonAccepts(cddl, "[2, [true]]"))
            #expect(!(await jsonAccepts(cddl, "[1, [1]]")))
        }
    }

    /// A rule's own definition and the alternatives `/=` adds to it are
    /// alternatives of one choice.
    @Test func validateTypeChoiceAlternateBesideTheRuleDefinition() async {
        let cddl = """
            x = [t]
            t = uint
            t /= tstr
            """
        #expect(await jsonAccepts(cddl, "[1]"))
        #expect(await jsonAccepts(cddl, #"["a"]"#))
        #expect(!(await jsonAccepts(cddl, "[true]")))
    }

    /// Every `//=` alternate is evaluated from the state the entry was reached
    /// with.
    @Test func validateGroupChoiceAlternateBeyondTheFirst() async {
        let cddl = """
            tester = [$$val]
            $$val //= (type: 10, data: uint)
            $$val //= (type: 11, data: tstr)
            """
        #expect(await jsonAccepts(cddl, "[10, 1]"))
        #expect(await jsonAccepts(cddl, #"[11, "t"]"#))
        #expect(!(await jsonAccepts(cddl, "[12, 1]")))
        #expect(!(await jsonAccepts(cddl, #"[10, "t"]"#)))
        #expect(!(await jsonAccepts(cddl, "[11, 1]")))
    }

    /// An entry marked `?` may be absent, in which case the entries after it
    /// match the items one position earlier.
    @Test func validateGroupChoiceWithAbsentOptionalEntry() async {
        #expect(
            await jsonAccepts("x = [ (? uint, tstr) // (bool, bool) ]", #"["z"]"#),
            "the optional entry is absent and `tstr` matches the sole item")
    }

    /// Wrapping a group choice in parentheses, or behind a group rule, does not
    /// change what it describes.
    @Test func validateGroupChoiceArityThroughAWrappingGroup() async {
        let parenthesized = "x = [ ( (0, uint) // (4, uint, uint) ) ]"
        let throughRule = """
            x = [g]
            g = ( (0, uint) // (4, uint, uint) )
            """
        let flat = "x = [ (0, uint) // (4, uint, uint) ]"
        for cddl in [parenthesized, throughRule, flat] {
            #expect(await jsonAccepts(cddl, "[0, 8]"), "\(cddl)")
            #expect(await jsonAccepts(cddl, "[4, 8, 9]"), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, "[0, 8, 9]")), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[0, 8, "junk"]"#)), "\(cddl)")
        }
    }

    /// A group socket is defined by its plugs, each an alternative accounting
    /// for the items its own entries do.
    @Test func validateSocketGroupChoiceAlternateArity() async {
        let cddl = """
            x = [ $$s ]
            $$s //= (0, uint)
            $$s //= (1, tstr, tstr)
            """
        #expect(await jsonAccepts(cddl, "[0, 5]"))
        #expect(await jsonAccepts(cddl, #"[1, "a", "b"]"#))
        #expect(!(await jsonAccepts(cddl, "[0, 5, 6]")), "no plug accounts for three items beginning with 0")
        #expect(!(await jsonAccepts(cddl, "[1, 5, 6]")))
    }

    /// A group rule assigned with `=` and extended with `//=` gains an
    /// alternative with its own arity.
    @Test func validateGroupChoiceAlternateExtendingADefinedRule() async {
        let cddl = """
            x = [g]
            g = (0, uint)
            g //= (4, uint, uint)
            """
        #expect(await jsonAccepts(cddl, "[0, 1]"))
        #expect(await jsonAccepts(cddl, "[4, 1, 2]"))
        #expect(!(await jsonAccepts(cddl, "[4, 1]")))
        #expect(!(await jsonAccepts(cddl, "[0, 1, 2]")))
    }

    /// An alternative whose entries are a nested group choice followed by
    /// further entries accounts for the items of both.
    @Test func validateGroupChoiceNestedAheadOfFurtherEntries() async {
        let inline = "x = [ ( ((0)//(1)), tstr, tstr ) // (uint, uint, uint) ]"
        let throughRule = """
            x = [ (disc, tstr, tstr) // (uint, uint, uint) ]
            disc = ( (0) // (1) )
            """
        for cddl in [inline, throughRule] {
            #expect(await jsonAccepts(cddl, #"[0, "a", "b"]"#), "\(cddl)")
            #expect(await jsonAccepts(cddl, #"[1, "a", "b"]"#), "\(cddl)")
            #expect(await jsonAccepts(cddl, "[1, 2, 3]"), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[5, "a", "b"]"#)), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[0, "a", 9]"#)), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[0, "a"]"#)), "\(cddl)")
        }
    }

    /// The entries before a nested group choice account for the items before
    /// it.
    @Test func validateGroupChoiceFollowingALeadingEntry() async {
        let cddl = "x = [ tstr, ( (0) // (1, uint) ) ]"
        #expect(await jsonAccepts(cddl, #"["a", 0]"#))
        #expect(await jsonAccepts(cddl, #"["a", 1, 5]"#))
        #expect(!(await jsonAccepts(cddl, #"["a", 0, 5]"#)), "no alternative accounts for two items after the leading one")
    }

    /// An alternative with no entries accounts for no items.
    @Test func validateGroupChoiceWithEmptyAlternative() async {
        for cddl in ["x = [ () // (uint) ]", "x = [ (uint) // () ]"] {
            #expect(await jsonAccepts(cddl, "[]"), "\(cddl)")
            #expect(await jsonAccepts(cddl, "[1]"), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"["a"]"#)), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, "[1, 2]")), "\(cddl)")
        }

        // The same holds where a sibling alternative stands for a run of items
        // of a length the group does not state.
        for cddl in ["x = [ (* uint) // () ]", "x = [ () // (* uint) ]"] {
            #expect(await jsonAccepts(cddl, "[]"), "\(cddl)")
            #expect(await jsonAccepts(cddl, "[1, 2]"), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"["a", "b"]"#)), "\(cddl)")
        }
    }

    /// A choice under an occurrence indicator covering more than one
    /// occurrence matches as many times as its alternatives go.
    @Test func validateRepeatedMapGroupChoice() async {
        let cddl = "x = { * ( a: uint // b: tstr ) }"
        #expect(await jsonAccepts(cddl, "{}"))
        #expect(await jsonAccepts(cddl, #"{"a": 1}"#))
        #expect(await jsonAccepts(cddl, #"{"b": "z"}"#))
        #expect(await jsonAccepts(cddl, #"{"a": 1, "b": "z"}"#))

        #expect(!(await jsonAccepts(cddl, #"{"a": "z"}"#)), "the value under `a` is not a uint")
        #expect(!(await jsonAccepts(cddl, #"{"b": 5}"#)), "the value under `b` is not a tstr")
        #expect(!(await jsonAccepts(cddl, #"{"q": 1}"#)), "no alternative names the key `q`")

        // `+` is the same choice repeated, and requires at least one match.
        let atLeastOnce = "x = { + ( a: uint // b: tstr ) }"
        #expect(!(await jsonAccepts(atLeastOnce, "{}")))
        #expect(await jsonAccepts(atLeastOnce, #"{"a": 1}"#))
    }

    /// An entry of an array group describes the item at its own position.
    @Test func validateArrayEntryAnswersForTheItemAtItsPosition() async {
        let cddl = "x = [[? uint, ? tstr]]"
        #expect(await jsonAccepts(cddl, "[[]]"))
        #expect(await jsonAccepts(cddl, "[[1]]"))
        #expect(await jsonAccepts(cddl, #"[[1, "a"]]"#))
        #expect(!(await jsonAccepts(cddl, "[1]")), "the sole item is not an array")
        #expect(!(await jsonAccepts(cddl, #"["a"]"#)))
    }

    /// An object admits only the members its group names.
    @Test func validateMapRejectsEntriesNoGroupEntryNames() async {
        let cddl = "x = { ? a: uint }"
        #expect(await jsonAccepts(cddl, "{}"))
        #expect(await jsonAccepts(cddl, #"{"a": 1}"#))
        #expect(!(await jsonAccepts(cddl, #"{"b": 1}"#)))
    }

    /// Recursion that steps into nested data terminates on the data and is
    /// validated at every level.
    @Test func validateOptionalRecursiveTail() async {
        let cddl = "a = [int, ? a]\n"
        #expect(await jsonAccepts(cddl, "[1]"))
        #expect(await jsonAccepts(cddl, "[1, [2]]"))
        #expect(await jsonAccepts(cddl, "[1, [2, [3]]]"))
        #expect(!(await jsonAccepts(cddl, #"[1, [2, ["x"]]]"#)))

        let mutual = "a = [int, ? b]\nb = [int, ? a]\n"
        #expect(await jsonAccepts(mutual, "[1]"))
        #expect(await jsonAccepts(mutual, "[1, [2]]"))
        #expect(await jsonAccepts(mutual, "[1, [2, [3]]]"))
        #expect(!(await jsonAccepts(mutual, #"[1, [2, ["x"]]]"#)))
    }

    /// A rule re-entered against the same value denotes no type at all.
    @Test func validateRuleCycleIsAnError() async {
        #expect(!(await jsonAccepts("x = x\n", "1")))
        #expect(!(await jsonAccepts("a = b\nb = a\n", "1")))
        #expect(!(await jsonAccepts("top = [a]\na = b\nb = a\n", "[1]")))

        // A cycle in an alternative that loses does not reject a document the
        // winning alternative matches.
        #expect(await jsonAccepts("a = int / b\nb = a\n", "1"))
        #expect(await jsonAccepts("a = b / int\nb = a\n", "1"))
    }

    /// Every level of a recursive rule is validated.
    @Test func validateRecursionUnderAHomogeneousOccurrence() async {
        let cddl = "data = int / tstr / [* data]\n"
        #expect(await jsonAccepts(cddl, "[[1]]"))
        #expect(await jsonAccepts(cddl, #"[[1, "a"], 2]"#))
        #expect(!(await jsonAccepts(cddl, "[3.14]")))
        #expect(!(await jsonAccepts(cddl, "[[3.14]]")))
        #expect(!(await jsonAccepts(cddl, "[[[3.14]]]")))

        let list = "list = [int, next]\nnext = list / null\n"
        #expect(await jsonAccepts(list, "[1, [2, null]]"))
        #expect(!(await jsonAccepts(list, "[1, [2, 3.14]]")))
    }

    /// A group entry that names a rule is one entry like any other.
    @Test func validateArrayLengthForEntriesThatNameARule() async {
        let one = "a = [b]\nb = uint\n"
        #expect(await jsonAccepts(one, "[1]"))
        #expect(!(await jsonAccepts(one, "[1, 2]")))

        let three = "a = [b, c, d]\nb = int\nc = tstr\nd = bool\n"
        #expect(await jsonAccepts(three, #"[1, "x", true]"#))
        #expect(!(await jsonAccepts(three, #"[1, "x", true, 9]"#)))

        let choice = "a = [b] / [c, d]\nb = int\nc = int\nd = tstr\n"
        #expect(await jsonAccepts(choice, "[1]"))
        #expect(!(await jsonAccepts(choice, "[1, 2]")))

        for cddl in ["a = [int, ? b]\nb = tstr\n", "a = [int, ? tstr]\n"] {
            #expect(await jsonAccepts(cddl, "[1]"), "\(cddl)")
            #expect(await jsonAccepts(cddl, #"[1, "a"]"#), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[1, "a", "b"]"#)), "\(cddl)")
        }
    }

    /// An entry under an occurrence indicator stands for the run of items
    /// starting at its own position.
    @Test func validateEntryCoveringSeveralItems() async {
        for cddl in ["a = [int, 2*3 b]\nb = tstr\n", "a = [int, 2*3 tstr]\n"] {
            #expect(!(await jsonAccepts(cddl, #"[1, "x"]"#)), "\(cddl)")
            #expect(await jsonAccepts(cddl, #"[1, "x", "y"]"#), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"[1, "x", 2]"#)), "\(cddl)")
        }

        let withHeader = """
            with-header = [header, * row]
            header = [tstr, tstr]
            row = [tstr, uint]
            """
        #expect(await jsonAccepts(withHeader, #"[["name", "score"], ["a", 100], ["b", 95]]"#))
        #expect(!(await jsonAccepts(withHeader, #"[["name", "score"], ["a", "x"]]"#)))
    }

    /// A generic argument naming a parameter of the rule being evaluated
    /// denotes what that parameter is bound to, and a generic rule defined in
    /// terms of itself is a cycle.
    @Test func validateGenericArguments() async {
        let cddl = """
            top = p<int>
            p<T> = [* q<T>]
            q<T> = [T]
            """
        #expect(await jsonAccepts(cddl, "[[1]]"))
        #expect(!(await jsonAccepts(cddl, #"[["x"]]"#)))

        #expect(!(await jsonAccepts("x = a<int>\na<T> = a<T>\n", "1")))
        #expect(!(await jsonAccepts("x = a<int>\na<T> = b<T>\nb<T> = a<T>\n", "1")))
    }

    /// An alternative of a type choice fails on its content like any other.
    @Test func validateObjectAlternativeOfATypeChoice() async {
        for cddl in ["p = {a: int} / tstr", "p = tstr / {a: int}"] {
            #expect(!(await jsonAccepts(cddl, #"{"a": true}"#)), "\(cddl)")
            #expect(await jsonAccepts(cddl, #"{"a": 1}"#), "\(cddl)")
            #expect(await jsonAccepts(cddl, #""z""#), "\(cddl)")
        }
        #expect(!(await jsonAccepts("p = {0: {a: int} / tstr}", #"{"0": {"a": true}}"#)))
    }

    /// An array alternative records its failures per item, and must be judged
    /// failed all the same.
    @Test func validateArrayAlternativeOfATypeChoiceFailingOnAnItem() async {
        for cddl in ["p = [int] / tstr", "p = tstr / [int]", "p = [* int] / tstr"] {
            #expect(!(await jsonAccepts(cddl, "[true]")), "\(cddl)")
            #expect(await jsonAccepts(cddl, "[1]"), "\(cddl)")
            #expect(await jsonAccepts(cddl, #""q""#), "\(cddl)")
        }
    }

    /// Outside member key position a type name describes the value itself,
    /// and an object is not a value of any of those types.
    @Test func validateTypeNameDoesNotMatchAnObjectOutsideMemberKeyPosition() async {
        for name in ["tstr", "int", "uint", "bool", "nil", "float"] {
            #expect(!(await jsonAccepts("p = \(name)", #"{"a": 1}"#)), "\(name)")
        }
        #expect(!(await jsonAccepts("p = [tstr]", #"[{"a": 1}]"#)))

        // A member key keyed by a type still matches the names of the object.
        #expect(await jsonAccepts("p = {* tstr => int}", #"{"a": 1}"#))
        #expect(!(await jsonAccepts("p = {* tstr => tstr}", #"{"a": 1}"#)))
        #expect(await jsonAccepts("p = {a: int}", #"{"a": 1}"#))
    }

    /// A range in member key position denotes the names the entry answers for;
    /// a member name is a string, so none lies in a range.
    @Test func validateObjectRangeMemberKey() async {
        #expect(await jsonAccepts("p = {* 3..255 => int}", "{}"))

        #expect(!(await jsonAccepts("p = {* 3..255 => int}", #"{"3": 1}"#)))
        #expect(!(await jsonAccepts("p = {* 3..255 => int}", #"{"2": 1}"#)))

        #expect(!(await jsonAccepts("p = {3..255 => int}", "{}")))
        #expect(!(await jsonAccepts("p = {3..255 => int}", #"{"3": 1}"#)))
        #expect(!(await jsonAccepts("p = {+ 3..255 => int}", "{}")))

        for cddl in ["p = {? a: int, * 3..255 => int}", "p = {* 3..255 => int, ? a: int}"] {
            #expect(await jsonAccepts(cddl, "{}"), "\(cddl)")
            #expect(await jsonAccepts(cddl, #"{"a": 1}"#), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"{"a": "x"}"#)), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"{"a": 1, "3": 2}"#)), "\(cddl)")
        }
    }

    /// A range reaches member key position written out, parenthesized, or
    /// under a name standing for one.
    @Test func validateObjectRangeMemberKeyWrittenIndirectly() async {
        for cddl in [
            "p = {* 3..255 => int}",
            "p = {* (3..255) => int}",
            "p = {* r => int}\nr = 3..255",
            "p = {* r => int}\nr = (s)\ns = 3..255",
            "p = {* lo..hi => int}\nlo = 3\nhi = 255",
        ] {
            #expect(await jsonAccepts(cddl, "{}"), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, #"{"3": 1}"#)), "\(cddl)")
        }
        #expect(!(await jsonAccepts("p = {* r => int}\nr = r", #"{"3": 1}"#)))
    }

    /// A name in member key position states the type of the names the entry
    /// answers for, so it is held to the names of the object one at a time.
    @Test func validateObjectNamedMemberKeyMatchesKeys() async {
        let cddl = "m = {* k => int}\nk = tstr"
        for json in ["{}", #"{"x":1}"#, #"{"x":1,"y":2}"#] {
            await expectJSONValid(cddl, json)
        }
        for json in [#"{"x":"y"}"#, #"{"x":1,"y":"z"}"#] {
            await expectJSONInvalid(cddl, json)
        }

        await expectJSONValid("m = {k => int}\nk = tstr", #"{"x":1}"#)
        await expectJSONInvalid("m = {k => int}\nk = tstr", "{}")
        await expectJSONInvalid("m = {k => int}\nk = tstr", #"{"x":1,"y":2}"#)

        await expectJSONValid("m = {? k => int}\nk = tstr", "{}")
        await expectJSONValid("m = {+ k => int}\nk = tstr", #"{"x":1}"#)
        await expectJSONInvalid("m = {+ k => int}\nk = tstr", "{}")

        await expectJSONValid("m = {2*3 k => int}\nk = tstr", #"{"x":1,"y":2}"#)
        await expectJSONInvalid("m = {2*3 k => int}\nk = tstr", #"{"x":1}"#)
    }

    /// An object type whose names and values are the type the object is
    /// itself an alternative of describes a document that nests.
    @Test func validateSelfReferentialObjectType() async {
        let cddl = """
            start = p
            p = {* p => p} / int / tstr
            """
        for json in ["{}", "1", #""x""#, #"{"k":1}"#, #"{"k":{"j":"v"}}"#, #"{"k":1,"j":{"i":2}}"#] {
            await expectJSONValid(cddl, json)
        }
        for json in ["true", "null", #"{"k":null}"#, #"{"k":{"j":true}}"#] {
            await expectJSONInvalid(cddl, json)
        }
    }

    /// A member key written as a bareword is shorthand for the text string of
    /// that name (RFC 8610 Section 3.5.1).
    @Test func validateObjectBarewordMemberKeyIsTheNameItself() async {
        for cddl in ["m = {k: int}\nk = tstr", "m = {? k: int}\nk = tstr", "m = {* k: int}\nk = tstr"] {
            await expectJSONValid(cddl, #"{"k":1}"#)
            await expectJSONInvalid(cddl, #"{"x":1}"#)
        }

        // A bareword carrying the name of a type of the standard prelude is
        // that text string too.
        await expectJSONValid("m = {tstr: int}", #"{"tstr":1}"#)
        await expectJSONInvalid("m = {tstr: int}", #"{"x":1}"#)

        // The arrow form of the same name is the type it stands for.
        await expectJSONValid("m = {k => int}\nk = tstr", #"{"x":1}"#)
    }

    /// A group choice whose alternatives each descend into the same nested
    /// data must not re-examine that data once per alternative.
    @Test func validateFailingGroupChoiceDoesNotReExamineNestedDataPerAlternative() async {
        let cddl = """
            nested = [leaf // all // any]
            leaf = (0, tstr)
            all = (1, [* nested])
            any = (2, [* nested])
            """
        let depth = 12
        var json = "[0,0]"
        for _ in 0..<depth {
            json = "[1,[\(json)]]"
        }
        let reported = jsonIssues(await jsonResult(cddl, json))
        #expect(
            reported.count < 16 * depth,
            "walked the document \(reported.count) times over, which is more than the nesting admits")
    }

    /// Stopping a failed alternative early must not stop the choice from
    /// reaching the alternative that matches.
    @Test func validateGroupChoiceStillReachesALaterMatchingAlternative() async {
        let cddl = """
            nested = [leaf // all // any]
            leaf = (0, tstr)
            all = (1, [* nested])
            any = (2, [* nested])
            """
        await expectJSONValid(cddl, #"[0,"x"]"#)
        await expectJSONValid(cddl, #"[1,[[2,[[0,"x"]]]]]"#)
        await expectJSONInvalid(cddl, "[1,[[2,[[0,0]]]]]")
    }

    /// A group with one alternative is not one way of matching among several,
    /// so every failing entry is reported.
    @Test func validateSingleAlternativeGroupReportsEveryFailingEntry() async {
        #expect(jsonIssues(await jsonResult("a = [uint, tstr, bool]", #"["x",1,"y"]"#)).count == 3)
    }

    /// RFC 8610 Appendix C: a name that denotes a group is inlined, and a name
    /// that denotes a type stands for a single item.
    @Test func arrayEntryNameIsInlinedOnlyWhenItDenotesAGroup() async {
        let group = "arr = [pair, pair]\npair = (int, text)"
        #expect(await jsonAccepts(group, #"[1, "a", 2, "b"]"#))
        #expect(!(await jsonAccepts(group, #"[1, "a"]"#)))

        let type = "arr = [*cap]\ncap = {}"
        #expect(await jsonAccepts(type, "[{}, {}]"))
        #expect(!(await jsonAccepts(type, "[1]")))
    }
}
