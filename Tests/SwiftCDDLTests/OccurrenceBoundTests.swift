import Testing

@testable import SwiftCDDL

// Occurrence bounds are 64-bit on every platform, and a bound larger than any
// collection can hold is a bound no collection reaches.

@Suite struct OccurrenceBoundTests {
    @Test func aBoundBeyondThe32BitRangeParses() throws {
        let cddl = try cddlFromStr("a = [ 5000000000*5000000001 int ]\n")
        #expect(cddl.description.contains("5000000000*5000000001 int"))
    }

    @Test func theLargestBoundsValidate() async {
        let schema = "a = [ 0*18446744073709551615 int ]\nb = { 18446744073709551615*18446744073709551615 tstr => int }\n"
        let document = try? CDDLDocument(schema)
        #expect(await document?.validate(json: "[1, 2, 3]").isValid == true)
        #expect(await document?.validate(json: #"{"x": 1}"#, rule: "b").isValid == false)
    }
}
