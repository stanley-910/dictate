import Foundation

/// Fuzzy vocabulary correction. The model cannot be biased at decode time,
/// so after transcription each dictionary term is matched against word
/// n-grams of the transcript on a normalized (lowercase, alphanumeric,
/// space-free) form. "neo vim" and "neovim" both normalize to "neovim",
/// so split/joined mishearings need no extra rules; near misses like
/// "neo them" are caught by edit-distance similarity.
enum Dictionary {
    struct Term {
        let display: String
        let key: String
        let words: Int
    }

    static func terms(_ list: [String]) -> [Term] {
        list.compactMap { t in
            let key = normalize(t)
            guard key.count >= 3 else { return nil }
            return Term(display: t, key: key, words: max(1, t.split(separator: " ").count))
        }
    }

    static func apply(_ text: String, terms: [Term], threshold: Double) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        // Tokenize into words with their ranges; punctuation stays attached
        // to the source string and is left untouched outside the core.
        var tokens: [(range: Range<String.Index>, core: String)] = []
        let scanner = text.startIndex
        var i = scanner
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            let word = text[start..<i]
            // Trim leading/trailing punctuation from the range so replacing
            // the core keeps "Neovim," intact.
            var s = word.startIndex, e = word.endIndex
            while s < e, !word[s].isLetter, !word[s].isNumber { s = word.index(after: s) }
            while e > s, !word[word.index(before: e)].isLetter, !word[word.index(before: e)].isNumber {
                e = word.index(before: e)
            }
            if s < e { tokens.append((s..<e, normalize(String(word[s..<e])))) }
        }
        guard !tokens.isEmpty else { return text }

        // Best match per token span, longest span first so "super whisper"
        // is not partially rewritten by a shorter term.
        var edits: [(range: Range<String.Index>, to: String)] = []
        var taken = [Bool](repeating: false, count: tokens.count)
        // +1 for split words; spelled-out acronyms ("G G U F") may span more.
        let maxWords = max(terms.map(\.words).max()! + 1, 6)
        for n in stride(from: maxWords, through: 1, by: -1) {
            guard n <= tokens.count else { continue }
            for start in 0...(tokens.count - n) {
                if (start..<start + n).contains(where: { taken[$0] }) { continue }
                let span = tokens[start..<start + n]
                let key = span.map(\.core).joined()
                guard key.count >= 3 else { continue }
                let spelled = n > 1 && span.allSatisfy { $0.core.count == 1 }
                var best: (Term, Double)?
                for term in terms where abs(term.words - n) <= 1 || spelled {
                    // Cheap length gate before the O(n·m) distance.
                    if abs(term.key.count - key.count) > max(2, term.key.count / 3) { continue }
                    let sim = similarity(key, term.key)
                    if sim >= threshold, sim > (best?.1 ?? 0) { best = (term, sim) }
                }
                if let (term, sim) = best {
                    let original = String(text[span.first!.range.lowerBound..<span.last!.range.upperBound])
                    if original != term.display {
                        edits.append((span.first!.range.lowerBound..<span.last!.range.upperBound, term.display))
                        if sim < 1 { log("dictionary: \"\(original)\" -> \"\(term.display)\" (\(Int(sim * 100))%)") }
                    }
                    for k in start..<start + n { taken[k] = true }
                }
            }
        }
        var out = text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.to)
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 1 - (Damerau-Levenshtein distance / longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.utf8), y = Array(b.utf8)
        let n = x.count, m = y.count
        if n == 0 || m == 0 { return 0 }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    cur[j] = min(cur[j], prev2[j - 2] + 1)
                }
            }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return 1 - Double(prev[m]) / Double(max(n, m))
    }
}
