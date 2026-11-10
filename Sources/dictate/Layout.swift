import Foundation

/// Spoken layout: "bullet sort, bullet scan" -> "- sort\n- scan", "number 1
/// sort, number 2 scan" -> "1. sort\n2. scan", "new line" and "new
/// paragraph". The model writes these as plain words with commas or periods
/// around them, so the triggers are words, guarded so prose keeps them.
enum Layout {
    private enum Kind: Equatable { case bullet, number(Int), line, paragraph }

    /// A trigger found at `start`, `length` words long.
    private struct Trigger { var kind: Kind; var start: Int; var length: Int }

    /// Words before a trigger that make it a noun: "a new line", "the next
    /// bullet", "print new line".
    static let before: Set<String> = [
        "a", "an", "the", "this", "that", "each", "every", "another", "one", "my", "your", "our", "their",
        "his", "her", "its", "per", "of", "on", "in", "with", "without", "by", "for", "to", "no", "any",
        "which", "first", "last", "add", "adds", "insert", "inserts", "start", "starts", "print", "prints",
        "begin", "use", "uses", "need", "needs", "put", "puts", "emit", "emits", "write", "writes",
        "trailing", "strip", "strips", "trim", "trims", "remove", "removes", "split", "splits", "escape",
    ]
    /// Words after a trigger that make it a noun: "bullet points are",
    /// "new line character", "number 1 is speed".
    static let after: Set<String> = [
        "is", "are", "was", "were", "will", "would", "has", "had", "should", "points", "proof", "hole",
        "holes", "wound", "wounds", "train", "journal", "journals", "hit", "hits", "of", "character",
        "characters", "char", "chars", "in", "at", "after", "before", "between", "reason", "priority",
    ]

    static let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                          "eight": 8, "nine": 9, "ten": 10]

    /// With `capitalize`, each new line or item starts with a capital, as
    /// typed; off for `casing: "lower"`.
    static func apply(_ text: String, capitalize: Bool = true) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let bare = { (w: String) in w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var found: [Trigger] = []
        var i = 0
        while i < words.count {
            if let t = trigger(words, i, bare) {
                found.append(t)
                i += t.length
            } else {
                i += 1
            }
        }
        // A list is two items or more, so "the bullet hit" or "number 1
        // priority" alone is prose; numbered items count up from 1.
        if found.filter({ $0.kind == .bullet }).count < 2 { found.removeAll { $0.kind == .bullet } }
        var next = 1
        found.removeAll {
            guard case .number(let n) = $0.kind else { return false }
            if n == next { next += 1; return false }
            return true
        }
        if next < 3 { found.removeAll { if case .number = $0.kind { return true }; return false } }
        guard !found.isEmpty else { return text }

        func piece(_ from: Int, _ to: Int) -> String {
            from < to ? words[from..<to].joined(separator: " ") : ""
        }
        var out = piece(0, found[0].start)
        var inList = false
        for (k, t) in found.enumerated() {
            let end = k + 1 < found.count ? found[k + 1].start : words.count
            var body = piece(t.start + t.length, end)
            // Punctuation the model put after the trigger: "Number 1, sort".
            let lastWord = words[t.start + t.length - 1]
            if let p = lastWord.last, !p.isLetter, !p.isNumber { body = String(p) + body }
            body = String(body.drop { ",.:;".contains($0) || $0 == " " })
            if capitalize, let first = body.first, first.isLowercase, !CodeNotation.startsWithCode(body) {
                body = first.uppercased() + body.dropFirst()
            }
            out = trimEnd(out)
            switch t.kind {
            case .line:
                out += "\n" + body
            case .paragraph:
                out += "\n\n" + body
                inList = false
            case .bullet, .number:
                // An item is a fragment: no period of its own.
                if body.hasSuffix("."), !body.hasSuffix("..") { body.removeLast() }
                if !inList, let last = out.last, last.isLetter || last.isNumber { out += ":" }
                let mark: String
                if case .number(let n) = t.kind { mark = "\(n). " } else { mark = "- " }
                out += (out.isEmpty ? "" : "\n") + mark + body
                inList = true
            }
        }
        return out
    }

    /// Strips the spaces and the comma or semicolon before a trigger.
    private static func trimEnd(_ s: String) -> String {
        var s = s
        while let last = s.last, last == " " || last == "," || last == ";" { s.removeLast() }
        return s
    }

    private static func trigger(_ words: [String], _ i: Int, _ bare: (String) -> String) -> Trigger? {
        // A comma or period before the trigger marks a new clause, so the
        // word before it says nothing.
        if i > 0, words[i - 1].last?.isLetter == true, before.contains(bare(words[i - 1])) { return nil }
        func at(_ k: Int) -> String? { i + k < words.count ? bare(words[i + k]) : nil }
        // Only the trigger's last word may carry punctuation: "new, line" is prose.
        func clean(_ n: Int) -> Bool { (0..<(n - 1)).allSatisfy { words[i + $0].last?.isLetter == true } }
        var t: Trigger?
        if at(0) == "bullet" {
            t = Trigger(kind: .bullet, start: i, length: 1)
        } else if at(0) == "new" || at(0) == "next", at(1) == "bullet", clean(2) {
            t = Trigger(kind: .bullet, start: i, length: 2)
        } else if at(0) == "new", at(1) == "line", clean(2) {
            t = Trigger(kind: .line, start: i, length: 2)
        } else if at(0) == "newline" {
            // The model writes "Dear Sam Newline Thanks" as often as "new line".
            t = Trigger(kind: .line, start: i, length: 1)
        } else if at(0) == "new", at(1) == "paragraph", clean(2) {
            t = Trigger(kind: .paragraph, start: i, length: 2)
        } else if at(0) == "number", let w = at(1), let n = numbers[w] ?? Int(w), clean(2) {
            t = Trigger(kind: .number(n), start: i, length: 2)
        }
        guard var t else { return nil }
        // "bullet point" is the same trigger.
        if t.kind == .bullet, at(t.length) == "point", words[i + t.length - 1].last?.isLetter == true { t.length += 1 }
        // Something must follow, and not a word that makes it a noun.
        guard let follow = at(t.length) else { return nil }
        let last = words[i + t.length - 1].last!
        if last.isLetter || last.isNumber, after.contains(follow) { return nil }
        return t
    }
}
