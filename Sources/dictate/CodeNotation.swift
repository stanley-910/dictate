import Foundation

/// Writes spoken code talk the way it is typed: "O of n log n" -> "O(n log n)",
/// and "take this string s and reverse s" -> "take this string `s` and
/// reverse `s`". The model spells both out in words.
enum CodeNotation {
    static func apply(_ text: String) -> String {
        backtickVariables(bigO(text))
    }

    // MARK: Big-O

    /// "O", "big O" or "oh of", then a math phrase: letters, numbers, log,
    /// squared, to the X, plus, times, factorial, square root of. The phrase
    /// ends at the first word that is not math, so "O of n time" keeps "time"
    /// and "big O notation" is left alone.
    static func bigO(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if isWordStart(chars, i), let (expr, end) = parseBigO(chars, from: i) {
                out += "O(\(expr))"
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

    /// The words after `i`, each preceded by spaces, with where each ends.
    /// Stops at punctuation: "O of 1, and" ends after "1".
    private static func tokens(_ c: [Character], from i: Int) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var j = i
        while true {
            var k = j
            while k < c.count, c[k] == " " { k += 1 }
            guard k > j || (out.isEmpty && k < c.count && c[k].isNumber), let (w, end) = word(c, k) else { break }
            out.append((w, end))
            j = end
            if out.count > 24 { break }
        }
        return out
    }

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
        guard let (expr, used) = Expression.parse(toks.map { $0.0 }), used > 0 else { return nil }
        return (expr, toks[used - 1].1)
    }

    /// A small grammar over spoken math words. Parsing is greedy and keeps the
    /// last point where the phrase was complete, so "O of n plus and" gives
    /// O(n) and leaves "plus and".
    private struct Expression {
        static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                              "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        static let ordinals = ["second": "2", "third": "3", "fourth": "4", "fifth": "5"]
        static let operators = ["plus": "+", "minus": "-", "times": "*", "over": "/"]

        let words: [String]
        var i = 0
        var out = ""
        var best: (String, Int)?

        static func parse(_ words: [String]) -> (String, Int)? {
            var e = Expression(words: words)
            e.run()
            return e.best
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
                let w = words[i]
                let lw = w.lowercased()
                if lw == "log" {
                    out += (expectOperand ? "" : " ") + "log "
                    i += 1
                    if peek() == "of" { i += 1 }
                    guard let o = operand(i < words.count ? words[i] : nil) else { return }
                    out += o
                    i += 1
                    expectOperand = false; previousWasNumber = false
                } else if (lw == "square" && peek(1) == "root") || lw == "root" {
                    guard expectOperand else { return }
                    i += lw == "square" ? 2 : 1
                    if peek() == "of" { i += 1 }
                    guard let o = operand(i < words.count ? words[i] : nil) else { return }
                    out += "√" + o
                    i += 1
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
                } else if !expectOperand, lw == "squared" || lw == "cubed" {
                    out += lw == "squared" ? "^2" : "^3"
                    i += 1
                } else if !expectOperand, lw == "factorial" {
                    out += "!"
                    i += 1
                } else if !expectOperand, lw == "to", peek(1) == "the" {
                    var k = 2
                    if peek(k) == "power", peek(k + 1) == "of" { k += 2 }
                    guard let x = peek(k) else { return }
                    let exponent: String?
                    if let o = Self.ordinals[x] { exponent = o }
                    else if x.count == 3, x.hasSuffix("th"), x.first!.isLetter { exponent = String(words[i + k].prefix(1)) }  // nth, kth
                    else { exponent = operand(words[i + k]) }
                    guard let exponent else { return }
                    out += "^" + exponent
                    i += k + 1
                    if peek() == "power" { i += 1 }
                } else if !expectOperand, let op = Self.operators[lw] ?? (lw == "divided" && peek(1) == "by" ? "/" : nil) {
                    out += " \(op) "
                    i += lw == "divided" ? 2 : 1
                    expectOperand = true
                    previousWasNumber = false
                    continue
                } else {
                    return
                }
                if !expectOperand { best = (out, i) }
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
    /// rest of the text. Letters never introduced that way are left alone, so
    /// "plan B" and "C" (the language) stay as they are.
    static func backtickVariables(_ text: String) -> String {
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
        guard !names.isEmpty else { return text }
        return words.map { w in
            guard let name = letter(w), names.contains(name) else { return w }
            // The letter, then whatever punctuation followed it.
            return "`\(name)`" + w.dropFirst()
        }.joined(separator: " ")
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
