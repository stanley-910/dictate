import Foundation

/// The join between two pieces decoded apart. The model ends every clip with
/// a full stop and starts the next with a capital, so a cut in a pause
/// mid-sentence reads as a new sentence. A probe, a short decode that heard
/// both sides of the cut, says whether the sentence runs on.
enum Seam {
    /// Words at each side of the cut matched against the probe.
    static let anchorWords = 3
    /// Words the probe may hear at the cut that neither piece kept: a clip
    /// often drops a trailing "and" or "so".
    static let maxDropped = 2

    /// `left` and `right` with the full stop between them taken out when
    /// `probe` runs through the cut without ending a sentence: the stop
    /// becomes the probe's comma (if any), words the probe heard at the cut
    /// go back in, and `right`'s first word is lowercased unless it is "I"
    /// or the probe capitalizes it too. Unchanged when the probe ends a
    /// sentence there, or cannot be lined up with both sides for sure.
    static func mend(_ left: String, _ right: String, probe: String) -> (String, String) {
        let l = words(left), r = words(right), p = words(probe)
        guard let lastLeft = l.last, let firstRight = r.first,
              lastLeft.text.hasSuffix("."), !lastLeft.text.hasSuffix("..."),
              let (at, dropped) = align(l, r, in: p) else { return (left, right) }
        // `at` is the probe's copy of left's last word; the cut follows it or the dropped words.
        let through = p[at...(at + dropped)]
        guard !through.contains(where: { endsSentence($0.text) }) else { return (left, right) }

        let carried = trailing(p[at + dropped].text).filter { ",;:".contains($0) }
        var head = String(left.dropLast())
        if dropped > 0 {
            head += " " + p[(at + 1)...(at + dropped)].map { stripped($0.text) }.joined(separator: " ")
        }
        head += carried

        var tail = right
        if !keepsCapital(firstRight, probe: p[at + dropped + 1].text),
           let i = right.firstIndex(where: \.isLetter), right[i].isUppercase,
           right.distance(from: right.startIndex, to: i) < firstRight.text.count {
            tail.replaceSubrange(i...i, with: right[i].lowercased())
        }
        return (head, tail)
    }

    /// Where `left`'s last words and `right`'s first words sit in `probe`,
    /// with up to `maxDropped` probe words between: the index of left's last
    /// word and the number of words between. nil when no place matches
    /// enough of both, or two places match equally well.
    static func align(_ left: [Word], _ right: [Word], in probe: [Word]) -> (at: Int, dropped: Int)? {
        let l = left.suffix(anchorWords).map(\.key), r = right.prefix(anchorWords).map(\.key)
        guard !l.isEmpty, !r.isEmpty else { return nil }
        // The words touching the cut must match, and one more on each side if there is one.
        let needLeft = min(2, l.count), needRight = min(2, r.count)
        var best: (at: Int, dropped: Int, score: Int)?
        var tied = false
        for at in probe.indices {
            for dropped in 0...maxDropped {
                let start = at + dropped + 1
                guard start < probe.count else { break }
                let leftHits = l.reversed().enumerated().filter { k, key in at - k >= 0 && probe[at - k].key == key }
                let rightHits = r.enumerated().filter { k, key in start + k < probe.count && probe[start + k].key == key }
                guard leftHits.first?.offset == 0, rightHits.first?.offset == 0,
                      leftHits.count >= needLeft, rightHits.count >= needRight else { continue }
                let left = leftHits.count, right = rightHits.count
                // A dropped word costs a match, so the closer reading wins.
                let score = left + right - dropped
                if let b = best, b.score == score { tied = true }
                if best == nil || score > best!.score { best = (at, dropped, score); tied = false }
            }
        }
        guard let best, !tied else { return nil }
        return (best.at, best.dropped)
    }

    struct Word: Equatable {
        let text: String
        /// Lowercase letters, digits and apostrophes: how words are compared.
        let key: String
    }

    /// Whitespace-separated words; bare punctuation ("-", "—") is left out.
    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let key = token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
            return key.isEmpty ? nil : Word(text: String(token), key: key)
        }
    }

    private static func endsSentence(_ word: String) -> Bool {
        trailing(word).contains { ".?!…".contains($0) }
    }

    /// The punctuation a word ends with.
    private static func trailing(_ word: String) -> String {
        String(word.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    private static func stripped(_ word: String) -> String {
        String(word.dropLast(trailing(word).count))
    }

    /// "I" and its contractions, acronyms, and words the probe also writes
    /// with a capital mid-sentence (names) keep theirs.
    private static func keepsCapital(_ word: Word, probe: String) -> Bool {
        if word.key == "i" || word.key.hasPrefix("i'") || word.key.hasPrefix("i’") { return true }
        let letters = word.text.filter(\.isLetter)
        if letters.count > 1 && letters.allSatisfy(\.isUppercase) { return true }
        return probe.first(where: \.isLetter)?.isUppercase ?? false
    }
}
