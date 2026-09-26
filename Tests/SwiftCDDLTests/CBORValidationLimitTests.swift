import Testing

@testable import SwiftCDDL

/// `levels` single-element arrays around the integer 1, encoded.
private func nestedArrayBytes(_ levels: Int) -> [UInt8] {
    [UInt8](repeating: 0x81, count: levels) + [0x01]
}

/// `payloads` byte strings each carrying the next, around the integer 5,
/// encoded.
private func nestedPayloadBytes(_ payloads: Int) -> [UInt8] {
    var payload: [UInt8] = [0x05]
    for _ in 0..<payloads {
        var wrapped: [UInt8]
        switch payload.count {
        case let n where n < 24:
            wrapped = [0x40 | UInt8(n)]
        case let n where n < 256:
            wrapped = [0x58, UInt8(n)]
        case let n:
            wrapped = [0x59, UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
        }
        wrapped.append(contentsOf: payload)
        payload = wrapped
    }
    return payload
}

/// The failure of validating `bytes` against `cddl` under `limits`, or `nil`
/// on a match.
private func limitedVerdict(_ cddl: String, _ bytes: [UInt8], _ limits: ValidationLimits) async -> CBORValidationError? {
    do {
        try await validateCBOR(cddl: cddl, cbor: bytes, limits: limits)
        return nil
    } catch {
        return error
    }
}

/// The rendered failure of validating `bytes`, expected to be a failure;
/// empty when the document matched.
private func failureText(
    _ cddl: String,
    _ bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) async -> String {
    guard let error = await expectInvalid(cddl, bytes, sourceLocation: sourceLocation) else { return "" }
    return error.description
}

/// Whether `verdict` is the failure of a schema that did not parse.
private func isSchemaParseFailure(_ verdict: CBORValidationError?) -> Bool {
    if case .cddlParsing = verdict {
        return true
    }
    return false
}

/// Validation under the implementation limits on nesting, rule references,
/// embedded payloads and report size, and the framing of the document as
/// exactly one well-formed data item (RFC 8949 Sections 1.2 and 5.3.1).
@Suite
struct CBORValidationLimitTests {
    /// Data nested past the supported depth is reported as exceeding that
    /// implementation limit rather than as a type mismatch.
    @Test func dataNestedPastTheSupportedDepthReportsTheLimit() async {
        let cddl = "data = int / [* data]"

        let deep = nestedArrayBytes(ValidationLimits.defaultMaxNestingDepth + 1)

        let message = await failureText(cddl, deep)
        #expect(message.contains("maximum supported nesting depth"), "got:\n\(message)")

        await expectValid(cddl, CBORNode.array([.array([.integer(1)])]).encoded())
    }

    /// How many payloads decoded out of the document may be open at once is
    /// bounded: a chain within the bound is walked to its leaf, one past it is
    /// refused as the limit it breaches, and the refusal is the whole report.
    @Test func aChainOfEmbeddedPayloadsIsBoundedByTheOpenPayloadLimit() async {
        let cddl = "a = bstr .cbor a / uint"

        let limits = ValidationLimits(maxEmbeddedDepth: 4)
        let withinVerdict = await limitedVerdict(cddl, nestedPayloadBytes(4), limits)
        #expect(withinVerdict == nil, "got \(withinVerdict.map { "\($0)" } ?? "")")

        let pastVerdict = await limitedVerdict(cddl, nestedPayloadBytes(5), limits)
        let errors = issues(pastVerdict)
        #expect(errors.count == 1, "\(errors)")
        #expect(
            errors.first?.reason.contains("maximum supported 4 open payloads") == true,
            "got:\n\(errors.first?.reason ?? "")")

        // The leaf is still held to the schema within the bound.
        var refused: [UInt8] = [0x60]
        for _ in 0..<4 {
            refused = [0x40 | UInt8(refused.count)] + refused
        }
        let refusedVerdict = await limitedVerdict(cddl, refused, limits)
        #expect(refusedVerdict != nil, "the leaf is a text string")
        #expect(
            refusedVerdict?.description.contains("open payloads") == false,
            "got:\n\(refusedVerdict.map { "\($0)" } ?? "")")

        // The default admits as many as it states.
        await expectValid(cddl, nestedPayloadBytes(ValidationLimits.defaultMaxEmbeddedDepth))
        let message = await failureText(cddl, nestedPayloadBytes(ValidationLimits.defaultMaxEmbeddedDepth + 1))
        #expect(message.contains("open payloads"), "got:\n\(message)")
    }

    /// A choice records what every failing alternative reported at every
    /// level, so a document refused deep inside a recursive schema records on
    /// the order of its nesting in errors. The report keeps the innermost of
    /// them up to a cap, and a report within the cap is handed out whole.
    @Test func aReportKeepsTheInnermostErrorsUpToTheBudget() async throws {
        let cddl = "x = [* x] / uint"
        let schema = try cddlFromStr(cddl)

        func refused(_ levels: Int) -> [UInt8] {
            [UInt8](repeating: 0x81, count: levels) + [0x60]
        }
        func errors(_ levels: Int, _ limits: ValidationLimits? = nil) async throws -> [CBORValidationIssue] {
            let validator = CBORValidator(cddl: schema, cbor: try decodeCBOR(refused(levels)))
            if let limits {
                validator.setLimits(limits)
            }
            do {
                try await validator.validate()
            } catch {
                return issues(error)
            }
            return issues(nil)
        }
        func rendered(_ errors: some Collection<CBORValidationIssue>) -> Int {
            errors.reduce(0) { $0 + $1.reason.utf8.count + $1.cborLocation.utf8.count }
        }
        func zeros(_ count: Int) -> String {
            String(repeating: "/0", count: count)
        }

        // Two mismatches at the leaf, and one at every level above it.
        let shallow = try await errors(10)
        #expect(shallow.count == 12)
        #expect(shallow.first?.cborLocation == zeros(10))

        // The whole report, when it fits.
        let deep = try await errors(600)
        #expect(deep.count == 602)
        #expect(rendered(deep) <= ValidationLimits.defaultMaxReportBytes)

        // Past the budget, the innermost errors are kept: the leaf's two and the
        // levels nearest it, in the order they were recorded.
        try #require(deep.count >= 40)
        let budget = rendered(deep[..<40])
        let kept = try await errors(600, ValidationLimits(maxReportBytes: budget))
        #expect(kept.count == 40, "\(rendered(kept))")
        #expect(rendered(kept) <= budget)
        #expect(kept.first?.cborLocation == zeros(600), "the leaf comes first")
        #expect(kept.allSatisfy { $0.cborLocation.utf8.count / 2 >= 600 - 38 }, "only the innermost are kept")
        // The leaf's two mismatches, then each level above in the order the
        // walk unwound through them.
        var ordered = true
        if kept.count > 2 {
            for index in 1..<(kept.count - 1)
            where kept[index].cborLocation.utf8.count < kept[index + 1].cborLocation.utf8.count {
                ordered = false
            }
        }
        #expect(ordered, "recorded order kept")

        // Too small for even one: the innermost is handed out all the same.
        let one = try await errors(600, ValidationLimits(maxReportBytes: 1))
        #expect(one.count == 1)
        #expect(one.first?.cborLocation == zeros(600))
    }

    /// The bounds validation runs under can be stated at the entry point.
    @Test func validateCborFromSliceUnderStatedLimits() async {
        let cddl = "data = int / [* data]"

        let pastTheDefault = nestedArrayBytes(ValidationLimits.defaultMaxNestingDepth + 1)

        // At the default the data is reported as exceeding the bound.
        let message = await failureText(cddl, pastTheDefault)
        #expect(message.contains("maximum supported nesting depth"), "got:\n\(message)")

        // Stating a bound the data fits within admits it.
        let raised = ValidationLimits(maxNestingDepth: ValidationLimits.defaultMaxNestingDepth + 8)
        var verdict = await limitedVerdict(cddl, pastTheDefault, raised)
        #expect(verdict == nil, "got \(verdict.map { "\($0)" } ?? "")")

        // Raising the other bound says nothing about how deeply data may nest.
        verdict = await limitedVerdict(cddl, pastTheDefault, ValidationLimits(maxRuleNesting: 1024))
        #expect(verdict != nil, "the rule bound does not admit more deeply nested data")
        #expect(
            verdict?.description.contains("maximum supported nesting depth") == true,
            "got:\n\(verdict.map { "\($0)" } ?? "")")

        // A raised bound validates what lies below it rather than admitting it.
        let invalid = [UInt8](repeating: 0x81, count: ValidationLimits.defaultMaxNestingDepth + 1) + [0xf5]
        verdict = await limitedVerdict(cddl, invalid, raised)
        #expect(verdict != nil, "the leaf is not an int")
        #expect(
            verdict?.description.contains("maximum supported nesting depth") == false,
            "got:\n\(verdict.map { "\($0)" } ?? "")")

        // Data within the default bound needs no limits stated for it.
        await expectValid(cddl, nestedArrayBytes(2))
    }

    /// A chain of rule references is bounded the same way and is settable at
    /// the entry point as well.
    @Test func validateCborFromSliceUnderAStatedRuleNestingLimit() async {
        func chain(_ links: Int) -> String {
            var cddl = "start = r0\n"
            for index in 0..<links {
                cddl += "r\(index) = r\(index + 1)\n"
            }
            cddl += "r\(links) = int\n"
            return cddl
        }

        let longChain = chain(ValidationLimits.defaultMaxRuleNesting + 4)
        let value = CBORNode.integer(1).encoded()

        let message = await failureText(longChain, value)
        #expect(message.contains("maximum supported rule nesting"), "got:\n\(message)")

        let raised = ValidationLimits(maxRuleNesting: ValidationLimits.defaultMaxRuleNesting + 16)
        var verdict = await limitedVerdict(longChain, value, raised)
        #expect(verdict == nil, "got \(verdict.map { "\($0)" } ?? "")")

        // Both bounds can be stated together.
        var both = ValidationLimits()
        both.maxRuleNesting = ValidationLimits.defaultMaxRuleNesting + 16
        both.maxNestingDepth = ValidationLimits.defaultMaxNestingDepth + 8
        verdict = await limitedVerdict(longChain, value, both)
        #expect(verdict == nil, "got \(verdict.map { "\($0)" } ?? "")")

        // The chain resolving does not stop the type at its end being applied.
        verdict = await limitedVerdict(longChain, CBORNode.text("x").encoded(), raised)
        #expect(verdict != nil, "the data is not an int")
        #expect(
            verdict?.description.contains("maximum supported rule nesting") == false,
            "got:\n\(verdict.map { "\($0)" } ?? "")")
    }

    /// Reaching a bound says nothing below the point it was reached was
    /// examined, so it is reported once and validation stops there.
    @Test func breachingALimitReportsItOnceAndStops() async {
        let cddl = """
            data = leaf / wrapper / pair / tagged
            leaf = int
            wrapper = [data]
            pair = [data, data]
            tagged = #6.24([data])

            """

        let value = nestedArrayBytes(ValidationLimits.defaultMaxNestingDepth + 4)

        var errors = issues(await expectInvalid(cddl, value))

        #expect(errors.count == 1, "the breach is the whole report, got:\n\(errors)")
        #expect(
            errors.first?.reason.contains("maximum supported nesting depth") == true,
            "got:\n\(errors.first?.reason ?? "")")

        // The same schema still accumulates the mismatches of a document it can
        // walk in full.
        errors = issues(await expectInvalid(cddl, CBORNode.array([.text("x")]).encoded()))
        #expect(errors.count > 1, "every alternative of the choice reports, got:\n\(errors)")
    }

    /// A well-formed data item takes no following extraneous data (RFC 8949
    /// Section 1.2), so a document carrying bytes after it is refused.
    @Test func validateRejectsBytesAfterTheTopLevelDataItem() async {
        let cases: [(String, [UInt8], Int)] = [
            ("start = uint", [0x05, 0x06], 1),
            ("start = [int]", [0x81, 0x01, 0xff], 1),
            ("start = uint", [0x05, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff], 6),
            // The item ends where its declared length says it does.
            ("start = bstr", [0x42, 0x01, 0x02, 0x03], 1),
            // Including an indefinite-length item closed by a break.
            ("start = [int]", [0x9f, 0x01, 0xff, 0x02], 1),
        ]
        for (cddl, document, trailing) in cases {
            let message = await failureText(cddl, document)
            #expect(
                message.contains("trailing byte") && message.contains("\(trailing)"),
                "\(cddl): the message must name how many bytes were left over, got:\n\(message)")
        }
    }

    /// A document that is exactly one data item validates.
    @Test func validateAdmitsADocumentThatIsExactlyOneDataItem() async {
        let cases: [(String, [UInt8])] = [
            ("start = uint", [0x05]),
            ("start = [int]", [0x81, 0x01]),
            ("start = [int]", [0x9f, 0x01, 0xff]),
            ("start = bstr", [0x42, 0x01, 0x02]),
            ("start = bstr", [0x5f, 0x41, 0x01, 0xff]),
            ("start = {int => int}", [0xa1, 0x01, 0x02]),
        ]
        for (cddl, document) in cases {
            await expectValid(cddl, document)
        }
    }

    /// `.cbor` says the byte string carries one data item (RFC 8610 Section
    /// 3.8.4), so bytes past it make the payload wrong for `.cbor`.
    @Test func validateEmbeddedCborRejectsBytesAfterThePayloadItem() async {
        // h'0506': a uint followed by a byte that is not part of it.
        let bytes = CBORNode.bytes([0x05, 0x06]).encoded()

        let message = await failureText("start = bstr .cbor uint", bytes)
        #expect(message.contains("trailing byte"), "got:\n\(message)")

        // The same payload read as the sequence it is.
        await expectValid("start = bstr .cborseq [uint, uint]", bytes)

        // A payload of exactly one item matches `.cbor`.
        await expectValid("start = bstr .cbor uint", CBORNode.bytes([0x05]).encoded())
    }

    /// A CBOR sequence is zero or more whole data items (RFC 8742); a
    /// truncated item is not dropped.
    @Test func validateEmbeddedCborseqRejectsATruncatedItem() async {
        for payload: [UInt8] in [
            // A uint, then an array head whose element is missing.
            [0x01, 0x81],
            // A byte string shorter than its declared length.
            [0x01, 0x43, 0x01],
            // An indefinite-length array with no break.
            [0x01, 0x9f, 0x01],
        ] {
            let verdict = await cborResult("start = bstr .cborseq [* any]", CBORNode.bytes(payload).encoded())
            #expect(verdict != nil, "a truncated item must not be dropped: \(payload)")
        }

        // The whole version of the first of those is admitted.
        await expectValid("start = bstr .cborseq [uint, [uint]]", CBORNode.bytes([0x01, 0x81, 0x02]).encoded())
    }

    /// A document that did not decode and a schema that did not parse are
    /// separate faults, each reported as itself.
    @Test func documentThatDidNotDecodeIsReportedApartFromASchemaThatDidNotParse() async {
        // (schema, a document that does not decode, the whole document it is a
        // damaged form of)
        let cases: [(String, [UInt8], [UInt8])] = [
            // Additional information 28 is reserved (RFC 8949 Section 3).
            ("start = uint", [0x1c], [0x00]),
            // A break outside any indefinite-length container.
            ("start = uint", [0xff], [0x01]),
            // An array head promising two elements, one of them present.
            ("start = [int, int]", [0x82, 0x01], [0x82, 0x01, 0x02]),
            // A text string shorter than its declared length.
            ("start = tstr", [0x63, 0x61, 0x62], [0x63, 0x61, 0x62, 0x63]),
            // Bytes after the data item.
            ("start = uint", [0x05, 0x06], [0x05]),
        ]
        for (cddl, malformed, whole) in cases {
            let verdict = await expectInvalid(cddl, malformed)
            guard case .cborDecoding = verdict else {
                Issue.record(
                    "\(cddl): a document that did not decode was reported as \(verdict.map { "\($0)" } ?? "a match")")
                continue
            }
            let message = verdict?.description ?? ""
            #expect(
                message.hasPrefix("error decoding CBOR document: "),
                "\(cddl): the message must name the document, got:\n\(message)")
            #expect(!message.contains("CDDL"), "\(cddl): the message must not name the schema, got:\n\(message)")

            // The whole document the malformed one was damaged from validates.
            await expectValid(cddl, whole)
        }
    }

    /// A schema that does not parse is reported as a schema fault, whatever
    /// the document is.
    @Test func schemaThatDidNotParseIsReportedAsASchemaFault() async {
        for broken in ["start = = uint", "start = [", "= uint"] {
            // A document that decodes, so only the schema is left to fail.
            var verdict = await expectInvalid(broken, [0x01])
            #expect(
                isSchemaParseFailure(verdict),
                "\(broken): a schema that did not parse was reported as \(verdict.map { "\($0)" } ?? "a match")")
            #expect(
                verdict?.description.hasPrefix("error parsing CDDL: ") == true,
                "\(broken): the message must name the schema, got:\n\(verdict.map { "\($0)" } ?? "")")

            // A document that does not decode against the same schema is still
            // reported as the schema fault, which is reached first.
            verdict = await expectInvalid(broken, [0x05, 0x06])
            #expect(isSchemaParseFailure(verdict), "\(broken): got \(verdict.map { "\($0)" } ?? "a match")")
        }

        // The same document under a schema that parses.
        await expectValid("start = uint", [0x01])
    }
}
