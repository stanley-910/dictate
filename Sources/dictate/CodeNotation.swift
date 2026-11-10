import Foundation

/// Writes spoken code talk the way it is typed: "O of n log n" -> "O(n log n)",
/// "4 minus 52" -> "4 - 52", "take this string s and reverse s" -> "take
/// this string `s` and reverse `s`", "s of i equals s of j" -> "`s[i] ==
/// s[j]`" and "camel case max depth" -> "`maxDepth`". The model writes
/// numbers as digits but spells the rest out in words.
enum CodeNotation {
    /// With `spans`, every converted expression is put in backticks, not
    /// only those that use a declared variable: "`4 - 52`", "`O(n)`".
    static func apply(_ text: String, spans: Bool = false) -> String {
        var out = identifiers(text)
        out = bigO(out, spans: spans)
        let names = declaredNames(out)
        out = arithmetic(out, names: names, functions: declaredNames(out, after: functionWords), spans: spans)
        out = symbols(out)
        return backtickVariables(out, names: names)
    }

    /// Whether `text` opens with a variable or an expression ("x^2 + 1",
    /// "i % n", "a == b", "x+y", "`s` is"), which sentence casing must not
    /// capitalize. "i - unlike him -" is prose: the right side must be an
    /// operand too.
    static func startsWithCode(_ text: String) -> Bool {
        if text.hasPrefix("`") { return true }
        let words = text.split(separator: " ", maxSplits: 3).map(String.init)
        guard let head = words.first, let first = head.first, first.isLetter, first.isASCII else { return false }
        let rest = head.dropFirst()
        // "x^2", "n!", "s[i]", "x+y" (not "x-ray")
        if let next = rest.first, "^![+*/%=<>".contains(next) { return true }
        guard rest.isEmpty, head != "I", words.count > 2, codeOperators.contains(words[1]) else { return false }
        let right = words[2]
        guard let r = right.first else { return false }
        if r.isNumber || r == "-" || r == "(" || r == "`" { return true }
        // "y", "y.", "y^2", "y!", "s[i]": one letter, then no more letters.
        return r.isLetter && r.isASCII && !right.dropFirst().contains(where: \.isLetter)
    }

    /// What `arithmetic` and the comparisons write between operands.
    static let codeOperators: Set<String> = [
        "+", "-", "*", "/", "%", "=", "==", "!=", "<", ">", "<=", ">=", "->", "=>", "+=", "-=", "*=", "&&", "||", "≈",
    ]

    // MARK: arithmetic

    /// Operator words between operands: "4 minus 52" -> "4 - 52", "i mod n"
    /// -> "i % n", "x squared plus 1" -> "x^2 + 1", "negative 48" -> "-48",
    /// "n is at least 2" -> "n >= 2", and for a declared variable "s of i"
    /// or "s at i" -> "s[i]". It needs an operand on each side, so "5 plus
    /// years", "C plus plus" and "three times a day" stay as they are. An
    /// expression that uses a declared variable goes in backticks whole.
    /// A spoken identifier ("`maxDepth`") is an operand too, and a declared
    /// function or an identifier before "of" is called: "f of x" -> f(x).
    static func arithmetic(_ text: String, names: Set<String> = [], functions: Set<String> = [], spans: Bool = false) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if isWordStart(chars, i), chars[i].isLetter || chars[i].isNumber || identifierEnd(chars, i) != nil {
                let toks = tokens(chars, from: i, first: true)
                if let found = Expression.parse(toks.map { $0.0 }, mode: .arithmetic, names: names, functions: functions),
                   found.used > 0, found.math {
                    out += spans || found.usesName ? "`\(found.text)`" : found.text
                    i = toks[found.used - 1].1
                    continue
                }
            }
            if let end = spanEnd(chars, i) ?? bigOEnd(chars, i) {
                out += String(chars[i..<end])
                i = end
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Past the closing backtick when a code span opens at `i`: code already
    /// written is left alone. Runs of backticks ("``x``") close on the same run.
    private static func spanEnd(_ c: [Character], _ i: Int) -> Int? {
        guard c[i] == "`" else { return nil }
        var n = 0
        while i + n < c.count, c[i + n] == "`" { n += 1 }
        var j = i + n
        while j < c.count {
            if c[j] == "`" {
                var m = 0
                while j + m < c.count, c[j + m] == "`" { m += 1 }
                if m == n { return j + m }
                j += m
            } else { j += 1 }
        }
        return nil
    }

    /// Past the closing backtick of a spoken identifier at `i`: "`maxDepth`".
    private static func identifierEnd(_ c: [Character], _ i: Int) -> Int? {
        guard c[i] == "`", i + 1 < c.count, c[i + 1].isLetter || c[i + 1] == "_" else { return nil }
        var j = i + 1
        while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
        return j < c.count && c[j] == "`" ? j + 1 : nil
    }

    /// Past the ")" of an `O(...)` that `bigO` wrote at `i`, so arithmetic
    /// does not take its inside apart again.
    private static func bigOEnd(_ c: [Character], _ i: Int) -> Int? {
        guard "OΘΩ".contains(c[i]), i + 1 < c.count, c[i + 1] == "(", isWordStart(c, i) else { return nil }
        var depth = 0
        for j in (i + 1)..<c.count {
            if c[j] == "(" { depth += 1 } else if c[j] == ")" { depth -= 1; if depth == 0 { return j + 1 } }
        }
        return nil
    }

    // MARK: Big-O

    /// "O", "big O" or "oh of", then a math phrase: letters, numbers, log,
    /// squared, to the X, plus, times, factorial, square root of. The phrase
    /// ends at the first word that is not math, so "O of n time" keeps "time"
    /// and "big O notation" is left alone.
    static func bigO(_ text: String, spans: Bool = false) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if let end = spanEnd(chars, i) {
                out += String(chars[i..<end])
                i = end
            } else if isWordStart(chars, i), let (head, expr, end) = parseBigO(chars, from: i) {
                out += spans ? "`\(head)(\(expr))`" : "\(head)(\(expr))"
                i = end
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func isWordStart(_ c: [Character], _ i: Int) -> Bool {
        i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "'" || c[i - 1] == "’")
    }

    /// The letters (or digits) of one word starting at `i`, and where it ends.
    private static func word(_ c: [Character], _ i: Int, digits: Bool = true) -> (String, Int)? {
        var j = i
        while j < c.count, c[j].isLetter || (digits && c[j].isNumber) { j += 1 }
        // "1.5": a point between digits stays in the number.
        while digits, j > i, c[j - 1].isNumber, j + 1 < c.count, c[j] == ".", c[j + 1].isNumber {
            j += 1
            while j < c.count, c[j].isNumber { j += 1 }
        }
        // "x.length", "node.next" as the model writes them; "e.g." is not one.
        while digits, j > i, c[j - 1].isLetter, j + 2 < c.count, c[j] == ".", c[j + 1].isLetter, c[j + 2].isLetter {
            j += 1
            while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
        }
        return j > i ? (String(c[i..<j]), j) : nil
    }

    /// The words after `i`, each preceded by spaces, with where each ends;
    /// with `first`, the word at `i` is the first of them. Stops at
    /// punctuation: "O of 1, and" ends after "1".
    private static func tokens(_ c: [Character], from i: Int, first: Bool = false) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var j = i
        while true {
            var k = j
            while k < c.count, c[k] == " " { k += 1 }
            // An operator the model wrote itself, alone between spaces: "i + 1".
            if k > j, k < c.count, "+-*/%".contains(c[k]), k + 1 < c.count, c[k + 1] == " " {
                out.append((String(c[k]), k + 1))
                j = k + 1
                continue
            }
            if k > j || (out.isEmpty && first), k < c.count, let end = identifierEnd(c, k) {
                out.append((String(c[k..<end]), end))
                j = end
                continue
            }
            guard k > j || (out.isEmpty && k < c.count && (first || c[k].isNumber)), let (w, end) = word(c, k) else { break }
            out.append((w, end))
            j = end
            if out.count > 24 { break }
        }
        return out
    }

    /// Words that follow a complexity: "O(1) time", "O(1) lookups".
    static let complexityWords: Set<String> = [
        "time", "space", "memory", "extra", "auxiliary", "lookup", "lookups", "access", "accesses",
        "insert", "inserts", "insertion", "insertions", "delete", "deletes", "deletion", "deletions",
        "operation", "operations", "op", "ops", "work", "runtime", "complexity", "amortized",
        "average", "worst", "best", "per", "each", "and", "or", "but", "so", "because", "which",
        "since", "if", "when", "while", "in", "for", "with", "to", "is", "too", "instead", "then",
    ]

    /// "theta of n" and "omega of n" are bounds like "O of n".
    static let bounds = ["o": "O", "oh": "O", "theta": "Θ", "omega": "Ω"]

    private static func parseBigO(_ c: [Character], from i: Int) -> (String, String, Int)? {
        guard var (w, end) = word(c, i, digits: false) else { return nil }
        if w.lowercased() == "big" {
            guard end < c.count, c[end] == " " || c[end] == "-",
                  let next = word(c, end + 1, digits: false) else { return nil }
            (w, end) = next
        }
        let lower = w.lowercased()
        guard let head = bounds[lower] else { return nil }
        var toks = tokens(c, from: end)
        if toks.first?.0.lowercased() == "of" {
            toks.removeFirst()
        } else if lower != "o" {
            return nil  // "oh n" is not how anyone says it; "oh, so" and "theta is" must stay
        }
        guard let found = Expression.parse(toks.map { $0.0 }, mode: .bigO), found.used > 0 else { return nil }
        let (expr, used) = (found.text, found.used)
        // "oh of one thing" is not O(1): a spelled number alone only counts at
        // the end of a clause or before a word that says what is O(1).
        if used == 1, Expression.numbers[toks[0].0.lowercased()] != nil, used < toks.count,
           !complexityWords.contains(toks[used].0.lowercased()) {
            return nil
        }
        return (head, expr, toks[used - 1].1)
    }

    /// A small grammar over spoken math words. Parsing is greedy and keeps the
    /// last point where the phrase was complete, so "O of n plus and" gives
    /// O(n) and leaves "plus and". Outside O(...) a phrase needs an operator
    /// to count, "I" before one is the variable i, and "log" and a bare
    /// "root" are words ("write to the log 2 times"). Inside brackets
    /// (`index`) a lone operand counts and there are no comparisons.
    private struct Expression {
        enum Mode { case bigO, arithmetic, index, group }
        struct Found {
            var text: String; var used: Int; var usesName: Bool
            /// Not only "not x", which counts only joined to a comparison.
            var math = true
            /// A comparison, or "not x": what "and" and "or" join.
            var comparison = false, boolean = false
        }

        static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                              "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        static let ordinals = ["second": "2", "third": "3", "fourth": "4", "fifth": "5"]
        static let operators = ["plus": "+", "minus": "-", "times": "*", "over": "/", "mod": "%", "modulo": "%",
                                "arrow": "->", "+": "+", "-": "-", "*": "*", "/": "/", "%": "%"]
        /// "open paren ... close paren", and how the model hears "paren".
        static let groups = ["paren": "(", "parens": "(", "parent": "(", "parenthesis": "(",
                             "bracket": "[", "brackets": "["]
        /// Longest first, so "less than or equal to" wins over "less than".
        static let comparisons: [([String], String)] = [
            (["is", "less", "than", "or", "equal", "to"], "<="), (["less", "than", "or", "equal", "to"], "<="),
            (["is", "greater", "than", "or", "equal", "to"], ">="), (["greater", "than", "or", "equal", "to"], ">="),
            (["is", "not", "equal", "to"], "!="), (["does", "not", "equal"], "!="), (["not", "equal", "to"], "!="),
            (["is", "less", "than"], "<"), (["is", "greater", "than"], ">"), (["is", "equal", "to"], "=="),
            (["is", "at", "most"], "<="), (["is", "at", "least"], ">="), (["is", "set", "to"], "="),
            (["less", "than"], "<"), (["greater", "than"], ">"), (["equal", "to"], "=="),
            (["double", "equals"], "=="), (["at", "most"], "<="), (["at", "least"], ">="),
            (["equals"], "=="),
            (["is", "approximately", "equal", "to"], "≈"), (["is", "approximately"], "≈"),
            (["approximately", "equal", "to"], "≈"), (["approximately", "equals"], "≈"), (["is", "roughly"], "≈"),
        ]

        let words: [String]
        let mode: Mode
        let names: Set<String>
        var functions: Set<String> = []
        var i = 0
        var out = ""
        var best: Found?
        /// An operator, power, factorial or sign so far: plain "4" is not math.
        private var sawMath = false
        private var usesName = false
        private var lastOperand = ""
        private var sawComparison = false
        private var negated = false
        private var arithmetic: Bool { mode != .bigO }

        static func parse(_ words: [String], mode: Mode, names: Set<String> = [], functions: Set<String> = []) -> Found? {
            var e = Expression(words: words, mode: mode, names: names, functions: functions)
            e.run()
            return e.best
        }

        private func isOperator(_ w: String?) -> Bool {
            guard let w else { return false }
            return Self.operators[w] != nil || w == "divided" || w == "squared" || w == "cubed" || w == "fat"
        }

        /// The comparison spoken at `k` words ahead, and how many words it takes.
        private func comparison(_ k: Int = 0) -> (String, Int)? {
            guard mode == .arithmetic else { return nil }
            for (spoken, op) in Self.comparisons where i + k + spoken.count <= words.count {
                if words[(i + k)..<(i + k + spoken.count)].map({ $0.lowercased() }) == spoken { return (op, spoken.count) }
            }
            return nil
        }

        private func peek(_ k: Int = 0) -> String? {
            i + k < words.count ? words[i + k].lowercased() : nil
        }

        /// A letter or a number, as written, or nil.
        private func operand(_ w: String?) -> String? {
            guard let w else { return nil }
            if let n = Self.numbers[w.lowercased()] { return n }
            if w.allSatisfy(\.isNumber) { return w }
            if w.split(separator: ".", omittingEmptySubsequences: false).count == 2,
               w.allSatisfy({ $0.isNumber || $0 == "." }), w.first!.isNumber, w.last!.isNumber { return w }
            // "2n" as the model writes it
            if let last = w.last, last.isLetter, w.count > 1, w.dropLast().allSatisfy(\.isNumber) { return w }
            // "a" and "I" are words, not variables, except in "open paren a plus b".
            if w.count == 1, w.first!.isLetter, w != "a" || mode == .group, w != "I" { return w }
            // A spoken identifier, "`maxDepth`", or a member the model wrote, "x.length".
            if w.count > 2, w.hasPrefix("`"), w.hasSuffix("`") { return String(w.dropFirst().dropLast()) }
            if w.contains("."), w.first!.isLetter, w.split(separator: ".").allSatisfy({ $0.first!.isLetter }) { return w }
            return nil
        }

        /// The exponent spoken `k` words ahead, "minus 3" or "9", and the words it takes.
        private func power(_ k: Int) -> (String, Int)? {
            var k = k, sign = ""
            if peek(k) == "minus" || peek(k) == "negative" { sign = "-"; k += 1 }
            guard i + k < words.count, let o = operand(words[i + k]) else { return nil }
            return (sign + o, sign.isEmpty ? 1 : 2)
        }

        /// "sum from i equals 1 to n of x sub i" -> Σ_{i=1}^n x_i, and
        /// "product" -> Π. The "of" and what follows it are needed, so "the
        /// sum from the first" and "sum from 1 to n" stay.
        private func series() -> (String, Int)? {
            guard peek(1) == "from", i + 4 < words.count, let v = operand(words[i + 2]), v.first!.isLetter,
                  peek(3) == "equals",
                  let low = Expression.parse(Array(words[(i + 4)...]), mode: .index, names: names),
                  peek(4 + low.used) == "to", i + 5 + low.used < words.count,
                  let high = Expression.parse(Array(words[(i + 5 + low.used)...]), mode: .index, names: names),
                  peek(5 + low.used + high.used) == "of", i + 6 + low.used + high.used < words.count,
                  let body = Expression.parse(Array(words[(i + 6 + low.used + high.used)...]), mode: .index,
                                              names: names, functions: functions) else { return nil }
            let top = high.text.contains(" ") ? "{\(high.text)}" : high.text
            let sign = peek() == "sum" ? "Σ" : "Π"
            return ("\(sign)_{\(v)=\(low.text)}^\(top) \(body.text)", 6 + low.used + high.used + body.used)
        }

        /// A word that "plus equals" or "plus plus" follows: "count plus
        /// equals 1" -> count += 1, "count plus plus" -> count++.
        private func assignTarget(_ w: String) -> Bool {
            guard mode == .arithmetic, out.isEmpty, w.count > 1, w.allSatisfy({ $0.isLowercase || $0 == "_" }),
                  let p = peek(1), p == "plus" || p == "minus" || p == "times" else { return false }
            return peek(2) == "equals" || (peek(2) == p && p != "times")
        }

        /// The arguments after "of" at `i`: "f of x and y" -> "x, y".
        private func arguments() -> (String, Int)? {
            var k = i + 1
            var parts: [String] = []
            var used = 0
            while k < words.count, let sub = Expression.parse(Array(words[k...]), mode: .index, names: names, functions: functions) {
                parts.append(sub.text)
                k += sub.used
                used = k - i
                guard k + 1 < words.count, ["and", "comma"].contains(words[k].lowercased()) else { break }
                k += 1
            }
            return parts.isEmpty ? nil : (parts.joined(separator: ", "), used)
        }

        /// The inside of "open paren ... close paren" starting at `i`, and
        /// the words it takes, when it closes with the same kind.
        private func group(_ open: String) -> (String, Int)? {
            guard i + 2 < words.count, let sub = Expression.parse(Array(words[(i + 2)...]), mode: .group, names: names),
                  peek(2 + sub.used) == "close", peek(3 + sub.used).flatMap({ Self.groups[$0] }) == open else { return nil }
            return (sub.text, sub.used + 4)
        }

        private var found: Found {
            Found(text: out, used: i, usesName: usesName, math: sawMath || mode != .arithmetic,
                  comparison: sawComparison, boolean: sawComparison || negated)
        }

        private mutating func run() {
            var expectOperand = true
            var previousWasNumber = false
            while i < words.count {
                var w = words[i]
                let lw = w.lowercased()
                // "I mod n", "s of I": the model capitalizes the variable i.
                if arithmetic, w == "I", expectOperand, mode == .index || mode == .group || isOperator(peek(1)) || comparison(1) != nil { w = "i" }
                if arithmetic, lw == "open", let open = peek(1).flatMap({ Self.groups[$0] }),
                   expectOperand || open == "[", let (inner, used) = group(open) {
                    // "open paren a plus b close paren", or after an operand
                    // "open bracket i close bracket" -> [i]
                    out += open + inner + (open == "(" ? ")" : "]")
                    i += used
                    sawMath = true
                    expectOperand = false; previousWasNumber = false
                } else if mode == .arithmetic, expectOperand, lw == "not", out.isEmpty || out.hasSuffix("& ") || out.hasSuffix("| "),
                          i + 1 < words.count, operand(words[i + 1]) != nil {
                    // "not visited" -> !visited, counted only beside a comparison.
                    out += "!"
                    i += 1
                    negated = true
                    continue
                } else if expectOperand, lw == "negative", let o = operand(peek(1).map { _ in words[i + 1] }) {
                    out += "-" + o
                    i += 2
                    sawMath = true
                    if names.contains(o) { usesName = true }
                    lastOperand = o
                    previousWasNumber = o.first!.isNumber
                    expectOperand = false
                } else if expectOperand, lw == "log", peek(1) == "base", let b = operand(i + 2 < words.count ? words[i + 2] : nil) {
                    // "log base 2 of n" -> log_2 n
                    i += 3
                    if peek() == "of" { i += 1 }
                    guard let o = operand(i < words.count ? words[i] : nil) else { return }
                    out += "log_\(b) \(o)"
                    i += 1
                    sawMath = true
                    expectOperand = false; previousWasNumber = false
                } else if arithmetic, expectOperand, lw == "sum" || lw == "product", let (text, used) = series() {
                    out += text
                    i += used
                    sawMath = true
                    expectOperand = false; previousWasNumber = false
                } else if !arithmetic, lw == "log" {
                    out += (expectOperand ? "" : " ") + "log "
                    i += 1
                    if peek() == "of" { i += 1 }
                    guard let o = operand(i < words.count ? words[i] : nil) else { return }
                    out += o
                    i += 1
                    expectOperand = false; previousWasNumber = false
                } else if (lw == "square" && peek(1) == "root") || (!arithmetic && lw == "root") {
                    guard expectOperand else { return }
                    i += lw == "square" ? 2 : 1
                    if peek() == "of" { i += 1 }
                    guard let o = operand(i < words.count ? words[i] : nil) else { return }
                    out += "√" + o
                    i += 1
                    sawMath = true
                    expectOperand = false; previousWasNumber = false
                } else if let o = operand(w) ?? (assignTarget(w) ? w : nil) {
                    if !expectOperand {
                        // "2 n" -> 2n; any other pair of operands ends the phrase.
                        guard previousWasNumber, !o.first!.isNumber else { return }
                    }
                    // "s of i plus s of j" is s[i] + s[j]: an index ends before another indexed name.
                    if mode == .index, !out.isEmpty, names.contains(o), peek(1) == "of" || peek(1) == "at" { return }
                    let identifier = w.hasPrefix("`")
                    lastOperand = o
                    out += o
                    i += 1
                    previousWasNumber = o.first!.isNumber
                    expectOperand = false
                    if o.contains(".") { sawMath = true }
                    if identifier || names.contains(String(o.prefix { $0 != "." })) { usesName = true }
                    if functions.contains(o) || identifier, peek() == "of", let (args, used) = arguments() {
                        // "f of x and y" -> f(x, y), for a declared function or a spoken identifier
                        out += "(\(args))"
                        i += used
                        sawMath = true
                    } else if names.contains(o), !functions.contains(o) || peek() == "at" {
                        // "s of i plus 1" -> s[i + 1]
                        if peek() == "of" || peek() == "at", i + 1 < words.count,
                           let sub = Expression.parse(Array(words[(i + 1)...]), mode: .index, names: names, functions: functions) {
                            out += "[\(sub.text)]"
                            i += 1 + sub.used
                            sawMath = true
                        }
                    }
                    // "x dot length" -> x.length, after a letter, a declared name or an identifier.
                    let named = identifier || names.contains(o) || (o.count == 1 && o.first!.isLetter) || operand(w) == nil
                    while arithmetic, named, peek() == "dot", i + 1 < words.count,
                          case let m = words[i + 1], m.count > 1, m.allSatisfy(\.isLetter),
                          !identifierStops.contains(m.lowercased()), m.lowercased() != "product" {
                        out += "." + m
                        i += 2
                        sawMath = true
                    }
                    // "x sub i" -> x_i, "n choose k" -> C(n, k); not "I sub in", "I choose 2".
                    if arithmetic, o.count == 1, o.first!.isLetter, peek() == "sub",
                       let sub = operand(i + 1 < words.count ? (words[i + 1] == "I" ? "i" : words[i + 1]) : nil) {
                        out += "_" + sub
                        i += 2
                        sawMath = true
                    }
                    if arithmetic, peek() == "choose", out.hasSuffix(o), let k = operand(i + 1 < words.count ? words[i + 1] : nil) {
                        out = String(out.dropLast(o.count)) + "C(\(o), \(k))"
                        i += 2
                        sawMath = true
                    }
                    // "i plus plus" -> i++, not "C plus plus" (a capital needs declaring).
                    if arithmetic, named, !(o.first!.isUppercase && o.count == 1 && !names.contains(o)),
                       let p = peek(), p == peek(1), p == "plus" || p == "minus" {
                        out += p == "plus" ? "++" : "--"
                        i += 2
                        sawMath = true
                    }
                } else if !expectOperand, let (op, length) = comparison(),
                          // "at least 3 people" is prose; "n is at least 3" is not.
                          !(previousWasNumber && op.count == 2 && words[i + length - 2].lowercased() == "at"),
                          // "Plan B is at least 2 hours": a capital letter compares only once declared.
                          !(lastOperand.count == 1 && lastOperand.first!.isUppercase && !names.contains(lastOperand)) {
                    out += " \(op) "
                    i += length
                    sawMath = true
                    sawComparison = true
                    expectOperand = true
                    previousWasNumber = false
                    continue
                } else if !expectOperand, lw == "squared" || lw == "cubed" {
                    out += lw == "squared" ? "^2" : "^3"
                    i += 1
                    sawMath = true
                } else if !expectOperand, lw == "factorial" {
                    out += "!"
                    i += 1
                    sawMath = true
                } else if !expectOperand, lw == "to", peek(1) == "the" {
                    var k = 2
                    if peek(k) == "power", peek(k + 1) == "of" { k += 2 }
                    var sign = ""
                    if peek(k) == "minus" || peek(k) == "negative" { sign = "-"; k += 1 }  // "x to the minus 1" -> x^-1
                    guard let x = peek(k) else { return }
                    var exponent: String?
                    if let o = Self.ordinals[x] { exponent = o }
                    else if x.count == 3, x.hasSuffix("th"), x.first!.isLetter { exponent = String(words[i + k].prefix(1)) }  // nth, kth
                    else if x.hasSuffix("th"), x.dropLast(2).allSatisfy(\.isNumber), x.count > 2 { exponent = String(x.dropLast(2)) }  // 10th
                    else { exponent = operand(words[i + k]) }
                    guard let e = exponent else { return }
                    exponent = sign + e
                    guard let exponent else { return }
                    if names.contains(e) { usesName = true }
                    out += "^" + exponent
                    i += k + 1
                    sawMath = true
                    if peek() == "power" { i += 1 }
                } else if !expectOperand, mode == .arithmetic, lw == "and" || lw == "or", sawComparison || negated,
                          i + 1 < words.count,
                          let next = Expression.parse(Array(words[(i + 1)...]), mode: .arithmetic, names: names, functions: functions),
                          next.boolean, sawComparison || next.comparison {
                    // "i is less than j and j is less than n" -> i < j && j < n: only between comparisons.
                    out += (lw == "and" ? " && " : " || ") + next.text
                    i += 1 + next.used
                    if next.usesName { usesName = true }
                    sawMath = true
                    sawComparison = true
                    best = found
                    return
                } else if !expectOperand, lw == "times", out.hasSuffix(lastOperand), lastOperand.first?.isNumber == true,
                          lastOperand.allSatisfy({ $0.isNumber || $0 == "." }), peek(1) == "10", peek(2) == "to", peek(3) == "the",
                          let (exponent, used) = power(4), Int(exponent) != nil {
                    // "2.5 times 10 to the minus 3" -> 2.5e-3
                    out += "e" + exponent
                    i += 4 + used
                    sawMath = true
                    previousWasNumber = false
                } else if !expectOperand, mode == .arithmetic, ["plus", "minus", "times"].contains(lw), peek(1) == "equals" {
                    // "count plus equals 1" -> count += 1
                    out += " \(Self.operators[lw]!)= "
                    i += 2
                    sawMath = true
                    expectOperand = true
                    previousWasNumber = false
                    continue
                } else if !expectOperand, let op = Self.operators[lw] ?? (lw == "divided" && peek(1) == "by" ? "/" : nil)
                            ?? (lw == "fat" && peek(1) == "arrow" ? "=>" : nil),
                          !(op.hasSuffix(">") && mode != .arithmetic) {
                    out += " \(op) "
                    i += lw == "divided" || lw == "fat" ? 2 : 1
                    sawMath = true
                    expectOperand = true
                    previousWasNumber = false
                    continue
                } else {
                    return
                }
                if !expectOperand, sawMath || mode != .arithmetic || negated { best = found }
            }
        }
    }

    // MARK: symbols

    /// Words before "double colon" or "open paren" that make it a noun:
    /// "a double colon", "use double colon syntax", "the open paren".
    static let symbolNouns: Set<String> = [
        "a", "an", "the", "this", "that", "each", "every", "one", "no", "any", "missing", "unmatched",
        "extra", "single", "triple", "use", "uses", "write", "writes", "type", "types", "add", "put",
        "with", "without", "like", "say", "says", "of", "or", "and", "is", "are",
    ]
    /// Words after "double colon" that are not a name: "double colon syntax".
    static let symbolEnds: Set<String> = ["syntax", "notation", "operator", "operators", "separator", "here", "there", "instead"]

    /// "dot dot dot", or ". . ." as the model writes it -> "...";
    /// "std double colon vector" -> std::vector between two names; "open
    /// paren in dollars close paren" -> "(in dollars)" when a matching close
    /// follows within 16 words. Expressions in parens were already written
    /// by `arithmetic`.
    static func symbols(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #" ?\.( \.){2,}"#, with: "...", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i) ?\bdot dot dot\b"#, with: "...", options: .regularExpression)
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let bare = { (w: String) in w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        // A name: letters, digits and "_", or code in backticks.
        let isName = { (w: String) -> Bool in
            let core = w.hasPrefix("`") && w.hasSuffix("`") && w.count > 2 ? String(w.dropFirst().dropLast()) : w
            guard let first = core.first, first.isLetter || first == "_" else { return false }
            return core.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }
        }
        var out: [String] = []
        var inSpan = false
        var i = 0
        scan: while i < words.count {
            let w = words[i]
            if !inSpan, i + 2 < words.count, let left = out.last, bare(w) == "double", w.last?.isLetter == true,
               bare(words[i + 1]) == "colon", words[i + 1].last?.isLetter == true, isName(left),
               left == left.uppercased() || !symbolNouns.contains(left) && !identifierStops.contains(left) {
                let right = words[i + 2]
                let core = String(right.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" })
                if isName(core), !identifierStops.contains(core.lowercased()), !symbolEnds.contains(core.lowercased()) {
                    out[out.count - 1] = left + "::" + right
                    i += 3
                    continue
                }
            }
            if !inSpan, bare(w) == "open", w.last?.isLetter == true, i + 1 < words.count,
               let open = Expression.groups[bare(words[i + 1])] ?? (bare(words[i + 1]) == "brace" ? "{" : nil),
               out.last.map({ $0.last?.isLetter != true || !symbolNouns.contains($0.lowercased()) }) ?? true {
                let close = open == "(" ? ")" : open == "[" ? "]" : "}"
                var j = i + 2
                while j + 1 < words.count, j < i + 18, bare(words[j]) != "open" {
                    let kind = bare(words[j + 1])
                    if bare(words[j]) == "close", (Expression.groups[kind] ?? (kind == "brace" ? "{" : nil)) == open, j > i + 2 {
                        let inner = words[(i + 2)..<j].joined(separator: " ")
                        let trail = words[j + 1].drop { $0.isLetter }
                        out.append(open + inner + close + trail)
                        i = j + 2
                        continue scan
                    }
                    j += 1
                }
            }
            if w.filter({ $0 == "`" }).count % 2 == 1 { inSpan.toggle() }
            out.append(w)
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: identifiers

    /// The spoken case styles, each with how it joins words.
    static let caseStyles: [([String], ([String]) -> String)] = [
        (["screaming", "snake", "case"], { $0.map { $0.uppercased() }.joined(separator: "_") }),
        (["constant", "case"], { $0.map { $0.uppercased() }.joined(separator: "_") }),
        (["camel", "case"], { ws in ws.enumerated().map { $0 == 0 ? $1 : $1.prefix(1).uppercased() + $1.dropFirst() }.joined() }),
        (["camelcase"], { ws in ws.enumerated().map { $0 == 0 ? $1 : $1.prefix(1).uppercased() + $1.dropFirst() }.joined() }),
        (["pascal", "case"], { $0.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }),
        (["pascalcase"], { $0.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }),
        (["snake", "case"], { $0.joined(separator: "_") }),
        (["snakecase"], { $0.joined(separator: "_") }),
        (["kebab", "case"], { $0.joined(separator: "-") }),
        (["kebabcase"], { $0.joined(separator: "-") }),
    ]

    /// Words that end a spoken identifier: "camel case max depth to 0" is
    /// `maxDepth` to 0. As the first word only `identifierStarts` count, so
    /// "camel case is valid" is `isValid` but "camel case for names" stays.
    static let identifierStops: Set<String> = [
        "and", "or", "then", "to", "is", "are", "was", "were", "be", "in", "on", "at", "of", "for", "with",
        "from", "by", "as", "into", "the", "a", "an", "it", "its", "if", "when", "while", "so", "but", "not",
        "equals", "equal", "plus", "minus", "times", "over", "mod", "divided", "less", "greater", "than",
        "that", "which", "this", "these", "those", "we", "you", "i", "he", "she", "they", "should", "would",
        "will", "can", "could", "must", "call", "calls", "set", "returns", "return", "gets", "has", "have",
    ]
    static let identifierStarts: Set<String> = ["is", "has", "get", "gets", "set", "can", "should", "to", "on", "as", "will"]
    /// After these, a case style is talked about, not used: "the camel case
    /// style", "I prefer snake case names".
    static let caseArticles: Set<String> = [
        "the", "a", "an", "in", "with", "prefer", "prefers", "like", "likes", "about", "of", "than",
        "is", "are", "not",
    ]
    /// The most words one identifier takes.
    static let maxIdentifierWords = 4

    /// "camel case max depth" -> `maxDepth`, "snake case user id" ->
    /// `user_id`, also "pascal", "kebab" and "screaming snake" / "constant"
    /// case. The words run to punctuation, a stop word or
    /// `maxIdentifierWords`. Once named, a later "max depth" is `maxDepth`
    /// too. Code already in backticks is left alone.
    static func identifiers(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let bare = { (w: String) in w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var named: [([String], String)] = []
        var out: [String] = []
        var inSpan = false
        var i = 0
        scan: while i < words.count {
            if !inSpan {
                for (spoken, join) in caseStyles where i + spoken.count < words.count {
                    let trigger = words[i..<(i + spoken.count)]
                    // Punctuation inside "camel, case" means it was not a command.
                    guard trigger.map(bare) == spoken, trigger.allSatisfy({ $0.last?.isLetter == true }),
                          i == 0 || !caseArticles.contains(bare(words[i - 1])) else { continue }
                    var parts: [String] = []
                    var trail = ""
                    var j = i + spoken.count
                    while j < words.count, parts.count < maxIdentifierWords {
                        let w = words[j]
                        let core = w.trimmingCharacters(in: .punctuationCharacters)
                        guard !core.isEmpty, core.allSatisfy({ $0.isLetter || $0.isNumber }), w.hasPrefix(core),
                              !identifierStops.contains(core.lowercased())
                                || (parts.isEmpty && identifierStarts.contains(core.lowercased())) else { break }
                        parts.append(core.lowercased())
                        j += 1
                        if w != core { trail = String(w.dropFirst(core.count)); break }
                    }
                    guard !parts.isEmpty else { continue }
                    // "(camel case x" keeps its "(".
                    let lead = String(words[i].prefix { !$0.isLetter })
                    let name = join(parts)
                    out.append(lead + "`\(name)`" + trail)
                    if parts.count > 1 { named.append((parts, name)) }
                    i = j
                    continue scan
                }
                // A later mention of a name given earlier, in plain words.
                for (parts, name) in named where i + parts.count <= words.count {
                    let run = words[i..<(i + parts.count)]
                    let last = run.last!
                    let core = last.trimmingCharacters(in: .punctuationCharacters)
                    guard run.map(bare) == parts, run.dropLast().allSatisfy({ $0.last?.isLetter == true }),
                          last.hasPrefix(core), run.first!.first?.isLetter == true else { continue }
                    out.append("`\(name)`" + last.dropFirst(core.count))
                    i += parts.count
                    continue scan
                }
            }
            if words[i].filter({ $0 == "`" }).count % 2 == 1 { inSpan.toggle() }
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: variables

    /// Type words a variable's name follows: "the string s", "pointer p".
    static let declarers: Set<String> = [
        "string", "strings", "array", "arrays", "list", "lists", "variable", "variables", "var",
        "integer", "integers", "int", "number", "numbers", "pointer", "pointers", "node", "nodes",
        "tree", "graph", "matrix", "map", "hashmap", "set", "dict", "dictionary", "index", "indices",
        "function", "parameter", "param", "argument", "arg", "key", "value", "char", "character",
        "vertex", "vertices", "edge", "counter", "word", "pattern", "target", "input", "output",
        "vector", "stack", "queue", "heap", "grid", "prefix", "suffix", "substring", "subarray",
        "sum", "row", "column", "col", "element", "item", "object", "type", "field",
        "buffer", "window", "interval", "length", "size", "count", "constant", "loop",
    ]

    /// A single letter right after a type word ("string s", "pointers i and
    /// j") becomes `s`, and so does every standalone use of that letter in the
    /// rest of the text, outside code already in backticks. Letters never
    /// introduced that way are left alone, so "plan B" and "C" (the language)
    /// stay as they are.
    static func backtickVariables(_ text: String, names: Set<String>? = nil) -> String {
        let names = names ?? declaredNames(text)
        guard !names.isEmpty else { return text }
        var inSpan = false
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let w = String(word)
            defer { if w.filter({ $0 == "`" }).count % 2 == 1 { inSpan.toggle() } }
            guard !inSpan, let name = letter(w), names.contains(name) else { return w }
            // The letter, then whatever punctuation followed it.
            return "`\(name)`" + w.dropFirst()
        }.joined(separator: " ")
    }

    /// The letters introduced as variables: "string s", "pointers i and j".
    /// Type words a function's name follows: "the function f".
    static let functionWords: Set<String> = ["function", "functions", "method", "methods"]

    static func declaredNames(_ text: String, after declarers: Set<String> = declarers) -> Set<String> {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var names: Set<String> = []
        var i = 0
        while i < words.count {
            let w = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if declarers.contains(w), !words[i].hasSuffix(","), !words[i].hasSuffix(".") {
                var j = i + 1
                while j < words.count, let name = letter(words[j]) {
                    names.insert(name)
                    // "i and j", "i, j"
                    if words[j].hasSuffix(","), j + 1 < words.count, letter(words[j + 1]) != nil { j += 1; continue }
                    if j + 2 < words.count, words[j + 1].lowercased() == "and", letter(words[j + 2]) != nil { j += 2; continue }
                    break
                }
            }
            i += 1
        }
        return names
    }

    /// The variable a word is, when it is one letter followed by nothing but
    /// end-of-clause punctuation: "s", "s,", "s." (not "s's", "x-axis", "e.g.").
    private static func letter(_ w: String) -> String? {
        guard let first = w.first, first.isLetter, first.isASCII, w != "a", w != "I" else { return nil }
        let rest = w.dropFirst()
        guard rest.count <= 1, rest.allSatisfy({ ",.;:?!".contains($0) }) else { return nil }
        return String(first)
    }
}
