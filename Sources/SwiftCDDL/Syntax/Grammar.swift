// The CDDL grammar (RFC 8610 Appendix B, with the RFC 9682 updates), written
// out as recursive descent against `GrammarState`.
//
// Each function parses the rule of the same name. Rules are ordered choices
// of sequences, as in a PEG. Between the operands of a sequence in a
// non-atomic rule an implicit `skip()` runs over whitespace and comments;
// it is written out explicitly here, because it decides which spans take in
// trailing whitespace. The shared prefixes of `group_entry`'s and
// `tag_expr`'s alternatives are parsed once.
//
// `group_entry` tries a bare type before a member key, guarded by a
// lookahead for the `=>`/`:` delimiter, so that an entry that is not a member
// is parsed exactly once and nested arrays parse in time linear in their
// depth.

extension GrammarState {
    // MARK: - Implicit whitespace

    /// The implicit skip between sequence operands:
    /// `WHITESPACE* ~ (COMMENT ~ WHITESPACE*)*`, active only in non-atomic
    /// rules.
    func skip() -> Bool {
        guard atomicity == .nonAtomic else { return true }
        return sequence {
            repeatLoop { WHITESPACE() }
                && repeatLoop {
                    sequence { COMMENT() && repeatLoop { WHITESPACE() } }
                }
        }
    }

    /// `x*` in a non-atomic rule.
    @inline(__always)
    private func zeroOrMore(_ expr: () -> Bool) -> Bool {
        sequence {
            optional {
                expr() && repeatLoop { sequence { skip() && expr() } }
            }
        }
    }

    // MARK: - Entry point and whitespace

    /// `cddl = { SOI ~ S ~ (rule ~ S)* ~ EOI }`
    func cddl() -> Bool {
        rule(.cddl) {
            sequence {
                startOfInput() && skip() && S() && skip()
                    && zeroOrMore { sequence { rule_() && skip() && S() } }
                    && skip() && EOI()
            }
        }
    }

    /// The implicit end-of-input rule.
    func EOI() -> Bool {
        rule(.EOI) { pos == input.count }
    }

    /// `WHITESPACE = _{ " " | "\t" | "\r" | "\n" }`
    func WHITESPACE() -> Bool {
        atomic(.atomic) {
            matchString(" ") || matchString("\t") || matchString("\r") || matchString("\n")
        }
    }

    /// `COMMENT = { ";" ~ (!NEWLINE ~ ANY)* }` (implicitly atomic)
    func COMMENT() -> Bool {
        rule(.COMMENT) {
            atomic(.atomic) {
                sequence {
                    matchString(";")
                        && repeatLoop {
                            sequence { lookahead(false) { NEWLINE() } && skipAny() }
                        }
                }
            }
        }
    }

    /// `S = _{ (WHITESPACE | COMMENT)* }`
    func S() -> Bool {
        zeroOrMore { WHITESPACE() || COMMENT() }
    }

    /// `NEWLINE = _{ "\n" | "\r\n" }`
    func NEWLINE() -> Bool {
        matchString("\n") || matchString("\r\n")
    }

    // MARK: - Rules

    /// `rule = { typename ~ generic_params? ~ S ~ assign_t ~ S ~ !occur ~ type_expr
    ///         | groupname ~ generic_params? ~ S ~ assign_g ~ S ~ group_entry }`
    func rule_() -> Bool {
        rule(.rule) {
            sequence {
                typename() && skip() && optional { generic_params() } && skip() && S() && skip()
                    && assign_t() && skip() && S() && skip() && lookahead(false) { occur() }
                    && skip() && type_expr()
            }
                || sequence {
                    groupname() && skip() && optional { generic_params() } && skip() && S()
                        && skip() && assign_g() && skip() && S() && skip() && group_entry()
                }
        }
    }

    func assign_t() -> Bool {
        rule(.assign_t) { assign() || assign_t_choice() }
    }

    func assign_g() -> Bool {
        rule(.assign_g) { assign() || assign_g_choice() }
    }

    func assign() -> Bool {
        rule(.assign) { matchString("=") }
    }

    func assign_t_choice() -> Bool {
        rule(.assign_t_choice) { matchString("/=") }
    }

    func assign_g_choice() -> Bool {
        rule(.assign_g_choice) { matchString("//=") }
    }

    // MARK: - Generic parameters and arguments

    /// `generic_params = { "<" ~ S ~ generic_param ~ (S ~ "," ~ S ~ generic_param)* ~ S ~ ">" }`
    func generic_params() -> Bool {
        rule(.generic_params) {
            sequence {
                matchString("<") && skip() && S() && skip() && generic_param() && skip()
                    && zeroOrMore {
                        sequence {
                            S() && skip() && matchString(",") && skip() && S() && skip()
                                && generic_param()
                        }
                    }
                    && skip() && S() && skip() && matchString(">")
            }
        }
    }

    func generic_param() -> Bool {
        rule(.generic_param) { id() }
    }

    /// `generic_args = { "<" ~ S ~ generic_arg ~ (S ~ "," ~ S ~ generic_arg)* ~ S ~ ">" }`
    func generic_args() -> Bool {
        rule(.generic_args) {
            sequence {
                matchString("<") && skip() && S() && skip() && generic_arg() && skip()
                    && zeroOrMore {
                        sequence {
                            S() && skip() && matchString(",") && skip() && S() && skip()
                                && generic_arg()
                        }
                    }
                    && skip() && S() && skip() && matchString(">")
            }
        }
    }

    func generic_arg() -> Bool {
        rule(.generic_arg) { type1() }
    }

    // MARK: - Type expressions

    /// `type_expr = { type_choice ~ (S ~ type_choice_op ~ S ~ type_choice)* }`
    func type_expr() -> Bool {
        rule(.type_expr) {
            sequence {
                type_choice() && skip()
                    && zeroOrMore {
                        sequence {
                            S() && skip() && type_choice_op() && skip() && S() && skip()
                                && type_choice()
                        }
                    }
            }
        }
    }

    func type_choice() -> Bool {
        rule(.type_choice) { type1() }
    }

    func type_choice_op() -> Bool {
        rule(.type_choice_op) { matchString("/") }
    }

    /// `type1 = { type2 ~ S ~ (range_op ~ S ~ type2 | control_op ~ S ~ controller)? }`
    func type1() -> Bool {
        rule(.type1) {
            sequence {
                type2() && skip() && S() && skip()
                    && optional {
                        sequence { range_op() && skip() && S() && skip() && type2() }
                            || sequence { control_op() && skip() && S() && skip() && controller() }
                    }
            }
        }
    }

    // MARK: - Operators

    func range_op() -> Bool {
        rule(.range_op) { range_op_exclusive() || range_op_inclusive() }
    }

    func range_op_inclusive() -> Bool {
        rule(.range_op_inclusive) { matchString("..") }
    }

    func range_op_exclusive() -> Bool {
        rule(.range_op_exclusive) { matchString("...") }
    }

    /// `control_op = { "." ~ control_name }`
    func control_op() -> Bool {
        rule(.control_op) {
            sequence { matchString(".") && skip() && control_name() }
        }
    }

    func control_name() -> Bool {
        rule(.control_name) {
            matchString("size") || matchString("bits") || matchString("regexp")
                || matchString("pcre") || matchString("iregexp") || matchString("cborseq")
                || matchString("cbor") || matchString("within") || matchString("and")
                || matchString("lt") || matchString("le") || matchString("gt")
                || matchString("ge") || matchString("eq") || matchString("ne")
                || matchString("default") || matchString("cat") || matchString("det")
                || matchString("plus") || matchString("abnfb") || matchString("abnf")
                || matchString("feature") || matchString("b64u-sloppy")
                || matchString("b64c-sloppy") || matchString("b64u") || matchString("b64c")
                || matchString("hexuc") || matchString("hexlc") || matchString("hex")
                || matchString("base10") || matchString("printf") || matchString("json")
                || matchString("join") || matchString("b32") || matchString("h32")
                || matchString("b45") || matchString("bitfield")
        }
    }

    func controller() -> Bool {
        rule(.controller) { type2() }
    }

    // MARK: - Type2

    func type2() -> Bool {
        rule(.type2) {
            value()
                || sequence { typename() && skip() && optional { generic_args() } }
                || sequence {
                    matchString("(") && skip() && S() && skip() && type_expr() && skip() && S()
                        && skip() && matchString(")")
                }
                || sequence {
                    matchString("{") && skip() && S() && skip() && group() && skip() && S()
                        && skip() && matchString("}")
                }
                || sequence {
                    matchString("[") && skip() && S() && skip() && group() && skip() && S()
                        && skip() && matchString("]")
                }
                || sequence {
                    matchString("~") && skip() && S() && skip() && typename() && skip()
                        && optional { generic_args() }
                }
                || sequence {
                    matchString("&") && skip() && S() && skip() && matchString("(") && skip()
                        && S() && skip() && group() && skip() && S() && skip() && matchString(")")
                }
                || sequence {
                    matchString("&") && skip() && S() && skip() && groupname() && skip()
                        && optional { generic_args() }
                }
                || tag_expr()
        }
    }

    /// `"(" ~ S ~ type_expr ~ S ~ ")"` as it appears inside `tag_expr`.
    private func parenthesizedTagType() -> Bool {
        sequence {
            matchString("(") && skip() && S() && skip() && type_expr() && skip() && S() && skip()
                && matchString(")")
        }
    }

    /// `tag_expr = { "#" ~ DIGIT ~ ("." ~ tag_value)? ~ ("(" ~ S ~ type_expr ~ S ~ ")")?
    ///             | "#" ~ ("(" ~ S ~ type_expr ~ S ~ ")")? }`, with the shared
    /// `"#"` parsed once.
    func tag_expr() -> Bool {
        rule(.tag_expr) {
            sequence {
                matchString("#") && skip()
                    && (sequence {
                        DIGIT() && skip()
                            && optional { sequence { matchString(".") && skip() && tag_value() } }
                            && skip() && optional { parenthesizedTagType() }
                    } || optional { parenthesizedTagType() })
            }
        }
    }

    /// `tag_value = { uint_value | "<" ~ S ~ type_expr ~ S ~ ">" }`
    func tag_value() -> Bool {
        rule(.tag_value) {
            uint_value()
                || sequence {
                    matchString("<") && skip() && S() && skip() && type_expr() && skip() && S()
                        && skip() && matchString(">")
                }
        }
    }

    // MARK: - Groups

    /// `group = { group_choice ~ (S ~ group_choice_op ~ S ~ group_choice)* }`
    func group() -> Bool {
        rule(.group) {
            sequence {
                group_choice() && skip()
                    && zeroOrMore {
                        sequence {
                            S() && skip() && group_choice_op() && skip() && S() && skip()
                                && group_choice()
                        }
                    }
            }
        }
    }

    /// `group_choice = { (group_entry ~ (S ~ optcom? ~ S ~ group_entry)* ~ (S ~ optcom)?)? }`
    func group_choice() -> Bool {
        rule(.group_choice) {
            optional {
                sequence {
                    group_entry() && skip()
                        && zeroOrMore {
                            sequence {
                                S() && skip() && optional { optcom() } && skip() && S() && skip()
                                    && group_entry()
                            }
                        }
                        && skip() && optional { sequence { S() && skip() && optcom() } }
                }
            }
        }
    }

    func group_choice_op() -> Bool {
        rule(.group_choice_op) { matchString("//") }
    }

    func optcom() -> Bool {
        rule(.optcom) { matchString(",") }
    }

    /// `group_entry`, with the shared `occur? ~ S` prefix of its last two
    /// alternatives parsed once.
    func group_entry() -> Bool {
        rule(.group_entry) {
            sequence {
                optional { occur() } && skip() && S() && skip() && matchString("(") && skip() && S()
                    && skip() && group() && skip() && S() && skip()
                    && lookahead(false) {
                        sequence { matchString(")") && skip() && entry_delimiter() }
                    }
                    && skip()
                    && lookahead(false) {
                        sequence {
                            matchString(")") && skip() && S() && skip()
                                && (range_op() || control_op())
                        }
                    }
                    && skip() && matchString(")")
            }
                || sequence {
                    optional { occur() } && skip() && S() && skip() && type_expr() && skip()
                        && lookahead(false) { entry_delimiter() }
                }
                || sequence {
                    optional { occur() } && skip() && S() && skip()
                        && (sequence {
                            member_key() && skip() && S() && skip()
                                && (sequence {
                                    optional { cut() } && skip() && S() && skip() && arrowmap()
                                } || colon())
                                && skip() && S() && skip() && type_expr()
                        } || sequence { groupname() && skip() && optional { generic_args() } })
                }
        }
    }

    /// `entry_delimiter = _{ S ~ ("^" ~ S)? ~ ("=>" | ":") }`
    func entry_delimiter() -> Bool {
        sequence {
            S() && skip() && optional { sequence { matchString("^") && skip() && S() } } && skip()
                && (matchString("=>") || matchString(":"))
        }
    }

    func cut() -> Bool {
        rule(.cut) { matchString("^") }
    }

    func arrowmap() -> Bool {
        rule(.arrowmap) { matchString("=>") }
    }

    func colon() -> Bool {
        rule(.colon) { matchString(":") }
    }

    /// `member_key = { type1 ~ S ~ &(("^" ~ S)? ~ "=>") | bareword | typename ~ generic_args? | value }`
    func member_key() -> Bool {
        rule(.member_key) {
            sequence {
                type1() && skip() && S() && skip()
                    && lookahead(true) {
                        sequence {
                            optional { sequence { matchString("^") && skip() && S() } } && skip()
                                && matchString("=>")
                        }
                    }
            }
                || bareword()
                || sequence { typename() && skip() && optional { generic_args() } }
                || value()
        }
    }

    // MARK: - Occurrence indicators

    func occur() -> Bool {
        rule(.occur) {
            occur_exact() || occur_zero_or_more() || occur_one_or_more() || occur_optional()
                || occur_range()
        }
    }

    /// `occur_exact = @{ uint_value ~ "*" ~ !DIGIT }`
    func occur_exact() -> Bool {
        rule(.occur_exact) {
            atomic(.atomic) {
                sequence { uint_value() && matchString("*") && lookahead(false) { DIGIT() } }
            }
        }
    }

    /// `occur_range = @{ uint_value ~ "*" ~ uint_value | uint_value? ~ "*" ~ uint_value? }`
    func occur_range() -> Bool {
        rule(.occur_range) {
            atomic(.atomic) {
                sequence { uint_value() && matchString("*") && uint_value() }
                    || sequence {
                        optional { uint_value() } && matchString("*") && optional { uint_value() }
                    }
            }
        }
    }

    /// `occur_zero_or_more = @{ "*" ~ !DIGIT }`
    func occur_zero_or_more() -> Bool {
        rule(.occur_zero_or_more) {
            atomic(.atomic) {
                sequence { matchString("*") && lookahead(false) { DIGIT() } }
            }
        }
    }

    func occur_one_or_more() -> Bool {
        rule(.occur_one_or_more) { atomic(.atomic) { matchString("+") } }
    }

    func occur_optional() -> Bool {
        rule(.occur_optional) { atomic(.atomic) { matchString("?") } }
    }

    // MARK: - Identifiers

    /// `id = @{ EALPHA_START ~ (("-" | ".")? ~ (EALPHA | DIGIT))* }`
    func id() -> Bool {
        rule(.id) {
            atomic(.atomic) {
                sequence {
                    EALPHA_START()
                        && repeatLoop {
                            sequence {
                                optional { matchString("-") || matchString(".") }
                                    && (EALPHA() || DIGIT())
                            }
                        }
                }
            }
        }
    }

    /// `typename = { socket_type? ~ id }`
    func typename() -> Bool {
        rule(.typename) {
            sequence { optional { socket_type() } && skip() && id() }
        }
    }

    /// `groupname = { socket_group? ~ id }`
    func groupname() -> Bool {
        rule(.groupname) {
            sequence { optional { socket_group() } && skip() && id() }
        }
    }

    /// `bareword = @{ id }`
    func bareword() -> Bool {
        rule(.bareword) { atomic(.atomic) { id() } }
    }

    func socket_type() -> Bool {
        rule(.socket_type) { matchString("$") }
    }

    func socket_group() -> Bool {
        rule(.socket_group) { matchString("$$") }
    }

    func EALPHA() -> Bool {
        rule(.EALPHA) { ALPHA() || matchString("@") || matchString("_") || matchString("$") }
    }

    func EALPHA_START() -> Bool {
        rule(.EALPHA_START) { ALPHA() || matchString("@") || matchString("_") }
    }

    func ALPHA() -> Bool {
        rule(.ALPHA) {
            matchRange(UInt8(ascii: "a"), UInt8(ascii: "z"))
                || matchRange(UInt8(ascii: "A"), UInt8(ascii: "Z"))
        }
    }

    func DIGIT() -> Bool {
        rule(.DIGIT) { matchRange(UInt8(ascii: "0"), UInt8(ascii: "9")) }
    }

    // MARK: - Values

    func value() -> Bool {
        rule(.value) { number() || text_value() || bytes_value() }
    }

    func number() -> Bool {
        rule(.number) { hexfloat() || float_value() || int_value() || uint_value() }
    }

    @inline(__always)
    private func asciiDigit() -> Bool {
        matchRange(UInt8(ascii: "0"), UInt8(ascii: "9"))
    }

    @inline(__always)
    private func asciiNonzeroDigit() -> Bool {
        matchRange(UInt8(ascii: "1"), UInt8(ascii: "9"))
    }

    @inline(__always)
    private func asciiBinDigit() -> Bool {
        matchRange(UInt8(ascii: "0"), UInt8(ascii: "1"))
    }

    @inline(__always)
    private func asciiHexDigit() -> Bool {
        matchRange(UInt8(ascii: "0"), UInt8(ascii: "9"))
            || matchRange(UInt8(ascii: "a"), UInt8(ascii: "f"))
            || matchRange(UInt8(ascii: "A"), UInt8(ascii: "F"))
    }

    /// The body shared by `uint_value` and `int_value`:
    /// `^"0x" ~ ASCII_HEX_DIGIT+ | ^"0b" ~ ASCII_BIN_DIGIT+ | ASCII_NONZERO_DIGIT ~ DIGIT* | "0"`
    private func unsignedDigits() -> Bool {
        sequence { matchInsensitive("0x") && asciiHexDigit() && repeatLoop { asciiHexDigit() } }
            || sequence { matchInsensitive("0b") && asciiBinDigit() && repeatLoop { asciiBinDigit() } }
            || sequence { asciiNonzeroDigit() && repeatLoop { DIGIT() } }
            || matchString("0")
    }

    func uint_value() -> Bool {
        rule(.uint_value) { atomic(.atomic) { unsignedDigits() } }
    }

    func int_value() -> Bool {
        rule(.int_value) {
            atomic(.atomic) { sequence { matchString("-") && unsignedDigits() } }
        }
    }

    /// `("+" | "-")? ~ DIGIT+` of an exponent.
    private func signedDigits() -> Bool {
        sequence {
            optional { matchString("+") || matchString("-") } && DIGIT() && repeatLoop { DIGIT() }
        }
    }

    /// `float_value = @{ "-"? ~ (ASCII_NONZERO_DIGIT ~ DIGIT* | "0")
    ///   ~ ("." ~ DIGIT+ ~ (^"e" ~ ("+" | "-")? ~ DIGIT+)? | ^"e" ~ ("+" | "-")? ~ DIGIT+) }`
    func float_value() -> Bool {
        rule(.float_value) {
            atomic(.atomic) {
                sequence {
                    optional { matchString("-") }
                        && (sequence { asciiNonzeroDigit() && repeatLoop { DIGIT() } }
                            || matchString("0"))
                        && (sequence {
                            matchString(".") && DIGIT() && repeatLoop { DIGIT() }
                                && optional { sequence { matchInsensitive("e") && signedDigits() } }
                        } || sequence { matchInsensitive("e") && signedDigits() })
                }
            }
        }
    }

    /// `hexfloat = @{ "-"? ~ ^"0x" ~ ASCII_HEX_DIGIT+ ~ ("." ~ ASCII_HEX_DIGIT+)? ~ ^"p"
    ///   ~ ("+" | "-")? ~ DIGIT+ }`
    func hexfloat() -> Bool {
        rule(.hexfloat) {
            atomic(.atomic) {
                sequence {
                    optional { matchString("-") } && matchInsensitive("0x") && asciiHexDigit()
                        && repeatLoop { asciiHexDigit() }
                        && optional {
                            sequence {
                                matchString(".") && asciiHexDigit() && repeatLoop { asciiHexDigit() }
                            }
                        }
                        && matchInsensitive("p") && signedDigits()
                }
            }
        }
    }

    // MARK: - Text values

    /// `text_value = ${ "\"" ~ text_inner ~ "\"" }`
    func text_value() -> Bool {
        atomic(.compoundAtomic) {
            rule(.text_value) {
                sequence { matchString("\"") && text_inner() && matchString("\"") }
            }
        }
    }

    /// `text_inner = @{ text_char* }`
    func text_inner() -> Bool {
        rule(.text_inner) { atomic(.atomic) { repeatLoop { text_char() } } }
    }

    /// `text_char = { escape_sequence | (!("\"" | "\\") ~ ANY) }`
    func text_char() -> Bool {
        rule(.text_char) {
            escape_sequence()
                || sequence {
                    lookahead(false) { matchString("\"") || matchString("\\") } && skip()
                        && skipAny()
                }
        }
    }

    /// `escape_sequence = @{ "\\" ~ ("\"" | "\\" | "/" | "b" | "f" | "n" | "r" | "t"
    ///   | ("u" ~ "{" ~ ASCII_HEX_DIGIT+ ~ "}") | ("u" ~ ASCII_HEX_DIGIT{4})) }`
    func escape_sequence() -> Bool {
        rule(.escape_sequence) {
            atomic(.atomic) {
                sequence {
                    matchString("\\")
                        && (matchString("\"") || matchString("\\") || matchString("/")
                            || matchString("b") || matchString("f") || matchString("n")
                            || matchString("r") || matchString("t")
                            || sequence {
                                matchString("u") && matchString("{") && asciiHexDigit()
                                    && repeatLoop { asciiHexDigit() } && matchString("}")
                            }
                            || sequence {
                                matchString("u") && asciiHexDigit() && asciiHexDigit()
                                    && asciiHexDigit() && asciiHexDigit()
                            })
                }
            }
        }
    }

    // MARK: - Byte strings

    func bytes_value() -> Bool {
        rule(.bytes_value) {
            bytes_b64() || bytes_b16() || bytes_h_quoted() || bytes_utf8()
        }
    }

    /// `bytes_b64 = @{ "b64'" ~ BASE64_INNER ~ "'" }`
    func bytes_b64() -> Bool {
        rule(.bytes_b64) {
            atomic(.atomic) {
                sequence { matchString("b64'") && BASE64_INNER() && matchString("'") }
            }
        }
    }

    /// `bytes_b16 = @{ "h'" ~ HEX_INNER ~ "'" }`
    func bytes_b16() -> Bool {
        rule(.bytes_b16) {
            atomic(.atomic) {
                sequence { matchString("h'") && HEX_INNER() && matchString("'") }
            }
        }
    }

    /// `bytes_h_quoted = @{ "h" ~ "\"" ~ (!("\"") ~ ANY)* ~ "\"" }`
    func bytes_h_quoted() -> Bool {
        rule(.bytes_h_quoted) {
            atomic(.atomic) {
                sequence {
                    matchString("h") && matchString("\"") && skipUntil(UInt8(ascii: "\""))
                        && matchString("\"")
                }
            }
        }
    }

    /// `bytes_utf8 = @{ "'" ~ BYTE_STRING_INNER ~ "'" }`
    func bytes_utf8() -> Bool {
        rule(.bytes_utf8) {
            atomic(.atomic) {
                sequence { matchString("'") && BYTE_STRING_INNER() && matchString("'") }
            }
        }
    }

    /// `BYTE_STRING_INNER = { (bytes_escape | (!(QUOTE | "\\") ~ ANY))* }`
    func BYTE_STRING_INNER() -> Bool {
        rule(.BYTE_STRING_INNER) {
            zeroOrMore {
                bytes_escape()
                    || sequence {
                        lookahead(false) { QUOTE() || matchString("\\") } && skip() && skipAny()
                    }
            }
        }
    }

    /// `bytes_escape = @{ "\\" ~ ANY }`
    func bytes_escape() -> Bool {
        rule(.bytes_escape) {
            atomic(.atomic) { sequence { matchString("\\") && skipAny() } }
        }
    }

    /// `BASE64_INNER = { (!(QUOTE) ~ ANY)* }`
    func BASE64_INNER() -> Bool {
        rule(.BASE64_INNER) {
            zeroOrMore { sequence { lookahead(false) { QUOTE() } && skip() && skipAny() } }
        }
    }

    /// `HEX_INNER = { (!(QUOTE) ~ ANY)* }`
    func HEX_INNER() -> Bool {
        rule(.HEX_INNER) {
            zeroOrMore { sequence { lookahead(false) { QUOTE() } && skip() && skipAny() } }
        }
    }

    /// `QUOTE = _{ "'" }`
    func QUOTE() -> Bool {
        matchString("'")
    }
}
