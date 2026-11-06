import Foundation

/// Writes spoken code talk the way it is typed: "O of n log n" -> "O(n log n)",
/// "4 minus 52" -> "4 - 52", "take this string s and reverse s" -> "take
/// this string `s` and reverse `s`", and "s of i equals s of j" -> "`s[i] ==
/// s[j]`". The model writes
/// numbers as digits but spells the rest out in words.
enum CodeNotation {
    /// With `spans`, every converted expression is put in backticks, not
    /// only those that use a declared variable: "`4 - 52`", "`O(n)`".
    static func apply(_ text: String, spans: Bool = false) -> String {
        var out = bigO(text, spans: spans)
        let names = declaredNames(out)
        out = arithmetic(out, names: names, spans: spans)
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
        return right.first.map { $0.isNumber || $0 == "-" || $0 == "(" || $0 == "`" } == true
            || (right.count == 1 || right.dropLast().count == 1 && !right.last!.isLetter) && right.first!.isLetter
    }

    /// What `arithmetic` and the comparisons write between operands.
    static let codeOperators: Set<String> = ["+", "-", "*", "/", "%", "=", "==", "!=", "<", ">", "<=", ">="]

    // MARK: arithmetic

    /// Operator words between operands: "4 minus 52" -> "4 - 52", "i mod n"
    /// -> "i % n", "x squared plus 1" -> "x^2 + 1", "negative 48" -> "-48",
    /// "n is at least 2" -> "n >= 2", and for a declared variable "s of i"
    /// or "s at i" -> "s[i]". It needs an operand on each side, so "5 plus
    /// years", "C plus plus" and "three times a day" stay as they are. An
    /// expression that uses a declared variable goes in backticks whole.
    static func arithmetic(_ text: String, names: Set<String> = [], spans: Bool = false) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if let end = spanEnd(chars, i) {
                out += String(chars[i..<end])
                i = end
                continue
            }
            if isWordStart(chars, i), chars[i].isLetter || chars[i].isNumber {
                let toks = tokens(chars, from: i, first: true)
                if let found = Expression.parse(toks.map { $0.0 }, mode: .arithmetic, names: names), found.used > 0 {
                    out += spans || found.usesName ? "`\(found.text)`" : found.text
                    i = toks[found.used - 1].1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Past the closing backtick when a code span opens at `i`: code already
    /// written is left alone.
    private static func spanEnd(_ c: [Character], _ i: Int) -> Int? {
        guard c[i] == "`", let close = c[(i + 1)...].firstIndex(of: "`") else { return nil }
        return close + 1
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
            } else if isWordStart(chars, i), let (expr, end) = parseBigO(chars, from: i) {
                out += spans ? "`O(\(expr))`" : "O(\(expr))"
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

    private static func parseBigO(_ c: [Character], from i: Int) -> (String, Int)? {
        guard var (w, end) = word(c, i, digits: false) else { return nil }
        if w.lowercased() == "big" {
            guard end < c.count, c[end] == " " || c[end] == "-",
                  let next = word(c, end + 1, digits: false) else { return nil }
            (w, end) = next
        }
        let lower = w.lowercased()
        guard lower == "o" || lower == "oh" else { return nil }
        var toks = tokens(c, from: end)
        if toks.first?.0.lowercased() == "of" {
            toks.removeFirst()
        } else if lower == "oh" {
            return nil  // "oh n" is not how anyone says it; "oh, so" must stay
        }
        guard let found = Expression.parse(toks.map { $0.0 }, mode: .bigO), found.used > 0 else { return nil }
        let (expr, used) = (found.text, found.used)
        // "oh of one thing" is not O(1): a spelled number alone only counts at
        // the end of a clause or before a word that says what is O(1).
        if used == 1, Expression.numbers[toks[0].0.lowercased()] != nil, used < toks.count,
           !complexityWords.contains(toks[used].0.lowercased()) {
            return nil
        }
        return (expr, toks[used - 1].1)
    }

    /// A small grammar over spoken math words. Parsing is greedy and keeps the
    /// last point where the phrase was complete, so "O of n plus and" gives
    /// O(n) and leaves "plus and". Outside O(...) a phrase needs an operator
    /// to count, "I" before one is the variable i, and "log" and a bare
    /// "root" are words ("write to the log 2 times"). Inside brackets
    /// (`index`) a lone operand counts and there are no comparisons.
    private struct Expression {
        enum Mode { case bigO, arithmetic, index }
        struct Found { var text: String; var used: Int; var usesName: Bool }

        static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                              "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        static let ordinals = ["second": "2", "third": "3", "fourth": "4", "fifth": "5"]
        static let operators = ["plus": "+", "minus": "-", "times": "*", "over": "/", "mod": "%", "modulo": "%",
                                "+": "+", "-": "-", "*": "*", "/": "/", "%": "%"]
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
        ]

        let words: [String]
        let mode: Mode
        let names: Set<String>
        var i = 0
        var out = ""
        var best: Found?
        /// An operator, power, factorial or sign so far: plain "4" is not math.
        private var sawMath = false
        private var usesName = false
        private var arithmetic: Bool { mode != .bigO }

        static func parse(_ words: [String], mode: Mode, names: Set<String> = []) -> Found? {
            var e = Expression(words: words, mode: mode, names: names)
            e.run()
            return e.best
        }

        private func isOperator(_ w: String?) -> Bool {
            guard let w else { return false }
            return Self.operators[w] != nil || w == "divided" || w == "squared" || w == "cubed"
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
            // "2n" as the model writes it
            if let last = w.last, last.isLetter, w.count > 1, w.dropLast().allSatisfy(\.isNumber) { return w }
            // "a" and "I" are words, not variables.
            if w.count == 1, w.first!.isLetter, w != "a", w != "I" { return w }
            return nil
        }

        private mutating func run() {
            var expectOperand = true
            var previousWasNumber = false
            while i < words.count {
                var w = words[i]
                let lw = w.lowercased()
                // "I mod n", "s of I": the model capitalizes the variable i.
                if arithmetic, w == "I", expectOperand, mode == .index || isOperator(peek(1)) || comparison(1) != nil { w = "i" }
                if expectOperand, lw == "negative", let o = operand(peek(1).map { _ in words[i + 1] }) {
                    out += "-" + o
                    i += 2
                    sawMath = true
                    previousWasNumber = o.first!.isNumber
                    expectOperand = false
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
                } else if let o = operand(w) {
                    if !expectOperand {
                        // "2 n" -> 2n; any other pair of operands ends the phrase.
                        guard previousWasNumber, !o.first!.isNumber else { return }
                    }
                    out += o
                    i += 1
                    previousWasNumber = o.first!.isNumber
                    expectOperand = false
                    if names.contains(o) {
                        usesName = true
                        // "s of i plus 1" -> s[i + 1]
                        if peek() == "of" || peek() == "at", i + 1 < words.count,
                           let sub = Expression.parse(Array(words[(i + 1)...]), mode: .index, names: names) {
                            out += "[\(sub.text)]"
                            i += 1 + sub.used
                            sawMath = true
                        }
                    }
                } else if !expectOperand, let (op, length) = comparison(),
                          // "at least 3 people" is prose; "n is at least 3" is not.
                          !(previousWasNumber && op.count == 2 && words[i + length - 2].lowercased() == "at") {
                    out += " \(op) "
                    i += length
                    sawMath = true
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
                    guard let x = peek(k) else { return }
                    let exponent: String?
                    if let o = Self.ordinals[x] { exponent = o }
                    else if x.count == 3, x.hasSuffix("th"), x.first!.isLetter { exponent = String(words[i + k].prefix(1)) }  // nth, kth
                    else if x.hasSuffix("th"), x.dropLast(2).allSatisfy(\.isNumber), x.count > 2 { exponent = String(x.dropLast(2)) }  // 10th
                    else { exponent = operand(words[i + k]) }
                    guard let exponent else { return }
                    out += "^" + exponent
                    i += k + 1
                    sawMath = true
                    if peek() == "power" { i += 1 }
                } else if !expectOperand, let op = Self.operators[lw] ?? (lw == "divided" && peek(1) == "by" ? "/" : nil) {
                    out += " \(op) "
                    i += lw == "divided" ? 2 : 1
                    sawMath = true
                    expectOperand = true
                    previousWasNumber = false
                    continue
                } else {
                    return
                }
                if !expectOperand, sawMath || mode != .arithmetic { best = Found(text: out, used: i, usesName: usesName) }
            }
        }
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
    static func declaredNames(_ text: String) -> Set<String> {
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
