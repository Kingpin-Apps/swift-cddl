import Testing

@testable import SwiftCDDL

// A deeply nested schema is parsed on a thread with a large stack; dropping
// its AST must not overflow the smaller stack of the thread that drops it.

private let shapes: [String: (open: String, inner: String, close: String)] = [
    "array": ("[", "int", "]"),
    "parenthesised type": ("(", "int", ")"),
    "map": ("{ k: ", "int", " }"),
    "arrow map": ("{ \"k\" => ", "int", " }"),
    "choice": ("[ int / ", "int", " ]"),
    "tag": ("#6.1(", "int", ")"),
]

private func deepSource(_ shape: String, depth: Int) -> String {
    let (open, inner, close) = shapes[shape]!
    return "a = " + String(repeating: open, count: depth) + inner + String(repeating: close, count: depth) + "\n"
}

@Suite struct DeepASTTests {
    @Test(arguments: ["array", "parenthesised type", "map", "arrow map", "choice", "tag"])
    func aDeepSchemaParsesAndDropsInsideATask(shape: String) async {
        let source = deepSource(shape, depth: 5000)
        let parsed = await Task.detached { () -> Bool in
            do {
                let cddl = try cddlFromStr(source)
                return cddl.rules.count == 1
            } catch {
                return false
            }
        }.value
        #expect(parsed)
    }

    @Test func aCopyOfADeepDocumentOutlivesTheOriginal() async {
        let source = deepSource("array", depth: 5000)
        let kept = await Task.detached { () -> Int in
            var copies: [CDDL] = []
            for _ in 0..<3 {
                guard let cddl = try? cddlFromStr(source) else { return -1 }
                copies.append(cddl)
            }
            var edited = copies[0]
            edited.comments = Comments(["edited"])
            copies.removeAll()
            return edited.rules.count
        }.value
        #expect(kept == 1)
    }

    @Test func bracketNestingIgnoresArrowsStringsAndComments() {
        #expect(bracketNesting(Array("a = { b => [ c ] } ; ((((\n".utf8)) == 2)
        #expect(bracketNesting(Array("a = \"[[[\" / h'(('\n".utf8)) == 0)
        #expect(bracketNesting(Array("a<t> = [ t ]\n".utf8)) == 1)
    }
}
